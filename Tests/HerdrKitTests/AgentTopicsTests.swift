import Foundation
import XCTest
@testable import HerdrKit

/// An omp agent's topics (jerryfane/herdr#475): the `agent_topics` capability, the
/// `agent.topics.*` wire shapes as herdr's schema (`docs/next/api/herdr-api.schema.json`)
/// defines them, `topic` on `agent.transcript`, and the `agent.topics.changed` event.
/// Every fixture is synthetic.
final class AgentTopicsTests: XCTestCase {

    /// A current herdr: topics, and `topic` honoured on `agent.transcript`.
    private static let pongWithTopics =
        #"{"id":"x","result":{"type":"pong","version":"0.9.9","protocol":22,"capabilities":{"agent_transcript":true,"agent_topics":true,"agent_transcript_topic":true}}}"#
    /// `agent.topics.*` but no `agent_transcript_topic`: a server that would ignore `topic`.
    private static let pongTopicsOnly =
        #"{"id":"x","result":{"type":"pong","version":"0.9.9","protocol":22,"capabilities":{"agent_transcript":true,"agent_topics":true}}}"#
    private static let pongTopicsTranscriptTopicFalse =
        #"{"id":"x","result":{"type":"pong","version":"0.9.9","protocol":22,"capabilities":{"agent_transcript":true,"agent_topics":true,"agent_transcript_topic":false}}}"#
    private static let pongWithoutTopics =
        #"{"id":"x","result":{"type":"pong","version":"0.9.4","protocol":22,"capabilities":{"agent_transcript":true}}}"#
    private static let emptyPage =
        #"{"id":"x","result":{"type":"agent_transcript","entries":[],"before":null,"after":"a"}}"#

    private func capabilities(_ json: String) throws -> ServerCapabilities {
        try JSONDecoder().decode(ServerCapabilities.self, from: Data(json.utf8))
    }

    // MARK: Capability

