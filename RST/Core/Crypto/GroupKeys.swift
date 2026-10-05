import CryptoKit
import Foundation

/// Копия группового ключа, зашифрованная лично для участника.
/// Лежит в group_members.encrypted_key:
/// {"v":1,"by":"<кто упаковал>","iv":"<base64>","ciphertext":"<base64>"}
///
/// Ключ распаковки — ECDH между приватным ключом участника и публичным ключом
/// того, кто упаковал. ECDH симметричен, поэтому подходит ключ любого из двоих.
struct GroupKeyPacket: Codable, Equatable {
    var version: Int = 1
    var packedBy: String
    var iv: String
    var ciphertext: String

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case packedBy = "by"
        case iv, ciphertext
    }

    var json: String { JSONCoding.encodeString(self) }

    static func parse(_ raw: String?) -> GroupKeyPacket? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let packet = try? JSONDecoder().decode(GroupKeyPacket.self, from: Data(trimmed.utf8)),
              packet.version == 1 else { return nil }
        return packet
    }
}

enum GroupKeyCrypto {

    /// Распаковывает групповой ключ из своей копии.
    static func unwrap(
        _ packet: GroupKeyPacket,
        myPrivateKey: P256.KeyAgreement.PrivateKey,
        packerPublicKey: P256.KeyAgreement.PublicKey
    ) throws -> SymmetricKey {
        let wrappingKey = try Ecdh.deriveSharedKey(privateKey: myPrivateKey, peerPublicKey: packerPublicKey)
        guard let iv = Data(base64Encoded: packet.iv), let ct = Data(base64Encoded: packet.ciphertext) else {
            throw CryptoError("Пакет ключа повреждён")
        }
        let raw: Data
        do {
            raw = try RstCrypto.decrypt(key: wrappingKey, iv: iv, ciphertext: ct)
        } catch {
            throw CryptoError("Не удалось распаковать ключ группы")
        }
        guard raw.count == 32 else { throw CryptoError("Ключ группы должен быть 32 байта, получено \(raw.count)") }
        return SymmetricKey(data: raw)
    }

    /// Упаковывает групповой ключ для участника: ECDH со своим приватным и его
    /// публичным, в поле by — своё имя. Для себя самого — собственный публичный
    /// ключ (вступление по ссылке, когда ключ пришёл во фрагменте адреса).
    static func wrap(
        _ groupKey: SymmetricKey,
        myUsername: String,
        myPrivateKey: P256.KeyAgreement.PrivateKey,
        memberPublicKey: P256.KeyAgreement.PublicKey
    ) throws -> GroupKeyPacket {
        let wrappingKey = try Ecdh.deriveSharedKey(privateKey: myPrivateKey, peerPublicKey: memberPublicKey)
        let (iv, ct) = try RstCrypto.encrypt(key: wrappingKey, plaintext: groupKey.rawData)
        return GroupKeyPacket(packedBy: myUsername, iv: iv.base64EncodedString(), ciphertext: ct.base64EncodedString())
    }
}

/// Состояние ключа группы с точки зрения этого устройства.
enum GroupKeyState {
    /// Настоящий ключ есть — сквозное шифрование.
    case secure
    /// Своего ключа нет, но он у группы есть (был здесь раньше или есть у
    /// кого-то из участников). Читать старое прежним ключом можно, писать —
    /// нельзя: ждём group_key_shared.
    case pending
    /// Настоящего ключа нет ни у кого: прежняя схема, сквозного шифрования нет.
    case insecure
}

/// Ключи одного чата.
///
/// У личного чата ключ один. У группы их может быть два: настоящий случайный
/// ключ из encrypted_key и прежний, выведенный из номера группы. При
/// расшифровке пробуем сначала настоящий, затем прежний. Шифруем всегда
/// настоящим; прежним — только если настоящего нет ни у кого (insecure).
struct ChatKeys {
    let primary: SymmetricKey
    let legacy: SymmetricKey?
    /// nil — личный чат.
    let groupState: GroupKeyState?

