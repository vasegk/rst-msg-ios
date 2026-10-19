import Foundation

/// Действия переписки этапа B: выделение, отложенные, напоминания, контакт,
/// ответ в другом чате и лично, «кто прочитал», автоудаление, поиск.
extension ChatViewModel {

    // MARK: - Выделение

    func toggleSelection(_ m: ChatMessage) {
        guard m.id > 0, !m.isSystem else { return }
        if selected.contains(m.id) { selected.remove(m.id) } else { selected.insert(m.id) }
        selecting = !selected.isEmpty
    }

    func startSelection(_ m: ChatMessage) {
        selecting = true
        toggleSelection(m)
    }

    func clearSelection() {
        selected.removeAll()
        selecting = false
    }

    var selectedMessages: [ChatMessage] {
        messages.filter { selected.contains($0.id) }.sorted { $0.id < $1.id }
    }

    func forwardSelected(to target: String) async -> Bool {
        do {
            let skipped = try await services.messages.forward(selectedMessages, to: target)
            if skipped > 0 { toast = "Одноразовые фото и видео не пересылаются" }
            clearSelection()
            return true
        } catch {
            toast = errorText(error)
            return false
        }
    }

    /// Удалить выбранное: у всех — только своё (чужое — у себя).
    func deleteSelected(forEveryone: Bool) {
        for m in selectedMessages {
            delete(m, forEveryone: forEveryone && m.isMine)
        }
        clearSelection()
    }

    var canDeleteSelectedForEveryone: Bool { selectedMessages.allSatisfy { $0.isMine } }

    // MARK: - Отложенные, «когда в сети», напоминания

