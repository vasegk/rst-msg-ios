import SwiftUI

// Темы в группах — как «Темы» (форум) в Telegram (js/topics.js): группа с
// включёнными темами открывается списком тем, тема — отдельная переписка
// той же группы с topic_id (0 — «Общее»), ключ — ключ группы.

@MainActor
@Observable
final class TopicsModel {
    let chatId: String
    private(set) var data: TopicsResponse?
    private(set) var previews: [Int64: String] = [:]
    var error: String?

    @ObservationIgnored private let services: Services
    @ObservationIgnored private var subscription: UUID?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    init(chatId: String, services: Services) {
        self.chatId = chatId
        self.services = services
        subscription = services.socket.subscribe(owner: self) { [weak self] event in self?.handle(event) }
    }

    var groupNumber: String { String(chatId.dropFirst(GroupKeyRepository.prefix.count)) }
    var topics: [ForumTopicDto] { data?.topics ?? [] }
    var canManage: Bool { data?.canManage ?? false }
    var canCreate: Bool { data?.canCreate ?? false }

    func canEdit(_ t: ForumTopicDto) -> Bool {
        t.general != true && (canManage || t.createdBy == services.me)
    }

    func load() async {
        do {
            let fresh = try await services.api.topics(groupNumber: groupNumber)
            var lines: [Int64: String] = [:]
            for t in fresh.topics ?? [] {
                guard let dto = t.lastMsg else { continue }
                let m = await services.messages.decryptSingle(dto, chatId: chatId)
                let text = Previews.oneLine(TextFormat.strip(Previews.describe(m)))
                if m.isSystem {
                    lines[t.id] = text
                } else {
                    let who = m.isMine ? "Вы" : services.chats.displayName(m.sender)
                    lines[t.id] = "\(who): \(text)"
                }
            }
            data = fresh
            previews = lines
            error = nil
        } catch {
            self.error = errorText(error)
        }
    }

    private func handle(_ event: WsEvent) {
        switch event {
        case .newMessage(_, let receiver) where receiver == chatId:
            scheduleReload()
        case .other(let action, let payload) where action == "topics_changed" || action == "group_forum":
            if payload["group"]?.stringValue == chatId { scheduleReload() }
        default:
            break
        }
    }

    /// Пачку событий — одним запросом.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    func create(title: String, icon: String) async -> ForumTopic? {
        do {
            let t = try await services.api.createTopic(groupNumber: groupNumber, title: title, icon: icon)
            await load()
            return t.topic
        } catch {
            self.error = errorText(error)
            return nil
        }
    }

    func update(_ t: ForumTopicDto, _ request: TopicUpdateRequest) async {
        do {
            try await services.api.updateTopic(groupNumber: groupNumber, id: t.id, request)
            await load()
        } catch {
            self.error = errorText(error)
        }
    }

    func delete(_ t: ForumTopicDto) async {
        do {
            try await services.api.deleteTopic(groupNumber: groupNumber, id: t.id)
            await load()
        } catch {
            self.error = errorText(error)
        }
    }
}

