import Foundation

// MARK: - All-panes status stream lines
//
// Wire contract: herdr events v2 (`events.subscribe` with `events_v2: true`).
// Every event line is `{"seq":N,"event":<kind>,"data":{…}}`. Pane subscription
// events use a dotted kind (`pane.agent_status_changed`, `pane.turn_completed`) and
// lifecycle events a snake_case one with a tagged `data` (`pane_created`,
// `pane_closed`, …). Control lines carry a top-level `control` key and no `event`.
// On a federation coordinator, ids in relayed events are qualified with the peer's
// alias (`build/w1:p2`), which is also how `agent.list` names remote panes, so they
// match listed rows as they are.

/// One line of `HerdrClient.subscribeAgentStatus()`.
public enum AgentStatusStreamLine: Sendable, Equatable {
    /// The acknowledgement. `rejectedIndices` lists request entries the daemon skipped.
    case started(rejectedIndices: [Int])
    case statusChanged(AgentStatusChange)
    case turnCompleted(AgentTurnCompletion)
    case paneCreated(paneID: String?, seq: UInt64?)
    case paneClosed(paneID: String, seq: UInt64?)
    case paneExited(paneID: String, seq: UInt64?)
    case agentDetected(paneID: String, seq: UInt64?)
    /// The daemon dropped events this stream had not read; resynchronize from `agent.list`.
    case lagged(seq: UInt64?, firstMissedSeq: UInt64?, lastMissedSeq: UInt64?)
    /// Written after 15 s with nothing else to send.
    case heartbeat(seq: UInt64?)
    /// Anything else: a kind this client does not act on, or a newer line shape.
    case unknown(raw: String)

    /// Whether the line means the listed panes or agents changed in a way a status
    /// patch cannot express, so the caller should reload `agent.list`.
    public var requiresRosterReload: Bool {
        switch self {
        case .paneCreated, .paneClosed, .paneExited, .agentDetected, .lagged:
            return true
        case .started, .statusChanged, .turnCompleted, .heartbeat, .unknown:
            return false
        }
    }

    /// The status or turn change this line carries, if any.
    public var liveUpdate: AgentLiveUpdate? {
        switch self {
        case .statusChanged(let change): return .status(change)
        case .turnCompleted(let completion): return .turn(completion)
        default: return nil
        }
    }

    /// Decodes one stream line. Throws the daemon's `APIError` for an error line
    /// (for example an older daemon refusing an entry without `pane_id`). Lines of
    /// any other shape, including events whose payload does not decode, become
    /// `.unknown` so a newer daemon cannot end the stream.
    public static func decode(_ line: String) throws -> AgentStatusStreamLine {
        let data = Data(line.utf8)
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(LineProbe.self, from: data) else {
            return .unknown(raw: line)
        }
        if let error = probe.error { throw error }
        if let control = probe.control {
            switch control {
            case "lagged":
                return .lagged(seq: probe.seq, firstMissedSeq: probe.firstMissedSeq,
                               lastMissedSeq: probe.lastMissedSeq)
            case "heartbeat":
                return .heartbeat(seq: probe.seq)
            default:
                return .unknown(raw: line)
            }
        }
        if probe.resultType == "subscription_started" {
            return .started(rejectedIndices: probe.rejectedIndices)
        }
        guard let event = probe.event else { return .unknown(raw: line) }

        func payload<T: Decodable>(_ type: T.Type) -> T? {
            try? decoder.decode(EventLine<T>.self, from: data).data
        }
        // Both spellings of a kind are accepted, so a pane event delivered as a
        // lifecycle line (or the reverse) is still recognised.
        switch event.replacingOccurrences(of: ".", with: "_") {
        case "pane_agent_status_changed":
            guard let p = payload(StatusPayload.self) else { return .unknown(raw: line) }
            return .statusChanged(AgentStatusChange(
                seq: probe.seq, paneID: p.paneID, workspaceID: p.workspaceID,
                agentStatus: p.agentStatus, inputPending: p.inputPending ?? false,
                inputPromptKind: p.inputPromptKind, agent: p.agent,
                turn: p.turn, turnEpoch: p.turnEpoch))
        case "pane_turn_completed":
            guard let p = payload(TurnPayload.self) else { return .unknown(raw: line) }
            return .turnCompleted(AgentTurnCompletion(
                seq: probe.seq, paneID: p.pane.paneID, agentStatus: p.pane.agentStatus,
                inputPending: p.pane.inputPending ?? false, inputPromptKind: p.pane.inputPromptKind,
                agent: p.pane.agent,
                turn: p.turn, turnEpoch: p.turnEpoch, outcome: p.outcome,
                completedUnixMs: p.completedUnixMs))
        case "pane_created":
            return .paneCreated(paneID: payload(PanePayload.self)?.pane?.paneID, seq: probe.seq)
        case "pane_closed":
            guard let pane = payload(PaneIDPayload.self)?.paneID else { return .unknown(raw: line) }
            return .paneClosed(paneID: pane, seq: probe.seq)
        case "pane_exited":
            guard let pane = payload(PaneIDPayload.self)?.paneID else { return .unknown(raw: line) }
            return .paneExited(paneID: pane, seq: probe.seq)
        case "pane_agent_detected":
            guard let pane = payload(PaneIDPayload.self)?.paneID else { return .unknown(raw: line) }
            return .agentDetected(paneID: pane, seq: probe.seq)
        default:
            return .unknown(raw: line)
        }
    }
}

