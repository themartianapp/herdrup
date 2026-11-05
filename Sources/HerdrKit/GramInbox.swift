import Foundation

/// The Gram inbox as held between loads: the last full list, plus the digest that
/// list was answered with.
///
/// It exists because the inbox was previously `@State` INSIDE the Gram page. On iPad
/// the page is built inside the detail column's `switch`, so leaving the section
/// destroys the view and its messages; coming back re-fetched the whole store from
/// zero and showed a spinner while it did. Switching Agents -> Gram -> Agents -> Gram
/// therefore paid for the entire history every time.
///
/// Two properties do the work:
///
/// - **It outlives the page**, so a remount renders the previous list immediately and
///   refreshes behind it. No spinner when there is something to show.
/// - **It holds the digest**, so the refresh behind it is conditional: an unchanged
///   store answers in a few hundred bytes instead of ~900 KB for ~870 messages, over
///   the one SSH channel the terminal also shares.
///
/// Deliberately NOT a cache with an expiry. The digest makes staleness observable at
/// the source, so a timer guessing when to distrust the list would add a second,
/// weaker answer to a question already answered exactly.
public struct GramInbox: Sendable, Equatable {
    /// The last full list the daemon sent, newest first.
    public private(set) var messages: [GramMessage] = []
    /// Digest of `messages` as the daemon fingerprinted them, or nil when we have
    /// never had a full answer (or the daemon does not send digests).
    public private(set) var digest: String?
    /// Which store `messages` came from. A change means these messages describe a
    /// DIFFERENT store and must not be kept.
    public private(set) var storeID: String?
    /// Whether a full list has ever landed. Distinct from `messages.isEmpty`: an inbox
    /// that has genuinely loaded and is empty must not show a spinner forever.
    public private(set) var hasLoaded = false

    public init() {}

    /// The digest to send as `ifUnchangedDigest` on the next poll — only while we
    /// actually hold the list it fingerprints. Sending a digest without the messages
    /// would invite an "unchanged" answer we could not render.
    public var conditionalDigest: String? { hasLoaded ? digest : nil }

    /// Unread agent->owner count. The daemon's count over the WHOLE store wins when it
    /// sends one, because a paged client holds a window and counting the window would
    /// silently under-count the badge. Without it (an older daemon, which then also
    /// sends the whole list) the local count is the same number.
    public var unreadCount: Int { serverUnreadCount ?? messages.filter(\.isUnread).count }

    /// Whether older messages exist beyond what is loaded, i.e. whether scrolling to
    /// the end should ask for another page. False on an unpaged daemon: the one answer
    /// it sends IS everything.
    public private(set) var hasMore = false

    /// The cursor for the next page: the oldest loaded message. Nil when nothing is
    /// loaded or nothing older remains.
    public var nextCursor: String? { hasMore ? messages.last?.id : nil }

    /// Whether unread messages the daemon counts lie beyond the loaded window, so opening
    /// at the first unread message needs another older page first. False once the window
    /// holds as many unread as the daemon counts, or when nothing older remains. Not
    /// bounded by the head refresh's limit: cursor paging reaches the whole store, and a
    /// first unread past that limit is still where the inbox must open.
    public var isMissingUnread: Bool {
        nextCursor != nil && messages.filter(\.isUnread).count < unreadCount
    }

    /// Bumped every time the loaded list is REPLACED (a changed head answer, or a store
    /// swap). A page fetch reads the cursor, suspends, and comes back with messages that
    /// only continue the list the cursor came from: appending them after a replacement
    /// would drop everything between the new oldest row and the old cursor. Carrying the
    /// generation across the await is what lets `appendPage` refuse a stale page instead
    /// of punching a hole in the timeline.
    public private(set) var generation = 0

    private var serverUnreadCount: Int?
    /// Ids marked read that the window does not hold, so a second mark of the same id
    /// cannot decrement the daemon's count twice. A later Read-all pass marks every id an
    /// unread-only fetch still returns, and a daemon that answered that fetch before the
    /// first mark landed returns this one again; that is why this set survives a head
    /// answer and is cleared only by a store swap.
    private var readOutsideWindow: Set<String> = []

