import Foundation
import Observation

/// Почему сеанс закончился — экран входа показывает этот текст.
enum SessionEnd: Equatable {
    case expired
    case revoked
    case accountDeleted
    case passwordChanged

    var message: String {
        switch self {
        case .expired: return "Сеанс истёк. Войдите снова."
        case .revoked: return "Сеанс завершён с другого устройства или после смены пароля."
        case .accountDeleted: return "Аккаунт удалён."
        case .passwordChanged: return "Пароль изменил администратор. Войдите с новым паролем."
        }
    }
}

/// События сокета, разобранные из JSON.
enum WsEvent {
    case newMessage(MessageDto, receiver: String)
    case messageRead(id: Int64, receiver: String, reader: String?)
    case groupRead(group: String, reader: String, upTo: Int64)
    case messageEdited(id: Int64, content: String, receiver: String)
    case messageDeleted(id: Int64, receiver: String)
    case reactionUpdate(messageId: Int64, reactions: String, receiver: String)
    case pinChanged(id: Int64, pinned: Bool, receiver: String, pinnedBy: String?)
    case presence(username: String, online: Bool, lastSeen: String?)
    case typing(sender: String, receiver: String, typing: Bool)
    case profileUpdate(username: String, displayName: String?, avatarUrl: String?, bio: String?, status: String?)
    case chatCleared(target: String)
    case groupAdded(groupId: String)
    case groupRemoved(groupId: String, kicked: Bool)
    case groupRenamed(groupId: String, newName: String)
    case groupSettingsChanged(groupId: String)
    case groupKeyShared(groupId: String, by: String)
    case userRenamed(old: String, new: String, newToken: String?)
    case contactRenamed(old: String, new: String)
    case chatTimer(chat: String, seconds: Int, setBy: String?)
    case pollUpdate(messageId: Int64, receiver: String, poll: JSONValue, my: [Int]?)
    case messagePlayed(id: Int64, receiver: String)
    case chatRead(chat: String, unread: Int)
    case draft(chat: String, content: String, updatedAt: String)
    case blocked(until: String?)
    case serverError(String)
    /// Соединение открыто или потеряно. reconnected — открыто не впервые:
    /// пора догнать пропущенное через after_id.
    case connection(connected: Bool, reconnected: Bool)
    /// Всё прочее (звонки, истории, темы) — сырым объектом.
    case other(action: String, payload: JSONValue)
}

/// Состояние соединения для интерфейса (полоса «нет связи»).
@Observable
final class ConnectionState {
    var connected = false
}

/// Постоянное соединение wss://<домен>/ws/{username}/{device_id}.
///
/// Токен передаётся субпротоколом (Sec-WebSocket-Protocol: bearer, <jwt>),
/// а не в адресе: адрес попадает в логи прокси открытым текстом.
///
/// Отказ по токену выглядит как успешное подключение: сервер принимает
/// соединение, шлёт {"type":"session_terminated"} и закрывает с кодом 4003.
/// После отказа не переподключаемся.
@MainActor
final class RstWebSocket {
    let state = ConnectionState()
    var onSessionEnd: @MainActor (SessionEnd) -> Void = { _ in }

    private let wsBase: String
    private let tokenProvider: @MainActor () -> String?
    private let usernameProvider: @MainActor () -> String?
    private let delegate = SocketDelegate()
    private lazy var urlSession: URLSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

    private var task: URLSessionWebSocketTask?
    private struct Handler {
        weak var owner: AnyObject?
        let hasOwner: Bool
        let call: @MainActor (WsEvent) -> Void
    }
    private var handlers: [UUID: Handler] = [:]
    private var reconnectTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var attempt = 0
    private var everConnected = false
    private var stopped = true
    private var ended = false

    /// Смотрят ли на экран: «в сети» — только пока приложение на экране.
    private(set) var active = true

    init(wsBase: String, tokenProvider: @escaping @MainActor () -> String?, usernameProvider: @escaping @MainActor () -> String?) {
        self.wsBase = wsBase
        self.tokenProvider = tokenProvider
        self.usernameProvider = usernameProvider
        delegate.onOpen = { [weak self] task in
            Task { @MainActor in self?.opened(task) }
        }
        delegate.onClose = { [weak self] task, code in
            Task { @MainActor in self?.closed(task, code: code) }
        }
        delegate.onComplete = { [weak self] task in
            Task { @MainActor in self?.lost(task) }
        }
    }

