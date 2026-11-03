import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One thing a relay socket can deliver.
public enum RelaySocketEvent: Equatable, Sendable {
    /// One binary message: one Noise message from the host.
    case data(Data)
    /// The socket closed with this WebSocket close code and reason.
    case closed(code: Int, reason: String?)
}

/// A guest WebSocket to the relay. Abstracted so the Noise and line logic is
/// testable without a network.
public protocol RelaySocket: Sendable {
    func send(_ message: Data) async throws
    /// The next binary message or the close. Throws `GuestError` for a refused
    /// upgrade and any other error for a dropped connection.
    func receive() async throws -> RelaySocketEvent
    func close()
}

public protocol RelaySocketConnector: Sendable {
    func connect(to url: URL) -> RelaySocket
    /// The longest one `RelayTransport.roundTrip` may take, from opening its socket to
    /// the reply line. Past it the socket is closed — even while it still waits for the
    /// upgrade or the host's handshake reply — and the call fails with
    /// `TransportError.requestTimedOut`. A `stream` has no limit.
    var roundTripLimit: Duration { get }
}

extension RelaySocketConnector {
    /// Every guest call is one short request, and the largest is one upload chunk
    /// (`RelayTransport.gramUploadChunkBytes`), so a minute only ends a call that is stuck.
    public var roundTripLimit: Duration { .seconds(60) }
}

/// Where a guest connects: the relay, the host's relay id, and the host's static key.
public struct RelayEndpoint: Hashable, Sendable, Codable {
    public let relay: URL
    public let hostID: String
    public let hostPublicKey: Data

    public init(relay: URL, hostID: String, hostPublicKey: Data) {
        self.relay = relay
        self.hostID = hostID
        self.hostPublicKey = hostPublicKey
    }

    /// `wss://<relay>/v1/guest/<host_id>` (or `ws://` for a local http relay).
    public var socketURL: URL {
        var components = URLComponents(url: relay, resolvingAgainstBaseURL: false)!
        components.scheme = relay.scheme == "http" ? "ws" : "wss"
        var base = components.path
        while base.hasSuffix("/") { base.removeLast() }
        components.path = "\(base)/v1/guest/\(hostID)"
        components.query = nil
        components.fragment = nil
        return components.url!
    }

    /// The Noise prologue binds the session to this host id.
    var prologue: Data { Data("herdr-guest/1:\(hostID)".utf8) }
}

/// An open, authenticated relay session: the socket plus the Noise transport.
final class RelaySession: @unchecked Sendable {
    let socket: RelaySocket
    /// The decoded message-2 payload.
    let reply: [String: Any]
    private let lock = NSLock()
    private var noise: NoiseIK.Transport

    private init(socket: RelaySocket, noise: NoiseIK.Transport, reply: [String: Any]) {
        self.socket = socket
        self.noise = noise
        self.reply = reply
    }

    /// Opens a socket and runs the IK handshake with `hello` as the message-1 payload.
    /// A refusal in message 2 throws `GuestError.refused`.
    static func open(
        endpoint: RelayEndpoint, identity: GuestIdentity, hello: Data, connector: RelaySocketConnector
    ) async throws -> RelaySession {
        var initiator: NoiseIK.Initiator
        let message1: Data
        do {
            initiator = try NoiseIK.Initiator(
                prologue: endpoint.prologue, staticKey: identity.privateKey, remoteStatic: endpoint.hostPublicKey)
            message1 = try initiator.writeMessage1(payload: hello)
        } catch let failure as NoiseIK.Failure {
            throw GuestError.secureChannelFailed(failure.description)
        }
        let socket = connector.connect(to: endpoint.socketURL)
        do {
            try await socket.send(message1)
            let message2: Data
            switch try await socket.receive() {
            case .data(let data): message2 = data
            case .closed(let code, let reason): throw RelayTransport.error(forClose: code, reason: reason)
            }
            let payload: Data
            let noise: NoiseIK.Transport
            do {
                (payload, noise) = try initiator.readMessage2(message2)
            } catch let failure as NoiseIK.Failure {
                throw GuestError.secureChannelFailed(failure.description)
            }
            guard let reply = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
                  let ok = reply["ok"] as? Bool
            else { throw GuestError.secureChannelFailed("the host's reply is not valid") }
            guard ok else {
                throw GuestError.refused(GuestRefusal(code: reply["error"] as? String ?? ""))
            }
            return RelaySession(socket: socket, noise: noise, reply: reply)
        } catch {
            socket.close()
            throw error
        }
    }

