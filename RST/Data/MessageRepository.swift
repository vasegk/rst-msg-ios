import Foundation

/// Упоминания в тексте: @ник латиницей, @все/@all — всем, @онлайн/@online — тем,
/// кто смотрит на экран (решает получатель). Веб: mentions.js, text-format.js.
enum Mentions {
    private static let nameRE = try! NSRegularExpression(pattern: #"(?:^|\s)@([A-Za-z0-9_-]{1,32})(?![\p{L}\p{N}_-])"#)
    private static let allRE = try! NSRegularExpression(pattern: #"(?:^|\s)@(все|all)(?![\p{L}\p{N}_-])"#, options: .caseInsensitive)
    private static let everyoneRE = try! NSRegularExpression(
        pattern: #"(?:^|\s)@(все|all|онлайн|online)(?![\p{L}\p{N}_-])"#, options: .caseInsensitive)
    static let special: Set<String> = ["all", "online", "все", "онлайн"]

    /// Подсказка серверу: mention_all и ники (по разу, без all/online, до 50).
    static func hints(in text: String) -> (all: Bool, names: [String]) {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let all = allRE.firstMatch(in: text, range: range) != nil
        var names: [String] = []
        for m in nameRE.matches(in: text, range: range) {
            let name = ns.substring(with: m.range(at: 1))
            guard !special.contains(name.lowercased()), !names.contains(name) else { continue }
            names.append(name)
            if names.count == 50 { break }
        }
        return (all, names)
    }

    /// Упомянут ли человек: @ник (без учёта регистра) или @все/@онлайн.
    static func mentions(_ username: String, in text: String) -> Bool {
        guard text.contains("@"), !username.isEmpty else { return false }
        let range = NSRange(location: 0, length: (text as NSString).length)
        if everyoneRE.firstMatch(in: text, range: range) != nil { return true }
        return hints(in: text).names.contains { $0.caseInsensitiveCompare(username) == .orderedSame }
    }
}

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

    let api: RstApi
    private let session: SessionStore
    let socket: RstWebSocket
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

    func sendKeys(for chatId: String) async throws -> ChatKeys {
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
    func history(_ chatId: String, beforeId: Int64? = nil, limit: Int = 100, topicId: Int64? = nil) async throws -> History {
        let response = try await api.messages(me: me, peer: chatId, limit: limit, beforeId: beforeId, topicId: topicId)
        let keys = try await readKeys(for: chatId)
        let list = (response.messages ?? []).filter { $0.commentTo == nil }
        return History(messages: list.map { decrypt($0, keys: keys) }, hasMore: response.hasMore ?? false, oldestId: response.oldestId)
    }

    /// Догнать пропущенное после перерыва: after_id отдаёт новее указанного
    /// от старых к новым, has_more — «ниже есть ещё».
    func since(_ chatId: String, afterId: Int64, topicId: Int64? = nil) async throws -> [ChatMessage] {
        let keys = try await readKeys(for: chatId)
        var result: [ChatMessage] = []
        var cursor = afterId
        for _ in 0..<10 {
            let page = try await api.messages(me: me, peer: chatId, limit: 200, afterId: cursor, topicId: topicId)
            let list = page.messages ?? []
            if list.isEmpty { break }
            result += list.filter { $0.commentTo == nil }.map { decrypt($0, keys: keys) }
            cursor = list.map(\.id).max() ?? cursor
            if page.hasMore != true { break }
        }
        return result
    }

    /// Комментарии к посту канала: обычные сообщения канала с comment_to.
    func comments(_ chatId: String, post: Int64) async throws -> [ChatMessage] {
        let response = try await api.messages(me: me, peer: chatId, limit: 200, commentTo: post)
        let keys = try await readKeys(for: chatId)
        return (response.messages ?? []).map { decrypt($0, keys: keys) }
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

    /// Подсказка серверу об упоминаниях — только в группе и не для пересылки.
    private func mentionExtra(_ chatId: String, text: String, forwarded: Bool) -> [String: JSONValue] {
        guard Self.isGroup(chatId), !forwarded else { return [:] }
        let hints = Mentions.hints(in: text)
        var extra: [String: JSONValue] = [:]
        if hints.all { extra["mention_all"] = .bool(true) }
        if !hints.names.isEmpty { extra["mentions"] = .array(hints.names.map { .string($0) }) }
        return extra
    }

    func sendText(_ chatId: String, text: String, replyTo: Int64? = nil, quote: String? = nil, forwardedFrom: String? = nil,
                  crossReply: CrossReply? = nil) async throws {
        let keys = try await sendKeys(for: chatId)
        var envelope = Envelope(text: text)
        if let quote, !quote.trimmingCharacters(in: .whitespaces).isEmpty { envelope.quote = String(quote.prefix(Self.quoteMax)) }
        envelope.crossReply = crossReply
        // Простой текст — строкой, как в вебе; конверт — только если есть что в него класть
        let content = try envelope.isPlainText
            ? MessageCrypto.encryptText(keys, text)
            : MessageCrypto.encryptEnvelope(keys, envelope)
        let extra = mentionExtra(chatId, text: text, forwarded: forwardedFrom != nil)
        if socket.sendMessage(receiver: chatId, content: content, replyTo: replyTo, forwardedFrom: forwardedFrom, extra: extra) { return }
        // Пересылку без сервера не проверить — честная ошибка; обычное — в очередь
        if forwardedFrom != nil { throw NotConnectedError() }
        enqueue(chatId: chatId, text: text, content: content, replyTo: replyTo, fileUrl: nil)
    }

    func sendAttachment(_ chatId: String, text: String, fileUrl: String, fileKeyB64: String, fileName: String,
                        mimeType: String, replyTo: Int64? = nil, forwardedFrom: String? = nil,
                        album: String? = nil, spoiler: Bool = false, viewOnce: Bool = false) async throws {
        let keys = try await sendKeys(for: chatId)
        var envelope = Envelope(text: text, fileKeyB64: fileKeyB64, fileName: fileName, mimeType: mimeType)
        envelope.album = album
        // Спойлер — только у фото и видео, и не у одноразовых
        envelope.spoiler = spoiler && !viewOnce && (mimeType.hasPrefix("image/") || mimeType.hasPrefix("video/"))
        let content = try MessageCrypto.encryptEnvelope(keys, envelope)
        var extra = mentionExtra(chatId, text: text, forwarded: forwardedFrom != nil)
        if viewOnce { extra["view_once"] = .bool(true) }
        // Файл ушёл зашифрованным, поэтому тип всегда двоичный поток:
        // настоящий MIME лежит в конверте, в поле m.
        if socket.sendMessage(receiver: chatId, content: content, fileUrl: fileUrl, fileType: RstApi.attachmentMime,
                              replyTo: replyTo, forwardedFrom: forwardedFrom, extra: extra) { return }
        if forwardedFrom != nil || viewOnce { throw NotConnectedError() }
        // Файл уже на сервере, а сокет как раз переподключается — send ждёт в очереди
        enqueue(chatId: chatId, text: text.isEmpty ? "📎 Вложение" : text, content: content, replyTo: replyTo, fileUrl: fileUrl)
    }

    /// Настройки нового опроса или чек-листа.
    struct PollSpec {
        var question: String
        var options: [String]
        var checklist = false
        var multiple = false
        var anonymous = true
        /// Викторина: номер правильного варианта.
        var correct: Int?
        /// Участники добавляют свои варианты (не у викторины).
        var openAdd = false
        /// Итоги — только после завершения.
        var hideResults = false
        /// Закрыть сам в это время.
        var closeAt: Date?
    }

    /// Опрос или чек-лист: вопрос и варианты шифруются в конверте, серверу — только число вариантов.
    func sendPoll(_ chatId: String, spec: PollSpec) async throws {
        if spec.checklist {
            guard (1...30).contains(spec.options.count) else { throw CryptoError("В чек-листе от 1 до 30 пунктов") }
        } else {
            guard (2...10).contains(spec.options.count) else { throw CryptoError("В опросе от 2 до 10 вариантов") }
        }
        let keys = try await sendKeys(for: chatId)
        let body = PollBody(question: spec.question, options: spec.options, isChecklist: spec.checklist)
        let prefix = spec.checklist ? "☑️ " : "📊 "
        let content = try MessageCrypto.encryptEnvelope(keys, Envelope(text: prefix + spec.question, poll: body))
        var poll: [String: JSONValue] = ["options": .number(Double(spec.options.count))]
        if spec.checklist {
            poll["kind"] = .string("checklist")
            poll["open_add"] = .bool(spec.openAdd)
        } else {
            poll["multiple"] = .bool(spec.multiple && spec.correct == nil)
            poll["anonymous"] = .bool(spec.anonymous)
            if let correct = spec.correct { poll["correct"] = .number(Double(correct)) }
            if spec.openAdd && spec.correct == nil { poll["open_add"] = .bool(true) }
            if spec.hideResults { poll["hide_results"] = .bool(true) }
            if let closeAt = spec.closeAt { poll["close_at"] = .string(ServerTime.iso(closeAt)) }
        }
        guard socket.sendMessage(receiver: chatId, content: content, fileType: MessageDto.fileTypePoll, poll: poll) else {
            throw NotConnectedError()
        }
    }

    /// Чек-лист: отметить или снять пункт.
    func toggleCheck(messageId: Int64, option: Int) throws {
        guard socket.sendCheckToggle(messageId: messageId, option: option) else { throw NotConnectedError() }
    }

    /// Свой вариант опроса или пункт чек-листа — зашифрован ключом чата, как сообщение.
    func addPollOption(_ chatId: String, messageId: Int64, text: String) async throws {
        let keys = try await sendKeys(for: chatId)
        let content = try MessageCrypto.encryptText(keys, String(text.prefix(300)))
        guard socket.sendPollAddOption(messageId: messageId, content: content) else { throw NotConnectedError() }
    }

    /// Одноразовое открыто: сервер стирает файл, обоим приходит view_once_opened.
    func consumeViewOnce(_ id: Int64) async throws {
        try await api.consumeViewOnce(id: id)
    }

    /// Варианты опроса с добавленными участниками, расшифрованные.
    func pollOptions(_ body: PollBody, state: PollState, keys: ChatKeys?) -> [String] {
        var extraTexts: [Int: String] = [:]
        for item in state.extra {
            if case .text(let t) = MessageCrypto.decrypt(keys, item.content) {
                extraTexts[item.index] = t
            } else if case .enveloped(let e) = MessageCrypto.decrypt(keys, item.content) {
                extraTexts[item.index] = e.text
            }
        }
        return Poll.mergedOptions(base: body.options, state: state, extraTexts: extraTexts)
    }

    /// Пересчитать варианты опроса по новому состоянию (poll_update).
    func refreshPoll(_ poll: Poll, rawState: JSONValue, chatId: String, base: [String]) async -> Poll {
        var updated = poll
        let state = PollState(rawState) ?? poll.state
        var keys: ChatKeys?
        if let found = try? await readKeys(for: chatId) { keys = found }
        updated.state = state
        updated.options = pollOptions(PollBody(question: poll.question, options: base, isChecklist: state.isChecklist),
                                      state: state, keys: keys)
        return updated
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

    /// Правка: конверт собирается заново из исходного со всеми полями —
    /// вложение (k/n/m), альбом, спойлер, цитата, ответ на историю, ответ из
    /// другого чата и незнакомые поля сохраняются, прежний текст — в историю
    /// правок e. Потеря любого поля сломала бы сообщение у остальных.
    func edit(_ chatId: String, message: ChatMessage, newText: String) async throws {
        let keys = try await sendKeys(for: chatId)
        let original = message.envelope ?? Envelope(text: message.text)
        let envelope = original.edited(newText: newText, previousText: message.text)
        let content = try MessageCrypto.encryptEnvelope(keys, envelope)
        guard socket.sendEdit(messageId: message.id, content: content, receiver: chatId) else { throw NotConnectedError() }
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
        base.viewOnce = dto.viewOnce ?? false
        base.isReminder = dto.reminder ?? false
        base.commentCount = dto.commentCount ?? 0

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
            base.envelope = env
            // У открытого одноразового file_url сервер стёр — вложения нет
            if env.hasFile, let url = dto.fileUrl, !url.isEmpty {
                base.attachment = Attachment(fileUrl: url, fileKeyB64: env.fileKeyB64 ?? "",
                                             fileName: env.fileName ?? "файл", mimeType: env.mimeType ?? RstApi.attachmentMime)
            }
            if let body = env.poll {
                let state = PollState(dto.poll) ?? PollState(options: body.options.count, checklist: body.isChecklist)
                base.poll = Poll(question: body.question, options: pollOptions(body, state: state, keys: keys), state: state)
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
        // Упоминание меня: сервер прислал очищенный список, иначе — по тексту
        if !base.isMine {
            base.mentionsMe = (dto.mentions ?? []).contains(me) || (dto.mentionAll ?? false)
                || Mentions.mentions(me, in: base.text)
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
