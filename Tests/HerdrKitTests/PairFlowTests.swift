import Crypto
import Foundation
import XCTest
@testable import HerdrKit

/// A stand-in for AccountService's pair-v1 routes (DESIGN §13) that both devices of one account
/// talk to: the new device N (session "N…") and the approver A (session "A…"). It enforces the
/// rules the protocol leans on: claim → reveal → finish once each, the reveal opening the
/// commit, only the claimant finishing, and a growing envelope seq. Tests bend it to play a
/// compromised service.
final class FakePairService: @unchecked Sendable {
    typealias Reply = AccountServiceStub.Reply

    static let requesterSession = String(repeating: "N", count: 22)
    static let approverSession = String(repeating: "A", count: 22)
    static let requestID = "PairReqAAAAAAAAAAAAAAA"

    private let lock = NSLock()
    let requester = GuestIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    let approver = GuestIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    let requesterName = "MacBook Air"
    let approverName = "Jerry's iPhone"

    private(set) var state = "none"
    private var commit = Data()
    private var sshPub = Data()
    private var nonceT: Data?
    private var nonceB: Data?
    private var envelope: (seq: UInt64, sealed: String)?
    private(set) var pushCapabilities: [String] = []

    /// The S the service lists to approvers; nil is the one N sent. Swapping it is the attack
    /// the commit exists for.
    var listedSSHPub: Data?
    /// The approver key `/v1/pairs/self` names; nil is the claimant's.
    var envelopeApproverPub: Data?
    /// Push registrations answer this status (204 by default).
    var pushStatus = 204

    func install() {
        AccountServiceStub.reset()
        AccountServiceStub.handler = { [self] in handle($0) }
    }

    func session(_ id: String) -> AccountSession {
        makeStubSession(store: InMemoryAccountTokenStore(refreshToken: "r1.\(id).\(Self.pad("refresh"))"))
    }

    private static func pad(_ text: String) -> String { text + String(repeating: "x", count: 43 - text.count) }

    var currentState: String { lock.withLock { state } }

