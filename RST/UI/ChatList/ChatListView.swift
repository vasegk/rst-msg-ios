import SwiftUI

struct ChatListView: View {
    let archived: Bool

    @Environment(Services.self) private var services
    @Environment(ChatListStore.self) private var store
    @State private var query = ""
    @State private var folderId: Int64?
    @State private var foundUsers: [ContactUserDto] = []
    @State private var foundGroups: [PublicGroupDto] = []
    @State private var searching = false
    @State private var showNewChat = false
    @State private var actionError: String?
    @State private var joinGroup: PublicGroupDto?

    private var source: [ChatSummary] { archived ? store.archivedList : store.mainList }

    private var visible: [ChatSummary] {
        var list = source
        if !archived, let folderId, let folder = store.folders.first(where: { $0.id == folderId }) {
            let targets = Set(folder.targets ?? [])
            list = store.chats.filter { targets.contains($0.chatId) }
                .sorted { a, b in a.pinned != b.pinned ? a.pinned : a.activity > b.activity }
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return list }
        let needle = q.hasPrefix("@") ? String(q.dropFirst()) : q
        return (archived ? list : store.chats).filter {
            $0.title.lowercased().contains(needle) || $0.chatId.lowercased().contains(needle)
        }
    }

    var body: some View {
        List {
            if !archived && query.isEmpty && !store.folders.isEmpty {
                folderChips
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if let until = store.blockedUntil, !archived {
                Text("Аккаунт ограничен модератором до \(until). Отправка сообщений недоступна.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.onSurface)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.danger.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if !archived && query.isEmpty && folderId == nil && !store.archivedList.isEmpty {
                NavigationLink(value: Route.archive) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Theme.input).frame(width: 46, height: 46)
                            Image(systemName: "archivebox.fill").foregroundStyle(Theme.muted)
                        }
                        Text("Архив").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        let unread = store.archivedList.reduce(0) { $0 + $1.unread }
                        if unread > 0 { UnreadBadge(count: unread, muted: true) }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            ForEach(visible) { chat in
                NavigationLink(value: Route.chat(chat.chatId)) {
                    ChatRow(chat: chat)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    let unread = chat.unread > 0 || chat.markedUnread
                    Button { prefs(chat, markedUnread: !unread) } label: {
                        Label(unread ? "Прочитано" : "Непрочитано", systemImage: unread ? "envelope.open" : "envelope.badge")
                    }
                    .tint(.blue)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !chat.isSystem {
                        Button { prefs(chat, archived: !chat.archived) } label: {
                            Label(chat.archived ? "Вернуть" : "Архив", systemImage: "archivebox")
                        }
                        .tint(.gray)
                    }
                    Button { prefs(chat, muteFor: chat.muted ? 0 : -1) } label: {
                        Label(chat.muted ? "Звук" : "Без звука", systemImage: chat.muted ? "bell" : "bell.slash")
                    }
                    .tint(.indigo)
                    Button { prefs(chat, pinned: !chat.pinned) } label: {
                        Label(chat.pinned ? "Открепить" : "Закрепить", systemImage: chat.pinned ? "pin.slash" : "pin")
                    }
                    .tint(Theme.accent)
                }
                .contextMenu { chatMenu(chat) }
            }

            if !query.isEmpty { searchResults }

            if visible.isEmpty && query.isEmpty && !store.loading {
                emptyState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .safeAreaInset(edge: .top, spacing: 0) { ConnectionBanner() }
        .navigationTitle(archived ? "Архив" : "Чаты")
        .navigationBarTitleDisplayMode(archived ? .inline : .large)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Поиск или @ник")
        .onChange(of: query) { _, value in search(value) }
        .refreshable { await store.refresh() }
        .toolbar {
            if !archived {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNewChat = true } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("Новый чат")
                }
            }
        }
        .sheet(isPresented: $showNewChat) { NewChatSheet() }
        .overlay {
            if store.loading && store.chats.isEmpty { ProgressView().tint(Theme.accent) }
            if let error = store.loadError, store.chats.isEmpty {
                VStack(spacing: 12) {
                    Text(error).foregroundStyle(Theme.muted)
                    Button("Повторить") { Task { await store.refresh() } }
                }
            }
        }
        .alert("Не получилось", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
        .confirmationDialog("Вступить в группу «\(joinGroup?.name ?? "")»?", isPresented: Binding(
            get: { joinGroup != nil }, set: { if !$0 { joinGroup = nil } }), titleVisibility: .visible) {
            Button("Вступить") { if let g = joinGroup { join(g) } }
        } message: {
            Text("Ключ шифрования передаст кто-то из участников, когда будет в сети.")
        }
    }

    // MARK: - Части

    private var folderChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "Все", selected: folderId == nil) { folderId = nil }
                ForEach(store.folders) { folder in
                    chip(title: folder.name, selected: folderId == folder.id) { folderId = folder.id }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func chip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundStyle(selected ? .white : Theme.onSurface)
                .background(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.input), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var searchResults: some View {
        let known = Set(store.chats.map(\.chatId))
        let people = foundUsers.filter { !known.contains($0.username) }
        let groups = foundGroups.filter { !known.contains($0.id) }
        if !people.isEmpty {
            Section("Люди") {
                ForEach(people, id: \.username) { user in
                    NavigationLink(value: Route.chat(user.username)) {
                        HStack(spacing: 12) {
                            AvatarView(name: user.displayName, url: user.avatarUrl, size: 42)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(user.displayName).font(.system(size: 15, weight: .semibold))
                                    if user.verified == true { VerifiedBadge() }
                                }
                                Text("@" + user.username).font(.system(size: 13)).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }
        }
        if !groups.isEmpty {
            Section("Публичные группы") {
                ForEach(groups) { group in
                    Button { joinGroup = group } label: {
                        HStack(spacing: 12) {
                            AvatarView(name: group.name ?? group.id, url: group.avatarUrl, size: 42)
                            Text(group.name ?? group.id).font(.system(size: 15, weight: .semibold))
                            Spacer()
                            Text(group.kind == "channel" ? "канал" : "группа").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
            }
        }
        if searching {
            HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
        } else if visible.isEmpty && people.isEmpty && groups.isEmpty {
            Text(query.hasPrefix("@") ? "Никого не нашлось" : "Ничего не нашлось. Незнакомых людей ищите по нику: @ник")
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
                .listRowBackground(Color.clear)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(Theme.muted)
            Text(archived ? "В архиве пусто" : "Чатов пока нет")
                .font(.system(size: 17, weight: .semibold))
            if !archived {
                Text("Найдите собеседника по нику через поиск: @ник")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    @ViewBuilder
    private func chatMenu(_ chat: ChatSummary) -> some View {
        Button { prefs(chat, pinned: !chat.pinned) } label: {
            Label(chat.pinned ? "Открепить" : "Закрепить", systemImage: chat.pinned ? "pin.slash" : "pin")
        }
        if chat.muted {
            Button { prefs(chat, muteFor: 0) } label: { Label("Включить уведомления", systemImage: "bell") }
        } else {
            Menu {
                Button("На 1 час") { prefs(chat, muteFor: 3600) }
                Button("На 8 часов") { prefs(chat, muteFor: 8 * 3600) }
                Button("На 2 дня") { prefs(chat, muteFor: 2 * 86400) }
                Button("Навсегда") { prefs(chat, muteFor: -1) }
            } label: { Label("Отключить уведомления", systemImage: "bell.slash") }
        }
        let unread = chat.unread > 0 || chat.markedUnread
        Button { prefs(chat, markedUnread: !unread) } label: {
            Label(unread ? "Отметить прочитанным" : "Отметить непрочитанным", systemImage: unread ? "envelope.open" : "envelope.badge")
        }
        if !chat.isSystem {
            Button { prefs(chat, archived: !chat.archived) } label: {
                Label(chat.archived ? "Вернуть из архива" : "В архив", systemImage: "archivebox")
            }
        }
    }

    // MARK: - Действия

    private func prefs(_ chat: ChatSummary, muteFor: Int? = nil, pinned: Bool? = nil, archived: Bool? = nil, markedUnread: Bool? = nil) {
        Task {
            do {
                if markedUnread == false && chat.unread > 0 && !chat.markedUnread {
                    // «Прочитано» без открытия: отметки по последним сообщениям
                    await markRead(chat)
                    return
                }
                try await store.setPrefs(ChatPrefsRequest(chatId: chat.chatId, muteFor: muteFor, pinned: pinned,
                                                          archived: archived, markedUnread: markedUnread))
                if markedUnread == false { await markRead(chat) }
            } catch {
                actionError = errorText(error)
            }
        }
    }

    private func markRead(_ chat: ChatSummary) async {
        guard let recent = try? await services.api.messages(me: services.me, peer: chat.chatId, limit: 50).messages else { return }
        if chat.isGroup {
            if let last = recent.map(\.id).max() { services.socket.sendRead(messageId: last, sender: chat.chatId) }
        } else {
            for m in recent where m.sender != services.me && m.status != "read" {
                services.socket.sendRead(messageId: m.id, sender: m.sender)
            }
        }
        store.update(chat.chatId) { $0.unread = 0 }
    }

    private func search(_ value: String) {
        let q = value.trimmingCharacters(in: .whitespaces)
        foundUsers = []
        foundGroups = []
        guard q.count >= 2 else { return }
        searching = true
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard q == query.trimmingCharacters(in: .whitespaces) else { return }
            defer { searching = false }
            // С 2026-10-02 сервер ищет людей только по «@ник»
            if q.hasPrefix("@"), q.count >= 2 {
                foundUsers = (try? await services.api.searchUsers(q).users) ?? []
            } else {
                foundGroups = (try? await services.api.searchGroups(q).groups) ?? []
            }
        }
    }

    private func join(_ group: PublicGroupDto) {
        Task {
            do {
                try await services.groupKeys.joinPublic(chatId: group.id)
                await store.refresh()
                query = ""
            } catch {
                actionError = errorText(error)
            }
        }
    }
}

struct UnreadBadge: View {
    let count: Int
    var muted = false
    var body: some View {
        Text(count > 999 ? "999+" : "\(count)")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .frame(minWidth: 22, minHeight: 22)
            .background(muted ? Theme.muted : Theme.accent, in: Capsule())
    }
}

/// Строка списка чатов.
struct ChatRow: View {
    let chat: ChatSummary
    @Environment(ChatListStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: chat.title, url: chat.avatarUrl, size: 52,
                       online: !chat.isGroup && chat.online && chat.chatId != store.me,
                       isSaved: chat.chatId == store.me)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if chat.isGroup {
                        Image(systemName: chat.isChannel ? "megaphone.fill" : "person.2.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                    }
                    Text(chat.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.onSurface)
                        .lineLimit(1)
                    if chat.verified { VerifiedBadge(size: 13) }
                    // Эмодзи-статус; у «Избранного» свой не показываем
                    if chat.chatId != store.me, let emoji = chat.activeEmojiStatus { Text(emoji).font(.system(size: 14)) }
                    if chat.unreadReactions > 0 {
                        Image(systemName: "heart.fill").font(.system(size: 11)).foregroundStyle(Theme.danger)
                    }
                    if chat.muted {
                        Image(systemName: "speaker.slash.fill").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 4)
                    if let last = chat.lastMsg, last.sender == store.me {
                        Checkmarks(read: last.status == "read")
                    }
                    Text(TimeFormat.listTime(ServerTime.parse(chat.lastMsg?.time)))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
                HStack(alignment: .top, spacing: 6) {
                    subtitle
                        .font(.system(size: 14))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if chat.pinned && chat.unread == 0 && !chat.markedUnread {
                        Image(systemName: "pin.fill").font(.system(size: 12)).foregroundStyle(Theme.muted).rotationEffect(.degrees(45))
                    }
                    if chat.unread > 0 {
                        UnreadBadge(count: chat.unread, muted: chat.muted)
                    } else if chat.markedUnread {
                        Circle().fill(chat.muted ? Theme.muted : Theme.accent).frame(width: 20, height: 20)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var subtitle: some View {
        if let typing = store.typingText(chat.chatId, isGroup: chat.isGroup) {
            Text(typing).foregroundStyle(Theme.accent)
        } else if chat.isDeleted {
            Text("Аккаунт удалён").foregroundStyle(Theme.muted)
        } else if let last = chat.lastMsg {
            let preview = store.previews[chat.chatId] ?? ""
            if chat.isGroup, let sender = last.sender, sender != "system", !chat.isChannel, last.fileType != "system" {
                (Text(store.displayName(sender) + ": ").foregroundColor(Theme.onSurface) + Text(preview).foregroundColor(Theme.muted))
            } else {
                Text(preview).foregroundStyle(Theme.muted)
            }
        } else {
            Text(chat.isGroup ? "Сообщений пока нет" : (chat.bio ?? "")).foregroundStyle(Theme.muted)
        }
    }
}

/// Галочки своего сообщения: одна — доставлено, две — прочитано.
struct Checkmarks: View {
    let read: Bool
    var color: Color = Theme.accent
    var body: some View {
        ZStack(alignment: .leading) {
            Image(systemName: "checkmark")
            if read { Image(systemName: "checkmark").offset(x: 5) }
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(read ? color : color.opacity(0.7))
        .padding(.trailing, read ? 5 : 0)
        .accessibilityLabel(read ? "Прочитано" : "Отправлено")
    }
}
