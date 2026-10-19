import AVFoundation
import SwiftUI
import UIKit

/// Кнопка справа от поля, как в вебе (media-ui.js) и Telegram: нажатие меняет
/// режим «голосовое ⇄ кружок», удержание записывает. Отпустил — ушло; увёл
/// палец вверх — запись закрепляется и идёт без рук; увёл влево — отмена.
@MainActor
@Observable
final class RecordingController {
    enum Mode: String { case voice, circle }

    static let holdStart: UInt64 = 220_000_000
    static let lockDistance: CGFloat = 60
    static let cancelDistance: CGFloat = 110
    private static let modeKey = "rst.recMode"

    var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }
    let voice = VoiceRecorder()
    let circle = CircleRecorder()
    /// Палец держит кнопку и запись идёт.
    private(set) var holding = false
    /// Запись идёт без рук: отправка или отмена — кнопками на полосе.
    private(set) var locked = false
    private(set) var drag: CGSize = .zero
    /// Готовая запись: голосовое или кружок.
    @ObservationIgnored var onFinish: ((Mode, URL, TimeInterval) -> Void)?
    @ObservationIgnored var onError: ((String) -> Void)?

    @ObservationIgnored private var pressed = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var released = false
    @ObservationIgnored private var startTask: Task<Void, Never>?

    init() {
        mode = Mode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .voice
        circle.onLimit = { [weak self] in self?.finish() }
    }

    var isRecording: Bool { voice.isRecording || circle.isRecording }
    var activeMode: Mode { circle.isRecording ? .circle : .voice }
    var elapsed: TimeInterval { circle.isRecording ? circle.elapsed : voice.elapsed }
    var elapsedText: String {
        let s = Int(elapsed)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    func dragChanged(_ translation: CGSize) {
        if !pressed {
            pressed = true
            started = false
            released = false
            drag = .zero
            let current = mode
            startTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.holdStart)
                guard let self, !Task.isCancelled, !self.released else { return }
                self.started = true
                await self.begin(current)
                guard self.isRecording else { return }
                // Отпустили, пока ждали микрофон или камеру (окно «Разрешить»):
                // отправлять нечего — пусть пишется без рук
                if self.released {
                    self.locked = true
                } else {
                    self.holding = true
                }
            }
            return
        }
        guard holding, isRecording else { return }
        drag = translation
        if translation.height <= -Self.lockDistance {
            lock()
        } else if translation.width <= -Self.cancelDistance {
            cancel()
        }
    }

    func dragEnded() {
        pressed = false
        released = true
        if !started {
            // Короткое нажатие — сменить режим
            startTask?.cancel()
            mode = mode == .voice ? .circle : .voice
            UISelectionFeedbackGenerator().selectionChanged()
            return
        }
        // Запись ещё не началась — решится, когда начнётся (см. выше)
        guard isRecording, holding else { return }
        holding = false
        finish()
    }

    /// Начать без удержания (VoiceOver): сразу закреплённая запись.
    func startLocked() {
        let current = mode
        Task {
            await begin(current)
            if isRecording { locked = true }
        }
    }

    func lock() {
        holding = false
        locked = true
        drag = .zero
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func cancel() {
        holding = false
        locked = false
        drag = .zero
        voice.cancel()
        circle.cancel()
    }

    func finish() {
        holding = false
        locked = false
        drag = .zero
        if circle.isRecording {
            Task {
                guard let (url, duration) = await circle.finish() else { return }
                onFinish?(.circle, url, duration)
            }
        } else if let (url, duration) = voice.finish() {
            onFinish?(.voice, url, duration)
        }
    }

    private func begin(_ mode: Mode) async {
        VoicePlayback.shared.stop()
        RoundPlayback.shared.stop()
        do {
            switch mode {
            case .voice: try await voice.start()
            case .circle: try await circle.start()
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } catch {
            onError?(errorText(error))
        }
    }
}

/// Кнопка записи: микрофон или кружок.
struct RecordButton: View {
    let rec: RecordingController

    var body: some View {
        Image(systemName: rec.mode == .voice ? "mic.fill" : "video.circle.fill")
            .font(.system(size: rec.mode == .voice ? 20 : 23))
            .foregroundStyle(rec.holding ? Theme.accent : Theme.muted)
            .scaleEffect(rec.holding ? 1.25 : 1)
            .frame(width: 44, height: 44)
            .glassCircleOnly()
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.15), value: rec.holding)
            .animation(.easeOut(duration: 0.15), value: rec.mode)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { rec.dragChanged($0.translation) }
                    .onEnded { _ in rec.dragEnded() }
            )
            .overlay(alignment: .top) {
                if rec.holding {
                    // Замок над кнопкой: ведут вверх — запись закрепляется
                    VStack(spacing: 2) {
                        Image(systemName: "lock.fill").font(.system(size: 15))
                        Image(systemName: "chevron.up").font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(Theme.muted)
                    .padding(.vertical, 8)
                    .frame(width: 38)
                    .background(Capsule().fill(Theme.surface))
                    .offset(y: -78 + min(0, rec.drag.height) / 2)
                    .allowsHitTesting(false)
                }
            }
            .accessibilityLabel(rec.mode == .voice ? "Голосовое" : "Кружок")
            .accessibilityHint("Удерживайте, чтобы записать. Нажатие меняет голосовое и кружок")
            .accessibilityAction(named: "Записать") { rec.startLocked() }
    }
}

