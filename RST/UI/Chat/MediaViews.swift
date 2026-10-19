import AVFoundation
import AVKit
import QuickLook
import SwiftUI
import UIKit

/// Расшифрованная картинка вложения.
struct EncryptedImageView: View {
    let attachment: Attachment
    var maxWidth: CGFloat = 260
    var maxHeight: CGFloat = 320
    var onOpen: (UIImage) -> Void = { _ in }

    @Environment(Services.self) private var services
    @State private var image: UIImage?
    @State private var failed = false
    /// Автозагрузка выключена (или не Wi-Fi) — ждём нажатия.
    @State private var waiting = false

    var body: some View {
        Group {
            if waiting {
                Button {
                    waiting = false
                    Task { await load(manual: true) }
                } label: {
                    placeholder(icon: "arrow.down.circle", text: "Фото · нажмите, чтобы загрузить")
                }
                .buttonStyle(.plain)
            } else if let image {
                let size = fitted(image.size)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen(image) }
            } else if failed {
                placeholder(icon: "exclamationmark.triangle", text: "Не удалось загрузить фото")
            } else {
                ZStack {
                    Rectangle().fill(Color.black.opacity(0.2))
                    ProgressView().tint(.white)
                }
                .frame(width: maxWidth * 0.8, height: maxWidth * 0.6)
            }
        }
        .task(id: attachment.fileUrl) { await load() }
    }

    private func fitted(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: maxWidth, height: maxWidth) }
        let scale = min(maxWidth / size.width, maxHeight / size.height, 1.5)
        return CGSize(width: max(120, size.width * scale), height: max(80, size.height * scale))
    }

    private func load(manual: Bool = false) async {
        if !manual && !ChatAppearance.shared.shouldAutoLoadPhotos && services.attachments.existingFileURL(for: attachment) == nil {
            waiting = true
            return
        }
        do {
            let data = try await services.attachments.data(for: attachment)
            let decoded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let img = UIImage(data: data) else { return nil }
                return img.preparingThumbnail(of: CGSize(width: 900, height: 900 * img.size.height / max(img.size.width, 1))) ?? img
            }.value
            if let decoded { image = decoded } else { failed = true }
        } catch {
            failed = true
        }
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
            Text(text).font(.system(size: 12))
        }
        .foregroundStyle(.secondary)
        .frame(width: 200, height: 120)
    }
}

/// Картинка без шифрования: стикер.
struct PlainImageView: View {
    let fileUrl: String
    var size: CGFloat = 160
    @Environment(Services.self) private var services
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.15))
            }
        }
        .frame(width: size, height: size)
        .task(id: fileUrl) {
            if let data = try? await services.attachments.plainData(fileUrl) { image = UIImage(data: data) }
        }
    }
}

/// Полноэкранный просмотр фото: масштаб жестом, «Поделиться».
struct ImageViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        NavigationStack {
            GeometryReader { _ in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { scale = max(1, lastScale * $0) }
                            .onEnded { _ in
                                lastScale = scale
                                if scale <= 1 { withAnimation { offset = .zero; lastOffset = .zero } }
                            }
                            .simultaneously(with: DragGesture()
                                .onChanged { v in
                                    guard scale > 1 else { return }
                                    offset = CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height)
                                }
                                .onEnded { _ in lastOffset = offset })
                    )
                    .onTapGesture(count: 2) {
                        withAnimation {
                            scale = scale > 1 ? 1 : 2.5
                            lastScale = scale
                            if scale == 1 { offset = .zero; lastOffset = .zero }
                        }
                    }
            }
            .background(Color.black.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: Image(uiImage: image), preview: SharePreview("Фото", image: Image(uiImage: image)))
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }
}

