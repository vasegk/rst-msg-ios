import SwiftUI

/// Текст сообщения с разметкой: блоки абзацев, цитат и кода.
struct MessageTextView: View {
    let text: String
    var isMine = false
    var fontSize: CGFloat = 16
    @State private var spoilersRevealed = false

    private var blocks: [TextFormat.Block] { TextFormat.parse(text) }

    var body: some View {
        let parsed = blocks
        let spoiler = parsed.contains(where: Self.hasSpoiler)
        let jumbo = JumboEmoji.isJumbo(text)
        let content = VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(parsed.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let rich):
                    Text(attributed(rich, size: jumbo ? 44 : fontSize))
                case .quote(let rich):
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(isMine ? Color.white : Theme.accent)
                            .frame(width: 3)
                        Text(attributed(rich, size: fontSize - 1))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                case .code(let code):
                    Text(code)
                        .font(.system(size: fontSize - 2, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(isMine ? 0.18 : 0.25), in: RoundedRectangle(cornerRadius: 8))
                        .textSelection(.enabled)
                }
            }
        }
        if spoiler {
            content.onTapGesture { withAnimation { spoilersRevealed.toggle() } }
        } else {
            content
        }
    }

    private static func hasSpoiler(_ block: TextFormat.Block) -> Bool {
        switch block {
        case .paragraph(let r), .quote(let r): return r.has(.spoiler)
        case .code: return false
        }
    }

    private func attributed(_ rich: TextFormat.Rich, size: CGFloat) -> AttributedString {
        var out = AttributedString()
        for run in rich.runs {
            var piece = AttributedString(run.text)
            let s = run.styles
            var font = Font.system(size: size)
            if s.contains(.code) { font = .system(size: size - 1, design: .monospaced) }
            if s.contains(.bold) { font = font.bold() }
            if s.contains(.italic) { font = font.italic() }
            piece.font = font
            if s.contains(.underline) { piece.underlineStyle = .single }
            if s.contains(.strike) { piece.strikethroughStyle = .single }
            if s.contains(.code) { piece.backgroundColor = Color.black.opacity(0.2) }
            if s.contains(.spoiler) && !spoilersRevealed {
                piece = AttributedString(String(repeating: "▒", count: max(3, min(run.text.count, 24))))
                piece.font = font
                piece.foregroundColor = isMine ? Color.white.opacity(0.7) : Theme.muted
            }
            if s.contains(.link), let target = run.data, !(s.contains(.spoiler) && !spoilersRevealed) {
                // Слова ссылки не совпадают с адресом — спросить перед открытием
                if TextFormat.linkNeedsConfirm(label: run.text, url: target) {
                    var comps = URLComponents()
                    comps.scheme = "rstmsg"
                    comps.host = "confirm"
                    comps.queryItems = [URLQueryItem(name: "u", value: target)]
                    piece.link = comps.url
                } else {
                    piece.link = URL(string: target)
                }
                piece.foregroundColor = isMine ? .white : Theme.accent
                piece.underlineStyle = .single
            }
            if s.contains(.mention), let name = run.data {
                piece.link = URL(string: "rstmsg://mention/\(name)")
                piece.foregroundColor = isMine ? .white : Theme.accent
                if isMine { piece.font = font.bold() }
            }
            out += piece
        }
        return out
    }
}

/// Сообщение из одних эмодзи (до трёх) рисуется крупно.
enum JumboEmoji {
    static func isJumbo(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 3 else { return false }
        return trimmed.allSatisfy { ch in
            ch.unicodeScalars.contains { $0.properties.isEmojiPresentation } ||
                (ch.unicodeScalars.first?.properties.isEmoji == true && ch.unicodeScalars.count > 1)
        }
    }
}
