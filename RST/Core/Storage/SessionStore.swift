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

/// Текущий сеанс: копия в памяти плюс связка ключей.
final class SessionStore {
    private let account = "session.current"
    private(set) var current: StoredSession?

    init() {
        if let data = Keychain.read(account) {
            current = try? JSONDecoder().decode(StoredSession.self, from: data)
        }
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
