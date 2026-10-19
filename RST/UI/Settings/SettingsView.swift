import PhotosUI
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(Services.self) private var services
    @Environment(ChatListStore.self) private var store
    @State private var confirmLogout = false

    private var me: ContactUserDto? { store.myProfile }

    var body: some View {
        List {
            Section {
                NavigationLink { MyProfileView() } label: {
                    HStack(spacing: 14) {
                        AvatarView(name: me?.displayName ?? services.me, url: me?.avatarUrl, size: 60)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text(me?.displayName ?? services.me).font(.system(size: 19, weight: .semibold))
                                if me?.verified == true { VerifiedBadge() }
                            }
                            Text("@" + services.me).font(.system(size: 14)).foregroundStyle(Theme.muted)
                        }
                    }
                    .padding(.vertical, 4)
                }
                NavigationLink { EmojiStatusView() } label: {
                    HStack {
                        Label("Эмодзи-статус", systemImage: "face.smiling")
                        Spacer()
                        Text(store.emojiStatus(of: services.me) ?? "не задан").foregroundStyle(Theme.muted)
                    }
                }
            }

            Section {
                NavigationLink { PrivacySettingsView() } label: { Label("Конфиденциальность", systemImage: "hand.raised.fill") }
                NavigationLink { NotificationSettingsView() } label: { Label("Уведомления", systemImage: "bell.fill") }
                NavigationLink { ChatSettingsView() } label: { Label("Настройки чатов", systemImage: "paintbrush.fill") }
                NavigationLink { DataSettingsView() } label: { Label("Данные и память", systemImage: "internaldrive.fill") }
                NavigationLink { FoldersSettingsView() } label: { Label("Папки с чатами", systemImage: "folder.fill") }
            }

            Section {
                NavigationLink { SecuritySettingsView() } label: { Label("Пароль и ключ восстановления", systemImage: "key.fill") }
                NavigationLink { SessionsView() } label: { Label("Устройства", systemImage: "iphone") }
                NavigationLink { BlockedUsersView() } label: { Label("Заблокированные", systemImage: "nosign") }
            }

            Section {
                Button(role: .destructive) { confirmLogout = true } label: {
                    Label("Выйти", systemImage: "rectangle.portrait.and.arrow.right")
                }
                NavigationLink { DeleteAccountView() } label: {
                    Label("Удалить аккаунт", systemImage: "trash").foregroundStyle(Theme.danger)
                }
            }

            Section {
                Text("RST для iOS \(AppConfig.version)")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)
        }
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .navigationTitle("Настройки")
        .refreshable { await store.refresh() }
        .confirmationDialog("Выйти из аккаунта?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Выйти", role: .destructive) { app.logout() }
        } message: {
            Text("Ключи шифрования будут стёрты с этого устройства. Войти снова можно паролем.")
        }
    }
}

// MARK: - Свой профиль

