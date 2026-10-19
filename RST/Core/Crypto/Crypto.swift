import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Ошибка криптографии: нерасшифровываемое — штатная ситуация, а не падение.
struct CryptoError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Криптографические примитивы, совместимые с WebCrypto веб-клиента RST.
///
/// Ничего из этого файла нельзя менять «по вкусу»: любое расхождение с браузером
/// означает, что сообщения перестанут читаться на одной из платформ.
enum RstCrypto {

    /// Число итераций для новых аккаунтов (с 2026-09-15). Старые аккаунты
    /// выведены со 100 000 — сервер отдаёт фактическое значение в
    /// kdf_iterations при входе, зашивать его нельзя.
    static let kdfIterations = 600_000

    /// Значение для аккаунтов, созданных до перехода.
    static let legacyKdfIterations = 100_000
    static let gcmIVBytes = 12
    static let gcmTagBytes = 16

    // MARK: - Случайность

    static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        precondition(status == errSecSuccess, "Генератор случайных чисел недоступен")
        return data
    }

    // MARK: - PBKDF2

    /// KEK из пароля: PBKDF2-HMAC-SHA256, соль — UTF-8 байты строки kdf_salt,
    /// 256 бит. Пароль кодируется в UTF-8, как в WebCrypto.
    static func deriveKek(password: String, kdfSalt: String, iterations: Int) -> SymmetricKey {
        let bits = pbkdf2SHA256(
            password: Data(password.utf8),
            salt: Data(kdfSalt.utf8),
            iterations: iterations,
            length: 32
        )
        return SymmetricKey(data: bits)
    }

    static func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, length: Int) -> Data {
        var out = Data(count: length)
        let status = out.withUnsafeMutableBytes { outBuffer -> Int32 in
            password.withUnsafeBytes { passwordBuffer -> Int32 in
                salt.withUnsafeBytes { saltBuffer -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.baseAddress?.assumingMemoryBound(to: CChar.self),
                        password.count,
                        saltBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        outBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        length
                    )
                }
            }
        }
        precondition(Int(status) == kCCSuccess, "PBKDF2 завершился с ошибкой \(status)")
        return out
    }

    // MARK: - AES-GCM

    static func aesKey(_ raw: Data) throws -> SymmetricKey {
        guard raw.count == 32 else {
            throw CryptoError("Ожидается ключ AES-256 (32 байта), получено \(raw.count)")
        }
        return SymmetricKey(data: raw)
    }

    static func randomAesKey() -> SymmetricKey { SymmetricKey(data: randomBytes(32)) }

    /// Шифрует и возвращает пару (iv, ciphertext||tag) — ровно как WebCrypto.
    static func encrypt(key: SymmetricKey, plaintext: Data) throws -> (iv: Data, ciphertext: Data) {
        let iv = randomBytes(gcmIVBytes)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: iv))
        return (iv, box.ciphertext + box.tag)
    }

    /// ciphertext — шифротекст с тегом в конце, как отдаёт WebCrypto.
    static func decrypt(key: SymmetricKey, iv: Data, ciphertext: Data) throws -> Data {
        guard iv.count == gcmIVBytes else { throw CryptoError("IV должен быть 12 байт") }
        guard ciphertext.count >= gcmTagBytes else { throw CryptoError("Шифротекст короче тега") }
        let body = Data(ciphertext.prefix(ciphertext.count - gcmTagBytes))
        let tag = Data(ciphertext.suffix(gcmTagBytes))
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: body, tag: tag)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw CryptoError("Не удалось расшифровать")
        }
    }

    // MARK: - Упаковка {"iv":"...","ciphertext":"..."}

    /// Шифрует текст и упаковывает в строку, которая кладётся в поле content.
    static func encryptToPacked(key: SymmetricKey, plaintext: String) throws -> String {
        let (iv, ct) = try encrypt(key: key, plaintext: Data(plaintext.utf8))
        return PackedCiphertext(iv: iv.base64EncodedString(), ciphertext: ct.base64EncodedString()).json
    }

    /// Разбирает упакованную строку и расшифровывает её в текст.
    static func decryptPacked(key: SymmetricKey, packed: String) throws -> String {
        guard let p = PackedCiphertext.parse(packed),
              let iv = Data(base64Encoded: p.iv),
              let ct = Data(base64Encoded: p.ciphertext) else {
            throw CryptoError("Строка не является упакованным шифротекстом")
        }
        let plain = try decrypt(key: key, iv: iv, ciphertext: ct)
        guard let text = String(data: plain, encoding: .utf8) else {
            throw CryptoError("Расшифрованное — не текст UTF-8")
        }
        return text
    }

    // MARK: - Ключ группы

    /// Прежняя (небезопасная) схема группового ключа:
    /// SHA-256(UTF-8("group_<id>_rst_group_salt")).
    ///
    /// Номер группы известен серверу, значит сервер способен вывести этот ключ.
    /// Поддерживается только ради читаемости старой переписки; шифровать им
    /// можно лишь тогда, когда настоящего ключа у группы нет ни у кого.
    static func legacyGroupKey(groupId: String) -> SymmetricKey {
        SymmetricKey(data: sha256(Data("group_\(groupId)_rst_group_salt".utf8)))
    }

    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    /// Та же форма соли, что выдаёт регистрация на сервере: 32 hex-символа.
    static func newKdfSalt() -> String { randomBytes(16).hexString }
}

