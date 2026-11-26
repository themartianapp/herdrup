import XCTest
@testable import HerdrKit

/// The guest side of the `shares` collection (#700, DESIGN #698 §5.1): an account-bound share
/// accepted on one device is pushed as its allowlisted fields, listed on the account's other
/// devices with nothing to accept, and leaving it anywhere removes it everywhere. Two devices
/// share one `FakeSyncService`.
@MainActor
final class AccountShareSyncTests: XCTestCase {
    private var service: FakeSyncService!

    private static let hostID = "AAECAwQFBgcICQoLDA0ODw"
    private static let enyoID = "Z3Vlc3QtbmlrZS1lbnlvMQ"
    private static let orgID = "Z3Vlc3QtbmlrZS1vcmdzMQ"
    private static let samID = "Z3Vlc3QtcGxhaW4tc2FtMQ"
    private static let nodePub = "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc"
    private static let endpoint = RelayEndpoint(relay: URL(string: "https://guest.herdrup.app/")!, hostID: hostID,
                                                hostPublicKey: Data(repeating: 7, count: 32))

    override func setUp() async throws {
        try await super.setUp()
        AccountServiceStub.reset()
        service = FakeSyncService()
        let service = service!
        AccountServiceStub.handler = { service.handle($0) }
    }

    override func tearDown() async throws {
        AccountServiceStub.reset()
        try await super.tearDown()
    }

    private func engine() throws -> SyncEngine {
        try SyncEngine(session: makeStubSession(), store: InMemorySyncStateStore())
    }

    private func access(_ guestID: String, agent: String = "enyo", bound: Bool = true) -> GuestAccess {
        GuestAccess(guestID: guestID, guestName: "Nike", machineLabel: "hetzner", ownerName: "jerry",
                    agentName: agent, agentTarget: "term-\(agent)", endpoint: Self.endpoint,
                    acceptedAt: Date(timeIntervalSince1970: 1_795_000_000), accountBound: bound)
    }

    private func item(_ guestID: String, agent: String = "enyo", rev: Int = 1) -> SyncItem {
        SyncItem(key: .share(hostID: Self.hostID, guestID: guestID), rev: rev, updatedMs: 0,
                 body: .share(SyncShare(relay: "https://guest.herdrup.app", hostID: Self.hostID, nodePub: Self.nodePub,
                                        guestID: guestID, agentName: agent, ownerName: "jerry", machineLabel: "hetzner")))
    }

    // MARK: The mapping

    func testAnAccessMapsToTheAllowlistedFieldsAndBack() async throws {
        let share = SyncShare(access(Self.enyoID))
        XCTAssertEqual(share, SyncShare(relay: "https://guest.herdrup.app", hostID: Self.hostID, nodePub: Self.nodePub,
                                        guestID: Self.enyoID, agentName: "enyo", ownerName: "jerry", machineLabel: "hetzner"),
                       "the relay is its canonical base, the node key b64url, no guest name or target")
        // The service's checks, run client-side when staging, take it.
        XCTAssertNoThrow(try SyncChange.upsert(.share(access(Self.enyoID)), .share(share)))

        let listed = try XCTUnwrap(AccountShare(share))
        XCTAssertEqual(listed.id, access(Self.enyoID).id, "a listed share has the id its access will have")
        XCTAssertEqual(listed.endpoint.hostPublicKey, Self.endpoint.hostPublicKey)
        XCTAssertEqual(listed.endpoint.socketURL, Self.endpoint.socketURL)
        XCTAssertEqual([listed.machineLabel, listed.agentName, listed.ownerName], ["hetzner", "enyo", "jerry"])
    }

    func testTheRelayDropsQueryFragmentAndTrailingSlashes() {
        XCTAssertEqual(SyncShare.relayBase(URL(string: "https://relay.example/base//?x=1#f")!), "https://relay.example/base")
        XCTAssertEqual(SyncShare.relayBase(URL(string: "http://127.0.0.1:8787")!), "http://127.0.0.1:8787")
    }

