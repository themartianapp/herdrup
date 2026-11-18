import Foundation
import XCTest
@testable import HerdrKit

/// herdrup#697: one guest Gram across grants, merged on the client (`GuestGramMerge`).
final class GuestGramMergeTests: XCTestCase {

    /// One grant's host: its Grams newest first, paged by `before_id` like `gram.list`.
    private struct Host {
        let grant: String
        var store: [GuestGramMessage]
        let pageSize: Int

        /// herdr's order (`guest::gram::list`): a stable sort by time, newest first, so
        /// equal timestamps come in reverse store order, not by id.
        func page(before cursor: String?) -> GuestGramPage {
            let sorted = store.enumerated()
                .sorted { ($0.element.createdUnixMs, $0.offset) > ($1.element.createdUnixMs, $1.offset) }
                .map(\.element)
            let start = cursor.flatMap { id in sorted.firstIndex { $0.id == id }.map { $0 + 1 } } ?? 0
            let slice = Array(sorted[start...].prefix(pageSize))
            return GuestGramPage(messages: slice, hasMore: start + slice.count < sorted.count)
        }
    }

    private static func gram(_ id: String, _ ms: UInt64, from: String = "agent",
                             incoming: Bool = true, read: Bool = false) -> GuestGramMessage {
        GuestGramMessage(id: id, direction: incoming ? .agentToOwner : .ownerToAgent, from: from,
                         text: id, createdUnixMs: ms, read: incoming ? read : true)
    }

    /// The client: a lane per grant, its newest page first, then `Earlier` as the merge asks.
    private struct Client {
        var hosts: [Host]
        var lanes: [GuestGramLane]

        init(hosts: [Host]) {
            self.hosts = hosts
            lanes = hosts.map { host in
                let page = host.page(before: nil)
                return GuestGramLane(grant: host.grant, messages: page.messages, hasMore: page.hasMore)
            }
        }

        var merge: GuestGramMerge { GuestGramMerge(lanes: lanes) }

        /// One "Earlier": the next page of every grant the merge names.
        mutating func earlier() {
            for grant in merge.grantsToPage {
                let index = lanes.firstIndex { $0.grant == grant }!
                let page = hosts[index].page(before: lanes[index].cursor)
                lanes[index].messages += page.messages
                lanes[index].hasMore = page.hasMore
            }
        }

        /// A refresh of one grant's newest page, keeping its older pages (as `GuestGramFeed`).
        mutating func refresh(_ grant: String) {
            let index = lanes.firstIndex { $0.grant == grant }!
            let head = hosts[index].page(before: nil).messages
            let ids = Set(head.map(\.id))
            lanes[index].messages = head + lanes[index].messages.filter { !ids.contains($0.id) }
        }
    }

    /// Every shown message is in order, and no grant still holds back an older message
    /// than one shown (unfetched messages older than the floor only).
    private func assertSafe(_ client: Client, file: StaticString = #filePath, line: UInt = #line) {
        let items = client.merge.items
        let keys = items.map { ($0.message.createdUnixMs, $0.message.id, $0.grant) }
        XCTAssertEqual(keys.map { "\($0.0)/\($0.1)/\($0.2)" },
                       keys.sorted { GuestGramMerge.precedes($0, $1) }.map { "\($0.0)/\($0.1)/\($0.2)" },
                       "oldest first", file: file, line: line)
        guard let oldestShown = items.first?.message.createdUnixMs else { return }
        for (host, lane) in zip(client.hosts, client.lanes) {
            let held = Set(lane.messages.map(\.id))
            let missing = host.store.filter { !held.contains($0.id) && $0.createdUnixMs >= oldestShown }
            XCTAssertEqual(missing.map(\.id), [], "\(host.grant) is missing messages inside the shown range",
                           file: file, line: line)
        }
    }

