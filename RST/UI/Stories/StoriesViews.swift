import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// Истории (js/stories.js): полоса над списком чатов, просмотр, публикация.

/// Кольца историй над списком: «Моя история» и авторы, непросмотренные — ярко.
struct StoriesBar: View {
    @Environment(Services.self) private var services
    @Environment(ChatListStore.self) private var store
    @State private var viewing: StoryStart?
    @State private var composing = false

    private var stories: StoryStore { services.stories }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                Button {
                    if let mine = stories.mine, !mine.stories.isEmpty {
                        viewing = StoryStart(author: mine.author)
                    } else {
                        composing = true
                    }
                } label: {
                    ring(name: store.myProfile?.displayName ?? services.me, url: store.myProfile?.avatarUrl,
                         title: "Моя история", unseen: false, has: stories.mine != nil, plus: stories.mine == nil)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { composing = true } label: { Label("Добавить историю", systemImage: "plus") }
                }
                ForEach(stories.others) { a in
                    Button { viewing = StoryStart(author: a.author) } label: {
                        ring(name: a.displayName ?? a.author, url: a.avatarUrl, title: a.displayName ?? a.author,
                             unseen: a.hasUnseen, has: true, plus: false)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .task { await stories.load() }
        .fullScreenCover(item: $viewing) { start in StoryViewer(startAuthor: start.author) }
        .sheet(isPresented: $composing) { StoryComposeSheet() }
    }

    private func ring(name: String, url: String?, title: String, unseen: Bool, has: Bool, plus: Bool) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(name: name, url: url, size: 56)
                    .padding(3)
                    .overlay(
                        Circle().stroke(
                            unseen ? AnyShapeStyle(LinearGradient(colors: [Theme.accent, Theme.accentLight],
                                                                  startPoint: .topLeading, endPoint: .bottomTrailing))
                                : AnyShapeStyle(has ? Theme.muted.opacity(0.5) : Color.clear),
                            lineWidth: 2.5)
                    )
                if plus {
                    Image(systemName: "plus.circle.fill").font(.system(size: 20)).foregroundStyle(.white, Theme.accent)
                }
            }
            Text(title).font(.system(size: 11)).lineLimit(1).frame(width: 66)
        }
    }
}

struct StoryStart: Identifiable {
    let author: String
    var id: String { author }
}

// MARK: - Просмотр

