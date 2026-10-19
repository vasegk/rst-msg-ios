import Foundation

/// Конверт сообщения. Шифруется целиком и кладётся в content вместо простого текста
/// (веб: crypto.js packContent / unpackContent):
///
/// - вложение: {"__rst":1,"t":"подпись","k":"<ключ файла>","n":"имя","m":"mime","a":"альбом","h":1}
/// - опрос/чек-лист: {"__rst":1,"t":"📊 Вопрос","p":{"q":"Вопрос","o":["Да","Нет"],"k":"c"}}
/// - ответ на историю: {"__rst":1,"t":"текст","s":{"a":"автор","id":5,"th":"data:image/jpeg;base64,..."}}
/// - ответ цитатой: {"__rst":1,"t":"текст","q":"фрагмент"}
/// - геопозиция в реальном времени: {"__rst":1,"t":"📍 …","g":{...}}
/// - контакт: "c":{"u":"ник","n":"Имя"}; история правок: "e":[{"t","at"}];
///   напоминание: "r":{"c","i","n"}; ответ из другого чата: "x":{"a","t","n"}
///
/// Все поля, кроме __rst, необязательны. Незнакомые поля сохраняются как есть
/// и уходят обратно при правке — иначе правка из iOS стирала бы то, что
/// добавил более новый веб.
struct Envelope: Equatable {
    static let version = 1

    var text: String = ""
    var fileKeyB64: String?
    var fileName: String?
    var mimeType: String?
    var poll: PollBody?
    var story: StoryRef?
    var quote: String?
    var geo: LiveGeo?
    /// Альбом: общее у вложений, отправленных вместе.
    var album: String?
    /// Фото/видео под спойлером: размыто, пока не нажмут.
    var spoiler = false
    var contact: ContactRef?
    /// Прежние версии текста, старые первыми, не больше 10.
    var edits: [EditVersion] = []
    var remind: RemindRef?
    var crossReply: CrossReply?
    /// Поля, которых этот клиент не знает.
    var unknown: [String: JSONValue] = [:]

    var hasFile: Bool { !(fileKeyB64 ?? "").isEmpty }

    private static let knownKeys: Set<String> = ["__rst", "t", "k", "n", "m", "p", "s", "q", "g", "a", "h", "c", "e", "r", "x"]
    static let quoteMax = 500
    static let editsMax = 10

    init(text: String = "", fileKeyB64: String? = nil, fileName: String? = nil, mimeType: String? = nil,
         poll: PollBody? = nil, story: StoryRef? = nil, quote: String? = nil, geo: LiveGeo? = nil) {
        self.text = text
        self.fileKeyB64 = fileKeyB64
        self.fileName = fileName
        self.mimeType = mimeType
        self.poll = poll
        self.story = story
        self.quote = quote
        self.geo = geo
    }

    /// Нужен ли конверт вообще: простой текст без вложения и метаданных
    /// уходит строкой, как в вебе.
    var isPlainText: Bool {
        !hasFile && poll == nil && story == nil && (quote ?? "").isEmpty && geo == nil && contact == nil
            && edits.isEmpty && remind == nil && crossReply == nil && unknown.isEmpty
    }

    // MARK: - Разбор

    /// Разбирает расшифрованный content. Строка, не являющаяся конвертом, —
    /// обычное текстовое сообщение (старый формат), тогда nil.
    static func parse(_ decrypted: String) -> Envelope? {
        let trimmed = decrypted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("&") else { return nil }
        if let env = decode(trimmed) { return env }
        // Содержимое могло пройти через преобразование HTML-сущностей на стороне веба
        if trimmed.contains("&") { return decode(HtmlEntities.unescape(trimmed)) }
        return nil
    }

    private static func decode(_ value: String) -> Envelope? {
        // Признак конверта обязателен: без него {"a":1} в обычном тексте
        // разобрался бы как конверт.
        guard let object = JSONValue.parse(value)?.object, object["__rst"]?.int == version else { return nil }
        return Envelope(object: object)
    }

