import Foundation
import Observation

/// Список чатов: загрузка из /api/contacts и живые правки по событиям сокета.
@MainActor
@Observable
final class ChatListStore {
    private(set) var chats: [ChatSummary] = []
    /// Расшифрованное превью последнего сообщения по чатам.
    private(set) var previews: [String: String] = [:]
    /// Кто печатает: чат -> имена.
    private(set) var typing: [String: Set<String>] = [:]
    private(set) var folders: [FolderDto] = []
    /// Своя запись из списка контактов — настройки профиля и приватности.
    private(set) var myProfile: ContactUserDto?
    private(set) var users: [String: ContactUserDto] = [:]
    private(set) var loading = false
    private(set) var loadError: String?
    /// Аккаунт заблокирован модератором до этого времени.
    var blockedUntil: String?
    /// Ограничение модератора ещё действует («навсегда» — без даты).
    var isBlockedNow: Bool {
        guard let blockedUntil else { return false }
        guard let date = ServerTime.parse(blockedUntil) else { return true }
        return date > Date()
    }
    var lastServerError: String?
    /// Открытый на экране чат: ему не прибавляем непрочитанное.
    var activeChatId: String?
    /// «Ответить в другом чате»: цитата, которую понесёт первое сообщение в этот чат.
    var crossReplyDraft: [String: CrossReply] = [:]
    private(set) var outboxVersion = 0

    private let api: RstApi
    private let session: SessionStore
    private let socket: RstWebSocket
    private let messages: MessageRepository
    private let userKeys: UserKeyRepository
    @ObservationIgnored private var typingTimers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(api: RstApi, session: SessionStore, socket: RstWebSocket, messages: MessageRepository, userKeys: UserKeyRepository) {
        self.api = api
        self.session = session
        self.socket = socket
        self.messages = messages
        self.userKeys = userKeys
        socket.subscribe { [weak self] event in self?.handle(event) }
    }

    var me: String { session.username ?? "" }

    /// Без архива: служебный чат первым, затем закреплённые, затем по свежести.
    var mainList: [ChatSummary] { sorted(chats.filter { !$0.archived }) }
    var archivedList: [ChatSummary] { sorted(chats.filter { $0.archived }) }

    var totalUnread: Int {
        chats.filter { !$0.muted && !$0.archived }.reduce(0) { $0 + ($1.unread > 0 ? $1.unread : ($1.markedUnread ? 1 : 0)) }
    }

    private func sorted(_ list: [ChatSummary]) -> [ChatSummary] {
        list.sorted { a, b in
            if a.isSystem != b.isSystem { return a.isSystem }
            if a.pinned != b.pinned { return a.pinned }
            return a.activity > b.activity
        }
    }

    func chat(_ chatId: String) -> ChatSummary? { chats.first { $0.chatId == chatId } }

    func title(for chatId: String) -> String {
        if chatId == me { return "Избранное" }
        return chat(chatId)?.title ?? users[chatId]?.displayName ?? chatId
    }

    /// Имя человека для подписи в группе: заданное имя контакта или ник.
    func displayName(_ username: String) -> String {
        if username == me { return "Вы" }
        return users[username]?.displayName ?? username
    }

    func clear() {
        refreshTask?.cancel()
        chats = []
        previews = [:]
        typing = [:]
        folders = []
        myProfile = nil
        users = [:]
        activeChatId = nil
        blockedUntil = nil
    }

    // MARK: - Загрузка