    /// Three grants, uneven volumes and page sizes: every "Earlier" grows the feed without a
    /// gap, a duplicate or a reorder, until every message of every grant shows.
    func testInterleavesThreeGrantsWithUnevenPaging() {
        let a = Host(grant: "a", store: (0..<23).map { Self.gram("a\($0)", 1_000 + UInt64($0) * 7) }, pageSize: 5)
        let b = Host(grant: "b", store: (0..<4).map { Self.gram("b\($0)", 1_003 + UInt64($0) * 40) }, pageSize: 3)
        let c = Host(grant: "c", store: (0..<11).map { Self.gram("c\($0)", 1_001 + UInt64($0) * 13) }, pageSize: 2)
        var client = Client(hosts: [a, b, c])
        var previous = client.merge.items.map(\.id)
        var rounds = 0
        while client.merge.hasMore {
            assertSafe(client)
            client.earlier()
            let now = client.merge.items.map(\.id)
            XCTAssertEqual(Array(now.suffix(previous.count)), previous, "Earlier only adds above")
            previous = now
            rounds += 1
            XCTAssertLessThan(rounds, 50)
        }
        assertSafe(client)
        let all = (a.store + b.store + c.store).count
        XCTAssertEqual(client.merge.items.count, all)
        XCTAssertEqual(Set(client.merge.items.map(\.id)).count, all, "no duplicates")
        XCTAssertEqual(client.merge.hiddenCount, 0)
    }

    /// The safe floor: with a grant whose next page still holds older messages, nothing older
    /// than its oldest held message shows, though other grants hold them.
    func testSafeFloorHidesWhatAnotherGrantMayStillBeMissing() {
        let a = Host(grant: "a", store: (0..<10).map { Self.gram("a\($0)", 100 + UInt64($0) * 10) }, pageSize: 3)
        let b = Host(grant: "b", store: (0..<3).map { Self.gram("b\($0)", 95 + UInt64($0) * 30) }, pageSize: 5)
        let c = Host(grant: "c", store: (0..<6).map { Self.gram("c\($0)", 101 + UInt64($0) * 15) }, pageSize: 2)
        var client = Client(hosts: [a, b, c])
        // a holds 170...190 (more), b all of 95, 125, 155, c 161 and 176 (more): floor 170,
        // and only what is strictly newer shows (a's 170 itself waits on its millisecond).
        XCTAssertEqual(client.merge.floorUnixMs, 170)
        XCTAssertEqual(client.merge.items.map(\.id), ["c/c5", "a/a8", "a/a9"],
                       "b's 155, c's 161 and a's own 170 are held but not shown")
        XCTAssertEqual(client.merge.grantsToPage, ["a"], "only the grant at the floor pages")
        XCTAssertEqual(client.merge.hiddenCount, 5)
        assertSafe(client)
        client.earlier()
        assertSafe(client)
        // a now holds down to 140; c's oldest held, 161, is the floor.
        XCTAssertEqual(client.merge.floorUnixMs, 161)
        XCTAssertEqual(client.merge.grantsToPage, ["c"])
        XCTAssertEqual(client.merge.items.first?.id, "a/a7")
        XCTAssertFalse(client.merge.items.contains { $0.message.createdUnixMs <= 161 })
    }

    /// Equal timestamps order by id byte-wise, then grant; a shared id on two hosts is two messages.
    func testEqualTimestampsBreakTiesByIDThenGrant() {
        let lanes = [
            GuestGramLane(grant: "h2", messages: [Self.gram("m-b", 500), Self.gram("X", 500)], hasMore: false),
            GuestGramLane(grant: "h1", messages: [Self.gram("m-b", 500), Self.gram("m-a", 500)], hasMore: false),
        ]
        XCTAssertEqual(GuestGramMerge(lanes: lanes).items.map(\.id), ["h2/X", "h1/m-a", "h1/m-b", "h2/m-b"])
        XCTAssertEqual(GuestGramMerge(lanes: lanes.reversed()).items.map(\.id),
                       ["h2/X", "h1/m-a", "h1/m-b", "h2/m-b"], "independent of lane order")
    }

