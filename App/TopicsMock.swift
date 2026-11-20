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
    /// `HERDR_MOCK_TOPICS_SEND_DELAY=<seconds>`: `agent.topics.send` answers that much later, and
    /// a send to a running topic is `queued`, so its receipt can land after the reader moved on.
    private static let sendDelay = ProcessInfo.processInfo.environment["HERDR_MOCK_TOPICS_SEND_DELAY"]
        .flatMap(Double.init) ?? 0

    static let owner = TopicsMock(agent: "herdr-app", paneID: "w9:p1", readerAuthor: ["author": "owner"])
    static let guest = TopicsMock(agent: "llm-opt", paneID: "w1-3",
                                  readerAuthor: ["author": "guest",
                                                 "author_name": GuestMockTransport.access.guestName])

    /// The pong's capabilities, after the other capabilities: topics, and `topic` honoured on
    /// `agent.transcript`.
    static var capability: String { enabled ? #","agent_topics":true,"agent_transcript_topic":true"# : "" }

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

    private init(agent: String, paneID: String, readerAuthor: [String: String]) {
        self.agent = agent
        self.paneID = paneID
        self.readerAuthor = readerAuthor
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
                if (Self.goesUnreachable && listCalls > 1) || listCalls <= Self.failsFirst {
                    return ChatMockConversation.error(id: id, code: "topics_unreachable",
                                                      message: "the agent has not offered its topics")
                }
                return ChatMockConversation.encode(id: id, result: [
                    "type": "agent_topics", "agent": agent, "pane_id": paneID,
                    "topics": topics.map { topic -> [String: Any] in
                        [
                            "topic_id": topic.id, "title": topic.title, "state": topic.state,
                            "turns": topic.messages.filter { $0.from != .agent }.count, "queued": 0,
                            "created_unix_ms": topic.createdMs, "last_activity_unix_ms": topic.lastMs,
                            "last_activity": topic.lastActivity ?? NSNull(),
                        ]
                    },
                ])
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
            default:
                return ChatMockConversation.error(id: id, code: "invalid_request",
                                                  message: "unknown variant `\(method)`")
            }
        }
    }

    /// `agent.transcript` with `topic`: that topic's whole conversation on one page, a turn per
    /// message (the reader's prompt, the topic's reply).
    func transcript(id: String, topic topicID: String) -> String {
        lock.withLock {
            guard let topic = topics.first(where: { $0.id == topicID }) else {
                return ChatMockConversation.error(id: id, code: "topic_not_found", message: "no such topic")
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
