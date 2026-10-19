import SwiftUI

/// Что сделать с сообщением — из меню пузыря в экран переписки.
enum MessageAction {
    case select(ChatMessage)
    case remind(ChatMessage)
    case crossReply(ChatMessage)
    case replyPrivately(ChatMessage)
    case readers(ChatMessage)
    case hashtag(String)
    case anyReaction(ChatMessage)
    case stickerSet(String)
    case comments(ChatMessage)
}

// MARK: - Любая реакция

/// Любой эмодзи реакцией (сервер принимает один значок, в т. ч. составной).
struct EmojiPickerSheet: View {
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var custom = ""
    @State private var stickers = false

    private struct EmojiGroup: Identifiable {
        let title: String
        let emojis: [String]
        var id: String { title }
    }

    private static let groups: [EmojiGroup] = [
        EmojiGroup(title: "Смайлы", emojis: Array("😀😃😄😁😆😅😂🤣🥲☺️😊😇🙂🙃😉😌😍🥰😘😋😛😝😜🤪🤨🧐🤓😎🥳😏😒😞😔😟😕🙁☹️😣😖😫😩🥺😢😭😤😠😡🤬🤯😳🥵🥶😱😨😰😥😓🤗🤔🫡🤭🤫😶😐😑😬🙄😯😮😲🥱😴🤤😵🤐🥴🤢🤮🤧😷🤒🤑🤠😈👻💀👽🤖🎃😺😹😻").map(String.init)),
        EmojiGroup(title: "Жесты", emojis: Array("👋🤚✋🖖👌🤌🤏✌️🤞🫰🤟🤘🤙👈👉👆👇☝️👍👎✊👊👏🙌🫶👐🤲🤝🙏✍️💪👀👅👄").map(String.init)),
        EmojiGroup(title: "Сердца", emojis: Array("❤️🧡💛💚💙💜🖤🤍🤎💔❣️💕💞💓💗💖💘💝").map(String.init)),
        EmojiGroup(title: "Разное", emojis: Array("🔥✨⭐🌟💫💥💯✅❌❓❗⚡🎉🎊🎁🏆🥇🎯🚀💡📌🔑💰🍕🍔🍿🍰🎂☕🍺🍷🥂⚽🎮🎧🎵📷🌈☀️🌙🌸🌹🍀🐶🐱🦊🐻🐼🐯🦁🐸🐵🙈🙉🙊🦄🐝🦋🐢🐳").map(String.init)),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("", selection: $stickers) {
                        Text("Эмодзи").tag(false)
                        Text("Стикеры").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if stickers {
                        StickerReactionGrid { value in
                            dismiss()
                            onPick(value)
                        }
                    } else {
                        HStack {
                            TextField("Любой эмодзи", text: $custom)
                                .textFieldStyle(.roundedBorder)
                            Button("OK") { pick(custom) }
                                .disabled(!Self.isSingleEmoji(custom))
                        }
                        ForEach(Self.groups) { group in
                            Text(group.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 8) {
                                ForEach(Array(group.emojis.enumerated()), id: \.offset) { _, emoji in
                                    Button { pick(emoji) } label: { Text(emoji).font(.system(size: 28)) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Реакция")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
        }
    }

    /// Один значок (в т. ч. составной): без ASCII и пробелов, до 16 знаков.
    static func isSingleEmoji(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count == 1, t.utf16.count <= 16, !t.contains(where: { $0.isASCII }) else { return false }
        return t.unicodeScalars.contains { $0.properties.isEmoji }
    }

    private func pick(_ emoji: String) {
        let e = emoji.trimmingCharacters(in: .whitespaces)
        guard Self.isSingleEmoji(e) else { return }
        dismiss()
        onPick(e)
    }
}

// MARK: - Вложения чата

/// «Вложения» чата: фото и видео сеткой, файлы и голосовые списком;
/// нажатие — к сообщению.
struct MediaGallerySheet: View {
    let model: ChatViewModel
    var onJump: (Int64) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var items: [ChatMessage] = []
    @State private var loading = true
    @State private var tab = 0

    private func isVisual(_ m: ChatMessage) -> Bool {
        (m.attachment?.isImage ?? false) || (m.attachment?.isVideo ?? false)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Фото и видео").tag(0)
                    Text("Файлы").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()
                if tab == 0 {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                            ForEach(items.filter { isVisual($0) }) { m in
                                cell(m)
                            }
                        }
                    }
                } else {
                    List(items.filter { !isVisual($0) }) { m in
                        Button { dismiss(); onJump(m.id) } label: {
                            HStack {
                                Image(systemName: (m.attachment?.isAudio ?? false) ? "waveform" : "doc")
                                VStack(alignment: .leading) {
                                    Text((m.attachment?.isAudio ?? false) ? "Голосовое сообщение" : (m.attachment?.fileName ?? "Файл"))
                                        .lineLimit(1)
                                    Text(TimeFormat.listTime(m.createdAt)).font(.system(size: 12)).foregroundStyle(Theme.muted)
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if loading { ProgressView() }
                if !loading && items.isEmpty { Text("Вложений пока нет").foregroundStyle(Theme.muted) }
            }
            .navigationTitle("Вложения")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
            .task {
                items = await model.loadMedia()
                loading = false
            }
        }
    }

    @ViewBuilder
    private func cell(_ m: ChatMessage) -> some View {
        if let a = m.attachment {
            Group {
                if a.isImage {
                    EncryptedImageView(attachment: a, maxWidth: 130, maxHeight: 130)
                } else {
                    VideoAttachmentView(attachment: a)
                }
            }
            .frame(width: 124, height: 124)
            .clipped()
            .contextMenu {
                Button { dismiss(); onJump(m.id) } label: { Label("К сообщению", systemImage: "arrow.right.circle") }
            }
        }
    }
}

// MARK: - Выбор времени (отложенное, напоминание)

struct TimePickerSheet: View {
    let title: String
    var onPick: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var custom = Date().addingTimeInterval(3600)

    private struct Preset: Identifiable {
        let title: String
        let date: Date
        var id: String { title }
    }

    private var presets: [Preset] {
        let cal = Calendar.current
        let now = Date()
        var list = [Preset(title: "Через час", date: now.addingTimeInterval(3600))]
        if let evening = cal.date(bySettingHour: 18, minute: 0, second: 0, of: now), evening > now.addingTimeInterval(60) {
            list.append(Preset(title: "Сегодня в 18:00", date: evening))
        }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
           let morning = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) {
            list.append(Preset(title: "Завтра в 9:00", date: morning))
        }
        return list
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(presets) { preset in
                        Button(preset.title) { pick(preset.date) }
                    }
                }
                Section("Своё время") {
                    DatePicker("Когда", selection: $custom, in: Date().addingTimeInterval(60)...)
                        .datePickerStyle(.graphical)
                    Button("Выбрать") { pick(custom) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
        }
    }

    private func pick(_ date: Date) {
        dismiss()
        onPick(date)
    }
}

// MARK: - Отложенные сообщения чата

struct ScheduledListSheet: View {
    let model: ChatViewModel
    @State private var items: [MessageRepository.ScheduledItem] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List {
                if !loading && items.isEmpty {
                    Text("Отложенных сообщений нет").foregroundStyle(Theme.muted)
                }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.text).lineLimit(3)
                        Text(when(item)).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    .swipeActions {
                        Button(role: .destructive) { Task { await model.cancelScheduled(item.id); await load() } } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                        Button { Task { await model.sendScheduledNow(item.id); await load() } } label: {
                            Label("Сейчас", systemImage: "paperplane")
                        }
                        .tint(Theme.accent)
                    }
                }
            }
            .overlay { if loading { ProgressView() } }
            .navigationTitle(model.isSaved ? "Напоминания" : "Отложенные")
            .navigationBarTitleDisplayMode(.inline)
            .task { await load() }
        }
    }

    private func when(_ item: MessageRepository.ScheduledItem) -> String {
        if item.whenOnline { return "когда собеседник будет в сети" }
        guard let date = item.sendAt else { return "" }
        let prefix = item.reminder ? "🔔 " : ""
        return prefix + "\(TimeFormat.dayHeader(date)), \(TimeFormat.clock(date))"
    }

    private func load() async {
        items = await model.loadScheduled()
        loading = false
    }
}

// MARK: - Кто прочитал (группа)

struct ReadersSheet: View {
    let model: ChatViewModel
    let message: ChatMessage
    @State private var readers: [ReaderDto] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List {
                if !loading && readers.isEmpty {
                    Text("Пока никто не прочитал").foregroundStyle(Theme.muted)
                }
                ForEach(readers) { r in
                    HStack(spacing: 12) {
                        AvatarView(name: r.name ?? r.username, url: r.avatarUrl, size: 36)
                        Text(r.deleted == true ? "Удалённый аккаунт" : ((r.name?.isEmpty == false ? r.name : nil) ?? r.username))
                    }
                }
            }
            .overlay { if loading { ProgressView() } }
            .navigationTitle("Прочитали")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                readers = await model.readers(of: message)
                loading = false
            }
        }
    }
}

