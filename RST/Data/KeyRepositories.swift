import CryptoKit
import Foundation

/// Кеш ключей переписки в памяти: вывод ECDH на каждое сообщение заметно
/// тормозит длинные чаты. Очищается при выходе из аккаунта.
@MainActor
final class ChatKeyCache {
    private var keys: [String: ChatKeys] = [:]

    func get(_ chatId: String) -> ChatKeys? { keys[chatId] }
    func put(_ chatId: String, _ value: ChatKeys) { keys[chatId] = value }
    func invalidate(_ chatId: String) { keys[chatId] = nil }
    func clear() { keys.removeAll() }
}

/// Ключи текущего пользователя и публичные ключи собеседников.
///
/// Открытые ключи раздаёт сервер, и нечестный сервер мог бы подсунуть свой.
/// Поэтому отпечаток ключа каждого собеседника запоминается при первой
/// встрече; сменился — в переписке предупреждение.
@MainActor
final class UserKeyRepository {
    private let api: RstApi
    private let session: SessionStore
    private var publicJwks: [String: Jwk] = [:]
    private var publicKeys: [String: P256.KeyAgreement.PublicKey] = [:]
    private var cachedPrivateKey: P256.KeyAgreement.PrivateKey?
    private let knownKeys = UserDefaults.standard

    /// Собеседники, чей открытый ключ сменился с прошлой встречи.
    private(set) var keyChanged: Set<String> = []

    init(api: RstApi, session: SessionStore) {
        self.api = api
        self.session = session
    }

    var myUsername: String {
        get throws {
            guard let name = session.username else { throw CryptoError("Нет активной сессии") }
            return name
        }
    }

    func myPrivateKey() throws -> P256.KeyAgreement.PrivateKey {
        if let cachedPrivateKey { return cachedPrivateKey }
        guard let jwk = session.privateKeyJwk else { throw CryptoError("Приватный ключ не восстановлен") }
        let key = try Ecdh.importPrivateJwk(jwk)
        cachedPrivateKey = key
        return key
    }

    /// Свой публичный ключ — из расшифрованного закрытого, а не с сервера.
    func myPublicKey() throws -> P256.KeyAgreement.PublicKey { try myPrivateKey().publicKey }

    func myPublicJwk() throws -> Jwk {
        guard let json = session.privateKeyJwk else { throw CryptoError("Приватный ключ не восстановлен") }
        return try Jwk.parse(json).publicOnly
    }

    func clear() {
        cachedPrivateKey = nil
        publicKeys.removeAll()
        publicJwks.removeAll()
        keyChanged.removeAll()
    }

    /// Собеседник перевыпустил ключи — забыть закешированный.
    func forget(_ username: String) {
        publicKeys[username] = nil
        publicJwks[username] = nil
    }

    /// Публичный ключ собеседника. Нет ключа (404 или пустое поле) —
    /// CryptoError: вызывающий решает, ошибка это или норма.
    func publicKey(of username: String) async throws -> P256.KeyAgreement.PublicKey {
        if let key = publicKeys[username] { return key }
        if username == session.username { return try myPublicKey() }
        let jwk = try await publicJwk(of: username)
        let key = try Ecdh.importPublicJwk(jwk)
        publicKeys[username] = key
        return key
    }

    func publicJwk(of username: String) async throws -> Jwk {
        if let jwk = publicJwks[username] { return jwk }
        let fetched: String?
        do {
            fetched = try await api.keys(username).publicKey
        } catch let error as ApiError where error.code == 404 {
            fetched = nil
        }
        guard let raw = fetched, !raw.isEmpty else { throw CryptoError("У пользователя \(username) нет опубликованного ключа") }
        let jwk = try Jwk.parse(raw)
        rememberFingerprint(username, jwk)
        publicJwks[username] = jwk
        return jwk
    }

    /// Ключ личной переписки: ECDH между своим приватным и публичным ключом собеседника.
    func directChatKeys(_ peer: String) async throws -> ChatKeys {
        let peerKey = try await publicKey(of: peer)
        return .direct(try Ecdh.deriveSharedKey(privateKey: myPrivateKey(), peerPublicKey: peerKey))
    }

