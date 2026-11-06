import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HerdrKit

/// The app half of relay push (herdrup#277): the `relay_capability` the app adds to token
/// registration, the `notifications.status` answer Settings renders, and the relay enrollment
/// that produces the capability.
final class PushRelayTests: XCTestCase {

    private static let nullResult = #"{"id":"x","result":null}"#

    private func params(_ line: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        return try XCTUnwrap(object?["params"] as? [String: Any], "no params in \(line)")
    }

    // MARK: relay_capability on registration

    /// Without a capability the request is exactly the pre-relay one, so a failed enrollment
    /// behaves as before; with one, the capability rides next to the raw token, which stays so a
    /// machine with its own APNs key keeps pushing directly.
    func testRegisterDeviceSendsCapabilityOnlyWhenPresentAndAlwaysTheToken() async throws {
        let capture = RecordingTransport(reply: Self.nullResult)
        let client = HerdrClient(transport: capture)

        try await client.registerDevice(token: "abcd", needsInput: true, dies: false,
                                        finishes: .off, gram: true)
        var p = try params(capture.lastRequest)
        XCTAssertEqual(p["device_token"] as? String, "abcd")
        XCTAssertNil(p["relay_capability"], "nil capability must be omitted: \(capture.lastRequest)")
        XCTAssertFalse(capture.lastRequest.contains("relay_capability"))

        try await client.registerDevice(token: "abcd", needsInput: true, dies: false,
                                        finishes: .off, gram: true, relayCapability: "hpr1.cap")
        p = try params(capture.lastRequest)
        XCTAssertEqual(p["device_token"] as? String, "abcd", "the raw token must still be sent")
        XCTAssertEqual(p["relay_capability"] as? String, "hpr1.cap")
    }

    func testRegisterActivitySendsCapabilityOnlyWhenPresentAndAlwaysTheToken() async throws {
        let capture = RecordingTransport(reply: Self.nullResult)
        let client = HerdrClient(transport: capture)

        try await client.registerActivity(token: "beef")
        var p = try params(capture.lastRequest)
        XCTAssertEqual(p["activity_push_token"] as? String, "beef")
        XCTAssertFalse(capture.lastRequest.contains("relay_capability"), capture.lastRequest)

        try await client.registerActivity(token: "beef", relayCapability: "hpr1.act")
        p = try params(capture.lastRequest)
        XCTAssertEqual(p["activity_push_token"] as? String, "beef")
        XCTAssertEqual(p["relay_capability"] as? String, "hpr1.act")
    }

    // MARK: notifications.status