    func testCapabilityDecodesAndDefaultsOff() throws {
        XCTAssertTrue(try capabilities(#"{"agent_transcript":true,"agent_topics":true}"#).agentTopics)
        XCTAssertFalse(try capabilities(#"{"agent_transcript":true}"#).agentTopics, "an older server has no topics")
        XCTAssertFalse(try capabilities(#"{"agent_topics":false}"#).agentTopics)
        XCTAssertTrue(try capabilities(#"{"agent_topics":true,"agent_transcript_topic":true}"#).agentTranscriptTopic)
        XCTAssertFalse(try capabilities(#"{"agent_topics":true}"#).agentTranscriptTopic,
                       "agent_topics alone does not say agent.transcript honours topic")
        XCTAssertFalse(try capabilities(#"{"agent_transcript_topic":false}"#).agentTranscriptTopic)
    }

    /// herdrup#757: `agent_topics` without `agent_transcript_topic` (absent or false) refuses a
    /// topic's transcript before sending, so a server that ignores `topic` cannot answer with
    /// the Inbox's page as the topic's. The topics calls themselves still go out.
    func testTopicTranscriptNeedsAgentTranscriptTopic() async throws {
        for pong in [Self.pongTopicsOnly, Self.pongTopicsTranscriptTopicFalse] {
            let transport = RecordingTransport { method, _ in
                switch method {
                case "ping": return pong
                case "agent.topics.list":
                    return #"{"id":"x","result":{"type":"agent_topics","agent":"enyo","pane_id":"w1:p1","topics":[]}}"#
                default: return Self.emptyPage
                }
            }
            let client = HerdrClient(transport: transport)
            do {
                _ = try await client.agentTranscript(target: "w1:p1", topic: "t1")
                XCTFail("a topic's transcript must not be asked of this server")
            } catch {
                XCTAssertEqual(error as? AgentTranscriptError, .unsupported)
            }
            XCTAssertFalse(transport.requests.contains { $0.method == "agent.transcript" },
                           "refused before sending")
            let pages = await client.advertisesTopicTranscripts()
            XCTAssertFalse(pages, "the page shows topic conversations as unavailable for good")
            _ = try await client.agentTopicsList(target: "w1:p1")
            XCTAssertEqual(transport.requests.last?.method, "agent.topics.list", "agent_topics still gates topics calls")
        }
        let both = RecordingTransport { method, _ in method == "ping" ? Self.pongWithTopics : Self.emptyPage }
        let bothClient = HerdrClient(transport: both)
        _ = try await bothClient.agentTranscript(target: "w1:p1", topic: "t1")
        XCTAssertEqual(try both.last().params["topic"] as? String, "t1", "both advertised: the topic is sent")
        let pages = await bothClient.advertisesTopicTranscripts()
        XCTAssertTrue(pages)
    }

    /// herdr #521: `relay` entries are opt-in. `relay_entries: true` goes on every transcript
    /// request (the Inbox's and a topic's) only to a server advertising
    /// `transcript_relay_entries`; otherwise the param is not sent at all.
    func testRelayEntriesAreAskedForOnlyWhenAdvertised() async throws {
        let relayPong =
            #"{"id":"x","result":{"type":"pong","version":"0.9.9","protocol":22,"capabilities":{"agent_transcript":true,"agent_topics":true,"agent_transcript_topic":true,"transcript_relay_entries":true}}}"#
        XCTAssertTrue(try capabilities(#"{"transcript_relay_entries":true}"#).transcriptRelayEntries)
        XCTAssertFalse(try capabilities(#"{"agent_transcript":true}"#).transcriptRelayEntries)

        let offered = RecordingTransport { method, _ in method == "ping" ? relayPong : Self.emptyPage }
        let client = HerdrClient(transport: offered)
        _ = try await client.agentTranscript(target: "w1:p1", topic: "t1")
        XCTAssertEqual(try offered.last().params["relay_entries"] as? Bool, true, "a topic's page asks for relays")
        _ = try await client.agentTranscript(target: "w1:p1")
        XCTAssertEqual(try offered.last().params["relay_entries"] as? Bool, true, "and so does the Inbox's")

        let older = RecordingTransport { method, _ in method == "ping" ? Self.pongWithTopics : Self.emptyPage }
        _ = try await HerdrClient(transport: older).agentTranscript(target: "w1:p1", topic: "t1")
        XCTAssertNil(try older.last().params["relay_entries"], "not advertised: not sent")
    }

    /// The Inbox's first page went out before the client knew the server offers relays, so
    /// it came without them. Once a topic's page learns the capability, the Inbox's next
    /// refresh reloads the newest page with `relay_entries`, once, and sends no `ping` of
    /// its own; after that it polls `after` again.
    @MainActor
    func testALegacyInboxSnapshotReloadsOnceWhenRelaysAreLearned() async throws {
        let relayPong =
            #"{"id":"x","result":{"type":"pong","version":"0.9.9","protocol":22,"capabilities":{"agent_transcript":true,"agent_topics":true,"agent_transcript_topic":true,"transcript_relay_entries":true}}}"#
        let transport = RecordingTransport { method, _ in method == "ping" ? relayPong : Self.emptyPage }
        let client = HerdrClient(transport: transport)
        let inbox = TranscriptStore(target: "w1:p1")
        await inbox.refresh(client: client)
        XCTAssertNil(try transport.last().params["relay_entries"], "nothing learned yet: a legacy page")
        await inbox.refresh(client: client)
        XCTAssertEqual(try transport.last().params["after"] as? String, "a", "unchanged: it polls after")

        _ = try await client.agentTranscript(target: "w1:p1", topic: "t1")
        let pings = transport.requests.filter { $0.method == "ping" }.count
        XCTAssertEqual(pings, 1, "the topic's page learned the capability")

        await inbox.refresh(client: client)
        let reload = try transport.last()
        XCTAssertNil(reload.params["after"], "the legacy snapshot is reloaded")
        XCTAssertEqual(reload.params["relay_entries"] as? Bool, true)
        await inbox.refresh(client: client)
        XCTAssertEqual(try transport.last().params["after"] as? String, "a", "once: then it polls after")
        XCTAssertEqual(transport.requests.filter { $0.method == "ping" }.count, pings, "no ping of its own")
    }

    // MARK: Discovery schedule (#758)

    /// `topics_unsupported` and a server without `agent_topics` stop discovery for good, on the
    /// first answer or after any number of retries.
    func testDiscoveryStopsOnPermanentRefusals() {
        for error in [AgentTopicsError.unsupported, .notAdvertised] {
            XCTAssertTrue(error.isPermanent, "\(error)")
            var backoff = TopicsDiscoveryBackoff()
            XCTAssertEqual(backoff.decide(after: error), .stop, "\(error)")
            _ = backoff.decide(after: AgentTopicsError.unreachable)
            XCTAssertEqual(backoff.decide(after: error), .stop, "\(error) after a retry")
        }
    }

    /// herdrup#777: `agent_not_found` is what a pane answers while its agent restarts. It is not
    /// a refusal for good: discovery backs off like `topics_unreachable`, and a list that fails
    /// so after Topics were offered keeps them offered (`TopicsModel` acts on `isPermanent`).
    func testAgentNotFoundIsPassing() {
        XCTAssertFalse(AgentTopicsError.agentNotFound.isPermanent)
        var backoff = TopicsDiscoveryBackoff()
        XCTAssertEqual(backoff.decide(after: AgentTopicsError.agentNotFound), .retry(afterSeconds: 60))
        XCTAssertEqual(backoff.decide(after: AgentTopicsError.agentNotFound), .retry(afterSeconds: 120))
        XCTAssertEqual(backoff.decide(after: nil), .offered)
    }

    /// herdrup#777: the first list fails `agent_not_found` (the agent was restarting), the next
    /// one answers: discovery keeps going and ends offered.
    @MainActor
    func testDiscoveryLoopOffersAfterTheAgentWasBrieflyGone() async {
        let sleeps = FakeSleeps()
        var answers: [(any Error)?] = [AgentTopicsError.agentNotFound, nil]
        var attempts = 0
        let loop = TopicsDiscoveryLoop(attempt: {
            attempts += 1
            return answers.removeFirst()
        }, sleep: { sleeps.sleep($0) })
        await loop.run()
        XCTAssertEqual(attempts, 2, "asked again after agent_not_found")
        XCTAssertEqual(sleeps.waits, [60])
    }

    /// `topics_unreachable` (every omp agent without topics on), a timeout or a dropped
    /// connection back off 60 s, doubling, to a 10 minute cap that then repeats.
    func testUnreachableBacksOffToATenMinuteCap() {
        var backoff = TopicsDiscoveryBackoff()
        var waits: [UInt64] = []
        for _ in 0..<8 {
            guard case .retry(let seconds) = backoff.decide(after: AgentTopicsError.unreachable) else {
                return XCTFail("unreachable retries")
            }
            waits.append(seconds)
        }
        XCTAssertEqual(waits, [60, 120, 240, 480, 600, 600, 600, 600])
        for error: Error in [AgentTopicsError.timeout, TransportError.closedBeforeResponse] {
            var other = TopicsDiscoveryBackoff()
            XCTAssertEqual(other.decide(after: error), .retry(afterSeconds: 60), "\(error) backs off too")
        }
    }

    /// A change of the agent (status, session, a topics change, a guest reconnect) resets the
    /// schedule to its start; a successful list ends it and also starts any later run fresh.
    func testResetAndSuccessRestartTheSchedule() {
        var backoff = TopicsDiscoveryBackoff()
        for _ in 0..<6 { _ = backoff.decide(after: AgentTopicsError.unreachable) }
        XCTAssertEqual(backoff.decide(after: AgentTopicsError.unreachable), .retry(afterSeconds: 600))
        backoff.reset()
        XCTAssertEqual(backoff.decide(after: AgentTopicsError.unreachable), .retry(afterSeconds: 60))
        XCTAssertEqual(backoff.decide(after: AgentTopicsError.unreachable), .retry(afterSeconds: 120))
        XCTAssertEqual(backoff.decide(after: nil), .offered)
        XCTAssertEqual(backoff.decide(after: AgentTopicsError.unreachable), .retry(afterSeconds: 60))
    }

    /// Records the waits the loop asks for and returns at once: the schedule runs without a clock.
    private final class FakeSleeps: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [UInt64] = []
        var waits: [UInt64] { lock.withLock { recorded } }
        func sleep(_ seconds: UInt64) { lock.withLock { recorded.append(seconds) } }
    }

    /// Without a wake, a failed list waits the schedule's first delay before asking again.
    @MainActor
    func testDiscoveryLoopWaitsAfterAFailedList() async {
        let sleeps = FakeSleeps()
        var answers: [(any Error)?] = [AgentTopicsError.unreachable, nil]
        var attempts = 0
        let loop = TopicsDiscoveryLoop(attempt: {
            attempts += 1
            return answers.removeFirst()
        }, sleep: { sleeps.sleep($0) })
        await loop.run()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(sleeps.waits, [60])
    }

    /// herdrup#767: an `agent.topics.changed` that lands while a list is still in flight, and
    /// that list then fails, makes the next attempt run at once, with no backoff wait.
    @MainActor
    func testWakeDuringAnInFlightListRetriesAtOnce() async {
        let sleeps = FakeSleeps()
        var attempts = 0
        var loop: TopicsDiscoveryLoop!
        loop = TopicsDiscoveryLoop(attempt: {
            attempts += 1
            if attempts == 1 {
                loop.wake()   // the event arrives while this list is on its way
                return AgentTopicsError.unreachable
            }
            return nil
        }, sleep: { sleeps.sleep($0) })
        await loop.run()
        XCTAssertEqual(attempts, 2, "the next attempt ran")
        XCTAssertEqual(sleeps.waits, [], "without waiting out the backoff")
    }

    /// After a wake, the schedule starts over: the next failure waits the first delay again.
    @MainActor
    func testWakeRestartsTheSchedule() async {
        let sleeps = FakeSleeps()
        var attempts = 0
        var loop: TopicsDiscoveryLoop!
        loop = TopicsDiscoveryLoop(attempt: {
            attempts += 1
            switch attempts {
            case 3: loop.wake(); return AgentTopicsError.unreachable
            case 5: return nil
            default: return AgentTopicsError.unreachable
            }
        }, sleep: { sleeps.sleep($0) })
        await loop.run()
        XCTAssertEqual(attempts, 5)
        XCTAssertEqual(sleeps.waits, [60, 120, 60], "the wake skips its wait and restarts at 60 s")
    }

    /// A permanent refusal ends the loop without waiting.
    @MainActor
    func testDiscoveryLoopStopsOnTopicsUnsupported() async {
        let sleeps = FakeSleeps()
        var attempts = 0
        let loop = TopicsDiscoveryLoop(attempt: {
            attempts += 1
            return AgentTopicsError.unsupported
        }, sleep: { sleeps.sleep($0) })
        await loop.run()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(sleeps.waits, [])
    }

    // MARK: Decoding

    func testListDecodesEveryFieldInSchemaSpelling() throws {
        let list = try JSONDecoder().decode(AgentTopicList.self, from: Data(#"""
        {"type":"agent_topics","agent":"enyo","pane_id":"w1:p1","topics":[
          {"topic_id":"t-diokan","title":"Diokan term sheet","state":"running","turns":12,"queued":1,
           "created_unix_ms":1700000000000,"last_activity_unix_ms":1700000900000,
           "last_activity":"Covenant headroom at 1.6x"}
        ]}
        """#.utf8))
        XCTAssertEqual(list.agent, "enyo")
        XCTAssertEqual(list.paneID, "w1:p1")
        XCTAssertEqual(list.topics, [AgentTopic(
            id: "t-diokan", title: "Diokan term sheet", state: .running, turns: 12, queued: 1,
            createdUnixMs: 1_700_000_000_000, lastActivityUnixMs: 1_700_000_900_000,
            lastActivity: "Covenant headroom at 1.6x")])
        XCTAssertTrue(list.topics[0].state.isWorking)
    }

    func testUnknownStatesAndFieldsDoNotFailTheList() throws {
        let list = try JSONDecoder().decode(AgentTopicList.self, from: Data(#"""
        {"type":"agent_topics","agent":"enyo","pane_id":"w1:p1","future_field":{"x":1},"topics":[
          {"topic_id":"a","title":"Hibernating","state":"hibernating","turns":1,"queued":0,
           "created_unix_ms":1,"last_activity_unix_ms":2,"cost_usd":0.12},
          {"topic_id":"b","title":"Minimal","state":"idle"},
          {"title":"No id, so no row"},
          {"topic_id":"c","title":"Odd numbers","state":"dead","turns":"many","queued":-1,
           "created_unix_ms":3,"last_activity_unix_ms":4,"last_activity":null}
        ]}
        """#.utf8))
        XCTAssertEqual(list.topics.map(\.id), ["a", "b", "c"], "a row without an id is left out, the rest stay")
        XCTAssertEqual(list.topics[0].state, .unknown)
        XCTAssertFalse(list.topics[0].state.isWorking)
        XCTAssertEqual(list.topics[1].turns, 0)
        XCTAssertEqual(list.topics[1].lastActivity, nil)
        XCTAssertEqual(list.topics[2].state, .dead)
        XCTAssertEqual(list.topics[2].turns, 0, "a malformed count reads as zero")
    }

    func testEmptyListIsNotAnError() throws {
        let list = try JSONDecoder().decode(AgentTopicList.self, from: Data(
            #"{"type":"agent_topics","agent":"enyo","pane_id":"w1:p1","topics":[]}"#.utf8))
        XCTAssertTrue(list.topics.isEmpty)
    }

    /// herdr's copy of the list: `stale` and `as_of_unix_ms` decode when sent and default
    /// when an older herdr leaves them out.
    func testListCarriesHerdrsCopyFieldsWhenSent() throws {
        let cached = try JSONDecoder().decode(AgentTopicList.self, from: Data(
            #"{"type":"agent_topics","agent":"enyo","pane_id":"w1:p1","topics":[],"stale":true,"as_of_unix_ms":1700000000000}"#.utf8))
        XCTAssertTrue(cached.stale)
        XCTAssertEqual(cached.asOfUnixMs, 1_700_000_000_000)
        let older = try JSONDecoder().decode(AgentTopicList.self, from: Data(
            #"{"type":"agent_topics","agent":"enyo","pane_id":"w1:p1","topics":[],"stale":"maybe"}"#.utf8))
        XCTAssertFalse(older.stale, "absent or malformed reads as fresh")
        XCTAssertNil(older.asOfUnixMs)
    }

    func testSeededRowsComeFromTopicSessionsNewestFirst() {
        let rows = AgentTopicList.seeded(from: [
            AgentTopicSession(topicID: "old", title: "Old", createdUnixMs: 1),
            AgentTopicSession(topicID: ""),
            AgentTopicSession(topicID: "new", title: nil, createdUnixMs: 9),
        ])
        XCTAssertEqual(rows.map(\.id), ["new", "old"], "an empty id is skipped; newest first")
        XCTAssertEqual(rows.map(\.title), ["", "Old"])
        XCTAssertTrue(rows.allSatisfy { $0.state == .unknown }, "no state is known before the agent answers")
    }

    func testOrderedPutsOpenTopicsByActivityThenClosedOnes() {
        let list = AgentTopicList(agent: "enyo", paneID: "w1:p1", topics: [
            AgentTopic(id: "old", title: "Old", state: .idle, createdUnixMs: 1, lastActivityUnixMs: 10),
            AgentTopic(id: "closed-new", title: "Closed", state: .closed, createdUnixMs: 1, lastActivityUnixMs: 99),
            AgentTopic(id: "new", title: "New", state: .running, createdUnixMs: 1, lastActivityUnixMs: 50),
            AgentTopic(id: "fresh", title: "Fresh", state: .starting, createdUnixMs: 60),
        ])
        XCTAssertEqual(list.ordered.map(\.id), ["fresh", "new", "old", "closed-new"])
    }

    func testTopicSessionsOnAgentInfoDecodeLeniently() throws {
        let agents = try JSONDecoder().decode([AgentInfo].self, from: Data(#"""
        [{"pane_id":"w1:p1","agent":"omp","topic_sessions":[
           {"topic_id":"t1","path":"/s/Diokan.jsonl","title":"Diokan","created_unix_ms":5},
           {"topic_id":"t2","path":"/s/x.jsonl"},
           7
         ]},
         {"pane_id":"w1:p2","agent":"claude"}]
        """#.utf8))
        XCTAssertEqual(agents[0].topicSessions?.map(\.topicID), ["t1", "t2", ""],
                       "an odd element reads as an empty id rather than failing agent.list")
        XCTAssertEqual(agents[0].topicSessions?.first?.title, "Diokan")
        XCTAssertNil(agents[1].topicSessions, "an agent without topics has none")
    }

    // MARK: Calls

    func testCallsSendSchemaParamsAndDecodeResults() async throws {
        let transport = RecordingTransport { method, _ in
            switch method {
            case "ping": return Self.pongWithTopics
            case "agent.topics.list":
                return #"{"id":"x","result":{"type":"agent_topics","agent":"enyo","pane_id":"w1:p1","topics":[]}}"#
            case "agent.topics.new":
                return #"{"id":"x","result":{"type":"agent_topic_created","agent":"enyo","pane_id":"w1:p1","topic_id":"t9"}}"#
            case "agent.topics.send":
                return #"{"id":"x","result":{"type":"agent_topic_sent","agent":"enyo","pane_id":"w1:p1","topic_id":"t9","mode":"queued"}}"#
            default:
                return #"{"id":"x","result":{"type":"agent_topic_updated","agent":"enyo","pane_id":"w1:p1","topic_id":"t9"}}"#
            }
        }
        let client = HerdrClient(transport: transport)

        _ = try await client.agentTopicsList(target: "w1:p1")
        var (method, params) = try transport.last()
        XCTAssertEqual(method, "agent.topics.list")
        XCTAssertEqual(params as NSDictionary, ["target": "w1:p1"])

        let id = try await client.agentTopicsNew(target: "w1:p1", title: "Q4 board pack", message: "Start the liquidity page")
        XCTAssertEqual(id, "t9")
        (method, params) = try transport.last()
        XCTAssertEqual(method, "agent.topics.new")
        XCTAssertEqual(params as NSDictionary,
                       ["target": "w1:p1", "title": "Q4 board pack", "message": "Start the liquidity page"])

        let mode = try await client.agentTopicsSend(target: "w1:p1", topicID: "t9", message: "And the cash page")
        XCTAssertEqual(mode, .queued)
        (method, params) = try transport.last()
        XCTAssertEqual(method, "agent.topics.send")
        XCTAssertEqual(params as NSDictionary, ["target": "w1:p1", "topic_id": "t9", "message": "And the cash page"])

        try await client.agentTopicsClose(target: "w1:p1", topicID: "t9")
        (method, params) = try transport.last()
        XCTAssertEqual(method, "agent.topics.close")
        XCTAssertEqual(params as NSDictionary, ["target": "w1:p1", "topic_id": "t9"])

        try await client.agentTopicsReopen(target: "w1:p1", topicID: "t9")
        XCTAssertEqual(try transport.last().method, "agent.topics.reopen")

        try await client.agentTopicsRename(target: "w1:p1", topicID: "t9", title: "Board pack")
        (method, params) = try transport.last()
        XCTAssertEqual(method, "agent.topics.rename")
        XCTAssertEqual(params as NSDictionary, ["target": "w1:p1", "topic_id": "t9", "title": "Board pack"])
    }

    func testUnknownSendModeDecodes() async throws {
        let transport = RecordingTransport(replies: [
            "ping": Self.pongWithTopics,
            "agent.topics.send": #"{"id":"x","result":{"type":"agent_topic_sent","agent":"e","pane_id":"w1:p1","topic_id":"t","mode":"teleported"}}"#,
        ])
        let mode = try await HerdrClient(transport: transport).agentTopicsSend(target: "w1:p1", topicID: "t", message: "hi")
        XCTAssertEqual(mode, .unknown)
    }

    func testRefusalsAreTyped() async {
        let cases: [(String, String, AgentTopicsError)] = [
            ("topics_unreachable", "the agent has not offered its topics", .unreachable),
            ("topics_unsupported", "topics are served by live omp agents only", .unsupported),
            ("topics_timeout", "slow", .timeout),
            ("topic_rejected", "no such title", .rejected("no such title")),
            ("topic_not_found", "gone", .topicNotFound),
            ("agent_not_found", "gone", .agentNotFound),
            ("invalid_request", "unknown variant `agent.topics.list`, expected one of", .unsupported),
            ("forbidden", "no", .other(APIError(code: "forbidden", message: "no"))),
        ]
        for (code, message, expected) in cases {
            let transport = RecordingTransport { method, _ in
                method == "ping" ? Self.pongWithTopics : RecordingTransport.errorReply(code: code, message: message)
            }
            do {
                _ = try await HerdrClient(transport: transport).agentTopicsList(target: "w1:p1")
                XCTFail("\(code) should throw")
            } catch {
                XCTAssertEqual(error as? AgentTopicsError, expected, code)
            }
        }
    }

    // MARK: Gating

    func testNoTopicCallReachesAServerWithoutTheCapability() async {
        let transport = RecordingTransport(replies: ["ping": Self.pongWithoutTopics])
        let client = HerdrClient(transport: transport)
        let advertises = await client.advertisesAgentTopics()
        XCTAssertFalse(advertises)
        do {
            _ = try await client.agentTopicsList(target: "w1:p1")
            XCTFail("a server without agent_topics is never asked")
        } catch {
            XCTAssertEqual(error as? AgentTopicsError, .notAdvertised)
        }
        do {
            _ = try await client.agentTranscript(target: "w1:p1", topic: "t1")
            XCTFail("a topic's transcript is never asked of a server without agent_topics")
        } catch {
            XCTAssertEqual(error as? AgentTranscriptError, .unsupported)
        }
        XCTAssertEqual(transport.requests.map(\.method), ["ping"],
                       "only the capability probe went out: no agent.topics.* and no topic transcript")
    }

    func testTranscriptCarriesTopicOnlyWhenAsked() async throws {
        let transport = RecordingTransport { method, _ in
            method == "ping" ? Self.pongWithTopics : Self.emptyPage
        }
        let client = HerdrClient(transport: transport)
        _ = try await client.agentTranscript(target: "w1:p1", topic: "t-diokan")
        XCTAssertEqual(try transport.last().params["topic"] as? String, "t-diokan")
        _ = try await client.agentTranscript(target: "w1:p1")
        XCTAssertFalse(try transport.last().params.keys.contains("topic"), "the Inbox's page sends no topic key at all")
    }

    func testTranscriptWithoutTopicNeverProbesTheCapability() async throws {
        let transport = RecordingTransport(reply: Self.emptyPage)
        _ = try await HerdrClient(transport: transport).agentTranscript(target: "w1:p1")
        XCTAssertEqual(transport.requests.map(\.method), ["agent.transcript"])
    }

    func testTopicNotFoundOnTheTranscriptIsTyped() async {
        let transport = RecordingTransport { method, _ in
            method == "ping" ? Self.pongWithTopics : RecordingTransport.errorReply(code: "topic_not_found", message: "no")
        }
        do {
            _ = try await HerdrClient(transport: transport).agentTranscript(target: "w1:p1", topic: "gone")
            XCTFail("topic_not_found should throw")
        } catch {
            XCTAssertEqual(error as? AgentTranscriptError, .topicNotFound)
        }
    }

    @MainActor
    func testStorePagesItsTopic() async throws {
        let transport = RecordingTransport { method, _ in
            method == "ping" ? Self.pongWithTopics : Self.emptyPage
        }
        let client = HerdrClient(transport: transport)
        let store = TranscriptStore(target: "w1:p1", topic: "t-diokan")
        await store.refresh(client: client)
        await store.refresh(client: client)
        let pages = transport.requests.filter { $0.method == "agent.transcript" }
        XCTAssertGreaterThanOrEqual(pages.count, 2)
        XCTAssertTrue(pages.allSatisfy { $0.params["topic"] as? String == "t-diokan" },
                      "the newest page and the after refresh both page the topic")
    }

    // MARK: Event

    func testChangedEventDecodesAndUnknownReasonsAreSafe() throws {
        let line = #"{"seq":4,"event":"agent_topics_changed","data":{"type":"agent_topics_changed","pane_id":"w1:p1","workspace_id":"w1","agent":"enyo","topic_id":"t1","reason":"turn_settled"}}"#
        XCTAssertEqual(try AgentTopicsStreamLine.decode(line), .changed(AgentTopicsChange(
            paneID: "w1:p1", workspaceID: "w1", agent: "enyo", topicID: "t1", reason: .turnSettled)))

        let future = #"{"seq":5,"event":"agent.topics.changed","data":{"type":"agent_topics_changed","pane_id":"w1:p1","workspace_id":"w1","topic_id":"t1","reason":"teleported","extra":true}}"#
        guard case .changed(let change) = try AgentTopicsStreamLine.decode(future) else {
            return XCTFail("a newer reason still reports the change")
        }
        XCTAssertEqual(change.reason, .unknown)
        XCTAssertNil(change.agent)

        XCTAssertEqual(try AgentTopicsStreamLine.decode(#"{"id":"s","result":{"type":"subscription_started"}}"#), .started)
        XCTAssertEqual(try AgentTopicsStreamLine.decode(#"{"control":"heartbeat","seq":9}"#), .other)
        XCTAssertEqual(try AgentTopicsStreamLine.decode(#"{"event":"pane_created","data":{"type":"pane_created"}}"#), .other)
        XCTAssertEqual(try AgentTopicsStreamLine.decode("not json"), .other)
        XCTAssertThrowsError(try AgentTopicsStreamLine.decode(
            #"{"id":"s","error":{"code":"invalid_request","message":"unknown variant `agent.topics.changed`"}}"#))
    }

    func testSubscriptionAsksForTheTopicsEvent() async throws {
        let transport = TopicStreamTransport(lines: [
            #"{"id":"s","result":{"type":"subscription_started"}}"#,
            #"{"seq":1,"event":"agent_topics_changed","data":{"type":"agent_topics_changed","pane_id":"w1:p1","workspace_id":"w1","topic_id":"t1","reason":"spawned"}}"#,
        ])
        var lines: [AgentTopicsStreamLine] = []
        for try await line in HerdrClient(transport: transport).subscribeTopicChanges() { lines.append(line) }
        XCTAssertEqual(lines.count, 2)
        let request = try XCTUnwrap(transport.requests.first)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])
        XCTAssertEqual(object["method"] as? String, "events.subscribe")
        let subscriptions = (object["params"] as? [String: Any])?["subscriptions"] as? [[String: Any]]
        XCTAssertEqual(subscriptions?.count, 1)
        XCTAssertEqual(subscriptions?.first?["type"] as? String, "agent.topics.changed")
        XCTAssertNil(subscriptions?.first?["pane_id"], "the topics event takes no pane id")
    }
}

/// Streams fixed lines, then closes, recording each request.
private final class TopicStreamTransport: HerdrTransport, @unchecked Sendable {
    private let lines: [String]
    private let lock = NSLock()
    private var recorded: [String] = []

    init(lines: [String]) { self.lines = lines }

    var requests: [String] { lock.withLock { recorded } }

    func roundTrip(_ requestLine: String) async throws -> String { "" }

    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        lock.withLock { recorded.append(requestLine) }
        return AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
}
