import SwiftUI
import Foundation
import UIKit    // UIPasteboard (Copy diagnostics)
import UniformTypeIdentifiers
import StoreKit // Product / tip jar (Settings' Support section)
import UserNotifications // notification authorization status (Settings notify section)
import HerdrKit

#if DEBUG
/// The roster stress fixture's arm control. Its accessibility value says whether
/// the arm action actually ran, so the UI test can confirm the precondition it depends
/// on instead of finding a dropped tap only as a missing deferred row much later.
struct RosterStressArmControl: View {
    let driver: RosterStressDriver
    @State private var armed = false

    var body: some View {
        Button {
            driver.arm()
            armed = true
        } label: {
            Color.clear.frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Arm roster refresh stress")
        .accessibilityValue(armed ? "armed" : "idle")
        .accessibilityIdentifier("roster-stress-arm")
    }
}

/// Keeps the precondition roster stable, then starts changing row count, row status and
/// sections only after a real scroll begins. Active-scroll snapshots contain a deferred
/// marker and an actual phase-dependent roster row, then polling blocks once the gesture
/// is idle. Those changes can reach the screen only through pending-snapshot promotion.
/// If the app changes its displayed snapshot while scrolling, a distinct violation row
/// makes that mutant fail the receipt.
final class RosterStressDriver: @unchecked Sendable {
    private let lock = NSLock()
    private var scrollRefreshCount = 0
    private var armed = false
    private var scrollingActive = false
    private var deferredServed = false
    private var publishedWhileScrolling = false
    private var violationServed = false
    private var eagerStackVisible = false

    func recordScrolling(_ scrolling: Bool) {
        lock.withLock { scrollingActive = armed && scrolling }
    }

    func arm() {
        lock.withLock { armed = true }
    }

    func recordEagerStackVisible() {
        lock.withLock { eagerStackVisible = true }
    }

    func recordRosterPublication(whileScrolling: Bool) {
        guard whileScrolling else { return }
        lock.withLock { publishedWhileScrolling = true }
    }