    var isConnected: Bool { state.connected }

    // MARK: - Подписка

    /// owner — подписка снимается сама, когда владелец исчезает.
    @discardableResult
    func subscribe(owner: AnyObject? = nil, _ handler: @escaping @MainActor (WsEvent) -> Void) -> UUID {
        let id = UUID()
        handlers[id] = Handler(owner: owner, hasOwner: owner != nil, call: handler)
        return id
    }

    func unsubscribe(_ id: UUID?) {
        guard let id else { return }
        handlers[id] = nil
    }

    private func emit(_ event: WsEvent) {
        handlers = handlers.filter { !$0.value.hasOwner || $0.value.owner != nil }
        for handler in handlers.values { handler.call(event) }
    }

    // MARK: - Подключение

    func connect() {
        guard !ended else { return }
        stopped = false
        guard task == nil else { return }
        openSocket()
    }

    /// Разорвать и открыть заново — например, после смены токена.
    func reconnect() {
        disconnect()
        connect()
    }

    /// Новый вход: прежний отказ больше не действует.
    func resetSessionEnd() { ended = false }

    func disconnect() {
        stopped = true
        reconnectTask?.cancel()
        reconnectTask = nil
        pingTask?.cancel()
        pingTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        everConnected = false
        state.connected = false
    }

