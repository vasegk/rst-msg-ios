import Foundation

/// Отложенные, напоминания, «когда будет в сети», контакт, пакетная пересылка.
extension MessageRepository {

    /// Отложенное сообщение (кадр schedule): ко времени send_at или, в личке,
    /// «когда будет в сети» (when_online без send_at).
    func scheduleText(_ chatId: String, text: String, sendAt: Date?, whenOnline: Bool = false,
                      replyTo: Int64? = nil) async throws {
        let keys = try await sendKeys(for: chatId)
        let content = try MessageCrypto.encryptText(keys, text)
        var extra: [String: JSONValue] = [:]
        if whenOnline { extra["when_online"] = .bool(true) }
        let sent = socket.sendMessage(receiver: chatId, content: content, replyTo: replyTo,
                                      sendAt: sendAt.map { ServerTime.iso($0) }, extra: extra, schedule: true)
        if !sent { throw NotConnectedError() }
    }

    /// «Напомнить» (с 2026-10-18): отложенное сообщение себе с reminder и полем r —
    /// копия текста и вложения (тот же file_url и ключ), ссылка на исходное.
    func remind(_ message: ChatMessage, fromChat chatId: String, chatName: String, at date: Date) async throws {
        let keys = try await sendKeys(for: me)
        var envelope = message.envelope ?? Envelope(text: message.text)
        envelope.edits = []
        envelope.crossReply = nil
        envelope.remind = RemindRef(chat: chatId, messageId: message.id, name: chatName)
        if envelope.text.isEmpty { envelope.text = Previews.describe(message) }
        let content = try MessageCrypto.encryptEnvelope(keys, envelope)
        let file = message.attachment?.fileUrl
        let sent = socket.sendMessage(receiver: me, content: content, fileUrl: file,
                                      fileType: file == nil ? nil : RstApi.attachmentMime,
                                      sendAt: ServerTime.iso(date), extra: ["reminder": .bool(true)], schedule: true)
        if !sent { throw NotConnectedError() }
    }

    /// Стикер: картинка открыта (file_url набора), подпись — эмодзи стикера — шифруется.
    func sendSticker(_ chatId: String, sticker: StickerDto, replyTo: Int64? = nil) async throws {
        let keys = try await sendKeys(for: chatId)
        let content = try MessageCrypto.encryptText(keys, StickerStore.caption(sticker.emoji))
        guard socket.sendMessage(receiver: chatId, content: content, fileUrl: sticker.fileUrl,
                                 fileType: MessageDto.fileTypeSticker, replyTo: replyTo) else {
            throw NotConnectedError()
        }
    }

    /// Комментарий к посту канала: кадр send с comment_to, ключ — ключ канала.
    func sendComment(_ chatId: String, post: Int64, text: String) async throws {
        let keys = try await sendKeys(for: chatId)
        let content = try MessageCrypto.encryptText(keys, text)
        guard socket.sendMessage(receiver: chatId, content: content, extra: ["comment_to": .number(Double(post))]) else {
            throw NotConnectedError()
        }
    }

    /// Поделиться контактом: текст для старых клиентов, карточка — полем c.
    func shareContact(_ chatId: String, contact: ContactRef) async throws {
        let keys = try await sendKeys(for: chatId)
        var envelope = Envelope(text: "👤 Контакт: \(contact.name) (@\(contact.username))")
        envelope.contact = contact
        let content = try MessageCrypto.encryptEnvelope(keys, envelope)
        if !socket.sendMessage(receiver: chatId, content: content) { throw NotConnectedError() }
    }

    /// Пересылка выбранного по порядку; одноразовые не пересылаются.
    func forward(_ list: [ChatMessage], to chatId: String) async throws -> Int {
        var skipped = 0
        for message in list.sorted(by: { $0.id < $1.id }) {
            if message.viewOnce || message.undecryptable || message.isSystem {
                skipped += 1
                continue
            }
            try await forward(message, to: chatId)
        }
        return skipped
    }

    /// Отложенные этого чата, текст расшифрован для списка.
    struct ScheduledItem: Identifiable, Equatable {
        let id: Int64
        let text: String
        let sendAt: Date?
        let reminder: Bool
        let whenOnline: Bool
    }

    func scheduledList(_ chatId: String) async throws -> [ScheduledItem] {
        let list = try await api.scheduled(chat: chatId).scheduled ?? []
        var keys: ChatKeys?
        if let found = try? await readKeys(for: chatId) { keys = found }
        return list.map { item in
            ScheduledItem(id: item.id,
                          text: Previews.describe(MessageCrypto.decrypt(keys, item.content), fileType: item.fileType),
                          sendAt: ServerTime.parse(item.sendAt),
                          reminder: item.reminder ?? false,
                          whenOnline: item.whenOnline ?? false)
        }
    }
}