    /// Sends one request line, split into Noise messages that fit the relay limit.
    func sendLine(_ line: String) async throws {
        let messages: [Data]
        do {
            messages = try lock.withLock { try noise.encryptChunked(Data((line + "\n").utf8)) }
        } catch let failure as NoiseIK.Failure {
            throw GuestError.secureChannelFailed(failure.description)
        }
        for message in messages {
            try await socket.send(message)
        }
    }

    /// The next decrypted chunk of the host's byte stream, or nil after a normal close.
    func receiveChunk() async throws -> Data? {
        switch try await socket.receive() {
        case .data(let message):
            do {
                return try lock.withLock { try noise.decrypt(message) }
            } catch let failure as NoiseIK.Failure {
                throw GuestError.secureChannelFailed(failure.description)
            }
        case .closed(let code, let reason):
            // A normal end carries no reason; a host that aborts (decrypt_failed,
            // overloaded, internal) closes 1000 WITH one, which must not read as EOF.
            if code == 1000, reason?.isEmpty ?? true { return nil }
            throw RelayTransport.error(forClose: code, reason: reason)
        }
    }

    func close() {
        socket.close()
    }
}

/// Reaches a host daemon through the guest relay. Like `CitadelTransport`, every
/// call gets its own connection: one WebSocket is one Noise session and carries
/// exactly one API request.
public struct RelayTransport: HerdrTransport {
    public let endpoint: RelayEndpoint
    let identity: GuestIdentity
    private let guestID: String
    let connector: RelaySocketConnector
    /// Hears each session's hello `features`, before the session's request is answered.
    let onFeatures: (@Sendable (GuestFeatures) -> Void)?

    /// Encoded once per transport; every request authenticates the same grant.
    private let returningHello: Data

    private struct ReturningHello: Encodable {
        let v = 1
        let guest_id: String
    }

    /// Raw bytes per `gram.upload_chunk` over the relay: 256 KiB. Every relay call is its
    /// own WebSocket and Noise handshake, so the SSH-sized 48 KiB chunk made a 6 MB
    /// photo 123 connections. The SSH argv cap behind 48 KiB does not apply here; the
    /// host's limits do, and this size keeps clear of each:
    /// - base64 makes the request line about 349.7 KB, which `encryptChunked` splits
    ///   into 6 Noise messages of at most 65,535 B (the relay caps a message at 70,000 B);
    /// - the host closes a session that has 32 undelivered messages queued
    ///   (`overloaded`), and 6 fit even if it delivers none before the last arrives;
    /// - the guest gate accepts at most 512 KiB decoded per chunk (this is half), and
    ///   the API reads at most 1 MiB per request line (this is a third);
    /// - the API must receive the whole line within 5 s of its first message, so the
    ///   phone's uplink needs about 70 KB/s (0.56 Mbit/s). 384 KiB would need
    ///   0.84 Mbit/s, which a weak cellular uplink does not always sustain.
    /// A 6 MB photo is 23 connections.
    static let gramUploadChunkBytes = 256 * 1024

    public var gramUploadChunkBytes: Int { Self.gramUploadChunkBytes }

    public init(guestID: String, endpoint: RelayEndpoint, identity: GuestIdentity, connector: RelaySocketConnector = URLSessionRelayConnector(),
                onFeatures: (@Sendable (GuestFeatures) -> Void)? = nil) {
        self.endpoint = endpoint
        self.identity = identity
        self.guestID = guestID
        // These two primitive fields have no failing Encodable implementation.
        self.returningHello = try! JSONEncoder().encode(ReturningHello(guest_id: guestID))
        self.connector = connector
        self.onFeatures = onFeatures
    }