struct MyProfileView: View {
    @Environment(Services.self) private var services
    @Environment(ChatListStore.self) private var store
    @State private var displayName = ""
    @State private var bio = ""
    @State private var status = "online"
    @State private var phone = ""
    @State private var email = ""
    @State private var birthday = ""
    @State private var avatarItem: PhotosPickerItem?
    @State private var busy = false
    @State private var message: String?
    @State private var loaded = false
    @State private var cropItem: CropItem?
    @State private var showAvatars = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    PhotosPicker(selection: $avatarItem, matching: .images) {
                        AvatarView(name: displayName.isEmpty ? services.me : displayName, url: store.myProfile?.avatarUrl, size: 110)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "camera.fill")
                                    .foregroundStyle(.white)
                                    .frame(width: 36, height: 36)
                                    .background(Circle().fill(Theme.accent))
                                    .overlay(Circle().stroke(Theme.background, lineWidth: 3))
                            }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .listRowBackground(Color.clear)
                if let url = store.myProfile?.avatarUrl, !url.isEmpty {
                    Button("Все фото профиля") { showAvatars = true }
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
            Section("Профиль") {
                TextField("Имя", text: $displayName)
                TextField("О себе", text: $bio, axis: .vertical)
                Picker("Статус", selection: $status) {
                    Text("В сети").tag("online")
                    Text("Не беспокоить").tag("dnd")
                    Text("Невидимка").tag("offline")
                }
            }
            Section("Контакты") {
                TextField("Телефон", text: $phone).keyboardType(.phonePad)
                TextField("Почта", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                TextField("День рождения (ГГГГ-ММ-ДД)", text: $birthday).keyboardType(.numbersAndPunctuation)
            }
            ProfileMusicSection()
            Section {
                ShareLink(item: "\(services.api.baseURL.absoluteString)/@\(services.me)") {
                    Label("Ссылка на профиль", systemImage: "link")
                }
            }
            if let message {
                Text(message).foregroundStyle(Theme.muted)
            }
        }
        .navigationTitle("Мой профиль")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if busy { ProgressView() } else { Button("Сохранить", action: save) }
            }
        }
        .onAppear(perform: fill)
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            avatarItem = nil
            Task {
                // Сначала обрезка — как в вебе
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    cropItem = CropItem(image: image)
                } else {
                    message = "Не удалось прочитать фото"
                }
            }
        }
        .sheet(item: $cropItem) { item in
            AvatarCropSheet(image: item.image) { cropped in
                Task { await uploadAvatar(cropped) }
            }
        }
        .fullScreenCover(isPresented: $showAvatars) {
            AvatarHistoryViewer(username: services.me, name: store.myProfile?.displayName ?? services.me,
                                currentUrl: store.myProfile?.avatarUrl)
        }
    }

    private func fill() {
        guard !loaded, let me = store.myProfile else { return }
        loaded = true
        displayName = me.name ?? ""
        bio = me.bio ?? ""
        status = me.status.flatMap { ["online", "dnd", "offline"].contains($0) ? $0 : nil } ?? "online"
        phone = me.phone ?? ""
        email = me.email ?? ""
        birthday = me.birthday ?? ""
    }

    private func save() {
        var request = ProfileUpdateRequest(username: services.me)
        request.displayName = displayName.trimmingCharacters(in: .whitespaces)
        request.bio = bio
        request.status = status
        request.phone = phone.trimmingCharacters(in: .whitespaces)
        request.email = email.trimmingCharacters(in: .whitespaces)
        request.birthday = birthday.trimmingCharacters(in: .whitespaces)
        busy = true
        Task {
            defer { busy = false }
            do {
                try await services.api.updateProfile(request)
                await store.refresh()
                message = "Сохранено"
            } catch {
                message = errorText(error)
            }
        }
    }

    private func uploadAvatar(_ image: UIImage) async {
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else {
            message = "Не удалось прочитать фото"
            return
        }
        busy = true
        defer { busy = false }
        do {
            // Аватары не шифруются: их видят люди без общего ключа
            let url = try await services.attachments.uploadPlain(jpeg, fileName: "avatar.jpg", mimeType: "image/jpeg")
            var request = ProfileUpdateRequest(username: services.me)
            request.avatarUrl = url
            try await services.api.updateProfile(request)
            await store.refresh()
            message = "Фото обновлено"
        } catch {
            message = errorText(error)
        }
    }
}

// MARK: - Конфиденциальность

struct PrivacySettingsView: View {
    @Environment(Services.self) private var services
    @Environment(ChatListStore.self) private var store
    @State private var error: String?

    private var me: ContactUserDto? { store.myProfile }

