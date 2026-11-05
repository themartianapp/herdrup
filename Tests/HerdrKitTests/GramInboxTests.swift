import XCTest
@testable import HerdrKit

/// `GramInbox` is what makes a section switch cheap: it survives the Gram page and
/// carries the digest that makes the next poll conditional. These pin the properties
/// the page relies on — each one, if broken, produces a specific visible bug.
final class GramInboxTests: XCTestCase {
    private func message(
        _ id: String, from: String = "trend-scout", unread: Bool = true, text: String = "hi"
    ) throws -> GramMessage {
        let json = """
        {"id":"\(id)","direction":"agent_to_owner","from":"\(from)","text":"\(text)",
         "created_unix_ms":1750000000000,"read_by_owner":\(unread ? "false" : "true")}
        """
        return try JSONDecoder().decode(GramMessage.self, from: Data(json.utf8))
    }

    private func answer(
        _ messages: [GramMessage]?, digest: String?, store: String? = "store-1"
    ) -> GramListAnswer {
        GramListAnswer(messages: messages, digest: digest, storeID: store)
    }

    /// The bug this whole type exists for: an "unchanged" answer carries NO messages,
    /// and must never be read as an empty inbox. Treating nil as [] would blank the
    /// list on every successful conditional poll — i.e. every 6 seconds.
    func testUnchangedAnswerKeepsTheMessages() throws {
        var inbox = GramInbox()
        inbox.apply(answer([try message("g1")], digest: "d1"))
        XCTAssertEqual(inbox.messages.count, 1)

        let changed = inbox.apply(answer(nil, digest: "d1"))
        XCTAssertFalse(changed, "an unchanged answer is not a change")
        XCTAssertEqual(inbox.messages.count, 1, "unchanged must not empty the inbox")
        XCTAssertTrue(inbox.hasLoaded)
        XCTAssertEqual(inbox.conditionalDigest, "d1")
    }

    /// An unchanged reply must leave the digest EXACTLY as it was, not re-assign it.
    /// A previous version adopted `answer.digest` here; the assignment was dead on a
    /// correct daemon (an unchanged reply only comes back when the digest we sent
    /// matched) and survived mutation, so this pins the branch that replaced it.
    /// The dangerous case is the one asserted second: an in-flight unchanged reply
    /// landing AFTER a local mutation cleared the digest must not re-arm one that
    /// describes the pre-mutation list, or the next poll is answered "unchanged"
    /// against a list we have already altered and the page never reconciles.
    func testUnchangedAnswerNeverReArmsTheDigest() throws {
        var inbox = GramInbox()
        inbox.apply(answer([try message("g1"), try message("g2")], digest: "d1"))

        inbox.apply(answer(nil, digest: "d-other"))
        XCTAssertEqual(inbox.conditionalDigest, "d1", "an unchanged reply must not change the digest")

        inbox.remove(id: "g1")
        XCTAssertNil(inbox.conditionalDigest)
        inbox.apply(answer(nil, digest: "d1"))
        XCTAssertNil(inbox.conditionalDigest,
                     "a late unchanged reply must not re-arm a digest for the pre-mutation list")
    }

    /// A warm inbox is what suppresses the spinner on a remount. `hasLoaded` has to be
    /// distinct from `messages.isEmpty`, or a genuinely empty inbox would spin forever.
    func testGenuinelyEmptyInboxCountsAsLoaded() {
        var inbox = GramInbox()
        XCTAssertFalse(inbox.hasLoaded, "nothing has arrived yet — a spinner is correct here")
        XCTAssertNil(inbox.conditionalDigest, "no list held, so no digest may be sent")

        inbox.apply(answer([], digest: "d-empty"))
        XCTAssertTrue(inbox.hasLoaded, "an empty list IS a loaded list")
        XCTAssertTrue(inbox.messages.isEmpty)
    }