    private func open(through connector: RelaySocketConnector) async throws -> RelaySession {
        let session = try await RelaySession.open(
            endpoint: endpoint, identity: identity, hello: returningHello, connector: connector)
        guard session.reply["guest_id"] as? String == guestID else {
            session.close()
            throw GuestError.revoked
        }
        onFeatures?(GuestFeatures(helloReply: session.reply))
        return session
    }

    /// Fails with `TransportError.requestTimedOut` after the connector's `roundTripLimit`
    /// and closes the call's socket. Without a limit, a connection whose upgrade or
    /// handshake reply never came left the call (and an upload behind it) waiting forever.
    /// The wait does not depend on the socket honouring the close: after invoking
    /// close, the call answers without waiting for the handshake or exchange to end.
    public func roundTrip(_ requestLine: String) async throws -> String {
        let sockets = ClosableConnector(connector)
        let outcome = FirstOutcome<String>()
        let work = Task {
            do {
                outcome.offer(.success(try await exchange(requestLine, through: sockets)))
            } catch {
                outcome.offer(.failure(error))
            }
        }
        let end = { @Sendable (error: Error) in
            outcome.offer(.failure(error)) {
                sockets.close()
                work.cancel()
            }
        }
        let expired = TransportError.requestTimedOut(host: endpoint.relay.host ?? endpoint.relay.absoluteString)
        let timer = Task { [limit = connector.roundTripLimit] in
            guard (try? await Task.sleep(for: limit)) != nil else { return }
            end(expired)
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await outcome.value()
        } onCancel: {
            end(CancellationError())
        }
    }

    private func exchange(_ requestLine: String, through connector: RelaySocketConnector) async throws -> String {
        let session = try await open(through: connector)
        defer { session.close() }
        try await session.sendLine(requestLine)
        var lines = LineAccumulator()
        while let chunk = try await session.receiveChunk() {
            if let first = lines.append(chunk).first { return first }
        }
        if lines.hasRemainder { return lines.flush() }
        throw TransportError.closedBeforeResponse
    }

    public func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let holder = SessionHolder()
            let task = Task {
                do {
                    let session = try await open(through: connector)
                    guard holder.adopt(session) else { continuation.finish(); return }
                    try await session.sendLine(requestLine)
                    var lines = LineAccumulator()
                    while let chunk = try await session.receiveChunk() {
                        for line in lines.append(chunk) { continuation.yield(line) }
                    }
                    if lines.hasRemainder { continuation.yield(lines.flush()) }
                    holder.close()
                    continuation.finish()
                } catch {
                    holder.close()
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                holder.close()
            }
        }
    }

    /// Maps a WebSocket close the relay or host sent to a guest error. The relay refuses
    /// a guest upgrade by accepting it and closing at once with 4000 plus the HTTP status
    /// an older relay answered: 4429 `rate_limited`, 4503 `host_offline`, 4504 `host_busy`.
    static func error(forClose code: Int, reason: String?) -> Error {
        if reason == "host_busy" { return GuestError.hostBusy }
        switch code {
        case 1001, 4503: return GuestError.hostOffline
        case 4504: return GuestError.hostBusy
        case 4429: return GuestError.rateLimited
        case 1009: return GuestError.messageTooLarge
        default: return GuestError.connectionClosed(code: code, reason: reason?.isEmpty == false ? reason : nil)
        }
    }

    /// Maps a refused upgrade. `code` is the relay's `X-Herdr-Guest-Error` header;
    /// without it only the status is known.
    static func error(forUpgradeStatus status: Int, code: String?) -> GuestError {
        switch (status, code) {
        case (_, "host_offline"): return .hostOffline
        case (_, "host_busy"): return .hostBusy
        case (_, "rate_limited"): return .rateLimited
        case (503, nil): return .hostOffline
        case (429, nil): return .rateLimited
        default: return .relayRejected(status: status, code: code)
        }
    }
}

