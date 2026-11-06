import XCTest
import Foundation
import Citadel
import NIOCore
@testable import HerdrKit

// `pane.input.stream` (fire-and-forget key input): the channel's framing and endings over
// a scripted `remote-api-bridge` (`ScriptedBridge`), the terminal's `PaneInputSender`
// routing between the stream and `pane.send_text`, and the `HerdrClient` gate that
// decides which panes may stream. Nothing here touches SSH.

/// A herdr host behind `CitadelTransport`: per-request execs answer `ping` with the
/// configured capabilities and every other request with `{}`; held links must be
/// `remote-api-bridge` and answer the stream's open line with `openReply`.
final class InputStreamHost: @unchecked Sendable {
    private let lock = NSLock()
    private let capabilities: String
    private let openReply: @Sendable (_ openLine: String) -> String
    private var execRequests: [String] = []
    private var links: [(command: String, bridge: ScriptedBridge)] = []

    init(
        capabilities: String = #"{"pane_input_stream":true}"#,
        openReply: @escaping @Sendable (_ openLine: String) -> String = InputStreamHost.acceptOpen
    ) {
        self.capabilities = capabilities
        self.openReply = openReply
    }

    static let acceptOpen: @Sendable (String) -> String = { line in
        ScriptedBridge.reply(to: line, result: #"{"type":"ok"}"#)
    }

    static let refuseOpen: @Sendable (String) -> String = { line in
        #"{"id":"\#(RequestChannel.responseID(line) ?? "")","error":{"code":"pane_not_found","message":"no such pane"}}"#
    }

    var requests: [String] { lock.withLock { execRequests } }
    /// `ping`s the client sent (the request pool's own capability probe has other ids).
    var pings: Int { requests.filter { $0.contains(#""id":"herdrkit:ping:"#) }.count }
    var sentTexts: [String] {
        requests.compactMap { line in
            guard line.contains(#""method":"pane.send_text""#),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let params = object["params"] as? [String: Any]
            else { return nil }
            return params["text"] as? String
        }
    }
    var opened: [(command: String, bridge: ScriptedBridge)] { lock.withLock { links } }

    var backend: ExecBackend {
        ExecBackend(
            execute: { command in
                let request = ScriptedHost.request(in: command)
                let reply: String = self.lock.withLock {
                    self.execRequests.append(request)
                    if request.contains(#""method":"ping""#) {
                        return ScriptedBridge.reply(
                            to: request,
                            result: #"{"type":"pong","version":"0.9.3","protocol":1,"capabilities":\#(self.capabilities)}"#)
                    }
                    return ScriptedBridge.reply(to: request, result: "{}")
                }
                return AsyncThrowingStream { continuation in
                    continuation.yield(.stdout(ByteBuffer(string: reply + "\n")))
                    continuation.finish()
                }
            },
            openLink: { command in
                XCTAssertTrue(command.contains("remote-api-bridge"), command)
                XCTAssertFalse(command.contains("api-bridge --multi"), command)
                let openReply = self.openReply
                let bridge = ScriptedBridge { line in
                    line.contains(#""method":"pane.input.stream""#) ? openReply(line) : nil
                }
                self.lock.withLock { self.links.append((command, bridge)) }
                return bridge
            })
    }

    func client(session: String? = nil) -> HerdrClient {
        var credentials = SSHCredentials(host: "box", username: "u", password: "p", remoteSocketPath: "")
        credentials.session = session
        let connection = SSHConnectionCore(
            credentials: credentials, hostKeyValidator: .acceptAnything(), connectTimeoutNanoseconds: 1_000 * ms)
        return HerdrClient(transport: CitadelTransport(
            credentials: credentials, connection: connection, backend: backend,
            requestChannelSettings: testSettings()))
    }
}

/// One decoded input frame as the bridge received it.
private struct SentFrame: Decodable, Equatable {
    let seq: UInt64
    let text: String
    let ack: Bool
}

private func frames(_ bridge: ScriptedBridge) -> [SentFrame] {
    bridge.requests
        .filter { !$0.contains(#""method":"pane.input.stream""#) }
        .compactMap { try? JSONDecoder().decode(SentFrame.self, from: Data($0.utf8)) }
}

private let openLine = #"{"id":"open-1","method":"pane.input.stream","params":{"pane_id":"w1:p1"}}"#

private func answerOpen(_ line: String) -> String? {
    line.contains(#""method":"pane.input.stream""#) ? ScriptedBridge.reply(to: line, result: #"{"type":"ok"}"#) : nil
}

/// Waits (yielding) until `condition` holds; fails the test after `seconds`.
@MainActor
private func waitUntil(
    _ what: String, seconds: Double = 2, file: StaticString = #filePath, line: UInt = #line,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline {
            XCTFail("timed out waiting for: \(what)", file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

/// Records every `send_text`; optionally holds each one until `release()`.
private final class TextSink: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    private var holding: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(holding: Bool = false) { self.holding = holding }

    var sent: [String] { lock.withLock { texts } }

    func send(_ text: String) async {
        lock.withLock { texts.append(text) }
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if holding { waiters.append(waiter); return false }
                return true
            }
            if resumeNow { waiter.resume() }
        }
    }

    func release() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            holding = false
            defer { waiters = [] }
            return waiters
        }
        waiting.forEach { $0.resume() }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    @discardableResult
    func increment() -> Int { lock.withLock { count += 1; return count } }
}

private final class FakeTime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1_000
    var now: TimeInterval { lock.withLock { value } }
    func advance(ms: Double) { lock.withLock { value += ms / 1000 } }
}

// MARK: - PaneInputChannel

final class PaneInputChannelTests: XCTestCase {
    private func openChannel(_ bridge: ScriptedBridge) async throws -> PaneInputChannel {
        let channel = PaneInputChannel(link: bridge, openLine: openLine)
        try await channel.start()
        return channel
    }

    private func waitForFrames(_ bridge: ScriptedBridge, count: Int) async throws {
        let deadline = Date().addingTimeInterval(2)
        while frames(bridge).count < count {
            guard Date() < deadline else { return XCTFail("bridge got \(frames(bridge).count) of \(count) frames") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func testFramesCarrySeqFromOneInOrderWithoutWaitingForAcks() async throws {
        let bridge = ScriptedBridge(responder: answerOpen)
        let channel = try await openChannel(bridge)
        XCTAssertEqual(bridge.requests.first, openLine, "the open request goes first")

        // Three sends back to back, none acked: each is written at once.
        XCTAssertEqual(try channel.send("l"), 1)
        XCTAssertEqual(try channel.send("s"), 2)
        XCTAssertEqual(try channel.send("\r"), 3)
        try await waitForFrames(bridge, count: 3)

        XCTAssertEqual(frames(bridge), [
            SentFrame(seq: 1, text: "l", ack: true),
            SentFrame(seq: 2, text: "s", ack: true),
            SentFrame(seq: 3, text: "\r", ack: true),
        ])
        channel.close()
    }

    func testAcksArriveAsEventsInOrder() async throws {
        let bridge = ScriptedBridge(responder: answerOpen)
        let channel = try await openChannel(bridge)
        try channel.send("a")
        try channel.send("b")
        bridge.emit(#"{"seq":1,"ok":true}"#)
        bridge.emit(#"{"seq":2,"ok":true}"#)
        bridge.emit(#"{"seq":2,"ok":true}"#)     // a repeat is not a new ack

        var iterator = channel.events.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        XCTAssertEqual(first, .acked(1))
        XCTAssertEqual(second, .acked(2))
        XCTAssertEqual(channel.ackedThrough, 2)
        channel.close()
    }

    func testOpenRefusalThrowsAndEndsTheLink() async throws {
        let bridge = ScriptedBridge { line in
            line.contains("pane.input.stream")
                ? #"{"id":"open-1","error":{"code":"pane_not_found","message":"no such pane"}}"#
                : nil
        }
        let channel = PaneInputChannel(link: bridge, openLine: openLine)
        do {
            try await channel.start()
            XCTFail("a refused open must throw")
        } catch let ending as PaneInputChannel.Ending {
            XCTAssertEqual(ending, .rejected(APIError(code: "pane_not_found", message: "no such pane")))
        }
        XCTAssertThrowsError(try channel.send("x")) { error in
            XCTAssertEqual(error as? PaneInputChannel.SendError, .notOpen)
        }
        let deadline = Date().addingTimeInterval(2)
        while !bridge.stdinClosed && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(bridge.stdinClosed, "the bridge is told to exit")
    }

    func testOpenThatIsNeverAnsweredTimesOut() async throws {
        let bridge = ScriptedBridge { _ in nil }
        let channel = PaneInputChannel(link: bridge, openLine: openLine, openTimeout: 20 * ms)
        do {
            try await channel.start()
            XCTFail("an unanswered open must throw")
        } catch let ending as PaneInputChannel.Ending {
            XCTAssertEqual(ending, .timedOut)
        }
    }

    func testFrameErrorEndsTheChannelAfterTheAcksBeforeIt() async throws {
        let bridge = ScriptedBridge(responder: answerOpen)
        let channel = try await openChannel(bridge)
        try channel.send("a")
        try channel.send("b")
        bridge.emit(#"{"seq":1,"ok":true}"#)
        bridge.emit(#"{"seq":2,"error":{"code":"pty_write_failed","message":"gone"}}"#)

        var events: [PaneInputChannel.Event] = []
        for await event in channel.events { events.append(event) }
        XCTAssertEqual(events, [
            .acked(1),
            .ended(.rejected(APIError(code: "pty_write_failed", message: "gone"))),
        ])
        XCTAssertThrowsError(try channel.send("c"), "nothing more is written once the daemon refused a frame")
    }

    func testLinkDropEndsTheChannel() async throws {
        let bridge = ScriptedBridge(responder: answerOpen)
        let channel = try await openChannel(bridge)
        try channel.send("a")
        bridge.drop()
        var events: [PaneInputChannel.Event] = []
        for await event in channel.events { events.append(event) }
        XCTAssertEqual(events, [.ended(.linkEnded)])
        XCTAssertEqual(channel.ackedThrough, 0)
    }

    func testCloseWaitsForTheFramesAlreadyWrittenBeforeEnding() async throws {
        let bridge = ScriptedBridge(responder: answerOpen)
        let channel = try await openChannel(bridge)
        try channel.send("a")
        channel.close()
        XCTAssertThrowsError(try channel.send("b"), "a closing channel takes no new frames")
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(bridge.stdinClosed, "frame 1 is still unacked: the channel stays up for its ack")

        bridge.emit(#"{"seq":1,"ok":true}"#)
        var events: [PaneInputChannel.Event] = []
        for await event in channel.events { events.append(event) }
        XCTAssertEqual(events, [.acked(1), .ended(.closed)])
        XCTAssertEqual(frames(bridge).map(\.text), ["a"])
        let deadline = Date().addingTimeInterval(2)
        while !bridge.stdinClosed && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(bridge.stdinClosed, "the bridge is told to exit once everything is acked")
    }

    func testCloseWithNothingInFlightEndsAtOnce() async throws {
        let bridge = ScriptedBridge(responder: answerOpen)
        let channel = try await openChannel(bridge)
        try channel.send("a")
        bridge.emit(#"{"seq":1,"ok":true}"#)
        var iterator = channel.events.makeAsyncIterator()
        let acked = await iterator.next()
        XCTAssertEqual(acked, .acked(1))
        channel.close()
        let ended = await iterator.next()
        XCTAssertEqual(ended, .ended(.closed))
    }

    func testLargePasteIsSplitIntoOrderedFramesUnder64KiB() throws {
        // Quotes, backslashes, control bytes (6-byte escapes) and multi-byte scalars, so
        // the split has to account for escaping and must never cut a scalar.
        let text = String(repeating: "ab\"\\\u{1b}é😀\n\t", count: 25_000)
        let lines = PaneInputFrame.lines(text, firstSeq: 7, maxLineBytes: PaneInputChannel.maxFrameBytes)
        XCTAssertGreaterThan(lines.count, 3)

        var rebuilt = ""
        for (index, line) in lines.enumerated() {
            XCTAssertLessThanOrEqual(line.readableBytes, PaneInputChannel.maxFrameBytes)
            let bytes = Array(line.readableBytesView)
            XCTAssertEqual(bytes.last, UInt8(ascii: "\n"))
            XCTAssertFalse(bytes.dropLast().contains(UInt8(ascii: "\n")), "one frame per line")
            let frame = try JSONDecoder().decode(SentFrame.self, from: Data(bytes.dropLast()))
            XCTAssertEqual(frame.seq, 7 + UInt64(index))
            XCTAssertTrue(frame.ack)
            rebuilt += frame.text
        }
        XCTAssertEqual(rebuilt, text)
        XCTAssertTrue(PaneInputFrame.lines("", firstSeq: 1, maxLineBytes: PaneInputChannel.maxFrameBytes).isEmpty)
    }

    func testLargeSendReturnsTheLastFramesSeq() async throws {
        let bridge = ScriptedBridge(responder: answerOpen)
        let channel = try await openChannel(bridge)
        let paste = String(repeating: "x", count: 150_000)
        let last = try channel.send(paste)
        XCTAssertEqual(last, 3)
        XCTAssertEqual(try channel.send("y"), 4)
        try await waitForFrames(bridge, count: 4)
        XCTAssertEqual(frames(bridge).map(\.seq), [1, 2, 3, 4])
        XCTAssertEqual(frames(bridge).dropLast().map(\.text).joined(), paste)
        channel.close()
    }
}

// MARK: - HerdrClient: which panes may stream

final class PaneInputOpenTests: XCTestCase {
    func testLocalPaneOpensOverRemoteApiBridgeInTheClientsSession() async throws {
        let host = InputStreamHost()
        let channel = await host.client(session: "work").openPaneInput(pane: "w1:p1")
        XCTAssertNotNil(channel)
        let link = try XCTUnwrap(host.opened.first)
        XCTAssertTrue(link.command.contains("--session work remote-api-bridge"), link.command)
        let open = try XCTUnwrap(link.bridge.requests.first)
        XCTAssertTrue(open.contains(#""method":"pane.input.stream""#), open)
        XCTAssertTrue(open.contains(#""pane_id":"w1:p1""#), open)
        // The owner's typing on the stream counts as the owner's turn (turn origin, 2026-11-06).
        XCTAssertTrue(open.contains(#""input_source":"app""#), open)
        channel?.close()
    }

    func testFederatedPaneNeverOpensTheStream() async {
        let host = InputStreamHost()
        let channel = await host.client().openPaneInput(pane: "build/w1:p2")
        XCTAssertNil(channel)
        XCTAssertTrue(host.opened.isEmpty, "no stream link for a federated pane")
        XCTAssertEqual(host.pings, 0, "not even a capability probe")
    }

    func testHostWithoutTheCapabilityNeverOpensTheStream() async {
        let host = InputStreamHost(capabilities: #"{"events_v2":true}"#)
        let client = host.client()
        let first = await client.openPaneInput(pane: "w1:p1")
        let second = await client.openPaneInput(pane: "w1:p1")
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertTrue(host.opened.isEmpty)
        XCTAssertEqual(host.pings, 1, "the capability is probed once per client")
    }

    /// Pane input and gram upload read one cached probe: an old daemon costs one `ping`
    /// for both openers, not one each.
    func testPaneInputAndGramUploadShareOneProbe() async {
        let host = InputStreamHost(capabilities: #"{"events_v2":true}"#)
        let client = host.client()
        let input = await client.openPaneInput(pane: "w1:p1")
        let upload = await client.gramOpenUploadChannel(uploadID: "app-1")
        let again = await client.openPaneInput(pane: "w1:p1")
        XCTAssertNil(input)
        XCTAssertNil(upload)
        XCTAssertNil(again)
        XCTAssertTrue(host.opened.isEmpty)
        XCTAssertEqual(host.pings, 1, "one capability probe per client, shared by both openers")
    }

    func testRefusedOpenGivesNoChannel() async {
        let host = InputStreamHost(openReply: InputStreamHost.refuseOpen)
        let channel = await host.client().openPaneInput(pane: "w1:p1")
        XCTAssertNil(channel)
        XCTAssertEqual(host.opened.count, 1)
    }

    func testNonSSHTransportGivesNoChannel() async {
        struct Unreachable: HerdrTransport {
            func roundTrip(_ requestLine: String) async throws -> String {
                XCTFail("no request for a transport that cannot stream: \(requestLine)")
                throw TransportError.closedBeforeResponse
            }
            func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { $0.finish(throwing: TransportError.closedBeforeResponse) }
            }
        }
        let channel = await HerdrClient(transport: Unreachable()).openPaneInput(pane: "w1:p1")
        XCTAssertNil(channel)
    }
}

// MARK: - PaneInputSender: routing between the stream and send_text

@MainActor
final class PaneInputSenderTests: XCTestCase {
    private func makeRecorder() -> (TypingLatencyRecorder, FakeTime) {
        let time = FakeTime()
        let recorder = TypingLatencyRecorder(clock: { time.now })
        recorder.begin(host: "mac-mini", network: "Wi-Fi")
        return (recorder, time)
    }

    /// A sender whose first stream is `bridge`, opened directly so the test owns it. A
    /// later open (a reopen) is counted and fails: a scripted bridge serves one link.
    private func makeSender(
        sink: TextSink, bridge: ScriptedBridge, opens: Counter = Counter(),
        recorder: TypingLatencyRecorder = TypingLatencyRecorder(), time: FakeTime = FakeTime()
    ) -> PaneInputSender {
        PaneInputSender(
            sendText: { text in await sink.send(text) },
            openStream: {
                guard opens.increment() == 1 else { return nil }
                let channel = PaneInputChannel(link: bridge, openLine: openLine)
                do { try await channel.start() } catch { return nil }
                return channel
            },
            recorder: recorder, now: { time.now })
    }

    func testKeysUseSendTextUntilTheStreamOpensThenFramesWithoutWaiting() async {
        let sink = TextSink()
        let bridge = ScriptedBridge(responder: answerOpen)
        let sender = makeSender(sink: sink, bridge: bridge)

        sender.enqueue("a")
        await waitUntil("the stream opens") { sender.isStreaming }
        XCTAssertEqual(sink.sent, ["a"], "the first key never waits for the open")

        // Two batches while nothing is acked: both are written (no stop-and-wait).
        sender.enqueue("b")
        sender.enqueue("c")
        await waitUntil("both frames written") { frames(bridge).count == 2 }
        XCTAssertEqual(frames(bridge).map(\.seq), [1, 2])
        XCTAssertEqual(frames(bridge).map(\.text), ["b", "c"])
        XCTAssertEqual(sink.sent, ["a"], "no send_text once streaming")
        sender.stop()
    }

    func testStreamOpeningMidSendWaitsForThatSendBeforeWritingFrames() async {
        let sink = TextSink(holding: true)
        let bridge = ScriptedBridge(responder: answerOpen)
        let sender = makeSender(sink: sink, bridge: bridge)

        sender.enqueue("a")                         // send_text("a") in flight, held
        await waitUntil("the stream opens") { sender.isStreaming }
        sender.enqueue("b")
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(frames(bridge).isEmpty, "a frame must not overtake the send_text in flight")

        sink.release()
        await waitUntil("b goes out as the first frame") { frames(bridge).count == 1 }
        XCTAssertEqual(frames(bridge), [SentFrame(seq: 1, text: "b", ack: true)])
        XCTAssertEqual(sink.sent, ["a"])
        sender.stop()
    }

    func testOpenFailureKeepsSendTextAndRetriesOnlyAfterThirtySeconds() async {
        let sink = TextSink()
        let opens = Counter()
        let time = FakeTime()
        let sender = PaneInputSender(
            sendText: { text in await sink.send(text) },
            openStream: { opens.increment(); return nil },
            recorder: TypingLatencyRecorder(), now: { time.now })

        sender.enqueue("a")
        await waitUntil("a sent") { sink.sent == ["a"] }
        await waitUntil("open tried") { opens.value == 1 }
        try? await Task.sleep(nanoseconds: 10_000_000)
        sender.enqueue("b")
        await waitUntil("b sent") { sink.sent == ["a", "b"] }
        XCTAssertEqual(opens.value, 1, "no reopen within 30 s")

        time.advance(ms: 30_001)
        sender.enqueue("c")
        await waitUntil("c sent") { sink.sent == ["a", "b", "c"] }
        await waitUntil("reopened after 30 s") { opens.value == 2 }
        XCTAssertFalse(sender.isStreaming)
    }

    func testRefusedOpenOverTheRealClientFallsBackToSendText() async {
        let host = InputStreamHost(openReply: InputStreamHost.refuseOpen)
        let client = host.client()
        let sender = PaneInputSender(
            sendText: { text in try await client.sendText(pane: "w1:p1", text: text) },
            openStream: { await client.openPaneInput(pane: "w1:p1") },
            recorder: TypingLatencyRecorder())

        sender.enqueue("a")
        await waitUntil("a sent") { host.sentTexts == ["a"] }
        await waitUntil("open refused") { host.opened.count == 1 }
        try? await Task.sleep(nanoseconds: 20_000_000)
        sender.enqueue("b")
        await waitUntil("b sent") { host.sentTexts == ["a", "b"] }
        XCTAssertFalse(sender.isStreaming)
        XCTAssertEqual(host.opened.count, 1, "a refused open is not retried at once")
    }

    func testFederatedPaneTypesThroughSendTextOnly() async {
        let host = InputStreamHost()
        let client = host.client()
        let pane = "build/w1:p2"
        let sender = PaneInputSender(
            sendText: { text in try await client.sendText(pane: pane, text: text) },
            openStream: { await client.openPaneInput(pane: pane) },
            recorder: TypingLatencyRecorder())

        sender.enqueue("l")
        await waitUntil("l sent") { host.sentTexts == ["l"] }
        sender.enqueue("s")
        await waitUntil("s sent") { host.sentTexts == ["l", "s"] }
        XCTAssertTrue(host.opened.isEmpty, "a federated pane never opens pane.input.stream")
        XCTAssertFalse(sender.isStreaming)
    }

    func testFrameErrorLosesUnackedKeysClosesAndFallsBackWithoutResending() async {
        let (recorder, time) = makeRecorder()
        let sink = TextSink()
        let bridge = ScriptedBridge(responder: answerOpen)
        let opens = Counter()
        let sender = makeSender(sink: sink, bridge: bridge, opens: opens, recorder: recorder, time: time)

        sender.enqueue("a")                          // not a measured key
        await waitUntil("the stream opens") { sender.isStreaming }

        recorder.keyPressed()
        sender.enqueue("b")                          // frame 1
        recorder.keyPressed()
        sender.enqueue("c")                          // frame 2
        await waitUntil("two frames") { frames(bridge).count == 2 }
        bridge.emit(#"{"seq":1,"ok":true}"#)
        bridge.emit(#"{"seq":2,"error":{"code":"pty_write_failed","message":"gone"}}"#)

        await waitUntil("back on send_text") { !sender.isStreaming }
        XCTAssertEqual(recorder.report().first?.lost, 1, "only the unacked key is lost")
        await waitUntil("the channel is closed") { bridge.stdinClosed }

        sender.enqueue("d")
        await waitUntil("d sent") { sink.sent == ["a", "d"] }
        XCTAssertEqual(frames(bridge).map(\.text), ["b", "c"], "the lost frame is never resent")
        XCTAssertEqual(opens.value, 1, "no reopen within 30 s of a failure")

        time.advance(ms: 30_001)
        sender.enqueue("e")
        await waitUntil("reopened after 30 s") { opens.value == 2 }
        sender.stop()
    }

    func testKeysTypedWhileTheStreamEndsWaitAndThenUseSendText() async {
        let sink = TextSink()
        let bridge = ScriptedBridge(responder: answerOpen)
        let sender = makeSender(sink: sink, bridge: bridge)
        sender.enqueue("a")
        await waitUntil("the stream opens") { sender.isStreaming }
        sender.enqueue("b")
        await waitUntil("frame b") { frames(bridge).count == 1 }

        sender.closeStream()                         // the pane left the foreground
        sender.enqueue("c")
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(sink.sent, ["a"], "c must wait until frame b is resolved")

        bridge.emit(#"{"seq":1,"ok":true}"#)     // the daemon finishes frame b; the stream ends
        await waitUntil("c sent after the stream ended") { sink.sent == ["a", "c"] }
        XCTAssertEqual(frames(bridge).map(\.text), ["b"])
    }

    func testAcksStampOnlyTheFramesTheyCover() async throws {
        let (recorder, time) = makeRecorder()
        let sink = TextSink()
        let bridge = ScriptedBridge(responder: answerOpen)
        let sender = makeSender(sink: sink, bridge: bridge, recorder: recorder, time: time)
        sender.enqueue("a")
        await waitUntil("the stream opens") { sender.isStreaming }

        recorder.keyPressed()                        // t = 0
        sender.enqueue("b")                          // frame 1
        time.advance(ms: 10)
        recorder.keyPressed()                        // t = 10
        sender.enqueue("c")                          // frame 2
        await waitUntil("two frames") { frames(bridge).count == 2 }
        time.advance(ms: 10)
        recorder.outputArrived()                     // t = 20
        recorder.painted()

        time.advance(ms: 10)                         // t = 30: frame 1 acked, frame 2 still out
        bridge.emit(#"{"seq":1,"ok":true}"#)
        await waitUntil("b measured") { recorder.report().first?.count == 1 }
        time.advance(ms: 20)                         // t = 50
        bridge.emit(#"{"seq":2,"ok":true}"#)
        await waitUntil("c measured") { recorder.report().first?.count == 2 }

        let report = try XCTUnwrap(recorder.report().first)
        XCTAssertEqual(try XCTUnwrap(report.keyToAck).median, 30, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(report.keyToAck).max, 40, accuracy: 0.001,
                       "c's ack is frame 2's, not frame 1's")
        XCTAssertEqual(report.streamKeys, 2)
        sender.stop()
    }

    func testOnAckedReportsEnqueueNumbersInOrderOnBothRoutes() async {
        let sink = TextSink()
        let bridge = ScriptedBridge(responder: answerOpen)
        let sender = makeSender(sink: sink, bridge: bridge)
        var answered: [UInt64] = []
        var failures = 0
        sender.onAcked = { through, failed in
            answered.append(through)
            if failed { failures += 1 }
        }

        XCTAssertEqual(sender.enqueue("a"), 1)
        await waitUntil("send_text answered") { answered == [1] }
        await waitUntil("the stream opens") { sender.isStreaming }
        XCTAssertEqual(sender.enqueue("b"), 2)
        XCTAssertEqual(sender.enqueue("c"), 3)
        await waitUntil("two frames") { frames(bridge).count == 2 }
        XCTAssertEqual(answered, [1], "frames are not answered before their ack")
        bridge.emit(#"{"seq":2,"ok":true}"#)
        await waitUntil("the cumulative ack answers both frames") { answered == [1, 3] }
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(sender.enqueue(""), 0, "nothing to send has no number")
        sender.stop()
    }
}

// MARK: - Recorder: per-batch acks and the input-stream share

final class TypingLatencyInputStreamTests: XCTestCase {
    func testAckThroughABatchStampsOnlyKeysUpToIt() throws {
        let time = FakeTime()
        let recorder = TypingLatencyRecorder(clock: { time.now })
        recorder.begin(host: "mac-mini", network: "Wi-Fi")

        recorder.keyPressed()                                            // t = 0
        let first = recorder.batchSent(byteCount: 1, route: .inputStream)
        time.advance(ms: 10)
        recorder.keyPressed()                                            // t = 10
        let second = recorder.batchSent(byteCount: 1, route: .inputStream)
        XCTAssertGreaterThan(second, first)
        time.advance(ms: 5)
        recorder.outputArrived()                                         // t = 15, echo before any ack
        recorder.painted()

        time.advance(ms: 15)                                             // t = 30
        recorder.batchAcked(through: first)
        XCTAssertEqual(recorder.report().first?.count, 1, "the second key's frame is still in flight")
        time.advance(ms: 30)                                             // t = 60
        recorder.batchAcked(through: first)                              // a stale ack changes nothing
        XCTAssertEqual(recorder.report().first?.count, 1)
        recorder.batchAcked(through: second)

        let report = try XCTUnwrap(recorder.report().first)
        XCTAssertEqual(report.count, 2)
        XCTAssertEqual(try XCTUnwrap(report.keyToAck).median, 30, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(report.keyToAck).max, 50, accuracy: 0.001)
    }

    func testFailedThroughABatchLosesOnlyKeysUpToIt() throws {
        let recorder = TypingLatencyRecorder(clock: { 0 })
        recorder.begin(host: "mac-mini", network: "Wi-Fi")
        recorder.keyPressed()
        let first = recorder.batchSent(byteCount: 1, route: .inputStream)
        recorder.keyPressed()
        _ = recorder.batchSent(byteCount: 1, route: .inputStream)
        recorder.batchAcked(failed: true, through: first)
        XCTAssertEqual(recorder.report().first?.lost, 1)
    }

    func testReportShowsTheInputStreamShareOfKeys() throws {
        let recorder = TypingLatencyRecorder(clock: { 0 })
        recorder.begin(host: "mac-mini", network: "Wi-Fi")
        recorder.keyPressed()
        recorder.batchSent(byteCount: 1, route: .sendText)
        recorder.batchAcked(failed: true)
        for _ in 0..<3 {
            recorder.keyPressed()
            recorder.batchSent(byteCount: 1, route: .inputStream)
        }
        recorder.batchAcked(failed: true)

        let report = try XCTUnwrap(recorder.report().first)
        XCTAssertEqual(report.streamKeys, 3)
        XCTAssertEqual(report.sendTextKeys, 1)
        XCTAssertEqual(try XCTUnwrap(report.inputStreamShare), 0.75, accuracy: 0.001)
        XCTAssertTrue(report.plainLines().contains("Input stream: 75% of 4 keys"), "\(report.plainLines())")
        XCTAssertTrue(report.plainLines().contains { $0.hasPrefix("Held channel:") }, "the request line stays")
    }
}
