import CryptoKit
import Foundation

/// Регистрация, вход и восстановление сессии со всей схемой ключей.
///
/// Пароль не сохраняется нигде: из него один раз выводится KEK, и дальше
/// живёт только KEK — в связке ключей. Приватный ключ расшифровывается
/// KEK-ом при входе и тоже хранится только там.
@MainActor
final class AuthRepository {
    private let api: RstApi
    private let session: SessionStore
    private let userKeys: UserKeyRepository

    init(api: RstApi, session: SessionStore, userKeys: UserKeyRepository) {
        self.api = api
        self.session = session
        self.userKeys = userKeys
    }

    /// PBKDF2 на 600 000 итераций — не на главном потоке.
    private func deriveKek(_ password: String, salt: String, iterations: Int) async -> SymmetricKey {
        await Task.detached(priority: .userInitiated) {
            RstCrypto.deriveKek(password: password, kdfSalt: salt, iterations: iterations)
        }.value
    }

    private func save(_ login: LoginResponse, kek: SymmetricKey, privateJwk: String?) {
        session.save(StoredSession(
            accessToken: login.accessToken,
            username: login.username,
            originalUsername: login.originalUsername ?? login.username,
            kdfSalt: login.kdfSalt,
            kdfIterations: login.kdfIterations ?? RstCrypto.legacyKdfIterations,
            kekB64: kek.rawData.base64EncodedString(),
            privateKeyJwk: privateJwk,
            tokenRefreshedAt: Date()
        ))
        userKeys.clear()
    }

    /// Регистрация: пара ECDH создаётся на устройстве, на сервер уходит только
    /// публичный ключ и приватный, зашифрованный KEK-ом. keys/upload требует
    /// авторизации, поэтому сначала вход.
    func register(username: String, password: String, email: String) async throws {
        let registration = try await api.register(username: username, password: password, email: email,
                                                  kdfIterations: RstCrypto.kdfIterations)
        let pair = Ecdh.generateKeyPair()
        let kek = await deriveKek(password, salt: registration.kdfSalt,
                                  iterations: registration.kdfIterations ?? RstCrypto.legacyKdfIterations)
        let encrypted = try RstCrypto.encryptToPacked(key: kek, plaintext: pair.privateJwkJson)

        let login = try await api.login(username, password: password)
        save(login, kek: kek, privateJwk: nil)
        try await api.uploadKeys(username: login.username, publicKey: pair.publicJwkJson, encryptedPrivateKey: encrypted)
        session.update { $0.privateKeyJwk = pair.privateJwkJson }
        userKeys.clear()
    }

    /// Поле username принимает и имя, и адрес почты.
    func login(_ usernameOrEmail: String, password: String) async throws {
        let response = try await api.login(usernameOrEmail, password: password)
        // Итерации — из ответа: у аккаунтов после 2026-09-15 их 600 000,
        // и зашитое значение не расшифровало бы их приватный ключ.
        let kek = await deriveKek(password, salt: response.kdfSalt,
                                  iterations: response.kdfIterations ?? RstCrypto.legacyKdfIterations)
        save(response, kek: kek, privateJwk: nil)
        do {
            try await restorePrivateKey(response.username, kek: kek)
        } catch {
            session.clear()
            throw error
        }
        userKeys.clear()
    }

    /// Вход по QR-коду: пароля у этого устройства нет, поэтому вместо KEK из
    /// пароля — случайный ключ; приватный ключ пришёл от подтвердившего.
    func finishQrLogin(_ poll: QrPollResponse, privateJwk: String) throws {
        guard let token = poll.accessToken, let username = poll.username, let salt = poll.kdfSalt else {
            throw CryptoError("Сервер не прислал данные входа")
        }
        let login = LoginResponse(username: username, originalUsername: poll.originalUsername, kdfSalt: salt,
                                  kdfIterations: poll.kdfIterations, accessToken: token)
        save(login, kek: RstCrypto.randomAesKey(), privateJwk: privateJwk)
        userKeys.clear()
    }