/// Листание историй автора и дальше по авторам; удержание — пауза.
struct StoryViewer: View {
    let startAuthor: String
    @Environment(Services.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var authorIndex = 0
    @State private var storyIndex = 0
    @State private var opened: StoryStore.Opened?
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var progress: Double = 0
    @State private var paused = false
    @State private var error: String?
    @State private var reply = ""
    @State private var showComments = false
    @State private var showViewers = false
    @State private var confirmDelete = false
    @State private var notice: String?
    @FocusState private var replyFocused: Bool

    static let photoSeconds: Double = 6

    private var stories: StoryStore { services.stories }
    private var authors: [StoryAuthorDto] { stories.authors }
    private var entry: StoryAuthorDto? { authors.indices.contains(authorIndex) ? authors[authorIndex] : nil }
    private var story: StoryDto? {
        guard let entry, entry.stories.indices.contains(storyIndex) else { return nil }
        return entry.stories[storyIndex]
    }
    private var isMine: Bool { entry?.author == services.me }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            media
            // Нажатие слева — назад, справа — вперёд; удержание — пауза
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).onTapGesture { previous() }
                Color.clear.contentShape(Rectangle()).onTapGesture { next() }
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.25)
                    .onChanged { _ in setPaused(true) }
                    .onEnded { _ in setPaused(false) }
            )
            .padding(.top, 80)
            .padding(.bottom, 90)
            VStack(spacing: 8) {
                header
                Spacer()
                if let caption = opened?.caption, !caption.isEmpty {
                    Text(caption)
                        .font(.system(size: 16)).foregroundStyle(.white)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                }
                footer
            }
        }
        .statusBarHidden()
        .onAppear(perform: start)
        .task(id: story?.id) { await load() }
        .task(id: "\(story?.id ?? 0)-\(paused)-\(opened != nil)") { await tick() }
        .sheet(isPresented: $showComments, onDismiss: { setPaused(false) }) {
            if let story, let entry {
                StoryCommentsSheet(story: story, author: entry.author, canWrite: entry.commentsEnabled != false)
            }
        }
        .sheet(isPresented: $showViewers, onDismiss: { setPaused(false) }) {
            if let story { StoryViewersSheet(story: story) }
        }
        .confirmationDialog("Удалить историю?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { deleteCurrent() }
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil; setPaused(false) } })) {
            Button("OK", role: .cancel) {}
        }
        .onChange(of: replyFocused) { _, focused in setPaused(focused) }
        .onDisappear { player?.pause() }
    }

    @ViewBuilder
    private var media: some View {
        if let opened, opened.isVideo, let player {
            VideoPlayer(player: player).disabled(true).ignoresSafeArea()
        } else if let image {
            Image(uiImage: image).resizable().scaledToFit()
        } else if let error {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 34))
                Text(error).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white.opacity(0.8)).padding()
        } else {
            ProgressView().tint(.white)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(Array((entry?.stories ?? []).enumerated()), id: \.offset) { i, _ in
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.35))
                            Capsule().fill(Color.white)
                                .frame(width: geo.size.width * (i < storyIndex ? 1 : (i == storyIndex ? progress : 0)))
                        }
                    }
                    .frame(height: 3)
                }
            }
            HStack(spacing: 10) {
                AvatarView(name: entry?.displayName ?? entry?.author ?? "", url: entry?.avatarUrl, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(isMine ? "Моя история" : (entry?.displayName ?? entry?.author ?? ""))
                        .font(.system(size: 15, weight: .semibold))
                    Text(TimeFormat.listTime(ServerTime.parse(story?.createdAt))).font(.system(size: 12)).opacity(0.75)
                }
                Spacer()
                if isMine {
                    Menu {
                        Button(role: .destructive) {
                            setPaused(true)
                            confirmDelete = true
                        } label: { Label("Удалить историю", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold)).frame(width: 36, height: 36)
                    }
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).frame(width: 36, height: 36)
                }
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var footer: some View {
        if let story, let entry {
            HStack(spacing: 12) {
                if isMine {
                    Button {
                        setPaused(true)
                        showViewers = true
                    } label: {
                        Label("\(story.views ?? 0)", systemImage: "eye").font(.system(size: 15, weight: .medium))
                    }
                    if (story.likes ?? 0) > 0 {
                        Label("\(story.likes ?? 0)", systemImage: "heart.fill").font(.system(size: 15))
                    }
                    Spacer()
                    Button {
                        setPaused(true)
                        showComments = true
                    } label: {
                        Label("\(story.comments ?? 0)", systemImage: "bubble.left").font(.system(size: 15))
                    }
                } else {
                    TextField("Ответить…", text: $reply)
                        .focused($replyFocused)
                        .submitLabel(.send)
                        .onSubmit(sendReply)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Capsule().stroke(Color.white.opacity(0.6)))
                    if entry.commentsEnabled != false {
                        Button {
                            setPaused(true)
                            showComments = true
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "bubble.left").font(.system(size: 22))
                                if (story.comments ?? 0) > 0 {
                                    Text("\(story.comments ?? 0)").font(.system(size: 10, weight: .bold))
                                        .padding(3).background(Circle().fill(Theme.accent)).offset(x: 8, y: -6)
                                }
                            }
                        }
                    }
                    Button {
                        Task { await stories.like(story, liked: story.liked != true) }
                    } label: {
                        Image(systemName: story.liked == true ? "heart.fill" : "heart").font(.system(size: 24))
                            .foregroundStyle(story.liked == true ? Color.red : Color.white)
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Ход

    private func start() {
        authorIndex = max(0, authors.firstIndex { $0.author == startAuthor } ?? 0)
        // С первой непросмотренной
        storyIndex = entry?.stories.firstIndex { $0.viewed != true } ?? 0
    }

    private func load() async {
        player?.pause()
        player = nil
        image = nil
        opened = nil
        error = nil
        progress = 0
        guard let story, let entry else { return }
        do {
            let o = try await stories.open(story, author: entry.author)
            if o.isVideo {
                let p = AVPlayer(url: o.fileURL)
                player = p
                if !paused { p.play() }
            } else {
                let path = o.fileURL.path
                image = await Task.detached { UIImage(contentsOfFile: path) }.value
            }
            opened = o
            stories.markViewed(story, author: entry.author)
        } catch {
            self.error = errorText(error)
        }
    }

    /// Полоса хода: фото — 6 секунд, видео — по его длине.
    private func tick() async {
        guard opened != nil || error != nil, !paused else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled, !paused else { return }
            if let player, let item = player.currentItem {
                let d = item.duration.seconds
                if d.isFinite && d > 0 { progress = min(1, player.currentTime().seconds / d) }
            } else {
                progress = min(1, progress + 0.05 / Self.photoSeconds)
            }
            if progress >= 1 {
                next()
                return
            }
        }
    }

    private func setPaused(_ value: Bool) {
        paused = value
        if value { player?.pause() } else { player?.play() }
    }

    private func next() {
        guard let entry else { return dismiss() }
        if storyIndex + 1 < entry.stories.count {
            storyIndex += 1
        } else if authorIndex + 1 < authors.count {
            authorIndex += 1
            storyIndex = authors[authorIndex].stories.firstIndex { $0.viewed != true } ?? 0
        } else {
            dismiss()
        }
    }

    private func previous() {
        if storyIndex > 0 {
            storyIndex -= 1
        } else if authorIndex > 0 {
            authorIndex -= 1
            storyIndex = max(0, authors[authorIndex].stories.count - 1)
        } else {
            progress = 0
            player?.seek(to: .zero)
        }
    }

    private func sendReply() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let story, let entry else { return }
        reply = ""
        replyFocused = false
        Task {
            do {
                try await services.messages.sendStoryReply(to: entry.author, text: text,
                                                           ref: StoryRef(author: entry.author, id: story.id, thumbnail: nil))
                notice = "Ответ отправлен"
                setPaused(true)
            } catch {
                notice = errorText(error)
            }
        }
    }

    private func deleteCurrent() {
        guard let story else { return }
        Task {
            do {
                try await stories.delete(story)
                if entry?.stories.isEmpty != false {
                    dismiss()
                } else {
                    storyIndex = min(storyIndex, (entry?.stories.count ?? 1) - 1)
                }
            } catch {
                notice = errorText(error)
            }
        }
    }
}

