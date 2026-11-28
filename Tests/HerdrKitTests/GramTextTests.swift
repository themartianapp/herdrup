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
        XCTAssertEqual(items.map(\.marker), ["1.", "•", "2."])

        // Nested ordered sublist resolves its starting ordinal directly on each item, and a child
        // indented to the active parent's content column continues across a blank line (#924).
        let nestedOrdered = "5. Outer\n  6. Sub A\n  7. Sub B\n\n   - note\n6. Outer 2"
        let nestedBlocks = GramText.proseBlocks(nestedOrdered)
        guard nestedBlocks.count == 1, case .list(_, _, let nItems) = nestedBlocks[0] else {
            return XCTFail("expected single nested list block, got \(nestedBlocks)")
        }
        XCTAssertEqual(nItems.map(\.marker), ["5.", "6.", "7.", "•", "6."])

        // Blank-line continuation compares against the ACTIVE parent's content column, not the
        // first item's (#924): narrower active item accepts 3-space child; wider active item splits.
        let narrowerActive = "100. First\n1. Second\n\n   - Child\n2. Third"
        let narrowerBlocks = GramText.proseBlocks(narrowerActive)
        guard narrowerBlocks.count == 1, case .list(_, _, let narrowerItems) = narrowerBlocks[0] else {
            return XCTFail("expected single list block, got \(narrowerBlocks)")
        }
        XCTAssertEqual(narrowerItems.map(\.marker), ["100.", "101.", "•", "102."])

        let widerActive = "9. First\n10. Second\n\n   - Separate bullet\n\n20. Third"
        XCTAssertEqual(GramText.proseBlocks(widerActive), [
            .list(ordered: true, start: 9, items: [
                ChatMarkdownListItem(text: "First", marker: "9."),
                ChatMarkdownListItem(text: "Second", marker: "10."),
            ]),
            .list(ordered: false, start: 1, items: [ChatMarkdownListItem(text: "Separate bullet", depth: 1)]),
            .list(ordered: true, start: 20, items: [ChatMarkdownListItem(text: "Third", marker: "20.")]),
        ])

        // Thematic break (with or without a preceding blank line) and shallowly-indented separate
        // bullet after a blank line never merge independent ordered lists (#916, #925).
        let withRule = "1. Ordered\n\n  - - -\n\n9. Independent ordered"
        XCTAssertEqual(GramText.proseBlocks(withRule), [
            .list(ordered: true, start: 1, items: [ChatMarkdownListItem(text: "Ordered", marker: "1.")]),
            .rule,
            .list(ordered: true, start: 9, items: [ChatMarkdownListItem(text: "Independent ordered", marker: "9.")]),
        ])
        let adjacentRule = "1. First\n  - - -\n9. New"
        XCTAssertEqual(GramText.proseBlocks(adjacentRule), [
            .list(ordered: true, start: 1, items: [ChatMarkdownListItem(text: "First", marker: "1.")]),
            .rule,
            .list(ordered: true, start: 9, items: [ChatMarkdownListItem(text: "New", marker: "9.")]),
        ])
        let separated = "10. First\n\n  - Separate bullet\n\n20. Second"
        XCTAssertEqual(GramText.proseBlocks(separated), [
            .list(ordered: true, start: 10, items: [ChatMarkdownListItem(text: "First", marker: "10.")]),
            .list(ordered: false, start: 1, items: [ChatMarkdownListItem(text: "Separate bullet", depth: 1)]),
            .list(ordered: true, start: 20, items: [ChatMarkdownListItem(text: "Second", marker: "20.")]),
        ])
    }

    func testTildeFencesRenderAsCodeSegmentsAndPreserveIndentationAndBackticks() {
        let tilde = "Run:\n~~~swift\n    let x = 1\n```\ninner\n```\n~~~\nDone"
        XCTAssertEqual(segments(tilde), [
            .text("Run:"),
            .code("    let x = 1\n```\ninner\n```", language: "swift"),
            .text("Done"),
        ])
        // Backtick line does not close a tilde fence, and unclosed tilde fence stays prose.
        XCTAssertEqual(segments("~~~bash\necho hi\n```"), [.text("~~~bash\necho hi\n```")])
        // Longer closing tilde fence closes shorter opening tilde fence.
        XCTAssertEqual(segments("~~~\na\n~~~~"), [.code("a", language: nil)])
        // Top-level 1..3-space tilde fence (with unindented body) and 4-space tilde fence inside
        // a 4-column list item both extract as code cards (#922).
        XCTAssertEqual(segments("  ~~~sh\npwd\n  ~~~"), [.code("pwd", language: "sh")])
        XCTAssertEqual(segments("10. Example:\n\n    ~~~sh\n    pwd\n    ~~~"), [
            .text("10. Example:\n"),
            .code("    pwd", language: "sh"),
        ])
        // Unclosed indented tilde opener inside a list item or 4-space top-level literal `~~~`
        // never swallows a later top-level code card (#915).
        let indentedInList = "- Example:\n\n  ~~~sh\n  echo hi\n\nNext:\n\n```sh\npwd\n```"
        XCTAssertEqual(segments(indentedInList), [
            .text("- Example:\n\n  ~~~sh\n  echo hi\n\nNext:\n"),
            .code("pwd", language: "sh"),
        ])
        let fourSpaceLiteral = "    ~~~\n    echo hi\n\n```sh\npwd\n```"
        XCTAssertEqual(segments(fourSpaceLiteral), [
            .text("    ~~~\n    echo hi\n"),
            .code("pwd", language: "sh"),
        ])
    }
}