    /// Отложить текст из поля ввода ко времени.
    func scheduleCurrent(at date: Date) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        Task {
            do {
                try await services.messages.scheduleText(chatId, text: body, sendAt: date, replyTo: replyTo?.id)
                updateText("")
                replyTo = nil
                toast = "Отправится \(TimeFormat.dayHeader(date).lowercased()) в \(TimeFormat.clock(date))"
            } catch {
                toast = errorText(error)
            }
        }
    }

    /// «Когда будет в сети» — только в личке (не себе и не системному).
    var canSendWhenOnline: Bool { !isGroup && !isSaved && !(summary?.isSystem ?? false) }

    func sendWhenOnline() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, canSendWhenOnline else { return }
        Task {
            do {
                try await services.messages.scheduleText(chatId, text: body, sendAt: nil, whenOnline: true)
                updateText("")
                toast = "Сообщение уйдёт, когда \(title) будет в сети"
            } catch {
                toast = errorText(error)
            }
        }
    }

    func remind(_ m: ChatMessage, at date: Date) {
        Task {
            do {
                try await services.messages.remind(m, fromChat: chatId, chatName: isSaved ? "" : title, at: date)
                toast = "Напомню \(TimeFormat.dayHeader(date).lowercased()) в \(TimeFormat.clock(date))"
            } catch {
                toast = errorText(error)
            }
        }
    }

    func loadScheduled() async -> [MessageRepository.ScheduledItem] {
        do {
            return try await services.messages.scheduledList(chatId)
        } catch {
            toast = errorText(error)
            return []
        }
    }

    func cancelScheduled(_ id: Int64) async {
        do { try await services.api.deleteScheduled(id: id) } catch { toast = errorText(error) }
    }

    func sendScheduledNow(_ id: Int64) async {
        do { try await services.api.sendScheduledNow(id: id) } catch { toast = errorText(error) }
    }

    // MARK: - Контакт, ответ в другом чате и лично

    func sendSticker(_ sticker: StickerDto) {
        let reply = replyTo?.id
        replyTo = nil
        Task {
            do { try await services.messages.sendSticker(chatId, sticker: sticker, replyTo: reply) } catch { toast = errorText(error) }
        }
    }

    func shareContact(_ contact: ContactRef) {
        Task {
            do { try await services.messages.shareContact(chatId, contact: contact) } catch { toast = errorText(error) }
        }
    }

    /// Цитата для другого чата: автор — отображаемое имя (своё — своим), текст до 300.
    func crossReply(for m: ChatMessage) -> CrossReply {
        let author = m.isMine ? (services.chats.myProfile?.displayName ?? me) : services.chats.displayName(m.sender)
        let body = m.text.isEmpty ? (m.attachment == nil ? Previews.describe(m) : "📎 Вложение") : m.text
        return CrossReply(author: author, text: body, chatName: isSaved ? "" : title)
    }

    /// «Ответить в другом чате» / «Ответить лично»: цитату понесёт первое сообщение туда.
    func prepareCrossReply(_ m: ChatMessage, to target: String) {
        services.chats.crossReplyDraft[target] = crossReply(for: m)
    }

    // MARK: - Кто прочитал, автоудаление

    func readers(of m: ChatMessage) async -> [ReaderDto] {
        do {
            return try await services.api.readers(groupId: chatId, messageId: m.id).readers ?? []
        } catch {
            toast = errorText(error)
            return []
        }
    }

    func loadTimer() async -> Int {
        (try? await services.api.chatTimer(chatId).seconds) ?? 0
    }

    func setTimer(_ seconds: Int) {
        if services.socket.sendSetTimer(chat: chatId, seconds: seconds) {
            toast = seconds == 0 ? "Автоудаление выключено" : "Сообщения будут удаляться через \(Self.timerTitle(seconds))"
        } else {
            toast = NotConnectedError().errorDescription
        }
    }

    static func timerTitle(_ seconds: Int) -> String {
        switch seconds {
        case 86400: return "сутки"
        case 604800: return "неделю"
        case 2592000: return "месяц"
        default: return "\(seconds / 3600) ч"
        }
    }

    // MARK: - Кнопки «@» и «❤»

    func loadReactionQueue() async {
        guard let items = try? await services.api.reactionsUnread(chat: chatId).items else { return }
        var ids: [Int64] = []
        for item in items where !ids.contains(item.messageId) { ids.append(item.messageId) }
        reactionQueue = ids
    }

    /// Сообщение побывало на экране — упоминание и новая реакция увидены.
    func markSeen(_ id: Int64) {
        guard visible else { return }
        mentionQueue.removeAll { $0 == id }
        if reactionQueue.contains(id) {
            reactionQueue.removeAll { $0 == id }
            let chat = chatId
            Task { try? await services.api.reactionsSeen(chat: chat, ids: [id]) }
        }
    }

    /// К самому раннему непросмотренному; давнее — догрузить.
    func jumpToNextMention() async {
        guard let id = mentionQueue.first else { return }
        await jumpLoading(id)
        mentionQueue.removeAll { $0 == id }
    }

    func jumpToNextReaction() async {
        guard let id = reactionQueue.first else { return }
        await jumpLoading(id)
        markSeen(id)
        reactionQueue.removeAll { $0 == id }
    }

    private func jumpLoading(_ id: Int64) async {
        var pages = 0
        while !messages.contains(where: { $0.id == id }) && hasMore && pages < 10 {
            await loadOlder()
            pages += 1
        }
        jump(to: id)
    }

    // MARK: - Подсказка «@»

    struct MentionSuggestion: Identifiable, Equatable {
        let username: String
        let title: String
        var id: String { username }
    }

    /// Участники группы по нику, имени профиля и имени в чате; «все» — админам.
    func mentionSuggestions(for token: String) -> [MentionSuggestion] {
        guard isGroup else { return [] }
        let q = token.lowercased()
        var list: [MentionSuggestion] = []
        if ["owner", "admin"].contains(myRole) && ("все".hasPrefix(q) || "all".hasPrefix(q)) {
            list.append(MentionSuggestion(username: "все", title: "Все участники"))
        }
        if "онлайн".hasPrefix(q) || "online".hasPrefix(q) {
            list.append(MentionSuggestion(username: "онлайн", title: "Все, кто в сети"))
        }
        for m in groupInfo?.members ?? [] where m.username != me {
            let name = services.chats.displayName(m.username)
            if q.isEmpty || m.username.lowercased().hasPrefix(q) || name.lowercased().contains(q)
                || m.shownName.lowercased().contains(q) {
                list.append(MentionSuggestion(username: m.username, title: name))
            }
            if list.count >= 8 { break }
        }
        return list
    }

    // MARK: - Галерея вложений

    func loadMedia() async -> [ChatMessage] {
        do {
            return try await services.messages.media(chatId)
        } catch {
            toast = errorText(error)
            return []
        }
    }

    // MARK: - Поиск по загруженной переписке

    /// Поиск по расшифрованному на устройстве (сервер хранит только шифр).
    func search(_ query: String) -> [ChatMessage] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        return messages.reversed().filter { m in
            !m.undecryptable && (m.text.localizedCaseInsensitiveContains(q)
                                 || (m.attachment?.fileName.localizedCaseInsensitiveContains(q) ?? false))
        }
    }
}