    var body: some View {
        Form {
            Section("Кто видит") {
                privacyPicker("Был(а) в сети", me?.lastSeenPrivacy) { $0.lastSeenPrivacy = $1 }
                privacyPicker("Телефон", me?.phonePrivacy) { $0.phonePrivacy = $1 }
                privacyPicker("Почту", me?.emailPrivacy) { $0.emailPrivacy = $1 }
                privacyPicker("День рождения", me?.birthdayPrivacy) { $0.birthdayPrivacy = $1 }
            }
            Section {
                privacyPicker("Кто может звонить", me?.callPrivacy) { $0.callPrivacy = $1 }
                privacyPicker("Кто может добавлять в группы", me?.groupInvitePrivacy) { $0.groupInvitePrivacy = $1 }
            } footer: {
                Text("«Мои контакты» — те, кому вы сами писали в личку.")
            }
            Section {
                Toggle("Отчёты о прочтении", isOn: Binding(get: { me?.readReceipts ?? true }, set: { v in update { $0.readReceipts = v } }))
                Toggle("Комментарии к историям", isOn: Binding(get: { me?.storyComments ?? true }, set: { v in update { $0.storyComments = v } }))
            } footer: {
                Text("Если выключить отчёты о прочтении, вы тоже не увидите их у других.")
            }
            Section("Автоудаление в новых чатах") {
                Picker("Таймер", selection: Binding(get: { me?.defaultTimer ?? 0 }, set: { v in update { $0.defaultTimer = v } })) {
                    Text("Выключено").tag(0)
                    Text("1 день").tag(86400)
                    Text("1 неделя").tag(604800)
                    Text("1 месяц").tag(2592000)
                }
            }
            if let error { Text(error).foregroundStyle(Theme.danger) }
        }
        .navigationTitle("Конфиденциальность")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func privacyPicker(_ title: String, _ value: String?, _ set: @escaping (inout ProfileUpdateRequest, String) -> Void) -> some View {
        Picker(title, selection: Binding(get: { value ?? "everyone" }, set: { v in update { set(&$0, v) } })) {
            Text("Все").tag("everyone")
            Text("Мои контакты").tag("contacts")
            Text("Никто").tag("nobody")
        }
    }

    private func update(_ change: (inout ProfileUpdateRequest) -> Void) {
        var request = ProfileUpdateRequest(username: services.me)
        change(&request)
        let r = request
        Task {
            do {
                try await services.api.updateProfile(r)
                await store.refresh()
                error = nil
            } catch {
                self.error = errorText(error)
            }
        }
    }
}

// MARK: - Уведомления

struct NotificationSettingsView: View {
    @Environment(Services.self) private var services
    @Environment(ChatListStore.self) private var store
    @State private var error: String?
    @State private var autoreplyText = ""

    private var me: ContactUserDto? { store.myProfile }