    private func handle(_ request: AccountServiceStub.Request) -> Reply {
        lock.lock(); defer { lock.unlock() }
        if request.path == "/v1/auth/refresh" {
            let presented = request.json["refresh_token"] as? String ?? ""
            let id = presented.split(separator: ".").dropFirst().first.map(String.init) ?? ""
            return .json(200, ["account_id": "AccountAAAAAAAAAAAAAAA", "access_token": "a1.\(id).\(Self.pad("access"))",
                               "access_expires_in": 3600, "refresh_token": presented, "refresh_expires_in": 7_776_000])
        }
        let bearer = request.bearer ?? ""
        let isRequester = bearer.contains(Self.requesterSession)
        let isApprover = bearer.contains(Self.approverSession)
        guard isRequester || isApprover else { return .error(401, "invalid_token") }
        let base = "/v1/approvals/\(Self.requestID)"
        let live = state == "claimed" || state == "revealed"
        // After a cancel every step on the request answers 410 cancelled; GET shows the state.
        if state == "cancelled", request.method != "GET", request.path.hasPrefix(base + "/") {
            return .error(410, "cancelled")
        }
        switch (request.method, request.path) {
        case ("POST", "/v1/approvals"):
            guard isRequester, request.json["kind"] as? String == "pair",
                  let c = Base64URL.decode(request.json["commit"] as? String ?? ""), c.count == 32,
                  let s = Base64URL.decode(request.json["ssh_pub"] as? String ?? ""), s.count == 32
            else { return .error(400, "bad_request") }
            commit = c
            sshPub = s
            state = "waiting"
            nonceT = nil
            nonceB = nil
            envelope = nil
            return .json(201, ["id": Self.requestID, "expires_in": 600])
        case ("GET", "/v1/approvals"):
            guard isApprover, request.query["kind"] == "any" else { return .json(200, ["requests": []]) }
            var listed: [[String: Any]] = [
                ["id": "WebReqAAAAAAAAAAAAAAAA", "kind": "browser", "commit": Base64URL.encode(Data(count: 32)),
                 "browser": ["device_id": "dev_web", "device_pub": Base64URL.encode(Data(count: 32)),
                             "name": "Chrome on macOS", "platform": "web", "created_ms": 1_800_000_000_000],
                 "claimed": "no", "expires_in": 600],
                // A kind this build doesn't know is skipped, not a failed list.
                ["id": "LaterReqAAAAAAAAAAAAAA", "kind": "later", "claimed": "no", "expires_in": 600],
            ]
            if state == "waiting" || live {
                listed.append(["id": Self.requestID, "kind": "pair", "device": device(), "commit": Base64URL.encode(commit),
                               "ssh_pub": Base64URL.encode(listedSSHPub ?? sshPub),
                               "claimed": state == "waiting" ? "no" : "you", "expires_in": 600])
            }
            return .json(200, ["requests": listed])
        case ("GET", base):
            var body: [String: Any] = ["state": state, "expires_in": 600]
            if state != "waiting" {
                body["approver"] = ["device_pub": Base64URL.encode(approver.publicKey), "name": approverName]
            }
            if ["approved", "denied", "expired", "cancelled"].contains(state) { body["outcome_stored"] = true }
            if live, let nonceT { body["nonce_t"] = Base64URL.encode(nonceT) }
            if isApprover {
                body["kind"] = "pair"
                body["ssh_pub"] = Base64URL.encode(listedSSHPub ?? sshPub)
                body["commit"] = Base64URL.encode(commit)
                body["device"] = device()
                if live, let nonceB { body["nonce_b"] = Base64URL.encode(nonceB) }
            }
            return .json(200, body)
        case ("POST", base + "/claim"):
            guard isApprover else { return .error(403, "own_request") }
            guard state == "waiting" else { return .error(409, "already_claimed") }
            nonceT = Base64URL.decode(request.json["nonce_t"] as? String ?? "")
            state = "claimed"
            return .json(200, ["state": "claimed"])
        case ("POST", base + "/reveal"):
            guard isRequester else { return .error(403, "forbidden") }
            guard state == "claimed" else { return .error(409, state == "revealed" ? "already_revealed" : "not_claimed") }
            let nonce = Base64URL.decode(request.json["nonce_b"] as? String ?? "") ?? Data()
            guard (try? PairV1.open(requesterPub: requester.publicKey, sshPub: sshPub, commit: commit, nonceB: nonce)) != nil else {
                state = "denied"
                return .error(400, "reveal_mismatch")
            }
            nonceB = nonce
            state = "revealed"
            return .json(200, ["state": "revealed"])
        case ("POST", base + "/cancel"):
            guard isRequester else { return .error(404, "not_found") }
            guard state == "waiting" || live else { return .error(409, "already_finished") }
            state = "cancelled"
            return .json(200, ["state": "cancelled"])
        case ("POST", base + "/finish"):
            guard isApprover else { return .error(403, "forbidden") }
            let json = request.json
            if json["outcome"] as? String == "denied" {
                guard live else { return .error(409, "already_finished") }
                state = "denied"
                return .json(200, ["state": "denied"])
            }
            guard state == "revealed" else { return .error(409, live ? "not_revealed" : "already_finished") }
            guard let seq = (json["seq"] as? NSNumber)?.uint64Value, seq >= 1, let sealed = json["sealed"] as? String,
                  json["scope"] == nil
            else { return .error(400, "bad_request") }
            envelope = (seq, sealed)
            state = "approved"
            return .json(200, ["state": "approved"])
        case ("PUT", base + "/envelope"):
            guard isApprover, state == "approved", let current = envelope else { return .error(409, "not_approved") }
            guard let seq = (request.json["seq"] as? NSNumber)?.uint64Value, let sealed = request.json["sealed"] as? String
            else { return .error(400, "bad_request") }
            guard seq > current.seq else { return .error(409, "stale_seq") }
            envelope = (seq, sealed)
            return .json(200, ["seq": seq])
        case ("GET", "/v1/pairs/self"):
            guard isRequester else { return .error(403, "forbidden") }
            var body: [String: Any] = ["envelopes": []]
            if state != "none" { body["request"] = ["id": Self.requestID, "state": state, "expires_in": 600] }
            if let envelope {
                body["envelopes"] = [["request_id": Self.requestID, "ssh_pub": Base64URL.encode(sshPub),
                                      "approver_pub": Base64URL.encode(envelopeApproverPub ?? approver.publicKey),
                                      "approver_name": approverName, "seq": envelope.seq, "sealed": envelope.sealed]]
            }
            return .json(200, body)
        case ("PUT", "/v1/devices/self/push"):
            guard pushStatus == 204 else { return .error(pushStatus, "unavailable") }
            pushCapabilities.append(request.json["capability"] as? String ?? "")
            return .noContent
        default:
            return .error(404, "not_found")
        }
    }

