import Foundation

/// A saved machine as the account sync sees it: the fields the app keeps beside its secret.
/// `address` is the saved address as typed (`host`, `host:port`, `[v6]:port`).
public struct LocalMachine: Equatable, Sendable {
    public var id: UUID
    public var address: String
    public var username: String
    public var nickname: String?
    public var authKind: SyncHost.AuthKind

    public init(id: UUID, address: String, username: String, nickname: String?, authKind: SyncHost.AuthKind) {
        self.id = id
        self.address = address
        self.username = username
        self.nickname = nickname
        self.authKind = authKind
    }
}

/// A saved prompt as the account sync sees it.
public struct LocalPrompt: Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var text: String

    public init(id: UUID, title: String, text: String) {
        self.id = id
        self.title = title
        self.text = text
    }
}

/// The app's own copies of what syncs (saved machines and prompts), as `AccountLocalSync`
/// reads and changes them. The secrets stay behind this protocol: the sync only asks whether
/// one is here.
@MainActor
public protocol AccountLocalStore: AnyObject {
    var machines: [LocalMachine] { get }
    var prompts: [LocalPrompt] { get }
    /// Whether this device holds machine `id`'s secret of `kind`.
    func hasSecret(_ id: UUID, kind: SyncHost.AuthKind) -> Bool
    /// Adds the machine, or updates the one with its id. Never touches a secret.
    func putMachine(_ machine: LocalMachine)
    /// Moves machine `id`, and its secret, to `newID`. False changes nothing.
    func moveMachine(_ id: UUID, to newID: UUID) -> Bool
    /// Folds machine `duplicate` into `kept` (keeping whichever secret is here). False changes nothing.
    func mergeMachine(_ duplicate: UUID, into kept: UUID) -> Bool
    /// Removes the machine and its secret. False changes nothing.
    func removeMachine(_ id: UUID) -> Bool
    func setPrompts(_ prompts: [LocalPrompt])
    /// The ids this device held in step with the account at the end of the last sync: only
    /// these, when missing here, count as deleted here.
    var heldMachineIDs: Set<String> { get set }
    var heldPromptIDs: Set<String> { get set }
}

/// What one sync did, for the account screen and its notices.
public struct AccountSyncSummary: Equatable, Sendable {
    public var date = Date()
    public var machinesAdded = 0
    public var machinesMerged = 0
    public var machinesRemoved = 0
    public var machinesPushed = 0
    public var promptsChanged = 0
    /// One line per item the account didn't take: refused as invalid, or holding something that
    /// looks like a secret (DESIGN #698 §5.4), which never leaves the device.
    public var rejected: [String] = []
    /// Edits made on another device at the same time; the account's copy was kept.
    public var conflicts = 0
    public var overQuota = false
    /// Machines the account holds under another id that couldn't move to it here.
    public var adoptFailures = 0

    public init() {}

