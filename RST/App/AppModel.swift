import Foundation
import Observation
import SwiftUI

/// Адреса сервера: из Info.plist (RSTBaseURL, RSTWebSocketURL), боевой — rst-msg.ru.
enum AppConfig {
    static var baseURL: URL {
        let raw = Bundle.main.object(forInfoDictionaryKey: "RSTBaseURL") as? String ?? "https://rst-msg.ru"
        return URL(string: raw) ?? URL(string: "https://rst-msg.ru")!
    }

    static var wsBase: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "RSTWebSocketURL") as? String ?? "wss://rst-msg.ru"
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(v) (\(b))"
    }
}

/// Все сервисы приложения. Живут столько же, сколько процесс.
@MainActor
@Observable
final class Services {
    let session: SessionStore
    let api: RstApi
    let socket: RstWebSocket
    let keyCache: ChatKeyCache
    let userKeys: UserKeyRepository
    let groupKeys: GroupKeyRepository
    let messages: MessageRepository
    let attachments: AttachmentRepository
    let auth: AuthRepository
    let chats: ChatListStore
    let stickers: StickerStore
    let stories: StoryStore
    let calls: CallService

    init() {
        let session = SessionStore()
        let keyCache = ChatKeyCache()
        let api = RstApi(baseURL: AppConfig.baseURL, tokenProvider: { session.accessToken })
        let socket = RstWebSocket(wsBase: AppConfig.wsBase,
                                  tokenProvider: { session.accessToken },
                                  usernameProvider: { session.username })
        let userKeys = UserKeyRepository(api: api, session: session)
        let groupKeys = GroupKeyRepository(api: api, userKeys: userKeys)
        let messages = MessageRepository(api: api, session: session, socket: socket, userKeys: userKeys,
                                         groupKeys: groupKeys, keyCache: keyCache)
        self.session = session
        self.keyCache = keyCache
        self.api = api
        self.socket = socket
        self.userKeys = userKeys
        self.groupKeys = groupKeys
        self.messages = messages
        self.attachments = AttachmentRepository(api: api)
        self.auth = AuthRepository(api: api, session: session, userKeys: userKeys)
        self.chats = ChatListStore(api: api, session: session, socket: socket, messages: messages, userKeys: userKeys)
        self.stickers = StickerStore(api: api)
        let attachments = self.attachments
        self.stories = StoryStore(api: api, userKeys: userKeys, attachments: attachments, socket: socket,
                                  me: { session.username ?? "" })
        self.calls = CallService(api: api, socket: socket)
    }

    var me: String { session.username ?? "" }
}

/// Состояние приложения верхнего уровня: вход или переписка.
@MainActor
@Observable
final class AppModel {
    enum Phase { case launching, loggedOut, loggedIn }

    private(set) var phase: Phase = .launching
    /// Почему сеанс закончился — экран входа показывает этот текст.
    var sessionEndMessage: String?
    /// Чат, который нужно открыть (по ссылке, из уведомления).
    var pendingChat: String?
    /// Тема: тёмная по умолчанию, как в вебе.
    var colorScheme: ColorScheme? = .dark

    let services = Services()
    @ObservationIgnored private var sessionEnding = false

    init() {
        let services = self.services
        // Сеанс окончен, когда токена нет: при выходе и по 401 он стирается.
        // Смотреть на экран нельзя — во время входа он тоже «вне сеанса»,
        // а запрос своего ключа после /api/login уже идёт с токеном.
        services.api.isSessionOver = { [weak services] in services?.session.accessToken == nil }
        services.api.onUnauthorized = { [weak self] in
            Task { @MainActor in self?.endSession(.expired) }
        }
        services.socket.onSessionEnd = { [weak self] reason in
            self?.endSession(reason)
        }
        services.socket.subscribe { [weak self] event in
            self?.handleGlobal(event)
        }
        services.messages.onOutboxChanged = { [weak services] in services?.chats.outboxChanged() }
        switch UserDefaults.standard.string(forKey: "rst.theme") {
        case "light": colorScheme = .light
        case "system": colorScheme = nil
        default: colorScheme = .dark
        }
    }