    private func device() -> [String: Any] {
        ["device_id": "dev_new", "device_pub": Base64URL.encode(requester.publicKey), "name": requesterName,
         "platform": "macos", "created_ms": 1_800_000_000_000]
    }
}

/// herdr on one machine, as the approver's connection sees it: `ping` with or without
/// `pair_add_key`, and `pair.add_key` that remembers the keys it took.
final class FakePairHerdr: HerdrTransport, @unchecked Sendable {
    private let lock = NSLock()
    let pairAddKey: Bool
    /// `pair.add_key` waits this long first (a machine that doesn't answer).
    var delay: TimeInterval = 0
    private(set) var added: [(key: String, label: String)] = []

    init(pairAddKey: Bool = true) { self.pairAddKey = pairAddKey }

    var keys: [(key: String, label: String)] { lock.withLock { added } }

    func roundTrip(_ requestLine: String) async throws -> String {
        let request = (try? JSONSerialization.jsonObject(with: Data(requestLine.utf8))) as? [String: Any] ?? [:]
        let id = request["id"] as? String ?? "x"
        switch request["method"] as? String {
        case "ping":
            let caps = pairAddKey ? #"{"pair_add_key":true}"# : "{}"
            return #"{"id":"\#(id)","result":{"type":"pong","version":"0.9.\#(pairAddKey ? 9 : 2)","protocol":22,"capabilities":\#(caps)}}"#
        case "pair.add_key":
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            let params = request["params"] as? [String: Any] ?? [:]
            let key = params["public_key"] as? String ?? "", label = params["label"] as? String ?? ""
            let already = lock.withLock { () -> Bool in
                let seen = added.contains { $0.key == key }
                if !seen { added.append((key, label)) }
                return seen
            }
            // herdr stores only [A-Za-z0-9 -_.'] of the label, at most 48, and answers that.
            let stored = String(label.filter { $0.isASCII && ($0.isLetter || $0.isNumber || " -_.'".contains($0)) }.prefix(48))
            return #"{"id":"\#(id)","result":{"type":"pair_key_added","added":\#(!already),"already":\#(already),"fingerprint":"SHA256:x","label":"\#(stored)"}}"#
        default:
            return #"{"id":"\#(id)","error":{"code":"unknown_method","message":""}}"#
        }
    }

    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }

    func machine(_ label: String, hostKey: String = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHostKey") -> PairMachine {
        PairMachine(id: label, label: label, host: "\(label).local", port: 22, user: "jerry", passwordLogin: false) {
            PairLink(client: HerdrClient(transport: self), hostKey: { hostKey }, close: {})
        }
    }
}

final class PairFlowTests: XCTestCase {
    private var service: FakePairService!

    override func setUp() {
        service = FakePairService()
        service.install()
    }

    private func startBoth() async throws -> (PairRequester, PairApproval, String) {
        let requester = try await PairRequester.start(session: service.session(FakePairService.requesterSession),
                                                      identity: service.requester, keyComment: "MacBook Air", poll: fastPoll)
        let approverSession = service.session(FakePairService.approverSession)
        let inbox = try await PairApproval.inbox(session: approverSession)
        XCTAssertEqual(inbox.pairs.map(\.device.name), ["MacBook Air"])
        XCTAssertEqual(inbox.browsers.map(\.browser.name), ["Chrome on macOS"], "one read lists both kinds")
        let approval = try await PairApproval.start(session: approverSession, identity: service.approver,
                                                    request: try XCTUnwrap(inbox.pairs.first), poll: fastPoll)
        async let shown = requester.awaitCode()
        try await approval.awaitReveal()
        let (code, approverName) = try await shown
        XCTAssertEqual(approverName, "Jerry's iPhone")
        return (requester, approval, code)
    }