    /// Код безопасности переписки: 12 групп по 5 цифр, совпадает с вебом.
    func safetyCode(_ peer: String) async throws -> [String] {
        let mine = try myPublicJwk()
        let theirs = try await publicJwk(of: peer)
        return SafetyCode.compute(mine: mine, theirs: theirs)
    }

    func acknowledgeKeyChange(_ username: String) { keyChanged.remove(username) }

    private func rememberFingerprint(_ username: String, _ jwk: Jwk) {
        guard let me = session.username else { return }
        let entry = "rst.known_key.\(me)|\(username)"
        let fingerprint = SafetyCode.fingerprint(jwk)
        let previous = knownKeys.string(forKey: entry)
        if let previous, previous != fingerprint { keyChanged.insert(username) }
        if previous != fingerprint { knownKeys.set(fingerprint, forKey: entry) }
    }
}

/// Получение и раздача ключей групп.
///
/// Главное правило (с 2026-09-27): писать ключом из номера группы можно, только
/// если настоящего ключа нет ни у кого. Иначе серверу достаточно ответить
/// «ключа нет», чтобы молча снять шифрование с любой группы.
///
/// groupId здесь — номер без префикса group_.
@MainActor
final class GroupKeyRepository {
    static let prefix = "group_"

    private let api: RstApi
    private let userKeys: UserKeyRepository
    /// Ключ, которым ничего не расшифровалось: кто-то передал негодный пакет.
    private var rejected: Set<String> = []

    init(api: RstApi, userKeys: UserKeyRepository) {
        self.api = api
        self.userKeys = userKeys
    }

    // MARK: Группы, где у нас хоть раз был настоящий ключ

    private func secureKey(_ me: String) -> String { "rst.secure_groups.\(me)" }

    private func remember(_ me: String, _ chatId: String) {
        var set = Set(UserDefaults.standard.stringArray(forKey: secureKey(me)) ?? [])
        guard !set.contains(chatId) else { return }
        set.insert(chatId)
        UserDefaults.standard.set(Array(set), forKey: secureKey(me))
    }