    /// Sending a digest we cannot back up with a list would invite an "unchanged"
    /// answer we have nothing to render. Only a held list licenses a conditional poll.
    func testDigestIsOnlyOfferedWhileTheListIsHeld() throws {
        var inbox = GramInbox()
        inbox.apply(answer(nil, digest: "d9"))
        XCTAssertNil(inbox.conditionalDigest,
                     "an unchanged answer arriving first leaves nothing to validate")

        inbox.apply(answer([try message("g1")], digest: "d1"))
        XCTAssertEqual(inbox.conditionalDigest, "d1")
    }

    /// A local edit makes our list differ from the one the daemon fingerprinted. If the
    /// digest survived, the next poll would be answered "unchanged" and the local
    /// deletion would never be reconciled with the server's view.
    func testLocalMutationClearsTheDigest() throws {
        var inbox = GramInbox()
        inbox.apply(answer([try message("g1"), try message("g2")], digest: "d1"))

        inbox.remove(id: "g1")
        XCTAssertEqual(inbox.messages.map(\.id), ["g2"])
        XCTAssertNil(inbox.conditionalDigest, "a locally altered list must be re-fetched in full")

        inbox.apply(answer([try message("g2")], digest: "d2"))
        inbox.markRead(id: "g2")
        XCTAssertNil(inbox.conditionalDigest, "a local mark-read also diverges from the digest")
    }

    /// Removing an id we do not hold must not clear the digest: that would turn every
    /// stray delete into a full re-download.
    func testRemovingAnUnknownIDLeavesTheDigestIntact() throws {
        var inbox = GramInbox()
        inbox.apply(answer([try message("g1")], digest: "d1"))
        inbox.remove(id: "nope")
        XCTAssertEqual(inbox.conditionalDigest, "d1")
    }

    /// The unread badge reads the FULL list, which is why the design keeps the whole
    /// list rather than a window — and why mark-read has to move the count.
    func testUnreadCountTracksTheWholeList() throws {
        var inbox = GramInbox()
        inbox.apply(answer([
            try message("g1", unread: true),
            try message("g2", unread: true),
            try message("g3", unread: false),
        ], digest: "d1"))
        XCTAssertEqual(inbox.unreadCount, 2)

        inbox.markRead(id: "g1")
        XCTAssertEqual(inbox.unreadCount, 1)
        XCTAssertEqual(inbox.messages.first?.readByOwner, true)
    }

    /// Messages describe one store. Reconnected to a different machine, keeping the old
    /// list would show another store's inbox — including on an "unchanged" answer,
    /// which is the case a digest check alone would not catch.
    func testStoreChangeDropsTheHeldList() throws {
        var inbox = GramInbox()
        inbox.apply(answer([try message("g1")], digest: "d1", store: "store-1"))

        let changed = inbox.apply(answer(nil, digest: "d1", store: "store-2"))
        XCTAssertFalse(changed)
        XCTAssertTrue(inbox.messages.isEmpty, "another store's messages must not be shown")
        XCTAssertFalse(inbox.hasLoaded, "and the page must load rather than render them")
        XCTAssertNil(inbox.conditionalDigest)
    }

    /// A daemon predating the digest sends none, so every poll stays unconditional and
    /// full — the pre-existing behaviour, which must keep working unchanged.
    func testDaemonWithoutDigestsStillLoads() throws {
        var inbox = GramInbox()
        let changed = inbox.apply(answer([try message("g1")], digest: nil, store: nil))
        XCTAssertTrue(changed)
        XCTAssertTrue(inbox.hasLoaded)
        XCTAssertNil(inbox.conditionalDigest, "no digest offered means no conditional request")
    }

    /// `apply` reports whether anything moved so the page can skip re-reconciling on a
    /// poll that changed nothing. A same-content answer is not a change even when the
    /// daemon re-sent the list.
    func testChangeReportingDistinguishesContentFromTransfer() throws {
        var inbox = GramInbox()
        XCTAssertTrue(inbox.apply(answer([try message("g1")], digest: "d1")))
        XCTAssertFalse(inbox.apply(answer([try message("g1")], digest: "d1")),
                       "re-sending identical messages is not a content change")
        XCTAssertTrue(inbox.apply(answer([try message("g1"), try message("g2")], digest: "d2")))
    }

