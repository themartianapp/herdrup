import XCTest
@testable import HerdrKit

final class StatementCacheTests: XCTestCase {
    private let clock = AccountTestClock()
    private var authority: StubAuthority!

    override func setUp() {
        super.setUp()
        AccountServiceStub.reset()
        authority = StubAuthority()
        let clock = clock
        let authority = authority!
        AccountServiceStub.handler = { request in
            if let refused = authority.handle(request) { return refused }
            guard request.path == "/v1/statements", let hosts = request.json["hosts"] as? [String] else {
                return .error(404, "not_found")
            }
            if hosts.count > 50 { return .error(400, "bad_request") }
            let iat = Int(clock.now.timeIntervalSince1970)
            return .json(200, ["statements": hosts.map { ["host": $0, "jws": "jws.\($0).\(iat)"] }, "exp": iat + 600],
                         delay: 0.05)
        }
    }

    override func tearDown() {
        AccountServiceStub.reset()
        super.tearDown()
    }

    private func host(_ n: Int) -> String {
        let digits = String(n)
        return "Host" + String(repeating: "0", count: 18 - digits.count) + digits
    }

    private func cache() -> StatementCache {
        let clock = clock
        return StatementCache(session: makeStubSession(clock: clock), now: { clock.now })
    }

    private var statementRequests: [[String]] {
        AccountServiceStub.requests(to: "/v1/statements").map { $0.json["hosts"] as? [String] ?? [] }
    }

    func testFetchesInBatchesOfFifty() async throws {
        let hosts = (0..<120).map(host)
        let statements = try await cache().statements(for: hosts + [host(3)])

        XCTAssertEqual(Set(statements.keys), Set(hosts))
        XCTAssertEqual(statements[host(7)]?.jws, "jws.\(host(7)).1800000000")
        XCTAssertEqual(statementRequests.map(\.count).sorted(), [20, 50, 50], "the batches go out together")
        XCTAssertEqual(Set(statementRequests.flatMap { $0 }), Set(hosts), "each host asked once")
        XCTAssertEqual(statementRequests.flatMap { $0 }.count, 120)
        XCTAssertEqual(statements[host(0)]?.expires, Date(timeIntervalSince1970: 1_800_000_600))
    }

    func testCachedUntilLessThanTwoMinutesRemain() async throws {
        let cache = cache()
        let first = try await cache.statement(for: host(1))

        clock.advance(600 - 121)
        let cached = try await cache.statement(for: host(1))
        XCTAssertEqual(cached, first)
        XCTAssertEqual(statementRequests.count, 1)

        clock.advance(2)
        let renewed = try await cache.statement(for: host(1))
        XCTAssertNotEqual(renewed.jws, first.jws)
        XCTAssertEqual(statementRequests.count, 2)
        XCTAssertGreaterThan(renewed.expires, first.expires)
    }

    func testOnlyMissingOrStaleHostsAreFetched() async throws {
        let cache = cache()
        _ = try await cache.statements(for: [host(1), host(2)])
        clock.advance(300)
        _ = try await cache.statements(for: [host(3)])
        clock.advance(200) // host 1 and 2: 100 s left; host 3: 400 s left.

        let all = try await cache.statements(for: [host(1), host(2), host(3), host(4)])

        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(statementRequests, [[host(1), host(2)], [host(3)], [host(1), host(2), host(4)]])
    }

    func testConcurrentAsksShareOneRequest() async throws {
        let cache = cache()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { _ = try await cache.statement(for: self.host(9)) } }
            try await group.waitForAll()
        }
        XCTAssertEqual(statementRequests, [[host(9)]])
    }

    func testClearForgetsEverything() async throws {
        let cache = cache()
        _ = try await cache.statement(for: host(1))
        await cache.clear()
        _ = try await cache.statement(for: host(1))
        XCTAssertEqual(statementRequests.count, 2)
    }

    func testInvalidHostIDIsRefusedWithoutARequest() async throws {
        do {
            _ = try await cache().statements(for: [host(1), "not-a-host-id"])
            XCTFail("expected invalidHostID")
        } catch {
            XCTAssertEqual(error as? StatementCache.Failure, .invalidHostID("not-a-host-id"))
        }
        XCTAssertTrue(statementRequests.isEmpty)
    }

    func testDeviceRemovedSurfacesTheRefusal() async throws {
        let authority = authority!
        AccountServiceStub.handler = { request in
            authority.handle(request) ?? .error(403, "device_removed")
        }
        do {
            _ = try await cache().statement(for: host(1))
            XCTFail("expected the refusal")
        } catch {
            XCTAssertEqual((error as? AccountError)?.code, "device_removed")
        }
    }
}
