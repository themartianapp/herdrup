import Foundation

/// Where the account's refresh token lives. The app backs this with the Keychain (DESIGN
/// §2.5: service `dev.herdr.account`, account `refresh`, after-first-unlock this device only,
/// not synchronizable); tests use memory. A protocol, like `GuestKeyStore`, so HerdrKit stays
/// free of the Security framework and builds on Linux. The access token is never stored.
public protocol AccountTokenStore: Sendable {
    func loadRefreshToken() throws -> String?
    func saveRefreshToken(_ token: String) throws
    /// Succeeds when the token is gone, including when there was none.
    func deleteRefreshToken() throws
}

/// A token store that lives only as long as the process: for tests and screenshots.
public final class InMemoryAccountTokenStore: AccountTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    public init(refreshToken: String? = nil) {
        token = refreshToken
    }

    public func loadRefreshToken() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return token
    }

    public func saveRefreshToken(_ token: String) throws {
        lock.lock(); defer { lock.unlock() }
        self.token = token
    }

    public func deleteRefreshToken() throws {
        lock.lock(); defer { lock.unlock() }
        token = nil
    }
}

/// This device's account session: the tokens, and every authenticated call made with them.
///
/// The refresh token is kept in `AccountTokenStore`, the access token in memory only. A call
/// whose access token is refused (`401 invalid_token`/`token_expired`) refreshes and is
/// retried once. Refresh is single-flight: the service rotates the refresh token at every use
/// and treats a rotated-away token presented again as theft, revoking the whole session
/// (DESIGN §2.5), so concurrent 401s share one refresh and every caller waits for its result.
///
/// The service refusing the refresh (a revoked, expired or unknown session; reuse detected)
/// signs out cleanly: the stored token is deleted, the memory cleared, `onSignOut` told why,
/// and callers get `AccountError.signedOut`. A refresh that doesn't reach the service
/// (offline, timeout) keeps the session and throws `AccountError.unreachable`.
public actor AccountSession {
    /// Why the session ended.
    public enum SignOutReason: Equatable, Sendable {
        /// `signOut()`.
        case user
        /// The service refused the refresh token: expired, signed out elsewhere, the device
        /// removed, or the account gone.
        case sessionEnded
        /// The refresh token was presented after it had been rotated away; the service
        /// revoked the whole session (`401 session_revoked`).
        case sessionRevoked
        /// `deleteAccount` succeeded.
        case accountDeleted
    }

    /// Refresh this long before the access token expires, so a call doesn't race the expiry.
    public static let accessExpiryMargin: TimeInterval = 60

    public nonisolated let client: AccountClient
    private let store: AccountTokenStore
    private let now: @Sendable () -> Date
    private let onSignOut: (@Sendable (SignOutReason) -> Void)?

    private var loaded = false
    private var refreshToken: String?
    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private var accountID: String?
    private var refreshing: Task<String, Error>?
    /// Bumped at every sign-in and sign-out, so a refresh that finishes after either doesn't
    /// bring the old session back.
    private var generation = 0

    /// `onSignOut` runs on the session's executor whenever the session ends (hop to the main
    /// actor yourself). The app clears `StatementCache` and the sync state there.
    public init(client: AccountClient = AccountClient(), store: AccountTokenStore,
                now: @escaping @Sendable () -> Date = { Date() },
                onSignOut: (@Sendable (SignOutReason) -> Void)? = nil) {
        self.client = client
        self.store = store
        self.now = now
        self.onSignOut = onSignOut
    }

    /// Whether this device holds a session. Reads the store once.
    public func isSignedIn() throws -> Bool {
        try loadIfNeeded()
        return refreshToken != nil
    }

    /// The account id, known once this process has signed in or refreshed.
    public var currentAccountID: String? { accountID }

    /// The account id, refreshing first if this process doesn't know it yet.
    public func requireAccountID() async throws -> String {
        if let accountID { return accountID }
        _ = try await refreshed(replacing: accessToken)
        guard let accountID else { throw AccountError.signedOut }
        return accountID
    }

    // MARK: Sign-in and sign-out

    /// The nonce to hand to Apple or Google for `signIn` or `deleteAccount`.
    public func nonce() async throws -> AccountNonce {
        try await client.nonce()
    }

    /// Signs in with a provider's ID token that carries `nonce`, and keeps the session. Any
    /// session this device held before is replaced (sign out first to end it on the service).
    public func signIn(provider: AccountProvider, idToken: String, nonce: String,
                       platform: AccountPlatform) async throws -> AccountSignIn {
        let answer = try await client.signIn(provider: provider, idToken: idToken, nonce: nonce, platform: platform)
        generation += 1
        refreshing = nil
        try adopt(answer.tokens, issuedAt: now())
        return answer
    }

    /// Ends the session on the service when it can be reached, and on this device always.
    public func signOut() async {
        if (try? loadIfNeeded()) != nil, refreshToken != nil {
            try? await authorized { [client] token in try await client.signOut(accessToken: token) }
        }
        end(.user)
    }

    /// `POST /v1/account/delete` with a fresh sign-in of the same account (DESIGN §6.1). On
    /// success the session ends here too (`.accountDeleted`).
    public func deleteAccount(provider: AccountProvider, idToken: String, nonce: String,
                              authorizationCode: String?) async throws -> AccountDeletion {
        let answer = try await authorized { [client] token in
            try await client.deleteAccount(provider: provider, idToken: idToken, nonce: nonce,
                                           authorizationCode: authorizationCode, accessToken: token)
        }
        end(.accountDeleted)
        return answer
    }

    // MARK: Authenticated calls

    /// Runs `call` with a current access token. When the service refuses that token, refreshes
    /// (single-flight) and runs `call` once more with the new one. A second refusal right
    /// after a refresh means the session is gone: it signs out and throws `.signedOut`.
    public func authorized<T: Sendable>(_ call: @Sendable (String) async throws -> T) async throws -> T {
        let token = try await currentAccessToken()
        do {
            return try await call(token)
        } catch let error as AccountError where error.rejectsAccessToken {
            let fresh = try await refreshed(replacing: token)
            do {
                return try await call(fresh)
            } catch let error as AccountError where error.rejectsAccessToken {
                end(.sessionEnded)
                throw AccountError.signedOut
            }
        }
    }

    public func account() async throws -> AccountInfo {
        try await authorized { [client] in try await client.account(accessToken: $0) }
    }

    public func devices() async throws -> [AccountDevice] {
        try await authorized { [client] in try await client.devices(accessToken: $0) }
    }

    public func renameDevice(id: String, name: String) async throws -> AccountDevice {
        try await authorized { [client] in try await client.renameDevice(id: id, name: name, accessToken: $0) }
    }

    /// Removes a device. Removing this session's own device (`current`) ends this session on
    /// the service, so it signs out here too.
    public func removeDevice(_ device: AccountDevice) async throws {
        try await authorized { [client] in try await client.removeDevice(id: device.id, accessToken: $0) }
        if device.current { end(.sessionEnded) }
    }

    // MARK: Tokens

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        refreshToken = try store.loadRefreshToken()
        loaded = true
    }

    private func currentAccessToken() async throws -> String {
        if let accessToken, accessExpiry.timeIntervalSince(now()) > Self.accessExpiryMargin {
            return accessToken
        }
        return try await refreshed(replacing: accessToken)
    }

    /// A fresh access token, replacing `stale`. If another caller already replaced it, that
    /// token is used; if a refresh is in flight, its result is awaited; otherwise this caller
    /// starts the one refresh.
    private func refreshed(replacing stale: String?) async throws -> String {
        if let accessToken, accessToken != stale, accessExpiry.timeIntervalSince(now()) > Self.accessExpiryMargin {
            return accessToken
        }
        if let refreshing { return try await refreshing.value }
        try loadIfNeeded()
        guard let presented = refreshToken else { throw AccountError.signedOut }
        let started = generation
        let task = Task { try await self.performRefresh(presented, generation: started) }
        refreshing = task
        defer { if refreshing == task { refreshing = nil } }
        return try await task.value
    }

    private func performRefresh(_ presented: String, generation started: Int) async throws -> String {
        let issuedAt = now()
        let tokens: AccountTokens
        do {
            tokens = try await client.refresh(refreshToken: presented)
        } catch AccountError.refused(let status, let code, _, _) where (400..<500).contains(status) && status != 429 {
            // Refused for good: a revoked, expired or unknown session, or reuse detected.
            if generation == started { end(code == "session_revoked" ? .sessionRevoked : .sessionEnded) }
            throw AccountError.signedOut
        }
        // Signed out (or in again) while this refresh ran: its tokens belong to no one.
        guard generation == started else { throw AccountError.signedOut }
        try adopt(tokens, issuedAt: issuedAt)
        return tokens.accessToken
    }

    /// Keeps a new pair: the refresh token goes to the store first, so a store failure leaves
    /// this device without a session rather than with one it can't resume.
    private func adopt(_ tokens: AccountTokens, issuedAt: Date) throws {
        do {
            try store.saveRefreshToken(tokens.refreshToken)
        } catch {
            end(.sessionEnded)
            throw error
        }
        loaded = true
        refreshToken = tokens.refreshToken
        accessToken = tokens.accessToken
        accessExpiry = issuedAt.addingTimeInterval(TimeInterval(tokens.accessExpiresIn))
        accountID = tokens.accountID
    }

    /// Forgets the session on this device. Deleting the stored token is best effort: a token
    /// left behind is refused by the service at its next use, which signs out again.
    private func end(_ reason: SignOutReason) {
        let hadSession = refreshToken != nil || accessToken != nil
        generation += 1
        refreshing = nil
        refreshToken = nil
        accessToken = nil
        accessExpiry = .distantPast
        accountID = nil
        loaded = true
        try? store.deleteRefreshToken()
        if hadSession { onSignOut?(reason) }
    }
}
