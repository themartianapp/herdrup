#if DEBUG
import Foundation

/// `HERDR_MOCK_TOPICS=1`: the `chatview` (owner) and guest mocks' omp agent serves topics, as a
/// herdr with `agent_topics` does (jerryfane/herdr#475): `agent.topics.list/new/send/close/
/// reopen/rename` and `agent.transcript` with `topic`. Unset, the pong does not advertise
/// `agent_topics`, so the page must show no Topics at all. Every word is made up for the mock.
///
/// One board per process for the owner (`herdr-app`) and one for the guest (`llm-opt`).
final class TopicsMock: @unchecked Sendable {
    static let enabled = ProcessInfo.processInfo.environment["HERDR_MOCK_TOPICS"] != nil
    /// `HERDR_MOCK_TOPICS_UNREACHABLE=1`: after the first list, every list call answers
    /// `topics_unreachable`, so the view keeps its last list and says the agent can't be reached.
    private static let goesUnreachable = ProcessInfo.processInfo.environment["HERDR_MOCK_TOPICS_UNREACHABLE"] != nil
    /// `HERDR_MOCK_TOPICS_FAIL_FIRST=<n>`: the first `n` list calls answer `topics_unreachable`
    /// (an agent that offers its topics only a moment later), so discovery has to retry.
    private static let failsFirst = ProcessInfo.processInfo.environment["HERDR_MOCK_TOPICS_FAIL_FIRST"]
        .flatMap(Int.init) ?? 0
    /// `HERDR_MOCK_TOPICS_GONE_AT=<n>[,<n>…]`: those list calls (counted from 1) answer
    /// `agent_not_found`, as an agent that restarts and leaves its pane without one for a moment
    /// (herdrup#777).
    private static let goneAt = Set((ProcessInfo.processInfo.environment["HERDR_MOCK_TOPICS_GONE_AT"] ?? "")
        .split(separator: ",").compactMap { Int($0) })
    /// `HERDR_MOCK_TOPICS_SEND_DELAY=<seconds>`: `agent.topics.send` answers that much later, and
    /// a send to a running topic is `queued`, so its receipt can land after the reader moved on.
    private static let sendDelay = ProcessInfo.processInfo.environment["HERDR_MOCK_TOPICS_SEND_DELAY"]
        .flatMap(Double.init) ?? 0

    static let owner = TopicsMock(agent: "herdr-app", paneID: "w9:p1", readerAuthor: ["author": "owner"])
    static let guest = TopicsMock(agent: "llm-opt", paneID: "w1-3",
                                  readerAuthor: ["author": "guest",
                                                 "author_name": GuestMockTransport.access.guestName])

    /// `HERDR_MOCK_TOPICS_SUGGEST=1`: the pong advertises `agent_topic_suggestions`, the list
    /// carries `suggestions`, the Inbox opens with one open suggestion, and Organise proposes
    /// three topics. Accept and dismiss work for the owner and the guest.
    static let suggests = ProcessInfo.processInfo.environment["HERDR_MOCK_TOPICS_SUGGEST"] != nil
    /// `HERDR_MOCK_TOPICS_SWITCH=1`: the pong advertises `agent_topics_switch`, herdr-app lists
    /// `topics_enabled` (off at launch), and `agent.topics.set_enabled` flips it (owner only).
    static let switchable = ProcessInfo.processInfo.environment["HERDR_MOCK_TOPICS_SWITCH"] != nil
    /// `HERDR_MOCK_TOPICS_SUGGEST_LIST_ONLY=1`: open suggestions are in `agent.topics.list` but
    /// not yet in the Inbox's transcript, as while the Inbox's turn is still running.
    static let listOnly = ProcessInfo.processInfo.environment["HERDR_MOCK_TOPICS_SUGGEST_LIST_ONLY"] != nil
    /// `HERDR_MOCK_TOPICS_ACCEPT_REVERTS=1`: `accept_suggestion` answers accepted, but the topic
    /// never starts, so the suggestion stays open in the list (and transcript), as omp puts it
    /// back when a seeded topic's start fails.
    static let acceptReverts = ProcessInfo.processInfo.environment["HERDR_MOCK_TOPICS_ACCEPT_REVERTS"] != nil
    /// `HERDR_MOCK_TOPICS_SUGGEST_AFTER=<seconds>`: the list carries no open suggestion until
    /// that long after the mock starts, as an agent that suggests a topic while the reader is
    /// already in its Inbox.
    private static let suggestAfter = ProcessInfo.processInfo.environment["HERDR_MOCK_TOPICS_SUGGEST_AFTER"]
        .flatMap(Double.init) ?? 0
    /// When the list starts carrying open suggestions (`suggestAfter`).
    private let suggestionsFrom = Date().addingTimeInterval(TopicsMock.suggestAfter)

