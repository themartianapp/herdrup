import XCTest
import Foundation
import Citadel
import NIOCore
@testable import HerdrKit

// Scripted stand-ins for `herdr api-bridge --multi` (herdrup#389-#391). Nothing here
// touches SSH: `ScriptedBridge` is a `RequestChannelLink`, and `ScriptedHost` is an
// `ExecBackend` serving both the per-request exec and the held channel.

struct ScriptedExit: RemoteExitError { let remoteExitCode: Int }
struct ScriptedDrop: Error, Equatable {}

/// Monotonic time the test moves by hand, for idleness and open-retry windows.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1_000_000_000
    var now: UInt64 { lock.withLock { value } }
    func advance(_ nanoseconds: UInt64) { lock.withLock { value += nanoseconds } }
}

/// A fake `api-bridge --multi`: records every request line and answers through
/// `responder` (nil holds the request for the test to answer later, in any order).
final class ScriptedBridge: RequestChannelLink, @unchecked Sendable {
    typealias Responder = @Sendable (_ requestLine: String) -> String?

    private let lock = NSLock()
    private var received: [String] = []
    private var responder: Responder
    private var stdinClosedFlag = false
    private let output: AsyncThrowingStream<ExecCommandOutput, Error>
    private let outputContinuation: AsyncThrowingStream<ExecCommandOutput, Error>.Continuation

    init(responder: @escaping Responder = ScriptedBridge.answerPings) {
        self.responder = responder
        (output, outputContinuation) = AsyncThrowingStream<ExecCommandOutput, Error>.makeStream()
    }

