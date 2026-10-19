import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Строка ввода: ответ/правка над полем, вложения, голосовое, отправка.
struct ComposerView: View {
    @Bindable var model: ChatViewModel
    @Environment(ChatListStore.self) private var store

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showPoll = false
    @State private var rec = RecordingController()
    /// Выбрано одно фото/видео — спросить: обычное, под спойлером, одноразовое.
    @State private var singleVisual: ChatViewModel.OutgoingFile?
    @State private var showSchedule = false
    @State private var showContactPicker = false
    @State private var showLocation = false
    @State private var showStickers = false
    @Environment(Services.self) private var services
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let reply = model.replyTo { contextBar(title: "Ответ: \(store.displayName(reply.sender))", text: Previews.describe(reply), icon: "arrowshape.turn.up.left.fill") }
            if let edit = model.editing { contextBar(title: "Изменение", text: Previews.describe(edit), icon: "pencil") }
            if let cross = store.crossReplyDraft[model.chatId] {
                // Ответ на сообщение из другого чата: цитату понесёт первое сообщение
                HStack(spacing: 10) {
                    Image(systemName: "arrowshape.turn.up.left.2.fill").foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(cross.author) · \(cross.chatName.isEmpty ? "из другого чата" : cross.chatName)")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                        Text(Previews.oneLine(TextFormat.strip(cross.text))).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer()
                    Button { store.crossReplyDraft[model.chatId] = nil } label: { Image(systemName: "xmark").foregroundStyle(Theme.muted) }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Theme.surface.opacity(0.95))
            }