    func testAnItemWithAnUnusableNodeKeyIsNotListed() {
        let bad = SyncShare(relay: "https://guest.herdrup.app", hostID: Self.hostID, nodePub: "short", guestID: Self.enyoID)
        XCTAssertNil(AccountShare(bad))
        let bare = SyncShare(relay: "https://guest.herdrup.app", hostID: Self.hostID, nodePub: Self.nodePub, guestID: Self.enyoID)
        XCTAssertEqual(AccountShare(bare)?.machineLabel, "Shared machine", "labels missing from an item fall back")
    }

    func testTheFirstOpenReplyBecomesAnAccountBoundAccess() async throws {
        let share = try XCTUnwrap(AccountShare(SyncShare(access(Self.enyoID))))
        let reply: [String: Any] = ["ok": true, "guest_id": Self.enyoID, "name": "Nike", "machine_label": "hetzner",
                                    "owner_name": "jerry", "agent": ["name": "enyo", "target": "term_7"]]
        func open(_ reply: [String: Any]) throws -> GuestAccess {
            try GuestSession.access(from: reply, expecting: .init(share), endpoint: share.endpoint,
                                    now: Date(timeIntervalSince1970: 5), accountBound: true)
        }
        let access = try open(reply)
        XCTAssertEqual(access.id, share.id)
        XCTAssertTrue(access.accountBound, "every later hello carries a statement")
        XCTAssertEqual(access.agentTarget, "term_7")
        XCTAssertEqual(access.guestName, "Nike")
        XCTAssertThrowsError(try open(["guest_id": Self.enyoID, "agent": ["target": "term_7"]]),
                             "only the host knows the guest's name")
        var other = reply
        other["guest_id"] = Self.orgID
        XCTAssertThrowsError(try open(other), "a reply for another grant") { XCTAssertEqual($0 as? GuestError, .revoked) }
    }