    private func page(
        _ messages: [GramMessage], hasMore: Bool, unread: Int? = nil, digest: String? = "d"
    ) -> GramListAnswer {
        GramListAnswer(messages: messages, digest: digest, storeID: "store-1",
                       hasMore: hasMore, unreadCount: unread)
    }

    /// Scrolling loads older pages BELOW what is held, de-duped, and the cursor walks
    /// to the oldest loaded message. Without the de-dupe a message that shifted between
    /// pages renders twice.
    func testAppendingAPageExtendsTheListAndMovesTheCursor() throws {
        var inbox = GramInbox()
        inbox.apply(page([try message("c"), try message("b")], hasMore: true))
        XCTAssertEqual(inbox.nextCursor, "b")

        inbox.appendPage(page([try message("b"), try message("a")], hasMore: false), generation: inbox.generation)
        XCTAssertEqual(inbox.messages.map(\.id), ["c", "b", "a"],
                       "the page must append older messages once, keeping newest-first order")
        XCTAssertFalse(inbox.hasMore)
        XCTAssertNil(inbox.nextCursor, "nothing older left to ask for")
    }

    /// A CHANGED head answer replaces the list, deep pages included. Splicing the old
    /// tail back on was tried and reverted: a head page says nothing about what is
    /// older, so a message deleted (or pruned) below the head survived the splice and
    /// was then frozen by the adopted whole-store digest, which answers every later
    /// poll "unchanged". Losing scroll depth on a real change is the cheaper wrong.
    func testChangedHeadAnswerDropsOlderPagesSoDeletionsCannotSurvive() throws {
        var inbox = GramInbox()
        inbox.apply(page([try message("c"), try message("b")], hasMore: true))
        inbox.appendPage(page([try message("a")], hasMore: false), generation: inbox.generation)
        XCTAssertEqual(inbox.messages.map(\.id), ["c", "b", "a"])

        inbox.apply(page([try message("d"), try message("c"), try message("b")], hasMore: true))
        XCTAssertEqual(inbox.messages.map(\.id), ["d", "c", "b"],
                       "the head is authoritative; older pages come back from the sentinel")
        XCTAssertTrue(inbox.hasMore, "and the cursor points past the head again")
    }

    /// An UNCHANGED answer must leave a deep reader exactly where they are — it is the
    /// common case on a six-second poll, and it carries no messages to reconcile.
    func testUnchangedAnswerKeepsDeepPagesLoaded() throws {
        var inbox = GramInbox()
        inbox.apply(page([try message("c")], hasMore: true))
        inbox.appendPage(page([try message("b"), try message("a")], hasMore: false), generation: inbox.generation)

        XCTAssertFalse(inbox.apply(answer(nil, digest: "d")))
        XCTAssertEqual(inbox.messages.map(\.id), ["c", "b", "a"])
    }

    /// Read-all marks messages OLDER than the loaded page — it takes its ids from an
    /// unread-only fetch. The badge is daemon-sourced now, so a mark for an id this
    /// inbox does not hold still has to move the count, or a fully successful pass
    /// leaves the badge and the Read-all button exactly where they were.
    func testMarkingReadAnIDOutsideTheWindowStillMovesTheCount() throws {
        var inbox = GramInbox()
        inbox.apply(page([try message("c")], hasMore: true, unread: 3))
        XCTAssertEqual(inbox.unreadCount, 3)

        inbox.markRead(id: "older-1")
        XCTAssertEqual(inbox.unreadCount, 2, "a server-confirmed read counts wherever it lives")
        XCTAssertNil(inbox.conditionalDigest,
                     "and the list no longer matches what the daemon fingerprinted")

        inbox.markRead(id: "c")
        XCTAssertEqual(inbox.unreadCount, 1)
        inbox.markRead(id: "c")
        XCTAssertEqual(inbox.unreadCount, 1, "a second mark of the same loaded id is a no-op")
    }

