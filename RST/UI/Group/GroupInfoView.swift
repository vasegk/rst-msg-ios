import PhotosUI
import SwiftUI

/// Карточка группы: описание, ссылка-приглашение, участники и роли, настройки.
struct GroupInfoView: View {
    let chatId: String

    @Environment(Services.self) private var services
    @Environment(ChatListStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var info: GroupInfoResponse?
    @State private var keys: ChatKeys?
    @State private var error: String?
    @State private var showAdd = false
    @State private var confirmLeave = false
    @State private var confirmDelete = false
    @State private var editing = false
    @State private var avatarItem: PhotosPickerItem?
    @State private var busy = false

    private var me: String { store.me }
    private var myRole: String { info?.members?.first { $0.username == me }?.role ?? store.chat(chatId)?.myRole ?? "member" }
    private var isAdmin: Bool { ["owner", "admin"].contains(myRole) }
    private var isOwner: Bool { myRole == "owner" }

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    AvatarView(name: info?.name ?? store.title(for: chatId), url: info?.avatarUrl ?? store.chat(chatId)?.avatarUrl, size: 96)
                        .overlay(alignment: .bottomTrailing) {
                            if isAdmin {
                                PhotosPicker(selection: $avatarItem, matching: .images) {
                                    Image(systemName: "camera.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.white)
                                        .frame(width: 32, height: 32)
                                        .background(Circle().fill(Theme.accent))
                                }
                            }
                        }
                    Text(info?.name ?? store.title(for: chatId))
                        .font(.system(size: 22, weight: .bold))
                    Text(info?.isChannel == true ? "канал · \(info?.subscribers ?? info?.members?.count ?? 0) подписч." :
                            "\(info?.members?.count ?? 0) \(Plural.members(info?.members?.count ?? 0))")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            if let description = info?.description, !description.isEmpty {
                Section("Описание") { Text(description) }
            }

            Section("Шифрование") {
                switch keys?.groupState {
                case .secure?:
                    Label("Сквозное шифрование включено", systemImage: "lock.fill").foregroundStyle(Theme.success)
                case .pending?:
                    Label("Ключ группы ещё не пришёл на это устройство", systemImage: "key.fill").foregroundStyle(Theme.accent)
                case .insecure?:
                    Label("Без сквозного шифрования: ключ выводится из номера группы", systemImage: "lock.open.fill").foregroundStyle(Theme.danger)
                    if isAdmin {
                        Button("Включить шифрование") { enableEncryption() }
                    }
                case nil:
                    ProgressView()
                }
            }

            if let hash = info?.inviteHash, !hash.isEmpty {
                Section("Приглашение") {
                    let link = services.groupKeys.inviteLink(base: services.api.baseURL, inviteHash: hash, keys: keys)
                    ShareLink(item: link) { Label("Поделиться ссылкой", systemImage: "square.and.arrow.up") }
                    Button { UIPasteboard.general.string = link } label: { Label("Скопировать ссылку", systemImage: "link") }
                    if keys?.realGroupKey == nil {
                        Text("В ссылке нет ключа: вступившим его передаст кто-то из участников.")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    if let alias = info?.alias, !alias.isEmpty {
                        Text("Короткий адрес: \(services.api.baseURL.host ?? "")/\(alias)").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    }
                }
            }

            if isAdmin { settingsSection }

            Section(info?.isChannel == true ? "Подписчики" : "Участники") {
                if isAdmin || myRole == "editor" {
                    Button { showAdd = true } label: { Label("Добавить участников", systemImage: "person.badge.plus") }
                }
                ForEach(sortedMembers) { member in
                    if member.username == me {
                        memberRow(member)
                    } else {
                        NavigationLink(value: Route.userProfile(member.username)) { memberRow(member) }
                    }
                }
            }

            Section {
                Button(role: .destructive) { confirmLeave = true } label: {
                    Label(info?.isChannel == true ? "Покинуть канал" : "Покинуть группу", systemImage: "rectangle.portrait.and.arrow.right")
                }
                if isOwner {
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Удалить для всех", systemImage: "trash") }
                }
            }

            if let error {
                Text(error).foregroundStyle(Theme.danger).listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .navigationTitle("Информация")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isAdmin {
                ToolbarItem(placement: .topBarTrailing) { Button("Изменить") { editing = true } }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showAdd) {
            AddMembersSheet(existing: Set(info?.members?.map(\.username) ?? [])) { picked in
                Task { await add(picked) }
            }
        }
        .sheet(isPresented: $editing) {
            EditGroupSheet(chatId: chatId, name: info?.name ?? "", description: info?.description ?? "") {
                Task { await load(); await store.refresh() }
            }
        }
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            avatarItem = nil
            Task { await uploadAvatar(item) }
        }
        .confirmationDialog("Покинуть?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Покинуть", role: .destructive) { leave() }
        } message: {
            Text(isOwner ? "Вы владелец. Если уйти, права перейдут другому участнику." : "Вернуться можно будет только по приглашению.")
        }
        .confirmationDialog("Удалить группу для всех?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { deleteGroup() }
        }
    }

    private var sortedMembers: [GroupMemberDto] {
        let order = ["owner": 0, "admin": 1, "editor": 2, "helper": 3, "member": 4]
        return (info?.members ?? []).sorted {
            let a = order[$0.role ?? "member"] ?? 5, b = order[$1.role ?? "member"] ?? 5
            return a != b ? a < b : $0.shownName.localizedCaseInsensitiveCompare($1.shownName) == .orderedAscending
        }
    }

    @ViewBuilder
    private var settingsSection: some View {
        Section("Настройки") {
            Toggle("Публичная группа", isOn: Binding(get: { info?.isPublic ?? false }, set: { v in
                applySettings { $0.isPublic = v }
            }))
            if info?.isChannel != true {
                Toggle("Пишут только администраторы", isOn: Binding(get: { info?.adminsOnly ?? false }, set: { v in
                    applySettings { $0.adminsOnly = v }
                }))
                Picker("Медленный режим", selection: Binding(get: { info?.slowMode ?? 0 }, set: { v in
                    applySettings { $0.slowMode = v }
                })) {
                    Text("Выключен").tag(0)
                    Text("10 с").tag(10)
                    Text("30 с").tag(30)
                    Text("1 мин").tag(60)
                    Text("5 мин").tag(300)
                    Text("15 мин").tag(900)
                    Text("1 час").tag(3600)
                }
            }
            Button("Новая ссылка-приглашение") { applySettings { $0.regenerateInvite = true } }
        }
    }

    private func memberRow(_ member: GroupMemberDto) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: member.shownName, url: member.avatarUrl, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(member.username == me ? "Вы" : store.users[member.username]?.displayName ?? member.shownName)
                        .font(.system(size: 15, weight: .medium))
                    if member.verified == true { VerifiedBadge(size: 12) }
                    if let title = member.title, !title.isEmpty {
                        Text(title).font(.system(size: 12)).foregroundStyle(Theme.accent)
                    }
                }
                Text("@" + member.username + (member.hasKey == false ? " · ждёт ключ" : ""))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            if let role = member.role, role != "member" {
                Text(roleName(role)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
            }
        }
        .contextMenu {
            if isAdmin && member.username != me && member.role != "owner" && (isOwner || member.role != "admin") {
                Menu {
                    ForEach(["admin", "editor", "helper", "member"], id: \.self) { role in
                        Button(roleName(role)) { act { try await services.api.promote(groupId: chatId, username: member.username, role: role) } }
                    }
                } label: { Label("Роль", systemImage: "star") }
                Button(role: .destructive) { act { try await services.api.kick(groupId: chatId, username: member.username) } } label: {
                    Label("Исключить", systemImage: "person.badge.minus")
                }
                Button(role: .destructive) { act { try await services.api.ban(groupId: chatId, username: member.username) } } label: {
                    Label("Заблокировать", systemImage: "nosign")
                }
            }
        }
    }

    private func roleName(_ role: String) -> String {
        switch role {
        case "owner": return "владелец"
        case "admin": return "админ"
        case "editor": return "редактор"
        case "helper": return "помощник"
        default: return "участник"
        }
    }

    // MARK: - Действия

    private func load() async {
        do {
            info = try await services.api.groupInfo(chatId)
            keys = try await services.messages.keys(for: chatId)
            error = nil
        } catch {
            self.error = errorText(error)
        }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
                await load()
            } catch {
                self.error = errorText(error)
            }
        }
    }

    private func applySettings(_ change: (inout GroupSettingsRequest) -> Void) {
        var request = GroupSettingsRequest(groupId: chatId)
        change(&request)
        let r = request
        act { try await services.api.groupSettings(r) }
    }

    private func add(_ usernames: [String]) async {
        guard !usernames.isEmpty else { return }
        do {
            let keys = try await services.messages.keys(for: chatId)
            let groupId = String(chatId.dropFirst(GroupKeyRepository.prefix.count))
            let skipped = try await services.groupKeys.addMembers(groupId: groupId, keys: keys, members: usernames)
            if skipped > 0 { error = "Не добавлено: \(skipped) — они запретили добавлять себя в группы" }
            await load()
        } catch {
            self.error = errorText(error)
        }
    }

    private func enableEncryption() {
        Task {
            do {
                let failed = try await services.groupKeys.enableEncryption(groupId: String(chatId.dropFirst(GroupKeyRepository.prefix.count)))
                services.messages.invalidateKeys(chatId)
                await load()
                if failed > 0 { error = "Ключ не удалось передать \(failed) участникам — им передаст кто-то из группы позже." }
            } catch {
                self.error = errorText(error)
            }
        }
    }

    private func uploadAvatar(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let jpeg = AttachmentRepository.compressImage(data, maxSide: 640, quality: 0.85) else { return }
        do {
            let url = try await services.attachments.uploadPlain(jpeg, fileName: "avatar.jpg", mimeType: "image/jpeg")
            var request = GroupUpdateRequest(groupId: chatId)
            request.avatarUrl = url
            try await services.api.updateGroup(request)
            await load()
            await store.refresh()
        } catch {
            self.error = errorText(error)
        }
    }

    private func leave() {
        Task {
            do {
                try await services.api.leaveGroup(chatId)
                store.remove(chatId)
                dismiss()
            } catch {
                self.error = errorText(error)
            }
        }
    }

    private func deleteGroup() {
        Task {
            do {
                try await services.api.deleteGroup(chatId)
                store.remove(chatId)
                dismiss()
            } catch {
                self.error = errorText(error)
            }
        }
    }
}

private struct AddMembersSheet: View {
    let existing: Set<String>
    var onDone: ([String]) -> Void
    @Environment(ChatListStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []

    var body: some View {
        NavigationStack {
            List(store.chats.filter { !$0.isGroup && !$0.isSystem && !$0.isDeleted && $0.chatId != store.me && !existing.contains($0.chatId) }) { chat in
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
            .navigationTitle("Добавить")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить") {
                        onDone(Array(selected))
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }
}

private struct EditGroupSheet: View {
    let chatId: String
    @State var name: String
    @State var description: String
    var onSaved: () -> Void
    @Environment(Services.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Название", text: $name)
                TextField("Описание", text: $description, axis: .vertical)
                if let error { Text(error).foregroundStyle(Theme.danger) }
            }
            .navigationTitle("Группа")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        Task {
                            do {
                                var request = GroupUpdateRequest(groupId: chatId)
                                request.name = name.trimmingCharacters(in: .whitespaces)
                                request.description = description
                                try await services.api.updateGroup(request)
                                onSaved()
                                dismiss()
                            } catch {
                                self.error = errorText(error)
                            }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
