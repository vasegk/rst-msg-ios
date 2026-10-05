import CryptoKit
import XCTest
@testable import RST

/// Тесты совместимости с веб-клиентом.
///
/// Эталоны WebCrypto получены настоящим WebCrypto (crypto.subtle в Node.js —
/// та же реализация API, что в браузере). PBKDF2 совпадает и с эталонами
/// Android-клиента. Если один из тестов упал — приложение перестало понимать
/// переписку из браузера.
final class CryptoCompatibilityTests: XCTestCase {

    // MARK: - Эталоны WebCrypto

    private let alicePrivateJwk = #"{"key_ops":["deriveKey","deriveBits"],"ext":true,"kty":"EC","x":"62vAG8Unp4VGS2BU6xSitEkmA3eceOh3V5PkLZnWC0I","y":"QMrv5fToLj80gp_sbktbrXEw4HE87KMCWNjV2-xUE14","crv":"P-256","d":"_9wcVtwTyip5Ss1GjwbD9VD4McrHU1Qvff3bToeDYUY"}"#
    private let bobPublicJwk = #"{"key_ops":[],"ext":true,"kty":"EC","x":"mrVRHn87JEA6H_yJoYaZDenLBBTXWP60Sr809RLi9RI","y":"jZDFWlnR63Op4mFuHBHwvjSYE9EWxdDOo7A1uT8poNg","crv":"P-256"}"#
    private let sharedRaw = "PF9IzHqvQj7JvURn8wxFti/Rb8yDB9AC2gaupGpMJMg="
    private let webText = "Привет из браузера 👋 **жирный**"
    private let webPacked = #"{"iv":"JcIYK656UD6uxZY4","ciphertext":"vXSNxikyznGWGfRD2HgVPAz21Hr1d7VsKIsDBy39LnoBmAbcSbPgNaNU5WDN8oHZ6kSAyxn0KWEEj5POmWTr+O8hxI+xC0YD"}"#
    private let webPackedEnvelope = #"{"iv":"gkzYKGQygvNBCbVR","ciphertext":"xW45IaIgg6cCWfcsijCXLFlAcOh6cWyrn7UIDNiCs9oOMFEdU33c3HvwmnowYZBMaPD8Z2Pf7MUrfxNm/kpB/RII2Mm9A0It1M/dlNzoEkRXrBa11QeO88iBo4Xl/QL0HJh+4faKqfDfMxGU8H1Oxngj3i6qteO8zD5xdxnM0JS0zjM="}"#
    private let webEncryptedPrivate = #"{"iv":"dJNabfJokInEYnyG","ciphertext":"xDuBdCtgOuToYPBFFsgQ0Xi76q8QzZQgU5GZ2zPyeOOy6V13DTFIbAu7f+ClI1aNoorBgCaTu36PVcDnYO/FglOZT0e2JPw8t4M/ZDXJ0uebxTJ7cCd+AIGHE0U1lFyoyNOeaWtR1vXzYhtu8cfgNDjVX4dmeWfySCxBRrOkDsJoPyJMCWrnHD2/cXRLBMk7t2QTv+2yOY7ODiYHp5JNa8SQen3DMRJtrN0Rhi6pzrbpeIzsuc5JUyRgrU5+OHQ1tvxT5N41jq74TB2mwHJ/AFm3o1rfuPqSSNYJUFtvVdXyy7YApRBwKzSHk2MA8X2G"}"#

    func testPbkdf2MatchesWebCrypto() {
        let kek = RstCrypto.deriveKek(password: "password", kdfSalt: "0123456789abcdef0123456789abcdef", iterations: 100_000)
        XCTAssertEqual(kek.rawData.base64EncodedString(), "2wS9AhKG0+nUaF/eSUuYTqFtmYpJAgZfq+JarKrHdO8=")
    }

    /// Аккаунты, созданные после 2026-09-15.
    func testPbkdf2With600kIterations() {
        let kek = RstCrypto.deriveKek(password: "password", kdfSalt: "0123456789abcdef0123456789abcdef", iterations: 600_000)
        XCTAssertEqual(kek.rawData.base64EncodedString(), "kaIZheYZRIGbH+1Vtml56xchM/YgoeJ4qZJ5ClllR/Q=")
    }

