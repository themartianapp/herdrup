import XCTest
@testable import HerdrKit

/// herdrup#811, #814: a topic Start opened that ended before its first turn returns the reader
/// to the Inbox from any answered list, not only from a `start_failed` this page happened to
/// see. A topic that ran a turn and then leaves the list does not (omp leaves live topics out
/// after a parent-session switch, and a turn that settled without a parked ref).
final class TopicsStartWatchTests: XCTestCase {
    private func topic(_ id: String, _ state: AgentTopicState = .starting, turns: UInt64 = 0) -> AgentTopic {
        AgentTopic(id: id, title: id, state: state, turns: turns)
    }

    /// #811: the owner missed `start_failed` (Start switched to Topics, between subscriptions),
    /// or a guest (no events): the next list no longer has the topic, which never ran a turn,
    /// and the reader leaves it.
    func testAListWithoutTheStartedTopicReturnsTheReader() {
        var watch = TopicsStartWatch()
        watch.didOpen("t-sug-1")
        XCTAssertNil(watch.endedSelection(selected: "t-sug-1", listed: [topic("t-1", .idle, turns: 3), topic("t-sug-1")]),
                     "still there")
        XCTAssertEqual(watch.endedSelection(selected: "t-sug-1", listed: [topic("t-1", .idle, turns: 3)]), "t-sug-1")
        XCTAssertTrue(watch.hasFailed("t-sug-1"), "a late Start does not open it")
        XCTAssertNil(watch.endedSelection(selected: "t-sug-1", listed: [topic("t-1", .idle, turns: 3)]), "it leaves once")
    }

    /// #814: the started topic ran a turn, then the list leaves it out (a parent-session
    /// switch; a settled turn without a parked ref). The reader stays on it.
    func testAStartedTopicThatRanATurnAndLeavesTheListKeepsTheReader() {
        var watch = TopicsStartWatch()
        watch.didOpen("t-sug-1")
        XCTAssertNil(watch.endedSelection(selected: "t-sug-1", listed: [topic("t-sug-1", .running)]))
        XCTAssertNil(watch.endedSelection(selected: "t-sug-1", listed: []), "it started: out of the list is not a failed start")
        XCTAssertFalse(watch.hasFailed("t-sug-1"))

        var settled = TopicsStartWatch()
        settled.didOpen("t-sug-2")
        XCTAssertNil(settled.endedSelection(selected: "t-sug-2", listed: [topic("t-sug-2", .idle, turns: 1)]))
        XCTAssertNil(settled.endedSelection(selected: "t-sug-2", listed: []))
        XCTAssertFalse(settled.hasFailed("t-sug-2"))
    }

    /// #814: a topic the list left out before its first turn comes back in a later list (the
    /// session switched back): it is not failed any more, so the Inbox's "Continued in topic"
    /// line opens it again. `start_failed` stays for good.
    func testATopicThatReappearsOpensAgain() {
        var watch = TopicsStartWatch()
        watch.didOpen("t-sug-1")
        XCTAssertEqual(watch.endedSelection(selected: "t-sug-1", listed: []), "t-sug-1")
        XCTAssertTrue(watch.hasFailed("t-sug-1"))
        XCTAssertNil(watch.endedSelection(selected: nil, listed: [topic("t-sug-1", .idle, turns: 2)]))
        XCTAssertFalse(watch.hasFailed("t-sug-1"), "listed again: the Inbox line opens it")

        watch.didFail("t-sug-3")
        XCTAssertNil(watch.endedSelection(selected: nil, listed: [topic("t-sug-3")]))
        XCTAssertTrue(watch.hasFailed("t-sug-3"), "start_failed is for good")
    }

    /// Only a topic a Start opened, and only the selected one: a topic picked from the list,
    /// or one the reader already left, is not this page's to undo.
    func testOnlyTheSelectedTopicAStartOpenedLeaves() {
        var watch = TopicsStartWatch()
        watch.didOpen("t-sug-1")
        XCTAssertNil(watch.endedSelection(selected: "t-1", listed: []), "picked from the list")
        XCTAssertNil(watch.endedSelection(selected: nil, listed: []), "nothing selected")
        XCTAssertFalse(watch.hasFailed("t-sug-1"), "not selected: not judged")
        XCTAssertEqual(watch.endedSelection(selected: "t-sug-1", listed: []), "t-sug-1")
    }
}
