#if DEBUG
import CryptoKit
import Foundation
import HerdrKit
import SwiftUI

/// The HerdrUp account screens over a stand-in account service (`HERDR_SCREENSHOT_MOCK=account`).
/// The real `AccountClient` talks to it through a `URLProtocol`, so `AccountSession`,
/// `DeviceEnroller`, `SyncEngine` and the app's merge run exactly as against
/// accounts.herdrup.app; only Apple's sheet and Google's page are replaced, since neither can
/// run in a UI test. Every token and key here is a made-up fixture.
///
/// Launch environment:
/// - `HERDR_MOCK_ACCOUNT_FEATURES`: `/v1/health`'s features, comma-separated. Default
///   `native_sign_in,devices,statements,sync,delete` (Apple only; add `native_sign_in_google`).
/// - `HERDR_MOCK_ACCOUNT_SIGNED_IN=1`: start signed in with Apple, this device enrolled.
/// - `HERDR_MOCK_ACCOUNT_ENROL`: `device_in_other_account` or `too_many_devices` refuses the
///   enrolment with that code.
/// - `HERDR_MOCK_ACCOUNT_MANUAL_REVOKE=1`: deletion answers `manual_revoke: true`.
/// - `HERDR_MOCK_ACCOUNT_STORED_HINT`: the display hint already stored beside the session from an
///   earlier launch (Google's `display_hint`), as a relaunch finds it. The app restores it with
///   a stored session and deletes it without one. The root's `fixture-stored-hint` element
///   reads the stored value back ("none" when there is none).
/// - `HERDR_MOCK_ACCOUNT_PROFILE_ONLY=1`: the profile is stored but the refresh token isn't (a
///   sign-out killed half-way), which is signed out.
/// - `HERDR_MOCK_ACCOUNT_SYNC_OFFLINE=1`: sync can't reach the service (a quiet failure), so
///   the account needs attention.
/// - `HERDR_MOCK_ACCOUNT_APPROVAL=1`: the service offers `web_approve`, and a browser ("Chrome on
///   macOS") waits for approval; it reveals as soon as this device claims. The sheet's
///   `fixture-browser-code` element reads the code the browser shows. The machines are
///   `OwnerAccessMock`'s.
/// - `HERDR_MOCK_ACCOUNT_PAIR`: the service offers `pair_v1`. `approver`: a new device ("MacBook
///   Air") asks to be paired; the sheet's `fixture-pair-code` reads the code it shows and
///   `fixture-pair-envelope` what it opens; the machines are `PairMachinesMock`'s. `new`: this
///   device asks, and a mock approver ("Jerry's iPhone") claims, approves and retries build-box
///   (`HERDR_MOCK_PAIR_OUTCOME=denied` denies); `fixture-pair-expected-code` reads its code.
///   `HERDR_MOCK_PAIR_UNREACHABLE`: hosts the reachability probe says no to (comma-separated).
///   `HERDR_MOCK_PAIR_CANCEL=1` (approver): the new device cancels while the code is typed.
/// - `HERDR_MOCK_ACCOUNT_SHARES`: `enyo` or `several`, the account holds guest shares accepted
///   on another device (and no machines); SHARED WITH YOU lists them, and a row opens them
///   with `GuestMockTransport.firstOpen` into the machine's guest home.
/// - Saved machines on this device: the `-dev.herdr.savedHosts.v1` launch argument
///   (SavedHostMissingSecretTests' pattern); mock runs never write the saved list.
///
/// The account starts with three machines: "Mac Studio" (jerry@mac-studio.local),
/// "fleet-hel1" (jerry@fleet-hel1) and an older fork of fleet-hel1 (`FLEET-HEL1.`, a higher
/// rev) that the merge tombstones, plus one prompt.
final class MockAccountService: AccountProviderSignIn, @unchecked Sendable {
    static let shared = MockAccountService()

    static let macStudioID = "6f1d2c3b-0a4e-4c55-9f61-2b7d8e9a0c11"
    static let fleetID = "8a2b3c4d-5e6f-4a1b-8c2d-3e4f5a6b7c8d"
    static let fleetForkID = "9c3d4e5f-6a7b-4c8d-9e0f-1a2b3c4d5e6f"
    static let promptID = "0b1c2d3e-4f5a-4b6c-8d7e-9f0a1b2c3d4e"
    static let otherDeviceID = "dev_mock_other_macbook"

    let client: AccountClient
    let tokenStore: InMemoryAccountTokenStore
    let defaults: UserDefaults
    let server = MockAccountServer()
    /// The display hint beside the session, seeded from `HERDR_MOCK_ACCOUNT_STORED_HINT`.
    let hintStore: InMemoryAccountHintStore
    /// `HERDR_MOCK_ACCOUNT_SYNC_OFFLINE=1`.
    let syncOffline: Bool

