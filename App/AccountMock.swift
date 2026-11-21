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

    private init() {
        let env = ProcessInfo.processInfo.environment
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockAccountURLProtocol.self]
        config.urlCache = nil
        config.httpCookieStorage = nil
        client = AccountClient(baseURL: URL(string: "https://accounts.mock.herdrup.invalid")!,
                               session: URLSession(configuration: config))
        let signedIn = env["HERDR_MOCK_ACCOUNT_SIGNED_IN"] == "1"
        tokenStore = InMemoryAccountTokenStore(refreshToken: signedIn ? "r1.mock-session.fixture-refresh" : nil)
        let suite = "herdr.mock.account"
        defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        if signedIn {
            server.signedIn = true
            server.enrolCurrent(name: "Mock iPhone", platform: "ios", devicePub: "fixture-device-pub")
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

    init() {
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
            let features = env["HERDR_MOCK_ACCOUNT_FEATURES"] ?? "native_sign_in,devices,statements,sync,delete"
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
            return (200, ["statements": [], "exp": Int(Date().timeIntervalSince1970) + 600])
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
/// the app shows it, with a Settings button standing in for the connected home's tab.
struct AccountMockRoot: View {
    @ObservedObject private var account = HerdrUpAccount.shared
    @State private var showSettings = false

    var body: some View {
        AccountOnboardingGate {
            ConnectView { _ in }
                .overlay(alignment: .topTrailing) {
                    Button("Settings") { showSettings = true }
                        .accessibilityIdentifier("fixture-open-settings")
                        .buttonStyle(.bordered)
                        .padding(.top, 8).padding(.trailing, 20)
                }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(mode: .owner(HerdrClient(transport: MockTransport())), agents: [],
                         host: "mac.tail-scale.ts.net", onClose: { showSettings = false })
        }
    }
}
#endif
