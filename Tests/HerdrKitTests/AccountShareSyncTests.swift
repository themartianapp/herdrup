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
        let access = try GuestSession.access(from: reply, share: share, now: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(access.id, share.id)
        XCTAssertTrue(access.accountBound, "every later hello carries a statement")
        XCTAssertEqual(access.agentTarget, "term_7")
        XCTAssertEqual(access.guestName, "Nike")
        XCTAssertThrowsError(try GuestSession.access(from: ["guest_id": Self.enyoID], share: share, now: Date()))
    }

    // MARK: The plan

    func testThePlanPushesNewBoundSharesAndIgnoresPlainOnes() {
        let plan = AccountShareSync.plan(local: [access(Self.enyoID), access(Self.samID, agent: "sam", bound: false)],
                                         mirror: [], held: [])
        XCTAssertEqual(plan.push.map(\.guestID), [Self.enyoID], "only the account-bound share goes to the account")
        XCTAssertTrue(plan.delete.isEmpty)
        XCTAssertTrue(plan.removeHere.isEmpty)
        XCTAssertTrue(plan.available.isEmpty)
    }

    func testThePlanListsTheAccountsOtherSharesAndRemovesOnesLeftElsewhere() {
        let enyo = access(Self.enyoID)
        // enyo was held in step and its item is gone: left on another device. orgstudio was
        // accepted on another device and isn't here.
        let plan = AccountShareSync.plan(local: [enyo], mirror: [item(Self.orgID, agent: "orgstudio")], held: [enyo.id])
        XCTAssertEqual(plan.removeHere, [enyo.id])
        XCTAssertTrue(plan.push.isEmpty, "a share left elsewhere is not pushed back")
        XCTAssertEqual(plan.available.map(\.agentName), ["orgstudio"])
    }

    func testThePlanDeletesAShareLeftHereAndDoesNotListIt() {
        let enyo = access(Self.enyoID)
        let plan = AccountShareSync.plan(local: [], mirror: [item(Self.enyoID)], held: [enyo.id])
        XCTAssertEqual(plan.delete, [.share(enyo)])
        XCTAssertTrue(plan.available.isEmpty, "a share just left here doesn't come back as one to open")
    }

    // MARK: Two devices

    func testAShareAcceptedOnOneDeviceOpensOnTheOtherAndLeavingRemovesItEverywhere() async throws {
        let iphone = FakeShareStore(shares: [access(Self.enyoID)])
        let mac = FakeShareStore(shares: [])
        let iphoneEngine = try engine()
        let macEngine = try engine()

        _ = try await iphoneEngine.sync()
        try await AccountShareSync(engine: iphoneEngine, store: iphone).run()
        let stored = try XCTUnwrap(service.body("shares", "\(Self.hostID)/\(Self.enyoID)"))
        XCTAssertEqual(stored["machine_label"] as? String, "hetzner")
        XCTAssertNil(stored["guest_name"], "nothing beyond the allowlist is pushed")
        XCTAssertEqual(iphone.heldShareIDs, [access(Self.enyoID).id])

        _ = try await macEngine.sync()
        try await AccountShareSync(engine: macEngine, store: mac).run()
        XCTAssertEqual(mac.accountShares.map(\.id), [access(Self.enyoID).id], "the Mac lists it with nothing to accept")
        XCTAssertTrue(mac.heldShareIDs.isEmpty, "listed, not held, until it is opened")

        // Opened on the Mac (a first-open hello), then left on the iPhone.
        mac.shares = [access(Self.enyoID)]
        _ = try await macEngine.sync()
        try await AccountShareSync(engine: macEngine, store: mac).run()
        XCTAssertTrue(mac.accountShares.isEmpty)
        XCTAssertEqual(mac.heldShareIDs, [access(Self.enyoID).id])

        iphone.shares = []
        _ = try await iphoneEngine.sync()
        try await AccountShareSync(engine: iphoneEngine, store: iphone).run()
        XCTAssertNil(service.body("shares", "\(Self.hostID)/\(Self.enyoID)"), "leaving tombstones the item")
        XCTAssertTrue(iphone.heldShareIDs.isEmpty)

        _ = try await macEngine.sync()
        try await AccountShareSync(engine: macEngine, store: mac).run()
        XCTAssertTrue(mac.shares.isEmpty, "the tombstone takes it off the Mac too")
        XCTAssertEqual(mac.removedElsewhere, [access(Self.enyoID).id])
        XCTAssertTrue(mac.accountShares.isEmpty)
        XCTAssertTrue(mac.heldShareIDs.isEmpty)
    }

    func testAShareLeftWhileTheRunWaitsIsDeletedByTheNextRun() async throws {
        let enyo = access(Self.enyoID)
        let store = FakeShareStore(shares: [enyo])
        let engine = try engine()
        try await AccountShareSync(engine: engine, store: store).run()
        XCTAssertEqual(store.heldShareIDs, [enyo.id])

        // Left between the plan and the end of the run: still held, so the next run deletes it.
        store.onSetAccountShares = { store.shares = [] }
        try await AccountShareSync(engine: engine, store: store).run()
        XCTAssertEqual(store.heldShareIDs, [enyo.id])
        store.onSetAccountShares = nil
        try await AccountShareSync(engine: engine, store: store).run()
        XCTAssertNil(service.body("shares", enyo.id))
        XCTAssertTrue(store.accountShares.isEmpty, "never listed as one to open")
    }
}

@MainActor
final class FakeShareStore: AccountShareStore {
    var shares: [GuestAccess]
    var accountShares: [AccountShare] = []
    var heldShareIDs: Set<String> = []
    var removedElsewhere: Set<String> = []
    var onSetAccountShares: (() -> Void)?

    init(shares: [GuestAccess]) { self.shares = shares }

    func removeLeftElsewhere(_ ids: Set<String>) {
        removedElsewhere.formUnion(ids)
        shares.removeAll { ids.contains($0.id) }
    }

    func setAccountShares(_ shares: [AccountShare]) {
        accountShares = shares
        onSetAccountShares?()
    }
}