    var candidates: [SymmetricKey] { [primary] + (legacy.map { [$0] } ?? []) }
    var isInsecureGroup: Bool { groupState == .insecure }
    var isKeyPending: Bool { groupState == .pending }

    /// Настоящий ключ группы — только он годится для раздачи и ссылки-приглашения.
    var realGroupKey: SymmetricKey? { groupState == .secure ? primary : nil }

    static func direct(_ key: SymmetricKey) -> ChatKeys {
        ChatKeys(primary: key, legacy: nil, groupState: nil)
    }

    static func secureGroup(_ key: SymmetricKey, groupId: String) -> ChatKeys {
        ChatKeys(primary: key, legacy: RstCrypto.legacyGroupKey(groupId: groupId), groupState: .secure)
    }

    static func legacyGroup(groupId: String) -> ChatKeys {
        ChatKeys(primary: RstCrypto.legacyGroupKey(groupId: groupId), legacy: nil, groupState: .insecure)
    }

    static func pendingGroup(groupId: String) -> ChatKeys {
        ChatKeys(primary: RstCrypto.legacyGroupKey(groupId: groupId), legacy: nil, groupState: .pending)
    }
}

/// Решение без своей копии ключа (с 2026-09-27). someoneHasKey == nil —
/// сведения о группе не загрузились: лучше подождать ключ, чем отправить
/// то, что прочитает сервер.
func groupStateWithoutOwnKey(remembered: Bool, someoneHasKey: Bool?) -> GroupKeyState {
    (remembered || someoneHasKey != false) ? .pending : .insecure
}

/// Шифрование и расшифровка поля content сообщения.
enum MessageCrypto {

    static func encryptText(_ keys: ChatKeys, _ text: String) throws -> String {
        try RstCrypto.encryptToPacked(key: keys.primary, plaintext: text)
    }

    static func encryptEnvelope(_ keys: ChatKeys, _ envelope: Envelope) throws -> String {
        try RstCrypto.encryptToPacked(key: keys.primary, plaintext: envelope.json)
    }

    /// Никогда не бросает: нерасшифрованное сообщение — штатная ситуация.
    /// Для группы перебираются оба ключа: сначала настоящий, затем прежний.
    static func decrypt(_ keys: ChatKeys?, _ packed: String?) -> DecryptedContent {
        guard let packed, !packed.isEmpty else { return .text("") }
        guard let keys else { return .undecryptable }
        for key in keys.candidates {
            guard let plain = try? RstCrypto.decryptPacked(key: key, packed: packed) else { continue }
            if var env = Envelope.parse(plain) {
                env.text = HtmlEntities.unescape(env.text)
                return .enveloped(env)
            }
            return .text(HtmlEntities.unescape(plain))
        }
        return .undecryptable
    }
}

/// Сквозное шифрование вложений: на сервер уходит поток IV(12) + шифротекст
/// под именем attachment.enc. Ключ у каждого файла свой — при пересылке файл
/// не перезаливается, а тот же ключ кладётся в новый конверт.
/// Аватары НЕ шифруются.
enum FileCrypto {
    struct Encrypted {
        let payload: Data
        let keyB64: String
    }

    static func encrypt(_ plain: Data) throws -> Encrypted {
        let key = RstCrypto.randomAesKey()
        let (iv, ct) = try RstCrypto.encrypt(key: key, plaintext: plain)
        return Encrypted(payload: iv + ct, keyB64: key.rawData.base64EncodedString())
    }

    static func decrypt(_ payload: Data, keyB64: String) throws -> Data {
        guard payload.count > RstCrypto.gcmIVBytes else {
            throw CryptoError("Файл короче, чем IV — данные повреждены")
        }
        guard let raw = Data(base64Encoded: keyB64) else { throw CryptoError("Ключ файла повреждён") }
        let key = try RstCrypto.aesKey(raw)
        let iv = Data(payload.prefix(RstCrypto.gcmIVBytes))
        let ct = Data(payload.dropFirst(RstCrypto.gcmIVBytes))
        return try RstCrypto.decrypt(key: key, iv: iv, ciphertext: ct)
    }
}

