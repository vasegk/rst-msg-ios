import Foundation

// Модели REST API. Имена полей — ровно как у сервера (PROMPT_ANDROID.md).
// Почти всё необязательно: сервер добавляет поля со временем, и отсутствие
// поля не должно ронять разбор всего ответа.

// MARK: - Учётная запись

struct RegisterRequest: Encodable {
    let username: String
    let password: String
    let email: String
    let kdfIterations: Int
    enum CodingKeys: String, CodingKey {
        case username, password, email
        case kdfIterations = "kdf_iterations"
    }
}

struct RegisterResponse: Decodable {
    let message: String?
    let kdfSalt: String
    let kdfIterations: Int?
    enum CodingKeys: String, CodingKey {
        case message
        case kdfSalt = "kdf_salt"
        case kdfIterations = "kdf_iterations"
    }
}

/// Поле username принимает и имя, и email.
struct LoginRequest: Encodable {
    let username: String
    let password: String
}

struct LoginResponse: Decodable {
    let username: String
    let originalUsername: String?
    let kdfSalt: String
    /// ЛОМАЕТ СОВМЕСТИМОСТЬ с 2026-09-15: у новых аккаунтов 600 000, у старых 100 000.
    let kdfIterations: Int?
    let accessToken: String
    enum CodingKeys: String, CodingKey {
        case username
        case originalUsername = "original_username"
        case kdfSalt = "kdf_salt"
        case kdfIterations = "kdf_iterations"
        case accessToken = "access_token"
    }
}

struct TokenResponse: Decodable {
    let accessToken: String
    enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
}

struct ChangePasswordRequest: Encodable {
    let oldPassword: String
    let newPassword: String
    let kdfSalt: String
    let kdfIterations: Int
    let encryptedPrivateKey: String
    let currentDevice: String
    enum CodingKeys: String, CodingKey {
        case oldPassword = "old_password"
        case newPassword = "new_password"
        case kdfSalt = "kdf_salt"
        case kdfIterations = "kdf_iterations"
        case encryptedPrivateKey = "encrypted_private_key"
        case currentDevice = "current_device"
    }
}

struct ChangePasswordResponse: Decodable {
    let kdfSalt: String
    let kdfIterations: Int
    let accessToken: String
    enum CodingKeys: String, CodingKey {
        case kdfSalt = "kdf_salt"
        case kdfIterations = "kdf_iterations"
        case accessToken = "access_token"
    }
}

struct RecoveryStatusResponse: Decodable {
    let enabled: Bool?
    let createdAt: String?
    enum CodingKeys: String, CodingKey {
        case enabled
        case createdAt = "created_at"
    }
}

struct RecoverySetupRequest: Encodable {
    let password: String
    let recoverySalt: String
    let recoveryKey: String
    let recoveryAuth: String
    enum CodingKeys: String, CodingKey {
        case password
        case recoverySalt = "recovery_salt"
        case recoveryKey = "recovery_key"
        case recoveryAuth = "recovery_auth"
    }
}

struct RecoveryBeginRequest: Encodable { let username: String }

struct RecoveryBeginResponse: Decodable {
    let recoverySalt: String
    let kdfIterations: Int?
    enum CodingKeys: String, CodingKey {
        case recoverySalt = "recovery_salt"
        case kdfIterations = "kdf_iterations"
    }
}

struct RecoveryUnlockRequest: Encodable {
    let username: String
    let recoveryAuth: String
    enum CodingKeys: String, CodingKey {
        case username
        case recoveryAuth = "recovery_auth"
    }
}

struct RecoveryUnlockResponse: Decodable {
    let recoveryKey: String
    enum CodingKeys: String, CodingKey { case recoveryKey = "recovery_key" }
}

struct RecoveryResetRequest: Encodable {
    let username: String
    let recoveryAuth: String
    let newPassword: String
    let kdfSalt: String
    let kdfIterations: Int
    let encryptedPrivateKey: String
    enum CodingKeys: String, CodingKey {
        case username
        case recoveryAuth = "recovery_auth"
        case newPassword = "new_password"
        case kdfSalt = "kdf_salt"
        case kdfIterations = "kdf_iterations"
        case encryptedPrivateKey = "encrypted_private_key"
    }
}

struct KeysUploadRequest: Encodable {
    let username: String
    let publicKey: String
    let encryptedPrivateKey: String
    enum CodingKeys: String, CodingKey {
        case username
        case publicKey = "public_key"
        case encryptedPrivateKey = "encrypted_private_key"
    }
}

struct KeysResponse: Decodable {
    let publicKey: String?
    /// Приходит только когда запрашиваешь сам себя.
    let encryptedPrivateKey: String?
    enum CodingKeys: String, CodingKey {
        case publicKey = "public_key"
        case encryptedPrivateKey = "encrypted_private_key"
    }
}

struct PasswordRequest: Encodable { let password: String }