    /// Подтвердить вход нового устройства своим приватным ключом.
    func approveQrLogin(_ link: QrLogin.Link) async throws {
        guard let jwk = session.privateKeyJwk else { throw CryptoError("На этом устройстве нет ключа шифрования — войдите заново") }
        let sealed = try QrLogin.approve(privateJwk: jwk, peerPub: link.pub)
        try await api.qrApprove(QrApproveRequest(session: link.session, pub: link.pub,
                                                 approverPub: sealed.approverPub, payload: sealed.payload))
    }

    /// Достаёт приватный ключ с сервера и расшифровывает KEK-ом. Если ключей
    /// на сервере нет вовсе (обрыв на регистрации) — создаём пару заново:
    /// переписки у такого пользователя ещё не было.
    private func restorePrivateKey(_ username: String, kek: SymmetricKey) async throws {
        var stored: String?
        do {
            stored = try await api.keys(username).encryptedPrivateKey
        } catch let error as ApiError where error.code == 404 {
            stored = nil
        }
        guard let encryptedKey = stored, !encryptedKey.isEmpty else {
            let pair = Ecdh.generateKeyPair()
            let encrypted = try RstCrypto.encryptToPacked(key: kek, plaintext: pair.privateJwkJson)
            try await api.uploadKeys(username: username, publicKey: pair.publicJwkJson, encryptedPrivateKey: encrypted)
            session.update { $0.privateKeyJwk = pair.privateJwkJson }
            return
        }
        let jwk: String
        do {
            jwk = try RstCrypto.decryptPacked(key: kek, packed: encryptedKey)
            _ = try Ecdh.importPrivateJwk(jwk)
        } catch {
            // Пароль верный (сервер уже его проверил), значит ключ
            // перевыпущен под другим паролем или повреждён.
            throw CryptoError("Не удалось расшифровать приватный ключ этим паролем")
        }
        session.update { $0.privateKeyJwk = jwk }
        await repairPublicKeyIfNeeded(username: username, encrypted: encryptedKey, privateJwk: jwk)
    }

    /// Открытый ключ на сервере с "d": null браузер не принимал — перезаписываем
    /// чистым, выведенным из своего закрытого. Ключ тот же, переписка цела.
    private func repairPublicKeyIfNeeded(username: String, encrypted: String, privateJwk: String) async {
        guard let current = try? await api.keys(username).publicKey,
              current.replacingOccurrences(of: " ", with: "").contains("\"d\":null"),
              let mine = try? Jwk.parse(privateJwk) else { return }
        try? await api.uploadKeys(username: username, publicKey: mine.publicOnly.json, encryptedPrivateKey: encrypted)
    }

    /// Автологин: сессия и ключи уже в связке ключей. Протухший по сроку
    /// токен сервер всё равно не примет — спрашивать незачем.
    func canRestoreSession() -> Bool {
        guard session.isLoggedIn, let token = session.accessToken else { return false }
        return !Self.tokenExpired(token)
    }

    /// Продлить токен, если с прошлой выдачи прошли сутки (живёт 30 дней).
    /// Без сети ничего не делаем: выкидывать человека из-за этого нельзя.
    func refreshTokenIfDue() async {
        guard let current = session.current, Date().timeIntervalSince(current.tokenRefreshedAt) > 24 * 3600 else { return }
        if let fresh = try? await api.refreshToken() { session.replaceToken(fresh.accessToken) }
    }

    /// Смена пароля: приватный ключ перешифровывает клиент — новая соль,
    /// новый KEK, тот же JWK. Остальные устройства получают force_logout.
    func changePassword(old: String, new: String) async throws {
        guard let jwk = session.privateKeyJwk else { throw CryptoError("Приватный ключ не восстановлен") }
        let salt = RstCrypto.newKdfSalt()
        let kek = await deriveKek(new, salt: salt, iterations: RstCrypto.kdfIterations)
        let encrypted = try RstCrypto.encryptToPacked(key: kek, plaintext: jwk)
        let response = try await api.changePassword(ChangePasswordRequest(
            oldPassword: old, newPassword: new, kdfSalt: salt, kdfIterations: RstCrypto.kdfIterations,
            encryptedPrivateKey: encrypted, currentDevice: DeviceId.value))
        session.update {
            $0.kdfSalt = response.kdfSalt
            $0.kdfIterations = response.kdfIterations
            $0.kekB64 = kek.rawData.base64EncodedString()
            $0.accessToken = response.accessToken
            $0.tokenRefreshedAt = Date()
        }
    }