/// Файл: значок, имя, «Открыть» — расшифровывается и показывается через Quick Look.
struct FileAttachmentView: View {
    let attachment: Attachment
    var isMine = false
    @Environment(Services.self) private var services
    @State private var busy = false
    @State private var previewURL: URL?
    @State private var error: String?

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(isMine ? Color.white.opacity(0.25) : Theme.accent.opacity(0.2)).frame(width: 44, height: 44)
                    if busy {
                        ProgressView().tint(isMine ? .white : Theme.accent)
                    } else {
                        Image(systemName: icon).foregroundStyle(isMine ? .white : Theme.accent)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.fileName)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(2)
                    Text(error ?? "Нажмите, чтобы открыть")
                        .font(.system(size: 12))
                        .opacity(0.75)
                }
                Spacer(minLength: 0)
            }
            .frame(minWidth: 200)
        }
        .buttonStyle(.plain)
        .quickLookPreview($previewURL)
    }

    private var icon: String {
        let m = attachment.mimeType
        if m.hasPrefix("video/") { return "play.fill" }
        if m.contains("pdf") { return "doc.richtext" }
        if m.contains("zip") { return "doc.zipper" }
        if m.hasPrefix("text/") { return "doc.text" }
        return "doc.fill"
    }

    private func open() {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                previewURL = try await services.attachments.fileURL(for: attachment)
            } catch {
                self.error = errorText(error)
            }
        }
    }
}

/// Видео: превью-кадр и проигрывание во весь экран.
struct VideoAttachmentView: View {
    let attachment: Attachment
    var round = false
    var onPlayed: () -> Void = {}
    @Environment(Services.self) private var services
    @State private var thumbnail: UIImage?
    @State private var url: URL?
    @State private var busy = false
    @State private var playing = false
    @State private var error: String?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color.black.opacity(0.35))
            }
            Circle().fill(Color.black.opacity(0.45)).frame(width: 52, height: 52)
            if busy {
                ProgressView().tint(.white)
            } else {
                Image(systemName: error == nil ? "play.fill" : "exclamationmark.triangle").font(.system(size: 22)).foregroundStyle(.white)
            }
        }
        .frame(width: round ? 220 : 260, height: round ? 220 : 180)
        .clipShape(round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 12)))
        .contentShape(Rectangle())
        .onTapGesture(perform: play)
        .task(id: attachment.fileUrl) { await prepareThumbnail() }
        .fullScreenCover(isPresented: $playing) {
            if let url { VideoPlayerScreen(url: url) }
        }
    }

    private func prepareThumbnail() async {
        // Кадр — только если файл уже скачан: без спроса трафик не тратим
        guard let file = services.attachments.existingFileURL(for: attachment) else { return }
        url = file
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)
        if let cg = try? await generator.image(at: .zero).image { thumbnail = UIImage(cgImage: cg) }
    }

    private func play() {
        if url != nil {
            onPlayed()
            playing = true
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                url = try await services.attachments.fileURL(for: attachment)
                onPlayed()
                playing = true
            } catch {
                self.error = errorText(error)
            }
        }
    }
}

struct VideoPlayerScreen: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player).ignoresSafeArea()
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Circle().fill(Color.black.opacity(0.5)))
            }
            .padding()
        }
        .onAppear {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            let p = AVPlayer(url: url)
            player = p
            p.play()
        }
        .onDisappear { player?.pause() }
    }
}

/// Плеер голосовых: воспроизведение, перемотка, скорость 1 / 1.5 / 2.
@MainActor
@Observable
final class VoicePlayback {
    static let shared = VoicePlayback()

    private(set) var currentUrl: String?
    private(set) var playing = false
    private(set) var progress: Double = 0
    private(set) var duration: Double = 0
    var rate: Float = 1
    /// Что дослушали до конца (не остановили): по нему играет следующее.
    private(set) var finishedKey: String?
    private(set) var finishCount = 0

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let finishDelegate = PlayerFinishDelegate()

    init() {
        finishDelegate.onFinish = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let key = self.currentUrl
                self.stop()
                self.finishedKey = key
                self.finishCount += 1
            }
        }
    }

    func toggle(_ key: String, data: Data) throws {
        if currentUrl == key, let player {
            if player.isPlaying { player.pause(); playing = false } else { player.play(); playing = true }
            return
        }
        stop()
        RoundPlayback.shared.stop()
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        let p = try AVAudioPlayer(data: data)
        p.enableRate = true
        p.rate = rate
        p.delegate = finishDelegate
        p.prepareToPlay()
        player = p
        currentUrl = key
        duration = p.duration
        p.play()
        playing = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.progress = player.duration > 0 ? player.currentTime / player.duration : 0
            }
        }
    }

    func seek(_ fraction: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(1, fraction)) * player.duration
        progress = fraction
    }

    func cycleRate() {
        rate = rate == 1 ? 1.5 : (rate == 1.5 ? 2 : 1)
        player?.rate = rate
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        playing = false
        progress = 0
        currentUrl = nil
    }

}