    /// A page fetched against the OLD cursor must be dropped after a head refresh
    /// replaced the list, not appended. Appending it leaves a hole between the new
    /// oldest row and the old cursor that nothing re-fetches: the reader scrolls past
    /// messages that were silently skipped.
    func testAPageBuiltBeforeAHeadRefreshIsDropped() throws {
        var inbox = GramInbox()
        inbox.apply(page([try message("c"), try message("b")], hasMore: true))
        let generation = inbox.generation

        // A message arrives; the head answer replaces the list.
        inbox.apply(page([try message("d"), try message("c")], hasMore: true))
        // The page that was already in flight comes back, built on the old cursor "b".
        XCTAssertFalse(inbox.appendPage(page([try message("a")], hasMore: false),
                                        generation: generation),
                       "a stale page must not land")
        XCTAssertEqual(inbox.messages.map(\.id), ["d", "c"])
        XCTAssertEqual(inbox.nextCursor, "c", "and the cursor still points at the real end")
    }

    /// `appendPage` reports GROWTH, not "the answer was non-empty". A walk to the end
    /// stops on that answer, and a page of ids already held would otherwise loop
    /// forever while looking like progress.
    func testAPageOfAlreadyKnownMessagesReportsNoGrowth() throws {
        var inbox = GramInbox()
        inbox.apply(page([try message("c"), try message("b")], hasMore: true))
        XCTAssertFalse(inbox.appendPage(page([try message("c"), try message("b")], hasMore: true),
                                        generation: inbox.generation),
                       "nothing new arrived, so nothing grew")
        XCTAssertEqual(inbox.messages.map(\.id), ["c", "b"])
    }

    /// Read-all marks each id TWICE on purpose (a poll landing mid-pass reverts the
    /// local flips), so the out-of-window decrement has to be idempotent or a partial
    /// pass walks the badge to zero while still reporting failures.
    func testMarkingReadTwiceOutsideTheWindowDecrementsOnce() throws {
        var inbox = GramInbox()
        inbox.apply(page([try message("c", unread: false)], hasMore: true, unread: 2))
        inbox.markRead(id: "older-1")
        inbox.markRead(id: "older-1")
        XCTAssertEqual(inbox.unreadCount, 1)
    }

    /// An IDENTICAL head answer must not invalidate a page already in flight. Any local
    /// mark-read or delete clears the digest, so the next poll is unconditional and
    /// ships the same rows straight back; bumping the generation there dropped a
    /// perfectly contiguous page and left the sentinel spinning on an unchanged cursor.
    func testAnIdenticalHeadAnswerKeepsAnInFlightPageValid() throws {
        var inbox = GramInbox()
        inbox.apply(page([try message("c"), try message("b")], hasMore: true))
        let generation = inbox.generation

        // The unconditional poll returns exactly what is held.
        XCTAssertFalse(inbox.apply(page([try message("c"), try message("b")], hasMore: true)))
        XCTAssertTrue(inbox.appendPage(page([try message("a")], hasMore: false),
                                       generation: generation),
                      "the page was still contiguous, so it must land")
        XCTAssertEqual(inbox.messages.map(\.id), ["c", "b", "a"])
    }

    /// Read-all marks each id twice with a poll landing in between — that poll is the
    /// reason the second pass exists. The out-of-window ledger therefore has to survive
    /// a head answer, or the re-apply decrements the badge a second time.
    func testAnOutOfWindowReadSurvivesAHeadRefresh() throws {
        var inbox = GramInbox()
        inbox.apply(page([try message("c")], hasMore: true, unread: 3))
        inbox.markRead(id: "older-1")
        XCTAssertEqual(inbox.unreadCount, 2)

        // A poll lands mid-pass: the daemon's count already excludes the id it marked.
        inbox.apply(page([try message("d"), try message("c")], hasMore: true, unread: 2))
        inbox.markRead(id: "older-1")
        XCTAssertEqual(inbox.unreadCount, 2, "the re-apply must not decrement again")
    }

