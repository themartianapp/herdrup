import Citadel
import Foundation
import NIOCore

/// The exec channel a `RequestChannel` drives: one `herdr api-bridge --multi`
/// process. A protocol so tests can script the bridge without SSH.
protocol RequestChannelLink: Sendable {
    /// Runs the channel until it ends. Writes every buffer from `stdin` in order and
    /// hands every output chunk to `onOutput`. Returns when the remote side closes
    /// cleanly; throws a `RemoteExitError` on a non-zero exit, or the link's own error
    /// when it drops. Finishing `stdin` closes the channel.
    func run(
        stdin: AsyncStream<ByteBuffer>,
        onOutput: @escaping @Sendable (ExecCommandOutput) async -> Void
    ) async throws
}

/// The production link: an exec channel on the shared SSH connection, driven the
/// way `GramUploadChannel` drives its `remote-api-bridge` channel. `@unchecked` because
/// Citadel does not mark `SSHClient` Sendable; it is used from any task throughout
/// this module, its state confined to its NIO event loop.
struct CitadelRequestLink: RequestChannelLink, @unchecked Sendable {
    let client: SSHClient
    let command: String

    /// How the reader ended. `withExec` closes the channel itself after its body
    /// returns, and closing a channel the remote side already closed THROWS, so the
    /// error `withExec` reports can hide the real ending (a clean exit, or the exit
    /// status the bridge classification needs). The reader's own outcome wins.
    private final class ReaderEnd: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: Result<Void, Error>?
        func set(_ value: Result<Void, Error>) {
            lock.lock()
            defer { lock.unlock() }
            if outcome == nil { outcome = value }
        }
        var value: Result<Void, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return outcome
        }
    }

    func run(
        stdin: AsyncStream<ByteBuffer>,
        onOutput: @escaping @Sendable (ExecCommandOutput) async -> Void
    ) async throws {
        // `withExec` writes stdin; it needs macOS 15 (never a limit on iOS 17+). On an
        // older Mac the channel cannot open and every request keeps the per-request path.
        guard #available(macOS 15.0, *) else { throw RequestChannel.NotSent.closed }
        let end = ReaderEnd()
        do {
            try await client.withExec(command) { inbound, outbound in
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await buffer in stdin {
                            try await outbound.write(buffer)
                        }
                    }
                    group.addTask {
                        do {
                            for try await chunk in inbound {
                                await onOutput(chunk)
                            }
                            end.set(.success(()))
                        } catch {
                            end.set(.failure(error))
                            throw error
                        }
                    }
                    // Whichever side ends first ends the channel: the reader when the
                    // bridge exits or the link drops, the writer when `close()`
                    // finishes stdin.
                    try await group.next()
                    group.cancelAll()
                }
            }
        } catch {
            guard let readerEnd = end.value else { throw error }
            try readerEnd.get()
            return
        }
        try end.value?.get()
    }
}

/// Timing for `RequestChannel` and `RequestChannelPool`, in nanoseconds. Injectable
/// so tests can run every timer in milliseconds and drive idleness from a fake clock.
struct RequestChannelSettings: Sendable {
    /// How long a request on the channel may wait for its reply. The per-request path
    /// has no such bound, but there a dead link ends the exec channel; a held channel
    /// over a half-open TCP connection can stay silent forever, so the bound is what
    /// keeps a caller from hanging. Normal replies take well under a second; the
    /// slowest request the app sends waits up to 6 s server-side (`agent.prompt` with a
    /// `wait`), and a large `pane.read` over a poor cellular link takes seconds more.
    /// 60 s clears all of those with room to spare and still ends a dead request.
    var requestTimeout: UInt64 = 60 * 1_000_000_000

    /// A channel silent this long gets a `ping` before the next request uses it.
    /// While a screen is open the app polls far more often than this, so an active
    /// channel never pays the ping; one quiet for 30 s may have lost its network (a
    /// screen lock, a Wi-Fi/cellular handoff), and the ping finds that out in
    /// `probeTimeout` instead of letting the real request wait `requestTimeout`.
    var idleProbeAfter: UInt64 = 30 * 1_000_000_000

