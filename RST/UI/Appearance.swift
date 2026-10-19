import Network
import PhotosUI
import SwiftUI
import UIKit

/// Настройки чатов на этом устройстве (как в вебе — localStorage): цвет
/// оформления, размер текста, обои, быстрая реакция, превью ссылок,
/// автозагрузка и сжатие фото. На сервер не уходят — это оформление.
@Observable
final class ChatAppearance: @unchecked Sendable {
    static let shared = ChatAppearance()
    static let defaultAccent = "#f57c00"
    static let defaultTextSize: Double = 16

    /// 12 готовых цветов — как в вебе и Android (chat.html, data-accent).
    static let presets: [(hex: String, name: String)] = [
        ("#f57c00", "Оранжевый"), ("#2f7ff0", "Синий"), ("#0b9fd8", "Голубой"), ("#0d9488", "Бирюзовый"),
        ("#1fae6c", "Зелёный"), ("#5c9a1a", "Травяной"), ("#5b5bd6", "Индиго"), ("#8b5cf6", "Фиолетовый"),
        ("#e0457b", "Розовый"), ("#e5484d", "Красный"), ("#a65f35", "Коричневый"), ("#5f6b7a", "Графит"),
    ]

    /// Готовые обои — те же градиенты, что в js/wallpaper.js.
    static let wallpapers: [(UInt32, UInt32)] = [
        (0x2b1f47, 0x1c152e), (0x1b2838, 0x0b141d), (0x3d1b1b, 0x1d0909), (0x123524, 0x071a10),
        (0x2d2a1f, 0x16130b), (0xe8eaf6, 0xc5cae9), (0xfff3e0, 0xffe0b2),
    ]

    enum AutoDownload: String, CaseIterable {
        case always, wifi, never
        var title: String {
            switch self {
            case .always: return "Всегда"
            case .wifi: return "Только по Wi-Fi"
            case .never: return "Никогда"
            }
        }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    var accentHex: String { didSet { defaults.set(accentHex, forKey: "rst.accent") } }
    var textSize: Double { didSet { defaults.set(textSize, forKey: "rst.textSize") } }
    /// "" — без обоев; "preset:N"; "color:#rrggbb"; "image" — своя картинка.
    var wallpaper: String { didSet { defaults.set(wallpaper, forKey: "rst.wallpaper") } }
    var wallpaperDim: Double { didSet { defaults.set(wallpaperDim, forKey: "rst.wallpaperDim") } }
    var wallpaperBlur: Double { didSet { defaults.set(wallpaperBlur, forKey: "rst.wallpaperBlur") } }
    var quickReaction: String { didSet { defaults.set(quickReaction, forKey: "rst.quickReaction") } }
    var linkPreviews: Bool { didSet { defaults.set(linkPreviews, forKey: "rst.linkPreviews") } }
    var compressPhotos: Bool { didSet { defaults.set(compressPhotos, forKey: "rst.compressPhotos") } }
    var autoPhotos: AutoDownload { didSet { defaults.set(autoPhotos.rawValue, forKey: "rst.autoPhotos") } }
    /// Классический (как в вебе) или Liquid Glass.
    var design: DesignMode { didSet { defaults.set(design.rawValue, forKey: "rst.design") } }
    /// Картинка обоев поменялась — перечитать файл.
    private(set) var wallpaperVersion = 0
    /// Сеть дорогая (сотовая, режим экономии) — для «Только по Wi-Fi».
    private(set) var expensiveNetwork = false

    @ObservationIgnored private let monitor = NWPathMonitor()

    private init() {
        let d = UserDefaults.standard
        accentHex = d.string(forKey: "rst.accent") ?? Self.defaultAccent
        let size = d.double(forKey: "rst.textSize")
        textSize = size >= 12 && size <= 24 ? size : Self.defaultTextSize
        wallpaper = d.string(forKey: "rst.wallpaper") ?? ""
        wallpaperDim = d.double(forKey: "rst.wallpaperDim")
        wallpaperBlur = d.double(forKey: "rst.wallpaperBlur")
        quickReaction = d.string(forKey: "rst.quickReaction") ?? "❤️"
        linkPreviews = d.object(forKey: "rst.linkPreviews") as? Bool ?? true
        compressPhotos = d.object(forKey: "rst.compressPhotos") as? Bool ?? true
        autoPhotos = AutoDownload(rawValue: d.string(forKey: "rst.autoPhotos") ?? "") ?? .always
        design = DesignMode(rawValue: d.string(forKey: "rst.design") ?? "") ?? .classic
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive || path.isConstrained
            DispatchQueue.main.async { self?.expensiveNetwork = expensive }
        }
        monitor.start(queue: DispatchQueue(label: "rst.network"))
    }

