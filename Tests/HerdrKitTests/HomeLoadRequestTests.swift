import XCTest
import Foundation
@testable import HerdrKit

/// A daemon that answers after `delay`, counting requests per method, so a test sees
/// which requests overlap and how many of each a screen load sends.
private final class SlowCountingTransport: HerdrTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var requestLines: [String] = []
    private var agentStatus = "idle"
    let delay: UInt64

    init(delay: UInt64 = 80 * ms) { self.delay = delay }

    func count(_ method: String) -> Int { lock.withLock { counts[method] ?? 0 } }
    var lines: [String] { lock.withLock { requestLines } }
    /// The daemon's state from now on. A request already received answers with the
    /// state it saw when it arrived.
    func setAgentStatus(_ status: String) { lock.withLock { agentStatus = status } }

    func roundTrip(_ requestLine: String) async throws -> String {
        let object = (try? JSONSerialization.jsonObject(with: Data(requestLine.utf8))) as? [String: Any]
        let method = object?["method"] as? String ?? ""
        let status = lock.withLock {
            counts[method, default: 0] += 1
            requestLines.append(requestLine)
            return agentStatus
        }
        try await Task.sleep(nanoseconds: delay)
        switch method {
        case "agent.list":
            return #"{"id":"x","result":{"type":"agent_list","agents":[{"pane_id":"w1:p1","name":"a","agent":"omp","agent_status":"\#(status)"}]}}"#
        case "ping":
            return #"{"id":"x","result":{"type":"pong","version":"0.9.5","protocol":22,"capabilities":{"agent_transcript":true}}}"#
        default:
            return #"{"id":"x","result":{}}"#
        }
    }

    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// What the home screen and an agent's page cost in requests (slow-network fix 2).
final class HomeLoadRequestTests: XCTestCase {
    /// Review of #675: the agent goes working → blocked by a live event, and the reader
    /// opens it within 5 s of the last `agent.list`. The page starts on the event's
    /// blocked row; its status resolve must not swap it for the cached working one,
    /// which would route menu keys to `agent.prompt`, refused while blocked.
    func testPageResolveAfterALiveChangeDoesNotReuseTheOlderList() async throws {
        let transport = SlowCountingTransport(delay: 10 * ms)
        let client = HerdrClient(transport: transport)
        transport.setAgentStatus("working")
        _ = try await client.agentList()                                  // home load

        transport.setAgentStatus("blocked")
        client.noteAgentListChanged()                                     // home receives the event

        let page = try await client.agentListing(sentAfter: .now - .seconds(5))  // page mount
        XCTAssertEqual(page.agents.first?.agentStatus, "blocked")
        XCTAssertEqual(transport.count("agent.list"), 2)
    }

    /// The same, with the older list still in flight when the event arrives: the page
    /// must not join it.
    func testPageResolveAfterALiveChangeDoesNotJoinAnOlderRequestInFlight() async throws {
        let transport = SlowCountingTransport()
        let client = HerdrClient(transport: transport)
        transport.setAgentStatus("working")
        async let home = client.agentList()
        try await eventually("home list sent") { transport.count("agent.list") == 1 }

        transport.setAgentStatus("blocked")
        client.noteAgentListChanged()

        let page = try await client.agentListing(sentAfter: .now - .seconds(5))
        XCTAssertEqual(page.agents.first?.agentStatus, "blocked")
        let homeList = try await home
        XCTAssertEqual(homeList.first?.agentStatus, "working")
        XCTAssertEqual(transport.count("agent.list"), 2)
    }

    /// With no live change since, the page still shares the home's list.
    func testPageResolveWithoutALiveChangeReusesTheHomeList() async throws {
        let transport = SlowCountingTransport(delay: 10 * ms)
        let client = HerdrClient(transport: transport)
        client.noteAgentListChanged(at: .now - .seconds(1))               // an earlier event
        _ = try await client.agentList()
        _ = try await client.agentListing(sentAfter: .now - .seconds(5))
        XCTAssertEqual(transport.count("agent.list"), 1)
    }

