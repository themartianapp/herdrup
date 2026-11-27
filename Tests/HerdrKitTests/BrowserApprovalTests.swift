import Crypto
import Foundation
import XCTest
@testable import HerdrKit

/// A stand-in for AccountService's approval endpoints (src/approvals.ts) with an honest browser
/// behind it: the browser commits, and reveals once this device claimed. Tests bend it to
/// tamper, refuse, or lose answers.
final class FakeApprovalService: @unchecked Sendable {
    typealias Reply = AccountServiceStub.Reply

    static let requestID = "ReqAAAAAAAAAAAAAAAAAAA"

    private let lock = NSLock()
    let authority = StubAuthority()
    let browser = Curve25519.KeyAgreement.PrivateKey()
    let nonceB = ApproveV1.newNonce()
    let browserName = "Chrome on macOS"

    /// waiting, claimed, revealed, approved, denied or expired.
    var state = "waiting"
    var expiresIn = 600
    /// The browser reveals on this many reads after the claim (0: the first).
    var revealAfterReads = 0
    /// What the browser reveals; nil is its honest `nonce_b`.
    var revealed: Data?
    var outcomeStored = false
    /// Answers to `GET /v1/approvals/<id>` before the state machine's, oldest first.
    var stateReplies: [Reply] = []
    /// Answers to finish, oldest first. `applyFailedFinish`: a 5xx one was still recorded.
    var finishReplies: [Reply] = []
    var applyFailedFinish = false
    /// Answers to claim before the state machine's, oldest first.
    var claimReplies: [Reply] = []
    /// Reads of the request that fail (503) right after each finish.
    var readFailuresAfterFinish = 0
    private var failingReads = 0

    private(set) var nonceT: Data?
    private(set) var finishes: [[String: Any]] = []
    private var reads = 0

    var browserPub: Data { browser.publicKey.rawRepresentation }

    var request: ApprovalRequest {
        ApprovalRequest(
            id: Self.requestID,
            browser: .init(deviceID: "dev_browser", devicePub: Base64URL.encode(browserPub), name: browserName, createdMs: 1_800_000_000_000),
            commit: Base64URL.encode(try! ApproveV1.commit(browserPub: browserPub, nonceB: nonceB)),
            claimed: "no", expiresIn: expiresIn)
    }

    /// The code the browser shows, once it knows this device's key.
    func code(approverPub: Data) -> String {
        try! ApproveV1.code(browserPub: browserPub, approverPub: approverPub, nonceB: nonceB, nonceT: nonceT!)
    }

    var finishCount: Int { lock.withLock { finishes.count } }
    var lastFinish: [String: Any]? { lock.withLock { finishes.last } }

    func install() {
        AccountServiceStub.reset()
        AccountServiceStub.handler = { [self] in handle($0) }
    }

    private func handle(_ request: AccountServiceStub.Request) -> Reply {
        if let refused = authority.handle(request) { return refused }
        lock.lock(); defer { lock.unlock() }
        let base = "/v1/approvals/\(Self.requestID)"
        switch (request.method, request.path) {
        case ("GET", "/v1/approvals"):
            let list = state == "waiting" || state == "claimed" || state == "revealed"
            return .json(200, ["requests": list ? [listed()] : []])
        case ("POST", base + "/claim"):
            if !claimReplies.isEmpty { return claimReplies.removeFirst() }
            guard state == "waiting" else { return .error(409, "already_claimed") }
            nonceT = Base64URL.decode(request.json["nonce_t"] as? String ?? "")
            state = "claimed"
            return .json(200, ["state": "claimed"])
        case ("GET", base):
            if !stateReplies.isEmpty { return stateReplies.removeFirst() }
            if failingReads > 0 {
                failingReads -= 1
                return .error(503, "unavailable")
            }
            if state == "claimed" {
                if reads >= revealAfterReads { state = "revealed" }
                reads += 1
            }
            var body: [String: Any] = ["state": state, "expires_in": expiresIn]
            if state == "revealed" { body["nonce_b"] = Base64URL.encode(revealed ?? nonceB) }
            if outcomeStored { body["outcome_stored"] = true }
            return .json(200, body)
        case ("POST", base + "/finish"):
            let json = request.json
            finishes.append(json)
            failingReads = readFailuresAfterFinish
            let outcome = json["outcome"] as? String
            if !finishReplies.isEmpty {
                let reply = finishReplies.removeFirst()
                if reply.status >= 500, applyFailedFinish, let outcome { state = outcome }
                return reply
            }
            guard state == "revealed" || (outcome == "denied" && state == "claimed") else {
                return state == "expired" ? .error(410, "expired") : .error(409, "already_finished")
            }
            state = outcome ?? state
            return .json(200, ["state": state])
        default:
            return .error(404, "not_found")
        }
    }