    /// A Gram landing in one grant while the others page joins at the bottom, and paging
    /// carries on without losing or repeating anything.
    func testNewMessageInOneGrantWhileOthersPage() {
        let a = Host(grant: "a", store: (0..<9).map { Self.gram("a\($0)", 10 + UInt64($0) * 10) }, pageSize: 3)
        let b = Host(grant: "b", store: (0..<9).map { Self.gram("b\($0)", 15 + UInt64($0) * 10) }, pageSize: 3)
        var client = Client(hosts: [a, b])
        client.earlier()
        client.hosts[0].store.append(Self.gram("a-new", 10_000))
        client.refresh("a")
        XCTAssertEqual(client.merge.items.last?.id, "a/a-new")
        assertSafe(client)
        while client.merge.hasMore { client.earlier(); assertSafe(client) }
        XCTAssertEqual(client.merge.items.count, 19)
        XCTAssertEqual(Set(client.merge.items.map(\.id)).count, 19)
    }

    /// The All row sums the grants' counts; reading the feed marks only shown unread, per grant.
    func testUnreadSumsAndShownMarks() {
        let lanes = [
            GuestGramLane(grant: "a", messages: [Self.gram("a2", 300), Self.gram("a1", 50, read: false)], hasMore: true),
            GuestGramLane(grant: "b", messages: [Self.gram("b1", 200), Self.gram("b0", 100, read: true),
                                                 Self.gram("mine", 250, incoming: false)], hasMore: false),
            GuestGramLane(grant: "c", messages: [], hasMore: false),
        ]
        let merge = GuestGramMerge(lanes: lanes)
        XCTAssertEqual(merge.unreadCount, 3)
        XCTAssertEqual(merge.unreadCount(grant: "a"), 2)
        XCTAssertEqual(merge.unreadCount(grant: "b"), 1)
        XCTAssertEqual(merge.unreadCount(grant: "c"), 0)
        // a's oldest held is 50, so the floor is 50: a1 waits on its millisecond.
        XCTAssertEqual(merge.shownUnreadByGrant, ["a": ["a2"], "b": ["b1"]])
        let hidden = GuestGramMerge(lanes: [
            GuestGramLane(grant: "a", messages: [Self.gram("a3", 400), Self.gram("a2", 300)], hasMore: true),
            GuestGramLane(grant: "b", messages: [Self.gram("b1", 200)], hasMore: false),
        ])
        XCTAssertEqual(hidden.shownUnreadByGrant, ["a": ["a3"]], "b1 is under the floor, not shown, not marked")
        XCTAssertEqual(hidden.unreadCount, 3)
    }

    /// A reply goes to its message's grant; a new message to the newest incoming one's, else the first.
    func testReplyAndDefaultTargets() {
        let merge = GuestGramMerge(lanes: [
            GuestGramLane(grant: "a", messages: [Self.gram("x", 100)], hasMore: false),
            GuestGramLane(grant: "b", messages: [Self.gram("x", 200), Self.gram("mine", 300, incoming: false)],
                          hasMore: false),
        ])
        XCTAssertEqual(merge.replyTarget(for: "a/x"), "a")
        XCTAssertEqual(merge.replyTarget(for: "b/x"), "b")
        XCTAssertNil(merge.replyTarget(for: "c/x"))
        XCTAssertEqual(merge.defaultTarget, "b", "the newest incoming, not the guest's own post")
        let quiet = GuestGramMerge(lanes: [GuestGramLane(grant: "q", messages: [], hasMore: false),
                                           GuestGramLane(grant: "r", messages: [], hasMore: false)])
        XCTAssertEqual(quiet.defaultTarget, "q")
    }

    // MARK: Review 1 (#702)