/// Обновление профиля. Сервер применяет только переданные поля
/// (nil не сериализуется), значения проверяет — иначе 422.
struct ProfileUpdateRequest: Encodable {
    var username: String
    var displayName: String?
    var bio: String?
    /// online | dnd | offline
    var status: String?
    /// Только /uploads/<32 hex>.<png|jpg|jpeg|gif|webp>
    var avatarUrl: String?
    /// ГГГГ-ММ-ДД или пусто
    var birthday: String?
    var birthdayPrivacy: String?
    var email: String?
    var phone: String?
    var phonePrivacy: String?
    var emailPrivacy: String?
    var lastSeenPrivacy: String?
    var readReceipts: Bool?
    var callPrivacy: String?
    var groupInvitePrivacy: String?
    var storyComments: Bool?
    var defaultTimer: Int?
    var quietHours: String?
    var timeZone: String?
    var notifyPrivate: Bool?
    var notifyGroups: Bool?
    var autoreplyOn: Bool?
    var autoreplyText: String?
    /// Музыка в профиле: /uploads/<32 hex>.<mp3|m4a|aac|ogg|wav|webm>; "" — убрать.
    var musicUrl: String?
    var musicTitle: String?

    init(username: String) { self.username = username }

    enum CodingKeys: String, CodingKey {
        case username, bio, status, birthday, email, phone
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case musicUrl = "music_url"
        case musicTitle = "music_title"
        case birthdayPrivacy = "birthday_privacy"
        case phonePrivacy = "phone_privacy"
        case emailPrivacy = "email_privacy"
        case lastSeenPrivacy = "last_seen_privacy"
        case readReceipts = "read_receipts"
        case callPrivacy = "call_privacy"
        case groupInvitePrivacy = "group_invite_privacy"
        case storyComments = "story_comments"
        case defaultTimer = "default_timer"
        case quietHours = "quiet_hours"
        case timeZone = "time_zone"
        case notifyPrivate = "notify_private"
        case notifyGroups = "notify_groups"
        case autoreplyOn = "autoreply_on"
        case autoreplyText = "autoreply_text"
    }
}

// MARK: - Контакты

/// Пользователь в списке чатов и в поиске.
///
/// Имена полей отличаются от привычных: `name` (не display_name), `online`,
/// `unread`. Заданное вами имя контакта уже подставлено в `name`.
struct ContactUserDto: Decodable, Equatable {
    let username: String
    let name: String?
    let avatarUrl: String?
    let bio: String?
    let birthday: String?
    let birthdayPrivacy: String?
    let email: String?
    let phone: String?
    let online: Bool?
    /// online, dnd, offline — или deleted у удалённого аккаунта
    let status: String?
    let unread: Int?
    let lastSeen: String?
    let isSystem: Bool?
    let lastMsg: LastMessageDto?
    let muted: Bool?
    let mutedUntil: String?
    let pinned: Bool?
    let archived: Bool?
    let markedUnread: Bool?
    // Только в своей записи — настройки для формы
    let phonePrivacy: String?
    let emailPrivacy: String?
    let lastSeenPrivacy: String?
    let readReceipts: Bool?
    let callPrivacy: String?
    let groupInvitePrivacy: String?
    let storyComments: Bool?
    let defaultTimer: Int?
    let quietHours: String?
    let notifyPrivate: Bool?
    let notifyGroups: Bool?
    let blockedUntil: String?
    let verified: Bool?
    let musicUrl: String?
    let musicTitle: String?
    let autoreplyOn: Bool?
    let autoreplyText: String?
    /// Сообщений с новыми реакциями на мои (с 2026-10-08).
    let unreadReactions: Int?
    let emojiStatus: String?
    let emojiStatusUntil: String?

    var isDeleted: Bool { status == "deleted" }
    var displayName: String { (name?.isEmpty == false ? name : nil) ?? username }

    enum CodingKeys: String, CodingKey {
        case username, name, bio, birthday, email, phone, online, status, unread, muted, pinned, archived, verified
        case avatarUrl = "avatar_url"
        case birthdayPrivacy = "birthday_privacy"
        case lastSeen = "last_seen"
        case isSystem = "is_system"
        case lastMsg = "last_msg"
        case mutedUntil = "muted_until"
        case markedUnread = "marked_unread"
        case phonePrivacy = "phone_privacy"
        case emailPrivacy = "email_privacy"
        case lastSeenPrivacy = "last_seen_privacy"
        case readReceipts = "read_receipts"
        case callPrivacy = "call_privacy"
        case groupInvitePrivacy = "group_invite_privacy"
        case storyComments = "story_comments"
        case defaultTimer = "default_timer"
        case quietHours = "quiet_hours"
        case notifyPrivate = "notify_private"
        case notifyGroups = "notify_groups"
        case blockedUntil = "blocked_until"
        case musicUrl = "music_url"
        case musicTitle = "music_title"
        case autoreplyOn = "autoreply_on"
        case autoreplyText = "autoreply_text"
        case unreadReactions = "unread_reactions"
        case emojiStatus = "emoji_status"
        case emojiStatusUntil = "emoji_status_until"
    }
}

