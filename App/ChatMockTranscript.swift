#if DEBUG
import Foundation
import HerdrKit
import SwiftUI

/// The `chatview` mock's root: the Agents home over `ChatMockTransport`, with the omp agent
/// `herdr-app` blocked on a question. Each launch starts from the Settings default named by
/// `HERDR_MOCK_CHAT_OPENS_IN` (`chat` unless set); the column width starts from its default
/// in every mock run (`HerdrApp.init`).
struct ChatViewMockHome: View {
    private static let freshPreference: Void = {
        UserDefaults.standard.set(ProcessInfo.processInfo.environment["HERDR_MOCK_CHAT_OPENS_IN"] ?? ChatPreference.chat,
                                  forKey: ChatPreference.key)
    }()

    @State private var client: HerdrClient = {
        _ = ChatViewMockHome.freshPreference
        return HerdrClient(transport: ChatMockTransport())
    }()

    var body: some View {
        TerminalHomeView(client: client, onDisconnect: {}, onTrustHostKey: { _ in false },
                         livePaneIDs: [ChatMockTransport.paneID, "w9:p2", "w9:p3"])
    }
}

/// The `chatview` screenshot mock and UI-test host: a synthetic omp conversation served as
/// `agent.transcript` pages, the way herdr pages a session file (turns, newest page first,
/// `before` cursors, a pending question). Every word is made up for the mock.
///
/// One conversation per process for the owner (agent `herdr-app`) and one for the guest
/// (agent `llm-opt`, as a guest sees it: no notes, no step details). Both can be answered
/// through `agent.answer`; the guest's only on a host that lets guests answer
/// (`GuestMockTransport.ownerOnlyAnswers` withholds `answerable` from the guest).
final class ChatMockConversation: @unchecked Sendable {
    enum Audience { case owner, guest }

    static let owner = ChatMockConversation(audience: .owner)
    static let guest = ChatMockConversation(audience: .guest)

    /// `HERDR_MOCK_CHAT_ANSWER=<code>`: `agent.answer` refuses with that error code (the
    /// "Answer in Terminal" fallback); unset, it answers.
    static let answerRefusal = ProcessInfo.processInfo.environment["HERDR_MOCK_CHAT_ANSWER"]
    /// `HERDR_MOCK_CHAT_ANSWERED=<option>`: the owner's question starts answered, so the
    /// agent is not blocked on a menu and a reply goes out as a prompt (`agent.prompt`).
    private static let answeredAtLaunch = ProcessInfo.processInfo.environment["HERDR_MOCK_CHAT_ANSWERED"]

    let audience: Audience
    private let lock = NSLock()
    private var answered: String?
    /// omp's `details.answers` once the form (`ChatMockAskForm`) was answered.
    private var formAnswers: [[String: String]]?
    /// Prompts sent through `agent.prompt`, as the agent records them: trimmed.
    private var prompted: [(text: String, ms: UInt64)] = []

    private init(audience: Audience) {
        self.audience = audience
        answered = audience == .owner ? Self.answeredAtLaunch : nil
    }

    var askID: String { audience == .owner ? "call_ask_merge" : "call_ask_bench" }
    var question: String {
        audience == .owner ? "Merge #305 and update the servers?" : "Post these to the team bench sheet?"
    }
    var options: [String] {
        audience == .owner ? ["Yes, merge and deploy", "Not yet"] : ["Yes, post them", "No, keep them here"]
    }

    var isAnswered: Bool { lock.withLock { settled } }

    /// The question no longer blocks omp: answered, or (a form) ended unanswered. Under `lock`.
    private var settled: Bool {
        answered != nil || formAnswers != nil || (ChatMockAskForm.enabled && ChatMockAskForm.endedStatus != nil)
    }

    // MARK: Requests