/// `pane.agent_status_changed`. `turn` / `turnEpoch` are advisory hints from the daemon.
public struct AgentStatusChange: Sendable, Equatable {
    public let seq: UInt64?
    public let paneID: String
    public let workspaceID: String?
    public let agentStatus: String
    public let inputPending: Bool
    public let inputPromptKind: String?
    public let agent: String?
    public let turn: Int?
    public let turnEpoch: UInt64?

    public init(seq: UInt64?, paneID: String, workspaceID: String?, agentStatus: String,
                inputPending: Bool = false, inputPromptKind: String? = nil, agent: String? = nil,
                turn: Int? = nil, turnEpoch: UInt64? = nil) {
        self.seq = seq
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.agentStatus = agentStatus
        self.inputPending = inputPending
        self.inputPromptKind = inputPromptKind
        self.agent = agent
        self.turn = turn
        self.turnEpoch = turnEpoch
    }
}

/// `pane.turn_completed`: the pane snapshot's status and input prompt plus the
/// finished turn. The snapshot omits `input_pending` / `input_prompt_kind` when the
/// pane is not waiting on input, so their absence means cleared.
public struct AgentTurnCompletion: Sendable, Equatable {
    public let seq: UInt64?
    public let paneID: String
    public let agentStatus: String?
    public let inputPending: Bool
    public let inputPromptKind: String?
    public let agent: String?
    public let turn: Int
    public let turnEpoch: UInt64
    public let outcome: String?
    public let completedUnixMs: Int64?

    public init(seq: UInt64?, paneID: String, agentStatus: String?,
                inputPending: Bool = false, inputPromptKind: String? = nil, agent: String? = nil,
                turn: Int, turnEpoch: UInt64,
                outcome: String? = nil, completedUnixMs: Int64? = nil) {
        self.seq = seq
        self.paneID = paneID
        self.agentStatus = agentStatus
        self.inputPending = inputPending
        self.inputPromptKind = inputPromptKind
        self.agent = agent
        self.turn = turn
        self.turnEpoch = turnEpoch
        self.outcome = outcome
        self.completedUnixMs = completedUnixMs
    }
}

/// A change `AgentInfo` rows can absorb without reloading `agent.list`.
public enum AgentLiveUpdate: Sendable, Equatable {
    case status(AgentStatusChange)
    case turn(AgentTurnCompletion)

    public var paneID: String {
        switch self {
        case .status(let change): return change.paneID
        case .turn(let completion): return completion.paneID
        }
    }

    /// The agent the event reports on the pane: nil for a pane without one, such as
    /// a plain shell, which `agent.list` never lists.
    public var agent: String? {
        switch self {
        case .status(let change): return change.agent
        case .turn(let completion): return completion.agent
        }
    }
}

