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

/// The ring the embedder would set for `cols`: the most it pages to, lowered to the budget.
private func ring (cols: Int) -> Int {
    Terminal.scrollbackLines (budgetBytes: budget, cols: cols, rows: rows, minimum: 0, maximum: 20_000)
}

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

    @Test("the budget never takes the ring below its minimum or above its maximum")
    func clamps () {
        #expect (Terminal.scrollbackLines (budgetBytes: 1 << 20, cols: 500, rows: rows, minimum: 2000, maximum: 20_000) == 2000)
        #expect (Terminal.scrollbackLines (budgetBytes: 1 << 30, cols: 80, rows: rows, minimum: 2000, maximum: 20_000) == 20_000)
        #expect (Terminal.scrollbackLines (budgetBytes: 0, cols: 80, rows: rows, minimum: 0, maximum: 1000) == 0)
    }
}