    /// The badge counts the whole store. A paged client holds a window, so the daemon's
    /// count has to win — counting the window would under-count every unread message
    /// older than the first page.
    func testUnreadCountPrefersTheServerCountOverTheWindow() throws {
        var inbox = GramInbox()
        inbox.apply(page([try message("c", unread: false)], hasMore: true, unread: 7))
        XCTAssertEqual(inbox.unreadCount, 7)

        // An unpaged daemon sends no count, and then the window IS the whole list.
        var unpaged = GramInbox()
        unpaged.apply(answer([try message("c"), try message("b", unread: false)], digest: "d"))
        XCTAssertEqual(unpaged.unreadCount, 1)
        XCTAssertFalse(unpaged.hasMore, "no paging fields means this answer is everything")
    }

    /// A page must not arm the conditional poll: the digest fingerprints the whole
    /// store, and adopting it from a page would have the daemon answer "unchanged" for
    /// a list this inbox only partly holds.
    func testAppendingAPageNeverAdoptsItsDigest() throws {
        var inbox = GramInbox()
        inbox.apply(page([try message("c")], hasMore: true, digest: "head"))
        inbox.appendPage(page([try message("b")], hasMore: false, digest: "page"), generation: inbox.generation)
        XCTAssertEqual(inbox.conditionalDigest, "head")
    }

    /// The inbox opens at the first unread message, which may sit past the first page: the
    /// daemon counts unread over the whole store. Until the window holds them all it must
    /// fetch older pages, or the feed opens at the newest (one unread past the page) or at
    /// the page's oldest unread instead of the first unread overall.
    func testUnreadBeyondTheWindowNeedsAnotherPage() throws {
        var inbox = GramInbox()
        inbox.apply(page([try message("c", unread: false), try message("b", unread: true)],
                         hasMore: true, unread: 2))
        XCTAssertTrue(inbox.isMissingUnread, "one of the two unread is older than the window")
        inbox.appendPage(page([try message("a", unread: true)], hasMore: true, unread: 2),
                         generation: inbox.generation)
        XCTAssertFalse(inbox.isMissingUnread, "both unread are loaded; older read pages are not needed")
    }

    func testUnreadPagingStopsOnlyAtTheEndOfTheStore() throws {
        var ended = GramInbox()
        ended.apply(page([try message("b", unread: false)], hasMore: false, unread: 1))
        XCTAssertFalse(ended.isMissingUnread, "nothing older to fetch")

        // Past the head refresh's 500 rows the first unread is still where the inbox opens.
        var deep = GramInbox()
        deep.apply(page(try (1...500).reversed().map { try message("m\($0 + 100)", unread: false) },
                        hasMore: true, unread: 1))
        XCTAssertEqual(deep.messages.count, 500)
        XCTAssertTrue(deep.isMissingUnread, "the one unread is older than 500 loaded rows")
    }

    // MARK: - Reads a poll answer could not have seen

    private func counted(_ messages: [GramMessage], unread: Int) -> GramListAnswer {
        GramListAnswer(messages: messages, digest: "d", storeID: "store-1", unreadCount: unread)
    }

