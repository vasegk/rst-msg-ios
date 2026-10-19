import AVFoundation
import SwiftUI
import UIKit

// MARK: - Эмодзи-статус (js/emoji-status.js)

/// Один эмодзи рядом с именем везде, где имя видно; можно со сроком.
/// Виден всем, как имя, — не шифруется.
struct EmojiStatusView: View {
    @Environment(Services.self) private var services
    @Environment(ChatListStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selected = ""
    @State private var custom = ""
    @State private var term: TimeInterval = 0
    @State private var busy = false
    @State private var error: String?

    static let frequent = ["😊", "😎", "🥳", "😴", "🤒", "🤔", "❤️", "🔥", "⭐", "🎉", "🏖", "✈️", "🏠", "💼", "💻", "📚",
                           "🎮", "🎧", "🏃", "🏋️", "🍕", "☕", "🎄", "🌙", "🚗", "🎂", "🙏", "👀", "🤫", "⛔", "🔕", "📵"]
    static let terms: [(TimeInterval, String)] = [(3600, "1 час"), (8 * 3600, "8 часов"), (86400, "Сутки"), (7 * 86400, "Неделя"), (0, "Без срока")]

    private var current: String? {
        guard let me = store.myProfile, let e = me.emojiStatus, !e.isEmpty else { return nil }
        if let until = ServerTime.parse(me.emojiStatusUntil), until < Date() { return nil }
        return e
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Сейчас")
                    Spacer()
                    Text(current ?? "не задан").foregroundStyle(Theme.muted)
                }
            }
            Section("Выберите эмодзи") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 10) {
                    ForEach(Self.frequent, id: \.self) { e in
                        Button {
                            selected = e
                            custom = ""
                        } label: {
                            Text(e).font(.system(size: 26)).frame(width: 36, height: 36)
                                .background(Circle().fill(selected == e ? Theme.accent.opacity(0.25) : Color.clear))
                        }
                        .buttonStyle(.plain)
                    }
                }
                TextField("Любой эмодзи", text: $custom)
                    .onChange(of: custom) { _, v in
                        if EmojiPickerSheet.isSingleEmoji(v) { selected = v.trimmingCharacters(in: .whitespaces) }
                    }
            }
            Section("Срок") {
                Picker("Снять через", selection: $term) {
                    ForEach(Self.terms, id: \.0) { Text($0.1).tag($0.0) }
                }
            }
            Section {
                Button("Сохранить") { save(selected) }.disabled(selected.isEmpty || busy)
                if current != nil {
                    Button("Убрать статус", role: .destructive) { save("") }.disabled(busy)
                }
            }
            if let error { Text(error).foregroundStyle(Theme.danger) }
        }
        .navigationTitle("Эмодзи-статус")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if selected.isEmpty { selected = current ?? "" } }
    }

    private func save(_ emoji: String) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let until = emoji.isEmpty || term == 0 ? nil : Date().addingTimeInterval(term)
                try await services.api.setEmojiStatus(emoji, until: until)
                await store.refresh()
                dismiss()
            } catch {
                self.error = errorText(error)
            }
        }
    }
}

// MARK: - Аватар на весь экран и история аватаров (js/avatar-viewer.js)

/// Все аватары человека, сверху нынешний: «1 из 3 · 12 октября». У своих —
/// «Удалить фото»: убрали нынешний — сервер ставит следующий.
struct AvatarHistoryViewer: View {
    let username: String
    let name: String
    var currentUrl: String?
    @Environment(Services.self) private var services
    @Environment(ChatListStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var items: [AvatarHistoryItem] = []
    @State private var index = 0
    @State private var confirmDelete = false
    @State private var loaded = false

    private var isMine: Bool { username == services.me }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if items.isEmpty {
                if loaded {
                    Text("Фото нет").foregroundStyle(.white.opacity(0.7))
                } else {
                    ProgressView().tint(.white)
                }
            } else {
                TabView(selection: $index) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        AsyncImage(url: services.api.absoluteURL(item.url)) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFit()
                            } else if phase.error != nil {
                                Image(systemName: "photo").font(.system(size: 40)).foregroundStyle(.white.opacity(0.5))
                            } else {
                                ProgressView().tint(.white)
                            }
                        }
                        .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                            .padding(12).background(Circle().fill(Color.black.opacity(0.5)))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        if !items.isEmpty {
                            Text(caption).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    Spacer()
                }
                .padding()
                Spacer()
                if isMine && !items.isEmpty {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Удалить фото", systemImage: "trash")
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .confirmationDialog("Удалить фото? Оно пропадёт из вашего профиля.", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { deleteCurrent() }
        }
        .task { await load() }
    }

