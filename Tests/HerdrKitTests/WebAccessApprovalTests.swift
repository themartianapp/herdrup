import Crypto
import Foundation
import XCTest
@testable import HerdrKit

/// The machines' side of an approval (D1's `desk_web_access.go` in Swift): `owner_access.info`
/// and `owner_access.add` per machine, the skips, the sealed list, and what happens to grants
/// when the report isn't recorded.
final class WebAccessApprovalTests: XCTestCase {
    private var service: FakeApprovalService!
    private var session: AccountSession!
    private let identity = GuestIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    private let hostID = "AQEBAQEBAQEBAQEBAQEBAQ"
    private let nodePub = "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI"

    override func setUp() {
        service = FakeApprovalService()
        service.install()
        session = makeStubSession()
    }

    override func tearDown() {
        AccountServiceStub.reset()
    }

    /// A herdr machine answering owner_access.* the way `kind` says.
    enum Kind { case current, h1, old, windows, otherRelay, refusesAdd, badIdentity }

    private func machine(_ label: String, _ kind: Kind, grantID: String = "AwMDAwMDAwMDAwMDAwMDAw",
                         reachable: Bool = true) -> (WebAccessMachine, RecordingTransport) {
        let host = hostID, node = nodePub
        let transport = RecordingTransport { method, params in
            switch (method, kind) {
            case ("owner_access.info", .old):
                return RecordingTransport.errorReply(code: "invalid_request", message: "unknown variant `owner_access.info`")
            case ("owner_access.info", .windows):
                return RecordingTransport.errorReply(code: "owner_access_unsupported", message: "unix only")
            case ("owner_access.info", _):
                let proto = kind == .h1 ? 1 : 2
                let relay = kind == .otherRelay ? "https://relay.example.com" : "https://guest.herdrup.app/"
                let nodePub = kind == .badIdentity ? node + "AAAA" : node
                return #"{"id":"x","result":{"type":"owner_access_info","protocol":\#(proto),"host_id":"\#(host)","node_pub":"\#(nodePub)","relay_url":"\#(relay)","link":{"state":"off"},"max_ttl_secs":2592000,"scopes":["chat","terminal"],"version":"0.9.\#(proto)"}}"#
            case ("owner_access.add", .refusesAdd):
                return RecordingTransport.errorReply(code: "owner_grant_limit", message: "10 grants")
            case ("owner_access.add", _):
                let scope = params["scope"] as? String ?? ""
                return #"{"id":"x","result":{"type":"owner_access_added","grant":{"grant_id":"\#(grantID)","device_pub":"\#(params["device_pub"] as? String ?? "")","fingerprint":"SHA256:00","device":"x","scope":"\#(scope)","approved_by":"x","created_ms":1,"expires_ms":1802592000999,"revoked":false},"replaced":[]}}"#
            case ("owner_access.remove", _):
                return #"{"id":"x","result":{"type":"owner_access_removed","removed":["\#(grantID)"]}}"#
            default:
                return RecordingTransport.errorReply(code: "unexpected", message: method)
            }
        }
        let open: @Sendable () async throws -> OwnerAccessLink = {
            guard reachable else { throw AccountError.unreachable }
            return OwnerAccessLink(client: HerdrClient(transport: transport), close: {})
        }
        return (WebAccessMachine(id: label, label: label, hostItemID: "item-\(label)", open: open), transport)
    }

