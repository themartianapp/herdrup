import XCTest
@testable import HerdrKit

/// `AccountLocalSync` over an in-memory stand-in for the app's stores and `FakeSyncService`:
/// the auth kind follows the secret actually on the device (#776 review F1), and an edit made
/// while a sync waits on the network survives and is pushed by the next round (F2).
@MainActor
final class AccountLocalSyncTests: XCTestCase {
    private var service: FakeSyncService!
    private let delay = PullDelay()

    private let accountID = UUID(uuidString: "6f1d2c3b-0a4e-4c55-9f61-2b7d8e9a0c11")!
    private let localID = UUID(uuidString: "11111111-0000-4000-8000-00000000000a")!

    /// How long `GET /v1/sync` answers take: a pull "held on the network".
    final class PullDelay: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: TimeInterval = 0
        var value: TimeInterval {
            get { lock.lock(); defer { lock.unlock() }; return seconds }
            set { lock.lock(); seconds = newValue; lock.unlock() }
        }
    }

    private var pullDelay: TimeInterval {
        get { delay.value }
        set { delay.value = newValue }
    }

    override func setUp() async throws {
        try await super.setUp()
        AccountServiceStub.reset()
        service = FakeSyncService()
        let service = service!
        let delay = delay
        delay.value = 0
        AccountServiceStub.handler = { request in
            var reply = service.handle(request)
            if request.method == "GET", request.path == "/v1/sync" { reply.delay = delay.value }
            return reply
        }
    }

    override func tearDown() async throws {
        AccountServiceStub.reset()
        try await super.tearDown()
    }

    private func engine() throws -> SyncEngine {
        try SyncEngine(session: makeStubSession(), store: InMemorySyncStateStore())
    }

    private func accountHost(_ id: UUID, host: String = "fleet-hel1", nickname: String = "fleet-hel1",
                             authKind: String?) {
        var body: [String: Any] = ["host": host, "username": "jerry", "nickname": nickname]
        if let authKind { body["auth_kind"] = authKind }
        service.write("hosts", id.uuidString.lowercased(), body: body)
    }

    private func serverAuthKind(_ id: UUID) -> String? {
        service.body("hosts", id.uuidString.lowercased())?["auth_kind"] as? String
    }

    // MARK: F1: a secret stays reachable

    func testAPasswordMachineAdoptingAKeyItemKeepsItsPassword() async throws {
        accountHost(accountID, authKind: "key")
        let store = FakeLocalStore(machines: [
            LocalMachine(id: localID, address: "FLEET-HEL1", username: "jerry", nickname: "fleet", authKind: .password),
        ], passwords: [localID])
        _ = try await AccountLocalSync(engine: engine(), store: store).run()

        let machine = try XCTUnwrap(store.machines.first)
        XCTAssertEqual(machine.id, accountID, "the account's id wins")
        XCTAssertEqual(machine.authKind, .password, "the kind whose store holds the secret stays")
        XCTAssertTrue(store.hasSecret(machine.id, kind: machine.authKind), "the password is still found")
        XCTAssertEqual(serverAuthKind(accountID), "password", "the local kind is pushed back as the newer value")
    }

    func testAPasswordMachineAdoptingAnItemWithoutAuthKindKeepsItsPassword() async throws {
        accountHost(accountID, authKind: nil)
        let store = FakeLocalStore(machines: [
            LocalMachine(id: localID, address: "fleet-hel1", username: "jerry", nickname: nil, authKind: .password),
        ], passwords: [localID])
        _ = try await AccountLocalSync(engine: engine(), store: store).run()

        let machine = try XCTUnwrap(store.machines.first)
        XCTAssertEqual(machine.id, accountID)
        XCTAssertEqual(machine.authKind, .password)
        XCTAssertTrue(store.hasSecret(machine.id, kind: machine.authKind))
        XCTAssertEqual(serverAuthKind(accountID), "password")
    }

    func testAnIDMatchOnTheFirstSyncAfterSignOutKeepsThePassword() async throws {
        // Signed out and in again: the sync state is gone, the machine kept the account's id.
        accountHost(accountID, authKind: "key")
        let store = FakeLocalStore(machines: [
            LocalMachine(id: accountID, address: "fleet-hel1", username: "jerry", nickname: "fleet-hel1", authKind: .password),
        ], passwords: [accountID])
        _ = try await AccountLocalSync(engine: engine(), store: store).run()

        let machine = try XCTUnwrap(store.machines.first)
        XCTAssertEqual(machine.authKind, .password)
        XCTAssertTrue(store.hasSecret(machine.id, kind: machine.authKind))
        XCTAssertEqual(serverAuthKind(accountID), "password")
    }

    func testTheAccountsKindWinsWhenItsSecretIsHere() async throws {
        accountHost(accountID, authKind: "key")
        let store = FakeLocalStore(machines: [
            LocalMachine(id: accountID, address: "fleet-hel1", username: "jerry", nickname: "fleet-hel1", authKind: .password),
        ], keys: [accountID], passwords: [accountID])
        _ = try await AccountLocalSync(engine: engine(), store: store).run()
        XCTAssertEqual(store.machines.first?.authKind, .key)
        XCTAssertEqual(serverAuthKind(accountID), "key")
    }

    func testAuthKindRule() {
        XCTAssertEqual(SyncHostMerge.authKind(account: .key, local: .key, hasSecret: { _ in false }).kind, .key)
        let kept = SyncHostMerge.authKind(account: nil, local: .password, hasSecret: { $0 == .password })
        XCTAssertEqual(kept.kind, .password)
        XCTAssertTrue(kept.pushBack)
        let none = SyncHostMerge.authKind(account: .password, local: .key, hasSecret: { _ in false })
        XCTAssertEqual(none.kind, .password, "no secret here at all: the account's kind")
        XCTAssertFalse(none.pushBack)
    }

    // MARK: F2: an edit during a sync survives

    func testAnEditMadeWhileSyncWaitsOnTheNetworkSurvivesAndIsPushedNext() async throws {
        accountHost(accountID, nickname: "fleet-hel1", authKind: "key")
        let store = FakeLocalStore(machines: [], keys: [])
        let engine = try engine()
        let sync = AccountLocalSync(engine: engine, store: store)
        _ = try await sync.run()
        XCTAssertEqual(store.machines.map(\.nickname), ["fleet-hel1"], "the first sync brought the machine")

        // Another device renames it; this device's next pull is slow, and the person renames
        // the machine here while it waits.
        accountHost(accountID, nickname: "from the other phone", authKind: "key")
        pullDelay = 0.8
        let loop = AccountSyncLoop { _ = try? await sync.run() }
        loop.request()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(loop.isRunning, "the sync is still waiting on the pull")
        var edited = try XCTUnwrap(store.machines.first)
        edited.nickname = "my edit"
        store.putMachine(edited)
        loop.request()
        await loop.waitUntilIdle()

        XCTAssertEqual(store.machines.first?.nickname, "my edit", "the merge left the edit alone")
        XCTAssertEqual(service.body("hosts", accountID.uuidString.lowercased())?["nickname"] as? String, "my edit",
                       "the follow-up round pushed it")
    }

    func testAMachineDeletedDuringASyncIsDeletedOnTheAccountNext() async throws {
        accountHost(accountID, authKind: "key")
        let store = FakeLocalStore(machines: [], keys: [])
        let sync = try AccountLocalSync(engine: engine(), store: store)
        _ = try await sync.run()
        XCTAssertEqual(store.machines.count, 1)

        pullDelay = 0.8
        let loop = AccountSyncLoop { _ = try? await sync.run() }
        loop.request()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(store.removeMachine(accountID))
        loop.request()
        await loop.waitUntilIdle()

        XCTAssertTrue(store.machines.isEmpty, "the delete isn't undone by the merge")
        XCTAssertNil(service.body("hosts", accountID.uuidString.lowercased()), "the next round deleted it on the account")
    }

    func testARequestDuringARunRunsOneMoreRound() async {
        var rounds = 0
        var loop: AccountSyncLoop!
        loop = AccountSyncLoop {
            rounds += 1
            if rounds == 1 {
                loop.request()
                loop.request()
            }
        }
        loop.request()
        await loop.waitUntilIdle()
        XCTAssertEqual(rounds, 2, "requests during a run fold into one more round")
    }
}