public enum AgentStatusStreamError: Error, Equatable, Sendable {
    /// No line arrived within the timeout, although the daemon writes a heartbeat
    /// every 15 s: the connection is treated as dead.
    case silent(Duration)
}

// MARK: - Patching listed rows

extension AgentInfo {
    /// This row with `update` applied. `receivedAt` stands in for the daemon's
    /// status-change time, which the event does not carry, and is used only when the
    /// status actually changes, so an event the listed row already reflects leaves
    /// the row's age badge alone.
    public func applying(_ update: AgentLiveUpdate, receivedAt: Date) -> AgentInfo {
        var next = self
        switch update {
        case .status(let change):
            next.setStatus(change.agentStatus, at: receivedAt)
            next.inputPending = change.inputPending
            next.inputPromptKind = change.inputPromptKind
            if let turn = change.turn { next.turn = turn }
            if let epoch = change.turnEpoch { next.turnEpoch = epoch }
        case .turn(let completion):
            if let status = completion.agentStatus {
                // A snapshot with a status is the pane's whole state, input prompt
                // included: a turn that finished `done` ends a `blocked` prompt.
                next.setStatus(status, at: receivedAt)
                next.inputPending = completion.inputPending
                next.inputPromptKind = completion.inputPromptKind
            }
            next.turn = completion.turn
            next.turnEpoch = completion.turnEpoch
            next.lastCompletedTurn = CompletedTurn(
                turn: completion.turn, turnEpoch: completion.turnEpoch,
                completedUnixMs: completion.completedUnixMs ?? lastCompletedTurn?.completedUnixMs)
        }
        return next
    }

    private mutating func setStatus(_ status: String, at time: Date) {
        guard status != agentStatus else { return }
        agentStatus = status
        statusSinceUnixMs = UInt64(max(0, time.timeIntervalSince1970 * 1000))
    }
}

extension Array where Element == AgentInfo {
    /// The list with `update` applied to its row, or nil when no live row has the
    /// pane (a pane the list has not seen yet; reload to pick it up).
    public func applying(_ update: AgentLiveUpdate, receivedAt: Date) -> [AgentInfo]? {
        let pane = update.paneID
        guard !pane.isEmpty, let index = firstIndex(where: { $0.paneID == pane }) else { return nil }
        var next = self
        next[index] = self[index].applying(update, receivedAt: receivedAt)
        return next
    }

    /// What one stream line does to this list: patch a listed row, reload
    /// `agent.list` (the panes changed), ask for a reload for an agent pane the list
    /// has not seen yet, or ignore it. The all-panes stream also reports panes
    /// without an agent (a plain shell's title changing, a pane whose agent quit);
    /// `agent.list` never lists those, so they are ignored.
    ///
    /// A row with a pending Topics switch (`topics_switch_pending`) is patched and then
    /// reloaded: herdr applies the held switch when the agent goes idle, and clears the
    /// pending flag and changes `topics_enabled`, which no status or turn event carries
    /// (herdrup#802). Until the reload the row would keep offering Cancel pending switch.
    public func effect(of line: AgentStatusStreamLine, receivedAt: Date) -> AgentRosterStreamEffect {
        guard let update = line.liveUpdate else { return line.requiresRosterReload ? .reload : .ignore }
        if let patched = applying(update, receivedAt: receivedAt) {
            let pending = contains { $0.paneID == update.paneID && $0.isTopicsSwitchPending }
            return pending ? .patchAndReload(patched) : .patch(patched)
        }
        guard !update.paneID.isEmpty, update.agent != nil else { return .ignore }
        return .reloadForUnlistedPane(update.paneID)
    }
}

/// See `[AgentInfo].effect(of:receivedAt:)`.
public enum AgentRosterStreamEffect: Sendable, Equatable {
    case patch([AgentInfo])
    /// Patch, then reload `agent.list`: the row has state the event cannot update.
    case patchAndReload([AgentInfo])
    case reload
    /// Reload, subject to `UnlistedPaneReloads`.
    case reloadForUnlistedPane(String)
    case ignore
}

