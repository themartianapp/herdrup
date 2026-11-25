import Foundation
import XCTest
@testable import HerdrKit

/// Account-bound guest shares on the wire herdr #440 speaks (src/guest/store.rs `admit_in`,
/// src/guest/link/session.rs `Refresh`): the invite's `acct`, `account` in the redemption and
/// returning hellos, and the in-band `account.refresh` before the statement's deadline.
final class GuestAccountStatementTests: XCTestCase {
    let identity = GuestIdentity(privateKey: .init())

    /// The issued statement of AccountService/test/vectors/statement-v1.json, the one herdr's
    /// account tests verify.
    func vectorJWS() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AccountService/test/vectors/statement-v1.json")
        let vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let issued = try XCTUnwrap(vectors["issued"] as? [String: Any])
        return try XCTUnwrap(issued["jws"] as? String)
    }

    func invite(for host: FakeHost, acct: Bool) -> GuestInvite {
        GuestInvite(
            relay: host.endpoint.relay, hostID: host.hostID, hostPublicKey: host.endpoint.hostPublicKey,
            inviteID: Base64URL.encode(Data(repeating: 3, count: 16)), secret: Base64URL.encode(Data(repeating: 4, count: 32)),
            machineLabel: "Jerry's Mac Studio", ownerName: "Jerry", agentName: "llm-opt", guestName: "plotarmordev",
            expires: Date().addingTimeInterval(3600), acceptsAccount: acct)
    }

    func acceptingHost() -> FakeHost {
        let host = FakeHost()
        host.reply = ["ok": true, "guest_id": "g_1", "name": "plotarmordev", "agent": ["name": "llm-opt", "target": "w1-3"]]
        return host
    }

    func multiRequestHost() -> FakeHost {
        let host = FakeHost()
        host.reply = ["ok": true, "guest_id": "g_1", "features": ["multi_request": true]]
        host.closeAfterServe = nil
        host.serve = { line in [Data(GuestSessionReuseTests.reply(to: line).utf8 + [0x0a])] }
        return host
    }

    func waitUntil(_ condition: @escaping () -> Bool, within seconds: TimeInterval = 3,
                   file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "timed out waiting", file: file, line: line)
    }

    // MARK: Invite

    func testTheInviteReadsAcct() throws {
        let host = FakeHost()
        let bound = invite(for: host, acct: true)
        let json = try GuestInvite.json(fromPayload: bound.payload)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: json) as? [String: Any])?["acct"] as? Int, 1)
        XCTAssertTrue(try GuestInvite.decode(json: json).acceptsAccount)

        let plain = invite(for: host, acct: false)
        let plainJSON = try GuestInvite.json(fromPayload: plain.payload)
        XCTAssertNil((try JSONSerialization.jsonObject(with: plainJSON) as? [String: Any])?["acct"],
                     "an invite from a host without accounts has no acct")
        XCTAssertFalse(try GuestInvite.decode(json: plainJSON).acceptsAccount)
    }

    // MARK: Redemption

    func testRedemptionWithAccountCarriesTheStatement() async throws {
        let host = acceptingHost()
        let jws = try vectorJWS()
        let statements = StubStatements([.success(.init(host: host.hostID, jws: jws, expires: Date().addingTimeInterval(600)))])
        let invite = invite(for: host, acct: true)

        let access = try await GuestSession.accept(invite, identity: identity, bindToAccount: true,
                                                   statements: statements, connector: host.connector())

        XCTAssertEqual(host.hellos.first as NSDictionary?, [
            "v": 1, "invite_id": invite.inviteID, "secret": invite.secret, "device": "iPhone", "account": jws,
        ] as NSDictionary)
        XCTAssertEqual(statements.asked, [host.hostID], "the statement is for the invite's host")
        XCTAssertTrue(access.accountBound)
        let saved = try JSONDecoder().decode(GuestAccess.self, from: JSONEncoder().encode(access))
        XCTAssertEqual(saved, access, "the saved grant remembers it is account-bound")
    }

    func testAcceptWithoutBindingStaysPlainEvenOnAnAcctInvite() async throws {
        let host = acceptingHost()
        let statements = StubStatements([])
        let invite = invite(for: host, acct: true)

        let access = try await GuestSession.accept(invite, identity: identity, statements: statements, connector: host.connector())

        XCTAssertNil(host.hellos.first?["account"])
        XCTAssertTrue(statements.asked.isEmpty)
        XCTAssertFalse(access.accountBound)
    }

    func testASavedGrantFromBeforeIsPlain() throws {
        let host = FakeHost()
        let old = GuestAccess(guestID: "g_1", guestName: "plotarmordev", machineLabel: "Mac", ownerName: "Jerry",
                              agentName: "llm-opt", agentTarget: "w1-3", endpoint: host.endpoint, acceptedAt: Date(timeIntervalSince1970: 0))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object["accountBound"] = nil
        let decoded = try JSONDecoder().decode(GuestAccess.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(decoded.accountBound)
        XCTAssertEqual(decoded, old)
    }

    func testARefusedStatementRedeemsNothing() async throws {
        for (thrown, expected) in [
            (AccountError.refused(status: 403, code: "device_not_enrolled") as Error, AccountStatementFailure.refused("device_not_enrolled")),
            (AccountError.unreachable, .unreachable),
            (AccountError.signedOut, .signedOut),
        ] {
            let host = acceptingHost()
            let connector = host.connector()
            let statements = StubStatements([.failure(thrown)])
            do {
                _ = try await GuestSession.accept(invite(for: host, acct: true), identity: identity, bindToAccount: true,
                                                  statements: statements, connector: connector)
                XCTFail("a bound redemption without a statement must not go plain")
            } catch {
                XCTAssertEqual(error as? GuestError, .accountStatement(expected))
            }
            XCTAssertTrue(connector.sockets.isEmpty, "nothing reached the host")
        }
    }

    func testBindingNeedsAnInviteThatTakesAccounts() async throws {
        let host = acceptingHost()
        let connector = host.connector()
        do {
            _ = try await GuestSession.accept(invite(for: host, acct: false), identity: identity, bindToAccount: true,
                                              statements: StubStatements([]), connector: connector)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? GuestError, .accountStatement(.notOffered))
        }
        XCTAssertTrue(connector.sockets.isEmpty)
    }

    func testTheHostsAccountRefusalsAreTyped() async throws {
        let host = acceptingHost()
        host.reply = ["ok": false, "error": "account_keys_stale"]
        let statements = StubStatements([.success(.init(host: host.hostID, jws: try vectorJWS(), expires: Date().addingTimeInterval(600)))])
        do {
            _ = try await GuestSession.accept(invite(for: host, acct: true), identity: identity, bindToAccount: true,
                                              statements: statements, connector: host.connector())
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? GuestError, .refused(.accountKeysStale))
        }
    }

    // MARK: Returning hello

    func testAReturningHelloForABoundGrantCarriesAFreshStatement() async throws {
        let host = FakeHost()
        host.serve = { line in [Data(GuestSessionReuseTests.reply(to: line).utf8 + [0x0a])] }
        let jws = try vectorJWS()
        let statements = StubStatements([.success(.init(host: host.hostID, jws: jws, expires: Date().addingTimeInterval(600)))])
        let access = GuestAccess(guestID: "g_1", guestName: "plotarmordev", machineLabel: "Mac", ownerName: "Jerry",
                                 agentName: "llm-opt", agentTarget: "w1-3", endpoint: host.endpoint, acceptedAt: Date(),
                                 accountBound: true)
        let transport = access.transport(identity: identity, statements: statements, connector: host.connector())

        _ = try await transport.roundTrip(GuestSessionReuseTests.request("1"))
        _ = try await transport.roundTrip(GuestSessionReuseTests.request("2"))

        XCTAssertEqual(host.hellos.count, 2)
        for hello in host.hellos {
            XCTAssertEqual(hello as NSDictionary, ["v": 1, "guest_id": "g_1", "account": jws] as NSDictionary)
        }
        XCTAssertEqual(statements.asked, [host.hostID, host.hostID], "every hello asks for a current statement")
    }

    func testAPlainGrantsReturningHelloIsUnchanged() async throws {
        let host = FakeHost()
        host.serve = { line in [Data(GuestSessionReuseTests.reply(to: line).utf8 + [0x0a])] }
        let statements = StubStatements([])
        let access = GuestAccess(guestID: "g_1", guestName: "plotarmordev", machineLabel: "Mac", ownerName: "Jerry",
                                 agentName: "llm-opt", agentTarget: "w1-3", endpoint: host.endpoint, acceptedAt: Date())
        _ = try await access.transport(identity: identity, statements: statements, connector: host.connector())
            .roundTrip(GuestSessionReuseTests.request("1"))
        XCTAssertEqual(host.hellos.first as NSDictionary?, ["v": 1, "guest_id": "g_1"] as NSDictionary)
        XCTAssertTrue(statements.asked.isEmpty)
    }

    func testABoundGrantWithoutAStatementNeverSendsAPlainHello() async throws {
        let host = FakeHost()
        let connector = host.connector()
        for (account, expected) in [
            (RelayTransport.Account.bound(nil), AccountStatementFailure.signedOut),
            (.bound(StubStatements([.failure(AccountError.refused(status: 404, code: "device_not_found"))])), .refused("device_not_found")),
        ] {
            let transport = RelayTransport(guestID: "g_1", endpoint: host.endpoint, identity: identity,
                                           account: account, connector: connector)
            do {
                _ = try await transport.roundTrip(GuestSessionReuseTests.request("1"))
                XCTFail("expected a typed failure")
            } catch {
                XCTAssertEqual(error as? GuestError, .accountStatement(expected))
            }
        }
        XCTAssertTrue(connector.sockets.isEmpty)
    }

    // MARK: In-band refresh

    func testTheRefreshMessageIsHerdrsFrame() {
        // herdr's link test `an_in_band_refresh_moves_the_deadline_and_a_bad_one_closes`.
        XCTAssertEqual(String(decoding: GuestStatements.refreshMessage("good"), as: UTF8.self),
                       #"{"t":"account.refresh","account":"good"}"#)
    }

    func testAnOpenSessionSendsANewStatementBeforeTheDeadline() async throws {
        let host = multiRequestHost()
        let connector = host.connector()
        let first = try vectorJWS()
        // Due for refresh 0.3 s from now (the lead before `exp`); the next lasts 10 minutes.
        let statements = StubStatements([
            .success(.init(host: host.hostID, jws: first,
                           expires: Date().addingTimeInterval(RelaySession.statementRefreshLead + 0.3))),
            .success(.init(host: host.hostID, jws: "second.statement.jws", expires: Date().addingTimeInterval(600))),
        ])
        let transport = RelayTransport(guestID: "g_1", endpoint: host.endpoint, identity: identity,
                                       account: .bound(statements), connector: connector)

        _ = try await transport.roundTrip(GuestSessionReuseTests.request("1"))
        XCTAssertTrue(host.refreshes.isEmpty, "nothing is sent before it is due")
        try await waitUntil { host.refreshes.count == 1 }
        XCTAssertEqual(host.refreshes.first.map { String(decoding: $0, as: UTF8.self) },
                       #"{"t":"account.refresh","account":"second.statement.jws"}"#)

        let line = try await transport.roundTrip(GuestSessionReuseTests.request("2"))
        XCTAssertEqual(line, GuestSessionReuseTests.reply(to: GuestSessionReuseTests.request("2")))
        XCTAssertEqual(connector.sockets.count, 1, "the session lived on past the first statement")
        XCTAssertEqual(host.hellos.count, 1)
        XCTAssertEqual(host.requests, ["1", "2"].map { GuestSessionReuseTests.request($0) },
                       "the refresh never reached the API")
        RelayTransport.closeReusedSessions()
    }

    func testARefusedRefreshEndsTheStreamWithTheHostsCode() async throws {
        let host = FakeHost()
        host.closeAfterServe = nil
        host.serve = { _ in [Data("{\"event\":1}\n".utf8)] }
        host.refuseRefresh = { _ in "device_removed" }
        let statements = StubStatements([
            .success(.init(host: host.hostID, jws: try vectorJWS(),
                           expires: Date().addingTimeInterval(RelaySession.statementRefreshLead + 0.2))),
            .success(.init(host: host.hostID, jws: "next", expires: Date().addingTimeInterval(600))),
        ])
        let transport = RelayTransport(guestID: "g_1", endpoint: host.endpoint, identity: identity,
                                       account: .bound(statements), connector: host.connector())

        var lines: [String] = []
        do {
            for try await line in transport.stream(GuestSessionReuseTests.request("1", "pane.stream")) { lines.append(line) }
            XCTFail("the host closed the stream with its code")
        } catch {
            XCTAssertEqual(error as? GuestError, .refused(.deviceRemoved))
            XCTAssertTrue((error as? GuestError)?.isAccessLost ?? false)
        }
        XCTAssertEqual(lines, ["{\"event\":1}"])
        XCTAssertEqual(host.refreshes.count, 1)
    }

    func testTheStatementDeadlineCloseIsTypedAndRetryable() {
        let error = RelayTransport.error(forClose: 1000, reason: "statement_expired")
        XCTAssertEqual(error as? GuestError, .refused(.statementExpired))
        XCTAssertTrue(RelayTransport.endedSession(error), "a read goes again on a session with a fresh statement")
        XCTAssertFalse(RelayTransport.endedSession(GuestError.accountStatement(.unreachable)))
    }
}

/// Hands out the queued statements in order (the last one again once the queue runs out)
/// and records each host asked for.
final class StubStatements: GuestStatementSource, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<StatementCache.Statement, Error>]
    private var _asked: [String] = []

    init(_ queue: [Result<StatementCache.Statement, Error>]) { self.queue = queue }

    var asked: [String] { lock.withLock { _asked } }

    func statement(for host: String) async throws -> StatementCache.Statement {
        let next = lock.withLock { () -> Result<StatementCache.Statement, Error>? in
            _asked.append(host)
            return queue.count > 1 ? queue.removeFirst() : queue.first
        }
        guard let next else { throw AccountError.signedOut }
        return try next.get()
    }
}