    /// Counts local reads: `markRead` stamps each read it applies with the next value. A
    /// head request reads it BEFORE it is sent and hands it back to `apply`, which can
    /// then tell a read the answer could not have seen from one it reflects.
    public private(set) var readStamp = 0
    /// Ids read locally, with their stamp, until a head answer requested after the read
    /// settles them. An answer requested BEFORE the read (a poll in flight while Read all
    /// ran) still reports the row unread: adopting it as is put the count back up for a
    /// whole poll interval after a fully successful pass.
    private var localReads: [String: Int] = [:]

    /// Folds in an answer to a HEAD request — the first page, or an unpaged full list.
    /// Returns whether `messages` changed, so a caller can skip work (re-render, badge
    /// writes) on an unchanged poll.
    ///
    /// A head answer with messages REPLACES the list, and that is deliberate even though
    /// it costs a deep reader their scrolled-in pages. A head page says nothing about
    /// what is older, so splicing the previous tail back on keeps rows the store may no
    /// longer have: a message another client deleted below the head, or one the daemon
    /// pruned, would be re-appended and then frozen in place by the adopted whole-store
    /// digest, which from then on answers every poll "unchanged". A changed answer means
    /// the store moved, so the only honest thing to hold is what the daemon just sent;
    /// older pages come back from the sentinel as the reader scrolls. Unchanged answers
    /// carry no messages and leave everything, including deep pages, exactly as it is —
    /// which is the common case on a 6-second poll.
    ///
    /// `readStamp` is this inbox's `readStamp` as it was when the request was SENT; the
    /// default treats the answer as requested after every local read. A row read locally
    /// after that stays read: it is flipped only once the daemon confirmed its
    /// `gram.mark_read`, so an answer still reporting it unread was computed before the
    /// mark landed. Answers requested after the flip are the daemon's word and win.
    @discardableResult
    public mutating func apply(_ answer: GramListAnswer, readStamp asked: Int = .max) -> Bool {
        // A store swap invalidates everything we hold, INCLUDING on an "unchanged"
        // answer. The daemon mixes its store id into the digest so it cannot happen
        // from that side, but a client that reconnected to a different machine must
        // not keep showing the old store's messages either way.
        if let known = storeID, let incoming = answer.storeID, known != incoming {
            messages = []
            digest = nil
            hasLoaded = false
            hasMore = false
            serverUnreadCount = nil
            readOutsideWindow = []
            localReads = [:]
            generation += 1
        }
        if let incoming = answer.storeID { storeID = incoming }

        guard var fresh = answer.messages else {
            // Unchanged: keep the list AND the digest we already hold. Never treat
            // this as an empty inbox.
            //
            // Deliberately does NOT adopt `answer.digest`. An unchanged reply is only
            // returned when the digest we SENT matched, so there is nothing new to
            // adopt; the previous version's assignment was dead on a correct daemon
            // and survived every mutation of it, which is how it was found. Leaving
            // the digest alone is also the safer behaviour in the one race that can
            // reach here: an in-flight unchanged reply landing after `remove` or
            // `markRead` cleared the digest must not re-arm a digest that describes
            // the pre-mutation list.
            return false
        }
        // A read made after the request went out was counted by that answer as unread:
        // the request reached the daemon before the confirmed mark did, and only unread
        // rows are ever marked. So it stays read and the daemon's count drops by it,
        // whether or not the answer carries the row. Read all marks rows older than the
        // loaded window too, and a head poll never carries those. Only a row the answer
        // itself reports read is already out of its count. Reads the answer could see are
        // settled by it.
        var unreadCount = answer.unreadCount
        var heldRead = false
        for (id, stamp) in localReads where stamp > asked {
            if let index = fresh.firstIndex(where: { $0.id == id }) {
                guard fresh[index].isUnread else { continue }
                fresh[index].readByOwner = true
            }
            if let count = unreadCount { unreadCount = max(0, count - 1) }
            heldRead = true
        }
        localReads = localReads.filter { $0.value > asked }
        let changed = fresh != messages
        messages = fresh
        // A row held read is not the list the daemon fingerprinted: hold no digest, so the
        // next poll is unconditional and brings the daemon's own word on it.
        digest = heldRead ? nil : answer.digest
        hasLoaded = true
        serverUnreadCount = unreadCount
        hasMore = answer.hasMore ?? false
        // ONLY on a real change. An identical answer leaves the oldest loaded row — and
        // therefore the cursor — exactly where it was, so a page fetch already in flight
        // is still contiguous; bumping here anyway dropped that page and left the
        // sentinel spinning with the same cursor and nothing to retry. Identical answers
        // are ordinary: any local mark-read or delete clears the digest, so the next poll
        // is unconditional and ships the same rows back.
        if changed { generation += 1 }
        return changed
    }

