import Crypto
import Foundation
import XCTest
@testable import HerdrKit

/// A scripted relay socket. Messages the guest sends are handed to `onSend`, which
/// answers by queueing events.
final class FakeRelaySocket: RelaySocket, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<RelaySocketEvent, Error>] = []
    private var waiters: [CheckedContinuation<RelaySocketEvent, Error>] = []
    private(set) var sent: [Data] = []
    private(set) var closed = false
    var onSend: ((Data, FakeRelaySocket) throws -> Void)?

    func push(_ event: RelaySocketEvent) { deliver(.success(event)) }
    func fail(_ error: Error) { deliver(.failure(error)) }

    private func deliver(_ result: Result<RelaySocketEvent, Error>) {
        let waiter: CheckedContinuation<RelaySocketEvent, Error>? = lock.withLock {
            if waiters.isEmpty { queue.append(result); return nil }
            return waiters.removeFirst()
        }
        waiter?.resume(with: result)
    }

    func send(_ message: Data) async throws {
        lock.withLock { sent.append(message) }
        try onSend?(message, self)
    }

    func receive() async throws -> RelaySocketEvent {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<RelaySocketEvent, Error>? = lock.withLock {
                if queue.isEmpty { waiters.append(continuation); return nil }
                return queue.removeFirst()
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    func close() {
        let pending: [CheckedContinuation<RelaySocketEvent, Error>] = lock.withLock {
            closed = true
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in pending { waiter.resume(returning: .closed(code: 1000, reason: nil)) }
    }
}

final class FakeConnector: RelaySocketConnector, @unchecked Sendable {
    private let lock = NSLock()
    private let make: () -> FakeRelaySocket
    private(set) var urls: [URL] = []
    private(set) var sockets: [FakeRelaySocket] = []
    let roundTripLimit: Duration

    init(roundTripLimit: Duration = .seconds(60), make: @escaping () -> FakeRelaySocket) {
        self.roundTripLimit = roundTripLimit
        self.make = make
    }

    func connect(to url: URL) -> RelaySocket {
        let socket = make()
        lock.withLock {
            urls.append(url)
            sockets.append(socket)
        }
        return socket
    }
}

/// Plays the host daemon behind the relay: runs the IK responder, answers the
/// handshake with `reply`, then answers the request line with `serve`.
final class FakeHost: @unchecked Sendable {
    let key = Curve25519.KeyAgreement.PrivateKey()
    let hostID = Base64URL.encode(Data(repeating: 7, count: 16))
    var reply: [String: Any] = ["ok": true, "guest_id": "g_1"]
    /// Returns the raw bytes the host streams back for one request line.
    var serve: (String) -> [Data] = { _ in [] }
    /// How the host ends a session after `serve`'s output.
    var closeAfterServe: RelaySocketEvent? = .closed(code: 1000, reason: nil)
    private(set) var hellos: [[String: Any]] = []
    private(set) var guestStatics: [Data] = []
    private(set) var requests: [String] = []

    var endpoint: RelayEndpoint {
        RelayEndpoint(relay: URL(string: "https://relay.test")!, hostID: hostID, hostPublicKey: key.publicKey.rawRepresentation)
    }

    func connector() -> FakeConnector {
        FakeConnector { [self] in
            let socket = FakeRelaySocket()
            var responder = TestIKResponder(prologue: Data("herdr-guest/1:\(hostID)".utf8), staticKey: key)
            var transport: TestResponderTransport?
            var pending = Data()
            socket.onSend = { [self] message, socket in
                guard var session = transport else {
                    // Like the daemon, a handshake that fails to decrypt ends the session.
                    guard let hello = try? responder.readMessage1(message) else {
                        socket.push(.closed(code: 1000, reason: "handshake failed"))
                        return
                    }
                    hellos.append((try JSONSerialization.jsonObject(with: hello)) as? [String: Any] ?? [:])
                    guestStatics.append(responder.remoteStatic)
                    let (message2, established) = try responder.writeMessage2(
                        try JSONSerialization.data(withJSONObject: reply))
                    transport = established
                    socket.push(.data(message2))
                    if reply["ok"] as? Bool != true {
                        socket.push(.closed(code: 1000, reason: "refused"))
                    }
                    return
                }
                pending += try session.decrypt(message)
                if let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: pending[..<newline], as: UTF8.self)
                    requests.append(line)
                    for chunk in serve(line) { socket.push(.data(try session.encrypt(chunk))) }
                    if let close = closeAfterServe { socket.push(close) }
                }
                transport = session
            }
            return socket
        }
    }
}

final class RelayTransportTests: XCTestCase {
    let identity = GuestIdentity(privateKey: .init())

