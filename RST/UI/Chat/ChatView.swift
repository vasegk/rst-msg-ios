import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    let chatId: String

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
            if model == nil { model = ChatViewModel(chatId: chatId, services: services) }
            model?.visible = scenePhase == .active
            store.markOpened(chatId)
            model?.markVisibleRead()
        }
        .onDisappear {
            model?.visible = false
            store.markClosed(chatId)
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

    var body: some View {
        VStack(spacing: 0) {
            ConnectionBanner()
            banners
            if !model.pinned.isEmpty { pinnedBar }
            messagesList
            ComposerView(model: model)
        }
        .background(AppBackground())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { header }
            ToolbarItem(placement: .topBarTrailing) {
                Button { openInfo() } label: {
                    AvatarView(name: model.title, url: store.chat(model.chatId)?.avatarUrl, size: 34,
                               online: !model.isGroup && (store.chat(model.chatId)?.online ?? false) && !model.isSaved,
                               isSaved: model.isSaved)
                }
            }
        }
        .toolbarBackground(.visible, for: .navigationBar)
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

        var id: String {
            switch self {
            case .day(let d): return "day-\(Int(d.timeIntervalSince1970))"
            case .message(let m, _, _): return "m\(m.id)"
            }
        }
    }

    private var items: [Item] {
        let all = model.messages + model.pendingMessages
        var out: [Item] = []
        let cal = Calendar.current
        var lastDay: Date?
        for (i, m) in all.enumerated() {
            let date = m.createdAt ?? Date()
            let day = cal.startOfDay(for: date)
            if lastDay != day {
                out.append(.day(day))
                lastDay = day
            }
            let prev = i > 0 ? all[i - 1] : nil
            let next = i + 1 < all.count ? all[i + 1] : nil
            let sameAsPrev = prev.map { $0.sender == m.sender && !$0.isSystem && cal.isDate($0.createdAt ?? date, inSameDayAs: date) } ?? false
            let sameAsNext = next.map { $0.sender == m.sender && !$0.isSystem } ?? false
            out.append(.message(m, showSender: !sameAsPrev, showAvatar: !sameAsNext))
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
                                       onConfirmLink: { linkToConfirm = $0 })
                                .id(item.id)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
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
