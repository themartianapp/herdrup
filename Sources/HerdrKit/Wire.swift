import Foundation

// Wire types for the herdr JSON API.
//
// Field sets were taken from a live server (build d293951f) rather than from the
// Rust source, so optionality reflects what the server actually omits.

public struct RequestEnvelope<P: Encodable>: Encodable {
    public let id: String
    public let method: String
    public let params: P
}

public struct EmptyParams: Encodable {
    public init() {}
}

public struct APIError: Error, Decodable, Equatable, Sendable, CustomStringConvertible {
    public let code: String
    public let message: String
    public var description: String { "\(code): \(message)" }
}

struct ErrorEnvelope: Decodable {
    let error: APIError
}

/// Whether a failed pane stream was PERMANENTLY refused by the server — and if so, what
/// to tell the user. Returns nil for anything transient, which the caller must keep
/// retrying.
///
/// A dropped socket and a refusal both arrive at the client as "the stream ended with an
/// error", but they need opposite handling. The reconnect loop is right for a drop and
/// actively harmful for a refusal: the server's answer will not change, so the terminal
/// sits on "connection lost; reconnecting…" forever with nothing behind it. That is the
/// shape a real daemon bug took — it advertised a pane in `agent.list`/`pane.list` that
/// `pane.stream` then refused, and the app spun instead of saying so.
///
/// Only codes that CANNOT become true by waiting belong here. `pane_not_found` is
/// permanent for a given pane id: pane ids are not reused, so a pane that is gone stays
/// gone, and a fresh id means a fresh stream. `invalid_request` means this server does
/// not speak the method — retrying the same call against the same daemon cannot help.
/// Everything else (transport failures, timeouts, a server restarting) stays transient
/// by default, because misclassifying a transient error as permanent strands a terminal
/// that would have recovered on its own.
public func permanentStreamRefusal(code: String) -> String? {
    switch code {
    case "pane_not_found":
        return "this pane no longer exists on the server; not reconnecting"
    case "invalid_request":
        // Seen most after installing the fork without restarting the running server.
        return "this herdr server does not support live terminals. If you just installed "
            + "jerryfane/herdr, restart it: herdr server stop, then herdr"
    case "guest_revoked":
        return "your access to this agent was revoked; not reconnecting"
    case "guest_forbidden":
        return "guests can't open this pane; not reconnecting"
    default:
        return nil
    }
}

struct ResultEnvelope<R: Decodable>: Decodable {
    let id: String?
    let result: R
}

// MARK: - Agents

public struct ComposerEvidence: Decodable, Equatable, Sendable {
    public let provenance: String?
    public let region: String?
    public let cursor: String?
    public let style: String?
    public let frameStable: Bool?

    enum CodingKeys: String, CodingKey {
        case provenance, region, cursor, style
        case frameStable = "frame_stable"
    }
}

public struct ComposerState: Decodable, Equatable, Sendable {
    /// e.g. "draft_present", "unknown". A draft sitting unsent in the composer is
    /// the symptom herdr#18/#22 exist to make visible, so the client surfaces it.
    public let state: String?
    public let attemptID: String?
    public let evidence: ComposerEvidence?

    enum CodingKeys: String, CodingKey {
        case state
        case attemptID = "attempt_id"
        case evidence
    }

    public var hasUnsentDraft: Bool { state == "draft_present" }
}

public struct CompletedTurn: Decodable, Equatable, Sendable {
    public let turn: Int?
    public let turnEpoch: UInt64?
    public let completedUnixMs: Int64?

    enum CodingKeys: String, CodingKey {
        case turn
        case turnEpoch = "turn_epoch"
        case completedUnixMs = "completed_unix_ms"
    }
}

/// The `archived { at, by, reason }` provenance the daemon surfaces on an archived
/// agent in `agent.list` (issue #173). Its PRESENCE on an `AgentInfo` is the
/// load-bearing "this agent is archived" signal; absent means active. Decoded
/// leniently (at/by optional) so a partial record never fails the whole list.
public struct AgentArchivedInfo: Decodable, Equatable, Sendable {
    public let at: String?
    public let by: String?
    public let reason: String?
}

/// A native harness whose visible transcript Herdr can translate. Unknown
/// values remain decodable so a newer daemon cannot break the entire agent list
/// on an older app.
public enum AgentSessionTransferHarness: Codable, Hashable, Sendable {
    case claude
    case codex
    case omp
    case unrecognised(String)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "claude": self = .claude
        case "codex": self = .codex
        case "omp": self = .omp
        default: self = .unrecognised(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var rawValue: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .omp: "omp"
        case .unrecognised(let value): value
        }
    }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .omp: "Oh My Pi"
        case .unrecognised(let value): value
        }
    }
}

/// The durable two-phase transfer state reported on `AgentInfo.sessionTransfer`.
public enum AgentSessionTransferPhase: Decodable, Equatable, Sendable {
    case preparing
    case ready
    case verifyingCutover
    case launchingTarget
    case awaitingTarget
    case completed
    case rollingBack
    case rolledBack
    case failed
    case unrecognised(String)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "preparing": self = .preparing
        case "ready": self = .ready
        case "verifying_cutover": self = .verifyingCutover
        case "launching_target": self = .launchingTarget
        case "awaiting_target": self = .awaitingTarget
        case "completed": self = .completed
        case "rolling_back": self = .rollingBack
        case "rolled_back": self = .rolledBack
        case "failed": self = .failed
        default: self = .unrecognised(value)
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .rolledBack, .failed, .unrecognised: return true
        default: return false
        }
    }

    /// A known final state after which starting a new transfer is safe. An
    /// unknown phase stops polling, but remains durable and visible because an
    /// older app cannot prove that the transaction has finished.
    public var isConclusive: Bool {
        switch self {
        case .completed, .rolledBack, .failed: return true
        default: return false
        }
    }
}

/// Records intentionally omitted from the visible-message transcript. These are
/// counts, not silent loss: the confirmation UI names every category before cutover.
public struct AgentSessionTransferOmissions: Decodable, Equatable, Sendable {
    public let toolRecords: UInt64
    public let reasoningRecords: UInt64
    public let systemRecords: UInt64
    public let attachmentRecords: UInt64
    public let metadataRecords: UInt64
    public let unsupportedBlocks: UInt64
    public let sidechainRecords: UInt64

    public var total: UInt64 {
        toolRecords + reasoningRecords + systemRecords + attachmentRecords
            + metadataRecords + unsupportedBlocks + sidechainRecords
    }

    enum CodingKeys: String, CodingKey {
        case toolRecords = "tool_records"
        case reasoningRecords = "reasoning_records"
        case systemRecords = "system_records"
        case attachmentRecords = "attachment_records"
        case metadataRecords = "metadata_records"
        case unsupportedBlocks = "unsupported_blocks"
        case sidechainRecords = "sidechain_records"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toolRecords = try c.decodeIfPresent(UInt64.self, forKey: .toolRecords) ?? 0
        reasoningRecords = try c.decodeIfPresent(UInt64.self, forKey: .reasoningRecords) ?? 0
        systemRecords = try c.decodeIfPresent(UInt64.self, forKey: .systemRecords) ?? 0
        attachmentRecords = try c.decodeIfPresent(UInt64.self, forKey: .attachmentRecords) ?? 0
        metadataRecords = try c.decodeIfPresent(UInt64.self, forKey: .metadataRecords) ?? 0
        unsupportedBlocks = try c.decodeIfPresent(UInt64.self, forKey: .unsupportedBlocks) ?? 0
        sidechainRecords = try c.decodeIfPresent(UInt64.self, forKey: .sidechainRecords) ?? 0
    }
}