    /// The notice to show, or nil when everything went through.
    public var problems: String? {
        var lines = rejected
        if conflicts > 0 {
            lines.append("\(conflicts) change\(conflicts == 1 ? " was" : "s were") also made on another device at the same time. The account's copy was kept here.")
        }
        if overQuota {
            lines.append("Your account is full (2,000 items). Remove some machines or prompts to sync the rest.")
        }
        if adoptFailures > 0 {
            lines.append("\(adoptFailures) machine\(adoptFailures == 1 ? "" : "s") couldn't take the account's copy: the Keychain refused. Sync tries again next time.")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n\n")
    }

    mutating func absorb(_ report: SyncReport) {
        conflicts += report.conflicts.count
        overQuota = overQuota || report.overQuota
        for rejection in report.rejected {
            rejected.append(Self.describe(rejection.change.key, body: rejection.change.body,
                                          error: .invalid(field: rejection.field)))
        }
    }

    /// Adds a later step's summary of the same sync (the shares after the machines and
    /// prompts): its counts and problems join this one's; the date stays this one's.
    public mutating func absorb(_ other: AccountSyncSummary) {
        machinesAdded += other.machinesAdded
        machinesMerged += other.machinesMerged
        machinesRemoved += other.machinesRemoved
        machinesPushed += other.machinesPushed
        promptsChanged += other.promptsChanged
        rejected += other.rejected
        conflicts += other.conflicts
        overQuota = overQuota || other.overQuota
        adoptFailures += other.adoptFailures
    }

    static func describe(_ key: SyncKey, body: SyncBody?, error: SyncError) -> String {
        let name: String
        switch body {
        case .host(let host)?: name = "Machine “\(host.nickname ?? host.host)”"
        case .prompt(let prompt)?: name = "Prompt “\(prompt.title ?? String(prompt.text.prefix(24)))”"
        case .share(let share)?: name = "Share “\(share.agentName ?? "agent") on \(share.machineLabel ?? "a shared machine")”"
        default:
            switch key.collection {
            case .hosts: name = "A machine"
            case .shares: name = "A share"
            default: name = "A prompt"
            }
        }
        switch error {
        case .secretLike(let field):
            return "\(name) wasn't synced: its \(field) looks like it holds a key or password, and those never leave this device."
        case .invalid(let field):
            return "\(name) wasn't synced: the account doesn't accept its \(field)."
        case .tooLarge:
            return "\(name) wasn't synced: it's too large."
        }
    }
}

/// One sync of saved machines and prompts with the HerdrUp account (DESIGN #698 §5):
///
/// 1. Local edits since the last sync are staged: a machine or prompt that differs from the
///    account's copy is pushed, one removed here is deleted there.
/// 2. `SyncEngine.sync()` pushes and pulls.
/// 3. The account's copy is merged into the local store by the host identity rule
///    (`SyncHostMerge`): a local machine matching an account machine takes the account's id,
///    of two account items for one machine the lower rev is kept, a second local copy is merged
///    into the first. Local machines the account doesn't know are staged and pushed by a second
///    `sync()`. On a first sign-in that is "pull first, adopt, then push the rest".
///
/// - **Secrets stay reachable.** A machine keeps the auth kind whose secret this device holds;
///   when the account names a kind whose store is empty here, the local kind stays and is
///   pushed back as the newer value.
/// - **Edits made during the sync win.** What the store holds is snapshotted before staging;
///   anything that differs from that snapshot once the network part is done was edited
///   meanwhile, and the merge leaves it alone. The next run (`AccountSyncLoop` queues one)
///   stages it.
@MainActor
public struct AccountLocalSync {
    public let engine: SyncEngine
    public let store: AccountLocalStore
    /// Told when the run starts and stops writing to the store, so those writes aren't taken
    /// for local edits.
    public let applying: (Bool) -> Void

    public init(engine: SyncEngine, store: AccountLocalStore, applying: @escaping (Bool) -> Void = { _ in }) {
        self.engine = engine
        self.store = store
        self.applying = applying
    }

    public func run() async throws -> AccountSyncSummary {
        var summary = AccountSyncSummary()
        let before = await engine.currentState
        let knownHosts = Set(before.items.filter { $0.key.collection == .hosts }.map(\.key.id))
        let knownPrompts = Set(before.items.filter { $0.key.collection == .prompts }.map(\.key.id))
        let machinesBefore = store.machines
        let promptsBefore = store.prompts

        try await stageMachineEdits(machinesBefore, into: &summary)
        try await stagePromptEdits(promptsBefore, into: &summary)
        summary.absorb(try await engine.sync())

        let hostMirror = await engine.items(in: .hosts)
        let promptMirror = await engine.items(in: .prompts)
        // No await from here to the end of the merge: what was edited meanwhile is known, and
        // nothing more can be edited before the merge has written.
        let dirtyMachines = Self.dirty(before: machinesBefore, now: store.machines, id: \.id)
        let dirtyPrompts = Self.dirty(before: promptsBefore, now: store.prompts, id: \.id)
        applying(true)
        var changes = mergeMachines(hostMirror, known: knownHosts, dirty: dirtyMachines, into: &summary)
        changes += mergePrompts(promptMirror, known: knownPrompts, dirty: dirtyPrompts, into: &summary)
        applying(false)
        let mergedMachineIDs = Set(store.machines.map { Self.id($0.id) })
        let mergedPromptIDs = Set(store.prompts.map { Self.id($0.id) })

        var staged = false
        for (key, body) in changes {
            if try await stage(key, body, into: &summary) { staged = true }
        }
        if staged { summary.absorb(try await engine.sync()) }

        // In step: what the merge left here and the account holds, plus what was deleted here
        // during the sync (still to be deleted there by the next run).
        let accountHosts = Set(await engine.items(in: .hosts).map(\.key.id))
        let accountPrompts = Set(await engine.items(in: .prompts).map(\.key.id))
        store.heldMachineIDs = mergedMachineIDs.union(dirtyMachines.map(Self.id)).intersection(accountHosts)
        store.heldPromptIDs = mergedPromptIDs.union(dirtyPrompts.map(Self.id)).intersection(accountPrompts)
        return summary
    }