            if let token = mentionToken {
                let suggestions = model.mentionSuggestions(for: token)
                if !suggestions.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(suggestions) { s in
                                Button { insertMention(s.username) } label: {
                                    HStack(spacing: 10) {
                                        AvatarView(name: s.title, url: store.users[s.username]?.avatarUrl, size: 30)
                                        Text(s.title).foregroundStyle(Theme.onSurface)
                                        if !Mentions.special.contains(s.username) {
                                            Text("@" + s.username).font(.system(size: 13)).foregroundStyle(Theme.muted)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                    .background(Theme.surface.opacity(0.97))
                }
            }

            if !model.canWrite {
                Text(blockedText)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.surface.opacity(0.95))
            } else {
                if rec.circle.isRecording { CircleRecordingPreview(circle: rec.circle) }
                if rec.locked && rec.isRecording {
                    recordingBar
                } else {
                    inputBar
                }
            }
        }
        .onAppear {
            rec.onError = { model.toast = $0 }
            rec.onFinish = { mode, url, duration in
                Task {
                    if mode == .circle {
                        await model.sendVideoNote(url: url, duration: duration)
                    } else {
                        await model.sendVoice(url: url, duration: duration)
                    }
                }
            }
        }
        .onDisappear { if rec.isRecording { rec.cancel() } }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await sendPhotos(items) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await sendFiles(urls) } }
        }
        .sheet(isPresented: $showPoll) { PollComposer(model: model) }
        .sheet(isPresented: $showStickers) { StickerPanelSheet { model.sendSticker($0) } }
        .sheet(isPresented: $showSchedule) {
            TimePickerSheet(title: "Отправить позже") { date in model.scheduleCurrent(at: date) }
        }
        .confirmationDialog("Местоположение", isPresented: $showLocation, titleVisibility: .visible) {
            Button("Отправить текущее место") { shareLocation(duration: 0) }
            Button("Делиться 15 минут") { shareLocation(duration: 15 * 60) }
            Button("Делиться 1 час") { shareLocation(duration: 3600) }
            Button("Делиться 8 часов") { shareLocation(duration: 8 * 3600) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Трансляция идёт, пока приложение открыто.")
        }
        .sheet(isPresented: $showContactPicker) {
            ChatPickerSheet(title: "Контакт", peopleOnly: true) { chat in
                model.shareContact(ContactRef(username: chat.chatId, name: chat.title))
            }
        }
        .confirmationDialog("Отправить", isPresented: Binding(
            get: { singleVisual != nil }, set: { if !$0 { singleVisual = nil } }), titleVisibility: .hidden) {
            Button("Отправить") { sendSingle() }
            Button("Скрыть под спойлер") { sendSingle(spoiler: true) }
            // Одноразовое — только в личке и не себе
            if !model.isGroup && !model.isSaved {
                Button("Одноразовое: откроют один раз") { sendSingle(viewOnce: true) }
            }
            Button("Отмена", role: .cancel) { singleVisual = nil }
        }
    }

    /// Последнее слово в поле, если это начатое «@…» (в группе).
    private var mentionToken: String? {
        guard model.isGroup, let last = model.text.split(separator: " ", omittingEmptySubsequences: false).last,
              last.hasPrefix("@"), !last.contains("\n") else { return nil }
        return String(last.dropFirst())
    }

    private func insertMention(_ username: String) {
        var parts = model.text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return }
        parts[parts.count - 1] = "@" + username
        model.updateText(parts.joined(separator: " ") + " ")
    }

    /// 0 — одна точка; иначе трансляция на столько секунд.
    private func shareLocation(duration: TimeInterval) {
        let chatId = model.chatId
        Task {
            do {
                if duration == 0 {
                    try await LiveLocationSharing.shared.sendCurrent(chatId: chatId, services: services)
                } else {
                    try await LiveLocationSharing.shared.start(chatId: chatId, duration: duration, services: services)
                }
            } catch {
                model.toast = errorText(error)
            }
        }
    }

    private func sendSingle(spoiler: Bool = false, viewOnce: Bool = false) {
        guard let file = singleVisual else { return }
        singleVisual = nil
        Task { await sendWithCaption([file], spoiler: spoiler, viewOnce: viewOnce) }
    }

    private var blockedText: String {
        if store.blockedUntil != nil { return "Отправка ограничена модератором" }
        if let s = store.chat(model.chatId) {
            if s.isSystem { return "Писать в этот чат нельзя" }
            if s.isDeleted { return "Аккаунт удалён" }
            if s.isChannel { return "Писать в канал могут только авторы" }
            if s.adminsOnly { return "Писать могут только администраторы" }
        }
        return "Писать сюда нельзя"
    }

    private func contextBar(title: String, text: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.accent)
            RoundedRectangle(cornerRadius: 1.5).fill(Theme.accent).frame(width: 3, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                Text(text).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
            Button { model.cancelCompose() } label: {
                Image(systemName: "xmark").foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.surface.opacity(0.95))
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if rec.holding {
                RecordingHoldIndicator(rec: rec)
            } else {
                inputFields
            }
            actionButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var inputFields: some View {
        Menu {
            Button { showPhotos = true } label: { Label("Фото или видео", systemImage: "photo.on.rectangle") }
            Button { showFiles = true } label: { Label("Файл", systemImage: "doc") }
            Button { showContactPicker = true } label: { Label("Контакт", systemImage: "person.crop.circle") }
            Button { showLocation = true } label: { Label("Местоположение", systemImage: "location") }
            if model.isGroup || !model.isSaved {
                Button { showPoll = true } label: { Label("Опрос", systemImage: "chart.bar.xaxis") }
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 22))
                .foregroundStyle(Theme.muted)
                .frame(width: 40, height: 44)
        }
        .disabled(model.editing != nil)

        TextField("Сообщение", text: Binding(get: { model.text }, set: { model.updateText($0) }), axis: .vertical)
            .lineLimit(1...7)
            .focused($focused)
            .font(.system(size: 16))
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
            .background(Theme.input, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(focused ? Theme.accent.opacity(0.7) : Theme.outline))

        if model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.editing == nil {
            Button { showStickers = true } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 21))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 34, height: 44)
            }
        }
    }

    /// Справа: запись (голосовое или кружок) или «Отправить».
    @ViewBuilder
    private var actionButton: some View {
        if rec.holding || (model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.editing == nil) {
            RecordButton(rec: rec)
                .disabled(model.sending)
        } else {
            Button { model.send() } label: {
                ZStack {
                    Circle().fill(Theme.accent).frame(width: 44, height: 44)
                        .shadow(color: Theme.accent.opacity(0.3), radius: 4, y: 2)
                    if model.sending {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: model.editing != nil ? "checkmark" : "arrow.up")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .disabled(model.sending)
            // Удержание «Отправить» — отложить или «когда будет в сети»
            .contextMenu {
                if model.editing == nil {
                    Button { showSchedule = true } label: { Label("Отправить позже", systemImage: "clock") }
                    if model.canSendWhenOnline {
                        Button { model.sendWhenOnline() } label: { Label("Когда будет в сети", systemImage: "person.badge.clock") }
                    }
                }
            }
        }
    }

    private var recordingBar: some View {
        HStack(spacing: 14) {
            Button { rec.cancel() } label: {
                Image(systemName: "trash").font(.system(size: 20)).foregroundStyle(Theme.danger).frame(width: 44, height: 44)
            }
            Circle().fill(Theme.danger).frame(width: 10, height: 10).opacity(rec.voice.blink || rec.circle.blink ? 1 : 0.3)
            Text(rec.elapsedText).font(.system(size: 16, weight: .medium).monospacedDigit())
            if rec.activeMode == .voice {
                LevelBars(levels: rec.voice.levels).frame(height: 22)
            }
            Spacer()
            Button { rec.finish() } label: {
                ZStack {
                    Circle().fill(Theme.accent).frame(width: 44, height: 44)
                    Image(systemName: "arrow.up").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    // MARK: - Действия

    private func sendPhotos(_ items: [PhotosPickerItem]) async {
        var files: [ChatViewModel.OutgoingFile] = []
        for item in items {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                model.toast = "Не удалось прочитать файл"
                continue
            }
            if isVideo {
                let type = item.supportedContentTypes.first { $0.conforms(to: .movie) }
                let ext = type?.preferredFilenameExtension ?? "mp4"
                let mime = type?.preferredMIMEType ?? "video/mp4"
                files.append(.init(data: data, fileName: "video.\(ext)", mimeType: mime))
            } else {
                let type = item.supportedContentTypes.first { $0.conforms(to: .image) }
                let mime = type?.preferredMIMEType ?? "image/jpeg"
                let ext = type?.preferredFilenameExtension ?? "jpg"
                files.append(.init(data: data, fileName: "photo.\(ext)", mimeType: mime))
            }
        }
        guard !files.isEmpty else { return }
        // Одно фото/видео — можно под спойлер или одноразовым (в личке)
        if files.count == 1 {
            singleVisual = files[0]
            return
        }
        await sendWithCaption(files)
    }

    private func sendFiles(_ urls: [URL]) async {
        var files: [ChatViewModel.OutgoingFile] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                model.toast = "Не удалось прочитать \(url.lastPathComponent)"
                continue
            }
            let mime = AttachmentRepository.mimeType(forExtension: url.pathExtension)
            // Файл, выбранный как документ, не пережимаем — даже если это картинка
            files.append(.init(data: data, fileName: url.lastPathComponent, mimeType: mime, compress: false))
        }
        await sendWithCaption(files)
    }

    /// Подпись — текст из поля ввода (как в вебе); после отправки поле чистится.
    private func sendWithCaption(_ files: [ChatViewModel.OutgoingFile], spoiler: Bool = false, viewOnce: Bool = false) async {
        guard !files.isEmpty else { return }
        let caption = viewOnce ? "" : model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !caption.isEmpty { model.updateText("") }
        await model.sendFiles(files, caption: caption, spoiler: spoiler, viewOnce: viewOnce)
    }
}

/// Создание опроса или чек-листа (с 2026-10-18): вопрос, варианты, анонимность,
/// несколько ответов, викторина, свои варианты участников, скрытые итоги, срок.
struct PollComposer: View {
    let model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var checklist = false
    @State private var question = ""
    @State private var options = ["", ""]
    @State private var anonymous = true
    @State private var multiple = false
    @State private var quiz = false
    @State private var correct = 0
    @State private var openAdd = false
    @State private var hideResults = false
    /// Закрыть сам через столько секунд; 0 — нет.
    @State private var closeAfter = 0
    @State private var busy = false

    private var cleanOptions: [String] { options.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    private var maxOptions: Int { checklist ? 30 : 10 }
    private var minOptions: Int { checklist ? 1 : 2 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Вид", selection: $checklist) {
                        Text("Опрос").tag(false)
                        Text("Чек-лист").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                Section(checklist ? "Название" : "Вопрос") {
                    TextField(checklist ? "Название" : "Вопрос", text: $question, axis: .vertical)
                }
                Section(checklist ? "Пункты" : "Варианты") {
                    ForEach(options.indices, id: \.self) { i in
                        HStack {
                            if quiz && !checklist {
                                Button { correct = i } label: {
                                    Image(systemName: correct == i ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(correct == i ? Theme.success : Theme.muted)
                                }
                                .buttonStyle(.plain)
                            }
                            TextField(checklist ? "Пункт \(i + 1)" : "Вариант \(i + 1)", text: $options[i])
                        }
                    }
                    .onDelete { set in
                        if options.count > minOptions { options.remove(atOffsets: set) }
                    }
                    if options.count < maxOptions {
                        Button(checklist ? "Добавить пункт" : "Добавить вариант") { options.append("") }
                    }
                }
                if checklist {
                    Section {
                        Toggle("Участники могут добавлять пункты", isOn: $openAdd)
                    }
                } else {
                    Section {
                        Toggle("Анонимный", isOn: $anonymous)
                        Toggle("Несколько ответов", isOn: $multiple).disabled(quiz)
                        Toggle("Викторина", isOn: $quiz)
                            .onChange(of: quiz) { _, on in if on { multiple = false; openAdd = false } }
                        Toggle("Участники могут добавлять свои варианты", isOn: $openAdd).disabled(quiz)
                        Toggle("Итоги — только после завершения", isOn: $hideResults)
                        Picker("Завершить сам", selection: $closeAfter) {
                            Text("Нет").tag(0)
                            Text("Через час").tag(3600)
                            Text("Через сутки").tag(86400)
                            Text("Через 3 дня").tag(3 * 86400)
                            Text("Через неделю").tag(7 * 86400)
                        }
                    }
                }
            }
            .navigationTitle(checklist ? "Новый чек-лист" : "Новый опрос")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Отправить") {
                        busy = true
                        let opts = cleanOptions
                        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
                        // Номер правильного — среди непустых вариантов
                        var correctIndex: Int?
                        if quiz && !checklist {
                            let kept = options.indices.filter { !options[$0].trimmingCharacters(in: .whitespaces).isEmpty }
                            correctIndex = kept.firstIndex(of: correct)
                        }
                        var spec = MessageRepository.PollSpec(question: q, options: opts)
                        spec.checklist = checklist
                        spec.openAdd = openAdd && correctIndex == nil
                        if !checklist {
                            spec.multiple = multiple
                            spec.anonymous = anonymous
                            spec.correct = correctIndex
                            spec.hideResults = hideResults
                            if closeAfter > 0 { spec.closeAt = Date().addingTimeInterval(TimeInterval(closeAfter)) }
                        }
                        Task {
                            if await model.sendPoll(spec) { dismiss() }
                            busy = false
                        }
                    }
                    .disabled(busy || question.trimmingCharacters(in: .whitespaces).isEmpty || cleanOptions.count < minOptions
                              || (quiz && !checklist && cleanOptions.count <= correct))
                }
            }
        }
    }
}
