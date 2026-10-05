import XCTest
@testable import RST

/// Те же случаи, что в tests/js/text-format.test.mjs веба и в тестах Android.
final class TextFormatTests: XCTestCase {

    private func single(_ raw: String, file: StaticString = #filePath, line: UInt = #line) -> TextFormat.Rich? {
        let blocks = TextFormat.parse(raw)
        guard blocks.count == 1, case .paragraph(let rich) = blocks[0] else {
            XCTFail("ожидался один абзац: \(blocks)", file: file, line: line)
            return nil
        }
        return rich
    }

    /// Текст, покрытый стилем.
    private func styled(_ rich: TextFormat.Rich?, _ style: TextFormat.Style) -> String {
        (rich?.runs ?? []).filter { $0.styles.contains(style) }.map(\.text).joined()
    }

    func testBold() {
        let rich = single("**привет**")
        XCTAssertEqual(rich?.text, "привет")
        XCTAssertEqual(styled(rich, .bold), "привет")
    }

    func testOtherStyles() {
        XCTAssertEqual(styled(single("__мир__"), .italic), "мир")
        XCTAssertEqual(styled(single("++да++"), .underline), "да")
        XCTAssertEqual(styled(single("~~нет~~"), .strike), "нет")
        XCTAssertEqual(styled(single("||тайна||"), .spoiler), "тайна")
    }

    func testNoMarkupInsideCode() {
        let rich = single("`a**b**c`")
        XCTAssertEqual(rich?.text, "a**b**c")
        XCTAssertEqual(styled(rich, .code), "a**b**c")
        XCTAssertEqual(styled(rich, .bold), "")
    }

    func testCodeBlockWithLanguage() {
        XCTAssertEqual(TextFormat.parse("```js\nconst x = 1 **2;\n```"), [.code("const x = 1 **2;")])
    }

    func testNesting() {
        let rich = single("**жир __кур__**")
        XCTAssertEqual(rich?.text, "жир кур")
        XCTAssertEqual(styled(rich, .bold), "жир кур")
        XCTAssertEqual(styled(rich, .italic), "кур")
    }

    func testSpaceInsideMarkerIsNotStyle() {
        XCTAssertEqual(single("2 ** 3 ** 4")?.text, "2 ** 3 ** 4")
        XCTAssertEqual(styled(single("2 ** 3 ** 4"), .bold), "")
        XCTAssertEqual(single("**")?.text, "**")
        XCTAssertEqual(single("C++ и C++")?.text, "C++ и C++")
    }

    func testQuotes() {
        let blocks = TextFormat.parse("> один\n> два\nтекст")
        XCTAssertEqual(blocks.count, 2)
        if case .quote(let q) = blocks[0] { XCTAssertEqual(q.text, "один\nдва") } else { XCTFail() }
        if case .paragraph(let p) = blocks[1] { XCTAssertEqual(p.text, "текст") } else { XCTFail() }
    }

    func testLinks() {
        let rich = single("смотри [сайт](https://example.com/a_b_c) и https://rst-msg.ru/x.")
        XCTAssertEqual(rich?.text, "смотри сайт и https://rst-msg.ru/x.")
        let links = (rich?.runs ?? []).filter { $0.styles.contains(.link) }
        XCTAssertEqual(links.map(\.data), ["https://example.com/a_b_c", "https://rst-msg.ru/x"])
        XCTAssertTrue(TextFormat.linkNeedsConfirm(label: "сайт", url: "https://example.com/a_b_c"))
        XCTAssertFalse(TextFormat.linkNeedsConfirm(label: "https://rst-msg.ru/x", url: "https://rst-msg.ru/x"))
    }

    func testJavascriptIsNotLink() {
        let rich = single("[жми](javascript:alert(1))")
        XCTAssertTrue((rich?.runs ?? []).allSatisfy { !$0.styles.contains(.link) })
    }

    func testMention() {
        let rich = single("привет @ivan_1!")
        XCTAssertEqual((rich?.runs ?? []).first { $0.styles.contains(.mention) }?.data, "ivan_1")
    }

    func testStrip() {
        XCTAssertEqual(TextFormat.strip("**жир** ||тайна|| [слова](https://a.b) `код`"), "жир ▒▒▒▒ слова код")
        XCTAssertEqual(TextFormat.strip("> цитата"), "цитата")
    }

    func testPreviewOneLine() {
        XCTAssertEqual(Previews.oneLine("раз\n  два\nтри"), "раз два три")
    }
}