    var body: some View {
        Form {
            Section {
                Toggle("Личные чаты", isOn: Binding(get: { me?.notifyPrivate ?? true }, set: { v in update { $0.notifyPrivate = v } }))
                Toggle("Группы", isOn: Binding(get: { me?.notifyGroups ?? true }, set: { v in update { $0.notifyGroups = v } }))
            } footer: {
                Text("Push-уведомления на iPhone появятся с подключением Apple Push Notification service. Сейчас новые сообщения приходят, пока приложение открыто.")
            }
            Section("Тихие часы") {
                Toggle("Включены", isOn: Binding(get: { !(me?.quietHours ?? "").isEmpty }, set: { on in
                    update {
                        $0.quietHours = on ? "23:00-08:00" : ""
                        $0.timeZone = TimeZone.current.identifier
                    }
                }))
                if let q = me?.quietHours, !q.isEmpty {
                    Text("С \(q.replacingOccurrences(of: "-", with: " до "))")
                        .foregroundStyle(Theme.muted)
                }
            }
            Section {
                Toggle("Автоответ", isOn: Binding(get: { me?.autoreplyOn ?? false }, set: { on in
                    update {
                        $0.autoreplyOn = on
                        if on && (me?.autoreplyText ?? "").isEmpty {
                            $0.autoreplyText = "Сейчас не могу ответить - напишу, как освобожусь."
                        }
                    }
                }))
                TextField("Текст автоответа", text: $autoreplyText, axis: .vertical)
                Button("Сохранить текст") {
                    update { $0.autoreplyText = autoreplyText.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                .disabled(autoreplyText.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Когда вы заняты")
            } footer: {
                Text("Автоответ отправляет сервер от вашего имени, поэтому он не защищён сквозным шифрованием.")
            }
            if let error { Text(error).foregroundStyle(Theme.danger) }
        }
        .navigationTitle("Уведомления")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { autoreplyText = me?.autoreplyText ?? "" }
    }

    private func update(_ change: (inout ProfileUpdateRequest) -> Void) {
        var request = ProfileUpdateRequest(username: services.me)
        change(&request)
        let r = request
        Task {
            do {
                try await services.api.updateProfile(r)
                await store.refresh()
                error = nil
            } catch {
                self.error = errorText(error)
            }
        }
    }
}

// MARK: - Оформление

// MARK: - Папки

struct FoldersSettingsView: View {
    @Environment(Services.self) private var services
    @Environment(ChatListStore.self) private var store
    @State private var newName = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                ForEach(store.folders) { folder in
                    NavigationLink { FolderEditView(folder: folder) } label: {
                        HStack {
                            Text(folder.name)
                            Spacer()
                            Text("\(folder.targets?.count ?? 0)").foregroundStyle(Theme.muted)
                        }
                    }
                }
                .onDelete { set in
                    let ids = set.map { store.folders[$0].id }
                    Task {
                        for id in ids { try? await services.api.deleteFolder(id: id) }
                        await store.refresh()
                    }
                }
            }
            Section("Новая папка") {
                HStack {
                    TextField("Название", text: $newName)
                    Button("Создать") {
                        let name = newName.trimmingCharacters(in: .whitespaces)
                        Task {
                            do {
                                try await services.api.createFolder(username: services.me, name: name, targets: [])
                                newName = ""
                                await store.refresh()
                            } catch {
                                self.error = errorText(error)
                            }
                        }
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let error { Text(error).foregroundStyle(Theme.danger) }
        }
        .navigationTitle("Папки")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct FolderEditView: View {
    let folder: FolderDto
    @Environment(Services.self) private var services
    @Environment(ChatListStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: Set<String> = []
    @State private var error: String?

    var body: some View {
        Form {
            TextField("Название", text: $name)
            Section("Чаты") {
                ForEach(store.mainList + store.archivedList) { chat in
                    Button {
                        if selected.contains(chat.chatId) { selected.remove(chat.chatId) } else { selected.insert(chat.chatId) }
                    } label: {
                        HStack {
                            AvatarView(name: chat.title, url: chat.avatarUrl, size: 30, isSaved: chat.chatId == store.me)
                            Text(chat.title).foregroundStyle(Theme.onSurface)
                            Spacer()
                            if selected.contains(chat.chatId) { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(Theme.danger) }
        }
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Сохранить") {
                    Task {
                        do {
                            try await services.api.updateFolder(id: folder.id, username: services.me,
                                                                name: name.trimmingCharacters(in: .whitespaces), targets: Array(selected))
                            await store.refresh()
                            dismiss()
                        } catch {
                            self.error = errorText(error)
                        }
                    }
                }
            }
        }
        .onAppear {
            name = folder.name
            selected = Set(folder.targets ?? [])
        }
    }
}

// MARK: - Безопасность

struct SecuritySettingsView: View {
    @Environment(Services.self) private var services
    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var repeatPassword = ""
    @State private var recoveryPassword = ""
    @State private var recoveryEnabled: Bool?
    @State private var recoveryCode: String?
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                SecureField("Текущий пароль", text: $oldPassword).textContentType(.password)
                SecureField("Новый пароль", text: $newPassword).textContentType(.newPassword)
                SecureField("Новый пароль ещё раз", text: $repeatPassword).textContentType(.newPassword)
                Button("Сменить пароль", action: changePassword)
                    .disabled(busy || oldPassword.isEmpty || newPassword.count < 8 || newPassword != repeatPassword)
            } header: {
                Text("Смена пароля")
            } footer: {
                Text("Ключ шифрования перешифруется новым паролем на этом устройстве. Остальные устройства выйдут из аккаунта.")
            }

            Section {
                if let code = recoveryCode {
                    Text(code)
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Скопировать") { UIPasteboard.general.string = code }
                    ShareLink(item: "Ключ восстановления RST (@\(services.me)): \(code)") { Label("Сохранить", systemImage: "square.and.arrow.up") }
                    Text("Сохраните ключ в надёжном месте. Больше он нигде не показывается.")
                        .font(.system(size: 13)).foregroundStyle(Theme.accent)
                } else {
                    if let enabled = recoveryEnabled {
                        Text(enabled ? "Ключ восстановления создан" : "Ключа восстановления нет")
                            .foregroundStyle(enabled ? Theme.success : Theme.muted)
                    }
                    SecureField("Пароль для подтверждения", text: $recoveryPassword)
                    Button(recoveryEnabled == true ? "Создать новый ключ" : "Создать ключ", action: createRecovery)
                        .disabled(busy || recoveryPassword.isEmpty)
                }
            } header: {
                Text("Ключ восстановления")
            } footer: {
                Text("Если забудете пароль, по ключу можно задать новый и не потерять переписку.")
            }

            if let message { Text(message).foregroundStyle(Theme.muted) }
        }
        .navigationTitle("Безопасность")
        .navigationBarTitleDisplayMode(.inline)
        .task { recoveryEnabled = try? await services.auth.recoveryEnabled() }
    }

    private func changePassword() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await services.auth.changePassword(old: oldPassword, new: newPassword)
                services.socket.reconnect()
                oldPassword = ""
                newPassword = ""
                repeatPassword = ""
                message = "Пароль изменён"
            } catch {
                message = errorText(error)
            }
        }
    }

    private func createRecovery() {
        busy = true
        Task {
            defer { busy = false }
            do {
                recoveryCode = try await services.auth.createRecoveryKey(password: recoveryPassword)
                recoveryPassword = ""
                recoveryEnabled = true
            } catch {
                message = errorText(error)
            }
        }
    }
}

struct SessionsView: View {
    @Environment(Services.self) private var services
    @State private var sessions: [SessionDto] = []
    @State private var message: String?
    @State private var confirm = false

