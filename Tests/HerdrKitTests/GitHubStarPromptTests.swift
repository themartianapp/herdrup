import XCTest
@testable import HerdrKit

final class GitHubStarPromptTests: XCTestCase {
    private typealias P = GitHubStarPrompt

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "herdr.starprompt.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private func send(_ count: Int, author: TranscriptAuthor = .owner,
                      delivery: PromptDelivery? = .submitted, in defaults: UserDefaults) {
        for _ in 0..<count { P.recordPrompt(author: author, delivery: delivery, in: defaults) }
    }

    func testRepositoryAndThreshold() {
        XCTAssertEqual(P.repositoryURL.absoluteString, "https://github.com/themartianapp/herdrup")
        XCTAssertEqual(P.threshold, 5)
    }

    func testNotShownBeforeFiveOwnerPrompts() throws {
        try withDefaults { defaults in
            XCTAssertFalse(P.isDue(in: defaults), "a fresh install shows nothing")
            send(4, in: defaults)
            XCTAssertEqual(defaults.integer(forKey: P.sentPromptsKey), 4)
            XCTAssertFalse(P.isDue(in: defaults), "four prompts are not enough")
        }
    }

    func testShownAtTheFifthOwnerPrompt() throws {
        try withDefaults { defaults in
            send(4, in: defaults)
            P.recordPrompt(author: .owner, delivery: .writtenToPty, in: defaults)
            XCTAssertTrue(P.isDue(in: defaults), "the fifth delivered prompt shows the card")
            send(3, in: defaults)
            XCTAssertEqual(defaults.integer(forKey: P.sentPromptsKey), P.threshold, "counting stops at the threshold")
            XCTAssertTrue(P.isDue(in: defaults), "unanswered, it stays due")
        }
    }

    func testNeverShownAgainAfterStarOrNotNow() throws {
        // "Star on GitHub" and "Not now" both answer the card.
        for button in ["Star on GitHub", "Not now"] {
            try withDefaults { defaults in
                send(5, in: defaults)
                XCTAssertTrue(P.isDue(in: defaults))
                P.markAnswered(in: defaults)
                XCTAssertFalse(P.isDue(in: defaults), "\(button) retires the card")
                send(20, in: defaults)
                XCTAssertFalse(P.isDue(in: defaults), "\(button): more prompts never bring it back")
            }
        }
    }

    func testAnsweredBeforeTheThresholdNeverShows() throws {
        try withDefaults { defaults in
            P.markAnswered(in: defaults)
            send(10, in: defaults)
            XCTAssertFalse(P.isDue(in: defaults))
            XCTAssertEqual(defaults.integer(forKey: P.sentPromptsKey), 0, "an answered card stops counting")
        }
    }

    func testGuestSendsNeverCount() throws {
        try withDefaults { defaults in
            send(10, author: .guest(name: "Ana"), in: defaults)
            send(10, author: .guest(name: nil), in: defaults)
            XCTAssertEqual(defaults.integer(forKey: P.sentPromptsKey), 0)
            XCTAssertFalse(P.isDue(in: defaults))
            XCTAssertFalse(P.counts(author: .guest(name: "Ana"), delivery: .submitted))
        }
    }

    func testFailedSendsNeverCount() throws {
        try withDefaults { defaults in
            // A rejected send throws before recording; an unconfirmed one returns no delivery.
            send(10, delivery: nil, in: defaults)
            XCTAssertEqual(defaults.integer(forKey: P.sentPromptsKey), 0)
            XCTAssertFalse(P.isDue(in: defaults))
            send(4, in: defaults)
            send(3, delivery: nil, in: defaults)
            XCTAssertFalse(P.isDue(in: defaults), "failed sends between good ones add nothing")
            XCTAssertEqual(defaults.integer(forKey: P.sentPromptsKey), 4)
        }
    }

    func testMockRunsNeedTheFlag() {
        XCTAssertFalse(P.mockShowsCard([:]), "screenshots and UI tests keep their pixels")
        XCTAssertFalse(P.mockShowsCard([P.mockEnvironmentKey: "0"]))
        XCTAssertTrue(P.mockShowsCard([P.mockEnvironmentKey: "1"]))
        XCTAssertTrue(P.mockShowsCard([P.mockEnvironmentKey: "keep"]))
    }

    func testMockLaunchResetsUnlessKept() throws {
        try withDefaults { defaults in
            send(5, in: defaults)
            P.markAnswered(in: defaults)
            P.resetForMockLaunch([P.mockEnvironmentKey: "keep"], in: defaults)
            XCTAssertTrue(defaults.bool(forKey: P.answeredKey), "a kept relaunch remembers the answer")
            P.resetForMockLaunch([P.mockEnvironmentKey: "1"], in: defaults)
            XCTAssertFalse(defaults.bool(forKey: P.answeredKey))
            XCTAssertEqual(defaults.integer(forKey: P.sentPromptsKey), 0)
            send(5, in: defaults)
            P.resetForMockLaunch([:], in: defaults)
            XCTAssertEqual(defaults.integer(forKey: P.sentPromptsKey), 0, "an unflagged mock run starts clean too")
        }
    }
}
