import XCTest
@testable import HerdrKit

/// herdrup#795: a suggestion's Start opens its topic only after a list that started after the
/// accept has answered. A list already in flight, or a failed one, does not mean the topic
/// is absent.
@MainActor
final class TopicsListRoundsTests: XCTestCase {
    /// A server and the page's list. `fetch` reads the server when the call starts, like a
    /// list request, and replaces the local list only when it answers.
    private final class Bench {
        var server: [String] = []
        var local: [String] = []
        var calls = 0
        /// Per call (1-based): fail instead of answering.
        var failing: Set<Int> = []
        /// Per call: hold the answer until `release()`.
        var holding: Set<Int> = []
        private var held: CheckedContinuation<Void, Never>?
        var isHolding: Bool { held != nil }

        func fetch() async -> Bool {
            calls += 1
            let call = calls
            let snapshot = server
            if holding.contains(call) { await withCheckedContinuation { held = $0 } }
            if failing.contains(call) { return false }
            local = snapshot
            return true
        }

        func release() {
            held?.resume()
            held = nil
        }
    }

    private final class FakeSleeps: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [UInt64] = []
        var waits: [UInt64] { lock.withLock { recorded } }
        func sleep(_ seconds: UInt64) { lock.withLock { recorded.append(seconds) } }
    }

    /// As `TopicsModel.open`: a topic not in the list waits for a list from after the call.
    private func open(_ id: String, rounds: TopicsListRounds, bench: Bench) async -> Bool {
        if bench.local.contains(id) { return true }
        guard await rounds.listedAfterNow({ await bench.fetch() }) else { return false }
        return bench.local.contains(id)
    }

    private func settle(until done: () -> Bool) async {
        for _ in 0..<1000 where !done() { await Task.yield() }
    }

    /// The owner's event stream starts a list during the accept; it was asked for before the
    /// topic started and comes back without it. Start waits for the next list and opens.
    func testStartWaitsPastAListInFlightDuringTheAccept() async {
        let rounds = TopicsListRounds(sleep: { _ in })
        let bench = Bench()
        bench.holding = [1]
        let inFlight = Task { await rounds.refresh { await bench.fetch() } }
        await settle { bench.isHolding }
        XCTAssertTrue(bench.isHolding, "a list is in flight")
        bench.server = ["t-scroll"]  // the accept starts the topic
        let opening = Task { await self.open("t-scroll", rounds: rounds, bench: bench) }
        await settle { false }
        bench.release()
        let opened = await opening.value
        await inFlight.value
        XCTAssertTrue(opened, "the list after the accept has the topic: Start opens it")
        XCTAssertEqual(bench.calls, 2, "one more list, after the one in flight")
    }

    /// A list that fails keeps the old list: Start asks again and opens on the answer.
    func testStartRetriesAFailedListAndOpensOnTheNextAnswer() async {
        let sleeps = FakeSleeps()
        let rounds = TopicsListRounds(sleep: { sleeps.sleep($0) })
        let bench = Bench()
        bench.server = ["t-scroll"]
        bench.failing = [1]
        let opened = await open("t-scroll", rounds: rounds, bench: bench)
        XCTAssertTrue(opened, "the second list answers with the topic")
        XCTAssertEqual(bench.calls, 2)
        XCTAssertEqual(sleeps.waits, [1])
    }

    /// No list answers: Start does not switch (it cannot tell the topic is missing).
    func testStartGivesUpWhenNoListAnswers() async {
        let sleeps = FakeSleeps()
        let rounds = TopicsListRounds(sleep: { sleeps.sleep($0) })
        let bench = Bench()
        bench.server = ["t-scroll"]
        bench.failing = [1, 2, 3, 4]
        let opened = await open("t-scroll", rounds: rounds, bench: bench)
        XCTAssertFalse(opened)
        XCTAssertEqual(bench.calls, 3, "three lists in all")
        XCTAssertEqual(sleeps.waits, [1, 1])
    }

    /// herdrup#791: a start that failed (the suggestion went back to open) answers a list
    /// without the topic: Start stays on the Inbox.
    func testAnAnsweredListWithoutTheTopicLeavesStartOnTheInbox() async {
        let rounds = TopicsListRounds(sleep: { _ in })
        let bench = Bench()
        let opened = await open("t-failed", rounds: rounds, bench: bench)
        XCTAssertFalse(opened)
        XCTAssertEqual(bench.calls, 1, "one answered list is enough")
    }

    /// A refresh during a list in flight returns at once and makes one more round.
    func testRefreshesDuringAListCoalesceIntoOneMoreRound() async {
        let rounds = TopicsListRounds(sleep: { _ in })
        let bench = Bench()
        bench.holding = [1]
        let first = Task { await rounds.refresh { await bench.fetch() } }
        await settle { bench.isHolding }
        await rounds.refresh { await bench.fetch() }
        await rounds.refresh { await bench.fetch() }
        XCTAssertEqual(bench.calls, 1, "both returned without a list of their own")
        bench.release()
        await first.value
        XCTAssertEqual(bench.calls, 2, "one more round for both")
    }
}