    var accent: Color { Color(hex: AccentMath.parse(accentHex) ?? 0xF57C00) }
    var accentLight: Color { Color(hex: AccentMath.parse(AccentMath.lighter(accentHex)) ?? 0xFF7043) }
    var isDefaultAccent: Bool { accentHex.lowercased() == Self.defaultAccent }

    /// Фото грузятся сами — по настройке и типу сети.
    var shouldAutoLoadPhotos: Bool {
        switch autoPhotos {
        case .always: return true
        case .wifi: return !expensiveNetwork
        case .never: return false
        }
    }

    static var wallpaperFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("wallpaper.jpg")
    }

    func setWallpaperImage(_ image: UIImage) {
        let side = max(image.size.width, image.size.height)
        let scale = min(1, 2560 / max(side, 1))
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: target).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        guard let data = resized.jpegData(compressionQuality: 0.85) else { return }
        try? data.write(to: Self.wallpaperFile, options: .atomic)
        wallpaper = "image"
        wallpaperVersion += 1
    }
}

/// Цвет оформления: формулы — те же, что в js/accent-colors.js и Android
/// (data/AccentColors.kt), чтобы один цвет выглядел одинаково везде.
enum AccentMath {
    static func parse(_ hex: String) -> UInt32? {
        let t = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard t.count == 6, let n = UInt32(t, radix: 16) else { return nil }
        return n
    }

    static func rgb(_ hex: String) -> [Double]? {
        guard let n = parse(hex) else { return nil }
        return [Double((n >> 16) & 255), Double((n >> 8) & 255), Double(n & 255)]
    }

    static func hex(_ rgb: [Double]) -> String {
        "#" + rgb.map { String(format: "%02x", Int(min(255, max(0, $0.rounded())))) }.joined()
    }

    static func toHsl(_ c: [Double]) -> (Double, Double, Double) {
        let r = c[0] / 255, g = c[1] / 255, b = c[2] / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        let l = (mx + mn) / 2
        var h = 0.0, s = 0.0
        if d != 0 {
            s = d / (1 - abs(2 * l - 1))
            if mx == r {
                h = ((g - b) / d).truncatingRemainder(dividingBy: 6)
            } else if mx == g {
                h = (b - r) / d + 2
            } else {
                h = (r - g) / d + 4
            }
            h *= 60
            if h < 0 { h += 360 }
        }
        return (h, s, l)
    }

    static func fromHsl(_ h: Double, _ s: Double, _ l: Double) -> [Double] {
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let hh = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let base: [Double]
        switch hh {
        case ..<60: base = [c, x, 0]
        case ..<120: base = [x, c, 0]
        case ..<180: base = [0, c, x]
        case ..<240: base = [0, x, c]
        case ..<300: base = [x, 0, c]
        default: base = [c, 0, x]
        }
        return base.map { (($0 + m) * 255).rounded() }
    }

    static func luminance(_ c: [Double]) -> Double {
        func ch(_ v: Double) -> Double {
            let x = v / 255
            return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * ch(c[0]) + 0.7152 * ch(c[1]) + 0.0722 * ch(c[2])
    }

    /// «Светлее»: светлота HSL +0.08, не выше 0.75.
    static func lighter(_ hexValue: String) -> String {
        guard let c = rgb(hexValue) else { return hexValue }
        let (h, s, l) = toHsl(c)
        return hex(fromHsl(h, s, min(0.75, l + 0.08)))
    }

    /// Читаемый вариант: пока яркость выше 0.40, светлота −0.01.
    static func readable(_ hexValue: String) -> (hex: String, darkened: Bool) {
        guard var cur = rgb(hexValue) else { return (hexValue, false) }
        if luminance(cur) <= 0.40 { return (hex(cur), false) }
        let (h, s, l0) = toHsl(cur)
        var l = l0
        while luminance(cur) > 0.40 && l > 0 {
            l = max(0, l - 0.01)
            cur = fromHsl(h, s, l)
        }
        return (hex(cur), true)
    }
}

// MARK: - Обои чата

/// Фон переписки: обои, свой цвет или картинка; затемнение и размытие.
struct ChatWallpaper: View {
    private var look: ChatAppearance { ChatAppearance.shared }
    @State private var image: UIImage?
    @State private var loadedVersion = -1

