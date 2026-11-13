import XCTest
import Foundation
import Citadel
import NIOCore
@testable import HerdrKit

/// Where a stream's channel runs (`SharedFirstLink`) and how `CitadelTransport.stream`
/// drives it, without SSH. The live proof that every stream rides one TCP connection
/// is `SharedConnectionLiveTests`.
final class SharedFirstLinkTests: XCTestCase {
    /// Records what the placement did with its slot and its own connection.
    final class Placement: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        func note(_ event: String) { lock.withLock { log.append(event) } }
        var events: [String] { lock.withLock { log } }
    }

    /// A link whose run ends with `outcome` once stdin finishes (or at once, when it
    /// throws), and notes that it ran.
    struct ScriptedLink: RequestChannelLink {
        let name: String
        let placement: Placement
        let failure: Error?

        func run(
            stdin: AsyncStream<ByteBuffer>,
            onOutput: @escaping @Sendable (ExecCommandOutput) async -> Void
        ) async throws {
            placement.note("run \(name)")
            if let failure { throw failure }
            await onOutput(.stdout(ByteBuffer(string: "\(name)\n")))
            for await _ in stdin {}
        }
    }

    private func link(
        _ placement: Placement, shared: Error?? = .some(nil), dedicated: Error? = nil
    ) -> SharedFirstLink {
        var link = SharedFirstLink(
            shared: {
                // .none: the shared connection is full; .some(failure): a slot whose
                // channel fails with `failure` (nil: runs fine).
                guard case .some(let failure) = shared else { return nil }
                return SharedChannelSlot(
                    link: ScriptedLink(name: "shared", placement: placement, failure: failure),
                    release: { placement.note("release") },
                    openTimedOut: { placement.note("drop connection") })
            },
            dedicated: {
                placement.note("connect own")
                return DedicatedChannel(
                    link: ScriptedLink(name: "own", placement: placement, failure: dedicated),
                    close: { placement.note("close own") })
            })
        link.isRefused = { $0 is RejectedOpen }
        return link
    }

    private func run(_ link: SharedFirstLink) async -> (lines: [String], error: Error?) {
        let (stdin, sink) = AsyncStream<ByteBuffer>.makeStream()
        sink.finish()
        let lines = Placement()
        do {
            try await link.run(stdin: stdin) { chunk in
                if case .stdout(let bytes) = chunk { lines.note(String(buffer: bytes)) }
            }
            return (lines.events, nil)
        } catch {
            return (lines.events, error)
        }
    }

    func testAStreamRunsOnTheSharedConnectionAndGivesItsSlotBack() async {
        let placement = Placement()
        let result = await run(link(placement))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.lines, ["shared\n"])
        XCTAssertEqual(placement.events, ["run shared", "release"])
    }

    /// sshd refused the channel (OpenSSH `MaxSessions`): the stream still opens, on a
    /// connection of its own, and the shared connection is left as it was.
    func testARefusedChannelFallsBackToItsOwnConnection() async {
        let placement = Placement()
        let result = await run(link(placement, shared: .some(RejectedOpen())))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.lines, ["own\n"])
        XCTAssertEqual(placement.events, ["run shared", "release", "connect own", "run own", "close own"])
    }

    /// The shared connection is full: straight to a connection of its own.
    func testAFullSharedConnectionSendsTheStreamToItsOwnConnection() async {
        let placement = Placement()
        let result = await run(link(placement, shared: .none))
        XCTAssertNil(result.error)
        XCTAssertEqual(placement.events, ["connect own", "run own", "close own"])
    }

    /// An open sshd never answers means a dead (half-open) connection: it is dropped so
    /// the next open reconnects, and this stream fails rather than dialling around it.
    func testAnUnansweredOpenDropsTheSharedConnection() async {
        let placement = Placement()
        let result = await run(link(placement, shared: .some(CitadelError.channelCreationFailed)))
        XCTAssertEqual(result.error as? CitadelError, .channelCreationFailed)
        XCTAssertEqual(placement.events, ["run shared", "drop connection", "release"])
    }

    /// Any other channel failure (the bridge exiting, the channel dropping) is this
    /// stream's alone: no fallback, no effect on the connection.
    func testAnyOtherChannelFailureEndsOnlyThatStream() async {
        let placement = Placement()
        let result = await run(link(placement, shared: .some(ScriptedExit(remoteExitCode: 1))))
        XCTAssertEqual((result.error as? ScriptedExit)?.remoteExitCode, 1)
        XCTAssertEqual(placement.events, ["run shared", "release"])
    }

    func testAFailingOwnConnectionStillCloses() async {
        let placement = Placement()
        let result = await run(link(placement, shared: .none, dedicated: ScriptedDrop()))
        XCTAssertEqual(result.error as? ScriptedDrop, ScriptedDrop())
        XCTAssertEqual(placement.events, ["connect own", "run own", "close own"])
    }

    /// Stands in for NIOSSH's `channelSetupRejected`, which only NIOSSH can construct.
    /// The real one is exercised live (`SharedConnectionLiveTests`, `MaxSessions`).
    private struct RejectedOpen: Error {}
}

