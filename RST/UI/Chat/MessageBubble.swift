import SwiftUI

/// Одно сообщение в ленте: пузырь со всем содержимым и реакции под ним.
struct MessageRow: View {
    let message: ChatMessage
    let isGroup: Bool
    let isChannel: Bool
    /// Первое в серии сообщений одного автора — с именем.
    let showSender: Bool
    /// Последнее в серии — с аватаром.
    let showAvatar: Bool
    let highlighted: Bool
    let model: ChatViewModel
    var onOpenImage: (UIImage) -> Void = { _ in }
    var onForward: (ChatMessage) -> Void = { _ in }
    var onReactionsList: (ChatMessage) -> Void = { _ in }
    var onOpenProfile: (String) -> Void = { _ in }
    var onConfirmLink: (String) -> Void = { _ in }
    /// Открыть другой чат на сообщении (напоминание, карточка контакта).
    var onOpenChat: (String, Int64) -> Void = { _, _ in }
    var onShowEdits: (ChatMessage) -> Void = { _ in }
    var onOpenViewOnce: (ChatMessage) -> Void = { _ in }
    var onAction: (MessageAction) -> Void = { _ in }
    @State private var swipe: CGFloat = 0

    @Environment(ChatListStore.self) private var store
    @Environment(\.openURL) private var openURL

    private var me: String { store.me }

