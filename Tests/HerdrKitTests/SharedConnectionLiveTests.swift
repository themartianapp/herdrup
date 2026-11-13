import XCTest
import Foundation
@testable import HerdrKit

/// Every stream and every request on ONE SSH connection, against a real sshd and a real
/// herdr, through a counting TCP relay (`TCPRelay`). Gated like the other live tests by
/// `LiveEnvironment` (key, sshd on :22, herdr socket); once the environment is there,
/// transport errors fail the test.
///
/// READ-ONLY BY CONTRACT, like `CitadelTransportLiveTests`: only `ping`, `agent.list`
/// and `events.subscribe` (`layout.updated`), so pointing this at a live machine
/// cannot disturb it.
final class SharedConnectionLiveTests: XCTestCase {
    private let subscribe = #"{"id":"sub","method":"events.subscribe","params":{"subscriptions":[{"type":"layout.updated"}]}}"#
    private let ping = #"{"id":"p","method":"ping","params":{}}"#

    private func transport(
        via relay: TCPRelay,
        connectTimeout: UInt64 = CitadelTransport.defaultConnectTimeoutNanoseconds
    ) throws -> CitadelTransport {
        var credentials = try LiveEnvironment.requireLiveCredentials()
        credentials.port = relay.port
        return CitadelTransport(
            credentials: credentials,
            hostKeyPolicy: PinningHostKeyPolicy(store: PinningHostKeyPolicy.PinStore()),
            connectTimeoutNanoseconds: connectTimeout)
    }

    /// A stream held open in the background: its first line, and whether it has ended.
    final class Held: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        private var endedWith: Result<Void, Error>?
        var task: Task<Void, Never>?

