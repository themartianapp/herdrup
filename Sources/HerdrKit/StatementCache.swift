import Foundation

/// Per-host device statements (DESIGN §3.3): the 10-minute JWS a guest shows a host to say
/// "this device key belongs to my account". Each is cached until less than `refreshMargin`
/// remains, and the hosts that need a new one are asked for together, at most `batchSize` per
/// `POST /v1/statements`. Concurrent asks for the same host share one request.
///
/// Statements are bearer proof for one host only and expire in minutes, so the cache is
/// memory only. The app clears it at sign-out and deletion.
public actor StatementCache {
    /// The most host ids one `POST /v1/statements` takes (statements.ts `MAX_HOSTS`).
    public static let batchSize = 50
    /// Ask again when less than this remains (DESIGN §3.3: 2 minutes).
    public static let refreshMargin: TimeInterval = 120

    public enum Failure: Error, Equatable, Sendable {
        /// Not a host id: 22 characters of base64url, as in the invite.
        case invalidHostID(String)
        /// The service answered without a statement for this host.
        case missingStatement(String)
    }

    public struct Statement: Equatable, Sendable {
        public let host: String
        public let jws: String
        public let expires: Date
    }

    private let session: AccountSession
    private let now: @Sendable () -> Date
    private var cache: [String: Statement] = [:]
    private var inFlight: [String: Task<[String: Statement], Error>] = [:]
    /// Bumped by `clear()`, so a fetch that finishes afterwards isn't cached.
    private var generation = 0

    public init(session: AccountSession, now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.now = now
    }

    /// The statement for one host, fetched when the cached one is missing or near expiry.
    public func statement(for host: String) async throws -> Statement {
        guard let statement = try await statements(for: [host])[host] else { throw Failure.missingStatement(host) }
        return statement
    }

    /// Current statements for `hosts`, keyed by host id. Only the hosts without a fresh one are
    /// fetched, in batches of at most `batchSize`.
    public func statements(for hosts: [String]) async throws -> [String: Statement] {
        var wanted: [String] = []
        for host in hosts where !wanted.contains(host) {
            guard Self.isHostID(host) else { throw Failure.invalidHostID(host) }
            wanted.append(host)
        }
        var result: [String: Statement] = [:]
        var waits: [Task<[String: Statement], Error>] = []
        var missing: [String] = []
        for host in wanted {
            if let cached = cache[host], isFresh(cached) {
                result[host] = cached
            } else if let task = inFlight[host] {
                if !waits.contains(task) { waits.append(task) }
            } else {
                missing.append(host)
            }
        }
        for start in stride(from: 0, to: missing.count, by: Self.batchSize) {
            let batch = Array(missing[start..<min(start + Self.batchSize, missing.count)])
            let task = Task { try await self.fetch(batch) }
            for host in batch { inFlight[host] = task }
            waits.append(task)
        }
        for task in waits {
            for (host, statement) in try await task.value where wanted.contains(host) {
                result[host] = statement
            }
        }
        for host in wanted where result[host] == nil { throw Failure.missingStatement(host) }
        return result
    }

    /// Forgets every statement: at sign-out, deletion, or when this device was removed.
    public func clear() {
        generation += 1
        cache = [:]
        inFlight = [:]
    }

    private func isFresh(_ statement: Statement) -> Bool {
        statement.expires.timeIntervalSince(now()) >= Self.refreshMargin
    }

    private func fetch(_ hosts: [String]) async throws -> [String: Statement] {
        let started = generation
        defer {
            if generation == started { for host in hosts { inFlight[host] = nil } }
        }
        let client = session.client
        let batch = try await session.authorized { try await client.statements(hosts: hosts, accessToken: $0) }
        let expires = Date(timeIntervalSince1970: TimeInterval(batch.exp))
        var fetched: [String: Statement] = [:]
        for item in batch.statements where hosts.contains(item.host) {
            fetched[item.host] = Statement(host: item.host, jws: item.jws, expires: expires)
        }
        if generation == started { cache.merge(fetched) { $1 } }
        return fetched
    }

    static func isHostID(_ text: String) -> Bool {
        text.utf8.count == 22 && text.utf8.allSatisfy { byte in
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x2D || byte == 0x5F
        }
    }
}
