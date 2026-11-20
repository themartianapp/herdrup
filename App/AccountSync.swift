import Foundation
import HerdrKit

/// What one sync did, for the account screen and its notices.
struct AccountSyncSummary: Equatable {
    var date = Date()
    var machinesAdded = 0
    var machinesMerged = 0
    var machinesRemoved = 0
    var machinesPushed = 0
    var promptsChanged = 0
    /// One line per item the account didn't take: refused as invalid, or holding something that
    /// looks like a secret (DESIGN #698 §5.4), which never leaves the device.
    var rejected: [String] = []
    /// Edits made on another device at the same time; the account's copy was kept.
    var conflicts = 0
    var overQuota = false
    /// Machines the account holds under another id that couldn't move to it here.
    var adoptFailures = 0

    /// The notice to show, or nil when everything went through.
    var problems: String? {
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

    static func describe(_ key: SyncKey, body: SyncBody?, error: SyncError) -> String {
        let name: String
        switch body {
        case .host(let host)?: name = "Machine “\(host.nickname ?? host.host)”"
        case .prompt(let prompt)?: name = "Prompt “\(prompt.title ?? String(prompt.text.prefix(24)))”"
        default: name = key.collection == .hosts ? "A machine" : "A prompt"
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
/// 3. The account's copy is merged into the local stores. Machines follow the host identity
///    rule (`SyncHostMerge`, the same as herdrup-desktop): a local machine matching an
///    account machine takes the account's id, of two account items for one machine the lower
///    `rev` is kept, and a second local copy is merged into the first. Local machines the
///    account doesn't know are staged, and pushed by a second `sync()`. On a first sign-in
///    that is "pull first, adopt, then push the rest".
///
/// Secrets never move: a machine's key or password stays in this device's Keychain, and a
/// machine new here asks for it (or a pairing) like any host whose secret is missing.
@MainActor
struct AccountSyncRun {
    let engine: SyncEngine
    let hosts: SavedHostsStore
    let prompts: SavedPromptsStore
    let defaults: UserDefaults
    /// Told when the run starts and stops changing the local stores.
    let applying: (Bool) -> Void

    /// The ids of machines and prompts this device held in step with the account at the end of
    /// the last sync: only these, when missing here, count as removed here.
    private static let hostIDsKey = "account.sync.hostIDs"
    private static let promptIDsKey = "account.sync.promptIDs"

    static func forgetLocalState(_ defaults: UserDefaults) {
        defaults.removeObject(forKey: hostIDsKey)
        defaults.removeObject(forKey: promptIDsKey)
    }

    func run() async throws -> AccountSyncSummary {
        var summary = AccountSyncSummary()
        let before = await engine.currentState
        let knownHosts = Set(before.items.filter { $0.key.collection == .hosts }.map(\.key.id))
        let knownPrompts = Set(before.items.filter { $0.key.collection == .prompts }.map(\.key.id))

        try await stageLocalHostEdits(into: &summary)
        try await stageLocalPromptEdits(into: &summary)
        summary.absorb(try await engine.sync())

        var staged = try await mergeHosts(known: knownHosts, into: &summary)
        staged = try await mergePrompts(known: knownPrompts, into: &summary) || staged
        if staged {
            summary.absorb(try await engine.sync())
        }
        await remember()
        return summary
    }

    // MARK: Machines

    private func stageLocalHostEdits(into summary: inout AccountSyncSummary) async throws {
        let items = await engine.items(in: .hosts)
        let mirror = Dictionary(items.map { ($0.key.id, $0) }) { first, _ in first }
        let held = Set(defaults.stringArray(forKey: Self.hostIDsKey) ?? [])
        var local: Set<String> = []
        for saved in hosts.hosts {
            let id = saved.id.uuidString.lowercased()
            local.insert(id)
            guard let item = mirror[id], case .host(let remote)? = item.body else { continue }
            guard !Self.sameFields(saved, remote), let body = Self.syncBody(saved, label: remote.label) else { continue }
            try await stage(SyncKey(.hosts, id), .host(body), into: &summary)
        }
        for id in held where !local.contains(id) && mirror[id] != nil {
            try await stage(SyncKey(.hosts, id), nil, into: &summary)
        }
    }

    /// Returns whether it staged anything to push.
    private func mergeHosts(known: Set<String>, into summary: inout AccountSyncSummary) async throws -> Bool {
        let mirror = await engine.items(in: .hosts)
        let byID = Dictionary(mirror.map { ($0.key.id, $0) }) { first, _ in first }
        let machines = hosts.hosts.compactMap { saved -> (SavedHost, SyncHostMerge.Local)? in
            guard let body = Self.syncBody(saved, label: nil) else { return nil }
            return (saved, SyncHostMerge.Local(id: saved.id.uuidString.lowercased(), body: body))
        }
        let plan = SyncHostMerge.plan(local: machines.map { $0.1 }, mirror: mirror, known: known)
        var staged = false
        applying(true)
        defer { applying(false) }

        for id in plan.delete {
            if try await stage(SyncKey(.hosts, id), nil, into: &summary) { staged = true }
        }
        // Where each local machine ends up, by index: its own id, or the account's.
        var finalID: [Int: UUID] = [:]
        for index in plan.matched {
            let saved = machines[index].0
            finalID[index] = saved.id
            if case .host(let remote)? = byID[machines[index].1.id]?.body { apply(remote, to: saved.id) }
        }
        for (index, id) in plan.adopt.sorted(by: { $0.key < $1.key }) {
            let saved = machines[index].0
            guard let uuid = UUID(uuidString: id), hosts.adoptSyncID(saved, id: uuid) else {
                summary.adoptFailures += 1
                continue
            }
            finalID[index] = uuid
            summary.machinesMerged += 1
            if case .host(let remote)? = byID[id]?.body { apply(remote, to: uuid) }
        }
        for (index, holder) in plan.duplicates.sorted(by: { $0.key < $1.key }) {
            guard let keeper = finalID[holder], let kept = hosts.hosts.first(where: { $0.id == keeper }) else { continue }
            if hosts.mergeDuplicate(machines[index].0, into: kept) { summary.machinesMerged += 1 }
        }
        for index in plan.gone {
            if hosts.delete(machines[index].0) { summary.machinesRemoved += 1 }
        }
        for id in plan.added {
            guard let uuid = UUID(uuidString: id), case .host(let remote)? = byID[id]?.body else { continue }
            apply(remote, to: uuid)
            summary.machinesAdded += 1
        }
        for index in plan.push {
            let local = machines[index].1
            if try await stage(SyncKey(.hosts, local.id), .host(local.body), into: &summary) {
                summary.machinesPushed += 1
                staged = true
            }
        }
        return staged
    }

    /// The account's fields onto the local machine `id` (added when it isn't here). The saved
    /// address keeps how it was typed when it names the same endpoint.
    private func apply(_ remote: SyncHost, to id: UUID) {
        let existing = hosts.hosts.first { $0.id == id }
        let address: String
        if let existing, HostEndpoint.parse(existing.host) == Self.endpoint(remote) {
            address = existing.host
        } else {
            address = Self.address(remote)
        }
        let nickname = remote.nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        hosts.applySynced(id: id, host: address, username: remote.username,
                          nickname: nickname?.isEmpty == false ? nickname : nil,
                          authKind: remote.authKind.map { $0 == .password ? .password : .key })
    }

    // MARK: Prompts

    private func stageLocalPromptEdits(into summary: inout AccountSyncSummary) async throws {
        let items = await engine.items(in: .prompts)
        let mirror = Dictionary(items.map { ($0.key.id, $0) }) { first, _ in first }
        let held = Set(defaults.stringArray(forKey: Self.promptIDsKey) ?? [])
        var local: Set<String> = []
        for prompt in prompts.prompts {
            let id = prompt.id.uuidString.lowercased()
            local.insert(id)
            guard let item = mirror[id], case .prompt(let remote)? = item.body,
                  !Self.sameFields(prompt, remote) else { continue }
            try await stage(SyncKey(.prompts, id), .prompt(Self.syncBody(prompt, order: remote.order)), into: &summary)
        }
        for id in held where !local.contains(id) && mirror[id] != nil {
            try await stage(SyncKey(.prompts, id), nil, into: &summary)
        }
    }

    private func mergePrompts(known: Set<String>, into summary: inout AccountSyncSummary) async throws -> Bool {
        let mirror = await engine.items(in: .prompts)
        var remote: [String: SyncPrompt] = [:]
        for item in mirror { if case .prompt(let body)? = item.body { remote[item.key.id] = body } }
        var next: [SavedPrompt] = []
        var toPush: [SavedPrompt] = []
        var changed = 0
        for prompt in prompts.prompts {
            let id = prompt.id.uuidString.lowercased()
            if let body = remote.removeValue(forKey: id) {
                let merged = Self.savedPrompt(id: prompt.id, body)
                if merged != prompt { changed += 1 }
                next.append(merged)
            } else if known.contains(id) {
                changed += 1
            } else {
                next.append(prompt)
                toPush.append(prompt)
            }
        }
        let added = remote.sorted { ($0.value.order ?? .infinity, $0.key) < ($1.value.order ?? .infinity, $1.key) }
        for (id, body) in added {
            guard let uuid = UUID(uuidString: id) else { continue }
            next.append(Self.savedPrompt(id: uuid, body))
            changed += 1
        }
        if next != prompts.prompts {
            applying(true)
            prompts.applySynced(next)
            applying(false)
        }
        summary.promptsChanged += changed
        var staged = false
        for prompt in toPush {
            let order = Double(next.firstIndex(of: prompt) ?? next.count)
            if try await stage(SyncKey(.prompts, prompt.id.uuidString.lowercased()),
                               .prompt(Self.syncBody(prompt, order: order)), into: &summary) {
                staged = true
            }
        }
        return staged
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

    private func remember() async {
        let hostItems = await engine.items(in: .hosts)
        let promptItems = await engine.items(in: .prompts)
        let hostIDs = Set(hostItems.map(\.key.id))
        let promptIDs = Set(promptItems.map(\.key.id))
        defaults.set(hosts.hosts.map { $0.id.uuidString.lowercased() }.filter(hostIDs.contains), forKey: Self.hostIDsKey)
        defaults.set(prompts.prompts.map { $0.id.uuidString.lowercased() }.filter(promptIDs.contains), forKey: Self.promptIDsKey)
    }

    // MARK: Conversions (the allowlisted fields only, DESIGN §5.1)

    /// A saved machine as the account stores it: the address split into host and port (22 is
    /// left out), no secret. Nil for an address that doesn't parse.
    static func syncBody(_ saved: SavedHost, label: String?) -> SyncHost? {
        guard let endpoint = HostEndpoint.parse(saved.host) else { return nil }
        let nickname = saved.nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SyncHost(nickname: nickname?.isEmpty == false ? nickname : nil, host: endpoint.host,
                        port: endpoint.port == 22 ? nil : Int(endpoint.port), username: saved.username,
                        authKind: saved.auth == .password ? .password : .key, label: label)
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

    static func sameFields(_ saved: SavedHost, _ remote: SyncHost) -> Bool {
        let nickname = saved.nickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let remoteNickname = remote.nickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return HostEndpoint.parse(saved.host) == endpoint(remote) && saved.username == remote.username
            && nickname == remoteNickname && saved.auth == (remote.authKind == .password ? .password : .key)
    }

    static func syncBody(_ prompt: SavedPrompt, order: Double?) -> SyncPrompt {
        let title = prompt.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return SyncPrompt(title: title.isEmpty ? nil : title, text: prompt.text, order: order)
    }

    static func savedPrompt(id: UUID, _ body: SyncPrompt) -> SavedPrompt {
        SavedPrompt(id: id, nickname: body.title ?? "", text: body.text)
    }

    static func sameFields(_ prompt: SavedPrompt, _ remote: SyncPrompt) -> Bool {
        prompt.nickname.trimmingCharacters(in: .whitespacesAndNewlines) == (remote.title ?? "") && prompt.text == remote.text
    }
}