/// Последнее сообщение чата — для превью и сортировки списка.
/// content зашифрован; status — sent|read для галочек у своего.
struct LastMessageDto: Decodable, Equatable {
    let id: Int64?
    let sender: String?
    let content: String?
    let fileType: String?
    let time: String?
    let status: String?
    enum CodingKeys: String, CodingKey {
        case id, sender, content, time, status
        case fileType = "file_type"
    }
}

/// Группа в списке чатов. `id` — строка вида group_2, то есть готовый chatId.
struct ContactGroupDto: Decodable, Equatable {
    let id: String
    let name: String?
    let avatarUrl: String?
    let unread: Int?
    let lastMsg: LastMessageDto?
    let adminsOnly: Bool?
    let slowMode: Int?
    let myRole: String?
    let muted: Bool?
    let mutedUntil: String?
    let pinned: Bool?
    let archived: Bool?
    let markedUnread: Bool?
    /// "group" или "channel"
    let kind: String?
    let forum: Bool?
    let unreadReactions: Int?
    /// Запрет пересылки и сохранения (с 2026-10-18).
    let isProtected: Bool?
    enum CodingKeys: String, CodingKey {
        case id, name, unread, muted, pinned, archived, kind, forum
        case unreadReactions = "unread_reactions"
        case isProtected = "protected"
        case avatarUrl = "avatar_url"
        case lastMsg = "last_msg"
        case adminsOnly = "admins_only"
        case slowMode = "slow_mode"
        case myRole = "my_role"
        case mutedUntil = "muted_until"
        case markedUnread = "marked_unread"
    }
}

struct ContactsResponse: Decodable {
    let users: [ContactUserDto]?
    let groups: [ContactGroupDto]?
}

/// Настройки чата: передаются только меняемые признаки.
struct ChatPrefsRequest: Encodable {
    let chatId: String
    var muted: Bool?
    /// Секунды; 0 — включить уведомления, -1 — отключить навсегда.
    var muteFor: Int?
    var pinned: Bool?
    var archived: Bool?
    var markedUnread: Bool?

    init(chatId: String, muteFor: Int? = nil, pinned: Bool? = nil, archived: Bool? = nil, markedUnread: Bool? = nil) {
        self.chatId = chatId
        self.muteFor = muteFor
        self.pinned = pinned
        self.archived = archived
        self.markedUnread = markedUnread
    }

    enum CodingKeys: String, CodingKey {
        case muted, pinned, archived
        case chatId = "chat_id"
        case muteFor = "mute_for"
        case markedUnread = "marked_unread"
    }
}

struct ChatPrefsResponse: Decodable {
    let muted: Bool?
    let mutedUntil: String?
    let pinned: Bool?
    let archived: Bool?
    let markedUnread: Bool?
    enum CodingKeys: String, CodingKey {
        case muted, pinned, archived
        case mutedUntil = "muted_until"
        case markedUnread = "marked_unread"
    }
}

struct UsersSearchResponse: Decodable { let users: [ContactUserDto]? }

struct ContactRenameRequest: Encodable {
    let owner: String
    let target: String
    let customName: String
    enum CodingKeys: String, CodingKey {
        case owner, target
        case customName = "custom_name"
    }
}

struct BlockRequest: Encodable {
    let blocker: String
    let blocked: String
}

struct BlockedUserDto: Decodable, Identifiable, Equatable {
    let username: String
    let name: String?
    let avatarUrl: String?
    var id: String { username }
    enum CodingKeys: String, CodingKey {
        case username, name
        case avatarUrl = "avatar_url"
    }
}

struct BlockedResponse: Decodable { let blocked: [BlockedUserDto]? }

struct ReportRequest: Encodable {
    let reporter: String
    let reported: String
    let reason: String
}

struct SharedGroupDto: Decodable, Identifiable {
    let id: String
    let name: String?
    let avatarUrl: String?
    enum CodingKeys: String, CodingKey {
        case id, name
        case avatarUrl = "avatar_url"
    }
}

struct SharedResponse: Decodable {
    let sharedGroups: [SharedGroupDto]?
    let isBlocked: Bool?
    enum CodingKeys: String, CodingKey {
        case sharedGroups = "shared_groups"
        case isBlocked = "is_blocked"
    }
}

// MARK: - Сеансы

/// Список строится из живых соединений в памяти сервера: после перезапуска
/// службы он пуст, пока клиенты не переподключатся.
struct SessionDto: Decodable, Identifiable {
    let deviceId: String
    let ip: String?
    let ua: String?
    var id: String { deviceId }
    enum CodingKeys: String, CodingKey {
        case ip, ua
        case deviceId = "device_id"
    }
}

