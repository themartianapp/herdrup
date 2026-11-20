import XCTest
@testable import HerdrKit

final class SyncEngineTests: XCTestCase {
    private var service: FakeSyncService!

    override func setUp() {
        super.setUp()
        AccountServiceStub.reset()
        service = FakeSyncService()
        let service = service!
        AccountServiceStub.handler = { service.handle($0) }
    }

    override func tearDown() {
        AccountServiceStub.reset()
        super.tearDown()
    }

    /// One device: its own session and sync state.
    private func device(store: InMemorySyncStateStore = InMemorySyncStateStore()) throws -> SyncEngine {
        try SyncEngine(session: makeStubSession(), store: store)
    }

    private let hostID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    private var hostKey: SyncKey { .host(hostID) }

    private func host(_ nickname: String) -> SyncBody {
        .host(SyncHost(nickname: nickname, host: "mac.local", port: 22, username: "jerry", authKind: .key))
    }

    private func nickname(_ item: SyncItem?) -> String? {
        if case .host(let host)? = item?.body { return host.nickname }
        return nil
    }

    private var pulls: [[String: String]] {
        AccountServiceStub.requests.filter { $0.method == "GET" && $0.path == "/v1/sync" }.map(\.query)
    }

    private var pushes: [[[String: Any]]] {
        AccountServiceStub.requests.filter { $0.method == "POST" && $0.path == "/v1/sync" }
            .map { $0.json["changes"] as? [[String: Any]] ?? [] }
    }

    // MARK: Last writer wins, per item

    func testLastWriteToReachTheServiceWinsPerItem() async throws {
        let a = try device()
        let b = try device()
        try await a.stage(.upsert(hostKey, host("from A")))
        _ = try await a.sync()
        _ = try await b.sync()
        let seenByB = await b.item(hostKey)
        XCTAssertEqual(nickname(seenByB), "from A")

        try await b.stage(.upsert(hostKey, host("from B")))
        _ = try await b.sync()
        // A edits later on the clock but reaches the service after B: background pushes carry
        // no base_rev, so A's write is the last and wins.
        try await a.stage(.upsert(hostKey, host("from A again")))
        let reportA = try await a.sync()
        XCTAssertTrue(reportA.changed.isEmpty, "A's own edit isn't news to A")
        XCTAssertEqual(service.body("hosts", hostKey.id)?["nickname"] as? String, "from A again")

        let reportB = try await b.sync()
        XCTAssertEqual(reportB.changed.map(\.key), [hostKey])
        XCTAssertEqual(nickname(reportB.changed.first), "from A again")
        XCTAssertEqual(service.rev("hosts", hostKey.id), 3)
    }

    func testPulledServerCopyDoesNotOverwriteAQueuedLocalEdit() async throws {
        let a = try device()
        service.write("hosts", hostKey.id, body: ["host": "mac.local", "username": "jerry", "nickname": "server"])
        _ = try await a.sync()
        try await a.stage(.upsert(hostKey, host("local")))
        service.write("hosts", hostKey.id, body: ["host": "mac.local", "username": "jerry", "nickname": "newer server"])

        let report = try await a.sync()

        // A's push reached the service after the other write, so A's value is the latest.
        XCTAssertTrue(report.changed.isEmpty)
        let item = await a.item(hostKey)
        XCTAssertEqual(nickname(item), "local")
        XCTAssertEqual(service.body("hosts", hostKey.id)?["nickname"] as? String, "local")
    }

