//
//  HerdrLiveScreenTests.swift
//  SwiftTermTests
//
//  herdr: the live screen's text, as the app keeps it for the next cold start. Every
//  character must survive, an erased screen must read as blank, and scrolling the
//  viewport must not change what is kept.
//

import Testing
@testable import SwiftTerm

@Suite("herdr live screen rows")
struct HerdrLiveScreenTests {

    @Test("emoji and combining marks survive")
    func graphemesSurvive () {
        let (terminal, _) = TerminalTestHarness.makeTerminal (cols: 40, rows: 4)
        // A wide emoji outside the BMP, and an e with a combining acute accent: both are
        // stored as terminal-local indices, not as their code points.
        terminal.feed (text: "OK \u{1F600} e\u{0301} tail\r\nnext")

        #expect (terminal.liveScreenRows () == ["OK \u{1F600} e\u{0301} tail", "next", "", ""])
    }

    @Test("an erased screen reads as blank rows")
    func erasedScreenIsBlank () {
        let (terminal, _) = TerminalTestHarness.makeTerminal (cols: 40, rows: 3)
        terminal.feed (text: "$ cargo test\r\nok\r\n$ ")
        // A space the program wrote is a cell, not a blank one, so "$ " keeps it.
        #expect (terminal.liveScreenRows () == ["$ cargo test", "ok", "$ "])

        terminal.feed (text: "\u{1b}[2J\u{1b}[H")

        #expect (terminal.liveScreenRows () == ["", "", ""])
    }

    @Test("the live rows, not the scrolled viewport")
    func liveRowsNotViewport () {
        let (terminal, _) = TerminalTestHarness.makeTerminal (cols: 40, rows: 3, scrollback: 100)
        for i in 1...20 {
            terminal.feed (text: "line \(i)\r\n")
        }
        terminal.feed (text: "$ ")
        terminal.userScrolling = true
        terminal.buffer.yDisp = 0

        #expect (terminal.liveScreenRows () == ["line 19", "line 20", "$ "])
    }
}
