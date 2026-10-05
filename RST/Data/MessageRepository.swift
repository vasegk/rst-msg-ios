import Foundation

/// Сокет не подключён — сообщение не ушло, текст остаётся в поле ввода.
struct NotConnectedError: LocalizedError {
    var errorDescription: String? { "Нет соединения с сервером. Сообщение не отправлено" }
}

struct GroupKeyPendingError: LocalizedError {
    var errorDescription: String? {
        "Ключ шифрования группы ещё не пришёл: его передаст любой участник, когда будет в сети. Без ключа сообщение смог бы прочитать сервер."
    }
}

/// Переписка: получение истории, расшифровка и отправка.
///
/// chatId — имя собеседника либо group_<id>. Ключ чата считается один раз
/// и кладётся в кеш: вывод ECDH на каждое сообщение заметно тормозит.
@MainActor
final class MessageRepository {
    static let groupPrefix = "group_"
    static let quoteMax = 500

    private let api: RstApi
    private let session: SessionStore
    private let socket: RstWebSocket
    private let userKeys: UserKeyRepository
    private let groupKeys: GroupKeyRepository
    private let keyCache: ChatKeyCache

    /// Написанное без связи — как в вебе: сообщение уже зашифровано и ждёт,
    /// в ленте оно с часиками, а с возвращением связи уходит само. Только в памяти.
    struct Queued: Equatable {
        let localId: Int64
        let chatId: String
        let text: String
        let content: String
        let replyTo: Int64?
        let fileUrl: String?
        let createdAt: Date
    }

    private(set) var outbox: [Queued] = []
    private var queuedSeq: Int64 = 0
    var onOutboxChanged: @MainActor () -> Void = {}

    init(api: RstApi, session: SessionStore, socket: RstWebSocket, userKeys: UserKeyRepository,
         groupKeys: GroupKeyRepository, keyCache: ChatKeyCache) {
        self.api = api
        self.session = session
        self.socket = socket
        self.userKeys = userKeys
        self.groupKeys = groupKeys
        self.keyCache = keyCache
    }

    var me: String { session.username ?? "" }

    nonisolated static func isGroup(_ chatId: String) -> Bool { chatId.hasPrefix("group_") }

    /// К какому чату относится сообщение: для группы receiver уже group_<id>,
    /// для лички собеседник — тот из двоих, кто не я.
    func chatId(sender: String, receiver: String) -> String {
        if receiver.hasPrefix(Self.groupPrefix) { return receiver }
        return sender == me ? receiver : sender
    }

    // MARK: - Ключи

    /// Ключи чата — для отправки обязательны: нет ключа — ошибка.
    func keys(for chatId: String) async throws -> ChatKeys {
        if let cached = keyCache.get(chatId) { return cached }
        let keys: ChatKeys
        if Self.isGroup(chatId) {
            keys = try await groupKeys.keys(for: String(chatId.dropFirst(Self.groupPrefix.count)))
        } else {
            keys = try await userKeys.directChatKeys(chatId)
        }
        keyCache.put(chatId, keys)
        return keys
    }

    /// Ключи для чтения. У аккаунта поддержки ключей нет вовсе, а у удалённого
    /// собеседника публичный ключ мог быть стёрт — чат должен открываться с
    /// заглушками, а не с ошибкой вместо всего. Сетевые ошибки идут наверх.
    func readKeys(for chatId: String) async throws -> ChatKeys? {
        do {
            return try await keys(for: chatId)
        } catch is CryptoError {
            if Self.isGroup(chatId) { throw CryptoError("Не удалось получить ключ группы") }
            return nil
        }
    }

    func invalidateKeys(_ chatId: String) {
        keyCache.invalidate(chatId)
        if !Self.isGroup(chatId) { userKeys.forget(chatId) }
    }