    // MARK: Machines

    private func stageMachineEdits(_ machines: [LocalMachine], into summary: inout AccountSyncSummary) async throws {
        let mirror = Dictionary(await engine.items(in: .hosts).map { ($0.key.id, $0) }) { first, _ in first }
        var local: Set<String> = []
        for machine in machines {
            let id = Self.id(machine.id)
            local.insert(id)
            guard case .host(let remote)? = mirror[id]?.body, !Self.sameFields(machine, remote),
                  let body = Self.syncBody(machine, label: remote.label) else { continue }
            try await stage(SyncKey(.hosts, id), .host(body), into: &summary)
        }
        for id in store.heldMachineIDs where !local.contains(id) && mirror[id] != nil {
            try await stage(SyncKey(.hosts, id), nil, into: &summary)
        }
    }

    /// Writes the account's machines into the store; returns the changes to push.
    private func mergeMachines(_ mirror: [SyncItem], known: Set<String>, dirty: Set<UUID>,
                               into summary: inout AccountSyncSummary) -> [(SyncKey, SyncBody?)] {
        let dirtyIDs = Set(dirty.map(Self.id))
        let mirror = mirror.filter { !dirtyIDs.contains($0.key.id) }
        let byID = Dictionary(mirror.map { ($0.key.id, $0) }) { first, _ in first }
        let machines = store.machines.filter { !dirty.contains($0.id) }.compactMap { machine -> (LocalMachine, SyncHostMerge.Local)? in
            guard let body = Self.syncBody(machine, label: nil) else { return nil }
            return (machine, SyncHostMerge.Local(id: Self.id(machine.id), body: body))
        }
        let plan = SyncHostMerge.plan(local: machines.map { $0.1 }, mirror: mirror, known: known)
        var changes: [(SyncKey, SyncBody?)] = plan.delete.map { (SyncKey(.hosts, $0), nil) }

        func applyRemote(_ remote: SyncHost, onto machine: LocalMachine, label: String?) {
            let (merged, pushBack) = Self.merged(remote, onto: machine) { store.hasSecret(machine.id, kind: $0) }
            if merged != machine { store.putMachine(merged) }
            if pushBack, let body = Self.syncBody(merged, label: label) {
                changes.append((SyncKey(.hosts, Self.id(merged.id)), .host(body)))
            }
        }

        var finalID: [Int: UUID] = [:]
        for index in plan.matched {
            let machine = machines[index].0
            finalID[index] = machine.id
            if case .host(let remote)? = byID[machines[index].1.id]?.body {
                applyRemote(remote, onto: machine, label: remote.label)
            }
        }
        for (index, id) in plan.adopt.sorted(by: { $0.key < $1.key }) {
            var machine = machines[index].0
            guard let uuid = UUID(uuidString: id), store.moveMachine(machine.id, to: uuid) else {
                summary.adoptFailures += 1
                continue
            }
            machine.id = uuid
            finalID[index] = uuid
            summary.machinesMerged += 1
            if case .host(let remote)? = byID[id]?.body { applyRemote(remote, onto: machine, label: remote.label) }
        }
        for (index, holder) in plan.duplicates.sorted(by: { $0.key < $1.key }) {
            guard let kept = finalID[holder] else { continue }
            if store.mergeMachine(machines[index].0.id, into: kept) { summary.machinesMerged += 1 }
        }
        for index in plan.gone {
            if store.removeMachine(machines[index].0.id) { summary.machinesRemoved += 1 }
        }
        for id in plan.added {
            guard let uuid = UUID(uuidString: id), case .host(let remote)? = byID[id]?.body else { continue }
            store.putMachine(LocalMachine(id: uuid, address: Self.address(remote), username: remote.username,
                                          nickname: Self.nickname(remote.nickname), authKind: remote.authKind ?? .key))
            summary.machinesAdded += 1
        }
        for index in plan.push {
            let local = machines[index].1
            changes.append((SyncKey(.hosts, local.id), .host(local.body)))
            summary.machinesPushed += 1
        }
        return changes
    }