    var body: some View {
        if message.isSystem {
            Text(Previews.oneLine(message.text))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.onSurface.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.card.opacity(0.85)))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                if model.selecting {
                    Image(systemName: model.selected.contains(message.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(model.selected.contains(message.id) ? Theme.accent : Theme.muted)
                        .padding(.bottom, 6)
                }
                if message.isMine { Spacer(minLength: 50) }
                if isGroup && !message.isMine && !isChannel {
                    if showAvatar {
                        AvatarView(name: store.displayName(message.sender), url: store.users[message.sender]?.avatarUrl, size: 32)
                    } else {
                        Color.clear.frame(width: 32, height: 1)
                    }
                }
                VStack(alignment: message.isMine ? .trailing : .leading, spacing: 4) {
                    bubble
                        .contextMenu { menu }
                    if !message.reactions.isEmpty {
                        ReactionsRow(reactions: message.reactions, me: me, isMine: message.isMine) { emoji in
                            model.react(message, emoji)
                        } onLongPress: {
                            onReactionsList(message)
                        }
                    }
                }
                if !message.isMine { Spacer(minLength: 50) }
            }
            .padding(.horizontal, 10)
            .padding(.top, showSender ? 6 : 1)
            .background(highlighted || model.selected.contains(message.id) ? Theme.accent.opacity(0.22) : Color.clear)
            .animation(.easeOut(duration: 0.6), value: highlighted)
            .offset(x: swipe)
            .contentShape(Rectangle())
            // В режиме выделения нажатие отмечает сообщение
            .onTapGesture { if model.selecting { model.toggleSelection(message) } }
            // Ответ свайпом влево
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { v in
                        guard !model.selecting, model.canWrite, !message.pending,
                              abs(v.translation.width) > abs(v.translation.height) else { return }
                        swipe = max(-70, min(0, v.translation.width))
                    }
                    .onEnded { _ in
                        if swipe <= -55 { model.startReply(message) }
                        withAnimation(.spring(response: 0.25)) { swipe = 0 }
                    }
            )
        }
    }

    // MARK: - Пузырь

    @ViewBuilder
    private var bubble: some View {
        if let sticker = message.stickerUrl {
            VStack(alignment: .trailing, spacing: 2) {
                PlainImageView(fileUrl: sticker, size: 150)
                footer.padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.black.opacity(0.35)))
            }
            .onTapGesture(count: 2) { model.react(message, "👍") }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if showSender && isGroup && !message.isMine && !isChannel {
                    HStack(spacing: 4) {
                        Text(store.displayName(message.sender))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.avatarGradient(for: store.displayName(message.sender)).0)
                        if store.users[message.sender]?.verified == true { VerifiedBadge(size: 11) }
                        if let emoji = store.emojiStatus(of: message.sender) { Text(emoji).font(.system(size: 12)) }
                    }
                }
                if let remind = message.remind, message.isReminder || model.isSaved {
                    // Напоминание: нажатие — к исходному сообщению в его чате
                    Button { onOpenChat(remind.chat, remind.messageId) } label: {
                        Label("Напоминание · \(remind.name.isEmpty ? store.title(for: remind.chat) : remind.name)", systemImage: "bell.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(message.isMine ? Color.white.opacity(0.9) : Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
                if let x = message.crossReply {
                    CrossReplyQuote(reply: x, isMine: message.isMine)
                }
                if let from = message.forwardedFrom {
                    Label("Переслано от \(store.displayName(from))", systemImage: "arrowshape.turn.up.right.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(message.isMine ? Color.white.opacity(0.85) : Theme.accent)
                }
                if message.isAutoreply {
                    Label("Автоответ", systemImage: "arrow.uturn.left")
                        .font(.system(size: 12, weight: .medium))
                        .opacity(0.8)
                }
                if let reply = message.reply {
                    ReplyQuote(reply: reply, isMine: message.isMine)
                        .onTapGesture { model.jump(to: reply.messageId) }
                }
                if let story = message.storyRef {
                    Label(story.author == me ? "Ваша история" : "История · \(store.displayName(story.author))", systemImage: "circle.dashed")
                        .font(.system(size: 12, weight: .medium))
                        .opacity(0.85)
                }
                content
                footer.frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .foregroundStyle(message.isMine ? Color.white : Theme.onSurface)
            .background(bubbleBackground)
            .clipShape(BubbleShape(isMine: message.isMine))
            .frame(maxWidth: 320, alignment: message.isMine ? .trailing : .leading)
            .onTapGesture(count: 2) { if !message.pending { model.react(message, "👍") } }
        }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if message.isMine {
            Theme.ownBubble
        } else {
            Theme.otherBubble.opacity(0.92)
        }
    }

    @ViewBuilder
    private var content: some View {
        if message.undecryptable {
            Label("Не удалось расшифровать сообщение", systemImage: "lock.fill")
                .font(.system(size: 14))
                .opacity(0.8)
        } else if message.viewOnce {
            ViewOnceBadge(message: message) { onOpenViewOnce(message) }
        } else {
            if let a = message.attachment {
                if message.spoiler && (a.isImage || a.isVideo) {
                    SpoilerContainer { attachmentView(a) }
                } else {
                    attachmentView(a)
                }
            }
            if let poll = message.poll {
                PollView(message: message, poll: poll, model: model)
            }
            if let live = message.live {
                LiveLocationCard(geo: live, isMine: message.isMine)
                if message.isMine && LiveLocationSharing.shared.isSharing(messageId: message.id) {
                    Button("Остановить") { LiveLocationSharing.shared.stop(messageId: message.id) }
                        .font(.system(size: 14, weight: .semibold))
                        .buttonStyle(.plain)
                }
            }
            if let contact = message.contact {
                ContactCard(contact: contact, isMine: message.isMine) { onOpenChat(contact.username, 0) }
            } else if !message.text.isEmpty && !isServiceCaption && !isFileNameCaption {
                MessageTextView(text: message.text, isMine: message.isMine)
                    .environment(\.openURL, OpenURLAction { url in handleLink(url) })
                if message.attachment == nil, let link = LinkPreviewCard.firstLink(in: message.text) {
                    LinkPreviewCard(url: link, isMine: message.isMine)
                }
            }
        }
    }

    /// У видео t, похожий на имя файла («имя.mp4» без пробелов), подписью не считается.
    private var isFileNameCaption: Bool {
        guard let a = message.attachment, a.isVideo || !a.isImage else { return false }
        let t = message.text
        return t == a.fileName || (!t.contains(" ") && t.range(of: #"^[^\s]+\.[A-Za-z0-9]{2,5}$"#, options: .regularExpression) != nil)
    }

    /// Подпись «🎤 Голосовое сообщение» у голосового и кружка — служебная, не показываем.
    private var isServiceCaption: Bool {
        guard let a = message.attachment else { return false }
        return (a.isAudio && message.text == Previews.voiceText) || (a.isVideo && message.text == Previews.videoNote)
    }

    @ViewBuilder
    private func attachmentView(_ a: Attachment) -> some View {
        if a.isImage {
            EncryptedImageView(attachment: a, onOpen: onOpenImage)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else if a.isAudio {
            VoiceMessageView(attachment: a, isMine: message.isMine, played: message.played) { model.markPlayed(message) }
        } else if a.isVideo {
            VideoAttachmentView(attachment: a, round: message.text == Previews.videoNote) { model.markPlayed(message) }
        } else {
            FileAttachmentView(attachment: a, isMine: message.isMine)
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if message.isPinned { Image(systemName: "pin.fill").font(.system(size: 9)) }
            if message.isEdited {
                // Есть прежние версии — «изменено» открывает историю правок
                if message.edits.isEmpty {
                    Text("изменено").font(.system(size: 11))
                } else {
                    Text("изменено")
                        .font(.system(size: 11))
                        .underline(pattern: .dot)
                        .onTapGesture { onShowEdits(message) }
                }
            }
            if message.expiresAt != nil { Image(systemName: "timer").font(.system(size: 9)) }
            Text(TimeFormat.clock(message.createdAt)).font(.system(size: 11))
            if message.isMine {
                if message.pending {
                    Image(systemName: "clock").font(.system(size: 10, weight: .semibold))
                } else {
                    Checkmarks(read: message.isRead, color: message.stickerUrl == nil ? .white : Theme.accent)
                }
            }
        }
        .opacity(0.8)
    }

    // MARK: - Меню

    @ViewBuilder
    private var menu: some View {
        if !message.pending {
            Menu {
                ForEach(["👍", "❤️", "😂", "😮", "😢", "🔥", "👏", "🎉", "🤔", "👎"], id: \.self) { emoji in
                    Button(emoji) { model.react(message, emoji) }
                }
            } label: { Label("Реакция", systemImage: "face.smiling") }
            if model.canWrite {
                Button { model.startReply(message) } label: { Label("Ответить", systemImage: "arrowshape.turn.up.left") }
            }
            // Защищённая группа: без ответа в другом чате, лично и напоминаний
            if !model.isProtected && !message.viewOnce && !message.undecryptable {
                Button { onAction(.crossReply(message)) } label: {
                    Label("Ответить в другом чате", systemImage: "arrowshape.turn.up.left.2")
                }
                if model.isGroup && !message.isMine && !isChannel {
                    Button { onAction(.replyPrivately(message)) } label: { Label("Ответить лично", systemImage: "person.fill") }
                }
                Button { onAction(.remind(message)) } label: { Label("Напомнить", systemImage: "bell") }
            }
            Button { onAction(.select(message)) } label: { Label("Выбрать", systemImage: "checkmark.circle") }
            if model.isGroup && message.isMine {
                Button { onAction(.readers(message)) } label: { Label("Кто прочитал", systemImage: "eye") }
            }
        }
        // Защищённая группа и одноразовые: без копирования и пересылки
        if !message.text.isEmpty && !message.undecryptable && !model.isProtected && !message.viewOnce {
            Button { UIPasteboard.general.string = TextFormat.strip(message.text) } label: { Label("Копировать", systemImage: "doc.on.doc") }
        }
        if !message.pending {
            if message.isMine && message.poll == nil && message.live == nil && !message.isAutoreply
                && message.stickerUrl == nil && !message.undecryptable && !message.viewOnce && message.contact == nil {
                Button { model.startEdit(message) } label: { Label("Изменить", systemImage: "pencil") }
            }
            if !message.edits.isEmpty {
                Button { onShowEdits(message) } label: { Label("История правок", systemImage: "clock.arrow.circlepath") }
            }
            if !model.isGroup || model.canModerate {
                Button { model.togglePin(message) } label: {
                    Label(message.isPinned ? "Открепить" : "Закрепить", systemImage: message.isPinned ? "pin.slash" : "pin")
                }
            }
            if !message.undecryptable && !message.viewOnce && !model.isProtected {
                Button { onForward(message) } label: { Label("Переслать", systemImage: "arrowshape.turn.up.right") }
            }
            if !message.reactions.isEmpty && model.isGroup {
                Button { onReactionsList(message) } label: { Label("Кто отреагировал", systemImage: "person.2") }
            }
            Divider()
            if message.isMine || canDeleteForEveryone {
                Button(role: .destructive) { model.delete(message, forEveryone: true) } label: {
                    Label("Удалить у всех", systemImage: "trash")
                }
            }
            Button(role: .destructive) { model.delete(message, forEveryone: false) } label: {
                Label("Удалить у себя", systemImage: "trash.slash")
            }
        }
    }

    /// Чужие сообщения у всех: владелец — любые, администратор — кроме
    /// владельца, хелпер — участников и редакторов. Сервер проверит сам.
    private var canDeleteForEveryone: Bool {
        guard model.isGroup else { return false }
        return ["owner", "admin", "helper"].contains(model.myRole)
    }

    private func handleLink(_ url: URL) -> OpenURLAction.Result {
        if url.scheme == "rstmsg" {
            if url.host == "mention" {
                // @все/@онлайн — подсветка без перехода в профиль
                let name = url.lastPathComponent
                if !Mentions.special.contains(name.lowercased()) { onOpenProfile(name) }
                return .handled
            }
            if url.host == "hashtag",
               let tag = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "t" })?.value {
                onAction(.hashtag(tag))
                return .handled
            }
            if url.host == "confirm",
               let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "u" })?.value {
                onConfirmLink(target)
                return .handled
            }
        }
        return .systemAction
    }
}

