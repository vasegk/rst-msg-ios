import CryptoKit
import Foundation

/// JWK ключа ECDH P-256 в том виде, в каком его отдаёт WebCrypto exportKey("jwk").
///
/// У открытого ключа поля "d" нет вовсе: с "d": null браузер ключ не
/// импортирует, и веб перестал бы читать сообщения от приложения.
struct Jwk: Codable, Equatable {
    var kty: String = "EC"
    var crv: String = "P-256"
    var x: String
    var y: String
    var d: String?
    var ext: Bool? = true
    var keyOps: [String]? = []

    enum CodingKeys: String, CodingKey {
        case kty, crv, x, y, d, ext
        case keyOps = "key_ops"
    }

    init(x: String, y: String, d: String? = nil, keyOps: [String] = []) {
        self.x = x
        self.y = y
        self.d = d
        self.keyOps = keyOps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kty = try c.decodeIfPresent(String.self, forKey: .kty) ?? "EC"
        crv = try c.decodeIfPresent(String.self, forKey: .crv) ?? "P-256"
        x = try c.decode(String.self, forKey: .x)
        y = try c.decode(String.self, forKey: .y)
        d = try c.decodeIfPresent(String.self, forKey: .d)
        ext = try c.decodeIfPresent(Bool.self, forKey: .ext)
        keyOps = try c.decodeIfPresent([String].self, forKey: .keyOps)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kty, forKey: .kty)
        try c.encode(crv, forKey: .crv)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encodeIfPresent(d, forKey: .d)
        try c.encode(ext ?? true, forKey: .ext)
        try c.encode(keyOps ?? [], forKey: .keyOps)
    }

    var json: String { JSONCoding.encodeString(self) }

    /// Открытая часть: без d и без операций, как экспортирует WebCrypto.
    var publicOnly: Jwk { Jwk(x: x, y: y) }

    static func parse(_ raw: String) throws -> Jwk {
        do {
            return try JSONDecoder().decode(Jwk.self, from: Data(raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        } catch {
            throw CryptoError("Не удалось разобрать JWK")
        }
    }
}

/// Пара ключей ECDH P-256 плюс их JWK-представление.
struct EcdhKeyPair {
    let privateKey: P256.KeyAgreement.PrivateKey
    let publicKey: P256.KeyAgreement.PublicKey
    let publicJwkJson: String
    let privateJwkJson: String
}

enum Ecdh {
    private static let coordBytes = 32

    static func generateKeyPair() -> EcdhKeyPair {
        let priv = P256.KeyAgreement.PrivateKey()
        return EcdhKeyPair(
            privateKey: priv,
            publicKey: priv.publicKey,
            publicJwkJson: exportPublicJwk(priv.publicKey).json,
            privateJwkJson: exportPrivateJwk(priv).json
        )
    }

    static func exportPublicJwk(_ key: P256.KeyAgreement.PublicKey) -> Jwk {
        let raw = key.x963Representation // 04 || x || y
        let x = raw.subdata(in: 1..<(1 + coordBytes))
        let y = raw.subdata(in: (1 + coordBytes)..<(1 + 2 * coordBytes))
        return Jwk(x: x.base64URLEncodedString, y: y.base64URLEncodedString)
    }

    static func exportPrivateJwk(_ key: P256.KeyAgreement.PrivateKey) -> Jwk {
        var jwk = exportPublicJwk(key.publicKey)
        jwk.d = key.rawRepresentation.base64URLEncodedString
        jwk.keyOps = ["deriveKey", "deriveBits"]
        return jwk
    }

    static func importPublicJwk(_ json: String) throws -> P256.KeyAgreement.PublicKey {
        try importPublicJwk(Jwk.parse(json))
    }

    static func importPublicJwk(_ jwk: Jwk) throws -> P256.KeyAgreement.PublicKey {
        guard let x = Data(base64URLEncoded: jwk.x), let y = Data(base64URLEncoded: jwk.y) else {
            throw CryptoError("Повреждены координаты открытого ключа")
        }
        do {
            return try P256.KeyAgreement.PublicKey(x963Representation: Data([0x04]) + fixed(x) + fixed(y))
        } catch {
            throw CryptoError("Открытый ключ не на кривой P-256")
        }
    }

    static func importPrivateJwk(_ json: String) throws -> P256.KeyAgreement.PrivateKey {
        try importPrivateJwk(Jwk.parse(json))
    }

    static func importPrivateJwk(_ jwk: Jwk) throws -> P256.KeyAgreement.PrivateKey {
        guard let dString = jwk.d, let d = Data(base64URLEncoded: dString) else {
            throw CryptoError("В JWK нет поля d — это не приватный ключ")
        }
        do {
            return try P256.KeyAgreement.PrivateKey(rawRepresentation: fixed(d))
        } catch {
            throw CryptoError("Приватный ключ повреждён")
        }
    }

    /// Ключ личной переписки: ECDH(свой приватный, чужой публичный).
    ///
    /// WebCrypto в deriveKey(ECDH -> AES-GCM 256) берёт координату X общей точки
    /// как сырой ключ, поэтому здесь ровно те же 32 байта, без KDF поверх.
    static func deriveSharedKey(
        privateKey: P256.KeyAgreement.PrivateKey,
        peerPublicKey: P256.KeyAgreement.PublicKey
    ) throws -> SymmetricKey {
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        let raw = secret.withUnsafeBytes { Data($0) }
        return try RstCrypto.aesKey(fixed(raw))
    }

    /// Координата P-256 всегда 32 байта: с левым дополнением нулями.
    private static func fixed(_ raw: Data) -> Data {
        if raw.count == coordBytes { return raw }
        if raw.count > coordBytes { return Data(raw.suffix(coordBytes)) }
        return Data(repeating: 0, count: coordBytes - raw.count) + raw
    }
}