/// Reviewable transfer facts retained on the logical agent throughout prepare,
/// cutover, rollback, and completion. `targetAccount` is deliberately echoed so
/// reopening a prepared sheet never has to guess which account confirmation needs.
public struct AgentSessionTransferInfo: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let source: AgentSessionTransferHarness
    public let target: AgentSessionTransferHarness
    public let targetAccount: String?
    public let phase: AgentSessionTransferPhase
    public let messageCount: UInt64
    public let omissions: AgentSessionTransferOmissions
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case id, source, target, phase, omissions, error
        case targetAccount = "target_account"
        case messageCount = "message_count"
    }
}

/// A federated name as people read it. The daemon routes a remote machine's agents by
/// prefixing their names with the machine's ALIAS. While aliases came from hand-written
/// config they read as `pi-burj/voice`; since the daemon moved SSH federation onto saved
/// machines the alias is the profile's immutable 32-hex id, so the same name reads
/// `2cc0ffe3a0753cafcf28f46a7bb29351/voice`. When the daemon sends the machine's label,
/// that one prefix is swapped for it.
///
/// Only the exact `<machineID>/` prefix is replaced: the remainder may itself contain
/// slashes (`…/w1:pB` style ids), and a local name has no prefix to touch. An unlabelled
/// machine keeps the raw name rather than inventing one.
public enum FederatedName {
    public static func display(_ raw: String, machineID: String?, machineLabel: String?) -> String {
        guard let machineID, let machineLabel, !machineLabel.isEmpty else { return raw }
        let prefix = "\(machineID)/"
        guard raw.hasPrefix(prefix) else { return raw }
        return "\(machineLabel)/\(raw.dropFirst(prefix.count))"
    }
}

/// The fields a live status event rewrites (`agentStatus`, `inputPending`,
/// `inputPromptKind`, `statusSinceUnixMs` and the turn counters) are settable inside
/// HerdrKit only, so `AgentInfo.applying(_:)` can patch a listed row between
/// `agent.list` reloads. Everything else stays exactly what the daemon sent.
public struct AgentInfo: Decodable, Equatable, Sendable, Identifiable {
    public let agent: String?
    public internal(set) var agentStatus: String?
    /// Set when the agent is showing an interactive prompt/menu that needs an
    /// on-screen choice (a plan-approval or an AskUserQuestion) rather than a chat
    /// prompt. `agent.prompt` is REJECTED while this is true (or `agentStatus ==
    /// "blocked"`), so the app must drive the pane with raw keys / `pane.send_text`
    /// instead. `inputPromptKind` is the menu kind ("select" / "confirm"). Decoded
    /// leniently — absent on an older server.
    public internal(set) var inputPending: Bool?
    public internal(set) var inputPromptKind: String?
    public let name: String?
    public let paneID: String
    public let tabID: String?
    public let workspaceID: String?
    public let terminalID: String?
    public let terminalTitleStripped: String?
    public let cwd: String?
    public let focused: Bool?
    public let interactiveReady: Bool?
    public let composer: ComposerState?
    /// Monotonic per-agent change counters. These are what make revision-gated
    /// refresh possible: poll the cheap list, fetch a screen only when one moves.
    public let revision: Int?
    public let stateChangeSeq: UInt64?
    /// Wall-clock ms when the agent entered its CURRENT status (daemon #173). `nil`
    /// until the first transition / on an older server. The card derives a compact
    /// "5m/2h/3d" time-in-state badge from `now - this`.
    public internal(set) var statusSinceUnixMs: UInt64?
    public internal(set) var turn: Int?
    public internal(set) var turnEpoch: UInt64?
    public internal(set) var lastCompletedTurn: CompletedTurn?
    /// Federation (daemon W3+): for a remote agent, the owning peer's alias
    /// (`machineID`, also carried as the `<alias>/…` prefix on `name`/`paneID`),
    /// the peer's reachability as of the home's last poll, and the agent's
    /// last-known status while its machine is unreachable. All absent on a local
    /// agent or a non-federated server — decoded leniently, so an older or
    /// non-federated server is unaffected.
    public let machineID: String?
    /// The peer's human label, when the daemon reports one. `machineID` is the
    /// saved profile's immutable id, so since the daemon moved SSH federation
    /// onto saved machines it is a 32-character hex string — and it is also the
    /// `<alias>/…` prefix baked into `name`, which is why unlabelled rows read
    /// as `2cc0ffe…/voice`. Absent on a local agent, an older daemon, or an
    /// explicit non-saved peer; decoded leniently so those stay unaffected.
    public let machineLabel: String?
    public let reachability: String?
    public let lastKnownStatus: String?
    /// Present only for an archived agent (issue #173). Its presence is the
    /// load-bearing "is archived" signal; absent means active. Decoded leniently,
    /// so an older/non-archiving server is unaffected.
    public let archived: AgentArchivedInfo?
    /// Account routing: which credential/config-home account this agent runs under
    /// (`account`), the directory that account resolves to (`accountConfigDir`, a PATH,
    /// never a credential), and whether the recorded account is missing from the
    /// server's registry (`accountUnresolved`).
    ///
    /// Reported because an agent silently coming back on the WRONG account is what a
    /// person experiences as hours of lost history — the work is intact, in another
    /// account's transcript. Decoded leniently: all absent on an older server, which
    /// reads as "this server does not report routing", not as an error.
    public let account: String?
    public let accountConfigDir: String?
    public let accountUnresolved: Bool?
    /// Present while a Claude Code/Codex transfer is staged or launching, and
    /// retained with its final outcome. Absent on older daemons.
    public let sessionTransfer: AgentSessionTransferInfo?
    /// Guest connections only: whether the shared agent is the pane's foreground
    /// program. False means guest access is paused. Absent for owners.
    public let guestRunning: Bool?
    /// The owner's chosen picture for this agent (herdrup#538), shared with every owner
    /// device and every guest of the agent. Absent means the agent's initial tile. Decoded
    /// leniently (`AgentAvatarDescriptor` never throws), so an odd value cannot fail the list.
    public let avatar: AgentAvatarDescriptor?

    /// Stable list identity. A LIVE agent is keyed on its pane id, which is unique
    /// and stable while it runs. An ARCHIVED agent has NO pane — the server empties
    /// `pane_id` because the pane is genuinely released (herdr src/app/agents.rs
    /// `archived_agent_info`) — so keying on it collapsed EVERY archived row onto the
    /// same `""` identity, and SwiftUI rendered them all as whichever one sorted
    /// first. That is the duplicate-name bug: the archived section sorts
    /// most-recently-archived first, so every row wore the last-archived name, and
    /// walked to the next name as each was unarchived.
    ///
    /// `terminal_id` is the durable handle: always non-empty, unique, and preserved
    /// across archive/unarchive (the server rehydrates the same terminal id on
    /// resume). It is also what `agent.unarchive` accepts as a target. `name` is the
    /// last resort — it can be nil for an unnamed agent, so it cannot lead.
    public var id: String {
        if !paneID.isEmpty { return paneID }
        return terminalID ?? name ?? paneID
    }

    /// This agent has been archived (its pane released, session preserved).
    public var isArchived: Bool { archived != nil }

    /// Human label for a pane, preferring the agent's assigned name; a federated agent's
    /// shows its machine's label rather than its id (`FederatedName`).
    public var displayName: String {
        FederatedName.display(name ?? terminalTitleStripped ?? paneID,
                              machineID: machineID, machineLabel: machineLabel)
    }