/// Ключ восстановления — новый пароль без потери переписки (js/recovery.js).
///
/// Код — 20 случайных байт, записанных 32 знаками алфавита без похожих I/1 и
/// O/0, группами по четыре. Из нормализованного кода PBKDF2-SHA256 (соль —
/// recovery_salt как UTF-8, 100 000 итераций) выводит 512 бит: первые 32 байта —
/// ключ AES-GCM для копии приватного JWK, вторые 32 байта в hex — recovery_auth.
enum RecoveryCode {
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    static let length = 32
    static let iterations = 100_000

    static func generate(random: Data = RstCrypto.randomBytes(20)) -> String {
        precondition(random.count == 20)
        var out = ""
        var value = 0
        var bits = 0
        for b in random {
            value = (value << 8) | Int(b)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(value >> (bits - 5)) & 31])
                bits -= 5
                value &= (1 << bits) - 1
            }
        }
        var groups: [String] = []
        var current = ""
        for ch in out {
            current.append(ch)
            if current.count == 4 { groups.append(current); current = "" }
        }
        if !current.isEmpty { groups.append(current) }
        return groups.joined(separator: "-")
    }

    /// Код как его ввели — в каноническую форму, или nil, если это не код.
    static func normalize(_ input: String) -> String? {
        let s = input.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard s.count == length, s.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return s
    }

    struct Derived {
        let key: SymmetricKey
        let authHex: String
    }

    static func derive(normalizedCode: String, salt: String, iterations: Int = RecoveryCode.iterations) -> Derived {
        let bits = RstCrypto.pbkdf2SHA256(
            password: Data(normalizedCode.utf8), salt: Data(salt.utf8), iterations: iterations, length: 64)
        return Derived(key: SymmetricKey(data: bits.prefix(32)), authHex: Data(bits.suffix(32)).hexString)
    }

    static func newSalt() -> String { RstCrypto.randomBytes(16).hexString }
}

/// Код безопасности переписки — как в вебе. Строка ключа — crv|x|y из JWK.
/// Две строки сортируются, код — SHA-256(UTF-8("rst-safety-v1|" + a + "|" + b)),
/// из первых 24 байт — 12 групп: ((b[2i] << 8) | b[2i+1]) % 100000.
enum SafetyCode {
    static func keyString(_ jwk: Jwk) -> String { "\(jwk.crv)|\(jwk.x)|\(jwk.y)" }

    static func compute(mine: Jwk, theirs: Jwk) -> [String] {
        // Сортировка — как Array.sort() в JS: по единицам UTF-16.
        let parts = [keyString(mine), keyString(theirs)].sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
        let hash = Array(RstCrypto.sha256(Data(("rst-safety-v1|" + parts.joined(separator: "|")).utf8)))
        return (0..<12).map { i in
            let value = (Int(hash[i * 2]) << 8) | Int(hash[i * 2 + 1])
            let s = String(value % 100_000)
            return String(repeating: "0", count: max(0, 5 - s.count)) + s
        }
    }

    /// Отпечаток для запоминания ключа собеседника: base64(SHA-256(crv|x|y)).
    static func fingerprint(_ jwk: Jwk) -> String {
        RstCrypto.sha256(Data(keyString(jwk).utf8)).base64EncodedString()
    }
}

/// Конверт истории, зашифрованный ключом истории:
/// {"f":"<ключ файла base64>","m":"<MIME>","c":"<подпись, до 200 символов>"}.
struct StoryEnvelope: Codable {
    var fileKeyB64: String
    var mimeType: String = ""
    var caption: String = ""

    enum CodingKeys: String, CodingKey {
        case fileKeyB64 = "f"
        case mimeType = "m"
        case caption = "c"
    }
}