    private struct Suggestion {
        let id: String
        let title: String
        let reason: String
        let messageIDs: [String]
        let createdMs: UInt64
        var state = "open"
        var topicID: String?
        var by: String?
    }

    /// `HERDR_MOCK_TOPICS_NO_TRANSCRIPT_TOPIC=1`: a server that lists topics but does not
    /// advertise `agent_transcript_topic`, so the app must not ask for a topic's transcript.
    private static let transcriptTopic = ProcessInfo.processInfo.environment["HERDR_MOCK_TOPICS_NO_TRANSCRIPT_TOPIC"] == nil

    /// The pong's capabilities, after the other capabilities: topics, and `topic` honoured on
    /// `agent.transcript` unless `HERDR_MOCK_TOPICS_NO_TRANSCRIPT_TOPIC`.
    static var capability: String {
        guard enabled else { return "" }
        let switchCapability = switchable ? #","agent_topics_switch":true"# : ""
        let suggestCapability = suggests ? #","agent_topic_suggestions":true"# : ""
        let base = transcriptTopic ? #","agent_topics":true,"agent_transcript_topic":true"# : #","agent_topics":true"#
        return base + switchCapability + suggestCapability
    }

    /// Who wrote a message: the owner (the written history), the one reading this mock (the
    /// owner, or the guest under its name), or the topic itself.
    private enum Speaker { case owner, reader, agent }

    private struct Topic {
        let id: String
        var title: String
        var state: String
        let createdMs: UInt64
        var lastMs: UInt64
        var lastActivity: String?
        /// The conversation, oldest first.
        var messages: [(from: Speaker, text: String, ms: UInt64)]
    }

    private let agent: String
    private let paneID: String
    /// The transcript's author fields for the reader's own prompts.
    private let readerAuthor: [String: String]
    private let lock = NSLock()
    private var topics: [Topic]
    private var created = 0
    private var listCalls = 0
    /// The agent's topic suggestions, every state (`HERDR_MOCK_TOPICS_SUGGEST`).
    private var suggestions: [Suggestion] = []
    /// Organise ran: a second one answers `organise_running`.
    private var organised = false
    /// The Topics switch (`HERDR_MOCK_TOPICS_SWITCH`), off at launch.
    private var topicsEnabled = false
    /// `HERDR_MOCK_TOPICS_TRANSCRIPT_STARTUP=<n>`: the first `n` topic transcript calls answer
    /// `transcript_unsupported`, as a topic whose session is still starting.
    private var startupRefusals = ProcessInfo.processInfo.environment["HERDR_MOCK_TOPICS_TRANSCRIPT_STARTUP"]
        .flatMap(Int.init) ?? 0

    private init(agent: String, paneID: String, readerAuthor: [String: String]) {
        self.agent = agent
        self.paneID = paneID
        self.readerAuthor = readerAuthor
        if Self.suggests { suggestions = [Self.openingSuggestion(guest: readerAuthor["author"] == "guest")] }
        let now = UInt64(max(Date().timeIntervalSince1970, 0) * 1000)
        let hour: UInt64 = 3_600_000
        topics = [
            Topic(id: "t-diokan", title: "Diokan term sheet", state: "running", createdMs: now - 30 * hour,
                  lastMs: now - 60_000, lastActivity: "Covenant headroom at 1.6x leaves room for the second draw.",
                  messages: [(.owner, "Draft the term sheet comparison for Diokan.", now - 30 * hour),
                             (.agent, "Two lenders fit; the covenant headroom is 1.6x on the base case.", now - 29 * hour)]),
            Topic(id: "t-board", title: "Q4 board pack", state: "idle", createdMs: now - 80 * hour,
                  lastMs: now - 50 * hour, lastActivity: "Liquidity page drafted; waiting on the November actuals.",
                  messages: [(.owner, "Start the Q4 board pack with the liquidity page.", now - 80 * hour),
                             (.agent, "Liquidity page drafted; waiting on the November actuals.", now - 50 * hour)]),
            Topic(id: "t-nippon", title: "Nippon data room checklist", state: "closed", createdMs: now - 600 * hour,
                  lastMs: now - 500 * hour, lastActivity: "41 of 57 items in; legal folder still empty.",
                  messages: [(.owner, "Track the Nippon data room.", now - 600 * hour),
                             (.agent, "41 of 57 items in; legal folder still empty.", now - 500 * hour)]),
        ]
    }