    func testPbkdf2EncodesPasswordAsUtf8() {
        let kek = RstCrypto.deriveKek(password: "пароль-ю", kdfSalt: "deadbeefdeadbeefdeadbeefdeadbeef", iterations: 100_000)
        XCTAssertEqual(kek.rawData.base64EncodedString(), "hGPbYstaZC+I6p5JhlH+0nDxJaPi3jd/t6UUUtE48PU=")
    }

    func testEcdhSharedKeyMatchesWebCrypto() throws {
        let priv = try Ecdh.importPrivateJwk(alicePrivateJwk)
        let pub = try Ecdh.importPublicJwk(bobPublicJwk)
        let shared = try Ecdh.deriveSharedKey(privateKey: priv, peerPublicKey: pub)
        XCTAssertEqual(shared.rawData.base64EncodedString(), sharedRaw)
    }

    func testDecryptsMessageFromBrowser() throws {
        let key = SymmetricKey(data: Data(base64Encoded: sharedRaw)!)
        XCTAssertEqual(try RstCrypto.decryptPacked(key: key, packed: webPacked), webText)
        XCTAssertEqual(MessageCrypto.decrypt(.direct(key), webPacked), .text(webText))
    }

    func testDecryptsAttachmentEnvelopeFromBrowser() throws {
        let key = SymmetricKey(data: Data(base64Encoded: sharedRaw)!)
        guard case .enveloped(let env) = MessageCrypto.decrypt(.direct(key), webPackedEnvelope) else {
            return XCTFail("конверт не распознан")
        }
        XCTAssertEqual(env.text, "подпись")
        XCTAssertEqual(env.fileName, "photo.png")
        XCTAssertEqual(env.mimeType, "image/png")
        XCTAssertTrue(env.hasFile)
    }

    /// Приватный ключ, зашифрованный в браузере при регистрации, открывается здесь.
    func testDecryptsPrivateKeyEncryptedByBrowser() throws {
        let kek = RstCrypto.deriveKek(password: "hunter2!", kdfSalt: "0123456789abcdef0123456789abcdef", iterations: 100_000)
        let jwk = try RstCrypto.decryptPacked(key: kek, packed: webEncryptedPrivate)
        let priv = try Ecdh.importPrivateJwk(jwk)
        let pub = try Ecdh.importPublicJwk(bobPublicJwk)
        XCTAssertEqual(try Ecdh.deriveSharedKey(privateKey: priv, peerPublicKey: pub).rawData.base64EncodedString(), sharedRaw)
    }

    /// Наша упаковка открывается тем же ключом — формат {"iv","ciphertext"}, тег в конце.
    func testOwnPackedHasWebFormat() throws {
        let key = SymmetricKey(data: Data(base64Encoded: sharedRaw)!)
        let packed = try RstCrypto.encryptToPacked(key: key, plaintext: "привет, мир")
        let object = try JSONSerialization.jsonObject(with: Data(packed.utf8)) as? [String: String]
        XCTAssertEqual(Set(object?.keys.map { $0 } ?? []), ["iv", "ciphertext"])
        XCTAssertEqual(Data(base64Encoded: object?["iv"] ?? "")?.count, 12)
        XCTAssertEqual(Data(base64Encoded: object?["ciphertext"] ?? "")?.count, "привет, мир".utf8.count + 16)
        XCTAssertFalse(packed.contains("\\/"), "слэши не экранируются, как в JSON.stringify")
        XCTAssertEqual(try RstCrypto.decryptPacked(key: key, packed: packed), "привет, мир")
    }

    // MARK: - Ключи

    func testLegacyGroupKeyIsDeterministic() {
        XCTAssertEqual(RstCrypto.legacyGroupKey(groupId: "42").rawData.base64EncodedString(),
                       "U2S1jyMUxrMvyRP05/IHRzDp7jn0Nqf4PBUB3G8YrmM=")
    }