    /// Activity without the CLI's leading prompt/spinner decoration.
    public var activityText: String? {
        guard let terminalTitleStripped else { return nil }
        let activity = AgentPresentation.activity(terminalTitleStripped)
        return activity.isEmpty ? nil : activity
    }

    public var isWorking: Bool { agentStatus == "working" }

    /// The agent is showing an interactive menu / permission prompt (plan-approval or
    /// AskUserQuestion) that must be answered on-screen. `agent.prompt` is refused in
    /// this state, so the app routes input as raw keys / `pane.send_text` instead.
    public var isAwaitingMenuInput: Bool { agentStatus == "blocked" || inputPending == true }

    /// A remote (federated) agent whose owning machine is currently unreachable.
    /// Its `agentStatus` is a stale last-known value, so the UI must render it as
    /// offline rather than as a live status. Unknown reachability strings (a newer
    /// server) read as reachable — the safe default is "not offline".
    public var isUnreachable: Bool { reachability == "unreachable" }

    /// A remote agent whose status the home has NOT confirmed on its latest poll:
    /// `degraded` (the daemon's 1 to 2 missed polls) or the fully `unreachable` case.
    ///
    /// The distinction matters because the daemon overwrites `agent_status` with
    /// "unknown" the moment reachability leaves `reachable`, and moves the real state
    /// into `last_known_status`. `AgentRow.resolvedGroup` surfaces a last-known BLOCKED
    /// row into needs-you, so without this the reader could not tell a colleague
    /// genuinely waiting from a guess about a machine that went quiet.
    ///
    /// Enumerated rather than `!= "reachable"`, matching `isUnreachable` above: an
    /// unknown string from a newer server reads as fresh, because the safe default is
    /// not to stamp every row as stale.
    public var hasUnconfirmedStatus: Bool {
        reachability == "degraded" || reachability == "unreachable"
    }

    /// This agent's recorded account is gone from the server's registry, so it will
    /// REFUSE to resume rather than come back on the default account and append to the
    /// wrong transcript. An error state a person must act on (re-register the account),
    /// not a transient. Absent on an older server reads as false — the safe default is
    /// "nothing is wrong", since such a server reports no routing at all.
    public var hasUnresolvedAccount: Bool { accountUnresolved == true }

    enum CodingKeys: String, CodingKey {
        case agent, name, composer, revision, turn, cwd, focused, reachability, archived
        case account, avatar
        case agentStatus = "agent_status"
        case inputPending = "input_pending"
        case inputPromptKind = "input_prompt_kind"
        case paneID = "pane_id"
        case tabID = "tab_id"
        case workspaceID = "workspace_id"
        case terminalID = "terminal_id"
        case terminalTitleStripped = "terminal_title_stripped"
        case interactiveReady = "interactive_ready"
        case stateChangeSeq = "state_change_seq"
        case statusSinceUnixMs = "status_since_unix_ms"
        case turnEpoch = "turn_epoch"
        case lastCompletedTurn = "last_completed_turn"
        case machineID = "machine_id"
        case machineLabel = "machine_label"
        case lastKnownStatus = "last_known_status"
        case accountConfigDir = "account_config_dir"
        case accountUnresolved = "account_unresolved"
        case sessionTransfer = "session_transfer"
        case guestRunning = "guest_running"
    }
}

struct AgentListResult: Decodable {
    let agents: [AgentInfo]
    /// The answering daemon's own `ping` capabilities. Absent on daemons that
    /// predate the field.
    let originCapabilities: ServerCapabilities?
    /// The answering daemon's install id. Absent on daemons that predate the field.
    let originMachineID: String?

    enum CodingKeys: String, CodingKey {
        case agents
        case originCapabilities = "origin_capabilities"
        case originMachineID = "origin_machine_id"
    }
}

/// `agent.list` with the answering daemon's capabilities (`origin_capabilities`).
/// `originCapabilities` is nil on a daemon that predates the field; `ping` is the
/// fallback there. `originMachineID` is the install id a question push names as its
/// `machine_id`, which is how a lock-screen answer finds its way back to this daemon.
public struct AgentListing: Sendable, Equatable {
    public let agents: [AgentInfo]
    public let originCapabilities: ServerCapabilities?
    public let originMachineID: String?

    public init(agents: [AgentInfo], originCapabilities: ServerCapabilities?, originMachineID: String? = nil) {
        self.agents = agents
        self.originCapabilities = originCapabilities
        self.originMachineID = originMachineID
    }
}

// MARK: - Accounts (credential subscriptions)

/// One credential account (subscription) the daemon knows about — the app half of
/// "multiple subscriptions per harness + swap". Mirrors the server's `AccountInfo`
/// (`accounts.list` → `{ accounts: [AccountInfo] }`) BYTE-FOR-BYTE.
///
/// `kind` carries the SAME strings as `AgentInfo.agent` (claude/codex/kimi), so an
/// agent may swap only among accounts whose `kind == agent.agent`. `usage` is
/// omitted by the server when it has no usage data, so it decodes to nil.
public struct CredentialAccount: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: String
    public let label: String
    public let active: Bool
    /// The account's login email, when the daemon can derive it. Optional → an
    /// older daemon that omits it decodes to nil. Identity only, never a secret.
    public let email: String?
    /// The account's config-home directory (daemon exposes it on accounts.list),
    /// e.g. `/root/.claude-2`. A non-secret path, never a credential. Optional → an
    /// older daemon that omits it decodes to nil. The in-app login/logout points
    /// `CLAUDE_CONFIG_DIR` at it so the flow targets the right account.
    public let configDir: String?
    public let usage: AccountUsage?

    enum CodingKeys: String, CodingKey {
        case id, kind, label, active, email, usage
        case configDir = "config_dir"
    }
}

/// One rate-limit window for an account (a 5-hour or weekly bucket, etc.).
public struct UsageWindow: Decodable, Equatable, Sendable, Identifiable {
    public let label: String
    public let usedPercent: Double?
    public let resetsAt: String?
    public let status: String?
    public var id: String { label }
    enum CodingKeys: String, CodingKey {
        case label
        case usedPercent = "used_percent"
        case resetsAt = "resets_at"
        case status
    }
}

/// A credential account's usage snapshot. EVERY field is optional — the server
/// omits any it cannot report, so a bare `{}` (or a missing `usage`) is valid and
/// must decode without failing.
///
/// `windows` is the current shape (any number of rate-limit buckets). `source`
/// is "live" (fetched from the provider) or "local" (read on-disk). The flat
/// `primaryUsedPercent`/`secondaryUsedPercent`/`resetsAt` are back-compat mirrors
/// of the first two windows (older daemons send only those); prefer `windows`.
public struct AccountUsage: Decodable, Equatable, Sendable {
    public let windows: [UsageWindow]
    public let source: String?
    public let primaryUsedPercent: Double?
    public let secondaryUsedPercent: Double?
    public let resetsAt: String?
    public let plan: String?
    public let tier: String?
    enum CodingKeys: String, CodingKey {
        case windows, source, plan, tier
        case primaryUsedPercent = "primary_used_percent"
        case secondaryUsedPercent = "secondary_used_percent"
        case resetsAt = "resets_at"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `windows` may be absent on older daemons — default to empty.
        windows = try c.decodeIfPresent([UsageWindow].self, forKey: .windows) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source)
        primaryUsedPercent = try c.decodeIfPresent(Double.self, forKey: .primaryUsedPercent)
        secondaryUsedPercent = try c.decodeIfPresent(Double.self, forKey: .secondaryUsedPercent)
        resetsAt = try c.decodeIfPresent(String.self, forKey: .resetsAt)
        plan = try c.decodeIfPresent(String.self, forKey: .plan)
        tier = try c.decodeIfPresent(String.self, forKey: .tier)
    }

    /// The windows to render: the real `windows` list when present, else a
    /// synthesized pair from the back-compat flat fields (older daemon).
    public var effectiveWindows: [UsageWindow] {
        if !windows.isEmpty { return windows }
        var out: [UsageWindow] = []
        if let p = primaryUsedPercent {
            out.append(UsageWindow(label: "5h", usedPercent: p, resetsAt: resetsAt, status: nil))
        }
        if let s = secondaryUsedPercent {
            out.append(UsageWindow(label: "weekly", usedPercent: s, resetsAt: nil, status: nil))
        }
        return out
    }
}