    private init() {
        let env = ProcessInfo.processInfo.environment
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockAccountURLProtocol.self]
        config.urlCache = nil
        config.httpCookieStorage = nil
        client = AccountClient(baseURL: URL(string: "https://accounts.mock.herdrup.invalid")!,
                               session: URLSession(configuration: config))
        let signedIn = env["HERDR_MOCK_ACCOUNT_SIGNED_IN"] == "1"
        hintStore = InMemoryAccountHintStore(hint: env["HERDR_MOCK_ACCOUNT_STORED_HINT"])
        syncOffline = env["HERDR_MOCK_ACCOUNT_SYNC_OFFLINE"] == "1"
        tokenStore = InMemoryAccountTokenStore(refreshToken: signedIn ? "r1.mock-session.fixture-refresh" : nil)
        let suite = "herdr.mock.account"
        defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        // `HERDR_MOCK_ACCOUNT_PROFILE_ONLY=1`: what a kill mid-sign-out leaves, the profile (and
        // perhaps a hint) still stored but the refresh token already deleted.
        let profileOnly = env["HERDR_MOCK_ACCOUNT_PROFILE_ONLY"] == "1"
        if signedIn {
            server.signedIn = true
            server.enrolCurrent(name: "Mock iPhone", platform: "ios", devicePub: "fixture-device-pub")
        }
        if signedIn || profileOnly {
            defaults.set(try? JSONEncoder().encode(AccountProfile(provider: .apple, appleUserID: nil)),
                         forKey: "account.profile.v1")
            defaults.set(true, forKey: "account.onboarding.done")
        }
    }

    /// Apple's sheet and Google's page, answered at once with a fixture ID token for `nonce`.
    @MainActor func signIn(_ provider: AccountProvider, nonce: String) async throws -> ProviderCredential {
        ProviderCredential(idToken: "mock-id-token.\(provider.rawValue).\(nonce)",
                           authorizationCode: provider == .apple ? "mock-authorization-code" : nil,
                           appleUserID: nil)
    }
}

/// The stand-in service's state and answers, after AccountService/src: one account, its
/// devices and its sync items.
final class MockAccountServer: @unchecked Sendable {
    private let lock = NSLock()
    private let env = ProcessInfo.processInfo.environment
    fileprivate var signedIn = false
    private var counter = 0
    private var rev = 0
    private var items: [SyncItem] = []
    private var devices: [[String: Any]] = [[
        "id": MockAccountService.otherDeviceID, "name": "Jerry's MacBook", "platform": "macos",
        "device_pub": "fixture-other-device-pub", "created_ms": 1_795_000_000_000, "current": false,
    ]]
    private var currentDeviceID: String?

