import Foundation

// Wire types for an omp agent's topics (jerryfane/herdr#475, `capabilities.agent_topics`):
// `agent.topics.list/new/send/close/reopen/rename`, the `agent.topics.changed` event, and the
// `topic` param of `agent.transcript`. A topic is a permanent, titled worker conversation under
// the agent's own one (the Inbox); its chat is `agent.transcript` with `topic`.
//
// Decoding is forgiving below the list level, like the transcript's: a newer server may add
// states, send modes, change reasons or fields, and one unfamiliar value must not fail the list.

// MARK: - Topics

/// Where a topic's worker is (`AgentTopicState`).
public enum AgentTopicState: String, Sendable, Equatable, Decodable {
    case starting, running, idle, dead, closed
    /// A state this client does not know yet.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentTopicState(rawValue: raw) ?? .unknown
    }

    /// The topic is taking a turn (or starting one).
    public var isWorking: Bool { self == .starting || self == .running }
}

/// One topic as `agent.topics.list` reports it, live from the agent (`AgentTopicInfo`).
public struct AgentTopic: Decodable, Sendable, Equatable, Identifiable {
    /// `topic_id`: the id every other topic call and `agent.transcript`'s `topic` take.
    public let id: String
    public let title: String
    public let state: AgentTopicState
    /// Turns the topic has run.
    public let turns: UInt64
    /// Messages waiting for the topic's current turn to end.
    public let queued: UInt64
    public let createdUnixMs: UInt64
    public let lastActivityUnixMs: UInt64
    /// The topic's newest step, in the agent's words.
    public let lastActivity: String?

    public init(id: String, title: String, state: AgentTopicState, turns: UInt64 = 0, queued: UInt64 = 0,
                createdUnixMs: UInt64 = 0, lastActivityUnixMs: UInt64 = 0, lastActivity: String? = nil) {
        self.id = id
        self.title = title
        self.state = state
        self.turns = turns
        self.queued = queued
        self.createdUnixMs = createdUnixMs
        self.lastActivityUnixMs = lastActivityUnixMs
        self.lastActivity = lastActivity
    }

    enum CodingKeys: String, CodingKey {
        case id = "topic_id"
        case title, state, turns, queued
        case createdUnixMs = "created_unix_ms"
        case lastActivityUnixMs = "last_activity_unix_ms"
        case lastActivity = "last_activity"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The id is what every call names the topic by: without it the row is useless.
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        state = try c.decodeIfPresent(AgentTopicState.self, forKey: .state) ?? .unknown
        turns = (try? c.decodeIfPresent(UInt64.self, forKey: .turns)) ?? 0
        queued = (try? c.decodeIfPresent(UInt64.self, forKey: .queued)) ?? 0
        createdUnixMs = (try? c.decodeIfPresent(UInt64.self, forKey: .createdUnixMs)) ?? 0
        lastActivityUnixMs = (try? c.decodeIfPresent(UInt64.self, forKey: .lastActivityUnixMs)) ?? 0
        lastActivity = (try? c.decodeIfPresent(String.self, forKey: .lastActivity)) ?? nil
    }

    /// When the topic last did something: its last activity, else when it was created.
    public var activityUnixMs: UInt64 { max(lastActivityUnixMs, createdUnixMs) }
}

/// Result of `agent.topics.list` (`type: "agent_topics"`): the agent's topics, live from the
/// agent; empty when it has none (an unreachable agent is an error instead).
public struct AgentTopicList: Decodable, Sendable, Equatable {
    public let agent: String
    public let paneID: String
    public let topics: [AgentTopic]

    public init(agent: String, paneID: String, topics: [AgentTopic]) {
        self.agent = agent
        self.paneID = paneID
        self.topics = topics
    }

    enum CodingKeys: String, CodingKey {
        case agent, topics
        case paneID = "pane_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? ""
        paneID = try c.decodeIfPresent(String.self, forKey: .paneID) ?? ""
        // One topic that does not decode is left out rather than failing the list.
        topics = try c.decode([Lossy<AgentTopic>].self, forKey: .topics).compactMap(\.value)
    }

