import SwiftUI

/// Профиль собеседника: статус, данные по приватности, общие группы,
/// код безопасности, блокировка, жалоба, очистка истории.
struct UserProfileView: View {
    let username: String

    @Environment(Services.self) private var services
    @Environment(ChatListStore.self) private var store
    @Environment(AppModel.self) private var app
    @State private var user: ContactUserDto?
    @State private var shared: [SharedGroupDto] = []
    @State private var blocked = false
    @State private var safetyCode: [String]?
    @State private var error: String?
    @State private var renameText = ""
    @State private var showRename = false
    @State private var showReport = false
    @State private var reportReason = ""
    @State private var confirmClear = false
    @State private var info: String?

    private var summary: ChatSummary? { store.chat(username) }
    private var name: String { user?.displayName ?? summary?.title ?? username }

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    AvatarView(name: name, url: user?.avatarUrl ?? summary?.avatarUrl, size: 110,
                               online: summary?.online ?? (user?.online ?? false))
                    HStack(spacing: 6) {
                        Text(name).font(.system(size: 24, weight: .bold))
                        if (user?.verified ?? summary?.verified) == true { VerifiedBadge(size: 18) }
                    }
                    Text(statusLine).font(.system(size: 14)).foregroundStyle(summary?.online == true ? Theme.accent : Theme.muted)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section {
                if summary?.isDeleted != true {
                    Button { app.pendingChat = username } label: { Label("Написать", systemImage: "bubble.left.fill") }
                }
                row("Имя пользователя", "@" + username)
                if let bio = user?.bio ?? summary?.bio, !bio.isEmpty { row("О себе", bio) }
                if let phone = user?.phone, !phone.isEmpty { row("Телефон", phone) }
                if let email = user?.email, !email.isEmpty { row("Почта", email) }
                if let birthday = user?.birthday, !birthday.isEmpty {
                    row("День рождения", birthday + (isBirthdayToday(birthday) ? " 🎉" : ""))
                }
                if let title = user?.musicTitle, !title.isEmpty { row("Трек в профиле", title) }
            }

            if !shared.isEmpty {
                Section("Общие группы") {
                    ForEach(shared) { group in
                        NavigationLink(value: Route.chat(group.id)) {
                            HStack(spacing: 12) {
                                AvatarView(name: group.name ?? group.id, url: group.avatarUrl, size: 34)
                                Text(group.name ?? group.id)
                            }
                        }
                    }
                }
            }

            Section("Шифрование") {
                if let code = safetyCode {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Код безопасности").font(.system(size: 13, weight: .semibold))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 6) {
                            ForEach(Array(code.enumerated()), id: \.offset) { _, group in
                                Text(group).font(.system(size: 15, design: .monospaced))
                            }
                        }
                        Text("Сверьте этот код с собеседником при встрече или по другому каналу. Совпадает — переписку никто не подменяет.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                    }
                } else {
                    Button("Показать код безопасности") { Task { await loadSafetyCode() } }
                }
            }

            Section {
                Button("Переименовать контакт") {
                    renameText = summary?.title ?? name
                    showRename = true
                }
                Button(blocked ? "Разблокировать" : "Заблокировать", role: blocked ? nil : .destructive) { toggleBlock() }
                Button("Пожаловаться", role: .destructive) { showReport = true }
                Button("Очистить историю", role: .destructive) { confirmClear = true }
            }

            if let error { Text(error).foregroundStyle(Theme.danger).listRowBackground(Color.clear) }
            if let info { Text(info).foregroundStyle(Theme.muted).listRowBackground(Color.clear) }
        }
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .navigationTitle("Профиль")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert("Имя контакта", isPresented: $showRename) {
            TextField("Имя", text: $renameText)
            Button("Сохранить") { rename() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Это имя видите только вы.")
        }
        .alert("Жалоба", isPresented: $showReport) {
            TextField("Причина", text: $reportReason)
            Button("Отправить", role: .destructive) { report() }
            Button("Отмена", role: .cancel) {}
        }
        .confirmationDialog("Очистить историю?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Только у меня", role: .destructive) { clear("me") }
            Button("У меня и у собеседника", role: .destructive) { clear("both") }
        }
    }

    private var statusLine: String {
        guard let summary else { return user?.online == true ? "в сети" : "" }
        if summary.isDeleted { return "аккаунт удалён" }
        if summary.online { return "в сети" }
        if summary.status == "dnd" { return "не беспокоить" }
        return TimeFormat.lastSeen(summary.lastSeen)
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.muted)
            Text(value).font(.system(size: 16)).textSelection(.enabled)
        }
    }

    private func isBirthdayToday(_ raw: String) -> Bool {
        let parts = raw.split(separator: "-")
        guard parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) else { return false }
        let now = Calendar.current.dateComponents([.month, .day], from: Date())
        return now.month == m && now.day == d
    }

    private func load() async {
        user = store.users[username]
        if user == nil, let found = try? await services.api.searchUsers("@" + username).users {
            user = found.first { $0.username.lowercased() == username.lowercased() }
        }
        if let response = try? await services.api.shared(services.me, with: username) {
            shared = response.sharedGroups ?? []
            blocked = response.isBlocked ?? false
        }
    }

    private func loadSafetyCode() async {
        do {
            safetyCode = try await services.userKeys.safetyCode(username)
        } catch {
            self.error = errorText(error)
        }
    }

    private func act(_ success: String? = nil, _ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
                info = success
                error = nil
            } catch {
                self.error = errorText(error)
            }
        }
    }

    private func toggleBlock() {
        let me = services.me
        let wasBlocked = blocked
        act(wasBlocked ? "Разблокирован" : "Заблокирован") {
            if wasBlocked { try await services.api.unblock(me, username) } else { try await services.api.block(me, username) }
            blocked = !wasBlocked
        }
    }

    private func rename() {
        let me = services.me
        let value = renameText.trimmingCharacters(in: .whitespaces)
        act("Имя сохранено") {
            try await services.api.renameContact(owner: me, target: username, customName: value)
            await store.refresh()
        }
    }

    private func report() {
        let me = services.me
        let reason = reportReason.trimmingCharacters(in: .whitespaces)
        act("Жалоба отправлена") {
            try await services.api.report(reporter: me, reported: username, reason: reason.isEmpty ? "Без причины" : reason)
        }
    }

    private func clear(_ mode: String) {
        let me = services.me
        act("История очищена") {
            try await services.api.clearChat(me: me, peer: username, mode: mode)
            await store.refresh()
        }
    }
}