    // async: a synchronous throwing test of a @MainActor class can't be listed on Linux.
    func testTheHelloLeavesOutWhatItDoesNotCarry() async throws {
        func keys(_ hello: GuestSession.Hello) throws -> Set<String> {
            Set(try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(hello)) as? [String: Any]).keys)
        }
        XCTAssertEqual(try keys(.returning(Self.enyoID, account: nil)), ["v", "guest_id"], "a plain returning hello")
        XCTAssertEqual(try keys(.returning(Self.enyoID, account: "jws", device: "iPad")), ["v", "guest_id", "account", "device"],
                       "an account share's first open here")
    }

    // MARK: The plan

    private static let accountA = "QUNDVF9BQUFBQUFBQUFBQUE"
    private static let accountB = "QUNDVF9CQkJCQkJCQkJCQkI"

    private func ledger(owners: [String: String] = [:], leaves: [String: String] = [:],
                        held: [String: Set<String>] = [:]) -> AccountShareLedger {
        var ledger = AccountShareLedger()
        ledger.owners = owners
        ledger.leaves = leaves
        ledger.held = held
        return ledger
    }

    func testThePlanClaimsAndPushesNewBoundSharesAndIgnoresPlainOnes() {
        let plan = AccountShareSync.plan(local: [access(Self.enyoID), access(Self.samID, agent: "sam", bound: false)],
                                         mirror: AccountShareMirror(live: []), ledger: ledger(), account: Self.accountA)
        XCTAssertEqual(plan.push.map(\.guestID), [Self.enyoID], "only the account-bound share goes to the account")
        XCTAssertEqual(plan.claim, [access(Self.enyoID).id])
        XCTAssertTrue(plan.delete.isEmpty)
        XCTAssertTrue(plan.removeHere.isEmpty)
        XCTAssertTrue(plan.available.isEmpty)
    }

    func testThePlanListsTheAccountsOtherSharesAndRemovesOnesLeftElsewhere() {
        let enyo = access(Self.enyoID)
        // enyo was held in step with this account and its item is gone: left on another
        // device. orgstudio was accepted on another device and isn't here.
        let plan = AccountShareSync.plan(local: [enyo], mirror: AccountShareMirror(live: [item(Self.orgID, agent: "orgstudio")]),
                                         ledger: ledger(owners: [enyo.id: Self.accountA], held: [Self.accountA: [enyo.id]]),
                                         account: Self.accountA)
        XCTAssertEqual(plan.removeHere, [enyo.id])
        XCTAssertTrue(plan.push.isEmpty, "a share left elsewhere is not pushed back")
        XCTAssertEqual(plan.available.map(\.agentName), ["orgstudio"])
    }

    func testThePlanNeverPushesBackAShareTheAccountHoldsAsATombstone() {
        let enyo = access(Self.enyoID)
        // Nothing held (this device's account state is new), but the account deleted it.
        let plan = AccountShareSync.plan(local: [enyo], mirror: AccountShareMirror(live: [], tombstones: [enyo.id]),
                                         ledger: ledger(owners: [enyo.id: Self.accountA]), account: Self.accountA)
        XCTAssertEqual(plan.removeHere, [enyo.id])
        XCTAssertTrue(plan.push.isEmpty)
    }

    func testThePlanDeletesAShareLeftHereAndDoesNotListIt() {
        let enyo = access(Self.enyoID)
        let plan = AccountShareSync.plan(local: [], mirror: AccountShareMirror(live: [item(Self.enyoID)]),
                                         ledger: ledger(leaves: [enyo.id: Self.accountA]), account: Self.accountA)
        XCTAssertEqual(plan.delete, [.share(enyo)])
        XCTAssertTrue(plan.available.isEmpty, "a share just left here doesn't come back as one to open")
        XCTAssertTrue(plan.leavesDone.isEmpty, "done once the account holds the tombstone")
    }

    func testAnotherAccountsShareWaitsForThatAccount() {
        let enyo = access(Self.enyoID)
        let org = access(Self.orgID, agent: "orgstudio")
        // enyo belongs to account A; signed in to B, which holds an item with the same id
        // (it can't in practice, but nothing here may touch A's share either way).
        let plan = AccountShareSync.plan(local: [enyo], mirror: AccountShareMirror(live: [item(Self.orgID, agent: "orgstudio")]),
                                         ledger: ledger(owners: [enyo.id: Self.accountA], leaves: [org.id: Self.accountA],
                                                        held: [Self.accountA: [enyo.id]]),
                                         account: Self.accountB)
        XCTAssertTrue(plan.push.isEmpty, "A's share is not pushed into B")
        XCTAssertTrue(plan.removeHere.isEmpty)
        XCTAssertTrue(plan.claim.isEmpty)
        XCTAssertTrue(plan.delete.isEmpty, "A's leave is not applied to B")
        XCTAssertTrue(plan.leavesDone.isEmpty, "A's leave waits for A")
    }

    func testALeaveRecordsTheSharesAccount() {
        var ledger = AccountShareLedger()
        ledger.claim([access(Self.enyoID).id], account: Self.accountA)
        ledger.claim([access(Self.enyoID).id], account: Self.accountB)
        XCTAssertEqual(ledger.owners, [access(Self.enyoID).id: Self.accountA], "the first account keeps it")
        ledger.left(access(Self.samID, agent: "sam", bound: false))
        ledger.left(access(Self.orgID, agent: "orgstudio"))
        XCTAssertTrue(ledger.leaves.isEmpty, "a plain share, or one no account took, has nothing to delete")
        ledger.left(access(Self.enyoID))
        XCTAssertEqual(ledger.leaves, [access(Self.enyoID).id: Self.accountA])
        XCTAssertTrue(ledger.owners.isEmpty)
    }

    // MARK: Two devices

    private func run(_ engine: SyncEngine, _ store: FakeShareStore,
                     account: String = AccountShareSyncTests.accountA) async throws {
        _ = try await engine.sync()
        try await AccountShareSync(engine: engine, store: store, account: account).run()
    }

    func testAShareAcceptedOnOneDeviceOpensOnTheOtherAndLeavingRemovesItEverywhere() async throws {
        let enyo = access(Self.enyoID)
        let iphone = FakeShareStore(shares: [])
        iphone.add(enyo, account: Self.accountA)
        let mac = FakeShareStore(shares: [])
        let iphoneEngine = try engine()
        let macEngine = try engine()

        try await run(iphoneEngine, iphone)
        let stored = try XCTUnwrap(service.body("shares", enyo.id))
        XCTAssertEqual(stored["machine_label"] as? String, "hetzner")
        XCTAssertNil(stored["guest_name"], "nothing beyond the allowlist is pushed")
        XCTAssertEqual(iphone.ledger.held[Self.accountA], [enyo.id])

        try await run(macEngine, mac)
        XCTAssertEqual(mac.accountShares.map(\.id), [enyo.id], "the Mac lists it with nothing to accept")
        XCTAssertEqual(mac.ledger.held[Self.accountA] ?? [], [], "listed, not held, until it is opened")

        // Opened on the Mac (a first-open hello), then left on the iPhone.
        mac.add(enyo, account: Self.accountA)
        try await run(macEngine, mac)
        XCTAssertTrue(mac.accountShares.isEmpty)
        XCTAssertEqual(mac.ledger.held[Self.accountA], [enyo.id])

        iphone.leave(enyo)
        try await run(iphoneEngine, iphone)
        XCTAssertNil(service.body("shares", enyo.id), "leaving tombstones the item")
        XCTAssertEqual(iphone.ledger, AccountShareLedger().with(held: [Self.accountA: []]), "the leave is done")

        try await run(macEngine, mac)
        XCTAssertTrue(mac.shares.isEmpty, "the tombstone takes it off the Mac too")
        XCTAssertEqual(mac.removedElsewhere, [enyo.id])
        XCTAssertTrue(mac.accountShares.isEmpty)
        XCTAssertEqual(mac.ledger.held[Self.accountA], [])
    }

    func testAShareLeftWhileTheRunWaitsIsDeletedByTheNextRun() async throws {
        let enyo = access(Self.enyoID)
        let store = FakeShareStore(shares: [])
        store.add(enyo, account: Self.accountA)
        let engine = try engine()
        try await run(engine, store)
        XCTAssertNotNil(service.body("shares", enyo.id))

        // Left between the plan and the end of the run: the leave waits in the ledger.
        store.onSetAccountShares = { store.leave(enyo) }
        try await run(engine, store)
        XCTAssertEqual(store.ledger.leaves, [enyo.id: Self.accountA])
        store.onSetAccountShares = nil
        try await run(engine, store)
        XCTAssertNil(service.body("shares", enyo.id))
        XCTAssertTrue(store.ledger.leaves.isEmpty)
        XCTAssertTrue(store.accountShares.isEmpty, "never listed as one to open")
    }

    // MARK: Sign-out between holding and leaving (#849 review F1)

    /// A sign-out clears the sync state (a new engine here) and the list of the account's
    /// shares, never the ledger.
    private func signOut(_ store: FakeShareStore) throws -> SyncEngine {
        store.accountShares = []
        return try engine()
    }

    func testAShareLeftElsewhereWhileSignedOutIsNotPushedBack() async throws {
        let enyo = access(Self.enyoID)
        let iphone = FakeShareStore(shares: [])
        iphone.add(enyo, account: Self.accountA)
        let mac = FakeShareStore(shares: [])
        mac.add(enyo, account: Self.accountA)
        var iphoneEngine = try engine()
        let macEngine = try engine()
        try await run(iphoneEngine, iphone)
        try await run(macEngine, mac)

        iphoneEngine = try signOut(iphone)
        mac.leave(enyo)
        try await run(macEngine, mac)
        XCTAssertNil(service.body("shares", enyo.id))

        try await run(iphoneEngine, iphone)
        XCTAssertNil(service.body("shares", enyo.id), "the account's tombstone wins over the share here")
        XCTAssertTrue(iphone.shares.isEmpty, "left on the Mac, so it leaves the iPhone")
        try await run(macEngine, mac)
        XCTAssertTrue(mac.accountShares.isEmpty, "the Mac doesn't list it again")
    }

    func testAShareLeftElsewhereIsNotPushedBackAfterItsTombstoneIsPruned() async throws {
        let enyo = access(Self.enyoID)
        let iphone = FakeShareStore(shares: [])
        iphone.add(enyo, account: Self.accountA)
        var iphoneEngine = try engine()
        try await run(iphoneEngine, iphone)

        iphoneEngine = try signOut(iphone)
        service.write("shares", enyo.id, body: nil)
        service.pruneTombstones()

        try await run(iphoneEngine, iphone)
        XCTAssertNil(service.body("shares", enyo.id), "held in step with this account before, gone now: left elsewhere")
        XCTAssertTrue(iphone.shares.isEmpty)
    }

    func testAShareLeftWhileSignedOutLeavesTheAccountAtTheNextSignIn() async throws {
        let enyo = access(Self.enyoID)
        let iphone = FakeShareStore(shares: [])
        iphone.add(enyo, account: Self.accountA)
        let mac = FakeShareStore(shares: [])
        mac.add(enyo, account: Self.accountA)
        var iphoneEngine = try engine()
        let macEngine = try engine()
        try await run(iphoneEngine, iphone)
        try await run(macEngine, mac)

        iphoneEngine = try signOut(iphone)
        iphone.leave(enyo)
        XCTAssertEqual(iphone.ledger.leaves, [enyo.id: Self.accountA], "kept for the next sign-in")

        try await run(iphoneEngine, iphone)
        XCTAssertNil(service.body("shares", enyo.id), "the leave reaches the account at the sign-in")
        XCTAssertTrue(iphone.accountShares.isEmpty, "and the share isn't listed here again")
        XCTAssertTrue(iphone.ledger.leaves.isEmpty)
        try await run(macEngine, mac)
        XCTAssertTrue(mac.shares.isEmpty, "it leaves the Mac too")
    }

    func testALeaveWaitsForItsOwnAccount() async throws {
        let enyo = access(Self.enyoID)
        let iphone = FakeShareStore(shares: [])
        iphone.add(enyo, account: Self.accountA)
        var iphoneEngine = try engine()
        try await run(iphoneEngine, iphone)

        iphoneEngine = try signOut(iphone)
        iphone.leave(enyo)
        // Signed in to account B (the fake service stands in for it): nothing of A's is touched.
        try await run(iphoneEngine, iphone, account: Self.accountB)
        XCTAssertNotNil(service.body("shares", enyo.id))
        XCTAssertEqual(iphone.ledger.leaves, [enyo.id: Self.accountA], "the leave still waits for A")
    }
}

extension AccountShareLedger {
    fileprivate func with(held: [String: Set<String>]) -> AccountShareLedger {
        var copy = self
        copy.held = held
        return copy
    }
}

/// The app's `SharedMachinesStore` and the account's claim, in memory.
@MainActor
final class FakeShareStore: AccountShareStore {
    var shares: [GuestAccess]
    var accountShares: [AccountShare] = []
    var ledger = AccountShareLedger()
    var removedElsewhere: Set<String> = []
    var onSetAccountShares: (() -> Void)?

    init(shares: [GuestAccess]) { self.shares = shares }

    /// Accepted with the account, or opened from it, while signed in to `account`.
    func add(_ access: GuestAccess, account: String) {
        shares.append(access)
        ledger.claim([access.id], account: account)
    }

    func leave(_ access: GuestAccess) {
        shares.removeAll { $0.id == access.id }
        ledger.left(access)
    }

    func removeLeftElsewhere(_ ids: Set<String>) {
        removedElsewhere.formUnion(ids)
        shares.removeAll { ids.contains($0.id) }
    }

    func setAccountShares(_ shares: [AccountShare]) {
        accountShares = shares
        onSetAccountShares?()
    }
}
