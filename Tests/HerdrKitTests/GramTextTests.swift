import XCTest
@testable import HerdrKit

/// Gram draws fenced code in its own monospaced inset with a Copy button, so the split
/// between prose and code decides what the owner can copy in one tap.
final class GramTextTests: XCTestCase {
    private func segments(_ text: String) -> [GramTextSegment] { GramText.segments(text) }

    func testPlainTextIsOneTextSegment() {
        XCTAssertEqual(segments("Digest ready: 7 trends.\nTwo need your call."),
                       [.text("Digest ready: 7 trends.\nTwo need your call.")])
    }

    func testEmptyTextHasNoSegments() {
        XCTAssertEqual(segments(""), [])
    }

    func testTextBeforeAndAfterACodeBlockLoseOnlyTheNewlineNextToTheFence() {
        XCTAssertEqual(segments("Scaffold is up. Run it with:\n```\ncd ~/src/amigo-poc && pnpm dev\n```\nThen open it."), [
            .text("Scaffold is up. Run it with:"),
            .code("cd ~/src/amigo-poc && pnpm dev", language: nil),
            .text("Then open it."),
        ])
        // Only ONE newline is the fence's: a blank line before or after stays in the prose.
        XCTAssertEqual(segments("Before\n\n```\nx\n```\n\nAfter"), [
            .text("Before\n"),
            .code("x", language: nil),
            .text("\nAfter"),
        ])
    }

    func testTheLanguageIsTheFirstWordAfterTheFence() {
        XCTAssertEqual(segments("```swift\nlet a = 1\n```"), [.code("let a = 1", language: "swift")])
        XCTAssertEqual(segments("```  bash title=run.sh\nls -la\n```"), [.code("ls -la", language: "bash")])
        XCTAssertEqual(segments("```   \nplain\n```"), [.code("plain", language: nil)])
    }

    func testMultiLineCodeKeepsItsLinesAndIndentation() {
        XCTAssertEqual(segments("```py\ndef f():\n    return 1\n\nprint(f())\n```"),
                       [.code("def f():\n    return 1\n\nprint(f())", language: "py")])
    }

    func testAnEmptyCodeBlockIsStillCode() {
        XCTAssertEqual(segments("```\n```"), [.code("", language: nil)])
    }

    func testAdjacentFencesAreTwoBlocksWithNoEmptyTextBetween() {
        XCTAssertEqual(segments("```sh\nmake\n```\n```json\n{}\n```"), [
            .code("make", language: "sh"),
            .code("{}", language: "json"),
        ])
        // A blank line between them is whitespace-only prose: dropped, not an empty bubble.
        XCTAssertEqual(segments("```\na\n```\n\n```\nb\n```"), [
            .code("a", language: nil),
            .code("b", language: nil),
        ])
    }

    func testAnUnclosedFenceIsTextToTheEnd() {
        XCTAssertEqual(segments("Try this:\n```bash\nrm -rf build\nand then rebuild"),
                       [.text("Try this:\n```bash\nrm -rf build\nand then rebuild")])
    }

    func testAnUnclosedFenceAfterAClosedBlockOnlySwallowsTheRest() {
        XCTAssertEqual(segments("```\none\n```\nnote\n```\ntwo"), [
            .code("one", language: nil),
            .text("note\n```\ntwo"),
        ])
    }

    func testALaterUnclosedFenceDoesNotRecoverIntoCode() {
        // The four-tick fence never closes (``` is shorter), so everything after it is prose,
        // even though a later ```py … ``` pair would close on its own.
        let text = "````\na\n```py\nb\n```"
        XCTAssertEqual(segments(text), [.text(text)])
    }

    func testTheClosingFenceNeedsAtLeastTheOpeningTicks() {
        XCTAssertEqual(segments("````md\n```\ninner\n```\n````"),
                       [.code("```\ninner\n```", language: "md")])
    }

    func testALongerClosingFenceClosesTheBlock() {
        // At least the opening ticks, not exactly: four ticks close a three-tick fence.
        XCTAssertEqual(segments("```\na\n````"), [.code("a", language: nil)])
        XCTAssertEqual(segments("```sh\nmake\n`````\nDone"), [
            .code("make", language: "sh"),
            .text("Done"),
        ])
    }

