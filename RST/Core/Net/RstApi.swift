import Foundation

/// Ошибка REST-запроса. Сервер отвечает кодом HTTP и телом {"detail": "текст"};
/// при 429 приходит заголовок Retry-After.
enum ApiError: LocalizedError {
    case http(code: Int, detail: String, retryAfter: Int?)
    case network(String)
    case badResponse
    case sessionOver

    var errorDescription: String? {
        switch self {
        case .http(let code, let detail, let retryAfter):
            if code == 429, let retryAfter {
                return "\(detail) Попробуйте через \(retryAfter) с."
            }
            return detail
        case .network(let text): return text
        case .badResponse: return "Некорректный ответ сервера"
        case .sessionOver: return "Сеанс завершён. Войдите снова"
        }
    }

    var code: Int? {
        if case .http(let code, _, _) = self { return code }
        return nil
    }

    var isNetwork: Bool {
        if case .network = self { return true }
        return false
    }
}

/// REST-клиент RST. Все запросы, кроме register/login/limits/recovery, идут с
/// заголовком Authorization: Bearer <access_token>.
///
/// 401 значит одно: токен недействителен. После первого такого ответа сеанс
/// признаётся законченным, и дальше запросы с авторизацией не уходят вовсе.
@MainActor
final class RstApi {
    let baseURL: URL
    private let session: URLSession
    private let tokenProvider: @MainActor () -> String?
    /// Вызывается при 401 на запросе с токеном.
    var onUnauthorized: @MainActor () -> Void = {}
    var isSessionOver: @MainActor () -> Bool = { false }

    static let defaultMaxUploadBytes: Int64 = 25 * 1024 * 1024
    /// Шифрование добавляет 12 байт IV и 16 байт тега GCM.
    static let attachmentOverhead: Int64 = 28
    static let attachmentFileName = "attachment.enc"
    static let attachmentMime = "application/octet-stream"

    init(baseURL: URL, tokenProvider: @escaping @MainActor () -> String?) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    // MARK: - Учётная запись

    func register(username: String, password: String, email: String, kdfIterations: Int) async throws -> RegisterResponse {
        try await post("/api/register", RegisterRequest(username: username, password: password, email: email, kdfIterations: kdfIterations), auth: false)
    }

    func limits() async throws -> LimitsResponse { try await get("/api/limits", auth: false) }

    func login(_ usernameOrEmail: String, password: String) async throws -> LoginResponse {
        try await post("/api/login", LoginRequest(username: usernameOrEmail, password: password), auth: false)
    }

    func refreshToken() async throws -> TokenResponse { try await post("/api/token/refresh", EmptyBody()) }

    func changePassword(_ request: ChangePasswordRequest) async throws -> ChangePasswordResponse {
        try await post("/api/users/change_password", request)
    }

    func recoveryStatus() async throws -> RecoveryStatusResponse { try await get("/api/recovery/status") }

    func recoverySetup(_ request: RecoverySetupRequest) async throws { try await send("POST", "/api/recovery/setup", request) }

    func recoveryBegin(_ login: String) async throws -> RecoveryBeginResponse {
        try await post("/api/recovery/begin", RecoveryBeginRequest(username: login), auth: false)
    }

    func recoveryUnlock(_ login: String, auth: String) async throws -> RecoveryUnlockResponse {
        try await post("/api/recovery/unlock", RecoveryUnlockRequest(username: login, recoveryAuth: auth), auth: false)
    }

    func recoveryReset(_ request: RecoveryResetRequest) async throws -> LoginResponse {
        try await post("/api/recovery/reset", request, auth: false)
    }

    func uploadKeys(username: String, publicKey: String, encryptedPrivateKey: String) async throws {
        try await send("POST", "/api/keys/upload", KeysUploadRequest(username: username, publicKey: publicKey, encryptedPrivateKey: encryptedPrivateKey))
    }

    func keys(_ username: String) async throws -> KeysResponse { try await get("/api/keys/\(path(username))") }

    func updateProfile(_ request: ProfileUpdateRequest) async throws { try await send("POST", "/api/profile/update", request) }

    func deleteAccount(password: String) async throws { try await send("POST", "/api/users/delete_account", PasswordRequest(password: password)) }

    func sessions(_ username: String) async throws -> SessionsResponse { try await get("/api/sessions/\(path(username))") }

    func terminateOtherSessions(username: String, deviceId: String) async throws -> TerminateSessionsResponse {
        try await post("/api/sessions/terminate", TerminateSessionsRequest(username: username, currentDevice: deviceId))
    }