    /// The account's fields over a local machine. The auth kind follows the secret actually
    /// here (`SyncHostMerge.authKind`), and the address keeps how it was typed when it names
    /// the same endpoint. `pushBack`: the local kind won, so the account should learn it.
    static func merged(_ remote: SyncHost, onto machine: LocalMachine,
                       hasSecret: (SyncHost.AuthKind) -> Bool) -> (LocalMachine, pushBack: Bool) {
        let auth = SyncHostMerge.authKind(account: remote.authKind, local: machine.authKind, hasSecret: hasSecret)
        var merged = machine
        if HostEndpoint.parse(machine.address) != endpoint(remote) { merged.address = address(remote) }
        merged.username = remote.username
        merged.nickname = nickname(remote.nickname)
        merged.authKind = auth.kind
        return (merged, auth.pushBack)
    }

    // MARK: Prompts

    private func stagePromptEdits(_ prompts: [LocalPrompt], into summary: inout AccountSyncSummary) async throws {
        let mirror = Dictionary(await engine.items(in: .prompts).map { ($0.key.id, $0) }) { first, _ in first }
        var local: Set<String> = []
        for prompt in prompts {
            let id = Self.id(prompt.id)
            local.insert(id)
            guard case .prompt(let remote)? = mirror[id]?.body, !Self.sameFields(prompt, remote) else { continue }
            try await stage(SyncKey(.prompts, id), .prompt(Self.syncBody(prompt, order: remote.order)), into: &summary)
        }
        for id in store.heldPromptIDs where !local.contains(id) && mirror[id] != nil {
            try await stage(SyncKey(.prompts, id), nil, into: &summary)
        }
    }

    private func mergePrompts(_ mirror: [SyncItem], known: Set<String>, dirty: Set<UUID>,
                              into summary: inout AccountSyncSummary) -> [(SyncKey, SyncBody?)] {
        let dirtyIDs = Set(dirty.map(Self.id))
        var remote: [String: SyncPrompt] = [:]
        for item in mirror where !dirtyIDs.contains(item.key.id) {
            if case .prompt(let body)? = item.body { remote[item.key.id] = body }
        }
        var next: [LocalPrompt] = []
        var toPush: [LocalPrompt] = []
        var changed = 0
        for prompt in store.prompts {
            let id = Self.id(prompt.id)
            if dirty.contains(prompt.id) {
                next.append(prompt)
            } else if let body = remote.removeValue(forKey: id) {
                let merged = Self.localPrompt(id: prompt.id, body)
                if merged != prompt { changed += 1 }
                next.append(merged)
            } else if known.contains(id) {
                changed += 1
            } else {
                next.append(prompt)
                toPush.append(prompt)
            }
        }
        for (id, body) in remote.sorted(by: { ($0.value.order ?? .infinity, $0.key) < ($1.value.order ?? .infinity, $1.key) }) {
            guard let uuid = UUID(uuidString: id) else { continue }
            next.append(Self.localPrompt(id: uuid, body))
            changed += 1
        }
        if next != store.prompts { store.setPrompts(next) }
        summary.promptsChanged += changed
        return toPush.map { prompt in
            let order = Double(next.firstIndex(of: prompt) ?? next.count)
            return (SyncKey(.prompts, Self.id(prompt.id)), .prompt(Self.syncBody(prompt, order: order)))
        }
    }

    // MARK: Staging