    func testEcdhIsSymmetric() throws {
        let alice = Ecdh.generateKeyPair()
        let bob = Ecdh.generateKeyPair()
        let a = try Ecdh.deriveSharedKey(privateKey: alice.privateKey, peerPublicKey: bob.publicKey)
        let b = try Ecdh.deriveSharedKey(privateKey: bob.privateKey, peerPublicKey: alice.publicKey)
        XCTAssertEqual(a.rawData, b.rawData)
        XCTAssertEqual(a.rawData.count, 32)
    }

    func testJwkRoundTrip() throws {
        let pair = Ecdh.generateKeyPair()
        let peer = Ecdh.generateKeyPair()
        let importedPrivate = try Ecdh.importPrivateJwk(pair.privateJwkJson)
        let importedPublic = try Ecdh.importPublicJwk(pair.publicJwkJson)
        XCTAssertEqual(try Ecdh.deriveSharedKey(privateKey: importedPrivate, peerPublicKey: peer.publicKey).rawData,
                       try Ecdh.deriveSharedKey(privateKey: pair.privateKey, peerPublicKey: peer.publicKey).rawData)
        XCTAssertEqual(try Ecdh.deriveSharedKey(privateKey: peer.privateKey, peerPublicKey: importedPublic).rawData,
                       try Ecdh.deriveSharedKey(privateKey: peer.privateKey, peerPublicKey: pair.publicKey).rawData)
    }

    /// Открытый ключ — без поля "d" вовсе: с "d": null браузер ключ не импортирует.
    func testPublicJwkHasNoD() throws {
        let pair = Ecdh.generateKeyPair()
        let object = try JSONSerialization.jsonObject(with: Data(pair.publicJwkJson.utf8)) as? [String: Any]
        XCTAssertNil(object?["d"])
        XCTAssertFalse(pair.publicJwkJson.contains("null"))
        XCTAssertEqual(object?["kty"] as? String, "EC")
        XCTAssertEqual(object?["crv"] as? String, "P-256")
        let priv = try Jwk.parse(pair.privateJwkJson)
        XCTAssertTrue(priv.keyOps?.contains("deriveKey") ?? false)
    }

    func testJwkCoordinatesAre32Bytes() throws {
        for _ in 0..<20 {
            let jwk = try Jwk.parse(Ecdh.generateKeyPair().privateJwkJson)
            XCTAssertEqual(Data(base64URLEncoded: jwk.x)?.count, 32)
            XCTAssertEqual(Data(base64URLEncoded: jwk.y)?.count, 32)
            XCTAssertEqual(Data(base64URLEncoded: jwk.d ?? "")?.count, 32)
        }
    }

    func testPrivateKeyEncryptedByKekRestores() throws {
        let salt = "0123456789abcdef0123456789abcdef"
        let kek = RstCrypto.deriveKek(password: "hunter2!", kdfSalt: salt, iterations: 1000)
        let pair = Ecdh.generateKeyPair()
        let encrypted = try RstCrypto.encryptToPacked(key: kek, plaintext: pair.privateJwkJson)
        let again = RstCrypto.deriveKek(password: "hunter2!", kdfSalt: salt, iterations: 1000)
        XCTAssertEqual(try RstCrypto.decryptPacked(key: again, packed: encrypted), pair.privateJwkJson)
    }

    // MARK: - Конверт

