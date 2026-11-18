//
//  ScrollbackBudgetTests.swift
//  SwiftTermTests
//
//  herdr (#687): a scrollback row holds a full-width array of cells, so a ring sized
//  in rows alone grows with the grid's width. A ring sized from a byte budget must
//  hold a long feed under that budget at any width, stay under it when the grid
//  widens and the ring is re-sized, free what a shrink trims, and stop paged-in
//  history at the same cap.
//

import Testing
@testable import SwiftTerm

private let rows = 50
private let budget = 8 << 20

/// The ring the embedder would set for `cols` × `height`: the most it pages to, lowered to the budget.
private func ring (cols: Int, height: Int = rows) -> Int {
    Terminal.scrollbackLines (budgetBytes: budget, cols: cols, rows: height, minimum: 0, maximum: 20_000)
}

private func text (_ terminal: Terminal, _ index: Int) -> String {
    terminal.normalBuffer.translateBufferLineToString (lineIndex: index, trimRight: true)
}

/// A full ring the way a keyframe seeds it: `row 0` (the oldest) at the top, exactly
/// `scrollback + rows` rows, none trimmed yet; and the anchor the embedder takes for it.
private func seededFullRing (cols: Int) -> (Terminal, Terminal.HistoryTop) {
    let (terminal, _) = TerminalTestHarness.makeTerminal (cols: cols, rows: rows, scrollback: ring (cols: cols))
    terminal.preservesScrollbackLayout = true
    let count = ring (cols: cols) + rows
    for i in 0..<count {
        terminal.feed (text: "row \(i)" + (i < count - 1 ? "\r\n" : ""))
    }
    return (terminal, terminal.historyTop)
}

/// The page above `row 0` a `pane.history` cursor names: `old 0` … `old 99`.
private let olderPage = ArraySlice ((0..<100).map { "old \($0)" }.joined (separator: "\r\n").utf8)

/// `count` full-width rows, so every row is as wide as the grid.
private func feedRows (_ terminal: Terminal, _ count: Int, cols: Int, prefix: String = "row") {
    for i in 0..<count {
        let label = "\(prefix) \(i) "
        terminal.feed (text: label + String (repeating: "x", count: max (0, cols - label.count - 1)) + "\r\n")
    }
}

private func visible (_ terminal: Terminal) -> [String] {
    TerminalTestHarness.visibleLinesText (buffer: terminal.normalBuffer, terminal: terminal)
}

@Suite("herdr scrollback budget")
struct ScrollbackBudgetTests {

    @Test("a row costs its cells plus a fixed overhead", arguments: [80, 200, 250])
    func rowCost (cols: Int) {
        #expect (Terminal.rowBytes (cols: cols) == cols * MemoryLayout<CharData>.stride + Terminal.rowOverheadBytes)
        #expect (MemoryLayout<CharData>.stride == 24)
    }

    @Test("a ring sized from the budget keeps a long feed under it", arguments: [80, 200, 250])
    func longFeedStaysUnderBudget (cols: Int) {
        let lines = ring (cols: cols)
        let (terminal, _) = TerminalTestHarness.makeTerminal (cols: cols, rows: rows, scrollback: lines)
        feedRows (terminal, lines * 2 + 500, cols: cols)

        #expect (terminal.normalBufferRowCount == lines + rows, "the ring is full")
        #expect (terminal.normalBufferBytes <= budget)
    }

    @Test("the ring a row cap alone sets outgrows the budget on a wide grid")
    func rowCapAloneOutgrowsBudget () {
        // What the embedder had: 20,000 rows whatever the width.
        let (terminal, _) = TerminalTestHarness.makeTerminal (cols: 250, rows: rows, scrollback: 20_000)
        feedRows (terminal, 20_500, cols: 250)

        #expect (terminal.normalBufferBytes > 110 << 20, "20,000 rows at 250 columns hold about 123 MB")
    }

    @Test("a widened grid is back under the budget once the ring is re-sized for it")
    func widenedGridResizedRing () {
        let (terminal, _) = TerminalTestHarness.makeTerminal (cols: 80, rows: rows, scrollback: ring (cols: 80))
        feedRows (terminal, ring (cols: 80) + 200, cols: 80)
        #expect (terminal.normalBufferBytes <= budget)

        terminal.resize (cols: 250, rows: rows)
        // Every row widened with the grid: the same rows cost three times as much.
        #expect (terminal.normalBufferBytes > budget)

        terminal.changeHistorySize (ring (cols: 250))
        #expect (terminal.normalBufferBytes <= budget)
        feedRows (terminal, ring (cols: 250) + 200, cols: 250, prefix: "wide")
        #expect (terminal.normalBufferBytes <= budget)
    }

    @Test("shrinking the ring frees the trimmed rows and keeps the screen")
    func shrinkFreesRows () {
        let cols = 200
        let (terminal, _) = TerminalTestHarness.makeTerminal (cols: cols, rows: rows, scrollback: ring (cols: cols))
        feedRows (terminal, ring (cols: cols) + 200, cols: cols)
        terminal.feed (text: "$ ")
        let screen = visible (terminal)
        let before = terminal.normalBufferBytes

        terminal.changeHistorySize (100)

        #expect (terminal.normalBufferRowCount == 100 + rows)
        #expect (terminal.normalBufferBytes == (100 + rows) * Terminal.rowBytes (cols: cols))
        #expect (terminal.normalBufferBytes < before / 10)
        #expect (visible (terminal) == screen, "the screen is untouched")
    }

