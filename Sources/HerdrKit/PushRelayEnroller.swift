import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Enrolls an APNs token with the publisher-run push relay (`POST /v1/enroll`) and returns the
/// sealed capability the app hands to the daemon as `relay_capability`. With it, a daemon that
/// has no APNs key of its own can still push to this device through the relay.
///
/// The capability is opaque: it is cached and sent back, never parsed. It is cached per
/// (kind, token, environment) in `UserDefaults`, so a relaunch registers straight away without
/// a network round trip, and a rotated token misses the cache and enrolls again. A failed
/// enrollment returns nil (the caller registers without a capability); the same token is
/// retried after `retryAfter` in this process, and at once on the next launch.
public actor PushRelayEnroller {
    public enum Kind: String, Sendable {
        /// The app's APNs device token (alert pushes).
        case device
        /// A Live Activity's per-activity push token.
        case activity
    }

    /// Which APNs host the relay pushes through. Debug builds hold sandbox tokens; TestFlight
    /// and the App Store hold production ones. The app decides, since only it knows its build.
    public enum Environment: String, Sendable {
        case production
        case sandbox
    }

    public static let defaultBaseURL = URL(string: "https://push.herdrup.app")!
    public static let timeout: TimeInterval = 10

    private let baseURL: URL
    private let environment: Environment
    private let session: URLSession
    private let defaults: UserDefaults
    /// Coalesces concurrent asks for the same token (connect and a prefs toggle can race) into
    /// one POST.
    private var inFlight: [String: Task<String?, Never>] = [:]
    /// When enrollment last failed, per token. Most failures (a rate limit, a dropped network) are
    /// transient, so a token is retried once `retryAfter` has passed; within that window
    /// registration goes ahead without a capability instead of hammering the relay. Not
    /// persisted: a relaunch retries at once.
    private var failedAt: [String: Date] = [:]
    public static let retryAfter: TimeInterval = 5 * 60
    private let now: @Sendable () -> Date

    public init(environment: Environment,
                baseURL: URL = PushRelayEnroller.defaultBaseURL,
                session: URLSession? = nil,
                defaults: UserDefaults = .standard,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.environment = environment
        self.now = now
        self.baseURL = baseURL
        self.defaults = defaults
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = Self.timeout
            config.timeoutIntervalForResource = Self.timeout
            self.session = URLSession(configuration: config)
        }
    }

    /// The relay capability for `token`, from the cache or a fresh enrollment. Nil when the relay
    /// could not be reached or refused the token.
    public func capability(kind: Kind, token: String) async -> String? {
        let token = token.lowercased()
        if let cached = cached(kind: kind, token: token) { return cached }
        let key = "\(kind.rawValue)|\(environment.rawValue)|\(token)"
        if let last = failedAt[key], now().timeIntervalSince(last) < Self.retryAfter { return nil }
        if let pending = inFlight[key] { return await pending.value }

        let task = Task { await Self.enroll(kind: kind, token: token, environment: environment,
                                            baseURL: baseURL, session: session) }
        inFlight[key] = task
        let capability = await task.value
        inFlight[key] = nil
        if let capability {
            store(capability, kind: kind, token: token)
            failedAt[key] = nil
        } else {
            failedAt[key] = now()
        }
        return capability
    }

    // MARK: Cache

    private func defaultsKey(_ kind: Kind) -> String { "pushRelay.capability.\(kind.rawValue)" }

    /// One slot per kind: only the current device token and the current activity token matter,
    /// so a rotated token overwrites its predecessor instead of accumulating.
    private func cached(kind: Kind, token: String) -> String? {
        guard let entry = defaults.dictionary(forKey: defaultsKey(kind)) as? [String: String],
              entry["token"] == token, entry["environment"] == environment.rawValue,
              let capability = entry["capability"], !capability.isEmpty
        else { return nil }
        return capability
    }

    private func store(_ capability: String, kind: Kind, token: String) {
        defaults.set(["token": token, "environment": environment.rawValue, "capability": capability],
                     forKey: defaultsKey(kind))
    }

    // MARK: Network

    private struct EnrollRequest: Encodable {
        let kind: String
        let token: String
        let environment: String
    }

    private struct EnrollResponse: Decodable {
        let capability: String
    }

    private static func enroll(kind: Kind, token: String, environment: Environment,
                               baseURL: URL, session: URLSession) async -> String? {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/enroll"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONEncoder().encode(
            EnrollRequest(kind: kind.rawValue, token: token, environment: environment.rawValue))
        else { return nil }
        request.httpBody = body
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(EnrollResponse.self, from: data),
              !decoded.capability.isEmpty
        else { return nil }
        return decoded.capability
    }
}
