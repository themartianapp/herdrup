import XCTest
@testable import HerdrKit

final class AccountSessionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AccountServiceStub.reset()
    }

    override func tearDown() {
        AccountServiceStub.reset()
        super.tearDown()
    }

    /// Serves `/v1/account` behind `authority`.
    private func serveAccount(_ authority: StubAuthority) {
        AccountServiceStub.handler = { request in
            if let refused = authority.handle(request) { return refused }
            switch request.path {
            case "/v1/account": return .json(200, ["account_id": "AccountAAAAAAAAAAAAAAA", "created_ms": 1_700_000_000_000])
            case "/v1/auth/signout": return .noContent
            default: return .error(404, "not_found")
            }
        }
    }

    final class SignOuts: @unchecked Sendable {
        private let lock = NSLock()
        private var _reasons: [AccountSession.SignOutReason] = []
        var reasons: [AccountSession.SignOutReason] { lock.lock(); defer { lock.unlock() }; return _reasons }
        func record(_ reason: AccountSession.SignOutReason) { lock.lock(); _reasons.append(reason); lock.unlock() }
    }

    // MARK: Single-flight refresh

    func testConcurrent401sShareOneRefresh() async throws {
        let authority = StubAuthority(signedIn: true)
        authority.refreshDelay = 0.3
        serveAccount(authority)
        let store = InMemoryAccountTokenStore()
        let session = makeStubSession(store: store)
        AccountServiceStub.handler = { [handler = AccountServiceStub.handler!] request in
            if request.path == "/v1/auth/apple" { return .json(200, StubTokens.pair(0).merging(["created": false]) { $1 }) }
            return handler(request)
        }
        _ = try await session.signIn(provider: .apple, idToken: "id", nonce: "n", platform: .ios)
        // The hour passes: the in-memory access token is now refused, but the session still
        // thinks it is fresh, so every call below goes out with it and gets a 401.
        authority.expireAccess()

        let results = try await withThrowingTaskGroup(of: AccountInfo.self) { group in
            for _ in 0..<12 { group.addTask { try await session.account() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(results.count, 12)
        XCTAssertEqual(authority.refreshes, 1, "concurrent 401s must cause exactly one refresh")
        XCTAssertEqual(AccountServiceStub.requests(to: "/v1/auth/refresh").count, 1)
        XCTAssertEqual(try store.loadRefreshToken(), StubTokens.refresh(1))
        // Every retry used the one new access token.
        let retries = AccountServiceStub.requests(to: "/v1/account").filter { $0.bearer == StubTokens.access(1) }
        XCTAssertEqual(retries.count, 12)
    }

    func testFirstCallsAfterLaunchShareOneRefresh() async throws {
        // A relaunch: the store holds the refresh token, memory holds no access token.
        let authority = StubAuthority()
        authority.refreshDelay = 0.2
        serveAccount(authority)
        let session = makeStubSession()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { _ = try await session.account() } }
            try await group.waitForAll()
        }

        XCTAssertEqual(authority.refreshes, 1)
        XCTAssertEqual(AccountServiceStub.requests(to: "/v1/account").count, 8, "no call needed a retry")
        let accountID = await session.currentAccountID
        XCTAssertEqual(accountID, "AccountAAAAAAAAAAAAAAA")
    }

    func testReuseRevocationSignsEveryCallerOutWithOneRefresh() async throws {
        let authority = StubAuthority()
        authority.refreshDelay = 0.2
        authority.refreshReply = .error(401, "session_revoked")
        serveAccount(authority)
        let store = InMemoryAccountTokenStore(refreshToken: StubTokens.refresh(0))
        let signOuts = SignOuts()
        let session = makeStubSession(store: store, onSignOut: { reason in signOuts.record(reason) })

        let errors = await withTaskGroup(of: Error?.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    do { _ = try await session.account(); return nil } catch { return error }
                }
            }
            return await group.reduce(into: [Error?]()) { $0.append($1) }
        }

        XCTAssertEqual(errors.count, 6)
        for error in errors { XCTAssertEqual(error as? AccountError, .signedOut) }
        XCTAssertEqual(authority.refreshes, 1)
        XCTAssertNil(try store.loadRefreshToken(), "a revoked session leaves no token behind")
        XCTAssertEqual(signOuts.reasons, [.sessionRevoked])
        let signedIn = try await session.isSignedIn()
        XCTAssertFalse(signedIn)
        // Signed out: no further request reaches the service.
        let before = AccountServiceStub.requests.count
        do {
            _ = try await session.account()
            XCTFail("expected signedOut")
        } catch {
            XCTAssertEqual(error as? AccountError, .signedOut)
        }
        XCTAssertEqual(AccountServiceStub.requests.count, before)
    }

    func testRealReuseOfASpentRefreshTokenIsRevocation() async throws {
        // Another process (or a thief) rotated the token this device holds: presenting it again
        // revokes the session on the service, and the device signs out cleanly.
        let authority = StubAuthority()
        serveAccount(authority)
        let thief = AccountServiceStub.client()
        _ = try await thief.refresh(refreshToken: StubTokens.refresh(0))

        let store = InMemoryAccountTokenStore(refreshToken: StubTokens.refresh(0))
        let signOuts = SignOuts()
        let session = makeStubSession(store: store, onSignOut: { reason in signOuts.record(reason) })
        do {
            _ = try await session.account()
            XCTFail("expected signedOut")
        } catch {
            XCTAssertEqual(error as? AccountError, .signedOut)
        }
        XCTAssertEqual(signOuts.reasons, [.sessionRevoked])
        XCTAssertNil(try store.loadRefreshToken())
    }

    // MARK: 401 → re-auth

    func test401RefreshesAndRetriesOnce() async throws {
        let authority = StubAuthority(signedIn: true)
        serveAccount(authority)
        let store = InMemoryAccountTokenStore()
        let session = makeStubSession(store: store)
        AccountServiceStub.handler = { [handler = AccountServiceStub.handler!] request in
            if request.path == "/v1/auth/google" {
                return .json(200, StubTokens.pair(0).merging(["created": true, "display_hint": "a@example.com"]) { $1 })
            }
            return handler(request)
        }
        let signIn = try await session.signIn(provider: .google, idToken: "id", nonce: "n", platform: .ipados)
        XCTAssertTrue(signIn.created)
        XCTAssertEqual(signIn.displayHint, "a@example.com")
        XCTAssertEqual(try store.loadRefreshToken(), StubTokens.refresh(0))
        authority.expireAccess()

        let account = try await session.account()

        XCTAssertEqual(account.accountID, "AccountAAAAAAAAAAAAAAA")
        XCTAssertEqual(AccountServiceStub.requests.map(\.path),
                       ["/v1/auth/google", "/v1/account", "/v1/auth/refresh", "/v1/account"])
        XCTAssertEqual(AccountServiceStub.requests(to: "/v1/auth/refresh").first?.json["refresh_token"] as? String,
                       StubTokens.refresh(0))
        XCTAssertEqual(try store.loadRefreshToken(), StubTokens.refresh(1), "the rotated token is kept")
    }

    func testRefusedRefreshSignsOutForReauth() async throws {
        let authority = StubAuthority()
        authority.refreshReply = .error(401, "invalid_token")
        serveAccount(authority)
        let store = InMemoryAccountTokenStore(refreshToken: StubTokens.refresh(0))
        let signOuts = SignOuts()
        let session = makeStubSession(store: store, onSignOut: { reason in signOuts.record(reason) })

        do {
            _ = try await session.account()
            XCTFail("expected signedOut")
        } catch {
            XCTAssertEqual(error as? AccountError, .signedOut)
        }
        XCTAssertEqual(signOuts.reasons, [.sessionEnded])
        XCTAssertNil(try store.loadRefreshToken())
        let signedIn = try await session.isSignedIn()
        XCTAssertFalse(signedIn, "the app shows sign-in again")
    }

    func testA401RightAfterARefreshSignsOut() async throws {
        // The device was removed: the refresh still answers (a race), but the session is gone.
        let authority = StubAuthority()
        let signOuts = SignOuts()
        AccountServiceStub.handler = { request in
            if request.path == "/v1/auth/refresh" { return authority.handle(request)! }
            return .error(401, "invalid_token")
        }
        let store = InMemoryAccountTokenStore(refreshToken: StubTokens.refresh(0))
        let session = makeStubSession(store: store, onSignOut: { reason in signOuts.record(reason) })
        // Give it an access token first.
        _ = try? await session.requireAccountID()

        do {
            _ = try await session.devices()
            XCTFail("expected signedOut")
        } catch {
            XCTAssertEqual(error as? AccountError, .signedOut)
        }
        XCTAssertEqual(signOuts.reasons, [.sessionEnded])
        XCTAssertNil(try store.loadRefreshToken())
    }

    func testUnreachableRefreshKeepsTheSession() async throws {
        AccountServiceStub.handler = nil
        let store = InMemoryAccountTokenStore(refreshToken: StubTokens.refresh(0))
        let signOuts = SignOuts()
        let session = makeStubSession(store: store, onSignOut: { reason in signOuts.record(reason) })

        do {
            _ = try await session.account()
            XCTFail("expected unreachable")
        } catch {
            XCTAssertEqual(error as? AccountError, .unreachable)
        }
        XCTAssertEqual(try store.loadRefreshToken(), StubTokens.refresh(0))
        XCTAssertEqual(signOuts.reasons, [])

        // Back online: the same token still works.
        let authority = StubAuthority()
        serveAccount(authority)
        _ = try await session.account()
        XCTAssertEqual(try store.loadRefreshToken(), StubTokens.refresh(1))
    }

    func testRateLimitedRefreshKeepsTheSession() async throws {
        let authority = StubAuthority()
        authority.refreshReply = .error(429, "rate_limited")
        serveAccount(authority)
        let store = InMemoryAccountTokenStore(refreshToken: StubTokens.refresh(0))
        let session = makeStubSession(store: store)

        do {
            _ = try await session.account()
            XCTFail("expected the refusal")
        } catch {
            XCTAssertEqual((error as? AccountError)?.code, "rate_limited")
        }
        XCTAssertEqual(try store.loadRefreshToken(), StubTokens.refresh(0))
    }

    func testAccessTokenIsRefreshedBeforeItExpires() async throws {
        let authority = StubAuthority()
        serveAccount(authority)
        let clock = AccountTestClock()
        let session = makeStubSession(clock: clock)

        _ = try await session.account()
        clock.advance(3600 - AccountSession.accessExpiryMargin - 5)
        _ = try await session.account()
        XCTAssertEqual(authority.refreshes, 1, "still fresh")
        clock.advance(10)
        _ = try await session.account()
        XCTAssertEqual(authority.refreshes, 2, "inside the margin: refreshed before use, no 401")
        XCTAssertEqual(AccountServiceStub.requests(to: "/v1/account").count, 3)
    }

    // MARK: Sign-out and deletion

    func testSignOutEndsTheSessionThereAndHere() async throws {
        let authority = StubAuthority()
        serveAccount(authority)
        let store = InMemoryAccountTokenStore(refreshToken: StubTokens.refresh(0))
        let signOuts = SignOuts()
        let session = makeStubSession(store: store, onSignOut: { reason in signOuts.record(reason) })

        await session.signOut()

        let signout = try XCTUnwrap(AccountServiceStub.requests(to: "/v1/auth/signout").first)
        XCTAssertEqual(signout.method, "POST")
        XCTAssertEqual(signout.bearer, StubTokens.access(1))
        XCTAssertNil(try store.loadRefreshToken())
        XCTAssertEqual(signOuts.reasons, [.user])
    }

    func testSignOutOfflineStillSignsOutHere() async throws {
        AccountServiceStub.handler = nil
        let store = InMemoryAccountTokenStore(refreshToken: StubTokens.refresh(0))
        let session = makeStubSession(store: store)
        await session.signOut()
        XCTAssertNil(try store.loadRefreshToken())
    }

    func testDeleteAccountSendsTheFreshSignInAndSignsOut() async throws {
        let authority = StubAuthority()
        AccountServiceStub.handler = { request in
            if let refused = authority.handle(request) { return refused }
            return .json(200, ["deleted": true, "manual_revoke": true])
        }
        let store = InMemoryAccountTokenStore(refreshToken: StubTokens.refresh(0))
        let signOuts = SignOuts()
        let session = makeStubSession(store: store, onSignOut: { reason in signOuts.record(reason) })

        let answer = try await session.deleteAccount(provider: .apple, idToken: "fresh-id", nonce: "fresh-nonce",
                                                     authorizationCode: "code")

        XCTAssertTrue(answer.manualRevoke)
        let request = try XCTUnwrap(AccountServiceStub.requests(to: "/v1/account/delete").first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.json as? [String: String],
                       ["provider": "apple", "id_token": "fresh-id", "nonce": "fresh-nonce", "authorization_code": "code"])
        XCTAssertNil(try store.loadRefreshToken())
        XCTAssertEqual(signOuts.reasons, [.accountDeleted])
    }

    func testRemovingThisDeviceSignsOut() async throws {
        let authority = StubAuthority()
        AccountServiceStub.handler = { request in
            if let refused = authority.handle(request) { return refused }
            return .noContent
        }
        let store = InMemoryAccountTokenStore(refreshToken: StubTokens.refresh(0))
        let session = makeStubSession(store: store)
        let current = try JSONDecoder().decode(AccountDevice.self, from: Data("""
            {"id":"DeviceAAAAAAAAAAAAAAAA","name":"iPhone","platform":"ios","device_pub":"x","created_ms":1,"current":true}
            """.utf8))

        try await session.removeDevice(current)

        XCTAssertEqual(AccountServiceStub.requests.last?.method, "DELETE")
        XCTAssertEqual(AccountServiceStub.requests.last?.path, "/v1/devices/DeviceAAAAAAAAAAAAAAAA")
        XCTAssertNil(try store.loadRefreshToken())
    }
}