// MARK: - Комментарии и зрители

struct StoryCommentsSheet: View {
    let story: StoryDto
    let author: String
    let canWrite: Bool
    @Environment(Services.self) private var services
    @Environment(ChatListStore.self) private var store
    @State private var comments: [StoryStore.Comment]?
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    if let comments {
                        if comments.isEmpty { Text("Комментариев пока нет").foregroundStyle(Theme.muted) }
                        ForEach(comments) { c in
                            HStack(alignment: .top, spacing: 10) {
                                AvatarView(name: c.name, url: c.avatarUrl, size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name).font(.system(size: 13, weight: .semibold))
                                    Text(c.text).font(.system(size: 15))
                                }
                            }
                            .swipeActions {
                                if c.canDelete {
                                    Button("Удалить", role: .destructive) { delete(c) }
                                }
                            }
                        }
                    } else if let error {
                        Text(error).foregroundStyle(Theme.danger)
                    } else {
                        ProgressView()
                    }
                }
                if canWrite {
                    HStack {
                        TextField("Комментарий…", text: $text, axis: .vertical).lineLimit(1...4)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Theme.input, in: RoundedRectangle(cornerRadius: 18))
                        Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)) }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(10)
                } else {
                    Text("Автор выключил комментарии").font(.system(size: 13)).foregroundStyle(Theme.muted).padding()
                }
            }
            .navigationTitle("Комментарии")
            .navigationBarTitleDisplayMode(.inline)
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        do {
            comments = try await services.stories.comments(story, author: author) { store.displayName($0) }
        } catch {
            self.error = errorText(error)
        }
    }

    private func send() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        text = ""
        Task {
            do {
                try await services.stories.addComment(story, author: author, text: body)
                await load()
            } catch {
                self.error = errorText(error)
            }
        }
    }

    private func delete(_ c: StoryStore.Comment) {
        Task {
            try? await services.stories.deleteComment(story, comment: c.id)
            await load()
        }
    }
}