struct SessionsResponse: Decodable { let sessions: [SessionDto]? }

struct TerminateSessionsRequest: Encodable {
    let username: String
    let currentDevice: String
    enum CodingKeys: String, CodingKey {
        case username
        case currentDevice = "current_device"
    }
}

/// Все прежние токены отозваны; текущее устройство получает новый.
struct TerminateSessionsResponse: Decodable {
    let closed: Int?
    let accessToken: String?
    enum CodingKeys: String, CodingKey {
        case closed
        case accessToken = "access_token"
    }
}

// MARK: - Папки

struct FolderDto: Decodable, Identifiable, Equatable {
    let id: Int64
    let name: String
    let targets: [String]?
}

struct FoldersResponse: Decodable { let folders: [FolderDto]? }

struct FolderCreateRequest: Encodable {
    let username: String
    let name: String
    let targets: [String]
}

// MARK: - Сообщения

/// content и reply_to_content приходят зашифрованными — расшифровывать оба.
struct MessageDto: Decodable, Equatable {
    let id: Int64
    let sender: String
    let receiver: String?
    let content: String?
    let fileUrl: String?
    let fileType: String?
    let status: String?
    /// JSON-строка вида {"имя_пользователя":"эмодзи"}
    let reactions: String?
    let isEdited: Bool?
    let replyTo: Int64?
    let replyToSender: String?
    let replyToContent: String?
    let isPinned: Bool?
    let forwardedFrom: String?
    let createdAt: String?
    let expiresAt: String?
    let silent: Bool?
    let poll: JSONValue?
    let played: Bool?
    let topicId: Int64?
    let commentTo: Int64?
    let commentCount: Int?
    /// Одноразовое фото/видео (с 2026-10-08).
    let viewOnce: Bool?
    /// Напоминание в Избранное (с 2026-10-18).
    let reminder: Bool?
    /// Уже очищенные сервером упоминания (с 2026-10-18).
    let mentionAll: Bool?
    let mentions: [String]?

    static let fileTypeSystem = "system"
    static let fileTypePoll = "application/x-rst-poll"
    static let fileTypeAutoreply = "application/x-rst-autoreply"
    static let fileTypeSticker = "application/x-rst-sticker"
    static let fileTypeLiveLocation = "application/x-rst-live-location"

    var isSystem: Bool { fileType == MessageDto.fileTypeSystem }

    enum CodingKeys: String, CodingKey {
        case id, sender, receiver, content, status, reactions, silent, poll, played
        case fileUrl = "file_url"
        case fileType = "file_type"
        case isEdited = "is_edited"
        case replyTo = "reply_to"
        case replyToSender = "reply_to_sender"
        case replyToContent = "reply_to_content"
        case isPinned = "is_pinned"
        case forwardedFrom = "forwarded_from"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case topicId = "topic_id"
        case commentTo = "comment_to"
        case commentCount = "comment_count"
        case viewOnce = "view_once"
        case reminder
        case mentionAll = "mention_all"
        case mentions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeFlexibleInt64(.id) ?? 0
        sender = (try? c.decodeIfPresent(String.self, forKey: .sender)) ?? ""
        receiver = try? c.decodeIfPresent(String.self, forKey: .receiver)
        content = try? c.decodeIfPresent(String.self, forKey: .content)
        fileUrl = try? c.decodeIfPresent(String.self, forKey: .fileUrl)
        fileType = try? c.decodeIfPresent(String.self, forKey: .fileType)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        // Реакции — JSON-строкой; на всякий случай принимаем и объект
        if let s = try? c.decodeIfPresent(String.self, forKey: .reactions) {
            reactions = s
        } else if let obj = try? c.decodeIfPresent(JSONValue.self, forKey: .reactions), obj != .null {
            reactions = JSONCoding.encodeString(obj)
        } else {
            reactions = nil
        }
        isEdited = try? c.decodeIfPresent(Bool.self, forKey: .isEdited)
        replyTo = try c.decodeFlexibleInt64(.replyTo)
        replyToSender = try? c.decodeIfPresent(String.self, forKey: .replyToSender)
        replyToContent = try? c.decodeIfPresent(String.self, forKey: .replyToContent)
        isPinned = try? c.decodeIfPresent(Bool.self, forKey: .isPinned)
        forwardedFrom = try? c.decodeIfPresent(String.self, forKey: .forwardedFrom)
        createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
        expiresAt = try? c.decodeIfPresent(String.self, forKey: .expiresAt)
        silent = try? c.decodeIfPresent(Bool.self, forKey: .silent)
        poll = try? c.decodeIfPresent(JSONValue.self, forKey: .poll)
        played = try? c.decodeIfPresent(Bool.self, forKey: .played)
        topicId = try c.decodeFlexibleInt64(.topicId)
        commentTo = try c.decodeFlexibleInt64(.commentTo)
        commentCount = try? c.decodeIfPresent(Int.self, forKey: .commentCount)
        viewOnce = try? c.decodeIfPresent(Bool.self, forKey: .viewOnce)
        reminder = try? c.decodeIfPresent(Bool.self, forKey: .reminder)
        mentionAll = try? c.decodeIfPresent(Bool.self, forKey: .mentionAll)
        mentions = try? c.decodeIfPresent([String].self, forKey: .mentions)
    }
}