struct AccountsListResult: Decodable {
    let accounts: [CredentialAccount]
}

// MARK: - Reads

public enum ReadSource: String, Codable, Sendable {
    case visible, recent
    case recentUnwrapped = "recent_unwrapped"
    /// Detection source ignores an `ansi` format request and returns plain text.
    /// Verified on a live server; it is the only source/format pair that does.
    case detection
}

public enum ReadFormat: String, Codable, Sendable {
    case text, ansi
}

public struct PaneRead: Decodable, Equatable, Sendable {
    public let paneID: String
    public let text: String
    public let truncated: Bool?
    public let source: String?
    public let format: String?

    enum CodingKeys: String, CodingKey {
        case text, truncated, source, format
        case paneID = "pane_id"
    }
}

struct PaneReadResult: Decodable {
    let read: PaneRead
}

// MARK: - Prompt delivery

/// herdr's `AgentPromptDelivery`: whether the prompt bytes only reached the pane's
/// composer (`writtenToPty`) or a turn actually STARTED (`submitted`). Mirrors the
/// server enum's snake_case wire values (src/api/schema/agents.rs). These are
/// different facts — the whole point of herdr#18/#26 lives in the gap between them
/// — so the app decodes which one the server confirmed rather than collapsing both
/// into "sent".
public enum PromptDelivery: String, Decodable, Sendable, Equatable {
    case writtenToPty = "written_to_pty"
    case submitted
}

/// The `agent.prompt` result (`type: "agent_prompted"`). Only `delivery` is
/// decoded — the echoed `agent` is deliberately not modelled so a schema change on
/// it cannot break this decode. `delivery` is optional: the server omits it on
/// paths that do not determine one.
public struct PromptResult: Decodable, Sendable, Equatable {
    public let delivery: PromptDelivery?
}

/// What a rejected `agent.prompt` establishes about a send.
///
/// A timeout may occur before or after the PTY write, so it is not permission
/// to resend. Older daemons report an acknowledged PTY write as
/// `agent_prompt_unverifiable` or `agent_prompt_stalled`; these establish delivery
/// to the terminal but not submission by the agent. Current daemons return the
/// same distinction in `PromptResult.delivery` instead.
///
/// One classification serves both composer restoration and the visible receipt.
public enum PromptRejection: Equatable, Sendable {
    /// Unknown whether the PTY write happened.
    case unconfirmed
    /// Bytes reached the terminal; agent submission was not verified.
    case writtenUnverified
    /// Submission was confirmed, but a requested status was not observed.
    case submittedStatusUnknown
    /// Written, and still sitting unsubmitted in the agent's OWN composer
    /// (`agent_prompt_unsubmitted`).
    ///
    /// Counted as reached, NOT as a failure to hand back: the text is visible in the
    /// terminal, so nothing is lost, while restoring it into the app's composer makes
    /// the obvious next tap a resend that stacks a second copy behind the first in the
    /// agent's composer. The fix the reader needs is Enter on the draft already there.
    case leftInComposer
    /// Never reached the agent: occupant changed, agent not ready, input pending, a
    /// refusal, or any code this client does not know. Unknown codes land here on
    /// purpose — giving the reader their text back is the safe answer to an error we
    /// cannot read.
    case notDelivered

    public init(_ error: APIError) {
        switch error.code {
        case "timeout": self = .unconfirmed
        case "agent_prompt_unverifiable", "agent_prompt_stalled": self = .writtenUnverified
        case "agent_status_unobserved_after_submit": self = .submittedStatusUnknown
        case "agent_prompt_unsubmitted": self = .leftInComposer
        default: self = .notDelivered
        }
    }

    /// True when the text may already be with the agent, so handing it (or an
    /// attachment batch) back for a resend would duplicate the prompt.
    public var mayHaveReachedAgent: Bool { self != .notDelivered }
}

// MARK: - Events

/// Subscription types the server actually accepts.
///
/// Deliberately does NOT include `pane.output_changed`: that kind exists inside
/// the server (`EventKind::PaneOutputChanged`) but is absent from the
/// `Subscription` enum, so subscribing to it is rejected. Verified by reading
/// the server's own rejection message. The consequence is that events give only
/// coarse invalidation — there is no per-output tick HERE to drive terminal refresh.
///
/// The per-output push this comment used to lament is now delivered out-of-band by
/// the `pane.stream` method (`HerdrClient.streamTerminal`), which streams the raw
/// PTY bytes themselves rather than an invalidation tick — see the "Live terminal
/// stream" section below. `events.subscribe` stays the coarse status channel.
public enum SubscriptionType: String, Codable, Sendable {
    case paneCreated = "pane.created"
    case paneUpdated = "pane.updated"
    case paneFocused = "pane.focused"
    case paneClosed = "pane.closed"
    case paneExited = "pane.exited"
    case paneAgentDetected = "pane.agent_detected"
    case paneAgentStatusChanged = "pane.agent_status_changed"
    case paneTurnCompleted = "pane.turn_completed"
    case paneScrollChanged = "pane.scroll_changed"
    case paneOutputMatched = "pane.output_matched"
    case layoutUpdated = "layout.updated"
}

/// A single subscription entry. Pane-scoped kinds require `paneID`; the server
/// rejects them with "missing field pane_id" otherwise. The one exception is a
/// daemon advertising `events_v2`: there `pane.agent_status_changed` and
/// `pane.turn_completed` accept no `paneID` and watch every pane, including
/// alias-qualified remote panes on a federation coordinator.
public struct Subscription: Encodable, Sendable {
    public let type: SubscriptionType
    public let paneID: String?

    public init(_ type: SubscriptionType, paneID: String? = nil) {
        self.type = type
        self.paneID = paneID
    }

    enum CodingKeys: String, CodingKey {
        case type
        case paneID = "pane_id"
    }
}

struct SubscribeParams: Encodable {
    let subscriptions: [Subscription]
    /// Opts into `lagged` / `heartbeat` control lines and per-entry rejection.
    /// Nil is omitted from the request, which is the pre-v2 wire shape.
    var eventsV2: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case subscriptions
        case eventsV2 = "events_v2"
    }
}

/// A line arriving on the event stream: either the opening acknowledgement or an event.
public enum StreamLine: Sendable, Equatable {
    case subscriptionStarted
    case event(kind: String, paneID: String?, raw: String)
    case other(raw: String)
}