    func testAnInfoStringWithABacktickIsNotAnOpeningFence() {
        // "```inline```" is prose, so the later bare ``` OPENS a fence (which never closes)
        // rather than closing one: the whole message stays prose.
        XCTAssertEqual(segments("```inline```\nrest\n```"), [.text("```inline```\nrest\n```")])
        XCTAssertEqual(segments("```js `x`\ny\n```\n"), [.text("```js `x`\ny\n```\n")])
    }

    func testWhitespaceOnlyProseIsDropped() {
        // Spaces and tabs between, before and after the blocks draw no empty bubble.
        XCTAssertEqual(segments("  \n```\na\n```\n \t \n```\nb\n```\n   "), [
            .code("a", language: nil),
            .code("b", language: nil),
        ])
        XCTAssertEqual(segments(" \t"), [])
    }

    func testAFenceLineWithInfoDoesNotCloseABlock() {
        XCTAssertEqual(segments("```\na\n```js\nb\n```"), [.code("a\n```js\nb", language: nil)])
    }

    func testInlineTriplesAreNotFences() {
        let text = "Use ```code``` inline, or say ``` mid-line."
        XCTAssertEqual(segments(text), [.text(text)])
        XCTAssertEqual(segments("```inline```\nrest"), [.text("```inline```\nrest")])
    }

    func testIndentedFencesAndTrailingSpacesStillCount() {
        XCTAssertEqual(segments("Steps:\n  ```zsh\n  brew install herdr\n  ```  \nDone"), [
            .text("Steps:"),
            .code("  brew install herdr", language: "zsh"),
            .text("Done"),
        ])
    }

    func testCRLFLineEndingsReadAsLF() {
        XCTAssertEqual(segments("Run:\r\n```bash\r\nmake test\r\nmake lint\r\n```\r\nDone\r\n"), [
            .text("Run:"),
            .code("make test\nmake lint", language: "bash"),
            .text("Done\n"),
        ])
    }

    func testTwoTicksAreNotAFence() {
        XCTAssertEqual(segments("``\nx\n``"), [.text("``\nx\n``")])
    }

    func testPlainMultiLineReportStaysSingleNonRichParagraph() {
        let report = "Deployed. vetrina.dev is live.\n• Build 412 passed\n• 2 migrations ran clean"
        let blocks = GramText.proseBlocks(report)
        XCTAssertEqual(blocks, [.paragraph(report)])
        XCTAssertFalse(GramText.isRichMarkdown(blocks))
        XCTAssertFalse(GramText.hasTable(blocks))
    }

    func testRichMarkdownAndTableDetection() {
        let rich = """
        ## Summary

        - First item
        - [x] Done

        | Service | Delta |
        |---|---|
        | API | +12% |
        """
        let blocks = GramText.proseBlocks(rich)
        XCTAssertTrue(GramText.isRichMarkdown(blocks))
        XCTAssertTrue(GramText.hasTable(blocks))
        XCTAssertEqual(blocks.count, 3)

        let twoParagraphs = GramText.proseBlocks("First paragraph.\n\nSecond paragraph.")
        XCTAssertTrue(GramText.isRichMarkdown(twoParagraphs))
        XCTAssertFalse(GramText.hasTable(twoParagraphs))
        XCTAssertFalse(GramText.hasTable(GramText.proseBlocks("plain prose with a | pipe")))
    }

    func testInlineTripleBacktickSpanAndUnclosedFenceStayProseInProseBlocks() {
        let inlineSpan = "``` `42` ```\n\nSecond paragraph."
        XCTAssertEqual(segments(inlineSpan), [.text(inlineSpan)])
        XCTAssertEqual(GramText.proseBlocks(inlineSpan), [
            .paragraph("``` `42` ```"),
            .paragraph("Second paragraph."),
        ])

        let unclosed = "Try this:\n```bash\nrm -rf build"
        XCTAssertEqual(segments(unclosed), [.text(unclosed)])
        XCTAssertEqual(GramText.proseBlocks(unclosed), [.paragraph(unclosed)])
    }

    func testOrderedListWithNestedBulletPreservesOuterNumbering() {
        let md = "1. First\n  - nested bullet\n2. Second"
        let blocks = GramText.proseBlocks(md)
        guard case .list(let ordered, let start, let items) = blocks.first else {
            return XCTFail("expected list block, got \(blocks)")
        }
        XCTAssertTrue(ordered)
        XCTAssertEqual(start, 1)
        XCTAssertEqual(ChatMarkdown.listMarkers(ordered: ordered, start: start, items: items), ["1.", "•", "2."])
    }
}