    /// Answers `ping` (what `RequestChannel.open` and probes send) and holds the rest.
    static let answerPings: Responder = { line in
        line.contains(#""method":"ping""#) ? reply(to: line, result: #"{"type":"pong"}"#) : nil
    }

    /// Answers every request with `{"via":"channel"}`.
    static let answerAll: Responder = { line in
        line.contains(#""method":"ping""#)
            ? reply(to: line, result: #"{"type":"pong"}"#)
            : reply(to: line, result: #"{"via":"channel"}"#)
    }

    static func reply(to requestLine: String, result: String) -> String {
        #"{"id":"\#(RequestChannel.responseID(requestLine) ?? "")","result":\#(result)}"#
    }

    var requests: [String] { lock.withLock { received } }
    var nonPingRequests: [String] { requests.filter { !$0.contains(#""method":"ping""#) } }
    var pingCount: Int { requests.count - nonPingRequests.count }
    var stdinClosed: Bool { lock.withLock { stdinClosedFlag } }
    func setResponder(_ responder: @escaping Responder) { lock.withLock { self.responder = responder } }

    func emit(_ line: String) {
        outputContinuation.yield(.stdout(ByteBuffer(string: line + "\n")))
    }

    /// Writes bytes as they are, newline or not: part of a reply still arriving.
    func emitRaw(_ bytes: String) {
        outputContinuation.yield(.stdout(ByteBuffer(string: bytes)))
    }

    func answer(_ requestLine: String, result: String) {
        emit(Self.reply(to: requestLine, result: result))
    }

    /// The bridge process exits with `code`, writing `stderr` first.
    func exit(code: Int, stderr: String = "") {
        if !stderr.isEmpty { outputContinuation.yield(.stderr(ByteBuffer(string: stderr))) }
        outputContinuation.finish(throwing: code == 0 ? nil : ScriptedExit(remoteExitCode: code))
    }

    /// The SSH link drops under the channel.
    func drop() {
        outputContinuation.finish(throwing: ScriptedDrop())
    }

    func run(
        stdin: AsyncStream<ByteBuffer>,
        onOutput: @escaping @Sendable (ExecCommandOutput) async -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var lines = LineAccumulator()
                for await buffer in stdin {
                    for line in lines.append(buffer) { self.receive(line) }
                }
                // Like the real bridge: stdin closing ends the process.
                self.lock.withLock { self.stdinClosedFlag = true }
                self.outputContinuation.finish()
            }
            group.addTask {
                for try await chunk in self.output { await onOutput(chunk) }
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func receive(_ line: String) {
        let responder = lock.withLock { () -> Responder in
            received.append(line)
            return self.responder
        }
        if let reply = responder(line) { emit(reply) }
    }
}

/// Polls `condition` until it holds; fails the test after `timeout` seconds.
func eventually(
    _ message: String, timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line,
    _ condition: @Sendable () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("timed out waiting for: \(message)", file: file, line: line)
}

func requestLine(_ id: String, method: String = "agent.list") -> String {
    #"{"id":"\#(id)","method":"\#(method)","params":{}}"#
}

/// `XCTAssertEqual` for an actor-isolated value (XCTest's autoclosures are synchronous).
func assertEqual<T: Equatable>(
    _ actual: @autoclosure () async -> T, _ expected: T,
    file: StaticString = #filePath, line: UInt = #line
) async {
    let value = await actual()
    XCTAssertEqual(value, expected, file: file, line: line)
}

let ms: UInt64 = 1_000_000
let longTime: UInt64 = 3_600 * 1_000_000_000

func testSettings(clock: ManualClock = ManualClock()) -> RequestChannelSettings {
    var settings = RequestChannelSettings()
    settings.requestTimeout = 2_000 * ms
    settings.idleProbeAfter = longTime
    settings.probeTimeout = 2_000 * ms
    settings.openTimeout = 2_000 * ms
    settings.unusedCloseAfter = longTime
    settings.openRetryAfter = 30_000 * ms
    settings.now = { clock.now }
    return settings
}

// MARK: - RequestChannel (#389)

final class RequestChannelTests: XCTestCase {
    private func openChannel(
        _ bridge: ScriptedBridge, settings: RequestChannelSettings = testSettings()
    ) async throws -> RequestChannel {
        let channel = RequestChannel(host: "box", settings: settings)
        try await channel.open(bridge)
        return channel
    }

    func testReplyIsMatchedToItsRequestByID() async throws {
        let bridge = ScriptedBridge(responder: ScriptedBridge.answerAll)
        let channel = try await openChannel(bridge)
        let reply = try await channel.send(requestLine("a"), id: "a", timeout: 2_000 * ms)
        XCTAssertEqual(reply, #"{"id":"a","result":{"via":"channel"}}"#)
        XCTAssertEqual(bridge.nonPingRequests, [requestLine("a")])
    }

    func testOutOfOrderRepliesReachTheirOwnRequests() async throws {
        let bridge = ScriptedBridge()
        let channel = try await openChannel(bridge)
        async let a = channel.send(requestLine("a"), id: "a", timeout: 2_000 * ms)
        async let b = channel.send(requestLine("b"), id: "b", timeout: 2_000 * ms)
        async let c = channel.send(requestLine("c"), id: "c", timeout: 2_000 * ms)
        try await eventually("three requests written") { bridge.nonPingRequests.count == 3 }
        // Reverse order, plus a reply nobody asked for, which must be dropped.
        bridge.emit(#"{"id":"","error":{"code":"invalid_request","message":"duplicate id"}}"#)
        bridge.answer(requestLine("c"), result: #""C""#)
        bridge.answer(requestLine("a"), result: #""A""#)
        bridge.answer(requestLine("b"), result: #""B""#)
        let replies = try await [a, b, c]
        XCTAssertEqual(replies, [
            #"{"id":"a","result":"A"}"#, #"{"id":"b","result":"B"}"#, #"{"id":"c","result":"C"}"#,
        ])
    }

    func testTimedOutRequestFailsAndLeavesThePendingMap() async throws {
        let bridge = ScriptedBridge()
        let channel = try await openChannel(bridge)
        do {
            _ = try await channel.send(requestLine("slow"), id: "slow", timeout: 50 * ms)
            XCTFail("expected a timeout")
        } catch TransportError.requestTimedOut(let host) {
            XCTAssertEqual(host, "box")
        }
        // Removed from the map: the late reply to the first send resolves nothing, and
        // the same id is accepted again (a stale entry would throw `duplicateID`).
        bridge.answer(requestLine("slow"), result: #""late""#)
        // The probe's pong is emitted after the late reply on the same ordered stream,
        // so once the probe returns the late reply has been seen and dropped.
        let probed = await channel.probe()
        XCTAssertTrue(probed)
        bridge.setResponder(ScriptedBridge.answerAll)
        let reply = try await channel.send(requestLine("slow"), id: "slow", timeout: 2_000 * ms)
        XCTAssertEqual(reply, #"{"id":"slow","result":{"via":"channel"}}"#)
    }

    func testTimeoutMarksTheChannelSuspect() async throws {
        let bridge = ScriptedBridge()
        let channel = try await openChannel(bridge)
        await assertEqual(await channel.status(), .ready)
        _ = try? await channel.send(requestLine("slow"), id: "slow", timeout: 20 * ms)
        await assertEqual(await channel.status(), .needsProbe)
    }

    func testDuplicateInFlightIDIsNotWritten() async throws {
        let bridge = ScriptedBridge()
        let channel = try await openChannel(bridge)
        let first = Task { try await channel.send(requestLine("x"), id: "x", timeout: 2_000 * ms) }
        try await eventually("first request written") { bridge.nonPingRequests.count == 1 }
        do {
            _ = try await channel.send(requestLine("x"), id: "x", timeout: 2_000 * ms)
            XCTFail("expected duplicateID")
        } catch let error as RequestChannel.NotSent {
            XCTAssertEqual(error, .duplicateID)
        }
        XCTAssertEqual(bridge.nonPingRequests.count, 1)
        bridge.answer(requestLine("x"), result: "1")
        _ = try await first.value
    }

    /// Every pending request fails with what the per-request path throws for an exec
    /// that ends the same way: here a non-zero exit with a diagnostic.
    func testChannelExitFailsEveryPendingRequestLikeThePerRequestPath() async throws {
        let bridge = ScriptedBridge()
        let channel = try await openChannel(bridge)
        let a = Task { try await channel.send(requestLine("a"), id: "a", timeout: 2_000 * ms) }
        let b = Task { try await channel.send(requestLine("b"), id: "b", timeout: 2_000 * ms) }
        try await eventually("both written") { bridge.nonPingRequests.count == 2 }
        bridge.exit(code: 1, stderr: "herdr: socket gone")

        let expected = try await perRequestFailure(exitCode: 1, stderr: "herdr: socket gone")
        for task in [a, b] {
            do {
                _ = try await task.value
                XCTFail("expected a failure")
            } catch {
                XCTAssertEqual(String(describing: error), expected)
                guard case TransportError.bridgeFailed = error else { return XCTFail("got \(error)") }
            }
        }
        await assertEqual(await channel.isOpen, false)
        do {
            _ = try await channel.send(requestLine("c"), id: "c", timeout: 2_000 * ms)
            XCTFail("a dead channel must refuse")
        } catch let error as RequestChannel.NotSent {
            XCTAssertEqual(error, .closed)
        }
    }

    func testCleanEOFFailsPendingWithClosedBeforeResponse() async throws {
        let bridge = ScriptedBridge()
        let channel = try await openChannel(bridge)
        let a = Task { try await channel.send(requestLine("a"), id: "a", timeout: 2_000 * ms) }
        try await eventually("written") { bridge.nonPingRequests.count == 1 }
        bridge.exit(code: 0)
        do {
            _ = try await a.value
            XCTFail("expected a failure")
        } catch TransportError.closedBeforeResponse {}
    }

    func testDroppedLinkFailsPendingWithTheLinkError() async throws {
        let bridge = ScriptedBridge()
        let channel = try await openChannel(bridge)
        let a = Task { try await channel.send(requestLine("a"), id: "a", timeout: 2_000 * ms) }
        try await eventually("written") { bridge.nonPingRequests.count == 1 }
        bridge.drop()
        do {
            _ = try await a.value
            XCTFail("expected a failure")
        } catch let error as ScriptedDrop {
            XCTAssertEqual(error, ScriptedDrop())
        }
    }

    /// herdr's `transport_error` reply for a missing daemon socket classifies exactly
    /// as on the per-request path.
    func testDaemonSocketFailureReplyClassifiesAsDaemonUnavailable() async throws {
        let bridge = ScriptedBridge()
        let channel = try await openChannel(bridge)
        let a = Task { try await channel.send(requestLine("a"), id: "a", timeout: 2_000 * ms) }
        try await eventually("written") { bridge.nonPingRequests.count == 1 }
        bridge.emit(#"{"id":"a","error":{"code":"transport_error","message":"api-bridge: No such file or directory (os error 2)"}}"#)
        do {
            _ = try await a.value
            XCTFail("expected a failure")
        } catch TransportError.daemonUnavailable(let host) {
            XCTAssertEqual(host, "box")
        }
    }

    /// An herdr without `--multi` exits with a usage error instead of answering the
    /// opening ping, so `open` fails and the caller keeps the per-request path.
    func testOpenFailsWhenTheBridgeExitsInsteadOfAnswering() async throws {
        let bridge = ScriptedBridge(responder: { _ in nil })
        let channel = RequestChannel(host: "box", settings: testSettings())
        let opening = Task { try await channel.open(bridge) }
        try await eventually("opening ping written") { bridge.requests.count == 1 }
        bridge.exit(code: 2, stderr: "error: unexpected argument '--multi' found")
        do {
            try await opening.value
            XCTFail("expected open to fail")
        } catch {}
        await assertEqual(await channel.isOpen, false)
    }

    func testOpenFailsWhenTheBridgeNeverAnswers() async throws {
        var settings = testSettings()
        settings.openTimeout = 50 * ms
        let bridge = ScriptedBridge(responder: { _ in nil })
        let channel = RequestChannel(host: "box", settings: settings)
        do {
            try await channel.open(bridge)
            XCTFail("expected open to time out")
        } catch TransportError.requestTimedOut {}
        await assertEqual(await channel.isOpen, false)
        try await eventually("stdin closed on the dead channel") { bridge.stdinClosed }
    }

    // MARK: #391 on the channel

    func testIdleChannelNeedsAProbeAndAnsweredProbeRestoresIt() async throws {
        let clock = ManualClock()
        var settings = testSettings(clock: clock)
        settings.idleProbeAfter = 30_000 * ms
        let bridge = ScriptedBridge()
        let channel = try await openChannel(bridge, settings: settings)
        await assertEqual(await channel.status(), .ready)
        clock.advance(30_000 * ms)
        await assertEqual(await channel.status(), .needsProbe)
        let probed = await channel.probe()
        XCTAssertTrue(probed)
        await assertEqual(await channel.status(), .ready)
        XCTAssertEqual(bridge.pingCount, 2)
    }

    func testUnansweredProbeClosesTheChannel() async throws {
        var settings = testSettings()
        settings.probeTimeout = 50 * ms
        let bridge = ScriptedBridge()
        let channel = try await openChannel(bridge, settings: settings)
        bridge.setResponder { _ in nil }  // the link went silent
        await channel.markSuspect()
        await assertEqual(await channel.status(), .needsProbe)
        let probed = await channel.probe()
        XCTAssertFalse(probed)
        await assertEqual(await channel.status(), .closed)
        try await eventually("stdin closed") { bridge.stdinClosed }
    }

    /// The 3G foreground case from the slow-network bench: a 0.9 MB transcript reply is
    /// still arriving when the app returns to the front, so the probe's pong queues
    /// behind it for longer than the probe budget. The link is working, so the probe
    /// must pass and the reply must land, instead of the channel closing and failing it
    /// with "peer closed before sending a response line".
    func testProbeBehindAReplyStillStreamingInKeepsTheChannelAndTheReply() async throws {
        var settings = testSettings()
        settings.probeTimeout = 60 * ms
        let bridge = ScriptedBridge()
        let channel = try await openChannel(bridge, settings: settings)
        bridge.setResponder { _ in nil }  // replies come from the feeder below, in order
        let big = Task {
            try await channel.send(requestLine("big", method: "agent.transcript"), id: "big", timeout: 5_000 * ms)
        }
        try await eventually("big request written") { bridge.nonPingRequests.count == 1 }
        await channel.markSuspect()

        // The big reply arrives in pieces for ~4x the probe budget; the pong only after it.
        let feeder = Task {
            bridge.emitRaw(#"{"id":"big","result":{"text":""#)
            for _ in 0..<12 {
                try await Task.sleep(nanoseconds: 20 * ms)
                bridge.emitRaw(String(repeating: "x", count: 4096))
            }
            bridge.emitRaw("\"}}\n")
            try await eventually("probe ping written") { bridge.pingCount == 2 }
            let ping = try XCTUnwrap(bridge.requests.last { $0.contains(#""method":"ping""#) })
            bridge.emit(ScriptedBridge.reply(to: ping, result: #"{"type":"pong"}"#))
        }

        let probed = await channel.probe()
        XCTAssertTrue(probed, "bytes still arriving prove the link alive")
        await assertEqual(await channel.isOpen, true)
        let reply = try await big.value
        XCTAssertTrue(reply.hasPrefix(#"{"id":"big""#))
        XCTAssertEqual(reply.utf8.count, #"{"id":"big","result":{"text":""}}"#.utf8.count + 12 * 4096)
        try await feeder.value
        await assertEqual(await channel.status(), .ready)
    }

    /// A link that sent part of a reply and then went silent is dead: only bytes after
    /// the probe started count.
    func testProbeOnALinkThatStoppedMidReplyClosesIt() async throws {
        var settings = testSettings()
        settings.probeTimeout = 60 * ms
        let bridge = ScriptedBridge()
        let channel = try await openChannel(bridge, settings: settings)
        bridge.setResponder { _ in nil }
        let big = Task {
            try await channel.send(requestLine("big", method: "agent.transcript"), id: "big", timeout: 5_000 * ms)
        }
        try await eventually("big request written") { bridge.nonPingRequests.count == 1 }
        bridge.emitRaw(#"{"id":"big","result":{"text":"xxxx"#)
        try await Task.sleep(nanoseconds: 20 * ms)
        await channel.markSuspect()
        let probed = await channel.probe()
        XCTAssertFalse(probed)
        await assertEqual(await channel.status(), .closed)
        do {
            _ = try await big.value
            XCTFail("the dead channel's request must fail")
        } catch TransportError.closedBeforeResponse {}
    }

    func testChannelUnusedForTheIntervalCloses() async throws {
        var settings = testSettings()
        settings.unusedCloseAfter = 400 * ms
        let bridge = ScriptedBridge(responder: ScriptedBridge.answerAll)
        let channel = try await openChannel(bridge, settings: settings)
        // Use keeps it open: each request restarts the interval.
        for index in 0..<4 {
            try await Task.sleep(nanoseconds: 150 * ms)
            _ = try await channel.send(requestLine("r\(index)"), id: "r\(index)", timeout: 2_000 * ms)
            await assertEqual(await channel.isOpen, true)
        }
        try await eventually("closed once unused") { await !channel.isOpen }
        try await eventually("bridge saw stdin EOF") { bridge.stdinClosed }
    }

    func testChannelWithARequestInFlightIsNotClosedAsUnused() async throws {
        var settings = testSettings()
        settings.unusedCloseAfter = 30 * ms
        let bridge = ScriptedBridge()
        let channel = try await openChannel(bridge, settings: settings)
        let slow = Task { try await channel.send(requestLine("slow"), id: "slow", timeout: 2_000 * ms) }
        try await eventually("written") { bridge.nonPingRequests.count == 1 }
        try await Task.sleep(nanoseconds: 120 * ms)
        await assertEqual(await channel.isOpen, true)
        bridge.answer(requestLine("slow"), result: "1")
        _ = try await slow.value
    }

    // MARK: routing rules

    func testRouteAppliesTheBridgeLimits() {
        XCTAssertEqual(RequestChannel.route(requestLine("a"))?.id, "a")
        XCTAssertNil(RequestChannel.route(requestLine("s", method: "pane.stream")))
        XCTAssertNil(RequestChannel.route(requestLine("s", method: "events.subscribe")))
        XCTAssertNil(RequestChannel.route(requestLine("")))
        XCTAssertNil(RequestChannel.route(#"{"method":"ping","params":{}}"#))
        XCTAssertNil(RequestChannel.route("not json"))

        // Exactly the bridge's 1 MiB line limit rides the channel; one byte more does not.
        let skeleton = requestLine("big").replacingOccurrences(of: "{}", with: #"{"text":""}"#)
        let filler = String(repeating: "x", count: RequestChannel.maxRequestLineBytes - skeleton.utf8.count)
        let atLimit = skeleton.replacingOccurrences(of: #""text":"""#, with: #""text":"\#(filler)""#)
        XCTAssertEqual(atLimit.utf8.count, RequestChannel.maxRequestLineBytes)
        XCTAssertEqual(RequestChannel.route(atLimit)?.id, "big")
        XCTAssertNil(RequestChannel.route(atLimit.replacingOccurrences(of: "xx", with: "xxx", options: [], range: atLimit.range(of: "xx"))))
    }

    func testRouteSendsReplyHeavyMethodsToTheBulkLane() {
        for method in ["agent.transcript", "agent.read", "pane.read", "pane.history",
                       "gram.list", "gram.get_file", "gram.get_file_chunk"] {
            XCTAssertEqual(RequestChannel.route(requestLine("b", method: method))?.lane, .bulk, method)
        }
        for method in ["agent.list", "ping", "accounts.list", "agent.prompt", "pane.send_text", "gram.post"] {
            XCTAssertEqual(RequestChannel.route(requestLine("i", method: method))?.lane, .interactive, method)
        }
    }

    func testResponseIDReadsHerdrsLeadingIDAndFallsBackToJSON() {
        XCTAssertEqual(RequestChannel.responseID(#"{"id":"herdrkit:ping:3","result":{}}"#), "herdrkit:ping:3")
        XCTAssertEqual(RequestChannel.responseID(#"{"result":{},"id":"late"}"#), "late")
        XCTAssertEqual(RequestChannel.responseID(#"{"id":"a\"b","result":{}}"#), #"a"b"#)
        XCTAssertNil(RequestChannel.responseID("garbage"))
    }

    /// What `parseBridgeOutput` (the per-request path) throws for an exec that writes
    /// `stderr` and exits `exitCode` without a reply.
    private func perRequestFailure(exitCode: Int, stderr: String) async throws -> String {
        let (stream, continuation) = AsyncThrowingStream<ExecCommandOutput, Error>.makeStream()
        continuation.yield(.stderr(ByteBuffer(string: stderr)))
        continuation.finish(throwing: ScriptedExit(remoteExitCode: exitCode))
        do {
            _ = try await CitadelTransport.parseBridgeOutput(stream, host: "box")
            XCTFail("expected a failure")
            return ""
        } catch {
            return String(describing: error)
        }
    }
}