// MARK: - Live terminal stream (pane.stream / pane.set_pty_size)
//
// Wire types for herdr's `pane.stream` raw PTY byte firehose and its companion
// `pane.set_pty_size`. Field names mirror the herdr Rust schema EXACTLY so the
// app decodes the server byte-for-byte:
//   - request params:  src/api/schema/panes.rs::PaneStreamParams / PaneSetPtySizeParams
//   - open ack:        src/api/schema/response.rs::ResponseResult::StreamStarted
//   - frame lines:     src/api/server/pane_output_stream.rs::StreamFrameLine
//   - resize result:   src/api/schema/response.rs::ResponseResult::PanePtySize
// Frames ride the SAME `\n`-delimited framing `events.subscribe` uses, but the raw
// PTY bytes are carried base64'd in `data_b64` because raw terminal output holds
// 0x0A, control bytes, and partial UTF-8 that a JSON string / line-framing cannot.

/// The first line of a `pane.stream` response: the `stream_started` ack, carrying
/// the pane geometry (cols/rows) and the runtime generation the app previously
/// lacked. `type` is `stream_started`; extra keys are ignored on decode.
public struct StreamStarted: Decodable, Sendable, Equatable {
    public let paneID: String
    public let epoch: UInt64
    public let cols: Int
    public let rows: Int
    /// Absolute byte offset of the seed's first byte since pane birth. Carried for
    /// a later gap-free resume; v1 always re-seeds a fresh reset.
    public let baseSeq: UInt64
    public let resync: Bool

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case epoch, cols, rows, resync
        case baseSeq = "base_seq"
    }
}

/// One decoded `pane.stream` frame line. The discriminator is the `frame` field
/// (herdr's `StreamFrameLine.frame`), tagged `"stream":"pane.bytes"`. `data_b64`
/// is decoded to raw `Data` here so callers feed bytes straight to a VT emulator.
public enum StreamFrame: Sendable, Equatable {
    /// Full-screen (re)seed. `lagged` = the client fell behind and the server
    /// dropped the backlog and re-seeded, so the caller should clear before feeding.
    /// `history` = the scrollback rows above this screen, oldest first, captured with
    /// it (`scrollback_lines` requested); `nil` from a server that does not send it.
    /// `historyCursor` = the `pane.history` token for the OLDEST row of `history`; only a
    /// `pane_history` server sends it, and only when older rows exist above that row.
    case reset(seq: UInt64, epoch: UInt64, cols: Int, rows: Int, data: Data, history: Data?,
               historyCursor: String?, lagged: Bool)
    /// Raw PTY delta bytes, to be fed to the emulator in `seq` order.
    case data(seq: UInt64, epoch: UInt64, data: Data)
    /// In-band SIGWINCH: the PTY winsize changed at this offset.
    case resize(seq: UInt64, epoch: UInt64, cols: Int, rows: Int)
    /// ~20s idle heartbeat; carries no payload and can be ignored.
    case ping(seq: UInt64, epoch: UInt64)
    /// The process is gone; the server closes the socket after this frame.
    case exited(seq: UInt64, epoch: UInt64)
}

extension StreamFrame: Decodable {
    private enum CodingKeys: String, CodingKey {
        case stream, frame, seq, epoch, cols, rows
        case dataB64 = "data_b64"
        case historyB64 = "history_b64"
        case historyCursor = "history_cursor"
        case lagged
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A pane.stream frame line MUST carry the `pane.bytes` stream tag. Anything
        // else on this channel is a foreign or corrupt line — reject it so the caller
        // FAILS the stream (and reconnects to a fresh reset) rather than feeding a
        // stateful VT emulator bytes from an unknown source.
        let stream = try c.decode(String.self, forKey: .stream)
        guard stream == "pane.bytes" else {
            throw DecodingError.dataCorruptedError(
                forKey: .stream, in: c,
                debugDescription: "unexpected stream '\(stream)' (want pane.bytes)")
        }
        let frame = try c.decode(String.self, forKey: .frame)
        // Decoding is STRICT. A raw byte stream is stateful: silently dropping a
        // frame (or its bytes) would resume the emulator mid-CSI/OSC/UTF-8 and
        // corrupt the screen permanently. So seq/epoch are required, and a
        // malformed line throws here — the caller then tears the stream down and
        // reconnects for a clean full-screen reset instead of feeding garbage.
        let seq = try c.decode(UInt64.self, forKey: .seq)
        let epoch = try c.decode(UInt64.self, forKey: .epoch)
        // `data_b64` is base64 of raw PTY bytes; on the frames that carry it it is
        // required AND must be valid base64, so a truncated payload fails loudly.
        func payload(_ key: CodingKeys = .dataB64) throws -> Data {
            let b64 = try c.decode(String.self, forKey: key)
            guard let bytes = Data(base64Encoded: b64) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: c,
                    debugDescription: "\(key.stringValue) is not valid base64")
            }
            return bytes
        }
        switch frame {
        case "reset":
            let cols = try c.decode(Int.self, forKey: .cols)
            let rows = try c.decode(Int.self, forKey: .rows)
            // Server omits `lagged` when false (skip_serializing_if is_false).
            let lagged = (try? c.decode(Bool.self, forKey: .lagged)) ?? false
            // Absent from servers that do not window history into keyframes; present
            // (possibly empty) once asked for, and then strict like `data_b64`.
            let history = c.contains(.historyB64) ? try payload(.historyB64) : nil
            let historyCursor = try c.decodeIfPresent(String.self, forKey: .historyCursor)
            self = .reset(seq: seq, epoch: epoch, cols: cols, rows: rows, data: try payload(),
                          history: history, historyCursor: historyCursor, lagged: lagged)
        case "data":
            self = .data(seq: seq, epoch: epoch, data: try payload())
        case "resize":
            let cols = try c.decode(Int.self, forKey: .cols)
            let rows = try c.decode(Int.self, forKey: .rows)
            self = .resize(seq: seq, epoch: epoch, cols: cols, rows: rows)
        case "ping":
            self = .ping(seq: seq, epoch: epoch)
        case "exited":
            self = .exited(seq: seq, epoch: epoch)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .frame, in: c,
                debugDescription: "unknown pane.stream frame '\(frame)'")
        }
    }
}

// MARK: - pane.input.stream (ordered, fire-and-forget key input)

/// Open params for `pane.input.stream`: the write-side mirror of `pane.stream`.
public struct PaneInputStreamParams: Encodable, Sendable {
    public let paneID: String
    /// `"app"` when the owner's app opens it: every frame on the stream is the owner's typing.
    public let inputSource: String?
    public init(paneID: String, inputSource: String?) {
        self.paneID = paneID
        self.inputSource = inputSource
    }
    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case inputSource = "input_source"
    }
}

/// One line the daemon writes on an open `pane.input.stream`. Frames themselves are
/// encoded by `PaneInputFrame`.
enum PaneInputStreamReply: Equatable {
    /// The open request's `{"id":…,"result":{"type":"ok"}}`.
    case opened
    /// `{"seq":N,"ok":true}`: frame N reached the PTY.
    case acked(UInt64)
    /// `{"seq":N,"error":{…}}`: frame N was refused; the daemon closes the stream.
    case frameRejected(seq: UInt64, APIError)
    /// An error envelope carrying the open request's id (unknown pane, guest, a
    /// malformed frame); the daemon closes the stream.
    case rejected(APIError)

    private struct Line: Decodable {
        struct OpenResult: Decodable { let type: String? }
        let seq: UInt64?
        let ok: Bool?
        let error: APIError?
        let result: OpenResult?
    }