    /// Review of #675: the home load pings with `serverCapabilities`; a page opened
    /// while that ping is on its way must wait for it, not send its own.
    func testPageCapabilityCheckJoinsTheHomePingInFlight() async throws {
        let transport = SlowCountingTransport()
        let client = HerdrClient(transport: transport)
        async let home = client.serverCapabilities()
        try await eventually("home ping sent") { transport.count("ping") == 1 }
        let page = try await client.knownCapabilities()
        XCTAssertEqual(page?.agentTranscript, true)
        let homeCapabilities = try await home
        XCTAssertEqual(homeCapabilities?.agentTranscript, true)
        XCTAssertEqual(transport.count("ping"), 1)
        // An explicit refresh after it answered still asks the daemon.
        _ = try await client.serverCapabilities()
        XCTAssertEqual(transport.count("ping"), 2)
    }

    /// A cold start used to send `agent.list` three or four times at once: the connect
    /// pre-warm, the home's first load, the page's status resolve and the pre-fill's
    /// `isPromptable`. On a slow link each ~55 KB copy queued behind the others.
    func testColdStartSendsOneAgentListForThePrewarmTheHomeAndThePage() async throws {
        let transport = SlowCountingTransport()
        let client = HerdrClient(transport: transport)

        async let prewarm = client.agentList()                                   // HerdrApp.connect
        try await Task.sleep(nanoseconds: 20 * ms)
        let homeStart = ContinuousClock.now
        async let firstLoad = client.agentListing(sentAfter: homeStart - .seconds(10))  // TerminalHomeView.load, first
        let (warm, home) = try await (prewarm, firstLoad)
        XCTAssertEqual(warm.count, 1)
        XCTAssertEqual(home.agents.map(\.paneID), ["w1:p1"])

        // The page the reader opens from that list.
        let page = try await client.agentListing(sentAfter: .now - .seconds(5))  // AgentPaneView mount
        XCTAssertEqual(page.agents.count, 1)
        let promptable = try await client.isPromptable(pane: "w1:p1", listSentAfter: .now - .seconds(1))
        XCTAssertFalse(promptable)

        XCTAssertEqual(transport.count("agent.list"), 1)
    }

    /// A caller that just changed something, or learned of a change (the status
    /// stream's start, a lifecycle event, a poll), never gets a list sent before it asked.
    func testFreshCallerDoesNotJoinAnOlderRequest() async throws {
        let transport = SlowCountingTransport()
        let client = HerdrClient(transport: transport)
        async let older = client.agentList()
        try await Task.sleep(nanoseconds: 20 * ms)
        async let fresh = client.agentListing()
        _ = try await (older, fresh)
        XCTAssertEqual(transport.count("agent.list"), 2)
        // And a finished list is not reused by a caller that asks after it.
        _ = try await client.agentListing()
        XCTAssertEqual(transport.count("agent.list"), 3)
    }

    /// Concurrent callers that accept the same window share one request.
    func testConcurrentCallersShareOneRequest() async throws {
        let transport = SlowCountingTransport()
        let client = HerdrClient(transport: transport)
        let since = ContinuousClock.now - .seconds(5)
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<5 { group.addTask { try await client.agentListing(sentAfter: since).agents.count } }
            for try await count in group { XCTAssertEqual(count, 1) }
        }
        XCTAssertEqual(transport.count("agent.list"), 1)
    }

    /// Opening an agent's page used to ping before Chat could show; the home screen's
    /// ping already answered it.
    func testPageReusesTheHomePingForItsChatGate() async throws {
        let transport = SlowCountingTransport(delay: 10 * ms)
        let client = HerdrClient(transport: transport)
        _ = try await client.serverCapabilities()                         // home load
        let capabilities = try await client.knownCapabilities()          // page mount
        XCTAssertEqual(capabilities?.agentTranscript, true)
        XCTAssertEqual(transport.count("ping"), 1)
    }

    func testConcurrentCapabilityChecksShareOnePing() async throws {
        let transport = SlowCountingTransport()
        let client = HerdrClient(transport: transport)
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<4 { group.addTask { try await client.knownCapabilities()?.agentTranscript == true } }
            for try await supported in group { XCTAssertTrue(supported) }
        }
        XCTAssertEqual(transport.count("ping"), 1)
    }

    /// The fork probe needs only "this is a gram list", not the whole store.
    func testForkProbeAsksForOneMessage() async throws {
        let transport = RecordingTransport(reply: #"{"id":"x","result":{"messages":[]}}"#)
        let probe = await HerdrClient(transport: transport).probeFork()
        XCTAssertEqual(probe, .isFork)
        let request = try transport.last()
        XCTAssertEqual(request.method, "gram.list")
        XCTAssertEqual(request.params["limit"] as? Int, 1)
    }
}