    func refresh() async {
        guard !me.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            let response = try await api.contacts(me)
            let userList = response.users ?? []
            var summaries = userList.map { ChatSummary(user: $0) }
            summaries += (response.groups ?? []).map { ChatSummary(group: $0) }
            var byName: [String: ContactUserDto] = [:]
            for u in userList { byName[u.username] = u }
            users = byName
            myProfile = byName[me]
            blockedUntil = myProfile?.blockedUntil
            if let index = summaries.firstIndex(where: { $0.chatId == me }) {
                summaries[index].title = "Избранное"
            }
            // Открытый чат прочитан — сервер мог ещё не успеть это учесть
            if let active = activeChatId, let index = summaries.firstIndex(where: { $0.chatId == active }) {
                summaries[index].unread = 0
            }
            chats = summaries
            loadError = nil
            await decryptPreviews(summaries)
        } catch {
            if chats.isEmpty { loadError = error.localizedDescription }
        }
        if let folderList = try? await api.folders(me).folders { folders = folderList }
    }

    /// Перечитать список, но не чаще раза в полсекунды подряд.
    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func decryptPreviews(_ list: [ChatSummary]) async {
        for chat in list {
            guard let last = chat.lastMsg else { continue }
            let text = await messages.previewText(chatId: chat.chatId, content: last.content, fileType: last.fileType)
            previews[chat.chatId] = text
        }
    }

    // MARK: - Настройки чата

    func setPrefs(_ request: ChatPrefsRequest) async throws {
        let result = try await api.chatPrefs(request)
        update(request.chatId) {
            $0.muted = result.muted ?? $0.muted
            $0.pinned = result.pinned ?? $0.pinned
            $0.archived = result.archived ?? $0.archived
            $0.markedUnread = result.markedUnread ?? $0.markedUnread
        }
    }

    func update(_ chatId: String, _ change: (inout ChatSummary) -> Void) {
        guard let index = chats.firstIndex(where: { $0.chatId == chatId }) else { return }
        change(&chats[index])
    }

    func markOpened(_ chatId: String) {
        activeChatId = chatId
        guard let chat = chat(chatId) else { return }
        update(chatId) { $0.unread = 0 }
        if chat.markedUnread {
            Task { try? await setPrefs(ChatPrefsRequest(chatId: chatId, markedUnread: false)) }
        }
    }

    func markClosed(_ chatId: String) {
        if activeChatId == chatId { activeChatId = nil }
    }

    func outboxChanged() { outboxVersion += 1 }

    func remove(_ chatId: String) {
        chats.removeAll { $0.chatId == chatId }
        previews[chatId] = nil
    }

    // MARK: - События сокета

    private func handle(_ event: WsEvent) {
        switch event {
        case .newMessage(let dto, let receiver):
            // Комментарии к постам канала в ленту и непрочитанные не входят
            guard dto.commentTo == nil else { return }
            let chatId = messages.chatId(sender: dto.sender, receiver: receiver)
            guard let index = chats.firstIndex(where: { $0.chatId == chatId }) else {
                scheduleRefresh()
                return
            }
            let last = LastMessageDto(id: dto.id, sender: dto.sender, content: dto.content, fileType: dto.fileType,
                                      time: dto.createdAt, status: dto.status)
            chats[index].lastMsg = last
            if dto.sender != me && activeChatId != chatId {
                chats[index].unread += 1
            }
            if dto.sender == me { chats[index].unread = 0 }
            clearTyping(chatId, dto.sender)
            Task {
                let text = await messages.previewText(chatId: chatId, content: dto.content, fileType: dto.fileType)
                previews[chatId] = text
            }
        case .messageRead(let id, let upTo, let receiver, _):
            // Прочитали моё последнее — галочки в строке (up_to: всё своё до него)
            let limit = max(id, upTo)
            for index in chats.indices where chats[index].lastMsg?.id == id || chats[index].chatId == receiver {
                if let last = chats[index].lastMsg, last.sender == me, (last.id ?? 0) <= limit {
                    chats[index].lastMsg = LastMessageDto(id: last.id, sender: last.sender, content: last.content,
                                                          fileType: last.fileType, time: last.time, status: "read")
                }
            }
        case .groupRead(let group, _, let upTo):
            update(group) {
                if let last = $0.lastMsg, last.sender == me, (last.id ?? 0) <= upTo {
                    $0.lastMsg = LastMessageDto(id: last.id, sender: last.sender, content: last.content,
                                                fileType: last.fileType, time: last.time, status: "read")
                }
            }
        case .chatRead(let chat, let unread):
            update(chat) { $0.unread = unread }
        case .messageDeleted:
            // Превью и счётчик могли измениться — перечитать список (серия
            // удалений схлопывается в один запрос)
            scheduleRefresh()
        case .messageEdited(let id, let content, let receiver):
            let target = receiver.hasPrefix("group_") ? receiver : chats.first(where: { $0.lastMsg?.id == id })?.chatId
            guard let chatId = target, let chat = chat(chatId), chat.lastMsg?.id == id, let last = chat.lastMsg else { return }
            update(chatId) {
                $0.lastMsg = LastMessageDto(id: last.id, sender: last.sender, content: content, fileType: last.fileType,
                                            time: last.time, status: last.status)
            }
            Task {
                let text = await messages.previewText(chatId: chatId, content: content, fileType: last.fileType)
                previews[chatId] = text
            }
        case .presence(let username, let online, let lastSeen):
            update(username) {
                $0.online = online
                if let lastSeen { $0.lastSeen = lastSeen }
            }
        case .typing(let sender, let receiver, let isTyping):
            guard sender != me else { return }
            let chatId = receiver.hasPrefix("group_") ? receiver : sender
            if isTyping { setTyping(chatId, sender) } else { clearTyping(chatId, sender) }
        case .profileUpdate(let username, let displayName, let avatarUrl, _, let status):
            update(username) {
                if let avatarUrl { $0.avatarUrl = avatarUrl.isEmpty ? nil : avatarUrl }
                if let status { $0.status = status }
            }
            // Заданное вручную имя контакта знает только сервер — перечитаем
            if displayName != nil { scheduleRefresh() }
        case .chatCleared(let target):
            update(target) { $0.lastMsg = nil }
            previews[target] = nil
            scheduleRefresh()
        case .other(let action, let payload):
            handleOther(action, payload)
        case .groupAdded, .groupRemoved, .groupRenamed, .groupSettingsChanged, .contactRenamed, .chatTimer:
            scheduleRefresh()
        case .blocked(let until):
            blockedUntil = until ?? "навсегда"
        case .serverError(let text):
            lastServerError = text
        case .connection(let connected, let reconnected):
            if connected && reconnected { scheduleRefresh() }
        default:
            break
        }
    }

    private func handleOther(_ action: String, _ payload: JSONValue) {
        switch action {
        case "reactions_unread_changed":
            // Кто-то поставил или снял реакцию на моё — «❤» в строке
            if payload["chat"]?.stringValue != activeChatId { scheduleRefresh() }
        case "emoji_status":
            guard let username = payload["username"]?.stringValue else { return }
            let emoji = payload["emoji_status"]?.stringValue ?? ""
            let until = ServerTime.parse(payload["emoji_status_until"]?.stringValue)
            update(username) {
                $0.emojiStatus = emoji.isEmpty ? nil : emoji
                $0.emojiStatusUntil = until
            }
            emojiStatuses[username] = emoji.isEmpty ? nil : EmojiStatus(emoji: emoji, until: until)
        case "join_request_done", "view_once_opened", "group_forum":
            scheduleRefresh()
        default:
            break
        }
    }

    struct EmojiStatus: Equatable {
        let emoji: String
        let until: Date?
    }

    /// Эмодзи-статусы людей вне списка чатов (участники групп), по событиям.
    private(set) var emojiStatuses: [String: EmojiStatus] = [:]

    /// Эмодзи-статус человека для показа после имени, если не истёк.
    func emojiStatus(of username: String) -> String? {
        if let s = chat(username)?.activeEmojiStatus { return s }
        if let s = emojiStatuses[username], s.until.map({ $0 > Date() }) ?? true { return s.emoji }
        if let u = users[username], let e = u.emojiStatus, !e.isEmpty {
            if let until = ServerTime.parse(u.emojiStatusUntil), until <= Date() { return nil }
            return e
        }
        return nil
    }

    private func setTyping(_ chatId: String, _ user: String) {
        typing[chatId, default: []].insert(user)
        let key = chatId + "|" + user
        typingTimers[key]?.cancel()
        // «печатает» гаснет само, если stop_typing потерялся
        typingTimers[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.clearTyping(chatId, user)
        }
    }

    private func clearTyping(_ chatId: String, _ user: String) {
        typing[chatId]?.remove(user)
        if typing[chatId]?.isEmpty == true { typing[chatId] = nil }
        typingTimers[chatId + "|" + user]?.cancel()
    }

    func typingText(_ chatId: String, isGroup: Bool) -> String? {
        guard let names = typing[chatId], !names.isEmpty else { return nil }
        if !isGroup { return "печатает…" }
        let shown = names.sorted().prefix(2).map { displayName($0) }.joined(separator: ", ")
        return names.count > 2 ? "\(shown) и ещё \(names.count - 2) печатают…" : "\(shown) печатает…"
    }
}