/// Полоса при записи с удержанием: время, громкость, «‹ Отмена» за пальцем.
struct RecordingHoldIndicator: View {
    let rec: RecordingController

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.danger).frame(width: 10, height: 10).opacity(rec.voice.blink || rec.circle.blink ? 1 : 0.3)
            Text(rec.elapsedText).font(.system(size: 16, weight: .medium).monospacedDigit())
            if rec.activeMode == .voice {
                LevelBars(levels: rec.voice.levels).frame(height: 22)
            }
            Spacer(minLength: 4)
            let left = min(0, rec.drag.width)
            Text("‹ Отмена")
                .font(.system(size: 15))
                .foregroundStyle(Theme.muted)
                .offset(x: left)
                .opacity(Double(1 + left / RecordingController.cancelDistance))
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }
}

/// Дорожка громкости: последние уровни микрофона столбиками.
struct LevelBars: View {
    let levels: [CGFloat]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule().fill(Theme.accent).frame(width: 3, height: max(3, level * 22))
            }
        }
        .animation(.linear(duration: 0.1), value: levels)
    }
}

// MARK: - Голосовое

/// Запись голосового: AAC в m4a, как приложение Android (audio/mp4).
@MainActor
@Observable
final class VoiceRecorder {
    static let levelCount = 28

    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var blink = false
    /// Уровни 0…1 для дорожки громкости.
    private(set) var levels: [CGFloat] = Array(repeating: 0, count: levelCount)
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var ticks = 0

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
        rec.isMeteringEnabled = true
        guard rec.record() else { throw CryptoError("Не удалось начать запись") }
        recorder = rec
        url = file
        elapsed = 0
        ticks = 0
        levels = Array(repeating: 0, count: Self.levelCount)
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let recorder else { return }
        elapsed = recorder.currentTime
        recorder.updateMeters()
        // −50 дБ и тише — тишина, 0 дБ — предел
        let db = CGFloat(recorder.averagePower(forChannel: 0))
        let level = max(0, min(1, (db + 50) / 50))
        levels.removeFirst()
        levels.append(level)
        ticks += 1
        if ticks % 5 == 0 { blink.toggle() }
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
        guard isRecording else { return }
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

// MARK: - Кружок

/// Запись кружка: фронтальная камера со звуком, до двух минут; перед
/// отправкой кадр обрезается квадратом 480×480, как холст в вебе.
@MainActor
@Observable
final class CircleRecorder {
    static let maxDuration: TimeInterval = 120
    nonisolated static let side: CGFloat = 480

    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var blink = false
    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored var onLimit: (() -> Void)?
    @ObservationIgnored private let output = AVCaptureMovieFileOutput()
    @ObservationIgnored private let delegate = MovieOutputDelegate()
    @ObservationIgnored private var configured = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var ticks = 0
    private static let queue = DispatchQueue(label: "rst.circle.session")

    var progress: Double { min(1, elapsed / Self.maxDuration) }

