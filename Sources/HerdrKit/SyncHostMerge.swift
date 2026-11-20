import Foundation

/// What makes two saved machines the same machine across devices (DESIGN #698 §5.5, the rule
/// herdrup-desktop's `internal/account/hosts.go` uses too): the username exactly as typed, the
/// host lowercased without a trailing dot, and the port, 22 when there is none. Nickname, label
/// and auth kind are not part of it.
public struct SyncHostIdentity: Hashable, Sendable {
    public let username: String
    public let host: String
    public let port: Int

    public init(_ body: SyncHost) {
        username = body.username
        var host = body.host.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        self.host = host
        port = body.port ?? 22
    }
}

/// Merges the account's saved machines into this device's (DESIGN #698 §5.5).
///
/// - Forks: of two account items with one identity, the lower `rev` is kept and the other is
///   deleted; a local machine on the deleted one moves to the kept one.
/// - A local machine whose id the account holds is that item, whatever its host or user now:
///   a rename on either side is an edit, not a delete.
/// - A local machine otherwise matching an item's identity takes the item's id: the account's
///   id wins over a different local one.
/// - A local machine whose id the account held (`known`) and no longer holds was deleted on
///   another device; one whose id it never held is pushed under its own id.
/// - An account item no local machine took is new here.
public enum SyncHostMerge {
    /// A local machine as the merge sees it: its sync id (a lowercase UUID) and its fields.
    public struct Local: Equatable, Sendable {
        public let id: String
        public let body: SyncHost

        public init(id: String, body: SyncHost) {
            self.id = id
            self.body = body
        }
    }

    public struct Plan: Equatable, Sendable {
        /// Local machine (by index) → the account's id it takes.
        public var adopt: [Int: String] = [:]
        /// Local machines (by index) matched to the account's item with the same id.
        public var matched: [Int] = []
        /// Local machines (by index) to push under their own id.
        public var push: [Int] = []
        /// Local machines (by index) that are the same machine as another local one (by index),
        /// which holds the account's item: merge them into that one.
        public var duplicates: [Int: Int] = [:]
        /// Account items that fork a machine another item already holds: tombstone them.
        public var delete: [String] = []
        /// Local machines (by index) the account deleted.
        public var gone: [Int] = []
        /// Live account items no local machine holds: add them here.
        public var added: [String] = []

        public init() {}
    }

    /// `mirror` is the account's live hosts items (tombstones and other collections are
    /// skipped); `known` the host ids the account is known to have held before this pull.
    public static func plan(local: [Local], mirror: [SyncItem], known: Set<String>) -> Plan {
        var plan = Plan()
        let remote: [(id: String, rev: Int, body: SyncHost)] = mirror.compactMap { item in
            guard item.key.collection == .hosts, case .host(let body)? = item.body else { return nil }
            return (item.key.id, item.rev, body)
        }.sorted { $0.rev != $1.rev ? $0.rev < $1.rev : $0.id < $1.id }

        var byIdentity: [SyncHostIdentity: String] = [:]
        var kept: Set<String> = []
        var forkOf: [String: String] = [:]
        for item in remote {
            let identity = SyncHostIdentity(item.body)
            if let keep = byIdentity[identity] {
                plan.delete.append(item.id)
                forkOf[item.id] = keep
            } else {
                byIdentity[identity] = item.id
                kept.insert(item.id)
            }
        }

        var claimedBy: [String: Int] = [:]
        var placed = Array(repeating: false, count: local.count)
        // By id first: the account's item is this machine even after a rename.
        for (index, machine) in local.enumerated() {
            let target = forkOf[machine.id] ?? machine.id
            guard kept.contains(target), claimedBy[target] == nil else { continue }
            claimedBy[target] = index
            placed[index] = true
            if target == machine.id { plan.matched.append(index) } else { plan.adopt[index] = target }
        }
        for (index, machine) in local.enumerated() where !placed[index] {
            // A machine on a deleted fork whose kept item is taken, or one matching a taken
            // item's identity, is a second copy of a machine already here.
            let target = forkOf[machine.id] ?? byIdentity[SyncHostIdentity(machine.body)]
            if let id = target, let holder = claimedBy[id] {
                plan.duplicates[index] = holder
            } else if let id = target {
                claimedBy[id] = index
                if id == machine.id { plan.matched.append(index) } else { plan.adopt[index] = id }
            } else if known.contains(machine.id) {
                plan.gone.append(index)
            } else {
                plan.push.append(index)
            }
        }
        plan.added = remote.map(\.id).filter { kept.contains($0) && claimedBy[$0] == nil }
        return plan
    }
}