    private func approval(seqStore: WebAccessSeqStore = InMemoryWebAccessSeqStore(),
                          now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) })
        async throws -> WebAccessApproval {
        let pending = try await BrowserApproval.pending(session: session)
        let request = try XCTUnwrap(pending.first)
        let approval = try await BrowserApproval.start(session: session, identity: identity, request: request, now: now, poll: fastPoll)
        try await approval.awaitReveal()
        let web = WebAccessApproval(approval: approval, approverName: "Jerry's iPhone",
                                    statement: { host in "jws.for.\(host)" }, seqStore: seqStore, now: now)
        let check = try await web.checkCode(service.code(approverPub: identity.publicKey))
        XCTAssertTrue(check.ok)
        return web
    }

    private func envelope(seq: UInt64) throws -> [String: Any] {
        let finish = try XCTUnwrap(service.lastFinish)
        let plain = try ApproveV1.openEnvelope(browser: service.browser, approverPub: identity.publicKey, seq: seq,
                                               sealed: try XCTUnwrap(finish["sealed"] as? String))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: plain) as? [String: Any])
    }

    func testGrantsEachMachineSkipsTheOthersAndSealsTheList() async throws {
        let (good, goodWire) = machine("dev2306", .current)
        let (h1, h1Wire) = machine("preview-box", .h1)
        let (old, _) = machine("old-vps", .old)
        let (win, _) = machine("win-box", .windows)
        let (relay, _) = machine("self-relay", .otherRelay)
        let (gone, _) = machine("offline", .current, reachable: false)
        let (full, _) = machine("full-box", .refusesAdd)
        let web = try await approval()

        let result = try await web.approve(machines: [good, h1, old, win, relay, gone, full], scope: .terminal, length: .sevenDays)

        XCTAssertEqual(result.granted, ["dev2306"])
        XCTAssertEqual(result.skipped.map(\.reason.rawValue), ["needs_update", "needs_update", "unsupported", "relay_not_allowed", "unreachable"])
        XCTAssertEqual(result.failed.map(\.label), ["full-box"])
        XCTAssertFalse(result.unsure)
        XCTAssertFalse(h1Wire.requests.contains { $0.method == "owner_access.add" }, "no grant below protocol 2")

        let add = try XCTUnwrap(goodWire.requests.first { $0.method == "owner_access.add" })
        XCTAssertEqual(add.params["device_pub"] as? String, Base64URL.encode(service.browserPub))
        XCTAssertEqual(add.params["device_name"] as? String, "Chrome on macOS")
        XCTAssertEqual(add.params["scope"] as? String, "terminal")
        XCTAssertEqual((add.params["ttl_secs"] as? NSNumber)?.intValue, 7 * 86_400)
        XCTAssertEqual(add.params["account_statement"] as? String, "jws.for.\(hostID)")
        XCTAssertEqual(add.params["approved_by"] as? String, "Jerry's iPhone")
        XCTAssertNil(add.params["machine"])

        let finish = try XCTUnwrap(service.lastFinish)
        XCTAssertEqual(finish["outcome"] as? String, "approved")
        XCTAssertEqual(finish["scope"] as? String, "terminal")
        XCTAssertEqual((finish["expires_ms"] as? NSNumber)?.int64Value, (1_800_000_000 + 7 * 86_400) * 1000)
        let seq = try XCTUnwrap((finish["seq"] as? NSNumber)?.uint64Value)
        XCTAssertEqual(seq, 1_800_000_000_000)

        let list = try envelope(seq: seq)
        XCTAssertEqual(list["v"] as? Int, 1)
        XCTAssertEqual((list["seq"] as? NSNumber)?.uint64Value, seq)
        XCTAssertEqual(list["issued_unix"] as? Int, 1_800_000_000)
        XCTAssertEqual(list["approver"] as? String, "Jerry's iPhone")
        let machines = try XCTUnwrap(list["machines"] as? [[String: Any]])
        XCTAssertEqual(machines.count, 1)
        XCTAssertEqual(machines[0]["host_item_id"] as? String, "item-dev2306")
        XCTAssertEqual(machines[0]["label"] as? String, "dev2306")
        XCTAssertEqual(machines[0]["relay"] as? String, "https://guest.herdrup.app")
        XCTAssertEqual(machines[0]["host_id"] as? String, hostID)
        XCTAssertEqual(machines[0]["node_pub"] as? String, nodePub)
        XCTAssertEqual(machines[0]["grant_id"] as? String, "AwMDAwMDAwMDAwMDAwMDAw")
        XCTAssertEqual(machines[0]["scope"] as? String, "terminal")
        XCTAssertEqual(machines[0]["expires_unix"] as? Int, 1_802_592_000)
        let skipped = try XCTUnwrap(list["skipped"] as? [[String: Any]])
        XCTAssertEqual(skipped.map { $0["label"] as? String }, ["preview-box", "old-vps", "win-box", "self-relay", "offline"])
        XCTAssertEqual(skipped[0]["version"] as? String, "0.9.1")
        XCTAssertNil(skipped[1]["version"])
    }

    /// herdr's ids go into the envelope at the lengths its size check counts: a machine that
    /// answers another length gets no grant.
    func testAMalformedRelayIdentityGetsNoGrant() async throws {
        let (bad, wire) = machine("odd-box", .badIdentity)
        let web = try await approval()
        let result = try await web.approve(machines: [bad], scope: .chat, length: .oneDay)
        XCTAssertEqual(result.failed.map(\.label), ["odd-box"])
        XCTAssertFalse(wire.requests.contains { $0.method == "owner_access.add" })
        XCTAssertEqual(service.finishCount, 0)
    }

    func testNoGrantAndNoReportWithoutTheCode() async throws {
        let pending = try await BrowserApproval.pending(session: session)
        let request = try XCTUnwrap(pending.first)
        let approval = try await BrowserApproval.start(session: session, identity: identity, request: request, poll: fastPoll)
        try await approval.awaitReveal()
        let web = WebAccessApproval(approval: approval, approverName: "iPhone", statement: { _ in "jws" },
                                    seqStore: InMemoryWebAccessSeqStore())
        let (good, wire) = machine("dev2306", .current)
        do {
            _ = try await web.approve(machines: [good], scope: .chat, length: .oneDay)
            XCTFail("expected codeNotChecked")
        } catch {
            XCTAssertEqual(error as? BrowserApproval.Failure, .codeNotChecked)
        }
        XCTAssertTrue(wire.requests.isEmpty)
        XCTAssertEqual(service.finishCount, 0)
    }

    func testNoMachineGrantedLeavesTheRequestOpen() async throws {
        let (old, _) = machine("old-vps", .old)
        let web = try await approval()
        let result = try await web.approve(machines: [old], scope: .chat, length: .thirtyDays)
        XCTAssertEqual(result.granted, [])
        XCTAssertEqual(service.finishCount, 0)
        XCTAssertEqual(service.state, "revealed")
    }

    func testAnEndingRequestGetsNoGrants() async throws {
        service.expiresIn = 50
        let (good, wire) = machine("dev2306", .current)
        let web = try await approval()
        do {
            _ = try await web.approve(machines: [good], scope: .chat, length: .oneDay)
            XCTFail("expected ending")
        } catch {
            XCTAssertEqual(error as? BrowserApproval.Failure, .ending)
        }
        XCTAssertTrue(wire.requests.isEmpty)
    }

    func testARefusedReportRemovesTheGrants() async throws {
        let (good, wire) = machine("dev2306", .current)
        let web = try await approval()
        service.finishReplies = [.error(409, "stale_seq")]
        do {
            _ = try await web.approve(machines: [good], scope: .chat, length: .oneDay)
            XCTFail("expected the refusal")
        } catch WebAccessApproval.Failure.problem(let text) {
            XCTAssertTrue(text.hasPrefix("The browser wasn't approved"), text)
        }
        let remove = try XCTUnwrap(wire.requests.last)
        XCTAssertEqual(remove.method, "owner_access.remove")
        XCTAssertEqual(remove.params["grant_id"] as? String, "AwMDAwMDAwMDAwMDAwMDAw")
        let pending = await web.reportPending
        XCTAssertFalse(pending)
    }

    func testALostReportKeepsTheGrantsAndApproveSendsTheSameReportAgain() async throws {
        let (good, wire) = machine("dev2306", .current)
        let web = try await approval()
        service.finishReplies = [.error(500, "internal")]
        let first = try await web.approve(machines: [good], scope: .chat, length: .oneDay)
        XCTAssertTrue(first.unsure)
        XCTAssertNotNil(first.problem)
        let pending = await web.reportPending
        XCTAssertTrue(pending)
        let firstSeq = (service.lastFinish?["seq"] as? NSNumber)?.uint64Value

        // Whatever is chosen now, the same report goes again, with no new grant.
        let adds = wire.requests.filter { $0.method == "owner_access.add" }.count
        let second = try await web.approve(machines: [], scope: .terminal, length: .thirtyDays)
        XCTAssertFalse(second.unsure)
        XCTAssertEqual(second.granted, ["dev2306"])
        XCTAssertEqual((service.lastFinish?["seq"] as? NSNumber)?.uint64Value, firstSeq)
        XCTAssertEqual(service.lastFinish?["scope"] as? String, "chat")
        XCTAssertEqual(wire.requests.filter { $0.method == "owner_access.add" }.count, adds)
        XCTAssertFalse(wire.requests.contains { $0.method == "owner_access.remove" })
    }

    func testDenyAfterALostReportRemovesTheGrants() async throws {
        let (good, wire) = machine("dev2306", .current)
        let web = try await approval()
        service.finishReplies = [.error(500, "internal")]
        _ = try await web.approve(machines: [good], scope: .chat, length: .oneDay)
        try await web.deny()
        XCTAssertEqual(service.lastFinish?["outcome"] as? String, "denied")
        XCTAssertEqual(wire.requests.last?.method, "owner_access.remove")
        let pending = await web.reportPending
        XCTAssertFalse(pending)
    }

    func testDenyAfterTheLostReportWasRecordedSaysSoAndKeepsTheGrants() async throws {
        let (good, wire) = machine("dev2306", .current)
        let web = try await approval()
        service.finishReplies = [.error(500, "internal")]
        service.applyFailedFinish = true
        // The lost finish was recorded, but the read right after still can't tell.
        service.readFailuresAfterFinish = 1
        let result = try await web.approve(machines: [good], scope: .chat, length: .oneDay)
        XCTAssertTrue(result.unsure)
        service.readFailuresAfterFinish = 0
        do {
            try await web.deny()
            XCTFail("expected alreadyApproved")
        } catch {
            XCTAssertEqual(error as? WebAccessApproval.Failure, .alreadyApproved)
        }
        XCTAssertFalse(wire.requests.contains { $0.method == "owner_access.remove" })
    }

    func testDenyAfterAComputedExpiryWithAnUnknownReportKeepsAsking() async throws {
        let (good, wire) = machine("dev2306", .current)
        let web = try await approval()
        service.finishReplies = [.error(500, "internal")]
        _ = try await web.approve(machines: [good], scope: .chat, length: .oneDay)
        service.state = "expired"
        do {
            try await web.deny()
            XCTFail("expected a problem")
        } catch WebAccessApproval.Failure.problem(let text) {
            XCTAssertTrue(text.contains("dev2306"), text)
        }
        XCTAssertFalse(wire.requests.contains { $0.method == "owner_access.remove" })
        // Once the service stores the expiry, nothing can be recorded: the grants go.
        service.outcomeStored = true
        try await web.deny()
        XCTAssertEqual(wire.requests.last?.method, "owner_access.remove")
    }

    func testEachReportTakesAFreshLargerSeq() async throws {
        let store = InMemoryWebAccessSeqStore(WebAccessSeq(approver: Base64URL.encode(identity.publicKey), seq: 1_900_000_000_000))
        let (good, _) = machine("dev2306", .current)
        let web = try await approval(seqStore: store)
        _ = try await web.approve(machines: [good], scope: .chat, length: .oneDay)
        XCTAssertEqual((service.lastFinish?["seq"] as? NSNumber)?.uint64Value, 1_900_000_000_001)
        XCTAssertEqual(try store.load()?.seq, 1_900_000_000_001)
    }

    func testASeqOfAnotherKeyDoesNotCount() async throws {
        let store = InMemoryWebAccessSeqStore(WebAccessSeq(approver: "someone-else", seq: 1_900_000_000_000))
        let (good, _) = machine("dev2306", .current)
        let web = try await approval(seqStore: store)
        _ = try await web.approve(machines: [good], scope: .chat, length: .oneDay)
        XCTAssertEqual((service.lastFinish?["seq"] as? NSNumber)?.uint64Value, 1_800_000_000_000)
    }

    func testTooManyMachinesForOneEnvelopeAreRefusedBeforeAnyGrant() async throws {
        let many = (0..<120).map { machine(String(repeating: "m", count: 60) + "\($0)", .current) }
        let web = try await approval()
        do {
            _ = try await web.approve(machines: many.map(\.0), scope: .chat, length: .oneDay)
            XCTFail("expected tooManyMachines")
        } catch {
            XCTAssertEqual(error as? WebAccessApproval.Failure, .tooManyMachines)
        }
        XCTAssertTrue(many.allSatisfy { $0.1.requests.isEmpty })
    }

    func testOneStepAtATime() async throws {
        let slow = RecordingTransport { _, _ in
            Thread.sleep(forTimeInterval: 0.3)
            return RecordingTransport.errorReply(code: "invalid_request", message: "unknown variant `owner_access.info`")
        }
        let machine = WebAccessMachine(id: "slow", label: "slow", hostItemID: "") {
            OwnerAccessLink(client: HerdrClient(transport: slow), close: {})
        }
        let web = try await approval()
        async let first = web.approve(machines: [machine], scope: .chat, length: .oneDay)
        try await Task.sleep(nanoseconds: 50_000_000)
        do {
            try await web.deny()
            XCTFail("expected busy")
        } catch {
            XCTAssertEqual(error as? WebAccessApproval.Failure, .busy)
        }
        _ = try await first
    }
}
