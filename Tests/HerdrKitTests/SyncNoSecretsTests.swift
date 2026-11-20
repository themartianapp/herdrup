import Crypto
import XCTest
@testable import HerdrKit

/// DESIGN §5.4: sync never uploads a secret. The encoders are their own allowlisted types, so a
/// store's secret has no field to travel in; `SyncSecretScan` catches one pasted into a free
/// text field; and every payload the engine actually sends is scanned here.
final class SyncNoSecretsTests: XCTestCase {
    // Secrets a device holds next to the data it syncs, all generated for the test.
    private let sshPrivateKey = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        -----END OPENSSH PRIVATE KEY-----
        """
    private let password = "correct horse battery staple 42!"
    private let sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl jerry@mac"
    private lazy var hostKeyPin = SHA256.hash(data: Data("host key".utf8)).map { String(format: "%02x", $0) }.joined()
    private lazy var hostKeyPinBase64 = "SHA256:" + Data(SHA256.hash(data: Data("host key".utf8))).base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
    private let inviteSecret = Base64URL.encode(Data((0..<32).map { UInt8($0 * 7 & 0xff) }))
    private lazy var inviteLink = "https://guest.herdrup.app/i/AbCdEfGhIjKl\(inviteSecret)"
    private let refreshToken = "r1.SSSSSSSSSSSSSSSSSSSSSS." + Base64URL.encode(Data(repeating: 0x5a, count: 32))
    private let guestPrivateKey = Curve25519.KeyAgreement.PrivateKey()

    /// What the app keeps for a saved host, secrets included: the shape the sync encoder must
    /// NOT mirror.
    private struct LocalHost {
        let id = UUID()
        let host = "mac.local:2222"
        let username = "jerry"
        let nickname = "Studio Mac"
        let privateKey: String
        let password: String
        let hostKeyPin: String
    }

    private func knownSecrets() -> [String] {
        [sshPrivateKey, "-----BEGIN", password, sshPublicKey, hostKeyPin, hostKeyPinBase64, inviteSecret, inviteLink,
         refreshToken, Base64URL.encode(guestPrivateKey.rawRepresentation)]
    }

    override func setUp() {
        super.setUp()
        AccountServiceStub.reset()
    }

    override func tearDown() {
        AccountServiceStub.reset()
        super.tearDown()
    }

    func testEverythingTheEngineSendsIsFreeOfSecrets() async throws {
        let service = FakeSyncService()
        AccountServiceStub.handler = { service.handle($0) }
        let local = LocalHost(privateKey: sshPrivateKey, password: password, hostKeyPin: hostKeyPin)
        let engine = try SyncEngine(session: makeStubSession(), store: InMemorySyncStateStore())

        // The app's encoders take the allowlisted fields only.
        try await engine.stage(.upsert(.host(local.id), .host(SyncHost(nickname: local.nickname, host: local.host,
                                                                          username: local.username, authKind: .password))))
        try await engine.stage(.upsert(.prompt(UUID()), .prompt(SyncPrompt(title: "Review", text: "Review this diff\n\tcarefully", order: 1.5))))
        for (key, value) in [("terminal.fontSize", SyncValue.number(13)), ("ui.theme", .string("dark")),
                             ("guest.ownerName", .string("Jerry")), ("notify.questions", .bool(true))] {
            try await engine.stage(.upsert(.setting(key), .setting(value)))
        }
        try await engine.stage(.upsert(.agentPref(host: local.id, agent: "claude-1"), .agentPref(SyncAgentPref(pinned: true, order: 2))))
        let hostID = "HostAAAAAAAAAAAAAAAAAA", guestID = "GuestAAAAAAAAAAAAAAAAA"
        try await engine.stage(.upsert(.share(hostID: hostID, guestID: guestID), .share(SyncShare(
            relay: "https://guest.herdrup.app", hostID: hostID,
            nodePub: Base64URL.encode(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation),
            guestID: guestID, agentName: "claude", ownerName: "Ann", machineLabel: "Ann's Mac", shareGram: false))))
        try await engine.stage(.delete(.prompt(UUID())))
        _ = try await engine.sync()

        let payloads = AccountServiceStub.requests.filter { $0.method == "POST" && $0.path == "/v1/sync" }.map(\.body)
        XCTAssertEqual(payloads.count, 1)
        for payload in payloads {
            XCTAssertEqual(SyncSecretScan.findings(inPush: payload), [])
            let text = String(decoding: payload, as: UTF8.self)
            for secret in knownSecrets() {
                XCTAssertFalse(text.contains(secret), "a push carried \(secret.prefix(12))…")
            }
            // Field names only: `auth_kind` may say "password" as a value.
            for word in ["password", "private", "token", "secret", "pin", "fingerprint", "invite", "key"] {
                XCTAssertFalse(text.contains("\"\(word)\":") || text.contains("_\(word)\":"),
                               "a field named like a secret: \(word)")
            }
        }
        // Nothing the service could see carries a secret either: the bearer is a header, not a body.
        for request in AccountServiceStub.requests where request.path == "/v1/sync" {
            XCTAssertNil(request.json["refresh_token"])
        }
    }

    func testSecretsPastedIntoFreeTextAreRefused() {
        let id = UUID()
        let cases: [(String, SyncBody, SyncKey)] = [
            ("pem in a nickname", .host(SyncHost(nickname: sshPrivateKey, host: "h", username: "u")), .host(id)),
            ("ssh key in a prompt", .prompt(SyncPrompt(text: "my key: \(sshPublicKey)")), .prompt(id)),
            ("bare ssh key blob", .prompt(SyncPrompt(text: "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0")), .prompt(id)),
            ("32-byte base64url secret", .host(SyncHost(host: "h", username: "u", label: inviteSecret)), .host(id)),
            ("32-byte base64 secret", .prompt(SyncPrompt(text: Data(repeating: 0xab, count: 32).base64EncodedString())), .prompt(id)),
            ("guest private key", .prompt(SyncPrompt(text: Base64URL.encode(guestPrivateKey.rawRepresentation))), .prompt(id)),
            ("session token", .prompt(SyncPrompt(title: refreshToken, text: "t")), .prompt(id)),
            ("hex host key pin", .prompt(SyncPrompt(text: "pin \(hostKeyPin)")), .prompt(id)),
            ("SHA256 host key pin", .host(SyncHost(nickname: hostKeyPinBase64, host: "h", username: "u")), .host(id)),
            ("invite link", .prompt(SyncPrompt(text: "join me: \(inviteLink)")), .prompt(id)),
            ("app invite link", .prompt(SyncPrompt(text: "herdrup://guest-invite#eyJ2IjoxfQ")), .prompt(id)),
            ("pairing link", .prompt(SyncPrompt(text: "herdrup://pair#eyJ2IjoxfQ")), .prompt(id)),
            ("owner name", .setting(.string("-----BEGIN RSA PRIVATE KEY-----")), .setting("guest.ownerName")),
        ]
        for (name, body, key) in cases {
            XCTAssertThrowsError(try SyncChange.upsert(key, body), name) { error in
                guard case .secretLike? = error as? SyncError else {
                    return XCTFail("\(name): \(error)")
                }
            }
        }
    }

    func testAnInviteLinkIsNotARelay() {
        let hostID = "HostAAAAAAAAAAAAAAAAAA", guestID = "GuestAAAAAAAAAAAAAAAAA"
        let nodePub = String(repeating: "N", count: 43)
        for relay in [inviteLink, "https://guest.herdrup.app/i", "https://guest.herdrup.app/%69/x",
                      "https://guest.herdrup.app/x/../i/abc", "https://guest.herdrup.app/i#payload",
                      "https://guest.herdrup.app/?invite=abc", "https://user:pass@guest.herdrup.app",
                      "herdrup://guest-invite#abc", "ftp://guest.herdrup.app"] {
            XCTAssertThrowsError(try SyncChange.upsert(
                .share(hostID: hostID, guestID: guestID),
                .share(SyncShare(relay: relay, hostID: hostID, nodePub: nodePub, guestID: guestID))), relay)
        }
        XCTAssertNoThrow(try SyncChange.upsert(
            .share(hostID: hostID, guestID: guestID),
            .share(SyncShare(relay: "https://relay.example.com/herdr", hostID: hostID, nodePub: nodePub, guestID: guestID))))
    }

    func testDeviceShapedAndUnknownSettingsStayLocal() {
        for key in ["previews.javascript", "ui.sidebarWidth", "hasSeenGesturesHelp", "gram.setupCardDismissed",
                    "notify.", "notify.1abc", "account.refresh"] {
            XCTAssertThrowsError(try SyncChange.upsert(.setting(key), .setting(.bool(true))), key) { error in
                XCTAssertEqual(error as? SyncError, .invalid(field: "id"))
            }
        }
        XCTAssertThrowsError(try SyncChange.upsert(.setting("terminal.fontSize"), .setting(.number(200))))
        XCTAssertThrowsError(try SyncChange.upsert(.setting("ui.theme"), .setting(.string("neon"))))
        XCTAssertNoThrow(try SyncChange.upsert(.setting("notify.agentDone"), .setting(.bool(false))))
    }

    func testTheScanFlagsSecretFieldNames() {
        let payload = Data(#"{"changes":[{"collection":"hosts","id":"x","body":{"host":"h","password":"x","private_key":"y","host_key_pin":"z","pinned":true}}]}"#.utf8)
        let fields = Set(SyncSecretScan.findings(inPush: payload).filter { $0.reason == "secret field name" }.map(\.field))
        XCTAssertEqual(fields, ["password", "private_key", "host_key_pin"], "`pinned` is an agent pref, not a pin")
    }

    func testPublicIDsPassTheScan() throws {
        // A share's node_pub is 43 characters of base64url, like a secret, but public and an id.
        let body = Data(#"{"relay":"https://guest.herdrup.app","host_id":"HostAAAAAAAAAAAAAAAAAA","node_pub":"\#(String(repeating: "N", count: 43))","guest_id":"GuestAAAAAAAAAAAAAAAAA"}"#.utf8)
        XCTAssertEqual(SyncSecretScan.findings(inBody: body), [])
        // The same value anywhere else is flagged.
        let elsewhere = Data(#"{"agent_name":"\#(String(repeating: "N", count: 43))"}"#.utf8)
        XCTAssertEqual(SyncSecretScan.findings(inBody: elsewhere).map(\.field), ["agent_name"])
    }
}