    // MARK: - Контакты

    func contacts(_ username: String) async throws -> ContactsResponse { try await get("/api/contacts/\(path(username))") }

    /// С 2026-10-02 — только запрос, начинающийся с «@».
    func searchUsers(_ query: String) async throws -> UsersSearchResponse { try await get("/api/users/search?q=\(queryEncoded(query))") }

    func chatPrefs(_ request: ChatPrefsRequest) async throws -> ChatPrefsResponse { try await post("/api/chats/prefs", request) }

    func renameContact(owner: String, target: String, customName: String) async throws {
        try await send("POST", "/api/contacts/rename", ContactRenameRequest(owner: owner, target: target, customName: customName))
    }

    func block(_ blocker: String, _ blocked: String) async throws { try await send("POST", "/api/users/block", BlockRequest(blocker: blocker, blocked: blocked)) }

    func unblock(_ blocker: String, _ blocked: String) async throws { try await send("POST", "/api/users/unblock", BlockRequest(blocker: blocker, blocked: blocked)) }

    func blockedUsers() async throws -> BlockedResponse { try await get("/api/users/blocked") }

    func report(reporter: String, reported: String, reason: String) async throws {
        try await send("POST", "/api/users/report", ReportRequest(reporter: reporter, reported: reported, reason: reason))
    }

    func shared(_ username: String, with target: String) async throws -> SharedResponse {
        try await get("/api/users/\(path(username))/shared/\(path(target))")
    }

    func linkPreview(_ url: String) async throws -> LinkPreviewDto? { try await get("/api/link-preview?url=\(queryEncoded(url))") }

    // MARK: - Папки

    func folders(_ username: String) async throws -> FoldersResponse { try await get("/api/folders/\(path(username))") }

    func createFolder(username: String, name: String, targets: [String]) async throws {
        try await send("POST", "/api/folders/create", FolderCreateRequest(username: username, name: name, targets: targets))
    }

    func updateFolder(id: Int64, username: String, name: String, targets: [String]) async throws {
        try await send("PUT", "/api/folders/\(id)", FolderCreateRequest(username: username, name: name, targets: targets))
    }

    func deleteFolder(id: Int64) async throws { try await send("DELETE", "/api/folders/\(id)", Optional<EmptyBody>.none) }

    // MARK: - Сообщения

    /// topicId — переписка одной темы форума (0 — «Общее»); commentTo —
    /// комментарии к посту канала.
    func messages(me: String, peer: String, limit: Int = 200, beforeId: Int64? = nil, afterId: Int64? = nil,
                  topicId: Int64? = nil, commentTo: Int64? = nil) async throws -> MessagesResponse {
        var query = "limit=\(limit)"
        if let beforeId { query += "&before_id=\(beforeId)" }
        if let afterId { query += "&after_id=\(afterId)" }
        if let topicId { query += "&topic_id=\(topicId)" }
        if let commentTo { query += "&comment_to=\(commentTo)" }
        return try await get("/api/messages/\(path(me))/\(path(peer))?\(query)")
    }

    /// Закреплённые; topicId — только своей темы форума (0 — «Общее»).
    func pinnedMessages(me: String, peer: String, topicId: Int64? = nil) async throws -> PinnedResponse {
        try await get("/api/messages/\(path(me))/\(path(peer))/pinned" + (topicId.map { "?topic_id=\($0)" } ?? ""))
    }

    /// Строки «закрепил(а)» в ленте: после after_id.
    func pinEvents(me: String, peer: String, topicId: Int64? = nil) async throws -> PinEventsResponse {
        try await get("/api/messages/\(path(me))/\(path(peer))/pin_events" + (topicId.map { "?topic_id=\($0)" } ?? ""))
    }

    func media(me: String, peer: String) async throws -> MediaResponse {
        try await get("/api/messages/\(path(me))/\(path(peer))/media")
    }

    func readers(groupId: String, messageId: Int64) async throws -> ReadersResponse {
        try await get("/api/groups/\(path(groupId))/messages/\(messageId)/readers")
    }

    func clearChat(me: String, peer: String, mode: String) async throws {
        try await send("POST", "/api/messages/clear_chat", ClearChatRequest(user1: me, user2: peer, mode: mode))
    }

    func chatTimer(_ chatId: String) async throws -> ChatTimerResponse { try await get("/api/chats/timer?chat=\(queryEncoded(chatId))") }

