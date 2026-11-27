import Foundation

/// A share the HerdrUp account holds (the `shares` collection, DESIGN #698 §5.1) that this
/// device has not opened yet: what SHARED WITH YOU lists with nothing to accept, and where its
/// first hello goes. Nothing in it is secret: `guest_id` only selects the grant, and the host
/// admits this device on the account's statement (§4).
public struct AccountShare: Equatable, Hashable, Sendable, Identifiable {
    public let guestID: String
    public let endpoint: RelayEndpoint
    public let agentName: String
    public let ownerName: String
    public let machineLabel: String

    /// The item id, and the id of the `GuestAccess` it becomes: `<host_id>/<guest_id>`.
    public var id: String { "\(endpoint.hostID)/\(guestID)" }

    public init(guestID: String, endpoint: RelayEndpoint, agentName: String, ownerName: String, machineLabel: String) {
        self.guestID = guestID
        self.endpoint = endpoint
        self.agentName = agentName
        self.ownerName = ownerName
        self.machineLabel = machineLabel
    }

    /// The account's item as a share to list; nil when its relay or node key can't be used.
    /// The labels are optional in the collection; every client writes them, so the fallbacks
    /// only cover an item written without them.
    public init?(_ share: SyncShare) {
        guard let relay = URL(string: share.relay), relay.host?.isEmpty == false,
              let key = Base64URL.decode(share.nodePub), key.count == 32 else { return nil }
        func text(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            return trimmed
        }
        self.init(guestID: share.guestID,
                  endpoint: RelayEndpoint(relay: relay, hostID: share.hostID, hostPublicKey: key),
                  agentName: text(share.agentName) ?? "agent",
                  ownerName: text(share.ownerName) ?? "the owner",
                  machineLabel: text(share.machineLabel) ?? "Shared machine")
    }
}

extension SyncShare {
    /// The item an account-bound share is saved as: where to reach it and what to show, from
    /// the allowlisted fields only. `relay` is the relay's canonical base (origin plus path,
    /// no trailing slash), never an invite link.
    public init(_ access: GuestAccess) {
        self.init(relay: Self.relayBase(access.endpoint.relay), hostID: access.endpoint.hostID,
                  nodePub: Base64URL.encode(access.endpoint.hostPublicKey), guestID: access.guestID,
                  agentName: access.agentName, ownerName: access.ownerName, machineLabel: access.machineLabel)
    }

    static func relayBase(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path
        return components.string ?? url.absoluteString
    }
}

extension SyncKey {
    /// The item an account-bound share is saved under.
    public static func share(_ access: GuestAccess) -> SyncKey {
        .share(hostID: access.endpoint.hostID, guestID: access.guestID)
    }
}

extension GuestSession {
    /// Opens a share the account holds on this device for the first time: no invite, nothing
    /// to accept. The returning hello selects the grant by `guest_id` and carries this
    /// device's statement and name, so herdr adds the device to the grant and names it in the
    /// owner's list (DESIGN #698 §4). The reply names the grant as an accept's does, and the
    /// result is account-bound, so every later hello carries a statement too.
    public static func open(
        _ share: AccountShare, identity: GuestIdentity, device: String = "iPhone",
        statements: GuestStatementSource?, now: Date = Date(),
        connector: RelaySocketConnector = URLSessionRelayConnector()
    ) async throws -> GuestAccess {
        let statement = try await GuestStatements.fetch(for: share.endpoint.hostID, from: statements)
        let hello = try JSONEncoder().encode(Hello.returning(share.guestID, account: statement.jws, device: device))
        let session = try await RelaySession.open(endpoint: share.endpoint, identity: identity, hello: hello, connector: connector)
        session.close()
        return try access(from: session.reply, expecting: ExpectedGrant(share), endpoint: share.endpoint, now: now,
                          accountBound: true)
    }
}

extension GuestSession.ExpectedGrant {
    /// A share opened from the account: its grant is selected, and only the host knows the
    /// guest's name.
    init(_ share: AccountShare) {
        self.init(guestID: share.guestID, guestName: nil, machineLabel: share.machineLabel,
                  ownerName: share.ownerName, agentName: share.agentName)
    }
}