    var body: some View {
        List {
            Section {
                ForEach(sessions) { s in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(deviceName(s.ua)).font(.system(size: 15, weight: .medium))
                            if s.deviceId == DeviceId.value {
                                Text("это устройство").font(.system(size: 12)).foregroundStyle(Theme.accent)
                            }
                        }
                        Text(s.ip ?? "").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                }
            } footer: {
                Text("Список строится по открытым соединениям: устройства без связи в нём не видны.")
            }
            Section {
                Button("Завершить другие сеансы", role: .destructive) { confirm = true }
            }
            if let message { Text(message).foregroundStyle(Theme.muted) }
        }
        .navigationTitle("Устройства")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("Завершить все другие сеансы?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Завершить", role: .destructive) {
                Task {
                    do {
                        let closed = try await services.auth.terminateOtherSessions()
                        services.socket.reconnect()
                        message = "Завершено сеансов: \(closed)"
                        await load()
                    } catch {
                        message = errorText(error)
                    }
                }
            }
        }
    }

    private func load() async {
        sessions = (try? await services.api.sessions(services.me).sessions) ?? []
    }

    private func deviceName(_ ua: String?) -> String {
        guard let ua, !ua.isEmpty else { return "Устройство" }
        if ua.contains("iPhone") { return "iPhone" }
        if ua.contains("Android") || ua.contains("okhttp") { return "Android" }
        if ua.contains("Mac") { return "Mac" }
        if ua.contains("Windows") { return "Windows" }
        return String(ua.prefix(40))
    }
}

struct BlockedUsersView: View {
    @Environment(Services.self) private var services
    @State private var blocked: [BlockedUserDto] = []

    var body: some View {
        List {
            if blocked.isEmpty {
                Text("Никого нет").foregroundStyle(Theme.muted)
            }
            ForEach(blocked) { user in
                HStack(spacing: 12) {
                    AvatarView(name: user.name ?? user.username, url: user.avatarUrl, size: 36)
                    Text(user.name ?? user.username)
                    Spacer()
                    Button("Разблокировать") {
                        Task {
                            try? await services.api.unblock(services.me, user.username)
                            await load()
                        }
                    }
                    .font(.system(size: 14))
                }
            }
        }
        .navigationTitle("Заблокированные")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        blocked = (try? await services.api.blockedUsers().blocked) ?? []
    }
}

struct DeleteAccountView: View {
    @Environment(AppModel.self) private var app
    @Environment(Services.self) private var services
    @State private var password = ""
    @State private var confirm = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text("Аккаунт и все ваши сообщения будут удалены безвозвратно.")
                SecureField("Пароль", text: $password)
                Button("Удалить аккаунт", role: .destructive) { confirm = true }
                    .disabled(password.isEmpty)
            }
            if let error { Text(error).foregroundStyle(Theme.danger) }
        }
        .navigationTitle("Удаление аккаунта")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Удалить аккаунт навсегда?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                Task {
                    do {
                        try await services.api.deleteAccount(password: password)
                        app.logout()
                    } catch {
                        self.error = errorText(error)
                    }
                }
            }
        }
    }
}