extension KeyedDecodingContainer {
    /// Число, которое могло прийти и строкой из цифр.
    func decodeFlexibleInt64(_ key: Key) throws -> Int64? {
        if let v = try? decodeIfPresent(Int64.self, forKey: key) { return v }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int64(s) }
        return nil
    }
}

struct MessagesResponse: Decodable {
    let messages: [MessageDto]?
    let hasMore: Bool?
    let oldestId: Int64?
    enum CodingKeys: String, CodingKey {
        case messages
        case hasMore = "has_more"
        case oldestId = "oldest_id"
    }
}

struct PinnedResponse: Decodable { let messages: [MessageDto]? }

struct MediaResponse: Decodable { let media: [MessageDto]? }

struct ReaderDto: Decodable, Identifiable {
    let username: String
    let name: String?
    let avatarUrl: String?
    let deleted: Bool?
    var id: String { username }
    enum CodingKeys: String, CodingKey {
        case username, name, deleted
        case avatarUrl = "avatar_url"
    }
}

struct ReadersResponse: Decodable {
    let readers: [ReaderDto]?
    let total: Int?
}

/// Отложенное сообщение: send_at — ISO с Z; reminder — напоминание в
/// Избранное; when_online — уйдёт, когда собеседник появится в сети.
struct ScheduledDto: Decodable, Identifiable, Equatable {
    let id: Int64
    let receiver: String?
    let content: String?
    let fileUrl: String?
    let fileType: String?
    let sendAt: String?
    let reminder: Bool?
    let whenOnline: Bool?
    enum CodingKeys: String, CodingKey {
        case id, receiver, content, reminder
        case fileUrl = "file_url"
        case fileType = "file_type"
        case sendAt = "send_at"
        case whenOnline = "when_online"
    }
}

struct ScheduledResponse: Decodable { let scheduled: [ScheduledDto]? }

struct ClearChatRequest: Encodable {
    let user1: String
    let user2: String
    let mode: String
}

struct ChatTimerResponse: Decodable {
    let seconds: Int?
    let setBy: String?
    enum CodingKeys: String, CodingKey {
        case seconds
        case setBy = "set_by"
    }
}

struct UploadResponse: Decodable {
    let fileUrl: String
    let fileType: String?
    enum CodingKeys: String, CodingKey {
        case fileUrl = "file_url"
        case fileType = "file_type"
    }
}

// MARK: - Группы

struct GroupCreateRequest: Encodable {
    let name: String
    let description: String?
    let members: [String]
    /// Ключ группы, упакованный отдельно для каждого участника: имя -> пакет JSON.
    let encryptedKeys: [String: String]
    /// "channel" — канал; nil — обычная группа.
    let kind: String?
    enum CodingKeys: String, CodingKey {
        case name, description, members, kind
        case encryptedKeys = "encrypted_keys"
    }
}

struct GroupCreateResponse: Decodable {
    let groupId: String
    let skipped: Int?
    enum CodingKeys: String, CodingKey {
        case skipped
        case groupId = "group_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .groupId) {
            groupId = s
        } else {
            groupId = String(try c.decode(Int64.self, forKey: .groupId))
        }
        skipped = try? c.decodeIfPresent(Int.self, forKey: .skipped)
    }
}

struct GroupAddMembersRequest: Encodable {
    let groupId: String
    let members: [String]
    let encryptedKeys: [String: String]
    enum CodingKeys: String, CodingKey {
        case members
        case groupId = "group_id"
        case encryptedKeys = "encrypted_keys"
    }
}

struct AddMembersResponse: Decodable { let skipped: Int? }

struct GroupKeyResponse: Decodable {
    let encryptedKey: String?
    enum CodingKeys: String, CodingKey { case encryptedKey = "encrypted_key" }
}

struct SetMyKeyRequest: Encodable {
    let groupId: String
    let encryptedKey: String
    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case encryptedKey = "encrypted_key"
    }
}

struct ShareKeyRequest: Encodable {
    let groupId: String
    let username: String
    let encryptedKey: String
    enum CodingKeys: String, CodingKey {
        case username
        case groupId = "group_id"
        case encryptedKey = "encrypted_key"
    }
}

struct StatusResponse: Decodable { let status: String? }

