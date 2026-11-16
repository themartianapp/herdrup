import UIKit
import XCTest
@testable import Herdr

/// The terminal's memory bounds (#687): the owner's iPad ran out of memory after three days
/// with the app open. A released terminal view must actually be freed, a terminal's ring must
/// stay inside its byte budget at any width, and a pane left hidden must give its scrollback
/// back and re-seed when it is shown again.
@MainActor
final class TerminalMemoryTests: XCTestCase {
    private typealias Coordinator = LiveTerminalView.Coordinator

    /// SwiftTerm's display link retained the view it drew, and the run loop retained the link,
    /// so every terminal view ever mounted (a remount on every return to the foreground, an
    /// LRU eviction, a session switch) stayed alive with its whole scrollback.
    func testAReleasedTerminalViewIsFreed() async throws {
        weak var released: LiveTerminalView.ReadOnlyTerminalView?
        autoreleasepool {
            let view = LiveTerminalView.ReadOnlyTerminalView(
                frame: CGRect(x: 0, y: 0, width: 400, height: 300), font: nil)
            view.feed(text: "hello\r\n")
            released = view
        }
        // The feed queued a repaint ~16 ms out that holds the view until it runs.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(released, "nothing may keep a terminal view, and its scrollback, alive once its host lets go")
    }

    /// 20,000 rows were 41 MB at 80 columns and 123 MB at 250. The ring a pane can page to is
    /// lowered to the budget for the grid it is at, and a long feed stays inside it.
    func testALongFeedStaysInsideTheBudgetAtEveryWidth() {
        for cols in [80, 160, 250] {
            let rows = 50
            let view = LiveTerminalView.ReadOnlyTerminalView(
                frame: CGRect(x: 0, y: 0, width: 400, height: 300), font: nil)
            let terminal = view.getTerminal()
            terminal.resize(cols: cols, rows: rows)
            let ring = Coordinator.scrollbackRing(Coordinator.historyScrollbackCap, cols: cols, rows: rows)
            XCTAssertGreaterThanOrEqual(ring, Coordinator.minimumScrollback, "\(cols) columns")
            terminal.changeHistorySize(ring)
            let row = String(repeating: "x", count: cols - 1) + "\r\n"
            for _ in 0..<(ring + rows + 200) { view.feed(text: row) }

            XCTAssertEqual(terminal.normalBufferRowCount, ring + rows, "\(cols) columns: the ring is full")
            XCTAssertLessThanOrEqual(terminal.normalBufferBytes, Coordinator.scrollbackBudgetBytes,
                                     "\(cols) columns")
        }
    }