    func testSettingsAreOneItemPerKeySoDevicesDontClobber() async throws {
        let a = try device()
        let b = try device()
        try await a.stage(.upsert(.setting("terminal.fontSize"), .setting(.number(14))))
        try await b.stage(.upsert(.setting("ui.theme"), .setting(.string("dark"))))
        _ = try await a.sync()
        _ = try await b.sync()
        let reportA = try await a.sync()

        XCTAssertEqual(reportA.changed.map(\.key), [.setting("ui.theme")])
        let settingsA = await a.items(in: .settings)
        let settingsB = await b.items(in: .settings)
        XCTAssertEqual(settingsA.map(\.key.id), ["terminal.fontSize", "ui.theme"])
        XCTAssertEqual(settingsB.map(\.key.id), ["terminal.fontSize", "ui.theme"])
        XCTAssertEqual(settingsA.first?.body, .setting(.number(14)))
        XCTAssertEqual(settingsA.last?.body, .setting(.string("dark")))
        XCTAssertEqual(pushes.flatMap { $0 }.map { $0["id"] as? String }, ["terminal.fontSize", "ui.theme"])
    }

    func testDeleteReachesOtherDevicesAsRemoval() async throws {
        let a = try device()
        let b = try device()
        try await a.stage(.upsert(hostKey, host("doomed")))
        _ = try await a.sync()
        _ = try await b.sync()

        try await a.stage(.delete(hostKey))
        _ = try await a.sync()
        let report = try await b.sync()

        XCTAssertEqual(report.removed, [hostKey])
        let item = await b.item(hostKey)
        XCTAssertNil(item)
        let rev = await b.serverRev(hostKey)
        XCTAssertEqual(rev, 2, "the tombstone is kept, so an editor's base_rev is right")
        XCTAssertEqual(pushes.last?.first?["deleted"] as? Bool, true)
        XCTAssertNil(pushes.last?.first?["body"])
    }

    // MARK: Conflicts

    func testStaleBaseRevComesBackAsAConflictWithTheServerCopy() async throws {
        let a = try device()
        let b = try device()
        try await a.stage(.upsert(hostKey, host("original")))
        _ = try await a.sync()
        _ = try await b.sync()

        // A opens the editor at rev 1; meanwhile B saves.
        let base = await a.serverRev(hostKey)
        XCTAssertEqual(base, 1)
        try await b.stage(.upsert(hostKey, host("B's edit")))
        _ = try await b.sync()
        let local = try SyncChange.upsert(hostKey, host("A's edit"), baseRev: base)
        try await a.stage(local)

        let report = try await a.sync()

        XCTAssertEqual(report.conflicts.count, 1)
        XCTAssertEqual(report.conflicts.first?.local, local)
        XCTAssertEqual(report.conflicts.first?.server?.rev, 2)
        XCTAssertEqual(nickname(report.conflicts.first?.server), "B's edit")
        XCTAssertEqual(pushes.last?.first?["base_rev"] as? Int, 1)
        // The service kept B's; so does A until the user resolves it.
        XCTAssertEqual(service.body("hosts", hostKey.id)?["nickname"] as? String, "B's edit")
        let item = await a.item(hostKey)
        XCTAssertEqual(nickname(item), "B's edit")
        let state = await a.currentState
        XCTAssertTrue(state.pending.isEmpty)

        // Keeping A's edit: stage again from the server's revision.
        try await a.stage(.upsert(hostKey, host("A's edit"), baseRev: report.conflicts.first?.server?.rev))
        let resolved = try await a.sync()
        XCTAssertTrue(resolved.conflicts.isEmpty)
        XCTAssertEqual(service.body("hosts", hostKey.id)?["nickname"] as? String, "A's edit")
    }

    func testCreateOnlyConflictsWithAnExistingItem() async throws {
        service.write("hosts", hostKey.id, body: ["host": "elsewhere", "username": "root"])
        let a = try device()
        try await a.stage(.upsert(hostKey, host("mine"), baseRev: 0))

        let report = try await a.sync()

        XCTAssertEqual(report.conflicts.map(\.local.key), [hostKey])
        XCTAssertEqual(report.changed.map(\.key), [hostKey], "the service's copy replaces the refused create")
    }

    // MARK: Paging