    // MARK: - Ключ восстановления

    func recoveryEnabled() async throws -> Bool { try await api.recoveryStatus().enabled ?? false }

    /// Создать (или заменить) ключ восстановления. Код нужно показать
    /// человеку: больше он нигде не хранится.
    func createRecoveryKey(password: String) async throws -> String {
        guard let jwk = session.privateKeyJwk else { throw CryptoError("Приватный ключ не восстановлен") }
        let code = RecoveryCode.generate()
        let salt = RecoveryCode.newSalt()
        guard let normalized = RecoveryCode.normalize(code) else { throw CryptoError("Не удалось создать код") }
        let derived = await Task.detached(priority: .userInitiated) {
            RecoveryCode.derive(normalizedCode: normalized, salt: salt)
        }.value
        let blob = try RstCrypto.encryptToPacked(key: derived.key, plaintext: jwk)
        // Туда-обратно: откроется ли копия этим же кодом
        guard try RstCrypto.decryptPacked(key: derived.key, packed: blob) == jwk else {
            throw CryptoError("Проверка ключа восстановления не прошла")
        }
        try await api.recoverySetup(RecoverySetupRequest(password: password, recoverySalt: salt, recoveryKey: blob, recoveryAuth: derived.authHex))
        return code
    }

    /// «Забыли пароль?»: новый пароль по коду. Приватный ключ тот же — вся
    /// переписка остаётся. Прежние сеансы сервер отзывает.
    func resetPassword(login: String, code: String, newPassword: String) async throws {
        guard let normalized = RecoveryCode.normalize(code) else {
            throw CryptoError("Это не похоже на ключ восстановления: 32 знака, например ABCD-EFGH-…")
        }
        let begin = try await api.recoveryBegin(login)
        let iterations = begin.kdfIterations ?? RecoveryCode.iterations
        let derived = await Task.detached(priority: .userInitiated) {
            RecoveryCode.derive(normalizedCode: normalized, salt: begin.recoverySalt, iterations: iterations)
        }.value
        let unlocked = try await api.recoveryUnlock(login, auth: derived.authHex)
        let jwk: String
        do {
            jwk = try RstCrypto.decryptPacked(key: derived.key, packed: unlocked.recoveryKey)
            _ = try Ecdh.importPrivateJwk(jwk)
        } catch {
            throw CryptoError("Ключ восстановления не подходит")
        }
        let salt = RstCrypto.newKdfSalt()
        let kek = await deriveKek(newPassword, salt: salt, iterations: RstCrypto.kdfIterations)
        let blob = try RstCrypto.encryptToPacked(key: kek, plaintext: jwk)
        let response = try await api.recoveryReset(RecoveryResetRequest(
            username: login, recoveryAuth: derived.authHex, newPassword: newPassword, kdfSalt: salt,
            kdfIterations: RstCrypto.kdfIterations, encryptedPrivateKey: blob))
        save(response, kek: kek, privateJwk: jwk)
    }

    /// Завершить остальные сеансы: прежние токены отозваны, новый — наш.
    func terminateOtherSessions() async throws -> Int {
        guard let me = session.username else { return 0 }
        let response = try await api.terminateOtherSessions(username: me, deviceId: DeviceId.value)
        if let token = response.accessToken { session.replaceToken(token) }
        return response.closed ?? 0
    }

    /// Срок из самого токена. Разобрать не смогли — решать серверу.
    nonisolated static func tokenExpired(_ token: String) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return true }
        guard let payload = Data(base64URLEncoded: String(parts[1])),
              let obj = JSONValue.parse(String(decoding: payload, as: UTF8.self)),
              let exp = obj["exp"]?.int64 else { return false }
        return Double(exp) <= Date().timeIntervalSince1970
    }
}