    /// Разбор снисходительный: кривое поле не роняет весь конверт.
    init(object o: [String: JSONValue]) {
        text = o["t"]?.stringValue ?? ""
        fileKeyB64 = o["k"]?.stringValue
        fileName = o["n"]?.stringValue
        mimeType = o["m"]?.stringValue
        poll = o["p"].flatMap { PollBody(json: $0) }
        story = o["s"].flatMap { StoryRef(json: $0) }
        if let q = o["q"]?.stringValue, !q.isEmpty { quote = String(q.prefix(Self.quoteMax)) }
        geo = o["g"].flatMap { LiveGeo(json: $0) }
        if let a = o["a"]?.stringValue, a.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil {
            album = a
        }
        spoiler = o["h"]?.int == 1
        contact = o["c"].flatMap { ContactRef(json: $0) }
        let versions = (o["e"]?.array ?? []).compactMap { EditVersion(json: $0) }
        edits = Array(versions.suffix(Self.editsMax))
        remind = o["r"].flatMap { RemindRef(json: $0) }
        crossReply = o["x"].flatMap { CrossReply(json: $0) }
        unknown = o.filter { !Self.knownKeys.contains($0.key) }
    }

    // MARK: - Сборка

    var jsonObject: [String: JSONValue] {
        var o = unknown
        o["__rst"] = .number(Double(Self.version))
        o["t"] = .string(text)
        if let fileKeyB64 { o["k"] = .string(fileKeyB64) }
        if let fileName { o["n"] = .string(fileName) }
        if let mimeType { o["m"] = .string(mimeType) }
        if let poll { o["p"] = poll.json }
        if let story { o["s"] = story.json }
        if let quote, !quote.isEmpty { o["q"] = .string(quote) }
        if let geo { o["g"] = geo.json }
        if let album { o["a"] = .string(album) }
        if spoiler { o["h"] = .number(1) }
        if let contact { o["c"] = contact.json }
        if !edits.isEmpty { o["e"] = .array(edits.suffix(Self.editsMax).map { $0.json }) }
        if let remind { o["r"] = remind.json }
        if let crossReply { o["x"] = crossReply.json }
        return o
    }

    var json: String { JSONCoding.encodeString(JSONValue.object(jsonObject)) }

    /// Правка: новый текст, прежний — в историю правок (как веб, edit-history.js).
    /// Всё остальное — ключ файла, альбом, спойлер, цитата, ответ из другого
    /// чата и незнакомые поля — сохраняется.
    func edited(newText: String, previousText: String, at date: Date = Date()) -> Envelope {
        var copy = self
        if previousText != newText {
            copy.edits.append(EditVersion(text: String(previousText.prefix(4096)),
                                          at: Int64(date.timeIntervalSince1970 * 1000)))
            copy.edits = Array(copy.edits.suffix(Self.editsMax))
        }
        copy.text = newText
        return copy
    }
}

/// Вопрос и варианты опроса — шифруются, сервер знает только их число.
/// k = "c" — чек-лист (с 2026-10-18).
struct PollBody: Equatable {
    var question: String
    var options: [String]
    var isChecklist = false

    init(question: String, options: [String], isChecklist: Bool = false) {
        self.question = question
        self.options = options
        self.isChecklist = isChecklist
    }

    init?(json: JSONValue) {
        guard let o = json.object else { return nil }
        question = o["q"]?.stringValue ?? ""
        options = (o["o"]?.array ?? []).compactMap { $0.stringValue }
        isChecklist = o["k"]?.stringValue == "c"
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["q": .string(question), "o": .array(options.map { .string($0) })]
        if isChecklist { o["k"] = .string("c") }
        return .object(o)
    }
}

/// Ссылка на историю в личном ответе на неё. th — необязательная миниатюра;
/// показывать только data:image/(jpeg|png|webp);base64.
struct StoryRef: Equatable {
    var author: String
    var id: Int64
    var thumbnail: String?

    init(author: String, id: Int64, thumbnail: String?) {
        self.author = author
        self.id = id
        self.thumbnail = thumbnail
    }

    init?(json: JSONValue) {
        guard let o = json.object else { return nil }
        author = o["a"]?.stringValue ?? ""
        id = o["id"]?.int64 ?? 0
        thumbnail = o["th"]?.stringValue
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["a": .string(author), "id": .number(Double(id))]
        if let thumbnail { o["th"] = .string(thumbnail) }
        return .object(o)
    }

    var safeThumbnail: String? {
        guard let th = thumbnail,
              th.range(of: "^data:image/(jpeg|png|webp);base64,", options: .regularExpression) != nil else { return nil }
        return th
    }
}

/// Точка трансляции местоположения: until и ts — миллисекунды эпохи,
/// stopped — последняя точка (трансляцию остановили или вышел срок).
struct LiveGeo: Equatable {
    var lat: Double
    var lon: Double
    var acc: Double?
    var until: Int64
    var ts: Int64
    var stopped: Bool?

    init(lat: Double, lon: Double, acc: Double?, until: Int64, ts: Int64, stopped: Bool?) {
        self.lat = lat
        self.lon = lon
        self.acc = acc
        self.until = until
        self.ts = ts
        self.stopped = stopped
    }