    /// The whole flow: N asks, A types N's code, adds N's key on the machine that supports it,
    /// and N opens the machine list with the host keys A pinned.
    func testTheApproverAddsTheKeyAndTheNewDeviceOpensTheMachines() async throws {
        let (requester, approval, code) = try await startBoth()
        let wrong = code == "0000" ? "1111" : "0000"
        let miss = try await approval.checkCode(wrong)
        XCTAssertEqual(miss.left, 2)
        let hit = try await approval.checkCode(code)
        XCTAssertTrue(hit.ok)

        let fleet = FakePairHerdr(), old = FakePairHerdr(pairAddKey: false)
        let label = PairMachines.label(requester: "MacBook Air", approver: "Jerry's iPhone")
        let (oldCheck, oldLink) = await PairMachines.check(old.machine("old-pi"))
        XCTAssertEqual(oldCheck, .needsUpdate(version: "0.9.2"))
        XCTAssertNil(oldLink)
        let (fleetCheck, fleetLink) = await PairMachines.check(fleet.machine("fleet-hel1"))
        XCTAssertEqual(fleetCheck, .ready)
        let added = await PairMachines.add(fleet.machine("fleet-hel1"), link: fleetLink,
                                           publicKeyLine: approval.publicKeyLine, label: label)
        let entry = added.machine
        XCTAssertEqual(entry.status, .added)
        // herdr got exactly N's key (S, with no comment) and the label; the label shown is the
        // one herdr stored.
        XCTAssertEqual(fleet.keys.map(\.key), [try XCTUnwrap(PairingKey.publicKeyLine(raw: requester.sshKey.publicKey))])
        XCTAssertEqual(fleet.keys.map(\.label), ["MacBook Air (approved on Jerry's iPhone)"])
        XCTAssertEqual(added.storedLabel, "MacBook Air approved on Jerry's iPhone")
        XCTAssertTrue(old.keys.isEmpty)
        let again = await PairMachines.add(fleet.machine("fleet-hel1"), link: nil,
                                           publicKeyLine: approval.publicKeyLine, label: label)
        XCTAssertEqual(again.machine.status, .already)
        XCTAssertEqual(fleet.keys.count, 1)

        try await approval.approve(PairEnvelope(machines: [entry]))
        let result = try await requester.awaitResult()
        XCTAssertEqual(result.seq, 1)
        XCTAssertEqual(result.approverName, "Jerry's iPhone")
        XCTAssertEqual(result.machines, [entry])
        XCTAssertEqual(result.machines.first?.hostKey, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHostKey")
        // The private half N saves is S's.
        XCTAssertTrue(requester.sshKey.privateKeyPEM.contains("OPENSSH PRIVATE KEY"))
    }

    /// A machine that timed out is tried again from the approver: a second envelope with a
    /// higher seq reaches N, which reads the new status.
    func testTryingAMachineAgainSendsANewerEnvelope() async throws {
        let (requester, approval, code) = try await startBoth()
        _ = try await approval.checkCode(code)
        let box = FakePairHerdr()
        box.delay = 2
        let machine = box.machine("build-box")
        let failed = await PairMachines.add(machine, link: nil, publicKeyLine: approval.publicKeyLine,
                                            label: "x", timeout: 0.2).machine
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.reason, "timed out")
        try await approval.approve(PairEnvelope(machines: [failed]))
        let first = try await requester.awaitResult()
        XCTAssertEqual(first.machines.first?.status, .failed)
        let none = try await requester.newerResult()
        XCTAssertNil(none, "no newer envelope yet")

        box.delay = 0
        let added = await PairMachines.add(machine, link: nil, publicKeyLine: approval.publicKeyLine, label: "x").machine
        XCTAssertEqual(added.status, .added)
        XCTAssertEqual(box.keys.count, 1, "the timed-out call was dropped, not left running")
        try await approval.resend(PairEnvelope(machines: [added]))
        let sentSeq = await approval.sentSeq
        XCTAssertEqual(sentSeq, 2)
        let second = try await requester.newerResult()
        XCTAssertEqual(second?.seq, 2)
        XCTAssertEqual(second?.machines.first?.status, .added)
        let again = try await requester.newerResult()
        XCTAssertNil(again, "seq 2 is taken once")
    }

