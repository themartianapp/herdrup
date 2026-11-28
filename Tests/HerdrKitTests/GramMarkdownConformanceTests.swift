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
        let iosBlocks: [String]?
        let hasTable: Bool
        let hasCode: Bool
        let iosHasCode: Bool?
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

    private func proseBlockTag(_ block: GramProseBlock) -> String {
        switch block {
        case .paragraph: return "paragraph"
        case .heading(let level, _): return "heading:\(level)"
        case .list(let ordered, let start, _):
            if ordered { return start == 1 ? "list:ordered" : "list:ordered:\(start)" }
            return "list:unordered"
        case .table: return "table"
        case .quote: return "quote"
        case .rule: return "rule"
        }
    }

    private func proseBlockPlainText(_ block: GramProseBlock) -> String {
        switch block {
        case .paragraph(let s): return s
        case .heading(_, let s): return s
        case .list(_, _, let items): return items.map(\.text).joined(separator: "\n")
        case .table(let h, let rows): return (h + rows.flatMap { $0 }).joined(separator: " ")
        case .quote(let s): return s
        case .rule: return ""
        }
    }

    /// Runs the production Gram message parsing pipeline (`GramText.segments` + `GramText.proseBlocks`).
    private func parseGramProduction(_ input: String) -> (tags: [String], hasTable: Bool, hasCode: Bool, plainText: String) {
        let segments = GramText.segments(input)
        var tags: [String] = []
        var hasTable = false
        var hasCode = false
        var textParts: [String] = []

        for segment in segments {
            switch segment {
            case .code(let code, let language):
                hasCode = true
                tags.append(language.map { "code:\($0)" } ?? "code")
                textParts.append(code)
            case .text(let prose):
                let blocks = GramText.proseBlocks(prose)
                if GramText.hasTable(blocks) { hasTable = true }
                for block in blocks {
                    tags.append(proseBlockTag(block))
                    textParts.append(proseBlockPlainText(block))
                }
            }
        }
        return (tags, hasTable, hasCode, textParts.joined(separator: "\n"))
    }

    /// Minimal quote-aware HTML tag/attribute scanner so quoted attribute values (e.g. title="onload=1")
    /// are never mistaken for live event handlers.
    private func assertSafeHTML(_ html: String, context: String, file: StaticString = #filePath, line: UInt = #line) {
        let forbiddenElements: Set<String> = ["script", "iframe", "object", "embed", "img"]
        let chars = Array(html)
        var i = 0
        while i < chars.count {
            guard chars[i] == "<" else { i += 1; continue }
            var pos = i + 1
            if pos < chars.count, chars[pos] == "/" {
                while pos < chars.count, chars[pos] != ">" { pos += 1 }
                i = min(pos + 1, chars.count)
                continue
            }
            let nameStart = pos
            while pos < chars.count, chars[pos].isLetter || chars[pos].isNumber || chars[pos] == "-" {
                pos += 1
            }
            let tagName = String(chars[nameStart..<pos]).lowercased()
            guard !tagName.isEmpty else { i += 1; continue }
            XCTAssertFalse(forbiddenElements.contains(tagName), "\(context): unexpected <\(tagName)>", file: file, line: line)

            while pos < chars.count {
                while pos < chars.count, chars[pos].isWhitespace { pos += 1 }
                if pos >= chars.count || chars[pos] == ">" { pos += 1; break }
                if chars[pos] == "/", pos + 1 < chars.count, chars[pos + 1] == ">" { pos += 2; break }
                let attrStart = pos
                while pos < chars.count, !chars[pos].isWhitespace, chars[pos] != "=", chars[pos] != "/", chars[pos] != ">" {
                    pos += 1
                }
                let attrName = String(chars[attrStart..<pos]).lowercased()
                guard !attrName.isEmpty else { pos += 1; continue }
                while pos < chars.count, chars[pos].isWhitespace { pos += 1 }
                var attrValue = ""
                if pos < chars.count, chars[pos] == "=" {
                    pos += 1
                    while pos < chars.count, chars[pos].isWhitespace { pos += 1 }
                    if pos < chars.count, chars[pos] == "\"" || chars[pos] == "'" {
                        let quote = chars[pos]
                        pos += 1
                        let valStart = pos
                        while pos < chars.count, chars[pos] != quote { pos += 1 }
                        attrValue = String(chars[valStart..<pos])
                        if pos < chars.count, chars[pos] == quote { pos += 1 }
                    } else {
                        let valStart = pos
                        while pos < chars.count, !chars[pos].isWhitespace, chars[pos] != ">" { pos += 1 }
                        attrValue = String(chars[valStart..<pos])
                    }
                }
                XCTAssertFalse(attrName.hasPrefix("on"), "\(context): live HTML event handler attribute \(attrName)", file: file, line: line)
                if attrName == "href" {
                    let lowerHref = attrValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let safe = lowerHref.hasPrefix("http://") || lowerHref.hasPrefix("https://") || lowerHref.hasPrefix("mailto:")
                    XCTAssertTrue(safe, "\(context): unsafe href '\(attrValue)'", file: file, line: line)
                }
            }
            i = pos
        }
    }

    func testSharedGramMarkdownConformanceCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.version, 1)
        XCTAssertGreaterThanOrEqual(corpus.cases.count, 15)

        for fixture in corpus.cases {
            let parsed = parseGramProduction(fixture.input)
            XCTAssertFalse(parsed.tags.isEmpty, "fixture \(fixture.id) produced no blocks")

            let expectedBlocks = fixture.expect.iosBlocks ?? fixture.expect.blocks
            XCTAssertEqual(parsed.tags, expectedBlocks, "fixture \(fixture.id) GramText block structure mismatch")

            XCTAssertEqual(parsed.hasTable, fixture.expect.hasTable, "fixture \(fixture.id) hasTable mismatch")
            let expectedCode = fixture.expect.iosHasCode ?? fixture.expect.hasCode
            XCTAssertEqual(parsed.hasCode, expectedCode, "fixture \(fixture.id) hasCode mismatch")

            for snippet in fixture.expect.containsText {
                XCTAssertTrue(parsed.plainText.contains(snippet), "fixture \(fixture.id) missing text '\(snippet)' in '\(parsed.plainText)'")
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

    /// Deterministic SplitMix64 generator (full 64-bit output mixing before range reduction).
    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
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
        var rng = SplitMix64(state: 0x5EED2026)
        for i in 0..<400 {
            let lineCount = rng.int(in: 1..<15)
            var lines: [String] = []
            lines.reserveCapacity(lineCount)
            for _ in 0..<lineCount {
                lines.append(Self.fuzzFragments[rng.int(in: 0..<Self.fuzzFragments.count)])
            }
            let doc = lines.joined(separator: "\n")
            _ = parseGramProduction(doc)
            let html = Markdown.toStyledHTML(doc)
            assertSafeHTML(html, context: "fuzz#\(i)")
        }
    }

    func testAdversarialNestedTildeInputLatencySmoke() {
        func makeAdversarialDoc(repeats: Int) -> String {
            var lines: [String] = []
            lines.reserveCapacity(repeats * 3)
            for i in 0..<repeats {
                lines.append("- item \(i) with **bold** `code` ftp://host/\(i) <script>\(i)</script>")
                lines.append("  ~~~md")
                lines.append("  > quote \(i) | col")
            }
            return lines.joined(separator: "\n")
        }

        for repeats in [100, 500] {
            let doc = makeAdversarialDoc(repeats: repeats)
            let start = Date()
            let parsed = parseGramProduction(doc)
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertFalse(parsed.tags.isEmpty)
            XCTAssertLessThan(elapsed, 2.0, "GramText production pipeline took \(elapsed)s on \(repeats * 3)-line adversarial input")
        }
    }
}
