import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    let chatId: String
    /// Тема форума — лента только её.
    var topic: ForumTopic? = nil

    @Environment(Services.self) private var services
    @Environment(ChatListStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var model: ChatViewModel?

    var body: some View {
        Group {
            if let model {
                ChatContent(model: model)
            } else {
                ProgressView().tint(Theme.accent)
            }
        }
        .onAppear {
            if model == nil { model = ChatViewModel(chatId: chatId, services: services, topic: topic) }
            // Сообщения в эту группу уходят с номером темы
            if let topic { services.socket.currentTopic = (chatId, topic.id) }
            model?.visible = scenePhase == .active
            store.markOpened(chatId)
            model?.markVisibleRead()
        }
        .onDisappear {
            model?.visible = false
            store.markClosed(chatId)
            if let topic, let current = services.socket.currentTopic, current.chat == chatId, current.id == topic.id {
                services.socket.currentTopic = nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            model?.visible = phase == .active
            if phase == .active { model?.markVisibleRead() }
        }
    }
}

private struct ChatContent: View {
    @Bindable var model: ChatViewModel

    @Environment(Services.self) private var services
    @Environment(ChatListStore.self) private var store
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var viewerImage: UIImage?
    @State private var forwarding: ChatMessage?
    @State private var reactionsOf: ChatMessage?
    @State private var profileTarget: String?
    @State private var linkToConfirm: String?
    @State private var pinnedIndex = 0
    @State private var nearBottom = true
    @State private var editsOf: ChatMessage?
    @State private var remindOf: ChatMessage?
    @State private var crossReplyOf: ChatMessage?
    @State private var readersOf: ChatMessage?
    @State private var searchQuery: String?
    @State private var showScheduled = false
    @State private var showTimer = false
    @State private var forwardingSelection = false
    @State private var anyReactionOf: ChatMessage?
    @State private var stickerSetRef: StickerSetRef?
    @State private var showMedia = false
    @State private var commentsOf: ChatMessage?
    @State private var viewOnceImage: UIImage?
    @State private var viewOnceVideo: URL?
    @Environment(AppModel.self) private var app
    @State private var confetti = false
    @State private var exported: ExportedFile?
    @State private var exporting = false
    /// Идёт запись или трансляция экрана — защищённый чат прячется.
    @State private var screenCaptured = UIScreen.main.isCaptured

    var body: some View {
        VStack(spacing: 0) {
            ConnectionBanner()
            if model.isGroup { GroupCallBanner(chatId: model.chatId) }
            banners
            if !model.pinned.isEmpty { pinnedBar }
            if model.isProtected && screenCaptured {
                // Запрет сохранения: при записи экрана переписку не показываем
                VStack(spacing: 10) {
                    Image(systemName: "eye.slash").font(.system(size: 34))
                    Text("В этой группе запрещено сохранять сообщения — во время записи экрана переписка скрыта.")
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(Theme.muted)
                .padding(30)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                messagesList
            }
            if model.selecting {
                selectionBar
            } else {
                ComposerView(model: model)
            }
        }
        .sheet(item: $remindOf) { message in
            TimePickerSheet(title: "Напомнить") { date in model.remind(message, at: date) }
        }
        .sheet(item: $crossReplyOf) { message in
            ChatPickerSheet(title: "Ответить в чате", exclude: [model.chatId]) { chat in
                model.prepareCrossReply(message, to: chat.chatId)
                app.pendingChat = chat.chatId
            }
        }
        .sheet(item: $readersOf) { message in
            ReadersSheet(model: model, message: message).presentationDetents([.medium, .large])
        }
        .sheet(isPresented: Binding(get: { searchQuery != nil }, set: { if !$0 { searchQuery = nil } })) {
            ChatSearchSheet(model: model, query: searchQuery ?? "") { id in model.jump(to: id) }
        }
        .sheet(isPresented: $showScheduled) { ScheduledListSheet(model: model) }
        .sheet(item: $stickerSetRef) { StickerSetSheet(ref: $0) }
        .sheet(item: $exported) { ShareSheet(items: [$0.url]) }
        .sheet(item: $commentsOf) { post in
            CommentsSheet(chatId: model.chatId, post: post, canModerate: ["owner", "admin"].contains(model.myRole))
        }
        .sheet(item: $anyReactionOf) { message in
            EmojiPickerSheet { emoji in model.react(message, emoji) }
        }
        .sheet(isPresented: $showMedia) {
            MediaGallerySheet(model: model) { id in model.jump(to: id) }
        }
        .sheet(isPresented: $showTimer) { ChatTimerSheet(model: model) }
        .sheet(isPresented: $forwardingSelection) {
            ChatPickerSheet(title: "Переслать \(model.selected.count)") { chat in
                Task { _ = await model.forwardSelected(to: chat.chatId) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            screenCaptured = UIScreen.main.isCaptured
        }
        .sheet(item: $editsOf) { message in
            EditHistorySheet(message: message).presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: Binding(get: { viewOnceImage != nil }, set: { if !$0 { viewOnceImage = nil } })) {
            if let viewOnceImage { ViewOnceImageViewer(image: viewOnceImage) }
        }
        .fullScreenCover(isPresented: Binding(get: { viewOnceVideo != nil }, set: { if !$0 { closeViewOnceVideo() } })) {
            if let viewOnceVideo { VideoPlayerScreen(url: viewOnceVideo) }
        }
        .background(ChatWallpaper())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { header }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !model.isGroup && !model.isSaved && !(store.chat(model.chatId)?.isSystem ?? false)
                        && !(store.chat(model.chatId)?.isDeleted ?? false) {
                        Button { services.calls.call(model.chatId, video: false) } label: { Label("Позвонить", systemImage: "phone") }
                            .disabled(services.calls.isBusy)
                        Button { services.calls.call(model.chatId, video: true) } label: { Label("Видеозвонок", systemImage: "video") }
                            .disabled(services.calls.isBusy)
                    }
                    if model.isGroup && !model.isChannel {
                        Button { services.groupCalls.join(model.chatId) } label: { Label("Звонок в группе", systemImage: "phone.arrow.up.right") }
                            .disabled(services.calls.isBusy || services.groupCalls.isActive)
                    }
                    Button { searchQuery = "" } label: { Label("Поиск в переписке", systemImage: "magnifyingglass") }
                    Button { showMedia = true } label: { Label("Вложения", systemImage: "photo.on.rectangle") }
                    Button { showScheduled = true } label: {
                        Label(model.isSaved ? "Напоминания" : "Отложенные", systemImage: "clock")
                    }
                    if !(store.chat(model.chatId)?.isSystem ?? false) {
                        Button { showTimer = true } label: { Label("Автоудаление", systemImage: "timer") }
                    }
                    if !model.isProtected {
                        Button { exportChat() } label: { Label("Экспорт переписки", systemImage: "square.and.arrow.up") }
                            .disabled(exporting)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { openInfo() } label: {
                    AvatarView(name: model.title, url: store.chat(model.chatId)?.avatarUrl, size: 34,
                               online: !model.isGroup && (store.chat(model.chatId)?.online ?? false) && !model.isSaved,
                               isSaved: model.isSaved)
                }
            }
        }
        .toolbarBackground(.visible, for: .navigationBar)
        .overlay {
            if confetti { ConfettiView().ignoresSafeArea().allowsHitTesting(false) }
        }
        .onAppear(perform: birthdayConfetti)
        .task { await model.loadIfNeeded() }
        .onDisappear { model.dispose() }
        .sheet(item: $forwarding) { message in
            ForwardSheet(message: message, model: model)
        }
        .sheet(item: $reactionsOf) { message in
            ReactionsListSheet(message: message)
                .presentationDetents([.medium])
        }
        .fullScreenCover(isPresented: Binding(get: { viewerImage != nil }, set: { if !$0 { viewerImage = nil } })) {
            if let viewerImage { ImageViewer(image: viewerImage) }
        }
        .navigationDestination(item: $profileTarget) { username in
            UserProfileView(username: username)
        }
        .alert("Открыть ссылку?", isPresented: Binding(get: { linkToConfirm != nil }, set: { if !$0 { linkToConfirm = nil } })) {
            Button("Открыть") { if let s = linkToConfirm, let url = URL(string: s) { openURL(url) } }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(linkToConfirm ?? "")
        }
        .overlay(alignment: .top) { toastView }
    }

    // MARK: - Шапка

    private var header: some View {
        Button(action: openInfo) {
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Text(model.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.onSurface)
                        .lineLimit(1)
                    if store.chat(model.chatId)?.verified == true { VerifiedBadge(size: 12) }
                }
                Text(model.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(subtitleHighlighted ? Theme.accent : Theme.muted)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    private func jumpButton(_ icon: String, count: Int, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Theme.card))
                .overlay(Circle().stroke(Theme.outline))
                .overlay(alignment: .topTrailing) {
                    if count > 1 {
                        Text("\(count)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(tint))
                            .offset(x: 4, y: -4)
                    }
                }
        }
    }

    /// Экспорт переписки текстом: история целиком, расшифровка на устройстве.
    private func exportChat() {
        exporting = true
        model.toast = "Собираю историю переписки…"
        Task {
            defer { exporting = false }
            do {
                let url = try await ChatExport.export(chatId: model.chatId, title: store.title(for: model.chatId), services: services)
                model.toast = nil
                exported = ExportedFile(url: url)
            } catch {
                model.toast = errorText(error)
            }
        }
    }

    /// День рождения собеседника — залп конфетти, раз в день на чат.
    private func birthdayConfetti() {
        guard !model.isGroup, !model.isSaved, ConfettiView.isToday(store.users[model.chatId]?.birthday) else { return }
        let key = "rst.confetti.\(model.chatId).\(Calendar.current.component(.year, from: Date()))-\(Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        confetti = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { confetti = false }
    }

    private func handle(_ action: MessageAction) {
        switch action {
        case .select(let m): model.startSelection(m)
        case .remind(let m): remindOf = m
        case .crossReply(let m): crossReplyOf = m
        case .replyPrivately(let m):
            // Лично автору — цитатой из группы
            model.prepareCrossReply(m, to: m.sender)
            app.pendingChat = m.sender
        case .readers(let m): readersOf = m
        case .hashtag(let tag): searchQuery = "#" + tag
        case .anyReaction(let m): anyReactionOf = m
        case .comments(let m): commentsOf = m
        case .stickerSet(let file): stickerSetRef = StickerSetRef(fileUrl: file)
        }
    }

    /// Панель выделения: переслать, удалить, отмена.
    private var selectionBar: some View {
        HStack(spacing: 18) {
            Button("Отмена") { model.clearSelection() }
            Spacer()
            Text("Выбрано: \(model.selected.count)").font(.system(size: 15, weight: .semibold))
            Spacer()
            if !model.isProtected {
                Button { forwardingSelection = true } label: { Image(systemName: "arrowshape.turn.up.right") }
                    .disabled(model.selected.isEmpty)
            }
            Menu {
                if model.canDeleteSelectedForEveryone {
                    Button(role: .destructive) { model.deleteSelected(forEveryone: true) } label: { Label("Удалить у всех", systemImage: "trash") }
                }
                Button(role: .destructive) { model.deleteSelected(forEveryone: false) } label: { Label("Удалить у себя", systemImage: "trash.slash") }
            } label: {
                Image(systemName: "trash").foregroundStyle(Theme.danger)
            }
            .disabled(model.selected.isEmpty)
        }
        .font(.system(size: 18))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    /// Другой чат (напоминание, карточка контакта); тот же — к сообщению.
    private func openChat(_ chat: String, _ messageId: Int64) {
        if chat == model.chatId {
            if messageId > 0 { model.jump(to: messageId) }
            return
        }
        if chat.hasPrefix("group_") && store.chat(chat) == nil {
            model.toast = "Этого чата больше нет в списке"
            return
        }
        app.pendingChat = chat
    }

    /// Одноразовое: в память, без кэша и без «Сохранить»; видео — во временный
    /// файл только на время просмотра.
    private func openViewOnce(_ message: ChatMessage) {
        let isVideo = message.attachment?.isVideo ?? false
        Task {
            guard let data = await model.openViewOnce(message) else { return }
            if isVideo {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("vo-\(UUID().uuidString).mp4")
                guard (try? data.write(to: url, options: [.completeFileProtection])) != nil else { return }
                viewOnceVideo = url
            } else if let image = UIImage(data: data) {
                viewOnceImage = image
            }
        }
    }

    private func closeViewOnceVideo() {
        if let url = viewOnceVideo { try? FileManager.default.removeItem(at: url) }
        viewOnceVideo = nil
    }

    private var subtitleHighlighted: Bool {
        if store.typingText(model.chatId, isGroup: model.isGroup) != nil { return true }
        return store.chat(model.chatId)?.online == true && !model.isGroup
    }

    private func openInfo() {
        if model.isSaved { return }
        if model.isGroup {
            profileTarget = nil
            groupInfoOpen = true
        } else {
            profileTarget = model.chatId
        }
    }

    @State private var groupInfoOpen = false

    // MARK: - Плашки

    @ViewBuilder
    private var banners: some View {
        if model.keyState == .insecure {
            banner("Группа без сквозного шифрования: ключ выводится из её номера, сервер может прочитать переписку. Администратор может включить шифрование в настройках группы.", icon: "lock.open.fill", color: Theme.danger)
        } else if model.keyState == .pending {
            banner("Ключ шифрования группы ещё не пришёл: его передаст любой участник, когда будет в сети. До этого писать нельзя.", icon: "key.fill", color: Theme.accent)
        }
        if model.keyChanged {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(Theme.accent)
                Text("Ключ шифрования собеседника изменился. Сверьте код безопасности в профиле.")
                    .font(.system(size: 13))
                Spacer()
                Button("OK") { model.acknowledgeKeyChange() }.font(.system(size: 13, weight: .semibold))
            }
            .padding(10)
            .background(Theme.accent.opacity(0.15))
        }
        if let summary = store.chat(model.chatId), summary.isDeleted {
            banner("Аккаунт удалён — написать ему нельзя.", icon: "person.crop.circle.badge.xmark", color: Theme.muted)
        }
    }

    private func banner(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.onSurface)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(color.opacity(0.14))
    }

    private var pinnedBar: some View {
        let list = model.pinned
        let index = min(pinnedIndex, list.count - 1)
        let item = list[max(0, index)]
        return Button {
            model.jump(to: item.id)
            pinnedIndex = (index + 1) % max(list.count, 1)
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.accent).frame(width: 3, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(list.count > 1 ? "Закреплённое \(index + 1) из \(list.count)" : "Закреплённое сообщение")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text(Previews.describe(item))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "pin.fill").foregroundStyle(Theme.muted).font(.system(size: 13))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Theme.surface.opacity(0.92))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Лента

    private enum Item: Identifiable {
        case day(Date)
        case message(ChatMessage, showSender: Bool, showAvatar: Bool)
        /// Альбом: подряд идущие вложения одного автора с общим a (до 10).
        case album([ChatMessage], showSender: Bool, showAvatar: Bool)

        var id: String {
            switch self {
            case .day(let d): return "day-\(Int(d.timeIntervalSince1970))"
            case .message(let m, _, _): return "m\(m.id)"
            // Прокрутка к сообщению альбома ищет id его первого вложения
            case .album(let list, _, _): return "m\(list.first?.id ?? 0)"
            }
        }
    }

    /// Сообщения, собранные в альбомы: подряд, один автор, одинаковый a, не больше 10.
    private func groupAlbums(_ all: [ChatMessage]) -> [[ChatMessage]] {
        var groups: [[ChatMessage]] = []
        for m in all {
            if let album = m.album, m.attachment != nil, !m.viewOnce, !m.isSystem,
               var last = groups.last, last.count < 10, let head = last.first,
               head.album == album, head.sender == m.sender {
                last.append(m)
                groups[groups.count - 1] = last
            } else {
                groups.append([m])
            }
        }
        return groups
    }

    private var items: [Item] {
        let groups = groupAlbums(model.messages + model.pendingMessages)
        var out: [Item] = []
        let cal = Calendar.current
        var lastDay: Date?
        for (i, group) in groups.enumerated() {
            guard let m = group.first else { continue }
            let date = m.createdAt ?? Date()
            let day = cal.startOfDay(for: date)
            if lastDay != day {
                out.append(.day(day))
                lastDay = day
            }
            let prev = i > 0 ? groups[i - 1].last : nil
            let next = i + 1 < groups.count ? groups[i + 1].first : nil
            let sameAsPrev = prev.map { $0.sender == m.sender && !$0.isSystem && cal.isDate($0.createdAt ?? date, inSameDayAs: date) } ?? false
            let sameAsNext = next.map { $0.sender == m.sender && !$0.isSystem } ?? false
            if group.count > 1 {
                out.append(.album(group, showSender: !sameAsPrev, showAvatar: !sameAsNext))
            } else {
                out.append(.message(m, showSender: !sameAsPrev, showAvatar: !sameAsNext))
            }
        }
        return out
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    if model.hasMore {
                        ProgressView()
                            .padding()
                            .onAppear {
                                let anchor = model.messages.first?.id
                                Task {
                                    await model.loadOlder()
                                    if let anchor { proxy.scrollTo("m\(anchor)", anchor: .top) }
                                }
                            }
                    }
                    ForEach(items) { item in
                        switch item {
                        case .day(let date):
                            Text(TimeFormat.dayHeader(date))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.onSurface.opacity(0.8))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Theme.card.opacity(0.8)))
                                .padding(.vertical, 6)
                                .id(item.id)
                        case .message(let m, let showSender, let showAvatar):
                            MessageRow(message: m, isGroup: model.isGroup, isChannel: model.isChannel,
                                       showSender: showSender, showAvatar: showAvatar,
                                       highlighted: model.highlighted == m.id, model: model,
                                       onOpenImage: { viewerImage = $0 },
                                       onForward: { forwarding = $0 },
                                       onReactionsList: { reactionsOf = $0 },
                                       onOpenProfile: { name in if name != store.me { profileTarget = name } },
                                       onConfirmLink: { linkToConfirm = $0 },
                                       onOpenChat: { chat, messageId in openChat(chat, messageId) },
                                       onShowEdits: { editsOf = $0 },
                                       onOpenViewOnce: { openViewOnce($0) },
                                       onAction: { handle($0) })
                                .id(item.id)
                                .onAppear { model.markSeen(m.id) }
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        case .album(let list, let showSender, let showAvatar):
                            AlbumRow(messages: list, isGroup: model.isGroup, isChannel: model.isChannel,
                                     showSender: showSender, showAvatar: showAvatar, model: model,
                                     onOpenImage: { viewerImage = $0 }, onForward: { forwarding = $0 })
                                .id(item.id)
                        }
                    }
                    Color.clear.frame(height: 6).id("bottom")
                        .onAppear { nearBottom = true }
                        .onDisappear { nearBottom = false }
                }
                .padding(.top, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .bottomTrailing) {
                // «❤» — новые реакции на мои, «@» — непросмотренные упоминания
                VStack(spacing: 10) {
                    if !model.reactionQueue.isEmpty {
                        jumpButton("heart.fill", count: model.reactionQueue.count, tint: Theme.danger) {
                            Task { await model.jumpToNextReaction() }
                        }
                    }
                    if !model.mentionQueue.isEmpty {
                        jumpButton("at", count: model.mentionQueue.count, tint: Theme.accent) {
                            Task { await model.jumpToNextMention() }
                        }
                    }
                }
                .padding(.trailing, 14)
                .padding(.bottom, nearBottom ? 14 : 64)
            }
            .overlay {
                if model.loading && model.messages.isEmpty {
                    ProgressView().tint(Theme.accent)
                } else if let error = model.loadError {
                    VStack(spacing: 10) {
                        Text(error).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                        Button("Повторить") { Task { await model.load() } }
                    }
                    .padding()
                } else if model.messages.isEmpty && !model.loading {
                    Text(model.isSaved ? "Сохраняйте сюда заметки, ссылки и файлы" : "Сообщений пока нет")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted)
                        .padding(12)
                        .background(Capsule().fill(Theme.card.opacity(0.8)))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !nearBottom {
                    Button { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.onSurface)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Theme.card))
                            .overlay(Circle().stroke(Theme.outline))
                    }
                    .padding(14)
                }
            }
            .onChange(of: model.scrollTarget) { _, target in
                guard let target else { return }
                let isNewest = target == model.messages.last?.id
                // Новое сообщение — вниз, только если и так были внизу (или оно своё)
                if isNewest {
                    let mine = model.messages.last?.isMine ?? false
                    if nearBottom || mine { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                } else {
                    withAnimation { proxy.scrollTo("m\(target)", anchor: .center) }
                }
                model.scrollTarget = nil
            }
            .onChange(of: model.pendingMessages.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .navigationDestination(isPresented: $groupInfoOpen) {
            GroupInfoView(chatId: model.chatId)
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = model.toast, !toast.isEmpty {
            Text(toast)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.black.opacity(0.85)))
                .padding(.top, 8)
                .padding(.horizontal, 20)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: toast) {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    withAnimation { model.toast = nil }
                }
                .onTapGesture { model.toast = nil }
        }
    }
}

