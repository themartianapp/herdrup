import Foundation
import XCTest
@testable import HerdrKit

/// Review P2 (herdrup#339): guest Gram refreshes run over separate relay sessions and can
/// finish out of order; only the newest may shape the list.
@MainActor
final class GuestGramFeedTests: XCTestCase {

    /// A host that answers each call with the next scripted reply, but holds the replies of
    /// the calls listed in `held` until the test releases them.
    private final class OutOfOrderHost: HerdrTransport, @unchecked Sendable {
        private let lock = NSLock()
        private let replies: [String]
        private let held: Set<Int>
        private var calls = 0
        private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
        private var released: Set<Int> = []

        init(replies: [String], held: Set<Int>) {
            self.replies = replies
            self.held = held
        }

        var started: Int { lock.withLock { calls } }

        func release(_ call: Int) {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                released.insert(call)
                return waiting.removeValue(forKey: call)
            }
            continuation?.resume()
        }

        func roundTrip(_ requestLine: String) async throws -> String {
            let index = lock.withLock { () -> Int in calls += 1; return calls - 1 }
            if held.contains(index) {
                await withCheckedContinuation { continuation in
                    let ready = lock.withLock { () -> Bool in
                        if released.contains(index) { return true }
                        waiting[index] = continuation
                        return false
                    }
                    if ready { continuation.resume() }
                }
            }
            let object = try JSONSerialization.jsonObject(with: Data(requestLine.utf8)) as? [String: Any]
            return replies[index].replacingOccurrences(of: "$ID", with: object?["id"] as? String ?? "x")
        }

        func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private static func page(_ ids: [String], hasMore: Bool = false) -> String {
        let messages = ids.enumerated().map { index, id in
            #"{"id":"\#(id)","direction":"agent_to_owner","from":"llm-opt","text":"\#(id)","created_unix_ms":\#(2_000 - index),"read":false}"#
        }
        return #"{"id":"$ID","result":{"type":"guest_gram_list","has_more":\#(hasMore),"messages":[\#(messages.joined(separator: ","))]}}"#
    }