/// Which HerdrUp account each account-bound share on this device belongs to, and the leaves
/// not yet written to it. It is kept with the shares, not with the sign-in: a sign-out clears
/// the sync state but not this. So a share left on another device while this one was signed
/// out is not pushed back at the next sign-in, and a share left here while signed out is
/// deleted from its account at the next sign-in to that account.
public struct AccountShareLedger: Codable, Equatable, Sendable {
    /// Share id → the account it was added to.
    public var owners: [String: String] = [:]
    /// Share id → the account it was left from here, until that account holds its tombstone.
    public var leaves: [String: String] = [:]
    /// Account id → the shares this device held in step with that account at the end of its
    /// last sync: one of these the account no longer holds was left elsewhere.
    public var held: [String: Set<String>] = [:]

    public init() {}

    /// Shares added while signed in to `account` (accepted with it, or opened from it).
    public mutating func claim(_ ids: some Sequence<String>, account: String) {
        for id in ids where owners[id] == nil { owners[id] = account }
    }

    /// `access` was left here (Leave, Remove share). One its account may hold is deleted
    /// there at that account's next sync, signed out meanwhile or not. A share no account
    /// ever took has nothing to delete.
    public mutating func left(_ access: GuestAccess) {
        guard access.accountBound, let owner = owners.removeValue(forKey: access.id) else { return }
        leaves[access.id] = owner
    }
}

/// The app's shares as `AccountShareSync` reads and changes them.
@MainActor
public protocol AccountShareStore: AnyObject {
    /// The shares held on this device; only account-bound ones take part.
    var shares: [GuestAccess] { get }
    /// Drops shares left on another device (their items are tombstones now). Nothing more is
    /// sent to the account for them.
    func removeLeftElsewhere(_ ids: Set<String>)
    /// The account's shares that aren't on this device: SHARED WITH YOU lists them.
    func setAccountShares(_ shares: [AccountShare])
    /// Persisted with the shares; a sign-out leaves it as it is.
    var ledger: AccountShareLedger { get set }
}

/// What one `AccountShareSync` decides, before anything is written.
public struct AccountSharePlan: Equatable, Sendable {
    /// Account-bound shares added here that the account doesn't hold yet.
    public var push: [SyncShare] = []
    /// Shares left here: their items become tombstones, so they leave every device.
    public var delete: [SyncKey] = []
    /// Shares here whose items were deleted on another device.
    public var removeHere: Set<String> = []
    /// The account's shares this device doesn't hold.
    public var available: [AccountShare] = []
    /// Account-bound shares here no account has claimed yet: this account's.
    public var claim: Set<String> = []
    /// Leaves from this account it holds no live item for any more: nothing left to delete.
    public var leavesDone: Set<String> = []

    public init() {}
}

/// The service's copy of the `shares` collection, as `AccountShareSync.plan` reads it.
public struct AccountShareMirror: Equatable, Sendable {
    /// Live items, with the changes queued here applied.
    public var live: [SyncItem]
    /// Ids the service holds as tombstones, with nothing queued here for them.
    public var tombstones: Set<String>
    /// Ids with a change queued here, not yet taken by the service.
    public var queued: Set<String>

    public init(live: [SyncItem], tombstones: Set<String> = [], queued: Set<String> = []) {
        self.live = live
        self.tombstones = tombstones
        self.queued = queued
    }

    /// The engine's current view.
    public static func of(_ engine: SyncEngine) async -> AccountShareMirror {
        let state = await engine.currentState
        let live = await engine.items(in: .shares)
        let queued = Set(state.pending.map(\.key).filter { $0.collection == .shares }.map(\.id))
        let tombstones = Set(state.items.filter { $0.key.collection == .shares && $0.deleted }.map(\.key.id))
        return AccountShareMirror(live: live, tombstones: tombstones.subtracting(queued), queued: queued)
    }
}