    func testPullPagesWithTheCursorAndKeepsTheLastRev() async throws {
        service.pageSize = 2
        let ids = (0..<5).map { UUID(uuidString: "00000000-0000-0000-0000-00000000000\($0)")! }
        for (n, id) in ids.enumerated() {
            service.write("prompts", id.uuidString.lowercased(), body: ["text": "prompt \(n)", "order": n])
        }
        let store = InMemorySyncStateStore()
        let a = try device(store: store)

        let report = try await a.sync()

        XCTAssertEqual(pulls, [["since": "0"], ["cursor": "2.5"], ["cursor": "4.5"]], "cursors go back unchanged")
        XCTAssertEqual(report.changed.count, 5)
        XCTAssertEqual(try store.loadSyncState()?.since, 5, "the last page's rev is the next since")
        let prompts = await a.items(in: .prompts)
        XCTAssertEqual(prompts.compactMap { item -> String? in
            if case .prompt(let prompt)? = item.body { return prompt.text }
            return nil
        }, (0..<5).map { "prompt \($0)" })

        service.write("prompts", ids[0].uuidString.lowercased(), body: ["text": "edited", "order": 0])
        let next = try await a.sync()
        XCTAssertEqual(pulls.last, ["since": "5"])
        XCTAssertEqual(next.changed.map(\.key), [.prompt(ids[0])])
        XCTAssertFalse(next.replaced)
    }

    func testAPullCutShortChangesNothing() async throws {
        service.pageSize = 1
        service.write("settings", "ui.theme", body: ["value": "dark"])
        service.write("settings", "chat.fontSize", body: ["value": 15])
        let store = InMemorySyncStateStore()
        let a = try device(store: store)
        AccountServiceStub.handler = { [service = service!] request in
            request.query["cursor"] != nil ? .error(503, "unavailable") : service.handle(request)
        }

        do {
            _ = try await a.sync()
            XCTFail("expected the refusal")
        } catch {
            XCTAssertEqual((error as? AccountError)?.code, "unavailable")
        }
        let items = await a.items(in: .settings)
        XCTAssertTrue(items.isEmpty)
        let state = await a.currentState
        XCTAssertEqual(state.since, 0)
    }

    // MARK: Full reset replaces the local copy

    func testResetRequiredReplacesTheLocalCopy() async throws {
        let a = try device()
        let b = try device()
        let keep = SyncKey.prompt(UUID())
        let gone = SyncKey.prompt(UUID())
        try await a.stage(.upsert(keep, .prompt(SyncPrompt(text: "keep"))))
        try await a.stage(.upsert(gone, .prompt(SyncPrompt(text: "gone"))))
        _ = try await a.sync()
        _ = try await b.sync()

        // B deletes one; the tombstone is pruned before A comes back, so A can't learn of the
        // delete incrementally.
        try await b.stage(.delete(gone))
        _ = try await b.sync()
        service.pruneTombstones()

        let report = try await a.sync()

        XCTAssertEqual(pulls.suffix(2), [["since": "2"], ["since": "0"]], "410, then a full pull")
        XCTAssertTrue(report.replaced)
        XCTAssertEqual(report.removed, [gone])
        let prompts = await a.items(in: .prompts)
        XCTAssertEqual(prompts.map(\.key), [keep])
        let state = await a.currentState
        XCTAssertEqual(state.since, 3)
        XCTAssertNil(state.items.first { $0.key == gone }, "nothing of the dropped item is kept")
    }

    func testAFullPullFromZeroReplacesEvenWithoutAReset() async throws {
        // A copy left from another history (a restored state with since 0): the full pull is
        // the truth, and every item it doesn't list goes.
        let stale = SyncItem(key: .setting("ui.theme"), rev: 9, updatedMs: 1, body: .setting(.string("light")))
        let a = try device(store: InMemorySyncStateStore(state: SyncState(since: 0, items: [stale])))
        service.write("settings", "chat.fontSize", body: ["value": 16])

        let report = try await a.sync()

        XCTAssertTrue(report.replaced)
        XCTAssertEqual(report.removed, [.setting("ui.theme")])
        XCTAssertEqual(report.changed.map(\.key), [.setting("chat.fontSize")])
        let settings = await a.items(in: .settings)
        XCTAssertEqual(settings.map(\.key.id), ["chat.fontSize"])
    }

