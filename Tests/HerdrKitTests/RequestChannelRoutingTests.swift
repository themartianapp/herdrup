import XCTest
import Foundation
import Citadel
import NIOCore
@testable import HerdrKit

/// A scripted herdr host behind `CitadelTransport`'s real routing (herdrup#390,
/// #391): the per-request `api-bridge <base64>` exec answers `{"via":"exec"}` (and
/// `ping` with the configured capability), and each `api-bridge --multi` link is a
/// fresh `ScriptedBridge`.
final class ScriptedHost: @unchecked Sendable {
    private let lock = NSLock()
    private var multi: Bool
    private var failOpens = 0
    private var execs: [(session: String?, request: String)] = []
    private var links: [(command: String, bridge: ScriptedBridge)] = []
    private var bridgeResponder: ScriptedBridge.Responder = ScriptedBridge.answerAll

    init(multi: Bool) { self.multi = multi }

    var perRequest: [String] { lock.withLock { execs.map(\.request) } }
    var perRequestNonPing: [String] { perRequest.filter { !$0.contains(#""method":"ping""#) } }
    var perRequestPings: Int { perRequest.count - perRequestNonPing.count }
    var opened: [(command: String, bridge: ScriptedBridge)] { lock.withLock { links } }
    var lastBridge: ScriptedBridge? { opened.last?.bridge }

    func failNextOpens(_ count: Int) { lock.withLock { failOpens = count } }
    func setBridgeResponder(_ responder: @escaping ScriptedBridge.Responder) {
        lock.withLock { bridgeResponder = responder }
    }

    /// The JSON request a per-request command carries (base64 words after `sh`).
    static func request(in command: String) -> String {
        let marker = #""$*"' sh "#
        guard let range = command.range(of: marker) else { return "" }
        let base64 = command[range.upperBound...].filter { $0 != "'" && $0 != " " }
        return String(decoding: Data(base64Encoded: String(base64)) ?? Data(), as: UTF8.self)
    }

    static func session(in command: String) -> String? {
        guard let range = command.range(of: "--session ") else { return nil }
        return String(command[range.upperBound...].prefix { $0 != " " && $0 != "'" })
    }

    var backend: ExecBackend {
        ExecBackend(
            execute: { command in
                let request = Self.request(in: command)
                let reply: String = self.lock.withLock {
                    self.execs.append((Self.session(in: command), request))
                    if request.contains(#""method":"ping""#) {
                        let caps = self.multi ? #"{"api_bridge_multi":true}"# : #"{"events_v2":true}"#
                        return ScriptedBridge.reply(
                            to: request, result: #"{"type":"pong","version":"0.9.4","protocol":1,"capabilities":\#(caps)}"#)
                    }
                    return ScriptedBridge.reply(to: request, result: #"{"via":"exec"}"#)
                }
                return AsyncThrowingStream { continuation in
                    continuation.yield(.stdout(ByteBuffer(string: reply + "\n")))
                    continuation.finish()
                }
            },
            openLink: { command in
                XCTAssertTrue(command.contains("api-bridge --multi"), command)
                return try self.lock.withLock {
                    if self.failOpens > 0 {
                        self.failOpens -= 1
                        throw ScriptedDrop()
                    }
                    let bridge = ScriptedBridge(responder: self.bridgeResponder)
                    self.links.append((command, bridge))
                    return bridge
                }
            })
    }
}

final class RequestChannelRoutingTests: XCTestCase {
    private func makeTransport(
        _ host: ScriptedHost, settings: RequestChannelSettings = testSettings(), session: String? = nil,
        hostName: String = "box"
    ) -> CitadelTransport {
        var credentials = SSHCredentials(host: hostName, username: "u", password: "p", remoteSocketPath: "")
        credentials.session = session
        let connection = SSHConnectionCore(
            credentials: credentials, hostKeyValidator: .acceptAnything(), connectTimeoutNanoseconds: 1_000 * ms)
        return CitadelTransport(
            credentials: credentials, connection: connection, backend: host.backend,
            requestChannelSettings: settings)
    }

    private static let viaExec = #"{"via":"exec"}"#
    private static let viaChannel = #"{"via":"channel"}"#

    private func via(_ reply: String) -> String {
        reply.contains(Self.viaChannel) ? "channel" : reply.contains(Self.viaExec) ? "exec" : reply
    }

    /// First use reads the capability; the probe opens the channel in the background.
    private func warmUp(_ transport: CitadelTransport) async throws {
        _ = try await transport.roundTrip(requestLine("warm-up"))
        await transport.requestChannelPool.settle()
    }

    // MARK: #390 routing

    func testOldHerdrWithoutTheCapabilityKeepsThePerRequestPath() async throws {
        let host = ScriptedHost(multi: false)
        let transport = makeTransport(host)
        for index in 0..<5 {
            let reply = try await transport.roundTrip(requestLine("r\(index)"))
            XCTAssertEqual(via(reply), "exec")
            await transport.requestChannelPool.settle()
        }
        XCTAssertEqual(host.opened.count, 0, "no capability, so no --multi channel")
        XCTAssertEqual(host.perRequestNonPing.count, 5)
        XCTAssertEqual(host.perRequestPings, 1, "the capability is read once and cached")
    }

    func testNewHerdrRoutesRequestsThroughTheChannel() async throws {
        let host = ScriptedHost(multi: true)
        let transport = makeTransport(host)
        // Capability unknown on first use: that request takes the per-request path
        // while the probe runs, so first use costs no extra round trip.
        let first = try await transport.roundTrip(requestLine("first"))
        XCTAssertEqual(via(first), "exec")
        await transport.requestChannelPool.settle()
        XCTAssertEqual(host.opened.count, 1)

        for index in 0..<5 {
            let reply = try await transport.roundTrip(requestLine("r\(index)"))
            XCTAssertEqual(via(reply), "channel")
            XCTAssertEqual(reply, ScriptedBridge.reply(to: requestLine("r\(index)"), result: Self.viaChannel))
        }
        XCTAssertEqual(host.perRequestNonPing, [requestLine("first")])
        XCTAssertEqual(host.lastBridge?.nonPingRequests.count, 5)
        XCTAssertEqual(host.opened.count, 1, "one channel serves every request")
    }

    func testHerdrClientRequestsRideTheChannelUnchanged() async throws {
        let host = ScriptedHost(multi: true)
        let transport = makeTransport(host)
        try await warmUp(transport)
        host.lastBridge?.setResponder { line in
            ScriptedBridge.reply(to: line, result: line.contains("ping")
                ? #"{"type":"pong"}"#
                : #"{"type":"agent_list","agents":[]}"#)
        }
        let client = HerdrClient(transport: transport)
        let agents = try await client.agentList()
        XCTAssertEqual(agents.count, 0)
        XCTAssertTrue(host.lastBridge?.nonPingRequests.last?.contains(#""method":"agent.list""#) ?? false)
    }

    func testDroppedChannelReopensOnTheNextRequest() async throws {
        let host = ScriptedHost(multi: true)
        let transport = makeTransport(host)
        try await warmUp(transport)
        let firstBridge = try XCTUnwrap(host.lastBridge)
        firstBridge.drop()
        try await eventually("channel noticed the drop") {
            await !transport.requestChannelPool.hasOpenChannel(session: nil)
        }

        let reply = try await transport.roundTrip(requestLine("after-drop"))
        XCTAssertEqual(via(reply), "channel")
        XCTAssertEqual(host.opened.count, 2)
        XCTAssertEqual(host.lastBridge?.nonPingRequests, [requestLine("after-drop")])
    }

    func testChannelThatCannotOpenFallsBackAndIsRetriedLater() async throws {
        let clock = ManualClock()
        let host = ScriptedHost(multi: true)
        let transport = makeTransport(host, settings: testSettings(clock: clock))
        host.failNextOpens(1)
        try await warmUp(transport)  // capability read; the open it triggers fails
        XCTAssertEqual(host.opened.count, 0)

        // Never failed for want of a channel: the request takes the per-request path,
        // and within the retry window no open is attempted.
        let reply = try await transport.roundTrip(requestLine("fallback"))
        XCTAssertEqual(via(reply), "exec")
        XCTAssertEqual(host.opened.count, 0)

        clock.advance(30_000 * ms)
        let later = try await transport.roundTrip(requestLine("retried"))
        XCTAssertEqual(via(later), "channel")
        XCTAssertEqual(host.opened.count, 1)
    }

    /// Settings > Typing latency must say why a host is slow when its held channel cannot
    /// open (herdrup: hetzner-ts ran an old `herdr` first on PATH: 0% held).
    func testFailedOpenOnAnAdvertisingHostIsReportedForThatHost() async throws {
        let clock = ManualClock()
        let host = ScriptedHost(multi: true)
        let name = "open-failure-\(UUID().uuidString)"
        let transport = makeTransport(host, settings: testSettings(clock: clock), hostName: name)
        host.failNextOpens(1)
        try await warmUp(transport)
        _ = try await transport.roundTrip(requestLine("slow"))

        let report = try XCTUnwrap(TypingLatencyRecorder.shared.routeReport(host: name))
        XCTAssertEqual(report.openFailures, 1)
        XCTAssertEqual(report.held, 0)
        XCTAssertGreaterThan(report.perRequest, 0)
    }

    func testEachSessionGetsItsOwnChannelAndCloseClosesThemAll() async throws {
        let host = ScriptedHost(multi: true)
        let main = makeTransport(host)
        let work = main.forSession("work")
        try await warmUp(main)
        try await warmUp(work)
        XCTAssertEqual(host.opened.count, 2)
        XCTAssertEqual(Set(host.opened.map { ScriptedHost.session(in: $0.command) ?? "default" }), ["default", "work"])

        _ = try await main.roundTrip(requestLine("m"))
        _ = try await work.roundTrip(requestLine("w"))
        // `roundTrip(_:inSession:)` uses that session's channel, not the caller's.
        _ = try await main.roundTrip(requestLine("pill"), inSession: "work")
        let byCommand = Dictionary(uniqueKeysWithValues: host.opened.map {
            (ScriptedHost.session(in: $0.command) ?? "default", $0.bridge.nonPingRequests)
        })
        XCTAssertEqual(byCommand["default"], [requestLine("m")])
        XCTAssertEqual(byCommand["work"], [requestLine("w"), requestLine("pill")])

        await work.close()
        for link in host.opened {
            try await eventually("every channel closed") { link.bridge.stdinClosed }
        }
        let poolOpen = await main.requestChannelPool.hasOpenChannel(session: nil)
        XCTAssertFalse(poolOpen)
    }

    func testConcurrentFirstRequestsOpenOneChannelPerSession() async throws {
        let host = ScriptedHost(multi: true)
        let transport = makeTransport(host)
        try await warmUp(transport)
        XCTAssertEqual(host.opened.count, 1)
        host.lastBridge?.drop()
        try await eventually("dropped") { await !transport.requestChannelPool.hasOpenChannel(session: nil) }

        try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<8 {
                group.addTask { try await transport.roundTrip(requestLine("c\(index)")) }
            }
            for try await reply in group { XCTAssertEqual(self.via(reply), "channel") }
        }
        XCTAssertEqual(host.opened.count, 2, "eight concurrent requests share one reopened channel")
    }

    /// The bench's three-screens case: a transcript page still being written must not
    /// hold up `agent.list`. Reply-heavy methods get the session's second channel,
    /// opened on the first of them.
    func testBigRepliesRideTheirOwnChannelSoSmallOnesDoNotQueueBehindThem() async throws {
        let host = ScriptedHost(multi: true)
        let transport = makeTransport(host)
        try await warmUp(transport)
        XCTAssertEqual(host.opened.count, 1)
        let interactive = try XCTUnwrap(host.lastBridge)

        let first = try await transport.roundTrip(requestLine("t1", method: "agent.transcript"))
        XCTAssertEqual(via(first), "channel")
        XCTAssertEqual(host.opened.count, 2, "the first big request opened the bulk channel")
        let bulk = try XCTUnwrap(host.lastBridge)
        XCTAssertEqual(bulk.nonPingRequests, [requestLine("t1", method: "agent.transcript")])
        await assertEqual(await transport.requestChannelPool.hasOpenChannel(session: nil, lane: .bulk), true)

        bulk.setResponder(ScriptedBridge.answerPings)  // the page is still being written
        let page = Task { try await transport.roundTrip(requestLine("t2", method: "agent.transcript")) }
        try await eventually("page requested on the bulk channel") { bulk.nonPingRequests.count == 1 }

        let list = try await transport.roundTrip(requestLine("l1"))
        XCTAssertEqual(via(list), "channel", "agent.list answered while the page is outstanding")
        XCTAssertEqual(interactive.nonPingRequests, [requestLine("l1")], "no big request rides the interactive channel")
        XCTAssertEqual(bulk.nonPingRequests, [requestLine("t1", method: "agent.transcript"),
                                              requestLine("t2", method: "agent.transcript")])

        bulk.answer(requestLine("t2", method: "agent.transcript"), result: Self.viaChannel)
        let pageReply = try await page.value
        XCTAssertEqual(via(pageReply), "channel")
    }

    /// A host without `api_bridge_multi` keeps every request, big or small, on the
    /// per-request path, exactly as before.
    func testBigRepliesOnAnOldHostKeepThePerRequestPath() async throws {
        let host = ScriptedHost(multi: false)
        let transport = makeTransport(host)
        try await warmUp(transport)
        let reply = try await transport.roundTrip(requestLine("t1", method: "agent.transcript"))
        XCTAssertEqual(via(reply), "exec")
        await transport.requestChannelPool.settle()
        XCTAssertEqual(host.opened.count, 0)
    }

    /// Gram download progress keeps the per-request path (see `roundTrip(_:onBytesReceived:)`).
    func testProgressReportingRequestKeepsThePerRequestPath() async throws {
        let host = ScriptedHost(multi: true)
        let transport = makeTransport(host)
        try await warmUp(transport)
        let counter = ProgressCounter()
        let reply = try await transport.roundTrip(requestLine("download"), onBytesReceived: { counter.record($0) })
        XCTAssertEqual(via(reply), "exec")
        XCTAssertGreaterThan(counter.last, 0)
        let plain = try await transport.roundTrip(requestLine("plain"), onBytesReceived: nil)
        XCTAssertEqual(via(plain), "channel")
    }

    // MARK: #391 reliability

    func testRequestOverTheBridgeLimitTakesThePerRequestPathAndFailsTheSameWay() async throws {
        let host = ScriptedHost(multi: true)
        let transport = makeTransport(host)
        try await warmUp(transport)
        let huge = #"{"id":"huge","method":"pane.send_text","params":{"text":"\#(String(repeating: "x", count: RequestChannel.maxRequestLineBytes))"}}"#
        do {
            _ = try await transport.roundTrip(huge)
            XCTFail("expected requestTooLarge")
        } catch TransportError.requestTooLarge(_, let max) {
            XCTAssertEqual(max, CitadelTransport.maxCommandBytes)
        }
        XCTAssertEqual(host.lastBridge?.nonPingRequests.count, 0, "never written to the channel")
    }

    func testRequestIsBoundedByTheRequestTimeout() async throws {
        var settings = testSettings()
        settings.requestTimeout = 60 * ms
        let host = ScriptedHost(multi: true)
        host.setBridgeResponder(ScriptedBridge.answerPings)  // holds every real request
        let transport = makeTransport(host, settings: settings)
        try await warmUp(transport)
        do {
            _ = try await transport.roundTrip(requestLine("stuck"))
            XCTFail("expected a timeout")
        } catch TransportError.requestTimedOut(let name) {
            XCTAssertEqual(name, "box")
        }
        // No automatic retry: the request was written once and not resent anywhere.
        XCTAssertEqual(host.lastBridge?.nonPingRequests, [requestLine("stuck")])
        XCTAssertEqual(host.perRequestNonPing, [requestLine("warm-up")])
    }

    func testIdleChannelIsPingedBeforeTheNextRequest() async throws {
        let clock = ManualClock()
        var settings = testSettings(clock: clock)
        settings.idleProbeAfter = 30_000 * ms
        let host = ScriptedHost(multi: true)
        let transport = makeTransport(host, settings: settings)
        try await warmUp(transport)
        let bridge = try XCTUnwrap(host.lastBridge)
        _ = try await transport.roundTrip(requestLine("busy"))
        XCTAssertEqual(bridge.pingCount, 1, "only the opening ping while active")

        clock.advance(30_000 * ms)
        _ = try await transport.roundTrip(requestLine("after-idle"))
        XCTAssertEqual(bridge.pingCount, 2)
        XCTAssertTrue(bridge.requests.suffix(2).first?.contains(#""method":"ping""#) ?? false, "the ping precedes the request")
    }

    func testDeadIdleChannelIsReplacedBeforeTheRequestIsSent() async throws {
        let clock = ManualClock()
        var settings = testSettings(clock: clock)
        settings.idleProbeAfter = 30_000 * ms
        settings.probeTimeout = 50 * ms
        let host = ScriptedHost(multi: true)
        let transport = makeTransport(host, settings: settings)
        try await warmUp(transport)
        let silent = try XCTUnwrap(host.lastBridge)
        silent.setResponder { _ in nil }  // half-open link: nothing comes back
        clock.advance(30_000 * ms)

        let reply = try await transport.roundTrip(requestLine("after-idle"))
        XCTAssertEqual(via(reply), "channel")
        XCTAssertEqual(host.opened.count, 2)
        XCTAssertEqual(silent.nonPingRequests, [], "the request never went to the dead channel")
        XCTAssertEqual(host.lastBridge?.nonPingRequests, [requestLine("after-idle")])
    }

    func testForegroundHookPingsBeforeTheNextRequest() async throws {
        let host = ScriptedHost(multi: true)
        let transport = makeTransport(host)
        let work = transport.forSession("work")
        try await warmUp(transport)
        try await warmUp(work)
        await transport.markRequestChannelsSuspect()
        for link in host.opened { XCTAssertEqual(link.bridge.pingCount, 1) }

        _ = try await transport.roundTrip(requestLine("back"))
        _ = try await work.roundTrip(requestLine("back-work"))
        for link in host.opened { XCTAssertEqual(link.bridge.pingCount, 2, "every session's channel is checked") }
        _ = try await transport.roundTrip(requestLine("again"))
        XCTAssertEqual(host.opened[0].bridge.pingCount, 2, "one check, not one per request")
    }

    func testUnusedChannelClosesAndReopensOnDemand() async throws {
        var settings = testSettings()
        settings.unusedCloseAfter = 60 * ms
        let host = ScriptedHost(multi: true)
        let transport = makeTransport(host, settings: settings)
        try await warmUp(transport)
        let first = try XCTUnwrap(host.lastBridge)
        try await eventually("closed when unused") { first.stdinClosed }

        let reply = try await transport.roundTrip(requestLine("later"))
        XCTAssertEqual(via(reply), "channel")
        XCTAssertEqual(host.opened.count, 2)
    }
}

final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var last: Int { lock.withLock { value } }
    func record(_ bytes: Int) { lock.withLock { value = bytes } }
}