    private static func now() -> UInt64 { UInt64(max(Date().timeIntervalSince1970, 0) * 1000) }

    /// Answers one `agent.topics.*` request, or nil for any other method.
    func reply(method: String, id: String, params: [String: Any]) async -> String? {
        guard Self.enabled, method.hasPrefix("agent.topics.") else { return nil }
        if method == "agent.topics.send", Self.sendDelay > 0 {
            try? await Task.sleep(for: .seconds(Self.sendDelay))
        }
        return answer(method: method, id: id, params: params)
    }

    private func answer(method: String, id: String, params: [String: Any]) -> String {
        guard params["target"] as? String == paneID || params["target"] as? String == agent else {
            return ChatMockConversation.error(id: id, code: "agent_not_found", message: "no such agent")
        }
        return lock.withLock { () -> String in
            let topicID = params["topic_id"] as? String ?? ""
            switch method {
            case "agent.topics.list":
                listCalls += 1
                if Self.goneAt.contains(listCalls) {
                    return ChatMockConversation.error(id: id, code: "agent_not_found", message: "no such agent")
                }
                if (Self.goesUnreachable && listCalls > 1) || listCalls <= Self.failsFirst {
                    return ChatMockConversation.error(id: id, code: "topics_unreachable",
                                                      message: "the agent has not offered its topics")
                }
                var result: [String: Any] = [
                    "type": "agent_topics", "agent": agent, "pane_id": paneID,
                    "topics": topics.map { topic -> [String: Any] in
                        [
                            "topic_id": topic.id, "title": topic.title, "state": topic.state,
                            "turns": topic.messages.filter { $0.from != .agent }.count, "queued": 0,
                            "created_unix_ms": topic.createdMs, "last_activity_unix_ms": topic.lastMs,
                            "last_activity": topic.lastActivity ?? NSNull(),
                        ]
                    },
                ]
                if Self.suggests {
                    let shown = Date() >= suggestionsFrom ? suggestions : []
                    result["suggestions"] = shown.filter { $0.state == "open" }.map { suggestion -> [String: Any] in
                        ["suggestion_id": suggestion.id, "title": suggestion.title, "reason": suggestion.reason,
                         "message_ids": suggestion.messageIDs, "created_unix_ms": suggestion.createdMs]
                    }
                }
                return ChatMockConversation.encode(id: id, result: result)
            case "agent.topics.new":
                let title = params["title"] as? String ?? ""
                let message = params["message"] as? String ?? ""
                guard !title.isEmpty, !message.isEmpty else {
                    return ChatMockConversation.error(id: id, code: "invalid_params", message: "title and message")
                }
                created += 1
                let newID = "t-new-\(created)"
                let now = Self.now()
                topics.append(Topic(id: newID, title: title, state: "running", createdMs: now, lastMs: now,
                                    lastActivity: nil, messages: [(.reader, message, now)]))
                return ChatMockConversation.encode(id: id, result: [
                    "type": "agent_topic_created", "agent": agent, "pane_id": paneID, "topic_id": newID])
            case "agent.topics.send":
                guard let index = topics.firstIndex(where: { $0.id == topicID }) else {
                    return ChatMockConversation.error(id: id, code: "topic_not_found", message: "no such topic")
                }
                let now = Self.now()
                let running = topics[index].state == "running"
                topics[index].messages.append((.reader, params["message"] as? String ?? "", now))
                topics[index].lastMs = now
                return ChatMockConversation.encode(id: id, result: [
                    "type": "agent_topic_sent", "agent": agent, "pane_id": paneID, "topic_id": topicID,
                    "mode": running ? (Self.sendDelay > 0 ? "queued" : "steered") : "turn"])
            case "agent.topics.close", "agent.topics.reopen", "agent.topics.rename":
                guard let index = topics.firstIndex(where: { $0.id == topicID }) else {
                    return ChatMockConversation.error(id: id, code: "topic_not_found", message: "no such topic")
                }
                switch method {
                case "agent.topics.close": topics[index].state = "closed"
                case "agent.topics.reopen": topics[index].state = "idle"
                default: topics[index].title = params["title"] as? String ?? topics[index].title
                }
                return ChatMockConversation.encode(id: id, result: [
                    "type": "agent_topic_updated", "agent": agent, "pane_id": paneID, "topic_id": topicID])
            case "agent.topics.accept_suggestion", "agent.topics.dismiss_suggestion":
                guard Self.suggests else {
                    return ChatMockConversation.error(id: id, code: "topics_unsupported", message: "no suggestions")
                }
                let suggestionID = params["suggestion_id"] as? String ?? ""
                guard let index = suggestions.firstIndex(where: { $0.id == suggestionID }) else {
                    return ChatMockConversation.error(id: id, code: "suggestion_not_found", message: "no such suggestion")
                }
                let by = readerAuthor["author_name"] ?? "owner"
                if method == "agent.topics.dismiss_suggestion" {
                    if suggestions[index].state == "accepted" {
                        return ChatMockConversation.error(id: id, code: "already_accepted", message: "already started")
                    }
                    let before = suggestions[index].state == "dismissed"
                    suggestions[index].state = "dismissed"
                    suggestions[index].by = by
                    return ChatMockConversation.encode(id: id, result: [
                        "type": "agent_topic_suggestion_dismissed", "agent": agent, "pane_id": paneID,
                        "suggestion_id": suggestionID, "already_dismissed": before])
                }
                if let topicID = suggestions[index].topicID {
                    return ChatMockConversation.encode(id: id, result: [
                        "type": "agent_topic_suggestion_accepted", "agent": agent, "pane_id": paneID,
                        "suggestion_id": suggestionID, "topic_id": topicID, "already_accepted": true])
                }
                if Self.acceptReverts {
                    return ChatMockConversation.encode(id: id, result: [
                        "type": "agent_topic_suggestion_accepted", "agent": agent, "pane_id": paneID,
                        "suggestion_id": suggestionID, "topic_id": "t-failed", "already_accepted": false])
                }
                // The topic starts with the messages the agent picked (copied, as omp seeds it).
                created += 1
                let newID = "t-sug-\(created)"
                let now = Self.now()
                let suggestion = suggestions[index]
                // While omp writes the seed summary the new topic is `starting`.
                topics.append(Topic(id: newID, title: suggestion.title, state: "starting", createdMs: now, lastMs: now,
                                    lastActivity: suggestion.reason,
                                    messages: [(.owner, "\(suggestion.messageIDs.count) earlier messages from the Inbox.", now),
                                               (.agent, suggestion.reason, now + 1)]))
                suggestions[index].state = "accepted"
                suggestions[index].topicID = newID
                suggestions[index].by = by
                return ChatMockConversation.encode(id: id, result: [
                    "type": "agent_topic_suggestion_accepted", "agent": agent, "pane_id": paneID,
                    "suggestion_id": suggestionID, "topic_id": newID, "already_accepted": false])
            case "agent.topics.organise":
                guard Self.suggests else {
                    return ChatMockConversation.error(id: id, code: "topics_unsupported", message: "no suggestions")
                }
                if organised {
                    return ChatMockConversation.error(id: id, code: "organise_running", message: "already organising")
                }
                organised = true
                // The review turn's proposals, as omp writes them (here at once).
                let now = Self.now()
                suggestions += Self.organiseProposals(audience: readerAuthor["author"] == "guest").map {
                    Suggestion(id: $0.id, title: $0.title, reason: $0.reason, messageIDs: $0.ids, createdMs: now)
                }
                return ChatMockConversation.encode(id: id, result: [
                    "type": "agent_topics_organise_started", "agent": agent, "pane_id": paneID, "queued": false])
            case "agent.topics.set_enabled":
                guard Self.switchable, readerAuthor["author"] != "guest" else {
                    return ChatMockConversation.error(id: id, code: "guest_forbidden", message: "owner only")
                }
                let enabled = params["enabled"] as? Bool ?? false
                let changed = enabled != topicsEnabled
                topicsEnabled = enabled
                return ChatMockConversation.encode(id: id, result: [
                    "type": "agent_topics_switched", "agent": agent, "changed": changed, "topics_enabled": enabled])
            default:
                return ChatMockConversation.error(id: id, code: "invalid_request",
                                                  message: "unknown variant `\(method)`")
            }
        }
    }