/// Lets a stream's termination close a session that may still be opening.
private final class SessionHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var session: RelaySession?
    private var closed = false

    /// Keeps `session`, or closes it and returns false when the stream already ended.
    func adopt(_ session: RelaySession) -> Bool {
        let keep = lock.withLock { () -> Bool in
            if closed { return false }
            self.session = session
            return true
        }
        if !keep { session.close() }
        return keep
    }

    func close() {
        let session = lock.withLock { () -> RelaySession? in
            closed = true
            defer { self.session = nil }
            return self.session
        }
        session?.close()
    }
}

/// Opens one call's socket through `base` and lets the call's deadline close it, even
/// before `RelaySession.open` has a session to close. A socket opened after the close
/// is closed at once.
private final class ClosableConnector: RelaySocketConnector, @unchecked Sendable {
    private let base: RelaySocketConnector
    private let lock = NSLock()
    private var socket: RelaySocket?
    private var closed = false

    init(_ base: RelaySocketConnector) {
        self.base = base
    }

    var roundTripLimit: Duration { base.roundTripLimit }

    func connect(to url: URL) -> RelaySocket {
        let socket = base.connect(to: url)
        let late = lock.withLock { () -> Bool in
            if closed { return true }
            self.socket = socket
            return false
        }
        if late { socket.close() }
        return socket
    }

    func close() {
        let socket = lock.withLock { () -> RelaySocket? in
            closed = true
            defer { self.socket = nil }
            return self.socket
        }
        socket?.close()
    }
}

/// The first offer reserves the outcome; it becomes visible only after its cleanup.
private final class FirstOutcome<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    private var result: Result<Value, Error>?
    private var waiter: CheckedContinuation<Value, Error>?

    /// Cleanup runs only for the winning offer, outside the lock: closing a socket
    /// can let the worker finish and offer its own result.
    func offer(_ result: Result<Value, Error>, beforePublishing cleanup: () -> Void = {}) {
        let first = lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
        guard first else { return }
        cleanup()
        let waiter = lock.withLock {
            self.result = result
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(with: result)
    }

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let ready = lock.withLock { () -> Result<Value, Error>? in
                if result == nil { waiter = continuation }
                return result
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}

/// Opens relay sockets with `URLSessionWebSocketTask`.
public struct URLSessionRelayConnector: RelaySocketConnector {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect(to url: URL) -> RelaySocket {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let task = session.webSocketTask(with: request)
        // The relay caps a message at 70000 bytes; a Noise message is at most 65535.
        task.maximumMessageSize = 70_000
        task.resume()
        return URLSessionRelaySocket(task: task)
    }
}

final class URLSessionRelaySocket: RelaySocket, @unchecked Sendable {
    let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ message: Data) async throws {
        do {
            try await task.send(.data(message))
        } catch {
            // The relay may have closed a refused upgrade before this first send.
            if case .closed(let code, let reason)? = closeEvent() {
                throw RelayTransport.error(forClose: code, reason: reason)
            }
            throw classify(error)
        }
    }

    func receive() async throws -> RelaySocketEvent {
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                if let close = closeEvent() { return close }
                throw classify(error)
            }
            switch message {
            case .data(let data):
                return .data(data)
            case .string:
                // Only a keepalive `pong` arrives as text; the protocol carries no text.
                continue
            @unknown default:
                continue
            }
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func closeEvent() -> RelaySocketEvent? {
        let code = task.closeCode
        guard code != .invalid else { return nil }
        let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) }
        return .closed(code: code.rawValue, reason: reason)
    }

    /// A failed upgrade carries the relay's HTTP answer; anything else is a drop.
    private func classify(_ error: Error) -> Error {
        guard let response = task.response as? HTTPURLResponse, response.statusCode != 101 else {
            return error
        }
        let code = response.value(forHTTPHeaderField: "X-Herdr-Guest-Error")
        return RelayTransport.error(forUpgradeStatus: response.statusCode, code: code)
    }
}
