import Foundation
import XCTest
@testable import HerdrKit

/// herdr #356: a host that advertises `features.multi_request` serves the guest's requests
/// in turn on one Noise session.
final class GuestSessionReuseTests: XCTestCase {
    let identity = GuestIdentity(privateKey: .init())

    /// A host that serves many requests per session and keeps it open after each reply.
    func multiRequestHost() -> FakeHost {
        let host = FakeHost()
        host.reply = ["ok": true, "guest_id": "g_1", "features": ["multi_request": true]]
        host.closeAfterServe = nil
        host.serve = { line in [Data(Self.reply(to: line).utf8 + [0x0a])] }
        return host
    }

    static func request(_ id: String, _ method: String = "agent.list") -> String {
        #"{"id":"\#(id)","method":"\#(method)","params":{}}"#
    }

    static func reply(to line: String) -> String {
        let id = ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])?["id"] as? String ?? ""
        return #"{"id":"\#(id)","result":{"type":"ok"}}"#
    }

    func transport(_ host: FakeHost, _ connector: FakeConnector) -> RelayTransport {
        RelayTransport(guestID: "g_1", endpoint: host.endpoint, identity: identity, connector: connector)
    }

    func waitUntil(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "timed out waiting", file: file, line: line)
    }

    func testSequentialCallsShareOneHandshake() async throws {
        let host = multiRequestHost()
        let connector = host.connector()
        let transport = transport(host, connector)

        for id in ["1", "2", "3"] {
            let line = try await transport.roundTrip(Self.request(id))
            XCTAssertEqual(line, Self.reply(to: Self.request(id)))
        }

        XCTAssertEqual(connector.sockets.count, 1, "one WebSocket")
        XCTAssertEqual(host.hellos.count, 1, "one Noise handshake")
        XCTAssertEqual(host.requests, ["1", "2", "3"].map { Self.request($0) })
        XCTAssertFalse(connector.sockets[0].closed, "the session stays open for the next call")
    }

    func testAnotherTransportOfTheSameGuestTakesTheSameSession() async throws {
        let host = multiRequestHost()
        let connector = host.connector()
        _ = try await transport(host, connector).roundTrip(Self.request("1"))
        _ = try await transport(host, connector).roundTrip(Self.request("2"))
        XCTAssertEqual(connector.sockets.count, 1)
        XCTAssertEqual(host.hellos.count, 1)
    }

    func testConcurrentCallsTakeTurns() async throws {
        let host = multiRequestHost()
        host.holdReply = { $0 == Self.request("first") }
        let connector = host.connector()
        let transport = transport(host, connector)
        _ = try await transport.roundTrip(Self.request("warm"))   // learns multi_request

        let first = Task { try await transport.roundTrip(Self.request("first")) }
        try await waitUntil { host.requests.count == 2 }
        let second = Task { try await transport.roundTrip(Self.request("second")) }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(host.requests, [Self.request("warm"), Self.request("first")],
                       "the second request waits for the first reply")
        XCTAssertEqual(connector.sockets.count, 1, "the waiting call opens no socket of its own")

        try host.release()
        let firstLine = try await first.value
        let secondLine = try await second.value
        XCTAssertEqual(firstLine, Self.reply(to: Self.request("first")))
        XCTAssertEqual(secondLine, Self.reply(to: Self.request("second")))
        XCTAssertEqual(host.requests, ["warm", "first", "second"].map { Self.request($0) })
        XCTAssertEqual(connector.sockets.count, 1)
        XCTAssertEqual(host.hellos.count, 1)
    }

    /// An older herdr: no `multi_request`, so one WebSocket and handshake per call even
    /// when the host leaves the socket open.
    func testWithoutTheFlagEveryCallHandshakes() async throws {
        let host = multiRequestHost()
        host.reply = ["ok": true, "guest_id": "g_1", "features": ["gram": true]]
        let connector = host.connector()
        let transport = transport(host, connector)
        for id in ["1", "2", "3"] { _ = try await transport.roundTrip(Self.request(id)) }
        XCTAssertEqual(connector.sockets.count, 3)
        XCTAssertEqual(host.hellos.count, 3)
        XCTAssertTrue(connector.sockets.allSatisfy(\.closed), "every call closes its socket")
    }

    /// herdr ended the session after reading the request (idle timeout racing the call,
    /// restart): a read goes once more on a fresh session.
    func testAReadReconnectsOnceWhenTheReusedSessionEnds() async throws {
        let host = multiRequestHost()
        var drops = 0
        host.dropAfter = { line in
            guard line == Self.request("2", "agent.transcript"), drops == 0 else { return false }
            drops += 1
            return true
        }
        let connector = host.connector()
        let transport = transport(host, connector)
        _ = try await transport.roundTrip(Self.request("1"))

        let line = try await transport.roundTrip(Self.request("2", "agent.transcript"))

        XCTAssertEqual(line, Self.reply(to: Self.request("2")))
        XCTAssertEqual(connector.sockets.count, 2, "one reconnect")
        XCTAssertEqual(host.hellos.count, 2)
        XCTAssertTrue(connector.sockets[0].closed)
        XCTAssertEqual(host.requests, ["1", "2", "2"].map { Self.request($0, $0 == "1" ? "agent.list" : "agent.transcript") })
    }

    func testAWrittenPromptIsNotRetriedWhenTheReusedSessionEnds() async throws {
        let host = multiRequestHost()
        host.dropAfter = { $0 == Self.request("2", "agent.prompt") }
        let connector = host.connector()
        let transport = transport(host, connector)
        _ = try await transport.roundTrip(Self.request("1"))

        do {
            _ = try await transport.roundTrip(Self.request("2", "agent.prompt"))
            XCTFail("expected the ended session to fail the prompt")
        } catch TransportError.closedBeforeResponse {
        }
        XCTAssertEqual(connector.sockets.count, 1, "no reconnect: the prompt reached the host")
        XCTAssertEqual(host.requests, [Self.request("1"), Self.request("2", "agent.prompt")], "the host ran it once")

        // The next call connects afresh.
        _ = try await transport.roundTrip(Self.request("3"))
        XCTAssertEqual(connector.sockets.count, 2)
    }

    /// A send that fails after its bytes left proves nothing about delivery: the prompt
    /// reached the host, so it must not run again on a fresh session.
    func testAPromptWhoseSendFailedAfterDeliveryIsNotRetried() async throws {
        let host = multiRequestHost()
        let connector = host.connector()
        let transport = transport(host, connector)
        _ = try await transport.roundTrip(Self.request("1"))
        connector.sockets[0].failSends(afterDelivering: URLError(.networkConnectionLost))

        do {
            _ = try await transport.roundTrip(Self.request("2", "agent.prompt"))
            XCTFail("expected the failed send to fail the prompt")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
        XCTAssertEqual(host.requests.filter { $0 == Self.request("2", "agent.prompt") }.count, 1, "the host ran it once")
        XCTAssertEqual(connector.sockets.count, 1, "no reconnect")
        XCTAssertEqual(host.hellos.count, 1)
    }

    /// herdr closed the idle session before the call: nothing of the prompt was sent on it,
    /// so it goes out once on a fresh session.
    func testAPromptOnASessionKnownClosedGoesOutOnAFreshSession() async throws {
        let host = multiRequestHost()
        let connector = host.connector()
        let transport = transport(host, connector)
        _ = try await transport.roundTrip(Self.request("1"))
        connector.sockets[0].hangUp()   // herdr's idle timeout or a restart
        try await waitUntil { connector.sockets[0].closed }

        let line = try await transport.roundTrip(Self.request("2", "agent.prompt"))

        XCTAssertEqual(line, Self.reply(to: Self.request("2")))
        XCTAssertEqual(connector.sockets.count, 2)
        XCTAssertEqual(connector.sockets[0].sent.count, 2, "handshake and request 1 only")
        XCTAssertEqual(host.requests, [Self.request("1"), Self.request("2", "agent.prompt")])
    }

    /// A transport that inherits the session another transport of the guest opened (a new
    /// `GuestConnection`) still hears the features that session's handshake authenticated.
    func testATransportInheritingTheSessionHearsItsFeatures() async throws {
        let host = multiRequestHost()
        host.reply = ["ok": true, "guest_id": "g_1",
                      "features": ["multi_request": true, "gram": true, "push": true]]
        let connector = host.connector()
        _ = try await transport(host, connector).roundTrip(Self.request("1"))

        let heard = HeardFeatures()
        let second = RelayTransport(guestID: "g_1", endpoint: host.endpoint, identity: identity, connector: connector,
                                    onFeatures: { heard.append($0) })
        _ = try await second.roundTrip(Self.request("2"))

        XCTAssertEqual(host.hellos.count, 1, "no new handshake")
        XCTAssertEqual(heard.values, [GuestFeatures(gram: true, push: true)])
    }

    func testGuestPausedEndsTheSessionAndForbiddenDoesNot() async throws {
        let host = multiRequestHost()
        host.serve = { line in
            let id = ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])?["id"] as? String ?? ""
            switch id {
            case "forbidden": return [Data(#"{"id":"forbidden","error":{"code":"guest_forbidden","message":"no"}}"#.utf8 + [0x0a])]
            case "paused": return [Data(#"{"id":"paused","error":{"code":"guest_paused","message":"no"}}"#.utf8 + [0x0a])]
            default: return [Data(Self.reply(to: line).utf8 + [0x0a])]
            }
        }
        let connector = host.connector()
        let transport = transport(host, connector)

        _ = try await transport.roundTrip(Self.request("1"))
        let forbidden = try await transport.roundTrip(Self.request("forbidden"))
        XCTAssertTrue(forbidden.contains("guest_forbidden"))
        XCTAssertEqual(connector.sockets.count, 1, "guest_forbidden leaves the session open")
        XCTAssertFalse(connector.sockets[0].closed)

        let paused = try await transport.roundTrip(Self.request("paused"))
        XCTAssertTrue(paused.contains("guest_paused"), "the reply reaches the client, which reports paused")
        XCTAssertTrue(connector.sockets[0].closed, "guest_paused ends the session")

        _ = try await transport.roundTrip(Self.request("2"))
        XCTAssertEqual(connector.sockets.count, 2)
        XCTAssertEqual(host.hellos.count, 2, "a new handshake after guest_paused")
    }

    func testPaneStreamOpensItsOwnSession() async throws {
        let host = multiRequestHost()
        let connector = host.connector()
        let transport = transport(host, connector)
        _ = try await transport.roundTrip(Self.request("1"))

        for try await _ in transport.stream(Self.request("s", "pane.stream")) { break }
        try await waitUntil { connector.sockets.count == 2 && connector.sockets[1].closed }
        _ = try await transport.roundTrip(Self.request("2"))

        XCTAssertEqual(connector.sockets.count, 2, "the stream had its own socket; the next call reused the first")
        XCTAssertEqual(host.hellos.count, 2)
        XCTAssertEqual(host.requests, [Self.request("1"), Self.request("s", "pane.stream"), Self.request("2")])
        XCTAssertFalse(connector.sockets[0].closed)
    }

    func testAnIdleSessionClosesAfterTheIdleLimit() async throws {
        let host = multiRequestHost()
        let connector = host.connector(sessionIdleLimit: .milliseconds(100))
        let transport = transport(host, connector)
        _ = try await transport.roundTrip(Self.request("1"))
        try await waitUntil { connector.sockets[0].closed }

        _ = try await transport.roundTrip(Self.request("2"))
        XCTAssertEqual(connector.sockets.count, 2)
        XCTAssertEqual(host.hellos.count, 2)
    }

    /// Steady polling keeps the session busy enough never to idle out; past its age limit
    /// the next call handshakes again and hears what the owner changed since.
    func testAnAgedSessionHandshakesAgainAndHearsNewFeatures() async throws {
        let host = multiRequestHost()
        host.reply = ["ok": true, "guest_id": "g_1", "features": ["multi_request": true]]
        let connector = host.connector(sessionAgeLimit: .milliseconds(300))
        let heard = HeardFeatures()
        let transport = RelayTransport(guestID: "g_1", endpoint: host.endpoint, identity: identity, connector: connector,
                                       onFeatures: { heard.append($0) })
        _ = try await transport.roundTrip(Self.request("1"))
        _ = try await transport.roundTrip(Self.request("2"))
        XCTAssertEqual(host.hellos.count, 1, "a call before the age limit reuses the session")
        XCTAssertEqual(heard.values, [GuestFeatures.none, GuestFeatures.none])

        // The owner turns Gram sharing and push on.
        host.reply = ["ok": true, "guest_id": "g_1",
                      "features": ["multi_request": true, "gram": true, "push": true]]
        let deadline = Date().addingTimeInterval(3)
        var polls = 0
        while host.hellos.count < 2, Date() < deadline {
            polls += 1
            _ = try await transport.roundTrip(Self.request("poll\(polls)"))
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(host.hellos.count, 2, "past the age limit the next call handshakes again")
        XCTAssertGreaterThan(polls, 1, "the polls before the age limit reused the session")
        XCTAssertEqual(heard.values.last, GuestFeatures(gram: true, push: true))
        XCTAssertTrue(connector.sockets[0].closed)
        XCTAssertEqual(connector.sockets.count, 2)
    }

    func testTheAgeLimitNeverCutsACallInFlight() async throws {
        let host = multiRequestHost()
        host.holdReply = { $0 == Self.request("slow") }
        let connector = host.connector(sessionAgeLimit: .milliseconds(200))
        let transport = transport(host, connector)
        _ = try await transport.roundTrip(Self.request("1"))

        let slow = Task { try await transport.roundTrip(Self.request("slow")) }
        try await waitUntil { host.requests.count == 2 }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(connector.sockets[0].closed, "the session outlives its age while a call holds it")
        try host.release()
        let line = try await slow.value
        XCTAssertEqual(line, Self.reply(to: Self.request("slow")))

        _ = try await transport.roundTrip(Self.request("2"))
        XCTAssertTrue(connector.sockets[0].closed)
        XCTAssertEqual(host.hellos.count, 2, "the call after it handshakes afresh")
    }

    func testClosingReusedSessionsClosesTheIdleOne() async throws {
        let host = multiRequestHost()
        let connector = host.connector()
        let transport = transport(host, connector)
        _ = try await transport.roundTrip(Self.request("1"))

        RelayTransport.closeReusedSessions()

        XCTAssertTrue(connector.sockets[0].closed)
        _ = try await transport.roundTrip(Self.request("2"))
        XCTAssertEqual(connector.sockets.count, 2)
    }

    func testACallCancelledWhileWaitingLeavesTheSessionOpen() async throws {
        let host = multiRequestHost()
        host.holdReply = { $0 == Self.request("first") }
        let connector = host.connector()
        let transport = transport(host, connector)
        _ = try await transport.roundTrip(Self.request("warm"))

        let first = Task { try await transport.roundTrip(Self.request("first")) }
        try await waitUntil { host.requests.count == 2 }
        let waiting = Task { try await transport.roundTrip(Self.request("cancelled")) }
        try await Task.sleep(nanoseconds: 100_000_000)
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }
        try host.release()
        _ = try await first.value
        _ = try await transport.roundTrip(Self.request("after"))

        XCTAssertEqual(host.requests, ["warm", "first", "after"].map { Self.request($0) })
        XCTAssertEqual(connector.sockets.count, 1)
        XCTAssertFalse(connector.sockets[0].closed)
    }

    /// herdr reads a read request and ends the reused session; `refuse` scripts how the
    /// relay refuses the one reconnect. The call reports `expected` and connects no more.
    func assertReconnectRefused(
        by refuse: @escaping (FakeRelaySocket) -> Void, reports expected: GuestError,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let host = multiRequestHost()
        host.dropAfter = { $0 == Self.request("2", "gram.list") }
        let hostSockets = host.connector()
        let lock = NSLock()
        var opened = 0
        let connector = FakeConnector {
            let index = lock.withLock { () -> Int in opened += 1; return opened }
            if index == 1 { return hostSockets.connect(to: host.endpoint.socketURL) as! FakeRelaySocket }
            let refused = FakeRelaySocket()
            refuse(refused)
            return refused
        }
        let transport = transport(host, connector)
        _ = try await transport.roundTrip(Self.request("1"))

        do {
            _ = try await transport.roundTrip(Self.request("2", "gram.list"))
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as GuestError {
            XCTAssertEqual(error, expected, file: file, line: line)
        }
        XCTAssertEqual(connector.sockets.count, 2, "one reconnect, no more", file: file, line: line)
    }

    /// The reconnect still maps a refused upgrade: an older relay's HTTP answer (here 429
    /// `rate_limited`), or the close a current relay sends right after accepting it.
    func testAReconnectRefusedByTheRelayReportsWhy() async throws {
        try await assertReconnectRefused(by: { $0.fail(GuestError.rateLimited) }, reports: .rateLimited)
        try await assertReconnectRefused(
            by: { $0.push(.closed(code: 4429, reason: "rate_limited")) }, reports: .rateLimited)
        try await assertReconnectRefused(
            by: { $0.push(.closed(code: 4504, reason: "host_busy")) }, reports: .hostBusy)
    }

    func testAReconnectClosedHostOfflineReportsItOnce() async throws {
        try await assertReconnectRefused(
            by: { $0.push(.closed(code: 4503, reason: "host_offline")) }, reports: .hostOffline)
    }

    /// A mapped close on the reused session is the call's answer, not a reason to reconnect.
    func testAMappedCloseOnTheReusedSessionIsReported() async throws {
        let host = multiRequestHost()
        let connector = host.connector()
        let transport = transport(host, connector)
        _ = try await transport.roundTrip(Self.request("1"))
        host.serve = { _ in [] }
        host.closeAfterServe = .closed(code: 1001, reason: "host_offline")

        do {
            _ = try await transport.roundTrip(Self.request("2", "agent.list"))
            XCTFail("expected hostOffline")
        } catch let error as GuestError {
            XCTAssertEqual(error, .hostOffline)
        }
        XCTAssertEqual(connector.sockets.count, 1)
        XCTAssertTrue(connector.sockets[0].closed)
    }

    func testSessionEndingReplies() {
        XCTAssertTrue(RelayTransport.endsSession(#"{"id":"1","error":{"code":"guest_paused","message":"x"}}"#))
        XCTAssertTrue(RelayTransport.endsSession(#"{"id":"1","error":{"code":"guest_revoked","message":"x"}}"#))
        XCTAssertTrue(RelayTransport.endsSession(#"{"id":"","error":{"code":"invalid_request","message":"x"}}"#))
        XCTAssertFalse(RelayTransport.endsSession(#"{"id":"1","error":{"code":"guest_forbidden","message":"x"}}"#))
        XCTAssertFalse(RelayTransport.endsSession(#"{"id":"1","result":{"text":"say \"guest_paused\""}}"#),
                       "a code quoted inside text is not a reply code")
        XCTAssertFalse(RelayTransport.endsSession(#"{"id":"1","result":{"guest_paused":true}}"#))
    }
}

/// What an `onFeatures` callback heard.
private final class HeardFeatures: @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [GuestFeatures] = []

    var values: [GuestFeatures] { lock.withLock { heard } }

    func append(_ features: GuestFeatures) {
        lock.withLock { heard.append(features) }
    }
}
