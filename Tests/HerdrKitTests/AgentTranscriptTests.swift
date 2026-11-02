import Foundation
import XCTest
@testable import HerdrKit

/// `agent.transcript` / `agent.answer` (herdr#306–#308) and the Chat view's model of an omp
/// conversation. Every fixture is synthetic.
final class AgentTranscriptDecodingTests: XCTestCase {

    private func decodePage(_ json: String) throws -> AgentTranscriptPage {
        try JSONDecoder().decode(AgentTranscriptPage.self, from: Data(json.utf8))
    }

    func testDecodesEveryEntryKindAndIgnoresUnknownOnes() throws {
        let page = try decodePage(#"""
        {"type":"agent_transcript","agent":"demo","pane_id":"w1:p1","session_id":"s1",
         "entries":[
          {"id":"u1","ts_ms":1000,"kind":"user","text":"Fix the build","author":"owner"},
          {"id":"u2","ts_ms":1001,"kind":"user","text":"Add a test","author":"guest","author_name":"sam"},
          {"id":"t1","ts_ms":1002,"kind":"thinking","text":"The linker flag is missing."},
          {"id":"s1","ts_ms":1003,"kind":"step","tool":"bash","intent":"Running the build","status":"running","detail":"make all"},
          {"id":"s2","ts_ms":1004,"kind":"step","tool":"read","status":"error"},
          {"id":"n1","ts_ms":1005,"kind":"note","source":"gitmoot","title":"Review approved","from":"reviewer","body":"LGTM"},
          {"id":"n2","ts_ms":1006,"kind":"note","source":"pager","title":"x","body":"y"},
          {"id":"p1","ts_ms":1007,"kind":"plan","items":[{"text":"Build","done":true},{"text":"Ship","done":false}]},
          {"id":"a1","ts_ms":1008,"kind":"ask","questions":[{"question":"Ship it?","options":["Yes","No"],"multi":false,"recommended":0}],"answer":["Yes"]},
          {"id":"r1","ts_ms":1009,"kind":"reply","text":"**Done.**","final":true},
          {"id":"e1","ts_ms":1010,"kind":"turn_end","status":"error","error":"rate limited"},
          {"id":"c1","ts_ms":1011,"kind":"summary","text":"Earlier messages were summarised"},
          {"id":"x1","ts_ms":1012,"kind":"hologram","text":"from the future"}
         ],
         "before":"b-cursor","after":"a-cursor",
         "pending_ask":{"id":"a2","questions":[{"question":"Merge?","options":["Yes","Not yet"],"multi":false}],"answerable":true},
         "working":{"intent":"Running the build","tool":"bash","since_ms":1003}}
        """#)

        XCTAssertEqual(page.agent, "demo")
        XCTAssertEqual(page.paneID, "w1:p1")
        XCTAssertEqual(page.sessionID, "s1")
        XCTAssertEqual(page.before, "b-cursor")
        XCTAssertEqual(page.after, "a-cursor")
        XCTAssertEqual(page.entries.map(\.kind), [
            .user(text: "Fix the build", author: .owner),
            .user(text: "Add a test", author: .guest(name: "sam")),
            .thinking(text: "The linker flag is missing."),
            .step(TranscriptStep(tool: "bash", intent: "Running the build", status: .running, detail: "make all")),
            // No intent: the tool name stands in, as the contract says the server does.
            .step(TranscriptStep(tool: "read", intent: "read", status: .error)),
            .note(TranscriptNote(source: .gitmoot, title: "Review approved", from: "reviewer", body: "LGTM")),
            // An unfamiliar note source still shows, as a generic note.
            .note(TranscriptNote(source: .other, title: "x", body: "y")),
            .plan([TranscriptPlanItem(text: "Build", done: true), TranscriptPlanItem(text: "Ship", done: false)]),
            .ask(TranscriptAsk(questions: [TranscriptQuestion(question: "Ship it?", options: ["Yes", "No"],
                                                              recommended: 0)], answer: ["Yes"])),
            .reply(text: "**Done.**", final: true),
            .turnEnd(status: .error, error: "rate limited"),
            .summary(text: "Earlier messages were summarised"),
            .unknown("hologram"),
        ])
        XCTAssertEqual(page.entries.map(\.tsMs), Array(1000...1012).map(UInt64.init))
        XCTAssertEqual(page.pendingAsk, TranscriptPendingAsk(
            id: "a2", questions: [TranscriptQuestion(question: "Merge?", options: ["Yes", "Not yet"])],
            answerable: true))
        XCTAssertEqual(page.working, TranscriptWorking(intent: "Running the build", tool: "bash", sinceMs: 1003))
    }

    func testNullCursorsAndAbsentAskDecode() throws {
        let page = try decodePage(#"""
        {"type":"agent_transcript","entries":[],"before":null,"after":"z","pending_ask":null,"working":null}
        """#)
        XCTAssertNil(page.before)
        XCTAssertNil(page.pendingAsk)
        XCTAssertNil(page.working)
        XCTAssertEqual(page.after, "z")
    }

    func testCapabilitiesDecodeTheChatFlagsAndDefaultFalse() throws {
        let on = try JSONDecoder().decode(ServerCapabilities.self,
                                          from: Data(#"{"agent_transcript":true,"agent_answer":true}"#.utf8))
        XCTAssertTrue(on.agentTranscript)
        XCTAssertTrue(on.agentAnswer)
        let old = try JSONDecoder().decode(ServerCapabilities.self, from: Data("{}".utf8))
        XCTAssertFalse(old.agentTranscript)
        XCTAssertFalse(old.agentAnswer)
    }

    func testDecodesSubagentsWithMissingOptionalsAndUnknownStatus() throws {
        let page = try decodePage(#"""
        {"type":"agent_transcript","entries":[],"before":null,"after":"a",
         "subagents":[
          {"id":"AppHeadReview","agent":"reviewer","label":"Review the app head","task":"Target: app\nReview",
           "status":"running","started_ms":1000,"finished_ms":null,"duration_ms":null,
           "last_intent":"Reading ChatView","last_ms":1500,"has_transcript":true},
          {"id":"DaemonHeadReview","agent":"","label":null,"task":null,"status":"completed",
           "started_ms":900,"finished_ms":1900,"duration_ms":1000,"last_intent":null,"last_ms":null,
           "has_transcript":false},
          {"id":"Later","status":"paused","started_ms":5}
         ]}
        """#)
        XCTAssertEqual(page.subagents, [
            TranscriptSubagent(id: "AppHeadReview", agent: "reviewer", label: "Review the app head",
                               task: "Target: app\nReview", status: .running, startedMs: 1000,
                               lastIntent: "Reading ChatView", lastMs: 1500, hasTranscript: true),
            TranscriptSubagent(id: "DaemonHeadReview", status: .completed, startedMs: 900,
                               finishedMs: 1900, durationMs: 1000),
            TranscriptSubagent(id: "Later", status: .unknown, startedMs: 5),
        ])
        XCTAssertEqual(page.subagents?.map(\.status.isRunning), [true, false, false])
        let without = try decodePage(#"{"type":"agent_transcript","entries":[],"before":null,"after":"a"}"#)
        XCTAssertNil(without.subagents)
    }

    func testModelThinkingLevelDecodesAndLabelsTheEffort() throws {
        func model(_ json: String) throws -> TranscriptModel {
            try JSONDecoder().decode(TranscriptModel.self, from: Data(json.utf8))
        }
        let plain = try model(#"{"provider":"anthropic","id":"claude-opus-5-5"}"#)
        XCTAssertNil(plain.thinkingLevel)
        XCTAssertFalse(plain.thinkingAuto)
        XCTAssertEqual(plain.label, "claude-opus-5-5")
        XCTAssertEqual(plain.accessibilityLabel, "Model: anthropic, claude-opus-5-5")

        let high = try model(#"{"provider":"anthropic","id":"claude-opus-5-5","thinking_level":"high"}"#)
        XCTAssertEqual(high, TranscriptModel(provider: "anthropic", id: "claude-opus-5-5", thinkingLevel: "high"))
        XCTAssertEqual(high.label, "claude-opus-5-5 · high")
        XCTAssertEqual(high.accessibilityLabel, "Model: anthropic, claude-opus-5-5, effort high")

        let resolved = try model(#"{"provider":"a","id":"m","thinking_level":"medium","thinking_auto":true}"#)
        XCTAssertTrue(resolved.thinkingAuto)
        XCTAssertEqual(resolved.label, "m · medium (auto)")
        XCTAssertEqual(resolved.accessibilityLabel, "Model: a, m, effort medium (auto)")

        let pending = try model(#"{"provider":"a","id":"m","thinking_auto":true}"#)
        XCTAssertEqual(pending.label, "m · auto")
        XCTAssertEqual(pending.accessibilityLabel, "Model: a, m, effort auto")
    }
}

final class AgentTranscriptClientTests: XCTestCase {

    func testTranscriptRequestCarriesTargetCursorAndClampedLimit() async throws {
        let transport = RecordingTransport(reply: #"{"id":"x","result":{"type":"agent_transcript","entries":[],"before":null,"after":"a"}}"#)
        let client = HerdrClient(transport: transport)
        _ = try await client.agentTranscript(target: "w1:p1", before: "b7", limit: 500)
        let (method, params) = try transport.last()
        XCTAssertEqual(method, "agent.transcript")
        XCTAssertEqual(params["target"] as? String, "w1:p1")
        XCTAssertEqual(params["before"] as? String, "b7")
        XCTAssertEqual(params["limit"] as? Int, 50)
        XCTAssertNil(params["after"])
    }

    func testSubagentTranscriptRequestCarriesTheSubagentAndItsRefusalIsTyped() async throws {
        let transport = RecordingTransport(reply: #"{"id":"x","result":{"type":"agent_transcript","entries":[],"before":null,"after":"a"}}"#)
        let client = HerdrClient(transport: transport)
        _ = try await client.agentTranscript(target: "w1:p1", subagent: "AppHeadReview")
        XCTAssertEqual(try transport.last().1["subagent"] as? String, "AppHeadReview")
        _ = try await client.agentTranscript(target: "w1:p1")
        XCTAssertNil(try transport.last().1["subagent"], "the agent's own page sends no subagent")

        let refusing = HerdrClient(transport: RecordingTransport.error(code: "subagent_not_found", message: "no"))
        do {
            _ = try await refusing.agentTranscript(target: "w1:p1", subagent: "Gone")
            XCTFail("subagent_not_found should throw")
        } catch {
            XCTAssertEqual(error as? AgentTranscriptError, .subagentNotFound)
        }
    }

    func testTranscriptRefusalsAreTyped() async {
        let cases: [(String, String, AgentTranscriptError)] = [
            ("agent_not_found", "no agent", .agentNotFound),
            ("transcript_unsupported", "not omp", .unsupported),
            ("transcript_unavailable", "missing", .unavailable),
            ("cursor_expired", "gone", .cursorExpired),
            ("invalid_request", "unknown variant `agent.transcript`, expected one of", .unsupported),
        ]
        for (code, message, expected) in cases {
            let client = HerdrClient(transport: RecordingTransport.error(code: code, message: message))
            do {
                _ = try await client.agentTranscript(target: "x")
                XCTFail("\(code) should throw")
            } catch {
                XCTAssertEqual(error as? AgentTranscriptError, expected, code)
            }
        }
    }

    func testAnswerSendsAskIDAndOptionAndDecodesStatus() async throws {
        let transport = RecordingTransport(reply: #"{"id":"x","result":{"type":"agent_answer","status":"sent_unconfirmed"}}"#)
        let client = HerdrClient(transport: transport)
        let status = try await client.agentAnswer(target: "w1:p1", askID: "call_9", option: "Not yet")
        XCTAssertEqual(status, .sentUnconfirmed)
        let (method, params) = try transport.last()
        XCTAssertEqual(method, "agent.answer")
        XCTAssertEqual(params["target"] as? String, "w1:p1")
        XCTAssertEqual(params["ask_id"] as? String, "call_9")
        XCTAssertEqual(params["option"] as? String, "Not yet")
    }

    func testAnswerRefusalKeepsTheServerCodeForTheTerminalFallback() async {
        let client = HerdrClient(transport: RecordingTransport.error(code: "ask_ui_not_found", message: "selector not on screen"))
        do {
            _ = try await client.agentAnswer(target: "w1:p1", askID: "a", option: "Yes")
            XCTFail("should throw")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "ask_ui_not_found")
            XCTAssertTrue(error.asksForTerminalAnswer)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertFalse(APIError(code: "ask_not_pending", message: "").asksForTerminalAnswer)
    }
}

// MARK: - Grouping

final class TranscriptGroupingTests: XCTestCase {
    private func e(_ id: String, _ ts: UInt64, _ kind: TranscriptEntry.Kind) -> TranscriptEntry {
        TranscriptEntry(id: id, tsMs: ts, kind: kind)
    }
    private func step(_ intent: String, _ status: TranscriptStepStatus = .ok) -> TranscriptEntry.Kind {
        .step(TranscriptStep(tool: "bash", intent: intent, status: status))
    }

    func testMidTaskReplySplitsWorkAndEachTurnStartsAtAUserEntry() {
        let turns = TranscriptGrouping.turns([
            e("u1", 0, .user(text: "Fix it", author: .owner)),
            e("t1", 1_000, .thinking(text: "First idea")),
            e("s1", 2_000, step("Reading the code")),
            e("t2", 3_000, .thinking(text: "  ")),
            e("r1", 4_000, .reply(text: "Found it, patching now.", final: false)),
            e("s2", 5_000, .step(TranscriptStep(tool: "edit", intent: "Patching", status: .ok))),
            e("s3", 65_000, step("Testing")),
            e("r2", 125_000, .reply(text: "Done.", final: true)),
            e("end1", 126_000, .turnEnd(status: .done, error: nil)),
            e("u2", 200_000, .user(text: "Thanks", author: .guest(name: "sam"))),
            e("r3", 201_000, .reply(text: "Any time.", final: true)),
        ])
        XCTAssertEqual(turns.map(\.id), ["u1", "u2"])
        XCTAssertEqual(turns[0].promptText, "Fix it")
        XCTAssertEqual(turns[1].promptAuthor, .guest(name: "sam"))

        let items = turns[0].items
        XCTAssertEqual(items.map(\.id), ["t1", "r1", "s2", "r2"])
        guard case .work(let first) = items[0], case .work(let second) = items[2] else {
            return XCTFail("expected work groups around the mid-task reply: \(items)")
        }
        // Empty thoughts are dropped; the steps keep omp's own intent.
        XCTAssertEqual(first.thoughts, ["First idea"])
        XCTAssertEqual(first.steps.map(\.intent), ["Reading the code"])
        XCTAssertEqual(second.steps.map(\.intent), ["Patching", "Testing"])
        // Each step row carries omp's tool name, which the chat draws before the intent.
        XCTAssertEqual(second.steps.map(\.tool), ["edit", "bash"])
        // A group's work lasts until whatever follows it.
        XCTAssertEqual(second.startMs, 5_000)
        XCTAssertEqual(second.endMs, 125_000)
        XCTAssertEqual(items[1], .reply(id: "r1", text: "Found it, patching now.", final: false))
        XCTAssertFalse(first.live || second.live)
    }

    func testRunningStepMarksOnlyTheNewestGroupLiveWhileWorking() {
        let entries = [
            e("u1", 0, .user(text: "Go", author: .owner)),
            e("s1", 1, step("Old", .running)),
            e("r1", 2, .reply(text: "Update", final: false)),
            e("s2", 3, step("Re-running the tests", .running)),
        ]
        let live = TranscriptGrouping.turns(entries, working: true)
        guard case .work(let old) = live[0].items[0], case .work(let newest) = live[0].items[2] else {
            return XCTFail("\(live)")
        }
        XCTAssertFalse(old.live)
        XCTAssertTrue(newest.live)
        XCTAssertEqual(newest.steps.last?.status, .running)

        let idle = TranscriptGrouping.turns(entries, working: false)
        guard case .work(let settled) = idle[0].items[2] else { return XCTFail() }
        XCTAssertFalse(settled.live)
    }

    func testOnlyTheNewestPlanOfATurnIsKeptWhereItArrived() {
        let turns = TranscriptGrouping.turns([
            e("u1", 0, .user(text: "Plan it", author: .owner)),
            e("p1", 1, .plan([TranscriptPlanItem(text: "A", done: false)])),
            e("r1", 2, .reply(text: "Starting", final: false)),
            e("p2", 3, .plan([TranscriptPlanItem(text: "A", done: true)])),
            e("u2", 4, .user(text: "Next", author: .owner)),
            e("p3", 5, .plan([TranscriptPlanItem(text: "B", done: false)])),
        ])
        XCTAssertEqual(turns[0].items.map(\.id), ["r1", "p2"])
        XCTAssertEqual(turns[1].items.map(\.id), ["p3"])
    }

    /// A host older than guest answers says `answerable: false` to a guest even for a
    /// question the buttons could answer; a multi-part or multi-select one is never answerable.
    func testPendingAskWithheldFromCallerOnlyForAnAnswerableShape() {
        let single = [TranscriptQuestion(question: "Merge?", options: ["Yes", "Not yet"])]
        XCTAssertTrue(TranscriptPendingAsk(id: "a", questions: single, answerable: false).isWithheldFromCaller)
        XCTAssertFalse(TranscriptPendingAsk(id: "a", questions: single, answerable: true).isWithheldFromCaller)
        for questions in [
            [TranscriptQuestion(question: "Pick", options: ["A", "B"], multi: true)],
            single + single,
            [TranscriptQuestion(question: "Name?", options: [])],
        ] {
            let ask = TranscriptPendingAsk(id: "a", questions: questions, answerable: false)
            XCTAssertFalse(ask.hasAnswerableShape)
            XCTAssertFalse(ask.isWithheldFromCaller)
        }
    }

    func testAnsweredAskStaysAnsweredAndPendingAskIsMarked() {
        let question = [TranscriptQuestion(question: "Merge?", options: ["Yes", "Not yet"])]
        let pending = TranscriptPendingAsk(id: "a2", questions: question, answerable: true)
        let turns = TranscriptGrouping.turns([
            e("u1", 0, .user(text: "Go", author: .owner)),
            e("a1", 1, .ask(TranscriptAsk(questions: question, answer: ["Yes"]))),
            e("a2", 2, .ask(TranscriptAsk(questions: question, answer: nil))),
        ], pendingAsk: pending)
        XCTAssertEqual(turns[0].items, [
            .ask(id: "a1", TranscriptAsk(questions: question, answer: ["Yes"]), pending: nil),
            .ask(id: "a2", TranscriptAsk(questions: question, answer: nil), pending: pending),
        ])
    }

    /// `pending_ask` one refresh behind an answer given elsewhere: the answered entry is the
    /// one card, with no live buttons.
    func testStalePendingAskForAnAnsweredEntryAddsNoSecondCard() {
        let question = [TranscriptQuestion(question: "Merge?", options: ["Yes", "Not yet"])]
        let stale = TranscriptPendingAsk(id: "a1", questions: question, answerable: true)
        let turns = TranscriptGrouping.turns([
            e("u1", 0, .user(text: "Go", author: .owner)),
            e("a1", 1, .ask(TranscriptAsk(questions: question, answer: ["Yes"]))),
        ], pendingAsk: stale)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].items, [.ask(id: "a1", TranscriptAsk(questions: question, answer: ["Yes"]), pending: nil)])
    }

    func testPendingAskWithoutItsEntryIsAppendedToTheLastTurn() {
        let pending = TranscriptPendingAsk(
            id: "a9", questions: [TranscriptQuestion(question: "Q?", options: ["A"])], answerable: false)
        let turns = TranscriptGrouping.turns([e("u1", 0, .user(text: "Go", author: .owner))], pendingAsk: pending)
        XCTAssertEqual(turns[0].items.map(\.id), ["a9"])
    }

    func testFailedTurnsShowAndSummariesOpenAPromptlessTurnAndUnknownIsSkipped() {
        let turns = TranscriptGrouping.turns([
            e("c0", 0, .summary(text: "Earlier messages were summarised")),
            e("r0", 1, .reply(text: "Continuing", final: false)),
            e("u1", 2, .user(text: "Go", author: .owner)),
            e("x1", 3, .unknown("hologram")),
            e("end", 4, .turnEnd(status: .aborted, error: nil)),
            e("c1", 5, .summary(text: "Earlier messages were summarised")),
            e("s1", 6, step("After compaction")),
        ])
        XCTAssertEqual(turns.map(\.id), ["c0", "u1", "c1"])
        XCTAssertNil(turns[0].prompt)
        XCTAssertEqual(turns[0].items.map(\.id), ["c0", "r0"])
        XCTAssertEqual(turns[1].items, [.turnFailed(id: "end", status: .aborted, error: nil)])
        XCTAssertEqual(turns[2].items.map(\.id), ["c1", "s1"])
    }
}

// MARK: - Store paging and live merge

@MainActor
final class TranscriptStoreTests: XCTestCase {

    private static func entry(_ id: String, _ kind: String = "reply", extra: String = #""text":"x","final":false"#) -> String {
        #"{"id":"\#(id)","ts_ms":1,"kind":"\#(kind)",\#(extra)}"#
    }

    private static func page(_ entries: [String], before: String? = nil, after: String = "a",
                             session: String = "s1", working: Bool = false, pendingAsk: String? = nil) -> String {
        let beforeJSON = before.map { "\"\($0)\"" } ?? "null"
        let workingJSON = working ? #"{"intent":"Testing","tool":"bash","since_ms":1}"# : "null"
        return #"{"id":"x","result":{"type":"agent_transcript","session_id":"\#(session)","entries":[\#(entries.joined(separator: ","))],"before":\#(beforeJSON),"after":"\#(after)","pending_ask":\#(pendingAsk ?? "null"),"working":\#(workingJSON)}}"#
    }

    /// Answers `agent.transcript` from a script keyed by which cursor the request carried.
    private func scripted(_ answer: @escaping (_ params: [String: Any]) -> String) -> (HerdrClient, RecordingTransport) {
        let transport = RecordingTransport { _, params in answer(params) }
        return (HerdrClient(transport: transport), transport)
    }

    func testLiveMetadataReplacesTheSnapshotWithoutOlderPagesRollingItBack() async throws {
        func metadata(_ page: String, model: String, plan: String) -> String {
            page.replacingOccurrences(of: #""result":{"#, with:
                #""result":{"model":{"provider":"test","id":"\#(model)"},"plan":\#(plan),"#)
        }
        var round = 0
        let oldPlan = Self.entry("old-plan", "plan", extra: #""items":[{"text":"Old task","done":false}]"#)
        let (client, _) = scripted { params in
            if params["before"] != nil {
                return metadata(Self.page([Self.entry("older")]), model: "old", plan: #"[{"text":"Old task","done":true}]"#)
            }
            defer { round += 1 }
            switch round {
            case 0: return metadata(Self.page([oldPlan], before: "older"), model: "first",
                                   plan: #"[{"text":"Ship","done":false,"status":"in_progress","phase":"Release"}]"#)
            case 1: return metadata(Self.page([], before: "older"), model: "selected",
                                   plan: #"[{"text":"Ship","done":false,"status":"blocked","phase":"Release","blocker":"Review"}]"#)
            default: return metadata(Self.page([]), model: "selected", plan: "[]")
            }
        }
        let store = TranscriptStore(target: "agent")
        await store.refresh(client: client)
        XCTAssertEqual(store.model?.id, "first")
        XCTAssertEqual(store.currentPlan.map(\.status), [.inProgress])
        await store.refresh(client: client)
        XCTAssertEqual(store.model?.id, "selected")
        XCTAssertEqual(store.currentPlan.map(\.status), [.blocked])
        XCTAssertEqual(store.currentPlan.first?.blocker, "Review")
        try await store.loadOlder(client: client)
        XCTAssertEqual(store.model?.id, "selected")
        XCTAssertEqual(store.currentPlan.map(\.status), [.blocked])
        await store.refresh(client: client)
        XCTAssertTrue(store.currentPlan.isEmpty, "an explicit empty snapshot must not revive an older plan")
    }

    func testSubagentsAreLiveMetadataThatOlderPagesNeverRollBack() async throws {
        func with(_ page: String, subagents: String) -> String {
            page.replacingOccurrences(of: #""result":{"#, with: #""result":{"subagents":\#(subagents),"#)
        }
        let running = #"{"id":"A","agent":"reviewer","label":"Review","status":"running","started_ms":10,"has_transcript":true}"#
        let finished = #"{"id":"A","agent":"reviewer","label":"Review","status":"completed","started_ms":10,"finished_ms":40,"duration_ms":30,"has_transcript":true}"#
        let second = #"{"id":"B","agent":"task","status":"running","started_ms":20,"last_intent":"Reading","last_ms":30}"#
        var round = 0
        let (client, _) = scripted { params in
            if params["before"] != nil {
                return with(Self.page([Self.entry("older")]), subagents: #"[{"id":"Old","status":"running","started_ms":1}]"#)
            }
            defer { round += 1 }
            switch round {
            case 0: return with(Self.page([Self.entry("r1")], before: "older"), subagents: "[\(running)]")
            case 1: return with(Self.page([], before: "older"), subagents: "[\(second),\(finished)]")
            default: return Self.page([])
            }
        }
        let store = TranscriptStore(target: "agent")
        var changes = 0
        store.onChange = { changes += 1 }
        await store.refresh(client: client)
        XCTAssertEqual(store.subagents.map(\.id), ["A"])
        XCTAssertEqual(store.subagents.first?.status, .running)
        changes = 0
        await store.refresh(client: client)
        XCTAssertEqual(store.subagents.map(\.id), ["B", "A"], "an after page replaces the list")
        XCTAssertEqual(store.subagents.map(\.status), [.running, .completed])
        XCTAssertEqual(store.subagents.last?.durationMs, 30)
        XCTAssertGreaterThan(changes, 0, "a subagent change alone must notify the view")
        try await store.loadOlder(client: client)
        XCTAssertEqual(store.subagents.map(\.id), ["B", "A"], "an older page must not roll the list back")
        await store.refresh(client: client)
        XCTAssertTrue(store.subagents.isEmpty, "a live page without subagents clears them")
    }

    func testSubagentStoreAsksForTheSubagentOnEveryPage() async throws {
        var round = 0
        let (client, transport) = scripted { params in
            if params["before"] != nil { return Self.page([Self.entry("older")]) }
            defer { round += 1 }
            return round == 0 ? Self.page([Self.entry("r1")], before: "older") : Self.page([])
        }
        let store = TranscriptStore(target: "w1:p1", subagent: "AppHeadReview")
        await store.refresh(client: client)
        XCTAssertEqual(try transport.last().params["subagent"] as? String, "AppHeadReview")
        await store.refresh(client: client)
        XCTAssertEqual(try transport.last().params["after"] as? String, "a")
        XCTAssertEqual(try transport.last().params["subagent"] as? String, "AppHeadReview")
        try await store.loadOlder(client: client)
        XCTAssertEqual(try transport.last().params["before"] as? String, "older")
        XCTAssertEqual(try transport.last().params["subagent"] as? String, "AppHeadReview")
    }

    func testOutgoingMessagesReconcileOncePerNewPromptAndAuthor() async {
        var round = 0
        let old = Self.entry("old", "user", extra: #""text":"Again","author":"owner""#)
        let guest = Self.entry("guest", "user", extra: #""text":"Again","author":"guest","author_name":"sam""#)
        let first = Self.entry("first", "user", extra: #""text":"Again","author":"owner""#)
        let second = Self.entry("second", "user", extra: #""text":"Again","author":"owner""#)
        // What the agent records: trimmed, and CRLF / CR as LF (pi trims a submitted prompt).
        let trimmed = Self.entry("trimmed", "user", extra: #""text":"hi","author":"owner""#)
        let pasted = Self.entry("pasted", "user", extra: #""text":"one\ntwo\nthree","author":"owner""#)
        let guestNewline = Self.entry("guest-newline", "user",
                                      extra: #""text":"Status?","author":"guest","author_name":"sam""#)
        let (client, _) = scripted { _ in
            defer { round += 1 }
            switch round {
            case 0: return Self.page([old])
            case 1: return Self.page([guest, first])
            case 2: return Self.page([first, second])
            default: return Self.page([trimmed, pasted, guestNewline])
            }
        }
        let store = TranscriptStore(target: "agent")
        await store.refresh(client: client)
        let firstID = store.stageOutgoing(text: "Again", author: .owner)
        let secondID = store.stageOutgoing(text: "Again", author: .owner)
        XCTAssertEqual(store.outbox.messages.map(\.id), [firstID, secondID])
        XCTAssertEqual(store.outbox.messages.map(\.state), [.sending, .sending])

        await store.refresh(client: client)
        XCTAssertEqual(store.outbox.messages.map(\.id), [secondID])
        XCTAssertEqual(store.outbox.recordedPromptIDs, ["first"])
        await store.refresh(client: client)
        XCTAssertTrue(store.outbox.messages.isEmpty)
        XCTAssertEqual(store.outbox.recordedPromptIDs, ["first", "second"])
        XCTAssertEqual(store.turns.map(\.id), ["old", "guest", "first", "second"])

        let spaced = store.stageOutgoing(text: "hi ", author: .owner)
        let crlf = store.stageOutgoing(text: "\r\none\r\ntwo\rthree", author: .owner)
        let guestSend = store.stageOutgoing(text: "Status?\n", author: .guest(name: "sam"))
        store.updateOutgoing(spaced, state: .submitted, wireText: "hi ")
        XCTAssertEqual(store.outbox.messages.map(\.id), [spaced, crlf, guestSend])
        await store.refresh(client: client)
        XCTAssertTrue(store.outbox.messages.isEmpty,
                      "a trailing space, CRLF and a guest's trailing newline must not leave a pending duplicate")
        XCTAssertEqual(store.outbox.recordedPromptIDs, ["first", "second", "trimmed", "pasted", "guest-newline"])
    }

    /// A placeholder never stays pending: a minute after its request returned, or once
    /// the agent finishes a turn for a later prompt, it reads "Not seen in chat". It still
    /// goes away if its prompt shows up after all.
    func testUnmatchedSendIsDemotedAfterAMinuteOrALaterTurn() async {
        var clock = Date(timeIntervalSince1970: 1_000)
        var pages: [String] = [
            Self.page([Self.entry("old", "user", extra: #""text":"Earlier","author":"owner""#)]),
            Self.page([]),
            Self.page([]),
            Self.page([Self.entry("late", "user", extra: #""text":"Ship it","author":"owner""#)]),
        ]
        let (client, _) = scripted { _ in pages.isEmpty ? Self.page([]) : pages.removeFirst() }
        let store = TranscriptStore(target: "agent", now: { clock })
        await store.refresh(client: client)

        let returned = store.stageOutgoing(text: "Ship it", author: .owner)
        let uploading = store.stageOutgoing(text: "With files", author: .owner)
        store.updateOutgoing(returned, state: .unconfirmed)
        clock += 59
        await store.refresh(client: client)
        XCTAssertEqual(store.outbox.messages.map(\.state), [.unconfirmed, .sending])
        clock += 1
        await store.refresh(client: client)
        XCTAssertEqual(store.outbox.messages.map(\.state), [.notSeen, .sending],
                       "a minute after the request returned it stops reading as pending; a send still in flight does not")
        await store.refresh(client: client)
        XCTAssertEqual(store.outbox.messages.map(\.id), [uploading], "a late record still removes the demoted placeholder")
        XCTAssertEqual(store.outbox.recordedPromptIDs, ["late"])
    }

    func testUnmatchedSendIsDemotedWhenTheAgentFinishesALaterTurn() async {
        let clock = Date(timeIntervalSince1970: 1_000)
        let end = #""status":"done""#
        var pages: [String] = [
            Self.page([Self.entry("old", "user", extra: #""text":"Earlier","author":"owner""#)]),
            // The turn that was running when the sends went out ends: they may be queued.
            Self.page([Self.entry("old-end", "turn_end", extra: end)]),
            // A prompt neither send matches is recorded, then its turn ends.
            Self.page([Self.entry("other", "user", extra: #""text":"Something else","author":"owner""#),
                       Self.entry("other-reply", "reply", extra: #""text":"Done.","final":true"#)]),
            Self.page([Self.entry("other-end", "turn_end", extra: end)]),
        ]
        let (client, _) = scripted { _ in pages.isEmpty ? Self.page([]) : pages.removeFirst() }
        let store = TranscriptStore(target: "agent", now: { clock })
        await store.refresh(client: client)
        let queued = store.stageOutgoing(text: "Deploy", author: .owner)
        store.updateOutgoing(queued, state: .submitted)
        await store.refresh(client: client)
        XCTAssertEqual(store.outbox.messages.map(\.state), [.submitted],
                       "the end of a turn that began before the send must not demote it")
        await store.refresh(client: client)
        XCTAssertEqual(store.outbox.messages.map(\.state), [.submitted])
        await store.refresh(client: client)
        XCTAssertEqual(store.outbox.messages.map(\.state), [.notSeen],
                       "the agent finished a later turn without recording this prompt")
    }

    func testFirstPageCannotConsumeAnOutgoingMessageBeforeItsSendBoundary() async {
        var round = 0
        let (client, _) = scripted { _ in
            defer { round += 1 }
            let id = round == 0 ? "old" : "new"
            return Self.page([Self.entry(id, "user", extra: #""text":"Again","author":"owner""#)])
        }
        let store = TranscriptStore(target: "agent")
        let id = store.stageOutgoing(text: "Again", author: .owner)
        let prepared = await store.prepareOutgoing(id, client: client)
        XCTAssertTrue(prepared)
        XCTAssertEqual(store.outbox.messages.map(\.id), [id])
        XCTAssertTrue(store.outbox.recordedPromptIDs.isEmpty)
        await store.refresh(client: client)
        XCTAssertTrue(store.outbox.messages.isEmpty)
        XCTAssertEqual(store.outbox.recordedPromptIDs, ["new"])
    }

    func testLoadingOlderHistoryDoesNotAcknowledgeANewSend() async throws {
        let old = Self.entry("older", "user", extra: #""text":"Again","author":"owner""#)
        let (client, _) = scripted { params in
            if params["before"] != nil { return Self.page([old]) }
            if params["after"] != nil { return Self.page([Self.entry("reply")]) }
            return Self.page([Self.entry("current")], before: "older-page")
        }
        let store = TranscriptStore(target: "agent")
        await store.refresh(client: client)
        let id = store.stageOutgoing(text: "Again", author: .owner)
        try await store.loadOlder(client: client)
        await store.refresh(client: client)
        XCTAssertEqual(store.outbox.messages.map(\.id), [id])
        XCTAssertEqual(store.outbox.messages.first?.state, .sending)
        XCTAssertTrue(store.outbox.recordedPromptIDs.isEmpty)
    }

    /// The change that shows an older page must already have "Load older" re-enabled;
    /// otherwise a reader (or UI test) that taps again as soon as the page appears hits a
    /// still-disabled button and the next page never loads.
    func testOlderPageIsPublishedWithLoadingAlreadyFinished() async throws {
        let (client, _) = scripted { params in
            switch params["before"] as? String {
            case "page-2": return Self.page([Self.entry("p2")], before: "page-3")
            case "page-3": return Self.page([Self.entry("p3")])
            default: return Self.page([Self.entry("p1")], before: "page-2")
            }
        }
        let store = TranscriptStore(target: "agent")
        await store.refresh(client: client)
        var loadingWhenPageAppeared: [Bool] = []
        store.onChange = {
            if store.entries.contains(where: { $0.id == "p2" }), loadingWhenPageAppeared.isEmpty {
                loadingWhenPageAppeared.append(store.loadingOlder)
            }
        }
        try await store.loadOlder(client: client)
        XCTAssertEqual(loadingWhenPageAppeared, [false])
        try await store.loadOlder(client: client)
        XCTAssertEqual(store.entries.map(\.id), ["p3", "p2", "p1"])
        XCTAssertFalse(store.hasOlder)
        XCTAssertFalse(store.loadingOlder)
    }

    func testRefusedAndPreviousSessionMessagesAreNotMatchedToOtherPrompts() throws {
        func page(_ id: String, session: String) throws -> AgentTranscriptPage {
            struct Envelope: Decodable { let result: AgentTranscriptPage }
            return try JSONDecoder().decode(Envelope.self, from: Data(Self.page([
                Self.entry(id, "user", extra: #""text":"Again","author":"owner""#)
            ], session: session).utf8)).result
        }
        let store = TranscriptStore(target: "agent")
        store.applyNewest(try page("old", session: "a"))
        let refused = store.stageOutgoing(text: "Again", author: .owner)
        store.updateOutgoing(refused, state: .notDelivered("Agent is asking a question."))
        store.mergeAfter(try page("other-device", session: "a"))
        XCTAssertEqual(store.outbox.messages.first?.state, .notDelivered("Agent is asking a question."))

        let uncertain = store.stageOutgoing(text: "Again", author: .owner)
        store.updateOutgoing(uncertain, state: .unconfirmed)
        store.applyNewest(try page("replacement", session: "b"))
        XCTAssertEqual(store.outbox.messages.first(where: { $0.id == uncertain })?.state, .previousSession)
        XCTAssertFalse(store.outbox.recordedPromptIDs.contains("replacement"))
        let current = store.stageOutgoing(text: "Again", author: .owner)
        store.mergeAfter(try page("current-session", session: "b"))
        XCTAssertFalse(store.outbox.messages.contains(where: { $0.id == current }))
        XCTAssertTrue(store.outbox.messages.contains(where: { $0.id == uncertain }))
        XCTAssertEqual(store.outbox.recordedPromptIDs, ["current-session"])
    }

    func testOlderPagesPrependWithoutDuplicatesAndStopAtTheStart() async throws {
        let (client, transport) = scripted { params in
            switch params["before"] as? String {
            case nil: return Self.page([Self.entry("u3", "user", extra: #""text":"c""#), Self.entry("r3")], before: "c2")
            // The older page overlaps the loaded one by an entry; it must not repeat.
            case "c2": return Self.page([Self.entry("u2", "user", extra: #""text":"b""#), Self.entry("r2"), Self.entry("u3", "user", extra: #""text":"c""#)], before: "c1")
            default: return Self.page([Self.entry("u1", "user", extra: #""text":"a""#)], before: nil)
            }
        }
        let store = TranscriptStore(target: "w1:p1")
        await store.refresh(client: client)
        XCTAssertEqual(store.entries.map(\.id), ["u3", "r3"])
        XCTAssertTrue(store.hasOlder)

        try await store.loadOlder(client: client)
        XCTAssertEqual(store.entries.map(\.id), ["u2", "r2", "u3", "r3"])
        try await store.loadOlder(client: client)
        XCTAssertEqual(store.entries.map(\.id), ["u1", "u2", "r2", "u3", "r3"])
        XCTAssertFalse(store.hasOlder)
        XCTAssertEqual(store.turns.map(\.id), ["u1", "u2", "u3"])

        // Nothing older: no request is made.
        let sent = transport.requestLines.count
        try await store.loadOlder(client: client)
        XCTAssertEqual(transport.requestLines.count, sent)
        // The newest page is a few turns, so a long session's chat draws at once; the reader
        // scrolls up for more, a full page at a time.
        XCTAssertEqual(transport.requests.compactMap { $0.params["limit"] as? Int }, [5, 20, 20])
    }

    func testNewestPageAsksForFiveTurnsAndOlderPagesForTwenty() async throws {
        let (client, transport) = scripted { params in
            params["before"] == nil
                ? Self.page([Self.entry("u2", "user", extra: #""text":"b""#)], before: "c1")
                : Self.page([Self.entry("u1", "user", extra: #""text":"a""#)])
        }
        let store = TranscriptStore(target: "w1:p1")
        await store.refresh(client: client)
        try await store.loadOlder(client: client)
        XCTAssertEqual(TranscriptStore.newestPageTurns, 5)
        XCTAssertEqual(transport.requests.map { $0.params["limit"] as? Int }, [5, 20])
        XCTAssertEqual(transport.requests.last?.params["before"] as? String, "c1")
    }

    func testARefreshThatBringsNothingNewDoesNotNotify() async {
        var round = 0
        let (client, _) = scripted { params in
            if params["after"] == nil {
                return Self.page([Self.entry("u1", "user", extra: #""text":"go""#), Self.entry("r1")], after: "a1")
            }
            round += 1
            // Round 1 is empty; round 2 re-sends the reply unchanged; round 3 changes it.
            switch round {
            case 1: return Self.page([], after: "a1")
            case 2: return Self.page([Self.entry("r1")], after: "a2")
            default: return Self.page([Self.entry("r1", extra: #""text":"y","final":true"#)], after: "a3")
            }
        }
        let store = TranscriptStore(target: "w1:p1")
        var changes = 0
        store.onChange = { changes += 1 }
        await store.refresh(client: client)
        XCTAssertEqual(changes, 1, "the first page is drawn")
        let turns = store.turns

        await store.refresh(client: client)
        XCTAssertEqual(changes, 1, "an empty refresh must not redraw the chat")
        await store.refresh(client: client)
        XCTAssertEqual(changes, 1, "re-sent, unchanged entries must not redraw the chat")
        XCTAssertEqual(store.turns, turns, "the turns are stable across refreshes that change nothing")

        await store.refresh(client: client)
        XCTAssertEqual(changes, 2, "a changed entry redraws")
        XCTAssertNotEqual(store.turns, turns)
    }

    func testAReloadThatBringsBackTheSamePageDoesNotNotify() throws {
        func page(_ text: String) throws -> AgentTranscriptPage {
            struct Envelope: Decodable { let result: AgentTranscriptPage }
            return try JSONDecoder().decode(Envelope.self, from: Data(Self.page([
                Self.entry("u1", "user", extra: #""text":"go""#),
                Self.entry("r1", extra: #""text":"\#(text)","final":true"#)
            ], before: "c1").utf8)).result
        }
        let store = TranscriptStore(target: "w1:p1")
        var changes = 0
        store.onChange = { changes += 1 }
        store.applyNewest(try page("done"))
        XCTAssertEqual(changes, 1)
        let turns = store.turns
        store.applyNewest(try page("done"))
        XCTAssertEqual(changes, 1, "the same page again must not redraw the chat")
        XCTAssertEqual(store.turns, turns)
        store.applyNewest(try page("changed"))
        XCTAssertEqual(changes, 2)
    }

    func testAfterRefreshReplacesChangedEntriesInPlaceAndAppendsNewOnes() async throws {
        let running = Self.entry("s1", "step", extra: #""tool":"bash","intent":"Testing","status":"running""#)
        let finished = Self.entry("s1", "step", extra: #""tool":"bash","intent":"Testing","status":"ok""#)
        var round = 0
        let (client, transport) = scripted { params in
            if params["after"] == nil {
                return Self.page([Self.entry("u1", "user", extra: #""text":"go""#), running], after: "a1", working: true)
            }
            round += 1
            // The step finished and a reply followed; the server re-sends the step.
            return round == 1
                ? Self.page([finished, Self.entry("r1", extra: #""text":"Done","final":true"#)], after: "a2")
                : Self.page([], after: "a2")
        }
        let store = TranscriptStore(target: "w1:p1")
        await store.refresh(client: client)
        XCTAssertTrue(store.isWorking)

        await store.refresh(client: client)
        XCTAssertEqual(transport.requests.last?.params["after"] as? String, "a1")
        XCTAssertEqual(store.entries.map(\.id), ["u1", "s1", "r1"])
        XCTAssertEqual(store.entries[1].kind, .step(TranscriptStep(tool: "bash", intent: "Testing", status: .ok)))
        XCTAssertFalse(store.isWorking)

        // An empty refresh keeps everything and advances to the newest cursor.
        await store.refresh(client: client)
        XCTAssertEqual(transport.requests.last?.params["after"] as? String, "a2")
        XCTAssertEqual(store.entries.map(\.id), ["u1", "s1", "r1"])
    }

    func testExpiredCursorOrNewSessionReloadsTheNewestPage() async {
        var newest = 0
        let (client, _) = scripted { params in
            if params["after"] == nil {
                newest += 1
                return newest == 1
                    ? Self.page([Self.entry("old")], after: "a1")
                    : Self.page([Self.entry("fresh")], after: "b1", session: newest == 2 ? "s1" : "s2")
            }
            if params["after"] as? String == "a1" {
                return RecordingTransport.errorReply(code: "cursor_expired", message: "gone")
            }
            return Self.page([Self.entry("other")], after: "c1", session: "s9")
        }
        let store = TranscriptStore(target: "w1:p1")
        await store.refresh(client: client)
        await store.refresh(client: client)
        XCTAssertEqual(store.entries.map(\.id), ["fresh"])
        // A refresh answering for a different session id means omp started over.
        await store.refresh(client: client)
        XCTAssertEqual(store.entries.map(\.id), ["fresh"])
        XCTAssertEqual(store.sessionID, "s2")
    }

    func testLocalAnswerHidesTheButtonsUntilTheServerReportsIt() async {
        let ask = Self.entry("a1", "ask", extra: #""questions":[{"question":"Merge?","options":["Yes","No"],"multi":false}]"#)
        let pending = #"{"id":"a1","questions":[{"question":"Merge?","options":["Yes","No"],"multi":false}],"answerable":true}"#
        let (client, _) = scripted { _ in Self.page([ask], pendingAsk: pending) }
        let store = TranscriptStore(target: "w1:p1")
        await store.refresh(client: client)
        guard case .ask(_, _, let before)? = store.turns.last?.items.last else { return XCTFail() }
        XCTAssertNotNil(before)

        store.noteAnswered(askID: "a1", option: "Yes")
        XCTAssertNil(store.pendingAsk)
        guard case .ask(_, let answered, let after)? = store.turns.last?.items.last else { return XCTFail() }
        XCTAssertNil(after)
        XCTAssertEqual(answered.answer, ["Yes"])

        // A refresh that still reports the question open keeps the answer sent from here.
        await store.refresh(client: client)
        guard case .ask(_, let kept, let again)? = store.turns.last?.items.last else { return XCTFail() }
        XCTAssertNil(again)
        XCTAssertEqual(kept.answer, ["Yes"])
    }

    func testFailedRefreshKeepsTheConversationAndRecordsTheError() async {
        var calls = 0
        let (client, _) = scripted { _ in
            calls += 1
            return calls == 1 ? Self.page([Self.entry("r1")], after: "a1")
                : RecordingTransport.errorReply(code: "transcript_unavailable", message: "missing")
        }
        let store = TranscriptStore(target: "w1:p1")
        await store.refresh(client: client)
        await store.refresh(client: client)
        XCTAssertEqual(store.entries.map(\.id), ["r1"])
        XCTAssertEqual(store.lastError as? AgentTranscriptError, .unavailable)
    }

    /// Replays agent.transcript responses captured from a real isolated server
    /// (herdr 071556a9) with a real omp producer (5fa7a6f3) and model-generated
    /// recaps. Proves the app reads the live wire shape, not only hand-written JSON.
    func testCapturedLiveServerRecapShowsClearsAndReplacesPerTurn() async throws {
        func fixture(_ name: String) throws -> String {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/live-recap-\(name).json")
            return try String(contentsOf: url, encoding: .utf8)
        }
        let replies = try ["transcript-turn1", "transcript-turn2-before-recap", "transcript-turn2"].map(fixture)
        var call = 0
        let (client, _) = scripted { _ in
            defer { call += 1 }
            return replies[min(call, replies.count - 1)]
        }
        let store = TranscriptStore(target: "w1:p1")

        await store.refresh(client: client)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.recap?.turnID, "0f44ffc7")
        XCTAssertEqual(store.recap?.text, "The typo fix in README.md has been completed successfully. "
            + "Next, verify the fix by reviewing the updated README.md for correctness.")

        await store.refresh(client: client)
        XCTAssertNil(store.lastError)
        XCTAssertNil(store.recap, "new work must clear the previous turn's recap")

        await store.refresh(client: client)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.recap?.turnID, "01c9d94d")
        XCTAssertTrue(store.recap?.text.hasPrefix("The task was to fix a typo in README.md and add") == true)
        let recapText = try XCTUnwrap(store.recap?.text)
        let entryTexts = store.entries.compactMap { entry -> String? in
            switch entry.kind {
            case let .user(text, _), let .reply(text, _), let .summary(text): text
            default: nil
            }
        }
        XCTAssertEqual(entryTexts.count, 4, "both real prompts and both real replies decode")
        XCTAssertFalse(entryTexts.contains(recapText), "the recap must not appear as a conversation entry")
    }
}
