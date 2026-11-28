import XCTest
@testable import HerdrKit

final class ChatMarkdownTests: XCTestCase {

    func testSplitsAReplyIntoNativeBlocks() {
        let blocks = ChatMarkdown.blocks("""
        Done. Scrolling up now keeps loading, **500 lines at a time**.
        Second line of the same paragraph.

        ## Results

        - Tested on a real server: no gaps.
        - The app part is in `#477`;
          the server part is `#305`.
          - nested detail
        - [x] merged

        1. First
        2) Second

        | Metric | Q5 | Change |
        |---|:--:|---:|
        | Decode | 41.2 tok/s | +36% |
        | Prefill | 1,180 tok/s |

        ```swift
        let x = 1

        print(x)
        ```

        > quoted
        > twice

        ---
        Final words.
        """)
        XCTAssertEqual(blocks, [
            .paragraph("Done. Scrolling up now keeps loading, **500 lines at a time**.\nSecond line of the same paragraph."),
            .heading(level: 2, "Results"),
            .list(ordered: false, start: 1, items: [
                ChatMarkdownListItem(text: "Tested on a real server: no gaps."),
                ChatMarkdownListItem(text: "The app part is in `#477`;\nthe server part is `#305`."),
                ChatMarkdownListItem(text: "nested detail", depth: 1),
                ChatMarkdownListItem(text: "merged", checked: true),
            ]),
            .list(ordered: true, start: 1, items: [
                ChatMarkdownListItem(text: "First", marker: "1."),
                ChatMarkdownListItem(text: "Second", marker: "2."),
            ]),
            .table(header: ["Metric", "Q5", "Change"], rows: [
                ["Decode", "41.2 tok/s", "+36%"],
                ["Prefill", "1,180 tok/s", ""],
            ]),
            .code(language: "swift", "let x = 1\n\nprint(x)"),
            .quote("quoted\ntwice"),
            .rule,
            .paragraph("Final words."),
        ])
    }

    func testUnclosedFenceRunsToTheEndAndPlainTextIsOneParagraph() {
        XCTAssertEqual(ChatMarkdown.blocks("```\ncode"), [.code(language: nil, "code")])
        XCTAssertEqual(ChatMarkdown.blocks("just text"), [.paragraph("just text")])
        XCTAssertEqual(ChatMarkdown.blocks("#hashtag not a heading"), [.paragraph("#hashtag not a heading")])
        XCTAssertEqual(ChatMarkdown.blocks(""), [])
    }

    /// A closed ```mermaid fence is a diagram the Chat view draws; the source keeps every
    /// line verbatim (indentation included) because mermaid parses it.
    func testClosedMermaidFenceIsADiagram() {
        XCTAssertEqual(ChatMarkdown.blocks("Plan:\n```mermaid\ngraph TD\n  A --> B\n```\nDone."), [
            .paragraph("Plan:"),
            .diagram(kind: "mermaid", source: "graph TD\n  A --> B"),
            .paragraph("Done."),
        ])
        XCTAssertEqual(ChatMarkdown.blocks("~~~ Mermaid title\nsequenceDiagram\n~~~"), [
            .diagram(kind: "mermaid", source: "sequenceDiagram"),
        ])
    }

    /// A reply still streaming has no closing fence yet: it stays code until the fence closes,
    /// so a half-written diagram is never rendered (or shown as a parse error).
    func testUnclosedMermaidFenceStaysCode() {
        XCTAssertEqual(ChatMarkdown.blocks("```mermaid\ngraph TD\n  A --> B"), [
            .code(language: "mermaid", "graph TD\n  A --> B"),
        ])
    }

    func testOtherFenceLanguagesStayCode() {
        XCTAssertEqual(ChatMarkdown.blocks("```mermaidx\ngraph TD\n```"), [.code(language: "mermaidx", "graph TD")])
        XCTAssertEqual(ChatMarkdown.blocks("```dot\ndigraph { a -> b }\n```"), [.code(language: "dot", "digraph { a -> b }")])
        XCTAssertEqual(ChatMarkdown.blocks("```\ngraph TD\n```"), [.code(language: nil, "graph TD")])
    }

    /// ```svg, and ```xml holding an `<svg>` document, are drawn; other XML stays code, and so
    /// does an SVG still streaming.
    func testSVGAndSVGDocumentXMLFencesAreDiagrams() {
        let svg = "<svg viewBox=\"0 0 10 10\">\n  <rect width=\"4\" height=\"4\"/>\n</svg>"
        XCTAssertEqual(ChatMarkdown.blocks("```svg\n\(svg)\n```"), [.diagram(kind: "svg", source: svg)])
        XCTAssertEqual(ChatMarkdown.blocks("```XML\n<?xml version=\"1.0\"?>\n\(svg)\n```"),
                       [.diagram(kind: "svg", source: "<?xml version=\"1.0\"?>\n\(svg)")])
        XCTAssertEqual(ChatMarkdown.blocks("```xml\n<config><svg/></config>\n```"),
                       [.code(language: "xml", "<config><svg/></config>")])
        XCTAssertEqual(ChatMarkdown.blocks("```svg\n<svg>"), [.code(language: "svg", "<svg>")])
    }

    func testOrderedListKeepsItsStartNumber() {
        XCTAssertEqual(ChatMarkdown.blocks("3. three\n4. four"), [
            .list(ordered: true, start: 3, items: [
                ChatMarkdownListItem(text: "three", marker: "3."),
                ChatMarkdownListItem(text: "four", marker: "4."),
            ]),
        ])
    }

    /// Only a real delimiter row (as many cells as the header, each `---`-like) and a pipe
    /// outside inline code make a table; prose with a stray pipe stays prose.
    func testProseWithAPipeIsNotATable() {
        XCTAssertEqual(ChatMarkdown.blocks("a|b\n-|-\nrest"), [.paragraph("a|b\n-|-\nrest")])
        XCTAssertEqual(ChatMarkdown.blocks("x | y | z\n---|---"), [.paragraph("x | y | z\n---|---")])
        XCTAssertEqual(ChatMarkdown.blocks("run `a|b` now\n---|---"), [.paragraph("run `a|b` now\n---|---")])
        XCTAssertEqual(ChatMarkdown.blocks("| `a|b` | c |\n|---|:-:|\n| 1 \\| 2 | 3 |"), [
            .table(header: ["`a|b`", "c"], rows: [["1 | 2", "3"]]),
        ])
    }

    func testBareTaskBoxesAreCheckedAndUnchecked() {
        XCTAssertEqual(ChatMarkdown.blocks("- [x]\n- [ ]\n- [X] done\n- [y] no"), [
            .list(ordered: false, start: 1, items: [
                ChatMarkdownListItem(text: "", checked: true),
                ChatMarkdownListItem(text: "", checked: false),
                ChatMarkdownListItem(text: "done", checked: true),
                ChatMarkdownListItem(text: "[y] no"),
            ]),
        ])
    }
}