    func start() {
        Task { await loadLimits() }
        if services.auth.canRestoreSession() {
            enterApp()
        } else {
            if services.session.current != nil { sessionEndMessage = SessionEnd.expired.message }
            services.session.clear()
            phase = .loggedOut
        }
    }

    private func loadLimits() async {
        if let limits = try? await services.api.limits(), let max = limits.maxUploadBytes {
            services.attachments.maxUploadBytes = max
        }
    }

    /// После входа или регистрации: сокет, список чатов.
    func enterApp() {
        addingAccount = false
        accountsVersion += 1
        sessionEnding = false
        sessionEndMessage = nil
        services.socket.resetSessionEnd()
        services.socket.connect()
        phase = .loggedIn
        Task {
            await services.auth.refreshTokenIfDue()
            await services.chats.refresh()
        }
    }

    func setTheme(_ value: String) {
        UserDefaults.standard.set(value, forKey: "rst.theme")
        switch value {
        case "light": colorScheme = .light
        case "system": colorScheme = nil
        default: colorScheme = .dark
        }
    }

    // MARK: - Жизненный цикл

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard self.phase == .loggedIn else { return }
        switch phase {
        case .active:
            services.socket.setActive(true)
            services.socket.connect()
            Task {
                await services.auth.refreshTokenIfDue()
                await services.chats.refresh()
            }
        case .background:
            services.socket.setActive(false)
        default:
            break
        }
    }

    // MARK: - Выход

    func logout() {
        clearLocalData()
        // Есть другие аккаунты — сразу в следующий
        if let next = services.session.saved.first {
            switchAccount(next.username)
            return
        }
        phase = .loggedOut
    }

    // MARK: - Несколько аккаунтов (js/accounts.js)

    /// Добавляем аккаунт: на экране входа можно вернуться к прежнему.
    var addingAccount = false
    var savedAccounts: [StoredSession] { _ = accountsVersion; return services.session.saved }
    private var accountsVersion = 0

    func addAccount() {
        clearCaches()
        services.session.parkCurrent()
        accountsVersion += 1
        addingAccount = true
        sessionEndMessage = nil
        phase = .loggedOut
    }

    func switchAccount(_ username: String) {
        clearCaches()
        guard services.session.activate(username) else { return }
        accountsVersion += 1
        addingAccount = false
        if services.auth.canRestoreSession() {
            enterApp()
        } else {
            // Срок токена истёк — этот аккаунт придётся войти заново
            services.session.clear()
            sessionEndMessage = "Сеанс @\(username) истёк — войдите снова"
            phase = .loggedOut
        }
    }

    func forgetAccount(_ username: String) {
        services.session.forgetSaved(username)
        accountsVersion += 1
    }

    /// Всё, что относится к одному аккаунту, кроме самого сеанса.
    private func clearCaches() {
        services.calls.hangup()
        services.socket.disconnect()
        services.keyCache.clear()
        services.userKeys.clear()
        services.attachments.clear()
        services.messages.clearOutbox()
        services.chats.clear()
        services.stickers.clear()
        services.stories.clear()
    }

    private func endSession(_ reason: SessionEnd) {
        guard phase == .loggedIn, !sessionEnding else { return }
        sessionEnding = true
        sessionEndMessage = reason.message
        clearLocalData()
        phase = .loggedOut
    }

    private func clearLocalData() {
        clearCaches()
        services.session.clear()
        accountsVersion += 1
    }

    private func handleGlobal(_ event: WsEvent) {
        switch event {
        case .userRenamed(let old, let new, let token):
            // Администратор переименовал учётную запись: у своей — новый токен
            guard old == services.session.username, !new.isEmpty else { return }
            services.session.update {
                $0.username = new
                if let token {
                    $0.accessToken = token
                    $0.tokenRefreshedAt = Date()
                }
            }
            services.userKeys.clear()
            services.keyCache.clear()
            services.socket.reconnect()
        case .connection(let connected, _):
            if connected { services.messages.flushOutbox() }
        case .groupAdded(let groupId):
            // Заявку одобрили (или добавили) — ключ из ссылки, если ждал
            Task { await services.groupKeys.applyPendingKey(chatId: groupId) }
        case .other(let action, let payload) where action == "join_request_done":
            guard let groupId = payload["group_id"]?.stringValue else { return }
            let name = payload["name"]?.stringValue ?? "группу"
            if payload["approved"]?.bool == true {
                Task {
                    await services.groupKeys.applyPendingKey(chatId: groupId)
                    await services.chats.refresh()
                }
                joinNotice = "Заявку в «\(name)» одобрили"
            } else {
                services.groupKeys.dropPendingKey(groupId)
                joinNotice = "Заявку в «\(name)» отклонили"
            }
        case .other(let action, let payload) where action == "join_request" || action == "join_request_resolved":
            // Админам: новая заявка или её рассмотрел другой админ
            guard let groupId = payload["group_id"]?.stringValue else { return }
            NotificationCenter.default.post(name: .rstJoinRequestsChanged, object: groupId)
            if action == "join_request" {
                let who = payload["username"]?.stringValue ?? ""
                joinNotice = "Заявка на вступление в «\(services.chats.title(for: groupId))» от @\(who)"
            }
        default:
            break
        }
    }

    // MARK: - Ссылки

    /// rstmsg://… и https://rst-msg.ru/… : приглашение в группу, профиль, чат.
    func open(url: URL) {
        let raw = url.absoluteString
        // Код входа нового устройства (#qr=…): подтвердить — только вошедшим
        if let qr = QrLogin.parse(raw) {
            if phase == .loggedIn { qrApproval = qr }
            return
        }
        if let invite = InviteLink.parse(raw) {
            Task { await previewInvite(invite) }
            return
        }
        // Ссылка на набор стикеров: /chat?stickers=имя
        if let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "stickers" })?.value, StickerStore.isValidName(name) {
            stickerLink = StickerSetRef(name: name)
            return
        }
        let path = url.path
        if path.hasPrefix("/@") {
            pendingChat = String(path.dropFirst(2))
        }
    }

    var joinError: String?
    /// Набор стикеров, открытый по ссылке.
    var stickerLink: StickerSetRef?
    /// Вход нового устройства по QR-коду ждёт подтверждения.
    var qrApproval: QrLogin.Link?
    /// Короткое сообщение о заявке (отправлена, одобрена, отклонена).
    var joinNotice: String?

    /// Окно «Вступить?» перед входом по ссылке (с 2026-10-12).
    struct JoinOffer: Identifiable {
        let invite: InviteLink
        let preview: JoinPreviewResponse
        var id: String { invite.inviteHash }
    }

    var joinOffer: JoinOffer?

    /// Сначала предпросмотр — он ничего не меняет; вступление — только по нажатию.
    private func previewInvite(_ invite: InviteLink) async {
        do {
            let preview = try await services.api.joinPreview(invite.inviteHash)
            let chatId = preview.groupId.map { $0.hasPrefix("group_") ? $0 : "group_" + $0 }
            if preview.isMember == true, let chatId {
                pendingChat = chatId
            } else if preview.requested == true {
                if let chatId, let key = invite.groupKeyB64 { services.groupKeys.savePendingKey(chatId, key) }
                joinNotice = "Заявка уже отправлена — её рассмотрят администраторы"
            } else {
                joinOffer = JoinOffer(invite: invite, preview: preview)
            }
        } catch let error as ApiError {
            switch error.code {
            case 404: joinError = "Ссылка недействительна или отозвана"
            case 410: joinError = "Срок ссылки истёк или её предел исчерпан"
            case 403: joinError = "Вы исключены из этой группы"
            default: joinError = error.localizedDescription
            }
        } catch {
            joinError = error.localizedDescription
        }
    }

    func confirmJoin(_ offer: JoinOffer) {
        joinOffer = nil
        Task {
            do {
                let result = try await services.groupKeys.join(invite: offer.invite)
                if result.requested {
                    joinNotice = "Заявка отправлена — её рассмотрят администраторы"
                } else {
                    await services.chats.refresh()
                    pendingChat = result.chatId
                }
            } catch {
                joinError = errorText(error)
            }
        }
    }
}
