import Foundation

/// Разметка текста сообщения — тем же синтаксисом, что в вебе (js/text-format.js):
///
///   **жирный**   __курсив__   ++подчёркнутый++   ~~зачёркнутый~~
///   ||спойлер||   `код`   ```блок кода```   > цитата в начале строки
///   [текст](https://адрес) — ссылка под словами
///
/// Порядок разбора тот же, что в вебе, чтобы одно сообщение выглядело одинаково:
///   1. код вынимается первым — внутри него разметка не действует;
///   2. ссылки и упоминания вынимаются следом — иначе __init__ в адресе
///      стал бы курсивом и сломал ссылку;
///   3. стили накладываются на оставшийся текст;
///   4. строки с «> » в начале собираются в цитаты.
///
/// Результат — не HTML, а блоки с кусками текста и их стилями.
enum TextFormat {

    enum Style: Int, CaseIterable, Hashable {
        case bold, italic, underline, strike, spoiler, code, link, mention
    }

    struct Run: Equatable {
        var text: String
        var styles: Set<Style>
        /// Адрес ссылки или имя упомянутого.
        var data: String?
    }

    struct Rich: Equatable {
        var runs: [Run]
        var text: String { runs.map(\.text).joined() }
        func has(_ style: Style) -> Bool { runs.contains { $0.styles.contains(style) } }
    }

    enum Block: Equatable {
        case paragraph(Rich)
        case quote(Rich)
        case code(String)
    }

    // MARK: - Метки

    // Метки вынутых кусков и границ стилей — символы, которых в тексте
    // сообщения быть не может: нулевой и область для частного использования
    // вычищаются первым шагом.
    private static let mark: Character = "\u{0}"
    private static let openBase: UInt32 = 0xE000
    private static let closeBase: UInt32 = 0xE100

    private enum Stashed {
        case inlineCode(String)
        case blockCode(String)
        case link(labelTagged: String, url: String)
        case bareLink(String)
        case mention(String)
    }

    private static func re(_ pattern: String) -> NSRegularExpression {
        // Шаблоны постоянные: ошибка в них — ошибка программиста.
        try! NSRegularExpression(pattern: pattern)
    }