    // Pair from another device (`HERDR_MOCK_ACCOUNT_PAIR`). As `approver`, a new device
    // ("MacBook Air") asks to be paired and reveals as soon as this device claims; its
    // `pairCode` and `pairEnvelopeSummary` are what it shows and what it opens. As `new`, this
    // device asks and a mock approver ("Jerry's iPhone") claims, approves after a few reads
    // with an envelope for fleet-hel1, Mac Studio and laptop (build-box timed out), then
    // retries build-box (seq 2). `HERDR_MOCK_PAIR_OUTCOME=denied` denies instead.
    static let pairID = "PairMockAAAAAAAAAAAAAA"
    static let pairRequesterKey = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 5, count: 32))
    static let pairRequesterSSH = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        .publicKey.rawRepresentation
    static let pairRequesterNonce = Data(repeating: 0x44, count: 32)
    static let pairApproverKey = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 6, count: 32))
    static let pairApproverNonce = Data(repeating: 0x55, count: 32)
    static let hostKeyA = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFC/pYhTFrUoMpRRfd1LTRs7gZ7TZuv4MPD7PcWa01KM"
    static let hostKeyB = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKtaOymmREbaU+scg5KF53w9vK9ijZSY27ib0eXyGNeK"
    private lazy var pairRole = env["HERDR_MOCK_ACCOUNT_PAIR"]
    private var pairState = "waiting"
    private var pairNonceT: Data?
    private var pairNonceB: Data?
    private var pairCommit = Data()
    private var pairSSHPub = Data()
    private var pairSeq: UInt64 = 0
    private var pairSealed = ""
    private var pairReads = 0
    private var pairSelfReads = 0
    private var pairRetryAt = Int.max

    /// The code the mock new device shows (`approver`), or the one the mock approver would
    /// type (`new`): known once both nonces are.
    var pairCode: String? {
        lock.lock(); defer { lock.unlock() }
        guard let me = try? GuestDevice.identity() else { return nil }
        if pairRole == "approver" {
            guard let nonceT = pairNonceT else { return nil }
            return try? PairV1.code(requesterPub: Self.pairRequesterKey.publicKey.rawRepresentation,
                                    sshPub: Self.pairRequesterSSH, approverPub: me.publicKey,
                                    nonceB: Self.pairRequesterNonce, nonceT: nonceT)
        }
        guard let nonceB = pairNonceB else { return nil }
        return try? PairV1.code(requesterPub: me.publicKey, sshPub: pairSSHPub,
                                approverPub: Self.pairApproverKey.publicKey.rawRepresentation,
                                nonceB: nonceB, nonceT: Self.pairApproverNonce)
    }

    /// What the mock new device reads in this device's envelope, opened with its own key:
    /// "seq 1: fleet-hel1 added, build-box failed (timed out)", or nil before one was sent.
    var pairEnvelopeSummary: String? {
        lock.lock(); defer { lock.unlock() }
        guard pairSeq > 0, let me = try? GuestDevice.identity(),
              let plain = try? PairV1.openEnvelope(requester: Self.pairRequesterKey, approverPub: me.publicKey,
                                                   sshPub: Self.pairRequesterSSH, requestID: Self.pairID,
                                                   seq: pairSeq, sealed: pairSealed),
              let envelope = try? PairEnvelope.parse(plain) else { return pairSeq > 0 ? "unreadable" : nil }
        let machines = envelope.machines.map { machine in
            "\(machine.nickname) \(machine.status.rawValue)" + (machine.reason.map { " (\($0))" } ?? "")
        }
        return "seq \(pairSeq): " + machines.joined(separator: ", ")
    }

    private func pairDevice(_ name: String, _ pub: Data, _ platform: String) -> [String: Any] {
        ["device_id": "dev_mock_pair", "device_pub": Base64URL.encode(pub), "name": name, "platform": platform,
         "created_ms": 1_795_300_000_000]
    }

    /// The pair-v1 routes, or nil for every other request.
    private func pairAnswer(method: String, path: String, query: [URLQueryItem], json: [String: Any]) -> (Int, Any)? {
        guard let role = pairRole else { return nil }
        let base = "/v1/approvals/\(Self.pairID)"
        let me = try? GuestDevice.identity()
        let requesterPub = Self.pairRequesterKey.publicKey.rawRepresentation
        let live = ["claimed", "revealed"].contains(pairState)
        // After a cancel every step on the request answers 410 cancelled (GET shows the state).
        if pairState == "cancelled", method != "GET", path.hasPrefix(base + "/") { return refusal(410, "cancelled") }
        switch (method, path) {
        case ("GET", "/v1/approvals") where query.contains(where: { $0.name == "kind" && $0.value == "any" }):
            // `HERDR_MOCK_PAIR_UNLISTED=1`: the list never shows it, so only its push opens it.
            guard role == "approver", pairState == "waiting" || live, env["HERDR_MOCK_PAIR_UNLISTED"] != "1" else {
                return (200, ["requests": []])
            }
            let commit = (try? PairV1.commit(requesterPub: requesterPub, sshPub: Self.pairRequesterSSH,
                                             nonceB: Self.pairRequesterNonce)) ?? Data()
            return (200, ["requests": [[
                "id": Self.pairID, "kind": "pair", "device": pairDevice("MacBook Air", requesterPub, "macos"),
                "commit": Base64URL.encode(commit), "ssh_pub": Base64URL.encode(Self.pairRequesterSSH),
                "claimed": pairState == "waiting" ? "no" : "you", "expires_in": 540,
            ]]])
        case ("POST", "/v1/approvals") where json["kind"] as? String == "pair":
            pairCommit = Base64URL.decode(json["commit"] as? String ?? "") ?? Data()
            pairSSHPub = Base64URL.decode(json["ssh_pub"] as? String ?? "") ?? Data()
            pairState = "waiting"
            pairNonceB = nil
            pairSeq = 0
            pairReads = 0
            pairSelfReads = 0
            pairRetryAt = .max
            return (201, ["id": Self.pairID, "expires_in": 600])
        case ("GET", base):
            var answer: [String: Any] = ["expires_in": 540, "kind": "pair"]
            if role == "approver" {
                // The mock new device reveals as soon as it sees the claim.
                if pairState == "claimed" {
                    pairState = "revealed"
                } else if pairState == "revealed", env["HERDR_MOCK_PAIR_CANCEL"] == "1" {
                    // `HERDR_MOCK_PAIR_CANCEL=1`: the mock new device cancels three reads after
                    // it revealed, while the code is being typed.
                    pairReads += 1
                    if pairReads >= 3 { pairState = "cancelled" }
                }
                let commit = (try? PairV1.commit(requesterPub: requesterPub, sshPub: Self.pairRequesterSSH,
                                                 nonceB: Self.pairRequesterNonce)) ?? Data()
                answer["commit"] = Base64URL.encode(commit)
                answer["ssh_pub"] = Base64URL.encode(Self.pairRequesterSSH)
                answer["device"] = pairDevice("MacBook Air", requesterPub, "macos")
                if pairState == "revealed" {
                    answer["nonce_b"] = Base64URL.encode(Self.pairRequesterNonce)
                    if let nonceT = pairNonceT { answer["nonce_t"] = Base64URL.encode(nonceT) }
                }
            } else {
                // The mock approver opens the request on the second look.
                pairReads += 1
                if pairState == "waiting", pairReads >= 2 { pairState = "claimed" }
                if pairState != "waiting" {
                    answer["approver"] = ["device_pub": Base64URL.encode(Self.pairApproverKey.publicKey.rawRepresentation),
                                          "name": "Jerry's iPhone"]
                }
                if live { answer["nonce_t"] = Base64URL.encode(Self.pairApproverNonce) }
                answer["ssh_pub"] = Base64URL.encode(pairSSHPub)
                answer["commit"] = Base64URL.encode(pairCommit)
                if let me { answer["device"] = pairDevice("Mock iPhone", me.publicKey, "ios") }
            }
            answer["state"] = pairState
            return (200, answer)
        case ("POST", base + "/claim"):
            guard role == "approver" else { return refusal(403, "own_request") }
            guard pairState == "waiting" else { return refusal(409, "already_claimed") }
            pairNonceT = Base64URL.decode(json["nonce_t"] as? String ?? "")
            pairState = "claimed"
            return (200, ["state": "claimed"])
        case ("POST", base + "/cancel"):
            guard role == "new" else { return refusal(404, "not_found") }
            guard pairState == "waiting" || live else {
                return pairState == "cancelled" ? refusal(410, "cancelled") : refusal(409, "already_finished")
            }
            pairState = "cancelled"
            return (200, ["state": "cancelled"])
        case ("POST", base + "/reveal"):
            guard role == "new", let me else { return refusal(403, "forbidden") }
            guard pairState == "claimed" else { return refusal(409, pairState == "revealed" ? "already_revealed" : "not_claimed") }
            let nonce = Base64URL.decode(json["nonce_b"] as? String ?? "") ?? Data()
            guard (try? PairV1.open(requesterPub: me.publicKey, sshPub: pairSSHPub, commit: pairCommit, nonceB: nonce)) != nil else {
                pairState = "denied"
                return refusal(400, "reveal_mismatch")
            }
            pairNonceB = nonce
            pairState = "revealed"
            return (200, ["state": "revealed"])
        case ("POST", base + "/finish"):
            guard role == "approver" else { return refusal(403, "forbidden") }
            if json["outcome"] as? String == "denied" {
                guard pairState == "waiting" || live else { return refusal(409, "already_finished") }
                pairState = "denied"
                return (200, ["state": "denied"])
            }
            guard pairState == "revealed" else { return refusal(409, "not_revealed") }
            guard let seq = (json["seq"] as? NSNumber)?.uint64Value, seq >= 1, let sealed = json["sealed"] as? String
            else { return refusal(400, "bad_request") }
            pairSeq = seq
            pairSealed = sealed
            pairState = "approved"
            return (200, ["state": "approved"])
        case ("PUT", base + "/envelope"):
            guard role == "approver", pairState == "approved" else { return refusal(409, "not_approved") }
            guard let seq = (json["seq"] as? NSNumber)?.uint64Value, let sealed = json["sealed"] as? String
            else { return refusal(400, "bad_request") }
            guard seq > pairSeq else { return refusal(409, "stale_seq") }
            pairSeq = seq
            pairSealed = sealed
            return (200, ["seq": seq])
        case ("GET", "/v1/pairs/self"):
            guard role == "new", let me else { return (200, ["envelopes": []]) }
            pairSelfReads += 1
            // The mock approver types the code after a few looks, then tries build-box again.
            if pairState == "revealed", pairSelfReads >= 4 {
                if env["HERDR_MOCK_PAIR_OUTCOME"] == "denied" {
                    pairState = "denied"
                } else {
                    pairState = "approved"
                    sealPair(seq: 1, buildBoxAdded: false, to: me.publicKey)
                    // About ten seconds later (the retry watch reads once a second in a mock).
                    pairRetryAt = pairSelfReads + 10
                }
            } else if pairState == "approved", pairSeq == 1, pairSelfReads >= pairRetryAt {
                sealPair(seq: 2, buildBoxAdded: true, to: me.publicKey)
            }
            var answer: [String: Any] = ["request": ["id": Self.pairID, "state": pairState, "expires_in": 500],
                                         "envelopes": []]
            if pairSeq > 0 {
                answer["envelopes"] = [["request_id": Self.pairID, "ssh_pub": Base64URL.encode(pairSSHPub),
                                        "approver_pub": Base64URL.encode(Self.pairApproverKey.publicKey.rawRepresentation),
                                        "approver_name": "Jerry's iPhone", "seq": pairSeq, "sealed": pairSealed]]
            }
            return (200, answer)
        case ("PUT", "/v1/devices/self/push"), ("DELETE", "/v1/devices/self/push"):
            return (204, [:])
        default:
            return nil
        }
    }

    /// The mock approver's envelope: fleet-hel1, Mac Studio and laptop got the key; build-box
    /// timed out (seq 1) or got it on the retry.
    private func sealPair(seq: UInt64, buildBoxAdded: Bool, to requesterPub: Data) {
        func machine(_ name: String, _ host: String, _ key: String, _ status: PairEnvelope.Machine.Status,
                     _ reason: String? = nil) -> PairEnvelope.Machine {
            PairEnvelope.Machine(nickname: name, host: host, port: 22, user: "jerry", hostKey: key, status: status, reason: reason)
        }
        let envelope = PairEnvelope(machines: [
            machine("fleet-hel1", "fleet-hel1", Self.hostKeyA, .added),
            machine("Mac Studio", "mac-studio.local", Self.hostKeyB, .added),
            buildBoxAdded ? machine("build-box", "10.0.0.12", Self.hostKeyA, .added)
                : machine("build-box", "10.0.0.12", "", .failed, "timed out"),
            machine("laptop", "laptop", Self.hostKeyB, .added),
        ])
        guard let plain = try? envelope.json(),
              let sealed = try? PairV1.seal(approver: Self.pairApproverKey, requesterPub: requesterPub, sshPub: pairSSHPub,
                                            requestID: Self.pairID, seq: seq, plaintext: plain) else { return }
        pairSeq = seq
        pairSealed = sealed
    }

    // Browser approval (`HERDR_MOCK_ACCOUNT_APPROVAL=1`): one browser, "Chrome on macOS", asks to
    // reach the account's machines, and reveals as soon as this device claims its request.
    static let approvalID = "ReqMockAAAAAAAAAAAAAAA"
    static let browserKey = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 9, count: 32))
    static let browserNonce = Data(repeating: 0x11, count: 32)
    private lazy var approvalMock = env["HERDR_MOCK_ACCOUNT_APPROVAL"] == "1"
    private var approvalState = "waiting"
    private var approvalNonceT: Data?

    /// The code the mock browser shows: known once this device claimed (it covers this device's
    /// key and `nonce_t`).
    var browserCode: String? {
        lock.lock(); defer { lock.unlock() }
        guard let nonceT = approvalNonceT, let approver = try? GuestDevice.identity() else { return nil }
        return try? ApproveV1.code(browserPub: Self.browserKey.publicKey.rawRepresentation,
                                   approverPub: approver.publicKey, nonceB: Self.browserNonce, nonceT: nonceT)
    }

    private func approvalListed() -> [String: Any] {
        let browserPub = Self.browserKey.publicKey.rawRepresentation
        let commit = (try? ApproveV1.commit(browserPub: browserPub, nonceB: Self.browserNonce)) ?? Data()
        return ["id": Self.approvalID,
                "browser": ["device_id": "dev_mock_browser", "device_pub": Base64URL.encode(browserPub),
                            "name": "Chrome on macOS", "platform": "web", "created_ms": 1_795_200_000_000],
                "commit": Base64URL.encode(commit),
                "claimed": approvalState == "waiting" ? "no" : "you", "expires_in": 540]
    }

    init() {
        // `HERDR_MOCK_ACCOUNT_SHARES`: the account holds shares accepted on another device
        // and no machines, so the list is a guest's (`enyo`: jerry's enyo on hetzner;
        // `several`: also his orgstudio there, and maya's landing on atlas-mini).
        if let shares = env["HERDR_MOCK_ACCOUNT_SHARES"] {
            func share(_ hostID: String, _ nodePub: String, _ guestID: String, _ agent: String, _ owner: String, _ machine: String) {
                rev += 1
                items.append(SyncItem(key: .share(hostID: hostID, guestID: guestID), rev: rev, updatedMs: 1_795_000_000_000,
                                      body: .share(SyncShare(relay: "https://guest.herdrup.app", hostID: hostID, nodePub: nodePub,
                                                             guestID: guestID, agentName: agent, ownerName: owner,
                                                             machineLabel: machine))))
            }
            let hetzner = ("aGV0em5lci1ob3N0LWlkMQ", "ISEhISEhISEhISEhISEhISEhISEhISEhISEhISEhISE")
            share(hetzner.0, hetzner.1, "Z3Vlc3QtbmlrZS1lbnlvMQ", "enyo", "jerry", "hetzner")
            if shares == "several" {
                share(hetzner.0, hetzner.1, "Z3Vlc3QtbmlrZS1vcmdzMQ", "orgstudio", "jerry", "hetzner")
                share("YXRsYXMtbWluaS1ob3N0MQ", "QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI",
                      "Z3Vlc3QtbmlrZS1sYW5kMQ", "landing", "maya", "atlas-mini")
            }
            return
        }
        func host(_ id: String, _ body: SyncHost) {
            rev += 1
            items.append(SyncItem(key: SyncKey(.hosts, id), rev: rev, updatedMs: 1_795_000_000_000, body: .host(body)))
        }
        host(MockAccountService.macStudioID, SyncHost(nickname: "Mac Studio", host: "mac-studio.local", username: "jerry", authKind: .key))
        host(MockAccountService.fleetID, SyncHost(nickname: "fleet-hel1", host: "fleet-hel1", username: "jerry", authKind: .key))
        host(MockAccountService.fleetForkID, SyncHost(nickname: "fleet (old phone)", host: "FLEET-HEL1.", port: 22, username: "jerry", authKind: .key))
        rev += 1
        items.append(SyncItem(key: SyncKey(.prompts, MockAccountService.promptID), rev: rev, updatedMs: 1_795_000_000_000,
                              body: .prompt(SyncPrompt(title: "Review", text: "Review the open PR and list the risks.", order: 0))))
    }

    fileprivate func enrolCurrent(name: String, platform: String, devicePub: String) {
        let id = "dev_mock_this_device"
        currentDeviceID = id
        devices.removeAll { $0["id"] as? String == id }
        devices.insert(["id": id, "name": name, "platform": platform, "device_pub": devicePub,
                        "created_ms": 1_795_100_000_000, "current": true], at: 0)
    }

    /// (status, JSON body) for one request.
    func answer(method: String, path: String, query: [URLQueryItem], body: Data?) -> (Int, Any) {
        lock.lock(); defer { lock.unlock() }
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        switch (method, path) {
        case ("GET", "/v1/health"):
            var features = env["HERDR_MOCK_ACCOUNT_FEATURES"] ?? "native_sign_in,devices,statements,sync,delete"
            if approvalMock { features += ",web_approve" }
            if pairRole != nil { features += ",pair_v1" }
            return (200, ["ok": true, "version": "mock",
                          "features": features.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }])
        case ("POST", "/v1/auth/nonce"):
            counter += 1
            return (200, ["nonce": "mock-nonce-\(counter)", "expires_unix": Int(Date().timeIntervalSince1970) + 600])
        case ("POST", "/v1/auth/apple"), ("POST", "/v1/auth/google"):
            signedIn = true
            var tokens = self.tokens()
            tokens["created"] = false
            if path.hasSuffix("google") { tokens["display_hint"] = "jerry@example.com" }
            return (200, tokens)
        case ("POST", "/v1/auth/refresh"):
            return signedIn ? (200, tokens()) : refusal(401, "invalid_token")
        default:
            break
        }
        guard signedIn else { return refusal(401, "invalid_token") }
        if let answer = pairAnswer(method: method, path: path, query: query, json: json) { return answer }
        switch (method, path) {
        case ("POST", "/v1/auth/signout"):
            signedIn = false
            return (200, ["ok": true])
        case ("GET", "/v1/account"):
            return (200, ["account_id": "acct_mock", "created_ms": 1_795_000_000_000])
        case ("POST", "/v1/devices/challenge"):
            let server = Curve25519.KeyAgreement.PrivateKey()
            return (200, ["challenge_id": "chal_mock_\(counter)",
                          "server_pub": Base64URL.encode(server.publicKey.rawRepresentation),
                          "salt": Base64URL.encode(Data(repeating: 7, count: 32)),
                          "account_id": "acct_mock", "expires_in": 60])
        case ("POST", "/v1/devices"):
            switch env["HERDR_MOCK_ACCOUNT_ENROL"] {
            case "device_in_other_account"?: return refusal(409, "device_in_other_account")
            case "too_many_devices"?: return refusal(403, "too_many_devices")
            default: break
            }
            enrolCurrent(name: json["name"] as? String ?? "Device", platform: json["platform"] as? String ?? "ios",
                         devicePub: json["device_pub"] as? String ?? "")
            return (200, ["device": devices[0]])
        case ("GET", "/v1/devices"):
            return (200, ["devices": devices])
        case ("POST", "/v1/statements"):
            let hosts = json["hosts"] as? [String] ?? []
            return (200, ["statements": hosts.map { ["host": $0, "jws": "mock.statement.\($0)"] },
                          "exp": Int(Date().timeIntervalSince1970) + 600])
        case ("GET", "/v1/approvals"):
            let live = approvalMock && ["waiting", "claimed", "revealed"].contains(approvalState)
            return (200, ["requests": live ? [approvalListed()] : []])
        case ("POST", "/v1/approvals/\(Self.approvalID)/claim"):
            guard approvalState == "waiting" else { return refusal(409, "already_claimed") }
            approvalNonceT = Base64URL.decode(json["nonce_t"] as? String ?? "")
            approvalState = "claimed"
            return (200, ["state": "claimed"])
        case ("GET", "/v1/approvals/\(Self.approvalID)"):
            // The browser reveals as soon as it sees the claim.
            if approvalState == "claimed" { approvalState = "revealed" }
            var answer: [String: Any] = ["state": approvalState, "expires_in": 540]
            if approvalState == "revealed" { answer["nonce_b"] = Base64URL.encode(Self.browserNonce) }
            return (200, answer)
        case ("POST", "/v1/approvals/\(Self.approvalID)/finish"):
            guard approvalState == "revealed" || approvalState == "claimed" else { return refusal(409, "already_finished") }
            approvalState = json["outcome"] as? String == "approved" ? "approved" : "denied"
            return (200, ["state": approvalState])
        case ("GET", "/v1/sync"):
            let since = query.first { $0.name == "since" }?.value.flatMap(Int.init) ?? 0
            let changes = items.filter { $0.rev > since }.sorted { $0.rev < $1.rev }.map(Self.object)
            return (200, ["rev": rev, "changes": changes, "more": false])
        case ("POST", "/v1/sync"):
            return push(json)
        case ("POST", "/v1/account/delete"):
            signedIn = false
            items = []
            return (200, ["deleted": true, "manual_revoke": env["HERDR_MOCK_ACCOUNT_MANUAL_REVOKE"] == "1"])
        default:
            break
        }
        if path.hasPrefix("/v1/devices/") {
            let id = String(path.dropFirst("/v1/devices/".count))
            guard let index = devices.firstIndex(where: { $0["id"] as? String == id }) else { return refusal(404, "not_found") }
            if method == "PATCH" {
                devices[index]["name"] = json["name"] as? String ?? devices[index]["name"]
                return (200, ["device": devices[index]])
            }
            if method == "DELETE" {
                devices.remove(at: index)
                if id == currentDeviceID { signedIn = false; currentDeviceID = nil }
                return (200, ["ok": true])
            }
        }
        return refusal(404, "not_found")
    }

    private func push(_ json: [String: Any]) -> (Int, Any) {
        guard let raw = json["changes"],
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let changes = try? JSONDecoder().decode([SyncChange].self, from: data)
        else { return refusal(400, "bad_request") }
        var applied: [[String: Any]] = []
        for change in changes {
            let existing = items.firstIndex { $0.key == change.key }
            if change.deleted, existing == nil || items[existing!].deleted {
                applied.append(["collection": change.key.collection.rawValue, "id": change.key.id, "rev": existing.map { items[$0].rev } ?? 0])
                continue
            }
            rev += 1
            let item = SyncItem(key: change.key, rev: rev, updatedMs: Int(Date().timeIntervalSince1970 * 1000), body: change.body)
            if let existing { items[existing] = item } else { items.append(item) }
            applied.append(["collection": change.key.collection.rawValue, "id": change.key.id, "rev": rev])
        }
        return (200, ["rev": rev, "applied": applied, "conflicts": []])
    }

    private func tokens() -> [String: Any] {
        counter += 1
        return ["account_id": "acct_mock", "access_token": "a1.mock-session.fixture-access-\(counter)",
                "access_expires_in": 3600, "refresh_token": "r1.mock-session.fixture-refresh-\(counter)",
                "refresh_expires_in": 7_776_000]
    }

    private func refusal(_ status: Int, _ code: String) -> (Int, Any) { (status, ["error": code]) }

    private static func object(_ item: SyncItem) -> Any {
        guard let data = try? JSONEncoder().encode(item),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return object
    }
}

