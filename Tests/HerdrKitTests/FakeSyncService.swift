import Foundation
@testable import HerdrKit

/// The sync half of the account service in memory, following AccountService/src/sync.ts:
/// every accepted write takes the account's next revision; `base_rev` mismatches come back as
/// conflicts with the stored copy; a write identical to the stored item keeps its revision;
/// deleting an absent item reports rev 0; pulls page by revision with a
/// `<position>.<base>` cursor; and `410 reset_required` follows the floor rule of DESIGN §5.5.
/// The page size is small so paging shows in a test.
final class FakeSyncService: @unchecked Sendable {
    struct Stored {
        var rev: Int
        var updatedMs: Int
        var deleted: Bool
        /// Canonical JSON (sorted keys), nil for a tombstone.
        var body: String?
    }

    private let lock = NSLock()
    private var items: [String: (collection: String, id: String, stored: Stored)] = [:]
    private(set) var syncRev = 0
    private(set) var floor = 0
    var pageSize = 500
    /// When set, a push answers this instead (403 quota, 400 invalid_item, …).
    var pushRefusal: ((_ changes: [[String: Any]]) -> AccountServiceStub.Reply?)?
    private var refreshCount = 0

    /// Answers sync and refresh requests; any bearer is accepted (sessions are tested elsewhere).
    func handle(_ request: AccountServiceStub.Request) -> AccountServiceStub.Reply {
        lock.lock(); defer { lock.unlock() }
        switch (request.method, request.path) {
        case ("POST", "/v1/auth/refresh"):
            refreshCount += 1
            return .json(200, StubTokens.pair(refreshCount))
        case ("GET", "/v1/sync"):
            return pull(request.query)
        case ("POST", "/v1/sync"):
            let changes = request.json["changes"] as? [[String: Any]] ?? []
            if let refusal = pushRefusal?(changes) { return refusal }
            return push(changes)
        default:
            return .error(404, "not_found")
        }
    }

    // MARK: Another device's writes, and the cron

    /// Writes as another device would (no base_rev).
    func write(_ collection: String, _ id: String, body: [String: Any]?) {
        lock.lock(); defer { lock.unlock() }
        _ = apply(collection: collection, id: id, baseRev: nil, deleted: body == nil, body: body.map(canonical))
    }

    /// The hourly prune: every tombstone goes, and the floor rises past them.
    func pruneTombstones() {
        lock.lock(); defer { lock.unlock() }
        for (key, entry) in items where entry.stored.deleted {
            floor = max(floor, entry.stored.rev)
            items[key] = nil
        }
    }

    func body(_ collection: String, _ id: String) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        guard let text = items[key(collection, id)]?.stored.body else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    func rev(_ collection: String, _ id: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return items[key(collection, id)]?.stored.rev
    }

    var liveCount: Int {
        lock.lock(); defer { lock.unlock() }
        return items.values.filter { !$0.stored.deleted }.count
    }

    // MARK: Endpoints

    private func pull(_ query: [String: String]) -> AccountServiceStub.Reply {
        let position: Int
        let base: Int
        if let cursor = query["cursor"] {
            let parts = cursor.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 2 else { return .error(400, "bad_request") }
            position = parts[0]
            base = parts[1]
        } else {
            position = Int(query["since"] ?? "0") ?? -1
            guard position >= 0 else { return .error(400, "bad_request") }
            base = position == 0 ? syncRev : position
        }
        let complete = max(position, base)
        if complete > syncRev || complete < floor { return .error(410, "reset_required") }
        let rows = items.values.filter { $0.stored.rev > position }.sorted { $0.stored.rev < $1.stored.rev }
        let more = rows.count > pageSize
        let page = rows.prefix(pageSize).map(itemJSON)
        if !more { return .json(200, ["rev": syncRev, "changes": page, "more": false]) }
        let last = rows[pageSize - 1].stored.rev
        return .json(200, ["rev": last, "changes": page, "more": true, "cursor": "\(last).\(base)"])
    }

    private func push(_ changes: [[String: Any]]) -> AccountServiceStub.Reply {
        var applied: [[String: Any]] = []
        var conflicts: [[String: Any]] = []
        for change in changes {
            let collection = change["collection"] as? String ?? ""
            let id = change["id"] as? String ?? ""
            let deleted = change["deleted"] as? Bool ?? false
            let body = (change["body"] as? [String: Any]).map(canonical)
            if let rev = apply(collection: collection, id: id, baseRev: change["base_rev"] as? Int, deleted: deleted, body: body) {
                applied.append(["collection": collection, "id": id, "rev": rev])
            } else {
                let server: Any = items[key(collection, id)].map(itemJSON) ?? NSNull()
                conflicts.append(["collection": collection, "id": id, "server": server])
            }
        }
        return .json(200, ["rev": syncRev, "applied": applied, "conflicts": conflicts])
    }

    /// The stored revision after the write, or nil when `baseRev` no longer matches.
    private func apply(collection: String, id: String, baseRev: Int?, deleted: Bool, body: String?) -> Int? {
        let k = key(collection, id)
        let existing = items[k]?.stored
        if let baseRev, baseRev != (existing?.rev ?? 0) { return nil }
        if deleted && existing == nil { return 0 }
        if let existing, existing.deleted == deleted, existing.body == body { return existing.rev }
        syncRev += 1
        items[k] = (collection, id, Stored(rev: syncRev, updatedMs: 1_800_000_000_000 + syncRev, deleted: deleted,
                                           body: deleted ? nil : body))
        return syncRev
    }

    private func itemJSON(_ entry: (collection: String, id: String, stored: Stored)) -> [String: Any] {
        let body: Any = entry.stored.body.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? NSNull()
        return ["collection": entry.collection, "id": entry.id, "rev": entry.stored.rev,
                "updated_ms": entry.stored.updatedMs, "deleted": entry.stored.deleted, "body": body]
    }

    private func key(_ collection: String, _ id: String) -> String { collection + "\n" + id }

    private func canonical(_ body: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