// MARK: - Одноразовые и защита от снимков экрана

/// Одноразовое фото: без «Сохранить» и «Поделиться», на снимке экрана — пусто.
struct ViewOnceImageViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            ScreenshotProtected {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Circle().fill(Color.black.opacity(0.5)))
            }
            .padding()
        }
        .preferredColorScheme(.dark)
    }
}

/// Содержимое внутри слоя защищённого поля ввода (isSecureTextEntry): на снимке
/// и записи экрана он пустой. Аналог FLAG_SECURE на Android. Снимок другим
/// устройством это не остановит.
struct ScreenshotProtected<Content: View>: UIViewRepresentable {
    @ViewBuilder var content: () -> Content

    func makeUIView(context: Context) -> UIView {
        let host = UIHostingController(rootView: content())
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.host = host

        let field = UITextField()
        field.isSecureTextEntry = true
        // Защищённый слой — первый вложенный вид поля; его и берём контейнером
        guard let secure = field.subviews.first else { return host.view }
        secure.subviews.forEach { $0.removeFromSuperview() }
        secure.isUserInteractionEnabled = true
        secure.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: secure.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: secure.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: secure.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: secure.bottomAnchor),
        ])
        return secure
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.host?.rootView = content()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var host: UIHostingController<Content>?
    }
}

