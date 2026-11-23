import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Typed calls to the account service (`accounts.herdrup.app`, AccountService/ in this repo;
/// DESIGN #698 §2, §3, §5, §6). One method per endpoint, nothing more: no token handling, no
/// retries. `AccountSession` adds the tokens and the single-flight refresh; `DeviceEnroller`,
/// `StatementCache` and `SyncEngine` are built on that.
///
/// Authenticated calls take the access token as their last argument. Every answer the service
/// gives is `no-store`, so the session keeps no cache and no cookies: apps send the refresh
/// token in the body (DESIGN §2.5), never as a cookie.
public struct AccountClient: Sendable {
    public static let productionBaseURL = URL(string: "https://accounts.herdrup.app")!
    public static let timeout: TimeInterval = 20

    public let baseURL: URL
    private let session: URLSession

    /// `session` is for tests (a `URLProtocol` stub); the default is an ephemeral session with
    /// no cache and no cookies.
    public init(baseURL: URL = AccountClient.productionBaseURL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = Self.timeout
            config.urlCache = nil
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: Health

    /// `GET /v1/health`: the service's version and the features this deployment offers, so an
    /// app shows only the sign-in providers the service is configured for.
    public func health() async throws -> AccountHealth {
        try await send("GET", "v1/health")
    }

    // MARK: Sign-in and sessions (DESIGN §2.2, §2.5)

    /// `POST /v1/auth/nonce`: the nonce to hand to Apple (`request.nonce`) or Google (`nonce`).
    public func nonce() async throws -> AccountNonce {
        try await send("POST", "v1/auth/nonce")
    }

    /// `POST /v1/auth/apple` or `/v1/auth/google` with the provider's ID token and the nonce it
    /// carries. Opens a session.
    public func signIn(provider: AccountProvider, idToken: String, nonce: String,
                       platform: AccountPlatform) async throws -> AccountSignIn {
        try await send("POST", "v1/auth/\(provider.rawValue)",
                       body: SignInRequest(idToken: idToken, nonce: nonce, platform: platform))
    }

    /// `POST /v1/auth/refresh`: rotates the pair. The presented refresh token is spent whatever
    /// happens to the answer, so callers refresh one at a time (`AccountSession`).
    public func refresh(refreshToken: String) async throws -> AccountTokens {
        try await send("POST", "v1/auth/refresh", body: ["refresh_token": refreshToken])
    }

    /// `POST /v1/auth/signout`: ends this session on the service.
    public func signOut(accessToken: String) async throws {
        try await sendNoContent("POST", "v1/auth/signout", bearer: accessToken)
    }

    /// `GET /v1/account`.
    public func account(accessToken: String) async throws -> AccountInfo {
        try await send("GET", "v1/account", bearer: accessToken)
    }

    /// `POST /v1/account/delete` (DESIGN §6.5) with a fresh sign-in of the same account.
    /// `authorizationCode` is Apple's, so the service can revoke the Apple grant.
    public func deleteAccount(provider: AccountProvider, idToken: String, nonce: String,
                              authorizationCode: String?, accessToken: String) async throws -> AccountDeletion {
        try await send("POST", "v1/account/delete", bearer: accessToken,
                       body: DeleteRequest(provider: provider, idToken: idToken, nonce: nonce,
                                           authorizationCode: authorizationCode))
    }

    // MARK: Devices (DESIGN §3.2)

    /// `POST /v1/devices/challenge`: a 60-second, one-use enrolment challenge for this session.
    public func deviceChallenge(accessToken: String) async throws -> DeviceChallenge {
        try await send("POST", "v1/devices/challenge", bearer: accessToken)
    }

    /// `POST /v1/devices`: enrols `devicePub` with the proof `DeviceEnroller.proof` computes.
    public func enrolDevice(challengeID: String, devicePub: String, mac: String, name: String,
                            platform: AccountPlatform, accessToken: String) async throws -> AccountDevice {
        let answer: DeviceAnswer = try await send(
            "POST", "v1/devices", bearer: accessToken,
            body: EnrolRequest(challengeID: challengeID, devicePub: devicePub, mac: mac, name: name, platform: platform))
        return answer.device
    }

    /// `GET /v1/devices`: every device of the account; `current` marks this session's.
    public func devices(accessToken: String) async throws -> [AccountDevice] {
        let answer: DeviceList = try await send("GET", "v1/devices", bearer: accessToken)
        return answer.devices
    }

    /// `PATCH /v1/devices/<id>`.
    public func renameDevice(id: String, name: String, accessToken: String) async throws -> AccountDevice {
        let answer: DeviceAnswer = try await send("PATCH", "v1/devices/\(id)", bearer: accessToken, body: ["name": name])
        return answer.device
    }

    /// `DELETE /v1/devices/<id>`: the sessions bound to that device end with it.
    public func removeDevice(id: String, accessToken: String) async throws {
        try await sendNoContent("DELETE", "v1/devices/\(id)", bearer: accessToken)
    }

    // MARK: Statements (DESIGN §3.3)

    /// `POST /v1/statements` for at most `StatementCache.batchSize` host ids.
    public func statements(hosts: [String], accessToken: String) async throws -> StatementBatch {
        try await send("POST", "v1/statements", bearer: accessToken, body: ["hosts": hosts])
    }

    // MARK: Browser approvals (web owner access WIRE-PLAN §2.4; `BrowserApproval` runs them)

    /// `GET /v1/approvals`: the browsers waiting for this account's approval.
    public func approvals(accessToken: String) async throws -> [ApprovalRequest] {
        let answer: ApprovalList = try await send("GET", "v1/approvals", bearer: accessToken)
        return answer.requests
    }

    /// `POST /v1/approvals/<id>/claim` with `nonce_t`. The service records this session's
    /// device as the approver, never one from the body. `409 already_claimed`.
    public func claimApproval(id: String, nonceT: Data, accessToken: String) async throws {
        let _: JSONNull = try await send("POST", "v1/approvals/\(id)/claim", bearer: accessToken,
                                         body: ["nonce_t": Base64URL.encode(nonceT)])
    }

    /// `GET /v1/approvals/<id>`.
    public func approvalState(id: String, accessToken: String) async throws -> ApprovalStatus {
        try await send("GET", "v1/approvals/\(id)", bearer: accessToken)
    }

    /// `POST /v1/approvals/<id>/finish` as approved, with the grants made and the sealed list.
    public func approveBrowser(id: String, report: ApprovalReport, accessToken: String) async throws {
        let _: JSONNull = try await send("POST", "v1/approvals/\(id)/finish", bearer: accessToken,
                                         body: FinishApproved(report: report))
    }

    /// `POST /v1/approvals/<id>/finish` as denied.
    public func denyBrowser(id: String, accessToken: String) async throws {
        let _: JSONNull = try await send("POST", "v1/approvals/\(id)/finish", bearer: accessToken,
                                         body: ["outcome": "denied"])
    }

    // MARK: Sync (DESIGN §5.2, §5.5)

    /// `GET /v1/sync?since=<rev>`; `since` 0 is a full pull.
    public func pull(since: Int, accessToken: String) async throws -> SyncPage {
        try await send("GET", "v1/sync", query: [URLQueryItem(name: "since", value: String(since))], bearer: accessToken)
    }

    /// `GET /v1/sync?cursor=<cursor>`: the next page, with the cursor the last one carried.
    public func pull(cursor: String, accessToken: String) async throws -> SyncPage {
        try await send("GET", "v1/sync", query: [URLQueryItem(name: "cursor", value: cursor)], bearer: accessToken)
    }

    /// `POST /v1/sync`.
    public func push(_ changes: [SyncChange], accessToken: String) async throws -> SyncPushResult {
        try await send("POST", "v1/sync", bearer: accessToken, body: SyncPushRequest(changes: changes))
    }

    // MARK: Transport

    private func request(_ method: String, _ path: String, query: [URLQueryItem], bearer: String?,
                         body: (any Encodable)?) throws -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw AccountError.malformedResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    private func data(for request: URLRequest) async throws -> (Data, Int) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AccountError.unreachable
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw AccountError.unreachable }
        guard (200..<300).contains(status) else {
            let refusal = try? JSONDecoder().decode(Refusal.self, from: data)
            throw AccountError.refused(status: status, code: refusal?.error ?? "", field: refusal?.field, index: refusal?.index)
        }
        return (data, status)
    }

    private func send<Answer: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [],
                                         bearer: String? = nil, body: (any Encodable)? = nil) async throws -> Answer {
        let (data, _) = try await data(for: request(method, path, query: query, bearer: bearer, body: body))
        do {
            return try JSONDecoder().decode(Answer.self, from: data)
        } catch {
            throw AccountError.malformedResponse
        }
    }

    private func sendNoContent(_ method: String, _ path: String, bearer: String) async throws {
        _ = try await data(for: request(method, path, query: [], bearer: bearer, body: nil))
    }

    private struct Refusal: Decodable {
        let error: String
        let field: String?
        let index: Int?
    }
}