    /// Budget for that ping. A ping on a live channel is one round trip (under a
    /// second even on poor cellular); 5 s tolerates a congested link and still
    /// replaces a dead channel quickly.
    var probeTimeout: UInt64 = 5 * 1_000_000_000

    /// Budget for opening a channel: the exec, the remote shell, a herdr process
    /// start (~150 ms) and the first `ping`. Twice `probeTimeout` because it pays the
    /// process start on top of the round trip.
    var openTimeout: UInt64 = 10 * 1_000_000_000

    /// A channel with nothing in flight for this long is closed, so a session the user
    /// left (a session switch, a session pill polled once) does not hold a remote herdr
    /// process for the life of the app. Three minutes outlasts the gaps between
    /// requests on any open screen, so a channel in use is not churned.
    var unusedCloseAfter: UInt64 = 180 * 1_000_000_000

    /// After a failed open, requests use the per-request path for this long before the
    /// next open attempt, so a host whose channel cannot open does not pay a failed
    /// open on every request.
    var openRetryAfter: UInt64 = 30 * 1_000_000_000

    /// Monotonic time in nanoseconds. `ContinuousClock` keeps counting while the
    /// device sleeps, which is exactly the idleness that matters.
    var now: @Sendable () -> UInt64 = RequestChannelSettings.continuousNow

    private static let epoch = ContinuousClock.now
    static let continuousNow: @Sendable () -> UInt64 = {
        let (seconds, attoseconds) = (ContinuousClock.now - epoch).components
        return UInt64(max(0, seconds)) * 1_000_000_000 + UInt64(max(0, attoseconds) / 1_000_000_000)
    }
}

