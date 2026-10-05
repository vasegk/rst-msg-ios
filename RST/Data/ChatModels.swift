import Foundation

/// Сообщение в том виде, в каком его показывает экран переписки:
/// содержимое уже расшифровано, конверт разобран.
struct ChatMessage: Identifiable, Equatable {
    var id: Int64
    var sender: String
    var isMine: Bool
    var text: String
    var attachment: Attachment?
    /// sent или read; для своих сообщений рисуем галочки.
    var status: String?
    /// имя пользователя -> эмодзи
    var reactions: [String: String] = [:]
    var isEdited = false
    var reply: ReplyPreview?
    var isPinned = false
    var forwardedFrom: String?
    var createdAt: Date?
    /// Не расшифровалось — заглушка вместо текста.
    var undecryptable = false
    /// Служебная запись: события группы, письмо поддержки, пропущенный звонок.
    var isSystem = false
    var poll: Poll?
    var expiresAt: Date?
    var played = true
    var quote: String?
    var isAutoreply = false
    var stickerUrl: String?
    var live: LiveGeo?
    var storyRef: StoryRef?
    /// Ждёт отправки (нет связи) — рисуется с часиками.
    var pending = false

    var isRead: Bool { status == "read" }
}

/// Вложение. Ключ файла живёт в конверте внутри зашифрованного content —
/// здесь он уже в открытом виде, но только в памяти процесса.
struct Attachment: Equatable {
    var fileUrl: String
    var fileKeyB64: String
    var fileName: String
    var mimeType: String

    var isImage: Bool { mimeType.hasPrefix("image/") }
    var isAudio: Bool { mimeType.hasPrefix("audio/") }
    var isVideo: Bool { mimeType.hasPrefix("video/") }
}

struct ReplyPreview: Equatable {
    var messageId: Int64
    var sender: String
    var text: String
    var undecryptable = false
}

/// Опрос: вопрос и варианты расшифрованы из конверта, состояние — от сервера.
struct Poll: Equatable {
    var question: String
    var options: [String]
    var state: PollState

    /// Результаты показываем после своего голоса или после завершения.
    var showResults: Bool { state.closed || !state.my.isEmpty }
}

struct PollState: Equatable {
    var options = 0
    var multiple = false
    var anonymous = true
    var closed = false
    var counts: [Int] = []
    var voters = 0
    var my: [Int] = []
    var quiz = false
    var correct: Int?

    init(options: Int) { self.options = options }

    init?(_ raw: JSONValue?) {
        guard let raw, raw.object != nil else { return nil }
        options = raw["options"]?.int ?? 0
        multiple = raw["multiple"]?.bool ?? false
        anonymous = raw["anonymous"]?.bool ?? true
        closed = raw["closed"]?.bool ?? false
        counts = raw["counts"]?.array?.compactMap { $0.int } ?? []
        voters = raw["voters"]?.int ?? 0
        my = raw["my"]?.array?.compactMap { $0.int } ?? []
        quiz = raw["quiz"]?.bool ?? false
        correct = raw["correct"]?.int
    }
}

/// Строка списка чатов — общий вид для личных переписок и групп.
struct ChatSummary: Identifiable, Equatable {
    /// Имя собеседника или group_<id> — годится и для адреса, и для receiver.
    var chatId: String
    var title: String
    var avatarUrl: String?
    var unread: Int
    var online: Bool
    var isGroup: Bool
    var lastMsg: LastMessageDto?
    var muted = false
    var pinned = false
    var archived = false
    var markedUnread = false
    /// online, dnd, offline, deleted — только у людей.
    var status: String?
    var lastSeen: String?
    var isSystem = false
    var bio: String?
    var verified = false
    var adminsOnly = false
    var slowMode = 0
    var myRole = "member"
    var isChannel = false
    var isForum = false

    var id: String { chatId }
    var isDeleted: Bool { status == "deleted" }

    /// Писать в группу «только для администраторов» могут owner, admin, editor.
    var canWrite: Bool {
        if isSystem || isDeleted { return false }
        if isGroup && adminsOnly { return ["owner", "admin", "editor"].contains(myRole) }
        return true
    }

    var isAdmin: Bool { ["owner", "admin"].contains(myRole) }

    /// Свежесть для сортировки: id последнего сообщения монотонный.
    var activity: Int64 { lastMsg?.id ?? -1 }

    init(user u: ContactUserDto) {
        chatId = u.username
        title = u.displayName
        avatarUrl = u.avatarUrl
        unread = u.unread ?? 0
        online = u.online ?? false
        isGroup = false
        lastMsg = u.lastMsg
        muted = u.muted ?? false
        pinned = u.pinned ?? false
        archived = u.archived ?? false
        markedUnread = u.markedUnread ?? false
        status = u.status
        lastSeen = u.lastSeen
        isSystem = u.isSystem ?? false
        bio = u.bio
        verified = u.verified ?? false
    }