struct GroupUpdateRequest: Encodable {
    let groupId: String
    var name: String?
    var description: String?
    var avatarUrl: String?
    enum CodingKeys: String, CodingKey {
        case name, description
        case groupId = "group_id"
        case avatarUrl = "avatar_url"
    }
}

/// leave и delete: исполнителя сервер берёт из токена.
struct GroupIdRequest: Encodable {
    let groupId: String
    enum CodingKeys: String, CodingKey { case groupId = "group_id" }
}

/// kick, ban, unban и promote. Поле называется target_username, а не username.
struct GroupMemberActionRequest: Encodable {
    let groupId: String
    let targetUsername: String
    var role: String?
    enum CodingKeys: String, CodingKey {
        case role
        case groupId = "group_id"
        case targetUsername = "target_username"
    }
}

struct GroupBansResponse: Decodable { let bans: [BlockedUserDto]? }

struct GroupSettingsRequest: Encodable {
    let groupId: String
    var isPublic: Bool?
    var regenerateInvite: Bool?
    var alias: String?
    var description: String?
    var adminsOnly: Bool?
    /// Секунды из набора 0, 10, 30, 60, 300, 900, 3600.
    var slowMode: Int?
    var isProtected: Bool?
    var joinApproval: Bool?

    init(groupId: String) { self.groupId = groupId }

    enum CodingKeys: String, CodingKey {
        case alias, description
        case isProtected = "protected"
        case joinApproval = "join_approval"
        case groupId = "group_id"
        case isPublic = "is_public"
        case regenerateInvite = "regenerate_invite"
        case adminsOnly = "admins_only"
        case slowMode = "slow_mode"
    }
}

struct JoinPublicRequest: Encodable {
    let groupId: String
    enum CodingKeys: String, CodingKey { case groupId = "group_id" }
}

/// Вступление по ссылке: status — ok / already_member / requested (заявка
/// отправлена, участником ещё не стал).
struct JoinByHashResponse: Decodable {
    let groupId: String
    let status: String?
    let name: String?
    enum CodingKeys: String, CodingKey {
        case status, name
        case groupId = "group_id"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .groupId) {
            groupId = s
        } else {
            groupId = String(try c.decode(Int64.self, forKey: .groupId))
        }
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
    }
    var isRequested: Bool { status == "requested" }
}

/// Предпросмотр группы по ссылке — ничего не меняет (с 2026-10-12).
struct JoinPreviewResponse: Decodable {
    let groupId: String?
    let name: String?
    let description: String?
    let avatarUrl: String?
    let kind: String?
    let members: Int?
    let approval: Bool?
    let isMember: Bool?
    let requested: Bool?
    var isChannel: Bool { kind == "channel" }
    enum CodingKeys: String, CodingKey {
        case name, description, kind, members, approval, requested
        case groupId = "group_id"
        case avatarUrl = "avatar_url"
        case isMember = "is_member"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decodeIfPresent(String.self, forKey: .groupId) {
            groupId = s
        } else if let n = try? c.decodeIfPresent(Int64.self, forKey: .groupId) {
            groupId = String(n)
        } else {
            groupId = nil
        }
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        avatarUrl = try? c.decodeIfPresent(String.self, forKey: .avatarUrl)
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        members = try? c.decodeIfPresent(Int.self, forKey: .members)
        approval = try? c.decodeIfPresent(Bool.self, forKey: .approval)
        isMember = try? c.decodeIfPresent(Bool.self, forKey: .isMember)
        requested = try? c.decodeIfPresent(Bool.self, forKey: .requested)
    }
}

/// Новые реакции на мои сообщения, по порядку (с 2026-10-08).
struct ReactionsUnreadResponse: Decodable {
    struct Item: Decodable, Equatable {
        let messageId: Int64
        let reactor: String?
        let emoji: String?
        enum CodingKeys: String, CodingKey {
            case reactor, emoji
            case messageId = "message_id"
        }
    }
    let items: [Item]?
}

struct ReactionsSeenRequest: Encodable {
    let chat: String
    let ids: [Int64]
}

struct PublicGroupDto: Decodable, Identifiable {
    let id: String
    let name: String?
    let avatarUrl: String?
    let kind: String?
    enum CodingKeys: String, CodingKey {
        case id, name, kind
        case avatarUrl = "avatar_url"
    }
}

struct GroupsSearchResponse: Decodable { let groups: [PublicGroupDto]? }

struct GroupMemberDto: Decodable, Identifiable, Equatable {
    let username: String
    let displayName: String?
    let avatarUrl: String?
    let role: String?
    let status: String?
    /// Есть ли у участника своя копия ключа группы (с 2026-09-16).
    let hasKey: Bool?
    let verified: Bool?
    let title: String?
    let emojiStatus: String?
    var id: String { username }
    var shownName: String { (displayName?.isEmpty == false ? displayName : nil) ?? username }
    enum CodingKeys: String, CodingKey {
        case username, role, status, verified, title
        case emojiStatus = "emoji_status"
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case hasKey = "has_key"
    }
}

