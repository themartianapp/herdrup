import Foundation

// One Gram inbox across every agent shared with a guest (herdrup#697, design 3B). Each
// grant's `gram.list` pages on its own (`GuestGramFeed`); this merges what the grants hold
// into one feed on the client, with no host change. The rules are shared with the desktop and
// web guests so all three show the same feed:
//
// 1. Order: `created_unix_ms` ascending, ties by message id (byte-wise), then by grant.
// 2. Identity: (grant, id); ids are not unique across hosts.
// 3. Paging: a cursor per grant. Only messages at or after the SAFE FLOOR show: the newest of
//    the oldest-held timestamps among grants that still have older pages. Older ones stay
//    held but hidden, since another grant may still be missing messages there. "Earlier"
//    pages the grants whose oldest held message is at the floor or newer. A grant with no
//    more pages stops counting toward the floor; when all are exhausted, everything shows.
// 4. Unread: the sum of the per-grant counts; reading the feed marks, per grant, only that
//    grant's shown messages.
// 5. A reply goes to its message's grant; a new message defaults to the grant of the newest
//    incoming message, else the first grant.

/// One grant's held Gram: what its feed has fetched, newest first, and whether older pages remain.
public struct GuestGramLane: Sendable, Equatable {
    public let grant: String
    public var messages: [GuestGramMessage]
    public var hasMore: Bool

    public init(grant: String, messages: [GuestGramMessage], hasMore: Bool) {
        self.grant = grant
        self.messages = messages
        self.hasMore = hasMore
    }

    /// The oldest held timestamp; nil when nothing is held.
    public var oldestUnixMs: UInt64? { messages.map(\.createdUnixMs).min() }
    /// The per-grant cursor: the oldest held message, `gram.list`'s `before_id`.
    public var cursor: String? {
        messages.min { GuestGramMerge.precedes(($0.createdUnixMs, $0.id, grant), ($1.createdUnixMs, $1.id, grant)) }?.id
    }
    public var unreadCount: Int { messages.filter(\.isUnread).count }
    /// The newest held message, for the inbox row's preview and time.
    public var newest: GuestGramMessage? {
        messages.max { GuestGramMerge.precedes(($0.createdUnixMs, $0.id, grant), ($1.createdUnixMs, $1.id, grant)) }
    }
}

/// One message in the merged feed, keyed by its grant and id.
public struct GuestGramMergedItem: Identifiable, Sendable, Equatable {
    public struct Key: Hashable, Sendable {
        public let grant: String
        public let messageID: String
    }

    public let grant: String
    public let message: GuestGramMessage

    public var key: Key { Key(grant: grant, messageID: message.id) }
    /// Unique across grants, for SwiftUI and accessibility.
    public var id: String { "\(grant)/\(message.id)" }
}

/// The merged feed of the guest's grants: a pure value over the lanes.
public struct GuestGramMerge: Sendable, Equatable {
    /// Shown messages, oldest first (newest last).
    public let items: [GuestGramMergedItem]
    /// The safe floor; nil when no grant has older pages (everything shows).
    public let floorUnixMs: UInt64?
    /// The grants "Earlier" should page next; empty when the feed is complete.
    public let grantsToPage: [String]
    /// Held messages hidden below the floor.
    public let hiddenCount: Int
    /// The grants in the caller's order, for the default target.
    public let grants: [String]
    private let unreadByGrant: [String: Int]

    public init(lanes: [GuestGramLane]) {
        grants = lanes.map(\.grant)
        // A paging grant holding nothing yet hides everything until its first page lands.
        let paging = lanes.filter(\.hasMore)
        let floor: UInt64? = paging.isEmpty ? nil : paging.map { $0.oldestUnixMs ?? .max }.max()
        var all: [GuestGramMergedItem] = []
        var seen = Set<GuestGramMergedItem.Key>()
        for lane in lanes {
            for message in lane.messages {
                let item = GuestGramMergedItem(grant: lane.grant, message: message)
                if seen.insert(item.key).inserted { all.append(item) }
            }
        }
        all.sort { Self.precedes(($0.message.createdUnixMs, $0.message.id, $0.grant),
                                 ($1.message.createdUnixMs, $1.message.id, $1.grant)) }
        let shown = floor.map { floor in all.filter { $0.message.createdUnixMs >= floor } } ?? all
        items = shown
        floorUnixMs = floor
        hiddenCount = all.count - shown.count
        grantsToPage = floor.map { floor in
            paging.filter { ($0.oldestUnixMs ?? .max) >= floor }.map(\.grant)
        } ?? []
        unreadByGrant = Dictionary(lanes.map { ($0.grant, $0.unreadCount) }, uniquingKeysWith: +)
    }

    /// Older messages remain to show ("Earlier").
    public var hasMore: Bool { !grantsToPage.isEmpty }

    /// Byte-wise order on (time, id, grant).
    static func precedes(_ a: (UInt64, String, String), _ b: (UInt64, String, String)) -> Bool {
        if a.0 != b.0 { return a.0 < b.0 }
        let ida = Array(a.1.utf8), idb = Array(b.1.utf8)
        if ida != idb { return ida.lexicographicallyPrecedes(idb) }
        return Array(a.2.utf8).lexicographicallyPrecedes(Array(b.2.utf8))
    }

    /// The "All agents" count: the sum of every grant's unread count.
    public var unreadCount: Int { unreadByGrant.values.reduce(0, +) }
    public func unreadCount(grant: String) -> Int { unreadByGrant[grant] ?? 0 }

    /// What reading the merged feed marks: per grant, the unread ids actually shown.
    public var shownUnreadByGrant: [String: [String]] {
        var result: [String: [String]] = [:]
        for item in items where item.message.isUnread { result[item.grant, default: []].append(item.message.id) }
        return result
    }

    /// A reply goes to the grant of the message it answers.
    public func replyTarget(for itemID: GuestGramMergedItem.ID) -> String? {
        items.first { $0.id == itemID }?.grant
    }

    /// A new message's default target: the grant of the newest incoming message, else the
    /// first grant.
    public var defaultTarget: String? {
        items.last(where: \.message.isFromAgent)?.grant ?? grants.first
    }
}

extension GuestGramFeed {
    /// What this grant's feed holds, for `GuestGramMerge`.
    public func lane(grant: String) -> GuestGramLane {
        GuestGramLane(grant: grant, messages: messages, hasMore: hasMore)
    }
}
