import Crypto
import Foundation
import XCTest
@testable import HerdrKit

/// An `owner_access.add` that was sent but got no answer in time may still have made a grant on
/// that machine, one that is in no envelope. Whatever the approval's outcome, the browser's key
/// is removed there (and a late answer's grant), and the slow machine doesn't hold the approval
/// past its deadline.
final class WebAccessApprovalTimeoutTests: XCTestCase {
    private var service: FakeApprovalService!
    private var session: AccountSession!
    private let identity = GuestIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    private let grantTime: TimeInterval = 0.4

    override func setUp() {
        service = FakeApprovalService()
        service.install()
        session = makeStubSession()
    }

    override func tearDown() {
        AccountServiceStub.reset()
    }

    /// A machine whose `owner_access.add` answers after `addDelay`, whatever cancellation says,
    /// as a stuck SSH channel would.
    private func machine(_ label: String, addDelay: TimeInterval, grantID: String) -> (WebAccessMachine, RecordingTransport) {
        let transport = RecordingTransport { method, params in
            switch method {
            case "owner_access.info":
                return #"{"id":"x","result":{"type":"owner_access_info","protocol":2,"host_id":"AQEBAQEBAQEBAQEBAQEBAQ","node_pub":"AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI","relay_url":"https://guest.herdrup.app","link":{"state":"on"},"max_ttl_secs":2592000,"scopes":["chat","terminal"],"version":"0.9.2"}}"#
            case "owner_access.add":
                Thread.sleep(forTimeInterval: addDelay)
                return #"{"id":"x","result":{"type":"owner_access_added","grant":{"grant_id":"\#(grantID)","device_pub":"\#(params["device_pub"] as? String ?? "")","fingerprint":"SHA256:00","device":"x","scope":"chat","approved_by":"x","created_ms":1,"expires_ms":1802592000000,"revoked":false},"replaced":[]}}"#
            case "owner_access.remove":
                return #"{"id":"x","result":{"type":"owner_access_removed","removed":[]}}"#
            default:
                return RecordingTransport.errorReply(code: "unexpected", message: method)
            }
        }
        let machine = WebAccessMachine(id: label, label: label, hostItemID: "item-\(label)") {
            OwnerAccessLink(client: HerdrClient(transport: transport), close: {})
        }
        return (machine, transport)
    }

    private func approval() async throws -> WebAccessApproval {
        let now: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }
        let pending = try await BrowserApproval.pending(session: session)
        let request = try XCTUnwrap(pending.first)
        let approval = try await BrowserApproval.start(session: session, identity: identity, request: request, now: now, poll: fastPoll)
        try await approval.awaitReveal()
        let web = WebAccessApproval(approval: approval, approverName: "iPhone", statement: { _ in "jws" },
                                    seqStore: InMemoryWebAccessSeqStore(), now: now, grantTime: grantTime)
        let check = try await web.checkCode(service.code(approverPub: identity.publicKey))
        XCTAssertTrue(check.ok)
        return web
    }

    private var browserKey: String { Base64URL.encode(service.browserPub) }

    private func removes(_ wire: RecordingTransport) -> [[String: Any]] {
        wire.requests.filter { $0.method == "owner_access.remove" }.map(\.params)
    }

    /// Waits up to `seconds` for `condition`.
    private func eventually(_ seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    func testASlowAddDoesNotHoldTheApprovalPastItsDeadline() async throws {
        let (slow, _) = machine("slow", addDelay: 1.5, grantID: "AwMDAwMDAwMDAwMDAwMDAw")
        let web = try await approval()
        let started = Date()
        let result = try await web.approve(machines: [slow], scope: .chat, length: .oneDay)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.2, "the add's deadline bounds the machine")
        XCTAssertEqual(result.granted, [])
        XCTAssertEqual(result.failed.map(\.label), ["slow"])
    }

    func testDenyAfterATimedOutAddRemovesTheBrowsersKeyThere() async throws {
        let (slow, wire) = machine("slow", addDelay: 1.0, grantID: "AwMDAwMDAwMDAwMDAwMDAw")
        let web = try await approval()
        _ = try await web.approve(machines: [slow], scope: .chat, length: .oneDay)
        try await web.deny()
        XCTAssertEqual(service.lastFinish?["outcome"] as? String, "denied")
        let key = browserKey
        let removed = await eventually(2) { self.removes(wire).contains { $0["device_pub"] as? String == key } }
        XCTAssertTrue(removed, "Deny removes the browser's key where an add got no answer")
    }

    func testALateAddAnswersGrantIsRemoved() async throws {
        let (slow, wire) = machine("slow", addDelay: 0.8, grantID: "BQUFBQUFBQUFBQUFBQUFBQ")
        let web = try await approval()
        _ = try await web.approve(machines: [slow], scope: .chat, length: .oneDay)
        let removed = await eventually(3) { self.removes(wire).contains { $0["grant_id"] as? String == "BQUFBQUFBQUFBQUFBQUFBQ" } }
        XCTAssertTrue(removed, "the grant a late answer names is in no envelope, so it goes")
    }

    func testARefusedReportRemovesTheSlowMachinesGrantToo() async throws {
        let (fast, fastWire) = machine("fast", addDelay: 0, grantID: "AwMDAwMDAwMDAwMDAwMDAw")
        let (slow, slowWire) = machine("slow", addDelay: 1.0, grantID: "BQUFBQUFBQUFBQUFBQUFBQ")
        let web = try await approval()
        service.finishReplies = [.error(409, "stale_seq")]
        do {
            _ = try await web.approve(machines: [fast, slow], scope: .chat, length: .oneDay)
            XCTFail("expected the refusal")
        } catch {}
        XCTAssertTrue(removes(fastWire).contains { $0["grant_id"] as? String == "AwMDAwMDAwMDAwMDAwMDAw" })
        let key = browserKey
        let removed = await eventually(2) { self.removes(slowWire).contains { $0["device_pub"] as? String == key } }
        XCTAssertTrue(removed, "a refused report removes the browser's key on the unanswered machine too")
    }

    func testARecordedApprovalStillRemovesTheBrowsersKeyOnTheUnansweredMachine() async throws {
        let (fast, fastWire) = machine("fast", addDelay: 0, grantID: "AwMDAwMDAwMDAwMDAwMDAw")
        let (slow, slowWire) = machine("slow", addDelay: 1.0, grantID: "BQUFBQUFBQUFBQUFBQUFBQ")
        let web = try await approval()
        let result = try await web.approve(machines: [fast, slow], scope: .chat, length: .oneDay)
        XCTAssertEqual(result.granted, ["fast"])
        XCTAssertEqual(service.lastFinish?["outcome"] as? String, "approved")
        XCTAssertTrue(removes(fastWire).isEmpty, "the recorded grant stays")
        let key = browserKey
        let removed = await eventually(2) { self.removes(slowWire).contains { $0["device_pub"] as? String == key } }
        XCTAssertTrue(removed, "the unanswered machine is in no envelope, so its grant goes")
    }
}