    /// Stages one change (`body` nil: a delete). A change the account would refuse, or one that
    /// looks like it holds a secret, is left out and named in the summary; the rest goes on.
    @discardableResult
    private func stage(_ key: SyncKey, _ body: SyncBody?, into summary: inout AccountSyncSummary) async throws -> Bool {
        do {
            let change = try body.map { try SyncChange.upsert(key, $0) } ?? (try SyncChange.delete(key))
            try await engine.stage(change)
            return true
        } catch let error as SyncError {
            summary.rejected.append(AccountSyncSummary.describe(key, body: body, error: error))
            return false
        }
    }

    /// Ids whose value differs between the two lists, including ones only in either.
    static func dirty<T: Equatable>(before: [T], now: [T], id: (T) -> UUID) -> Set<UUID> {
        let old = Dictionary(before.map { (id($0), $0) }) { first, _ in first }
        let new = Dictionary(now.map { (id($0), $0) }) { first, _ in first }
        return Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
    }

    // MARK: Conversions (the allowlisted fields only, DESIGN §5.1)

    static func id(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }

    static func nickname(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// A machine as the account stores it: the address split into host and port (22 left out),
    /// no secret. Nil for an address that doesn't parse.
    public static func syncBody(_ machine: LocalMachine, label: String?) -> SyncHost? {
        guard let endpoint = HostEndpoint.parse(machine.address) else { return nil }
        return SyncHost(nickname: nickname(machine.nickname), host: endpoint.host,
                        port: endpoint.port == 22 ? nil : Int(endpoint.port), username: machine.username,
                        authKind: machine.authKind, label: label)
    }

    static func endpoint(_ remote: SyncHost) -> HostEndpoint? {
        let port = remote.port ?? 22
        guard (1...65535).contains(port) else { return nil }
        return HostEndpoint(host: remote.host, port: UInt16(port))
    }

    /// The saved-address form of an account machine: `host`, `host:port`, `[v6]:port`.
    static func address(_ remote: SyncHost) -> String {
        guard let port = remote.port, port != 22 else { return remote.host }
        return remote.host.contains(":") ? "[\(remote.host)]:\(port)" : "\(remote.host):\(port)"
    }

    static func sameFields(_ machine: LocalMachine, _ remote: SyncHost) -> Bool {
        HostEndpoint.parse(machine.address) == endpoint(remote) && machine.username == remote.username
            && (nickname(machine.nickname) ?? "") == (nickname(remote.nickname) ?? "")
            && machine.authKind == (remote.authKind ?? .key)
    }

    static func syncBody(_ prompt: LocalPrompt, order: Double?) -> SyncPrompt {
        let title = prompt.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return SyncPrompt(title: title.isEmpty ? nil : title, text: prompt.text, order: order)
    }

    static func localPrompt(id: UUID, _ body: SyncPrompt) -> LocalPrompt {
        LocalPrompt(id: id, title: body.title ?? "", text: body.text)
    }

    static func sameFields(_ prompt: LocalPrompt, _ remote: SyncPrompt) -> Bool {
        prompt.title.trimmingCharacters(in: .whitespacesAndNewlines) == (remote.title ?? "") && prompt.text == remote.text
    }
}

/// One account sync at a time, and none lost: a sync asked for while one runs makes that run
/// go round once more when it ends, so an edit made during a sync is pushed by the next round
/// rather than folded into the one already under way.
@MainActor
public final class AccountSyncLoop {
    private let body: @MainActor () async -> Void
    private var running: Task<Void, Never>?
    private var again = false
    /// Bumped by `cancel()`, so a cancelled run that ends late doesn't clear a newer one.
    private var generation = 0

    public init(_ body: @escaping @MainActor () async -> Void) {
        self.body = body
    }

    public var isRunning: Bool { running != nil }

    /// Starts a run, or queues one more round of the run in progress.
    public func request() {
        guard running == nil else {
            again = true
            return
        }
        let started = generation
        running = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                again = false
                await body()
            } while again && !Task.isCancelled && generation == started
            if generation == started { running = nil }
        }
    }

    /// Returns once no run is in progress or queued.
    public func waitUntilIdle() async {
        while let running { await running.value }
    }

    /// Stops after the current round and drops any queued one.
    public func cancel() {
        generation += 1
        running?.cancel()
        running = nil
        again = false
    }
}