    private func remembered(_ me: String, _ chatId: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: secureKey(me)) ?? []).contains(chatId)
    }

    // MARK: Ключи

    /// Откат на прежний ключ — только когда своей копии действительно нет:
    /// 404, пустой encrypted_key или пакет, который не расшифровался. Сетевую
    /// ошибку пропускаем наверх: временный сбой не должен превращать
    /// защищённую группу в незащищённую.
    func keys(for groupId: String) async throws -> ChatKeys {
        let chatId = Self.prefix + groupId
        let me = try userKeys.myUsername
        if rejected.contains(chatId) { return await withoutOwnKey(groupId, me: me) }

        let encrypted: String?
        do {
            encrypted = try await api.groupKey(groupId: chatId, username: me).encryptedKey
        } catch let error as ApiError where error.code == 404 {
            encrypted = nil
        }
        guard let packet = GroupKeyPacket.parse(encrypted) else { return await withoutOwnKey(groupId, me: me) }

        let packer: P256.KeyAgreement.PublicKey
        do {
            packer = try await userKeys.publicKey(of: packet.packedBy)
        } catch is CryptoError {
            return await withoutOwnKey(groupId, me: me)
        }
        do {
            let groupKey = try GroupKeyCrypto.unwrap(packet, myPrivateKey: userKeys.myPrivateKey(), packerPublicKey: packer)
            // Настоящий ключ был — эта группа больше не откатится на ключ из номера
            remember(me, chatId)
            return .secureGroup(groupKey, groupId: groupId)
        } catch {
            return await withoutOwnKey(groupId, me: me)
        }
    }

    private func withoutOwnKey(_ groupId: String, me: String) async -> ChatKeys {
        let chatId = Self.prefix + groupId
        let wasSecure = remembered(me, chatId)
        var someoneHasKey: Bool? = true
        if !wasSecure {
            someoneHasKey = try? await api.groupInfo(chatId).members?.contains { $0.hasKey == true }
        }
        switch groupStateWithoutOwnKey(remembered: wasSecure, someoneHasKey: someoneHasKey) {
        case .insecure: return .legacyGroup(groupId: groupId)
        default: return .pendingGroup(groupId: groupId)
        }
    }

    /// Упаковывает ключ группы для перечисленных участников: имя -> JSON пакета.
    /// У кого нет ключа (не завершил настройку) — пропускаем: ему потом
    /// передаст любой участник через share_key.
    func pack(_ groupKey: SymmetricKey, for members: [String]) async throws -> [String: String] {
        let me = try userKeys.myUsername
        let priv = try userKeys.myPrivateKey()
        var result: [String: String] = [:]
        for member in members {
            let pub: P256.KeyAgreement.PublicKey
            do {
                pub = try await userKeys.publicKey(of: member)
            } catch is CryptoError {
                continue
            }
            result[member] = try GroupKeyCrypto.wrap(groupKey, myUsername: me, myPrivateKey: priv, memberPublicKey: pub).json
        }
        return result
    }

    /// Добавление участников. Копии ключа — только настоящего: прежний
    /// раздавать бессмысленно и вредно. Возвращает число пропущенных сервером.
    func addMembers(groupId: String, keys: ChatKeys, members: [String]) async throws -> Int {
        var encrypted: [String: String] = [:]
        if let real = keys.realGroupKey { encrypted = try await pack(real, for: members) }
        let response = try await api.addMembers(GroupAddMembersRequest(groupId: Self.prefix + groupId, members: members, encryptedKeys: encrypted))
        return response.skipped ?? 0
    }

    /// Раздать ключ участникам без копии: вступили по короткой ссылке или
    /// через поиск. Тихо: не вышло — раздаст кто-то другой.
    func shareWithNewcomers(groupId: String, keys: ChatKeys, members: [GroupMemberDto]) async {
        guard let groupKey = keys.realGroupKey, let me = try? userKeys.myUsername else { return }
        let waiting = members.filter { $0.hasKey != true && $0.username != me }.map(\.username)
        for username in waiting {
            guard let packet = try? await pack(groupKey, for: [username])[username] else { continue }
            _ = try? await api.shareGroupKey(groupId: Self.prefix + groupId, username: username, encryptedKey: packet)
        }
    }

    /// Ключ передал другой участник — проверяем его делом: хоть одно из
    /// последних сообщений должно расшифроваться. Не вышло — остаёмся на прежнем.
    func verifySharedKey(groupId: String, me: String, fresh: ChatKeys) async -> Bool {
        let chatId = Self.prefix + groupId
        guard let recent = try? await api.messages(me: me, peer: chatId, limit: 5).messages else { return true }
        let candidates = recent.filter { !$0.isSystem && ($0.content ?? "").contains("\"iv\"") }
        if candidates.isEmpty { return true }
        let fits = candidates.contains { MessageCrypto.decrypt(fresh, $0.content) != .undecryptable }
        if !fits { rejected.insert(chatId) }
        return fits
    }

    /// Создание группы: случайный ключ, упакованный каждому участнику и себе.
    func createGroup(name: String, description: String?, members: [String], channel: Bool) async throws -> (String, Int) {
        let me = try userKeys.myUsername
        let groupKey = RstCrypto.randomAesKey()
        let everyone = Array(Set(members + [me]))
        let encrypted = try await pack(groupKey, for: everyone)
        guard encrypted[me] != nil else { throw CryptoError("Не удалось упаковать ключ группы для себя") }
        let response = try await api.createGroup(GroupCreateRequest(
            name: name, description: description, members: members.filter { $0 != me },
            encryptedKeys: encrypted, kind: channel ? "channel" : nil))
        let chatId = response.groupId.hasPrefix(Self.prefix) ? response.groupId : Self.prefix + response.groupId
        remember(me, chatId)
        return (chatId, response.skipped ?? 0)
    }

    /// Вступление по ссылке: ключ приходит во фрагменте адреса, поэтому после
    /// вступления его нужно упаковать для себя и сохранить на сервере.
    func join(invite: InviteLink) async throws -> String {
        let resolved = try await api.resolveInvite(invite.inviteHash).groupId
        let groupId = resolved.hasPrefix(Self.prefix) ? String(resolved.dropFirst(Self.prefix.count)) : resolved
        let chatId = Self.prefix + groupId
        guard let keyB64 = invite.groupKeyB64, let raw = Data(base64Encoded: keyB64) else { return chatId }
        let me = try userKeys.myUsername
        let priv = try userKeys.myPrivateKey()
        let packet = try GroupKeyCrypto.wrap(SymmetricKey(data: raw), myUsername: me, myPrivateKey: priv, memberPublicKey: priv.publicKey)
        try await api.setMyGroupKey(groupId: chatId, encryptedKey: packet.json)
        remember(me, chatId)
        return chatId
    }

    /// Публичная группа из поиска: ключ передаст кто-то из участников.
    func joinPublic(chatId: String) async throws {
        try await api.joinPublic(groupId: chatId)
    }

    /// Включить сквозное шифрование в старой группе: новый случайный ключ,
    /// своя копия через set_my_key, остальным — share_key.
    func enableEncryption(groupId: String) async throws -> Int {
        let chatId = Self.prefix + groupId
        let me = try userKeys.myUsername
        let info = try await api.groupInfo(chatId)
        let members = info.members ?? []
        if members.contains(where: { $0.hasKey == true }) { throw CryptoError("В группе уже есть ключ шифрования") }
        let groupKey = RstCrypto.randomAesKey()
        guard let mine = try await pack(groupKey, for: [me])[me] else { throw CryptoError("Не удалось упаковать ключ для себя") }
        try await api.setMyGroupKey(groupId: chatId, encryptedKey: mine)
        remember(me, chatId)
        let others = members.map(\.username).filter { $0 != me }
        let packets = try await pack(groupKey, for: others)
        var failed = 0
        for username in others {
            guard let packet = packets[username] else { failed += 1; continue }
            if (try? await api.shareGroupKey(groupId: chatId, username: username, encryptedKey: packet)) == nil { failed += 1 }
        }
        rejected.remove(chatId)
        return failed
    }

    /// Ссылка-приглашение с ключом во фрагменте: на сервер ключ не уходит.
    func inviteLink(base: URL, inviteHash: String, keys: ChatKeys?) -> String {
        var link = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/join/" + inviteHash
        if let key = keys?.realGroupKey {
            link += "#k=" + key.rawData.base64EncodedString()
        }
        return link
    }
}