    init?(json: JSONValue) {
        guard let o = json.object, let lat = o["lat"]?.double, let lon = o["lon"]?.double else { return nil }
        self.lat = lat
        self.lon = lon
        acc = o["acc"]?.double
        until = o["until"]?.int64 ?? 0
        ts = o["ts"]?.int64 ?? 0
        stopped = o["stopped"]?.bool
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["lat": .number(lat), "lon": .number(lon),
                                      "until": .number(Double(until)), "ts": .number(Double(ts))]
        if let acc { o["acc"] = .number(acc) }
        if let stopped { o["stopped"] = .bool(stopped) }
        return .object(o)
    }

    func isActive(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Bool {
        !(stopped ?? false) && nowMs < until
    }
}

/// Карточка контакта: {"u":"ник","n":"Имя"}; ник [A-Za-z0-9_-]{1,64}, иначе не карточка.
struct ContactRef: Equatable {
    var username: String
    var name: String

    init(username: String, name: String) {
        self.username = username
        self.name = String(name.prefix(64))
    }

    init?(json: JSONValue) {
        guard let o = json.object, let u = o["u"]?.stringValue,
              u.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else { return nil }
        username = u
        name = String((o["n"]?.stringValue ?? "").prefix(64))
    }

    var json: JSONValue { .object(["u": .string(username), "n": .string(name)]) }
}

/// Прежняя версия текста: at — миллисекунды эпохи (0, если не число).
struct EditVersion: Equatable {
    var text: String
    var at: Int64

    init(text: String, at: Int64) {
        self.text = text
        self.at = at
    }

    init?(json: JSONValue) {
        guard let o = json.object, let t = o["t"]?.stringValue else { return nil }
        text = String(t.prefix(4096))
        at = o["at"]?.int64 ?? 0
    }

    var json: JSONValue { .object(["t": .string(text), "at": .number(Double(at))]) }
    var date: Date? { at > 0 ? Date(timeIntervalSince1970: Double(at) / 1000) : nil }
}

/// Напоминание в Избранном: из какого чата (c) и какое сообщение (i), имя чата (n).
struct RemindRef: Equatable {
    var chat: String
    var messageId: Int64
    var name: String

    init(chat: String, messageId: Int64, name: String) {
        self.chat = chat
        self.messageId = messageId
        self.name = String(name.prefix(64))
    }

    init?(json: JSONValue) {
        guard let o = json.object, let c = o["c"]?.stringValue,
              c.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil else { return nil }
        chat = c
        let i = o["i"]?.int64 ?? 0
        messageId = i > 0 ? i : 0
        name = String((o["n"]?.stringValue ?? "").prefix(64))
    }

    var json: JSONValue { .object(["c": .string(chat), "i": .number(Double(messageId)), "n": .string(name)]) }
}

/// Ответ на сообщение из другого чата: автор, текст, имя исходного чата
/// (пустое — «из другого чата»). Номеров нет — собеседник исходник не прочтёт.
struct CrossReply: Equatable {
    var author: String
    var text: String
    var chatName: String

    init(author: String, text: String, chatName: String) {
        self.author = String(author.prefix(64))
        self.text = text.count > 300 ? String(text.prefix(300)) + "…" : text
        self.chatName = String(chatName.prefix(64))
    }

    init?(json: JSONValue) {
        guard let o = json.object, let t = o["t"]?.stringValue else { return nil }
        author = String((o["a"]?.stringValue ?? "").prefix(64))
        text = String(t.prefix(301))
        chatName = String((o["n"]?.stringValue ?? "").prefix(64))
    }

    var json: JSONValue { .object(["a": .string(author), "t": .string(text), "n": .string(chatName)]) }
}

/// Результат расшифровки content: либо простой текст, либо конверт.
enum DecryptedContent: Equatable {
    case text(String)
    case enveloped(Envelope)
    /// Сообщение не расшифровалось — показываем заглушку, а не падаем.
    case undecryptable

    /// Текст для превью и цитаты: подпись, иначе карточка, имя файла или вопрос опроса.
    var previewText: String {
        switch self {
        case .text(let t): return t
        case .enveloped(let e):
            if !e.text.trimmingCharacters(in: .whitespaces).isEmpty { return e.text }
            if let c = e.contact { return "👤 \(c.name) (@\(c.username))" }
            return e.poll?.question ?? e.fileName ?? ""
        case .undecryptable: return ""
        }
    }
}