/// What an account call can fail with.
public enum AccountError: Error, Equatable, Sendable {
    /// No session on this device: never signed in, signed out, or the service ended it.
    case signedOut
    /// The service could not be reached or didn't answer in time. The session is kept.
    case unreachable
    /// A success answer this build can't read.
    case malformedResponse
    /// The service refused: its HTTP status and `error` code, as AccountService/src answers
    /// them (`invalid_token`, `device_in_other_account`, `reset_required`, `quota`, …). A sync
    /// push refused for one change also names the change (`index`) and the key at fault (`field`).
    case refused(status: Int, code: String, field: String? = nil, index: Int? = nil)

    /// The service's error code, when it refused.
    public var code: String? {
        if case .refused(_, let code, _, _) = self { return code }
        return nil
    }

    /// The access token was refused (`401 invalid_token` or `token_expired`, the codes
    /// `authenticate` in sessions.ts gives). Other 401s (`token_invalid`, `nonce_used`, …) are
    /// about an ID token or a nonce, not the session.
    var rejectsAccessToken: Bool {
        guard case .refused(401, let code, _, _) = self else { return false }
        return code == "invalid_token" || code == "token_expired"
    }
}

public enum AccountProvider: String, Codable, Sendable {
    case apple
    case google
}

/// The `platform` the service records per session and device (sessions.ts `PLATFORMS`).
public enum AccountPlatform: String, Codable, Sendable {
    case ios, ipados, macos, windows, linux, web
}