    /// Ключ группы передал другой участник: перечитываем и проверяем делом.
    func onGroupKeyShared(_ chatId: String) async -> Bool {
        keyCache.invalidate(chatId)
        let groupId = String(chatId.dropFirst(Self.groupPrefix.count))
        guard let fresh = try? await groupKeys.keys(for: groupId) else { return false }
        guard fresh.realGroupKey != nil else {
            keyCache.put(chatId, fresh)
            return false
        }
        if await groupKeys.verifySharedKey(groupId: groupId, me: me, fresh: fresh) {
            keyCache.put(chatId, fresh)
            return true
        }
        if let fallback = try? await groupKeys.keys(for: groupId) { keyCache.put(chatId, fallback) }
        return false
    }

    private func sendKeys(for chatId: String) async throws -> ChatKeys {
        let keys = try await keys(for: chatId)
        if keys.isKeyPending { throw GroupKeyPendingError() }
        return keys
    }

    // MARK: - История

    struct History {
        let messages: [ChatMessage]
        let hasMore: Bool
        let oldestId: Int64?
    }

    /// Сервер отдаёт последние limit сообщений по порядку; для подгрузки
    /// вверх передаётся before_id = oldest_id.
    func history(_ chatId: String, beforeId: Int64? = nil, limit: Int = 100) async throws -> History {
        let response = try await api.messages(me: me, peer: chatId, limit: limit, beforeId: beforeId)
        let keys = try await readKeys(for: chatId)
        let list = (response.messages ?? []).filter { $0.commentTo == nil }
        return History(messages: list.map { decrypt($0, keys: keys) }, hasMore: response.hasMore ?? false, oldestId: response.oldestId)
    }

    /// Догнать пропущенное после перерыва: after_id отдаёт новее указанного
    /// от старых к новым, has_more — «ниже есть ещё».
    func since(_ chatId: String, afterId: Int64) async throws -> [ChatMessage] {
        let keys = try await readKeys(for: chatId)
        var result: [ChatMessage] = []
        var cursor = afterId
        for _ in 0..<10 {
            let page = try await api.messages(me: me, peer: chatId, limit: 200, afterId: cursor)
            let list = page.messages ?? []
            if list.isEmpty { break }
            result += list.filter { $0.commentTo == nil }.map { decrypt($0, keys: keys) }
            cursor = list.map(\.id).max() ?? cursor
            if page.hasMore != true { break }
        }
        return result
    }

    func pinned(_ chatId: String) async throws -> [ChatMessage] {
        let keys = try await readKeys(for: chatId)
        return (try await api.pinnedMessages(me: me, peer: chatId).messages ?? []).map { decrypt($0, keys: keys) }
    }

    func media(_ chatId: String) async throws -> [ChatMessage] {
        let keys = try await readKeys(for: chatId)
        return (try await api.media(me: me, peer: chatId).media ?? []).map { decrypt($0, keys: keys) }.filter { $0.attachment != nil }
    }

    func decryptSingle(_ dto: MessageDto, chatId: String) async -> ChatMessage {
        var keys: ChatKeys?
        if !dto.isSystem, let found = try? await readKeys(for: chatId) { keys = found }
        return decrypt(dto, keys: keys)
    }

    /// Расшифровка одного content в текст для превью (список чатов).
    func previewText(chatId: String, content: String?, fileType: String?) async -> String {
        if fileType == MessageDto.fileTypeSystem || fileType == MessageDto.fileTypeAutoreply {
            return Previews.system(content)
        }
        var keys: ChatKeys?
        if let found = try? await readKeys(for: chatId) { keys = found }
        return Previews.describe(MessageCrypto.decrypt(keys, content), fileType: fileType)
    }

    // MARK: - Отправка

    func sendText(_ chatId: String, text: String, replyTo: Int64? = nil, quote: String? = nil, forwardedFrom: String? = nil) async throws {
        let keys = try await sendKeys(for: chatId)
        let content: String
        if let quote, !quote.trimmingCharacters(in: .whitespaces).isEmpty {
            content = try MessageCrypto.encryptEnvelope(keys, Envelope(text: text, quote: String(quote.prefix(Self.quoteMax))))
        } else {
            content = try MessageCrypto.encryptText(keys, text)
        }
        if socket.sendMessage(receiver: chatId, content: content, replyTo: replyTo, forwardedFrom: forwardedFrom) { return }
        // Пересылку без сервера не проверить — честная ошибка; обычное — в очередь
        if forwardedFrom != nil { throw NotConnectedError() }
        enqueue(chatId: chatId, text: text, content: content, replyTo: replyTo, fileUrl: nil)
    }