struct StoryViewersSheet: View {
    let story: StoryDto
    @Environment(Services.self) private var services
    @State private var data: StoryViewersResponse?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let data {
                    Section {
                        ForEach(data.viewers ?? []) { v in
                            HStack(spacing: 12) {
                                AvatarView(name: v.displayName ?? v.username, url: v.avatarUrl, size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(v.displayName ?? v.username)
                                    Text(TimeFormat.listTime(ServerTime.parse(v.viewedAt))).font(.system(size: 12)).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                if v.liked == true { Image(systemName: "heart.fill").foregroundStyle(.red) }
                            }
                        }
                    } footer: {
                        Text("Посмотрели \(data.viewers?.count ?? 0) из \(data.audience ?? 0)")
                    }
                } else if let error {
                    Text(error).foregroundStyle(Theme.danger)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Кто смотрел")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                do { data = try await services.stories.viewers(story) } catch { self.error = errorText(error) }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Публикация

/// Несколько фото и видео с общей подписью: каждое — своя история.
struct StoryComposeSheet: View {
    @Environment(Services.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var items: [PhotosPickerItem] = []
    @State private var files: [StoryStore.Outgoing] = []
    @State private var previews: [UIImage] = []
    @State private var caption = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $items, maxSelectionCount: StoryStore.maxPerPublish, matching: .any(of: [.images, .videos])) {
                        Label(files.isEmpty ? "Выбрать фото или видео" : "Выбрано: \(files.count)", systemImage: "photo.on.rectangle")
                    }
                    if !previews.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(Array(previews.enumerated()), id: \.offset) { _, img in
                                    Image(uiImage: img).resizable().scaledToFill()
                                        .frame(width: 70, height: 110).clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                    }
                }
                Section {
                    TextField("Подпись", text: $caption, axis: .vertical).lineLimit(1...4)
                } footer: {
                    Text("История видна сутки вашим контактам — тем, кому вы писали сами. Скрыть её от кого-то можно в настройках конфиденциальности.")
                }
                if let error { Text(error).foregroundStyle(Theme.danger) }
            }
            .navigationTitle("Новая история")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Опубликовать") { publish() }.disabled(files.isEmpty)
                    }
                }
            }
            .onChange(of: items) { _, picked in Task { await prepare(picked) } }
        }
    }

    private func prepare(_ picked: [PhotosPickerItem]) async {
        var out: [StoryStore.Outgoing] = []
        var thumbs: [UIImage] = []
        for item in picked {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            if let movie = item.supportedContentTypes.first(where: { $0.conforms(to: .movie) }) {
                out.append(StoryStore.Outgoing(data: data, mime: movie.preferredMIMEType ?? "video/mp4"))
                thumbs.append(UIImage(systemName: "video.fill") ?? UIImage())
            } else {
                // Фото — JPEG до 2560 точек, как в вебе
                let jpeg = AttachmentRepository.compressImage(data) ?? data
                out.append(StoryStore.Outgoing(data: jpeg, mime: "image/jpeg"))
                if let img = UIImage(data: jpeg) { thumbs.append(img) }
            }
        }
        files = out
        previews = thumbs
    }

    private func publish() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await services.stories.publish(files, caption: caption.trimmingCharacters(in: .whitespacesAndNewlines))
                dismiss()
            } catch {
                self.error = errorText(error)
            }
        }
    }
}

// MARK: - Скрыть мои истории от

struct StoryHiddenView: View {
    @Environment(Services.self) private var services
    @Environment(ChatListStore.self) private var store
    @State private var hidden: Set<String> = []
    @State private var loaded = false
    @State private var error: String?

    private var people: [ChatSummary] {
        store.chats.filter { !$0.isGroup && !$0.isSystem && !$0.isDeleted && $0.chatId != services.me }
    }

    var body: some View {
        List {
            Section {
                ForEach(people) { p in
                    Button {
                        if hidden.contains(p.chatId) { hidden.remove(p.chatId) } else { hidden.insert(p.chatId) }
                        save()
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(name: p.title, url: p.avatarUrl, size: 34)
                            Text(p.title).foregroundStyle(Theme.onSurface)
                            Spacer()
                            if hidden.contains(p.chatId) { Image(systemName: "eye.slash.fill").foregroundStyle(Theme.accent) }
                        }
                    }
                }
            } footer: {
                Text("Отмеченные не увидят ваши истории — ни новые, ни уже опубликованные.")
            }
            if let error { Text(error).foregroundStyle(Theme.danger) }
        }
        .navigationTitle("Скрыть истории от")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded else { return }
            loaded = true
            do { hidden = Set(try await services.stories.hidden()) } catch { self.error = errorText(error) }
        }
    }

    private func save() {
        let names = hidden.sorted()
        Task {
            do { try await services.stories.setHidden(names) } catch { self.error = errorText(error) }
        }
    }
}