    private var caption: String {
        let n = "\(index + 1) из \(items.count)"
        let date = Self.dateLabel(items[min(index, items.count - 1)].setAt)
        return date.isEmpty ? n : "\(n) · \(date)"
    }

    /// «12 октября», с годом — если не этот год; пусто — даты нет.
    static func dateLabel(_ iso: String?, now: Date = Date()) -> String {
        guard let date = ServerTime.parse(iso) else { return "" }
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now)
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = sameYear ? "d MMMM" : "d MMMM yyyy"
        return f.string(from: date)
    }

    private func load() async {
        defer { loaded = true }
        let list = (try? await services.api.avatars(username).avatars) ?? []
        items = list.filter { !$0.url.isEmpty }
        if items.isEmpty, let currentUrl, !currentUrl.isEmpty {
            items = [AvatarHistoryItem(url: currentUrl, setAt: nil)]
        }
    }

    private func deleteCurrent() {
        guard index < items.count else { return }
        let url = items[index].url
        Task {
            do {
                try await services.api.deleteMyAvatar(url: url)
                items.remove(at: index)
                index = max(0, min(index, items.count - 1))
                await store.refresh()
                if items.isEmpty { dismiss() }
            } catch {
                // Не удалось — фото остаётся на месте
            }
        }
    }
}

// MARK: - Обрезка аватара

struct CropItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Круглая рамка: двигать и увеличивать пальцами; на выходе квадрат 640×640.
struct AvatarCropSheet: View {
    let image: UIImage
    var onDone: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    private let side: CGFloat = 300
    static let output: CGFloat = 640

    var body: some View {
        NavigationStack {
            VStack {
                Spacer()
                cropped
                    .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 2))
                    .overlay(
                        Rectangle().fill(Color.black.opacity(0.55))
                            .mask(Rectangle().overlay(Circle().blendMode(.destinationOut)).compositingGroup())
                            .allowsHitTesting(false)
                    )
                    .contentShape(Rectangle())
                    .gesture(
                        SimultaneousGesture(
                            MagnificationGesture()
                                .onChanged { scale = max(1, min(lastScale * $0, 6)) }
                                .onEnded { _ in
                                    lastScale = scale
                                    clamp()
                                },
                            DragGesture()
                                .onChanged {
                                    offset = CGSize(width: lastOffset.width + $0.translation.width,
                                                    height: lastOffset.height + $0.translation.height)
                                }
                                .onEnded { _ in clamp() }
                        )
                    )
                Text("Двигайте и увеличивайте фото пальцами").font(.system(size: 13)).foregroundStyle(Theme.muted).padding(.top, 14)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Фото")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { finish() } }
            }
        }
    }

    private var cropped: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: side, height: side)
            .scaleEffect(scale)
            .offset(offset)
            .frame(width: side, height: side)
            .clipped()
    }

    /// Фото не уезжает за рамку: край не показывает пустоту.
    private func clamp() {
        let limit = side * (scale - 1) / 2
        offset = CGSize(width: max(-limit, min(limit, offset.width)), height: max(-limit, min(limit, offset.height)))
        lastOffset = offset
    }

    private func finish() {
        let renderer = ImageRenderer(content: cropped)
        renderer.scale = Self.output / side
        if let result = renderer.uiImage { onDone(result) }
        dismiss()
    }
}