private final class PlayerFinishDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: () -> Void = {}
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onFinish() }
}

struct VoiceMessageView: View {
    let attachment: Attachment
    var isMine = false
    var played = true
    /// Дослушали предыдущее — это играет само.
    var autoplay = false
    var onPlayed: () -> Void = {}
    var onFinished: () -> Void = {}

    @Environment(Services.self) private var services
    @State private var busy = false
    @State private var error: String?
    @State private var localDuration: Double?
    private var playback: VoicePlayback { VoicePlayback.shared }

    private var isCurrent: Bool { playback.currentUrl == attachment.fileUrl }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                ZStack {
                    Circle().fill(isMine ? Color.white : Theme.accent).frame(width: 42, height: 42)
                    if busy {
                        ProgressView().tint(isMine ? Theme.accent : .white)
                    } else {
                        Image(systemName: isCurrent && playback.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(isMine ? Theme.accent : .white)
                    }
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 5) {
                Waveform(progress: isCurrent ? playback.progress : 0, seed: attachment.fileUrl, isMine: isMine)
                    .frame(height: 22)
                    .overlay(GeometryReader { geo in
                        Color.clear.contentShape(Rectangle()).onTapGesture(coordinateSpace: .local) { location in
                            if isCurrent { playback.seek(location.x / geo.size.width) }
                        }
                    })
                HStack(spacing: 6) {
                    Text(error ?? timeLabel)
                        .font(.system(size: 12, weight: .medium))
                        .opacity(0.8)
                    if !played && !isMine {
                        Circle().fill(isMine ? Color.white : Theme.accent).frame(width: 6, height: 6)
                    }
                    if isCurrent {
                        Button(rateLabel) { playback.cycleRate() }
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.black.opacity(0.2)))
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(minWidth: 220)
        .onChange(of: playback.finishCount) {
            if playback.finishedKey == attachment.fileUrl { onFinished() }
        }
        .onChange(of: autoplay, initial: true) { _, now in
            if now && !isCurrent { toggle() }
        }
    }

    private var rateLabel: String {
        playback.rate == 1 ? "1×" : (playback.rate == 1.5 ? "1,5×" : "2×")
    }

    private var timeLabel: String {
        let total = isCurrent ? playback.duration : (localDuration ?? 0)
        let shown = isCurrent ? total * playback.progress : total
        guard total > 0 else { return "Голосовое" }
        let s = Int(shown.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func toggle() {
        if isCurrent {
            try? playback.toggle(attachment.fileUrl, data: Data())
            return
        }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let data = try await services.attachments.data(for: attachment)
                do {
                    try playback.toggle(attachment.fileUrl, data: data)
                    localDuration = playback.duration
                    onPlayed()
                } catch {
                    // Голосовые из Chrome — audio/webm: на iOS этот контейнер не играется
                    self.error = attachment.mimeType.contains("webm") ? "Формат WebM на iPhone не воспроизводится" : "Не удалось воспроизвести"
                }
            } catch {
                self.error = errorText(error)
            }
        }
    }
}

/// Псевдо-форма звука: столбики по хешу ссылки — стабильно для одного файла.
struct Waveform: View {
    let progress: Double
    let seed: String
    var isMine = false

