import XCTest
@testable import HerdrKit

/// herdrup#797: `agent.topics.organise` only says the turn was queued. Organise is over on a
/// new proposal or after 3 minutes, so a turn that proposes nothing does not leave it running.
final class TopicsOrganiseWaitTests: XCTestCase {
    private let asked = Date(timeIntervalSince1970: 1_800_000_000)

    func testItWaitsThreeMinutesByDefault() {
        var wait = TopicsOrganiseWait()
        wait.start(at: asked, open: [])
        XCTAssertEqual(wait.deadline, asked.addingTimeInterval(180))
    }

    /// A turn that proposes nothing: lists keep coming without a new id; the deadline ends it.
    func testATurnThatProposesNothingEndsAtTheDeadline() {
        var wait = TopicsOrganiseWait(timeout: 180)
        wait.start(at: asked, open: [])
        XCTAssertTrue(wait.isRunning)
        XCTAssertFalse(wait.end(open: [], now: asked.addingTimeInterval(30)), "still running")
        XCTAssertFalse(wait.end(open: nil, now: asked.addingTimeInterval(179)), "not yet")
        XCTAssertTrue(wait.end(open: [], now: asked.addingTimeInterval(180)), "over at the deadline")
        XCTAssertFalse(wait.isRunning)
        XCTAssertFalse(wait.end(open: nil, now: asked.addingTimeInterval(400)), "ends once")
    }

    /// The clock alone ends it too: back on Topics with no list answering.
    func testTheClockAloneEndsItAfterTheDeadline() {
        var wait = TopicsOrganiseWait(timeout: 2)
        wait.start(at: asked, open: [])
        XCTAssertTrue(wait.end(open: nil, now: asked.addingTimeInterval(5)))
    }

    /// Proposing again only what is already open is not a new proposal; the deadline ends it.
    func testOnlyReproposedIDsWaitForTheDeadline() {
        var wait = TopicsOrganiseWait(timeout: 180)
        wait.start(at: asked, open: ["sg-scroll"])
        XCTAssertFalse(wait.end(open: ["sg-scroll"], now: asked.addingTimeInterval(10)))
        XCTAssertTrue(wait.end(open: ["sg-scroll"], now: asked.addingTimeInterval(181)))
    }

    /// A new proposal still ends it at once.
    func testANewProposalEndsItAtOnce() {
        var wait = TopicsOrganiseWait(timeout: 180)
        wait.start(at: asked, open: ["sg-scroll"])
        XCTAssertTrue(wait.end(open: ["sg-scroll", "sg-bench"], now: asked.addingTimeInterval(1)))
        XCTAssertFalse(wait.isRunning)
    }

    /// Not running: nothing to end.
    func testNothingEndsWhenOrganiseWasNotAsked() {
        var wait = TopicsOrganiseWait(timeout: 180)
        XCTAssertFalse(wait.end(open: ["sg-scroll"], now: asked))
        wait.start(at: asked, open: [])
        wait.stop()
        XCTAssertFalse(wait.end(open: nil, now: asked.addingTimeInterval(500)))
    }
}