    /// The reviewer's probe: a page can end inside a group sharing one millisecond, and the
    /// host orders that group by its store, not by id. Neither the timestamp alone nor the
    /// full (time, id, grant) key bounds what a paging grant may still be missing there, so
    /// nothing at the floor's millisecond shows until it is complete: "Earlier" only ever
    /// adds above.
    func testAPageEndingInsideOneMillisecondNeverInsertsBelowShownRows() {
        let scenarios: [(a: [GuestGramMessage], b: [GuestGramMessage])] = [
            // The probe: a holds z@500 with more to come (y@500); exhausted b holds a@500.
            (a: [Self.gram("y", 500), Self.gram("z", 500)], b: [Self.gram("a", 500)]),
            // Against a full-key floor: a's first page ends at c@500, its next holds q@500,
            // and b's k@500 sorts between them.
            (a: [Self.gram("q", 500), Self.gram("c", 500)], b: [Self.gram("k", 500)]),
            // The same with a newer row on top that may show at once.
            (a: [Self.gram("q", 500), Self.gram("c", 500), Self.gram("top", 900)], b: [Self.gram("k", 500)]),
        ]
        for (index, scenario) in scenarios.enumerated() {
            var client = Client(hosts: [Host(grant: "a", store: scenario.a, pageSize: 1),
                                        Host(grant: "b", store: scenario.b, pageSize: 5)])
            var previous = client.merge.items.map(\.id)
            assertSafe(client)
            while client.merge.hasMore {
                client.earlier()
                assertSafe(client)
                let now = client.merge.items.map(\.id)
                XCTAssertEqual(Array(now.suffix(previous.count)), previous,
                               "scenario \(index): Earlier only adds above (\(previous) -> \(now))")
                previous = now
            }
            XCTAssertEqual(client.merge.items.count, scenario.a.count + scenario.b.count, "scenario \(index)")
        }
    }

    /// A grant whose first page hasn't landed is unknown, not exhausted: the combined feed
    /// shows (and marks) nothing until every grant's first answer sets the range. Production
    /// `GuestGramFeed`s, as the review's probe.
    @MainActor
    func testAGrantStillLoadingWithholdsTheCombinedRange() async {
        let fast = GuestGramFeed()
        let slow = GuestGramFeed()
        await fast.refresh(client: HerdrClient(transport: PageHost(Self.pageLine([("old", 100)], hasMore: false))))
        let early = GuestGramMerge(lanes: [fast.lane(grant: "fast"), slow.lane(grant: "slow")])
        XCTAssertEqual(early.items.map(\.id), [], "nothing shows while slow is unknown")
        XCTAssertEqual(early.shownUnreadByGrant, [:], "and nothing is marked read")
        XCTAssertFalse(early.hasMore, "the loading grant is refreshing, not paging")
        XCTAssertEqual(early.unreadCount, 1, "the counts don't wait")

        await slow.refresh(client: HerdrClient(transport: PageHost(Self.pageLine([("new", 1_000)], hasMore: true))))
        let later = GuestGramMerge(lanes: [fast.lane(grant: "fast"), slow.lane(grant: "slow")])
        XCTAssertFalse(later.items.contains { $0.id == "fast/old" }, "old@100 is below slow's unfetched range")
        XCTAssertEqual(later.grantsToPage, ["slow"])
    }