    /// nil for a line that is none of these; the caller ignores it.
    init?(line: String) {
        guard let decoded = try? JSONDecoder().decode(Line.self, from: Data(line.utf8)) else { return nil }
        switch (decoded.seq, decoded.error) {
        case let (seq?, error?): self = .frameRejected(seq: seq, error)
        case let (nil, error?): self = .rejected(error)
        case let (seq?, nil):
            guard decoded.ok == true else { return nil }
            self = .acked(seq)
        case (nil, nil):
            guard let result = decoded.result else { return nil }
            self = result.type == "ok"
                ? .opened
                : .rejected(APIError(code: "unexpected_open_reply", message: line))
        }
    }
}

/// What `streamTerminal` yields, mirroring how `subscribe` unifies its ack + event
/// lines into one `StreamLine`: the opening `stream_started` ack, then frames.
public enum TerminalStreamEvent: Sendable, Equatable {
    case started(StreamStarted)
    case frame(StreamFrame)
}

/// `pane.stream` subscription params. Only `pane_id` is required; the rest carry
/// server defaults / resume hints (v1 ignores resume and always re-seeds). Nil
/// optionals are omitted by the synthesized encoder, matching serde's
/// `skip_serializing_if = "Option::is_none"`.

public struct PaneStreamParams: Encodable, Sendable {
    public let paneID: String
    public let includeHistory: Bool
    public let resumeFrom: UInt64?
    public let epoch: UInt64?
    public let maxFrameBytes: Int?
    public let scrollbackLines: Int?
    /// Opaque per-view identity for the daemon's PTY width-lease bookkeeping (#137).
    /// The daemon ties a viewer's width-lease liveness to its `pane.stream`: it drops
    /// that viewer's lease when this stream closes. MUST be the SAME value the view
    /// sends on its `pane.set_pty_size` (`PaneSetPtySizeParams.viewerID`) so the lease
    /// taken there is the one released when this stream ends. Optional/omitted-when-nil:
    /// an older daemon ignores it and a caller that doesn't lease leaves it nil.
    public let viewerID: String?

    public init(
        paneID: String,
        includeHistory: Bool = true,
        resumeFrom: UInt64? = nil,
        epoch: UInt64? = nil,
        maxFrameBytes: Int? = nil,
        scrollbackLines: Int? = nil,
        viewerID: String? = nil
    ) {
        self.paneID = paneID
        self.includeHistory = includeHistory
        self.resumeFrom = resumeFrom
        self.epoch = epoch
        self.maxFrameBytes = maxFrameBytes
        self.scrollbackLines = scrollbackLines
        self.viewerID = viewerID
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case includeHistory = "include_history"
        case resumeFrom = "resume_from"
        case epoch
        case maxFrameBytes = "max_frame_bytes"
        case scrollbackLines = "scrollback_lines"
        case viewerID = "viewer_id"
    }
}

/// `pane.set_pty_size` params — sets the REAL PTY winsize (distinct from
/// `pane.resize`, which is a layout split ratio). `lock:true` takes geometry
/// ownership so the desktop TUI stops re-asserting layout size. `lock:false` still
/// resizes the shared PTY (the server resizes, then releases ownership), so a
/// co-viewing desktop reflows transiently — it just is not pinned to the new size.
public struct PaneSetPtySizeParams: Encodable, Sendable {
    public let paneID: String
    public let cols: Int
    public let rows: Int
    public let cellWidthPx: UInt32?
    public let cellHeightPx: UInt32?
    public let lock: Bool
    /// Opaque per-view identity for the daemon's PTY width-lease (#137). The daemon
    /// keys a viewer's width-lease on this: the WIDEST active viewer's geometry wins,
    /// so a narrow viewer no longer shrinks a wider co-viewer. MUST equal the value
    /// this view sends on its `pane.stream` open (`PaneStreamParams.viewerID`) — the
    /// daemon drops this lease when that stream closes. Optional/omitted-when-nil so an
    /// older daemon (and a non-leasing caller) is unaffected.
    public let viewerID: String?
    /// Lease time-to-live in milliseconds (#137). The daemon clamps to [1, 86_400_000]
    /// and applies a 5-minute default (`DEFAULT_PTY_LEASE_TTL`) when omitted. A
    /// foreground view re-sends within the TTL to keep its lease alive. Optional/
    /// omitted-when-nil.
    public let ttl: UInt64?

    public init(
        paneID: String,
        cols: Int,
        rows: Int,
        cellWidthPx: UInt32? = nil,
        cellHeightPx: UInt32? = nil,
        lock: Bool = false,
        viewerID: String? = nil,
        ttl: UInt64? = nil
    ) {
        self.paneID = paneID
        self.cols = cols
        self.rows = rows
        self.cellWidthPx = cellWidthPx
        self.cellHeightPx = cellHeightPx
        self.lock = lock
        self.viewerID = viewerID
        self.ttl = ttl
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case cols, rows, lock
        case cellWidthPx = "cell_width_px"
        case cellHeightPx = "cell_height_px"
        case viewerID = "viewer_id"
        case ttl = "ttl_ms"
    }
}

/// Result of `pane.set_pty_size` (`type: "pane_pty_size"`): the size actually
/// applied and whether geometry ownership is now locked. Mirrors the server's
/// `ResponseResult::PanePtySize` EXACTLY — `pane_id/cols/rows/locked`, no `epoch`
/// (the resize result carries none; the stream ack is where an epoch would live).
public struct PanePtySize: Decodable, Sendable, Equatable {
    public let paneID: String
    public let cols: Int
    public let rows: Int
    public let locked: Bool

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case cols, rows, locked
    }
}

// MARK: - pane.history (older scrollback, paged by cursor)

/// Params of `pane.history`. `cursor` is a token the server issued (a reset's
/// `history_cursor` or a previous page's `cursor`); it follows its row while the pane
/// keeps writing, which a row number could not.
public struct PaneHistoryParams: Encodable, Sendable {
    public let paneID: String
    public let cursor: String
    public let lines: UInt32

    public init(paneID: String, cursor: String, lines: UInt32) {
        self.paneID = paneID
        self.cursor = cursor
        self.lines = lines
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case cursor, lines
    }
}

/// Result of `pane.history` (`type: "pane_history"`): the rows directly ABOVE the
/// requested cursor's row, oldest first, rendered like a keyframe's `history_b64`.
/// `cursor` addresses the oldest row returned, i.e. the next older page; nil once the
/// page reached the start of the history the server still keeps.
public struct PaneHistoryPage: Decodable, Sendable, Equatable {
    public let paneID: String
    public let data: Data
    public let rows: Int
    public let cursor: String?

    public init(paneID: String, data: Data, rows: Int, cursor: String?) {
        self.paneID = paneID
        self.data = data
        self.rows = rows
        self.cursor = cursor
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case historyB64 = "history_b64"
        case rows, cursor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paneID = try c.decode(String.self, forKey: .paneID)
        rows = try c.decode(Int.self, forKey: .rows)
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
        // Strict like a keyframe's history: these bytes go into a stateful emulator, so a
        // truncated payload must fail the page rather than be fed half-decoded.
        let b64 = try c.decode(String.self, forKey: .historyB64)
        guard let bytes = Data(base64Encoded: b64) else {
            throw DecodingError.dataCorruptedError(
                forKey: .historyB64, in: c, debugDescription: "history_b64 is not valid base64")
        }
        data = bytes
    }
}

/// Why `pane.history` produced no page. Both mean "stop paging": neither becomes true
/// by retrying the same cursor.
public enum PaneHistoryError: Error, Equatable, Sendable {
    /// `history_cursor_expired`: the token is unknown to this server process (restart,
    /// handoff, evicted) or its row was trimmed off the top of the pane's scrollback.
    case historyCursorExpired
    /// The server cannot deserialize `pane.history` at all (it predates `pane_history`).
    case unsupported
}

