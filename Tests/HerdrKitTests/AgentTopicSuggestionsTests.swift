import Foundation
import XCTest
@testable import HerdrKit

/// The Topics switch (`agent_topics_switch`, `agent.topics.set_enabled`, `topics_enabled`), topic
/// suggestions and Organise (`agent_topic_suggestions`, `agent.topics.accept_suggestion` /
/// `dismiss_suggestion` / `organise`, `suggestions` on the list, `topic_suggestion` entries).
/// The agent picks the messages that come along: no call sends `message_ids`. Every fixture is
/// synthetic.
final class AgentTopicSuggestionsTests: XCTestCase {

    private static let pongAll =
        #"{"id":"x","result":{"type":"pong","version":"0.9.9","protocol":22,"capabilities":{"agent_transcript":true,"agent_topics":true,"agent_transcript_topic":true,"agent_topics_switch":true,"agent_topic_suggestions":true}}}"#
    private static let pongTopicsOnly =
        #"{"id":"x","result":{"type":"pong","version":"0.9.9","protocol":22,"capabilities":{"agent_transcript":true,"agent_topics":true}}}"#

    private func capabilities(_ json: String) throws -> ServerCapabilities {
        try JSONDecoder().decode(ServerCapabilities.self, from: Data(json.utf8))
    }

    private func makeClient(_ replies: [String: String], pong: String = pongAll) -> (HerdrClient, RecordingTransport) {
        let transport = RecordingTransport { method, _ in
            method == "ping" ? pong : (replies[method] ?? RecordingTransport.emptyResult)
        }
        return (HerdrClient(transport: transport), transport)
    }

    // MARK: Capabilities