    /// Вышли на экран / ушли в фон — сказать серверу; повтор безвреден.
    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        _ = sendObject(["action": .string("presence"), "active": .bool(value)], requireOpen: false)
    }

    private func openSocket() {
        guard !ended, let token = tokenProvider(), let username = usernameProvider() else { return }
        let user = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
        var address = "\(wsBase)/ws/\(user)/\(DeviceId.value)"
        if !active { address += "?active=0" }
        guard let url = URL(string: address) else { return }
        let newTask = urlSession.webSocketTask(with: url, protocols: ["bearer", token])
        newTask.maximumMessageSize = 4 * 1024 * 1024
        task = newTask
        newTask.resume()
        receive(on: newTask)
    }

    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, socket === self.task else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text): self.handle(text)
                    case .data(let data): self.handle(String(decoding: data, as: UTF8.self))
                    @unknown default: break
                    }
                    self.receive(on: socket)
                case .failure:
                    self.lost(socket)
                }
            }
        }
    }

    private func opened(_ socket: URLSessionWebSocketTask) {
        guard socket === task else { return }
        attempt = 0
        let reconnected = everConnected
        everConnected = true
        state.connected = true
        emit(.connection(connected: true, reconnected: reconnected))
        startPing(socket)
    }

    private func closed(_ socket: URLSessionWebSocketTask, code: Int) {
        // 4001 — сеансы завершены (смена пароля, «завершить другие»), 4003 — токен не принят
        if code == 4001 { endSession(.revoked) }
        if code == 4003 { endSession(.expired) }
        lost(socket)
    }

    private func lost(_ socket: URLSessionWebSocketTask) {
        guard socket === task else { return }
        if socket.closeCode.rawValue == 4001 { endSession(.revoked) }
        if socket.closeCode.rawValue == 4003 { endSession(.expired) }
        task = nil
        pingTask?.cancel()
        if state.connected {
            state.connected = false
            emit(.connection(connected: false, reconnected: false))
        }
        scheduleReconnect()
    }

    private func endSession(_ reason: SessionEnd) {
        guard !ended else { return }
        ended = true
        stopped = true
        reconnectTask?.cancel()
        pingTask?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        state.connected = false
        onSessionEnd(reason)
    }

    /// Переподключение с нарастающей задержкой: 1, 2, 4 … до 30 секунд.
    private func scheduleReconnect() {
        guard !stopped, !ended, reconnectTask == nil else { return }
        let delay = min(30.0, pow(2.0, Double(min(attempt, 5))))
        attempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            if !self.stopped, self.task == nil { self.openSocket() }
        }
    }

    /// ping раз в 25 секунд — сервер отвечает pong и считает соединение живым.
    private func startPing(_ socket: URLSessionWebSocketTask) {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard let self, !Task.isCancelled, socket === self.task else { return }
                socket.send(.string(#"{"action":"ping"}"#)) { _ in }
            }
        }
    }

    // MARK: - Приём

    private func handle(_ text: String) {
        guard let obj = JSONValue.parse(text), obj.object != nil else { return }
        if handleSessionEnd(obj) { return }
        if let event = parse(obj) { emit(event) }
    }

    private func handleSessionEnd(_ obj: JSONValue) -> Bool {
        let reason: SessionEnd?
        switch obj["type"]?.string {
        case "session_terminated":
            reason = obj["reason"]?.string == "revoked" ? .revoked : .expired
        case "admin_user_deleted":
            reason = .accountDeleted
        case "admin_password_changed":
            reason = .passwordChanged
        default:
            reason = obj["action"]?.string == "force_logout" ? .revoked : nil
        }
        guard let found = reason else { return false }
        endSession(found)
        return true
    }

    private func parse(_ obj: JSONValue) -> WsEvent? {
        func str(_ k: String) -> String? { obj[k]?.string }
        func num(_ k: String) -> Int64? { obj[k]?.int64 }

        if let type = str("type") {
            switch type {
            case "admin_user_renamed":
                return .userRenamed(old: str("old_username") ?? "", new: str("new_username") ?? "", newToken: str("new_token"))
            case "contact_renamed":
                return .contactRenamed(old: str("old_username") ?? "", new: str("new_username") ?? "")
            case "admin_group_renamed":
                return .groupRenamed(groupId: str("group_id") ?? "", newName: str("new_name") ?? "")
            case "admin_group_deleted":
                return .groupRemoved(groupId: str("group_id") ?? "", kicked: false)
            default:
                return nil
            }
        }

        guard let action = str("action") else { return nil }
        switch action {
        case "new_msg":
            guard let dto = obj.decode(MessageDto.self) else { return nil }
            return .newMessage(dto, receiver: str("receiver") ?? "")
        case "msg_read":
            return num("id").map { .messageRead(id: $0, receiver: str("receiver") ?? "", reader: str("reader")) }
        case "group_read":
            return num("up_to").map { .groupRead(group: str("group") ?? "", reader: str("reader") ?? "", upTo: $0) }
        case "msg_edited":
            return num("id").map { .messageEdited(id: $0, content: str("content") ?? "", receiver: str("receiver") ?? "") }
        case "msg_deleted":
            return num("id").map { .messageDeleted(id: $0, receiver: str("receiver") ?? "") }
        case "reaction_update":
            let reactions: String
            if let s = obj["reactions"], case .string(let raw) = s { reactions = raw }
            else if let o = obj["reactions"], o.object != nil { reactions = JSONCoding.encodeString(o) }
            else { reactions = "{}" }
            return num("message_id").map { .reactionUpdate(messageId: $0, reactions: reactions, receiver: str("receiver") ?? "") }
        case "msg_pinned", "msg_unpinned":
            return num("id").map { .pinChanged(id: $0, pinned: action == "msg_pinned", receiver: str("receiver") ?? "", pinnedBy: str("pinned_by")) }
        case "presence":
            return .presence(username: str("username") ?? "", online: obj["online"]?.bool ?? false, lastSeen: str("last_seen"))
        case "typing", "stop_typing":
            return .typing(sender: str("sender") ?? "", receiver: str("receiver") ?? "", typing: action == "typing")
        case "profile_update":
            return .profileUpdate(username: str("username") ?? "", displayName: str("display_name"),
                                  avatarUrl: str("avatar_url"), bio: str("bio"), status: str("status"))
        case "chat_cleared":
            return .chatCleared(target: str("target") ?? "")
        case "group_added":
            return .groupAdded(groupId: str("group_id") ?? "")
        case "group_deleted":
            return .groupRemoved(groupId: str("group_id") ?? "", kicked: false)
        case "group_kicked":
            return .groupRemoved(groupId: str("group_id") ?? "", kicked: true)
        case "group_settings":
            return .groupSettingsChanged(groupId: str("group_id") ?? "")
        case "group_key_shared":
            return .groupKeyShared(groupId: str("group_id") ?? "", by: str("by") ?? "")
        case "chat_timer":
            return .chatTimer(chat: str("chat") ?? "", seconds: obj["seconds"]?.int ?? 0, setBy: str("set_by"))
        case "poll_update":
            guard let id = num("message_id"), let poll = obj["poll"] else { return nil }
            let my = obj["my"]?.array?.compactMap { $0.int }
            return .pollUpdate(messageId: id, receiver: str("receiver") ?? "", poll: poll, my: my)
        case "msg_played":
            return num("id").map { .messagePlayed(id: $0, receiver: str("receiver") ?? "") }
        case "chat_read":
            return str("chat").map { .chatRead(chat: $0, unread: obj["unread"]?.int ?? 0) }
        case "draft":
            return str("chat").map { .draft(chat: $0, content: str("content") ?? "", updatedAt: str("updated_at") ?? "") }
        case "blocked":
            return .blocked(until: str("blocked_until"))
        case "error":
            return .serverError(str("message") ?? "")
        case "pong":
            return nil
        default:
            return .other(action: action, payload: obj)
        }
    }

    // MARK: - Отправка

    /// false — сокет не на связи, кадр не ушёл.
    @discardableResult
    func sendObject(_ object: [String: JSONValue], requireOpen: Bool = true) -> Bool {
        guard let task, !requireOpen || state.connected else { return false }
        let text = JSONCoding.encodeString(JSONValue.object(object))
        task.send(.string(text)) { _ in }
        return true
    }

    func sendMessage(receiver: String, content: String, fileUrl: String? = nil, fileType: String? = nil,
                     replyTo: Int64? = nil, forwardedFrom: String? = nil, silent: Bool = false,
                     poll: [String: JSONValue]? = nil, sendAt: String? = nil) -> Bool {
        var obj: [String: JSONValue] = [
            "action": .string(sendAt != nil ? "schedule" : "send"),
            "receiver": .string(receiver),
            "content": .string(content),
            "file_url": fileUrl.map { .string($0) } ?? .null,
            "file_type": fileType.map { .string($0) } ?? .null,
            "reply_to": replyTo.map { .number(Double($0)) } ?? .null,
            "forwarded_from": forwardedFrom.map { .string($0) } ?? .null,
        ]
        if silent { obj["silent"] = .bool(true) }
        if let poll { obj["poll"] = .object(poll) }
        if let sendAt { obj["send_at"] = .string(sendAt) }
        return sendObject(obj)
    }

    func sendTyping(_ receiver: String, typing: Bool) {
        sendObject(["action": .string(typing ? "typing" : "stop_typing"), "receiver": .string(receiver)])
    }

    func sendRead(messageId: Int64, sender: String) {
        sendObject(["action": .string("read"), "message_id": .number(Double(messageId)), "sender": .string(sender)])
    }

    func sendReaction(messageId: Int64, emoji: String) -> Bool {
        sendObject(["action": .string("reaction"), "message_id": .number(Double(messageId)), "emoji": .string(emoji)])
    }

    func sendEdit(messageId: Int64, content: String, receiver: String) -> Bool {
        sendObject(["action": .string("edit_msg"), "message_id": .number(Double(messageId)),
                    "content": .string(content), "receiver": .string(receiver)])
    }

    /// mode: both — у всех (только своё сообщение), me — только у себя.
    func sendDelete(messageId: Int64, mode: String) -> Bool {
        sendObject(["action": .string("delete_msg"), "message_id": .number(Double(messageId)), "mode": .string(mode)])
    }

    func sendPin(messageId: Int64, pinned: Bool) -> Bool {
        sendObject(["action": .string(pinned ? "pin_msg" : "unpin_msg"), "message_id": .number(Double(messageId))])
    }

    func sendPlayed(messageId: Int64) {
        sendObject(["action": .string("played"), "message_id": .number(Double(messageId))])
    }

    func sendSetTimer(chat: String, seconds: Int) -> Bool {
        sendObject(["action": .string("set_timer"), "chat": .string(chat), "seconds": .number(Double(seconds))])
    }

    func sendPollVote(messageId: Int64, options: [Int]) -> Bool {
        sendObject(["action": .string("poll_vote"), "message_id": .number(Double(messageId)),
                    "options": .array(options.map { .number(Double($0)) })])
    }

    func sendPollClose(messageId: Int64) -> Bool {
        sendObject(["action": .string("poll_close"), "message_id": .number(Double(messageId))])
    }
}

/// Делегат URLSession: колбэки приходят с фоновой очереди и пересылаются
/// на главный поток самим сокетом.
private final class SocketDelegate: NSObject, URLSessionWebSocketDelegate {
    var onOpen: (URLSessionWebSocketTask) -> Void = { _ in }
    var onClose: (URLSessionWebSocketTask, Int) -> Void = { _, _ in }
    var onComplete: (URLSessionWebSocketTask) -> Void = { _ in }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onOpen(webSocketTask)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onClose(webSocketTask, closeCode.rawValue)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let ws = task as? URLSessionWebSocketTask { onComplete(ws) }
    }
}
