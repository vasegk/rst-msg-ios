import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Истории (как js/stories.js, сервер — routers/stories.py): фото или видео
/// с подписью на сутки.
///
/// У каждой истории свой случайный ключ: им шифруется конверт {f, m, c}
/// (ключ файла, тип, подпись) и комментарии; файл — как обычное вложение,
/// своим ключом. Ключ истории упакован для каждого зрителя ECDH между
/// автором и зрителем — так же, как ключ группы ({"v":1,"by",...}).
@MainActor
@Observable
final class StoryStore {
    struct Opened {
        let fileURL: URL
        let mime: String
        let caption: String
        let key: SymmetricKey
        var isVideo: Bool { mime.hasPrefix("video/") }
    }

    struct Comment: Identifiable {
        let id: Int64
        let author: String
        let name: String
        let avatarUrl: String?
        let text: String
        let createdAt: Date?
        let canDelete: Bool
    }

    struct Outgoing {
        let data: Data
        let mime: String
    }

    static let maxPerPublish = 10

    private(set) var authors: [StoryAuthorDto] = []
    var error: String?

    @ObservationIgnored private let api: RstApi
    @ObservationIgnored private let userKeys: UserKeyRepository
    @ObservationIgnored private let attachments: AttachmentRepository
    @ObservationIgnored private let me: () -> String
    @ObservationIgnored private var opened: [String: Opened] = [:]
    @ObservationIgnored private var subscription: UUID?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    init(api: RstApi, userKeys: UserKeyRepository, attachments: AttachmentRepository, socket: RstWebSocket,
         me: @escaping () -> String) {
        self.api = api
        self.userKeys = userKeys
        self.attachments = attachments
        self.me = me
        subscription = socket.subscribe(owner: self) { [weak self] event in
            guard case .other(let action, _) = event, action.hasPrefix("story_") else { return }
            self?.scheduleReload()
        }
    }

    var mine: StoryAuthorDto? { authors.first { $0.author == me() } }
    var others: [StoryAuthorDto] { authors.filter { $0.author != me() } }

    func clear() {
        authors = []
        opened = [:]
    }

    func load() async {
        do {
            authors = try await api.stories().authors ?? []
            error = nil
        } catch {
            self.error = errorText(error)
        }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    // MARK: - Просмотр

    func open(_ story: StoryDto, author: String) async throws -> Opened {
        let cacheKey = "\(story.id)|\(story.fileUrl)"
        if let ready = opened[cacheKey] { return ready }
        guard let packet = GroupKeyPacket.parse(story.key), packet.packedBy == author else {
            throw CryptoError("Ключ истории упакован не автором")
        }
        let pub = author == me() ? try userKeys.myPublicKey() : try await userKeys.publicKey(of: author)
        let key = try GroupKeyCrypto.unwrap(packet, myPrivateKey: try userKeys.myPrivateKey(), packerPublicKey: pub)
        let plain = try RstCrypto.decryptPacked(key: key, packed: story.content)
        guard let env = JSONValue.parse(plain), let fileKey = env["f"]?.string else {
            throw CryptoError("Не удалось расшифровать историю")
        }
        let mime = env["m"]?.string ?? "image/jpeg"
        let ext = UTType(mimeType: mime)?.preferredFilenameExtension ?? (mime.hasPrefix("video/") ? "mp4" : "jpg")
        let attachment = Attachment(fileUrl: story.fileUrl, fileKeyB64: fileKey, fileName: "story_\(story.id).\(ext)", mimeType: mime)
        let url = try await attachments.fileURL(for: attachment)
        let result = Opened(fileURL: url, mime: mime, caption: env["c"]?.string ?? "", key: key)
        opened[cacheKey] = result
        return result
    }

    /// Просмотрел чужую — отметка у автора; локально кольцо гаснет сразу.
    func markViewed(_ story: StoryDto, author: String) {
        guard author != me(), story.viewed != true else { return }
        update(story.id) { $0.viewed = true }
        Task { try? await api.viewStory(story.id) }
    }

    func like(_ story: StoryDto, liked: Bool) async {
        update(story.id) { $0.liked = liked }
        do {
            try await api.likeStory(story.id, liked: liked)
        } catch {
            update(story.id) { $0.liked = !liked }
            self.error = errorText(error)
        }
    }

    func delete(_ story: StoryDto) async throws {
        try await api.deleteStory(story.id)
        await load()
    }

    func viewers(_ story: StoryDto) async throws -> StoryViewersResponse {
        try await api.storyViewers(story.id)
    }

    private func update(_ id: Int64, _ change: (inout StoryDto) -> Void) {
        for a in authors.indices {
            if let s = authors[a].stories.firstIndex(where: { $0.id == id }) {
                change(&authors[a].stories[s])
                return
            }
        }
    }

    // MARK: - Комментарии (шифруются ключом истории)

    func comments(_ story: StoryDto, author: String, names: (String) -> String) async throws -> [Comment] {
        let key = try await open(story, author: author).key
        let list = try await api.storyComments(story.id).comments ?? []
        let mine = me()
        return list.map { c in
            let text = (try? RstCrypto.decryptPacked(key: key, packed: c.content)) ?? "🔒 Не удалось расшифровать"
            return Comment(id: c.id, author: c.author, name: c.author == mine ? "Вы" : (c.displayName ?? names(c.author)),
                           avatarUrl: c.avatarUrl, text: text, createdAt: ServerTime.parse(c.createdAt), canDelete: c.canDelete ?? false)
        }
    }

    func addComment(_ story: StoryDto, author: String, text: String) async throws {
        let key = try await open(story, author: author).key
        try await api.addStoryComment(story.id, content: try RstCrypto.encryptToPacked(key: key, plaintext: text))
    }

    func deleteComment(_ story: StoryDto, comment: Int64) async throws {
        try await api.deleteStoryComment(story: story.id, comment: comment)
    }

    // MARK: - Публикация

    /// Каждый файл — своя история: зашифровать, загрузить, упаковать ключ
    /// себе и каждому из аудитории, опубликовать.
    func publish(_ files: [Outgoing], caption: String) async throws {
        let audience = try await api.storyAudience().viewers ?? []
        var pubs: [String: P256.KeyAgreement.PublicKey] = [:]
        for name in audience {
            if let key = try? await userKeys.publicKey(of: name) { pubs[name] = key }
        }
        let myPriv = try userKeys.myPrivateKey()
        let myPub = try userKeys.myPublicKey()
        let author = me()
        for file in files.prefix(Self.maxPerPublish) {
            let uploaded = try await attachments.upload(file.data)
            let storyKey = RstCrypto.randomAesKey()
            let envelope = JSONCoding.encodeString(JSONValue.object([
                "f": .string(uploaded.keyB64), "m": .string(file.mime), "c": .string(caption),
            ]))
            let content = try RstCrypto.encryptToPacked(key: storyKey, plaintext: envelope)
            var keys = [author: try GroupKeyCrypto.wrap(storyKey, myUsername: author, myPrivateKey: myPriv, memberPublicKey: myPub).json]
            for (name, pub) in pubs {
                keys[name] = try GroupKeyCrypto.wrap(storyKey, myUsername: author, myPrivateKey: myPriv, memberPublicKey: pub).json
            }
            _ = try await api.createStory(StoryCreateRequest(content: content, fileUrl: uploaded.fileUrl, keys: keys))
        }
        await load()
    }

    // MARK: - Скрыть мои истории от

    func hidden() async throws -> [String] { try await api.storyHidden().hidden ?? [] }

    func setHidden(_ names: [String]) async throws { try await api.setStoryHidden(names) }
}