    var body: some View {
        ZStack {
            AppBackground()
            Group {
                if look.wallpaper.hasPrefix("preset:"), let i = Int(look.wallpaper.dropFirst(7)), ChatAppearance.wallpapers.indices.contains(i) {
                    let pair = ChatAppearance.wallpapers[i]
                    LinearGradient(colors: [Color(hex: pair.0), Color(hex: pair.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
                } else if look.wallpaper.hasPrefix("color:"), let n = AccentMath.parse(String(look.wallpaper.dropFirst(6))) {
                    Color(hex: n)
                } else if look.wallpaper == "image", let image {
                    GeometryReader { geo in
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height).clipped()
                    }
                }
            }
            .blur(radius: look.wallpaperBlur)
            if !look.wallpaper.isEmpty && look.wallpaperDim > 0 {
                Color.black.opacity(look.wallpaperDim)
            }
        }
        .ignoresSafeArea()
        .task(id: "\(look.wallpaper)#\(look.wallpaperVersion)") {
            guard look.wallpaper == "image", loadedVersion != look.wallpaperVersion || image == nil else { return }
            loadedVersion = look.wallpaperVersion
            let path = ChatAppearance.wallpaperFile.path
            image = await Task.detached { UIImage(contentsOfFile: path) }.value
        }
    }
}

// MARK: - Настройки чатов

struct ChatSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var customColor = Color.orange
    @State private var darkenedNote = false
    @State private var wallpaperItem: PhotosPickerItem?
    @State private var reactionPicker = false
    @State private var look = ChatAppearance.shared

    var body: some View {
        Form {
            Section {
                Picker("Дизайн", selection: $look.design) {
                    ForEach(DesignMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Дизайн")
            } footer: {
                Text(ChatAppearance.nativeGlass
                     ? "«Классический» — как в веб-версии. «Liquid Glass» — оформление iOS 26: стеклянные панели, кнопки и сообщения."
                     : "«Классический» — как в веб-версии. «Liquid Glass» — стеклянное оформление iOS 26; на этой версии iOS — приближённо, полупрозрачным материалом.")
            }

            Section("Тема") {
                Picker("Тема", selection: Binding(get: {
                    switch app.colorScheme {
                    case .light?: return "light"
                    case nil: return "system"
                    default: return "dark"
                    }
                }, set: { app.setTheme($0) })) {
                    Text("Тёмная").tag("dark")
                    Text("Светлая").tag("light")
                    Text("Как в системе").tag("system")
                }
                .pickerStyle(.segmented)
            }

            Section("Цвет оформления") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                    ForEach(ChatAppearance.presets, id: \.hex) { preset in
                        Button {
                            look.accentHex = preset.hex
                            darkenedNote = false
                        } label: {
                            Circle().fill(Color(hex: AccentMath.parse(preset.hex) ?? 0))
                                .frame(width: 36, height: 36)
                                .overlay(Circle().stroke(Color.white, lineWidth: look.accentHex.lowercased() == preset.hex ? 3 : 0))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(preset.name)
                    }
                }
                .padding(.vertical, 4)
                ColorPicker("Свой цвет", selection: Binding(get: { customColor }, set: { color in
                    customColor = color
                    applyCustom(color)
                }), supportsOpacity: false)
                if darkenedNote {
                    Text("Чуть темнее выбранного — чтобы текст на кнопках читался").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }

            Section {
                HStack {
                    Text("Размер текста")
                    Spacer()
                    Text("\(Int(look.textSize))").foregroundStyle(Theme.accent).fontWeight(.semibold)
                }
                Slider(value: $look.textSize, in: 12...24, step: 1)
                Text("Так выглядит сообщение в переписке.")
                    .font(.system(size: look.textSize))
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.otherBubble))
            }

            Section("Обои") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        wallpaperTile(selected: look.wallpaper.isEmpty, action: { look.wallpaper = "" }) {
                            ZStack {
                                AppBackground()
                                Image(systemName: "nosign").foregroundStyle(Theme.muted)
                            }
                        }
                        ForEach(Array(ChatAppearance.wallpapers.enumerated()), id: \.offset) { i, pair in
                            wallpaperTile(selected: look.wallpaper == "preset:\(i)", action: { look.wallpaper = "preset:\(i)" }) {
                                LinearGradient(colors: [Color(hex: pair.0), Color(hex: pair.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                ColorPicker("Свой цвет фона", selection: Binding(get: { Color.black }, set: { color in
                    look.wallpaper = "color:" + Self.hex(of: color)
                }), supportsOpacity: false)
                PhotosPicker(selection: $wallpaperItem, matching: .images) {
                    Label(look.wallpaper == "image" ? "Заменить картинку" : "Своя картинка", systemImage: "photo")
                }
                if !look.wallpaper.isEmpty {
                    VStack(alignment: .leading) {
                        Text("Затемнение")
                        Slider(value: $look.wallpaperDim, in: 0...0.7)
                        Text("Размытие")
                        Slider(value: $look.wallpaperBlur, in: 0...20)
                    }
                }
            }

            Section {
                Button { reactionPicker = true } label: {
                    HStack {
                        Text("Быстрая реакция").foregroundStyle(Theme.onSurface)
                        Spacer()
                        Text(look.quickReaction).font(.system(size: 22))
                    }
                }
                Toggle("Превью ссылок", isOn: $look.linkPreviews)
            } footer: {
                Text("Быстрая реакция ставится двойным нажатием на сообщение.")
            }
        }
        .navigationTitle("Настройки чатов")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: wallpaperItem) { _, item in
            guard let item else { return }
            wallpaperItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    look.setWallpaperImage(image)
                }
            }
        }
        .sheet(isPresented: $reactionPicker) {
            EmojiPickerSheet { look.quickReaction = $0 }
        }
    }

    private func wallpaperTile<C: View>(selected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> C) -> some View {
        Button(action: action) {
            content()
                .frame(width: 54, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Theme.accent : Theme.outline, lineWidth: selected ? 3 : 1))
        }
        .buttonStyle(.plain)
    }

    private func applyCustom(_ color: Color) {
        let readable = AccentMath.readable(Self.hex(of: color))
        look.accentHex = readable.hex
        darkenedNote = readable.darkened
    }

    static func hex(of color: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return AccentMath.hex([Double(r * 255), Double(g * 255), Double(b * 255)])
    }
}

// MARK: - Данные и память

struct DataSettingsView: View {
    @Environment(Services.self) private var services
    @State private var cacheBytes: Int64?
    @State private var confirmClear = false
    @State private var look = ChatAppearance.shared
    @State private var exporting = false
    @State private var exported: ExportedFile?
    @State private var exportError: String?