    func sendAttachment(_ chatId: String, text: String, fileUrl: String, fileKeyB64: String, fileName: String,
                        mimeType: String, replyTo: Int64? = nil, forwardedFrom: String? = nil) async throws {
        let keys = try await sendKeys(for: chatId)
        let content = try MessageCrypto.encryptEnvelope(keys, Envelope(text: text, fileKeyB64: fileKeyB64, fileName: fileName, mimeType: mimeType))
        // Файл ушёл зашифрованным, поэтому тип всегда двоичный поток:
        // настоящий MIME лежит в конверте, в поле m.
        if socket.sendMessage(receiver: chatId, content: content, fileUrl: fileUrl, fileType: RstApi.attachmentMime,
                              replyTo: replyTo, forwardedFrom: forwardedFrom) { return }
        if forwardedFrom != nil { throw NotConnectedError() }
        // Файл уже на сервере, а сокет как раз переподключается — send ждёт в очереди
        enqueue(chatId: chatId, text: text.isEmpty ? "📎 Вложение" : text, content: content, replyTo: replyTo, fileUrl: fileUrl)
    }

    /// Опрос: вопрос и варианты шифруются в конверте, серверу — только число вариантов.
    func sendPoll(_ chatId: String, question: String, options: [String], multiple: Bool, anonymous: Bool, correct: Int?) async throws {
        guard (2...10).contains(options.count) else { throw CryptoError("В опросе от 2 до 10 вариантов") }
        let keys = try await sendKeys(for: chatId)
        let content = try MessageCrypto.encryptEnvelope(keys, Envelope(text: "📊 " + question, poll: PollBody(question: question, options: options)))
        var spec: [String: JSONValue] = [
            "options": .number(Double(options.count)),
            "multiple": .bool(multiple && correct == nil),
            "anonymous": .bool(anonymous),
        ]
        if let correct { spec["correct"] = .number(Double(correct)) }
        guard socket.sendMessage(receiver: chatId, content: content, fileType: MessageDto.fileTypePoll, poll: spec) else {
            throw NotConnectedError()
        }
    }

    /// Пересылка: файл не перезаливается — в новый конверт кладётся тот же ключ.
    func forward(_ message: ChatMessage, to chatId: String) async throws {
        let from = message.forwardedFrom ?? message.sender
        if let a = message.attachment {
            try await sendAttachment(chatId, text: message.text, fileUrl: a.fileUrl, fileKeyB64: a.fileKeyB64,
                                     fileName: a.fileName, mimeType: a.mimeType, forwardedFrom: from)
        } else if let sticker = message.stickerUrl {
            let keys = try await sendKeys(for: chatId)
            let content = try MessageCrypto.encryptText(keys, message.text.isEmpty ? "Стикер" : message.text)
            guard socket.sendMessage(receiver: chatId, content: content, fileUrl: sticker, fileType: MessageDto.fileTypeSticker) else {
                throw NotConnectedError()
            }
        } else {
            try await sendText(chatId, text: message.text, forwardedFrom: from)
        }
    }

    /// quote — q исходного сообщения: правка ответа цитатой её сохраняет.
    func edit(_ chatId: String, messageId: Int64, text: String, quote: String?) async throws {
        let keys = try await sendKeys(for: chatId)
        let content: String
        if let quote, !quote.isEmpty {
            content = try MessageCrypto.encryptEnvelope(keys, Envelope(text: text, quote: quote))
        } else {
            content = try MessageCrypto.encryptText(keys, text)
        }
        guard socket.sendEdit(messageId: messageId, content: content, receiver: chatId) else { throw NotConnectedError() }
    }

    /// Шифр ключом «Избранного» — для черновиков: его знают только свои устройства.
    func encryptForSelf(_ text: String) async throws -> String {
        try MessageCrypto.encryptText(try await keys(for: me), text)
    }

    func decryptForSelf(_ content: String) async -> String? {
        guard let keys = try? await keys(for: me) else { return nil }
        if case .text(let t) = MessageCrypto.decrypt(keys, content) { return t }
        return nil
    }

