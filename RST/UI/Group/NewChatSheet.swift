import SwiftUI

/// Новый чат: человек по нику или новая группа/канал.
struct NewChatSheet: View {
    @Environment(Services.self) private var services
    @Environment(ChatListStore.self) private var store
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var found: [ContactUserDto] = []
    @State private var searching = false
    @State private var inviteText = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { CreateGroupView(channel: false) { open($0) } } label: {
                        Label("Новая группа", systemImage: "person.2.fill")
                    }
                    NavigationLink { CreateGroupView(channel: true) { open($0) } } label: {
                        Label("Новый канал", systemImage: "megaphone.fill")
                    }
                }
                Section("Вступить по ссылке") {
                    HStack {
                        TextField("https://rst-msg.ru/join/…", text: $inviteText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Открыть") {
                            if let url = URL(string: inviteText.trimmingCharacters(in: .whitespaces)) {
                                dismiss()
                                app.open(url: url)
                            }
                        }
                        .disabled(InviteLink.parse(inviteText) == nil)
                    }
                }
                Section("Найти человека по нику") {
                    TextField("@ник", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: query) { _, value in search(value) }
                    if searching { ProgressView() }
                    ForEach(found, id: \.username) { user in
                        Button { open(user.username) } label: {
                            HStack(spacing: 12) {
                                AvatarView(name: user.displayName, url: user.avatarUrl, size: 40)
                                VStack(alignment: .leading) {
                                    HStack(spacing: 4) {
                                        Text(user.displayName).foregroundStyle(Theme.onSurface)
                                        if user.verified == true { VerifiedBadge(size: 12) }
                                    }
                                    Text("@" + user.username).font(.system(size: 13)).foregroundStyle(Theme.muted)
                                }
                            }
                        }
                    }
                }
                Section("Контакты") {
                    ForEach(store.chats.filter { !$0.isGroup && !$0.isSystem && $0.chatId != store.me }) { chat in
                        Button { open(chat.chatId) } label: {
                            HStack(spacing: 12) {
                                AvatarView(name: chat.title, url: chat.avatarUrl, size: 40, online: chat.online)
                                Text(chat.title).foregroundStyle(Theme.onSurface)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Новый чат")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
            }
        }
    }

    private func open(_ chatId: String) {
        dismiss()
        app.pendingChat = chatId
    }

    private func search(_ value: String) {
        var q = value.trimmingCharacters(in: .whitespaces)
        found = []
        guard !q.isEmpty else { return }
        if !q.hasPrefix("@") { q = "@" + q }
        guard q.count >= 2 else { return }
        searching = true
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            let current = query.trimmingCharacters(in: .whitespaces)
            guard q == (current.hasPrefix("@") ? current : "@" + current) else { return }
            defer { searching = false }
            found = ((try? await services.api.searchUsers(q).users) ?? []).filter { $0.username != store.me }
        }
    }
}

/// Создание группы или канала: название, описание, участники.
/// Ключ группы создаётся на устройстве и упаковывается каждому участнику.
struct CreateGroupView: View {
    let channel: Bool
    var onCreated: (String) -> Void

    @Environment(Services.self) private var services
    @Environment(ChatListStore.self) private var store
    @State private var name = ""
    @State private var about = ""
    @State private var selected: Set<String> = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField(channel ? "Название канала" : "Название группы", text: $name)
                TextField("Описание (необязательно)", text: $about, axis: .vertical)
            }
            Section(channel ? "Пригласить (необязательно)" : "Участники") {
                ForEach(store.chats.filter { !$0.isGroup && !$0.isSystem && !$0.isDeleted && $0.chatId != store.me }) { chat in
                    Button {
                        if selected.contains(chat.chatId) { selected.remove(chat.chatId) } else { selected.insert(chat.chatId) }
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(name: chat.title, url: chat.avatarUrl, size: 36)
                            Text(chat.title).foregroundStyle(Theme.onSurface)
                            Spacer()
                            Image(systemName: selected.contains(chat.chatId) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(chat.chatId) ? Theme.accent : Theme.muted)
                        }
                    }
                }
            }
            if let error {
                Text(error).foregroundStyle(Theme.danger)
            }
        }
        .navigationTitle(channel ? "Новый канал" : "Новая группа")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if busy {
                    ProgressView()
                } else {
                    Button("Создать", action: create)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func create() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let (chatId, skipped) = try await services.groupKeys.createGroup(
                    name: name.trimmingCharacters(in: .whitespaces),
                    description: about.isEmpty ? nil : about,
                    members: Array(selected),
                    channel: channel)
                await store.refresh()
                if skipped > 0 {
                    store.lastServerError = "Не добавлено: \(skipped) — они запретили добавлять себя в группы"
                }
                onCreated(chatId)
            } catch {
                self.error = errorText(error)
            }
        }
    }
}