/// One held `herdr api-bridge --multi` exec channel (herdrup#389). Requests are
/// written as lines and matched to their replies by `id`, which the bridge carries
/// through unchanged; replies may arrive in any order.
///
/// Failure semantics match the per-request path so callers do not change: when the
/// channel ends, every pending request fails with the error a per-request exec ending
/// the same way throws (see `endFailure`). Nothing is retried here — a request that
/// was written may have run (`agent.rename`, `agent.archive` are not idempotent).
actor RequestChannel {
    /// The request was NOT written, so the caller may send it another way.
    enum NotSent: Error, Equatable {
        /// The channel is not open (never opened, closed, or ended).
        case closed
        /// A request with this `id` is already in flight. The bridge would refuse the
        /// second one with an error line carrying id "", which no caller could claim.
        case duplicateID
    }

    /// The bridge's limit on one request line, newline excluded (herdr PR #296). A
    /// longer line is rejected by the bridge, so it never rides the channel.
    static let maxRequestLineBytes = 1_048_576

    /// Methods the bridge refuses with `unsupported_method`: they stream, so they
    /// cannot share a line-per-reply channel.
    static let unsupportedMethods: Set<String> = [
        "events.subscribe", "pane.stream", "gram.upload.stream", "pane.input.stream",
        "server.ssh_agent.register",
    ]

    /// Cap on retained stderr: it is only diagnostic text for the end-of-channel
    /// classification, and the channel lives for minutes.
    private static let maxStderrBytes = 64 * 1024

    enum Status: Equatable {
        case ready
        /// Open, but idle past `idleProbeAfter` or marked suspect: ping before use.
        case needsProbe
        case closed
    }

    private struct Pending {
        let continuation: CheckedContinuation<String, Error>
        let timer: Task<Void, Never>
    }

    private enum State { case idle, open, closed }

    private let host: String
    private let settings: RequestChannelSettings
    private var state = State.idle
    private var stdin: AsyncStream<ByteBuffer>.Continuation?
    private var runner: Task<Void, Never>?
    private var pending: [String: Pending] = [:]
    private var lines = LineAccumulator()
    private var stderr = ""
    private var lastActivity: UInt64
    private var suspect = false
    private var pingSequence: UInt64 = 0
    private var unusedTimer: Task<Void, Never>?
    /// Every stdout byte the bridge has sent, complete line or not. A reply still
    /// streaming in moves it, which is how a probe tells a busy link from a dead one.
    private var inboundBytes: UInt64 = 0
    /// Probes waiting for any inbound byte, resumed true on the next chunk, false at
    /// their deadline or when the channel ends.
    private var progressWaiters: [UInt64: (continuation: CheckedContinuation<Bool, Never>, timer: Task<Void, Never>)] = [:]
    private var progressSequence: UInt64 = 0

    init(host: String, settings: RequestChannelSettings) {
        self.host = host
        self.settings = settings
        self.lastActivity = settings.now()
    }

    var isOpen: Bool { state == .open }

    func status() -> Status {
        guard state == .open else { return .closed }
        if suspect || settings.now() &- lastActivity >= settings.idleProbeAfter { return .needsProbe }
        return .ready
    }

    /// The next request pings first. For a return to the foreground, a timed-out
    /// request, or anything else that casts doubt on the link.
    func markSuspect() {
        suspect = true
    }

    /// Starts `link` and waits for the bridge to answer a `ping`, so no caller's
    /// request is the first thing to find out that the channel does not work (an old
    /// herdr binary without `--multi` exits instead of answering).
    func open(_ link: RequestChannelLink) async throws {
        guard state == .idle else { throw NotSent.closed }
        let (stream, continuation) = AsyncStream<ByteBuffer>.makeStream()
        stdin = continuation
        state = .open
        lastActivity = settings.now()
        // Holds the channel strongly for the link's lifetime: the link ends on
        // `close()`, the bridge exiting, or the SSH connection dropping.
        runner = Task {
            do {
                try await link.run(stdin: stream) { chunk in await self.receive(chunk) }
                self.linkEnded(nil)
            } catch {
                self.linkEnded(error)
            }
        }
        do {
            _ = try await ping(timeout: settings.openTimeout)
        } catch {
            close()
            throw error
        }
    }

    /// Checks the link is alive before a request uses it. It pings, then waits up to
    /// `probeTimeout` for ANY inbound byte: the pong, or the next piece of a reply still
    /// streaming in. On a slow link the pong queues behind whatever reply is ahead of
    /// it (a 0.9 MB transcript page takes far longer than 5 s on 3G), and closing then
    /// would fail that reply and every other pending request on a link that is
    /// working. Only a link silent for the whole budget is closed. True when alive.
    func probe() async -> Bool {
        guard state == .open else { return false }
        let mark = inboundBytes
        // The pong only has to prove liveness when nothing else is arriving, so it gets
        // the normal request budget: a short one would expire behind the busy reply and
        // mark the channel suspect again for no reason.
        let pong = Task { _ = try? await self.ping(timeout: self.settings.requestTimeout) }
        if await inboundArrived(since: mark, within: settings.probeTimeout) {
            suspect = false
            return true
        }
        pong.cancel()
        close()
        return false
    }

    private func ping(timeout: UInt64) async throws -> String {
        pingSequence &+= 1
        let id = "herdrkit:request-channel-ping:\(pingSequence)"
        return try await send(#"{"id":"\#(id)","method":"ping","params":{}}"#, id: id, timeout: timeout)
    }

    /// Writes `requestLine` (whose `id` is `id`, see `route`) and waits for the
    /// reply carrying that id. Throws `NotSent` when nothing was written; after that,
    /// a `TransportError` (the channel ended, or `requestTimedOut`), or
    /// `CancellationError` when the caller is cancelled.
    func send(_ requestLine: String, id: String, timeout: UInt64) async throws -> String {
        guard state == .open, let stdin else { throw NotSent.closed }
        guard pending[id] == nil else { throw NotSent.duplicateID }
        try Task.checkCancellation()

        var buffer = ByteBuffer()
        buffer.reserveCapacity(requestLine.utf8.count + 1)
        buffer.writeString(requestLine)
        buffer.writeInteger(UInt8(ascii: "\n"))
        lastActivity = settings.now()
        unusedTimer?.cancel()
        unusedTimer = nil

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let timer = Task { [weak self] in
                    // `try?`: a cancelled sleep means the reply came; the guard below.
                    try? await Task.sleep(nanoseconds: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.expire(id)
                }
                pending[id] = Pending(continuation: continuation, timer: timer)
                stdin.yield(buffer)
            }
        } onCancel: {
            Task { await self.abandon(id, with: CancellationError()) }
        }
    }

    /// Closes the channel; every pending request fails with `closedBeforeResponse`.
    /// Does not wait for the remote side: finishing stdin makes the link close the
    /// exec channel, and the remote bridge exits on the EOF. Idempotent.
    func close() {
        guard state != .closed else { return }
        finish(failing: TransportError.closedBeforeResponse)
        runner?.cancel()
    }

    // MARK: - internals

    private func expire(_ id: String) {
        guard pending[id] != nil else { return }
        // A request that got no reply casts doubt on the link: the next one pings first.
        suspect = true
        abandon(id, with: TransportError.requestTimedOut(host: host))
    }

    /// Fails one pending request. A reply that arrives later is dropped.
    private func abandon(_ id: String, with error: Error) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timer.cancel()
        entry.continuation.resume(throwing: error)
        scheduleUnusedCloseIfIdle()
    }

    private func receive(_ chunk: ExecCommandOutput) {
        switch chunk {
        case .stdout(let bytes):
            if bytes.readableBytes > 0 { noteInbound(bytes.readableBytes) }
            for line in lines.append(bytes) {
                deliver(line)
            }
        case .stderr(let bytes):
            if stderr.utf8.count < Self.maxStderrBytes {
                stderr += String(buffer: bytes)  // diagnostic text; a lossy decode is fine
            }
        }
    }

    /// Any stdout byte proves the link alive: it counts as activity (so a channel busy
    /// receiving a long reply is not "idle" and owes no probe) and wakes every probe.
    private func noteInbound(_ count: Int) {
        inboundBytes &+= UInt64(count)
        lastActivity = settings.now()
        resolveProgressWaiters(alive: true)
    }

    /// True as soon as an inbound byte arrives after `mark`; false when none does
    /// within `timeout`, or the channel ends first.
    private func inboundArrived(since mark: UInt64, within timeout: UInt64) async -> Bool {
        if inboundBytes != mark { return true }
        guard state == .open else { return false }
        progressSequence &+= 1
        let token = progressSequence
        return await withCheckedContinuation { continuation in
            let timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeout)
                guard !Task.isCancelled else { return }
                await self?.resolveProgressWaiter(token, alive: false)
            }
            progressWaiters[token] = (continuation, timer)
        }
    }

    private func resolveProgressWaiter(_ token: UInt64, alive: Bool) {
        guard let waiter = progressWaiters.removeValue(forKey: token) else { return }
        waiter.timer.cancel()
        waiter.continuation.resume(returning: alive)
    }

    private func resolveProgressWaiters(alive: Bool) {
        guard !progressWaiters.isEmpty else { return }
        let waiting = progressWaiters
        progressWaiters = [:]
        for waiter in waiting.values {
            waiter.timer.cancel()
            waiter.continuation.resume(returning: alive)
        }
    }

    private func deliver(_ line: String) {
        lastActivity = settings.now()
        // No owner: a reply to a request that timed out or was cancelled, or a bridge
        // error line with an empty id. Nobody is waiting for it.
        guard let id = Self.responseID(line), let entry = pending.removeValue(forKey: id) else { return }
        entry.timer.cancel()
        if let failure = CitadelTransport.daemonSocketFailure(in: line, host: host) {
            entry.continuation.resume(throwing: failure)
        } else {
            entry.continuation.resume(returning: line)
        }
        scheduleUnusedCloseIfIdle()
    }

    private func linkEnded(_ error: Error?) {
        if lines.hasRemainder { deliver(lines.flush()) }
        guard state != .closed else { return }
        finish(failing: Self.endFailure(error, stderr: stderr, host: host))
    }

    private func finish(failing failure: Error) {
        state = .closed
        stdin?.finish()
        stdin = nil
        unusedTimer?.cancel()
        unusedTimer = nil
        let waiting = pending
        pending = [:]
        for entry in waiting.values {
            entry.timer.cancel()
            entry.continuation.resume(throwing: failure)
        }
        resolveProgressWaiters(alive: false)
    }

    private func scheduleUnusedCloseIfIdle() {
        guard state == .open, pending.isEmpty else { return }
        unusedTimer?.cancel()
        let after = settings.unusedCloseAfter
        unusedTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: after)
            guard !Task.isCancelled else { return }
            await self?.closeIfUnused()
        }
    }

    private func closeIfUnused() {
        // Every `send` cancels the timer, so reaching here with nothing in flight
        // means nothing was sent for `unusedCloseAfter`.
        guard state == .open, pending.isEmpty else { return }
        close()
    }

    // MARK: - wire

    private struct Head: Decodable {
        let id: String?
        let method: String?
    }

    /// The error pending requests fail with when the channel ends: the same
    /// classification `CitadelTransport.parseBridgeOutput` gives a per-request exec
    /// that ends without a reply, so a caller sees no difference between the paths.
    static func endFailure(_ error: Error?, stderr: String, host: String) -> Error {
        switch error {
        case let exit as RemoteExitError:
            return CitadelTransport.classifyBridgeFailure(
                stderr: stderr, exitCode: exit.remoteExitCode, host: host)
        case let error?:
            return error
        case nil:
            guard !stderr.isEmpty else { return TransportError.closedBeforeResponse }
            return CitadelTransport.classifyBridgeFailure(stderr: stderr, exitCode: 0, host: host)
        }
    }

    /// Which held channel a request rides. The bridge writes each reply whole, so on
    /// one channel a big reply holds up every reply queued behind it: a 0.9 MB
    /// transcript page took `agent.list` from 0.8 s to 8.6 s on a 3G link. Replies that
    /// can run to hundreds of kilobytes get their own channel, so the small ones the
    /// screen waits on (the agent list, a prompt, a key) never queue behind them.
    enum Lane: Hashable, Sendable {
        case interactive
        case bulk
    }

    /// Methods whose replies can be large: transcript pages, terminal reads and
    /// history, Gram lists and file bytes.
    static let bulkMethods: Set<String> = [
        "agent.transcript", "agent.read", "pane.read", "pane.history",
        "gram.list", "gram.get_file", "gram.get_file_chunk",
    ]

    struct Route: Equatable {
        let id: String
        let lane: Lane
    }

    /// How the request can ride a channel: within the bridge's line limit, a single
    /// line, a non-empty string id, and not a streaming method. nil sends it down the
    /// per-request path instead.
    static func route(_ requestLine: String) -> Route? {
        let bytes = requestLine.utf8
        guard bytes.count <= maxRequestLineBytes, !bytes.contains(UInt8(ascii: "\n")),
              let head = try? JSONDecoder().decode(Head.self, from: Data(bytes)),
              let id = head.id, !id.isEmpty,
              let method = head.method, !unsupportedMethods.contains(method)
        else { return nil }
        return Route(id: id, lane: bulkMethods.contains(method) ? .bulk : .interactive)
    }

    /// A reply's `id`. herdr writes it first, so the common case reads only the
    /// line's opening bytes; anything else (escapes, another key order) falls back to
    /// a JSON decode.
    static func responseID(_ line: String) -> String? {
        let prefix = #"{"id":""#
        if line.hasPrefix(prefix) {
            let bytes = line.utf8
            let start = bytes.index(bytes.startIndex, offsetBy: prefix.utf8.count)
            if let end = bytes[start...].firstIndex(where: { $0 == UInt8(ascii: "\"") || $0 == UInt8(ascii: "\\") }),
               bytes[end] == UInt8(ascii: "\"") {
                return String(line[start..<end])
            }
        }
        return (try? JSONDecoder().decode(Head.self, from: Data(line.utf8)))?.id
    }
}