    func testRoundTripReturnsTheFirstLineAcrossSplitMessages() async throws {
        let host = FakeHost()
        // A reply split mid-scalar across two Noise messages must not be corrupted.
        let reply = Data(#"{"id":"1","result":{"type":"pong","note":"héllo"}}"#.utf8) + Data("\n{\"extra\":1}\n".utf8)
        let split = reply.firstIndex(of: 0xC3)! + 1
        host.serve = { _ in [reply.prefix(upTo: split), reply.suffix(from: split)] }
        let connector = host.connector()
        let transport = RelayTransport(guestID: "g_1", endpoint: host.endpoint, identity: identity, connector: connector)

        let line = try await transport.roundTrip(#"{"id":"1","method":"ping","params":{}}"#)

        XCTAssertEqual(line, #"{"id":"1","result":{"type":"pong","note":"héllo"}}"#)
        XCTAssertEqual(host.requests, [#"{"id":"1","method":"ping","params":{}}"#])
        XCTAssertEqual(host.guestStatics, [identity.publicKey], "the host learns the guest's device key")
        XCTAssertEqual(connector.urls.map(\.absoluteString), ["wss://relay.test/v1/guest/\(host.hostID)"])
        XCTAssertTrue(connector.sockets[0].closed, "a round trip closes its socket")
    }

    func testEveryCallOpensItsOwnSession() async throws {
        let host = FakeHost()
        host.serve = { _ in [Data("{}\n".utf8)] }
        let connector = host.connector()
        let transport = RelayTransport(guestID: "g_1", endpoint: host.endpoint, identity: identity, connector: connector)
        _ = try await transport.roundTrip("a")
        _ = try await transport.roundTrip("b")
        XCTAssertEqual(connector.sockets.count, 2)
        XCTAssertEqual(host.requests, ["a", "b"])
    }

    func testLargeRequestLinesAreChunkedUnderTheNoiseCeiling() async throws {
        let host = FakeHost()
        host.serve = { _ in [Data("{}\n".utf8)] }
        let connector = host.connector()
        let transport = RelayTransport(guestID: "g_1", endpoint: host.endpoint, identity: identity, connector: connector)
        let line = String(repeating: "x", count: 150_000)
        _ = try await transport.roundTrip(line)
        XCTAssertEqual(host.requests, [line])
        let transportMessages = connector.sockets[0].sent.dropFirst()
        XCTAssertEqual(transportMessages.count, 3)
        XCTAssertTrue(transportMessages.allSatisfy { $0.count <= NoiseIK.maxMessageBytes })
    }

    func testRoundTripClosedBeforeAnyLine() async throws {
        let host = FakeHost()
        let transport = RelayTransport(guestID: "g_1", endpoint: host.endpoint, identity: identity, connector: host.connector())
        do {
            _ = try await transport.roundTrip("x")
            XCTFail("expected closedBeforeResponse")
        } catch TransportError.closedBeforeResponse {
        }
    }

    func testStreamYieldsLinesThenTheGuestPausedErrorLine() async throws {
        let host = FakeHost()
        host.serve = { _ in
            [Data(#"{"id":"s","result":{"type":"stream_started"}}"#.utf8 + [0x0a]),
             Data(#"{"id":"s","error":{"code":"guest_paused","message":"paused"}}"#.utf8 + [0x0a])]
        }
        let transport = RelayTransport(guestID: "g_1", endpoint: host.endpoint, identity: identity, connector: host.connector())
        var lines: [String] = []
        for try await line in transport.stream("s") { lines.append(line) }
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains("guest_paused"))
    }

    func testHostDroppingMidStreamIsHostOffline() async throws {
        let host = FakeHost()
        host.serve = { _ in [Data("{\"a\":1}\n".utf8)] }
        host.closeAfterServe = .closed(code: 1001, reason: "host_offline")
        let transport = RelayTransport(guestID: "g_1", endpoint: host.endpoint, identity: identity, connector: host.connector())
        var lines: [String] = []
        do {
            for try await line in transport.stream("s") { lines.append(line) }
            XCTFail("expected hostOffline")
        } catch let error as GuestError {
            XCTAssertEqual(error, .hostOffline)
        }
        XCTAssertEqual(lines, [#"{"a":1}"#])
    }

    func testCancellingAStreamClosesItsSocket() async throws {
        let host = FakeHost()
        host.serve = { _ in [Data("{\"a\":1}\n".utf8)] }
        host.closeAfterServe = nil   // the host keeps streaming
        let connector = host.connector()
        let transport = RelayTransport(guestID: "g_1", endpoint: host.endpoint, identity: identity, connector: connector)
        let task = Task {
            for try await _ in transport.stream("s") { break }
        }
        try await task.value
        let deadline = Date().addingTimeInterval(2)
        while !(connector.sockets.first?.closed ?? false), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(connector.sockets.first?.closed ?? false)
    }

    /// A relay or host answering with a message that does not authenticate under the
    /// session keys must fail the call, never surface as data.
    func testForgedHostMessageFailsTheCall() async throws {
        let host = FakeHost()
        host.serve = { _ in [] }
        host.closeAfterServe = .data(Data(repeating: 0xAB, count: 40))
        let transport = RelayTransport(guestID: "g_1", endpoint: host.endpoint, identity: identity, connector: host.connector())
        do {
            _ = try await transport.roundTrip("x")
            XCTFail("expected a secure channel failure")
        } catch GuestError.secureChannelFailed {
        }
    }

    /// The guest pinned the host key from the invite; a different key answering the
    /// relay slot cannot complete the handshake.
    func testWrongHostKeyNeverReachesTheRequest() async throws {
        let host = FakeHost()
        let impostor = RelayEndpoint(relay: host.endpoint.relay, hostID: host.hostID,
                                     hostPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
        let transport = RelayTransport(guestID: "g_1", endpoint: impostor, identity: identity, connector: host.connector())
        do {
            _ = try await transport.roundTrip("secret request")
            XCTFail("expected failure")
        } catch let error as GuestError {
            XCTAssertEqual(error, .connectionClosed(code: 1000, reason: "handshake failed"))
        }
        XCTAssertTrue(host.requests.isEmpty)
        XCTAssertTrue(host.hellos.isEmpty, "the impostor could not read message 1")
    }

    func testUpgradeRefusalMapping() {
        XCTAssertEqual(RelayTransport.error(forUpgradeStatus: 503, code: "host_offline"), .hostOffline)
        XCTAssertEqual(RelayTransport.error(forUpgradeStatus: 503, code: "host_busy"), .hostBusy)
        XCTAssertEqual(RelayTransport.error(forUpgradeStatus: 503, code: nil), .hostOffline)
        XCTAssertEqual(RelayTransport.error(forUpgradeStatus: 429, code: nil), .rateLimited)
        XCTAssertEqual(RelayTransport.error(forUpgradeStatus: 429, code: "rate_limited"), .rateLimited)
        XCTAssertEqual(RelayTransport.error(forUpgradeStatus: 404, code: "not_found"),
                       .relayRejected(status: 404, code: "not_found"))
        XCTAssertEqual(RelayTransport.error(forUpgradeStatus: 426, code: nil),
                       .relayRejected(status: 426, code: nil))
    }

    /// A host that aborts mid-response closes 1000 with a reason; that is a failure,
    /// not a short reply.
    func testHostAbortWithReasonIsAnError() async throws {
        let host = FakeHost()
        host.serve = { _ in [Data("{\"partial".utf8)] }
        host.closeAfterServe = .closed(code: 1000, reason: "overloaded")
        let transport = RelayTransport(guestID: "g_1", endpoint: host.endpoint, identity: identity, connector: host.connector())
        do {
            _ = try await transport.roundTrip("x")
            XCTFail("expected an error")
        } catch let error as GuestError {
            XCTAssertEqual(error, .connectionClosed(code: 1000, reason: "overloaded"))
        }
    }

    func testCloseCodeMapping() {
        XCTAssertEqual(RelayTransport.error(forClose: 1000, reason: "host_busy") as? GuestError, .hostBusy)
        XCTAssertEqual(RelayTransport.error(forClose: 1001, reason: "host_offline") as? GuestError, .hostOffline)
        XCTAssertEqual(RelayTransport.error(forClose: 1009, reason: nil) as? GuestError, .messageTooLarge)
        XCTAssertEqual(RelayTransport.error(forClose: 1003, reason: "") as? GuestError,
                       .connectionClosed(code: 1003, reason: nil))
        // A refused guest upgrade: the relay accepts it, then closes with 4000 + the HTTP status.
        XCTAssertEqual(RelayTransport.error(forClose: 4429, reason: "rate_limited") as? GuestError, .rateLimited)
        XCTAssertEqual(RelayTransport.error(forClose: 4503, reason: "host_offline") as? GuestError, .hostOffline)
        XCTAssertEqual(RelayTransport.error(forClose: 4504, reason: "host_busy") as? GuestError, .hostBusy)
    }

    /// The relay closes a refused upgrade before the host ever sees message 1.
    func testRelayRefusalCloseFailsTheCallWithItsError() async throws {
        let cases: [(Int, String, GuestError)] = [
            (4429, "rate_limited", .rateLimited),
            (4503, "host_offline", .hostOffline),
            (4504, "host_busy", .hostBusy),
        ]
        for (code, reason, expected) in cases {
            let connector = FakeConnector {
                let socket = FakeRelaySocket()
                socket.push(.closed(code: code, reason: reason))
                return socket
            }
            let transport = RelayTransport(guestID: "g_1", endpoint: FakeHost().endpoint, identity: identity, connector: connector)
            do {
                _ = try await transport.roundTrip("x")
                XCTFail("expected \(expected)")
            } catch let error as GuestError {
                XCTAssertEqual(error, expected)
            }
        }
    }

    func testAPIErrorsClassifyAsGuestErrors() {
        XCTAssertEqual(GuestError.classify(APIError(code: "guest_paused", message: "")), .paused)
        XCTAssertEqual(GuestError.classify(APIError(code: "guest_revoked", message: "")), .revoked)
        XCTAssertEqual(GuestError.classify(APIError(code: "guest_forbidden", message: "")), .forbidden)
        XCTAssertNil(GuestError.classify(APIError(code: "pane_not_found", message: "")))
        XCTAssertNotNil(permanentStreamRefusal(code: "guest_revoked"))
        XCTAssertNil(permanentStreamRefusal(code: "guest_paused"), "a pause lifts when the agent runs again")
    }
}

final class GuestSessionTests: XCTestCase {
    func invite(for host: FakeHost, expires: Date = Date().addingTimeInterval(3600)) -> GuestInvite {
        GuestInvite(
            relay: host.endpoint.relay, hostID: host.hostID, hostPublicKey: host.endpoint.hostPublicKey,
            inviteID: Base64URL.encode(Data(repeating: 3, count: 16)), secret: Base64URL.encode(Data(repeating: 4, count: 32)),
            machineLabel: "Jerry's Mac Studio", ownerName: "Jerry", agentName: "llm-opt", guestName: "plotarmordev",
            expires: expires)
    }

    func testAcceptSendsTheInviteSecretAndReturnsTheGrant() async throws {
        let host = FakeHost()
        host.reply = ["ok": true, "guest_id": "g_1", "name": "plotarmordev", "machine_label": "Jerry's Mac Studio",
                      "owner_name": "Jerry", "agent": ["name": "llm-opt", "target": "w1-3"]]
        let identity = GuestIdentity(privateKey: .init())
        let invite = invite(for: host)
        let now = Date()

        let access = try await GuestSession.accept(invite, identity: identity, now: now, connector: host.connector())

        XCTAssertEqual(host.hellos.first as NSDictionary?,
                       ["v": 1, "invite_id": invite.inviteID, "secret": invite.secret, "device": "iPhone"] as NSDictionary)
        XCTAssertEqual(access.guestID, "g_1")
        XCTAssertEqual(access.agentTarget, "w1-3")
        XCTAssertEqual(access.agentName, "llm-opt")
        XCTAssertEqual(access.endpoint, host.endpoint)
        XCTAssertEqual(access.composerPlaceholder, "Message llm-opt as plotarmordev")
        XCTAssertTrue(host.requests.isEmpty, "accepting sends no API request")
    }

    func testRefusalsSurfaceTheirReason() async throws {
        for (code, refusal) in [("invite_used", GuestRefusal.inviteUsed), ("invite_expired", .inviteExpired),
                                ("invite_invalid", .inviteInvalid), ("revoked", .revoked)] {
            let host = FakeHost()
            host.reply = ["ok": false, "error": code]
            do {
                _ = try await GuestSession.accept(invite(for: host), identity: GuestIdentity(privateKey: .init()),
                                                  connector: host.connector())
                XCTFail("expected refusal \(code)")
            } catch let error as GuestError {
                XCTAssertEqual(error, .refused(refusal))
            }
        }
    }

    func testAnExpiredInviteNeverConnects() async throws {
        let host = FakeHost()
        let connector = host.connector()
        do {
            _ = try await GuestSession.accept(invite(for: host, expires: Date().addingTimeInterval(-1)),
                                              identity: GuestIdentity(privateKey: .init()), connector: connector)
            XCTFail("expected expiry")
        } catch let error as GuestInvite.Failure {
            XCTAssertEqual(error, .expired)
        }
        XCTAssertTrue(connector.urls.isEmpty)
    }

    func testIncompleteAcceptanceIsRejected() async throws {
        let host = FakeHost()
        host.reply = ["ok": true, "guest_id": "g_1"]
        do {
            _ = try await GuestSession.accept(invite(for: host), identity: GuestIdentity(privateKey: .init()),
                                              connector: host.connector())
            XCTFail("expected failure")
        } catch GuestError.secureChannelFailed {
        }
    }

    func testReturningGuestSessionsUseTheSameDeviceKey() async throws {
        let host = FakeHost()
        host.reply = ["ok": true, "guest_id": "g_1", "agent": ["name": "llm-opt", "target": "w1-3"]]
        let identity = GuestIdentity(privateKey: .init())
        let access = try await GuestSession.accept(invite(for: host), identity: identity, connector: host.connector())
        host.serve = { _ in [Data("{}\n".utf8)] }
        _ = try await access.transport(identity: identity, connector: host.connector()).roundTrip("{}")
        XCTAssertEqual(host.guestStatics, [identity.publicKey, identity.publicKey])
    }
}