/// `CitadelTransport.stream` over a scripted stream link: lines in order, the channel
/// closed when the consumer stops, and failures classified as before.
final class CitadelTransportStreamTests: XCTestCase {
    final class Links: @unchecked Sendable {
        private let lock = NSLock()
        private var opened: [(command: String, bridge: ScriptedBridge)] = []
        func open(_ command: String) -> ScriptedBridge {
            let bridge = ScriptedBridge(responder: { _ in nil })
            lock.withLock { opened.append((command, bridge)) }
            return bridge
        }
        var all: [(command: String, bridge: ScriptedBridge)] { lock.withLock { opened } }
    }

    private func transport(_ links: Links) -> CitadelTransport {
        let credentials = SSHCredentials(host: "box", username: "u", password: "p", remoteSocketPath: "")
        let connection = SSHConnectionCore(
            credentials: credentials, hostKeyValidator: .acceptAnything(), connectTimeoutNanoseconds: 1_000_000_000)
        let backend = ExecBackend(
            execute: { _ in throw ScriptedDrop() },
            openLink: { _ in throw ScriptedDrop() },
            openStreamLink: { command in links.open(command) })
        return CitadelTransport(credentials: credentials, connection: connection, backend: backend)
    }

    private let subscribe = #"{"id":"s","method":"events.subscribe","params":{"subscriptions":[]}}"#