    func testAFullPullKeepsQueuedLocalChanges() async throws {
        // since 7 is past this account's history (a restored database): reset. The push is
        // held back by the quota, so the local change is still queued when the copy is replaced.
        let a = try device(store: InMemorySyncStateStore(state: SyncState(since: 7)))
        service.write("settings", "chat.fontSize", body: ["value": 16])
        service.pushRefusal = { _ in .error(403, "quota") }
        try await a.stage(.upsert(.setting("ui.fontScale"), .setting(.number(1.5))))

        let report = try await a.sync()

        XCTAssertTrue(report.overQuota)
        XCTAssertTrue(report.replaced)
        XCTAssertEqual(pulls, [["since": "7"], ["since": "0"]])
        let fontScale = await a.item(.setting("ui.fontScale"))
        XCTAssertEqual(fontScale?.body, .setting(.number(1.5)), "a queued change outlives the replace")
        let chat = await a.item(.setting("chat.fontSize"))
        XCTAssertEqual(chat?.body, .setting(.number(16)))
        let state = await a.currentState
        XCTAssertEqual(state.pending.map(\.key), [.setting("ui.fontScale")])

        service.pushRefusal = nil
        _ = try await a.sync()
        XCTAssertEqual(service.body("settings", "ui.fontScale")?["value"] as? Double, 1.5)
    }

    // MARK: Sign-out during a sync

    /// Serves the fake, answering requests that match `hold` only after `delay`.
    private func holdReplies(_ delay: TimeInterval = 0.4, where hold: @escaping @Sendable (AccountServiceStub.Request) -> Bool) {
        let service = service!
        AccountServiceStub.handler = { request in
            var reply = service.handle(request)
            if hold(request) { reply.delay = delay }
            return reply
        }
    }

    /// Waits until the stub has seen a request matching `match`.
    private func waitForRequest(_ match: (AccountServiceStub.Request) -> Bool,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if AccountServiceStub.requests.contains(where: match) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("the request never went out", file: file, line: line)
    }

    func testClearDuringAHeldPullSavesNothingAndTheNextSyncStartsOver() async throws {
        let store = InMemorySyncStateStore()
        let a = try device(store: store)
        service.write("settings", "chat.fontSize", body: ["value": 15])
        service.write("settings", "terminal.fontSize", body: ["value": 13])
        service.write("settings", "guest.ownerName", body: ["value": "Old Account"])
        _ = try await a.sync()
        XCTAssertEqual(try store.loadSyncState()?.since, 3)

        service.write("settings", "ui.theme", body: ["value": "dark"])
        holdReplies { $0.method == "GET" && $0.query["since"] == "3" }
        let held = Task { try await a.sync() }
        try await waitForRequest { $0.method == "GET" && $0.query["since"] == "3" }

        // Signed out while the pull is on the wire.
        try await a.clear()
        XCTAssertNil(try store.loadSyncState())
        _ = try? await held.value
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertNil(try store.loadSyncState(), "the stale pull must not write the old account's copy back")
        let state = await a.currentState
        XCTAssertEqual(state, SyncState())

        // Signed in again: a full replace from 0, not an incremental pull from the old cursor.
        holdReplies(0) { _ in false }
        let report = try await a.sync()
        XCTAssertEqual(pulls.last, ["since": "0"])
        XCTAssertTrue(report.replaced)
        XCTAssertEqual(try store.loadSyncState()?.since, 4)
    }

