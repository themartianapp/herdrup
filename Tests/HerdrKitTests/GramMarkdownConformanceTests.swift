import Foundation
import XCTest
@testable import HerdrKit

/// Shared cross-platform Gram Markdown conformance corpus & deterministic property/fuzz tests.
/// Fixture file Tests/HerdrKitTests/Fixtures/gram-markdown-fixtures.json is kept byte-identical
/// with jerryfane/herdrup-desktop's test/fixtures/gram-markdown-fixtures.json.
final class GramMarkdownConformanceTests: XCTestCase {

    private struct Corpus: Decodable {
        let version: Int
        let cases: [FixtureCase]
    }

    private struct FixtureCase: Decodable {
        let id: String
        let input: String
        let expect: FixtureExpect
    }

    private struct FixtureExpect: Decodable {
        let blocks: [String]
        let hasTable: Bool
        let hasCode: Bool
        let containsText: [String]
        let allowedLinks: [String]
        let forbiddenSubstrings: [String]
    }

    private func loadCorpus() throws -> Corpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/gram-markdown-fixtures.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Corpus.self, from: data)
    }

    private func blockTag(_ block: ChatMarkdownBlock) -> String {
        switch block {
        case .paragraph: return "paragraph"
        case .heading(let level, _): return "heading:\(level)"
        case .list(let ordered, let start, _):
            if ordered { return start == 1 ? "list:ordered" : "list:ordered:\(start)" }
            return "list:unordered"
        case .code(let lang, _):
            return lang.map { "code:\($0)" } ?? "code"
        case .diagram(let kind, _): return "diagram:\(kind)"
        case .table: return "table"
        case .quote: return "quote"
        case .rule: return "rule"
        }
    }

    private func blockPlainText(_ blocks: [ChatMarkdownBlock]) -> String {
        blocks.map { block in
            switch block {
            case .paragraph(let s): return s
            case .heading(_, let s): return s
            case .list(_, _, let items): return items.map(\.text).joined(separator: "\n")
            case .code(_, let s): return s
            case .diagram(_, let s): return s
            case .table(let h, let rows):
                return (h + rows.flatMap { $0 }).joined(separator: " ")
            case .quote(let s): return s
            case .rule: return ""
            }
        }.joined(separator: "\n")
    }

    private func assertSafeHTML(_ html: String, context: String, file: StaticString = #filePath, line: UInt = #line) {
        let lower = html.lowercased()
        for bad in ["<script", "<iframe", "<object", "<embed", "<img ", "href=\"javascript:", "href=\"data:", "href=\"ftp:"] {
            XCTAssertFalse(lower.contains(bad), "\(context): unexpected \(bad)", file: file, line: line)
        }
        let hasLiveHandler = html.range(of: #"<[^>]*\bon(?:error|load|click|mouseover|focus)\s*="#, options: [.regularExpression, .caseInsensitive]) != nil
        XCTAssertFalse(hasLiveHandler, "\(context): live HTML event handler attribute", file: file, line: line)
    }

    func testSharedGramMarkdownConformanceCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.version, 1)
        XCTAssertGreaterThanOrEqual(corpus.cases.count, 15)

        for fixture in corpus.cases {
            let blocks = ChatMarkdown.blocks(fixture.input)
            XCTAssertFalse(blocks.isEmpty, "fixture \(fixture.id) produced no blocks")

            let gotTags = blocks.map(blockTag)
            XCTAssertEqual(gotTags, fixture.expect.blocks, "fixture \(fixture.id) block structure mismatch")

            let gotTable = blocks.contains { if case .table = $0 { return true }; return false }
            XCTAssertEqual(gotTable, fixture.expect.hasTable, "fixture \(fixture.id) hasTable mismatch")

            let gotCode = blocks.contains { if case .code = $0 { return true }; return false }
            XCTAssertEqual(gotCode, fixture.expect.hasCode, "fixture \(fixture.id) hasCode mismatch")

            let plain = blockPlainText(blocks)
            for snippet in fixture.expect.containsText {
                XCTAssertTrue(plain.contains(snippet), "fixture \(fixture.id) missing text '\(snippet)' in '\(plain)'")
            }

            let html = Markdown.toStyledHTML(fixture.input)
            for href in fixture.expect.allowedLinks {
                XCTAssertTrue(html.contains("href=\"\(href)\""), "fixture \(fixture.id) missing safe link \(href)")
            }
            for forbidden in fixture.expect.forbiddenSubstrings {
                XCTAssertFalse(html.lowercased().contains(forbidden.lowercased()), "fixture \(fixture.id) emitted forbidden '\(forbidden)'")
            }
            assertSafeHTML(html, context: "fixture \(fixture.id)")
        }
    }

    private struct SeededRNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
        mutating func int(in range: Range<Int>) -> Int {
            let span = UInt64(range.upperBound - range.lowerBound)
            return range.lowerBound + Int(next() % span)
        }
    }

    private static let fuzzFragments: [String] = [
        "# Heading",
        "## Subheading",
        "Plain text **bold** *italic* `code`",
        "- bullet item",
        "  - nested bullet",
        "- [x] done",
        "- [ ] todo",
        "1. first\n2. second",
        "| A | B |\n|---|---|\n| 1 | 2 |",
        "> quoted line",
        ">>> deep quote",
        "---",
        "```sh\necho <script>1</script>\n```",
        "~~~md\n```swift\nlet x = 1\n```\n~~~",
        "[safe](https://herdrup.app)",
        "[mail](mailto:ops@herdrup.app)",
        "[bad-js](javascript:alert(1))",
        "[bad-data](data:text/html,<script>1</script>)",
        "ftp://[2001:db8::1]/report@example.test",
        "https://guest.herdrup.app/web/?a=1&b=2",
        "<script>alert(1)</script><img src=x onerror=alert(1)>",
        "foo | bar & baz < qux > end",
        "`unclosed backtick **bold**",
        "",
    ]

    func testPropertyFuzz400SeededMarkdownDocuments() {
        var rng = SeededRNG(state: 0x5EED2026)
        for i in 0..<400 {
            let lineCount = rng.int(in: 1..<15)
            var lines: [String] = []
            lines.reserveCapacity(lineCount)
            for _ in 0..<lineCount {
                lines.append(Self.fuzzFragments[rng.int(in: 0..<Self.fuzzFragments.count)])
            }
            let doc = lines.joined(separator: "\n")
            _ = ChatMarkdown.blocks(doc)
            let html = Markdown.toStyledHTML(doc)
            assertSafeHTML(html, context: "fuzz#\(i)")
        }
    }

    func testPropertyFuzz1500LineAdversarialInputLinearTime() {
        var lines: [String] = []
        lines.reserveCapacity(1500)
        for i in 0..<500 {
            lines.append("- item \(i) with **bold** `code` ftp://host/\(i) <script>\(i)</script>")
            lines.append("  ~~~md")
            lines.append("  > quote \(i) | col")
        }
        let doc = lines.joined(separator: "\n")
        let start = Date()
        let blocks = ChatMarkdown.blocks(doc)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(blocks.isEmpty)
        XCTAssertLessThan(elapsed, 2.0, "ChatMarkdown.blocks took \(elapsed)s on 1500-line adversarial input")
    }
}