    func nextAgentList() async throws -> String {
        let responseState: (
            phase: Int,
            includesDeferred: Bool,
            includesViolation: Bool,
            includesEagerReceipt: Bool
        )? = lock.withLock {
            if deferredServed, !scrollingActive {
                guard publishedWhileScrolling, !violationServed else { return nil }
                violationServed = true
                return (
                    (scrollRefreshCount % 2) + 1,
                    false,
                    true,
                    eagerStackVisible
                )
            }
            guard scrollingActive else {
                // No 50 ms churn before the first gesture. Repeated responses are
                // byte-equivalent and receiveRoster equality-gates them, so cold
                // layout is a precondition rather than a second stress scenario.
                return (0, false, false, eagerStackVisible)
            }
            scrollRefreshCount += 1
            deferredServed = true
            return (
                (scrollRefreshCount % 2) + 1,
                true,
                publishedWhileScrolling,
                eagerStackVisible
            )
        }
        guard let responseState else {
            try await Task.sleep(nanoseconds: 300_000_000_000)
            return MockWireFixtures.agentList
        }

        let phase = responseState.phase
        let count: Int
        switch phase {
        case 0: count = 80
        case 1: count = 82
        default: count = 81
        }
        var agents: [[String: Any]] = (0..<count).map { index in
            let statusIndex = (index + phase) % 3
            let status = ["blocked", "working", "idle"][statusIndex]
            return [
                "pane_id": String(format: "stress:p%03d", index),
                "name": String(format: "stress-agent-%03d", index),
                "agent": "claude",
                "agent_status": status,
                "cwd": "/root/stress",
                "terminal_title_stripped": "refreshing roster while scrolling",
                "account": "acc-claude-1",
                "last_completed_turn": ["completed_unix_ms": 2_000_000_000_000 - index - phase],
            ]
        }
        agents.append([
            "pane_id": "stress:top",
            "name": "scroll-top-marker",
            "agent": "claude",
            "agent_status": "blocked",
            "cwd": "/root/stress",
            "terminal_title_stripped": "must move off screen",
            "last_completed_turn": ["completed_unix_ms": 2_000_000_000_002],
        ])
        agents.append([
            "pane_id": "stress:bottom",
            "name": "scroll-bottom-marker",
            "agent": "claude",
            // The Idle section starts collapsed. Keep this marker at the bottom of
            // the expanded Working section so the UI test can prove displacement.
            "agent_status": "working",
            "cwd": "/root/stress",
            "terminal_title_stripped": "must become visible",
            "last_completed_turn": ["completed_unix_ms": 1],
        ])
        agents.append([
            "pane_id": "stress:phase",
            "name": phase == 0
                ? "stable-pre-scroll-phase-marker"
                : "scroll-refresh-phase-\(phase)-marker",
            "agent": "claude",
            "agent_status": phase == 0 ? "blocked" : "working",
            "cwd": "/root/stress",
            "terminal_title_stripped": "actual generated roster phase",
            "last_completed_turn": ["completed_unix_ms": 2_000_000_000_001],
        ])
        if responseState.includesDeferred {
            agents.append([
                "pane_id": "stress:deferred",
                "name": "deferred-refresh-marker",
                "agent": "claude",
                "agent_status": "blocked",
                "cwd": "/root/stress",
                "terminal_title_stripped": "must be promoted after scrolling",
                "last_completed_turn": ["completed_unix_ms": 2_000_000_000_003],
            ])
        }
        if responseState.includesViolation {
            agents.append([
                "pane_id": "stress:coalescing-violation",
                "name": "coalescing-violation-marker",
                "agent": "claude",
                "agent_status": "blocked",
                "cwd": "/root/stress",
                "terminal_title_stripped": "roster published while scrolling",
                "last_completed_turn": ["completed_unix_ms": 2_000_000_000_004],
            ])
        }
        if responseState.includesEagerReceipt {
            agents.append([
                "pane_id": "stress:eager-stack",
                "name": "eager-stack-marker",
                "agent": "claude",
                "agent_status": "blocked",
                "cwd": "/root/stress",
                "terminal_title_stripped": "eager roster stack is active",
                "last_completed_turn": ["completed_unix_ms": 2_000_000_000_005],
            ])
        }
        let payload: [String: Any] = [
            "id": "mock",
            "result": ["type": "agent_list", "agents": agents],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return MockWireFixtures.agentList
        }
        return text
    }
}

/// Stand-in for a daemon that windows history into its keyframes (herdr#301). `agent.read`
/// has no history; every history read (agent.read, source=recent) is counted in `reads`.
///
/// By default (`keyframehistory`, the reconnect receipt) the FIRST `pane.stream` delivers a
/// screen-only keyframe and then ends — a dropped stream the app must reconnect in place (no
/// remount, no backfill). Every later stream's keyframe carries 300 numbered history rows in
/// `history_b64`, so scrollback can only come from the reconnect's keyframe.
///
/// With `historyFromFirstKeyframe` (`keyframehistoryread`, the redundant-read receipt) every
/// keyframe carries the history and the first stream stays open, as on a current server, and
/// each history read is held for `heldReadNanos` before it answers. `reads` then shows whether
/// the app cancelled the read once the first keyframe arrived, or let it run to its answer.
final class KeyframeHistoryDriver: @unchecked Sendable {
    /// Counts of history reads: requested, answered, and cancelled while held.
    final class ReadLog: @unchecked Sendable {
        private let lock = NSLock()
        private var requested = 0, answered = 0, cancelled = 0

        fileprivate func requestedOne() { lock.withLock { requested += 1 } }
        fileprivate func answeredOne() { lock.withLock { answered += 1 } }
        fileprivate func cancelledOne() { lock.withLock { cancelled += 1 } }

        var summary: String {
            lock.withLock { "requested=\(requested) answered=\(answered) cancelled=\(cancelled)" }
        }
    }

    /// Process-wide, like the gram mock's call logs: the mock view may rebuild its transport.
    static let reads = ReadLog()
    /// Shorter than the app's 6 s backfill timeout, whose expiry also cancels the read: a read
    /// cancelled while held was cancelled by something other than that timeout.
    static let heldReadNanos: UInt64 = 3_000_000_000