/// `GET /v1/health`'s answer. `features` are flags about the deployment's configuration
/// (AccountService/src/index.ts `features`); an app offers a flow only when its flag is listed.
public struct AccountHealth: Decodable, Equatable, Sendable {
    /// Native ID-token sign-in (`/v1/auth/apple`, `/v1/auth/google`); Apple's app client.
    public static let nativeSignIn = "native_sign_in"
    /// Native Google sign-in with the Google iOS client (`GOOGLE_IOS_CLIENT_ID` configured).
    public static let nativeSignInGoogle = "native_sign_in_google"

    /// Browser approvals for web owner access (`/v1/approvals`, WIRE-PLAN §2.4).
    public static let webApprove = "web_approve"

    public let version: String
    public let features: [String]

    public init(version: String, features: [String]) {
        self.version = version
        self.features = features
    }

    public func offers(_ feature: String) -> Bool { features.contains(feature) }
}

public struct AccountNonce: Decodable, Equatable, Sendable {
    public let nonce: String
    /// Unix seconds; the nonce is good for 10 minutes.
    public let expiresUnix: Int

    enum CodingKeys: String, CodingKey {
        case nonce
        case expiresUnix = "expires_unix"
    }
}

/// A session's token pair. `accessToken` lives an hour and stays in memory; `refreshToken`
/// lives 90 days, rotates at every refresh, and is the only thing `AccountTokenStore` keeps.
public struct AccountTokens: Decodable, Equatable, Sendable {
    public let accountID: String
    public let accessToken: String
    /// Seconds.
    public let accessExpiresIn: Int
    public let refreshToken: String
    /// Seconds.
    public let refreshExpiresIn: Int

