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
    /// The longest one `RelayTransport.roundTrip` may take, from its turn (opening its
    /// socket, or taking the session the call before it left open) to the reply line.
    /// Past it the socket is closed — even while it still waits for the upgrade or the
    /// host's handshake reply — and the call fails with `TransportError.requestTimedOut`.
    /// A `stream` has no limit.
    var roundTripLimit: Duration { get }
    /// How long a session kept open for the next call may sit unused before this client
    /// closes it.
    var sessionIdleLimit: Duration { get }
    /// How long after its handshake a session kept open for the next call may still be
    /// handed to one. A call holding it is never cut; the next one handshakes afresh.
    var sessionAgeLimit: Duration { get }
}

extension RelaySocketConnector {
    /// Every guest call is one short request, and the largest is one upload chunk
    /// (`RelayTransport.gramUploadChunkBytes`), so a minute only ends a call that is stuck.
    public var roundTripLimit: Duration { .seconds(60) }
    /// herdr ends a guest session after 60 s without a request; closing it first means a
    /// call never writes into a session the host is ending.
    public var sessionIdleLimit: Duration { .seconds(50) }
    /// The hello reply's `features` (the owner sharing Grams, guest push) are read once per
    /// handshake. Before session reuse every call handshook, so an owner's change reached the
    /// guest within one poll; a session that steady polling keeps open would never learn
    /// it. Two minutes bounds how stale they get.
    public var sessionAgeLimit: Duration { .seconds(120) }
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
    /// The host serves the next request on this session after a reply (herdr #356).
    var multiRequest: Bool { GuestFeatures.multiRequest(helloReply: reply) }
    private let lock = NSLock()
    private var noise: NoiseIK.Transport
    /// The socket read started while the session idled between calls (`watchWhileIdle`).
    private var idleRead: Task<RelaySocketEvent, Error>?
    /// A call took the idling session for its request (`claim`).
    private var claimed = false
    /// The socket delivered something while the session idled: it has ended.
    private var endedWhileIdle = false
    /// When the handshake completed: the features in `reply` are as of then.
    let opened = ContinuousClock.now

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
        let pending = lock.withLock { () -> Task<RelaySocketEvent, Error>? in
            defer { idleRead = nil }
            return idleRead
        }
        let event: RelaySocketEvent
        if let pending { event = try await pending.value } else { event = try await socket.receive() }
        switch event {
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

    /// Reads ahead while the session idles between calls. herdr sends nothing between a
    /// reply and the next request, so anything the socket delivers before a call claims the
    /// session — mostly the close when herdr ends it (idle, restart, revocation) — means it
    /// has ended: the session is closed, and a call that then claims it opens a fresh one
    /// without having sent anything on this one. The read a claiming call inherits is its
    /// reply's first event.
    func watchWhileIdle() {
        lock.withLock {
            claimed = false
            guard idleRead == nil, !endedWhileIdle else { return }
            idleRead = Task { [weak self, socket] in
                do {
                    let event = try await socket.receive()
                    self?.deliveredWhileIdle()
                    return event
                } catch {
                    self?.deliveredWhileIdle()
                    throw error
                }
            }
        }
    }

    private func deliveredWhileIdle() {
        let ended = lock.withLock { () -> Bool in
            guard !claimed else { return false }
            endedWhileIdle = true
            return true
        }
        if ended { socket.close() }
    }

    /// Takes the session for a call's request, or false when it already ended while idle:
    /// nothing of the call has been sent on it.
    func claim() -> Bool {
        lock.withLock {
            guard !endedWhileIdle else { return false }
            claimed = true
            return true
        }
    }

    func close() {
        socket.close()
    }
}

/// Reaches a host daemon through the guest relay. One WebSocket is one Noise session. Like
/// `CitadelTransport`, every call gets its own session, unless the host serves many
/// requests per session (`features.multi_request`, herdr #356): then the guest's calls take
/// turns on one open session (`ReusableSession`). A `stream` always opens its own.
public struct RelayTransport: HerdrTransport {
    public let endpoint: RelayEndpoint
    let identity: GuestIdentity
    private let guestID: String
    let connector: RelaySocketConnector
    /// Hears each session's hello `features`, before the session's request is answered.
    let onFeatures: (@Sendable (GuestFeatures) -> Void)?

    /// Encoded once per transport; every request authenticates the same grant.
    private let returningHello: Data
    /// The session this guest keeps open to this host between calls, shared by every
    /// transport of the same guest, host and device key.
    private let reusable: ReusableSession

    private struct ReturningHello: Encodable {
        let v = 1
        let guest_id: String
    }