/// Ссылка-приглашение: https://домен/join/<invite_hash>#k=<base64 ключа группы>.
struct InviteLink: Equatable {
    let inviteHash: String
    /// Стандартный base64 ключа (32 байта) или nil, если ключа во фрагменте нет.
    let groupKeyB64: String?

    var hasKey: Bool { groupKeyB64 != nil }

    static func parse(_ raw: String) -> InviteLink? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Фрагмент разбираем сами: в нём может оказаться что угодно, и
        // URLComponents отказался бы от всей ссылки целиком.
        let hashIndex = trimmed.firstIndex(of: "#")
        let main = hashIndex.map { String(trimmed[..<$0]) } ?? trimmed
        let fragment = hashIndex.map { String(trimmed[trimmed.index(after: $0)...]) }
        guard let components = URLComponents(string: main) else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "join"), index + 1 < parts.count else { return nil }
        let hash = parts[index + 1]
        guard !hash.isEmpty else { return nil }

        var key: String?
        if let fragment {
            for pair in fragment.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2, kv[0] == "k" else { continue }
                let value = kv[1].removingPercentEncoding ?? kv[1]
                // Ключ может прийти и в base64url — приводим к обычному
                if let raw = Data(base64Encoded: value) ?? Data(base64URLEncoded: value), raw.count == 32 {
                    key = raw.base64EncodedString()
                }
            }
        }
        return InviteLink(inviteHash: hash, groupKeyB64: key)
    }
}