    func testEnvelopeDetection() throws {
        let keys = ChatKeys.direct(RstCrypto.randomAesKey())
        let withFile = try MessageCrypto.encryptEnvelope(keys, Envelope(text: "смотри", fileKeyB64: RstCrypto.randomBytes(32).base64EncodedString(),
                                                                        fileName: "photo.png", mimeType: "image/png"))
        guard case .enveloped(let env) = MessageCrypto.decrypt(keys, withFile) else { return XCTFail() }
        XCTAssertEqual(env.fileName, "photo.png")

        let plain = try MessageCrypto.encryptText(keys, "просто текст")
        XCTAssertEqual(MessageCrypto.decrypt(keys, plain), .text("просто текст"))

        // Старый формат: текст с фигурной скобкой, но не конверт
        let jsonish = try MessageCrypto.encryptText(keys, #"{"a":1}"#)
        XCTAssertEqual(MessageCrypto.decrypt(keys, jsonish), .text(#"{"a":1}"#))
    }

    func testUndecryptableDoesNotCrash() throws {
        let packed = try RstCrypto.encryptToPacked(key: RstCrypto.randomAesKey(), plaintext: "чужим ключом")
        XCTAssertEqual(MessageCrypto.decrypt(.direct(RstCrypto.randomAesKey()), packed), .undecryptable)
        XCTAssertEqual(MessageCrypto.decrypt(nil, "что-нибудь"), .undecryptable)
        XCTAssertEqual(MessageCrypto.decrypt(nil, nil), .text(""))
    }

    func testFileCryptoLayout() throws {
        let original = Data((0..<1000).map { UInt8($0 % 251) })
        let encrypted = try FileCrypto.encrypt(original)
        XCTAssertEqual(encrypted.payload.count, original.count + 12 + 16)
        XCTAssertEqual(try FileCrypto.decrypt(encrypted.payload, keyB64: encrypted.keyB64), original)
    }

    func testHtmlEntities() {
        XCTAssertEqual(HtmlEntities.unescape("он сказал &quot;да&quot; &amp; ушёл"), #"он сказал "да" & ушёл"#)
        XCTAssertEqual(HtmlEntities.unescape("&amp;amp;lt;"), "&amp;lt;")
    }

    func testEscapedPackedStillReadable() throws {
        let keys = ChatKeys.direct(RstCrypto.randomAesKey())
        let packed = try MessageCrypto.encryptText(keys, "привет из браузера")
        let escaped = packed.replacingOccurrences(of: "\"", with: "&quot;")
        XCTAssertEqual(MessageCrypto.decrypt(keys, escaped), .text("привет из браузера"))
    }

    func testEscapedEnvelopeParsed() throws {
        let keys = ChatKeys.direct(RstCrypto.randomAesKey())
        let packed = try MessageCrypto.encryptEnvelope(keys, Envelope(text: "подпись", fileKeyB64: RstCrypto.randomBytes(32).base64EncodedString(),
                                                                      fileName: "doc.pdf", mimeType: "application/pdf"))
        guard case .enveloped(let env) = MessageCrypto.decrypt(keys, packed.replacingOccurrences(of: "\"", with: "&quot;")) else {
            return XCTFail()
        }
        XCTAssertEqual(env.fileName, "doc.pdf")
    }

    func testPollEnvelopeFromWeb() throws {
        let keys = ChatKeys.direct(RstCrypto.randomAesKey())
        let web = #"{"__rst":1,"t":"📊 Куда едем?","p":{"q":"Куда едем?","o":["Море","Горы"]}}"#
        guard case .enveloped(let env) = MessageCrypto.decrypt(keys, try RstCrypto.encryptToPacked(key: keys.primary, plaintext: web)) else {
            return XCTFail()
        }
        XCTAssertEqual(env.text, "📊 Куда едем?")
        XCTAssertEqual(env.poll?.options, ["Море", "Горы"])
        XCTAssertFalse(env.hasFile)
    }

    func testStoryReplyAndUnknownFieldsDoNotBreakParsing() throws {
        let keys = ChatKeys.direct(RstCrypto.randomAesKey())
        let web = #"{"__rst":1,"t":"класс!","s":{"a":"ivan","id":7,"th":"javascript:alert(1)"},"zz":{"new":true}}"#
        guard case .enveloped(let env) = MessageCrypto.decrypt(keys, try RstCrypto.encryptToPacked(key: keys.primary, plaintext: web)) else {
            return XCTFail()
        }
        XCTAssertEqual(env.text, "класс!")
        XCTAssertEqual(env.story?.author, "ivan")
        XCTAssertEqual(env.story?.id, 7)
        XCTAssertNil(env.story?.safeThumbnail)
    }

    func testEnvelopeWithoutAttachmentWritesNoNull() {
        let json = Envelope(text: "т", poll: PollBody(question: "в", options: ["a", "b"])).json
        XCTAssertFalse(json.contains("null"))
        XCTAssertTrue(json.contains(#""__rst":1"#))
    }

    func testPackedParseRequiresValidJson() {
        XCTAssertNil(PackedCiphertext.parse("обычный текст"))
        XCTAssertNil(PackedCiphertext.parse(#"{"нет":"полей"}"#))
    }

    // MARK: - Ключ группы

    func testMemberUnwrapsKeyWrappedByOwner() throws {
        let owner = Ecdh.generateKeyPair()
        let member = Ecdh.generateKeyPair()
        let groupKey = RstCrypto.randomAesKey()
        let packet = try GroupKeyCrypto.wrap(groupKey, myUsername: "owner", myPrivateKey: owner.privateKey, memberPublicKey: member.publicKey)
        let unwrapped = try GroupKeyCrypto.unwrap(packet, myPrivateKey: member.privateKey, packerPublicKey: owner.publicKey)
        XCTAssertEqual(packet.version, 1)
        XCTAssertEqual(packet.packedBy, "owner")
        XCTAssertEqual(unwrapped.rawData, groupKey.rawData)
        let restored = GroupKeyPacket.parse(packet.json)
        XCTAssertEqual(restored, packet)
        XCTAssertTrue(packet.json.contains(#""v":1"#))
        XCTAssertTrue(packet.json.contains(#""by":"owner""#))
    }

    func testSelfWrapForInviteLink() throws {
        let me = Ecdh.generateKeyPair()
        let groupKey = RstCrypto.randomAesKey()
        let packet = try GroupKeyCrypto.wrap(groupKey, myUsername: "me", myPrivateKey: me.privateKey, memberPublicKey: me.publicKey)
        XCTAssertEqual(try GroupKeyCrypto.unwrap(packet, myPrivateKey: me.privateKey, packerPublicKey: me.publicKey).rawData, groupKey.rawData)
    }

    func testStrangerCannotUnwrap() throws {
        let owner = Ecdh.generateKeyPair()
        let member = Ecdh.generateKeyPair()
        let stranger = Ecdh.generateKeyPair()
        let packet = try GroupKeyCrypto.wrap(RstCrypto.randomAesKey(), myUsername: "owner", myPrivateKey: owner.privateKey, memberPublicKey: member.publicKey)
        XCTAssertThrowsError(try GroupKeyCrypto.unwrap(packet, myPrivateKey: stranger.privateKey, packerPublicKey: owner.publicKey))
    }

    func testOldGroupMessagesReadWithLegacyKey() throws {
        let keys = ChatKeys.secureGroup(RstCrypto.randomAesKey(), groupId: "42")
        let old = try RstCrypto.encryptToPacked(key: RstCrypto.legacyGroupKey(groupId: "42"), plaintext: "до перехода")
        let new = try MessageCrypto.encryptText(keys, "после перехода")
        XCTAssertEqual(MessageCrypto.decrypt(keys, old), .text("до перехода"))
        XCTAssertEqual(MessageCrypto.decrypt(keys, new), .text("после перехода"))
        XCTAssertFalse(keys.isInsecureGroup)
    }

    /// С 2026-09-27: без своей копии писать ключом из номера можно только
    /// если настоящего ключа нет ни у кого.
    func testGroupWithoutOwnKeyDoesNotSilentlyFallBack() {
        XCTAssertEqual(groupStateWithoutOwnKey(remembered: true, someoneHasKey: false), .pending)
        XCTAssertEqual(groupStateWithoutOwnKey(remembered: false, someoneHasKey: true), .pending)
        XCTAssertEqual(groupStateWithoutOwnKey(remembered: false, someoneHasKey: nil), .pending)
        XCTAssertEqual(groupStateWithoutOwnKey(remembered: false, someoneHasKey: false), .insecure)
    }

    func testInviteLinkParsing() {
        let keyB64 = RstCrypto.randomBytes(32).base64EncodedString()
        let link = InviteLink.parse("https://rst-msg.ru/join/abc123XYZ#k=\(keyB64)")
        XCTAssertEqual(link?.inviteHash, "abc123XYZ")
        XCTAssertEqual(link?.groupKeyB64, keyB64)

        let noKey = InviteLink.parse("https://rst-msg.ru/join/abc123")
        XCTAssertEqual(noKey?.inviteHash, "abc123")
        XCTAssertFalse(noKey?.hasKey ?? true)
        XCTAssertNil(InviteLink.parse("https://rst-msg.ru/chats"))

        let raw = RstCrypto.randomBytes(32)
        let percent = raw.base64EncodedString().replacingOccurrences(of: "+", with: "%2B")
            .replacingOccurrences(of: "/", with: "%2F").replacingOccurrences(of: "=", with: "%3D")
        XCTAssertEqual(InviteLink.parse("https://rst-msg.ru/join/abc#k=\(raw.base64URLEncodedString)")?.groupKeyB64, raw.base64EncodedString())
        XCTAssertEqual(InviteLink.parse("https://rst-msg.ru/join/abc#k=\(percent)")?.groupKeyB64, raw.base64EncodedString())

        XCTAssertFalse(InviteLink.parse("https://rst-msg.ru/join/abc#k=не-ключ")?.hasKey ?? true)
        XCTAssertFalse(InviteLink.parse("https://rst-msg.ru/join/abc#k=" + RstCrypto.randomBytes(16).base64EncodedString())?.hasKey ?? true)
    }

    // MARK: - Код безопасности и ключ восстановления

    func testSafetyCodeMatchesReference() {
        let alice = Jwk(x: "f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU", y: "x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0")
        let bob = Jwk(x: "gI0GAILBdu7T53akrFmMyGcsF3n5dO7MmwNBHKW5SV0", y: "SLW_xSffzlPWrHEVI30DHM_4egVwt3NQqeUD7nMFpps")
        let expected = "26102 40759 08823 46231 25812 63874 05952 54408 26778 65393 48503 49219".split(separator: " ").map(String.init)
        XCTAssertEqual(SafetyCode.compute(mine: alice, theirs: bob), expected)
        XCTAssertEqual(SafetyCode.compute(mine: bob, theirs: alice), expected)
        XCTAssertEqual(SafetyCode.fingerprint(alice), "0mnyklSOpaVESJFd0U5t6Sd4wD9wyOSQCAhSQzs2BY0=")
    }

    func testRecoveryCodeFromKnownBytes() {
        XCTAssertEqual(RecoveryCode.generate(random: Data((0..<20).map { UInt8($0) })), "AAAS-EA2E-AWDA-QCAK-BJFS-2DJQ-B6JB-CESV")
        XCTAssertEqual(RecoveryCode.generate().count, 39)
    }

    func testRecoveryNormalization() {
        XCTAssertEqual(RecoveryCode.normalize("aaas-ea2e awda-qcak-bjfs-2djq-b6jb-cesv"), "AAASEA2EAWDAQCAKBJFS2DJQB6JBCESV")
        XCTAssertNil(RecoveryCode.normalize("пароль123"))
        XCTAssertNil(RecoveryCode.normalize("OAAS-EA2E-AWDA-QCAK-BJFS-2DJQ-B6JB-CES0"))
    }

    func testRecoveryDerivation() {
        let derived = RecoveryCode.derive(normalizedCode: "AAASEA2EAWDAQCAKBJFS2DJQB6JBCESV", salt: "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(derived.key.rawData.base64EncodedString(), "jaD1WKuPzDLEk9cbjnfoTWYuyZ63fLe6fUxFvwsn2G8=")
        XCTAssertEqual(derived.authHex, "ae2d1eb83398b62b40a1f8a9977aeb5005abbc08bd94a2af44a3c66d2c20db16")
    }

    func testTokenExpiry() {
        func token(exp: TimeInterval) -> String {
            let payload = Data(#"{"sub":"ivan","exp":\#(Int(exp))}"#.utf8).base64URLEncodedString
            return "eyJhbGciOiJIUzI1NiJ9.\(payload).sig"
        }
        XCTAssertTrue(AuthRepository.tokenExpired(token(exp: Date().timeIntervalSince1970 - 10)))
        XCTAssertFalse(AuthRepository.tokenExpired(token(exp: Date().timeIntervalSince1970 + 3600)))
        XCTAssertTrue(AuthRepository.tokenExpired("мусор"))
    }
}