    public init(accountID: String, accessToken: String, accessExpiresIn: Int, refreshToken: String, refreshExpiresIn: Int) {
        self.accountID = accountID
        self.accessToken = accessToken
        self.accessExpiresIn = accessExpiresIn
        self.refreshToken = refreshToken
        self.refreshExpiresIn = refreshExpiresIn
    }

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case accessToken = "access_token"
        case accessExpiresIn = "access_expires_in"
        case refreshToken = "refresh_token"
        case refreshExpiresIn = "refresh_expires_in"
    }
}

/// The answer to a sign-in: the pair, whether the account is new, and for Google the email
/// the service passes through once (`display_hint`, never stored there). Show it, don't keep it.
public struct AccountSignIn: Decodable, Equatable, Sendable {
    public let tokens: AccountTokens
    public let created: Bool
    public let displayHint: String?

    enum CodingKeys: String, CodingKey {
        case created
        case displayHint = "display_hint"
    }

    public init(from decoder: Decoder) throws {
        tokens = try AccountTokens(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        created = try container.decode(Bool.self, forKey: .created)
        displayHint = try container.decodeIfPresent(String.self, forKey: .displayHint)
    }
}

public struct AccountInfo: Decodable, Equatable, Sendable {
    public let accountID: String
    /// Unix milliseconds.
    public let createdMs: Int

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case createdMs = "created_ms"
    }
}

public struct AccountDeletion: Decodable, Equatable, Sendable {
    public let deleted: Bool
    /// Apple didn't confirm the revoke: show Apple's manual path (Settings → Apple Account →
    /// Sign in with Apple → HerdrUp → Stop using). The account is gone either way.
    public let manualRevoke: Bool

    enum CodingKeys: String, CodingKey {
        case deleted
        case manualRevoke = "manual_revoke"
    }
}

/// `POST /v1/devices/challenge`'s answer. Keys and salt are unpadded base64url.
public struct DeviceChallenge: Decodable, Equatable, Sendable {
    public let challengeID: String
    public let serverPub: String
    public let salt: String
    public let accountID: String
    /// Seconds.
    public let expiresIn: Int

    public init(challengeID: String, serverPub: String, salt: String, accountID: String, expiresIn: Int) {
        self.challengeID = challengeID
        self.serverPub = serverPub
        self.salt = salt
        self.accountID = accountID
        self.expiresIn = expiresIn
    }

    enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case serverPub = "server_pub"
        case salt
        case accountID = "account_id"
        case expiresIn = "expires_in"
    }
}

public struct AccountDevice: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// An `AccountPlatform` raw value, kept as text so a newer platform still lists.
    public let platform: String
    /// The device's guest key (X25519), unpadded base64url.
    public let devicePub: String
    /// Unix milliseconds.
    public let createdMs: Int
    /// This session's own device.
    public let current: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, platform, current
        case devicePub = "device_pub"
        case createdMs = "created_ms"
    }
}

public struct HostStatement: Decodable, Equatable, Sendable {
    /// The host id (22-character base64url, from the invite).
    public let host: String
    /// The compact EdDSA JWS the host checks (DESIGN §3.3).
    public let jws: String
}

public struct StatementBatch: Decodable, Equatable, Sendable {
    public let statements: [HostStatement]
    /// Unix seconds, the same for every statement of the batch.
    public let exp: Int
}

private struct SignInRequest: Encodable {
    let idToken: String
    let nonce: String
    let platform: AccountPlatform

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case nonce, platform
    }
}

private struct DeleteRequest: Encodable {
    let provider: AccountProvider
    let idToken: String
    let nonce: String
    let authorizationCode: String?

    enum CodingKeys: String, CodingKey {
        case provider, nonce
        case idToken = "id_token"
        case authorizationCode = "authorization_code"
    }
}

private struct EnrolRequest: Encodable {
    let challengeID: String
    let devicePub: String
    let mac: String
    let name: String
    let platform: AccountPlatform

    enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case devicePub = "device_pub"
        case mac, name, platform
    }
}

private struct DeviceAnswer: Decodable {
    let device: AccountDevice
}

private struct DeviceList: Decodable {
    let devices: [AccountDevice]
}

private struct SyncPushRequest: Encodable {
    let changes: [SyncChange]
}
