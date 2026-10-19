import Foundation
import UIKit

/// Свои стикеры (как js/stickers.js): добавленные наборы, окно набора и мастерская.
///
/// Набор общий, как аватар: картинки лежат открыто, сервер их видит; подпись
/// сообщения — эмодзи стикера — шифруется, как любой текст. Сервер принимает
/// стикером только картинку из какого-нибудь набора.
@MainActor
@Observable
final class StickerStore {
    nonisolated static let maxSide: CGFloat = 512
    nonisolated static let maxGifBytes = 1024 * 1024
    static let maxStickers = 120

    /// Добавленные себе наборы; nil — ещё не загружали.
    private(set) var sets: [StickerSetDto]?
    private(set) var error: String?

    @ObservationIgnored private let api: RstApi

    init(api: RstApi) {
        self.api = api
    }

    @discardableResult
    func load(force: Bool = false) async -> [StickerSetDto] {
        if let sets, !force { return sets }
        do {
            let result = try await api.stickerSets().sets ?? []
            sets = result
            error = nil
            return result
        } catch {
            self.error = errorText(error)
            return sets ?? []
        }
    }

    /// Сбросить кэш (после выхода из аккаунта).
    func clear() {
        sets = nil
    }

    func set(named name: String) async throws -> StickerSetDto {
        try await api.stickerSet(name: name)
    }

    func setName(forSticker fileUrl: String) async throws -> String {
        try await api.stickerLookup(fileUrl: fileUrl).name
    }

    func toggleInstall(_ set: StickerSetDto) async throws {
        try await api.installStickerSet(id: set.id, install: !(set.installed ?? false))
        await load(force: true)
    }

    func create(title: String, name: String) async throws -> StickerSetDto {
        let created = try await api.createStickerSet(title: title, name: name)
        await load(force: true)
        return created
    }

    func deleteSet(_ set: StickerSetDto) async throws {
        try await api.deleteStickerSet(id: set.id)
        await load(force: true)
    }

    func remove(_ sticker: StickerDto, from set: StickerSetDto) async throws {
        try await api.removeSticker(setId: set.id, stickerId: sticker.id)
        sets = nil
    }

    /// Картинка → стикер: ужать до 512 точек по длинной стороне (PNG, с
    /// прозрачностью); GIF — как есть, чтобы не потерять анимацию.
    func add(imageData: Data, emoji: String, to set: StickerSetDto) async throws -> StickerDto {
        let ready = try await Task.detached(priority: .userInitiated) { try Self.shrink(imageData) }.value
        let uploaded = try await api.upload(ready.data, fileName: "sticker.\(ready.ext)", mimeType: ready.mime)
        let clean = String(emoji.filter { !$0.isWhitespace && $0 != "<" && $0 != ">" }.prefix(16))
        let sticker = try await api.addSticker(setId: set.id, fileUrl: uploaded.fileUrl, emoji: clean)
        sets = nil
        return sticker
    }

    nonisolated static func shrink(_ data: Data) throws -> (data: Data, ext: String, mime: String) {
        if data.starts(with: Array("GIF8".utf8)) {
            guard data.count <= maxGifBytes else { throw CryptoError("GIF больше 1 МБ — возьмите поменьше") }
            return (data, "gif", "image/gif")
        }
        guard let image = UIImage(data: data) else { throw CryptoError("Не удалось обработать картинку") }
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height, 1))
        let target = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let png = UIGraphicsImageRenderer(size: target, format: format).pngData { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return (png, "png", "image/png")
    }

    /// Подпись стикера в тексте сообщения: по ней его видно в списке чатов и в ответах.
    nonisolated static func caption(_ emoji: String?) -> String {
        let e = (emoji ?? "").trimmingCharacters(in: .whitespaces)
        return e.isEmpty ? "Стикер" : e + " Стикер"
    }

    static func link(_ name: String) -> String {
        AppConfig.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat?stickers=" + name
    }

    nonisolated static func isValidName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9_]{3,32}$", options: .regularExpression) != nil
    }

    nonisolated static func countText(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return "\(n) стикер" }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return "\(n) стикера" }
        return "\(n) стикеров"
    }

    /// Имя набора для ссылки из названия: транслит, как в вебе.
    nonisolated static func suggestName(_ title: String) -> String {
        let map: [Character: String] = [
            "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh", "з": "z", "и": "i",
            "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t",
            "у": "u", "ф": "f", "х": "h", "ц": "c", "ч": "ch", "ш": "sh", "щ": "sch", "ъ": "", "ы": "y", "ь": "",
            "э": "e", "ю": "yu", "я": "ya",
        ]
        let raw = title.lowercased().map { map[$0] ?? String($0) }.joined()
        var out = ""
        var lastUnderscore = false
        for ch in raw {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch)
                lastUnderscore = false
            } else if !lastUnderscore {
                out.append("_")
                lastUnderscore = true
            }
        }
        return String(out.trimmingCharacters(in: CharacterSet(charactersIn: "_")).prefix(32))
    }
}
