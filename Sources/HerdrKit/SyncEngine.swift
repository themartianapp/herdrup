import Foundation

/// What `SyncEngine` keeps between launches: the revision to pull from, this device's copy of
/// the service's items (tombstones included, so an editor's `base_rev` is right), and the
/// changes made here that haven't reached the service yet. Nothing in it is secret.
public struct SyncState: Codable, Equatable, Sendable {
    /// The `rev` of the last pull's last page: the next pull's `since`. 0 means a full pull.
    public var since: Int
    public var items: [SyncItem]
    public var pending: [SyncChange]

    public init(since: Int = 0, items: [SyncItem] = [], pending: [SyncChange] = []) {
        self.since = since
        self.items = items
        self.pending = pending
    }
}

/// Where `SyncState` lives: a file in the app, memory in tests.
public protocol SyncStateStore: Sendable {
    func loadSyncState() throws -> SyncState?
    func saveSyncState(_ state: SyncState) throws
    func deleteSyncState() throws
}

public final class InMemorySyncStateStore: SyncStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: SyncState?

    public init(state: SyncState? = nil) {
        self.state = state
    }

    public func loadSyncState() throws -> SyncState? {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    public func saveSyncState(_ state: SyncState) throws {
        lock.lock(); defer { lock.unlock() }
        self.state = state
    }

    public func deleteSyncState() throws {
        lock.lock(); defer { lock.unlock() }
        state = nil
    }
}

/// What a sync changed on this device, for the app to apply to its own stores.
public struct SyncReport: Equatable, Sendable {
    /// Items whose value here changed: new, or edited on another device.
    public var changed: [SyncItem] = []
    /// Items that are gone: deleted on another device, or dropped by a full pull.
    public var removed: [SyncKey] = []
    /// Edits the service refused because their `baseRev` was stale. The local edit is no longer
    /// queued; the app shows both and stages again with `baseRev: server?.rev ?? 0` to keep its own.
    public var conflicts: [SyncConflict] = []
    /// Changes the service refused as invalid (`400 invalid_item`), dropped from the queue.
    public var rejected: [SyncRejection] = []
    /// The account is at a cap (`403 quota`): the queue stays until something is deleted.
    public var overQuota = false
    /// This sync was a full pull, which replaced this device's copy (DESIGN §5.5).
    public var replaced = false
}

public struct SyncConflict: Equatable, Sendable {
    public let local: SyncChange
    /// The service's copy (perhaps a tombstone), or nil when it holds none.
    public let server: SyncItem?
}

public struct SyncRejection: Equatable, Sendable {
    public let change: SyncChange
    public let field: String
}

