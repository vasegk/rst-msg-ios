import Foundation

/// Конверт сообщения. Шифруется целиком и кладётся в content вместо простого текста:
///
/// - вложение: {"__rst":1,"t":"подпись","k":"<ключ файла>","n":"имя","m":"mime"}
/// - опрос:    {"__rst":1,"t":"📊 Вопрос","p":{"q":"Вопрос","o":["Да","Нет"]}}
/// - ответ на историю: {"__rst":1,"t":"текст","s":{"a":"автор","id":5,"th":"data:image/jpeg;base64,..."}}
/// - ответ цитатой: {"__rst":1,"t":"текст","q":"фрагмент"}
/// - геопозиция в реальном времени: {"__rst":1,"t":"📍 …","g":{...}}
///
/// Все поля, кроме __rst, необязательны, а незнакомые игнорируются: так
/// клиент, не знающий о новом виде конверта, покажет хотя бы текст t.
struct Envelope: Codable, Equatable {
    static let version = 1

    var text: String = ""
    var fileKeyB64: String?
    var fileName: String?
    var mimeType: String?
    var poll: PollBody?
    var story: StoryRef?
    var quote: String?
    var geo: LiveGeo?

    var hasFile: Bool { !(fileKeyB64 ?? "").isEmpty }

    enum CodingKeys: String, CodingKey {
        case version = "__rst"
        case text = "t"
        case fileKeyB64 = "k"
        case fileName = "n"
        case mimeType = "m"
        case poll = "p"
        case story = "s"
        case quote = "q"
        case geo = "g"
    }

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

    /// Разбор снисходительный: кривое поле не роняет весь конверт.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = (try? c.decode(Int.self, forKey: .version)) ?? 0
        guard v == Envelope.version else {
            throw CryptoError("Неизвестная версия конверта")
        }
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        fileKeyB64 = try? c.decodeIfPresent(String.self, forKey: .fileKeyB64)
        fileName = try? c.decodeIfPresent(String.self, forKey: .fileName)
        mimeType = try? c.decodeIfPresent(String.self, forKey: .mimeType)
        poll = try? c.decodeIfPresent(PollBody.self, forKey: .poll)
        story = try? c.decodeIfPresent(StoryRef.self, forKey: .story)
        quote = try? c.decodeIfPresent(String.self, forKey: .quote)
        geo = try? c.decodeIfPresent(LiveGeo.self, forKey: .geo)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Envelope.version, forKey: .version)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(fileKeyB64, forKey: .fileKeyB64)
        try c.encodeIfPresent(fileName, forKey: .fileName)
        try c.encodeIfPresent(mimeType, forKey: .mimeType)
        try c.encodeIfPresent(poll, forKey: .poll)
        try c.encodeIfPresent(story, forKey: .story)
        try c.encodeIfPresent(quote, forKey: .quote)
        try c.encodeIfPresent(geo, forKey: .geo)
    }

    var json: String { JSONCoding.encodeString(self) }

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
        let data = Data(value.utf8)
        // Признак конверта обязателен: без него {"a":1} в обычном тексте
        // разобрался бы как конверт.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["__rst"] != nil else { return nil }
        return try? JSONDecoder().decode(Envelope.self, from: data)
    }
}

/// Вопрос и варианты опроса — шифруются, сервер знает только их число.
struct PollBody: Codable, Equatable {
    var question: String
    var options: [String]

    enum CodingKeys: String, CodingKey {
        case question = "q"
        case options = "o"
    }

    init(question: String, options: [String]) {
        self.question = question
        self.options = options
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        question = (try? c.decode(String.self, forKey: .question)) ?? ""
        options = (try? c.decode([String].self, forKey: .options)) ?? []
    }
}

/// Ссылка на историю в личном ответе на неё. th — необязательная миниатюра;
/// показывать только data:image/(jpeg|png|webp);base64.
struct StoryRef: Codable, Equatable {
    var author: String
    var id: Int64
    var thumbnail: String?

    enum CodingKeys: String, CodingKey {
        case author = "a"
        case id
        case thumbnail = "th"
    }

    init(author: String, id: Int64, thumbnail: String?) {
        self.author = author
        self.id = id
        self.thumbnail = thumbnail
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        author = (try? c.decode(String.self, forKey: .author)) ?? ""
        id = (try? c.decode(Int64.self, forKey: .id)) ?? 0
        thumbnail = try? c.decodeIfPresent(String.self, forKey: .thumbnail)
    }

    var safeThumbnail: String? {
        guard let th = thumbnail,
              th.range(of: "^data:image/(jpeg|png|webp);base64,", options: .regularExpression) != nil else { return nil }
        return th
    }
}

/// Точка трансляции местоположения: until и ts — миллисекунды эпохи,
/// stopped — последняя точка (трансляцию остановили или вышел срок).
struct LiveGeo: Codable, Equatable {
    var lat: Double
    var lon: Double
    var acc: Double?
    var until: Int64
    var ts: Int64
    var stopped: Bool?

    func isActive(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Bool {
        !(stopped ?? false) && nowMs < until
    }
}

/// Результат расшифровки content: либо простой текст, либо конверт.
enum DecryptedContent: Equatable {
    case text(String)
    case enveloped(Envelope)
    /// Сообщение не расшифровалось — показываем заглушку, а не падаем.
    case undecryptable

    /// Текст для превью и цитаты: подпись, иначе имя файла или вопрос опроса.
    var previewText: String {
        switch self {
        case .text(let t): return t
        case .enveloped(let e):
            if !e.text.trimmingCharacters(in: .whitespaces).isEmpty { return e.text }
            return e.poll?.question ?? e.fileName ?? ""
        case .undecryptable: return ""
        }
    }
}