// MARK: - Автоудаление

struct ChatTimerSheet: View {
    let model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var current = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Удалять сообщения", selection: $current) {
                        Text("Выключено").tag(0)
                        Text("Через сутки").tag(86400)
                        Text("Через неделю").tag(604800)
                        Text("Через месяц").tag(2592000)
                    }
                    .pickerStyle(.inline)
                } footer: {
                    Text("Новые сообщения в этом чате удалятся у всех через выбранное время.")
                }
            }
            .navigationTitle("Автоудаление")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        model.setTimer(current)
                        dismiss()
                    }
                }
            }
            .task { current = await model.loadTimer() }
        }
    }
}

// MARK: - Выбор чата и контакта

struct ChatPickerSheet: View {
    let title: String
    var exclude: Set<String> = []
    var peopleOnly = false
    var onPick: (ChatSummary) -> Void
    @Environment(ChatListStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var list: [ChatSummary] {
        let all = store.mainList.filter { chat in
            !exclude.contains(chat.chatId) && !chat.isSystem && (!peopleOnly || (!chat.isGroup && chat.chatId != store.me))
                && (query.isEmpty || chat.title.localizedCaseInsensitiveContains(query) || chat.chatId.localizedCaseInsensitiveContains(query))
        }
        // Избранное — первым
        return all.filter { $0.chatId == store.me } + all.filter { $0.chatId != store.me }
    }

    var body: some View {
        NavigationStack {
            List(list) { chat in
                Button {
                    dismiss()
                    onPick(chat)
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(name: chat.title, url: chat.avatarUrl, size: 40, isSaved: chat.chatId == store.me)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chat.title).foregroundStyle(Theme.onSurface)
                            if !chat.isGroup && chat.chatId != store.me {
                                Text("@" + chat.chatId).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Поиск")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
        }
    }
}

// MARK: - Поиск в переписке

struct ChatSearchSheet: View {
    let model: ChatViewModel
    @State var query: String
    var onJump: (Int64) -> Void
    @Environment(ChatListStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var loadingMore = false

    private var found: [ChatMessage] { model.search(query) }

    var body: some View {
        NavigationStack {
            List {
                ForEach(found) { m in
                    Button {
                        dismiss()
                        onJump(m.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(m.isMine ? "Вы" : store.displayName(m.sender)).font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Text(TimeFormat.listTime(m.createdAt)).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                            Text(Previews.describe(m)).font(.system(size: 14)).lineLimit(2).foregroundStyle(Theme.onSurface)
                        }
                    }
                }
                if query.count >= 2 && model.hasMore {
                    Button {
                        loadingMore = true
                        Task {
                            await model.loadOlder()
                            loadingMore = false
                        }
                    } label: {
                        HStack {
                            Text("Искать в более ранних сообщениях")
                            if loadingMore {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(loadingMore)
                }
                if query.count >= 2 && found.isEmpty && !model.hasMore {
                    Text("Ничего не нашлось").foregroundStyle(Theme.muted)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Поиск в переписке")
            .navigationTitle("Поиск")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
        }
    }
}

// MARK: - Превью ссылки

/// Ответ /api/link-preview в памяти: nil тоже запоминаем — у страницы нечего показать.
final class LinkPreviewBox {
    let value: LinkPreviewDto?
    init(_ value: LinkPreviewDto?) { self.value = value }
}

enum LinkPreviewCache {
    static let shared = NSCache<NSString, LinkPreviewBox>()
}

/// Карточка ссылки под текстом. Сервер сам открывает страницу; фрагмент #…
/// отрезается — в ссылках-приглашениях там ключ группы.
struct LinkPreviewCard: View {
    let url: String
    let isMine: Bool
    @Environment(Services.self) private var services
    @Environment(\.openURL) private var openURL
    @State private var preview: LinkPreviewDto?

    static func firstLink(in text: String) -> String? {
        guard let match = text.range(of: #"https?://[^\s<>]+"#, options: .regularExpression) else { return nil }
        var link = String(text[match])
        while let last = link.last, ".,:!?)*_~|".contains(last) { link.removeLast() }
        return link
    }

    var body: some View {
        Group {
            if let p = preview, !(p.title ?? "").isEmpty || !(p.description ?? "").isEmpty {
                Button { if let u = URL(string: url) { openURL(u) } } label: {
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5).fill(isMine ? Color.white : Theme.accent).frame(width: 3)
                        VStack(alignment: .leading, spacing: 3) {
                            if let host = URL(string: url)?.host {
                                Text(host).font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(isMine ? Color.white : Theme.accent)
                            }
                            if let title = p.title, !title.isEmpty {
                                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                            }
                            if let d = p.description, !d.isEmpty {
                                Text(d).font(.system(size: 13)).lineLimit(3).opacity(0.85)
                            }
                            if let image = p.image, image.hasPrefix("https://"), let imageURL = URL(string: image) {
                                AsyncImage(url: imageURL) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                                    .frame(maxWidth: 240, maxHeight: 130)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        let clean = url.components(separatedBy: "#").first ?? url
        if let cached = LinkPreviewCache.shared.object(forKey: clean as NSString) {
            preview = cached.value
            return
        }
        var value: LinkPreviewDto?
        if let fetched = try? await services.api.linkPreview(clean) { value = fetched }
        LinkPreviewCache.shared.setObject(LinkPreviewBox(value), forKey: clean as NSString)
        preview = value
    }
}
