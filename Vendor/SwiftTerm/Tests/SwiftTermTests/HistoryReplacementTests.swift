//
//  HistoryReplacementTests.swift
//  SwiftTermTests
//
//  herdr (#726): the embedder replaces a live terminal's history -- after an unpark from
//  a backfill read, after a reconnect from a keyframe -- by feeding it through the same
//  emulator, which kept whatever modes the pane had set. A retained scroll region made
//  the history scroll inside the region instead of into the scrollback: a 300-row
//  backfill kept 24 rows. Fed after `Terminal.historyReplacementSequence`, the history
//  must land exactly as it does on a fresh terminal, whatever the live one kept.
//
//  The steps mirror the app (`LiveTerminalView.Coordinator`): parking frees the
//  scrollback (`changeHistorySize(0)`), unparking gives the ring back, and the reset
//  that follows feeds the history, an SGR reset, then the visible clear and the seed.
//

import Testing
@testable import SwiftTerm

private let cols = 80
private let rows = 24
private let ring = 4000

/// The app's visible clear before a seed (`clearSequence`).
private let clearSequence = "\u{1b}[2J\u{1b}[H"
/// A one-screen keyframe seed, rows separated by CR LF like the server's.
private let seed = (0..<rows).map { "seed \($0)" }.joined (separator: "\r\n")

private func backfill (_ call: Int, _ count: Int = 300) -> String {
    (0..<count).map { "BACKFILL-\(call) row \($0)" }.joined (separator: "\r\n")
}

private func makeTerminal () -> Terminal {
    let (terminal, _) = TerminalTestHarness.makeTerminal (cols: cols, rows: rows, scrollback: ring)
    terminal.preservesScrollbackLayout = true
    return terminal
}

/// Every row of the normal buffer, oldest first.
private func normalText (_ terminal: Terminal) -> [String] {
    (0..<terminal.normalBuffer.lines.count).map {
        terminal.normalBuffer.translateBufferLineToString (lineIndex: $0, trimRight: true)
    }
}

/// A reset on a server whose keyframes carry no history: the backfill read lands above
/// the seed (the app's legacy-backfill branch).
private func resetWithBackfill (_ terminal: Terminal, _ history: String) {
    terminal.feed (byteArray: Terminal.historyReplacementSequence)
    terminal.feed (text: history)
    terminal.feed (text: "\u{1b}[0m")
    terminal.feed (text: clearSequence)
    terminal.feed (text: seed)
}

/// A reset whose keyframe carries history (the app's `seedKeyframeHistory`): after the
/// history, `rows` line feeds scroll exactly the history rows off the top.
private func resetWithKeyframeHistory (_ terminal: Terminal, _ history: String) {
    terminal.feed (byteArray: Terminal.historyReplacementSequence)
    terminal.feed (text: history)
    terminal.feed (text: "\u{1b}[0m" + String (repeating: "\r\n", count: rows))
    terminal.feed (text: clearSequence)
    terminal.feed (text: seed)
}

/// Modes a live pane may have left set when its history is replaced.
private let retainedModes: [(String, String)] = [
    ("a scroll region", "\u{1b}[2;20r"),
    ("a scroll region and origin mode", "\u{1b}[2;20r\u{1b}[?6h"),
    ("left/right margins", "\u{1b}[?69h\u{1b}[10;40s"),
    ("insert mode", "\u{1b}[4h"),
    ("no autowrap", "\u{1b}[?7l"),
    ("DEC line drawing", "\u{1b}(0"),
    ("the alternate screen", "\u{1b}[?1049h"),
]

@Suite("herdr history replacement")
struct HistoryReplacementTests {

    @Test("unparking re-seeds the backfill as a fresh attach does, whatever modes were kept",
          arguments: retainedModes.indices)
    func unparkBackfillMatchesFreshAttach (mode: Int) {
        let (name, modes) = retainedModes [mode]

        let fresh = makeTerminal ()
        resetWithBackfill (fresh, backfill (2))

        // A live pane: attached, its own modes set, output since; then parked and shown.
        let live = makeTerminal ()
        resetWithBackfill (live, backfill (1))
        live.feed (text: "\r\n" + modes)
        for i in 0..<50 { live.feed (text: "live \(i)\r\n") }
        live.changeHistorySize (0)        // park
        live.changeHistorySize (ring)     // unpark
        resetWithBackfill (live, backfill (2))

        let text = normalText (live)
        #expect (text.contains ("BACKFILL-2 row 0"), "\(name): the oldest backfill row reached the scrollback")
        #expect (!text.contains { $0.hasPrefix ("BACKFILL-1") || $0.hasPrefix ("live ") },
                 "\(name): nothing from before the park is left")
        #expect (text == normalText (fresh), "\(name): the buffer is the one a fresh attach builds")
        #expect (!live.isCurrentBufferAlternate, "\(name): history belongs to the main screen")
    }

    @Test("a reconnect's keyframe history lands as on a fresh terminal, whatever modes were kept",
          arguments: retainedModes.indices)
    func keyframeHistoryMatchesFreshTerminal (mode: Int) {
        let (name, modes) = retainedModes [mode]

        let fresh = makeTerminal ()
        resetWithKeyframeHistory (fresh, backfill (2))

        let live = makeTerminal ()
        resetWithKeyframeHistory (live, backfill (1))
        live.feed (text: "\r\n" + modes)
        for i in 0..<50 { live.feed (text: "live \(i)\r\n") }
        resetWithKeyframeHistory (live, backfill (2))

        let text = normalText (live)
        #expect (text.contains ("BACKFILL-2 row 0"), "\(name): the oldest history row reached the scrollback")
        #expect (text == normalText (fresh), "\(name): the buffer is the one a fresh terminal builds")
    }

    @Test("the issue's probe: a 300-row backfill under a retained scroll region keeps its 276 scrollback rows")
    func issueProbe () {
        let live = makeTerminal ()
        resetWithBackfill (live, backfill (1))
        live.feed (text: "\u{1b}[2;20r")
        live.changeHistorySize (0)
        live.changeHistorySize (ring)
        resetWithBackfill (live, backfill (2))

        let kept = normalText (live).filter { $0.hasPrefix ("BACKFILL-2 row ") }.count
        // The last screen of the backfill is erased by the visible clear and repainted by the
        // seed, exactly as on a fresh attach: 300 - 24 rows stay above it.
        #expect (kept == 300 - rows)
    }
}