/// The guest side of the `shares` collection (#700): run after `AccountLocalSync`, on the
/// mirror it just pulled, for the signed-in `account`.
///
/// - **Added with the account here** (accepted with it, or opened from it): the share is
///   claimed for the account and pushed when the account doesn't hold it yet.
/// - **Left here** (Leave, Remove share): the ledger keeps a leave until the share's own
///   account holds a tombstone for it, so it leaves every device, even when it was left while
///   signed out.
/// - **Left on another device:** a share of this account that it holds as a tombstone, or
///   that was in step at this account's last sync and is gone, is removed here and never
///   pushed back.
/// - **Accepted on another device:** listed with nothing to accept; opening it is a returning
///   hello with the statement (`GuestSession.open(_:)`).
/// - A share of another account waits for a sign-in to that account.
@MainActor
public struct AccountShareSync {
    public let engine: SyncEngine
    public let store: AccountShareStore
    public let account: String

    public init(engine: SyncEngine, store: AccountShareStore, account: String) {
        self.engine = engine
        self.store = store
        self.account = account
    }

    public static func plan(local: [GuestAccess], mirror: AccountShareMirror, ledger: AccountShareLedger,
                            account: String) -> AccountSharePlan {
        var live: [String: SyncShare] = [:]
        for item in mirror.live where item.key.collection == .shares {
            if case .share(let share)? = item.body { live[item.key.id] = share }
        }
        let held = ledger.held[account] ?? []
        let here = Set(local.map(\.id))
        var plan = AccountSharePlan()
        for access in local where access.accountBound {
            switch ledger.owners[access.id] {
            case nil: plan.claim.insert(access.id)
            case account?: break
            default: continue
            }
            if live[access.id] != nil || mirror.queued.contains(access.id) { continue }
            if mirror.tombstones.contains(access.id) || held.contains(access.id) {
                plan.removeHere.insert(access.id)
            } else {
                plan.push.append(SyncShare(access))
            }
        }
        for (id, owner) in ledger.leaves.sorted(by: { $0.key < $1.key }) where owner == account {
            if let share = live[id] {
                plan.delete.append(.share(hostID: share.hostID, guestID: share.guestID))
            } else if !mirror.queued.contains(id) {
                plan.leavesDone.insert(id)
            }
        }
        plan.available = live.keys.sorted()
            .filter { !here.contains($0) && ledger.leaves[$0] == nil }
            .compactMap { live[$0].flatMap(AccountShare.init) }
        return plan
    }

    /// The plan, applied: removals, the list here and the ledger, then pushes and deletes.
    /// Returns the summary of the extra push, when there was one.
    @discardableResult
    public func run() async throws -> AccountSyncSummary {
        var summary = AccountSyncSummary()
        let mirror = await AccountShareMirror.of(engine)
        // No await from the snapshot to the store writes: the plan holds for what is here.
        let plan = Self.plan(local: store.shares, mirror: mirror, ledger: store.ledger, account: account)
        if !plan.removeHere.isEmpty { store.removeLeftElsewhere(plan.removeHere) }
        store.setAccountShares(plan.available)
        var ledger = store.ledger
        ledger.claim(plan.claim, account: account)
        for id in plan.removeHere { ledger.owners[id] = nil }
        for id in plan.leavesDone { ledger.leaves[id] = nil }
        store.ledger = ledger

        var staged = false
        for share in plan.push {
            if try await stage(.share(hostID: share.hostID, guestID: share.guestID), .share(share), into: &summary) {
                staged = true
            }
        }
        for key in plan.delete {
            if try await stage(key, nil, into: &summary) { staged = true }
        }
        if staged { summary.absorb(try await engine.sync()) }

        // What changed here while the run waited (a share left, one added) is in the ledger
        // and the store now: read both again.
        let after = await AccountShareMirror.of(engine)
        let inAccount = Set(after.live.map(\.key.id))
        ledger = store.ledger
        for (id, owner) in ledger.leaves where owner == account && !inAccount.contains(id) && !after.queued.contains(id) {
            ledger.leaves[id] = nil
        }
        let mine = store.shares.filter { $0.accountBound && ledger.owners[$0.id] == account }.map(\.id)
        ledger.held[account] = Set(mine).intersection(inAccount)
        let kept = Set(store.shares.map(\.id))
        ledger.owners = ledger.owners.filter { kept.contains($0.key) }
        store.ledger = ledger
        return summary
    }

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
}
