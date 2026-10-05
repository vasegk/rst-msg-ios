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
    @State private var recorder = VoiceRecorder()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let reply = model.replyTo { contextBar(title: "Ответ: \(store.displayName(reply.sender))", text: Previews.describe(reply), icon: "arrowshape.turn.up.left.fill") }
            if let edit = model.editing { contextBar(title: "Изменение", text: Previews.describe(edit), icon: "pencil") }

            if !model.canWrite {
                Text(blockedText)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.surface.opacity(0.95))
            } else if recorder.isRecording {
                recordingBar
            } else {
                inputBar
            }
        }
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
            Menu {
                Button { showPhotos = true } label: { Label("Фото или видео", systemImage: "photo.on.rectangle") }
                Button { showFiles = true } label: { Label("Файл", systemImage: "doc") }
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
                Button { Task { await startRecording() } } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 44, height: 44)
                }
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
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var recordingBar: some View {
        HStack(spacing: 14) {
            Button { recorder.cancel() } label: {
                Image(systemName: "trash").font(.system(size: 20)).foregroundStyle(Theme.danger).frame(width: 44, height: 44)
            }
            Circle().fill(Theme.danger).frame(width: 10, height: 10).opacity(recorder.blink ? 1 : 0.3)
            Text(recorder.elapsedText).font(.system(size: 16, weight: .medium).monospacedDigit())
            Spacer()
            Text("Запись…").foregroundStyle(Theme.muted).font(.system(size: 14))
            Button {
                if let result = recorder.finish() {
                    Task { await model.sendVoice(url: result.0, duration: result.1) }
                }
            } label: {
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

    private func startRecording() async {
        do {
            try await recorder.start()
        } catch {
            model.toast = errorText(error)
        }
    }

    private func sendPhotos(_ items: [PhotosPickerItem]) async {
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
                await model.sendAttachment(data: data, fileName: "video.\(ext)", mimeType: mime)
            } else {
                let type = item.supportedContentTypes.first { $0.conforms(to: .image) }
                let mime = type?.preferredMIMEType ?? "image/jpeg"
                let ext = type?.preferredFilenameExtension ?? "jpg"
                await model.sendAttachment(data: data, fileName: "photo.\(ext)", mimeType: mime)
            }
        }
    }

    private func sendFiles(_ urls: [URL]) async {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                model.toast = "Не удалось прочитать \(url.lastPathComponent)"
                continue
            }
            let mime = AttachmentRepository.mimeType(forExtension: url.pathExtension)
            // Файл, выбранный как документ, не пережимаем — даже если это картинка
            await model.sendAttachment(data: data, fileName: url.lastPathComponent, mimeType: mime, compress: false)
        }
    }
}

/// Запись голосового: AAC в m4a, как приложение Android (audio/mp4).
@MainActor
@Observable
final class VoiceRecorder {
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var blink = false
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var url: URL?

    var elapsedText: String {
        let s = Int(elapsed)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    func start() async throws {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            throw CryptoError("Нет доступа к микрофону. Разрешите его в Настройках → RST.")
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("voice_\(Int(Date().timeIntervalSince1970)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let rec = try AVAudioRecorder(url: file, settings: settings)
        guard rec.record() else { throw CryptoError("Не удалось начать запись") }
        recorder = rec
        url = file
        elapsed = 0
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                self.elapsed = recorder.currentTime
                self.blink.toggle()
            }
        }
    }

    /// Остановить и вернуть файл с длительностью.
    func finish() -> (URL, TimeInterval)? {
        guard let recorder, let url else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        reset()
        return (url, duration)
    }

    func cancel() {
        recorder?.stop()
        recorder?.deleteRecording()
        reset()
    }

    private func reset() {
        timer?.invalidate()
        timer = nil
        recorder = nil
        url = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Создание опроса: вопрос, 2–10 вариантов, анонимность, несколько ответов, викторина.
struct PollComposer: View {
    let model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var options = ["", ""]
    @State private var anonymous = true
    @State private var multiple = false
    @State private var quiz = false
    @State private var correct = 0
    @State private var busy = false

    private var cleanOptions: [String] { options.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Вопрос") {
                    TextField("Вопрос", text: $question, axis: .vertical)
                }
                Section("Варианты") {
                    ForEach(options.indices, id: \.self) { i in
                        HStack {
                            if quiz {
                                Button { correct = i } label: {
                                    Image(systemName: correct == i ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(correct == i ? Theme.success : Theme.muted)
                                }
                                .buttonStyle(.plain)
                            }
                            TextField("Вариант \(i + 1)", text: $options[i])
                        }
                    }
                    .onDelete { set in
                        if options.count > 2 { options.remove(atOffsets: set) }
                    }
                    if options.count < 10 {
                        Button("Добавить вариант") { options.append("") }
                    }
                }
                Section {
                    Toggle("Анонимный", isOn: $anonymous)
                    Toggle("Несколько ответов", isOn: $multiple).disabled(quiz)
                    Toggle("Викторина", isOn: $quiz)
                        .onChange(of: quiz) { _, on in if on { multiple = false } }
                }
            }
            .navigationTitle("Новый опрос")
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
                        if quiz {
                            let kept = options.indices.filter { !options[$0].trimmingCharacters(in: .whitespaces).isEmpty }
                            correctIndex = kept.firstIndex(of: correct)
                        }
                        Task {
                            if await model.sendPoll(question: q, options: opts, multiple: multiple, anonymous: anonymous, correct: correctIndex) {
                                dismiss()
                            }
                            busy = false
                        }
                    }
                    .disabled(busy || question.trimmingCharacters(in: .whitespaces).isEmpty || cleanOptions.count < 2 || (quiz && cleanOptions.count <= correct))
                }
            }
        }
    }
}
