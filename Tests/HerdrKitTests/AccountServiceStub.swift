import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HerdrKit

/// A `URLProtocol` standing in for the account service: records each request and answers with
/// `handler`. No handler fails the load like an unreachable host. Answers may be delayed, so
/// tests can hold several requests in flight at once.
final class AccountServiceStub: URLProtocol {
    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let authorization: String?
        let body: Data

        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
        /// The bearer token, without "Bearer ".
        var bearer: String? {
            guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
            return String(authorization.dropFirst("Bearer ".count))
        }
    }

    struct Reply {
        var status: Int
        var body: String
        var delay: TimeInterval = 0
        var headers: [String: String] = [:]

        static func json(_ status: Int, _ object: [String: Any], delay: TimeInterval = 0) -> Reply {
            let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return Reply(status: status, body: String(decoding: data, as: UTF8.self), delay: delay)
        }

        static func error(_ status: Int, _ code: String) -> Reply { json(status, ["error": code]) }
        static let noContent = Reply(status: 204, body: "")
    }

    private static let lock = NSLock()
    private static var _requests: [Request] = []
    private static var _handler: ((Request) -> Reply)?

    static var requests: [Request] { lock.lock(); defer { lock.unlock() }; return _requests }
    static var handler: ((Request) -> Reply)? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; lock.unlock() }
    }

    static func reset() {
        lock.lock(); _requests = []; _handler = nil; lock.unlock()
    }

    static func requests(to path: String) -> [Request] { requests.filter { $0.path == path } }

    static func client() -> AccountClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AccountServiceStub.self]
        return AccountClient(baseURL: URL(string: "https://accounts.test")!, session: URLSession(configuration: config))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    /// A cancelled load gets no answer: a delayed reply after `stopLoading` is dropped.
    private let stopLock = NSLock()
    private var stopped = false

    override func stopLoading() {
        stopLock.lock(); stopped = true; stopLock.unlock()
    }

    override func startLoading() {
        let url = request.url!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let recorded = Request(method: request.httpMethod ?? "GET", path: url.path, query: query,
                               authorization: request.value(forHTTPHeaderField: "Authorization"),
                               body: request.httpBody ?? Self.drain(request.httpBodyStream))
        Self.lock.lock(); Self._requests.append(recorded); Self.lock.unlock()

        guard let reply = Self.handler?(recorded) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let finish = { [self] in
            stopLock.lock(); let isStopped = stopped; stopLock.unlock()
            if isStopped { return }
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                           headerFields: reply.headers.merging(["Content-Type": "application/json"]) { $1 })!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: finish)
        } else {
            finish()
        }
    }

    private static func drain(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// A test clock.
final class AccountTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return _now }
        set { lock.lock(); _now = newValue; lock.unlock() }
    }

    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// Session tokens shaped like the service's (`a1.<22>.<43>`, `r1.<22>.<43>`).
enum StubTokens {
    static let sessionID = "SSSSSSSSSSSSSSSSSSSSSS"

    static func access(_ n: Int) -> String { "a1.\(sessionID).\(pad("access\(n)"))" }
    static func refresh(_ n: Int) -> String { "r1.\(sessionID).\(pad("refresh\(n)"))" }

    static func pair(_ n: Int, account: String = "AccountAAAAAAAAAAAAAAA", accessExpiresIn: Int = 3600) -> [String: Any] {
        ["account_id": account, "access_token": access(n), "access_expires_in": accessExpiresIn,
         "refresh_token": refresh(n), "refresh_expires_in": 7_776_000]
    }

    private static func pad(_ text: String) -> String {
        text + String(repeating: "x", count: 43 - text.count)
    }
}

/// A signed-in session against the stub: the store holds `refresh(n)`, and the first call
/// refreshes to get an access token unless `signIn` was used.
func makeStubSession(store: InMemoryAccountTokenStore = InMemoryAccountTokenStore(refreshToken: StubTokens.refresh(0)),
                     clock: AccountTestClock = AccountTestClock(),
                     onSignOut: (@Sendable (AccountSession.SignOutReason) -> Void)? = nil) -> AccountSession {
    AccountSession(client: AccountServiceStub.client(), store: store, now: { clock.now }, onSignOut: onSignOut)
}

/// The service's session rules, as sessions.ts applies them: one current refresh token that
/// rotates at every use, any rotated-away token presented again revokes the session, and only
/// the newest access token is accepted.
final class StubAuthority: @unchecked Sendable {
    private let lock = NSLock()
    /// The number of the session's current refresh token.
    private var refreshNumber = 0
    /// The number of the access token the service accepts; nil once it expired.
    private var accessNumber: Int?
    private var revoked = false
    private var _refreshes = 0
    /// How long a refresh takes to answer.
    var refreshDelay: TimeInterval = 0
    /// When set, the refresh endpoint answers this instead.
    var refreshReply: AccountServiceStub.Reply?

    /// `signedIn`: the access token of pair 0 is current, as right after a sign-in.
    init(signedIn: Bool = false) {
        accessNumber = signedIn ? 0 : nil
    }

    var refreshes: Int { lock.lock(); defer { lock.unlock() }; return _refreshes }

    /// Makes the current access token stale, as an hour passing would.
    func expireAccess() {
        lock.lock(); defer { lock.unlock() }
        accessNumber = nil
    }

    /// The answer to `/v1/auth/refresh`, or to a request with a refused bearer; nil when the
    /// request is authorized and isn't a refresh.
    func handle(_ request: AccountServiceStub.Request) -> AccountServiceStub.Reply? {
        lock.lock(); defer { lock.unlock() }
        if request.path == "/v1/auth/refresh" {
            _refreshes += 1
            if let refreshReply { return refreshReply }
            guard !revoked, let presented = request.json["refresh_token"] as? String else {
                return .error(401, "invalid_token")
            }
            if presented == StubTokens.refresh(refreshNumber) {
                refreshNumber += 1
                accessNumber = refreshNumber
                return .json(200, StubTokens.pair(refreshNumber), delay: refreshDelay)
            }
            if (0..<refreshNumber).contains(where: { StubTokens.refresh($0) == presented }) {
                // A rotated-away token again: theft, the whole session goes.
                revoked = true
                accessNumber = nil
                return .error(401, "session_revoked")
            }
            return .error(401, "invalid_token")
        }
        if revoked { return .error(401, "invalid_token") }
        guard let accessNumber, request.bearer == StubTokens.access(accessNumber) else {
            return .error(401, "token_expired")
        }
        return nil
    }
}