    /// `agent.transcript`: the newest page, an older page (`before`), or a live refresh
    /// (`after`). Like herdr, an `after` page carries only what came since its cursor and
    /// re-sends the newest agent turn (its question may have been answered since), never
    /// older history: the client appends entries it has not seen at the tail, so older
    /// turns there would draw below the conversation.
    func transcript(id: String, params: [String: Any]) -> String {
        if let subagent = params["subagent"] as? String {
            return subagentTranscript(id: id, subagent: subagent)
        }
        let limit = max(1, min(params["limit"] as? Int ?? 20, 50))
        let (turns, sentCount) = lock.withLock { (buildTurns(), prompted.count) }
        let start: Int
        let end: Int
        let after = (params["before"] as? String) == nil ? params["after"] as? String : nil
        let isAfter = after != nil
        if let before = params["before"] as? String {
            guard before.hasPrefix("t"), let index = Int(before.dropFirst()), index <= turns.count else {
                return Self.error(id: id, code: "cursor_expired", message: "unknown cursor")
            }
            end = index
            start = max(0, end - limit)
        } else if let after {
            guard after.hasPrefix("a"), let seen = Int(after.dropFirst()), seen <= turns.count else {
                return Self.error(id: id, code: "cursor_expired", message: "unknown cursor")
            }
            end = turns.count
            // The sent prompts follow the agent's turns: the newest agent turn is the last
            // one before them.
            start = max(0, min(seen, turns.count - sentCount) - 1)
        } else {
            end = turns.count
            start = max(0, end - limit)
        }
        let entries = turns[start..<end].flatMap { $0 }
        var result: [String: Any] = [
            "type": "agent_transcript",
            "agent": audience == .owner ? "herdr-app" : "llm-opt",
            "pane_id": audience == .owner ? ChatMockTransport.paneID : GuestMockTransport.access.agentTarget,
            "session_id": "mock-session",
            "entries": entries,
            "before": !isAfter && start > 0 ? "t\(start)" : NSNull(),
            "after": "a\(turns.count)",
            "working": NSNull(),
            "pending_ask": NSNull(),
        ]
        if lock.withLock({ settled }) {
            result["working"] = ["intent": audience == .owner ? "Merging #305" : "Posting to the bench sheet",
                                 "tool": "bash",
                                 "since_ms": Self.today(16, 52)]
        } else if ChatMockAskForm.enabled {
            result["pending_ask"] = [
                "id": askID,
                "questions": ChatMockAskForm.questions,
                "answerable": false,
                "form": ChatMockAskForm.form,
                "form_answerable": ChatMockAskForm.answerable
                    && (audience == .owner || !GuestMockTransport.ownerOnlyAnswers),
            ]
        } else {
            result["pending_ask"] = [
                "id": askID,
                "questions": [["question": question, "options": options, "multi": false, "recommended": 0]],
                "answerable": audience == .owner || !GuestMockTransport.ownerOnlyAnswers,
            ]
        }
        if let subagents = subagents {
            result["subagents"] = subagents
        }
        return Self.encode(id: id, result: result)
    }

    // MARK: Subagents

    /// `HERDR_CHAT_UX_SUBAGENTS=1`: omp's `task` tool has two reviewers running and one
    /// render finished, ordered as herdr sends them (running first, newest first). A guest
    /// gets no assignment and no transcript to open.
    private var subagents: [[String: Any]]? {
        guard ProcessInfo.processInfo.environment["HERDR_CHAT_UX_SUBAGENTS"] == "1" else { return nil }
        let owner = audience == .owner
        let now = Self.launchMs
        func subagent(_ id: String, agent: String, label: String, status: String, startedAgo: UInt64,
                      finishedAgo: UInt64? = nil, intent: String? = nil) -> [String: Any] {
            // A nil field goes out as JSON null, as herdr sends it.
            let fields: [String: Any?] = [
                "id": id, "agent": agent, "label": label,
                "task": owner ? "\(label) for the chat round 3 changes." : nil,
                "status": status, "started_ms": now - startedAgo,
                "finished_ms": finishedAgo.map { now - $0 },
                "duration_ms": finishedAgo.map { startedAgo - $0 },
                "last_intent": intent, "last_ms": intent == nil ? nil : now - 5_000,
                "has_transcript": owner,
            ]
            return fields.mapValues { $0 ?? NSNull() }
        }
        return [
            subagent("DaemonHeadReview", agent: "reviewer", label: "Review the daemon head", status: "running",
                     startedAgo: 40_000, intent: "Running cargo test"),
            subagent("AppHeadReview", agent: "reviewer", label: "Review the app head", status: "running",
                     startedAgo: 125_000, intent: "Reading ChatView.swift"),
            subagent("MermaidRender", agent: "task", label: "Render the diagram", status: "completed",
                     startedAgo: 600_000, finishedAgo: 300_000),
        ]
    }