    /// Отложенные (и напоминания, и «когда будет в сети») этого чата.
    func scheduled(chat: String) async throws -> ScheduledResponse { try await get("/api/scheduled?chat=\(queryEncoded(chat))") }

    func deleteScheduled(id: Int64) async throws { try await send("DELETE", "/api/scheduled/\(id)", Optional<EmptyBody>.none) }

    func sendScheduledNow(id: Int64) async throws { try await send("POST", "/api/scheduled/\(id)/send_now", EmptyBody()) }

    func drafts() async throws -> DraftsResponse { try await get("/api/drafts") }

    func putDraft(chat: String, content: String) async throws { try await send("PUT", "/api/drafts", DraftPutRequest(chat: chat, content: content)) }

    /// Загрузка файла: multipart, поле file. Лимит сервер считает по
    /// передаваемому файлу, то есть уже по шифротексту.
    func upload(_ bytes: Data, fileName: String, mimeType: String) async throws -> UploadResponse {
        let boundary = "rst-" + UUID().uuidString
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(bytes)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = try makeRequest("/api/upload", method: "POST", auth: true)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        let (data, response) = try await perform(request, body: body)
        try check(response, data: data, auth: true)
        return try decode(UploadResponse.self, data)
    }

    /// Скачать файл по file_url (относительному или полному адресу).
    func download(_ fileUrl: String) async throws -> Data {
        let url: URL
        if fileUrl.hasPrefix("http") {
            guard let u = URL(string: fileUrl) else { throw ApiError.badResponse }
            url = u
        } else {
            guard let u = URL(string: fileUrl, relativeTo: baseURL)?.absoluteURL else { throw ApiError.badResponse }
            url = u
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        if let token = tokenProvider() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await perform(request, body: nil)
        try check(response, data: data, auth: true)
        return data
    }

    func absoluteURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL
    }

    // MARK: - Группы

    func createGroup(_ request: GroupCreateRequest) async throws -> GroupCreateResponse { try await post("/api/groups/create", request) }

    func groupInfo(_ groupId: String) async throws -> GroupInfoResponse { try await get("/api/groups/\(path(groupId))/info") }

    func addMembers(_ request: GroupAddMembersRequest) async throws -> AddMembersResponse { try await post("/api/groups/add_members", request) }

    /// Своя копия ключа группы. Пустое значение или 404 — копии нет.
    func groupKey(groupId: String, username: String) async throws -> GroupKeyResponse {
        try await get("/api/groups/\(path(groupId))/key/\(path(username))")
    }

    func setMyGroupKey(groupId: String, encryptedKey: String) async throws {
        try await send("POST", "/api/groups/set_my_key", SetMyKeyRequest(groupId: groupId, encryptedKey: encryptedKey))
    }

    func shareGroupKey(groupId: String, username: String, encryptedKey: String) async throws -> StatusResponse {
        try await post("/api/groups/share_key", ShareKeyRequest(groupId: groupId, username: username, encryptedKey: encryptedKey))
    }

    func searchGroups(_ query: String) async throws -> GroupsSearchResponse { try await get("/api/groups/search?q=\(queryEncoded(query))") }

    func joinPublic(groupId: String) async throws { try await send("POST", "/api/groups/join_public", JoinPublicRequest(groupId: groupId)) }

    /// Вступление по ссылке: ok / already_member / requested (заявка ждёт админов).
    func resolveInvite(_ hash: String) async throws -> JoinByHashResponse { try await get("/api/groups/join/\(path(hash))") }

    /// Предпросмотр группы по ссылке — ничего не меняет.
    func joinPreview(_ hash: String) async throws -> JoinPreviewResponse {
        try await get("/api/groups/join/\(path(hash))/preview")
    }

    // MARK: - Одноразовые, реакции, эмодзи-статус

    /// Одноразовое открыто: сервер стирает файл и рассылает view_once_opened.
    func consumeViewOnce(id: Int64) async throws {
        try await send("POST", "/api/messages/\(id)/consume", EmptyBody())
    }

    func reactionsUnread(chat: String) async throws -> ReactionsUnreadResponse {
        try await get("/api/reactions/unread?chat=\(queryEncoded(chat))")
    }

    func reactionsSeen(chat: String, ids: [Int64]) async throws {
        try await send("POST", "/api/reactions/seen", ReactionsSeenRequest(chat: chat, ids: ids))
    }