    /// Same-named agents read apart in the recipient picker: by owner and machine across
    /// hosts, by terminal on one machine; a unique name stays bare.
    func testRecipientLabelsTellSameNamedAgentsApart() {
        func share(_ guest: String, _ name: String, owner: String, machine: String, host: String,
                   target: String) -> GuestAccess {
            GuestAccess(guestID: guest, guestName: "nike", machineLabel: machine, ownerName: owner,
                        agentName: name, agentTarget: target,
                        endpoint: RelayEndpoint(relay: URL(string: "https://relay.example")!, hostID: host,
                                                hostPublicKey: Data(repeating: 1, count: 32)),
                        acceptedAt: Date(timeIntervalSince1970: 0))
        }
        let shares = [
            share("g1", "llm-opt", owner: "Jerry", machine: "Studio", host: "h1", target: "w1"),
            share("g2", "enyo-ui", owner: "Jerry", machine: "Studio", host: "h1", target: "w2-4"),
            share("g3", "enyo-ui", owner: "Jerry", machine: "Studio", host: "h1", target: "w2-9"),
            share("g4", "docs", owner: "Jerry", machine: "Studio", host: "h1", target: "w3"),
            share("g5", "docs", owner: "Ana", machine: "Laptop", host: "h2", target: "w3"),
        ]
        let labels = GuestAccess.recipientLabels(shares)
        XCTAssertEqual(shares.map { labels[$0.id] ?? "" }, [
            "llm-opt", "enyo-ui · Jerry · Studio · w2-4", "enyo-ui · Jerry · Studio · w2-9",
            "docs · Jerry · Studio", "docs · Ana · Laptop",
        ])
        XCTAssertEqual(Set(labels.values).count, shares.count)
    }

    /// Review 2: terminals are host-local, so two machines each holding two enyo-ui at the
    /// same terminals must keep their owner and machine as well as the terminal.
    func testRecipientLabelsStayUniqueAcrossMachinesWithDuplicates() {
        func share(_ guest: String, owner: String, machine: String, host: String, target: String) -> GuestAccess {
            GuestAccess(guestID: guest, guestName: "nike", machineLabel: machine, ownerName: owner,
                        agentName: "enyo-ui", agentTarget: target,
                        endpoint: RelayEndpoint(relay: URL(string: "https://relay.example")!, hostID: host,
                                                hostPublicKey: Data(repeating: 1, count: 32)),
                        acceptedAt: Date(timeIntervalSince1970: 0))
        }
        let shares = [
            share("g1", owner: "Jerry", machine: "Studio", host: "h1", target: "w1-3"),
            share("g2", owner: "Jerry", machine: "Studio", host: "h1", target: "w2-4"),
            share("g3", owner: "Ana", machine: "Laptop", host: "h2", target: "w1-3"),
            share("g4", owner: "Ana", machine: "Laptop", host: "h2", target: "w2-4"),
            // Same owner and machine label on another host, same terminal: the host tells it apart.
            share("g5", owner: "Ana", machine: "Laptop", host: "h3-abcdef", target: "w1-3"),
        ]
        let labels = GuestAccess.recipientLabels(shares)
        XCTAssertEqual(shares.map { labels[$0.id] ?? "" }, [
            "enyo-ui · Jerry · Studio · w1-3", "enyo-ui · Jerry · Studio · w2-4",
            "enyo-ui · Ana · Laptop · w1-3 · h2", "enyo-ui · Ana · Laptop · w2-4",
            "enyo-ui · Ana · Laptop · w1-3 · h3-abc",
        ])
        XCTAssertEqual(Set(labels.values).count, shares.count, "every recipient reads apart")
    }

    private static func pageLine(_ messages: [(String, UInt64)], hasMore: Bool) -> String {
        let items = messages.map { id, ms in
            #"{"id":"\#(id)","direction":"agent_to_owner","from":"agent","text":"\#(id)","created_unix_ms":\#(ms),"read":false}"#
        }
        return #"{"id":"$ID","result":{"type":"guest_gram_list","has_more":\#(hasMore),"messages":[\#(items.joined(separator: ","))]}}"#
    }

    /// A host that answers every call with one `gram.list` page.
    private struct PageHost: HerdrTransport {
        let line: String
        init(_ line: String) { self.line = line }
        func roundTrip(_ requestLine: String) async throws -> String {
            let object = try JSONSerialization.jsonObject(with: Data(requestLine.utf8)) as? [String: Any]
            return line.replacingOccurrences(of: "$ID", with: object?["id"] as? String ?? "x")
        }
        func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }
}