    func start() async throws {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            throw CryptoError("Нет доступа к камере. Разрешите её в Настройках → RST.")
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            throw CryptoError("Нет доступа к микрофону. Разрешите его в Настройках → RST.")
        }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetooth])
        try audio.setActive(true)
        if !configured {
            try configure()
            configured = true
        }
        let session = self.session
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Self.queue.async {
                if !session.isRunning { session.startRunning() }
                done.resume()
            }
        }
        if let connection = output.connection(with: .video) {
            // Как в зеркале — так же, как видно на превью
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("circle_\(Int(Date().timeIntervalSince1970)).mov")
        delegate.reset()
        output.startRecording(to: file, recordingDelegate: delegate)
        startedAt = Date()
        elapsed = 0
        ticks = 0
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video) else {
            throw CryptoError("Камера недоступна")
        }
        let cameraInput = try AVCaptureDeviceInput(device: camera)
        if session.canAddInput(cameraInput) { session.addInput(cameraInput) }
        if let mic = AVCaptureDevice.default(for: .audio), let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }
        if session.canAddOutput(output) { session.addOutput(output) }
        output.maxRecordedDuration = CMTime(seconds: Self.maxDuration, preferredTimescale: 600)
    }

    private func tick() {
        elapsed = Date().timeIntervalSince(startedAt)
        ticks += 1
        if ticks % 5 == 0 { blink.toggle() }
        if elapsed >= Self.maxDuration - 0.2 { onLimit?() }
    }

    /// Остановить и вернуть квадратный mp4 с длительностью.
    func finish() async -> (URL, TimeInterval)? {
        guard isRecording else { return nil }
        let duration = elapsed
        let output = self.output
        stopTimer()
        let recorded = await delegate.wait { output.stopRecording() }
        teardown()
        guard let recorded else { return nil }
        let square = (try? await Self.squareCrop(recorded)) ?? recorded
        if square != recorded { try? FileManager.default.removeItem(at: recorded) }
        return (square, duration)
    }

    func cancel() {
        guard isRecording else { return }
        let output = self.output
        let delegate = self.delegate
        stopTimer()
        Task {
            if let url = await delegate.wait({ output.stopRecording() }) { try? FileManager.default.removeItem(at: url) }
            teardown()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        isRecording = false
    }

    private func teardown() {
        let session = self.session
        Self.queue.async { if session.isRunning { session.stopRunning() } }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Квадрат по центру кадра с учётом поворота дорожки, 480×480, mp4.
    nonisolated static func squareCrop(_ source: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return source }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let oriented = CGRect(origin: .zero, size: natural).applying(transform)
        let width = abs(oriented.width), height = abs(oriented.height)
        let crop = min(width, height)
        guard crop > 0 else { return source }
        let scale = side / crop

        var t = transform.concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
        t = t.concatenating(CGAffineTransform(translationX: -(width - crop) / 2, y: -(height - crop) / 2))
        t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(t, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: side, height: side)
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.instructions = [instruction]

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else { return source }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("video_msg_\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: target)
        export.outputURL = target
        export.outputFileType = .mp4
        export.videoComposition = composition
        export.shouldOptimizeForNetworkUse = true
        await export.export()
        guard export.status == .completed else { return source }
        return target
    }
}

/// Делегат записи: результат приходит с очереди камеры, ждём его на главной.
private final class MovieOutputDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private var result: URL??
    private var waiter: CheckedContinuation<URL?, Never>?

    @MainActor func reset() {
        result = nil
        waiter = nil
    }

    /// Остановить запись и дождаться файла (или nil при ошибке).
    @MainActor func wait(_ stop: () -> Void) async -> URL? {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            waiter = continuation
            stop()
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        var ok = error == nil
        // Предел длительности — тоже «ошибка», но файл цел
        if let error, ((error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) == true { ok = true }
        let url: URL? = ok ? outputFileURL : nil
        DispatchQueue.main.async {
            if let waiter = self.waiter {
                self.waiter = nil
                waiter.resume(returning: url)
            } else {
                self.result = .some(url)
            }
        }
    }
}

/// Превью камеры для кружка.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

/// Крупный кружок с кольцом-таймером над полем ввода во время записи.
struct CircleRecordingPreview: View {
    let circle: CircleRecorder

    var body: some View {
        ZStack {
            CameraPreview(session: circle.session)
                .clipShape(Circle())
            Circle()
                .trim(from: 0, to: circle.progress)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(-6)
        }
        .frame(width: 240, height: 240)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
    }
}