    /// Folds in an answer to a page request (`beforeID` set): older messages appended
    /// below what is loaded, de-duped by id so a message that moved between pages
    /// cannot appear twice.
    ///
    /// `generation` is the one the caller read BEFORE it asked for the page. A page
    /// built on a cursor that a head replacement has since invalidated is DROPPED, not
    /// appended: appending it would leave a gap between the new oldest row and the old
    /// cursor that nothing would ever re-fetch.
    ///
    /// Returns whether the loaded list actually GREW — not whether the answer was
    /// non-empty. A caller walking to the end uses this to stop, and an answer of
    /// entirely known ids would otherwise loop forever.
    ///
    /// The digest is NOT adopted: it fingerprints the whole store, and adopting it from
    /// a page would arm a conditional head poll for a list this inbox only partly holds.
    @discardableResult
    public mutating func appendPage(_ answer: GramListAnswer, generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        if let known = storeID, let incoming = answer.storeID, known != incoming {
            // The page belongs to another store; the head refresh will reset us.
            return false
        }
        guard let older = answer.messages, !older.isEmpty else {
            hasMore = answer.hasMore ?? false
            return false
        }
        let known = Set(messages.map(\.id))
        let before = messages.count
        messages.append(contentsOf: older.filter { !known.contains($0.id) })
        hasMore = answer.hasMore ?? false
        if let count = answer.unreadCount { serverUnreadCount = count }
        hasLoaded = true
        return messages.count > before
    }

    /// Drops a message the owner deleted, so the local list agrees with the server
    /// before the next poll confirms it. Clears the digest: our list no longer matches
    /// what the daemon fingerprinted, and a conditional poll against a stale digest
    /// would be answered "unchanged" against a list we have already altered.
    public mutating func remove(id: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        // The daemon's whole-store count has to move with the local edit too, or a
        // paged inbox keeps rendering a badge for a message that is gone.
        if messages[index].isUnread, let count = serverUnreadCount {
            serverUnreadCount = max(0, count - 1)
        }
        messages.remove(at: index)
        digest = nil
    }

    /// Marks a message read locally, once the daemon has confirmed `gram.mark_read` for
    /// it. Same digest reasoning as `remove`, and the same reason for moving the server
    /// count. Each read is stamped (`readStamp`), so a head answer requested before it
    /// cannot flip the row back (`apply`).
    ///
    /// An id this inbox does not HOLD still counts. Read-all takes its ids from an
    /// unread-only fetch, so it legitimately marks messages older than the loaded page;
    /// ignoring those left the daemon-sourced badge frozen after a fully successful
    /// pass, with the Read-all button still sitting there and nothing to explain it.
    ///
    /// IDEMPOTENT on both paths. A loaded row is guarded by `isUnread`; an out-of-window
    /// id is remembered, because the same id can be marked again (see
    /// `readOutsideWindow`) and a second decrement would walk the badge to zero while a
    /// pass was still reporting failures.
    public mutating func markRead(id: String) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            guard messages[index].isUnread else { return }
            messages[index].readByOwner = true
        } else {
            guard readOutsideWindow.insert(id).inserted else { return }
        }
        if let count = serverUnreadCount { serverUnreadCount = max(0, count - 1) }
        digest = nil
        readStamp += 1
        localReads[id] = readStamp
    }
}