    // MARK: Suggestions

    /// `topic_suggestion` entries for the agent's own conversation (the Inbox), newest state,
    /// stamped from `ms` on: herdr re-sends an entry under its id when it changes.
    func suggestionEntries(after ms: UInt64) -> [[String: Any]] {
        guard Self.enabled, Self.suggests else { return [] }
        // The Inbox's turn never ends here: no suggestion entry reaches the transcript.
        if Self.listOnly { return [] }
        return entries(ms: ms)
    }

    private func entries(ms: UInt64) -> [[String: Any]] {
        return lock.withLock {
            suggestions.enumerated().map { index, suggestion in
                var entry: [String: Any] = [
                    "id": suggestion.id, "ts_ms": ms + UInt64(index + 1) * 1_000, "kind": "topic_suggestion",
                    "title": suggestion.title, "reason": suggestion.reason, "message_ids": suggestion.messageIDs,
                    "message_count": suggestion.messageIDs.count, "state": suggestion.state,
                ]
                if let topicID = suggestion.topicID { entry["topic_id"] = topicID }
                if let by = suggestion.by { entry["by"] = by }
                return entry
            }
        }
    }

    /// The Topics switch's state for the agents list (`topics_enabled`); nil without
    /// `HERDR_MOCK_TOPICS_SWITCH`.
    var topicsEnabledJSON: String {
        guard Self.switchable else { return "" }
        return lock.withLock { #","topics_enabled":\#(topicsEnabled)"# }
    }

    /// The Inbox's opening suggestion: the subject began at the mockup's second prompt.
    private static func openingSuggestion(guest: Bool) -> Suggestion {
        guest
            ? Suggestion(id: "sg-bench", title: "TensorFold bench",
                         reason: "The Q5 bench and its table are a separate line of work.",
                         messageIDs: ["g2u", "g2r"] + (1...10).map { "f\($0)u" }, createdMs: 0)
            : Suggestion(id: "sg-scroll", title: "Terminal scrollback",
                         reason: "Paging older terminal output became its own piece of work.",
                         messageIDs: ["o2u", "o2r"] + (1...10).map { "f\($0)u" }, createdMs: 0)
    }

    private static func organiseProposals(audience guest: Bool)
        -> [(id: String, title: String, reason: String, ids: [String])] {
        let prefix = guest ? "g" : "o"
        return [
            ("sg-org-servers", "Server updates", "Merging #305 and rolling 0.9.5 out to the servers.",
             (11...33).map { "f\($0)u" }),
            ("sg-org-ci", "Fork CI", "The fork's CI runs and the stuck run from Oct 8.", ["\(prefix)1u"] + (34...41).map { "f\($0)u" }),
            ("sg-org-checks", "Synthetic checks", "The daily checks you asked about one by one.", (1...6).map { "f\($0)u" }),
        ]
    }

    /// `agent.transcript` with `topic`: that topic's whole conversation on one page, a turn per
    /// message (the reader's prompt, the topic's reply).
    func transcript(id: String, topic topicID: String) -> String {
        lock.withLock {
            guard let topic = topics.first(where: { $0.id == topicID }) else {
                return ChatMockConversation.error(id: id, code: "topic_not_found", message: "no such topic")
            }
            if startupRefusals > 0 {
                startupRefusals -= 1
                return ChatMockConversation.error(id: id, code: "transcript_unsupported",
                                                  message: "the topic's session is still starting")
            }
            var entries: [[String: Any]] = []
            for (index, message) in topic.messages.enumerated() {
                switch message.from {
                case .owner, .reader:
                    var entry: [String: Any] = ["id": "\(topic.id)-\(index)u", "ts_ms": message.ms, "kind": "user",
                                                "text": message.text, "author": "owner"]
                    if message.from == .reader { for (key, value) in readerAuthor { entry[key] = value } }
                    entries.append(entry)
                case .agent:
                    entries.append(["id": "\(topic.id)-\(index)r", "ts_ms": message.ms, "kind": "reply",
                                    "text": message.text, "final": true])
                    entries.append(["id": "\(topic.id)-\(index)e", "ts_ms": message.ms + 1, "kind": "turn_end",
                                    "status": "done"])
                }
            }
            return ChatMockConversation.encode(id: id, result: [
                "type": "agent_transcript", "agent": agent, "pane_id": paneID,
                "session_id": "mock-topic-\(topic.id)",
                "entries": entries,
                "before": NSNull(),
                "after": "a\(topic.messages.count)",
                "working": NSNull(),
                "pending_ask": NSNull(),
            ])
        }
    }
}
#endif