        var first: String? { lock.withLock { lines.first } }
        var ended: Bool { lock.withLock { endedWith != nil } }
        func received(_ line: String) { lock.withLock { lines.append(line) } }
        func end(_ result: Result<Void, Error>) { lock.withLock { endedWith = result } }
    }

    /// Opens `request` as a stream and waits for its first line (the subscription ack).
    private func hold(_ transport: CitadelTransport, _ request: String) async throws -> Held {
        let held = Held()
        let stream = transport.stream(request)
        held.task = Task {
            do {
                for try await line in stream { held.received(line) }
                held.end(.success(()))
            } catch {
                held.end(.failure(error))
            }
        }
        try await eventually("the stream's first line", timeout: 20) { held.first != nil || held.ended }
        return held
    }

    private func assertAcknowledged(_ held: Held, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(held.first?.contains("subscription_started") == true,
                      "not a subscription ack: \(held.first ?? "<ended>")", file: file, line: line)
    }

    /// Four subscriptions and eight concurrent requests: ONE TCP connection. Before,
    /// each stream dialled its own (1 + 4 here), paying 9–13 round trips each. The
    /// requests go out before the request channel is up, so each is its own exec
    /// channel: with the two streams that is more than sshd's default 10 channels per
    /// connection, and the refused ones wait their turn instead of failing.
    func testEveryStreamAndRequestRidesOneTCPConnection() async throws {
        let relay = try TCPRelay()
        defer { relay.stop() }
        let transport = try transport(via: relay)

        async let a = hold(transport, subscribe)
        async let b = hold(transport, subscribe)
        var streams = try await [a, b]
        let replies = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<8 {
                group.addTask {
                    try await transport.roundTrip(
                        index.isMultiple(of: 2) ? self.ping : #"{"id":"l","method":"agent.list","params":{}}"#)
                }
            }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }
        async let c = hold(transport, subscribe)
        async let d = hold(transport, subscribe)
        streams += try await [c, d]

        for held in streams { assertAcknowledged(held) }
        XCTAssertEqual(replies.count, 8)
        XCTAssertTrue(replies.allSatisfy { $0.contains(#""result""#) }, "\(replies)")
        XCTAssertEqual(relay.accepted, 1, "streams and requests must share one SSH connection")

        for held in streams { held.task?.cancel() }
        await transport.close()
    }

    /// A stream the daemon refuses ends by itself; the connection, the stream next to it
    /// and the requests carry on.
    func testAFailingStreamLeavesTheConnectionAndTheOtherStreamsRunning() async throws {
        let relay = try TCPRelay()
        defer { relay.stop() }
        let transport = try transport(via: relay)
        let healthy = try await hold(transport, subscribe)
        assertAcknowledged(healthy)

        // Not JSON: the bridge refuses it and exits.
        var failed = false
        do {
            for try await line in transport.stream("not a request") {
                failed = failed || line.contains(#""error""#)
            }
        } catch {
            failed = true
        }
        XCTAssertTrue(failed, "the bad stream should end with an error")

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(healthy.ended, "a failed channel took down another stream")
        let reply = try await transport.roundTrip(ping)
        XCTAssertTrue(reply.contains(#""result""#), reply)
        let another = try await hold(transport, subscribe)
        assertAcknowledged(another)
        XCTAssertEqual(relay.accepted, 1, "a failed channel must not cost the connection")

        healthy.task?.cancel()
        another.task?.cancel()
        await transport.close()
    }

    /// The connection drops: every stream ends, and when they resubscribe (as the app's
    /// stream loops do, each on its own backoff) they all land on ONE new connection.
    func testAfterADropEveryStreamResubscribesOnOneNewConnection() async throws {
        let relay = try TCPRelay()
        defer { relay.stop() }
        let transport = try transport(via: relay)
        var streams: [Held] = []
        for _ in 0..<3 { streams.append(try await hold(transport, subscribe)) }
        XCTAssertEqual(relay.accepted, 1)

        relay.severAll()
        for held in streams {
            try await eventually("each stream sees the drop", timeout: 20) { held.ended }
        }

        async let a = hold(transport, subscribe)
        async let b = hold(transport, subscribe)
        async let c = hold(transport, subscribe)
        let again = try await [a, b, c]
        for held in again { assertAcknowledged(held) }
        let reply = try await transport.roundTrip(ping)
        XCTAssertTrue(reply.contains(#""result""#), reply)
        XCTAssertEqual(relay.accepted, 2, "the resubscribed streams must share one new connection")

        for held in again { held.task?.cancel() }
        await transport.close()
    }

    /// A handshake slower than Citadel's own fixed 10 s login timer still connects:
    /// the app's connect budget (15 s) is the only one.
    func testAHandshakeSlowerThanTenSecondsStillConnects() async throws {
        let relay = try TCPRelay(serverHelloDelay: 11)
        defer { relay.stop() }
        let transport = try transport(via: relay)
        let reply = try await transport.roundTrip(ping)
        XCTAssertTrue(reply.contains(#""result""#), reply)
        await transport.close()
    }

    /// An sshd that allows fewer channels per connection than the app holds (OpenSSH
    /// `MaxSessions`): streams past its limit still open, on connections of their own.
    ///
    /// Needs a second sshd with a low `MaxSessions` (3), named by
    /// `HERDRKIT_LIVE_LOW_SESSIONS_PORT`; skipped otherwise.
    func testStreamsPastSshdsChannelLimitOpenOnTheirOwnConnections() async throws {
        guard let value = ProcessInfo.processInfo.environment["HERDRKIT_LIVE_LOW_SESSIONS_PORT"],
              let port = UInt16(value) else {
            throw XCTSkip("set HERDRKIT_LIVE_LOW_SESSIONS_PORT to an sshd with MaxSessions 3")
        }
        let relay = try TCPRelay(upstreamPort: port)
        defer { relay.stop() }
        let transport = try transport(via: relay)
        var streams: [Held] = []
        for _ in 0..<5 { streams.append(try await hold(transport, subscribe)) }
        for held in streams { assertAcknowledged(held) }
        // 3 on the shared connection; the 4th and 5th are refused there and open their own.
        XCTAssertEqual(relay.accepted, 3)
        for held in streams { held.task?.cancel() }
        await transport.close()
    }
}