    /// Topics in the order the Topics view lists them: open ones by last activity, newest
    /// first, then the closed ones the same way.
    public var ordered: [AgentTopic] {
        topics.sorted { a, b in
            let aClosed = a.state == .closed, bClosed = b.state == .closed
            if aClosed != bClosed { return !aClosed }
            if a.activityUnixMs != b.activityUnixMs { return a.activityUnixMs > b.activityUnixMs }
            return a.id < b.id
        }
    }
}

/// Decodes one element of an array, or nil when it does not decode.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: - Topic sessions (agent.list)

/// One topic transcript of an omp agent's current session, as `agent.list` / `agent.get`
/// report it from the session file on disk (`AgentTopicSession`), whether or not the agent can
/// be reached. Never throws: an element that is not what the schema says reads as an empty id,
/// which callers skip.
public struct AgentTopicSession: Decodable, Sendable, Equatable {
    public let topicID: String
    /// The topic's own session file.
    public let path: String
    /// The newest owner-facing title the session file records.
    public let title: String?
    public let createdUnixMs: UInt64?

    public init(topicID: String, path: String = "", title: String? = nil, createdUnixMs: UInt64? = nil) {
        self.topicID = topicID
        self.path = path
        self.title = title
        self.createdUnixMs = createdUnixMs
    }

    enum CodingKeys: String, CodingKey {
        case path, title
        case topicID = "topic_id"
        case createdUnixMs = "created_unix_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        topicID = (try? c?.decodeIfPresent(String.self, forKey: .topicID)) ?? ""
        path = (try? c?.decodeIfPresent(String.self, forKey: .path)) ?? ""
        title = (try? c?.decodeIfPresent(String.self, forKey: .title)) ?? nil
        createdUnixMs = (try? c?.decodeIfPresent(UInt64.self, forKey: .createdUnixMs)) ?? nil
    }
}

// MARK: - Results of the other calls

/// How `agent.topics.send` delivered a message (`AgentTopicSendMode`).
public enum AgentTopicSendMode: String, Sendable, Equatable, Decodable {
    /// Steered into the topic's running turn.
    case steered
    /// Queued behind the topic's running turn.
    case queued
    /// Started a new turn.
    case turn
    /// A delivery this client does not know yet.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentTopicSendMode(rawValue: raw) ?? .unknown
    }
}

/// `agent.topics.new` (`agent_topic_created`), `agent.topics.send` (`agent_topic_sent`, with
/// `mode`) and close/reopen/rename (`agent_topic_updated`): the topic the call acted on.
struct AgentTopicResult: Decodable, Sendable {
    let topicID: String
    let mode: AgentTopicSendMode?

    enum CodingKeys: String, CodingKey {
        case topicID = "topic_id"
        case mode
    }
}

// MARK: - Params

struct AgentTopicsListParams: Encodable, Sendable {
    let target: String
}

struct AgentTopicsNewParams: Encodable, Sendable {
    let target: String
    let title: String
    let message: String
}

struct AgentTopicsSendParams: Encodable, Sendable {
    let target: String
    let topicID: String
    let message: String

    enum CodingKeys: String, CodingKey {
        case target, message
        case topicID = "topic_id"
    }
}

/// `agent.topics.close` / `agent.topics.reopen` (`AgentTopicTarget`).
struct AgentTopicTargetParams: Encodable, Sendable {
    let target: String
    let topicID: String

    enum CodingKeys: String, CodingKey {
        case target
        case topicID = "topic_id"
    }
}

struct AgentTopicsRenameParams: Encodable, Sendable {
    let target: String
    let topicID: String
    let title: String

    enum CodingKeys: String, CodingKey {
        case target, title
        case topicID = "topic_id"
    }
}

// MARK: - Errors

/// Why an `agent.topics.*` call did not do what it asked. Anything else arrives as `.other`.
public enum AgentTopicsError: Error, Equatable, Sendable {
    /// The server does not advertise `agent_topics`: the call was never sent.
    case notAdvertised
    /// `topics_unsupported`: not a live omp agent.
    case unsupported
    /// `topics_unreachable`: the agent has not offered its topics, or its control socket broke.
    case unreachable
    /// `topics_timeout`: the agent did not answer in time.
    case timeout
    /// `topic_rejected`: the agent refused the command, with its reason.
    case rejected(String)
    /// `topic_not_found`.
    case topicNotFound
    /// `agent_not_found`.
    case agentNotFound
    case other(APIError)