/// Routes `AccountClient`'s requests to `MockAccountServer`.
final class MockAccountURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if MockAccountService.shared.syncOffline, (components?.path ?? url.path) == "/v1/sync" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let (status, object) = MockAccountService.shared.server.answer(
            method: request.httpMethod ?? "GET", path: components?.path ?? url.path,
            query: components?.queryItems ?? [], body: body)
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// The `account` mock's root: the machine list behind the first-launch gate (1B), exactly as
/// the app shows it, with a Settings button standing in for the connected home's tab. A
/// shared machine opened from the list shows its guest home over `GuestMockTransport`.
struct AccountMockRoot: View {
    @ObservedObject private var account = HerdrUpAccount.shared
    @ObservedObject private var devicePairing = DevicePairing.shared
    @State private var showSettings = false
    @State private var openShare: GuestAccess?
    private let sharesMock = ProcessInfo.processInfo.environment["HERDR_MOCK_ACCOUNT_SHARES"] != nil

    var body: some View {
        if let openShare {
            SharedMachineHomeView(access: openShare, connect: GuestMockTransport.connection(for:),
                                  onBack: { self.openShare = nil }, onLeave: { self.openShare = nil })
        } else {
            gate
        }
    }

    private var gate: some View {
        AccountOnboardingGate {
            ConnectView(onConnect: { _ in }, onOpenShared: { openShare = $0 })
                // Bottom trailing: the logo row's trailing edge is the account avatar's.
                .overlay(alignment: .bottomTrailing) {
                    if !sharesMock {
                        Button("Settings") { showSettings = true }
                            .accessibilityIdentifier("fixture-open-settings")
                            .buttonStyle(.bordered)
                            .padding(.bottom, 8).padding(.trailing, 20)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    // What the hint store holds, for the tests (re-read whenever the account
                    // changes, since this view observes it).
                    Color.clear.frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityIdentifier("fixture-stored-hint")
                        .accessibilityLabel((try? MockAccountService.shared.hintStore.loadDisplayHint()).flatMap { $0 } ?? "none")
                        .id(account.signedIn)
                }
                .overlay(alignment: .topLeading) {
                    // `HERDR_MOCK_ACCOUNT_PAIR=new`: the code the mock approver computes from its
                    // side, which the code this device shows must equal (re-read as the request moves).
                    if ProcessInfo.processInfo.environment["HERDR_MOCK_ACCOUNT_PAIR"] == "new" {
                        Color.clear.frame(width: 1, height: 1)
                            .accessibilityElement()
                            .accessibilityIdentifier("fixture-pair-expected-code")
                            .accessibilityLabel(MockAccountService.shared.server.pairCode ?? "none")
                            .id("\(devicePairing.phase)")
                    }
                }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(mode: .owner(HerdrClient(transport: MockTransport())), agents: [],
                         host: "mac.tail-scale.ts.net", onClose: { showSettings = false })
        }
    }
}

/// The approver's machines under `HERDR_MOCK_ACCOUNT_PAIR=approver`, as in the option B frames:
/// fleet-hel1 and studio take the key, build-box (a password login) times out the first time
/// and takes it on "Try build-box again", laptop can't be reached, and old-pi runs herdr 0.9.2,
/// which has no `pair.add_key`.
enum PairMachinesMock {
    static func entries() -> [PairApprovalEntry] {
        [
            entry("fleet-hel1", "fleet-hel1", Transport(version: "0.9.9", supports: true), key: MockAccountServer.hostKeyA),
            entry("studio", "studio.local", Transport(version: "0.9.9", supports: true), key: MockAccountServer.hostKeyB),
            entry("build-box", "10.0.0.12", Transport(version: "0.9.9", supports: true, timesOutFirst: true),
                  key: MockAccountServer.hostKeyA, password: true),
            entry("laptop", "laptop", nil, key: ""),
            entry("old-pi", "old-pi", Transport(version: "0.9.2", supports: false), key: ""),
        ]
    }

