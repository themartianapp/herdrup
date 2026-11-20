import XCTest
@testable import HerdrKit

/// The host identity rule and the merge iOS runs after each pull (DESIGN #698 §5.5, the same
/// cases as herdrup-desktop's `internal/account/hosts_test.go`).
final class SyncHostMergeTests: XCTestCase {
    private let idA = "aaaaaaaa-0000-4000-8000-000000000001"
    private let idB = "bbbbbbbb-0000-4000-8000-000000000002"
    private let idC = "cccccccc-0000-4000-8000-000000000003"
    private let idL = "11111111-0000-4000-8000-00000000000a"
    private let idM = "22222222-0000-4000-8000-00000000000b"

    private func item(_ id: String, rev: Int, host: String, user: String = "jerry", port: Int? = nil,
                      nickname: String? = nil) -> SyncItem {
        SyncItem(key: SyncKey(.hosts, id), rev: rev, updatedMs: 0,
                 body: .host(SyncHost(nickname: nickname, host: host, port: port, username: user)))
    }

    private func local(_ id: String, host: String, user: String = "jerry", port: Int? = nil,
                       nickname: String? = nil) -> SyncHostMerge.Local {
        SyncHostMerge.Local(id: id, body: SyncHost(nickname: nickname, host: host, port: port, username: user))
    }

    func testIdentityLowercasesTheHostDropsATrailingDotAndDefaultsThePort() {
        let typed = SyncHostIdentity(SyncHost(nickname: "Studio", host: "Mac-Studio.Local.", username: "jerry",
                                              authKind: .key, label: "desk"))
        let plain = SyncHostIdentity(SyncHost(host: "mac-studio.local", port: 22, username: "jerry", authKind: .password))
        XCTAssertEqual(typed, plain, "nickname, label and auth kind are not part of the identity")
        XCTAssertNotEqual(plain, SyncHostIdentity(SyncHost(host: "mac-studio.local", username: "Jerry")),
                          "the username is compared exactly as typed")
        XCTAssertNotEqual(plain, SyncHostIdentity(SyncHost(host: "mac-studio.local", port: 2222, username: "jerry")))
    }

    func testALocalDuplicateWithAnotherIDAdoptsTheAccountsID() {
        let plan = SyncHostMerge.plan(
            local: [local(idL, host: "mac-studio.local", nickname: "studio")],
            mirror: [item(idA, rev: 3, host: "Mac-Studio.local.", nickname: "Mac Studio"),
                     item(idB, rev: 4, host: "fleet-hel1")],
            known: [])
        XCTAssertEqual(plan.adopt, [0: idA], "remote wins: the local machine takes the account's id")
        XCTAssertEqual(plan.push, [])
        XCTAssertEqual(plan.added, [idB], "the account's other machine is new here")
        XCTAssertEqual(plan.delete, [])
    }

    func testUnmatchedLocalMachinesArePushedUnderTheirOwnIDs() {
        let plan = SyncHostMerge.plan(local: [local(idL, host: "build-box", user: "ci"), local(idM, host: "pi")],
                                      mirror: [item(idA, rev: 1, host: "fleet-hel1")], known: [])
        XCTAssertEqual(plan.push, [0, 1])
        XCTAssertEqual(plan.added, [idA])
    }

    func testTwoAccountItemsWithOneIdentityKeepTheLowerRev() {
        let plan = SyncHostMerge.plan(
            local: [local(idC, host: "fleet-hel1")],
            mirror: [item(idB, rev: 9, host: "FLEET-HEL1"), item(idA, rev: 2, host: "fleet-hel1.")],
            known: [idA, idB])
        XCTAssertEqual(plan.delete, [idB], "the higher rev is tombstoned")
        XCTAssertEqual(plan.adopt, [0: idA])
        XCTAssertEqual(plan.added, [])
    }