    private func waitUntil(_ host: OutOfOrderHost, started count: Int) async {
        for _ in 0..<500 where host.started < count {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(host.started, count)
    }

    /// The first refresh (before a push) answers after the second (for the push): the push's
    /// Gram must stay in the list.
    func testAnOlderRefreshThatAnswersLastDoesNotHideANewerGram() async {
        let host = OutOfOrderHost(replies: [Self.page(["m1"]), Self.page(["m2", "m1"])], held: [0])
        let client = HerdrClient(transport: host)
        let feed = GuestGramFeed()

        let older = Task { await feed.refresh(client: client) }
        await waitUntil(host, started: 1)
        let newerApplied = await feed.refresh(client: client)
        XCTAssertTrue(newerApplied)
        XCTAssertEqual(feed.messages.map(\.id), ["m2", "m1"])

        host.release(0)
        let olderApplied = await older.value
        XCTAssertFalse(olderApplied, "an overtaken refresh applies nothing")
        XCTAssertEqual(feed.messages.map(\.id), ["m2", "m1"], "the newer Gram stays")
        XCTAssertEqual(feed.unreadCount, 2)
    }

    /// An older failure that lands after a newer success must not show an error either.
    func testAnOlderFailureThatAnswersLastLeavesTheNewerList() async {
        let failure = #"{"id":"$ID","error":{"code":"host_busy","message":"busy"}}"#
        let host = OutOfOrderHost(replies: [failure, Self.page(["m2"])], held: [0])
        let client = HerdrClient(transport: host)
        let feed = GuestGramFeed()

        let older = Task { await feed.refresh(client: client) }
        await waitUntil(host, started: 1)
        await feed.refresh(client: client)
        host.release(0)
        _ = await older.value
        XCTAssertNil(feed.lastError, "the newest answer succeeded")
        XCTAssertEqual(feed.messages.map(\.id), ["m2"])
    }

    /// An older page fetched before a refresh replaced the list is dropped rather than
    /// appended to the new one.
    func testAnOlderPageFetchedBeforeARefreshIsDropped() async {
        let host = OutOfOrderHost(
            replies: [Self.page(["m3", "m2"], hasMore: true), Self.page(["m1"]), Self.page(["m9", "m3"], hasMore: false)],
            held: [1])
        let client = HerdrClient(transport: host)
        let feed = GuestGramFeed()
        await feed.refresh(client: client)
        XCTAssertTrue(feed.hasMore)

        let more = Task { try? await feed.loadMore(client: client) }
        await waitUntil(host, started: 2)
        await feed.refresh(client: client)
        host.release(1)
        _ = await more.value
        XCTAssertEqual(feed.messages.map(\.id), ["m9", "m3"])
        XCTAssertFalse(feed.hasMore)
    }

    /// CI (#702, j_5b6a9810 / j_359c2da7): the conversation opens with a refresh and, when the
    /// strict floor hides every row, an older page at once. A refresh that lands while the
    /// page is out but leaves the list ending at the page's cursor must not drop the page's
    /// answer: a failure is kept (the screen offers Retry) and a page is appended. Dropping
    /// them left the floor pager spinning forever.
    func testARefreshKeepingTheCursorDoesNotDropTheOlderPage() async throws {
        let failure = #"{"id":"$ID","error":{"code":"internal","message":"gram store busy"}}"#
        do {
            let host = OutOfOrderHost(replies: [Self.page(["z"], hasMore: true), failure, Self.page(["z"], hasMore: true)],
                                      held: [1])
            let client = HerdrClient(transport: host)
            let feed = GuestGramFeed()
            await feed.refresh(client: client)
            let more = Task { () -> Error? in
                do { try await feed.loadMore(client: client); return nil } catch { return error }
            }
            await waitUntil(host, started: 2)
            await feed.refresh(client: client)
            host.release(1)
            let thrown = await more.value
            XCTAssertNotNil(thrown, "the failure reaches the caller")
            XCTAssertNotNil(feed.pageError, "and is kept: the list still ends at the failed page's cursor")
        }
        do {
            let host = OutOfOrderHost(replies: [Self.page(["z"], hasMore: true), Self.page(["y"]), Self.page(["z"], hasMore: true)],
                                      held: [1])
            let client = HerdrClient(transport: host)
            let feed = GuestGramFeed()
            await feed.refresh(client: client)
            let more = Task { try? await feed.loadMore(client: client) }
            await waitUntil(host, started: 2)
            await feed.refresh(client: client)
            host.release(1)
            _ = await more.value
            XCTAssertEqual(feed.messages.map(\.id), ["z", "y"], "the page below the unchanged cursor is appended")
            XCTAssertFalse(feed.hasMore)
        }
    }

    /// Review 2 (#702): an older page that fails is kept as state, not only thrown, so a
    /// conversation whose rows the strict floor all hides can offer Retry; the next page
    /// that lands, or a refresh, clears it.
    func testAFailedOlderPageIsKeptUntilAPageLands() async throws {
        let first = #"{"id":"$ID","result":{"type":"guest_gram_list","has_more":true,"messages":[{"id":"z","direction":"agent_to_owner","from":"a","text":"z","created_unix_ms":500,"read":false}]}}"#
        let older = #"{"id":"$ID","result":{"type":"guest_gram_list","has_more":false,"messages":[{"id":"y","direction":"agent_to_owner","from":"a","text":"y","created_unix_ms":500,"read":true}]}}"#
        let failure = #"{"id":"$ID","error":{"code":"internal","message":"gram store busy"}}"#
        let host = ScriptedHost([first, failure, older])
        let client = HerdrClient(transport: host)
        let feed = GuestGramFeed()
        await feed.refresh(client: client)
        var thrown: Error?
        do { try await feed.loadMore(client: client) } catch { thrown = error }
        XCTAssertNotNil(thrown, "the failure is thrown")
        XCTAssertNotNil(feed.pageError, "and kept for a screen with no sentinel to show it")
        XCTAssertNil(feed.lastError, "the list itself is fine")
        var changes = 0
        feed.onChange = { changes += 1 }
        feed.clearPageError()
        XCTAssertNil(feed.pageError, "Retry clears it, so the view's paging asks again")
        XCTAssertEqual(changes, 1, "and the view hears it")
        feed.onChange = nil
        XCTAssertFalse(GuestGramMerge(lanes: [feed.lane(grant: "a")]).hasMore == false, "still pageable: Retry can ask again")
        try await feed.loadMore(client: client)
        XCTAssertNil(feed.pageError, "a page that lands clears it")
        XCTAssertEqual(GuestGramMerge(lanes: [feed.lane(grant: "a")]).items.map(\.id), ["a/y", "a/z"])
    }

    /// Answers each call with the next scripted line.
    private final class ScriptedHost: HerdrTransport, @unchecked Sendable {
        private var lines: [String]
        private let lock = NSLock()
        init(_ lines: [String]) { self.lines = lines }
        func roundTrip(_ requestLine: String) async throws -> String {
            let object = try JSONSerialization.jsonObject(with: Data(requestLine.utf8)) as? [String: Any]
            let line = lock.withLock { lines.removeFirst() }
            return line.replacingOccurrences(of: "$ID", with: object?["id"] as? String ?? "x")
        }
        func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }
}
