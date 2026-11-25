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
    /// `{"v":1,"guest_id":…,"account":…,"device":…}`: a returning hello for an account-bound
    /// grant from a device the host may not know yet. herdr adds the device to the grant on
    /// the statement and names it by `device` in the owner's list (DESIGN #698 §4).
    private struct FirstOpenHello: Encodable {
        let v = 1
        let guestID: String
        let account: String
        let device: String

        enum CodingKeys: String, CodingKey {
            case v, account, device
            case guestID = "guest_id"
        }
    }

    /// Opens a share the account holds on this device for the first time: no invite, nothing
    /// to accept. The hello selects the grant by `guest_id` and carries this device's
    /// statement for the host; the reply names the grant as an accept's does, and the result
    /// is account-bound, so every later hello carries a statement too.
    public static func open(
        _ share: AccountShare, identity: GuestIdentity, device: String = "iPhone",
        statements: GuestStatementSource?, now: Date = Date(),
        connector: RelaySocketConnector = URLSessionRelayConnector()
    ) async throws -> GuestAccess {
        let statement = try await GuestStatements.fetch(for: share.endpoint.hostID, from: statements)
        let hello = try JSONEncoder().encode(FirstOpenHello(guestID: share.guestID, account: statement.jws, device: device))
        let session = try await RelaySession.open(endpoint: share.endpoint, identity: identity, hello: hello, connector: connector)
        session.close()
        guard session.reply["guest_id"] as? String == share.guestID else { throw GuestError.revoked }
        return try access(from: session.reply, share: share, now: now)
    }

    static func access(from reply: [String: Any], share: AccountShare, now: Date) throws -> GuestAccess {
        func text(_ value: Any?) -> String? {
            guard let string = value as? String, !string.isEmpty else { return nil }
            return string
        }
        let agent = reply["agent"] as? [String: Any]
        guard let target = text(agent?["target"]), let name = text(reply["name"]) else {
            throw GuestError.secureChannelFailed("the host's answer is incomplete")
        }
        return GuestAccess(
            guestID: share.guestID,
            guestName: name,
            machineLabel: text(reply["machine_label"]) ?? share.machineLabel,
            ownerName: text(reply["owner_name"]) ?? share.ownerName,
            agentName: text(agent?["name"]) ?? share.agentName,
            agentTarget: target,
            endpoint: share.endpoint,
            acceptedAt: now,
            accountBound: true)
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
    /// The ids this device held in step with the account at the end of the last sync: only
    /// these, when missing here, count as left here.
    var heldShareIDs: Set<String> { get set }
}

/// What one `AccountShareSync` decides, before anything is written.
public struct AccountSharePlan: Equatable, Sendable {
    /// Account-bound shares accepted here that the account doesn't hold yet.
    public var push: [SyncShare] = []
    /// Shares left here: their items become tombstones, so they leave every device.
    public var delete: [SyncKey] = []
    /// Shares here whose items were deleted on another device.
    public var removeHere: Set<String> = []
    /// The account's shares this device doesn't hold.
    public var available: [AccountShare] = []

    public init() {}
}

/// The guest side of the `shares` collection (#700): run after `AccountLocalSync`, on the
/// mirror it just pulled.
///
/// - **Accepted with the account here:** the share is pushed (on the next sync after accept,
///   or after a sync that couldn't reach the service).
/// - **Left here** (Leave, Remove share): a share held in step that is no longer here is
///   deleted in the account, so it leaves the other devices too.
/// - **Left on another device:** a share held in step whose item is gone is removed here.
/// - **Accepted on another device:** listed with nothing to accept; opening it is a returning
///   hello with the statement (`GuestSession.open(_:)`), and only then is it held here.
///
/// The ids held at the end come from the shares this run saw, so a share left while the run
/// waited on the network still counts as held and is deleted by the next run.
@MainActor
public struct AccountShareSync {
    public let engine: SyncEngine
    public let store: AccountShareStore

    public init(engine: SyncEngine, store: AccountShareStore) {
        self.engine = engine
        self.store = store
    }

    public static func plan(local: [GuestAccess], mirror: [SyncItem], held: Set<String>) -> AccountSharePlan {
        var live: [String: SyncShare] = [:]
        for item in mirror where item.key.collection == .shares {
            if case .share(let share)? = item.body { live[item.key.id] = share }
        }
        let here = Set(local.map(\.id))
        var plan = AccountSharePlan()
        for access in local where access.accountBound {
            if live[access.id] != nil { continue }
            if held.contains(access.id) {
                plan.removeHere.insert(access.id)
            } else {
                plan.push.append(SyncShare(access))
            }
        }
        var leaving: Set<String> = []
        for id in held.sorted() where !here.contains(id) {
            guard let share = live[id] else { continue }
            leaving.insert(id)
            plan.delete.append(.share(hostID: share.hostID, guestID: share.guestID))
        }
        plan.available = live.keys.sorted()
            .filter { !here.contains($0) && !leaving.contains($0) }
            .compactMap { live[$0].flatMap(AccountShare.init) }
        return plan
    }

    /// The plan, applied: removals and the list here, then pushes and deletes. Returns the
    /// summary of the extra push, when there was one.
    @discardableResult
    public func run() async throws -> AccountSyncSummary {
        var summary = AccountSyncSummary()
        let mirror = await engine.items(in: .shares)
        // No await from the snapshot to the store writes: the plan holds for what is here.
        let local = store.shares
        let plan = Self.plan(local: local, mirror: mirror, held: store.heldShareIDs)
        if !plan.removeHere.isEmpty { store.removeLeftElsewhere(plan.removeHere) }
        store.setAccountShares(plan.available)
        let seen = Set(local.filter(\.accountBound).map(\.id)).subtracting(plan.removeHere)
            .union(store.heldShareIDs)

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

        let account = Set(await engine.items(in: .shares).map(\.key.id))
        store.heldShareIDs = seen.intersection(account)
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