    private func enqueue(chatId: String, text: String, content: String, replyTo: Int64?, fileUrl: String?) {
        queuedSeq += 1
        outbox.append(Queued(localId: -queuedSeq, chatId: chatId, text: text, content: content,
                             replyTo: replyTo, fileUrl: fileUrl, createdAt: Date()))
        onOutboxChanged()
    }

    /// Связь вернулась — отправить накопленное, по порядку.
    func flushOutbox() {
        while let item = outbox.first {
            let sent = socket.sendMessage(receiver: item.chatId, content: item.content,
                                          fileUrl: item.fileUrl, fileType: item.fileUrl == nil ? nil : RstApi.attachmentMime,
                                          replyTo: item.replyTo)
            guard sent else { break }
            outbox.removeFirst()
        }
        onOutboxChanged()
    }

    func clearOutbox() {
        outbox.removeAll()
        onOutboxChanged()
    }

    // MARK: - Расшифровка

    func decrypt(_ dto: MessageDto, keys: ChatKeys?) -> ChatMessage {
        var base = ChatMessage(
            id: dto.id,
            sender: dto.sender,
            isMine: dto.sender == me,
            text: "",
            status: dto.status,
            reactions: Self.parseReactions(dto.reactions),
            isEdited: dto.isEdited ?? false,
            isPinned: dto.isPinned ?? false,
            forwardedFrom: dto.forwardedFrom,
            createdAt: ServerTime.parse(dto.createdAt),
            expiresAt: ServerTime.parse(dto.expiresAt),
            played: dto.played ?? true
        )

        // Системные записи — открытый текст, расшифровывать нечего
        if dto.isSystem {
            base.text = dto.content ?? ""
            base.isSystem = true
            return base
        }
        // Автоответ сервера — тоже открытый текст: ключей сервер не знает
        if dto.fileType == MessageDto.fileTypeAutoreply {
            base.text = dto.content ?? ""
            base.isAutoreply = true
            return base
        }
        let sticker = dto.fileType == MessageDto.fileTypeSticker ? dto.fileUrl : nil

        if let replyId = dto.replyTo {
            let replyContent = MessageCrypto.decrypt(keys, dto.replyToContent)
            base.reply = ReplyPreview(messageId: replyId, sender: dto.replyToSender ?? "",
                                      text: replyContent.previewText, undecryptable: replyContent == .undecryptable)
        }

        switch MessageCrypto.decrypt(keys, dto.content) {
        case .text(let t):
            base.text = t
            base.stickerUrl = sticker
        case .enveloped(let env):
            if env.hasFile, let url = dto.fileUrl {
                base.attachment = Attachment(fileUrl: url, fileKeyB64: env.fileKeyB64 ?? "",
                                             fileName: env.fileName ?? "файл", mimeType: env.mimeType ?? RstApi.attachmentMime)
            }
            if let body = env.poll {
                base.poll = Poll(question: body.question, options: body.options,
                                 state: PollState(dto.poll) ?? PollState(options: body.options.count))
            }
            // У опроса t — «📊 Вопрос» для старых клиентов; вопрос рисуем сами
            base.text = base.poll != nil ? "" : env.text
            if let q = env.quote, !q.trimmingCharacters(in: .whitespaces).isEmpty, base.reply != nil {
                base.reply?.text = q
                base.reply?.undecryptable = false
            }
            base.quote = env.quote
            base.storyRef = env.story
            base.live = dto.fileType == MessageDto.fileTypeLiveLocation ? env.geo : nil
        case .undecryptable:
            if let sticker {
                base.text = "Стикер"
                base.stickerUrl = sticker
            } else {
                base.undecryptable = true
            }
        }
        return base
    }

    /// reactions приходит JSON-строкой вида {"имя":"эмодзи"}.
    nonisolated static func parseReactions(_ raw: String?) -> [String: String] {
        guard let raw, !raw.isEmpty, raw != "{}", let obj = JSONValue.parse(raw)?.object else { return [:] }
        var result: [String: String] = [:]
        for (k, v) in obj { if let s = v.string { result[k] = s } }
        return result
    }
}