    init(_ error: APIError) {
        switch error.code {
        case "topics_unsupported": self = .unsupported
        case "topics_unreachable": self = .unreachable
        case "topics_timeout": self = .timeout
        case "topic_rejected": self = .rejected(error.message)
        case "topic_not_found": self = .topicNotFound
        case "agent_not_found": self = .agentNotFound
        default:
            // An older server that cannot even deserialize the method.
            if error.code == "invalid_request",
               error.message.lowercased().contains("unknown variant"),
               error.message.contains("agent.topics") {
                self = .unsupported
            } else {
                self = .other(error)
            }
        }
    }
}

// MARK: - Discovery

/// When to ask an agent for its topics list again while it does not offer them (#758).
///
/// `topics_unreachable` is the steady answer of every omp agent without topics turned on,
/// so it backs off: 60 s, doubling, capped at 10 minutes. There are no short early retries:
/// an agent that is just starting changes its status (or its session) as it comes up, and
/// that resets the schedule (`reset()`), so the quick second look comes from the agent, not
/// from a timer. A timeout, a dropped connection and `agent_not_found` (the pane has no agent
/// for a moment while it restarts, herdrup#777) back off the same way. `topics_unsupported`
/// and a server without `agent_topics` stop discovery for good.
public struct TopicsDiscoveryBackoff: Sendable, Equatable {
    /// Seconds between attempts, the last one repeating.
    public static let delays: [UInt64] = [60, 120, 240, 480, 600]

    public enum Decision: Sendable, Equatable {
        /// The agent answered: it offers topics.
        case offered
        /// The agent will not offer topics: stop asking.
        case stop
        /// Ask again after this many seconds.
        case retry(afterSeconds: UInt64)
    }

    /// Retries scheduled since the start or the last `reset()`.
    public private(set) var attempt = 0

    /// The delays in use: `delays` unless a test or a mock passes its own.
    public let schedule: [UInt64]

    public init(schedule: [UInt64] = TopicsDiscoveryBackoff.delays) {
        self.schedule = schedule.isEmpty ? Self.delays : schedule
    }

    /// What to do after one `agent.topics.list` answer: nil error for a list.
    public mutating func decide(after error: Error?) -> Decision {
        guard let error else {
            attempt = 0
            return .offered
        }
        if let topics = error as? AgentTopicsError, topics.isPermanent { return .stop }
        let delays = schedule
        let seconds = delays[min(attempt, delays.count - 1)]
        attempt += 1
        return .retry(afterSeconds: seconds)
    }

    /// The agent changed (status, session, a topics change, a guest reconnect): start the
    /// schedule over.
    public mutating func reset() { attempt = 0 }
}

/// Runs discovery on `TopicsDiscoveryBackoff`'s schedule: one attempt, then the wait its
/// answer calls for, until the agent offers topics or refuses for good.
///
/// `wake()` (an `agent.topics.changed` for the agent) restarts the schedule and asks again
/// at once: it ends a wait in progress, and one that arrives while an attempt is still in
/// flight is kept and consumed before the next wait is installed, so it is never lost to a
/// full backoff sleep (herdrup#767). `attempt` returns nil when the agent answered with a list.
/// `sleep` is injectable so tests run the schedule without a clock.
@MainActor
public final class TopicsDiscoveryLoop {
    public typealias Attempt = @MainActor () async -> (any Error)?
    public typealias Sleep = @Sendable (_ seconds: UInt64) async -> Void

    private let schedule: [UInt64]
    private let attempt: Attempt
    private let sleep: Sleep
    /// A wake arrived since the current attempt started.
    private var woken = false
    private var wait: Task<Void, Never>?

    public init(schedule: [UInt64] = TopicsDiscoveryBackoff.delays,
                attempt: @escaping Attempt,
                sleep: @escaping Sleep = { seconds in try? await Task.sleep(nanoseconds: seconds * 1_000_000_000) }) {
        self.schedule = schedule
        self.attempt = attempt
        self.sleep = sleep
    }