// MARK: - Server / ping and daemon version (server.staged_update)

/// Feature flags returned by `ping`. Missing fields decode false so a newer app
/// talking to an older daemon simply hides unsupported controls.
public struct ServerCapabilities: Decodable, Equatable, Sendable {
    public let liveHandoff: Bool
    public let paneInputStream: Bool
    public let gramUploadStream: Bool
    public let agentSessionTransfer: Bool
    /// Nil means the daemon predates explicit harness advertisement and uses
    /// the legacy Claude/Codex pair. An explicit list, including an empty or
    /// future-only one, must not be replaced with that fallback.
    public let agentSessionTransferHarnesses: [AgentSessionTransferHarness]?
    /// `events.subscribe` accepts `events_v2: true` (control lines, `seq`,
    /// per-entry rejection) and all-pane status / turn entries without a `pane_id`.
    /// On a federation coordinator those entries also carry relayed remote panes.
    public let eventsV2: Bool
    /// `agent.forget` removes an archived agent's record (herdr#291), #380.
    public let agentForget: Bool
    /// `herdr api-bridge --multi` exists: one exec channel serves many requests
    /// (herdr PR #296). `CitadelTransport` routes one-off requests over it (#390).
    public let apiBridgeMulti: Bool
    /// `pane.history` pages older scrollback by cursor, and `pane.stream` resets carry
    /// `history_cursor` (herdr terminal history paging).
    public let paneHistory: Bool
    /// `agent.transcript` pages an omp agent's conversation for the Chat view (herdr#306).
    public let agentTranscript: Bool
    /// `agent.answer` answers omp's pending `ask` question from the app (herdr#308).
    public let agentAnswer: Bool
    /// `agent.avatar.set` / `agent.avatar.get` exist and `AgentInfo.avatar` is reported
    /// (herdrup#538). False hides the avatar editing UI; agents still show their initial tile.
    public let agentAvatar: Bool
    /// `agent.groups.get` / `agent.groups.set`: the owner's agent folders and stars (#552).
    public let agentGroups: Bool
    /// `server.update_check` / `update_apply` / `update_status`: the server updates itself to
    /// the newest signed preview (jerryfane/herdr#336). False on older servers, which have to
    /// be updated once by hand.
    public let serverUpdate: Bool
    /// herdr keeps each turn's origin (owner's or not, from `input_source: "app"`): finished
    /// pushes honour `notify_finishes_mine_only`, and `agent.transcript` marks prompts that
    /// were not the owner's with `origin: "other"` (owner decision 2026-11-06).
    public let turnOrigin: Bool
    /// herdr parses omp's HTML-form `ask` (omp ≥ 18.18.3) into `form`, reports its answer, and
    /// answers it with `agent.answer_form`. False: a form shows read-only with "Answer in Terminal".
    public let askForm: Bool

    enum CodingKeys: String, CodingKey {
        case liveHandoff = "live_handoff"
        case paneInputStream = "pane_input_stream"
        case gramUploadStream = "gram_upload_stream"
        case agentSessionTransfer = "agent_session_transfer"
        case agentSessionTransferHarnesses = "agent_session_transfer_harnesses"
        case eventsV2 = "events_v2"
        case agentForget = "agent_forget"
        case apiBridgeMulti = "api_bridge_multi"
        case paneHistory = "pane_history"
        case agentTranscript = "agent_transcript"
        case agentAnswer = "agent_answer"
        case agentAvatar = "agent_avatar"
        case agentGroups = "agent_groups"
        case serverUpdate = "server_update"
        case turnOrigin = "turn_origin"
        case askForm = "ask_form"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        liveHandoff = try c.decodeIfPresent(Bool.self, forKey: .liveHandoff) ?? false
        paneInputStream = try c.decodeIfPresent(Bool.self, forKey: .paneInputStream) ?? false
        gramUploadStream = try c.decodeIfPresent(Bool.self, forKey: .gramUploadStream) ?? false
        agentSessionTransfer = try c.decodeIfPresent(Bool.self, forKey: .agentSessionTransfer) ?? false
        agentSessionTransferHarnesses = try c.decodeIfPresent(
            [AgentSessionTransferHarness].self,
            forKey: .agentSessionTransferHarnesses
        )
        eventsV2 = try c.decodeIfPresent(Bool.self, forKey: .eventsV2) ?? false
        agentForget = try c.decodeIfPresent(Bool.self, forKey: .agentForget) ?? false
        apiBridgeMulti = try c.decodeIfPresent(Bool.self, forKey: .apiBridgeMulti) ?? false
        paneHistory = try c.decodeIfPresent(Bool.self, forKey: .paneHistory) ?? false
        agentTranscript = try c.decodeIfPresent(Bool.self, forKey: .agentTranscript) ?? false
        agentAnswer = try c.decodeIfPresent(Bool.self, forKey: .agentAnswer) ?? false
        agentAvatar = try c.decodeIfPresent(Bool.self, forKey: .agentAvatar) ?? false
        agentGroups = try c.decodeIfPresent(Bool.self, forKey: .agentGroups) ?? false
        serverUpdate = try c.decodeIfPresent(Bool.self, forKey: .serverUpdate) ?? false
        turnOrigin = try c.decodeIfPresent(Bool.self, forKey: .turnOrigin) ?? false
        askForm = try c.decodeIfPresent(Bool.self, forKey: .askForm) ?? false
    }
}

struct PingResult: Decodable {
    let version: String
    let protocolVersion: Int
    let capabilities: ServerCapabilities?

    enum CodingKeys: String, CodingKey {
        case version, capabilities
        case protocolVersion = "protocol"
    }
}

/// Result of `server.staged_update` (`type: "staged_update"`), read only for the running daemon's
/// version, protocol and commit — the Connection row's "herdr daemon" line. Mirrors
/// `ResponseResult::StagedUpdate` (`src/api/schema/response.rs`); the internally-tagged `type` key
/// and the retired `staged` build are ignored on decode (updates go through `server.update_check`).
///
/// The version string is static across commits (`0.8.0`), so `runningSha` — the running binary's
/// git commit — is what actually identifies the build. `runningSha` is nil on an older daemon that
/// predates the sha-reporting change.
public struct StagedUpdate: Decodable, Sendable, Equatable {
    public let runningVersion: String
    public let runningProtocol: Int
    public let runningSha: String?

    enum CodingKeys: String, CodingKey {
        case runningVersion = "running_version"
        case runningProtocol = "running_protocol"
        case runningSha = "running_sha"
    }
}

/// Ack of a command that returns `{ type: "ok" }` (e.g. `guest.revoke`). Decoded as an empty object
/// (the `type` tag is ignored).
struct OkAck: Decodable, Sendable {}

// MARK: - Push status (notifications.status)

