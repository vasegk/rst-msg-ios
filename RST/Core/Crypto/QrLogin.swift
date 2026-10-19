import CryptoKit
import Foundation

/// Вход по QR-коду (как js/qr-login.js, сервер — routers/qrlogin.py).
///
/// Новое устройство: одноразовая пара ECDH, в коде — адрес
/// https://<домен>/chat#qr=<сеанс>.<открытый ключ base64url>. Подтверждающее
/// устройство шифрует свой приватный ключ (JWK строкой) общим ключом
/// ECDH(своя одноразовая пара, ключ из кода) — ключ получателя берётся из
/// самого кода, подменить его сервер не может. Общий ключ — координата X
/// общей точки, как deriveKey(ECDH → AES-GCM 256) в WebCrypto.
enum QrLogin {
    struct Link: Equatable {
        let session: String
        let pub: String
    }

    /// «#qr=<сеанс>.<ключ>» из адреса — или nil.
    static func parse(_ raw: String) -> Link? {
        let pattern = #"[#&]qr=([A-Za-z0-9_-]{20,64})\.([A-Za-z0-9_-]{80,100})"#
        guard let range = raw.range(of: pattern, options: .regularExpression) else { return nil }
        let body = raw[range].dropFirst(4)
        let parts = body.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return Link(session: parts[0], pub: parts[1])
    }

    static func link(base: URL, session: String, pub: String) -> String {
        base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat#qr=\(session).\(pub)"
    }

    /// Открытый ключ «сырым» (04‖X‖Y) в base64url.
    static func rawPublic(_ key: P256.KeyAgreement.PublicKey) -> String {
        key.x963Representation.base64URLEncodedString
    }

    static func sharedKey(_ mine: P256.KeyAgreement.PrivateKey, peerRaw: String) throws -> SymmetricKey {
        guard let raw = Data(base64URLEncoded: peerRaw),
              let peer = try? P256.KeyAgreement.PublicKey(x963Representation: raw) else {
            throw CryptoError("Неверный QR-код")
        }
        return try Ecdh.deriveSharedKey(privateKey: mine, peerPublicKey: peer)
    }

    /// Подтверждающее устройство: (approver_pub, payload) для /api/qr/approve.
    static func approve(privateJwk: String, peerPub: String) throws -> (approverPub: String, payload: String) {
        let pair = P256.KeyAgreement.PrivateKey()
        let key = try sharedKey(pair, peerRaw: peerPub)
        let body = JSONCoding.encodeString(["v": JSONValue.number(1), "priv": .string(privateJwk)])
        let sealed = try RstCrypto.encrypt(key: key, plaintext: Data(body.utf8))
        let payload = JSONCoding.encodeString([
            "iv": sealed.iv.base64EncodedString(),
            "ct": sealed.ciphertext.base64EncodedString(),
        ])
        return (rawPublic(pair.publicKey), payload)
    }

    /// Новое устройство: приватный ключ аккаунта (JWK строкой) из ответа poll.
    static func open(mine: P256.KeyAgreement.PrivateKey, approverPub: String, payload: String) throws -> String {
        let key = try sharedKey(mine, peerRaw: approverPub)
        guard let box = JSONValue.parse(payload),
              let iv = box["iv"]?.string.flatMap({ Data(base64Encoded: $0) }),
              let ct = box["ct"]?.string.flatMap({ Data(base64Encoded: $0) }) else {
            throw CryptoError("Повреждён ответ подтверждения")
        }
        let plain = try RstCrypto.decrypt(key: key, iv: iv, ciphertext: ct)
        guard let inner = JSONValue.parse(String(decoding: plain, as: UTF8.self)), let priv = inner["priv"]?.string else {
            throw CryptoError("Пришёл не тот ключ")
        }
        // Настоящий приватный ключ P-256 — иначе не входим
        let jwk = try Jwk.parse(priv)
        guard jwk.d != nil else { throw CryptoError("Пришёл не тот ключ") }
        _ = try Ecdh.importPrivateJwk(jwk)
        return priv
    }
}
