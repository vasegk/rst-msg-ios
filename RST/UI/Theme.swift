import SwiftUI
import UIKit

/// Палитра веб-клиента (css/variables.css). Цвета зависят от темы.
enum Theme {
    /// Цвет оформления — из настроек чатов (12 готовых или свой).
    static var accent: Color { ChatAppearance.shared.accent }
    static var accentLight: Color {
        ChatAppearance.shared.isDefaultAccent ? Color(hex: 0xE65100) : ChatAppearance.shared.accentLight
    }
    static let danger = Color(hex: 0xFF4A5A)
    static let success = Color(hex: 0x00E676)
    static let verified = Color(hex: 0x3897F0)

    static let background = dynamic(dark: 0x050505, light: 0xF5F5F7)
    static let surface = dynamic(dark: 0x0F0F0F, light: 0xFFFFFF)
    static let input = dynamic(dark: 0x141414, light: 0xE9E9EB)
    static let card = dynamic(dark: 0x121214, light: 0xFFFFFF)
    static let otherBubble = dynamic(dark: 0x191919, light: 0xFCFCFD)
    static let onSurface = dynamic(dark: 0xF0F0F0, light: 0x1D1D1F)
    static let muted = dynamic(dark: 0x9BA0A6, light: 0x6E6E73)
    static let outline = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.07) : UIColor(white: 0, alpha: 0.06) })

    /// Своё сообщение — градиент 135° (#E65100 → #FF7043 в тёмной теме);
    /// со своим цветом оформления — от него к «светлее».
    static var ownBubble: LinearGradient {
        let look = ChatAppearance.shared
        if look.isDefaultAccent { return defaultOwnBubble }
        return LinearGradient(colors: [look.accent, look.accentLight], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    private static let defaultOwnBubble = LinearGradient(
        colors: [dynamic(dark: 0xE65100, light: 0xF57C00), dynamic(dark: 0xFF7043, light: 0xFF9800)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    /// Градиенты аватаров без фото — набор и правило выбора как в вебе
    /// (hash * 31 + код символа UTF-16, беззнаковое 32-битное).
    static let avatarGradients: [(Color, Color)] = [
        (Color(hex: 0xFF9A3C), Color(hex: 0xE8590C)),
        (Color(hex: 0xF6B73C), Color(hex: 0xD9822B)),
        (Color(hex: 0xEF6F6C), Color(hex: 0xC2410C)),
        (Color(hex: 0x4FB0A5), Color(hex: 0x2F7F78)),
        (Color(hex: 0x6F8FD8), Color(hex: 0x4A63B8)),
        (Color(hex: 0xA07AD6), Color(hex: 0x7454B0)),
    ]

    static func avatarGradient(for name: String) -> (Color, Color) {
        var hash: UInt64 = 0
        for unit in name.utf16 { hash = (hash &* 31 &+ UInt64(unit)) & 0xFFFF_FFFF }
        return avatarGradients[Int(hash % UInt64(avatarGradients.count))]
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

/// Почти чёрный фон с двумя размытыми цветными пятнами — как в вебе.
struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.background
                if scheme == .dark {
                    Circle()
                        .fill(Color(red: 245 / 255, green: 124 / 255, blue: 0).opacity(0.25))
                        .frame(width: geo.size.width * 0.8, height: geo.size.width * 0.8)
                        .blur(radius: 90)
                        .offset(x: -geo.size.width * 0.35, y: -geo.size.height * 0.35)
                    Circle()
                        .fill(Color(red: 0, green: 230 / 255, blue: 118 / 255).opacity(0.15))
                        .frame(width: geo.size.width * 0.7, height: geo.size.width * 0.7)
                        .blur(radius: 90)
                        .offset(x: geo.size.width * 0.35, y: geo.size.height * 0.35)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }
}

/// Аватар: фото с сервера или буква на градиенте.
struct AvatarView: View {
    let name: String
    let url: String?
    var size: CGFloat = 46
    var online = false
    var isSaved = false

    @Environment(Services.self) private var services

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if isSaved {
                    ZStack {
                        Circle().fill(LinearGradient(colors: [Theme.accent, Color(hex: 0xFF7043)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: size * 0.4, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                } else if let address = services.api.absoluteURL(url) {
                    AsyncImage(url: address, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            letter
                        }
                    }
                } else {
                    letter
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())

            if online {
                Circle()
                    .fill(Theme.success)
                    .frame(width: size * 0.26, height: size * 0.26)
                    .overlay(Circle().stroke(Theme.background, lineWidth: 2))
            }
        }
    }

    private var letter: some View {
        let colors = Theme.avatarGradient(for: name)
        return ZStack {
            Circle().fill(LinearGradient(colors: [colors.0, colors.1], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(String(name.trimmingCharacters(in: .whitespaces).first.map { String($0) } ?? "?").uppercased())
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

/// Синяя галочка подтверждения у имени.
struct VerifiedBadge: View {
    var size: CGFloat = 14
    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: size))
            .foregroundStyle(Theme.verified)
            .accessibilityLabel("Подтверждённый аккаунт")
    }
}

/// Поле ввода в стиле веба: скругление 24, мягкая подложка.
struct RstTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .rstSurface(RoundedRectangle(cornerRadius: 14), classic: Theme.input)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.outline))
    }
}

/// Основная кнопка: акцентная, скругление 12.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .rstSurface(RoundedRectangle(cornerRadius: ChatAppearance.shared.isGlass ? 24 : 12),
                        classic: LinearGradient(colors: [Theme.accentLight, Theme.accent], startPoint: .leading, endPoint: .trailing)
                            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4),
                        tint: Theme.accent.opacity(isEnabled ? 0.9 : 0.4), interactive: true)
    }
}

/// Сообщение об ошибке человеческим языком.
func errorText(_ error: Error) -> String {
    if let api = error as? ApiError { return api.localizedDescription }
    if let crypto = error as? CryptoError { return crypto.message }
    if error is CancellationError { return "" }
    return error.localizedDescription
}

enum TimeFormat {
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayMonth: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM"
        return f
    }()

    private static let full: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM yyyy"
        return f
    }()

    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EE"
        return f
    }()

    static func clock(_ date: Date?) -> String { date.map { time.string(from: $0) } ?? "" }

    /// Время в списке чатов: сегодня — часы, на неделе — день, раньше — дата.
    static func listTime(_ date: Date?) -> String {
        guard let date else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return time.string(from: date) }
        if let days = cal.dateComponents([.day], from: date, to: Date()).day, days < 7 { return weekday.string(from: date) }
        return dayMonth.string(from: date)
    }

    static func dayHeader(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Сегодня" }
        if cal.isDateInYesterday(date) { return "Вчера" }
        if cal.component(.year, from: date) == cal.component(.year, from: Date()) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ru_RU")
            f.dateFormat = "d MMMM"
            return f.string(from: date)
        }
        return full.string(from: date)
    }

    /// «был(а) в сети …»
    static func lastSeen(_ raw: String?) -> String {
        guard let date = ServerTime.parse(raw) else { return "не в сети" }
        let cal = Calendar.current
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return "был(а) только что" }
        if minutes < 60 { return "был(а) \(minutes) мин назад" }
        if cal.isDateInToday(date) { return "был(а) сегодня в \(time.string(from: date))" }
        if cal.isDateInYesterday(date) { return "был(а) вчера в \(time.string(from: date))" }
        return "был(а) \(dayMonth.string(from: date)) в \(time.string(from: date))"
    }
}
