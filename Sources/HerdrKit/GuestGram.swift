import Foundation

// A guest's view of the shared agent's Gram (herdrup#338), over the guest relay. The host
// decides what is visible: the granted agent's own Grams to the owner since the grant, plus
// the guest's own posts to it. The owner's read, claim and origin fields never reach a
// guest; `read` is the guest's own mark.

/// A file on a Gram a guest can see. `mime` and `sha256` may be absent on the wire.
public struct GuestGramFile: Decodable, Sendable, Equatable {
    public let name: String
    public let size: UInt64
    public let mime: String
    public let sha256: String?

    public init(name: String, size: UInt64, mime: String = "", sha256: String? = nil) {
        self.name = name
        self.size = size
        self.mime = mime
        self.sha256 = sha256
    }

    enum CodingKeys: String, CodingKey { case name, size, mime, sha256 }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        size = try c.decode(UInt64.self, forKey: .size)
        mime = try c.decodeIfPresent(String.self, forKey: .mime) ?? ""
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
    }

    public var displaySize: String { GramFile.displaySize(of: size) }

    /// The owner's file metadata for the same file (no checksum when the host sent none).
    public var gramFile: GramFile { GramFile(name: name, size: size, mime: mime, sha256: sha256 ?? "") }
}

/// One Gram in the guest's list.
public struct GuestGramMessage: Decodable, Identifiable, Sendable, Equatable {
    public let id: String
    public let direction: GramDirection
    /// The agent for its Grams; the guest's own name on the guest's posts.
    public let from: String
    public let text: String
    public let createdUnixMs: UInt64
    public let file: GuestGramFile?
    /// The file the host store's attachment budget expired (herdr#298): what was there, with
    /// no bytes to fetch. Never openable; nil when `file` is present, and absent from hosts
    /// predating it.
    public let expiredFile: GuestGramFile?
    /// The guest has seen it. `var` for the optimistic flip after `gram.mark_read`.
    public var read: Bool

    public init(id: String, direction: GramDirection, from: String, text: String,
                createdUnixMs: UInt64, file: GuestGramFile? = nil, expiredFile: GuestGramFile? = nil,
                read: Bool) {
        self.id = id
        self.direction = direction
        self.from = from
        self.text = text
        self.createdUnixMs = createdUnixMs
        self.file = file
        self.expiredFile = file == nil ? expiredFile : nil
        self.read = read
    }

    enum CodingKeys: String, CodingKey {
        case id, direction, from, text, file, read
        case expiredFile = "expired_file"
        case createdUnixMs = "created_unix_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        direction = try c.decode(GramDirection.self, forKey: .direction)
        from = try c.decode(String.self, forKey: .from)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        createdUnixMs = try c.decode(UInt64.self, forKey: .createdUnixMs)
        file = try c.decodeIfPresent(GuestGramFile.self, forKey: .file)
        expiredFile = try file == nil ? c.decodeIfPresent(GuestGramFile.self, forKey: .expiredFile) : nil
        read = try c.decodeIfPresent(Bool.self, forKey: .read) ?? false
    }

    /// The agent sent it (as opposed to the guest's own post).
    public var isFromAgent: Bool { direction == .agentToOwner }
    /// Only the agent's Grams can be unread; the guest wrote their own.
    public var isUnread: Bool { isFromAgent && !read }
    public var createdAt: Date { Date(timeIntervalSince1970: Double(createdUnixMs) / 1000.0) }

    /// This Gram as the owner's feed draws it (the app's `GramRow`): the agent's Grams come
    /// from the agent, and the guest's own posts are addressed to `agent`, so they read
    /// "Delivered to <agent>" under the bubble. The guest's read mark stands in for the
    /// owner's; there is no queue claim or federated machine on a guest's projection.
    /// `machineLabel`, when given, is what tells this agent apart from another share's of the
    /// same name ("Jerry · Studio"): the sender line reads "name · <machineLabel>".
    public func gramMessage(agent: String, machineLabel: String? = nil) -> GramMessage {
        GramMessage(
            id: id, direction: direction, from: from, to: isFromAgent ? nil : agent, text: text,
            createdUnixMs: createdUnixMs, readByOwner: read,
            file: file.map(\.gramFile), expiredFile: expiredFile.map(\.gramFile),
            machineLabel: isFromAgent ? machineLabel : nil)
    }
}