struct GroupInfoResponse: Decodable {
    let groupId: String?
    let name: String?
    let avatarUrl: String?
    let description: String?
    let members: [GroupMemberDto]?
    let isPublic: Bool?
    let inviteHash: String?
    let alias: String?
    let adminsOnly: Bool?
    let slowMode: Int?
    let kind: String?
    let subscribers: Int?
    let isProtected: Bool?
    let joinApproval: Bool?
    let joinRequests: Int?
    var isChannel: Bool { kind == "channel" }
    enum CodingKeys: String, CodingKey {
        case name, description, members, alias, kind, subscribers
        case isProtected = "protected"
        case joinApproval = "join_approval"
        case joinRequests = "join_requests"
        case groupId = "group_id"
        case avatarUrl = "avatar_url"
        case isPublic = "is_public"
        case inviteHash = "invite_hash"
        case adminsOnly = "admins_only"
        case slowMode = "slow_mode"
    }
}

// MARK: - Прочее

/// Ограничения сервера: запрашиваются при запуске, зашивать их нельзя.
struct LimitsResponse: Decodable {
    let maxUploadBytes: Int64?
    let maxPlainFileBytes: Int64?
    let minPasswordLength: Int?
    enum CodingKeys: String, CodingKey {
        case maxUploadBytes = "max_upload_bytes"
        case maxPlainFileBytes = "max_plain_file_bytes"
        case minPasswordLength = "min_password_length"
    }
}

struct LinkPreviewDto: Decodable {
    let title: String?
    let description: String?
    let image: String?
    let url: String?
}

struct DraftPutRequest: Encodable {
    let chat: String
    let content: String
}

struct DraftDto: Decodable {
    let chat: String
    let content: String?
    let updatedAt: String?
    enum CodingKeys: String, CodingKey {
        case chat, content
        case updatedAt = "updated_at"
    }
}

struct DraftsResponse: Decodable { let drafts: [DraftDto]? }

struct EmptyBody: Encodable {}

// MARK: - Стикеры

struct StickerDto: Decodable, Identifiable, Hashable {
    let id: Int64
    let fileUrl: String
    let emoji: String?
    enum CodingKeys: String, CodingKey {
        case id, emoji
        case fileUrl = "file_url"
    }
}

struct StickerSetDto: Decodable, Identifiable {
    let id: Int64
    let name: String
    let title: String
    let mine: Bool?
    let installed: Bool?
    var stickers: [StickerDto]
}

struct StickerSetsResponse: Decodable { let sets: [StickerSetDto]? }

struct StickerLookupResponse: Decodable { let name: String }

struct StickerSetCreateRequest: Encodable {
    let title: String
    let name: String
}

struct StickerAddRequest: Encodable {
    let fileUrl: String
    let emoji: String
    enum CodingKeys: String, CodingKey {
        case emoji
        case fileUrl = "file_url"
    }
}

// MARK: - Управление группой

struct MemberTitleRequest: Encodable {
    let groupId: String
    let targetUsername: String
    let title: String
    enum CodingKeys: String, CodingKey {
        case title
        case groupId = "group_id"
        case targetUsername = "target_username"
    }
}

/// Дополнительная ссылка-приглашение (routers/invites.py, invite_out).
struct InviteDto: Decodable, Identifiable {
    let id: Int64
    let token: String
    let title: String?
    let expiresAt: String?
    let usageLimit: Int?
    let usageCount: Int?
    let approval: Bool?
    /// active / expired / exhausted / revoked
    let state: String?
    var isActive: Bool { (state ?? "active") == "active" }
    enum CodingKeys: String, CodingKey {
        case id, token, title, approval, state
        case expiresAt = "expires_at"
        case usageLimit = "usage_limit"
        case usageCount = "usage_count"
    }
}

struct InvitesResponse: Decodable {
    let invites: [InviteDto]?
    let joinApproval: Bool?
    let requests: Int?
    enum CodingKeys: String, CodingKey {
        case invites, requests
        case joinApproval = "join_approval"
    }
}

struct InviteCreateRequest: Encodable {
    var title: String = ""
    /// Секунды; 0 — без срока.
    var expiresIn: Int = 0
    var usageLimit: Int?
    var approval: Bool = false
    enum CodingKeys: String, CodingKey {
        case title, approval
        case expiresIn = "expires_in"
        case usageLimit = "usage_limit"
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(expiresIn, forKey: .expiresIn)
        try c.encode(usageLimit, forKey: .usageLimit)
        try c.encode(approval, forKey: .approval)
    }
}

struct JoinRequestDto: Decodable, Identifiable {
    let username: String
    let name: String?
    let avatarUrl: String?
    let createdAt: String?
    /// Название ссылки, по которой подали заявку.
    let via: String?
    var id: String { username }
    enum CodingKeys: String, CodingKey {
        case username, name, via
        case avatarUrl = "avatar_url"
        case createdAt = "created_at"
    }
}