    private func availability(reply: String) async -> PushAvailability {
        let capture = RecordingTransport(reply: reply)
        let availability = await HerdrClient(transport: capture).pushAvailability()
        XCTAssertTrue(capture.lastRequest.contains(#""method":"notifications.status""#), capture.lastRequest)
        return availability
    }

    private func statusReply(_ state: String, mode: String = "auto") -> String {
        #"{"id":"x","result":{"type":"notifications_status","state":"\#(state)","mode":"\#(mode)","relay_url":"https://push.herdrup.themartian.app","devices":2,"relay_devices":1}}"#
    }

    func testStatusDecodesEveryKnownState() async {
        let expected: [(String, NotificationsStatus.State)] = [
            ("unsupported", .unsupported), ("off", .off), ("unconfigured", .unconfigured),
            ("direct_ready", .directReady), ("relay_ready", .relayReady),
        ]
        for (wire, state) in expected {
            let result = await availability(reply: statusReply(wire))
            XCTAssertEqual(result, .status(NotificationsStatus(
                state: state, mode: "auto", relayURL: "https://push.herdrup.themartian.app",
                devices: 2, relayDevices: 1)), wire)
        }
    }

    /// A state a newer daemon adds must not read as "update Herdr" (a decode failure would):
    /// push is simply not ready from this app's point of view.
    func testUnknownFutureStateIsTreatedAsUnconfigured() async {
        let result = await availability(reply: statusReply("quantum_ready"))
        guard case .status(let status) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(status.state, .unconfigured)
    }

    /// A herdr that predates the method rejects the request line itself; that is the "update
    /// Herdr on this machine" case. A bridge failure is not an answer and must not say that.
    func testOlderDaemonAndTransportFailureAreDistinguished() async {
        let old = await availability(reply:
            #"{"id":"","error":{"code":"invalid_request","message":"invalid request: unknown variant `notifications.status`"}}"#)
        XCTAssertEqual(old, .daemonTooOld)

        let bridge = await availability(reply:
            #"{"id":"x","error":{"code":"transport_error","message":"api-bridge: Broken pipe (os error 32)"}}"#)
        XCTAssertEqual(bridge, .unreachable)

        // A daemon that knows the method but fails to answer it is not "too old": telling the
        // user to update would send them after the wrong fix.
        let internalError = await availability(reply:
            #"{"id":"x","error":{"code":"internal_error","message":"push store unavailable"}}"#)
        XCTAssertEqual(internalError, .unreachable)
        let otherInvalid = await availability(reply:
            #"{"id":"x","error":{"code":"invalid_request","message":"request line too long"}}"#)
        XCTAssertEqual(otherInvalid, .unreachable)
    }

    // MARK: Relay enrollment

    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "PushRelayTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        StubRelay.reset()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        StubRelay.reset()
        super.tearDown()
    }

    private func enroller(_ environment: PushRelayEnroller.Environment = .sandbox,
                          clock: TestClock = TestClock()) -> PushRelayEnroller {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubRelay.self]
        return PushRelayEnroller(environment: environment,
                                 baseURL: URL(string: "https://relay.test")!,
                                 session: URLSession(configuration: config),
                                 defaults: defaults,
                                 now: { clock.now })
    }

    final class TestClock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private let tokenA = String(repeating: "ab", count: 32)
    private let tokenB = String(repeating: "cd", count: 32)

    func testSuccessfulEnrollmentPostsTheContractBodyAndIsCachedAcrossLaunches() async throws {
        StubRelay.respond = { request in
            (200, #"{"capability":"hpr1.first"}"#)
        }
        let cap = await enroller().capability(kind: .device, token: tokenA.uppercased())
        XCTAssertEqual(cap, "hpr1.first")

        let requests = StubRelay.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.path, "/v1/enroll")
        XCTAssertEqual(request.body["kind"], "device")
        XCTAssertEqual(request.body["token"], tokenA, "the token is sent lowercased")
        XCTAssertEqual(request.body["environment"], "sandbox")

        // A relaunch is a fresh enroller over the same defaults: no second POST.
        let again = await enroller().capability(kind: .device, token: tokenA)
        XCTAssertEqual(again, "hpr1.first")
        XCTAssertEqual(StubRelay.requests.count, 1, "a cached capability must not re-enroll")
    }

    func testFailedEnrollmentReturnsNilCachesNothingAndRetriesOnNextLaunch() async {
        StubRelay.respond = { _ in (429, #"{"error":"rate_limited"}"#) }
        let first = enroller()
        let failed = await first.capability(kind: .device, token: tokenA)
        XCTAssertNil(failed)
        // Right away: not hammered again (registration still goes ahead without a capability).
        _ = await first.capability(kind: .device, token: tokenA)
        XCTAssertEqual(StubRelay.requests.count, 1)

        // Next launch: tried again, and this time it works.
        StubRelay.respond = { _ in (200, #"{"capability":"hpr1.later"}"#) }
        let retried = await enroller().capability(kind: .device, token: tokenA)
        XCTAssertEqual(retried, "hpr1.later")
        XCTAssertEqual(StubRelay.requests.count, 2)
    }

    /// A transient failure (rate limit, dropped network) must not downgrade the whole session:
    /// the same process retries once the retry window has passed.
    func testFailedEnrollmentIsRetriedInTheSameLaunchAfterTheRetryWindow() async {
        StubRelay.respond = { _ in (429, #"{"error":"rate_limited"}"#) }
        let clock = TestClock()
        let relay = enroller(clock: clock)
        let failed = await relay.capability(kind: .device, token: tokenA)
        XCTAssertNil(failed)

        StubRelay.respond = { _ in (200, #"{"capability":"hpr1.recovered"}"#) }
        clock.now += PushRelayEnroller.retryAfter - 1
        let tooSoon = await relay.capability(kind: .device, token: tokenA)
        XCTAssertNil(tooSoon, "inside the window nothing is sent")
        XCTAssertEqual(StubRelay.requests.count, 1)

        clock.now += 2
        let recovered = await relay.capability(kind: .device, token: tokenA)
        XCTAssertEqual(recovered, "hpr1.recovered")
        XCTAssertEqual(StubRelay.requests.count, 2)
    }

    func testUnreachableRelayAndMalformedBodyAreFailures() async {
        let unreachable = await enroller().capability(kind: .device, token: tokenA)
        XCTAssertNil(unreachable)

        StubRelay.respond = { _ in (200, #"{"error":"nope"}"#) }
        let malformed = await enroller().capability(kind: .device, token: tokenB)
        XCTAssertNil(malformed)
        XCTAssertNil(defaults.dictionary(forKey: "pushRelay.capability.device"),
                     "a failure must not leave a cached capability behind")
    }

    func testTokenChangeReEnrolls() async {
        var issued = 0
        StubRelay.respond = { _ in
            issued += 1
            return (200, #"{"capability":"hpr1.n\#(issued)"}"#)
        }
        let first = await enroller().capability(kind: .device, token: tokenA)
        let rotated = await enroller().capability(kind: .device, token: tokenB)
        XCTAssertEqual(first, "hpr1.n1")
        XCTAssertEqual(rotated, "hpr1.n2", "a new token must get its own capability")
        XCTAssertEqual(StubRelay.requests.map { $0.body["token"] }, [tokenA, tokenB])

        // Device and activity tokens are cached independently.
        let activity = await enroller().capability(kind: .activity, token: tokenA)
        XCTAssertEqual(activity, "hpr1.n3")
        XCTAssertEqual(StubRelay.requests.last?.body["kind"], "activity")
        let device = await enroller().capability(kind: .device, token: tokenB)
        XCTAssertEqual(device, "hpr1.n2")
        XCTAssertEqual(StubRelay.requests.count, 3)
    }

    /// A capability sealed for sandbox is useless to a production build (different APNs host),
    /// so switching builds on one install must enroll again.
    func testEnvironmentChangeReEnrolls() async {
        StubRelay.respond = { request in
            (200, #"{"capability":"hpr1.\#(request.body["environment"] ?? "")"}"#)
        }
        let sandbox = await enroller(.sandbox).capability(kind: .device, token: tokenA)
        let production = await enroller(.production).capability(kind: .device, token: tokenA)
        XCTAssertEqual(sandbox, "hpr1.sandbox")
        XCTAssertEqual(production, "hpr1.production")
        XCTAssertEqual(StubRelay.requests.count, 2)
    }
}

/// A `URLProtocol` standing in for the relay: records each request and answers with
/// `respond`. Unset `respond` fails the load like an unreachable host.
final class StubRelay: URLProtocol {
    struct Recorded {
        let method: String
        let url: URL
        let body: [String: String]
    }

    private static let lock = NSLock()
    private static var _requests: [Recorded] = []
    private static var _respond: ((Recorded) -> (Int, String))?

    static var requests: [Recorded] { lock.lock(); defer { lock.unlock() }; return _requests }
    static var respond: ((Recorded) -> (Int, String))? {
        get { lock.lock(); defer { lock.unlock() }; return _respond }
        set { lock.lock(); _respond = newValue; lock.unlock() }
    }
    static func reset() {
        lock.lock(); _requests = []; _respond = nil; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let data = request.httpBody ?? Self.drain(request.httpBodyStream)
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] ?? [:]
        let recorded = Recorded(method: request.httpMethod ?? "", url: request.url!, body: body)
        Self.lock.lock(); Self._requests.append(recorded); Self.lock.unlock()

        guard let (status, text) = Self.respond?(recorded) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
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