    private static func entry(_ label: String, _ host: String, _ transport: Transport?, key: String,
                              password: Bool = false) -> PairApprovalEntry {
        let machine = PairMachine(id: label, label: label, host: host, port: 22, user: "jerry",
                                  passwordLogin: password) {
            guard let transport else { throw TransportError.closedBeforeResponse }
            return PairLink(client: HerdrClient(transport: transport), hostKey: { key }, close: {})
        }
        return PairApprovalEntry(id: label, label: label, machine: machine)
    }

    /// Tries per machine, so build-box fails once (one approval per launch).
    private final class Tries: @unchecked Sendable {
        static let shared = Tries()
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func next(_ key: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            counts[key, default: 0] += 1
            return counts[key]!
        }
    }

    struct Transport: HerdrTransport {
        let version: String
        let supports: Bool
        var timesOutFirst = false

        func roundTrip(_ requestLine: String) async throws -> String {
            let request = (try? JSONSerialization.jsonObject(with: Data(requestLine.utf8))) as? [String: Any] ?? [:]
            let id = request["id"] as? String ?? "x"
            switch request["method"] as? String {
            case "ping":
                let caps = supports ? #"{"pair_add_key":true}"# : "{}"
                return #"{"id":"\#(id)","result":{"type":"pong","version":"\#(version)","protocol":22,"capabilities":\#(caps)}}"#
            case "pair.add_key":
                // Slow enough for "Adding…" to show, one machine at a time.
                try await Task.sleep(nanoseconds: 700_000_000)
                if timesOutFirst, Tries.shared.next(version + "build-box") == 1 {
                    throw WebAccessApproval.Failure.timedOut
                }
                let params = request["params"] as? [String: Any] ?? [:]
                // herdr keeps only [A-Za-z0-9 -_.'] of the label, at most 48, and answers that.
                let stored = String((params["label"] as? String ?? "").filter {
                    $0.isASCII && ($0.isLetter || $0.isNumber || " -_.'".contains($0))
                }.prefix(48))
                return #"{"id":"\#(id)","result":{"type":"pair_key_added","added":true,"already":false,"fingerprint":"SHA256:mock","label":"\#(stored)"}}"#
            default:
                return #"{"id":"\#(id)","error":{"code":"unknown_method","message":"not in the pair mock"}}"#
            }
        }