    #if DEBUG
    /// A pane hidden past the grace stops streaming and frees its scrollback; shown again it
    /// re-opens the stream, whose keyframe replaces the screen, and gets its ring back.
    func testAParkedPaneFreesItsScrollbackAndReseedsWhenShown() async throws {
        let coordinator = Coordinator(client: .init(transport: MockTransport()), paneID: "w1:p1")
        let view = LiveTerminalView.ReadOnlyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600), font: nil)
        coordinator.attach(LiveTerminalView.TerminalSurfaceView(terminal: view))
        defer { coordinator.stop(dismantling: true) }
        let terminal = view.getTerminal()
        let initialRing = terminal.options.scrollback

        try await waitUntil("the first keyframe raised the ring and painted its seed") {
            terminal.options.scrollback != initialRing && self.screen(view).contains("mock render")
        }
        let warmRing = terminal.options.scrollback
        let cols = terminal.cols
        let row = String(repeating: "x", count: max(1, cols - 1)) + "\r\n"
        for _ in 0..<(warmRing + 500) { view.feed(text: row) }
        view.feed(text: "PARKED-MARKER")
        let warmBytes = terminal.normalBufferBytes
        XCTAssertLessThanOrEqual(warmBytes, Coordinator.scrollbackBudgetBytes)

        coordinator.setForeground(false)
        coordinator.park()

        XCTAssertEqual(terminal.normalBufferRowCount, terminal.rows, "parking frees the whole scrollback")
        XCTAssertLessThan(terminal.normalBufferBytes, warmBytes / 10)
        XCTAssertTrue(screen(view).contains("PARKED-MARKER"), "the screen stays until the re-seed")

        coordinator.setForeground(true)

        try await waitUntil("showing the pane re-seeded it from a fresh keyframe") {
            !self.screen(view).contains("PARKED-MARKER") && self.screen(view).contains("mock render")
        }
        XCTAssertEqual(terminal.options.scrollback, warmRing, "the ring is back at its budget")
    }

    /// Review of #694: parking cancels a pending reconnect without stopping the pane, and the
    /// reconnect's sleep swallowed the cancellation (`try?`) and restarted the stream anyway,
    /// with nothing left to park it again.
    func testParkingCancelsAPendingReconnect() async throws {
        var transport = TerminalParkingMockTransport()
        transport.dropsStreams = true
        let server = transport.server
        let coordinator = Coordinator(client: .init(transport: transport), paneID: "w1:p1")
        let view = LiveTerminalView.ReadOnlyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600), font: nil)
        coordinator.attach(LiveTerminalView.TerminalSurfaceView(terminal: view))
        defer { coordinator.stop(dismantling: true) }

        // Every stream ends after its keyframe, so from here on a reconnect is always pending
        // (its backoff sleeps at least 0.3 s) or a stream is just opening.
        try await waitUntil("the pane reconnected at least once") { server.streamsOpened >= 2 }
        coordinator.setForeground(false)
        coordinator.park()
        let opened = server.streamsOpened

        try await Task.sleep(nanoseconds: 3_000_000_000)   // past the backoff's 0.5 s ceiling, twice over
        XCTAssertEqual(server.streamsOpened, opened, "a parked pane opens no stream")

        coordinator.setForeground(true)
        try await waitUntil("showing the pane opened its stream again") { server.streamsOpened > opened }
    }

    /// Review of #694: on a server whose keyframes carry no history, the scrollback comes from
    /// the `agent.read` backfill, which only the first reset fed. An unparked pane re-seeds like
    /// a fresh attach: a fresh read restores what scrolled off while it was parked, and none of
    /// the history it held before is left under it, so nothing is doubled.
    func testUnparkingRefreshesTheBackfillOnAnOlderServer() async throws {
        let transport = TerminalParkingMockTransport()
        let server = transport.server
        let coordinator = Coordinator(client: .init(transport: transport), paneID: "w1:p1")
        let view = LiveTerminalView.ReadOnlyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600), font: nil)
        coordinator.attach(LiveTerminalView.TerminalSurfaceView(terminal: view))
        defer { coordinator.stop(dismantling: true) }

        try await waitUntil("the first reset fed the first backfill above its seed") {
            self.allText(view).contains("BACKFILL-1 row 0") && self.screen(view).contains("mock render")
        }

        coordinator.setForeground(false)
        coordinator.park()
        XCTAssertFalse(allText(view).contains("BACKFILL-1 row 0"), "parking freed the scrollback")
        coordinator.setForeground(true)

        try await waitUntil("the re-seed fed a fresh backfill above its seed") {
            self.allText(view).contains("BACKFILL-2 row 0") && self.screen(view).contains("mock render")
        }
        XCTAssertEqual(server.backfillReads, 2)
        let text = allText(view)
        XCTAssertFalse(text.contains("BACKFILL-1"), "nothing from before the park is left under the re-seed")
        XCTAssertEqual(text.components(separatedBy: "BACKFILL-2 row 0\n").count, 2, "the fresh history is fed once")
    }
    #endif

    /// The visible rows. Takes the view, not its `Terminal`: this target does not import SwiftTerm.
    private func screen(_ view: LiveTerminalView.ReadOnlyTerminalView) -> String {
        let terminal = view.getTerminal()
        return (0..<terminal.rows)
            .compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
            .joined(separator: "\n")
    }

    /// Every row the normal buffer holds, scrollback and screen, oldest first.
    private func allText(_ view: LiveTerminalView.ReadOnlyTerminalView) -> String {
        let terminal = view.getTerminal()
        let first = terminal.buffer.totalLinesTrimmed
        return (0..<terminal.normalBufferRowCount)
            .compactMap { terminal.getScrollInvariantLine(row: first + $0)?.translateToString(trimRight: true) }
            .joined(separator: "\n")
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 15,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting: \(what)")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