    func testClearDuringAHeldPushSavesNothingAndTheNextSyncStartsOver() async throws {
        let store = InMemorySyncStateStore()
        let a = try device(store: store)
        service.write("settings", "chat.fontSize", body: ["value": 15])
        _ = try await a.sync()

        try await a.stage(.upsert(.setting("ui.theme"), .setting(.string("dark"))))
        holdReplies { $0.method == "POST" && $0.path == "/v1/sync" }
        let held = Task { try await a.sync() }
        try await waitForRequest { $0.method == "POST" && $0.path == "/v1/sync" }

        try await a.clear()
        XCTAssertNil(try store.loadSyncState())
        _ = try? await held.value
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertNil(try store.loadSyncState(), "the stale push must not write the old account's copy back")
        let state = await a.currentState
        XCTAssertEqual(state, SyncState())
        let pushesBefore = pushes.count

        holdReplies(0) { _ in false }
        let report = try await a.sync()
        XCTAssertEqual(pushes.count, pushesBefore, "nothing of the old queue is pushed again")
        XCTAssertEqual(pulls.last, ["since": "0"])
        XCTAssertTrue(report.replaced)
    }

    func testStageRefusesADecodedChangeWithASecret() async throws {
        let store = InMemorySyncStateStore()
        let a = try device(store: store)
        let decoded = try JSONDecoder().decode(SyncChange.self, from: Data("""
            {"collection":"prompts","id":"6f9619ff-8b86-d011-b42d-00c04fc964ff",
             "body":{"text":"-----BEGIN OPENSSH PRIVATE KEY-----\\nb3BlbnNzaC1rZXktdjEAAAAA\\n-----END OPENSSH PRIVATE KEY-----"}}
            """.utf8))

        do {
            try await a.stage(decoded)
            XCTFail("expected secretLike")
        } catch {
            guard case .secretLike? = error as? SyncError else { return XCTFail("\(error)") }
        }
        let state = await a.currentState
        XCTAssertTrue(state.pending.isEmpty)
        XCTAssertNil(try store.loadSyncState())

        // An invalid decoded change is refused at the same boundary.
        let invalid = try JSONDecoder().decode(SyncChange.self, from: Data("""
            {"collection":"settings","id":"previews.javascript","body":{"value":true}}
            """.utf8))
        do {
            try await a.stage(invalid)
            XCTFail("expected invalid")
        } catch {
            XCTAssertEqual(error as? SyncError, .invalid(field: "id"))
        }
    }

    func testAQueuedSecretFromAStoredStateIsNeverPushed() async throws {
        let secret = try JSONDecoder().decode(SyncChange.self, from: Data("""
            {"collection":"prompts","id":"6f9619ff-8b86-d011-b42d-00c04fc964ff",
             "body":{"text":"pin SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU"}}
            """.utf8))
        let fine = try SyncChange.upsert(.setting("ui.theme"), .setting(.string("light")))
        let a = try device(store: InMemorySyncStateStore(state: SyncState(since: 0, pending: [secret, fine])))

        let report = try await a.sync()

        XCTAssertEqual(report.rejected.map(\.change), [secret])
        XCTAssertEqual(pushes.flatMap { $0 }.map { $0["id"] as? String }, ["ui.theme"])
        let state = await a.currentState
        XCTAssertTrue(state.pending.isEmpty)
    }

    // MARK: Push limits and refusals

    func testPushesInBatchesOfAHundred() async throws {
        let a = try device()
        for _ in 0..<250 { try await a.stage(.upsert(.prompt(UUID()), .prompt(SyncPrompt(text: "p")))) }

        _ = try await a.sync()

        XCTAssertEqual(pushes.map(\.count), [100, 100, 50])
        XCTAssertEqual(service.liveCount, 250)
        let state = await a.currentState
        XCTAssertTrue(state.pending.isEmpty)
    }

