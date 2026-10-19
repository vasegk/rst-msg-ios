import CryptoKit
import Foundation
import Security

/// Обёртка над связкой ключей iOS. Секреты (токен, KEK, приватный JWK)
/// хранятся только здесь — не в UserDefaults и не в логах.
enum Keychain {
    private static let service = "ru.rstmsg.messenger"

    static func read(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    static func write(_ account: String, _ data: Data) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Только это устройство и только после первой разблокировки:
            // в резервную копию и на другой телефон секреты не уезжают.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            attributes.forEach { add[$0.key] = $0.value }
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Данные входа одного аккаунта. Пароль не хранится нигде: из него один раз
/// выводится KEK, а приватный ключ расшифровывается им при входе.
struct StoredSession: Codable, Equatable {
    var accessToken: String
    var username: String
    var originalUsername: String
    var kdfSalt: String
    var kdfIterations: Int
    var kekB64: String
    var privateKeyJwk: String?
    var tokenRefreshedAt: Date
}

/// Текущий сеанс: копия в памяти плюс связка ключей. Другие аккаунты этого
/// устройства (как js/accounts.js) лежат рядом списком — переключение не
/// требует пароля.
final class SessionStore {
    private let account = "session.current"
    private let savedAccount = "session.saved"
    private(set) var current: StoredSession?
    /// Остальные аккаунты на устройстве, без текущего.
    private(set) var saved: [StoredSession] = []

    init() {
        if let data = Keychain.read(account) {
            current = try? JSONDecoder().decode(StoredSession.self, from: data)
        }
        if let data = Keychain.read(savedAccount) {
            saved = (try? JSONDecoder().decode([StoredSession].self, from: data)) ?? []
        }
    }

    private func persistSaved() {
        if saved.isEmpty {
            Keychain.delete(savedAccount)
        } else if let data = try? JSONEncoder().encode(saved) {
            Keychain.write(savedAccount, data)
        }
    }

    /// «Добавить аккаунт»: текущий — в список, вход начинается с чистого листа.
    func parkCurrent() {
        guard let c = current, c.privateKeyJwk != nil else { return }
        saved.removeAll { $0.username == c.username }
        saved.insert(c, at: 0)
        persistSaved()
        current = nil
        Keychain.delete(account)
    }

    /// Сделать текущим аккаунт из списка; прежний текущий уходит в список.
    @discardableResult
    func activate(_ username: String) -> Bool {
        guard let i = saved.firstIndex(where: { $0.username == username }) else { return false }
        let next = saved.remove(at: i)
        if let c = current, c.privateKeyJwk != nil { saved.insert(c, at: 0) }
        persistSaved()
        save(next)
        return true
    }

    /// Убрать аккаунт из списка (сеанс кончился или вышли из него).
    func forgetSaved(_ username: String) {
        saved.removeAll { $0.username == username }
        persistSaved()
    }

    var isLoggedIn: Bool { current?.privateKeyJwk != nil }
    var accessToken: String? { current?.accessToken }
    var username: String? { current?.username }
    var privateKeyJwk: String? { current?.privateKeyJwk }
    var kek: SymmetricKey? {
        guard let b64 = current?.kekB64, let raw = Data(base64Encoded: b64) else { return nil }
        return SymmetricKey(data: raw)
    }

    func save(_ session: StoredSession) {
        current = session
        if saved.contains(where: { $0.username == session.username }) { forgetSaved(session.username) }
        if let data = try? JSONEncoder().encode(session) { Keychain.write(account, data) }
    }

    func update(_ change: (inout StoredSession) -> Void) {
        guard var s = current else { return }
        change(&s)
        save(s)
    }

    func replaceToken(_ token: String) {
        update {
            $0.accessToken = token
            $0.tokenRefreshedAt = Date()
        }
    }

    func clear() {
        current = nil
        Keychain.delete(account)
    }
}

/// Постоянный идентификатор установки для адреса сокета
/// wss://<домен>/ws/{username}/{device_id}. Генерируется один раз.
enum DeviceId {
    private static let key = "rst.device_id"

    static var value: String {
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }
}
