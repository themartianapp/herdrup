import Foundation
import XCTest
@testable import HerdrKit

// Turn origin (owner decision 2026-11-06): the owner's writes say `input_source: "app"` so herdr
// can tell the owner's turns from gitmoot's, scripts' and other agents'; a guest's never do.
// "An agent finishes" can then push only the owner's turns, and the Chat's up arrow jumps to
// the owner's previous message. Every fixture is synthetic.

final class InputSourceTests: XCTestCase {
    private static let ok = #"{"id":"x","result":{}}"#

    /// Every owner write the app makes: a Chat send, terminal typing, named keys to an agent
    /// and to a plain pane.
    private func writeEverything(_ client: HerdrClient) async throws {
        _ = try await client.prompt(pane: "w1:p1", text: "Ship it")
        try await client.sendText(pane: "w1:p1", text: "ls\r")
        try await client.sendKeys(pane: "w1:p1", keys: ["Enter"])
        try await client.sendPaneKeys(pane: "w1:p2", keys: ["Escape"])
    }

    func testOwnerWritesSayTheyComeFromTheApp() async throws {
        let transport = RecordingTransport(reply: Self.ok)
        try await writeEverything(HerdrClient(transport: transport))

        XCTAssertEqual(transport.requests.map(\.method),
                       ["agent.prompt", "pane.send_text", "agent.send_keys", "pane.send_keys"])
        for request in transport.requests {
            XCTAssertEqual(request.params["input_source"] as? String, "app",
                           "\(request.method) must claim the owner's app")
        }
    }

    /// The same calls over the guest relay never claim to be the owner's: a guest's prompt
    /// must not count as "mine" for the owner's notifications or Chat.
    func testGuestWritesOverTheRelayNeverClaimTheApp() async throws {
        let host = FakeHost()
        host.serve = { _ in [Data((Self.ok + "\n").utf8)] }
        let transport = RelayTransport(guestID: "g_1", endpoint: host.endpoint,
                                       identity: GuestIdentity(privateKey: .init()), connector: host.connector())
        try await writeEverything(HerdrClient(transport: transport))

        XCTAssertEqual(host.requests.count, 4)
        for line in host.requests {
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let params = try XCTUnwrap(object["params"] as? [String: Any])
            XCTAssertNil(params["input_source"], "a guest write must not carry input_source: \(line)")
            XCTAssertNotNil(params["text"] ?? params["keys"], "the write itself still goes out: \(line)")
        }
    }