// MARK: - Пересылка

private struct ForwardSheet: View {
    let message: ChatMessage
    let model: ChatViewModel
    @Environment(ChatListStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List(store.mainList.filter { $0.canWrite && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }) { chat in
                Button {
                    busy = true
                    Task {
                        if await model.forward(message, to: chat.chatId) { dismiss() }
                        busy = false
                    }
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(name: chat.title, url: chat.avatarUrl, size: 40, isSaved: chat.chatId == store.me)
                        Text(chat.title).foregroundStyle(Theme.onSurface)
                    }
                }
                .disabled(busy)
            }
            .searchable(text: $query, prompt: "Кому переслать")
            .navigationTitle("Переслать")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            }
        }
    }
}

private struct ReactionsListSheet: View {
    let message: ChatMessage
    @Environment(ChatListStore.self) private var store

    var body: some View {
        NavigationStack {
            List(message.reactions.sorted(by: { $0.key < $1.key }), id: \.key) { pair in
                let username = pair.key
                let emoji = pair.value
                HStack(spacing: 12) {
                    AvatarView(name: store.displayName(username), url: store.users[username]?.avatarUrl, size: 36)
                    Text(store.displayName(username))
                    Spacer()
                    if emoji.hasPrefix("s:") {
                        PlainImageView(fileUrl: String(emoji.dropFirst(2)), size: 24)
                    } else {
                        Text(emoji).font(.system(size: 22))
                    }
                }
            }
            .navigationTitle("Реакции")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