    struct EmojiStatusRequest: Encodable {
        let emoji: String
        /// nil уходит как null — бессрочно.
        let until: String?
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(emoji, forKey: .emoji)
            try c.encode(until, forKey: .until)
        }
        enum CodingKeys: String, CodingKey { case emoji, until }
    }

    func setEmojiStatus(_ emoji: String, until: Date?) async throws {
        try await send("PUT", "/api/emoji_status", EmojiStatusRequest(emoji: emoji, until: until.map { ServerTime.iso($0) }))
    }

    /// Все аватары человека, сверху нынешний.
    func avatars(_ username: String) async throws -> AvatarsResponse { try await get("/api/users/\(path(username))/avatars") }

    /// Убрать своё фото из истории; убрали нынешний — сервер ставит следующий.
    func deleteMyAvatar(url: String) async throws {
        try await send("DELETE", "/api/users/me/avatars?url=\(queryEncoded(url))", Optional<EmptyBody>.none)
    }

    func updateGroup(_ request: GroupUpdateRequest) async throws { try await send("POST", "/api/groups/update", request) }

    func groupSettings(_ request: GroupSettingsRequest) async throws { try await send("POST", "/api/groups/settings", request) }

    func leaveGroup(_ groupId: String) async throws { try await send("POST", "/api/groups/leave", GroupIdRequest(groupId: groupId)) }

    func deleteGroup(_ groupId: String) async throws { try await send("POST", "/api/groups/delete", GroupIdRequest(groupId: groupId)) }

    func kick(groupId: String, username: String) async throws {
        try await send("POST", "/api/groups/kick", GroupMemberActionRequest(groupId: groupId, targetUsername: username))
    }

    func ban(groupId: String, username: String) async throws {
        try await send("POST", "/api/groups/ban", GroupMemberActionRequest(groupId: groupId, targetUsername: username))
    }

    func unban(groupId: String, username: String) async throws {
        try await send("POST", "/api/groups/unban", GroupMemberActionRequest(groupId: groupId, targetUsername: username))
    }

    func groupBans(_ groupId: String) async throws -> GroupBansResponse { try await get("/api/groups/\(path(groupId))/bans") }

    func promote(groupId: String, username: String, role: String) async throws {
        try await send("POST", "/api/groups/promote", GroupMemberActionRequest(groupId: groupId, targetUsername: username, role: role))
    }

    // MARK: - Управление группой: подписи, ссылки и заявки, журнал

    /// Подпись участника: владелец и админы — любому, участник — себе. Пусто — снять.
    func setMemberTitle(groupId: String, username: String, title: String) async throws {
        try await send("POST", "/api/groups/member_title", MemberTitleRequest(groupId: groupId, targetUsername: username, title: title))
    }

    func invites(groupId: String) async throws -> InvitesResponse { try await get("/api/groups/\(path(groupId))/invites") }

    func createInvite(groupId: String, _ request: InviteCreateRequest) async throws -> InviteDto {
        try await post("/api/groups/\(path(groupId))/invites", request)
    }

    func revokeInvite(groupId: String, id: Int64) async throws {
        try await send("POST", "/api/groups/\(path(groupId))/invites/\(id)/revoke", EmptyBody())
    }

    func joinRequests(groupId: String) async throws -> JoinRequestsResponse { try await get("/api/groups/\(path(groupId))/requests") }

    func resolveJoinRequest(groupId: String, username: String, approve: Bool) async throws {
        try await send("POST", "/api/groups/\(path(groupId))/requests/\(path(username))/\(approve ? "approve" : "decline")", EmptyBody())
    }

    func adminLog(groupId: String, before: Int64?) async throws -> AdminLogResponse {
        try await get("/api/groups/\(path(groupId))/admin_log" + (before.map { "?before=\($0)" } ?? ""))
    }

    // MARK: - Темы (routers/topics.py): номер группы без «group_»

    func topics(groupNumber: String) async throws -> TopicsResponse { try await get("/api/groups/\(path(groupNumber))/topics") }

    func setForum(groupNumber: String, enabled: Bool) async throws {
        try await send("POST", "/api/groups/\(path(groupNumber))/forum", ForumToggleRequest(enabled: enabled))
    }

    func createTopic(groupNumber: String, title: String, icon: String) async throws -> ForumTopicDto {
        try await post("/api/groups/\(path(groupNumber))/topics", TopicCreateRequest(title: title, icon: icon))
    }

    func updateTopic(groupNumber: String, id: Int64, _ request: TopicUpdateRequest) async throws {
        try await send("PATCH", "/api/groups/\(path(groupNumber))/topics/\(id)", request)
    }

    func deleteTopic(groupNumber: String, id: Int64) async throws {
        try await send("DELETE", "/api/groups/\(path(groupNumber))/topics/\(id)", Optional<EmptyBody>.none)
    }

    // MARK: - Вход по QR-коду (routers/qrlogin.py)

    func qrStart(pub: String) async throws -> QrStartResponse { try await post("/api/qr/start", QrStartRequest(pub: pub), auth: false) }

    /// 410 — код устарел.
    func qrPoll(session: String, secret: String) async throws -> QrPollResponse {
        try await post("/api/qr/poll", QrPollRequest(session: session, secret: secret), auth: false)
    }

    func qrInfo(session: String) async throws -> QrInfoResponse { try await get("/api/qr/" + path(session)) }

    func qrApprove(_ request: QrApproveRequest) async throws { try await send("POST", "/api/qr/approve", request) }

    func qrDeny(session: String) async throws { try await send("POST", "/api/qr/deny", QrSessionRequest(session: session)) }

    // MARK: - Звонки

    func turnCredentials() async throws -> TurnCredentialsResponse { try await get("/api/turn-credentials") }

    func logCall(_ request: CallLogRequest) async throws { try await send("POST", "/api/calls/log", request) }

    func callHistory() async throws -> CallHistoryResponse { try await get("/api/calls") }

    // MARK: - Истории (routers/stories.py)

    func stories() async throws -> StoriesResponse { try await get("/api/stories") }

    /// Кому видны мои истории — им упаковывается ключ.
    func storyAudience() async throws -> StoryAudienceResponse { try await get("/api/stories/audience") }

    func createStory(_ request: StoryCreateRequest) async throws -> StoryCreateResponse { try await post("/api/stories", request) }

    func viewStory(_ id: Int64) async throws { try await send("POST", "/api/stories/\(id)/view", EmptyBody()) }

    func storyViewers(_ id: Int64) async throws -> StoryViewersResponse { try await get("/api/stories/\(id)/viewers") }

    func likeStory(_ id: Int64, liked: Bool) async throws { try await send("POST", "/api/stories/\(id)/like", StoryLikeRequest(liked: liked)) }

    func storyComments(_ id: Int64) async throws -> StoryCommentsResponse { try await get("/api/stories/\(id)/comments") }

    func addStoryComment(_ id: Int64, content: String) async throws {
        try await send("POST", "/api/stories/\(id)/comments", StoryCommentRequest(content: content))
    }

    func deleteStoryComment(story: Int64, comment: Int64) async throws {
        try await send("DELETE", "/api/stories/\(story)/comments/\(comment)", Optional<EmptyBody>.none)
    }

    func deleteStory(_ id: Int64) async throws { try await send("DELETE", "/api/stories/\(id)", Optional<EmptyBody>.none) }

    func storyHidden() async throws -> StoryHiddenResponse { try await get("/api/stories/hidden") }

    func setStoryHidden(_ usernames: [String]) async throws { try await send("PUT", "/api/stories/hidden", StoryHiddenRequest(usernames: usernames)) }

    // MARK: - Стикеры (routers/stickers.py)

    /// Добавленные себе наборы (свои — тоже).
    func stickerSets() async throws -> StickerSetsResponse { try await get("/api/stickers") }

    func stickerSet(name: String) async throws -> StickerSetDto { try await get("/api/stickers/sets/\(path(name))") }

    /// Имя набора по картинке стикера — открыть набор из переписки.
    func stickerLookup(fileUrl: String) async throws -> StickerLookupResponse {
        try await get("/api/stickers/lookup?file_url=\(queryEncoded(fileUrl))")
    }

    func createStickerSet(title: String, name: String) async throws -> StickerSetDto {
        try await post("/api/stickers/sets", StickerSetCreateRequest(title: title, name: name))
    }

    func addSticker(setId: Int64, fileUrl: String, emoji: String) async throws -> StickerDto {
        try await post("/api/stickers/sets/\(setId)/stickers", StickerAddRequest(fileUrl: fileUrl, emoji: emoji))
    }

    func removeSticker(setId: Int64, stickerId: Int64) async throws {
        try await send("DELETE", "/api/stickers/sets/\(setId)/stickers/\(stickerId)", Optional<EmptyBody>.none)
    }

    func deleteStickerSet(id: Int64) async throws { try await send("DELETE", "/api/stickers/sets/\(id)", Optional<EmptyBody>.none) }

    func installStickerSet(id: Int64, install: Bool) async throws {
        if install {
            try await send("POST", "/api/stickers/sets/\(id)/install", EmptyBody())
        } else {
            try await send("DELETE", "/api/stickers/sets/\(id)/install", Optional<EmptyBody>.none)
        }
    }

    // MARK: - Внутреннее

    private static let retryPauses: [UInt64] = [1_500, 3_500]
    private static let retryableCodes: Set<Int> = [502, 503, 504]

    /// GET повторяется дважды при 502/503/504: выкладка новой версии
    /// останавливает сервер на несколько секунд. Пишущие запросы не повторяются.
    private func get<T: Decodable>(_ path: String, auth: Bool = true) async throws -> T {
        for pause in Self.retryPauses {
            do {
                return try await execute(makeRequest(path, method: "GET", auth: auth), body: nil, auth: auth)
            } catch let error as ApiError {
                switch error {
                case .http(let code, _, _) where Self.retryableCodes.contains(code): break
                case .network: break
                default: throw error
                }
            }
            try await Task.sleep(nanoseconds: pause * 1_000_000)
        }
        return try await execute(makeRequest(path, method: "GET", auth: auth), body: nil, auth: auth)
    }

    private func post<B: Encodable, T: Decodable>(_ path: String, _ body: B, auth: Bool = true) async throws -> T {
        var request = try makeRequest(path, method: "POST", auth: auth)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await execute(request, body: try JSONCoding.encodeData(body), auth: auth)
    }

    private func send<B: Encodable>(_ method: String, _ path: String, _ body: B?) async throws {
        var request = try makeRequest(path, method: method, auth: true)
        var data: Data?
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            data = try JSONCoding.encodeData(body)
        }
        let (responseData, response) = try await perform(request, body: data)
        try check(response, data: responseData, auth: true)
    }

    private func execute<T: Decodable>(_ request: URLRequest, body: Data?, auth: Bool) async throws -> T {
        let (data, response) = try await perform(request, body: body)
        try check(response, data: data, auth: auth)
        return try decode(T.self, data)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ApiError.badResponse
        }
    }

    private func makeRequest(_ path: String, method: String, auth: Bool) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw ApiError.badResponse }
        if auth && isSessionOver() { throw ApiError.sessionOver }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if auth, let token = tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func perform(_ request: URLRequest, body: Data?) async throws -> (Data, URLResponse) {
        do {
            if let body {
                return try await session.upload(for: request, from: body)
            }
            return try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ApiError.network("Сеть недоступна")
        }
    }

    private func check(_ response: URLResponse, data: Data, auth: Bool) throws {
        guard let http = response as? HTTPURLResponse else { throw ApiError.badResponse }
        guard !(200..<300).contains(http.statusCode) else { return }
        // 401 на запросе с токеном — токен недействителен. На входе
        // (auth = false) 401 означает всего лишь неверный пароль.
        if http.statusCode == 401 && auth { onUnauthorized() }
        let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap { Int($0) }
        throw ApiError.http(code: http.statusCode, detail: ApiErrorText.detail(data, code: http.statusCode), retryAfter: retryAfter)
    }

    private func path(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
    }

    private func queryEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// Текст ошибки сервера человеческим языком.