    /// A poll sent BEFORE a confirmed read answers with the row still unread. Read all
    /// finished, then that answer landed and put the count back up for a poll interval.
    func testAnswerRequestedBeforeAReadKeepsItRead() throws {
        var inbox = GramInbox()
        inbox.apply(counted([try message("a"), try message("b")], unread: 2))
        let asked = inbox.readStamp
        inbox.markRead(id: "a")
        inbox.markRead(id: "b")
        XCTAssertEqual(inbox.unreadCount, 0)

        inbox.apply(counted([try message("a"), try message("b")], unread: 2), readStamp: asked)
        XCTAssertEqual(inbox.unreadCount, 0, "a stale answer must not undo a confirmed read")
        XCTAssertFalse(inbox.messages.contains(where: \.isUnread))
        XCTAssertNil(inbox.conditionalDigest,
                     "the held rows are not the list the daemon fingerprinted: the next poll is unconditional")
    }

    /// An answer requested AFTER the read is the daemon's word, even when it says unread
    /// (another client, or a daemon that lost the mark): it wins, and the read is settled.
    func testAnswerRequestedAfterAReadWins() throws {
        var inbox = GramInbox()
        inbox.apply(counted([try message("a")], unread: 1))
        inbox.markRead(id: "a")
        let asked = inbox.readStamp
        inbox.apply(counted([try message("a")], unread: 1), readStamp: asked)
        XCTAssertEqual(inbox.unreadCount, 1)
        XCTAssertTrue(inbox.messages[0].isUnread)
        XCTAssertEqual(inbox.conditionalDigest, "d")

        // Settled: a later answer, however old its request, no longer carries the read.
        inbox.apply(counted([try message("a")], unread: 1), readStamp: 0)
        XCTAssertEqual(inbox.unreadCount, 1)
    }

    /// A stale answer that already reports the row read is taken as is: the daemon's
    /// count reflects it, so it is not decremented a second time.
    func testStaleAnswerThatAlreadySawTheReadIsNotCountedTwice() throws {
        var inbox = GramInbox()
        inbox.apply(counted([try message("a"), try message("b")], unread: 2))
        let asked = inbox.readStamp
        inbox.markRead(id: "a")
        inbox.apply(counted([try message("a", unread: false), try message("b")], unread: 1), readStamp: asked)
        XCTAssertEqual(inbox.unreadCount, 1)
        XCTAssertEqual(inbox.conditionalDigest, "d")
    }

    /// Read all also marks unread rows older than the loaded window, and a head poll never
    /// carries those. A poll requested before the marks still counted them unread, so
    /// its count must drop by them too, or the badge comes back for every one (#447).
    func testStaleAnswerStillCountsReadsOutsideTheWindow() throws {
        var inbox = GramInbox()
        inbox.apply(counted([try message("a")], unread: 2))
        let asked = inbox.readStamp
        inbox.markRead(id: "a")
        inbox.markRead(id: "old")
        XCTAssertEqual(inbox.unreadCount, 0)

        inbox.apply(counted([try message("a")], unread: 2), readStamp: asked)
        XCTAssertEqual(inbox.unreadCount, 0, "a stale answer must not bring back an out-of-window read")
        XCTAssertFalse(inbox.messages[0].isUnread)
        XCTAssertNil(inbox.conditionalDigest, "the next poll is unconditional and brings the daemon's own count")

        // The next answer, requested after the reads, is the daemon's word.
        inbox.apply(counted([try message("a", unread: false)], unread: 0), readStamp: inbox.readStamp)
        XCTAssertEqual(inbox.unreadCount, 0)
        XCTAssertEqual(inbox.conditionalDigest, "d")
    }

    /// The same when no loaded row was marked at all: the out-of-window read alone holds.
    func testStaleAnswerCountsAnOutOfWindowReadWithNoLoadedRowMarked() throws {
        var inbox = GramInbox()
        inbox.apply(counted([try message("a")], unread: 2))
        let asked = inbox.readStamp
        inbox.markRead(id: "old")
        XCTAssertEqual(inbox.unreadCount, 1)
        inbox.apply(counted([try message("a")], unread: 2), readStamp: asked)
        XCTAssertEqual(inbox.unreadCount, 1)
        XCTAssertTrue(inbox.messages[0].isUnread)
        XCTAssertNil(inbox.conditionalDigest)
    }
}