/// Значок темы: эмодзи, «#» у «Общего» или цветная буква названия.
struct TopicIcon: View {
    let title: String
    let icon: String
    var general = false
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            if general {
                Circle().fill(Theme.surface)
                Text("#").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(Theme.muted)
            } else if !icon.isEmpty {
                Text(icon).font(.system(size: size * 0.62))
            } else {
                Circle().fill(Theme.avatarGradient(for: title).0)
                Text(String(title.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                    .font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Список тем группы.
struct TopicsListView: View {
    let chatId: String
    @Environment(Services.self) private var services
    @Environment(ChatListStore.self) private var store
    @State private var model: TopicsModel?
    @State private var editing: ForumTopicDto?
    @State private var creating = false
    @State private var confirmDelete: ForumTopicDto?
    @State private var opened: ForumTopic?

    var body: some View {
        Group {
            if let model {
                list(model)
            } else {
                ProgressView().tint(Theme.accent)
            }
        }
        .background(AppBackground())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                NavigationLink(value: Route.groupInfo(chatId)) {
                    HStack(spacing: 8) {
                        AvatarView(name: store.title(for: chatId), url: store.chat(chatId)?.avatarUrl, size: 30)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(store.title(for: chatId)).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            Text("темы").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            if model?.canCreate == true {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { creating = true } label: { Image(systemName: "square.and.pencil") }
                }
            }
        }
        .task {
            if model == nil { model = TopicsModel(chatId: chatId, services: services) }
            await model?.load()
        }
        .navigationDestination(item: $opened) { topic in ChatView(chatId: chatId, topic: topic) }
        .sheet(isPresented: $creating) {
            TopicEditorSheet(title: "", icon: "", isNew: true, canClose: false, closed: false) { title, icon, _ in
                Task {
                    if let topic = await model?.create(title: title, icon: icon) { opened = topic }
                }
            }
        }
        .sheet(item: $editing) { t in
            TopicEditorSheet(title: t.title, icon: t.icon ?? "", isNew: false, canClose: model?.canManage == true,
                             closed: t.closed ?? false) { title, icon, closed in
                var request = TopicUpdateRequest()
                if title != t.title { request.title = title }
                if icon != (t.icon ?? "") { request.icon = icon }
                if closed != (t.closed ?? false) { request.closed = closed }
                Task { await model?.update(t, request) }
            }
        }
        .confirmationDialog("Удалить тему вместе с сообщениями?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                if let t = confirmDelete { Task { await model?.delete(t) } }
            }
        }
        .alert(model?.error ?? "", isPresented: Binding(get: { model?.error != nil }, set: { if !$0 { model?.error = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func list(_ model: TopicsModel) -> some View {
        List {
            ForEach(model.topics) { t in
                Button { opened = t.topic } label: { row(t, model: model) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if model.canEdit(t) {
                            Button { editing = t } label: { Label("Изменить", systemImage: "pencil") }
                        }
                        if model.canManage && t.general != true {
                            Button {
                                Task { await model.update(t, TopicUpdateRequest(closed: !(t.closed ?? false))) }
                            } label: {
                                Label(t.closed == true ? "Открыть тему" : "Закрыть тему", systemImage: t.closed == true ? "lock.open" : "lock")
                            }
                            Button(role: .destructive) { confirmDelete = t } label: { Label("Удалить", systemImage: "trash") }
                        }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await model.load() }
    }

    private func row(_ t: ForumTopicDto, model: TopicsModel) -> some View {
        HStack(spacing: 12) {
            TopicIcon(title: t.title, icon: t.icon ?? "", general: t.general == true)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(t.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    if t.closed == true { Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(Theme.muted) }
                    Spacer()
                    Text(TimeFormat.listTime(ServerTime.parse(t.lastMsg?.createdAt)))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                HStack {
                    Text(t.lastMsg == nil ? "Пока нет сообщений" : (model.previews[t.id] ?? ""))
                        .font(.system(size: 14)).foregroundStyle(Theme.muted).lineLimit(1)
                    Spacer()
                    if let n = t.unread, n > 0 {
                        Text(n > 999 ? "999+" : "\(n)")
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.accent))
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// Новая тема или правка: название, значок, закрыта ли.
struct TopicEditorSheet: View {
    @State var title: String
    @State var icon: String
    let isNew: Bool
    let canClose: Bool
    @State var closed: Bool
    var onSave: (String, String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    static let icons = ["💬", "📌", "😂", "🔥", "🎮", "🎵", "📷", "📚", "💼", "⚽", "🍔", "✈️", "💡", "❤️", "🛠️", "📢", "🐱", "🎬"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        TopicIcon(title: title.isEmpty ? "?" : title, icon: icon)
                        TextField("Название темы", text: $title)
                    }
                }
                Section("Значок") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                        Button { icon = "" } label: {
                            Text("Aa").font(.system(size: 15, weight: .semibold)).frame(width: 38, height: 38)
                                .background(Circle().stroke(icon.isEmpty ? Theme.accent : Color.clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        ForEach(Self.icons, id: \.self) { e in
                            Button { icon = e } label: {
                                Text(e).font(.system(size: 24)).frame(width: 38, height: 38)
                                    .background(Circle().stroke(icon == e ? Theme.accent : Color.clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if canClose {
                    Toggle("Тема закрыта: пишут только администраторы", isOn: $closed)
                }
            }
            .navigationTitle(isNew ? "Новая тема" : "Тема")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Создать" : "Сохранить") {
                        let clean = title.trimmingCharacters(in: .whitespaces).filter { $0 != "<" && $0 != ">" }
                        onSave(String(clean.prefix(64)), icon, closed)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Комментарии к постам канала

/// Обсуждение поста (js/comments.js): комментарий — сообщение канала с
/// comment_to; писать может любой подписчик, шифрование — ключом канала.
struct CommentsSheet: View {
    let chatId: String
    let post: ChatMessage
    var canModerate: Bool
    @Environment(Services.self) private var services
    @Environment(ChatListStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var comments: [ChatMessage]?
    @State private var text = ""
    @State private var error: String?
    @State private var subscription: UUID?
    @State private var confirmDelete: ChatMessage?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(store.title(for: chatId)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                                Text(post.text.isEmpty ? Previews.describe(post) : TextFormat.strip(post.text))
                                    .font(.system(size: 15)).lineLimit(6)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))

                            if let comments {
                                if comments.isEmpty {
                                    Text("Пока никто не прокомментировал — будьте первым.")
                                        .font(.system(size: 14)).foregroundStyle(Theme.muted)
                                        .frame(maxWidth: .infinity).padding(.top, 20)
                                }
                                ForEach(comments) { c in
                                    commentRow(c).id(c.id)
                                }
                            } else if let error {
                                Text(error).foregroundStyle(Theme.muted)
                            } else {
                                ProgressView().frame(maxWidth: .infinity).padding(.top, 20)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: comments?.count) {
                        if let last = comments?.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                HStack(spacing: 8) {
                    TextField("Комментировать…", text: $text, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Theme.input, in: RoundedRectangle(cornerRadius: 20))
                    Button { send() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(10)
                .background(.ultraThinMaterial)
            }
            .background(AppBackground())
            .navigationTitle(comments.map { CommentsSheet.countText($0.count) } ?? "Комментарии")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
            .confirmationDialog("Удалить комментарий? Он пропадёт у всех.", isPresented: Binding(
                get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
                Button("Удалить", role: .destructive) {
                    if let c = confirmDelete, services.socket.sendDelete(messageId: c.id, mode: "both") {
                        comments?.removeAll { $0.id == c.id }
                    }
                }
            }
        }
        .task { await load() }
        .onAppear {
            subscription = services.socket.subscribe { event in handle(event) }
        }
        .onDisappear { services.socket.unsubscribe(subscription) }
    }

    static func countText(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return "\(n) комментарий" }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return "\(n) комментария" }
        return "\(n) комментариев"
    }

    private func commentRow(_ c: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(name: store.displayName(c.sender), url: store.users[c.sender]?.avatarUrl, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(c.isMine ? "Вы" : store.displayName(c.sender)).font(.system(size: 13, weight: .semibold))
                    Text(c.createdAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Text(TextFormat.strip(c.text)).font(.system(size: 15))
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button { UIPasteboard.general.string = c.text } label: { Label("Копировать", systemImage: "doc.on.doc") }
            if c.isMine || canModerate {
                Button(role: .destructive) { confirmDelete = c } label: { Label("Удалить", systemImage: "trash") }
            }
        }
    }

    private func load() async {
        do {
            comments = try await services.messages.comments(chatId, post: post.id)
        } catch {
            self.error = "Не удалось загрузить комментарии."
        }
    }

    private func handle(_ event: WsEvent) {
        switch event {
        case .newMessage(let dto, let receiver):
            guard receiver == chatId, dto.commentTo == post.id else { return }
            Task {
                let m = await services.messages.decryptSingle(dto, chatId: chatId)
                if comments?.contains(where: { $0.id == m.id }) == false { comments?.append(m) }
            }
        case .messageDeleted(let id, _):
            comments?.removeAll { $0.id == id }
        default:
            break
        }
    }

    private func send() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        Task {
            do {
                try await services.messages.sendComment(chatId, post: post.id, text: body)
                text = ""
            } catch {
                self.error = errorText(error)
            }
        }
    }
}