    var body: some View {
        GeometryReader { geo in
            let count = max(12, Int(geo.size.width / 4))
            let heights = Self.heights(seed: seed, count: count)
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<count, id: \.self) { i in
                    let filled = Double(i) / Double(count) < progress
                    Capsule()
                        .fill(isMine ? Color.white.opacity(filled ? 1 : 0.45) : (filled ? Theme.accent : Theme.muted.opacity(0.6)))
                        .frame(width: 2, height: max(3, geo.size.height * heights[i]))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    static func heights(seed: String, count: Int) -> [CGFloat] {
        var h: UInt64 = 1469598103934665603
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return (0..<count).map { _ in
            h = h &* 6364136223846793005 &+ 1442695040888963407
            return 0.25 + CGFloat((h >> 33) % 1000) / 1000 * 0.75
        }
    }
}

// MARK: - Кружки

/// Кружок играет прямо в ленте: по нажатию — со звуком с начала, повторное
/// нажатие — пауза. Одновременно звучит что-то одно: голосовое или кружок.
@MainActor
@Observable
final class RoundPlayback {
    static let shared = RoundPlayback()

    private(set) var currentKey: String?
    private(set) var playing = false
    private(set) var progress: Double = 0
    private(set) var finishedKey: String?
    private(set) var finishCount = 0
    @ObservationIgnored private(set) var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    func toggle(_ key: String, url: URL) {
        if currentKey == key, let player {
            if playing { player.pause() } else { player.play() }
            playing.toggle()
            return
        }
        stop()
        VoicePlayback.shared.stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        player = p
        currentKey = key
        progress = 0
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, let d = self.player?.currentItem?.duration.seconds, d.isFinite, d > 0 else { return }
                self.progress = min(1, time.seconds / d)
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let key = self.currentKey
                self.stop()
                self.finishedKey = key
                self.finishCount += 1
            }
        }
        p.play()
        playing = true
    }

    func stop() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player?.pause()
        player = nil
        currentKey = nil
        playing = false
        progress = 0
    }
}

private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: LayerView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }
}

/// Кружок в ленте: кадр, по нажатию — видео со звуком и кольцо прогресса.
struct RoundVideoView: View {
    let attachment: Attachment
    var played = true
    var isMine = false
    var autoplay = false
    var onPlayed: () -> Void = {}
    var onFinished: () -> Void = {}
    @Environment(Services.self) private var services
    @State private var thumbnail: UIImage?
    @State private var busy = false
    @State private var error: String?
    private var playback: RoundPlayback { RoundPlayback.shared }
    private var isCurrent: Bool { playback.currentKey == attachment.fileUrl }
    private static let size: CGFloat = 220

    var body: some View {
        ZStack {
            if isCurrent, let player = playback.player {
                PlayerLayerView(player: player)
            } else if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color.black.opacity(0.35))
            }
            if isCurrent {
                Circle()
                    .trim(from: 0, to: playback.progress)
                    .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(3)
            }
            if busy {
                ProgressView().tint(.white)
            } else if !isCurrent || !playback.playing {
                Circle().fill(Color.black.opacity(0.45)).frame(width: 52, height: 52)
                Image(systemName: error == nil ? "play.fill" : "exclamationmark.triangle").font(.system(size: 22)).foregroundStyle(.white)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
            if !played && !isMine {
                Circle().fill(Theme.accent).frame(width: 10, height: 10).offset(x: -18, y: -18)
            }
        }
        .contentShape(Circle())
        .onTapGesture(perform: toggle)
        .task(id: attachment.fileUrl) { await prepareThumbnail() }
        .onChange(of: playback.finishCount) {
            if playback.finishedKey == attachment.fileUrl { onFinished() }
        }
        .onChange(of: autoplay, initial: true) { _, now in
            if now && !isCurrent { toggle() }
        }
    }

    private func prepareThumbnail() async {
        guard let file = services.attachments.existingFileURL(for: attachment) else { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        if let cg = try? await generator.image(at: .zero).image { thumbnail = UIImage(cgImage: cg) }
    }

    private func toggle() {
        if isCurrent, let url = services.attachments.existingFileURL(for: attachment) {
            playback.toggle(attachment.fileUrl, url: url)
            return
        }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let url = try await services.attachments.fileURL(for: attachment)
                playback.toggle(attachment.fileUrl, url: url)
                onPlayed()
                if thumbnail == nil { await prepareThumbnail() }
            } catch {
                self.error = errorText(error)
            }
        }
    }
}