    /// When the mock launched: the subagents' times stay put across polls, as herdr's do.
    private static let launchMs = ms(Date())

    /// `agent.transcript` with `subagent`: that subagent's own conversation, one turn (its
    /// assignment and its answer so far). A guest is refused like a forged target.
    private func subagentTranscript(id: String, subagent: String) -> String {
        guard audience == .owner,
              let fixture = subagents?.first(where: { $0["id"] as? String == subagent }) else {
            return Self.error(id: id, code: "subagent_not_found", message: "no such subagent")
        }
        let started = fixture["started_ms"] as? UInt64 ?? Self.launchMs
        let result: [String: Any] = [
            "type": "agent_transcript",
            "agent": "herdr-app",
            "pane_id": ChatMockTransport.paneID,
            "session_id": "mock-subagent-\(subagent)",
            "entries": [
                Self.entry("\(subagent)-task", started, ["kind": "user",
                                                          "text": fixture["task"] as? String ?? subagent]),
                Self.entry("\(subagent)-reply", started + 2_000, ["kind": "reply", "final": true,
                                                                   "text": "\(subagent) fixture conversation."]),
            ],
            "before": NSNull(),
            "after": "a1",
            "working": NSNull(),
            "pending_ask": NSNull(),
            "model": ["provider": "fixture", "id": "fixture-subagent-model", "thinking_level": "medium"],
        ]
        return Self.encode(id: id, result: result)
    }

    /// `agent.answer`: records the choice; the next page shows it answered.
    func answer(id: String, params: [String: Any]) -> String {
        let option = params["option"] as? String ?? ""
        let ask = params["ask_id"] as? String ?? ""
        return lock.withLock {
            if let refusal = Self.answerRefusal {
                return Self.error(id: id, code: refusal, message: "mock refusal")
            }
            guard ask == askID, answered == nil else {
                return Self.error(id: id, code: "ask_not_pending", message: "no pending question with that id")
            }
            guard options.contains(option) else {
                return Self.error(id: id, code: "selection_mismatch", message: "not one of the options")
            }
            answered = option
            return Self.encode(id: id, result: ["type": "agent_answer", "status": "answered"])
        }
    }

    /// `agent.answer_form`: checks the values as herdr does and records omp's answers; the
    /// next page shows them.
    func answerForm(id: String, params: [String: Any]) -> String {
        let ask = params["ask_id"] as? String ?? ""
        let values = params["values"] as? [String: Any] ?? [:]
        return lock.withLock {
            if let refusal = ChatMockAskForm.refusal {
                let message = refusal == "ask_form_invalid" ? "form: that inbox is not an @lenscale.ai address" : "mock refusal"
                return Self.error(id: id, code: refusal, message: message)
            }
            guard ChatMockAskForm.enabled, ask == askID, !settled else {
                return Self.error(id: id, code: "ask_not_pending", message: "no pending question with that id")
            }
            switch ChatMockAskForm.answers(for: values) {
            case .failure(let refusal):
                return Self.error(id: id, code: refusal.code, message: refusal.message)
            case .success(let answers):
                formAnswers = answers
                return Self.encode(id: id, result: ["type": "ask_form_answered", "status": "answered", "answers": answers])
            }
        }
    }