struct JoinRequestsResponse: Decodable { let requests: [JoinRequestDto]? }

/// Запись журнала администраторов (routers/admin_log.py).
struct AdminLogItem: Decodable, Identifiable {
    let id: Int64
    let action: String
    let createdAt: String?
    let actor: String?
    let actorName: String?
    let target: String?
    let targetName: String?
    let details: JSONValue?
    enum CodingKeys: String, CodingKey {
        case id, action, actor, target, details
        case createdAt = "created_at"
        case actorName = "actor_name"
        case targetName = "target_name"
    }
}

struct AdminLogResponse: Decodable {
    let items: [AdminLogItem]?
    let hasMore: Bool?
    enum CodingKeys: String, CodingKey {
        case items
        case hasMore = "has_more"
    }
}

// MARK: - Темы

/// Тема форума (list_topics в routers/topics.py); id 0 — «Общее».
struct ForumTopicDto: Decodable, Identifiable {
    let id: Int64
    let title: String
    let icon: String?
    let closed: Bool?
    let general: Bool?
    let createdBy: String?
    let lastMsg: MessageDto?
    /// Время последнего сообщения (поле time у last_msg).
    let lastTime: String?
    let unread: Int?
    var topic: ForumTopic {
        ForumTopic(id: id, title: title, icon: icon ?? "", closed: closed ?? false, general: general ?? false)
    }
    enum CodingKeys: String, CodingKey {
        case id, title, icon, closed, general, unread
        case createdBy = "created_by"
        case lastMsg = "last_msg"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        icon = try? c.decodeIfPresent(String.self, forKey: .icon)
        closed = try? c.decodeIfPresent(Bool.self, forKey: .closed)
        general = try? c.decodeIfPresent(Bool.self, forKey: .general)
        createdBy = try? c.decodeIfPresent(String.self, forKey: .createdBy)
        lastMsg = try? c.decodeIfPresent(MessageDto.self, forKey: .lastMsg)
        lastTime = (try? c.decodeIfPresent(JSONValue.self, forKey: .lastMsg))??["time"]?.stringValue
        unread = try? c.decodeIfPresent(Int.self, forKey: .unread)
    }
}

/// Открытая тема — для маршрута и экрана переписки.
struct ForumTopic: Hashable {
    let id: Int64
    var title: String
    var icon: String
    var closed: Bool
    var general: Bool
}

struct TopicsResponse: Decodable {
    let forum: Bool?
    let canManage: Bool?
    let canCreate: Bool?
    let topics: [ForumTopicDto]?
    enum CodingKeys: String, CodingKey {
        case forum, topics
        case canManage = "can_manage"
        case canCreate = "can_create"
    }
}

struct ForumToggleRequest: Encodable { let enabled: Bool }

struct TopicCreateRequest: Encodable {
    let title: String
    let icon: String
}

/// Правка темы: только заданные поля.
struct TopicUpdateRequest: Encodable {
    var title: String?
    var icon: String?
    var closed: Bool?
}

// MARK: - История аватаров (routers/avatars.py)

struct AvatarHistoryItem: Decodable, Hashable {
    let url: String
    /// Когда поставлен; nil — поставлен до истории.
    let setAt: String?
    enum CodingKeys: String, CodingKey {
        case url
        case setAt = "set_at"
    }
}

struct AvatarsResponse: Decodable { let avatars: [AvatarHistoryItem]? }

// MARK: - Вход по QR-коду (routers/qrlogin.py)

struct QrStartRequest: Encodable { let pub: String }

struct QrStartResponse: Decodable {
    let session: String
    let secret: String
    let expiresIn: Int?
    enum CodingKeys: String, CodingKey {
        case session, secret
        case expiresIn = "expires_in"
    }
}

struct QrPollRequest: Encodable {
    let session: String
    let secret: String
}

/// pending / denied / approved (с токеном и ключом).
struct QrPollResponse: Decodable {
    let status: String
    let username: String?
    let originalUsername: String?
    let kdfSalt: String?
    let kdfIterations: Int?
    let accessToken: String?
    let payload: String?
    let approverPub: String?
    enum CodingKeys: String, CodingKey {
        case status, username, payload
        case originalUsername = "original_username"
        case kdfSalt = "kdf_salt"
        case kdfIterations = "kdf_iterations"
        case accessToken = "access_token"
        case approverPub = "approver_pub"
    }
}

struct QrInfoResponse: Decodable {
    let device: String?
    let ip: String?
}

struct QrApproveRequest: Encodable {
    let session: String
    let pub: String
    let approverPub: String
    let payload: String
    enum CodingKeys: String, CodingKey {
        case session, pub, payload
        case approverPub = "approver_pub"
    }
}

struct QrSessionRequest: Encodable { let session: String }