    /// Until the agent offers topics or refuses for good, or the task is cancelled.
    public func run() async {
        var backoff = TopicsDiscoveryBackoff(schedule: schedule)
        while !Task.isCancelled {
            woken = false
            let error = await attempt()
            if Task.isCancelled { return }
            switch backoff.decide(after: error) {
            case .offered, .stop:
                return
            case .retry(let seconds):
                // A wake during the attempt: start over and ask again now, no wait.
                if woken {
                    backoff.reset()
                    continue
                }
                let sleep = self.sleep
                let pending = Task<Void, Never> { await sleep(seconds) }
                wait = pending
                await withTaskCancellationHandler { await pending.value } onCancel: { pending.cancel() }
                wait = nil
                if woken { backoff.reset() }
            }
        }
    }

    /// The agent changed: ask again now, from the start of the schedule.
    public func wake() {
        woken = true
        wait?.cancel()
    }
}

extension AgentTopicsError {
    /// The agent will not offer topics for the rest of this page's life: `topics_unsupported`
    /// or a server without `agent_topics`. Anything else may pass, `agent_not_found` too: a
    /// restarting agent leaves its pane without one for a moment (herdrup#777).
    public var isPermanent: Bool {
        switch self {
        case .unsupported, .notAdvertised: return true
        case .unreachable, .timeout, .rejected, .topicNotFound, .agentNotFound, .other: return false
        }
    }
}

// MARK: - Event

/// Why a topic changed (`AgentTopicChangeReason`).
public enum AgentTopicChangeReason: String, Sendable, Equatable, Decodable {
    case spawned
    case turnStarted = "turn_started"
    case turnSettled = "turn_settled"
    case closed, reopened, retitled
    /// The agent restored the topic with its session (startup, session switch).
    case restored
    /// A reason this client does not know yet.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentTopicChangeReason(rawValue: raw) ?? .unknown
    }
}

/// One of an omp agent's topics changed (`agent.topics.changed`, event data
/// `agent_topics_changed`).
public struct AgentTopicsChange: Decodable, Sendable, Equatable {
    public let paneID: String
    public let workspaceID: String?
    public let agent: String?
    public let topicID: String
    public let reason: AgentTopicChangeReason

    public init(paneID: String, workspaceID: String? = nil, agent: String? = nil, topicID: String,
                reason: AgentTopicChangeReason) {
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.agent = agent
        self.topicID = topicID
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case agent, reason
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case topicID = "topic_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paneID = try c.decode(String.self, forKey: .paneID)
        topicID = try c.decode(String.self, forKey: .topicID)
        workspaceID = try? c.decodeIfPresent(String.self, forKey: .workspaceID)
        agent = try? c.decodeIfPresent(String.self, forKey: .agent)
        reason = (try? c.decodeIfPresent(AgentTopicChangeReason.self, forKey: .reason)) ?? .unknown
    }
}

/// One line of `HerdrClient.subscribeTopicChanges()`.
public enum AgentTopicsStreamLine: Sendable, Equatable {
    /// The acknowledgement.
    case started
    case changed(AgentTopicsChange)
    /// Anything else: a heartbeat, another kind, or a payload this client cannot read.
    case other

    /// Decodes one stream line. Throws the server's `APIError` for an error line (a server
    /// that refuses the subscription); every other shape is `.other`, so a newer server
    /// cannot end the stream.
    public static func decode(_ line: String) throws -> AgentTopicsStreamLine {
        let data = Data(line.utf8)
        let decoder = JSONDecoder()
        if let failure = try? decoder.decode(ErrorEnvelope.self, from: data) { throw failure.error }
        guard let probe = try? decoder.decode(Probe.self, from: data) else { return .other }
        if probe.result?.type == "subscription_started" { return .started }
        guard let event = probe.event?.replacingOccurrences(of: ".", with: "_"),
              event == "agent_topics_changed",
              let change = try? decoder.decode(Payload.self, from: data).data
        else { return .other }
        return .changed(change)
    }

    /// Each key read on its own: an `event` that is not a string (another line shape) must
    /// not hide a `result`.
    private struct Probe: Decodable {
        struct Result: Decodable { let type: String? }
        let event: String?
        let result: Result?

        enum CodingKeys: String, CodingKey { case event, result }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            event = (try? c.decodeIfPresent(String.self, forKey: .event)) ?? nil
            result = (try? c.decodeIfPresent(Result.self, forKey: .result)) ?? nil
        }
    }

    private struct Payload: Decodable {
        let data: AgentTopicsChange
    }
}