/// The host's answer to a guest's `gram.post`: its guest projection of the stored message
/// (`project_gram_sent`), which carries none of the owner's direction, claim or read fields.
/// Only `id` is required; the rest is informational.
public struct GuestGramPostReceipt: Decodable, Sendable, Equatable {
    public let id: String
    public let from: String?
    public let to: String?
    public let text: String?
    public let createdUnixMs: UInt64?
    public let file: GuestGramFile?

    enum CodingKeys: String, CodingKey {
        case id, from, to, text, file
        case createdUnixMs = "created_unix_ms"
    }
}

/// `gram.post` result as a guest sees it: only `message` is decoded.
struct GuestGramPostResult: Decodable {
    let message: GuestGramPostReceipt
}

/// One page of the guest's `gram.list`, newest first.
public struct GuestGramPage: Decodable, Sendable, Equatable {
    public let messages: [GuestGramMessage]
    /// Older messages remain; absent reads as "this is everything".
    public let hasMore: Bool

    public init(messages: [GuestGramMessage], hasMore: Bool = false) {
        self.messages = messages
        self.hasMore = hasMore
    }

    enum CodingKeys: String, CodingKey {
        case messages
        case hasMore = "has_more"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = try c.decodeIfPresent([GuestGramMessage].self, forKey: .messages) ?? []
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }

    /// Unread Grams from the agent on this page.
    public var unreadCount: Int { messages.filter(\.isUnread).count }
}

/// Which of the guest's unread Grams to send in `gram.mark_read`, so marking read can't loop.
/// The list flips a mark optimistically and flips it back when the host refuses; a view that
/// marks on every list change would then re-send at once, forever. An id already in flight is
/// never sent twice, and an id the host refused waits out a backoff that doubles on each
/// failure (5 s up to 5 min) before it is sent again.
public struct GuestGramReadMarks: Sendable {
    public static let initialBackoff: TimeInterval = 5
    public static let maxBackoff: TimeInterval = 300

    private var inFlight: Set<String> = []
    private var retryAt: [String: Date] = [:]
    private var backoff: [String: TimeInterval] = [:]

    public init() {}

    /// The ids of `unread` to send now, which are then in flight until `succeeded` or `failed`.
    public mutating func begin(unread: [String], now: Date) -> [String] {
        let ready = unread.filter { id in
            !inFlight.contains(id) && (retryAt[id].map { $0 <= now } ?? true)
        }
        inFlight.formUnion(ready)
        return ready
    }

    public mutating func succeeded(_ ids: [String]) {
        for id in ids {
            inFlight.remove(id)
            retryAt[id] = nil
            backoff[id] = nil
        }
    }

    public mutating func failed(_ ids: [String], now: Date) {
        for id in ids {
            inFlight.remove(id)
            let wait = backoff[id].map { min($0 * 2, Self.maxBackoff) } ?? Self.initialBackoff
            backoff[id] = wait
            retryAt[id] = now.addingTimeInterval(wait)
        }
    }

    /// A mark is on its way to the host: a list fetched meanwhile still shows it read.
    public func isMarking(_ id: String) -> Bool { inFlight.contains(id) }
}