        func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }
}

/// The machines "Approve a browser?" offers under `HERDR_MOCK_ACCOUNT_APPROVAL=1`: "fleet-hel1"
/// runs a herdr that admits owner browsers (protocol 2), "Mac Studio" one that only stores
/// grants (protocol 1, so it is skipped as needing an update).
enum OwnerAccessMock {
    static let machines: [WebAccessMachine] = [
        machine(MockAccountService.fleetID, "fleet-hel1", protocol: 2),
        machine(MockAccountService.macStudioID, "Mac Studio", protocol: 1),
    ]

    private static func machine(_ id: String, _ label: String, protocol version: Int) -> WebAccessMachine {
        WebAccessMachine(id: id, label: label, hostItemID: id) {
            OwnerAccessLink(client: HerdrClient(transport: Transport(protocolVersion: version)), close: {})
        }
    }

    struct Transport: HerdrTransport {
        let protocolVersion: Int

        func roundTrip(_ requestLine: String) async throws -> String {
            let request = (try? JSONSerialization.jsonObject(with: Data(requestLine.utf8))) as? [String: Any] ?? [:]
            let params = request["params"] as? [String: Any] ?? [:]
            let result: [String: Any]
            switch request["method"] as? String {
            case "owner_access.info":
                result = ["type": "owner_access_info", "protocol": protocolVersion, "host_id": "AQEBAQEBAQEBAQEBAQEBAQ",
                          "node_pub": "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI", "relay_url": "https://guest.herdrup.app",
                          "link": ["state": "off"], "max_ttl_secs": 2_592_000, "scopes": ["chat", "terminal"],
                          "version": "0.9.\(protocolVersion)"]
            case "owner_access.add":
                let ttl = (params["ttl_secs"] as? NSNumber)?.uint64Value ?? 0
                result = ["type": "owner_access_added", "replaced": [],
                          "grant": ["grant_id": "AwMDAwMDAwMDAwMDAwMDAw", "device_pub": params["device_pub"] ?? "",
                                    "fingerprint": "SHA256:0000000000000000", "device": params["device_name"] ?? "",
                                    "scope": params["scope"] ?? "terminal", "approved_by": params["approved_by"] ?? "",
                                    "created_ms": 1_795_200_000_000,
                                    "expires_ms": UInt64(Date().timeIntervalSince1970 * 1000) + ttl * 1000, "revoked": false]]
            case "owner_access.remove":
                result = ["type": "owner_access_removed", "removed": ["AwMDAwMDAwMDAwMDAwMDAw"]]
            default:
                return #"{"id":"x","error":{"code":"forbidden","message":"not in the owner_access mock"}}"#
            }
            let data = try JSONSerialization.data(withJSONObject: ["id": request["id"] ?? "x", "result": result])
            return String(decoding: data, as: UTF8.self)
        }

        func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }
}
#endif