// MARK: - Конфетти в день рождения

/// Залп конфетти на пару секунд; сквозь него можно нажимать.
struct ConfettiView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        let width = UIScreen.main.bounds.width
        let emitter = CAEmitterLayer()
        emitter.emitterShape = .line
        emitter.emitterPosition = CGPoint(x: width / 2, y: -10)
        emitter.emitterSize = CGSize(width: width, height: 1)
        let colors: [UIColor] = [.systemPink, .systemYellow, .systemTeal, .systemPurple, .systemOrange, .systemGreen]
        emitter.emitterCells = colors.map { color in
            let cell = CAEmitterCell()
            cell.birthRate = 14
            cell.lifetime = 6
            cell.velocity = 220
            cell.velocityRange = 80
            cell.emissionLongitude = .pi
            cell.emissionRange = .pi / 4
            cell.spin = 3
            cell.spinRange = 4
            cell.scale = 0.6
            cell.scaleRange = 0.3
            cell.yAcceleration = 160
            cell.color = color.cgColor
            cell.contents = Self.piece.cgImage
            return cell
        }
        view.layer.addSublayer(emitter)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { emitter.birthRate = 0 }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    private static let piece: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 6)).image { ctx in
        UIColor.white.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 6))
    }

    /// День рождения сегодня: «ГГГГ-ММ-ДД» или «ММ-ДД».
    static func isToday(_ raw: String?, now: Date = Date()) -> Bool {
        guard let raw else { return false }
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        let m = parts[parts.count - 2], d = parts[parts.count - 1]
        let c = Calendar.current.dateComponents([.month, .day], from: now)
        return c.month == m && c.day == d
    }
}

// MARK: - Блокировка модератором: отсчёт (js/moderation-ui.js)

enum ModerationText {
    /// «2 дня 3 часа», «14 минут 5 секунд», «45 секунд».
    static func remaining(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86400, hours = (total % 86400) / 3600, minutes = (total % 3600) / 60, secs = total % 60
        func p(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
            let n10 = n % 10, n100 = n % 100
            if n10 == 1 && n100 != 11 { return "\(n) \(one)" }
            if (2...4).contains(n10) && !(10..<20).contains(n100) { return "\(n) \(few)" }
            return "\(n) \(many)"
        }
        if days > 0 { return p(days, "день", "дня", "дней") + " " + p(hours, "час", "часа", "часов") }
        if hours > 0 { return p(hours, "час", "часа", "часов") + " " + p(minutes, "минута", "минуты", "минут") }
        if minutes > 0 { return p(minutes, "минута", "минуты", "минут") + " " + p(secs, "секунда", "секунды", "секунд") }
        return p(secs, "секунда", "секунды", "секунд")
    }
}

/// Плашка «Аккаунт ограничен модератором» с живым отсчётом.
struct ModerationBanner: View {
    let until: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(text(now: context.date))
                .font(.system(size: 13))
                .foregroundStyle(Theme.onSurface)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.danger.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func text(now: Date) -> String {
        guard let date = ServerTime.parse(until) else {
            return "Аккаунт ограничен модератором. Отправка сообщений недоступна."
        }
        let left = date.timeIntervalSince(now)
        if left <= 0 { return "Ограничение снято — потяните список вниз, чтобы обновить." }
        return "Аккаунт ограничен модератором. Осталось \(ModerationText.remaining(left)). Отправка сообщений недоступна."
    }
}

// MARK: - Музыка в профиле (js/profile-music.js)

/// Свой трек: выбрать, заменить, убрать. Файл лежит открыто, как аватар.
struct ProfileMusicSection: View {
    @Environment(Services.self) private var services
    @Environment(ChatListStore.self) private var store
    @State private var picking = false
    @State private var busy = false
    @State private var message: String?

    static let maxBytes = 25 * 1024 * 1024
    static let extensions = ["mp3", "m4a", "aac", "ogg", "wav", "webm"]