    init(group g: ContactGroupDto) {
        chatId = g.id
        title = (g.name?.isEmpty == false ? g.name : nil) ?? g.id
        avatarUrl = g.avatarUrl
        unread = g.unread ?? 0
        online = false
        isGroup = true
        lastMsg = g.lastMsg
        muted = g.muted ?? false
        pinned = g.pinned ?? false
        archived = g.archived ?? false
        markedUnread = g.markedUnread ?? false
        adminsOnly = g.adminsOnly ?? false
        slowMode = g.slowMode ?? 0
        myRole = g.myRole ?? "member"
        isChannel = g.kind == "channel"
        isForum = g.forum ?? false
    }
}

/// Одна строка превью — для списка чатов, закрепа, цитаты и уведомления.
/// Разметка снимается (спойлер становится ▒▒▒▒), переводы строк — пробелы.
enum Previews {
    static let undecryptable = "🔒 Зашифрованное сообщение"
    static let videoNote = "📹 Видеосообщение"
    static let voiceText = "🎤 Голосовое сообщение"
    private static let serviceTexts: Set<String> = [
        videoNote, voiceText, "📎 Вложение", "Вложение", "Изображение", "Вложенный документ", "Прикрепленный файл",
    ]

    static func describe(_ content: DecryptedContent, fileType: String? = nil) -> String {
        switch content {
        case .text(let t):
            if fileType == MessageDto.fileTypeSticker { return oneLine(t) }
            let line = oneLine(TextFormat.strip(t))
            return line.isEmpty ? fallback(fileType) : line
        case .enveloped(let e):
            return describe(e)
        case .undecryptable:
            return undecryptable
        }
    }

    static func describe(_ envelope: Envelope) -> String {
        let text = oneLine(TextFormat.strip(envelope.text))
        if let poll = envelope.poll { return text.isEmpty ? "📊 " + poll.question : text }
        if envelope.hasFile { return withLabel(fileLabel(envelope.mimeType, envelope.fileName, text: text), text, envelope.fileName) }
        return text
    }

    static func describe(_ message: ChatMessage) -> String {
        if message.isSystem { return oneLine(message.text) }
        if message.undecryptable { return undecryptable }
        if let poll = message.poll { return "📊 " + poll.question }
        if let a = message.attachment {
            let text = oneLine(TextFormat.strip(message.text))
            return withLabel(fileLabel(a.mimeType, a.fileName, text: text), text, a.fileName)
        }
        return oneLine(TextFormat.strip(message.text))
    }

    /// Системная запись — открытый текст; у письма поддержки первая строка — заголовок.
    static func system(_ content: String?) -> String {
        oneLine((content ?? "").components(separatedBy: "\n").first ?? "")
    }

    static func fileLabel(_ mime: String?, _ name: String?, text: String = "") -> String {
        guard let mime else { return "📎 \(name ?? "Файл")" }
        if mime.hasPrefix("image/") { return "📷 Фото" }
        if mime.hasPrefix("video/") && text == videoNote { return videoNote }
        if mime.hasPrefix("video/") { return "📹 Видео" }
        if mime.hasPrefix("audio/") { return "🎤 Голосовое" }
        return "📎 \(name ?? "Файл")"
    }

    private static func withLabel(_ label: String, _ text: String, _ fileName: String?) -> String {
        if text.trimmingCharacters(in: .whitespaces).isEmpty || text == label || serviceTexts.contains(text) || text == fileName {
            return label
        }
        return "\(label) \(text)"
    }

    private static func fallback(_ fileType: String?) -> String {
        switch fileType {
        case nil: return ""
        case "system"?: return "Системное сообщение"
        default: return "Вложение"
        }
    }

    static func oneLine(_ text: String) -> String {
        TextFormat.replace(text, try! NSRegularExpression(pattern: #"\s*\n\s*"#)) { _ in " " }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Время сервера: ISO-8601 с «Z», со смещением или без пояса (тогда UTC).
enum ServerTime {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ raw: String?) -> Date? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: " ", with: "T")
        let hasZone = s.hasSuffix("Z") || s.range(of: #"[+-]\d\d:?\d\d$"#, options: .regularExpression) != nil
        if !hasZone { s += "Z" }
        // Дробная часть длиннее миллисекунд ISO8601DateFormatter не понимает — режем
        if let dot = s.firstIndex(of: "."), let zoneStart = s[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let fraction = s[s.index(after: dot)..<zoneStart]
            if fraction.count > 3 {
                let head: String = String(s[..<s.index(after: dot)])
                let millis: String = String(fraction.prefix(3))
                let zone: String = String(s[zoneStart...])
                s = head + millis + zone
            }
        }
        return withFraction.date(from: s) ?? plain.date(from: s)
    }

    static func iso(_ date: Date) -> String { withFraction.string(from: date) }
}