/// The request channels of one SSH connection, at most two per herdr session
/// (herdrup#390, #391): an interactive lane and a bulk lane (`RequestChannel.Lane`).
/// Shared by a `CitadelTransport` and its `forSession` siblings.
///
/// Routing per session:
/// - capability unknown: the request takes the per-request path while a `ping` over
///   that path reads `capabilities.api_bridge_multi` in the background, so first use
///   costs no extra round trip. A failed probe stays unknown and is retried.
/// - unsupported (older herdr): always the per-request path.
/// - supported: the lane's channel, opened (or reopened after it ended) on demand.
///   A channel that fails to open sends that request down the per-request path, and
///   the next attempt waits `openRetryAfter`. A request is never failed only because
///   the channel is unavailable.
/// - each lane opens on its first request, so a session that never asks for a big
///   reply (another session's `agent.list` for the session pills) never holds a second
///   bridge process. A big request never borrows the interactive lane, even while its
///   own channel opens: that wait is one exec on the open connection, while a big
///   reply on the interactive lane holds up every small one behind it.
actor RequestChannelPool {
    /// The per-request path for one request line in one session.
    typealias PerRequest = @Sendable (_ requestLine: String, _ session: String?) async throws -> String
    /// Opens the link for one session's `api-bridge --multi` channel.
    typealias LinkOpener = @Sendable (_ session: String?) async throws -> RequestChannelLink
    typealias Lane = RequestChannel.Lane

    private enum Capability { case unknown, supported, unsupported }

    private struct LaneState {
        var channel: RequestChannel?
        /// An open or a ping in flight; concurrent requests await this one.
        var preparing: Task<RequestChannel?, Never>?
        var retryOpenAt: UInt64?
    }

    private struct Slot {
        var capability = Capability.unknown
        var probe: Task<Void, Never>?
        var lanes: [Lane: LaneState] = [:]
    }

    private let host: String
    private let settings: RequestChannelSettings
    private let perRequest: PerRequest
    private let openLink: LinkOpener
    private var slots: [String: Slot] = [:]
    /// Bumped by `close()`, so a probe or open that finishes afterwards installs nothing.
    private var generation: UInt64 = 0
    private var probeSequence: UInt64 = 0

    init(host: String, settings: RequestChannelSettings, perRequest: @escaping PerRequest, openLink: @escaping LinkOpener) {
        self.host = host
        self.settings = settings
        self.perRequest = perRequest
        self.openLink = openLink
    }

    /// One slot per session as herdr resolves it: nil, "default" and an invalid name
    /// all address the default session (`CitadelTransport.flagSession`).
    private static func key(_ session: String?) -> String {
        CitadelTransport.flagSession(session) ?? ""
    }

    /// The reply when the request rode one of the session's channels; nil when the
    /// caller must use the per-request path (nothing was written to a channel).
    func send(_ requestLine: String, session: String?) async throws -> String? {
        guard let route = RequestChannel.route(requestLine) else { return nil }
        let key = Self.key(session)
        switch slots[key]?.capability ?? .unknown {
        case .unsupported:
            return nil
        case .unknown:
            startCapabilityProbe(key, session: session)
            return nil
        case .supported:
            break
        }
        guard let channel = await readyChannel(key, lane: route.lane, session: session) else { return nil }
        do {
            return try await channel.send(requestLine, id: route.id, timeout: settings.requestTimeout)
        } catch is RequestChannel.NotSent {
            return nil
        }
    }

    /// Every open channel pings before its next request (the app calls this on its
    /// return to the foreground: a suspended process's channel may not have survived).
    func markSuspect() async {
        for slot in slots.values {
            for state in slot.lanes.values {
                await state.channel?.markSuspect()
            }
        }
    }

    /// Closes every channel and forgets every capability. Idempotent.
    func close() async {
        generation &+= 1
        let closing = slots
        slots = [:]
        for slot in closing.values {
            slot.probe?.cancel()
            for state in slot.lanes.values {
                state.preparing?.cancel()
                await state.channel?.close()
            }
        }
    }

    /// Waits until no background probe or open is in flight. Test-only.
    func settle() async {
        while let task = slots.values.lazy.compactMap({ $0.probe }).first { await task.value }
        while let task = slots.values.lazy.flatMap({ $0.lanes.values }).compactMap({ $0.preparing }).first {
            _ = await task.value
        }
    }

    /// Whether the session's channel on `lane` is open right now. Test-only.
    func hasOpenChannel(session: String?, lane: Lane = .interactive) async -> Bool {
        guard let channel = slots[Self.key(session)]?.lanes[lane]?.channel else { return false }
        return await channel.isOpen
    }

    // MARK: - capability

    private func startCapabilityProbe(_ key: String, session: String?) {
        guard slots[key]?.probe == nil else { return }
        probeSequence &+= 1
        let line = #"{"id":"herdrkit:request-channel-probe:\#(probeSequence)","method":"ping","params":{}}"#
        let generation = generation
        let perRequest = perRequest
        slots[key, default: Slot()].probe = Task {
            let supported: Bool?
            do {
                supported = Self.advertisesMulti(try await perRequest(line, session))
            } catch {
                supported = nil
            }
            await self.capabilityProbed(key, session: session, supported: supported, generation: generation)
        }
    }

    private func capabilityProbed(_ key: String, session: String?, supported: Bool?, generation: UInt64) async {
        guard generation == self.generation else { return }
        slots[key]?.probe = nil
        guard let supported else { return }
        slots[key, default: Slot()].capability = supported ? .supported : .unsupported
        // Open now, off the request path, so the next request finds it ready.
        if supported { _ = await readyChannel(key, lane: .interactive, session: session) }
    }

    /// `api_bridge_multi` from a `ping` reply; nil when the reply is not a ping result
    /// (an error envelope), which leaves the capability unknown.
    static func advertisesMulti(_ reply: String) -> Bool? {
        guard let envelope = try? JSONDecoder().decode(ResultEnvelope<PingResult>.self, from: Data(reply.utf8))
        else { return nil }
        return envelope.result.capabilities?.apiBridgeMulti ?? false
    }

    // MARK: - channel

    /// The lane's channel ready for a request, opening or pinging it first when
    /// needed; nil when there is none to use right now.
    private func readyChannel(_ key: String, lane: Lane, session: String?) async -> RequestChannel? {
        if let preparing = slots[key]?.lanes[lane]?.preparing { return await preparing.value }
        let current = slots[key]?.lanes[lane]?.channel
        let status = await current?.status() ?? .closed
        if status == .ready, let current { return current }
        // Re-read after the suspension: another request may have started preparing.
        if let preparing = slots[key]?.lanes[lane]?.preparing { return await preparing.value }
        if status == .closed, let retryAt = slots[key]?.lanes[lane]?.retryOpenAt, settings.now() < retryAt { return nil }
        let generation = generation
        let task = Task { await self.prepare(key, lane: lane, session: session, current: current, generation: generation) }
        slots[key, default: Slot()].lanes[lane, default: LaneState()].preparing = task
        return await task.value
    }

    private func prepare(
        _ key: String, lane: Lane, session: String?, current: RequestChannel?, generation: UInt64
    ) async -> RequestChannel? {
        defer { if generation == self.generation { slots[key]?.lanes[lane]?.preparing = nil } }
        if let current {
            switch await current.status() {
            // A reply landed since the caller looked: it is live, and may have
            // requests in flight that closing would fail.
            case .ready: return current
            case .needsProbe: if await current.probe() { return current }
            case .closed: break
            }
            await current.close()
        }
        let channel = RequestChannel(host: host, settings: settings)
        do {
            try await channel.open(try await openLink(session))
        } catch {
            await channel.close()
            if generation == self.generation {
                slots[key]?.lanes[lane]?.channel = nil
                slots[key]?.lanes[lane]?.retryOpenAt = settings.now() &+ settings.openRetryAfter
            }
            // The host advertised api_bridge_multi but the bridge would not answer:
            // usually the `herdr` found first on that machine's PATH is older than its
            // server. Every request is now on the slow path, so say so in the report.
            TypingLatencyRecorder.shared.noteHeldChannelOpenFailed(host: host)
            return nil
        }
        guard generation == self.generation else {
            await channel.close()
            return nil
        }
        slots[key, default: Slot()].lanes[lane, default: LaneState()].channel = channel
        slots[key]?.lanes[lane]?.retryOpenAt = nil
        return channel
    }
}