/// Reloads asked for by status or turn events naming an agent pane the list does
/// not show. One request per pane until a load that started after it publishes,
/// so a burst of events for one new pane, or a pane `agent.list` keeps leaving out
/// (a federation peer's pane the coordinator's directory has not caught up with),
/// costs a reload per published load rather than one per event.
public struct UnlistedPaneReloads: Sendable, Equatable {
    private var requested: [String: ContinuousClock.Instant] = [:]

    public init() {}

    /// Whether an event for unlisted `paneID` received at `now` should reload.
    public mutating func request(_ paneID: String, at now: ContinuousClock.Instant) -> Bool {
        guard requested[paneID] == nil else { return false }
        requested[paneID] = now
        return true
    }

    /// The load that started at `start` published: it answered every request made
    /// before it started.
    public mutating func loadPublished(startedAt start: ContinuousClock.Instant) {
        requested = requested.filter { $0.value >= start }
    }
}

/// Keeps live updates that arrived while an `agent.list` load was in flight, so the
/// load's (possibly older) snapshot cannot undo them.
///
/// Take `mark` when a load starts. When that load publishes, `replay(onto:after:)`
/// re-applies every update received since, in order, then `settle(through:)` drops
/// the ones the snapshot already covers: an update received before the request was
/// sent reached the daemon's state before the daemon answered it.
public struct AgentLiveUpdateLedger: Sendable {
    /// Bounds memory when loads keep failing; the oldest entries go first.
    public static let capacity = 256

    private struct Entry: Sendable {
        let index: UInt64
        let update: AgentLiveUpdate
        let receivedAt: Date
    }

    private var entries: [Entry] = []
    private var counter: UInt64 = 0

    public init() {}

    /// The position a load started at.
    public var mark: UInt64 { counter }

    public mutating func record(_ update: AgentLiveUpdate, receivedAt: Date) {
        counter &+= 1
        entries.append(Entry(index: counter, update: update, receivedAt: receivedAt))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    /// `agents` with every update recorded after `mark` applied in arrival order.
    /// Updates for panes absent from `agents` are skipped.
    public func replay(onto agents: [AgentInfo], after mark: UInt64) -> [AgentInfo] {
        var result = agents
        for entry in entries where entry.index > mark {
            if let next = result.applying(entry.update, receivedAt: entry.receivedAt) { result = next }
        }
        return result
    }

    /// Forgets updates recorded at or before `mark`.
    public mutating func settle(through mark: UInt64) {
        entries.removeAll { $0.index <= mark }
    }
}

// MARK: - Reconnect backoff

/// Exponential reconnect delay: `initial`, doubling, capped at `maximum`. With `jitter`,
/// each delay is that step scaled by a random factor drawn from the range (the live
/// terminal uses 0.6...1.0). `reset()` once the stream has genuinely re-established; each
/// caller decides what counts as that (the status stream: its ack; the terminal: a keyframe).
public struct ReconnectBackoff: Sendable, Equatable {
    public let initial: Duration
    public let maximum: Duration
    public let jitter: ClosedRange<Double>?
    private var current: Duration

    public init(initial: Duration = .seconds(1), maximum: Duration = .seconds(30),
                jitter: ClosedRange<Double>? = nil) {
        self.initial = initial
        self.maximum = maximum
        self.jitter = jitter
        self.current = initial
    }

    /// The delay before the next attempt; each call doubles the following one.
    public mutating func next() -> Duration {
        var generator = SystemRandomNumberGenerator()
        return next(using: &generator)
    }

    /// `next()` drawing its jitter from `generator`, so a test can make it repeatable.
    public mutating func next<G: RandomNumberGenerator>(using generator: inout G) -> Duration {
        let step = min(current, maximum)
        current = min(current * 2, maximum)
        guard let jitter else { return step }
        return step * Double.random(in: jitter, using: &generator)
    }

    public mutating func reset() { current = initial }
}

// MARK: - agent.list backstop

/// When the home list's poll re-fetches `agent.list`. Without an open status stream
/// every tick loads; with one, only once `interval` has passed since the last load
/// that published. A failed load (an event-driven resync after `lagged` or a pane
/// lifecycle event, say) leaves the list due, so the next tick retries it rather
/// than treating the failure as a fresh backstop.
public struct AgentListBackstop: Sendable, Equatable {
    private var lastPublishedLoadStart: ContinuousClock.Instant?