    /// The stream rides a stream link (never a connection of its own here), yields its
    /// lines in order, and closes that channel, by finishing its stdin, when the
    /// consumer stops reading.
    func testLinesArriveInOrderAndStoppingClosesTheChannel() async throws {
        let links = Links()
        let stream = transport(links).stream(subscribe)
        let received = SharedFirstLinkTests.Placement()
        let reader = Task {
            for try await line in stream { received.note(line) }
        }
        try await eventually("the stream link opens") { links.all.count == 1 }
        let bridge = links.all[0].bridge
        XCTAssertTrue(links.all[0].command.contains("api-bridge"), links.all[0].command)
        bridge.emit(#"{"id":"s","result":{"type":"subscription_started"}}"#)
        bridge.emit(#"{"event":"one"}"#)
        try await eventually("both lines arrive") { received.events.count == 2 }
        XCTAssertEqual(received.events, [#"{"id":"s","result":{"type":"subscription_started"}}"#, #"{"event":"one"}"#])
        XCTAssertFalse(bridge.stdinClosed)
        reader.cancel()   // the consumer stops reading
        try await eventually("the channel closes") { bridge.stdinClosed }
    }

    /// The bridge exiting non-zero is classified exactly as a one-off request's exit.
    func testANonZeroExitIsClassified() async throws {
        let links = Links()
        let stream = transport(links).stream(subscribe)
        let reader = Task { () -> Error? in
            do {
                for try await _ in stream {}
                return nil
            } catch { return error }
        }
        try await eventually("the stream link opens") { links.all.count == 1 }
        links.all[0].bridge.exit(code: 127, stderr: CitadelTransport.herdrNotInstalledSentinel)
        let error = await reader.value
        guard case .herdrNotInstalled? = error as? TransportError else {
            return XCTFail("expected herdrNotInstalled, got \(String(describing: error))")
        }
    }

    /// A line saying the daemon socket is unreachable ends the stream with the typed
    /// error, and closes the channel.
    func testAnUnreachableDaemonEndsTheStreamTyped() async throws {
        let links = Links()
        let stream = transport(links).stream(subscribe)
        let reader = Task { () -> Error? in
            do {
                for try await _ in stream {}
                return nil
            } catch { return error }
        }
        try await eventually("the stream link opens") { links.all.count == 1 }
        let bridge = links.all[0].bridge
        bridge.emit(#"{"id":"s","error":{"code":"transport_error","message":"api-bridge: Connection refused (os error 111)"}}"#)
        let error = await reader.value
        guard case .daemonUnavailable? = error as? TransportError else {
            return XCTFail("expected daemonUnavailable, got \(String(describing: error))")
        }
        XCTAssertTrue(bridge.stdinClosed)
    }

    /// N streams are N stream links: none of them opens a connection of its own unless
    /// the placement says so.
    func testEveryStreamOpensItsOwnLink() async throws {
        let links = Links()
        let transport = transport(links)
        let streams = (0..<4).map { _ in transport.stream(subscribe) }
        let readers = streams.map { stream in Task { for try await _ in stream {} } }
        try await eventually("four stream links open") { links.all.count == 4 }
        for reader in readers { reader.cancel() }
        try await eventually("every channel closes") { links.all.allSatisfy { $0.bridge.stdinClosed } }
    }
}

/// After a failed connect the next one waits out a backoff, so the streams that all
/// lost the shared connection at once do not each dial a host that is down.
final class SSHConnectionCoreBackoffTests: XCTestCase {
    func testAConnectRightAfterAFailedOneWaitsOutTheBackoff() async throws {
        // Port 1 on loopback: nothing listens, so the connect is refused at once.
        let credentials = SSHCredentials(host: "127.0.0.1", port: 1, username: "u", password: "p", remoteSocketPath: "")
        let core = SSHConnectionCore(
            credentials: credentials, hostKeyValidator: .acceptAnything(),
            connectTimeoutNanoseconds: 2_000_000_000,
            reconnectBackoff: (initial: .milliseconds(600), maximum: .seconds(5)))
        let clock = ContinuousClock()

        let first = clock.now
        do { _ = try await core.connectedClient(); XCTFail("nothing listens on port 1") } catch {}
        let firstTook = clock.now - first
        try XCTSkipIf(firstTook > .milliseconds(300), "a refused loopback connect took \(firstTook); cannot time a backoff")

        let second = clock.now
        do { _ = try await core.connectedClient(); XCTFail("nothing listens on port 1") } catch {}
        let secondTook = clock.now - second
        XCTAssertGreaterThanOrEqual(secondTook, .milliseconds(500), "the retry did not back off")

        // The delay doubles, counted from the last failure.
        let third = clock.now
        do { _ = try await core.connectedClient(); XCTFail("nothing listens on port 1") } catch {}
        XCTAssertGreaterThanOrEqual(clock.now - third, .milliseconds(1_100), "the backoff did not grow")
    }

    /// A caller that already waited longer than the backoff (a stream's own retry
    /// delay) pays nothing extra.
    func testAConnectLongAfterTheFailureDoesNotWait() async throws {
        let credentials = SSHCredentials(host: "127.0.0.1", port: 1, username: "u", password: "p", remoteSocketPath: "")
        let core = SSHConnectionCore(
            credentials: credentials, hostKeyValidator: .acceptAnything(),
            connectTimeoutNanoseconds: 2_000_000_000,
            reconnectBackoff: (initial: .milliseconds(300), maximum: .seconds(5)))
        let clock = ContinuousClock()
        do { _ = try await core.connectedClient() } catch {}
        try await Task.sleep(for: .milliseconds(400))
        let started = clock.now
        do { _ = try await core.connectedClient() } catch {}
        XCTAssertLessThan(clock.now - started, .milliseconds(250))
    }
}