extension SymmetricKey {
    var rawData: Data { withUnsafeBytes { Data($0) } }
}

extension Data {
    /// base64url без паддинга — формат полей JWK (x, y, d).
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

/// Транспортная обёртка шифротекста: {"iv":"<base64>","ciphertext":"<base64>"}.
/// В этом виде лежат и content сообщения, и encrypted_private_key.
struct PackedCiphertext: Codable, Equatable {
    let iv: String
    let ciphertext: String

    /// Порядок полей важен: веб узнаёт шифротекст по началу строки
    /// `{"iv":` (crypto.js, decryptText), а JSONEncoder порядок ключей не
    /// обещает — с `{"ciphertext":…}` браузер показывал сообщение как есть.
    /// Base64 экранирования в JSON не требует, поэтому собираем вручную.
    var json: String { #"{"iv":""# + iv + #"","ciphertext":""# + ciphertext + #""}"# }

    /// nil, если строка не похожа на упакованный шифротекст.
    ///
    /// Разбирается и экранированный вариант: веб-клиент местами прогоняет
    /// содержимое через преобразование HTML-сущностей, и тогда вместо
    /// {"iv":...} приходит {&quot;iv&quot;:...}.
    static func parse(_ raw: String) -> PackedCiphertext? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("&") else { return nil }
        if let value = decode(trimmed) { return value }
        if trimmed.contains("&") { return decode(HtmlEntities.unescape(trimmed)) }
        return nil
    }

    private static func decode(_ value: String) -> PackedCiphertext? {
        guard let parsed = try? JSONDecoder().decode(PackedCiphertext.self, from: Data(value.utf8)),
              !parsed.iv.isEmpty, !parsed.ciphertext.isEmpty else { return nil }
        return parsed
    }
}

/// Веб-клиент местами прогоняет текст через экранирование HTML-сущностей,
/// поэтому в расшифрованном тексте встречаются &quot; и подобные.
enum HtmlEntities {
    private static let map: [(String, String)] = [
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&#39;", "'"),
        ("&#x27;", "'"),
        ("&#x2F;", "/"),
        ("&nbsp;", " "),
    ]

    static func unescape(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        // &amp; разворачивается последним, иначе &amp;lt; превратится в <
        for (entity, ch) in map { result = result.replacingOccurrences(of: entity, with: ch) }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Общие настройки JSON: без экранирования «/», как JSON.stringify в вебе.
enum JSONCoding {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    static func encodeString<T: Encodable>(_ value: T) -> String {
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func encodeData<T: Encodable>(_ value: T) throws -> Data { try encoder.encode(value) }
}