    /// A service that lists another S than N committed to: A sees the reveal doesn't open the
    /// commit, denies, and N learns it wasn't approved.
    func testASwappedKeyIsDeniedNotApproved() async throws {
        service.listedSSHPub = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let requester = try await PairRequester.start(session: service.session(FakePairService.requesterSession),
                                                      identity: service.requester, keyComment: "x", poll: fastPoll)
        let approverSession = service.session(FakePairService.approverSession)
        let listed = try await PairApproval.inbox(session: approverSession).pairs
        let request = try XCTUnwrap(listed.first)
        let approval = try await PairApproval.start(session: approverSession, identity: service.approver,
                                                    request: request, poll: fastPoll)
        async let shown = requester.awaitCode()
        do {
            try await approval.awaitReveal()
            XCTFail("a swapped key must not reach the code")
        } catch {
            XCTAssertEqual(error as? BrowserApproval.Failure, .tampered)
        }
        _ = try? await shown
        XCTAssertEqual(service.currentState, "denied")
        do {
            _ = try await requester.awaitResult()
            XCTFail("expected denied")
        } catch {
            XCTAssertEqual(error as? PairRequester.Failure, .denied)
        }
    }

    func testThreeWrongCodesDenyTheRequest() async throws {
        let (requester, approval, code) = try await startBoth()
        let wrong = code == "0000" ? "1111" : "0000"
        _ = try await approval.checkCode(wrong)
        _ = try await approval.checkCode(wrong)
        let last = try await approval.checkCode(wrong)
        XCTAssertEqual(last.left, 0)
        XCTAssertTrue(last.denied)
        do {
            _ = try await approval.checkCode(code)
            XCTFail("no code is taken after the third")
        } catch {
            XCTAssertEqual(error as? BrowserApproval.Failure, .ended)
        }
        do {
            _ = try await requester.awaitResult()
            XCTFail("expected denied")
        } catch {
            XCTAssertEqual(error as? PairRequester.Failure, .denied)
        }
    }

    func testApprovingBeforeTheCodeMatchesSendsNothing() async throws {
        let (_, approval, _) = try await startBoth()
        do {
            try await approval.approve(PairEnvelope(machines: []))
            XCTFail("expected not recorded")
        } catch {
            XCTAssertTrue(error is BrowserApproval.NotRecorded, "\(error)")
        }
        XCTAssertEqual(service.currentState, "revealed")
    }

    /// N cancels after A matched the code. A check before adding keys says so; a finish sent
    /// anyway is refused and reported as cancelled, never approved.
    func testACancelledRequestTellsTheApproverAndIsNeverApproved() async throws {
        let (requester, approval, code) = try await startBoth()
        _ = try await approval.checkCode(code)
        try await approval.stillOpen()
        try await requester.cancel()
        XCTAssertEqual(service.currentState, "cancelled")
        do {
            try await approval.approve(PairEnvelope(machines: []))
            XCTFail("expected not recorded")
        } catch let error as BrowserApproval.NotRecorded {
            XCTAssertEqual(error.reason as? BrowserApproval.Failure, .cancelled)
        }
        XCTAssertEqual(service.currentState, "cancelled")
        do {
            try await approval.stillOpen()
            XCTFail("expected cancelled")
        } catch {
            XCTAssertEqual(error as? BrowserApproval.Failure, .cancelled)
        }
        // Cancelling again (the answer was lost) is not an error.
        try await requester.cancel()

        // Another approval of a fresh request: the check alone catches the cancel.
        let (second, secondApproval, secondCode) = try await startBoth()
        _ = try await secondApproval.checkCode(secondCode)
        try await second.cancel()
        do {
            try await secondApproval.stillOpen()
            XCTFail("expected cancelled")
        } catch {
            XCTAssertEqual(error as? BrowserApproval.Failure, .cancelled)
        }
    }