    func testAMachineOnTheDeletedForkMovesToTheKeptItem() {
        let plan = SyncHostMerge.plan(
            local: [local(idB, host: "fleet-hel1")],
            mirror: [item(idA, rev: 2, host: "fleet-hel1"), item(idB, rev: 5, host: "fleet-hel1")],
            known: [idA, idB])
        XCTAssertEqual(plan.delete, [idB])
        XCTAssertEqual(plan.adopt, [0: idA])
    }

    func testASecondLocalCopyOfAMachineMergesIntoTheOneHoldingTheItem() {
        // A machine synced here (idA, no key) and the same machine paired here again (idL).
        let plan = SyncHostMerge.plan(
            local: [local(idA, host: "fleet-hel1", nickname: "fleet"), local(idL, host: "FLEET-HEL1:22")],
            mirror: [item(idA, rev: 2, host: "fleet-hel1")], known: [idA])
        XCTAssertEqual(plan.matched, [0])
        XCTAssertEqual(plan.duplicates, [1: 0], "the second copy is merged, not pushed as a fork")
        XCTAssertEqual(plan.push, [])
        XCTAssertEqual(plan.gone, [])
    }

    func testACopyOnTheDeletedForkMergesWhenTheKeptItemIsTaken() {
        let plan = SyncHostMerge.plan(
            local: [local(idA, host: "fleet-hel1"), local(idB, host: "fleet-hel1")],
            mirror: [item(idA, rev: 2, host: "fleet-hel1"), item(idB, rev: 5, host: "fleet-hel1")],
            known: [idA, idB])
        XCTAssertEqual(plan.delete, [idB])
        XCTAssertEqual(plan.matched, [0])
        XCTAssertEqual(plan.duplicates, [1: 0])
        XCTAssertEqual(plan.gone, [])
    }
    func testAMatchingIDIsTheSameMachineAfterARename() {
        let plan = SyncHostMerge.plan(local: [local(idA, host: "new-name")],
                                      mirror: [item(idA, rev: 7, host: "old-name")], known: [idA])
        XCTAssertEqual(plan.matched, [0])
        XCTAssertEqual(plan.adopt, [:])
        XCTAssertEqual(plan.gone, [])
    }

    func testAKnownIDTheAccountNoLongerHoldsWasDeletedElsewhere() {
        let plan = SyncHostMerge.plan(local: [local(idA, host: "gone-box"), local(idL, host: "fresh-box")],
                                      mirror: [], known: [idA])
        XCTAssertEqual(plan.gone, [0])
        XCTAssertEqual(plan.push, [1])
    }

    func testTombstonesAndOtherCollectionsAreNotMachines() {
        let tombstone = SyncItem(key: SyncKey(.hosts, idA), rev: 4, updatedMs: 0, body: nil)
        let prompt = SyncItem(key: SyncKey(.prompts, idB), rev: 5, updatedMs: 0, body: .prompt(SyncPrompt(text: "hi")))
        let plan = SyncHostMerge.plan(local: [local(idA, host: "box")], mirror: [tombstone, prompt], known: [idA])
        XCTAssertEqual(plan.gone, [0])
        XCTAssertEqual(plan.added, [])
    }
}

final class AccountHealthTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AccountServiceStub.reset()
    }

    override func tearDown() {
        AccountServiceStub.reset()
        super.tearDown()
    }

    func testHealthListsTheDeploymentsFeatures() async throws {
        AccountServiceStub.handler = { request in
            guard request.method == "GET", request.path == "/v1/health" else { return .error(404, "not_found") }
            return .json(200, ["ok": true, "version": "0.5.1",
                               "features": ["native_sign_in", "native_sign_in_google", "sync"]])
        }
        let health = try await AccountServiceStub.client().health()
        XCTAssertEqual(health.version, "0.5.1")
        XCTAssertTrue(health.offers(AccountHealth.nativeSignIn))
        XCTAssertTrue(health.offers(AccountHealth.nativeSignInGoogle))
        XCTAssertFalse(health.offers("web_sign_in_google"))
        XCTAssertNil(AccountServiceStub.requests(to: "/v1/health").first?.authorization, "health takes no token")
    }
}