    /// Raw bytes per `gram.upload_chunk` over the relay: 256 KiB. On a host without session
    /// reuse every relay call is its own WebSocket and Noise handshake, so the SSH-sized 48 KiB chunk made a 6 MB
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
    /// A 6 MB photo is 23 requests (23 connections without session reuse).
    static let gramUploadChunkBytes = 256 * 1024

    public var gramUploadChunkBytes: Int { Self.gramUploadChunkBytes }

    /// The relay is the guest's way in: its writes are never the owner's.
    public var actsAsGuest: Bool { true }

    public init(guestID: String, endpoint: RelayEndpoint, identity: GuestIdentity, connector: RelaySocketConnector = URLSessionRelayConnector(),
                onFeatures: (@Sendable (GuestFeatures) -> Void)? = nil) {
        self.endpoint = endpoint
        self.identity = identity
        self.guestID = guestID
        // These two primitive fields have no failing Encodable implementation.
        self.returningHello = try! JSONEncoder().encode(ReturningHello(guest_id: guestID))
        self.connector = connector
        self.onFeatures = onFeatures
        self.reusable = ReusableSession.shared(
            ReusableSession.Key(endpoint: endpoint, guestID: guestID, device: identity.publicKey))
    }

    private func open(through connector: RelaySocketConnector) async throws -> RelaySession {
        let session = try await RelaySession.open(
            endpoint: endpoint, identity: identity, hello: returningHello, connector: connector)
        guard session.reply["guest_id"] as? String == guestID else {
            session.close()
            throw GuestError.revoked
        }
        reusable.learn(multiRequest: session.multiRequest)
        onFeatures?(GuestFeatures(helloReply: session.reply))
        return session
    }

    /// Fails with `TransportError.requestTimedOut` after the connector's `roundTripLimit`
    /// and closes the call's socket. Without a limit, a connection whose upgrade or
    /// handshake reply never came left the call (and an upload behind it) waiting forever.
    /// The wait does not depend on the socket honouring the close: after invoking
    /// close, the call answers without waiting for the handshake or exchange to end.
    ///
    /// Once a handshake advertised `features.multi_request`, calls take turns on the
    /// guest's one open session: herdr reads the next request only after its reply, so a
    /// call waits for the one before it, and its limit starts when its turn does.
    public func roundTrip(_ requestLine: String) async throws -> String {
        guard reusable.reuses else {
            // Its own socket and handshake, as on a host without session reuse. A host that
            // turns out to serve many requests per session keeps the session for the next call.
            let generation = reusable.generation
            let reply = try await withDeadline { try await exchange(requestLine, reusing: nil, through: $0) }
            if let session = reply.session {
                reusable.offer(session, from: generation, limits: connector)
            }
            return reply.line
        }
        let turn = try await reusable.take()
        // A call cancelled while it waited hands the session on unused rather than closing it.
        var kept = turn.session
        defer { reusable.finish(turn, keeping: kept, limits: connector) }
        try Task.checkCancellation()
        kept = nil
        let reply = try await withDeadline { try await exchange(requestLine, reusing: turn.session, through: $0) }
        kept = reply.session
        return reply.line
    }

    /// Closes every guest session kept open between calls, and each in-flight one when its
    /// call ends. The app calls it on going to the background, where a suspended socket
    /// dies with the network; the next call connects afresh.
    public static func closeReusedSessions() {
        ReusableSession.closeAll()
    }

    /// One call's reply line, and its session when that can carry the next request.
    private struct Reply: Sendable {
        let line: String
        let session: RelaySession?
    }