    @Test("history paged in above the scrollback stops at the budgeted cap")
    func prependStopsAtBudget () {
        let cols = 250
        let cap = ring (cols: cols)
        let (terminal, _) = TerminalTestHarness.makeTerminal (cols: cols, rows: rows, scrollback: 1000)
        feedRows (terminal, 1200, cols: cols)

        var inserted = 0
        repeat {
            let page = (0..<500).map { "old \($0) " + String (repeating: "y", count: cols - 12) }
                .joined (separator: "\r\n")
            inserted = terminal.prependHistory (ArraySlice (page.utf8), maxScrollback: cap)
        } while inserted > 0

        #expect (terminal.normalBufferRowCount == cap + rows)
        #expect (terminal.normalBufferBytes <= budget)
    }

    // Review of #694: at 250 columns a 50-row grid shrunk to 25 under the old scrollback
    // trimmed the 25 oldest rows, and the re-budget then reopened room for 25: the page
    // above `row 0` was inserted above `row 25`.

    @Test("a shorter grid re-budgeted in one step keeps the oldest row, so a page adjoins it")
    func shorterGridKeepsTop () {
        let cols = 250
        let (terminal, top) = seededFullRing (cols: cols)
        #expect (text (terminal, 0) == "row 0")

        terminal.resize (cols: cols, rows: 25, scrollback: ring (cols: cols, height: 25))

        #expect (text (terminal, 0) == "row 0", "no row left the top")
        #expect (terminal.historyAdjoins (top))
        #expect (terminal.normalBufferBytes <= budget)
        let inserted = terminal.prependHistory (olderPage, maxScrollback: ring (cols: cols, height: 25), adjoining: top)
        #expect (text (terminal, inserted) == "row 0", "whatever was inserted sits directly above row 0")

        // And back: the taller grid re-budgets down without trimming either.
        let before = text (terminal, 0)
        terminal.resize (cols: cols, rows: rows, scrollback: ring (cols: cols))
        #expect (text (terminal, 0) == before)
        #expect (terminal.normalBufferBytes <= budget)
    }

    @Test("a page is refused once any row has left the top", arguments: ["trim", "resize", "output", "erase"])
    func pageRefusedAfterTopRowLeaves (how: String) {
        let cols = 250
        let (terminal, top) = seededFullRing (cols: cols)
        switch how {
        case "trim": terminal.changeHistorySize (ring (cols: cols) - 10)
        case "resize": terminal.resize (cols: cols, rows: 25)     // under the old scrollback
        case "output": terminal.feed (text: "\r\nmore")           // pushes row 0 out of the full ring
        default: terminal.feed (text: "\u{1b}[3J")                // erases the scrollback
        }
        terminal.changeHistorySize (ring (cols: cols) + 100)      // room again

        #expect (!terminal.historyAdjoins (top))
        #expect (terminal.prependHistory (olderPage, maxScrollback: ring (cols: cols) + 100, adjoining: top) == 0)
    }

    // Re-review of #694: a full ring RECYCLES its rows (`CircularBufferLineList.recycle`
    // clears the row leaving the top and reuses the object at the bottom), so after one full
    // rotation the anchored row object is at the top again. Identity alone then vouched for a
    // cursor whose rows had all been pushed out, and a taller grid's re-budget opened room
    // for its page above missing output. The app's numbers: 40 MiB, 80 × 24, cap 20,000.
    @Test("a ring that rotated all the way round no longer adjoins its old top")
    func fullRotationDetachesTop () {
        let appBudget = 40 << 20
        func appRing (_ height: Int) -> Int {
            Terminal.scrollbackLines (budgetBytes: appBudget, cols: 80, rows: height, minimum: 2000, maximum: 20_000)
        }
        let (terminal, _) = TerminalTestHarness.makeTerminal (cols: 80, rows: 24, scrollback: appRing (24))
        terminal.preservesScrollbackLayout = true
        let capacity = appRing (24) + 24
        #expect (capacity == 20_024)
        for i in 0..<capacity {
            terminal.feed (text: "row \(i)" + (i < capacity - 1 ? "\r\n" : ""))
        }
        let top = terminal.historyTop
        #expect (text (terminal, 0) == "row 0")

        // Exactly one full rotation: every row is pushed out once and the ring is back on
        // the object it started with.
        for i in 0..<capacity {
            terminal.feed (text: "\r\nnew \(i)")
        }
        #expect (text (terminal, 0) == "new 0", "every original row has left")
        #expect (!terminal.historyAdjoins (top), "the reused row object is not the row the cursor named")

        terminal.resize (cols: 80, rows: 50, scrollback: appRing (50))
        let inserted = terminal.prependHistory (olderPage, maxScrollback: appRing (50), adjoining: top)
        #expect (inserted == 0, "the old cursor's page would land above the missing output")
    }

    @Test("the budget never takes the ring below its minimum or above its maximum")
    func clamps () {
        #expect (Terminal.scrollbackLines (budgetBytes: 1 << 20, cols: 500, rows: rows, minimum: 2000, maximum: 20_000) == 2000)
        #expect (Terminal.scrollbackLines (budgetBytes: 1 << 30, cols: 80, rows: rows, minimum: 2000, maximum: 20_000) == 20_000)
        #expect (Terminal.scrollbackLines (budgetBytes: 0, cols: 80, rows: rows, minimum: 0, maximum: 1000) == 0)
    }
}