    func testInvalidItemIsDroppedAndTheRestPushed() async throws {
        let a = try device()
        let bad = SyncKey.prompt(UUID())
        try await a.stage(.upsert(.prompt(UUID()), .prompt(SyncPrompt(text: "fine"))))
        try await a.stage(.upsert(bad, .prompt(SyncPrompt(text: "the service refuses this one"))))
        try await a.stage(.upsert(.prompt(UUID()), .prompt(SyncPrompt(text: "also fine"))))
        service.pushRefusal = { changes in
            guard let index = changes.firstIndex(where: { $0["id"] as? String == bad.id }) else { return nil }
            return .json(400, ["error": "invalid_item", "index": index, "field": "text"])
        }

        let report = try await a.sync()

        XCTAssertEqual(report.rejected.map(\.change.key), [bad])
        XCTAssertEqual(report.rejected.first?.field, "text")
        XCTAssertEqual(pushes.map(\.count), [3, 2])
        XCTAssertEqual(service.liveCount, 2)
        let state = await a.currentState
        XCTAssertTrue(state.pending.isEmpty)
    }

    func testQuotaKeepsTheQueueAndStillPulls() async throws {
        let a = try device()
        service.write("settings", "ui.theme", body: ["value": "dark"])
        service.pushRefusal = { _ in .error(403, "quota") }
        try await a.stage(.upsert(.prompt(UUID()), .prompt(SyncPrompt(text: "over the cap"))))

        let report = try await a.sync()

        XCTAssertTrue(report.overQuota)
        XCTAssertEqual(report.changed.map(\.key.collection), [.settings])
        let state = await a.currentState
        XCTAssertEqual(state.pending.count, 1)
    }

    func testStateSurvivesARelaunch() async throws {
        let store = InMemorySyncStateStore()
        let a = try device(store: store)
        try await a.stage(.upsert(hostKey, host("persisted")))
        _ = try await a.sync()

        let relaunched = try device(store: store)
        let item = await relaunched.item(hostKey)
        XCTAssertEqual(nickname(item), "persisted")
        let state = await relaunched.currentState
        XCTAssertEqual(state.since, 1)

        try await relaunched.clear()
        XCTAssertNil(try store.loadSyncState())
    }

    func testWireFormatOfAChange() throws {
        let change = try SyncChange.upsert(.share(hostID: "HostAAAAAAAAAAAAAAAAAA", guestID: "GuestAAAAAAAAAAAAAAAAA"),
                                           .share(SyncShare(relay: "https://guest.herdrup.app", hostID: "HostAAAAAAAAAAAAAAAAAA",
                                                            nodePub: String(repeating: "N", count: 43),
                                                            guestID: "GuestAAAAAAAAAAAAAAAAA", agentName: "claude",
                                                            shareGram: true)),
                                           baseRev: 4)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(change)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["collection", "id", "base_rev", "body"])
        XCTAssertEqual(json["collection"] as? String, "shares")
        XCTAssertEqual(json["base_rev"] as? Int, 4)
        let body = try XCTUnwrap(json["body"] as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["relay", "host_id", "node_pub", "guest_id", "agent_name", "share_gram"])

        let decoded = try JSONDecoder().decode(SyncChange.self, from: JSONEncoder().encode(change))
        XCTAssertEqual(decoded, change)
    }

    func testUnknownCollectionsInAPageAreSkipped() throws {
        let page = try JSONDecoder().decode(SyncPage.self, from: Data("""
            {"rev":3,"more":false,"changes":[
              {"collection":"future","id":"x","rev":1,"updated_ms":1,"deleted":false,"body":{"a":1}},
              {"collection":"settings","id":"ui.theme","rev":2,"updated_ms":1,"deleted":false,"body":{"value":"dark"}},
              {"collection":"hosts","id":"6f9619ff-8b86-d011-b42d-00c04fc964ff","rev":3,"updated_ms":1,"deleted":true,"body":null}
            ]}
            """.utf8))
        XCTAssertEqual(page.changes.map(\.key.id), ["ui.theme", "6f9619ff-8b86-d011-b42d-00c04fc964ff"])
        XCTAssertEqual(page.changes.first?.body, .setting(.string("dark")))
        XCTAssertEqual(page.changes.last?.deleted, true)
    }
}