    private static let privateRE = re(#"[\u0000-]"#)
    private static let styleRules: [(NSRegularExpression, Style)] = [
        // Внутри маркера не может стоять пробел с краю: «2 ** 3 ** 4» — не жирный
        (re(#"\*\*(?=\S)([\s\S]*?\S)\*\*"#), .bold),
        (re(#"__(?=\S)([\s\S]*?\S)__"#), .italic),
        // «C++ и C++» не задевает: после первого ++ стоит пробел
        (re(#"\+\+(?=\S)([\s\S]*?\S)\+\+"#), .underline),
        (re(#"~~(?=\S)([\s\S]*?\S)~~"#), .strike),
        (re(#"\|\|(?=\S)([\s\S]*?\S)\|\|"#), .spoiler),
    ]
    private static let codeBlockRE = re(#"```(?:[A-Za-z0-9_+#.-]{1,20}\n)?([\s\S]*?)```"#)
    private static let inlineCodeRE = re(#"`([^`\n]+)`"#)
    /// Адрес — только http(s): javascript: и прочие схемы ссылкой не становятся.
    private static let labeledLinkRE = re(#"\[([^\]\n]+)\]\((https?://[^\s()<>\u0000]+)\)"#)
    private static let bareLinkRE = re(#"https?://[^\s<>\u0000]+"#)
    /// @ник латиницей и @все/@онлайн (без продолжения буквой — «@всем» не упоминание).
    private static let mentionRE = re(#"(^|\s)@([a-zA-Z0-9_-]+|все(?![\p{L}\p{N}_-])|онлайн(?![\p{L}\p{N}_-]))"#)
    private static let stashRE = re(#"\u0000(\d+)\u0000"#)

    // MARK: - Разбор

    static func parse(_ raw: String?) -> [Block] {
        guard var s = raw, !s.isEmpty else { return [] }
        s = replace(s, privateRE) { _ in "" }

        var stash: [Stashed] = []
        func keep(_ item: Stashed) -> String {
            stash.append(item)
            return "\u{0}\(stash.count - 1)\u{0}"
        }

        // 1. Код. Имя языка на первой строке блока отбрасываем.
        s = replace(s, codeBlockRE) { g in keep(.blockCode(g[1].trimmingCharacters(in: CharacterSet(charactersIn: "\n")))) }
        s = replace(s, inlineCodeRE) { g in keep(.inlineCode(g[1])) }

        // 2. Ссылка под словами — первой, иначе её адрес стал бы отдельной
        //    ссылкой. Стили к словам применяем сразу: дальше они спрятаны.
        s = replace(s, labeledLinkRE) { g in keep(.link(labelTagged: applyStyles(g[1]), url: g[2])) }
        s = replace(s, bareLinkRE) { g in
            let (url, tail) = splitUrlTail(g[0])
            return keep(.bareLink(url)) + tail
        }
        s = replace(s, mentionRE) { g in g[1] + keep(.mention(g[2])) }

        // 3. Стили
        s = applyStyles(s)

        // 4. Цитаты: подряд идущие строки с «> » в начале — один блок
        var blocks: [Block] = []
        var paragraph: [String] = []
        var quote: [String] = []

        func flushQuote() {
            guard !quote.isEmpty else { return }
            emitTagged(quote.joined(separator: "\n"), stash: stash, into: &blocks, asQuote: true)
            quote.removeAll()
        }
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            emitTagged(paragraph.joined(separator: "\n"), stash: stash, into: &blocks, asQuote: false)
            paragraph.removeAll()
        }

        for line in s.components(separatedBy: "\n") {
            if line.hasPrefix(">") {
                flushParagraph()
                var body = String(line.dropFirst())
                if body.hasPrefix(" ") { body.removeFirst() }
                quote.append(body)
            } else {
                flushQuote()
                paragraph.append(line)
            }
        }
        flushQuote()
        flushParagraph()
        return blocks.filter {
            if case .paragraph(let rich) = $0 { return !rich.runs.isEmpty }
            return true
        }
    }

    /// Текст без разметки — для превью в списке чатов, закрепа и уведомлений.
    /// Спойлер не раскрываем и здесь.
    static func strip(_ raw: String?) -> String {
        guard var s = raw, !s.isEmpty else { return "" }
        s = replace(s, codeBlockRE) { $0[1] }
        s = replace(s, inlineCodeRE) { $0[1] }
        s = replace(s, re(#"\[([^\]\n]+)\]\((https?://[^\s()<>]+)\)"#)) { $0[1] }
        s = replace(s, re(#"\|\|(?=\S)([\s\S]*?\S)\|\|"#)) { _ in "▒▒▒▒" }
        s = replace(s, re(#"\*\*(?=\S)([\s\S]*?\S)\*\*"#)) { $0[1] }
        s = replace(s, re(#"__(?=\S)([\s\S]*?\S)__"#)) { $0[1] }
        s = replace(s, re(#"\+\+(?=\S)([\s\S]*?\S)\+\+"#)) { $0[1] }
        s = replace(s, re(#"~~(?=\S)([\s\S]*?\S)~~"#)) { $0[1] }
        s = replace(s, (try? NSRegularExpression(pattern: #"^> ?"#, options: .anchorsMatchLines)) ?? re("^$")) { _ in "" }
        return s
    }

    /// Слова ссылки совпадают с адресом? Если нет — перед открытием нужно
    /// спросить «Открыть ссылку?» с настоящим адресом.
    static func linkNeedsConfirm(label: String, url: String) -> Bool {
        label.trimmingCharacters(in: .whitespaces) != url
    }

    // MARK: - Внутреннее

    private static func applyStyles(_ input: String) -> String {
        var s = input
        for (regex, style) in styleRules {
            s = replace(s, regex) { g in open(style) + g[1] + close(style) }
        }
        return s
    }

    private static func open(_ style: Style) -> String {
        String(Character(Unicode.Scalar(openBase + UInt32(style.rawValue))!))
    }

    private static func close(_ style: Style) -> String {
        String(Character(Unicode.Scalar(closeBase + UInt32(style.rawValue))!))
    }

    /// Отделить от адреса то, что к нему прилипло: точку в конце предложения,
    /// маркер разметки. Скобку — только если открывающей в адресе нет.
    private static func splitUrlTail(_ match: String) -> (String, String) {
        var url = match
        var tail = ""
        while let last = url.last {
            if ".,:!?*_~|".contains(last) || (last == ")" && !url.contains("(")) {
                tail = String(last) + tail
                url.removeLast()
            } else {
                break
            }
        }
        return (url, tail)
    }

    /// Регулярная замена с доступом к группам (группа 0 — всё совпадение).
    static func replace(_ s: String, _ regex: NSRegularExpression, _ transform: ([String]) -> String) -> String {
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var result = ""
        var last = 0
        for m in matches {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var groups: [String] = []
            for i in 0..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            result += transform(groups)
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    private enum Token {
        case char(Character)
        case open(Style)
        case close(Style)
        case stash(Int)
    }

    private static func tokenize(_ tagged: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(tagged)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == mark {
                var j = i + 1
                var digits = ""
                while j < chars.count, let d = chars[j].wholeNumberValue, chars[j].isASCII {
                    digits.append(String(d))
                    j += 1
                }
                if j < chars.count, chars[j] == mark, let index = Int(digits) {
                    tokens.append(.stash(index))
                    i = j + 1
                    continue
                }
            }
            if let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 {
                let v = scalar.value
                if v >= openBase, v < openBase + UInt32(Style.allCases.count), let st = Style(rawValue: Int(v - openBase)) {
                    tokens.append(.open(st)); i += 1; continue
                }
                if v >= closeBase, v < closeBase + UInt32(Style.allCases.count), let st = Style(rawValue: Int(v - closeBase)) {
                    tokens.append(.close(st)); i += 1; continue
                }
            }
            tokens.append(.char(ch))
            i += 1
        }
        return tokens
    }

    /// Незакрытые стили по конец строки не тянем: оставляем только пары.
    private static func pairedOnly(_ tokens: [Token]) -> [Token] {
        var keep = [Bool](repeating: true, count: tokens.count)
        var openStack: [(Style, Int)] = []
        for (i, t) in tokens.enumerated() {
            switch t {
            case .open(let s):
                openStack.append((s, i))
                keep[i] = false
            case .close(let s):
                if let idx = openStack.lastIndex(where: { $0.0 == s }) {
                    keep[openStack[idx].1] = true
                    openStack.remove(at: idx)
                } else {
                    keep[i] = false
                }
            default:
                break
            }
        }
        return tokens.enumerated().filter { keep[$0.offset] }.map(\.element)
    }

    private final class RichBuilder {
        var runs: [Run] = []
        var open: [Style] = []

        var isEmpty: Bool { runs.isEmpty }

        func append(_ text: String, extra: Style? = nil, data: String? = nil) {
            guard !text.isEmpty else { return }
            var styles = Set(open)
            if let extra { styles.insert(extra) }
            if data == nil, let lastRun = runs.last, lastRun.styles == styles, lastRun.data == nil {
                runs[runs.count - 1].text += text
            } else {
                runs.append(Run(text: text, styles: styles, data: data))
            }
        }

        func push(_ s: Style) { open.append(s) }

        func pop(_ s: Style) {
            if let idx = open.lastIndex(of: s) { open.remove(at: idx) }
        }

        func trimTrailingNewline() {
            guard var lastRun = runs.last, lastRun.text.hasSuffix("\n") else { return }
            lastRun.text.removeLast()
            if lastRun.text.isEmpty { runs.removeLast() } else { runs[runs.count - 1] = lastRun }
        }

        func build() -> Rich? { runs.isEmpty ? nil : Rich(runs: runs) }

        func reset() { runs.removeAll(); open.removeAll() }
    }

    /// Размеченная строка — в блоки. Блок кода режет абзац надвое.
    private static func emitTagged(_ tagged: String, stash: [Stashed], into out: inout [Block], asQuote: Bool) {
        let builder = RichBuilder()
        let tokens = pairedOnly(tokenize(tagged))
        var i = 0
        var skipNewline = false
        while i < tokens.count {
            let token = tokens[i]
            i += 1
            if skipNewline {
                skipNewline = false
                if case .char(let c) = token, c == "\n" { continue }
            }
            switch token {
            case .char(let c):
                builder.append(String(c))
            case .open(let s):
                builder.push(s)
            case .close(let s):
                builder.pop(s)
            case .stash(let index):
                guard index < stash.count else { continue }
                if case .blockCode(let code) = stash[index] {
                    builder.trimTrailingNewline()
                    if let rich = builder.build() { out.append(asQuote ? .quote(rich) : .paragraph(rich)) }
                    out.append(.code(code))
                    let keptOpen = builder.open
                    builder.reset()
                    builder.open = keptOpen
                    skipNewline = true
                } else {
                    appendStashed(builder, stash[index], stash: stash)
                }
            }
        }
        if let rich = builder.build() { out.append(asQuote ? .quote(rich) : .paragraph(rich)) }
    }

    private static func appendStashed(_ builder: RichBuilder, _ item: Stashed, stash: [Stashed]) {
        switch item {
        case .inlineCode(let code):
            builder.append(code, extra: .code)
        case .blockCode(let code):
            builder.append(code, extra: .code)
        case .bareLink(let url):
            builder.append(url, extra: .link, data: url)
        case .mention(let name):
            builder.append("@" + name, extra: .mention, data: name)
        case .link(let labelTagged, let url):
            // Слова ссылки могут содержать стили и код — раскрываем вложенное
            let inner = RichBuilder()
            inner.open = builder.open
            for token in pairedOnly(tokenize(labelTagged)) {
                switch token {
                case .char(let c): inner.append(String(c))
                case .open(let s): inner.push(s)
                case .close(let s): inner.pop(s)
                case .stash(let idx):
                    if idx < stash.count {
                        if case .blockCode = stash[idx] { continue }
                        appendStashed(inner, stash[idx], stash: stash)
                    }
                }
            }
            for run in inner.runs {
                var styles = run.styles
                styles.insert(.link)
                builder.runs.append(Run(text: run.text, styles: styles, data: url))
            }
        }
    }
}