/// Where a tapped push for a shared agent goes. Guest pushes carry a `herdr_guest` object
/// naming the invite's host and the guest, so the app opens that share's own screens and
/// never an owner screen, whatever other keys the payload also carries.
public struct GuestPushRoute: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A new Gram: the share's Gram tab.
        case gram
        /// A status change (needs you, finished, died), or a kind this build doesn't know:
        /// the share's terminal.
        case status
    }

    public let hostID: String
    public let guestID: String?
    public let kind: Kind
    public let gramID: String?

    public init(hostID: String, guestID: String?, kind: Kind, gramID: String? = nil) {
        self.hostID = hostID
        self.guestID = guestID
        self.kind = kind
        self.gramID = gramID
    }

    /// Nil when the payload is not a guest push (no `herdr_guest.host_id`).
    public init?(userInfo: [AnyHashable: Any]) {
        guard let guest = userInfo["herdr_guest"] as? [String: Any],
              let hostID = guest["host_id"] as? String, !hostID.isEmpty
        else { return nil }
        let guestID = (guest["guest_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let gramID = (guest["gram_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.init(hostID: hostID, guestID: guestID,
                  kind: guest["kind"] as? String == "gram" ? .gram : .status, gramID: gramID)
    }

    /// The share this push is for: the one on its host held as its guest. Nil when the
    /// phone no longer holds it (left, or another install's guest).
    public func access(in shares: [GuestAccess]) -> GuestAccess? {
        shares.first { share in
            share.endpoint.hostID == hostID && (guestID == nil || share.guestID == guestID)
        }
    }
}

/// What a tapped notification opens. A payload that carries `herdr_guest` at all is a guest
/// push, and its classification ends there: a well-formed one opens its share, a malformed
/// one opens nothing. Its other keys (`gram`, `pane_id`) are never read, so no guest push,
/// malformed or mixed, can open an owner screen.
public enum PushTapTarget: Equatable, Sendable {
    /// A guest push naming its host: open that share, if the phone holds it.
    case guest(GuestPushRoute)
    /// A guest push without a usable host: drop the tap.
    case droppedGuest
    /// The owner's Gram page.
    case ownerGram
    /// The owner's pane.
    case ownerPane(String)
    /// Nothing to open.
    case none

    public init(userInfo: [AnyHashable: Any]) {
        if userInfo["herdr_guest"] != nil {
            self = GuestPushRoute(userInfo: userInfo).map(PushTapTarget.guest) ?? .droppedGuest
        } else if userInfo["gram"] as? Bool == true {
            self = .ownerGram
        } else if let paneID = userInfo["pane_id"] as? String, !paneID.isEmpty {
            self = .ownerPane(paneID)
        } else {
            self = .none
        }
    }
}

/// The guest's Gram list and the calls that change it: newest page, older pages, read marks.
///
/// Refreshes start from many places (the host's features arriving, a tab change, a push, a
/// pull) and each runs over its own relay session, so they can finish out of order. Every
/// fetch takes a token from `AgentRosterLoadGate` and applies only while it is still the
/// newest, so an older answer can never hide a Gram a newer one showed. `onChange` fires
/// after every change of state, for a view model to republish.
@MainActor
public final class GuestGramFeed {
    public static let pageSize = 100

    public private(set) var messages: [GuestGramMessage] = []
    public private(set) var hasMore = false
    /// A list answer (or failure) has been applied at least once.
    public private(set) var loaded = false
    /// Why the newest refresh failed; nil after one succeeds. An older page's failure is
    /// thrown by `loadMore` instead.
    public private(set) var lastError: Error?
    /// Why the last older page failed, until a page lands, the reader retries, or a refresh
    /// replaces the end of the list:
    /// state for a view with nothing else on screen to show it (the strict floor hides
    /// every row), as well as thrown by `loadMore`.
    public private(set) var pageError: Error?
    public var onChange: (() -> Void)?

    private var gate = AgentRosterLoadGate()
    private var loadingMore = false
    private var marks = GuestGramReadMarks()

    public init() {}

    public var unreadCount: Int { messages.filter(\.isUnread).count }

    /// Reloads the newest page, keeping older pages already scrolled in. Returns false when a
    /// newer refresh overtook this one, which then applied nothing.
    @discardableResult
    public func refresh(client: HerdrClient) async -> Bool {
        let token = gate.begin()
        let result: Result<GuestGramPage, Error>
        do {
            result = .success(try await client.guestGramList(limit: Self.pageSize))
        } catch is CancellationError {
            return false
        } catch {
            result = .failure(error)
        }
        guard gate.accepts(token) else { return false }
        switch result {
        case .success(let page):
            let head = page.messages.map { message -> GuestGramMessage in
                var message = message
                if marks.isMarking(message.id) { message.read = true }
                return message
            }
            let headIDs = Set(head.map(\.id))
            let oldest = head.last?.createdUnixMs ?? .max
            let older = page.hasMore
                ? messages.filter { !headIDs.contains($0.id) && $0.createdUnixMs < oldest } : []
            let end = messages.last?.id
            messages = head + older
            if older.isEmpty { hasMore = page.hasMore }
            lastError = nil
            // A failed older page stands (with Retry) while the list still ends where it was
            // asked; only a list whose end was replaced makes it moot.
            if messages.last?.id != end { pageError = nil }
        case .failure(let error):
            lastError = error
        }
        loaded = true
        onChange?()
        return true
    }

    /// The next older page. Dropped if a refresh meanwhile replaced the message it was asked
    /// below (`applies`). A failure is
    /// THROWN rather than kept in `lastError`, for the caller to show where the reader asked
    /// for the page (the feed's top sentinel) with a retry, as the owner's inbox does; it is
    /// also kept in `pageError` until a page lands, the reader retries (`clearPageError`), or
    /// a refresh replaces the end of the list.
    public func loadMore(client: HerdrClient) async throws {
        guard hasMore, !loadingMore, let last = messages.last else { return }
        loadingMore = true
        defer { loadingMore = false }
        let cursor = last.id
        let page: GuestGramPage
        do {
            page = try await client.guestGramList(limit: Self.pageSize, beforeID: cursor)
        } catch {
            guard applies(cursor), !(error is CancellationError) else { return }
            pageError = error
            onChange?()
            throw error
        }
        guard applies(cursor) else { return }
        let known = Set(messages.map(\.id))
        messages += page.messages.filter { !known.contains($0.id) }
        hasMore = page.hasMore
        pageError = nil
        onChange?()
    }

    /// An older page's answer still belongs to the list: it ends at the page's cursor. A
    /// refresh that landed meanwhile and kept that end (the newest page unchanged, or older
    /// pages kept below it) leaves the page valid; one that replaced the end drops it.
    private func applies(_ cursor: String) -> Bool { messages.last?.id == cursor }

    /// The reader asked to retry the failed older page: the failure clears so the view's
    /// paging asks again (and keeps it again if that fails too).
    public func clearPageError() {
        guard pageError != nil else { return }
        pageError = nil
        onChange?()
    }

    /// The guest is looking at the list: every unread Gram in it is now read, for this guest
    /// only. Flipped at once; restored if the host refuses, and then not re-sent until its
    /// backoff (`GuestGramReadMarks`) has passed.
    public func markAllRead(client: HerdrClient, now: Date = Date()) async {
        await markRead(messages.filter(\.isUnread).map(\.id), client: client, now: now)
    }

    /// Marks only `shown` read: what the combined inbox (#697) drew of this grant.
    public func markRead(_ shown: [String], client: HerdrClient, now: Date = Date()) async {
        let unread = Set(messages.filter(\.isUnread).map(\.id))
        let ids = marks.begin(unread: shown.filter(unread.contains), now: now)
        guard !ids.isEmpty else { return }
        setRead(ids, true)
        do {
            try await client.guestGramMarkRead(ids: ids)
            marks.succeeded(ids)
        } catch {
            marks.failed(ids, now: Date())
            setRead(ids, false)
        }
    }

    private func setRead(_ ids: [String], _ read: Bool) {
        let set = Set(ids)
        for index in messages.indices where set.contains(messages[index].id) {
            messages[index].read = read
        }
        onChange?()
    }
}