/// Скругление 16, угол со стороны отправителя — 4.
struct BubbleShape: Shape {
    let isMine: Bool
    func path(in rect: CGRect) -> Path {
        let big: CGFloat = 16, small: CGFloat = 4
        return Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(
            topLeading: big, bottomLeading: isMine ? big : small, bottomTrailing: isMine ? small : big, topTrailing: big))
    }
}

struct ReplyQuote: View {
    let reply: ReplyPreview
    let isMine: Bool
    @Environment(ChatListStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isMine ? Color.white : Theme.accent)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.displayName(reply.sender))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isMine ? Color.white : Theme.accent)
                Text(reply.undecryptable ? Previews.undecryptable : Previews.oneLine(TextFormat.strip(reply.text)))
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .opacity(0.85)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: 260, alignment: .leading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ReactionsRow: View {
    let reactions: [String: String]
    let me: String
    let isMine: Bool
    var onTap: (String) -> Void
    var onLongPress: () -> Void

    struct ReactionGroup: Identifiable {
        let emoji: String
        let count: Int
        let mine: Bool
        var id: String { emoji }
    }

    private var grouped: [ReactionGroup] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for (_, emoji) in reactions.sorted(by: { $0.key < $1.key }) {
            if counts[emoji] == nil { order.append(emoji) }
            counts[emoji, default: 0] += 1
        }
        let mineEmoji = reactions[me]
        return order.map { ReactionGroup(emoji: $0, count: counts[$0] ?? 0, mine: $0 == mineEmoji) }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(grouped) { item in
                Button { onTap(item.emoji) } label: {
                    HStack(spacing: 3) {
                        if item.emoji.hasPrefix("s:") {
                            PlainImageView(fileUrl: String(item.emoji.dropFirst(2)), size: 18)
                        } else {
                            Text(item.emoji).font(.system(size: 14))
                        }
                        if item.count > 1 { Text("\(item.count)").font(.system(size: 12, weight: .semibold)) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(item.mine ? Theme.accent.opacity(0.22) : Color.black.opacity(0.3))
                    )
                    .overlay(Capsule().stroke(item.mine ? Theme.accent : Color.clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .simultaneousGesture(LongPressGesture().onEnded { _ in onLongPress() })
            }
        }
        .foregroundStyle(Theme.onSurface)
    }
}

/// Опрос: голосование и итоги после своего голоса или завершения.
/// Чек-лист: пункты отмечают участники, «Выполнено N из M».
struct PollView: View {
    let message: ChatMessage
    let poll: Poll
    let model: ChatViewModel
    @Environment(ChatListStore.self) private var store
    @State private var selection: Set<Int> = []
    @State private var adding = false
    @State private var newOption = ""

    private var state: PollState { poll.state }
    private var total: Int { max(state.counts.reduce(0, +), 1) }
    /// Свой вариант: можно, если open_add или ты автор; не в закрытом и не в викторине.
    private var canAdd: Bool {
        guard !state.closed, !state.quiz else { return false }
        let limit = state.isChecklist ? 50 : 20
        return (state.openAdd || message.isMine) && poll.options.count < limit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(poll.question).font(.system(size: 16, weight: .semibold))
            Text(caption).font(.system(size: 12)).opacity(0.75)
            ForEach(Array(poll.options.enumerated()), id: \.offset) { index, option in
                if state.isChecklist {
                    checkRow(index, option)
                } else {
                    optionRow(index, option)
                }
            }
            if canAdd {
                if adding {
                    HStack {
                        TextField(state.isChecklist ? "Пункт" : "Свой вариант", text: $newOption)
                            .textFieldStyle(.roundedBorder)
                            .foregroundStyle(Theme.onSurface)
                            .onSubmit(addOption)
                        Button("OK", action: addOption).disabled(newOption.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else {
                    Button(state.isChecklist ? "+ Пункт" : "+ Свой вариант") { adding = true }
                        .font(.system(size: 14))
                        .buttonStyle(.plain)
                }
            }
            HStack {
                if !state.isChecklist && state.multiple && !poll.showResults && state.my.isEmpty && !selection.isEmpty {
                    Button("Голосовать") { model.vote(message, options: selection.sorted()) }
                        .font(.system(size: 14, weight: .semibold))
                }
                if !state.isChecklist && !state.closed && !state.quiz && !state.my.isEmpty {
                    Button("Отменить голос") { model.vote(message, options: []) }
                        .font(.system(size: 13))
                }
                Spacer()
                if message.isMine && !state.closed && !state.isChecklist {
                    Button("Завершить") { model.closePoll(message) }
                        .font(.system(size: 13))
                }
            }
            .buttonStyle(.plain)
            .opacity(0.9)
        }
        .frame(minWidth: 220)
    }

    private func addOption() {
        model.addPollOption(message, text: newOption)
        newOption = ""
        adding = false
    }

    private var caption: String {
        if state.isChecklist {
            let done = (0..<poll.options.count).filter { !voters($0).isEmpty }.count
            return "Чек-лист · выполнено \(done) из \(poll.options.count)"
        }
        var parts: [String] = []
        parts.append(state.quiz ? "Викторина" : (state.anonymous ? "Анонимный опрос" : "Открытый опрос"))
        if state.multiple { parts.append("несколько ответов") }
        if state.hidden && !state.my.isEmpty {
            parts.append("\(state.voters) \(state.voters == 1 ? "голос" : "голосов") · ваш голос учтён")
        } else {
            parts.append("голосов: \(state.voters)")
        }
        if state.hideResults && !state.closed { parts.append("итоги после завершения") }
        if let closeAt = state.closeAt, !state.closed {
            parts.append("до \(TimeFormat.dayHeader(closeAt).lowercased()), \(TimeFormat.clock(closeAt))")
        }
        if state.closed { parts.append("завершён") }
        return parts.joined(separator: " · ")
    }

    private func voters(_ index: Int) -> [String] {
        index < state.votersByOption.count ? state.votersByOption[index] : []
    }

    /// Пункт чек-листа: квадратная галочка, отмеченный зачёркнут, справа — кто отметил.
    private func checkRow(_ index: Int, _ option: String) -> some View {
        let who = voters(index)
        let done = !who.isEmpty || (index < state.counts.count && state.counts[index] > 0)
        return Button { model.toggleCheck(message, option: index) } label: {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                Text(option)
                    .font(.system(size: 15))
                    .strikethrough(done)
                    .opacity(done ? 0.7 : 1)
                Spacer()
                if let first = who.first {
                    Text(store.displayName(first)).font(.system(size: 12)).opacity(0.75)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(state.closed)
    }

    @ViewBuilder
    private func optionRow(_ index: Int, _ option: String) -> some View {
        let count = index < state.counts.count ? state.counts[index] : 0
        let percent = Double(count) / Double(total)
        let chosen = state.my.contains(index) || selection.contains(index)
        Button {
            // Проголосовал — варианты не нажимаются (и при скрытых итогах)
            guard !poll.showResults, !state.closed, state.my.isEmpty else { return }
            if state.multiple {
                if selection.contains(index) { selection.remove(index) } else { selection.insert(index) }
            } else {
                model.vote(message, options: [index])
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    Text(option).font(.system(size: 15))
                    Spacer()
                    if poll.showResults {
                        if state.quiz, let correct = state.correct, correct == index {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.success)
                        }
                        Text("\(Int((percent * 100).rounded()))%").font(.system(size: 13, weight: .semibold))
                    }
                }
                if poll.showResults {
                    GeometryReader { geo in
                        Capsule().fill(Color.white.opacity(0.15))
                            .overlay(alignment: .leading) {
                                Capsule().fill(message.isMine ? Color.white : Theme.accent).frame(width: geo.size.width * percent)
                            }
                    }
                    .frame(height: 4)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// Ответ на сообщение из другого чата: «Автор · Имя чата» и текст; не нажимается.
struct CrossReplyQuote: View {
    let reply: CrossReply
    let isMine: Bool

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isMine ? Color.white : Theme.accent)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(reply.author) · \(reply.chatName.isEmpty ? "из другого чата" : reply.chatName)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isMine ? Color.white : Theme.accent)
                    .lineLimit(1)
                Text(Previews.oneLine(TextFormat.strip(reply.text)))
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .opacity(0.85)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: 260, alignment: .leading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Карточка контакта: аватар, имя, @ник и «Написать».
struct ContactCard: View {
    let contact: ContactRef
    let isMine: Bool
    var onWrite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AvatarView(name: contact.name.isEmpty ? contact.username : contact.name, url: nil, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.name.isEmpty ? contact.username : contact.name)
                        .font(.system(size: 15, weight: .semibold))
                    Text("@" + contact.username).font(.system(size: 13)).opacity(0.8)
                }
            }
            Button(action: onWrite) {
                Text("Написать")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(isMine ? Color.white.opacity(0.22) : Theme.accent.opacity(0.18)))
            }
            .buttonStyle(.plain)
        }
        .frame(minWidth: 200)
    }
}

/// Одноразовое фото или видео: кнопка «открыть один раз», после — «Просмотрено».
struct ViewOnceBadge: View {
    let message: ChatMessage
    var onOpen: () -> Void

    private var kind: String { (message.attachment?.isVideo ?? message.envelope?.mimeType?.hasPrefix("video/") ?? false) ? "видео" : "фото" }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: message.viewOnceConsumed ? "eye.slash" : "flame.fill")
                .font(.system(size: 20))
            VStack(alignment: .leading, spacing: 2) {
                Text("Одноразовое \(kind)").font(.system(size: 15, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).opacity(0.8)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { if !message.isMine && !message.viewOnceConsumed { onOpen() } }
    }

    private var subtitle: String {
        if message.viewOnceConsumed { return "Просмотрено" }
        return message.isMine ? "Откроется один раз" : "Нажмите, чтобы открыть"
    }
}

/// Фото/видео под спойлером: размыто, пока не нажмут; первое нажатие только раскрывает.
struct SpoilerContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var revealed = false

    var body: some View {
        ZStack {
            content()
                .blur(radius: revealed ? 0 : 24)
                .allowsHitTesting(revealed)
            if !revealed {
                Text("Спойлер")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.45)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { if !revealed { withAnimation(.easeOut(duration: 0.25)) { revealed = true } } }
    }
}

/// История правок: «Сейчас» и прежние версии, новые сверху.
struct EditHistorySheet: View {
    let message: ChatMessage

    var body: some View {
        NavigationStack {
            List {
                Section("Сейчас") {
                    Text(message.text).textSelection(.enabled)
                }
                Section("Прежние версии") {
                    ForEach(Array(message.edits.reversed().enumerated()), id: \.offset) { _, version in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(version.text).textSelection(.enabled)
                            if let date = version.date {
                                Text("\(TimeFormat.dayHeader(date)), \(TimeFormat.clock(date))")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
            }
            .navigationTitle("История правок")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Карточка трансляции местоположения: последняя точка и «Открыть на карте».
struct LiveLocationCard: View {
    let geo: LiveGeo
    let isMine: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(geo.isActive() ? "Геопозиция в реальном времени" : "Трансляция завершена", systemImage: "location.fill")
                .font(.system(size: 14, weight: .semibold))
            if geo.isActive() {
                let minutes = max(0, Int((Double(geo.until) / 1000 - Date().timeIntervalSince1970) / 60))
                Text("осталось \(minutes) мин").font(.system(size: 12)).opacity(0.8)
            }
            Button("Открыть на карте") {
                if let url = URL(string: "https://maps.apple.com/?ll=\(geo.lat),\(geo.lon)&q=%F0%9F%93%8D") { openURL(url) }
            }
            .font(.system(size: 14, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(isMine ? Color.white : Theme.accent)
        }
    }
}