    func testCapabilitiesDecodeAndDefaultOff() throws {
        let all = try capabilities(#"{"agent_topics":true,"agent_topics_switch":true,"agent_topics_switch_when_idle":true,"agent_topic_suggestions":true}"#)
        XCTAssertTrue(all.agentTopicsSwitch)
        XCTAssertTrue(all.agentTopicsSwitchWhenIdle)
        XCTAssertTrue(all.agentTopicSuggestions)
        let old = try capabilities(#"{"agent_topics":true}"#)
        XCTAssertFalse(old.agentTopicsSwitch, "an older server has no switch")
        XCTAssertFalse(old.agentTopicsSwitchWhenIdle, "an older server cannot wait for idle")
        XCTAssertFalse(old.agentTopicSuggestions, "an older server has no suggestions")
        let switchOnly = try capabilities(#"{"agent_topics_switch":true}"#)
        XCTAssertFalse(switchOnly.agentTopicsSwitchWhenIdle, "the switch before herdr#493 ignores when_idle")
        let off = try capabilities(#"{"agent_topics_switch":false,"agent_topics_switch_when_idle":false,"agent_topic_suggestions":false}"#)
        XCTAssertFalse(off.agentTopicsSwitch)
        XCTAssertFalse(off.agentTopicsSwitchWhenIdle)
        XCTAssertFalse(off.agentTopicSuggestions)
    }

    func testAgentInfoReadsTopicsEnabled() throws {
        struct Wrap: Decodable { let agents: [AgentInfo] }
        let wrap = try JSONDecoder().decode(Wrap.self, from: Data(#"""
        {"agents":[{"pane_id":"w1:p1","agent":"omp","topics_enabled":true},
                   {"pane_id":"w1:p2","agent":"omp","topics_enabled":false},
                   {"pane_id":"w1:p3","agent":"claude"}]}
        """#.utf8))
        XCTAssertEqual(wrap.agents.map(\.topicsEnabled), [true, false, nil])
        XCTAssertEqual(wrap.agents.map(\.isTopicsSwitchPending), [false, false, false], "absent: not pending")
    }

    func testAgentInfoReadsTopicsSwitchPending() throws {
        struct Wrap: Decodable { let agents: [AgentInfo] }
        let wrap = try JSONDecoder().decode(Wrap.self, from: Data(#"""
        {"agents":[{"pane_id":"w1:p1","agent":"omp","agent_status":"working","topics_enabled":false,"topics_switch_pending":true},
                   {"pane_id":"w1:p2","agent":"omp","topics_enabled":true,"topics_switch_pending":false},
                   {"pane_id":"w1:p3","agent":"omp","topics_enabled":true}]}
        """#.utf8))
        XCTAssertEqual(wrap.agents.map(\.isTopicsSwitchPending), [true, false, false])
        XCTAssertEqual(wrap.agents.map(\.topicsSwitchPending), [true, false, nil])
    }

    // MARK: Switch

    func testSetEnabledEncodesAndDecodes() async throws {
        let (client, transport) = makeClient(["agent.topics.set_enabled":
            #"{"id":"x","result":{"type":"agent_topics_switched","agent":"enyo","changed":true,"topics_enabled":true}}"#])
        let result = try await client.agentTopicsSetEnabled(target: "w1:p1", enabled: true)
        XCTAssertEqual(result, AgentTopicsSwitched(agent: "enyo", changed: true, topicsEnabled: true))
        let last = try transport.last()
        XCTAssertEqual(last.method, "agent.topics.set_enabled")
        XCTAssertEqual(last.params["target"] as? String, "w1:p1")
        XCTAssertEqual(last.params["enabled"] as? Bool, true)
        XCTAssertEqual(last.params["when_idle"] as? Bool, false, "switch now by default")
        XCTAssertEqual(Set(last.params.keys), ["target", "enabled", "when_idle"])
        XCTAssertFalse(result.scheduled, "absent scheduled reads as false")

        let (offClient, offTransport) = makeClient(["agent.topics.set_enabled":
            #"{"id":"x","result":{"type":"agent_topics_switched","agent":"enyo","changed":false,"topics_enabled":false}}"#])
        let off = try await offClient.agentTopicsSetEnabled(target: "enyo", enabled: false)
        XCTAssertFalse(off.changed, "already off")
        XCTAssertFalse(off.topicsEnabled)
        XCTAssertEqual(try offTransport.last().params["enabled"] as? Bool, false)
    }

    func testSetEnabledWhenIdleSendsTheFlagAndDecodesScheduled() async throws {
        let (client, transport) = makeClient(["agent.topics.set_enabled":
            #"{"id":"x","result":{"type":"agent_topics_switched","agent":"enyo","changed":true,"topics_enabled":false,"scheduled":true}}"#])
        let result = try await client.agentTopicsSetEnabled(target: "w1:p1", enabled: true, whenIdle: true)
        XCTAssertEqual(result, AgentTopicsSwitched(agent: "enyo", changed: true, topicsEnabled: false, scheduled: true))
        XCTAssertEqual(try transport.last().params["when_idle"] as? Bool, true)

        let (now, _) = makeClient(["agent.topics.set_enabled":
            #"{"id":"x","result":{"type":"agent_topics_switched","agent":"enyo","changed":true,"topics_enabled":true,"scheduled":false}}"#])
        let applied = try await now.agentTopicsSetEnabled(target: "w1:p1", enabled: true, whenIdle: true)
        XCTAssertFalse(applied.scheduled, "an idle agent switches at once")
        XCTAssertTrue(applied.topicsEnabled)
    }

    /// herdrup#802: Cancel pending switch reads the agent fresh first. Still pending: it sends
    /// the current state (with `when_idle`), which herdr reads as the cancel.
    func testCancelPendingSwitchSendsWhileTheServerStillHoldsIt() async throws {
        let (client, transport) = makeClient([
            "agent.get": #"{"id":"x","result":{"type":"agent_info","agent":{"pane_id":"w1:p1","agent":"omp","agent_status":"working","topics_enabled":false,"topics_switch_pending":true}}}"#,
            "agent.topics.set_enabled": #"{"id":"x","result":{"type":"agent_topics_switched","agent":"enyo","changed":false,"topics_enabled":false,"scheduled":false}}"#,
        ])
        let outcome = try await client.agentTopicsCancelPendingSwitch(target: "w1:p1")
        XCTAssertEqual(outcome, .answered(AgentTopicsSwitched(agent: "enyo", changed: false, topicsEnabled: false)))
        let methods = transport.requests.map(\.method).filter { $0 != "ping" }
        XCTAssertEqual(methods, ["agent.get", "agent.topics.set_enabled"], "read fresh, then cancel")
        let get = try XCTUnwrap(transport.requests.first { $0.method == "agent.get" })
        XCTAssertEqual(get.params["target"] as? String, "w1:p1")
        let cancel = try transport.last()
        XCTAssertEqual(cancel.params["enabled"] as? Bool, false, "the agent's current state")
        XCTAssertEqual(cancel.params["when_idle"] as? Bool, true, "a lost race never cuts a turn")
    }

    /// herdrup#802: herdr already applied the held switch (the listed row is stale): nothing is
    /// sent, so the agent is not switched straight back.
    func testCancelPendingSwitchSendsNothingOnceTheSwitchWasApplied() async throws {
        let (client, transport) = makeClient([
            "agent.get": #"{"id":"x","result":{"type":"agent_info","agent":{"pane_id":"w1:p1","agent":"omp","agent_status":"idle","topics_enabled":true}}}"#,
            "agent.topics.set_enabled": #"{"id":"x","result":{"type":"agent_topics_switched","agent":"enyo","changed":true,"topics_enabled":false,"scheduled":false}}"#,
        ])
        let outcome = try await client.agentTopicsCancelPendingSwitch(target: "w1:p1")
        XCTAssertEqual(outcome, .notPending(topicsEnabled: true))
        XCTAssertFalse(transport.requests.contains { $0.method == "agent.topics.set_enabled" },
                       "no switch back")

        let (old, oldTransport) = makeClient([:], pong: Self.pongTopicsOnly)
        do {
            _ = try await old.agentTopicsCancelPendingSwitch(target: "w1:p1")
            XCTFail("refused before sending")
        } catch {
            XCTAssertEqual(error as? AgentTopicsSwitchError, .notAdvertised)
        }
        XCTAssertEqual(oldTransport.requests.map(\.method).filter { $0 != "ping" }, [])
    }

    func testSetEnabledNeedsTheCapabilityAndTypesItsErrors() async throws {
        let (old, oldTransport) = makeClient([:], pong: Self.pongTopicsOnly)
        do {
            try await old.agentTopicsSetEnabled(target: "w1:p1", enabled: true)
            XCTFail("refused before sending")
        } catch {
            XCTAssertEqual(error as? AgentTopicsSwitchError, .notAdvertised)
        }
        XCTAssertFalse(oldTransport.requests.contains { $0.method == "agent.topics.set_enabled" })

        let cases: [(String, AgentTopicsSwitchError)] = [
            ("topics_build_missing", .buildMissing), ("not_omp", .notOmp), ("guest_forbidden", .guestForbidden),
            ("agent_directory_unavailable", .directoryUnavailable),
        ]
        for (code, expected) in cases {
            let (client, _) = makeClient(["agent.topics.set_enabled": RecordingTransport.errorReply(code: code, message: "no")])
            do {
                try await client.agentTopicsSetEnabled(target: "w1:p1", enabled: true)
                XCTFail(code)
            } catch {
                XCTAssertEqual(error as? AgentTopicsSwitchError, expected, code)
            }
        }
        let (restart, _) = makeClient(["agent.topics.set_enabled":
            RecordingTransport.errorReply(code: "no_resumable_session", message: "no session")])
        do {
            try await restart.agentTopicsSetEnabled(target: "w1:p1", enabled: true)
            XCTFail("agent.restart's errors come through")
        } catch let AgentTopicsSwitchError.other(api) {
            XCTAssertEqual(api.code, "no_resumable_session")
        }
    }

    // MARK: Suggestion calls

    func testAcceptEncodesWithoutMessageIDsAndDecodes() async throws {
        let (client, transport) = makeClient(["agent.topics.accept_suggestion":
            #"{"id":"x","result":{"type":"agent_topic_suggestion_accepted","agent":"enyo","pane_id":"w1:p1","suggestion_id":"s1","topic_id":"t9","already_accepted":false}}"#])
        let accepted = try await client.agentTopicsAcceptSuggestion(target: "w1:p1", suggestionID: "s1")
        XCTAssertEqual(accepted, AgentTopicSuggestionAccepted(topicID: "t9", alreadyAccepted: false))
        let last = try transport.last()
        XCTAssertEqual(last.method, "agent.topics.accept_suggestion")
        XCTAssertEqual(last.params["suggestion_id"] as? String, "s1")
        XCTAssertEqual(Set(last.params.keys), ["target", "suggestion_id"], "the user never picks messages")

        let (again, _) = makeClient(["agent.topics.accept_suggestion":
            #"{"id":"x","result":{"topic_id":"t9","already_accepted":true}}"#])
        let second = try await again.agentTopicsAcceptSuggestion(target: "w1:p1", suggestionID: "s1")
        XCTAssertTrue(second.alreadyAccepted)
        XCTAssertEqual(second.topicID, "t9")

        let (nested, _) = makeClient(["agent.topics.accept_suggestion": #"{"id":"x","result":{"topic":{"topic_id":"t3"}}}"#])
        let third = try await nested.agentTopicsAcceptSuggestion(target: "w1:p1", suggestionID: "s2")
        XCTAssertEqual(third.topicID, "t3", "a `topic` object is read too")
    }

    func testDismissAndOrganiseEncodeAndDecode() async throws {
        let (client, transport) = makeClient([
            "agent.topics.dismiss_suggestion":
                #"{"id":"x","result":{"type":"agent_topic_suggestion_dismissed","agent":"enyo","pane_id":"w1:p1","suggestion_id":"s1","already_dismissed":true}}"#,
            "agent.topics.organise":
                #"{"id":"x","result":{"type":"agent_topics_organise_started","agent":"enyo","pane_id":"w1:p1","queued":true}}"#,
        ])
        let already = try await client.agentTopicsDismissSuggestion(target: "w1:p1", suggestionID: "s1")
        XCTAssertTrue(already)
        var last = try transport.last()
        XCTAssertEqual(last.method, "agent.topics.dismiss_suggestion")
        XCTAssertEqual(Set(last.params.keys), ["target", "suggestion_id"])
        XCTAssertEqual(last.params["suggestion_id"] as? String, "s1")

        let queued = try await client.agentTopicsOrganise(target: "w1:p1")
        XCTAssertTrue(queued)
        last = try transport.last()
        XCTAssertEqual(last.method, "agent.topics.organise")
        XCTAssertEqual(Set(last.params.keys), ["target"])

        let (fresh, _) = makeClient(["agent.topics.dismiss_suggestion": #"{"id":"x","result":{}}"#,
                                 "agent.topics.organise": #"{"id":"x","result":{}}"#])
        let notBefore = try await fresh.agentTopicsDismissSuggestion(target: "w1:p1", suggestionID: "s1")
        XCTAssertFalse(notBefore)
        let started = try await fresh.agentTopicsOrganise(target: "w1:p1")
        XCTAssertFalse(started, "started at once")
    }

    func testSuggestionCallsNeedTheCapabilityAndTypeTheirErrors() async throws {
        let (old, oldTransport) = makeClient([:], pong: Self.pongTopicsOnly)
        do {
            _ = try await old.agentTopicsAcceptSuggestion(target: "w1:p1", suggestionID: "s1")
            XCTFail("refused before sending")
        } catch {
            XCTAssertEqual(error as? AgentTopicsError, .suggestionsNotAdvertised)
        }
        do {
            try await old.agentTopicsOrganise(target: "w1:p1")
            XCTFail("refused before sending")
        } catch {
            XCTAssertEqual(error as? AgentTopicsError, .suggestionsNotAdvertised)
        }
        XCTAssertEqual(oldTransport.requests.map(\.method), ["ping"])

        let cases: [(String, AgentTopicsError)] = [
            ("suggestion_not_found", .suggestionNotFound), ("already_accepted", .alreadyAccepted),
            ("organise_running", .organiseRunning), ("topics_disabled", .topicsDisabled),
            ("invalid_message_ids", .invalidMessageIDs), ("topic_rejected", .rejected("no")),
        ]
        for (code, expected) in cases {
            let (client, _) = makeClient(["agent.topics.dismiss_suggestion": RecordingTransport.errorReply(code: code, message: "no")])
            do {
                try await client.agentTopicsDismissSuggestion(target: "w1:p1", suggestionID: "s1")
                XCTFail(code)
            } catch {
                XCTAssertEqual(error as? AgentTopicsError, expected, code)
                XCTAssertFalse(expected.isPermanent, "\(code) does not stop discovery")
            }
        }
        // An omp without suggestions answers these methods `topics_unsupported`.
        let (unsupported, _) = makeClient(["agent.topics.organise":
            RecordingTransport.errorReply(code: "topics_unsupported", message: "no")])
        do {
            try await unsupported.agentTopicsOrganise(target: "w1:p1")
            XCTFail("topics_unsupported")
        } catch {
            XCTAssertEqual(error as? AgentTopicsError, .unsupported)
        }
    }

    // MARK: List

    func testListDecodesOpenSuggestionsLeniently() throws {
        let list = try JSONDecoder().decode(AgentTopicList.self, from: Data(#"""
        {"type":"agent_topics","agent":"enyo","pane_id":"w1:p1","topics":[],
         "suggestions":[
          {"suggestion_id":"s1","title":"iPad build times","reason":"The build went from 12 to 40 min.",
           "message_ids":["m1","m2","m3"],"created_unix_ms":5},
          {"title":"no id"},
          {"suggestion_id":"s2","title":"Guest invites"}
         ]}
        """#.utf8))
        XCTAssertEqual(list.suggestions?.map(\.id), ["s1", "s2"], "one odd suggestion is left out")
        XCTAssertEqual(list.suggestions?.first?.messageCount, 3)
        XCTAssertEqual(list.suggestions?.first?.reason, "The build went from 12 to 40 min.")
        XCTAssertEqual(list.suggestions?.last?.messageIDs, [])

        let without = try JSONDecoder().decode(AgentTopicList.self, from: Data(
            #"{"type":"agent_topics","agent":"enyo","pane_id":"w1:p1","topics":[]}"#.utf8))
        XCTAssertNil(without.suggestions, "an omp without suggestions sends none")
    }

    // MARK: Transcript

    private static func suggestionEntry(_ state: String, extra: String = "") -> String {
        #"{"id":"sg1","ts_ms":2000,"kind":"topic_suggestion","title":"iPad build times","reason":"You asked why it takes 40 min.","message_ids":["u1","r1"],"message_count":12,"state":"\#(state)"\#(extra)}"#
    }

    private static func page(_ entries: [String], after: String) -> String {
        #"{"id":"x","result":{"type":"agent_transcript","session_id":"s1","entries":[\#(entries.joined(separator: ","))],"before":null,"after":"\#(after)","pending_ask":null,"working":null}}"#
    }

    private func decodePage(_ line: String) throws -> AgentTranscriptPage {
        struct Envelope: Decodable { let result: AgentTranscriptPage }
        return try JSONDecoder().decode(Envelope.self, from: Data(line.utf8)).result
    }

    func testTranscriptEntryDecodesEachState() throws {
        let open = try decodePage(Self.page([Self.suggestionEntry("open")], after: "a1")).entries[0]
        guard case .topicSuggestion(let s) = open.kind else { return XCTFail("\(open.kind)") }
        XCTAssertEqual(s.title, "iPad build times")
        XCTAssertEqual(s.reason, "You asked why it takes 40 min.")
        XCTAssertEqual(s.messageIDs, ["u1", "r1"])
        XCTAssertEqual(s.messageCount, 12, "message_count wins over the ids it sends")
        XCTAssertEqual(s.state, .open)
        XCTAssertNil(s.topicID)

        let accepted = try decodePage(Self.page([Self.suggestionEntry("accepted",
            extra: #","topic_id":"t9","by":"owner""#)], after: "a1")).entries[0]
        XCTAssertEqual(accepted.kind, .topicSuggestion(TranscriptTopicSuggestion(
            title: "iPad build times", reason: "You asked why it takes 40 min.", messageIDs: ["u1", "r1"],
            messageCount: 12, state: .accepted, topicID: "t9", by: "owner")))

        let dismissed = try decodePage(Self.page([Self.suggestionEntry("dismissed",
            extra: #","by":"plotarmordev""#)], after: "a1")).entries[0]
        guard case .topicSuggestion(let d) = dismissed.kind else { return XCTFail() }
        XCTAssertEqual(d.state, .dismissed)
        XCTAssertEqual(d.by, "plotarmordev")

        let future = try decodePage(Self.page([Self.suggestionEntry("merged")], after: "a1")).entries[0]
        guard case .topicSuggestion(let f) = future.kind else { return XCTFail() }
        XCTAssertEqual(f.state, .unknown, "an unfamiliar state does not fail the page")
        XCTAssertTrue(TranscriptGrouping.turns([future]).flatMap(\.items).isEmpty, "and draws nothing")

        let noCount = try decodePage(Self.page([
            #"{"id":"sg2","ts_ms":1,"kind":"topic_suggestion","title":"T","message_ids":["a","b","c"],"state":"open"}"#,
        ], after: "a1")).entries[0]
        guard case .topicSuggestion(let n) = noCount.kind else { return XCTFail() }
        XCTAssertEqual(n.messageCount, 3, "without message_count the ids are counted")
    }

    /// open → accepted: an `after` page re-sends the entry under the same id, which replaces
    /// the open one in place rather than adding a second card.
    @MainActor
    func testStateProgressionReplacesTheEntryInPlace() async throws {
        let store = TranscriptStore(target: "w1:p1")
        let user = #"{"id":"u1","ts_ms":1000,"kind":"user","text":"Separate thing: the iPad build.","author":"owner"}"#
        store.applyNewest(try decodePage(Self.page([user, Self.suggestionEntry("open")], after: "a1")))
        func suggestionItems() -> [TranscriptItem] {
            TranscriptGrouping.turns(store.entries).flatMap(\.items).filter {
                if case .topicSuggestion = $0 { return true }
                return false
            }
        }
        XCTAssertEqual(suggestionItems().count, 1)
        if case .topicSuggestion(_, let s)? = suggestionItems().first { XCTAssertEqual(s.state, .open) }

        store.mergeAfter(try decodePage(Self.page([Self.suggestionEntry("accepted", extra: #","topic_id":"t9","by":"owner""#)],
                                                  after: "a2")))
        XCTAssertEqual(suggestionItems().count, 1, "replaced, not appended")
        guard case .topicSuggestion(let id, let accepted)? = suggestionItems().first else { return XCTFail() }
        XCTAssertEqual(id, "sg1")
        XCTAssertEqual(accepted.state, .accepted)
        XCTAssertEqual(accepted.topicID, "t9")
    }

    // MARK: Events

    /// The suggestion reasons of `agent.topics.changed` (underscores), with `suggestion_id` and
    /// an empty `topic_id`.
    func testTopicsChangedDecodesTheSuggestionReasons() throws {
        for (raw, reason) in [("suggested", AgentTopicChangeReason.suggested),
                              ("suggestion_accepted", .suggestionAccepted),
                              ("suggestion_dismissed", .suggestionDismissed)] {
            let line = #"{"seq":7,"event":"agent_topics_changed","data":{"type":"agent_topics_changed","pane_id":"w1:p1","workspace_id":"w1","agent":"enyo","topic_id":"","suggestion_id":"s1","reason":"\#(raw)"}}"#
            XCTAssertEqual(try AgentTopicsStreamLine.decode(line), .changed(AgentTopicsChange(
                paneID: "w1:p1", workspaceID: "w1", agent: "enyo", topicID: "", reason: reason, suggestionID: "s1")), raw)
        }
        let hyphen = #"{"event":"agent_topics_changed","data":{"pane_id":"w1:p1","topic_id":"","suggestion_id":"s1","reason":"suggestion-accepted"}}"#
        guard case .changed(let change) = try AgentTopicsStreamLine.decode(hyphen) else { return XCTFail() }
        XCTAssertEqual(change.reason, .unknown, "only the underscore spelling is the contract")
    }
}
