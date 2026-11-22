import XCTest
@testable import HerdrKit

/// herdrup#811: a topic Start opened that ended before its first turn returns the reader to
/// the Inbox from any answered list, not only from a `start_failed` this page happened to see.
final class TopicsStartWatchTests: XCTestCase {
    /// The owner missed `start_failed` (Start switched to Topics, between subscriptions), or a
    /// guest (no events): the next list no longer has the topic, and the reader leaves it.
    func testAListWithoutTheStartedTopicReturnsTheReader() {
        var watch = TopicsStartWatch()
        watch.didOpen("t-sug-1")
        XCTAssertNil(watch.endedSelection(selected: "t-sug-1", listed: ["t-1", "t-sug-1"]), "still there")
        XCTAssertEqual(watch.endedSelection(selected: "t-sug-1", listed: ["t-1"]), "t-sug-1")
        XCTAssertTrue(watch.hasFailed("t-sug-1"), "a late Start does not open it")
        XCTAssertNil(watch.endedSelection(selected: "t-sug-1", listed: ["t-1"]), "it leaves once")
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