    public init() {}

    /// The load that started at `start` published its snapshot.
    public mutating func loadSucceeded(startedAt start: ContinuousClock.Instant) {
        lastPublishedLoadStart = start
    }

    /// The newest load failed: the next tick loads again.
    public mutating func loadFailed() {
        lastPublishedLoadStart = nil
    }

    public func isDue(streaming: Bool, interval: Duration, now: ContinuousClock.Instant) -> Bool {
        guard streaming, let last = lastPublishedLoadStart else { return true }
        return now - last >= interval
    }
}

// MARK: - Decoding helpers

/// Records when the last line arrived, for the silence watchdog.
actor StreamActivity {
    private var last = ContinuousClock.now

    func touch() { last = .now }

    func remaining(of timeout: Duration) -> Duration {
        timeout - (ContinuousClock.now - last)
    }
}

/// Routes a line by its top-level keys. Each key is decoded leniently, so an odd
/// value in one key cannot hide the others.
private struct LineProbe: Decodable {
    let control: String?
    let event: String?
    let seq: UInt64?
    let firstMissedSeq: UInt64?
    let lastMissedSeq: UInt64?
    let resultType: String?
    let rejectedIndices: [Int]
    let error: APIError?

    private enum CodingKeys: String, CodingKey {
        case control, event, seq, result, error
        case firstMissedSeq = "first_missed_seq"
        case lastMissedSeq = "last_missed_seq"
    }

    private struct Result: Decodable {
        let type: String?
        let rejected: [Rejection]?
    }

    private struct Rejection: Decodable {
        let index: Int
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        control = try? c.decodeIfPresent(String.self, forKey: .control)
        event = try? c.decodeIfPresent(String.self, forKey: .event)
        seq = try? c.decodeIfPresent(UInt64.self, forKey: .seq)
        firstMissedSeq = try? c.decodeIfPresent(UInt64.self, forKey: .firstMissedSeq)
        lastMissedSeq = try? c.decodeIfPresent(UInt64.self, forKey: .lastMissedSeq)
        let result = try? c.decodeIfPresent(Result.self, forKey: .result)
        resultType = result?.type
        rejectedIndices = result?.rejected?.map(\.index) ?? []
        error = try? c.decodeIfPresent(APIError.self, forKey: .error)
    }
}

private struct EventLine<T: Decodable>: Decodable {
    let data: T
}

private struct StatusPayload: Decodable {
    let paneID: String
    let workspaceID: String?
    let agentStatus: String
    let inputPending: Bool?
    let inputPromptKind: String?
    let agent: String?
    let turn: Int?
    let turnEpoch: UInt64?

    enum CodingKeys: String, CodingKey {
        case agent, turn
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case agentStatus = "agent_status"
        case inputPending = "input_pending"
        case inputPromptKind = "input_prompt_kind"
        case turnEpoch = "turn_epoch"
    }
}

private struct TurnPayload: Decodable {
    struct Pane: Decodable {
        let paneID: String
        let agentStatus: String?
        let inputPending: Bool?
        let inputPromptKind: String?
        let agent: String?
        enum CodingKeys: String, CodingKey {
            case agent
            case paneID = "pane_id"
            case agentStatus = "agent_status"
            case inputPending = "input_pending"
            case inputPromptKind = "input_prompt_kind"
        }
    }

    let pane: Pane
    let turn: Int
    let turnEpoch: UInt64
    let outcome: String?
    let completedUnixMs: Int64?

    enum CodingKeys: String, CodingKey {
        case pane, turn, outcome
        case turnEpoch = "turn_epoch"
        case completedUnixMs = "completed_unix_ms"
    }
}

private struct PanePayload: Decodable {
    struct Pane: Decodable {
        let paneID: String
        enum CodingKeys: String, CodingKey { case paneID = "pane_id" }
    }
    let pane: Pane?
}

private struct PaneIDPayload: Decodable {
    let paneID: String
    enum CodingKeys: String, CodingKey { case paneID = "pane_id" }
}
