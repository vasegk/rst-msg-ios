import Foundation
import SwiftUI
import UIKit

/// Экспорт переписки текстом (как js/chat-export.js). Переписка
/// зашифрована, поэтому экспорт целиком на устройстве: история страницами,
/// расшифровка здесь же, файл .txt. Вложения в файл не входят — только названия.
enum ChatExport {
    static let page = 500
    static let maxPages = 400

    static func when(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "dd.MM.yyyy, HH:mm"
        return f.string(from: date)
    }

    private static func indent(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
    }

    /// Одна запись экспорта.
    static func format(_ m: ChatMessage, name: (String) -> String) -> String {
        var lines = ["[\(when(m.createdAt))] \(name(m.sender)):"]
        if let from = m.forwardedFrom { lines.append("    (переслано от \(from))") }
        if let reply = m.reply, !reply.sender.isEmpty {
            let quote = String((reply.text.split(separator: "\n").first ?? "").prefix(80))
            lines.append("    ↪ в ответ \(name(reply.sender)): «\(quote)»")
        }
        if let poll = m.poll {
            var text = "📊 " + poll.question
            for (i, option) in poll.options.enumerated() {
                let count = i < poll.state.counts.count ? poll.state.counts[i] : 0
                text += "\n- \(option) — \(count)"
            }
            lines.append(indent(text))
        } else {
            if let a = m.attachment {
                lines.append("    [вложение\(a.fileName.isEmpty ? "" : ": " + a.fileName)]")
            } else if m.stickerUrl != nil {
                lines.append("    [стикер]")
            }
            let text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty && !(m.attachment != nil && text == m.attachment?.fileName) { lines.append(indent(text)) }
        }
        if m.isEdited { lines.append("    (изменено)") }
        return lines.joined(separator: "\n")
    }

    static func messagesWord(_ n: Int) -> String {
        let d = n % 10, c = n % 100
        if d == 1 && c != 11 { return "сообщение" }
        if (2...4).contains(d) && !(12...14).contains(c) { return "сообщения" }
        return "сообщений"
    }

    static func safeFilePart(_ text: String) -> String {
        let bad = CharacterSet(charactersIn: "\\/:*?\"<>|").union(.whitespacesAndNewlines)
        let cleaned = text.unicodeScalars.map { bad.contains($0) ? "_" : String($0) }.joined()
        let collapsed = cleaned.replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
        let result = String(collapsed.prefix(40))
        return result.isEmpty ? "chat" : result
    }

    /// Вся история чата, расшифрованная и по порядку; файл во временной папке.
    @MainActor
    static func export(chatId: String, title: String, services: Services) async throws -> URL {
        var pages: [[ChatMessage]] = []
        var before: Int64?
        for _ in 0..<maxPages {
            let history = try await services.messages.history(chatId, beforeId: before, limit: page)
            if !history.messages.isEmpty { pages.insert(history.messages, at: 0) }
            guard history.hasMore, let first = history.oldestId ?? history.messages.first?.id else { break }
            before = first
        }
        // Не расшифровалось или служебное — в файле бесполезно
        let messages = pages.flatMap { $0 }.filter { !$0.undecryptable && !$0.isSystem }
        let me = services.me
        let myName = services.chats.myProfile?.displayName ?? me
        let chats = services.chats
        let name: (String) -> String = { $0 == me ? myName : chats.displayName($0) }
        let header = [
            "Переписка: \(title)",
            "Выгружено: \(when(Date())) пользователем \(myName)",
            "Сообщений: \(messages.count)",
            "Вложения в файл не входят - только их названия.",
            "",
        ].joined(separator: "\n")
        let body = messages.map { format($0, name: name) }.joined(separator: "\n\n")
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let file = "RST_\(safeFilePart(title))_\(day.string(from: Date())).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(file)
        // BOM — чтобы Блокнот в Windows узнал UTF-8
        try Data(("\u{FEFF}" + header + "\n" + body + "\n").utf8).write(to: url, options: .atomic)
        return url
    }
}

/// Системное окно «Поделиться» для файла.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ExportedFile: Identifiable {
    let id = UUID()
    let url: URL
}
