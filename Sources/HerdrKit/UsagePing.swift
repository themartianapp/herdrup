import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The anonymous daily usage ping (owner request 2026-11-02; the binding contract is
/// fleet-tools `state/herdr-round5-20261029/usage-ping-contract.md`). It exists only to count
/// daily / weekly / monthly active installs by platform and version, which App Store Connect
/// cannot do for users who did not opt in to share with developers.
///
/// At most once per UTC calendar day, `POST {guest relay}/v1/ping` with exactly
/// `{"v":1,"install":…,"app":…,"version":…,"build":…}`. The install ID is 16 random bytes,
/// not derived from any device, Apple or account identifier, and is sent nowhere else.
///
/// UIKit-free so it tests on Linux: the app passes in its platform and version, decides
/// whether a launch may ping at all (never a mock or UI-test launch), and calls `pingIfDue`
/// whenever a scene becomes active.
public actor UsagePing {
    /// The guest relay origin. The app has no other constant for it: guest invites carry
    /// their relay in the link.
    public static let relay = URL(string: "https://guest.herdrup.themartian.app")!
    public static let endpoint = relay.appendingPathComponent("v1/ping")
    public static let timeout: TimeInterval = 10

    /// UserDefaults keys.
    public enum Key {
        /// The Settings › About switch. Absent means on.
        public static let enabled = "usagePing.enabled"
        public static let install = "usagePing.install"
        /// The UTC day (`yyyy-MM-dd`) of the last ping the relay accepted.
        public static let lastSentDay = "usagePing.lastSentDay"
    }

    /// The `app` field: which client this is.
    public enum Platform: String, Sendable {
        case ios
        case ipados
        case macosCatalyst = "macos-catalyst"

        /// The Mac comes first: the iPad app running on a Mac (Designed for iPad) reports
        /// the pad idiom too.
        public init(isiOSAppOnMac: Bool, isMacCatalystApp: Bool, isPad: Bool) {
            if isiOSAppOnMac || isMacCatalystApp {
                self = .macosCatalyst
            } else if isPad {
                self = .ipados
            } else {
                self = .ios
            }
        }
    }

    /// Sends one request and returns the HTTP status, or nil when no response arrived.
    public typealias Send = @Sendable (URLRequest) async -> Int?

    // MARK: The switch

    public static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: Key.enabled) as? Bool ?? true
    }

    /// Off stops pings and deletes the install ID at once; on makes a new ID. The last-sent
    /// day is kept, so switching off and on again does not count this phone twice in a day.
    /// Serialized with a ping's switch check and ID lookup (`enabledInstallID`), so a ping
    /// that is starting can never recreate the ID after the switch has gone off (#623).
    public static func setEnabled(_ on: Bool, in defaults: UserDefaults) {
        switchLock.withLock {
            defaults.set(on, forKey: Key.enabled)
            if on {
                _ = installID(in: defaults)
            } else {
                defaults.removeObject(forKey: Key.install)
            }
        }
    }

    /// Guards the switch and the install ID together. Process-wide: the switch is flipped
    /// on the main actor while a ping runs on the `UsagePing` actor.
    private static let switchLock = NSLock()

    /// The install ID to send, or nil when the switch is off: one step under `switchLock`.
    static func enabledInstallID(in defaults: UserDefaults) -> String? {
        switchLock.withLock { isEnabled(in: defaults) ? installID(in: defaults) : nil }
    }

    // MARK: Pure parts

    /// 16 random bytes, base64url without padding: 22 characters.
    public static func makeInstallID() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Base64URL.encode(Data(bytes))
    }

    /// The stored install ID, made and stored on first use.
    static func installID(in defaults: UserDefaults) -> String {
        if let stored = defaults.string(forKey: Key.install), isInstallID(stored) { return stored }
        let id = makeInstallID()
        defaults.set(id, forKey: Key.install)
        return id
    }

    /// What the relay accepts as `install`: `^[A-Za-z0-9_-]{22}$`.
    static func isInstallID(_ text: String) -> Bool {
        text.utf8.count == 22 && text.utf8.allSatisfy { isBase64URL($0) }
    }

    /// The UTC calendar day of `date`, `yyyy-MM-dd`, whatever the phone's time zone.
    public static func utcDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        func pad(_ value: Int?, _ width: Int) -> String {
            let digits = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return "\(pad(parts.year, 4))-\(pad(parts.month, 2))-\(pad(parts.day, 2))"
    }

    /// The request body, byte for byte as the contract fixes it. Nil when a field is not one
    /// the relay accepts (version and build: 1-32 of `[0-9A-Za-z._-]`), which also means no
    /// field ever needs escaping.
    public static func body(install: String, platform: Platform, version: String, build: String) -> Data? {
        guard isInstallID(install), isVersionField(version), isVersionField(build) else { return nil }
        let json = #"{"v":1,"install":"\#(install)","app":"\#(platform.rawValue)","#
            + #""version":"\#(version)","build":"\#(build)"}"#
        return Data(json.utf8)
    }

    private static func isVersionField(_ text: String) -> Bool {
        (1...32).contains(text.utf8.count)
            && text.utf8.allSatisfy { isBase64URL($0) || $0 == UInt8(ascii: ".") }
    }

    private static func isBase64URL(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
            return true
        default:
            return false
        }
    }

    // MARK: Sending

    private let endpoint: URL
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let send: Send
    /// A foreground that comes while a ping is out (several windows, or a quick
    /// inactive → active) does not send a second one.
    private var sending = false

    public init(endpoint: URL = UsagePing.endpoint,
                defaults: UserDefaults = .standard,
                now: @escaping @Sendable () -> Date = { Date() },
                send: Send? = nil) {
        self.endpoint = endpoint
        self.defaults = defaults
        self.now = now
        self.send = send ?? Self.urlSessionSend()
    }

    /// Sends today's ping if the switch is on and the relay has not accepted one this UTC
    /// day. Only a 2xx records the day; any failure records nothing, so the next foreground
    /// tries again (no retry loop). Returns whether a ping was accepted.
    @discardableResult
    public func pingIfDue(platform: Platform, version: String, build: String) async -> Bool {
        guard !sending else { return false }
        let today = Self.utcDay(now())
        guard defaults.string(forKey: Key.lastSentDay) != today else { return false }
        // The switch check and the ID lookup are one step, so an opt-out can never be
        // followed by a recreated ID (#623).
        guard let install = Self.enabledInstallID(in: defaults),
              let body = Self.body(install: install, platform: platform,
                                   version: version, build: build)
        else { return false }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        // An opt-out that finished while the request was being built stops it here. One that
        // lands after this line cannot stop a request already on its way; the ID it carries
        // is deleted by that opt-out and never recreated.
        guard Self.isEnabled(in: defaults) else { return false }
        sending = true
        let status = await send(request)
        sending = false
        guard let status, (200..<300).contains(status) else { return false }
        defaults.set(today, forKey: Key.lastSentDay)
        return true
    }

    /// A session that keeps nothing between pings: no cookie store (an ephemeral session still
    /// keeps cookies in memory, which a response could use to link install IDs across a reset),
    /// no cache, no credentials.
    static func pingConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        return config
    }

    private static func urlSessionSend() -> Send {
        let session = URLSession(configuration: pingConfiguration())
        return { request in
            guard let (_, response) = try? await session.data(for: request) else { return nil }
            return (response as? HTTPURLResponse)?.statusCode
        }
    }
}