    private var url: String { store.myProfile?.musicUrl ?? "" }
    private var title: String {
        let t = store.myProfile?.musicTitle ?? ""
        return t.isEmpty ? "Трек" : t
    }

    var body: some View {
        Section {
            HStack {
                Image(systemName: "music.note").foregroundStyle(Theme.accent)
                Text(url.isEmpty ? "Не выбрана" : title)
                    .foregroundStyle(url.isEmpty ? Theme.muted : Theme.onSurface)
                Spacer()
                if busy { ProgressView() }
            }
            Button(url.isEmpty ? "Выбрать" : "Заменить") { picking = true }.disabled(busy)
            if !url.isEmpty {
                Button("Убрать", role: .destructive) { save(url: "", title: "") }.disabled(busy)
            }
            if let message { Text(message).font(.system(size: 13)).foregroundStyle(Theme.muted) }
        } header: {
            Text("Музыка в профиле")
        } footer: {
            Text("Трек слышат все, кто откроет ваш профиль: mp3, m4a, aac, ogg, wav — до 25 МБ.")
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.audio]) { result in
            if case .success(let file) = result { Task { await upload(file) } }
        }
    }

    private func upload(_ file: URL) async {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        let ext = file.pathExtension.lowercased()
        guard Self.extensions.contains(ext) else {
            message = "Это не музыка: подойдут mp3, m4a, aac, ogg, wav"
            return
        }
        guard let data = try? Data(contentsOf: file) else {
            message = "Не удалось прочитать файл"
            return
        }
        guard data.count <= Self.maxBytes else {
            message = "Файл больше 25 МБ — выберите покороче или сожмите его"
            return
        }
        busy = true
        defer { busy = false }
        do {
            let mime = AttachmentRepository.mimeType(forExtension: ext)
            let uploaded = try await services.attachments.uploadPlain(data, fileName: "track.\(ext)", mimeType: mime)
            let name = String(file.deletingPathExtension().lastPathComponent.filter { $0 != "<" && $0 != ">" }.prefix(100))
            if await saveAsync(url: uploaded, title: name) { message = "Музыка в профиле обновлена" }
        } catch {
            message = errorText(error)
        }
    }

    private func save(url: String, title: String) {
        busy = true
        Task {
            defer { busy = false }
            _ = await saveAsync(url: url, title: title)
        }
    }

    private func saveAsync(url: String, title: String) async -> Bool {
        var request = ProfileUpdateRequest(username: services.me)
        request.musicUrl = url
        request.musicTitle = title
        do {
            try await services.api.updateProfile(request)
            await store.refresh()
            return true
        } catch {
            message = errorText(error)
            return false
        }
    }
}

/// Плеер трека в чужом профиле.
struct ProfileMusicPlayer: View {
    let url: String
    let title: String
    @Environment(Services.self) private var services
    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var progress: Double = 0
    @State private var duration: Double = 0
    @State private var observer: Any?

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Theme.accent))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 5) {
                Text(title.isEmpty ? "Трек" : title).font(.system(size: 15, weight: .medium)).lineLimit(1)
                ProgressView(value: progress).tint(Theme.accent)
                if duration > 0 {
                    Text("\(Self.time(progress * duration)) / \(Self.time(duration))")
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(.vertical, 4)
        .onDisappear(perform: stop)
    }

    static func time(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    private func toggle() {
        if let player {
            if playing { player.pause() } else { player.play() }
            playing.toggle()
            return
        }
        guard let address = services.api.absoluteURL(url) else { return }
        VoicePlayback.shared.stop()
        RoundPlayback.shared.stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let p = AVPlayer(url: address)
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { time in
            MainActor.assumeIsolated {
                guard let d = p.currentItem?.duration.seconds, d.isFinite, d > 0 else { return }
                duration = d
                progress = min(1, time.seconds / d)
                if progress >= 0.999 { playing = false }
            }
        }
        player = p
        p.play()
        playing = true
    }

    private func stop() {
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        player = nil
        playing = false
    }
}