    private func listed() -> [String: Any] {
        ["id": Self.requestID,
         "browser": ["device_id": "dev_browser", "device_pub": Base64URL.encode(browserPub), "name": browserName,
                     "platform": "web", "created_ms": 1_800_000_000_000],
         "commit": Base64URL.encode(try! ApproveV1.commit(browserPub: browserPub, nonceB: nonceB)),
         "claimed": state == "waiting" ? "no" : "you", "expires_in": expiresIn]
    }
}

let fastPoll: @Sendable (TimeInterval) -> TimeInterval = { _ in 0.01 }

final class BrowserApprovalTests: XCTestCase {
    private var service: FakeApprovalService!
    private var session: AccountSession!
    private let identity = GuestIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())

    override func setUp() {
        service = FakeApprovalService()
        service.install()
        session = makeStubSession()
    }

    override func tearDown() {
        AccountServiceStub.reset()
    }

    private func started() async throws -> BrowserApproval {
        let requests = try await BrowserApproval.pending(session: session)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request, service.request)
        return try await BrowserApproval.start(session: session, identity: identity, request: request, poll: fastPoll)
    }

    private func revealed() async throws -> BrowserApproval {
        let approval = try await started()
        try await approval.awaitReveal()
        return approval
    }

    func testAnHonestBrowserIsApprovedWithItsCodeAndOpensTheList() async throws {
        service.revealAfterReads = 2
        let approval = try await revealed()
        XCTAssertEqual(service.nonceT?.count, 32)
        let wrong = service.code(approverPub: identity.publicKey) == "0000" ? "0001" : "0000"
        let miss = try await approval.checkCode(wrong)
        XCTAssertEqual(miss, BrowserApproval.CodeCheck(ok: false, left: 2))
        let hit = try await approval.checkCode(service.code(approverPub: identity.publicKey))
        XCTAssertTrue(hit.ok)

        let envelope = Data(#"{"v":1,"seq":9}"#.utf8)
        try await approval.approve(scope: "terminal", expiresMs: 1_802_592_000_000, seq: 9, envelope: envelope)
        let finish = try XCTUnwrap(service.lastFinish)
        XCTAssertEqual(finish["outcome"] as? String, "approved")
        XCTAssertEqual(finish["scope"] as? String, "terminal")
        XCTAssertEqual((finish["expires_ms"] as? NSNumber)?.int64Value, 1_802_592_000_000)
        XCTAssertEqual((finish["seq"] as? NSNumber)?.uint64Value, 9)
        let opened = try ApproveV1.openEnvelope(browser: service.browser, approverPub: identity.publicKey, seq: 9,
                                                sealed: try XCTUnwrap(finish["sealed"] as? String))
        XCTAssertEqual(opened, envelope)
    }

    func testARevealThatDoesNotOpenTheCommitIsDenied() async throws {
        service.revealed = ApproveV1.newNonce()
        let approval = try await started()
        do {
            try await approval.awaitReveal()
            XCTFail("expected tampered")
        } catch {
            XCTAssertEqual(error as? BrowserApproval.Failure, .tampered)
        }
        XCTAssertEqual(service.lastFinish?["outcome"] as? String, "denied")
        do {
            _ = try await approval.checkCode("1234")
            XCTFail("a tampered request takes no code")
        } catch {
            XCTAssertEqual(error as? BrowserApproval.Failure, .ended)
        }
    }

    func testAMalformedRequestIsNeverClaimed() async throws {
        let request = service.request
        let bad = ApprovalRequest(id: request.id, browser: .init(deviceID: "d", devicePub: "short", name: "x", createdMs: 0),
                                  commit: request.commit, claimed: "no", expiresIn: 600)
        do {
            _ = try await BrowserApproval.start(session: session, identity: identity, request: bad)
            XCTFail("expected tampered")
        } catch {
            XCTAssertEqual(error as? BrowserApproval.Failure, .tampered)
        }
        XCTAssertTrue(AccountServiceStub.requests(to: "/v1/approvals/\(request.id)/claim").isEmpty)
    }

    func testARequestClaimedElsewhereHasEnded() async throws {
        service.claimReplies = [.error(409, "already_claimed")]
        do {
            _ = try await started()
            XCTFail("expected ended")
        } catch {
            XCTAssertEqual(error as? BrowserApproval.Failure, .ended)
        }
    }

    func testThreeWrongCodesDenyTheRequest() async throws {
        let approval = try await revealed()
        let right = service.code(approverPub: identity.publicKey)
        let wrong = right == "0000" ? "0001" : "0000"
        _ = try await approval.checkCode(wrong)
        _ = try await approval.checkCode(wrong)
        let last = try await approval.checkCode(wrong)
        XCTAssertEqual(last, BrowserApproval.CodeCheck(ok: false, left: 0, denied: true))
        XCTAssertEqual(service.lastFinish?["outcome"] as? String, "denied")
        do {
            _ = try await approval.checkCode(right)
            XCTFail("no code after the denial")
        } catch {
            XCTAssertEqual(error as? BrowserApproval.Failure, .ended)
        }
    }

    func testNoApprovalBeforeTheCode() async throws {
        let approval = try await revealed()
        do {
            try await approval.ready()
            XCTFail("expected codeNotChecked")
        } catch {
            XCTAssertEqual(error as? BrowserApproval.Failure, .codeNotChecked)
        }
    }

    func testACodeBeforeTheRevealIsRefused() async throws {
        service.revealAfterReads = 1000
        let approval = try await started()
        do {
            _ = try await approval.checkCode("1234")
            XCTFail("expected codeNotShown")
        } catch {
            XCTAssertEqual(error as? BrowserApproval.Failure, .codeNotShown)
        }
    }

    func testABusyServiceDoesNotEndTheWait() async throws {
        let approval = try await started()
        service.stateReplies = [.error(429, "too_many_requests"), .error(503, "unavailable")]
        try await approval.awaitReveal()
        let shown = await approval.codeShown
        XCTAssertTrue(shown)
    }

    func testARequestThatEndsWhileWaitingEndsTheWait() async throws {
        let approval = try await started()
        service.stateReplies = [.error(410, "expired")]
        do {
            try await approval.awaitReveal()
            XCTFail("expected ended")
        } catch {
            XCTAssertEqual(error as? BrowserApproval.Failure, .ended)
        }
    }

    func testTheWaitEndsWhenTheRequestExpires() async throws {
        service.expiresIn = 1
        service.revealAfterReads = 100_000
        let approval = try await started()
        do {
            try await approval.awaitReveal()
            XCTFail("expected expired")
        } catch {
            XCTAssertEqual(error as? BrowserApproval.Failure, .expired)
        }
    }

    private func matched() async throws -> BrowserApproval {
        let approval = try await revealed()
        _ = try await approval.checkCode(service.code(approverPub: identity.publicKey))
        return approval
    }

    func testARequestAboutToExpireTakesNoGrants() async throws {
        service.expiresIn = 30
        let approval = try await matched()
        do {
            _ = try await approval.live(min: 60)
            XCTFail("expected ending")
        } catch {
            XCTAssertEqual(error as? BrowserApproval.Failure, .ending)
        }
    }

    func testARefusedApprovalIsNotRecorded() async throws {
        let approval = try await matched()
        service.finishReplies = [.error(409, "stale_seq")]
        do {
            try await approval.approve(scope: "chat", expiresMs: 1, seq: 1, envelope: Data("{}".utf8))
            XCTFail("expected NotRecorded")
        } catch {
            XCTAssertTrue(error is BrowserApproval.NotRecorded, "\(error)")
        }
    }

    func testALostAnswerThatWasRecordedIsApproved() async throws {
        let approval = try await matched()
        service.finishReplies = [.error(502, "bad_gateway")]
        service.applyFailedFinish = true
        try await approval.approve(scope: "chat", expiresMs: 1, seq: 1, envelope: Data("{}".utf8))
    }

    func testALostAnswerWhileStillRevealedIsUnknownThenSettlesOnRetry() async throws {
        let approval = try await matched()
        service.finishReplies = [.error(500, "internal")]
        do {
            try await approval.approve(scope: "chat", expiresMs: 1, seq: 1, envelope: Data("{}".utf8))
            XCTFail("expected OutcomeUnknown")
        } catch {
            XCTAssertTrue(error is BrowserApproval.OutcomeUnknown, "\(error)")
        }
        // Sent again, now answered: recorded.
        try await approval.approve(scope: "chat", expiresMs: 1, seq: 1, envelope: Data("{}".utf8))
        XCTAssertEqual(service.finishCount, 2)
    }

    /// The account's approval budget is shared by every approval route of every device; once
    /// spent (`429 rate_limited`) the claim and the finish are sent again until they go
    /// through, never ending the approval as refused.
    func testARateLimitedClaimAndFinishAreSentAgainUntilTheyGoThrough() async throws {
        service.claimReplies = [.error(429, "rate_limited"), .error(429, "rate_limited")]
        let approval = try await matched()
        XCTAssertEqual(AccountServiceStub.requests(to: "/v1/approvals/\(FakeApprovalService.requestID)/claim").count, 3)
        service.finishReplies = [.error(429, "rate_limited"), .error(429, "rate_limited")]
        try await approval.approve(scope: "chat", expiresMs: 1, seq: 1, envelope: Data("{}".utf8))
        XCTAssertEqual(service.finishCount, 3)
        XCTAssertEqual(service.lastFinish?["outcome"] as? String, "approved")
    }

    /// A rate limit that says when to come back (`Retry-After`) is waited out that long.
    func testARateLimitWaitsTheServicesRetryAfter() async throws {
        AccountServiceStub.handler = { _ in
            var reply = AccountServiceStub.Reply.error(429, "rate_limited")
            reply.headers = ["Retry-After": "7"]
            return reply
        }
        do {
            _ = try await AccountServiceStub.client().approvals(accessToken: "a")
            XCTFail("expected rate_limited")
        } catch {
            XCTAssertEqual(error as? AccountError, .refused(status: 429, code: "rate_limited", retryAfter: 7))
            XCTAssertEqual(BrowserApproval.backoff(0.01, failures: 1, after: error), 7)
        }
    }

    /// After an unknown outcome, a computed expiry proves nothing (the lost finish may still be
    /// recorded), a stored one does (outcome_stored).
    func testAnExpiryIsFinalOnlyWhenStoredAfterAnUnknownOutcome() async throws {
        let approval = try await matched()
        service.finishReplies = [.error(500, "internal")]
        do {
            try await approval.approve(scope: "chat", expiresMs: 1, seq: 1, envelope: Data("{}".utf8))
        } catch {}
        service.state = "expired"
        let computed = try await approval.outcome()
        XCTAssertEqual(computed.0, .expired)
        XCTAssertFalse(computed.1)
        service.outcomeStored = true
        let stored = try await approval.outcome()
        XCTAssertTrue(stored.1)
        do {
            try await approval.approve(scope: "chat", expiresMs: 1, seq: 1, envelope: Data("{}".utf8))
            XCTFail("expected NotRecorded")
        } catch {
            XCTAssertTrue(error is BrowserApproval.NotRecorded, "\(error)")
        }
    }

    func testAnExpiryWithoutAnyUnknownFinishIsFinal() async throws {
        let approval = try await matched()
        service.state = "expired"
        let read = try await approval.outcome()
        XCTAssertTrue(read.1)
    }

    func testDenyIsTakenOnceAndAnEndedRequestSendsNothing() async throws {
        let approval = try await revealed()
        try await approval.deny()
        try await approval.deny()
        XCTAssertEqual(service.finishCount, 1)
    }

    func testDenyingAnExpiredRequestIsEnded() async throws {
        let approval = try await started()
        service.state = "expired"
        service.finishReplies = [.error(410, "expired")]
        do {
            try await approval.deny()
            XCTFail("expected ended")
        } catch {
            XCTAssertEqual(error as? BrowserApproval.Failure, .ended)
        }
    }
}
