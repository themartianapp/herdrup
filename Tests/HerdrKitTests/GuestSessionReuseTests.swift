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

    func testAReadReconnectsOnceWhenTheReusedSessionEnded() async throws {
        let host = multiRequestHost()
        let connector = host.connector()
        let transport = transport(host, connector)
        _ = try await transport.roundTrip(Self.request("1"))
        connector.sockets[0].hangUp()   // herdr went idle or restarted

        let line = try await transport.roundTrip(Self.request("2", "agent.transcript"))

        XCTAssertEqual(line, Self.reply(to: Self.request("2")))
        XCTAssertEqual(connector.sockets.count, 2, "one reconnect")
        XCTAssertEqual(host.hellos.count, 2)
        XCTAssertTrue(connector.sockets[0].closed)
        XCTAssertEqual(host.requests, [Self.request("1"), Self.request("2", "agent.transcript")])
    }

    func testAWrittenPromptIsNotRetriedWhenTheReusedSessionEnded() async throws {
        let host = multiRequestHost()
        let connector = host.connector()
        let transport = transport(host, connector)
        _ = try await transport.roundTrip(Self.request("1"))
        connector.sockets[0].hangUp()

        do {
            _ = try await transport.roundTrip(Self.request("2", "agent.prompt"))
            XCTFail("expected the ended session to fail the prompt")
        } catch TransportError.closedBeforeResponse {
        }
        XCTAssertEqual(connector.sockets.count, 1, "no reconnect: the prompt may have reached the host")
        XCTAssertEqual(connector.sockets[0].sent.count, 3, "handshake, request 1, the prompt — sent once")

        // The next call connects afresh.
        _ = try await transport.roundTrip(Self.request("3"))
        XCTAssertEqual(connector.sockets.count, 2)
    }

    func testAPromptThatNeverLeftIsSentOnAFreshSession() async throws {
        let host = multiRequestHost()
        let connector = host.connector()
        let transport = transport(host, connector)
        _ = try await transport.roundTrip(Self.request("1"))
        connector.sockets[0].hangUp(failingSends: URLError(.networkConnectionLost))

        let line = try await transport.roundTrip(Self.request("2", "agent.prompt"))

        XCTAssertEqual(line, Self.reply(to: Self.request("2")))
        XCTAssertEqual(connector.sockets.count, 2)
        XCTAssertEqual(host.requests, [Self.request("1"), Self.request("2", "agent.prompt")])
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

    /// The reconnect still maps a refused upgrade (here 429 `rate_limited`).
    func testAReconnectRefusedByTheRelayReportsWhy() async throws {
        let host = multiRequestHost()
        let hostSockets = host.connector()
        let lock = NSLock()
        var opened = 0
        let connector = FakeConnector {
            let index = lock.withLock { () -> Int in opened += 1; return opened }
            if index == 1 { return hostSockets.connect(to: host.endpoint.socketURL) as! FakeRelaySocket }
            let refused = FakeRelaySocket()
            refused.fail(GuestError.rateLimited)
            return refused
        }
        let transport = transport(host, connector)
        _ = try await transport.roundTrip(Self.request("1"))
        connector.sockets[0].hangUp()

        do {
            _ = try await transport.roundTrip(Self.request("2", "gram.list"))
            XCTFail("expected rate limiting")
        } catch let error as GuestError {
            XCTAssertEqual(error, .rateLimited)
        }
        XCTAssertEqual(connector.sockets.count, 2, "one reconnect, no more")
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