/// The app's stores, in memory: machines with which secrets this device holds, and prompts.
@MainActor
final class FakeLocalStore: AccountLocalStore {
    private(set) var machines: [LocalMachine]
    private(set) var prompts: [LocalPrompt] = []
    private var keys: Set<UUID>
    private var passwords: Set<UUID>
    var heldMachineIDs: Set<String> = []
    var heldPromptIDs: Set<String> = []

    init(machines: [LocalMachine], keys: Set<UUID> = [], passwords: Set<UUID> = []) {
        self.machines = machines
        self.keys = keys
        self.passwords = passwords
    }

    func hasSecret(_ id: UUID, kind: SyncHost.AuthKind) -> Bool {
        kind == .key ? keys.contains(id) : passwords.contains(id)
    }

    func putMachine(_ machine: LocalMachine) {
        if let index = machines.firstIndex(where: { $0.id == machine.id }) {
            machines[index] = machine
        } else {
            machines.append(machine)
        }
    }

    func moveMachine(_ id: UUID, to newID: UUID) -> Bool {
        guard let index = machines.firstIndex(where: { $0.id == id }) else { return false }
        machines[index].id = newID
        if keys.remove(id) != nil { keys.insert(newID) }
        if passwords.remove(id) != nil { passwords.insert(newID) }
        return true
    }

    func mergeMachine(_ duplicate: UUID, into kept: UUID) -> Bool {
        machines.removeAll { $0.id == duplicate }
        return true
    }

    func removeMachine(_ id: UUID) -> Bool {
        machines.removeAll { $0.id == id }
        keys.remove(id)
        passwords.remove(id)
        return true
    }

    func setPrompts(_ prompts: [LocalPrompt]) {
        self.prompts = prompts
    }
}