    /// N cancels before revealing: A, waiting for the code, is told it was cancelled.
    func testCancellingBeforeTheCodeEndsTheApproversWait() async throws {
        let requester = try await PairRequester.start(session: service.session(FakePairService.requesterSession),
                                                      identity: service.requester, keyComment: "x", poll: fastPoll)
        let approverSession = service.session(FakePairService.approverSession)
        let listed = try await PairApproval.inbox(session: approverSession).pairs
        let request = try XCTUnwrap(listed.first)
        let approval = try await PairApproval.start(session: approverSession, identity: service.approver,
                                                    request: request, poll: fastPoll)
        try await requester.cancel()
        do {
            try await approval.awaitReveal()
            XCTFail("expected cancelled")
        } catch {
            XCTAssertEqual(error as? BrowserApproval.Failure, .cancelled)
        }
        let inbox = try await PairApproval.inbox(session: approverSession)
        XCTAssertTrue(inbox.pairs.isEmpty, "a cancelled request leaves the list")
    }

    /// An envelope that names another approver than the one N showed its code to is refused,
    /// whatever it holds.
    func testAnEnvelopeFromAnotherApproverIsRefused() async throws {
        let (requester, approval, code) = try await startBoth()
        _ = try await approval.checkCode(code)
        service.envelopeApproverPub = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        try await approval.approve(PairEnvelope(machines: []))
        do {
            _ = try await requester.awaitResult()
            XCTFail("expected tampered")
        } catch {
            XCTAssertEqual(error as? PairRequester.Failure, .tampered)
        }
    }

    /// The push capability is registered once per device and capability, and again when either
    /// changes or the last send failed.
    func testThePushCapabilityIsRegisteredOncePerDeviceAndCapability() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "pair-push-\(UUID().uuidString)"))
        let registration = AccountPushRegistration(session: service.session(FakePairService.approverSession),
                                                   defaults: defaults)
        service.pushStatus = 503
        let failed = await registration.register(capability: "hpr1.one", deviceID: "dev_a")
        XCTAssertFalse(failed)
        service.pushStatus = 204
        let first = await registration.register(capability: "hpr1.one", deviceID: "dev_a")
        let again = await registration.register(capability: "hpr1.one", deviceID: "dev_a")
        XCTAssertTrue(first && again)
        XCTAssertEqual(service.pushCapabilities, ["hpr1.one"])
        _ = await registration.register(capability: "hpr1.two", deviceID: "dev_a")
        _ = await registration.register(capability: "hpr1.two", deviceID: "dev_b")
        XCTAssertEqual(service.pushCapabilities, ["hpr1.one", "hpr1.two", "hpr1.two"])
        await registration.forget()
        _ = await registration.register(capability: "hpr1.two", deviceID: "dev_b")
        XCTAssertEqual(service.pushCapabilities.count, 4)
    }

    /// A push opens its request without a list: the state read carries the keys and commit.
    func testARequestLoadsFromItsIDAlone() async throws {
        _ = try await PairRequester.start(session: service.session(FakePairService.requesterSession),
                                          identity: service.requester, keyComment: "x", poll: fastPoll)
        let request = try await PairApproval.load(session: service.session(FakePairService.approverSession),
                                                  id: FakePairService.requestID)
        XCTAssertEqual(request.device.name, "MacBook Air")
        XCTAssertEqual(request.claimed, "no")
        do {
            _ = try await PairApproval.load(session: service.session(FakePairService.approverSession), id: "Nope")
            XCTFail("expected ended")
        } catch {
            XCTAssertEqual(error as? BrowserApproval.Failure, .ended)
        }
    }
}
