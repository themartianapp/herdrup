import Foundation

/// Typed client for the herdr JSON API.
///
/// A one-off command is one request and one reply: its own channel, because the
/// control socket is single-shot (see `HerdrTransport`), or a held `api-bridge
/// --multi` channel where the daemon has one (see `CitadelTransport`). The streams
/// (`subscribe`, `subscribeAgentStatus`, `streamTerminal`) and the gram upload and
/// pane input channels each hold a connection open while they run.
public actor HerdrClient {
    private let transport: HerdrTransport
    /// One encoder for every request, including the nonisolated stream openers.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Do NOT escape "/" as "\/". A base64 gram file chunk is slash-heavy (an
        // all-0xFF chunk is ALL "/"), and the default escaping would nearly double
        // those bytes — enough to push an otherwise in-budget chunk past the SSH
        // transport's command-size cap. Unescaped "/" is valid JSON and the server
        // parses it identically.
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()
    private let decoder = JSONDecoder()
    private var sequence: UInt64 = 0
    /// The daemon's `ping` capabilities, cached per client so the pane-input and
    /// gram-upload openers pay ONE `ping` between them (and a ten-file send one in all).
    ///
    /// Two states on purpose: a successful probe is cached either way (so an old
    /// daemon, which reports no capabilities, is not re-probed per open), while a
    /// FAILED probe leaves it `unknown` (so a transient error cannot pin this client to
    /// the fallback path for its whole lifetime, and a daemon upgraded under a
    /// long-lived app is picked up).
    private enum CapabilityCache {
        case unknown
        case probed(ServerCapabilities?)
    }
    private var capabilityCache: CapabilityCache = .unknown

    /// `input_source` on every write this client makes: `"app"` for the owner (herdr counts
    /// the turn it starts as the owner's, for "Only my requests" and the Chat's up arrow),
    /// nil over the guest relay, so a guest's prompt is never the owner's.
    let inputSource: String?

    /// The value herdr reads as "a HerdrUp client acting for the owner".
    public static let appInputSource = "app"

    public init(transport: HerdrTransport) {
        self.transport = transport
        self.inputSource = transport.actsAsGuest ? nil : Self.appInputSource
    }

    private func nextID(_ method: String) -> String {
        sequence &+= 1
        return "herdrkit:\(method):\(sequence)"
    }

    private func encodeRequest<P: Encodable>(_ method: String, _ params: P) throws -> String {
        let env = RequestEnvelope(id: nextID(method), method: method, params: params)
        let data = try Self.encoder.encode(env)
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes a response line, surfacing a server `error` object as a thrown `APIError`.
    private func decodeResult<R: Decodable>(_ line: String, as: R.Type) throws -> R {
        let data = Data(line.utf8)
        if let err = try? decoder.decode(ErrorEnvelope.self, from: data) {
            throw err.error
        }
        return try decoder.decode(ResultEnvelope<R>.self, from: data).result
    }

    private func call<P: Encodable, R: Decodable>(
        _ method: String, _ params: P, as type: R.Type
    ) async throws -> R {
        let line = try encodeRequest(method, params)
        let response = try await transport.roundTrip(line)
        return try decodeResult(response, as: type)
    }

    // MARK: - Commands

    /// Every agent the server knows about, with the `revision` /
    /// `stateChangeSeq` counters that drive refresh decisions.
    public func agentList() async throws -> [AgentInfo] {
        try await agentListing().agents
    }

    /// `agent.list` with the answering daemon's own capabilities, so a caller that
    /// polls the list learns about `events_v2` (or a daemon upgrade) without an
    /// extra `ping`.
    public func agentListing() async throws -> AgentListing {
        let result = try await call("agent.list", EmptyParams(), as: AgentListResult.self)
        return AgentListing(agents: result.agents, originCapabilities: result.originCapabilities,
                            originMachineID: result.originMachineID)
    }

    private struct MachineStatusResult: Decodable {
        let machines: [String: SavedMachineStatus]
    }

    public func machineStatuses() async throws -> [SavedMachineStatus] {
        let result = try await call("machine.status", EmptyParams(), as: MachineStatusResult.self)
        return result.machines.values.sorted { $0.displayLabel < $1.displayLabel }
    }

    /// The SSH host executes Herdr's fixed one-machine command; `machine.status`
    /// remains the source of truth after the command returns.
    public func setMachineFederation(profileID: String, enabled: Bool) async throws {
        guard let machineTransport = transport as? any MachineFederationTransport else {
            throw TransportError.machineCommandFailed(stderr: "Machine federation requires an SSH connection")
        }
        try await machineTransport.setMachineFederation(profileID: profileID, enabled: enabled)
    }

    /// The herdr sessions on the connected machine (#347). Throws when the transport can't
    /// run commands or the machine's herdr predates sessions (no `session list`); callers
    /// then treat the machine as default-only.
    public func listSessions() async throws -> [HerdrSession] {
        guard let sessionTransport = transport as? any SessionListingTransport else {
            throw TransportError.machineCommandFailed(stderr: "Sessions require an SSH connection")
        }
        return try await sessionTransport.listSessions()
    }

    /// `agent.list` from another herdr session on the same machine (#347), for the
    /// session pills' needs-you counts. Throws when the transport can't reach other sessions.
    public func agentList(inSession session: String?) async throws -> [AgentInfo] {
        guard let sessionTransport = transport as? any SessionListingTransport else {
            throw TransportError.machineCommandFailed(stderr: "Sessions require an SSH connection")
        }
        let line = try encodeRequest("agent.list", EmptyParams())
        let response = try await sessionTransport.roundTrip(line, inSession: session)
        return try decodeResult(response, as: AgentListResult.self).agents
    }

    /// Every credential account (subscription) the daemon knows about, for the
    /// Settings → Accounts list and the per-agent "Swap subscription" menu. Mirrors
    /// `agentList()`: a small parameterless JSON query. THROWS the server's
    /// `APIError` on an older daemon that lacks the method, so callers that want a
    /// quiet degrade use `try?`.
    public func accountsList() async throws -> [CredentialAccount] {
        try await call("accounts.list", EmptyParams(), as: AccountsListResult.self).accounts
    }

    /// Feature flags from the daemon's `ping` result. `nil` capabilities means an
    /// older daemon; callers treat every new feature as unsupported in that case.
    public func serverCapabilities() async throws -> ServerCapabilities? {
        try await call("ping", EmptyParams(), as: PingResult.self).capabilities
    }

    /// The server's version string and capabilities from one `ping`, uncached: an update
    /// replaces the server under the same client. The answer also replaces the cached
    /// capabilities, so the openers see what the server that answered supports.
    public func serverVersionAndCapabilities() async throws -> (version: String, capabilities: ServerCapabilities?) {
        let pong = try await call("ping", EmptyParams(), as: PingResult.self)
        capabilityCache = .probed(pong.capabilities)
        return (pong.version, pong.capabilities)
    }

    /// Whether the daemon advertises `flag`, from the per-client `capabilityCache`.
    /// False when the probe fails, which leaves the cache `unknown` for the next call.
    ///
    /// The probe is NOT written with `try?`: `serverCapabilities()` both throws AND
    /// returns an Optional, so `try?` flattens "the ping failed" into the same nil as
    /// "the daemon sent no capabilities", and would cache a transient error as the
    /// unsupported answer — the outcome the `unknown` state exists to prevent.
    private func supports(_ flag: KeyPath<ServerCapabilities, Bool>) async -> Bool {
        if case .probed(let capabilities) = capabilityCache {
            return capabilities?[keyPath: flag] == true
        }
        do {
            let probed = try await serverCapabilities()
            capabilityCache = .probed(probed)
            return probed?[keyPath: flag] == true
        } catch {
            return false
        }
    }

    /// The daemon keeps each turn's origin (`turn_origin`): "Only my requests" can filter
    /// finished pushes, and the Chat's up arrow can skip turns that are not the owner's.
    /// From the per-client capability cache, so asking again costs no `ping`.
    public func advertisesTurnOrigin() async -> Bool {
        await supports(\.turnOrigin)
    }

    struct AccountsCreateParams: Encodable {
        let kind: String
        let label: String
        let configDir: String?
        enum CodingKeys: String, CodingKey {
            case kind, label
            case configDir = "config_dir"
        }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            try container.encode(label, forKey: .label)
            try container.encodeIfPresent(configDir, forKey: .configDir)
        }
    }

    /// Register a NEW credential account (`accounts.create`): the daemon derives a
    /// fresh config-home + id, creates the dir, appends it to config.toml, reloads, and
    /// returns the refreshed list. Only non-secret metadata is written — the caller then
    /// drives login into the new account's config-home. Returns the refreshed accounts.
    @discardableResult
    public func accountsCreate(kind: String, label: String, configDir: String? = nil) async throws -> [CredentialAccount] {
        try await call("accounts.create",
                       AccountsCreateParams(kind: kind, label: label, configDir: configDir),
                       as: AccountsListResult.self)
            .accounts
    }

    struct AccountsRemoveParams: Encodable {
        let id: String
    }

    /// Unregister an account (`accounts.remove`): the daemon drops its `[[accounts]]`
    /// block from config.toml and reloads, returning the refreshed list. Does NOT delete
    /// the account's config-home or credentials — the entry can be re-added later. THROWS
    /// the server's `APIError` on an older daemon that lacks the method.
    @discardableResult
    public func accountsRemove(id: String) async throws -> [CredentialAccount] {
        try await call("accounts.remove",
                       AccountsRemoveParams(id: id),
                       as: AccountsListResult.self)
            .accounts
    }

    /// The running daemon's version, protocol and commit (`server.staged_update`; its `staged` build
    /// is retired and ignored). Parameterless read; THROWS the server's `APIError` on a daemon too
    /// old to know the method, so callers that want a quiet degrade use `try?` (mirrors
    /// `accountsList`).
    public func stagedUpdate() async throws -> StagedUpdate {
        try await call("server.staged_update", EmptyParams(), as: StagedUpdate.self)
    }

    /// The running build, the newest signed preview, and how the server can take it
    /// (`server.update_check`). THROWS `APIError`: `update_manifest_unreachable`,
    /// `update_signature_invalid` (also "not ready yet": no signature published),
    /// `update_manifest_invalid`, and `guest_forbidden` for anyone but the owner.
    public func updateCheck() async throws -> ServerUpdateCheck {
        try await call("server.update_check", EmptyParams(), as: ServerUpdateCheck.self)
    }

    struct UpdateApplyParams: Encodable {
        let buildID: String
        let restartLater: Bool
        enum CodingKeys: String, CodingKey {
            case buildID = "build_id"
            case restartLater = "restart_later"
        }
    }

    /// Starts updating to `buildID`, the build the user confirmed (`server.update_apply`). The
    /// server answers once preflight passes, BEFORE the download and the handoff; the handoff then
    /// drops this connection, so progress and the outcome come from `updateStatus()`.
    /// `restartLater` downloads and installs on disk without touching the running server.
    /// THROWS `APIError`: `update_build_mismatch`, `update_in_progress`, `update_not_available`,
    /// `update_restart_required`, `update_unsupported_install`, `update_preflight_failed`.
    @discardableResult
    public func updateApply(buildID: String, restartLater: Bool) async throws -> String {
        try await call("server.update_apply",
                       UpdateApplyParams(buildID: buildID, restartLater: restartLater),
                       as: ServerUpdateApplyResult.self).attemptID
    }

    /// The last update attempt on this machine (`server.update_status`); nil if none ever ran.
    public func updateStatus() async throws -> ServerUpdateAttempt? {
        try await call("server.update_status", EmptyParams(), as: ServerUpdateStatus.self).attempt
    }

    struct FsListDirParams: Encodable {
        let path: String?
        enum CodingKeys: String, CodingKey { case path }
        // Omit `path` when nil so the daemon defaults to $HOME (rather than sending null).
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(path, forKey: .path)
        }
    }

    /// List one directory on the connected machine (`fs.list_dir`), for the new-agent folder browser.
    /// `path` nil → the daemon's `$HOME`; a leading `~` expands there. Returns the resolved absolute
    /// path + entries (dirs first). THROWS `APIError` (`not_a_directory`) for a non-directory, and on
    /// a daemon too old to know the method — callers browsing folders use `try?` to degrade to manual
    /// path entry.
    public func listDir(path: String?) async throws -> DirListing {
        try await call("fs.list_dir", FsListDirParams(path: path), as: DirListing.self)
    }

    struct AgentKindsResult: Decodable {
        let kinds: [AgentKind]
    }

    /// The known agent kinds and whether each harness is installed on the connected machine
    /// (`agent.kinds`). The new-agent picker offers only the installed ones. THROWS on an older daemon
    /// lacking the method, so callers `try?`-degrade to a static kind list.
    public func agentKinds() async throws -> [AgentKind] {
        try await call("agent.kinds", EmptyParams(), as: AgentKindsResult.self).kinds
    }

    struct ReadParams: Encodable {
        let target: String
        let source: ReadSource
        let format: ReadFormat
        let lines: UInt32?
    }

    /// Reads a pane. `lines` is clamped by the server to 1000 and defaults to 80.
    ///
    /// Requesting `.ansi` with `.detection` silently yields plain text, so this
    /// refuses that combination rather than returning unstyled output that the
    /// caller believes is styled.
    /// Defaults to `.recentUnwrapped`: `read` is the REFLOWED-SNAPSHOT surface —
    /// a 100-column pane at readable size does not fit a phone, so a transcript
    /// reflowed to the phone's width is the right default for skimming. Styling
    /// survives it. This is now the COMPLEMENT to the live path, not the only
    /// option: `streamTerminal(pane:)` renders a real grid-faithful VT from the
    /// raw byte stream, and `setPTYSize(...)` drives the actual PTY geometry that
    /// `PaneInfo` never exposed. `read` stays the cheap, reflowed snapshot.
    public func read(
        pane: String,
        source: ReadSource = .recentUnwrapped,
        format: ReadFormat = .ansi,
        lines: UInt32? = nil
    ) async throws -> PaneRead {
        if format == .ansi && source == .detection {
            throw APIError(
                code: "herdrkit_invalid_read",
                message: "source=detection ignores format=ansi and returns plain text; "
                    + "use .visible or .recent for styled output"
            )
        }
        let params = ReadParams(target: pane, source: source, format: format, lines: lines)
        return try await call("agent.read", params, as: PaneReadResult.self).read
    }

    struct PromptParams: Encodable {
        let target: String
        let text: String
        let wait: PromptWaitOptions?
        /// `"app"` from the owner, omitted from a guest (`HerdrClient.inputSource`).
        let inputSource: String?
        enum CodingKeys: String, CodingKey {
            case target, text, wait
            case inputSource = "input_source"
        }
    }

    /// The `wait` block herdr's `agent.prompt` accepts: block until the agent
    /// settles into one of `until` (an AgentStatus set) or `timeoutMs` elapses.
    /// Passing it is what makes the server report a REAL `delivery` (submitted vs
    /// written_to_pty); the no-wait path returns an unconditional written_to_pty.
    struct PromptWaitOptions: Encodable {
        let until: [String]
        let timeoutMs: Int?
        enum CodingKeys: String, CodingKey {
            case until
            case timeoutMs = "timeout_ms"
        }
    }

    /// The full AgentStatus set. Passed as `agent.prompt`'s `wait.until` so the
    /// server returns AS SOON AS it has classified delivery (every real status is
    /// in the set, so the initial wait-match succeeds immediately and no status
    /// timeout can fire) — the point is the truthful `delivery`, not to block for a
    /// particular status.
    public static let anyAgentStatus = ["working", "idle", "blocked", "done", "unknown"]

    /// Submits prompt text as intent rather than as raw keystrokes.
    ///
    /// Pass `waitUntil` (a set of AgentStatus wire values, e.g. `anyAgentStatus`)
    /// to have the server report a real `delivery`; without it herdr returns an
    /// unconditional `writtenToPty`, so the app cannot tell a started turn from a
    /// stranded draft. Returns the server's `delivery` (nil when it did not
    /// determine one). THROWS the server's `APIError` on rejection, so a non-delivery
    /// is never silent — but not every rejection IS a non-delivery: classify it with
    /// `PromptRejection` before handing text back for a resend.
    @discardableResult
    public func prompt(
        pane: String,
        text: String,
        waitUntil: [String]? = nil,
        timeoutMs: Int? = nil
    ) async throws -> PromptDelivery? {
        let wait = waitUntil.map { PromptWaitOptions(until: $0, timeoutMs: timeoutMs) }
        let result = try await call(
            "agent.prompt", PromptParams(target: pane, text: text, wait: wait, inputSource: inputSource),
            as: PromptResult.self)
        return result.delivery
    }

    struct SendTextParams: Encodable {
        let paneID: String
        let text: String
        let inputSource: String?
        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case text
            case inputSource = "input_source"
        }
    }

    /// Types literal characters into a pane. Does not submit — Enter is a
    /// separate call, so nothing executes without a deliberate second action.
    public func sendText(pane: String, text: String) async throws {
        _ = try await call("pane.send_text", SendTextParams(paneID: pane, text: text, inputSource: inputSource),
                           as: JSONNull.self)
    }

    /// Opens an ordered, fire-and-forget `pane.input.stream` to a local pane, or nil
    /// when it cannot be had: a federated pane (`<alias>/…`, which the home daemon
    /// cannot proxy the stream to), a transport that is not SSH, a daemon without the
    /// `pane_input_stream` capability, or an open the daemon refuses or that fails.
    /// The caller then keeps `sendText`.
    public func openPaneInput(pane: String) async -> PaneInputChannel? {
        guard PaneInputChannel.canStream(pane: pane),
              let citadel = transport as? CitadelTransport else { return nil }
        // Probed once per client (`supports(_:)`): a failed ping is retried on the next open.
        guard await supports(\.paneInputStream) else { return nil }
        let openLine: String
        do {
            openLine = try encodeRequest("pane.input.stream",
                                         PaneInputStreamParams(paneID: pane, inputSource: inputSource))
        } catch {
            return nil
        }
        return await citadel.openPaneInput(openLine: openLine)
    }

    struct RegisterDeviceParams: Encodable {
        let deviceToken: String
        let platform: String
        let notifyNeedsInput: Bool
        let notifyDies: Bool
        let notifyFinishes: Bool
        /// With `notifyFinishes`: push a finished turn only when the owner started it (herdr's
        /// `turn_origin` "mine"; an unknown origin counts as mine). A daemon without
        /// `turn_origin` ignores it and pushes every finished turn.
        let notifyFinishesMineOnly: Bool
        let notifyGram: Bool
        /// Public pane ids the owner muted on this device — the server skips their
        /// pushes. The client owns the set and sends the full list each time.
        let mutedPanes: [String]
        /// The push relay's sealed capability for this token (`PushRelayEnroller`). Omitted when
        /// nil, so a failed enrollment and an older daemon both see the pre-relay JSON.
        let relayCapability: String?
        enum CodingKeys: String, CodingKey {
            case deviceToken = "device_token"
            case platform
            case notifyNeedsInput = "notify_needs_input"
            case notifyDies = "notify_dies"
            case notifyFinishes = "notify_finishes"
            case notifyFinishesMineOnly = "notify_finishes_mine_only"
            case notifyGram = "notify_gram"
            case mutedPanes = "muted_panes"
            case relayCapability = "relay_capability"
        }
    }

    /// Register this device's APNs token so the server can push agent transitions (needs-you /
    /// finished / stopped) and gram messages even while the app is closed, filtered by the user's
    /// category prefs. Idempotent — safe to re-send on every (re)connect and whenever a token or
    /// pref changes. A server that does not yet implement the method (or the `notify_gram` field)
    /// just ignores what it does not know, and an older server throws, which the caller ignores.
    /// `relayCapability` lets a daemon without its own APNs key push through the relay; the raw
    /// token is still sent so a daemon with a key keeps pushing directly. `finishes` is the
    /// three-way "An agent finishes" choice (`notify_finishes` + `notify_finishes_mine_only`).
    public func registerDevice(
        token: String, needsInput: Bool, dies: Bool, finishes: FinishNotifications, gram: Bool,
        mutedPanes: [String] = [], relayCapability: String? = nil
    ) async throws {
        _ = try await call("notifications.register_device",
                           RegisterDeviceParams(deviceToken: token, platform: "apns",
                                                notifyNeedsInput: needsInput, notifyDies: dies,
                                                notifyFinishes: finishes.notifies,
                                                notifyFinishesMineOnly: finishes.mineOnly,
                                                notifyGram: gram,
                                                mutedPanes: mutedPanes,
                                                relayCapability: relayCapability),
                           as: JSONNull.self)
    }

    struct RegisterActivityParams: Encodable {
        let activityPushToken: String
        /// Omitted when nil, exactly like `RegisterDeviceParams.relayCapability`.
        var relayCapability: String? = nil
        enum CodingKeys: String, CodingKey {
            case activityPushToken = "activity_push_token"
            case relayCapability = "relay_capability"
        }
    }

    /// Register a Live Activity's PER-ACTIVITY push token so the server can update the
    /// lock-screen / Dynamic Island widget with the session's agent status while the app is
    /// closed. Distinct from `registerDevice` (that is the one device APNs token; this is one
    /// token per running Live Activity). Idempotent — safe to re-send on (re)connect and each
    /// time the token rotates. A server that does not implement the method throws, which the
    /// caller ignores (the widget still updates in the foreground).
    public func registerActivity(token: String, relayCapability: String? = nil) async throws {
        _ = try await call("notifications.register_activity",
                           RegisterActivityParams(activityPushToken: token,
                                                  relayCapability: relayCapability),
                           as: JSONNull.self)
    }

    /// Stop pushing to a Live Activity token (the activity ended / the session disconnected),
    /// so the server prunes it instead of pushing to a dead activity. Best-effort like the above.
    public func unregisterActivity(token: String) async throws {
        _ = try await call("notifications.unregister_activity",
                           RegisterActivityParams(activityPushToken: token),
                           as: JSONNull.self)
    }

    struct UnregisterDeviceParams: Encodable {
        let deviceToken: String
        enum CodingKeys: String, CodingKey { case deviceToken = "device_token" }
    }

    /// Stop pushing to this device token. A guest calls it when it removes a share, so the
    /// host drops the guest's registration rather than pushing to a phone that left.
    public func unregisterDevice(token: String) async throws {
        _ = try await call("notifications.unregister_device",
                           UnregisterDeviceParams(deviceToken: token), as: JSONNull.self)
    }

    /// Whether this daemon can deliver push at all, and how (`notifications.status`). THROWS the
    /// server's `APIError` on a daemon too old to know the method.
    public func notificationsStatus() async throws -> NotificationsStatus {
        try await call("notifications.status", EmptyParams(), as: NotificationsStatus.self)
    }

    /// `notificationsStatus` for Settings: a failure is classified (older daemon versus no answer
    /// at all) instead of thrown, so the screen can tell the user which one it is.
    public func pushAvailability() async -> PushAvailability {
        do {
            return .status(try await notificationsStatus())
        } catch {
            return PushAvailability(failure: error)
        }
    }

    // MARK: - Gram (owner<->agent messages)

    struct GramListParams: Encodable {
        let callerPaneID: String?
        let onlyQueue: Bool
        let unreadOnly: Bool
        /// Omitted when nil, so an unconditional fetch sends the same JSON it always
        /// did and a daemon without the feature sees no new field at all.
        var ifUnchangedDigest: String?
        /// Newest-first page size. Omitted when nil — the whole list, as before.
        var limit: Int?
        /// Cursor: only messages older than this id. Omitted for the first page.
        var beforeID: String?
        enum CodingKeys: String, CodingKey {
            case callerPaneID = "caller_pane_id"
            case onlyQueue = "only_queue"
            case unreadOnly = "unread_only"
            case ifUnchangedDigest = "if_unchanged_digest"
            case limit
            case beforeID = "before_id"
        }
    }

    /// The owner view of the gram store: every message, both directions, newest
    /// first. The app is the owner, so it omits `caller_pane_id` (supplying one
    /// would select an agent view). `unreadOnly` narrows to unread agent->owner
    /// messages. Throws the server's `APIError` on an older server that lacks gram.
    /// Reads the inbox. `ifUnchangedDigest` makes the fetch conditional: pass the
    /// digest from the previous answer and a daemon that still has the same store
    /// replies "unchanged" with no messages, which is the difference between a few
    /// hundred bytes and the whole store on a 6-second poll.
    ///
    /// `limit` and `beforeID` page it: the inbox opens on the newest `limit` messages
    /// and asks for older ones as the reader scrolls, instead of paying ~900 KB for
    /// ~870 messages before it can draw anything. Conditional fetch is head-only — a
    /// daemon ignores `ifUnchangedDigest` when `beforeID` is set, because "unchanged"
    /// answers a question about the whole list, not about one page.
    ///
    /// Needs no capability gate. `GramListParams` is not `deny_unknown_fields`, and a
    /// daemon predating any of these fields IGNORES them and returns the full list —
    /// which decodes as a normal changed answer with `hasMore` nil, i.e. "this is
    /// everything". An old daemon therefore behaves exactly as before rather than
    /// erroring or paging half an inbox.
    public func gramList(
        unreadOnly: Bool = false, ifUnchangedDigest: String? = nil,
        limit: Int? = nil, beforeID: String? = nil
    ) async throws -> GramListAnswer {
        let result = try await call(
            "gram.list",
            GramListParams(callerPaneID: nil, onlyQueue: false, unreadOnly: unreadOnly,
                           ifUnchangedDigest: ifUnchangedDigest, limit: limit,
                           beforeID: beforeID),
            as: GramListResult.self)
        return GramListAnswer(
            messages: result.messages, digest: result.digest, storeID: result.storeID,
            hasMore: result.hasMore, unreadCount: result.unreadCount)
    }

    /// Whether the connected daemon is our fork or the upstream base.
    public enum ForkProbe: Sendable, Equatable {
        /// Has the fork-only methods (gram, live terminal, push).
        case isFork
        /// The base daemon — rejected a fork-only method as unknown.
        case notFork
        /// Couldn't tell (network/transport error, or an unexpected API error on a
        /// well-formed call). Callers should NOT prompt on this — assume fork.
        case indeterminate
    }

    /// Detect the fork by calling a fork-only method (`gram.list`). The base daemon
    /// parses `method` as an enum, so it cannot even DESERIALIZE an unknown method and
    /// answers `invalid_request` / "unknown variant" — an outcome a well-formed
    /// `gram.list` never produces on the fork (which returns a list, or
    /// `gram_unavailable` when the shared server is down). Everything that is not a
    /// definitive "unknown method" is treated as `indeterminate`, so a real fork user
    /// is never falsely told to install the fork (a false positive is worse than a
    /// missed one — the notice is only advisory).
    public func probeFork() async -> ForkProbe {
        do {
            // A success line that decodes to NO messages is not proof of a fork. This
            // probe sends no `ifUnchangedDigest`, and an unconditional `gram.list` on
            // the fork always answers with a list — so nil means the line was not a
            // gram-list answer at all (it decoded only because every field is
            // optional), which is exactly the case that used to surface as a
            // DecodingError before conditional fetch made `messages` optional.
            guard try await gramList().messages != nil else { return .indeterminate }
            return .isFork
        } catch let error as APIError {
            if error.code == "gram_unavailable" {
                return .isFork  // fork HAS gram.list; the shared server is just down
            }
            let lowered = error.message.lowercased()
            if error.code == "invalid_request",
                lowered.contains("unknown variant"),
                lowered.contains("gram.list")
            {
                // serde's variant error always names the offending tag ("unknown
                // variant `gram.list`, …"). Requiring the METHOD name narrows this to
                // the top-level method enum — so if gram.list ever gains an enum-typed
                // PARAM, an older fork that rejects that param's variant degrades to
                // indeterminate (quiet) instead of a false notFork.
                return .notFork
            }
            return .indeterminate  // some other API error on a well-formed call
        } catch {
            return .indeterminate  // network / decode / transport error
        }
    }

    /// A file already uploaded via `gramUploadFile`, ready to attach to a post.
    public struct GramFileAttachment: Sendable {
        public let uploadID: String
        public let name: String
        public let mime: String
        public init(uploadID: String, name: String, mime: String) {
            self.uploadID = uploadID
            self.name = name
            self.mime = mime
        }
    }

    struct GramFileUploadParams: Encodable {
        let uploadID: String
        let name: String
        let mime: String
        enum CodingKeys: String, CodingKey {
            case uploadID = "upload_id"
            case name, mime
        }
    }

    struct GramPostParams: Encodable {
        let text: String
        let to: String?
        let file: GramFileUploadParams?
    }

    /// The owner posts a message to agents. `to == nil` posts to the shared
    /// grab-queue any agent can claim; `to == <agentName>` addresses one live
    /// agent directly (the server rejects a name that is not a live agent).
    /// `attachment` attaches a file previously uploaded with `gramUploadFile`; the
    /// text may be empty when a file is attached. Returns the stored message.
    @discardableResult
    public func gramPost(
        text: String, to: String? = nil, attachment: GramFileAttachment? = nil
    ) async throws -> GramMessage {
        let file = attachment.map {
            GramFileUploadParams(uploadID: $0.uploadID, name: $0.name, mime: $0.mime)
        }
        return try await call("gram.post", GramPostParams(text: text, to: to, file: file),
                              as: GramMessageResult.self).message
    }

    struct GramMarkReadParams: Encodable { let id: String }

    /// The owner marks an agent->owner message read (clears its unread badge).
    public func gramMarkRead(id: String) async throws {
        _ = try await call("gram.mark_read", GramMarkReadParams(id: id), as: JSONNull.self)
    }

    struct GramDeleteParams: Encodable { let id: String }

    /// The owner deletes a gram message and any file attached to it, for good. As
    /// the owner the app sends no caller pane, so it may delete any message.
    public func gramDelete(id: String) async throws {
        _ = try await call("gram.delete", GramDeleteParams(id: id), as: JSONNull.self)
    }

    struct GramUploadDiscardParams: Encodable {
        let uploadID: String
        enum CodingKeys: String, CodingKey {
            case uploadID = "upload_id"
        }
    }

    struct GramUploadDiscardResult: Decodable { let discarded: Bool }

    /// Drops a staged upload that will never be posted (`gram.upload.discard`), so its
    /// bytes stop counting against the host's shared staging budget before the 24 h sweep
    /// would reclaim them. Owner or guest: the host scopes a guest to its own uploads.
    ///
    /// Returns whether the host held an upload under that id; `false` (unknown, already
    /// discarded, or consumed by a post) is a normal answer. A host that predates the
    /// method cannot even deserialize it (`invalid_request` / "unknown variant", see
    /// `probeFork`), and that also answers `false`: the sweep reclaims the bytes there.
    @discardableResult
    public func gramUploadDiscard(uploadID: String) async throws -> Bool {
        do {
            return try await call("gram.upload.discard", GramUploadDiscardParams(uploadID: uploadID),
                                  as: GramUploadDiscardResult.self).discarded
        } catch let error as APIError where Self.isUnknownMethod(error, "gram.upload.discard") {
            return false
        }
    }

    /// The answer a host gives a method it predates: it parses `method` as an enum, so an
    /// unknown one fails deserialization with `invalid_request` naming the variant
    /// (`unknown_method` on hosts that report it by name).
    static func isUnknownMethod(_ error: APIError, _ method: String) -> Bool {
        if error.code == "unknown_method" { return true }
        return error.code == "invalid_request"
            && error.message.lowercased().contains("unknown variant")
            && error.message.contains(method)
    }

    struct GramUploadChunkParams: Encodable {
        let uploadID: String
        let offset: UInt64
        let dataBase64: String
        enum CodingKeys: String, CodingKey {
            case uploadID = "upload_id"
            case offset
            case dataBase64 = "data_base64"
        }
    }

    /// Raw bytes per upload chunk on the SSH transport, and the default
    /// `HerdrTransport.gramUploadChunkBytes`. The SSH transport caps a whole request
    /// command near 120 KB, and the request JSON is base64'd twice on the way out (the
    /// inner `data_base64`, then the argv itself), a ~1.78x expansion. 48 KiB raw
    /// lands around 87 KB of command — safely under the cap with headroom.
    static let gramUploadChunkBytes = 48 * 1024

    /// The pauses before each resend of a chunk whose connection failed: three
    /// resends, so a chunk gets four attempts.
    static let gramChunkRetryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(3)]

    /// True when a request died with its connection, so the host either never saw it or
    /// answered into a closed socket: the relay or host closed the socket, the host was
    /// offline or busy, the connection dropped or timed out, or it closed before the
    /// reply. A host's own answer (`APIError`) and a refused or failed handshake are not.
    static func isDroppedConnection(_ error: Error) -> Bool {
        switch error {
        case let guest as GuestError:
            switch guest {
            case .connectionClosed, .hostOffline, .hostBusy: return true
            default: return false
            }
        case let transport as TransportError:
            switch transport {
            case .closedBeforeResponse, .requestTimedOut: return true
            default: return false
            }
        case is URLError:
            return true
        default:
            // URLSessionRelaySocket rethrows URLSession's own error for a dropped socket:
            // an NSURLErrorDomain error, or a POSIX one for a reset connection.
            let domain = (error as NSError).domain
            return domain == NSURLErrorDomain || domain == NSPOSIXErrorDomain
        }
    }

    /// One `gram.upload_chunk`. A chunk whose connection failed is sent again, the
    /// SAME bytes at the SAME offset under the SAME `upload_id`, up to
    /// `gramChunkRetryDelays.count` more times: the daemon accepts an exact replay of
    /// a chunk it already committed (a lost reply) and appends one it never got, so the
    /// upload resumes rather than restarting from offset 0 under a new id. An error the
    /// daemon answered with is thrown at once.
    private func gramUploadChunk(uploadID: String, offset: UInt64, dataBase64: String) async throws {
        var delays = Self.gramChunkRetryDelays[...]
        while true {
            do {
                _ = try await call(
                    "gram.upload_chunk",
                    GramUploadChunkParams(uploadID: uploadID, offset: offset, dataBase64: dataBase64),
                    as: JSONNull.self)
                return
            } catch {
                guard !Task.isCancelled, Self.isDroppedConnection(error), let delay = delays.popFirst() else {
                    throw error
                }
                try await Task.sleep(for: delay)
            }
        }
    }

    /// Raw bytes per streamed frame. The streaming path has no argv, so the
    /// 120 KB command cap does not apply; this is the daemon's own
    /// `MAX_CHUNK_BYTES` (512 KiB), which keeps a base64 frame (~700 KB) under
    /// its 1 MiB request-line ceiling.
    static let gramStreamChunkBytes = 512 * 1024

    struct GramUploadStreamParams: Encodable {
        let uploadID: String
        enum CodingKeys: String, CodingKey {
            case uploadID = "upload_id"
        }
    }

    /// Opens a streaming upload channel, or nil when this transport or daemon
    /// cannot serve one. Feature-detected by `ping` CAPABILITY, never by
    /// attempting the method: an unknown method comes back with an EMPTY `id` and
    /// the connection closed, so the reply cannot be correlated to the attempt.
    public func gramOpenUploadChannel(uploadID: String) async -> GramUploadChannel? {
        guard let citadel = transport as? CitadelTransport else { return nil }
        guard await supports(\.gramUploadStream) else { return nil }
        let env = RequestEnvelope(
            id: "herdrkit:gram.upload.stream:\(uploadID)",
            method: "gram.upload.stream",
            params: GramUploadStreamParams(uploadID: uploadID)
        )
        guard let data = try? Self.encoder.encode(env) else { return nil }
        return citadel.openUploadChannel(String(decoding: data, as: UTF8.self))
    }

    /// A fresh `upload_id`. The daemon keys its staging file and its single-writer
    /// claim on this, and validates it as one safe path component.
    static func mintUploadID() -> String {
        "app-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// Uploads a file's bytes FROM DISK and returns the `upload_id` to attach to a
    /// `gramPost`.
    ///
    /// Streams over one held channel when the daemon advertises
    /// `gram_upload_stream`, else falls back to per-chunk `gram.upload_chunk` —
    /// still reading from disk, so neither path holds the whole file in memory
    /// and a 100 MB attachment costs one chunk of resident bytes. Per-chunk, the
    /// chunk size is the transport's (`HerdrTransport.gramUploadChunkBytes`), and a
    /// chunk whose connection failed is resent at its offset (`gramUploadChunk`).
    ///
    /// `onProgress` (if given) is called on the main actor with
    /// `(bytesSent, totalBytes)` — once at 0, then throttled to ~1% steps, and
    /// once at completion.
    public func gramUploadFile(
        fileURL: URL,
        onProgress: (@MainActor @Sendable (_ bytesSent: Int, _ totalBytes: Int) -> Void)? = nil
    ) async throws -> String {
        var uploadID = Self.mintUploadID()
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let total = (attributes[.size] as? NSNumber)?.intValue ?? 0

        // Open the FILE first, and only then the channel. A file we cannot read must
        // not cost an SSH channel and a daemon-side claim on this `upload_id` that is
        // then released asynchronously by the `defer` below.
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let channel = await gramOpenUploadChannel(uploadID: uploadID)
        var streaming = false
        if let channel {
            do {
                try await channel.start()
                streaming = true
            } catch {
                // An out-of-date capability flag, a daemon that advertises the
                // method but cannot serve it, or a channel that died before the
                // ack must not fail the send — fall back. A REAL rejection
                // (invalid_params, gram_unavailable, upload_in_progress,
                // gram_file_error) is rethrown: the staged file may be partially
                // written, so a fallback retry from offset 0 would be a second
                // writer on the same upload_id.
                await channel.close()
                if let fatal = Self.fatalStreamOpenError(error) { throw fatal }
                // Fall back under an id the daemon has NEVER seen. It takes its
                // single-writer claim at OPEN — before it asks the app anything — and
                // refuses a per-chunk write while that claim is held, so reusing this
                // id can lose a race with the claim's release and fail the send with
                // `upload_in_progress` for a reason unrelated to the file. Nothing
                // outside this function keys on the id: the caller passes whatever is
                // returned straight to `gramPost(attachment:)`.
                uploadID = Self.mintUploadID()
            }
        }
        defer { if let channel { Task { await channel.close() } } }

        let chunkBytes = streaming ? Self.gramStreamChunkBytes : transport.gramUploadChunkBytes

        // Report at most ~once per 1% (or per chunk, whichever is coarser) so a
        // big file's round-trips don't schedule thousands of UI updates. The total is
        // widened to the bytes actually read: the file is stat'd before the first
        // read, so one that GREW in between must not drive a determinate bar past
        // 100% (a shrunken one simply reports fewer bytes and ends early).
        let reportStep = max(chunkBytes, total / 100)
        var lastReported = -reportStep
        var offset = 0
        await onProgress?(0, total)
        while let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty {
            // A composer cancels a pre-upload whose chip was removed. The streaming channel
            // tears itself down on cancellation; the per-chunk path stops here, between
            // chunks, rather than sending the rest of a file nobody will post.
            try Task.checkCancellation()
            let encoded = chunk.base64EncodedString()
            if streaming, let channel {
                try await channel.sendChunk(offset: UInt64(offset), dataBase64: encoded)
            } else {
                try await gramUploadChunk(uploadID: uploadID, offset: UInt64(offset), dataBase64: encoded)
            }
            offset += chunk.count
            // Throttle ONLY: no `offset >= total` disjunct. That condition is
            // permanently true once the cursor passes the stat'd size, so a file that
            // grew after being stat'd reported every single chunk — the exact main-actor
            // flood the throttle exists to prevent. The terminal report is emitted once,
            // after the loop.
            if offset - lastReported >= reportStep {
                lastReported = offset
                await onProgress?(offset, max(total, offset))
            }
        }
        // Frames ride ahead of their acks (`GramUploadChannel.maxFramesInFlight`), so
        // the last few are not known to be staged — or rejected — until every ack is in.
        if streaming, let channel {
            try await channel.finish()
        }
        // One terminal report at the bytes ACTUALLY read, so a determinate bar always
        // lands on 100%. `(offset, offset)`, not `max(total, offset)`: a file that
        // SHRANK after the stat would otherwise leave the bar at `offset/total` — 50%
        // for a file half the stat'd size — and a shrink whose last chunk happens to
        // land on `reportStep` would emit no terminal report at all.
        if lastReported != offset || total != offset {
            await onProgress?(offset, offset)
        }
        // The daemon frees its single-writer claim on the `upload_id` only when it
        // observes EOF on the upload connection, and it REFUSES a `gram.post` that
        // would finalize an upload a stream still owns. The caller posts immediately
        // after this returns, over the already-warm command connection, so returning
        // before the teardown completes makes that post race the claim release and
        // fail with `upload_in_progress` after a fully successful upload.
        if streaming, let channel {
            await channel.closeAndWait()
        }
        return uploadID
    }

    /// A streaming-open failure the caller must NOT retry per-chunk, or nil when
    /// falling back is safe. Only a daemon-side REJECTION of the UPLOAD is fatal;
    /// transport, capability and availability failures are what the fallback exists
    /// for, because on those paths the daemon read no frame and staging is untouched.
    static func fatalStreamOpenError(_ error: Error) -> Error? {
        guard case GramUploadChannel.ChannelError.remoteError(let api) = error else { return nil }
        // `invalid_request`: an older daemon's answer to an unknown method.
        // `server_unavailable`: the open handshake timed out waiting on the daemon's
        // single-threaded app loop (5 s), or the daemon is shutting down. Neither
        // says anything about the upload, so both fall back rather than failing the
        // send — a busy app thread must not abort a whole batch.
        let recoverable = ["invalid_request", "server_unavailable"]
        return recoverable.contains(api.code) ? nil : api
    }

    struct GramGetFileParams: Encodable { let id: String }

    /// Downloads the file attached to a message and returns its name, mime, and
    /// bytes. As the owner the app sends no caller pane and may download any file.
    /// The bytes come back inline (base64) in one reply.
    ///
    /// `onBytesReceived` reports REPLY bytes as the SSH channel delivers them, so a
    /// caller that knows the file's size can show a real bar. It fires only on the
    /// Citadel transport — a mock or a local socket gets the plain path and no
    /// callbacks, which a caller must treat as "no progress available" rather than
    /// "no bytes yet". The counted bytes are the BASE64 reply, about 4/3 of the file
    /// plus the JSON envelope, which is why the caller scales rather than dividing by
    /// the file size directly.
    public func gramGetFile(
        id: String, onBytesReceived: ((Int) -> Void)? = nil
    ) async throws -> (name: String, mime: String, data: Data) {
        let result: GramFileContentResult
        if let onBytesReceived, let citadel = transport as? CitadelTransport {
            let line = try encodeRequest("gram.get_file", GramGetFileParams(id: id))
            let response = try await citadel.roundTrip(line, onBytesReceived: onBytesReceived)
            result = try decodeResult(response, as: GramFileContentResult.self)
        } else {
            result = try await call("gram.get_file", GramGetFileParams(id: id),
                                    as: GramFileContentResult.self)
        }
        guard let data = Data(base64Encoded: result.dataBase64) else {
            throw GramError.invalidFileData
        }
        return (result.name, result.mime, data)
    }

    struct GramGetFileChunkParams: Encodable {
        let id: String
        let offset: UInt64
    }

    /// The host's ceilings: at most 512 KiB of file per `gram.get_file_chunk` reply, and at
    /// most 100 MiB per attachment.
    public static let gramMaxChunkBytes = 512 * 1024
    public static let gramMaxFileBytes = 100 * 1024 * 1024

    /// Downloads a message's file in bounded `gram.get_file_chunk` pieces. A listed
    /// size is checked against every piece. Chat envelopes have no size, so the first
    /// authorized response establishes it instead. The same file and chunk ceilings,
    /// exact offsets and progress checks apply in both cases.
    public func gramGetFileChunked(
        id: String, expectedSize: UInt64? = nil, onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> (name: String, mime: String, data: Data) {
        if let expectedSize, expectedSize > UInt64(Self.gramMaxFileBytes) {
            throw GramError.invalidFileData
        }
        let maxEncoded = (Self.gramMaxChunkBytes + 2) / 3 * 4
        var size = expectedSize
        var data = Data()
        if let size { data.reserveCapacity(Int(size)) }
        while true {
            let chunk = try await call("gram.get_file_chunk",
                                       GramGetFileChunkParams(id: id, offset: UInt64(data.count)),
                                       as: GramFileChunkResult.self)
            guard chunk.size <= UInt64(Self.gramMaxFileBytes),
                  size == nil || chunk.size == size,
                  chunk.offset == UInt64(data.count),
                  chunk.dataBase64.utf8.count <= maxEncoded else { throw GramError.invalidFileData }
            let total = Int(chunk.size)
            guard let bytes = Data(base64Encoded: chunk.dataBase64),
                  !bytes.isEmpty || total == 0,
                  bytes.count <= Self.gramMaxChunkBytes,
                  bytes.count <= total - data.count else { throw GramError.invalidFileData }
            if size == nil {
                size = chunk.size
                data.reserveCapacity(total)
            }
            data.append(bytes)
            onProgress?(data.count, total)
            if data.count == total { return (chunk.name, chunk.mime, data) }
        }
    }

    // MARK: - Gram (guest)

    struct GuestGramListParams: Encodable {
        /// The host's cap on one page.
        static let maxLimit = 500
        let limit: Int?
        let beforeID: String?

        enum CodingKeys: String, CodingKey {
            case limit
            case beforeID = "before_id"
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(limit.map { min(max($0, 1), Self.maxLimit) }, forKey: .limit)
            try c.encodeIfPresent(beforeID, forKey: .beforeID)
        }
    }

    /// A guest's Gram for the shared agent (`gram.list` over the guest relay), newest first.
    /// `beforeID` pages back from a message id. `guest_forbidden` when the owner doesn't
    /// share Gram with this guest.
    public func guestGramList(limit: Int? = nil, beforeID: String? = nil) async throws -> GuestGramPage {
        try await call("gram.list", GuestGramListParams(limit: limit, beforeID: beforeID),
                       as: GuestGramPage.self)
    }

    struct GuestGramMarkReadParams: Encodable { let ids: [String] }

    /// Marks Grams read for this guest only; the owner's read state is untouched.
    public func guestGramMarkRead(ids: [String]) async throws {
        _ = try await call("gram.mark_read", GuestGramMarkReadParams(ids: ids), as: JSONNull.self)
    }

    /// A guest posts a Gram to the shared agent (`gram.post` over the guest relay), e.g. an
    /// attachment uploaded with `gramUploadFile`. The host answers with its guest projection
    /// of the stored message, which `GramMessage` (the owner's view) cannot decode.
    @discardableResult
    public func guestGramPost(
        text: String, to: String, attachment: GramFileAttachment? = nil
    ) async throws -> GuestGramPostReceipt {
        let file = attachment.map {
            GramFileUploadParams(uploadID: $0.uploadID, name: $0.name, mime: $0.mime)
        }
        return try await call("gram.post", GramPostParams(text: text, to: to, file: file),
                              as: GuestGramPostResult.self).message
    }

    struct SendKeysParams: Encodable {
        let target: String
        let keys: [String]
        let inputSource: String?
        enum CodingKeys: String, CodingKey {
            case target, keys
            case inputSource = "input_source"
        }
    }

    /// Sends named keys (e.g. "Enter", "Escape", "Up") to an AGENT pane, for dialog
    /// navigation and turn control.
    ///
    /// Goes through `agent.send_keys`, which does agent-specific work `pane.send_keys`
    /// does not: it refuses a pane whose running process is not the expected agent, and
    /// records a turn abort for keys that interrupt one. Use it only where the pane
    /// really hosts an agent — the server rejects anything else with `agent_not_found`.
    /// For a plain shell pane use `sendPaneKeys`.
    public func sendKeys(pane: String, keys: [String]) async throws {
        _ = try await call("agent.send_keys", SendKeysParams(target: pane, keys: keys, inputSource: inputSource),
                           as: JSONNull.self)
    }

    struct PaneSendKeysParams: Encodable {
        let paneID: String
        let keys: [String]
        let inputSource: String?
        enum CodingKeys: String, CodingKey {
            case keys
            case paneID = "pane_id"
            case inputSource = "input_source"
        }
    }

    /// Sends named keys to ANY pane, agent or not.
    ///
    /// The counterpart to `sendKeys` for panes that host a plain shell — the sign-in and
    /// sign-out flows split a fresh shell and need to press Enter in it. Those flows used
    /// `sendKeys`, and every one of them failed: `agent.send_keys` resolves a pane id only
    /// when that pane is an agent terminal, so a bare shell came back as
    /// `agent target <pane> not found`.
    public func sendPaneKeys(pane: String, keys: [String]) async throws {
        _ = try await call("pane.send_keys", PaneSendKeysParams(paneID: pane, keys: keys, inputSource: inputSource),
                           as: JSONNull.self)
    }

    // MARK: - Spawning agents

    /// A new pane splits off horizontally (`right`) or vertically (`down`). herdr
    /// supports only these two — there is no left/up split.
    public enum SplitDirection: String, Sendable {
        case right, down
    }

    struct PaneSplitParams: Encodable {
        let direction: String
        let cwd: String?
        let focus: Bool
    }

    struct PaneInfoResult: Decodable {
        let pane: PaneRef
        /// Only the id is needed here; the rest of `pane` is deliberately not
        /// modelled so a schema addition on the server cannot break this decode.
        struct PaneRef: Decodable {
            let paneID: String
            enum CodingKeys: String, CodingKey { case paneID = "pane_id" }
        }
    }

    /// Splits the currently focused pane and returns the NEW pane's id. `cwd` is
    /// the working directory the new pane (and the agent started in it) runs in —
    /// the "folder" of the new-agent form; nil follows the split pane's cwd.
    /// No target pane is sent, so the server splits whatever is focused.
    ///
    /// `focus` defaults to true, which is right for a pane the user ASKED for and is
    /// about to look at. Pass false for a BACKGROUND pane the app drives on the user's
    /// behalf — sign-in and log-out run a command in a pane the user never sees, and
    /// focusing it yanks the box's focus away from whatever they were actually doing.
    public func splitPane(cwd: String?, direction: SplitDirection = .down,
                          focus: Bool = true) async throws -> String {
        let params = PaneSplitParams(direction: direction.rawValue, cwd: cwd, focus: focus)
        return try await call("pane.split", params, as: PaneInfoResult.self).pane.paneID
    }

    struct AgentStartParams: Encodable {
        let name: String
        let kind: String
        let paneID: String
        enum CodingKeys: String, CodingKey {
            case name, kind
            case paneID = "pane_id"
        }
    }

    /// Starts an agent of `kind` (claude/codex/gemini/…) named `name` in an
    /// existing pane. Returns the started agent. One `agent.start` attempt: a pane
    /// `splitPane` just created goes through `startAgentWhenShellReady` instead.
    ///
    /// NOTE: this only INITIATES launch. `agent.start` returns while the agent is
    /// still `launch_pending`, and `agent.prompt` refuses (agent_not_ready) for a
    /// variable, sometimes-long window until the agent registers as a promptable
    /// known agent with a composer. There is no reliable client-pollable readiness
    /// flag (`interactive_ready` is not populated on this path), so we do NOT
    /// auto-deliver a task after start. The caller opens the new pane instead and
    /// lets the terminal's own input router send the task as a prompt once the
    /// pane reports a composer (`InputMode.intent`). See `NewAgentView.start`.
    public func startAgent(name: String, kind: String, paneID: String) async throws -> AgentInfo {
        let params = AgentStartParams(name: name, kind: kind, paneID: paneID)
        return try await call("agent.start", params, as: AgentInfoResult.self).agent
    }

    struct PaneProcessInfoResult: Decodable {
        let processInfo: PaneProcessInfo
        enum CodingKeys: String, CodingKey { case processInfo = "process_info" }
    }

    /// The pane's shell pid, foreground process group and foreground processes
    /// (`pane.process_info` -> `ResponseResult::PaneProcessInfo { process_info }`).
    public func paneProcessInfo(paneID: String) async throws -> PaneProcessInfo {
        try await call("pane.process_info", PaneTarget(paneID: paneID),
                       as: PaneProcessInfoResult.self).processInfo
    }

    /// Pacing and clock for `startAgentWhenShellReady`. The defaults are herdr CLI's
    /// `AGENT_START_POLL_INTERVAL` (100 ms) and `PANE_SHELL_READINESS_RETRY_TIMEOUT`
    /// (2 s) from src/cli/agent.rs; tests inject `now`/`sleep` to run the loop on a
    /// fake clock.
    struct ShellReadinessTiming: Sendable {
        var pollInterval: Duration = .milliseconds(100)
        var window: Duration = .seconds(2)
        var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
        var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    }

    /// `startAgent` on a pane whose shell may still be starting — the pane `splitPane`
    /// just created (herdrup#435).
    ///
    /// herdr accepts `agent.start` only while the pane's foreground job is its lone idle
    /// shell, so a shell still running its rc files answers `agent_pane_busy`. This is
    /// herdr CLI's readiness retry (`agent start`, src/cli/agent.rs: the loop after
    /// `PANE_SHELL_READINESS_RETRY_TIMEOUT`, `pane_shell_is_initializing`,
    /// `process_info_shows_shell_initialization`): on `agent_pane_busy`, retry while
    /// `pane.process_info` shows the shell leading the foreground group
    /// (`PaneProcessInfo.showsShellInitialization`), polling every 100 ms within 2 s of
    /// the first busy answer, re-checking the shell before each retry. A pane some other
    /// foreground process owns, or a window that runs out, surfaces the last
    /// `agent_pane_busy`; every other `agent.start` error is thrown at once.
    ///
    /// Deliberate differences from the CLI:
    /// - A herdr that predates `pane.process_info` (rejects it as an unknown method)
    ///   gets plain `agent.start` retries in the same window instead of none: its fresh
    ///   panes race their shell startup just the same.
    /// - No `pane.get` terminal pinning: the caller created this pane moments ago. Nor
    ///   the CLI's `timeout_ms` gate, since no `timeout_ms` is sent.
    /// - Any other `pane.process_info` API error (or an undecodable answer) reads as
    ///   "not initializing", as the CLI's null `process_info` does; transport errors
    ///   propagate, as the CLI's `send_request(..)?` does.
    public func startAgentWhenShellReady(name: String, kind: String,
                                         paneID: String) async throws -> AgentInfo {
        try await startAgentWhenShellReady(name: name, kind: kind, paneID: paneID,
                                           timing: ShellReadinessTiming())
    }

    func startAgentWhenShellReady(name: String, kind: String, paneID: String,
                                  timing: ShellReadinessTiming) async throws -> AgentInfo {
        var processInfoUnsupported = false
        func shellMayBeInitializing() async throws -> Bool {
            if processInfoUnsupported { return true }
            do {
                return try await paneProcessInfo(paneID: paneID).showsShellInitialization
            } catch let error as APIError
                where error.code == "invalid_request"
                    && error.message.lowercased().contains("unknown variant")
                    && error.message.contains("pane.process_info") {
                // An older herdr cannot even deserialize the method (see `probeFork`).
                processInfoUnsupported = true
                return true
            } catch is APIError {
                return false
            } catch is DecodingError {
                return false
            }
        }

        var deadline: ContinuousClock.Instant?
        var previousBusy: APIError?
        while true {
            if let busy = previousBusy {
                if let deadline, timing.now() >= deadline { throw busy }
                guard try await shellMayBeInitializing() else { throw busy }
            }
            do {
                return try await startAgent(name: name, kind: kind, paneID: paneID)
            } catch let busy as APIError where busy.code == "agent_pane_busy" {
                guard try await shellMayBeInitializing() else { throw busy }
                let end = deadline ?? timing.now() + timing.window
                deadline = end
                previousBusy = busy
                let remaining = end - timing.now()
                guard remaining > .zero else { throw busy }
                try await timing.sleep(min(timing.pollInterval, remaining))
            }
        }
    }

    struct PaneTarget: Encodable {
        let paneID: String
        enum CodingKeys: String, CodingKey { case paneID = "pane_id" }
    }

    /// Closes a pane — used to clean up the pane a failed spawn left behind, so a
    /// retry does not accumulate orphan panes.
    public func closePane(paneID: String) async throws {
        _ = try await call("pane.close", PaneTarget(paneID: paneID), as: JSONNull.self)
    }

    /// `agent.restart` params. `account` is the credential-account id to swap the
    /// agent onto; it is OMITTED when nil (a plain in-place restart) via the custom
    /// `encode`, so a no-account restart sends exactly the old `{ target }` payload
    /// and an older daemon is unaffected. Mirrors the server's optional/skip-if-none.
    struct AgentRestartParams: Encodable {
        let target: String
        let account: String?

        enum CodingKeys: String, CodingKey {
            case target, account
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(target, forKey: .target)
            try container.encodeIfPresent(account, forKey: .account)
        }
    }

    struct AgentInfoResult: Decodable {
        let agent: AgentInfo
    }

    /// Restarts an agent in place: the daemon kills its harness process and
    /// reopens the SAME session with `--resume`, keeping the pane and identity.
    /// `target` is the pane id (or agent name). Passing `account` reopens the
    /// session on that credential subscription instead (the "swap subscription"
    /// action); nil keeps the current account. Throws when the agent has no
    /// resumable session (`no_resumable_session` — not a herdr-launched agent, or
    /// none reported). Returns the restarted agent.
    @discardableResult
    public func restartAgent(target: String, account: String? = nil) async throws -> AgentInfo {
        try await call("agent.restart", AgentRestartParams(target: target, account: account),
                       as: AgentInfoResult.self)
            .agent
    }

    /// Wire payload shared by the explicit prepare and confirm calls. False
    /// `confirm` and nil optionals are omitted so the prepare request stays the
    /// minimal `{ target, to, account? }` contract.
    struct AgentTransferSessionParams: Encodable {
        let target: String
        let to: AgentSessionTransferHarness
        let account: String?
        let transferID: String?
        let confirm: Bool

        enum CodingKeys: String, CodingKey {
            case target, to, account, confirm
            case transferID = "transfer_id"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(target, forKey: .target)
            try container.encode(to, forKey: .to)
            try container.encodeIfPresent(account, forKey: .account)
            try container.encodeIfPresent(transferID, forKey: .transferID)
            if confirm { try container.encode(true, forKey: .confirm) }
        }
    }

    /// Stage and verify a native destination transcript while the source harness
    /// remains live. The returned agent carries `sessionTransfer`; the caller must
    /// review its counts before making the separate confirmation call.
    @discardableResult
    public func prepareAgentSessionTransfer(
        target: String,
        to harness: AgentSessionTransferHarness,
        account: String? = nil
    ) async throws -> AgentInfo {
        try await call(
            "agent.transfer_session",
            AgentTransferSessionParams(
                target: target, to: harness, account: account,
                transferID: nil, confirm: false),
            as: AgentInfoResult.self
        ).agent
    }

    /// Confirm one exact prepared transfer. Herdr first returns the durable
    /// `verifyingCutover` phase while the source stays live, then owns cutover and
    /// rollback; this call never silently prepares a replacement transaction.
    @discardableResult
    public func confirmAgentSessionTransfer(
        target: String,
        to harness: AgentSessionTransferHarness,
        account: String? = nil,
        transferID: String
    ) async throws -> AgentInfo {
        try await call(
            "agent.transfer_session",
            AgentTransferSessionParams(
                target: target, to: harness, account: account,
                transferID: transferID, confirm: true),
            as: AgentInfoResult.self
        ).agent
    }

    struct AgentRenameParams: Encodable {
        let target: String
        let name: String
    }

    /// Renames an agent (`agent.rename`): sets the agent's `name`, which becomes a
    /// resolvable mention target daemon-side (`herdr agent read <name>` / another agent
    /// prompting `<name>`). `target` is the pane id (or the current name). The server
    /// enforces the name grammar `^[a-z][a-z0-9_-]{0,31}$`, so callers pass a name already
    /// coerced by `AgentName.normalize`; it still THROWS `APIError` for a duplicate
    /// (`agent_name_taken`) or an otherwise invalid name. Returns the updated agent.
    @discardableResult
    public func renameAgent(target: String, name: String) async throws -> AgentInfo {
        try await call("agent.rename", AgentRenameParams(target: target, name: name),
                       as: AgentInfoResult.self)
            .agent
    }

    struct AgentAvatarSetParams: Encodable {
        let target: String
        let choice: AgentAvatarChoice?

        enum CodingKeys: String, CodingKey {
            case target, avatar, mime
            case imageBase64 = "image_base64"
        }
        enum DescriptorKeys: String, CodingKey { case style, mascot }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(target, forKey: .target)
            switch choice {
            case nil:
                // An explicit null: clearing is a value, not an omitted field.
                try c.encodeNil(forKey: .avatar)
            case .mascot(let id)?:
                var d = c.nestedContainer(keyedBy: DescriptorKeys.self, forKey: .avatar)
                try d.encode("mascot", forKey: .style)
                try d.encode(id, forKey: .mascot)
            case .image(let data, let mime)?:
                var d = c.nestedContainer(keyedBy: DescriptorKeys.self, forKey: .avatar)
                try d.encode("image", forKey: .style)
                try c.encode(data.base64EncodedString(), forKey: .imageBase64)
                try c.encode(mime, forKey: .mime)
            }
        }
    }

    struct AgentAvatarSetResult: Decodable {
        let avatar: AgentAvatarDescriptor?
    }

    struct AgentAvatarGetParams: Encodable {
        let target: String
        let sha256: String
    }

    struct AgentAvatarGetResult: Decodable {
        let mime: String
        let dataBase64: String
        enum CodingKeys: String, CodingKey {
            case mime
            case dataBase64 = "data_base64"
        }
    }

    /// Sets (or with nil, clears) an agent's picture (`agent.avatar.set`, herdrup#538).
    /// Owner only. `target` is what `agent.rename` takes; the terminal id is the stable
    /// one. Returns the stored descriptor (nil after a clear). Throws
    /// `AgentAvatarError.unsupported` on a daemon without the method, else the server's
    /// `APIError` (`invalid_avatar`, `avatar_too_large`, `agent_not_found`, ...).
    public func agentAvatarSet(target: String, choice: AgentAvatarChoice?) async throws -> AgentAvatarDescriptor? {
        do {
            return try await call("agent.avatar.set", AgentAvatarSetParams(target: target, choice: choice),
                                  as: AgentAvatarSetResult.self).avatar
        } catch let error as APIError where Self.isUnknownMethod(error, "agent.avatar.set") {
            throw AgentAvatarError.unsupported
        }
    }

    /// An agent's picture bytes by content address (`agent.avatar.get`). Owners may read
    /// any agent's; a guest only its granted agent's. Callers cache by `sha256`
    /// (`AgentAvatarImageCache`), so each image crosses the wire once.
    public func agentAvatarGet(target: String, sha256: String) async throws -> AgentAvatarImageData {
        let result: AgentAvatarGetResult
        do {
            result = try await call("agent.avatar.get", AgentAvatarGetParams(target: target, sha256: sha256),
                                    as: AgentAvatarGetResult.self)
        } catch let error as APIError where Self.isUnknownMethod(error, "agent.avatar.get") {
            throw AgentAvatarError.unsupported
        }
        guard let data = Data(base64Encoded: result.dataBase64) else { throw AgentAvatarError.malformedImage }
        return AgentAvatarImageData(mime: result.mime, data: data)
    }

    // MARK: agent folders and stars (herdrup#552)

    /// `groups_conflict` carries the server's current document beside the code and message.
    private struct AgentGroupsErrorEnvelope: Decodable {
        struct Body: Decodable {
            let code: String
            let message: String
            let current: AgentGroupsDocument?
        }
        let error: Body
    }

    /// The owner's folders and stars.
    public func agentGroupsGet() async throws -> AgentGroupsDocument {
        try await agentGroupsCall("agent.groups.get", EmptyParams())
    }

    /// Replaces the whole document. `document.revision` must be the revision it was read at;
    /// the reply carries the new one. A stale revision throws `.conflict` with the server's
    /// current document, onto which the caller can replay its edit.
    public func agentGroupsSet(_ document: AgentGroupsDocument) async throws -> AgentGroupsDocument {
        try await agentGroupsCall("agent.groups.set", document)
    }

    private func agentGroupsCall<P: Encodable>(_ method: String, _ params: P) async throws -> AgentGroupsDocument {
        let response = try await transport.roundTrip(try encodeRequest(method, params))
        if let envelope = try? decoder.decode(AgentGroupsErrorEnvelope.self, from: Data(response.utf8)) {
            let error = envelope.error
            switch error.code {
            case "groups_conflict":
                if let current = error.current { throw AgentGroupsError.conflict(current: current) }
            case "invalid_groups":
                throw AgentGroupsError.invalid(error.message)
            case "guest_forbidden":
                throw AgentGroupsError.forbidden
            default:
                if Self.isUnknownMethod(APIError(code: error.code, message: error.message), method) {
                    throw AgentGroupsError.unsupported
                }
            }
            throw APIError(code: error.code, message: error.message)
        }
        return try decodeResult(response, as: AgentGroupsDocument.self)
    }

    /// `agent.archive` params. `reason`/`by`/`force` are OMITTED when nil/false so a plain
    /// archive sends `{ target }` and matches the server's optional/skip-if-none.
    struct AgentArchiveParams: Encodable {
        let target: String
        let reason: String?
        let by: String?
        let force: Bool

        enum CodingKeys: String, CodingKey {
            case target, reason, by, force
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(target, forKey: .target)
            try container.encodeIfPresent(reason, forKey: .reason)
            try container.encodeIfPresent(by, forKey: .by)
            if force { try container.encode(true, forKey: .force) }
        }
    }

    /// Archives an agent (`agent.archive`, issue #173): the daemon releases its pane
    /// but preserves the session ref so `agent.unarchive` can resume it later. `target`
    /// is the pane id (or agent name). The server REJECTS archiving an agent that is
    /// mid-turn unless `force` — that surfaces as an `APIError` the caller shows.
    /// Returns the archived agent (its `archived` block now set).
    ///
    /// PASS `by` AND `reason`. They are optional on the wire, and omitting them is not
    /// neutral: the daemon then records `by: "api"` with no reason, which is exactly what
    /// it records for bookkeeping on a pane that merely died. An archive that does not say
    /// who did it or why is indistinguishable from one nobody decided — a real ambiguity
    /// downstream, where tooling reads the `archived` block as evidence a seat is gone.
    /// Both are `encodeIfPresent`, so a caller that passes neither still sends the exact
    /// bytes it did before.
    @discardableResult
    public func archiveAgent(
        target: String, reason: String? = nil, by: String? = nil, force: Bool = false
    ) async throws -> AgentInfo {
        try await call("agent.archive",
                       AgentArchiveParams(target: target, reason: reason, by: by, force: force),
                       as: AgentInfoResult.self)
            .agent
    }

    /// `agent.unarchive` params. `fresh` (start a clean agent instead of resuming the
    /// preserved session) is OMITTED when false.
    struct AgentUnarchiveParams: Encodable {
        let target: String
        let fresh: Bool

        enum CodingKeys: String, CodingKey {
            case target, fresh
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(target, forKey: .target)
            if fresh { try container.encode(true, forKey: .fresh) }
        }
    }

    /// Unarchives an agent (`agent.unarchive`, issue #173): resumes the preserved
    /// session into a fresh pane, restoring the agent's terminal identity. `target` is
    /// the archived agent's name or terminal id. Returns the resumed agent.
    @discardableResult
    public func unarchiveAgent(target: String, fresh: Bool = false) async throws -> AgentInfo {
        try await call("agent.unarchive", AgentUnarchiveParams(target: target, fresh: fresh),
                       as: AgentInfoResult.self)
            .agent
    }

    struct AgentForgetParams: Encodable {
        let target: String
    }

    /// `agent.forget`: remove this archived agent's record for good (#380, herdr#291). Its
    /// transcript stays on the machine. Only offered when `ping` advertises `agent_forget`.
    @discardableResult
    public func forgetAgent(_ archived: AgentInfo) async throws -> AgentInfo {
        try await call("agent.forget", AgentForgetParams(target: Self.forgetTarget(archived)),
                       as: AgentInfoResult.self).agent
    }

    /// The `agent.forget` target for an archived row. herdr takes a name or a terminal id
    /// and acts on the FIRST archived record that matches, and two archived agents can
    /// share a name. Forgetting is irreversible, so it addresses the row by its terminal
    /// id, which is unique; the name is only a fallback for a record without one.
    static func forgetTarget(_ archived: AgentInfo) -> String {
        archived.terminalID ?? archived.name ?? archived.paneID
    }

    struct PaneRenameParams: Encodable {
        let paneID: String
        let label: String
        enum CodingKeys: String, CodingKey {
            case label
            case paneID = "pane_id"
        }
    }

    /// Renames a pane (`pane.rename`): sets the pane's manual `label`, which shows in
    /// `pane.list` — so a plain terminal can be mentioned to an agent ("check the terminal
    /// labelled <label>"; the agent lists panes, matches the label, then reads that pane).
    /// Works on any pane, agent or not. The server trims the label. The returned pane is
    /// ignored (callers keep the app-local label in sync separately).
    public func renamePane(paneID: String, label: String) async throws {
        _ = try await call("pane.rename", PaneRenameParams(paneID: paneID, label: label),
                           as: PaneInfoResult.self)
    }

    /// True when `pane` reports an agent WITH a composer — the observable proxy for
    /// "a prompt will land NOW". This is the STRICTER new-agent PRE-FILL gate
    /// (`InputRouter.isPromptable(for:)`), deliberately NOT the reply-routing gate
    /// (`mode(for:)`, which needs only a named agent): auto-delivering a just-
    /// spawned agent's task unattended warrants holding out for a confirmed
    /// composer, since there is no reliable readiness flag (interactive_ready is nil
    /// on this path). The UI polls THIS to learn when a just-spawned agent can
    /// receive its pre-filled task — then delivers it as a prompt, never as rawKeys
    /// send_text into a not-ready agent. Absent pane, or an agent with no composer,
    /// is NOT promptable (false).
    public func isPromptable(pane: String) async throws -> Bool {
        guard let info = try await agentList().first(where: { $0.paneID == pane }) else { return false }
        return InputRouter().isPromptable(for: info)
    }

    // MARK: - Events

    /// Opens the persistent event stream.
    ///
    /// The first line is `subscriptionStarted`; the connection then stays open.
    /// Pane-scoped subscriptions need a `paneID` — the server has no wildcard.
    public nonisolated func subscribe(
        _ subscriptions: [Subscription]
    ) -> AsyncThrowingStream<StreamLine, Error> {
        openLineStream(id: "herdrkit:events.subscribe", method: "events.subscribe",
                       params: SubscribeParams(subscriptions: subscriptions)) {
            { Self.classify($0) }
        }
    }

    /// Opens one of the long-lived streams (`subscribe`, `subscribeAgentStatus`,
    /// `streamTerminal`). Its request has a fixed `id`, because these methods are
    /// nonisolated and cannot take `nextID`. Each line is yielded through a transform
    /// made once per stream (so it may keep state across lines), in order. A transform
    /// that throws finishes the stream with that error; the transport ending finishes
    /// it normally. `alongside` starts a companion task (a watchdog), cancelled with
    /// the reader.
    private nonisolated func openLineStream<P: Encodable, T: Sendable>(
        id: String, method: String, params: P,
        alongside: (@Sendable (AsyncThrowingStream<T, Error>.Continuation) -> Task<Void, Never>)? = nil,
        transform makeTransform: @escaping @Sendable () -> (String) async throws -> T
    ) -> AsyncThrowingStream<T, Error> {
        let env = RequestEnvelope(id: id, method: method, params: params)
        guard let data = try? Self.encoder.encode(env) else {
            return AsyncThrowingStream { $0.finish(throwing: TransportError.closedBeforeResponse) }
        }
        let raw = transport.stream(String(decoding: data, as: UTF8.self))

        return AsyncThrowingStream { continuation in
            let reader = Task {
                let transform = makeTransform()
                do {
                    for try await line in raw {
                        continuation.yield(try await transform(line))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let companion = alongside?(continuation)
            // Finishing from either side lands here: the reader stops iterating,
            // which terminates the transport stream and closes its connection.
            continuation.onTermination = { _ in
                reader.cancel()
                companion?.cancel()
            }
        }
    }

    nonisolated static func classify(_ line: String) -> StreamLine {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .other(raw: line) }

        if let result = obj["result"] as? [String: Any],
           result["type"] as? String == "subscription_started" {
            return .subscriptionStarted
        }
        if let event = obj["event"] as? [String: Any] {
            let kind = (event["type"] as? String) ?? (event["kind"] as? String) ?? "unknown"
            return .event(kind: kind, paneID: event["pane_id"] as? String, raw: line)
        }
        if let kind = obj["type"] as? String {
            return .event(kind: kind, paneID: obj["pane_id"] as? String, raw: line)
        }
        return .other(raw: line)
    }

    // MARK: - All-panes status stream

    /// The entries `subscribeAgentStatus` sends: status and turn changes for every
    /// pane (no `pane_id`, `events_v2` daemons only), plus the lifecycle events that
    /// mean the listed set of panes or agents changed.
    public static let agentStatusSubscriptions: [Subscription] = [
        Subscription(.paneAgentStatusChanged),
        Subscription(.paneTurnCompleted),
        Subscription(.paneCreated),
        Subscription(.paneClosed),
        Subscription(.paneExited),
        Subscription(.paneAgentDetected),
    ]

    /// One long-lived `events.subscribe` with `events_v2: true` that reports status
    /// changes for every pane the daemon knows, including alias-qualified remote
    /// panes a federation coordinator relays. Call it only when the daemon
    /// advertises `ServerCapabilities.eventsV2`: an older daemon rejects the entries
    /// without `pane_id`, which surfaces here as a thrown `APIError`.
    ///
    /// The stream holds its own transport stream (a dedicated SSH connection on
    /// `CitadelTransport`). Ending iteration or cancelling the consuming task closes
    /// it. It finishes normally when the daemon closes the connection, and throws
    /// `AgentStatusStreamError.silent` when no line (event or heartbeat, which the
    /// daemon writes every 15 s) arrives within `silenceTimeout`, so a half-open
    /// connection is noticed rather than waited on forever.
    public nonisolated func subscribeAgentStatus(
        silenceTimeout: Duration = .seconds(45)
    ) -> AsyncThrowingStream<AgentStatusStreamLine, Error> {
        let activity = StreamActivity()
        return openLineStream(
            id: "herdrkit:events.subscribe:agent-status",
            method: "events.subscribe",
            params: SubscribeParams(subscriptions: Self.agentStatusSubscriptions, eventsV2: true),
            alongside: { continuation in
                Task {
                    while !Task.isCancelled {
                        let remaining = await activity.remaining(of: silenceTimeout)
                        if remaining <= .zero {
                            continuation.finish(throwing: AgentStatusStreamError.silent(silenceTimeout))
                            return
                        }
                        try? await Task.sleep(for: remaining)
                    }
                }
            },
            transform: {
                { line in
                    await activity.touch()
                    return try AgentStatusStreamLine.decode(line)
                }
            })
    }

    // MARK: - Live terminal stream

    /// Opens `pane.stream` — herdr's persistent server->client raw PTY byte firehose
    /// — and yields the opening `stream_started` ack (geometry + epoch) followed by
    /// the ordered `\n`-delimited frames. Opened like `subscribe()` (`openLineStream`):
    /// same Transport line framing, no busy-poll (the server pushes as bytes arrive
    /// off the PTY). A line that fails to decode as a valid frame THROWS and finishes the stream — a
    /// stateful byte stream can't skip a corrupt line without desyncing the emulator,
    /// so the view surfaces the failure and re-opening the pane reseeds a fresh reset.
    /// The connection also ends when the peer closes or the task is cancelled (closing
    /// the SSH channel = unsubscribe).
    public nonisolated func streamTerminal(
        pane: String,
        includeHistory: Bool = true,
        maxFrameBytes: Int? = nil,
        scrollbackLines: Int? = nil,
        viewerID: String? = nil
    ) -> AsyncThrowingStream<TerminalStreamEvent, Error> {
        openLineStream(
            id: "herdrkit:pane.stream:\(pane)",
            method: "pane.stream",
            params: PaneStreamParams(
                paneID: pane, includeHistory: includeHistory,
                resumeFrom: nil, epoch: nil,
                maxFrameBytes: maxFrameBytes, scrollbackLines: scrollbackLines,
                viewerID: viewerID)
        ) {
            let decoder = JSONDecoder()
            var sawAck = false
            return { line in
                if !sawAck {
                    sawAck = true
                    switch Self.decodeStreamAck(line, decoder) {
                    case .started(let started):
                        return .started(started)
                    case .error(let apiError):
                        // pane_not_found, or an older server rejecting the
                        // unknown method — surface it and stop cleanly.
                        throw apiError
                    case .undecodable:
                        // Not the ack we expected: fall through and try this
                        // line as a frame. If it is a valid frame it is
                        // yielded; if not, the strict decode below THROWS and
                        // ends the stream (a stray non-frame leading line is
                        // not silently swallowed).
                        break
                    }
                }
                // A server can END a live stream with an error line after frames
                // (a guest stream closes with guest_paused or guest_revoked), so
                // every line is checked before the strict frame decode.
                let data = Data(line.utf8)
                if let err = try? decoder.decode(ErrorEnvelope.self, from: data) {
                    throw err.error
                }
                // STRICT: every line after the ack must be a valid pane.bytes
                // frame. A stateful byte stream cannot skip a corrupt line
                // without desyncing the emulator (feeding the next frame mid
                // escape-sequence), so a decode failure THROWS — the stream
                // ends with an error, the view surfaces it, and re-opening the
                // pane reseeds a fresh full-screen reset. The ack fall-through
                // above lands here too, so a non-ack/non-frame leading line
                // also fails loudly rather than being silently swallowed.
                return .frame(try decoder.decode(StreamFrame.self, from: data))
            }
        }
    }

    private enum StreamAck {
        case started(StreamStarted)
        case error(APIError)
        case undecodable
    }

    /// Classifies the first `pane.stream` line: the `stream_started` ack, a server
    /// error envelope, or something else (which the caller then re-tries as a frame).
    private nonisolated static func decodeStreamAck(_ line: String, _ decoder: JSONDecoder) -> StreamAck {
        let data = Data(line.utf8)
        if let err = try? decoder.decode(ErrorEnvelope.self, from: data) {
            return .error(err.error)
        }
        if let ok = try? decoder.decode(ResultEnvelope<StreamStarted>.self, from: data) {
            return .started(ok.result)
        }
        return .undecodable
    }

    /// Sets the pane's real PTY winsize and takes/releases geometry ownership.
    /// One-shot request/response on the single-shot control socket, dispatched via
    /// the same `call(...)` path as `read`/`sendText`. NOTE `lock:false` (the
    /// default) is NOT side-effect-free: the server applies the winsize resize FIRST
    /// and only then releases ownership, so this DOES resize the shared PTY (a
    /// co-viewing desktop reflows until its next render reclaims the size). `false`
    /// only means "don't PIN the geometry"; it does not mean "don't resize". cols/
    /// rows are clamped to the server's floor (cols>=4, rows>=2) before the round-trip.
    public func setPTYSize(
        pane: String,
        cols: Int,
        rows: Int,
        cellWidthPx: UInt32? = nil,
        cellHeightPx: UInt32? = nil,
        lock: Bool = false,
        viewerID: String? = nil,
        ttl: UInt64? = nil
    ) async throws -> PanePtySize {
        let clampedCols = min(max(cols, 4), Int(UInt16.max))
        let clampedRows = min(max(rows, 2), Int(UInt16.max))
        let params = PaneSetPtySizeParams(
            paneID: pane, cols: clampedCols, rows: clampedRows,
            cellWidthPx: cellWidthPx, cellHeightPx: cellHeightPx, lock: lock,
            viewerID: viewerID, ttl: ttl)
        return try await call("pane.set_pty_size", params, as: PanePtySize.self)
    }

    /// One page of the pane's scrollback ABOVE `cursor`'s row (`pane.history`): up to
    /// `lines` rows (the server's 1...1000 range), oldest first, plus the cursor for the
    /// next older page (nil at the start of the retained history).
    ///
    /// The two refusals that end paging for good are typed (`PaneHistoryError`) so the
    /// caller can stop quietly on them while still treating a transport failure, or a
    /// `pane_not_found`, as the `APIError` it is.
    public func paneHistory(pane: String, cursor: String, lines: UInt32 = 500) async throws -> PaneHistoryPage {
        let params = PaneHistoryParams(paneID: pane, cursor: cursor, lines: min(max(lines, 1), 1000))
        do {
            return try await call("pane.history", params, as: PaneHistoryPage.self)
        } catch let error as APIError where error.code == "history_cursor_expired" {
            throw PaneHistoryError.historyCursorExpired
        } catch let error as APIError
            where error.code == "invalid_request"
                && error.message.lowercased().contains("unknown variant")
                && error.message.contains("pane.history") {
            // An older herdr cannot even deserialize the method (see `probeFork`).
            throw PaneHistoryError.unsupported
        }
    }

    // MARK: - omp Chat view (agent.transcript / agent.answer)

    /// One page of an omp agent's conversation (`agent.transcript`), oldest entry first.
    /// `before` pages back from an older page's cursor; `after` returns what was appended
    /// (or changed) since a page's `after` cursor; neither asks for the newest turns.
    /// `limit` counts turns and is clamped to the server's 1...50. `subagent` pages that
    /// subagent's own conversation (a `TranscriptSubagent.id` with `hasTranscript`).
    ///
    /// The refusals the view acts on are typed (`AgentTranscriptError`); an older server
    /// that cannot deserialize the method reports `.unsupported` like a non-omp agent.
    public func agentTranscript(
        target: String, before: String? = nil, after: String? = nil, limit: UInt32? = nil,
        subagent: String? = nil
    ) async throws -> AgentTranscriptPage {
        let params = AgentTranscriptParams(target: target, before: before, after: after,
                                           limit: limit.map { min(max($0, 1), 50) }, subagent: subagent)
        do {
            return try await call("agent.transcript", params, as: AgentTranscriptPage.self)
        } catch let error as APIError {
            switch error.code {
            case "agent_not_found": throw AgentTranscriptError.agentNotFound
            case "transcript_unsupported": throw AgentTranscriptError.unsupported
            case "transcript_unavailable": throw AgentTranscriptError.unavailable
            case "cursor_expired": throw AgentTranscriptError.cursorExpired
            case "subagent_not_found": throw AgentTranscriptError.subagentNotFound
            case "invalid_request"
                where error.message.lowercased().contains("unknown variant")
                    && error.message.contains("agent.transcript"):
                throw AgentTranscriptError.unsupported
            default: throw error
            }
        }
    }

    /// Answer omp's pending `ask` question by picking `option` (`agent.answer`). Server
    /// refusals arrive as the plain `APIError` (`ask_not_pending`, `ask_unsupported`,
    /// `ask_ui_not_found`, `selection_mismatch`, `forbidden`).
    public func agentAnswer(target: String, askID: String, option: String) async throws -> AgentAnswerStatus {
        try await call("agent.answer",
                       AgentAnswerParams(target: target, askID: askID, option: option),
                       as: AgentAnswerResult.self).status
    }

    // MARK: - Guest access (owner)

    /// Create a one-use invite for a live agent (`guest.invite.create`). `target` is the
    /// daemon-local pane id; for a federated agent pass the peer alias as `machine` (see
    /// `GuestRoute`). Owner-only: a federation token or a guest gets `forbidden`, and a
    /// Windows daemon answers `unsupported`.
    public func guestInviteCreate(
        target: String, name: String, ownerName: String, machineLabel: String,
        ttlSecs: UInt64? = nil, machine: String? = nil, shareGram: Bool = false
    ) async throws -> GuestInviteCreated {
        try await call("guest.invite.create",
                       GuestInviteCreateParams(target: target, name: name, ownerName: ownerName,
                                               machineLabel: machineLabel, ttlSecs: ttlSecs,
                                               machine: machine, shareGram: shareGram),
                       as: GuestInviteCreated.self)
    }

    /// Turn Gram sharing on or off for an accepted guest (`guest.update`). Takes effect on the
    /// guest's next call; turning it off also stops their Gram pushes.
    public func guestUpdate(guestID: String, shareGram: Bool, machine: String? = nil) async throws {
        _ = try await call("guest.update",
                           GuestUpdateParams(guestID: guestID, shareGram: shareGram, machine: machine),
                           as: JSONNull.self)
    }

    /// Guests, invites and the relay link state of one machine (`guest.list`). Fingerprints only.
    public func guestList(machine: String? = nil) async throws -> GuestListing {
        try await call("guest.list", GuestListParams(machine: machine), as: GuestListing.self)
    }

    /// Revoke a guest (its live sessions close immediately) or cancel an unused invite.
    public func guestRevoke(_ target: GuestRevokeTarget, machine: String? = nil) async throws {
        _ = try await call("guest.revoke", GuestRevokeParams(target: target, machine: machine),
                           as: OkAck.self)
    }

    /// The guest activity log, newest first (`guest.audit`). `limit` is clamped to the
    /// daemon's 1...500; `beforeMs` pages further back.
    public func guestAudit(
        guestID: String? = nil, limit: Int = 100, beforeMs: UInt64? = nil, machine: String? = nil
    ) async throws -> [GuestAuditEntry] {
        try await call("guest.audit",
                       GuestAuditParams(guestID: guestID, limit: limit, beforeMs: beforeMs,
                                        machine: machine),
                       as: GuestAuditResult.self).entries
    }
}

/// Who the app reports as the actor when it archives an agent, and why.
///
/// Constants, not free text, for two readers. A person sees
/// "archived by herdrup · user action" on the archived row. Fleet tooling that treats the
/// `archived` block as evidence a seat is gone can match these EXACTLY to tell a deliberate
/// archive from bookkeeping on a dead pane — a distinction that was previously impossible,
/// because the app sent neither field and the daemon's `by: "api"` default is what a
/// reasonless archive looks like too.
///
/// `by` names the actor; `reason` says it was deliberate. Neither repeats the other, since
/// the row renders them joined.
public let appArchiveActor = "herdrup"
public let appArchiveReason = "user action"

/// Decodes any JSON value, for calls whose result body the client ignores.
struct JSONNull: Decodable {
    init(from decoder: Decoder) throws { _ = decoder }
}