    /// The ask entry: omp's old single question, or (`ChatMockAskForm`) its HTML form.
    private func askEntry() -> [String: Any] {
        guard ChatMockAskForm.enabled else {
            var ask: [String: Any] = ["kind": "ask", "questions": [[
                "question": question, "options": options, "multi": false, "recommended": 0,
            ]]]
            if let answered { ask["answer"] = [answered] }
            return ask
        }
        var ask: [String: Any] = ["kind": "ask", "questions": ChatMockAskForm.questions, "form": ChatMockAskForm.form]
        if let formAnswers {
            ask["form_answer"] = formAnswers
            ask["form_status"] = "answered"
            ask["answer"] = formAnswers.map { "\($0["question"] ?? ""): \($0["answer"] ?? "")" }
        } else if let status = ChatMockAskForm.endedStatus {
            ask["form_status"] = status
        }
        return ask
    }

    /// `agent.prompt` (owner): the agent submits the prompt and records it trimmed, as pi
    /// does, so the next page carries it as a new turn.
    func prompt(id: String, params: [String: Any]) -> String {
        let text = (params["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock { prompted.append((text: text, ms: Self.ms(Date()))) }
        return Self.encode(id: id, result: ["type": "agent_prompted", "delivery": "submitted"])
    }

    // MARK: The conversation

    /// Older filler turns first (so there is history to page in), then the mockup's turns.
    private func buildTurns() -> [[[String: Any]]] {
        let fillerCount = 40
        var turns: [[[String: Any]]] = (0..<fillerCount).map { index in
            let at = Self.daysAgo(fillerCount - index + 1, hour: 11, minute: 15)
            let n = index + 1
            return [
                Self.entry("f\(n)u", at, ["kind": "user", "text": "Synthetic question \(n): is check \(n) green?",
                                         "author": "owner"]),
                Self.entry("f\(n)s", at + 20_000, ["kind": "step", "tool": "bash", "intent": "Running check \(n)",
                                                   "status": "ok"]),
                Self.entry("f\(n)r", at + 60_000, ["kind": "reply", "text": "Check \(n) is green.", "final": true]),
                Self.entry("f\(n)e", at + 61_000, ["kind": "turn_end", "status": "done"]),
            ]
        }
        turns += audience == .owner ? ownerTurns() : guestTurns()
        for (index, sent) in prompted.enumerated() {
            turns.append([Self.entry("sent\(index)u", sent.ms, ["kind": "user", "text": sent.text, "author": "owner"])])
        }
        if audience == .owner, let origins = Self.origins {
            turns = turns.map { turn in turn.map { Self.marked($0, origins: origins) } }
        }
        return turns
    }

    /// `HERDR_MOCK_CHAT_ORIGINS` (owner): who started each turn, as a host with `turn_origin`
    /// reports it, for the Chat's up arrow (`chat-jump-previous-mine`). `some`: synthetic
    /// questions 38 and 40 and the CI question came from someone else (`origin: "other"`, as
    /// gitmoot's would) and 39 from a guest, so the newest page holds only the newest owner
    /// prompt; `none`: every prompt but the newest is someone else's. Unset: a host without
    /// turn origins (the ping does not advertise them).
    static let origins = ProcessInfo.processInfo.environment["HERDR_MOCK_CHAT_ORIGINS"]

    /// A user entry with the origin or author `origins` gives its turn; other entries as they are.
    private static func marked(_ entry: [String: Any], origins: String) -> [String: Any] {
        guard entry["kind"] as? String == "user", let id = entry["id"] as? String else { return entry }
        let turn = String(id.dropLast())
        var marked = entry
        switch origins {
        case "some":
            if ["f38", "f40", "o1"].contains(turn) { marked["origin"] = "other" }
            if turn == "f39" {
                marked["author"] = "guest"
                marked["author_name"] = "sam"
            }
        case "none":
            if turn != "o2", !turn.hasPrefix("sent") { marked["origin"] = "other" }
        default:
            break
        }
        return marked
    }

    private static let ownerStepIntents = [
        "Reading the scroll code in the terminal view", "Searching for the history cursor",
        "Reading the pane.history handler", "Writing the paging loop", "Running the unit tests",
        "Building the app for the simulator", "Running the scroll UI test", "Checking the gaps between pages",
    ]

    private func ownerTurns() -> [[[String: Any]]] {
        let ci = Self.today(14, 5)
        var first: [[String: Any]] = [
            Self.entry("o1u", ci, ["kind": "user", "text": "Is the herdr fork's CI running again?", "author": "owner"]),
            Self.entry("o1t", ci + 4_000, ["kind": "thinking",
                                           "text": "Check the Actions banner and the newest run, not the old queued one."]),
        ]
        for step in 0..<6 {
            first.append(Self.entry("o1s\(step)", ci + 10_000 + UInt64(step) * 20_000, [
                "kind": "step", "tool": "bash", "intent": ["Opening the fork's Actions page", "Reading the newest run",
                                                          "Checking each platform's job", "Finding the run from Oct 8",
                                                          "Cancelling the stuck run", "Confirming the queue is empty"][step],
                "status": "ok", "detail": "gh run list --limit 5",
            ]))
        }
        first.append(Self.entry("o1r", ci + 125_000, [
            "kind": "reply", "final": true,
            "text": "Yes. The first run since Oct 8 passed on **macOS, Windows, Linux and Nix**. I cancelled the stuck run from Oct 8, so nothing is queued now.",
        ]))
        first.append(Self.entry("o1e", ci + 126_000, ["kind": "turn_end", "status": "done"]))

        let scroll = Self.today(16, 12)
        var second: [[String: Any]] = [
            Self.entry("o2u", scroll, ["kind": "user", "author": "owner",
                                       "text": "Scrolling up in a terminal stops too early. Keep loading, like Gram."]),
            Self.entry("o2t", scroll + 5_000, ["kind": "thinking",
                                               "text": "The phone only gets the last 1,000 rows; the server keeps far more, so the app has to page. Each page should follow its row while the pane keeps writing."]),
        ]
        // 112 steps over 38 minutes.
        for step in 0..<112 {
            var entry: [String: Any] = ["kind": "step", "tool": "bash", "status": "ok",
                                        "intent": Self.ownerStepIntents[step % Self.ownerStepIntents.count]]
            if audience == .owner { entry["detail"] = "step \(step + 1) of the synthetic run" }
            second.append(Self.entry("o2s\(step)", scroll + 10_000 + UInt64(step) * 20_250, entry))
        }
        let noteAt = scroll + 2_290_000
        second.append(Self.entry("o2n", noteAt, [
            "kind": "note", "source": "gitmoot", "title": "Review approved · herdr #305", "from": "herdr-kimi-review",
            "body": "Approved. The cursor follows its row and the pages meet without gaps.",
        ]))
        second.append(Self.entry("o2p", noteAt + 1_000, ["kind": "plan", "items": [
            ["text": "Page history on the server", "done": true],
            ["text": "Load it in the app as you scroll", "done": true],
            ["text": "Test it end to end", "done": true],
            ["text": "Merge and deploy", "done": false],
        ]]))
        second.append(Self.entry("o2r", noteAt + 2_000, [
            "kind": "reply", "final": false,
            "text": "Done. Scrolling up now keeps loading older output, **500 lines at a time**, back to the very start.\n\n- Tested on a real server: 3,661 older lines, no gaps, with live output arriving between pages.\n- The app part is in `#477`; the server part is `#305`.",
        ]))
        second.append(Self.entry(askID, noteAt + 3_000, askEntry()))
        if answered != nil || formAnswers != nil {
            second.append(Self.entry("o2after", noteAt + 9_000, [
                "kind": "reply", "final": false, "text": "Merging #305 and updating the servers.",
            ]))
            second.append(Self.entry("o2merge", noteAt + 10_000, [
                "kind": "step", "tool": "bash", "intent": "Merging #305", "status": "running",
            ]))
        }
        return [first, second]
    }

    private func guestTurns() -> [[[String: Any]]] {
        let q4 = Self.daysAgo(1, hour: 18, minute: 40)
        var first: [[String: Any]] = [
            Self.entry("g1u", q4, ["kind": "user", "author": "guest", "author_name": "plotarmordev",
                                   "text": "What changed between the Q4 and Q5 builds?"]),
        ]
        for step in 0..<4 {
            first.append(Self.entry("g1s\(step)", q4 + 5_000 + UInt64(step) * 15_000, [
                "kind": "step", "tool": "read", "intent": "Reading the Q5 changelog", "status": "ok",
            ]))
        }
        first.append(Self.entry("g1r", q4 + 70_000, [
            "kind": "reply", "final": true,
            "text": "Q5 switches the attention kernel to the fused path and drops the extra KV copy. Decode should be faster; prefill about the same.",
        ]))
        first.append(Self.entry("g1e", q4 + 71_000, ["kind": "turn_end", "status": "done"]))

        let bench = Self.today(10, 2)
        var second: [[String: Any]] = [
            Self.entry("g2u", bench, ["kind": "user", "author": "guest", "author_name": "plotarmordev",
                                      "text": "Can you rerun the TensorFold bench against our Q5 build and send me the table?"]),
            Self.entry("g2t", bench + 3_000, ["kind": "thinking",
                                              "text": "Q5 needs the warm-up pass first, or decode looks slower than it is."]),
        ]
        for step in 0..<14 {
            second.append(Self.entry("g2s\(step)", bench + 6_000 + UInt64(step) * 25_000, [
                "kind": "step", "tool": "bash", "intent": "Running the TensorFold bench", "status": "ok",
            ]))
        }
        second.append(Self.entry("g2r", bench + 362_000, [
            "kind": "reply", "final": false,
            "text": "Here are the Q5 numbers against the last baseline:\n\n| Metric | Q5 | Change |\n|---|---|---|\n| Decode | 41.2 tok/s | +36% |\n| Prefill | 1,180 tok/s | +4% |\n\nFull results are in `results/tensorfold-q5.md`.",
        ]))
        second.append(Self.entry(askID, bench + 363_000, askEntry()))
        if answered != nil || formAnswers != nil {
            second.append(Self.entry("g2post", bench + 370_000, [
                "kind": "step", "tool": "bash", "intent": "Posting to the bench sheet", "status": "running",
            ]))
        }
        return [first, second]
    }

    // MARK: Helpers

    private static func entry(_ id: String, _ ms: UInt64, _ fields: [String: Any]) -> [String: Any] {
        var entry = fields
        entry["id"] = id
        entry["ts_ms"] = ms
        return entry
    }

    private static func today(_ hour: Int, _ minute: Int) -> UInt64 {
        let now = MockClock.pinned ?? Date()
        return ms(Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now)
    }

    private static func daysAgo(_ days: Int, hour: Int, minute: Int) -> UInt64 {
        let now = MockClock.pinned ?? Date()
        let day = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        return ms(Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day)
    }

    private static func ms(_ date: Date) -> UInt64 { UInt64(max(date.timeIntervalSince1970, 0) * 1000) }

    static func encode(id: String, result: [String: Any]) -> String {
        let object: [String: Any] = ["id": id, "result": result]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func error(id: String, code: String, message: String) -> String {
        encode(id: id, result: [:]).replacingOccurrences(
            of: #""result":{}"#, with: #""error":{"code":"\#(code)","message":"\#(message)"}"#)
    }

    static func requestObject(_ line: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
    }
}

/// The owner side of the `chatview` mock: the Agents home with an omp agent (`herdr-app`)
/// waiting on a question, on a server that advertises `agent_transcript` and `agent_answer`.
/// Everything else falls through to `MockTransport`.
struct ChatMockTransport: HerdrTransport {
    static let paneID = "w9:p1"
    private let base = MockTransport()

    /// `HERDR_MOCK_CHAT_STARTUP=code,code,…`: herdr-app's first `agent.transcript` calls answer
    /// these error codes in order, then the conversation. A just-started omp agent answers
    /// `transcript_unsupported` until omp's integration reports a session (#604).
    private static let startupErrors = ScriptedCodes(
        ProcessInfo.processInfo.environment["HERDR_MOCK_CHAT_STARTUP"]?
            .split(separator: ",").map(String.init) ?? [])

    /// `HERDR_MOCK_CHAT_OLDER_DELAY=<seconds>`: older pages (`before`) answer that much later,
    /// so a test can act while one is still on the way.
    private static let olderDelay = ProcessInfo.processInfo.environment["HERDR_MOCK_CHAT_OLDER_DELAY"]
        .flatMap(Double.init) ?? 0

    private final class ScriptedCodes: @unchecked Sendable {
        private let lock = NSLock()
        private var codes: [String]
        init(_ codes: [String]) { self.codes = codes }
        func next() -> String? {
            lock.lock(); defer { lock.unlock() }
            return codes.isEmpty ? nil : codes.removeFirst()
        }
    }

    func roundTrip(_ requestLine: String) async throws -> String {
        if let response = await ChatUXSmoke.reply(requestLine) { return response }
        let request = ChatMockConversation.requestObject(requestLine)
        let id = request["id"] as? String ?? "mock"
        let params = request["params"] as? [String: Any] ?? [:]
        switch request["method"] as? String {
        case "ping":
            // A host that keeps turn origins whenever the conversation carries them.
            let turnOrigin = ChatMockConversation.origins == nil ? "" : #","turn_origin":true"#
            return #"{"id":"\#(id)","result":{"type":"pong","version":"0.9.4","protocol":22,"capabilities":{"agent_transcript":true,"agent_answer":true,"agent_avatar":true\#(turnOrigin)\#(ChatMockAskForm.capability)}}}"#
        case "agent.list":
            return AgentAvatarMockServer.overlay(#"{"id":"\#(id)","result":{"type":"agent_list","agents":[\#(Self.agentsJSON)]}}"#)
        case "agent.transcript":
            let target = params["target"] as? String
            guard target == Self.paneID || target == "herdr-app" else {
                return ChatMockConversation.error(id: id, code: "transcript_unsupported", message: "not an omp agent")
            }
            if let code = Self.startupErrors.next() {
                return ChatMockConversation.error(id: id, code: code, message: "agent still starting")
            }
            if Self.olderDelay > 0, params["before"] is String {
                try? await Task.sleep(for: .seconds(Self.olderDelay))
            }
            return ChatMockConversation.owner.transcript(id: id, params: params)
        case "agent.answer":
            return ChatMockConversation.owner.answer(id: id, params: params)
        case "agent.answer_form":
            return ChatMockConversation.owner.answerForm(id: id, params: params)
        case "agent.prompt":
            return ChatMockConversation.owner.prompt(id: id, params: params)
        default:
            return try await base.roundTrip(requestLine)
        }
    }

    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        base.stream(requestLine)
    }

    /// `HERDR_MOCK_STILL=1`: no agent reads working. A working row's spinner animates
    /// forever, which keeps XCUITest from ever seeing the app idle.
    private static let still = ProcessInfo.processInfo.environment["HERDR_MOCK_STILL"] == "1"

    /// herdr-app (omp, waiting on the question; working once answered), a Claude agent and a
    /// second omp agent, as in the iPad mockup's sidebar.
    private static var agentsJSON: String {
        let working = still ? "idle" : "working"
        let status = ChatMockConversation.owner.isAnswered ? working : "blocked"
        return [
            #"{"pane_id":"\#(paneID)","name":"herdr-app","agent":"omp","agent_status":"\#(status)","cwd":"/root/herdr","terminal_title_stripped":"Merge #305 and update the servers?"}"#,
            #"{"pane_id":"w9:p2","terminal_id":"t-keephair","name":"keephair","avatar":{"style":"mascot","mascot":"cub","sha256":null,"updated_unix_ms":1723041000000},"agent":"claude","agent_status":"\#(working)","cwd":"/root/keephair-repo","terminal_title_stripped":"Running the iPad tests"}"#,
            #"{"pane_id":"w9:p3","name":"llm-opt","agent":"omp","agent_status":"done","cwd":"/root/llm-opt","terminal_title_stripped":"Bench results posted"}"#,
        ].joined(separator: ",")
    }
}
#endif