/// Sync of non-secret settings with the account service (DESIGN §5).
///
/// - **Order.** The service orders writes: each takes the account's next revision, and the last
///   write to reach it wins, per item. Settings are one item per key, so two devices changing
///   different settings don't clobber each other. A local edit stays queued (and wins here)
///   until its push lands, since it will be the later write.
/// - **Push.** `stage` queues a change, which `SyncChange` has already checked against the
///   service's schema and `SyncSecretScan`. `sync` pushes the queue (≤ 100 changes and 256 KB a
///   push), then pulls. A change with `baseRev` that the service refuses comes back in
///   `SyncReport.conflicts` with the service's copy.
/// - **Pull.** `GET /v1/sync?since=<rev>`, then `?cursor=<cursor>` while `more`, sending the
///   cursor back unchanged; the last page's `rev` is the next `since`. Pages are applied only
///   once the last one has arrived, so a pull cut short changes nothing.
/// - **Replace.** A full pull (`since` 0, or after `410 reset_required`) doesn't list the
///   tombstones pruned while it ran, so it replaces this device's copy: every item it doesn't
///   list as live is removed (DESIGN §5.5). Queued local changes are kept and pushed next.
public actor SyncEngine {
    /// The service's push limits (sync.ts `MAX_CHANGES`, `MAX_SYNC_BODY_BYTES`).
    public static let maxChangesPerPush = 100
    public static let maxPushBytes = 256 * 1024
    /// Full pulls tried in a row when the service keeps answering `410 reset_required`.
    static let maxResets = 3

    private let session: AccountSession
    private let store: SyncStateStore
    private let now: @Sendable () -> Date
    private var state: SyncState
    private var running: Task<SyncReport, Error>?

    public init(session: AccountSession, store: SyncStateStore, now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.session = session
        self.store = store
        self.now = now
        state = try store.loadSyncState() ?? SyncState()
    }

    /// The state as kept, for tests and diagnostics.
    public var currentState: SyncState { state }

    /// The live items of `collection` as this device sees them: the service's copy with the
    /// queued local changes applied.
    public func items(in collection: SyncCollection) -> [SyncItem] {
        effective().values.filter { $0.key.collection == collection }.sorted { $0.key.id < $1.key.id }
    }

    /// The item as this device sees it, nil when absent or deleted.
    public func item(_ key: SyncKey) -> SyncItem? { effective()[key] }

    /// The revision of the service's copy (tombstones included), for an editor's `baseRev`.
    /// 0 when the service has never held it.
    public func serverRev(_ key: SyncKey) -> Int {
        state.items.first { $0.key == key }?.rev ?? 0
    }

    /// Queues a local change; a later change to the same item replaces it.
    public func stage(_ change: SyncChange) throws {
        state.pending.removeAll { $0.key == change.key }
        state.pending.append(change)
        try store.saveSyncState(state)
    }

    /// Forgets everything: at sign-out and account deletion. The app's own copies stay.
    public func clear() throws {
        state = SyncState()
        try store.deleteSyncState()
    }

    /// Pushes the queue, then pulls. Concurrent calls share one run.
    public func sync() async throws -> SyncReport {
        if let running { return try await running.value }
        let task = Task { try await self.run() }
        running = task
        defer { if running == task { running = nil } }
        return try await task.value
    }

    private func run() async throws -> SyncReport {
        let before = effective()
        var report = SyncReport()
        try await push(into: &report)
        try await pull(into: &report)
        try store.saveSyncState(state)
        let after = effective()
        for (key, item) in after where before[key]?.body != item.body {
            report.changed.append(item)
        }
        report.changed.sort { $0.key.description < $1.key.description }
        report.removed = before.keys.filter { after[$0] == nil }.sorted { $0.description < $1.description }
        return report
    }

    // MARK: Push

    private func push(into report: inout SyncReport) async throws {
        var queue = state.pending
        while !queue.isEmpty {
            let batch = try Self.nextBatch(of: queue)
            queue.removeFirst(batch.count)
            var remaining = batch
            while !remaining.isEmpty {
                let client = session.client
                let changes = remaining
                do {
                    let result = try await session.authorized { try await client.push(changes, accessToken: $0) }
                    apply(result, of: changes, into: &report)
                    remaining = []
                } catch AccountError.refused(400, "invalid_item", let field, let index?) where changes.indices.contains(index) {
                    // One bad change refuses the whole push: drop it, push the rest again.
                    let bad = changes[index]
                    report.rejected.append(SyncRejection(change: bad, field: field ?? ""))
                    dropPending(bad)
                    remaining.remove(at: index)
                } catch AccountError.refused(403, "quota", _, _) {
                    report.overQuota = true
                    return
                }
            }
            try store.saveSyncState(state)
        }
    }

    /// The longest prefix of `queue` within one push's limits.
    static func nextBatch(of queue: [SyncChange]) throws -> [SyncChange] {
        let encoder = JSONEncoder()
        var batch: [SyncChange] = []
        var bytes = 16
        for change in queue.prefix(maxChangesPerPush) {
            let size = try encoder.encode(change).count + 1
            if !batch.isEmpty && bytes + size > maxPushBytes { break }
            batch.append(change)
            bytes += size
        }
        return batch
    }

    private func apply(_ result: SyncPushResult, of changes: [SyncChange], into report: inout SyncReport) {
        let updatedMs = Int(now().timeIntervalSince1970 * 1000)
        for applied in result.applied {
            guard let change = changes.first(where: { $0.key == applied.key }) else { continue }
            if applied.rev == 0 {
                state.items.removeAll { $0.key == applied.key }
            } else {
                store(SyncItem(key: applied.key, rev: applied.rev, updatedMs: updatedMs, body: change.body), force: false)
            }
            dropPending(change)
        }
        for conflict in result.conflicts {
            guard let change = changes.first(where: { $0.key == conflict.key }) else { continue }
            if let server = conflict.server {
                store(server, force: true)
            } else {
                state.items.removeAll { $0.key == conflict.key }
            }
            dropPending(change)
            report.conflicts.append(SyncConflict(local: change, server: conflict.server))
        }
    }

    /// Unqueues `change`, unless it was replaced by a newer edit while its push ran.
    private func dropPending(_ change: SyncChange) {
        state.pending.removeAll { $0 == change }
    }

    // MARK: Pull

    private func pull(into report: inout SyncReport) async throws {
        var resets = 0
        var since = state.since
        while true {
            do {
                let (items, rev) = try await pullPages(since: since)
                if since == 0 {
                    // A full pull replaces this device's copy (DESIGN §5.5): what it doesn't
                    // list is gone, including deletes whose tombstones were pruned meanwhile.
                    state.items = []
                    report.replaced = true
                }
                for item in items { store(item, force: false) }
                state.since = rev
                return
            } catch AccountError.refused(410, "reset_required", _, _) where resets < Self.maxResets {
                resets += 1
                since = 0
            }
        }
    }

    /// Every page from `since`, and the revision to pull from next time.
    private func pullPages(since: Int) async throws -> ([SyncItem], Int) {
        let client = session.client
        var page = try await session.authorized { try await client.pull(since: since, accessToken: $0) }
        var items = page.changes
        while page.more {
            guard let cursor = page.cursor else { throw AccountError.malformedResponse }
            page = try await session.authorized { try await client.pull(cursor: cursor, accessToken: $0) }
            items += page.changes
        }
        return (items, page.rev)
    }

    // MARK: The local copy

    /// Keeps `item` unless a newer revision of it is already here (`force`: the service's copy
    /// from a conflict, which is current by definition).
    private func store(_ item: SyncItem, force: Bool) {
        if let index = state.items.firstIndex(where: { $0.key == item.key }) {
            if force || item.rev >= state.items[index].rev { state.items[index] = item }
        } else {
            state.items.append(item)
        }
    }

    /// The service's copy, live items only, with the queue applied over it.
    private func effective() -> [SyncKey: SyncItem] {
        var view: [SyncKey: SyncItem] = [:]
        for item in state.items where !item.deleted { view[item.key] = item }
        for change in state.pending {
            if let body = change.body {
                let base = view[change.key] ?? state.items.first { $0.key == change.key }
                view[change.key] = SyncItem(key: change.key, rev: base?.rev ?? 0, updatedMs: base?.updatedMs ?? 0, body: body)
            } else {
                view[change.key] = nil
            }
        }
        return view
    }
}