/// Result of `notifications.status` (`type: "notifications_status"`): whether this daemon can
/// deliver push, and how. Never carries key material or tokens.
public struct NotificationsStatus: Decodable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// The daemon runs without its session server, so it keeps no device registry.
        case unsupported
        /// `push.mode = "off"`.
        case off
        /// No APNs key in direct mode, or no relay-enrolled device yet in relay mode.
        case unconfigured
        case directReady
        case relayReady
    }

    public let state: State
    /// `auto` / `direct` / `relay` / `off`. A string, not an enum: it only picks guidance wording.
    public let mode: String?
    public let relayURL: String?
    public let devices: Int
    /// Registered devices that carry a relay capability (activities are not counted).
    public let relayDevices: Int

    public init(state: State, mode: String? = nil, relayURL: String? = nil,
                devices: Int = 0, relayDevices: Int = 0) {
        self.state = state
        self.mode = mode
        self.relayURL = relayURL
        self.devices = devices
        self.relayDevices = relayDevices
    }

    enum CodingKeys: String, CodingKey {
        case state, mode, devices
        case relayURL = "relay_url"
        case relayDevices = "relay_devices"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A state a newer daemon adds must not fail the whole decode (which would read as "update
        // Herdr"); it can only mean push is not ready yet, so it degrades to `unconfigured`.
        switch try c.decode(String.self, forKey: .state) {
        case "unsupported": state = .unsupported
        case "off": state = .off
        case "direct_ready": state = .directReady
        case "relay_ready": state = .relayReady
        default: state = .unconfigured
        }
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        relayURL = try c.decodeIfPresent(String.self, forKey: .relayURL)
        devices = try c.decodeIfPresent(Int.self, forKey: .devices) ?? 0
        relayDevices = try c.decodeIfPresent(Int.self, forKey: .relayDevices) ?? 0
    }
}

/// What Settings can say about push on the connected machine.
public enum PushAvailability: Sendable, Equatable {
    case status(NotificationsStatus)
    /// The daemon answered but does not know `notifications.status` (or answered with something
    /// this app cannot read): it predates relay push and needs updating.
    case daemonTooOld
    /// The request never reached a daemon (SSH or bridge failure), so nothing is known.
    case unreachable

    /// Classifies a failed `notifications.status`. Only a herdr that predates the method is "too
    /// old": it rejects the request line with `invalid_request` naming the unknown variant. Any
    /// other error (the bridge's `transport_error`, an internal error, a rate limit) says nothing
    /// about the daemon's version, so it is reported as unreachable rather than as an update hint.
    public init(failure: Error) {
        switch failure {
        case let api as APIError
            where api.code == "invalid_request" && api.message.contains("unknown variant"):
            self = .daemonTooOld
        case is DecodingError: self = .daemonTooOld
        default: self = .unreachable
        }
    }
}

/// Settings > Notifications > "An agent finishes" (owner decision 2026-11-06). Stored as two
/// switches, `notify.finishes` and `notify.finishesMineOnly`, so the old single switch carries
/// over without a migration step: an install that had it on (and never saw this setting) is
/// `always`; the default stays `off`.
public enum FinishNotifications: String, CaseIterable, Sendable, Equatable {
    case off
    /// Only turns the owner started (herdr's `turn_origin` "mine"): not gitmoot, scripts,
    /// other agents or guests.
    case mine
    case always

    public init(notifies: Bool, mineOnly: Bool) {
        self = !notifies ? .off : mineOnly ? .mine : .always
    }

    /// `notify_finishes` and the stored `notify.finishes`.
    public var notifies: Bool { self != .off }
    /// `notify_finishes_mine_only` and the stored `notify.finishesMineOnly`.
    public var mineOnly: Bool { self == .mine }

    public var label: String {
        switch self {
        case .off: return "Off"
        case .mine: return "Only my requests"
        case .always: return "Always"
        }
    }
}

// MARK: - Folder browsing + agent kinds (fs.list_dir / agent.kinds)

/// Result of `fs.list_dir` (`type: "dir_list"`): the resolved absolute `path` and its entries. The
/// daemon returns directories first then case-insensitive by name; the app uses `path` to compute a
/// parent for "up". Mirrors `ResponseResult::DirList`.
public struct DirListing: Decodable, Sendable, Equatable {
    public let path: String
    public let entries: [Entry]

    public struct Entry: Decodable, Sendable, Equatable, Identifiable {
        public let name: String
        public let isDir: Bool
        public var id: String { name }
        enum CodingKeys: String, CodingKey {
            case name
            case isDir = "is_dir"
        }
    }
}

/// One known agent kind and whether its harness binary is installed on the connected machine
/// (`agent.kinds`). The new-agent picker offers only `installed` kinds.
public struct AgentKind: Decodable, Sendable, Equatable, Identifiable {
    public let kind: String
    public let installed: Bool
    public var id: String { kind }
}

// MARK: - Pane process info (pane.process_info)

/// A pane's shell and foreground job (`pane.process_info`, `ResponseResult::PaneProcessInfo`).
/// Field-for-field herdr's `PaneProcessInfo` / `PaneProcessInfoProcess`
/// (src/api/schema/panes.rs): every field the server may skip is optional here, and
/// `foreground_processes` (skipped when empty) decodes to `[]`.
public struct PaneProcessInfo: Decodable, Sendable, Equatable {
    public let paneID: String
    public let shellPID: UInt32?
    public let foregroundProcessGroupID: UInt32?
    public let tty: String?
    public let foregroundProcesses: [Process]

    public struct Process: Decodable, Sendable, Equatable {
        public let pid: UInt32
        public let name: String
        public let argv0: String?
        public let argv: [String]?
        public let cmdline: String?
        public let cwd: String?
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case shellPID = "shell_pid"
        case foregroundProcessGroupID = "foreground_process_group_id"
        case tty
        case foregroundProcesses = "foreground_processes"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paneID = try container.decode(String.self, forKey: .paneID)
        shellPID = try container.decodeIfPresent(UInt32.self, forKey: .shellPID)
        foregroundProcessGroupID = try container.decodeIfPresent(UInt32.self, forKey: .foregroundProcessGroupID)
        tty = try container.decodeIfPresent(String.self, forKey: .tty)
        foregroundProcesses = try container.decodeIfPresent([Process].self, forKey: .foregroundProcesses) ?? []
    }

    /// herdr CLI's `process_info_shows_shell_initialization` (src/cli/agent.rs): the pane's
    /// shell leads the foreground process group and is itself among the foreground processes.
    /// True both while the shell is still running its rc files (whose children share its
    /// group, so the server's `agent.start` answers `agent_pane_busy`) and once it is an idle
    /// prompt; false when a job-controlled foreground process owns the terminal, or when the
    /// host exposes no foreground group (Windows) — a pane that will not become free by waiting.
    public var showsShellInitialization: Bool {
        guard let shellPID, foregroundProcessGroupID == shellPID else { return false }
        return foregroundProcesses.contains { process in
            process.pid == shellPID
                && (Self.isPaneShellProcessName(process.name)
                    || process.argv?.first.map(Self.isPaneShellProcessName) == true)
        }
    }

    /// herdr's `is_pane_shell_process_name` over `normalized_process_name`
    /// (src/platform/mod.rs): basename, leading `-` (login shell) and trailing `.exe`
    /// stripped, ASCII-lowercased, then matched against the known shells. A non-ASCII
    /// basename can never equal an ASCII shell name under ASCII lowercasing, so it is
    /// rejected up front rather than run through Unicode `lowercased()`.
    static func isPaneShellProcessName(_ name: String) -> Bool {
        var normalized = Substring(name.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
        normalized = normalized.split(separator: "\\", omittingEmptySubsequences: false).last ?? ""
        guard normalized.allSatisfy(\.isASCII) else { return false }
        while normalized.hasPrefix("-") { normalized = normalized.dropFirst() }
        while normalized.hasSuffix(".exe") { normalized = normalized.dropLast(4) }
        return paneShellNames.contains(normalized.lowercased())
    }

    private static let paneShellNames: Set<String> = [
        "sh", "bash", "dash", "zsh", "fish", "ksh", "mksh", "csh", "tcsh",
        "elvish", "xonsh", "nu", "pwsh", "powershell", "cmd",
    ]
}