    private func withDeadline(
        _ work: @escaping @Sendable (ClosableConnector) async throws -> Reply
    ) async throws -> Reply {
        let sockets = ClosableConnector(connector)
        let outcome = FirstOutcome<Reply>()
        let task = Task {
            do {
                outcome.offer(.success(try await work(sockets)))
            } catch {
                outcome.offer(.failure(error))
            }
        }
        let end = { @Sendable (error: Error) in
            outcome.offer(.failure(error)) {
                sockets.close()
                task.cancel()
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

    /// Sends `requestLine` on `reused`, or on a session of its own. A reused session known
    /// to have ended before the request (herdr closed it while it idled) is closed and the
    /// request goes out on a fresh session: nothing of it was sent. One that fails once the
    /// request was handed to it costs one more connect only for a read: a failed send does
    /// not prove the host received nothing, so a prompt, an answer, keys, a Gram post or an
    /// upload chunk reports the failure instead of running twice.
    private func exchange(
        _ requestLine: String, reusing reused: RelaySession?, through sockets: ClosableConnector
    ) async throws -> Reply {
        if let reused {
            sockets.adopt(reused.socket)
            if reused.claim() {
                // This transport did not run the session's handshake; its consumer hears the
                // features that handshake authenticated, as on a session of its own.
                onFeatures?(GuestFeatures(helloReply: reused.reply))
                do {
                    try await reused.sendLine(requestLine)
                    return try await reply(on: reused)
                } catch {
                    reused.close()
                    guard !Task.isCancelled, Self.endedSession(error), Self.onlyReads(requestLine) else { throw error }
                }
            } else {
                reused.close()
            }
        }
        let session = try await open(through: sockets)
        do {
            try await session.sendLine(requestLine)
            return try await reply(on: session)
        } catch {
            session.close()
            throw error
        }
    }

    /// Reads the reply line. The session stays open for the next call only on a host that
    /// serves many requests per session, when the reply is all it sent and does not end
    /// the session; otherwise it is closed here.
    private func reply(on session: RelaySession) async throws -> Reply {
        var lines = LineAccumulator()
        while let chunk = try await session.receiveChunk() {
            let complete = lines.append(chunk)
            guard let first = complete.first else { continue }
            let reusable = session.multiRequest && complete.count == 1 && !lines.hasRemainder
                && !Self.endsSession(first)
            if !reusable { session.close() }
            return Reply(line: first, session: reusable ? session : nil)
        }
        guard lines.hasRemainder else { throw TransportError.closedBeforeResponse }
        session.close()
        return Reply(line: lines.flush(), session: nil)
    }

    /// The error codes after which herdr ends a guest session: `guest_paused`,
    /// `guest_revoked`, and `invalid_request` for a line that is not a request.
    /// `guest_forbidden` leaves it open.
    static let sessionEndingCodes: Set<String> = ["guest_paused", "guest_revoked", "invalid_request"]

    /// Whether `line` is an error reply that ends the session. Only a reply that quotes one
    /// of the codes is parsed; a quote inside a JSON string is escaped, so text that merely
    /// mentions a code never matches.
    static func endsSession(_ line: String) -> Bool {
        guard sessionEndingCodes.contains(where: { line.contains("\"\($0)\"") }) else { return false }
        let reply = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        guard let reply else { return true }
        guard let code = (reply["error"] as? [String: Any])?["code"] as? String else { return false }
        return sessionEndingCodes.contains(code)
    }

    /// Guest methods that only read, so a request that may have reached herdr on a session
    /// that then ended can go once more on a fresh one.
    static let readMethods: Set<String> = [
        "ping", "agent.list", "agent.get", "agent.read", "agent.avatar.get", "agent.transcript",
        "pane.read", "pane.history", "gram.list", "gram.get_file", "gram.get_file_chunk",
    ]

    static func onlyReads(_ requestLine: String) -> Bool {
        let request = (try? JSONSerialization.jsonObject(with: Data(requestLine.utf8))) as? [String: Any]
        guard let method = request?["method"] as? String else { return false }
        return readMethods.contains(method)
    }

    /// Whether `error` means the session was gone rather than the call failing: an end of
    /// stream before the reply, a close code this client does not map, or a dropped socket.
    /// A mapped close (offline, busy, rate limited, too large), a Noise failure, a timeout
    /// or a cancellation is the call's own answer.
    static func endedSession(_ error: Error) -> Bool {
        switch error {
        case let guest as GuestError:
            if case .connectionClosed = guest { return true }
            return false
        case let transport as TransportError:
            if case .closedBeforeResponse = transport { return true }
            return false
        case is CancellationError:
            return false
        default:
            return true
        }
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

/// A guest's one open session to a host that serves many requests per session
/// (`features.multi_request`), shared by every `RelayTransport` of the same guest, host
/// and device key. Calls take turns: herdr reads the next request only after the reply to
/// the one before, so a call waits until the call ahead of it finishes. Between calls the
/// session idles until the connector's `sessionIdleLimit` (herdr ends it after 60 s), its
/// `sessionAgeLimit` after the handshake, or `closeAll`.
final class ReusableSession: @unchecked Sendable {
    struct Key: Hashable {
        let endpoint: RelayEndpoint
        let guestID: String
        let device: Data
    }

    /// A call's turn, with the session the call before it left open (nil: open one).
    struct Turn: Sendable {
        let session: RelaySession?
        fileprivate let generation: Int
    }

    private struct Parked {
        let session: RelaySession
        let expires: ContinuousClock.Instant
        let timer: Task<Void, Never>
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [Key: ReusableSession] = [:]

    static func shared(_ key: Key) -> ReusableSession {
        registryLock.withLock {
            if let existing = registry[key] { return existing }
            let created = ReusableSession()
            registry[key] = created
            return created
        }
    }

    static func closeAll() {
        for reusable in registryLock.withLock({ Array(registry.values) }) { reusable.close() }
    }

    private let lock = NSLock()
    /// What the last handshake advertised; nil before the first.
    private var multiRequest: Bool?
    /// A call holds the turn.
    private var busy = false
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Turn, Error>)] = []
    private var lastWaiter: UInt64 = 0
    private var parked: Parked?
    /// Bumped by `close`: a session from a call that began before it is not kept.
    private var currentGeneration = 0

    /// Calls take turns on the shared session: the last handshake advertised it.
    var reuses: Bool { lock.withLock { multiRequest == true } }

    var generation: Int { lock.withLock { currentGeneration } }

    /// Remembers what a handshake advertised. A host that stopped advertising it (an older
    /// herdr after a restart) loses the idle session.
    func learn(multiRequest: Bool) {
        let dropped = lock.withLock { () -> RelaySession? in
            self.multiRequest = multiRequest
            return multiRequest ? nil : unpark()?.session
        }
        dropped?.close()
    }

    /// Waits for the call's turn. A session past its idle or age limit (the app was
    /// suspended before its timer ran) is closed rather than handed on.
    func take() async throws -> Turn {
        let id = lock.withLock { () -> UInt64 in
            lastWaiter += 1
            return lastWaiter
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var expired: RelaySession?
                let ready = lock.withLock { () -> Result<Turn, Error>? in
                    // Checked under the lock the cancellation handler takes: a call
                    // cancelled from here on finds its continuation queued.
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if busy {
                        waiters.append((id, continuation))
                        return nil
                    }
                    busy = true
                    var session: RelaySession?
                    if let idle = unpark() {
                        if ContinuousClock.now < idle.expires { session = idle.session } else { expired = idle.session }
                    }
                    return .success(Turn(session: session, generation: currentGeneration))
                }
                expired?.close()
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> CheckedContinuation<Turn, Error>? in
                guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: index).continuation
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    /// Ends a call's turn. `session`, still open (nil when the call ended it), goes to the
    /// next waiting call while younger than the connector's `sessionAgeLimit`, or idles
    /// until its idle or age limit.
    func finish(_ turn: Turn, keeping session: RelaySession?, limits: RelaySocketConnector) {
        var session = session
        var stale: RelaySession?
        let next = lock.withLock { () -> (CheckedContinuation<Turn, Error>, Turn)? in
            let aged = session.map { ContinuousClock.now >= $0.opened.advanced(by: limits.sessionAgeLimit) } ?? false
            if turn.generation != currentGeneration || aged {
                stale = session
                session = nil
            }
            if !waiters.isEmpty {
                return (waiters.removeFirst().continuation, Turn(session: session, generation: currentGeneration))
            }
            busy = false
            if let session { park(session, limits: limits) }
            return nil
        }
        stale?.close()
        if let (waiter, turn) = next { waiter.resume(returning: turn) }
    }

    /// Keeps a session a call opened outside the turns (before a handshake said the host
    /// serves many requests per session) when no other is open or in use; else closes it.
    func offer(_ session: RelaySession, from generation: Int, limits: RelaySocketConnector) {
        let kept = lock.withLock { () -> Bool in
            guard generation == currentGeneration, !busy, parked == nil else { return false }
            park(session, limits: limits)
            return true
        }
        if !kept { session.close() }
    }

    /// Closes the idle session; the one in use is closed when its call ends.
    func close() {
        let dropped = lock.withLock { () -> RelaySession? in
            currentGeneration += 1
            return unpark()?.session
        }
        dropped?.close()
    }

    /// Call with `lock` held. The session idles until its idle limit, or its age limit
    /// when that comes first.
    private func park(_ session: RelaySession, limits: RelaySocketConnector) {
        session.watchWhileIdle()
        let now = ContinuousClock.now
        let expires = min(now.advanced(by: limits.sessionIdleLimit), session.opened.advanced(by: limits.sessionAgeLimit))
        let timer = Task { [weak self] in
            guard (try? await Task.sleep(for: now.duration(to: expires))) != nil else { return }
            self?.expire(session)
        }
        parked = Parked(session: session, expires: expires, timer: timer)
    }

    private func expire(_ session: RelaySession) {
        let idle = lock.withLock { () -> RelaySession? in
            guard parked?.session === session else { return nil }
            return unpark()?.session
        }
        idle?.close()
    }

    /// Call with `lock` held.
    private func unpark() -> Parked? {
        defer { parked = nil }
        parked?.timer.cancel()
        return parked
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
    var sessionIdleLimit: Duration { base.sessionIdleLimit }
    var sessionAgeLimit: Duration { base.sessionAgeLimit }

    func connect(to url: URL) -> RelaySocket {
        let socket = base.connect(to: url)
        adopt(socket)
        return socket
    }

    /// Lets the deadline close `socket` too: one the call opened, or the reused session's.
    func adopt(_ socket: RelaySocket) {
        let late = lock.withLock { () -> Bool in
            if closed { return true }
            self.socket = socket
            return false
        }
        if late { socket.close() }
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
