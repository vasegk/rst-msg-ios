import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class ChatViewModel {
    let chatId: String
    let isGroup: Bool

    private(set) var messages: [ChatMessage] = []
    private(set) var hasMore = false
    private(set) var loading = true
    private(set) var loadingOlder = false
    private(set) var loadError: String?
    private(set) var pinned: [ChatMessage] = []
    private(set) var groupInfo: GroupInfoResponse?
    private(set) var keyState: GroupKeyState?
    private(set) var keyChanged = false
    /// Для своих сообщений в группе: выше этой отметки прочитано (group_read).
    var replyTo: ChatMessage?
    var editing: ChatMessage?
    private(set) var text = ""
    var toast: String?
    var sending = false
    /// Прокрутить к сообщению (ответ, закреп).
    var scrollTarget: Int64?
    var highlighted: Int64?

    @ObservationIgnored private let services: Services
    @ObservationIgnored private var subscription: UUID?
    @ObservationIgnored private var oldestId: Int64?
    @ObservationIgnored private var lastGroupRead: Int64 = 0
    @ObservationIgnored private var typingSentAt: Date?
    @ObservationIgnored private var typingStopTask: Task<Void, Never>?
    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?
    @ObservationIgnored var visible = false
    @ObservationIgnored private var suppressDraft = false

    init(chatId: String, services: Services) {
        self.chatId = chatId
        self.isGroup = MessageRepository.isGroup(chatId)
        self.services = services
        subscription = services.socket.subscribe(owner: self) { [weak self] event in self?.handle(event) }
        text = UserDefaults.standard.string(forKey: draftKey) ?? ""
    }

    /// Поле ввода меняет текст только здесь: черновик и «печатает…».
    func updateText(_ value: String) {
        let old = text
        text = value
        textChanged(old)
    }

    /// Экран ушёл с глаз (другая вкладка, назад). Подписка на сокет снимется
    /// сама вместе с моделью — здесь только гасим «печатает».
    func dispose() {
        visible = false
        stopTyping()
    }

    var me: String { services.me }
    var summary: ChatSummary? { services.chats.chat(chatId) }
    var isSaved: Bool { chatId == me }
    var title: String { services.chats.title(for: chatId) }
    var myRole: String { summary?.myRole ?? groupInfo?.members?.first { $0.username == me }?.role ?? "member" }
    var canModerate: Bool { ["owner", "admin", "editor", "helper"].contains(myRole) }
    var isChannel: Bool { summary?.isChannel ?? groupInfo?.isChannel ?? false }

    var canWrite: Bool {
        if services.chats.blockedUntil != nil { return false }
        if let summary { return summary.canWrite }
        return true
    }

    /// Очередь без связи для этого чата — с часиками в ленте.
    var pendingMessages: [ChatMessage] {
        _ = services.chats.outboxVersion
        return services.messages.outbox.filter { $0.chatId == chatId }.map {
            ChatMessage(id: $0.localId, sender: me, isMine: true, text: $0.text, createdAt: $0.createdAt, pending: true)
        }
    }

    var subtitle: String {
        if let typing = services.chats.typingText(chatId, isGroup: isGroup) { return typing }
        if isSaved { return "заметки для себя" }
        if isGroup {
            if isChannel {
                let n = groupInfo?.subscribers ?? groupInfo?.members?.count ?? 0
                return n > 0 ? "канал · \(n) подписч." : "канал"
            }
            let n = groupInfo?.members?.count ?? 0
            return n > 0 ? "\(n) \(Plural.members(n))" : "группа"
        }
        guard let s = summary else { return "" }
        if s.isSystem { return "служебный аккаунт" }
        if s.isDeleted { return "аккаунт удалён" }
        if s.online { return "в сети" }
        if s.status == "dnd" { return "не беспокоить" }
        return TimeFormat.lastSeen(s.lastSeen)
    }

    // MARK: - Загрузка

    @ObservationIgnored private var loadedOnce = false

    /// Первая загрузка; при возврате на экран — только догнать новое.
    func loadIfNeeded() async {
        if loadedOnce {
            await catchUp()
            return
        }
        loadedOnce = true
        await load()
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            let history = try await services.messages.history(chatId)
            messages = history.messages
            hasMore = history.hasMore
            oldestId = history.oldestId ?? history.messages.first?.id
            loadError = nil
            if let keys = services.keyCache.get(chatId) { keyState = keys.groupState }
            keyChanged = !isGroup && services.userKeys.keyChanged.contains(chatId)
            markVisibleRead()
        } catch {
            if messages.isEmpty { loadError = errorText(error) }
        }
        Task { await loadPinned() }
        if isGroup { Task { await loadGroupInfo() } }
        Task { await syncDraftFromServer() }
    }

    func loadOlder() async {
        guard hasMore, !loadingOlder, let before = oldestId else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let page = try await services.messages.history(chatId, beforeId: before)
            let known = Set(messages.map(\.id))
            messages = page.messages.filter { !known.contains($0.id) } + messages
            hasMore = page.hasMore
            oldestId = page.oldestId ?? page.messages.first?.id ?? oldestId
        } catch {
            toast = errorText(error)
        }
    }

    func loadPinned() async {
        pinned = (try? await services.messages.pinned(chatId)) ?? pinned
    }

    func loadGroupInfo() async {
        guard let info = try? await services.api.groupInfo(chatId) else { return }
        groupInfo = info
        // Раздать ключ тем, у кого его нет (вступили по короткой ссылке или из поиска)
        if let keys = services.keyCache.get(chatId), keys.realGroupKey != nil {
            await services.groupKeys.shareWithNewcomers(groupId: String(chatId.dropFirst(6)), keys: keys, members: info.members ?? [])
        }
    }

    /// Догнать пропущенное после перерыва в связи.
    private func catchUp() async {
        guard let last = messages.last(where: { $0.id > 0 })?.id else {
            await load()
            return
        }
        guard let fresh = try? await services.messages.since(chatId, afterId: last) else { return }
        merge(fresh)
        markVisibleRead()
    }

    private func merge(_ fresh: [ChatMessage]) {
        guard !fresh.isEmpty else { return }
        var byId = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for m in fresh { byId[m.id] = m }
        messages = byId.values.sorted { $0.id < $1.id }
    }

    // MARK: - Прочтение

    /// Отмечать прочитанным — только когда чат действительно перед глазами.
    func markVisibleRead() {
        guard visible else { return }
        if isGroup {
            // Своё тоже: сервер считает непрочитанным всё после отметки
            guard let last = messages.last(where: { $0.id > 0 }), last.id > lastGroupRead else { return }
            lastGroupRead = last.id
            services.socket.sendRead(messageId: last.id, sender: chatId)
        } else {
            for m in messages where !m.isMine && !m.isRead && !m.isSystem && m.id > 0 {
                services.socket.sendRead(messageId: m.id, sender: m.sender)
                if let i = messages.firstIndex(where: { $0.id == m.id }) { messages[i].status = "read" }
            }
        }
        services.chats.update(chatId) { $0.unread = 0 }
    }

    // MARK: - События

    private func belongs(_ receiver: String, sender: String? = nil) -> Bool {
        if isGroup { return receiver == chatId }
        if let sender { return services.messages.chatId(sender: sender, receiver: receiver) == chatId }
        return receiver == chatId || receiver == me
    }

    private func handle(_ event: WsEvent) {
        switch event {
        case .newMessage(let dto, let receiver):
            guard dto.commentTo == nil,
                  services.messages.chatId(sender: dto.sender, receiver: receiver) == chatId else { return }
            Task {
                let message = await services.messages.decryptSingle(dto, chatId: chatId)
                merge([message])
                scrollTarget = message.id
                if !message.isMine { markVisibleRead() }
            }
        case .messageEdited(let id, let content, _):
            guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
            let old = messages[index]
            Task {
                var keys: ChatKeys?
                if let found = try? await services.messages.readKeys(for: chatId) { keys = found }
                var updated = old
                switch MessageCrypto.decrypt(keys, content) {
                case .text(let t): updated.text = t; updated.quote = nil
                case .enveloped(let e):
                    updated.text = e.text
                    updated.quote = e.quote
                    if let q = e.quote, !q.isEmpty { updated.reply?.text = q }
                    if e.geo != nil { updated.live = e.geo }
                case .undecryptable: updated.undecryptable = true
                }
                if updated.live == nil { updated.isEdited = true }
                if let i = messages.firstIndex(where: { $0.id == id }) { messages[i] = updated }
            }
        case .messageDeleted(let id, _):
            messages.removeAll { $0.id == id }
            pinned.removeAll { $0.id == id }
        case .reactionUpdate(let id, let reactions, _):
            if let i = messages.firstIndex(where: { $0.id == id }) {
                messages[i].reactions = MessageRepository.parseReactions(reactions)
            }
        case .messageRead(let id, let receiver, _):
            guard !isGroup, belongs(receiver) else { return }
            for i in messages.indices where messages[i].isMine && messages[i].id <= id && messages[i].id > 0 {
                messages[i].status = "read"
            }
        case .groupRead(let group, _, let upTo):
            guard group == chatId else { return }
            for i in messages.indices where messages[i].isMine && messages[i].id <= upTo {
                messages[i].status = "read"
            }
        case .pinChanged(let id, let isPinned, _, _):
            guard let i = messages.firstIndex(where: { $0.id == id }) else {
                Task { await loadPinned() }
                return
            }
            messages[i].isPinned = isPinned
            Task { await loadPinned() }
        case .pollUpdate(let id, _, let poll, let my):
            guard let i = messages.firstIndex(where: { $0.id == id }), var current = messages[i].poll else { return }
            var state = PollState(poll) ?? current.state
            // my приходит только моим устройствам; у остальных свой выбор не трогаем
            state.my = my ?? current.state.my
            current.state = state
            messages[i].poll = current
        case .messagePlayed(let id, _):
            if let i = messages.firstIndex(where: { $0.id == id }) { messages[i].played = true }
        case .chatCleared(let target):
            if target == chatId { Task { await load() } }
        case .groupKeyShared(let groupId, _):
            let target = groupId.hasPrefix("group_") ? groupId : "group_" + groupId
            guard target == chatId else { return }
            Task {
                if await services.messages.onGroupKeyShared(chatId) {
                    toast = "Ключ шифрования группы получен"
                }
                await load()
            }
        case .groupSettingsChanged(let groupId):
            if groupId == chatId { Task { await loadGroupInfo() } }
        case .connection(let connected, let reconnected):
            if connected && reconnected { Task { await catchUp() } }
        case .serverError(let message):
            if visible && !message.isEmpty { toast = message }
        default:
            break
        }
    }

    // MARK: - Отправка

    func send() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !sending else { return }
        if body.count > 4096 {
            toast = "Сообщение длиннее 4096 символов"
            return
        }
        let reply = replyTo
        let editTarget = editing
        sending = true
        Task {
            defer { sending = false }
            do {
                if let editTarget {
                    try await services.messages.edit(chatId, messageId: editTarget.id, text: body, quote: editTarget.quote)
                } else {
                    try await services.messages.sendText(chatId, text: body, replyTo: reply?.id)
                }
                updateText("")
                replyTo = nil
                editing = nil
                stopTyping()
            } catch {
                toast = errorText(error)
            }
        }
    }

    func sendAttachment(data: Data, fileName: String, mimeType: String, caption: String = "", compress: Bool = true) async {
        sending = true
        defer { sending = false }
        do {
            var payload = data
            var mime = mimeType
            var name = fileName
            if compress && mimeType.hasPrefix("image/") && mimeType != "image/gif",
               let compressed = AttachmentRepository.compressImage(data) {
                payload = compressed
                mime = "image/jpeg"
                name = ((fileName as NSString).deletingPathExtension.isEmpty ? "photo" : (fileName as NSString).deletingPathExtension) + ".jpg"
            }
            // Ключ ждём до загрузки: иначе файл ушёл бы зря
            let keys = try await services.messages.keys(for: chatId)
            if keys.isKeyPending { throw GroupKeyPendingError() }
            let uploaded = try await services.attachments.upload(payload)
            try await services.messages.sendAttachment(chatId, text: caption, fileUrl: uploaded.fileUrl, fileKeyB64: uploaded.keyB64,
                                                       fileName: name, mimeType: mime, replyTo: replyTo?.id)
            replyTo = nil
        } catch {
            toast = errorText(error)
        }
    }

    func sendVoice(url: URL, duration: TimeInterval) async {
        guard duration >= 0.7, let data = try? Data(contentsOf: url) else {
            toast = duration < 0.7 ? "Слишком короткое голосовое" : "Не удалось прочитать запись"
            return
        }
        await sendAttachment(data: data, fileName: "voice.m4a", mimeType: "audio/mp4", caption: Previews.voiceText)
        try? FileManager.default.removeItem(at: url)
    }

    func sendPoll(question: String, options: [String], multiple: Bool, anonymous: Bool, correct: Int?) async -> Bool {
        do {
            try await services.messages.sendPoll(chatId, question: question, options: options, multiple: multiple,
                                                 anonymous: anonymous, correct: correct)
            return true
        } catch {
            toast = errorText(error)
            return false
        }
    }

    // MARK: - Действия с сообщением

    func startReply(_ m: ChatMessage) {
        editing = nil
        replyTo = m
    }

    func startEdit(_ m: ChatMessage) {
        replyTo = nil
        editing = m
        suppressDraft = true
        updateText(m.text)
        suppressDraft = false
    }

    func cancelCompose() {
        if editing != nil {
            suppressDraft = true
            updateText("")
            suppressDraft = false
        }
        editing = nil
        replyTo = nil
    }

    func react(_ m: ChatMessage, _ emoji: String) {
        if !services.socket.sendReaction(messageId: m.id, emoji: emoji) { toast = NotConnectedError().errorDescription }
    }

    func delete(_ m: ChatMessage, forEveryone: Bool) {
        if m.pending { return }
        if services.socket.sendDelete(messageId: m.id, mode: forEveryone ? "both" : "me") {
            if !forEveryone { messages.removeAll { $0.id == m.id } }
        } else {
            toast = NotConnectedError().errorDescription
        }
    }

    func togglePin(_ m: ChatMessage) {
        if !services.socket.sendPin(messageId: m.id, pinned: !m.isPinned) { toast = NotConnectedError().errorDescription }
    }

    func forward(_ m: ChatMessage, to target: String) async -> Bool {
        do {
            try await services.messages.forward(m, to: target)
            return true
        } catch {
            toast = errorText(error)
            return false
        }
    }

    func vote(_ m: ChatMessage, options: [Int]) {
        if !services.socket.sendPollVote(messageId: m.id, options: options) { toast = NotConnectedError().errorDescription }
    }

    func closePoll(_ m: ChatMessage) {
        if !services.socket.sendPollClose(messageId: m.id) { toast = NotConnectedError().errorDescription }
    }

    func markPlayed(_ m: ChatMessage) {
        guard !m.isMine, !m.played, m.id > 0 else { return }
        services.socket.sendPlayed(messageId: m.id)
        if let i = messages.firstIndex(where: { $0.id == m.id }) { messages[i].played = true }
    }

    func jump(to id: Int64) {
        if messages.contains(where: { $0.id == id }) {
            scrollTarget = id
            highlighted = id
            Task {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                if highlighted == id { highlighted = nil }
            }
        } else {
            toast = "Сообщение слишком старое — пролистайте выше"
        }
    }

    func acknowledgeKeyChange() {
        services.userKeys.acknowledgeKeyChange(chatId)
        keyChanged = false
    }

    // MARK: - Набор текста и черновик

    private var draftKey: String { "rst.draft.\(services.me).\(chatId)" }

    private func textChanged(_ old: String) {
        guard !suppressDraft, text != old else { return }
        if editing == nil {
            UserDefaults.standard.set(text.isEmpty ? nil : text, forKey: draftKey)
            scheduleDraftSync()
        }
        if text.isEmpty {
            stopTyping()
            return
        }
        // «печатает» — не чаще раза в 3 секунды
        if typingSentAt.map({ Date().timeIntervalSince($0) > 3 }) ?? true {
            typingSentAt = Date()
            services.socket.sendTyping(chatId, typing: true)
        }
        typingStopTask?.cancel()
        typingStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.stopTyping()
        }
    }

    private func stopTyping() {
        typingStopTask?.cancel()
        guard typingSentAt != nil else { return }
        typingSentAt = nil
        services.socket.sendTyping(chatId, typing: false)
    }

    /// Черновик на всех своих устройствах: шифр ключом «Избранного», с задержкой 1,5 с.
    private func scheduleDraftSync() {
        draftSaveTask?.cancel()
        let value = text
        draftSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            let content = value.isEmpty ? "" : ((try? await self.services.messages.encryptForSelf(value)) ?? "")
            if !value.isEmpty && content.isEmpty { return }
            try? await self.services.api.putDraft(chat: self.chatId, content: content)
        }
    }

    private func syncDraftFromServer() async {
        guard text.isEmpty, let drafts = try? await services.api.drafts().drafts,
              let mine = drafts.first(where: { $0.chat == chatId }), let content = mine.content, !content.isEmpty,
              let plain = await services.messages.decryptForSelf(content), text.isEmpty else { return }
        suppressDraft = true
        updateText(plain)
        suppressDraft = false
        UserDefaults.standard.set(plain, forKey: draftKey)
    }
}

enum Plural {
    static func members(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "участник" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "участника" }
        return "участников"
    }
}