    var body: some View {
        Form {
            Section {
                Picker("Загружать фото сами", selection: $look.autoPhotos) {
                    ForEach(ChatAppearance.AutoDownload.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Автозагрузка")
            } footer: {
                Text("Видео, кружки и файлы загружаются по нажатию. Что не загрузилось само, загрузится по нажатию.")
            }
            Section {
                Toggle("Сжимать фото при отправке", isOn: $look.compressPhotos)
            } footer: {
                Text("Сжатое фото — до 2560 точек по длинной стороне, JPEG. Выбранное как файл не сжимается никогда.")
            }
            Section {
                HStack {
                    Text("Расшифрованные файлы")
                    Spacer()
                    Text(cacheBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                        .foregroundStyle(Theme.muted)
                }
                Button("Очистить", role: .destructive) { confirmClear = true }
            } header: {
                Text("Память устройства")
            } footer: {
                Text("Файлы снова скачаются и расшифруются, когда понадобятся. Переписка не пострадает.")
            }
            Section {
                Button(action: exportAll) {
                    HStack {
                        Text("Выгрузить все переписки")
                        Spacer()
                        if exporting { ProgressView() }
                    }
                }
                .disabled(exporting)
                if let exportError { Text(exportError).foregroundStyle(Theme.danger) }
            } footer: {
                Text("Один текстовый файл со всеми чатами — копия на всякий случай. Расшифровка на этом устройстве; вложения — только названиями.")
            }
        }
        .sheet(item: $exported) { ShareSheet(items: [$0.url]) }
        .navigationTitle("Данные и память")
        .navigationBarTitleDisplayMode(.inline)
        .task { cacheBytes = await Self.size(of: AttachmentRepository.tempDir) }
        .confirmationDialog("Стереть расшифрованные файлы с устройства?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Очистить", role: .destructive) {
                services.attachments.clear()
                cacheBytes = 0
            }
        }
    }

    private func exportAll() {
        exporting = true
        exportError = nil
        Task {
            defer { exporting = false }
            do {
                exported = ExportedFile(url: try await ChatExport.exportAll(services: services))
            } catch {
                exportError = errorText(error)
            }
        }
    }

    static func size(of dir: URL) async -> Int64 {
        await Task.detached {
            var total: Int64 = 0
            let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
            if let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) {
                while let url = walker.nextObject() as? URL {
                    let values = try? url.resourceValues(forKeys: Set(keys))
                    if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
                }
            }
            return total
        }.value
    }
}