enum ApiErrorText {
    static let fieldNames: [String: String] = [
        "display_name": "Имя", "bio": "О себе", "birthday": "День рождения", "phone": "Телефон",
        "email": "Почта", "status": "Статус", "avatar_url": "Аватар", "username": "Имя пользователя",
        "name": "Название", "description": "Описание", "alias": "Короткая ссылка",
        "quiet_hours": "Тихие часы", "custom_name": "Имя контакта", "password": "Пароль",
    ]

    /// Текст ошибки из detail. При 422 это массив {loc, msg}: имя поля —
    /// последний элемент loc, сообщение сервера английское — подставляем подпись.
    static func detail(_ data: Data, code: Int) -> String {
        if let body = try? JSONDecoder().decode(JSONValue.self, from: data), let detail = body["detail"] {
            if case .string(let s) = detail, !s.isEmpty { return s }
            if let first = detail.array?.first {
                let field = first["loc"]?.array?.last?.string ?? ""
                if let label = fieldNames[field] { return "Проверьте поле «\(label)»" }
                if let msg = first["msg"]?.string, !msg.isEmpty { return msg }
            }
        }
        // 413 приходит и от nginx с HTML-телом — опираемся на код
        switch code {
        case 413: return "Файл слишком большой"
        case 507: return "На сервере закончилось место"
        case 429: return "Слишком много запросов."
        case 500...599: return "Сервер временно недоступен"
        default: return "Ошибка \(code)"
        }
    }
}
