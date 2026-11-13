import Foundation
import XCTest
@testable import HerdrKit

/// Slow-network fix 4: what a cold start paints before the network answers. The store is
/// bounded, least recently used out, wiped per machine or per share, holds only what the
/// screens show, and survives a relaunch.
final class ContentCacheTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("content-cache-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A clock that moves one second per reading, so LRU order is the order of use.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var tick = 1_700_000_000.0
        func now() -> Date { lock.withLock { tick += 1; return Date(timeIntervalSince1970: tick) } }
    }

    /// Every instance made so far, so a "relaunch" (and a look at the disk) first lets the
    /// earlier ones finish their queued writes, as a quitting app would have.
    private var made: [ContentCache] = []

    private func cache(budget: Int = ContentCache.defaultBudgetBytes,
                       entryLimit: Int = ContentCache.defaultEntryLimitBytes,
                       clock: Clock = Clock()) -> ContentCache {
        made.forEach { $0.flush() }
        let cache = ContentCache(root: root, budgetBytes: budget, entryLimitBytes: entryLimit, now: { clock.now() })
        made.append(cache)
        return cache
    }

    private static func agentList(_ names: [String]) -> String {
        let agents = names.enumerated().map { index, name in
            #"{"pane_id":"w1:p\#(index + 1)","terminal_id":"t\#(index + 1)","name":"\#(name)","agent":"omp","agent_status":"idle"}"#
        }
        return #"{"id":"x","result":{"type":"agent_list","agents":[\#(agents.joined(separator: ","))]}}"#
    }

    private static func transcript(_ ids: [String], after: String = "cursor-after", before: String? = "cursor-before") -> String {
        let entries = ids.map { #"{"id":"\#($0)","ts_ms":1,"kind":"reply","text":"\#($0)","final":true}"# }
        let beforeJSON = before.map { "\"\($0)\"" } ?? "null"
        return #"{"id":"x","result":{"type":"agent_transcript","session_id":"s1","entries":[\#(entries.joined(separator: ","))],"before":\#(beforeJSON),"after":"\#(after)"}}"#
    }

    private static func gram(_ ids: [String]?, digest: String = "d1") -> String {
        guard let ids else { return #"{"id":"x","result":{"type":"gram_list","digest":"\#(digest)","store_id":"st"}}"# }
        let messages = ids.map {
            #"{"id":"\#($0)","direction":"agent_to_owner","from":"alfa","to":"owner","text":"hello \#($0)","created_unix_ms":1,"read_by_owner":false}"#
        }
        return #"{"id":"x","result":{"type":"gram_list","messages":[\#(messages.joined(separator: ","))],"digest":"\#(digest)","store_id":"st","has_more":false}}"#
    }

    /// Every file the cache holds, relative to its root.
    private func storedFiles() -> [String] {
        made.forEach { $0.flush() }
        let base = root.resolvingSymlinksInPath().path
        let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (walk?.allObjects as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { String($0.resolvingSymlinksInPath().path.dropFirst(base.count + 1)) }
            .sorted()
    }

    private func storedBytes() -> String {
        storedFiles().compactMap { try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
    }

    // MARK: Round trip through the client

    func testTheClientRecordsTheAgentListAndARelaunchReadsItBack() async throws {
        let store = cache()
        let transport = RecordingTransport(replies: ["agent.list": Self.agentList(["alfa", "bravo"])])
        let client = HerdrClient(transport: transport, contentCache: store.scope(machine: "me@mac:22", session: nil))
        let fresh = try await client.agentListing()

        // A new process: a new cache over the same directory, no client, no network.
        let relaunched = cache().scope(machine: "me@mac:22", session: nil)
        XCTAssertEqual(relaunched.agents(), fresh)
        XCTAssertEqual(relaunched.agents()?.agents.map(\.name), ["alfa", "bravo"])
    }

    func testMachinesAndSessionsAreKeptApart() async throws {
        let store = cache()
        for (machine, session, name) in [("me@mac:22", nil, "default-agent"), ("me@mac:22", "work", "work-agent"),
                                         ("me@linux:22", nil, "other-machine")] as [(String, String?, String)] {
            let client = HerdrClient(transport: RecordingTransport(replies: ["agent.list": Self.agentList([name])]),
                                     contentCache: store.scope(machine: machine, session: session))
            _ = try await client.agentListing()
        }
        XCTAssertEqual(store.scope(machine: "me@mac:22", session: nil).agents()?.agents.map(\.name), ["default-agent"])
        XCTAssertEqual(store.scope(machine: "me@mac:22", session: "default").agents()?.agents.map(\.name),
                       ["default-agent"], "\"default\" is the default session")
        XCTAssertEqual(store.scope(machine: "me@mac:22", session: "work").agents()?.agents.map(\.name), ["work-agent"])
        XCTAssertEqual(store.scope(machine: "me@linux:22", session: nil).agents()?.agents.map(\.name), ["other-machine"])
        XCTAssertNil(store.scope(machine: "me@mac:22", session: "personal").agents())
    }

    func testOnlyTheNewestChatPageIsKeptAndItsCursorsAreNotTrusted() async throws {
        let store = cache()
        let transport = RecordingTransport { _, params in
            if params["before"] != nil { return Self.transcript(["older"], before: nil) }
            if params["after"] != nil { return Self.transcript(["appended"]) }
            return Self.transcript(["newest-1", "newest-2"])
        }
        let client = HerdrClient(transport: transport, contentCache: store.scope(machine: "me@mac:22", session: nil))
        _ = try await client.agentTranscript(target: "w1:p1", limit: 5)
        _ = try await client.agentTranscript(target: "w1:p1", before: "b")
        _ = try await client.agentTranscript(target: "w1:p1", after: "a")

        let kept = try XCTUnwrap(store.scope(machine: "me@mac:22", session: nil).transcript(target: "w1:p1"))
        XCTAssertEqual(kept.entries.map(\.id), ["newest-1", "newest-2"])
        XCTAssertTrue(store.scope(machine: "me@mac:22", session: nil).hasTranscript(target: "w1:p1"))
        XCTAssertNil(store.scope(machine: "me@mac:22", session: nil).transcript(target: "w2:p1"))
        XCTAssertNil(store.scope(machine: "me@mac:22", session: nil).transcript(target: "w1:p1", subagent: "Review"),
                     "a subagent's page is its own entry")
    }

    func testGramKeepsOnlyTheInboxHeadPageAndAnUnchangedAnswerKeepsIt() async throws {
        let store = cache()
        var reply = Self.gram(["g1", "g2"])
        let transport = RecordingTransport { _, _ in reply }
        let client = HerdrClient(transport: transport, contentCache: store.scope(machine: "me@mac:22", session: nil))
        let scope = store.scope(machine: "me@mac:22", session: nil)

        // The badge, the fork probe and older pages are not what the inbox shows.
        _ = try await client.gramList(unreadOnly: true, keepsForColdStart: true)
        _ = try await client.gramList(limit: 1)
        _ = try await client.gramList(limit: 40, beforeID: "g0", keepsForColdStart: true)
        XCTAssertNil(scope.gramHead())

        _ = try await client.gramList(limit: 40, keepsForColdStart: true)
        XCTAssertEqual(scope.gramHead()?.messages?.map(\.id), ["g1", "g2"])
        XCTAssertEqual(scope.gramHead()?.digest, "d1")

        reply = Self.gram(nil)
        _ = try await client.gramList(ifUnchangedDigest: "d1", limit: 40, keepsForColdStart: true)
        XCTAssertEqual(scope.gramHead()?.messages?.map(\.id), ["g1", "g2"], "\"unchanged\" must not blank the kept page")

        reply = Self.gram(["g3", "g1", "g2"], digest: "d2")
        _ = try await client.gramList(ifUnchangedDigest: "d1", limit: 40, keepsForColdStart: true)
        XCTAssertEqual(scope.gramHead()?.messages?.map(\.id), ["g3", "g1", "g2"])
    }

    func testTerminalTextIsPlainTextPerPane() {
        let scope = cache().scope(machine: "me@mac:22", session: nil)
        scope.storeTerminalText("$ ls\nREADME.md", pane: "w1:p1")
        XCTAssertEqual(scope.terminalText(pane: "w1:p1"), "$ ls\nREADME.md")
        XCTAssertNil(scope.terminalText(pane: "w1:p2"))
    }

    // MARK: Bounds

    func testTheLeastRecentlyUsedEntryGoesFirstWhenTheBudgetIsFull() {
        let entry = String(repeating: "x", count: 400)
        let store = cache(budget: 1_000)
        let scope = store.scope(machine: "me@mac:22", session: nil)
        scope.storeTerminalText(entry, pane: "a")
        scope.storeTerminalText(entry, pane: "b")
        XCTAssertNotNil(scope.terminalText(pane: "a"), "reading `a` makes `b` the least recently used")
        scope.storeTerminalText(entry, pane: "c")

        XCTAssertNotNil(scope.terminalText(pane: "a"))
        XCTAssertNil(scope.terminalText(pane: "b"))
        XCTAssertNotNil(scope.terminalText(pane: "c"))
        XCTAssertLessThanOrEqual(store.totalBytes, 1_000)
    }

    func testTheBudgetSpansEveryMachineAndShare() {
        let entry = String(repeating: "x", count: 400)
        let store = cache(budget: 1_000)
        store.scope(machine: "me@mac:22", session: nil).storeTerminalText(entry, pane: "a")
        store.scope(share: "relay/guest", sharedTarget: "t1").storeTerminalText(entry, pane: "t1")
        store.scope(machine: "me@linux:22", session: "work").storeTerminalText(entry, pane: "b")

        XCTAssertNil(store.scope(machine: "me@mac:22", session: nil).terminalText(pane: "a"))
        XCTAssertNotNil(store.scope(share: "relay/guest", sharedTarget: "t1").terminalText(pane: "t1"))
        XCTAssertNotNil(store.scope(machine: "me@linux:22", session: "work").terminalText(pane: "b"))
        XCTAssertLessThanOrEqual(store.totalBytes, 1_000)
    }

    func testRecencySurvivesARelaunch() {
        let entry = String(repeating: "x", count: 400)
        let clock = Clock()
        let first = cache(budget: 1_000, clock: clock).scope(machine: "me@mac:22", session: nil)
        first.storeTerminalText(entry, pane: "a")
        first.storeTerminalText(entry, pane: "b")
        _ = first.terminalText(pane: "a")

        // The next launch learns the order from the files, not from memory.
        let second = cache(budget: 1_000, clock: clock).scope(machine: "me@mac:22", session: nil)
        second.storeTerminalText(entry, pane: "c")
        XCTAssertNotNil(second.terminalText(pane: "a"))
        XCTAssertNil(second.terminalText(pane: "b"))
    }

    func testAnEntryOverTheLimitIsNotKeptAndDropsItsOlderCopy() {
        let store = cache(entryLimit: 100)
        let scope = store.scope(machine: "me@mac:22", session: nil)
        scope.storeTerminalText("small", pane: "a")
        scope.storeTerminalText(String(repeating: "x", count: 101), pane: "a")
        XCTAssertNil(scope.terminalText(pane: "a"), "a stale screen must not outlive the one that replaced it")
        XCTAssertEqual(store.totalBytes, 0)
    }

    // MARK: Wipes

    func testForgettingAMachineWipesEverySessionOfItAndNothingElse() async throws {
        let store = cache()
        let mac = store.scope(machine: "me@mac:22", session: nil)
        let macWork = store.scope(machine: "me@mac:22", session: "work")
        let linux = store.scope(machine: "me@linux:22", session: nil)
        let share = store.scope(share: "relay/guest", sharedTarget: "t1")
        for scope in [mac, macWork, linux, share] {
            let client = HerdrClient(transport: RecordingTransport(replies: [
                "agent.list": Self.agentList(["alfa"]), "agent.transcript": Self.transcript(["e1"])]),
                                     contentCache: scope)
            _ = try await client.agentListing()
            _ = try await client.agentTranscript(target: "t1", limit: 5)
            scope.storeTerminalText("screen", pane: "t1")
        }

        store.wipe(.machine("me@mac:22"))
        XCTAssertNil(mac.agents())
        XCTAssertNil(mac.transcript(target: "t1"))
        XCTAssertNil(mac.terminalText(pane: "t1"))
        XCTAssertNil(macWork.agents())
        XCTAssertNotNil(linux.agents())
        XCTAssertNotNil(share.agents())
        XCTAssertFalse(storedFiles().contains { $0.hasPrefix(ContentCache.Owner.machine("me@mac:22").directoryName) },
                       "the machine's files are gone from disk, not just from the index")

        // A relaunch agrees.
        XCTAssertNil(cache().scope(machine: "me@mac:22", session: "work").agents())
        XCTAssertNotNil(cache().scope(machine: "me@linux:22", session: nil).agents())
    }

    func testLeavingAShareWipesOnlyThatShare() async throws {
        let store = cache()
        let left = store.scope(share: "relay/guest-1", sharedTarget: "t1")
        let kept = store.scope(share: "relay/guest-2", sharedTarget: "t1")
        let owner = store.scope(machine: "me@mac:22", session: nil)
        for scope in [left, kept, owner] { scope.storeTerminalText("screen", pane: "t1") }

        store.wipe(.share("relay/guest-1"))
        XCTAssertNil(left.terminalText(pane: "t1"))
        XCTAssertNotNil(kept.terminalText(pane: "t1"))
        XCTAssertNotNil(owner.terminalText(pane: "t1"))
    }

    // MARK: What is kept

    func testAGuestKeepsOnlyWhatItsShareShows() async throws {
        let store = cache()
        let scope = store.scope(share: "relay/guest", sharedTarget: "t2")
        let transport = RecordingTransport(replies: [
            "agent.list": Self.agentList(["unshared", "shared", "also-unshared"]),
            "agent.transcript": Self.transcript(["e1"]),
            "gram.list": Self.gram(["g1"]),
        ])
        let client = HerdrClient(transport: transport, contentCache: scope)
        _ = try await client.agentListing()
        _ = try await client.agentTranscript(target: "t1", limit: 5)
        _ = try await client.agentTranscript(target: "t2", limit: 5)
        _ = try await client.gramList(limit: 40, keepsForColdStart: true)
        scope.storeTerminalText("not shared", pane: "t1")
        scope.storeTerminalText("shared screen", pane: "t2")

        XCTAssertEqual(scope.agents()?.agents.map(\.name), ["shared"])
        XCTAssertNil(scope.transcript(target: "t1"))
        XCTAssertNotNil(scope.transcript(target: "t2"))
        XCTAssertNil(scope.gramHead())
        XCTAssertNil(scope.terminalText(pane: "t1"))
        XCTAssertEqual(scope.terminalText(pane: "t2"), "shared screen")
        XCTAssertFalse(storedBytes().contains("unshared"), "no trace of an agent the share does not show")
    }

    func testAGuestWhoseHostOmitsTheIdsKeepsTheSharedAgentByName() async throws {
        let scope = cache().scope(share: "relay/guest", sharedTarget: "t9", sharedName: "shared")
        let reply = #"{"id":"x","result":{"type":"agent_list","agents":[{"pane_id":"","name":"other"},{"pane_id":"","name":"shared"}]}}"#
        let client = HerdrClient(transport: RecordingTransport(replies: ["agent.list": reply]), contentCache: scope)
        _ = try await client.agentListing()
        XCTAssertEqual(scope.agents()?.agents.map(\.name), ["shared"])
        XCTAssertFalse(storedBytes().contains("other"))
    }

    func testNothingButTheShownRepliesIsWrittenSoNoSecretReachesDisk() async throws {
        let store = cache()
        let secret = "invite-token-3f9a"
        let transport = RecordingTransport { method, _ in
            switch method {
            case "agent.list": return Self.agentList(["alfa"])
            case "agent.transcript": return Self.transcript(["e1"])
            case "gram.list": return Self.gram(["g1"])
            default:
                // Replies that carry tokens: guest invites, push registration, anything else.
                return #"{"id":"x","result":{"type":"ok","token":"\#(secret)","invite":"herdr://join?t=\#(secret)","capabilities":{}}}"#
            }
        }
        let client = HerdrClient(transport: transport, contentCache: store.scope(machine: "me@mac:22", session: nil))
        _ = try await client.agentListing()
        _ = try await client.agentTranscript(target: "w1:p1", limit: 5)
        _ = try await client.gramList(limit: 40, keepsForColdStart: true)
        _ = try? await client.serverCapabilities()
        _ = try? await client.accountsList()
        _ = try? await client.guestInviteCreate(target: "w1:p1", name: "Ann", ownerName: "Me", machineLabel: "Mac")

        XCTAssertEqual(storedFiles().map { ($0 as NSString).lastPathComponent }.sorted(),
                       ["agents.json", "chat-" + ContentCache.fileSafe("w1:p1") + ".json", "gram.json"])
        XCTAssertFalse(storedBytes().contains(secret))
        XCTAssertFalse(storedFiles().joined().contains("me@mac"), "file names do not spell out the machine")
    }

    func testAClientWithoutACacheWritesNothing() async throws {
        let client = HerdrClient(transport: RecordingTransport(replies: ["agent.list": Self.agentList(["alfa"])]))
        _ = try await client.agentListing()
        XCTAssertNil(client.contentCache)
        XCTAssertEqual(storedFiles(), [])
    }

    func testAnUnreadableEntryReadsAsNothing() throws {
        let store = cache()
        let scope = store.scope(machine: "me@mac:22", session: nil)
        scope.recordAgentList("not json")
        XCTAssertNil(scope.agents())
    }

    func testLongKeysStayValidFileNames() {
        let long = String(repeating: "pane-", count: 100)
        XCTAssertLessThanOrEqual(ContentCache.fileSafe(long).utf8.count, 130)
        XCTAssertEqual(ContentCache.fileSafe(long), ContentCache.fileSafe(long))
        XCTAssertFalse(ContentCache.fileSafe("a/b+c").contains("/"))
        let scope = cache().scope(machine: "me@mac:22", session: nil)
        scope.storeTerminalText("screen", pane: long)
        XCTAssertEqual(scope.terminalText(pane: long), "screen")
    }
}

/// The Chat's cold start: a kept page shows at once, and the first refresh replaces it.
@MainActor
final class TranscriptStoreCachedPageTests: XCTestCase {
    private static func page(_ ids: [String], after: String = "fresh-after") throws -> AgentTranscriptPage {
        let entries = ids.map { #"{"id":"\#($0)","ts_ms":1,"kind":"reply","text":"\#($0)","final":true}"# }
        let line = #"{"result":{"type":"agent_transcript","session_id":"s1","entries":[\#(entries.joined(separator: ","))],"before":"older","after":"\#(after)"}}"#
        struct Envelope: Decodable { let result: AgentTranscriptPage }
        return try JSONDecoder().decode(Envelope.self, from: Data(line.utf8)).result
    }

    func testAKeptPageShowsAtOnceAndTheFirstRefreshReplacesIt() async throws {
        let transport = RecordingTransport { _, _ in
            #"{"id":"x","result":{"type":"agent_transcript","session_id":"s1","entries":[{"id":"e1","ts_ms":1,"kind":"reply","text":"e1","final":true},{"id":"e2","ts_ms":2,"kind":"reply","text":"e2","final":true}],"before":null,"after":"a2"}}"#
        }
        let client = HerdrClient(transport: transport)
        let store = TranscriptStore(target: "w1:p1")
        var changes = 0
        store.onChange = { changes += 1 }

        store.showCached(try Self.page(["e1"], after: "stale-cursor"))
        XCTAssertTrue(store.loaded, "the chat draws the kept page instead of a spinner")
        XCTAssertTrue(store.isShowingCached)
        XCTAssertEqual(store.entries.map(\.id), ["e1"])
        XCTAssertFalse(store.hasOlder, "the kept page's cursors describe the server as it was")
        XCTAssertEqual(changes, 1)

        await store.refresh(client: client)
        let request = try transport.last()
        XCTAssertNil(request.params["after"], "the first refresh fetches the newest page, not what followed a stale cursor")
        XCTAssertEqual(request.params["limit"] as? Int, Int(TranscriptStore.newestPageTurns))
        XCTAssertFalse(store.isShowingCached)
        XCTAssertEqual(store.entries.map(\.id), ["e1", "e2"])
    }

    func testAKeptPageNeverReplacesALoadedOne() async throws {
        let client = HerdrClient(transport: RecordingTransport { _, _ in
            #"{"id":"x","result":{"type":"agent_transcript","session_id":"s1","entries":[{"id":"live","ts_ms":1,"kind":"reply","text":"live","final":true}],"before":null,"after":"a"}}"#
        })
        let store = TranscriptStore(target: "w1:p1")
        await store.refresh(client: client)
        store.showCached(try Self.page(["kept"]))
        XCTAssertEqual(store.entries.map(\.id), ["live"])
        XCTAssertFalse(store.isShowingCached)
    }

    func testAFailedRefreshKeepsTheKeptPageAndEndsUpdating() async throws {
        let client = HerdrClient(transport: RecordingTransport.error(code: "transcript_unavailable", message: "busy"))
        let store = TranscriptStore(target: "w1:p1")
        store.showCached(try Self.page(["kept"]))
        await store.refresh(client: client)
        XCTAssertEqual(store.entries.map(\.id), ["kept"], "a stale page beats an empty chat")
        XCTAssertFalse(store.isShowingCached)
        XCTAssertNotNil(store.lastError)
    }

    func testASendWaitsForTheRealPageNotTheKeptOne() async throws {
        let client = HerdrClient(transport: RecordingTransport { _, _ in
            #"{"id":"x","result":{"type":"agent_transcript","session_id":"s1","entries":[],"before":null,"after":"a"}}"#
        })
        let store = TranscriptStore(target: "w1:p1")
        store.showCached(try Self.page(["kept"]))
        let id = store.stageOutgoing(text: "hi", author: .owner)
        let ready = await store.prepareOutgoing(id, client: client)
        XCTAssertTrue(ready)
        XCTAssertFalse(store.isShowingCached, "preparing a send fetched the real page first")
    }
}
