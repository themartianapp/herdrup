import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HerdrKit

/// The anonymous daily usage ping: the install ID, once per UTC day, the exact body, and the
/// Settings switch.
final class UsagePingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "UsagePingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Records every request and answers each with `status` (nil: no response).
    private final class Relay: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        private var _status: Int?

        init(status: Int?) { _status = status }

        var requests: [URLRequest] { lock.withLock { _requests } }
        var status: Int? {
            get { lock.withLock { _status } }
            set { lock.withLock { _status = newValue } }
        }

        var send: UsagePing.Send {
            { request in
                self.lock.withLock {
                    self._requests.append(request)
                    return self._status
                }
            }
        }
    }

    /// A clock the test moves.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: Date
        init(_ now: Date) { _now = now }
        var now: Date {
            get { lock.withLock { _now } }
            set { lock.withLock { _now = newValue } }
        }
    }

    private func date(_ text: String, in zone: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return try XCTUnwrap(formatter.date(from: text), text)
    }

    private func ping(_ pinger: UsagePing) async -> Bool {
        await pinger.pingIfDue(platform: .ios, version: "1.4.0", build: "231")
    }

    // MARK: Install ID

    func testInstallIDIs16RandomBytesInUnpaddedBase64URL() throws {
        var seen = Set<String>()
        for _ in 0..<200 {
            let id = UsagePing.makeInstallID()
            XCTAssertEqual(id.count, 22, id)
            XCTAssertNotNil(id.range(of: "^[A-Za-z0-9_-]{22}$", options: .regularExpression), id)
            XCTAssertEqual(Base64URL.decode(id)?.count, 16, id)
            seen.insert(id)
        }
        XCTAssertEqual(seen.count, 200, "every ID is fresh")
    }

    func testTheInstallIDIsMadeOnceAndKept() async throws {
        let relay = Relay(status: 204)
        let clock = Clock(try date("2026-11-02 12:00", in: "UTC"))
        let pinger = UsagePing(defaults: defaults, now: { clock.now }, send: relay.send)

        XCTAssertNil(defaults.string(forKey: UsagePing.Key.install))
        _ = await ping(pinger)
        let id = try XCTUnwrap(defaults.string(forKey: UsagePing.Key.install))
        clock.now += 86_400
        _ = await ping(pinger)
        XCTAssertEqual(relay.requests.count, 2)
        for request in relay.requests {
            let body = try XCTUnwrap(request.httpBody)
            XCTAssertTrue(String(decoding: body, as: UTF8.self).contains(#""install":"\#(id)""#))
        }
    }

    // MARK: Once per UTC day

    func testSameUTCDaySendsNothingAndTheNextUTCDaySends() async throws {
        let relay = Relay(status: 204)
        let clock = Clock(try date("2026-11-02 00:00", in: "UTC"))
        let pinger = UsagePing(defaults: defaults, now: { clock.now }, send: relay.send)

        let first = await ping(pinger)
        XCTAssertTrue(first)
        XCTAssertEqual(defaults.string(forKey: UsagePing.Key.lastSentDay), "2026-11-02")
        clock.now = try date("2026-11-02 23:59", in: "UTC")
        let sameDay = await ping(pinger)
        XCTAssertFalse(sameDay)
        XCTAssertEqual(relay.requests.count, 1, "one ping per UTC day")

        clock.now = try date("2026-11-03 00:00", in: "UTC")
        let nextDay = await ping(pinger)
        XCTAssertTrue(nextDay)
        XCTAssertEqual(relay.requests.count, 2)
        XCTAssertEqual(defaults.string(forKey: UsagePing.Key.lastSentDay), "2026-11-03")
    }

    /// The day is the UTC day, not the phone's: local midnight is no new day, and a UTC
    /// midnight in the middle of the local morning is one. Run with a non-UTC default zone so
    /// a local calendar in the implementation would fail.
    func testTheDayIsUTCWhateverThePhonesTimeZone() async throws {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }

        // Los Angeles (UTC-8 in November): 23:50 → 00:10 local is 07:50Z → 08:10Z.
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let relay = Relay(status: 204)
        let clock = Clock(try date("2026-11-02 23:50", in: "America/Los_Angeles"))
        let pinger = UsagePing(defaults: defaults, now: { clock.now }, send: relay.send)
        _ = await ping(pinger)
        XCTAssertEqual(defaults.string(forKey: UsagePing.Key.lastSentDay), "2026-11-03")
        clock.now = try date("2026-11-03 00:10", in: "America/Los_Angeles")
        let pastLocalMidnight = await ping(pinger)
        XCTAssertFalse(pastLocalMidnight, "local midnight is not a new UTC day")
        XCTAssertEqual(relay.requests.count, 1)

        // Tokyo (UTC+9): 08:50 → 09:10 on the same local day crosses UTC midnight.
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let tokyoDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName + ".tokyo"))
        defer { tokyoDefaults.removePersistentDomain(forName: suiteName + ".tokyo") }
        let tokyoRelay = Relay(status: 204)
        let tokyoClock = Clock(try date("2026-11-03 08:50", in: "Asia/Tokyo"))
        let tokyo = UsagePing(defaults: tokyoDefaults, now: { tokyoClock.now }, send: tokyoRelay.send)
        _ = await ping(tokyo)
        XCTAssertEqual(tokyoDefaults.string(forKey: UsagePing.Key.lastSentDay), "2026-11-02")
        tokyoClock.now = try date("2026-11-03 09:10", in: "Asia/Tokyo")
        let pastUTCMidnight = await ping(tokyo)
        XCTAssertTrue(pastUTCMidnight, "UTC midnight is a new day though the local day is the same")
        XCTAssertEqual(tokyoRelay.requests.count, 2)
        XCTAssertEqual(tokyoDefaults.string(forKey: UsagePing.Key.lastSentDay), "2026-11-03")
    }

    func testAFailureRecordsNothingAndTheNextForegroundTriesAgain() async throws {
        let relay = Relay(status: nil)
        let clock = Clock(try date("2026-11-02 12:00", in: "UTC"))
        let pinger = UsagePing(defaults: defaults, now: { clock.now }, send: relay.send)

        let unreachable = await ping(pinger)
        XCTAssertFalse(unreachable)
        XCTAssertNil(defaults.string(forKey: UsagePing.Key.lastSentDay))

        relay.status = 400
        let rejected = await ping(pinger)
        XCTAssertFalse(rejected)
        relay.status = 503
        let unavailable = await ping(pinger)
        XCTAssertFalse(unavailable)
        XCTAssertNil(defaults.string(forKey: UsagePing.Key.lastSentDay), "only a 2xx records the day")
        XCTAssertEqual(relay.requests.count, 3, "each foreground tries again the same day")

        relay.status = 204
        let accepted = await ping(pinger)
        XCTAssertTrue(accepted)
        XCTAssertEqual(defaults.string(forKey: UsagePing.Key.lastSentDay), "2026-11-02")
        let again = await ping(pinger)
        XCTAssertFalse(again)
        XCTAssertEqual(relay.requests.count, 4)
    }

    // MARK: The request

    func testTheRequestIsExactlyTheContractsPOST() async throws {
        let id = Base64URL.encode(Data(repeating: 0xAB, count: 16))
        defaults.set(id, forKey: UsagePing.Key.install)
        let relay = Relay(status: 204)
        let pinger = UsagePing(defaults: defaults, now: { Date(timeIntervalSince1970: 1_793_000_000) },
                               send: relay.send)

        _ = await pinger.pingIfDue(platform: .macosCatalyst, version: "1.4.0", build: "231")
        let request = try XCTUnwrap(relay.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://guest.herdrup.themartian.app/v1/ping")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.allHTTPHeaderFields?.count, 1, "no other header: \(request.allHTTPHeaderFields ?? [:])")
        XCTAssertEqual(String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self),
                       #"{"v":1,"install":"q6urq6urq6urq6urq6urqw","app":"macos-catalyst","version":"1.4.0","build":"231"}"#)
    }

    func testBodyCarriesEachPlatformAndRefusesFieldsTheRelayWouldReject() throws {
        let id = Base64URL.encode(Data(repeating: 0, count: 16))
        for (platform, wire) in [(UsagePing.Platform.ios, "ios"), (.ipados, "ipados"),
                                 (.macosCatalyst, "macos-catalyst")] {
            let body = try XCTUnwrap(UsagePing.body(install: id, platform: platform, version: "2.0", build: "9"))
            XCTAssertEqual(String(decoding: body, as: UTF8.self),
                           #"{"v":1,"install":"AAAAAAAAAAAAAAAAAAAAAA","app":"\#(wire)","version":"2.0","build":"9"}"#)
        }
        XCTAssertNil(UsagePing.body(install: id, platform: .ios, version: #"1"0"#, build: "9"))
        XCTAssertNil(UsagePing.body(install: id, platform: .ios, version: "1.0 beta", build: "9"))
        XCTAssertNil(UsagePing.body(install: id, platform: .ios, version: "", build: "9"))
        XCTAssertNil(UsagePing.body(install: id, platform: .ios, version: "1.0",
                                    build: String(repeating: "9", count: 33)))
        XCTAssertNotNil(UsagePing.body(install: id, platform: .ios, version: "1.0",
                                       build: String(repeating: "9", count: 32)))
        XCTAssertNil(UsagePing.body(install: id + "A", platform: .ios, version: "1.0", build: "9"))
    }

    func testPlatformMapping() {
        XCTAssertEqual(UsagePing.Platform(isiOSAppOnMac: false, isMacCatalystApp: false, isPad: false), .ios)
        XCTAssertEqual(UsagePing.Platform(isiOSAppOnMac: false, isMacCatalystApp: false, isPad: true), .ipados)
        XCTAssertEqual(UsagePing.Platform(isiOSAppOnMac: true, isMacCatalystApp: false, isPad: true), .macosCatalyst,
                       "the iPad app on a Mac reports the pad idiom and is still the Mac")
        XCTAssertEqual(UsagePing.Platform(isiOSAppOnMac: false, isMacCatalystApp: true, isPad: false), .macosCatalyst)
    }

    // MARK: The switch

    func testTheSwitchIsOnByDefault() {
        XCTAssertTrue(UsagePing.isEnabled(in: defaults))
    }

    func testSwitchingOffSendsNothingAndDeletesTheIDAndOnMakesANewOne() async throws {
        let relay = Relay(status: 204)
        let clock = Clock(try date("2026-11-02 12:00", in: "UTC"))
        let pinger = UsagePing(defaults: defaults, now: { clock.now }, send: relay.send)
        _ = await ping(pinger)
        let first = try XCTUnwrap(defaults.string(forKey: UsagePing.Key.install))

        UsagePing.setEnabled(false, in: defaults)
        XCTAssertFalse(UsagePing.isEnabled(in: defaults))
        XCTAssertNil(defaults.string(forKey: UsagePing.Key.install), "off deletes the install ID")
        clock.now += 86_400
        let whileOff = await ping(pinger)
        XCTAssertFalse(whileOff)
        XCTAssertEqual(relay.requests.count, 1, "nothing is sent while off")
        XCTAssertNil(defaults.string(forKey: UsagePing.Key.install), "and no ID is made while off")

        UsagePing.setEnabled(true, in: defaults)
        let second = try XCTUnwrap(defaults.string(forKey: UsagePing.Key.install))
        XCTAssertNotEqual(second, first, "on makes a new ID")
        let backOn = await ping(pinger)
        XCTAssertTrue(backOn)
        let body = String(decoding: try XCTUnwrap(relay.requests.last?.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains(second), body)
    }

    /// Review F1 on #607: the real session must not keep a cookie the relay sets, or a
    /// response could link a new install ID to the old one across an off → on reset.
    func testTheRealSessionNeverReplaysACookieAcrossAReset() async throws {
        let server = try CookieRelay()
        defer { server.stop() }
        let clock = Clock(try date("2026-11-02 12:00", in: "UTC"))
        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/v1/ping"))
        let pinger = UsagePing(endpoint: endpoint, defaults: defaults, now: { clock.now })
        let first = await ping(pinger)
        XCTAssertTrue(first, "the first ping is accepted")

        UsagePing.setEnabled(false, in: defaults)
        UsagePing.setEnabled(true, in: defaults)
        clock.now += 86_400
        let second = await ping(pinger)
        XCTAssertTrue(second, "the second ping is accepted")

        let heads = server.requestHeads()
        XCTAssertEqual(heads.count, 2)
        for head in heads {
            XCTAssertFalse(head.lowercased().contains("\ncookie:"), "a ping carried a cookie:\n\(head)")
        }
    }
}

/// A loopback HTTP server that answers every request 204 with a `Set-Cookie` and records the
/// request head. Plain sockets, as the pairing tests use, so the real URLSession is exercised.
private final class CookieRelay: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private let lock = NSLock()
    private var heads: [String] = []

    init() throws {
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { throw URLError(.cannotConnectToHost) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); throw URLError(.cannotConnectToHost) }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        self.fd = fd
        self.port = Int(UInt16(bigEndian: actual.sin_port))
        Thread { [self] in serve() }.start()
    }

    func requestHeads() -> [String] { lock.withLock { heads } }

    func stop() {
        _ = shutdown(fd, Int32(SHUT_RDWR))
        close(fd)
    }

    private func serve() {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var data = [UInt8]()
            var buffer = [UInt8](repeating: 0, count: 4096)
            // Read the head, then the body by Content-Length.
            while true {
                let n = recv(client, &buffer, buffer.count, 0)
                if n <= 0 { break }
                data.append(contentsOf: buffer[0..<n])
                let text = String(decoding: data, as: UTF8.self)
                guard let end = text.range(of: "\r\n\r\n") else { continue }
                let head = String(text[..<end.lowerBound])
                let length = head.split(separator: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if data.count - text.utf8.distance(from: text.utf8.startIndex, to: end.upperBound) >= length {
                    lock.withLock { heads.append(head.replacingOccurrences(of: "\r\n", with: "\n")) }
                    break
                }
            }
            let reply = "HTTP/1.1 204 No Content\r\nSet-Cookie: relay_tracking=stable-cookie; Path=/\r\nConnection: close\r\n\r\n"
            _ = reply.withCString { send(client, $0, strlen($0), 0) }
            close(client)
        }
    }
}