    private let historyFromFirstKeyframe: Bool
    private let lock = NSLock()
    private var opens = 0

    init(historyFromFirstKeyframe: Bool = false) {
        self.historyFromFirstKeyframe = historyFromFirstKeyframe
    }

    /// Answers an `agent.read`. Only source=recent is the backfill's history read.
    func read(_ requestLine: String) async throws -> String {
        guard requestLine.contains(#""source":"recent""#) else { return MockWireFixtures.agentRead }
        Self.reads.requestedOne()
        if historyFromFirstKeyframe {
            do {
                try await Task.sleep(nanoseconds: Self.heldReadNanos)
            } catch {
                Self.reads.cancelledOne()
                throw error
            }
        }
        Self.reads.answeredOne()
        return MockWireFixtures.agentRead
    }

    func stream() -> AsyncThrowingStream<String, Error> {
        let attempt: Int = lock.withLock {
            opens += 1
            return opens
        }
        let history = historyFromFirstKeyframe || attempt > 1
        return AsyncThrowingStream { continuation in
            continuation.yield(MockWireFixtures.paneStreamAck)
            continuation.yield(Self.resetFrame(history: history))
            if !history {
                // Dropped: the app's in-place reconnect must recover the history.
                continuation.finish()
                return
            }
            let pings = MockTransport.keepAlive(continuation)
            continuation.onTermination = { _ in pings.cancel() }
        }
    }

    /// Varied rows (like the backfill fixture) so distinct regions of history render
    /// visibly differently and a scroll moves pixels; cursor hidden so frames are static.
    private static func resetFrame(history: Bool) -> String {
        let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf"]
        var past = ""
        if history {
            for n in 1...300 {
                let pad = String(repeating: "=", count: (n * 7) % 30)
                past += "\u{1b}[3\(1 + n % 6)mhistory \(n) \(words[n % words.count]) \(pad)\u{1b}[0m\r\n"
            }
        }
        var screen = "\u{1b}[?25l"
        for n in 1...8 { screen += "live row \(n)\r\n" }
        screen += "$ "
        var object: [String: Any] = [
            "stream": "pane.bytes", "frame": "reset", "seq": 0, "epoch": 7, "cols": 80, "rows": 24,
            "data_b64": Data(screen.utf8).base64EncodedString(),
        ]
        if history { object["history_b64"] = Data(past.utf8).base64EncodedString() }
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// DEBUG receipt for the redundant-history-read test: `KeyframeHistoryDriver.reads` as the
/// label of `keyframe-history-reads`, refreshed while the mock pane is up.
struct KeyframeHistoryReadProbe: View {
    @State private var summary = KeyframeHistoryDriver.reads.summary

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityIdentifier("keyframe-history-reads")
            .accessibilityLabel(summary)
            .task {
                while !Task.isCancelled {
                    let now = KeyframeHistoryDriver.reads.summary
                    if now != summary { summary = now }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
    }
}

/// Stand-in for a `pane_history` daemon (terminal history paging). The pane's whole history
/// is rows `older 1` ... `older 2300`; the keyframe carries the newest 300 of them with a
/// `history_cursor` for row 2001, and `pane.history` serves the rows above any cursor, a page
/// at a time, down to row 1 (null cursor). Every page is held for `heldPageNanos` so the
/// loading capsule stays on screen long enough for a UI test polling it every 0.1 s after the
/// request to see it. Each request's cursor is logged in order, so a test can tell whether the
/// app chained the cursors it was given.
/// `HERDR_MOCK_HISTORY_KEYFRAME_ROWS` shortens the keyframe's history (a pane within a screen
/// of the top of its history, which pages on request rather than by itself).
final class HistoryPagingDriver: @unchecked Sendable {
    final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var cursors: [String] = []

        fileprivate func requested(_ cursor: String) { lock.withLock { cursors.append(cursor) } }

        /// "requests=N cursors=a,b,…".
        var summary: String {
            lock.withLock { "requests=\(cursors.count) cursors=\(cursors.joined(separator: ","))" }
        }
    }

    static let requests = RequestLog()
    static let totalRows = 2300
    static let keyframeRows =
        ProcessInfo.processInfo.environment["HERDR_MOCK_HISTORY_KEYFRAME_ROWS"].flatMap(Int.init) ?? 300
    static let heldPageNanos: UInt64 = 2_000_000_000
    /// The mock pane's terminal, for `scrollToTop`. Every DEBUG attach registers; only this
    /// mock keeps it.
    @MainActor private static weak var terminal: UIScrollView?

    @MainActor static func register(_ view: UIScrollView) {
        guard ScreenshotMock.mode == .historyPaging else { return }
        terminal = view
    }

    /// Puts the terminal at the top of its scrollback the way a Mac wheel or trackpad scroll
    /// can: an offset write with no drag and no deceleration behind it.
    @MainActor static func scrollToTop() {
        terminal?.setContentOffset(.zero, animated: false)
    }

    private static func row(_ n: Int) -> String {
        let pad = String(repeating: "-", count: (n * 7) % 30)
        return "\u{1b}[3\(1 + n % 6)molder \(n) \(pad)\u{1b}[0m"
    }

    /// Answers a `pane.history` request line.
    func page(_ requestLine: String) async throws -> String {
        let object = (try? JSONSerialization.jsonObject(with: Data(requestLine.utf8))) as? [String: Any]
        let params = object?["params"] as? [String: Any]
        let cursor = params?["cursor"] as? String ?? ""
        let lines = params?["lines"] as? Int ?? 500
        Self.requests.requested(cursor)
        try await Task.sleep(nanoseconds: Self.heldPageNanos)
        guard cursor.hasPrefix("hc-"), let above = Int(cursor.dropFirst(3)), above >= 1 else {
            return #"{"id":"mock","error":{"code":"history_cursor_expired","message":"history cursor expired"}}"#
        }
        let first = max(1, above - lines)
        let rows = (first..<above).map(Self.row).joined(separator: "\r\n")
        let result: [String: Any] = [
            "type": "pane_history", "pane_id": "w1:p1",
            "history_b64": Data(rows.utf8).base64EncodedString(),
            "rows": above - first,
            "cursor": first > 1 ? "hc-\(first)" : NSNull(),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: ["id": "mock", "result": result])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    func stream() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(MockWireFixtures.paneStreamAck)
            continuation.yield(Self.resetFrame())
            let pings = MockTransport.keepAlive(continuation)
            continuation.onTermination = { _ in pings.cancel() }
        }
    }

    private static func resetFrame() -> String {
        let oldestSent = totalRows - keyframeRows + 1
        let past = (oldestSent...totalRows).map(row).joined(separator: "\r\n") + "\r\n"
        var screen = "\u{1b}[?25l"
        for n in 1...8 { screen += "live row \(n)\r\n" }
        screen += "$ "
        let object: [String: Any] = [
            "stream": "pane.bytes", "frame": "reset", "seq": 0, "epoch": 7, "cols": 80, "rows": 24,
            "data_b64": Data(screen.utf8).base64EncodedString(),
            "history_b64": Data(past.utf8).base64EncodedString(),
            "history_cursor": "hc-\(oldestSent)",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// DEBUG receipt for the history-paging test: `HistoryPagingDriver.requests` as the label of
/// `history-paging-requests`, refreshed while the mock pane is up, and the
/// `history-scroll-top` action (see `HistoryPagingDriver.scrollToTop`).
struct HistoryPagingProbe: View {
    @State private var summary = HistoryPagingDriver.requests.summary

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityIdentifier("history-paging-requests")
                .accessibilityLabel(summary)
            Button("top") { HistoryPagingDriver.scrollToTop() }
                .font(.caption2)
                .accessibilityIdentifier("history-scroll-top")
        }
        .task {
            while !Task.isCancelled {
                let now = HistoryPagingDriver.requests.summary
                if now != summary { summary = now }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
}

/// Stateful stand-in for a Claude-Code pane in the `ccscroll` UI test. It puts the REAL
/// SwiftTerm view into MOUSE-MODE on the normal buffer (see `attach`), then —
/// each time the app SENDS it an SGR wheel event (`ESC[<64`/`<65`, proof the finger-drag
/// was translated to wheel for a mouse-mode agent) — redraws the screen shifted by a few
/// lines, standing in for Claude Code scrolling its own viewport. So the XCUITest proves
/// the whole path: drag → app emits SGR wheel → rendered content moves. If the app fails
/// to emit wheel (the bug), no redraw happens and the screenshots stay identical → FAIL.
final class CCScrollDriver: @unchecked Sendable {
    static let shared = CCScrollDriver()

    private let lock = NSLock()
    private var cont: AsyncThrowingStream<String, Error>.Continuation?
    private var seq: UInt64 = 1
    private var offset = 0            // 0 = newest window (bottom); grows toward older

    /// Called when `pane.stream` opens: keep the continuation, turn on mouse tracking on
    /// the NORMAL (main) buffer, and render the initial window.
    ///
    /// Deliberately NOT the alternate screen: on the alt buffer the OLD gate
    /// (`guard isCurrentBufferAlternate`) already passed, so an alt seed couldn't prove
    /// the new `|| mouseMode != .off` branch is what makes a mouse-mode agent scrollable
    /// (reviewer HIGH). Seeding mouse-mode on the NORMAL buffer exercises exactly the new
    /// branch AND the isScrollEnabled toggle — and would be RED on the old alt-only gate
    /// (a normal-buffer drag returned early → no wheel → static).
    func attach(_ c: AsyncThrowingStream<String, Error>.Continuation) {
        lock.lock(); cont = c; offset = 0; lock.unlock()
        // ?1000h+?1006h mouse tracking (SGR), like Claude Code · ?25l hide cursor. NO
        // ?1049h — stays on the normal buffer so `isCurrentBufferAlternate == false`.
        let body = "\u{1b}[?1000h\u{1b}[?1006h\u{1b}[?25l" + renderWindow()
        c.yield(resetFrame(body))
    }

    /// Inspect an outgoing request; if it carries an SGR wheel event, scroll + redraw.
    func received(_ requestLine: String) {
        let up = requestLine.contains("[<64")      // wheel-up → older content
        let down = requestLine.contains("[<65")    // wheel-down → newer content
        guard up || down else { return }
        lock.lock()
        offset = max(0, min(offset + (up ? 4 : -4), 170))
        let frame = dataFrame(renderWindow())
        let c = cont
        lock.unlock()
        c?.yield(frame)
    }

    /// A 24-row window into a 200-line virtual transcript at the current `offset`,
    /// cleared + home-positioned so each redraw fully repaints the visible screen.
    /// Each row is a FULL-WIDTH band of a character keyed to its line number, so a
    /// scroll (window shift) changes most pixels on screen — a subtle number-only tweak
    /// would fall under the test's pixel-diff threshold even when the scroll DID happen.
    private func renderWindow() -> String {
        var s = "\u{1b}[H\u{1b}[2J"
        let top = max(1, 200 - 24 - offset)
        for i in 0..<24 {
            let n = top + i
            let fill = Character(UnicodeScalar(UInt8(65 + (n % 26))))   // A..Z by line number
            s += String(format: "CC%03d ", n) + String(repeating: fill, count: 60) + "\r\n"
        }
        return s
    }

    private func resetFrame(_ body: String) -> String {
        let b64 = Data(body.utf8).base64EncodedString()
        return "{\"stream\":\"pane.bytes\",\"frame\":\"reset\",\"seq\":0,\"epoch\":7,\"cols\":80,\"rows\":24,\"data_b64\":\"\(b64)\"}"
    }
    private func dataFrame(_ body: String) -> String {
        let b64 = Data(body.utf8).base64EncodedString()
        let s = seq; seq += 1
        return "{\"stream\":\"pane.bytes\",\"frame\":\"data\",\"seq\":\(s),\"epoch\":7,\"data_b64\":\"\(b64)\"}"
    }
}
#endif