    func testTurnOriginCapabilityDecodesAndDefaultsOff() throws {
        func capabilities(_ json: String) throws -> ServerCapabilities {
            try JSONDecoder().decode(ServerCapabilities.self, from: Data(json.utf8))
        }
        XCTAssertTrue(try capabilities(#"{"turn_origin":true}"#).turnOrigin)
        XCTAssertFalse(try capabilities(#"{"agent_transcript":true}"#).turnOrigin,
                       "a herdr without it falls back to every finished turn")
    }

    func testAdvertisesTurnOriginAsksThePingOnce() async {
        let transport = RecordingTransport(
            reply: #"{"id":"x","result":{"type":"pong","version":"1","protocol":1,"capabilities":{"turn_origin":true}}}"#)
        let client = HerdrClient(transport: transport)
        let first = await client.advertisesTurnOrigin()
        let second = await client.advertisesTurnOrigin()
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(transport.requests.filter { $0.method == "ping" }.count, 1, "the answer is cached per client")

        let old = HerdrClient(transport: RecordingTransport(
            reply: #"{"id":"x","result":{"type":"pong","version":"1","protocol":1}}"#))
        let oldAnswer = await old.advertisesTurnOrigin()
        XCTAssertFalse(oldAnswer)
    }
}

final class FinishNotificationsTests: XCTestCase {
    /// The old single switch carries over: on is Always, off (or never set) is Off.
    func testStoredSwitchesMapToTheThreeChoices() {
        XCTAssertEqual(FinishNotifications(notifies: false, mineOnly: false), .off)
        XCTAssertEqual(FinishNotifications(notifies: true, mineOnly: false), .always,
                       "an install that had \"An agent finishes\" on keeps every finished turn")
        XCTAssertEqual(FinishNotifications(notifies: true, mineOnly: true), .mine)
        XCTAssertEqual(FinishNotifications(notifies: false, mineOnly: true), .off,
                       "off stays off whatever the mine-only switch says")
        for choice in FinishNotifications.allCases {
            XCTAssertEqual(FinishNotifications(notifies: choice.notifies, mineOnly: choice.mineOnly), choice)
        }
        XCTAssertEqual(FinishNotifications.allCases.map(\.label), ["Off", "Only my requests", "Always"])
    }

    func testRegistrationSendsTheMineOnlyFlag() async throws {
        let transport = RecordingTransport(reply: #"{"id":"x","result":null}"#)
        let client = HerdrClient(transport: transport)
        var sent: [FinishNotifications: (Bool?, Bool?)] = [:]
        for choice in FinishNotifications.allCases {
            try await client.registerDevice(token: "abcd", needsInput: true, dies: true, finishes: choice, gram: true)
            let params = try transport.last().params
            sent[choice] = (params["notify_finishes"] as? Bool, params["notify_finishes_mine_only"] as? Bool)
        }
        XCTAssertEqual(sent[.off]?.0, false)
        XCTAssertEqual(sent[.off]?.1, false)
        XCTAssertEqual(sent[.mine]?.0, true)
        XCTAssertEqual(sent[.mine]?.1, true, "Only my requests asks the daemon to filter")
        XCTAssertEqual(sent[.always]?.0, true)
        XCTAssertEqual(sent[.always]?.1, false)
    }
}

final class TranscriptOriginTests: XCTestCase {
    private func entries(_ json: String) throws -> [TranscriptEntry] {
        try JSONDecoder().decode([TranscriptEntry].self, from: Data(json.utf8))
    }

    func testOriginOtherDecodesAndAbsentOrUnknownIsMine() throws {
        let decoded = try entries(#"""
        [{"id":"u1","ts_ms":1,"kind":"user","text":"Review #305","author":"owner","origin":"other"},
         {"id":"u2","ts_ms":2,"kind":"user","text":"Fix the build","author":"owner"},
         {"id":"u3","ts_ms":3,"kind":"user","text":"From the future","author":"owner","origin":"robot"},
         {"id":"u4","ts_ms":4,"kind":"user","text":"Add a test","author":"guest","author_name":"sam","origin":"other"}]
        """#)
        XCTAssertEqual(decoded.map(\.kind), [
            .user(text: "Review #305", author: .owner, origin: .other),
            .user(text: "Fix the build", author: .owner, origin: .mine),
            .user(text: "From the future", author: .owner, origin: .mine),
            .user(text: "Add a test", author: .guest(name: "sam"), origin: .other),
        ])
        let turns = TranscriptGrouping.turns(decoded)
        XCTAssertEqual(turns.map(\.promptOrigin), [.other, .mine, .mine, .other])
    }
}

// MARK: - The Chat's up arrow

final class TranscriptPreviousMineTests: XCTestCase {
    /// One user entry per turn, oldest first. `origin` other, or `guest`.
    static func user(_ id: String, _ ts: UInt64, other: Bool = false, guest: Bool = false) -> String {
        let author = guest ? #""author":"guest","author_name":"sam""# : #""author":"owner""#
        return #"{"id":"\#(id)","ts_ms":\#(ts),"kind":"user","text":"\#(id)",\#(author)\#(other ? #","origin":"other""# : "")}"#
    }

    private func turns(_ users: [String]) throws -> [TranscriptTurn] {
        TranscriptGrouping.turns(try JSONDecoder().decode([TranscriptEntry].self,
                                                          from: Data("[\(users.joined(separator: ","))]".utf8)))
    }

    func testSkipsOtherAndGuestTurnsAndGoesOneFurtherUpEachTime() throws {
        let loaded = try turns([
            Self.user("mine1", 1), Self.user("gitmoot", 2, other: true), Self.user("guest", 3, guest: true),
            Self.user("mine2", 4), Self.user("script", 5, other: true), Self.user("newest", 6),
        ])
        func step(above: String?) -> TranscriptPreviousMine.Step {
            TranscriptPreviousMine.step(in: loaded, above: above, hasOlder: false, honoursOrigin: true)
        }
        // At the bottom with every prompt above the screen, the newest of the owner's.
        XCTAssertEqual(step(above: nil), .jump(turnID: "newest"))
        // The newest prompt on screen: past the script's turn to the owner's.
        XCTAssertEqual(step(above: "newest"), .jump(turnID: "mine2"))
        // Past the guest and gitmoot.
        XCTAssertEqual(step(above: "mine2"), .jump(turnID: "mine1"))
        XCTAssertEqual(step(above: "mine1"), TranscriptPreviousMine.Step.none, "nothing above, no older history")
        XCTAssertEqual(step(above: "gone"), .jump(turnID: "newest"), "an id no longer loaded searches every turn")
    }

    func testWithoutTurnOriginsEveryOwnerPromptCountsButNeverAGuests() throws {
        let loaded = try turns([Self.user("guest", 1, guest: true), Self.user("gitmoot", 2, other: true),
                                Self.user("newest", 3)])
        XCTAssertEqual(TranscriptPreviousMine.step(in: loaded, above: "newest", hasOlder: false, honoursOrigin: false),
                       .jump(turnID: "gitmoot"))
        XCTAssertEqual(TranscriptPreviousMine.step(in: loaded, above: "gitmoot", hasOlder: false, honoursOrigin: false),
                       TranscriptPreviousMine.Step.none)
    }

    func testAPromptlessTurnIsNeverATarget() throws {
        // A page that begins at a compaction summary opens a turn with no prompt.
        let loaded = TranscriptGrouping.turns(try JSONDecoder().decode([TranscriptEntry].self, from: Data(#"""
        [{"id":"c1","ts_ms":1,"kind":"summary","text":"Earlier messages were summarised"},
         {"id":"u1","ts_ms":2,"kind":"user","text":"Go","author":"owner"}]
        """#.utf8)))
        XCTAssertEqual(TranscriptPreviousMine.step(in: loaded, above: "u1", hasOlder: false, honoursOrigin: true),
                       TranscriptPreviousMine.Step.none)
    }

    /// One tap as the Chat runs it: where to search from, then where to go.
    private func tap(_ loaded: [TranscriptTurn], boundary: String?, lastJump: TranscriptPreviousMine.LastJump?,
                     offset: Double?) -> TranscriptPreviousMine.Step {
        let start = TranscriptPreviousMine.searchStart(in: loaded, boundary: boundary, lastJump: lastJump, offset: offset)
        return TranscriptPreviousMine.step(in: loaded, above: start, hasOlder: false, honoursOrigin: true)
    }

    /// Review 18e58482c5fdb8ca F1: up-arrow to m2, search moves the chat to m4, search closes,
    /// the next tap goes to m3 (the owner's message just above the screen), not m1.
    func testAfterSearchMovesTheChatTheNextTapStartsFromTheScreen() throws {
        let loaded = try turns([Self.user("m1", 1), Self.user("m2", 2), Self.user("m3", 3), Self.user("m4", 4)])
        // The jump to m2 settled at offset 1000.
        let jumped = TranscriptPreviousMine.LastJump(turnID: "m2", offset: 1000)
        // Search revealed m4 lower down: the chat sits at 2600, m4 the oldest prompt on screen.
        XCTAssertEqual(tap(loaded, boundary: "m4", lastJump: jumped, offset: 2600), .jump(turnID: "m3"))
        // Without the move, the jump still stands and the tap goes on from it.
        XCTAssertEqual(tap(loaded, boundary: "m2", lastJump: jumped, offset: 1002), .jump(turnID: "m1"),
                       "a few points of layout drift keep the jump")
    }

    /// Quick taps while a jump is still gliding (its offset not recorded yet, the screen still
    /// showing the bottom) step one further up each time.
    func testQuickTapsWhileAJumpGlidesStepTwoTurns() throws {
        let loaded = try turns([Self.user("m1", 1), Self.user("m2", 2), Self.user("m3", 3), Self.user("m4", 4)])
        // At the bottom every prompt is above the screen.
        guard case .jump(let first) = tap(loaded, boundary: nil, lastJump: nil, offset: 3000) else {
            return XCTFail("the first tap should jump")
        }
        XCTAssertEqual(first, "m4")
        // The scroll has barely moved when the second tap lands.
        guard case .jump(let second) = tap(loaded, boundary: nil,
                                           lastJump: .init(turnID: first), offset: 2980) else {
            return XCTFail("the second tap should jump")
        }
        XCTAssertEqual(second, "m3", "two quick taps step two turns")
        XCTAssertEqual(tap(loaded, boundary: nil, lastJump: .init(turnID: second), offset: 2900),
                       .jump(turnID: "m2"))
    }

    func testALastJumpHoldsOnlyWhereItSettled() {
        let gliding = TranscriptPreviousMine.LastJump(turnID: "m2")
        XCTAssertTrue(gliding.holds(at: 500), "not settled yet: still the reader's place")
        let settled = TranscriptPreviousMine.LastJump(turnID: "m2", offset: 500)
        XCTAssertTrue(settled.holds(at: 504))
        XCTAssertFalse(settled.holds(at: 505), "moved past the tolerance")
        XCTAssertFalse(settled.holds(at: nil))
    }
}

/// The up arrow against a real `TranscriptStore`: when no owner turn is loaded above, it asks
/// for older pages until one is found, and gives up when the history ends.
@MainActor
final class TranscriptPreviousMinePagingTests: XCTestCase {
    private static func page(_ users: [String], before: String?) -> String {
        let beforeJSON = before.map { #""\#($0)""# } ?? "null"
        return #"{"id":"x","result":{"type":"agent_transcript","session_id":"s","entries":[\#(users.joined(separator: ","))],"before":\#(beforeJSON),"after":"a","pending_ask":null,"working":null}}"#
    }

    /// Follows the steps a tap takes in the Chat: jump, or load the next older page and look again.
    private func tap(_ store: TranscriptStore, client: HerdrClient, above: String?) async throws -> String? {
        while true {
            switch TranscriptPreviousMine.step(in: store.turns, above: above, hasOlder: store.hasOlder,
                                               honoursOrigin: true) {
            case .jump(let turnID): return turnID
            case .none: return nil
            case .loadOlder: try await store.loadOlder(client: client)
            }
        }
    }

    func testWalksIntoOlderPagesUntilAnOwnerTurnAndStopsWhenTheHistoryEnds() async throws {
        let user = TranscriptPreviousMineTests.user
        let transport = RecordingTransport { _, params in
            switch params["before"] as? String {
            case nil:
                return Self.page([user("gitmoot1", 30, true, false), user("newest", 31, false, false)], before: "p2")
            case "p2":
                // A whole page of someone else's turns: keep going.
                return Self.page([user("guest", 20, false, true), user("gitmoot2", 21, true, false)], before: "p3")
            case "p3":
                return Self.page([user("first", 10, false, false), user("script", 11, true, false)], before: nil)
            default:
                return RecordingTransport.errorReply(code: "cursor_expired", message: "unknown cursor")
            }
        }
        let client = HerdrClient(transport: transport)
        let store = TranscriptStore(target: "agent")
        await store.refresh(client: client)
        XCTAssertEqual(store.turns.map(\.id), ["gitmoot1", "newest"])

        let target = try await tap(store, client: client, above: "newest")
        XCTAssertEqual(target, "first", "two older pages in, past every turn that was not the owner's")
        XCTAssertEqual(transport.requests.compactMap { $0.params["before"] as? String }, ["p2", "p3"])
        XCTAssertFalse(store.hasOlder)

        let none = try await tap(store, client: client, above: "first")
        XCTAssertNil(none, "no owner turn above the first, and no history left: the button hides")
        XCTAssertEqual(transport.requests.compactMap { $0.params["before"] as? String }, ["p2", "p3"],
                       "nothing more is fetched once the history ended")
    }
}
