import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class ChatViewModel {
    let chatId: String
    let isGroup: Bool
    /// Открытая тема форума: лента и отправка — только её.
    let topic: ForumTopic?

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
    /// Режим выделения: выбранные сообщения.
    var selected: Set<Int64> = []
    var selecting = false
    /// Упоминания меня, ещё не попавшиеся на глаза (кнопка «@»), по возрастанию.
    var mentionQueue: [Int64] = []
    /// Мои сообщения с новыми реакциями (кнопка «❤»), по порядку.
    var reactionQueue: [Int64] = []
    /// Сколько было непрочитанных при открытии — среди них ищем упоминания.
    @ObservationIgnored var unreadAtOpen = 0
    /// Прокрутить к сообщению (ответ, закреп).
    var scrollTarget: Int64?
    var highlighted: Int64?

    @ObservationIgnored let services: Services
    @ObservationIgnored private var subscription: UUID?
    @ObservationIgnored private var oldestId: Int64?
    @ObservationIgnored private var lastGroupRead: Int64 = 0
    @ObservationIgnored private var typingSentAt: Date?
    @ObservationIgnored private var typingStopTask: Task<Void, Never>?
    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?
    @ObservationIgnored var visible = false
    @ObservationIgnored private var suppressDraft = false

    init(chatId: String, services: Services, topic: ForumTopic? = nil) {
        self.chatId = chatId
        self.topic = topic
        self.isGroup = MessageRepository.isGroup(chatId)
        self.services = services
        subscription = services.socket.subscribe(owner: self) { [weak self] event in self?.handle(event) }
        unreadAtOpen = services.chats.chat(chatId)?.unread ?? 0
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
    var title: String { topic.map { ($0.icon.isEmpty ? "" : $0.icon + " ") + $0.title } ?? services.chats.title(for: chatId) }
    var myRole: String { summary?.myRole ?? groupInfo?.members?.first { $0.username == me }?.role ?? "member" }
    var canModerate: Bool { ["owner", "admin", "editor", "helper"].contains(myRole) }
    var isChannel: Bool { summary?.isChannel ?? groupInfo?.isChannel ?? false }

    var canWrite: Bool {
        if services.chats.isBlockedNow { return false }
        // В закрытую тему пишут только владелец и админы
        if topic?.closed == true && !["owner", "admin"].contains(myRole) { return false }
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
        if topic != nil { return services.chats.title(for: chatId) + (topic?.closed == true ? " · тема закрыта" : "") }
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
            let history = try await services.messages.history(chatId, topicId: topic?.id)
            messages = history.messages
            hasMore = history.hasMore
            oldestId = history.oldestId ?? history.messages.first?.id
            loadError = nil
            if let keys = services.keyCache.get(chatId) { keyState = keys.groupState }
            keyChanged = !isGroup && services.userKeys.keyChanged.contains(chatId)
            // Упоминания среди непрочитанных на момент открытия
            let incoming = messages.filter { !$0.isMine && !$0.isSystem }.suffix(unreadAtOpen)
            mentionQueue = incoming.filter(\.mentionsMe).map(\.id)
            Task { await loadReactionQueue() }
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
            let page = try await services.messages.history(chatId, beforeId: before, topicId: topic?.id)
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

    /// Подписи участников («Модератор») — рядом с именем в ленте группы.
    private(set) var memberTitles: [String: String] = [:]

    func loadGroupInfo() async {
        guard let info = try? await services.api.groupInfo(chatId) else { return }
        groupInfo = info
        var titles: [String: String] = [:]
        for m in info.members ?? [] {
            if let t = m.title, !t.isEmpty { titles[m.username] = t }
        }
        memberTitles = titles
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
        guard let fresh = try? await services.messages.since(chatId, afterId: last, topicId: topic?.id) else { return }
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
            // С 2026-10-07 read с номером N отмечает всё чужое до N — хватает
            // одного кадра для последнего непрочитанного
            guard let last = messages.last(where: { !$0.isMine && !$0.isRead && !$0.isSystem && $0.id > 0 }) else {
                services.chats.update(chatId) { $0.unread = 0 }
                return
            }
            services.socket.sendRead(messageId: last.id, sender: last.sender)
            for i in messages.indices where !messages[i].isMine && messages[i].id <= last.id {
                messages[i].status = "read"
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
            guard services.messages.chatId(sender: dto.sender, receiver: receiver) == chatId else { return }
            if let post = dto.commentTo {
                // Комментарий к посту канала: счётчик под постом
                if let i = messages.firstIndex(where: { $0.id == post }) { messages[i].commentCount += 1 }
                return
            }
            // Тема форума: в ленте только её сообщения (0 — «Общее»)
            if let topic, (dto.topicId ?? 0) != topic.id { return }
            Task {
                let message = await services.messages.decryptSingle(dto, chatId: chatId)
                merge([message])
                if message.mentionsMe && !mentionQueue.contains(message.id) { mentionQueue.append(message.id) }
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
                case .text(let t):
                    updated.text = t
                    updated.quote = nil
                    updated.envelope = nil
                case .enveloped(let e):
                    updated.text = e.text
                    updated.quote = e.quote
                    updated.envelope = e
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
        case .reactionUpdate(let id, let reactions, _) where messages.first(where: { $0.id == id })?.isMine == true:
            // Реакция на моё — список «❤» перечитать
            if let i = messages.firstIndex(where: { $0.id == id }) {
                messages[i].reactions = MessageRepository.parseReactions(reactions)
            }
            Task { await loadReactionQueue() }
        case .reactionUpdate(let id, let reactions, _):
            if let i = messages.firstIndex(where: { $0.id == id }) {
                messages[i].reactions = MessageRepository.parseReactions(reactions)
            }
        case .messageRead(let id, let upTo, let receiver, _):
            guard !isGroup, belongs(receiver) else { return }
            let limit = max(id, upTo)
            for i in messages.indices where messages[i].isMine && messages[i].id <= limit && messages[i].id > 0 {
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
            guard let i = messages.firstIndex(where: { $0.id == id }), let current = messages[i].poll else { return }
            let base = messages[i].envelope?.poll?.options ?? current.options
            Task {
                var updated = await services.messages.refreshPoll(current, rawState: poll, chatId: chatId, base: base)
                // my приходит только моим устройствам; у остальных свой выбор не трогаем
                updated.state.my = my ?? current.state.my
                if let j = messages.firstIndex(where: { $0.id == id }) { messages[j].poll = updated }
            }
        case .other(let action, let payload):
            handleOther(action, payload)
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

    private func handleOther(_ action: String, _ payload: JSONValue) {
        switch action {
        case "member_title":
            guard payload["group_id"]?.stringValue == chatId, let username = payload["username"]?.stringValue else { return }
            let title = payload["title"]?.stringValue ?? ""
            memberTitles[username] = title.isEmpty ? nil : title
        case "view_once_opened":
            // Одноразовое открыли — у обоих файла больше нет
            guard let id = payload["id"]?.int64, let i = messages.firstIndex(where: { $0.id == id }) else { return }
            messages[i].attachment = nil
        default:
            break
        }
    }

    /// Группа запретила пересылку и сохранение: меню без них, экран защищён.
    var isProtected: Bool { summary?.isProtected ?? groupInfo?.isProtected ?? false }

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
                    try await services.messages.edit(chatId, message: editTarget, newText: body)
                } else {
                    // Первое сообщение после «Ответить в другом чате» несёт цитату x
                    let cross = services.chats.crossReplyDraft[chatId]
                    try await services.messages.sendText(chatId, text: body, replyTo: cross == nil ? reply?.id : nil,
                                                         crossReply: cross)
                    services.chats.crossReplyDraft[chatId] = nil
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

    /// Файл, выбранный к отправке.
    struct OutgoingFile {
        var data: Data
        var fileName: String
        var mimeType: String
        /// Пережать фото (выбранное как документ — не трогаем).
        var compress = true

        var isVisual: Bool { mimeType.hasPrefix("image/") || mimeType.hasPrefix("video/") }

        /// Фото перед отправкой — JPEG до 2560 по длинной стороне, как в вебе.
        func prepared() -> OutgoingFile {
            guard compress, ChatAppearance.shared.compressPhotos, mimeType.hasPrefix("image/"), mimeType != "image/gif",
                  let jpeg = AttachmentRepository.compressImage(data) else { return self }
            let stem = (fileName as NSString).deletingPathExtension
            return OutgoingFile(data: jpeg, fileName: (stem.isEmpty ? "photo" : stem) + ".jpg", mimeType: "image/jpeg", compress: false)
        }
    }

    func sendAttachment(data: Data, fileName: String, mimeType: String, caption: String = "", compress: Bool = true,
                        spoiler: Bool = false, viewOnce: Bool = false) async {
        await sendFiles([OutgoingFile(data: data, fileName: fileName, mimeType: mimeType, compress: compress)],
                        caption: caption, spoiler: spoiler, viewOnce: viewOnce)
    }

    /// Отправка вложений, как в вебе (альбомы, 2026-10-07): несколько выбранных
    /// разом уходят альбомом — у каждого своё сообщение, общее поле a в
    /// конверте. Фото и видео — альбомами по 10, остальные файлы — отдельными
    /// альбомами по 10. Сначала шифруются и загружаются все файлы пачки, затем
    /// сообщения уходят подряд. Подпись — у первого фото/видео; у одних
    /// документов — отдельным текстом следом. Ответ — только у первого.
    func sendFiles(_ files: [OutgoingFile], caption: String = "", spoiler: Bool = false, viewOnce: Bool = false) async {
        guard !files.isEmpty else { return }
        sending = true
        defer { sending = false }
        do {
            // Ключ ждём до загрузки: иначе файлы ушли бы зря
            let keys = try await services.messages.keys(for: chatId)
            if keys.isKeyPending { throw GroupKeyPendingError() }
            let prepared = files.map { $0.prepared() }
            let visual = prepared.filter(\.isVisual)
            let documents = prepared.filter { !$0.isVisual }
            var batches: [[OutgoingFile]] = []
            for group in [visual, documents] where !group.isEmpty {
                stride(from: 0, to: group.count, by: 10).forEach { batches.append(Array(group[$0..<min($0 + 10, group.count)])) }
            }
            var reply = replyTo?.id
            var captionLeft = caption
            for batch in batches {
                var uploaded: [(OutgoingFile, AttachmentRepository.Uploaded)] = []
                for file in batch {
                    uploaded.append((file, try await services.attachments.upload(file.data)))
                }
                let album: String? = batch.count > 1 ? RstCrypto.randomBytes(8).hexString : nil
                for (index, item) in uploaded.enumerated() {
                    // Подпись — полем t первого фото/видео альбома
                    let text = index == 0 && item.0.isVisual ? captionLeft : ""
                    if !text.isEmpty { captionLeft = "" }
                    try await services.messages.sendAttachment(
                        chatId, text: text, fileUrl: item.1.fileUrl, fileKeyB64: item.1.keyB64,
                        fileName: item.0.fileName, mimeType: item.0.mimeType, replyTo: reply,
                        album: album, spoiler: spoiler && batch.count == 1, viewOnce: viewOnce && files.count == 1 && !isGroup)
                    reply = nil
                }
            }
            // Одни документы: подпись — отдельным сообщением следом
            if !captionLeft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await services.messages.sendText(chatId, text: captionLeft)
            }
            replyTo = nil
        } catch {
            toast = errorText(error)
        }
    }

    /// Одноразовое: скачать и расшифровать в память (без кэша) и сказать серверу.
    func openViewOnce(_ m: ChatMessage) async -> Data? {
        guard let a = m.attachment, !m.isMine else { return nil }
        do {
            let payload = try await services.api.download(a.fileUrl)
            let plain = try FileCrypto.decrypt(payload, keyB64: a.fileKeyB64)
            try? await services.messages.consumeViewOnce(m.id)
            if let i = messages.firstIndex(where: { $0.id == m.id }) { messages[i].attachment = nil }
            return plain
        } catch {
            toast = errorText(error)
            return nil
        }
    }

    func toggleCheck(_ m: ChatMessage, option: Int) {
        do { try services.messages.toggleCheck(messageId: m.id, option: option) } catch { toast = errorText(error) }
    }

    func addPollOption(_ m: ChatMessage, text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        Task {
            do { try await services.messages.addPollOption(chatId, messageId: m.id, text: value) } catch { toast = errorText(error) }
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

    /// Кружок: обычное видео-вложение с подписью «📹 Видеосообщение», как в вебе.
    func sendVideoNote(url: URL, duration: TimeInterval) async {
        defer { try? FileManager.default.removeItem(at: url) }
        guard duration >= 1, let data = try? Data(contentsOf: url) else {
            toast = duration < 1 ? "Слишком короткий кружок" : "Не удалось прочитать запись"
            return
        }
        await sendAttachment(data: data, fileName: "video_msg.mp4", mimeType: "video/mp4", caption: Previews.videoNote, compress: false)
    }

    /// Голосовое или кружок, которое заиграет само (дослушали предыдущее).
    var autoplayId: Int64?

    /// Дослушали — следующее голосовое или кружок ниже в ленте играет само.
    func playNext(after message: ChatMessage) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let next = messages[(index + 1)...].first { m in
            guard let a = m.attachment, !m.undecryptable else { return false }
            return (a.isAudio && m.text == Previews.voiceText) || (a.isVideo && m.text == Previews.videoNote)
        }
        autoplayId = next?.id
    }

    func sendPoll(_ spec: MessageRepository.PollSpec) async -> Bool {
        do {
            try await services.messages.sendPoll(chatId, spec: spec)
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
