import Foundation
import Citadel
import Crypto
import NIOCore
import NIOSSH

/// The pure-Swift transport: swift-nio-ssh + Citadel, replacing libssh2.
///
/// Where `SSHTransport` needed a bounded thread pool, a cancellation handle that
/// publishes the socket, and `DescriptorAudit` — all because libssh2 blocks and
/// owns raw fds — this needs none of it. Citadel is async/await-native:
/// cancellation is `channel.close()` on an event loop, and there are no fds to
/// audit. That deletion is the whole point of route B.
///
/// It reaches herdr's JSON API not by forwarding a unix socket (libssh2's
/// `direct-streamlocal`, which nio-ssh does not implement) but by exec'ing the
/// `herdr api-bridge` subcommand over SSH channels and reading its stdout. Two
/// ways, chosen per herdr session (#390):
///
/// - On a herdr that advertises `api_bridge_multi`, one held channel runs
///   `herdr api-bridge --multi` and carries every one-off request as a line
///   (`RequestChannel`, `RequestChannelPool`), so a request costs neither a channel
///   open nor a herdr process start.
/// - Otherwise — and for anything the channel cannot carry, or whenever it is
///   unavailable — the per-request path: one channel per call, the request riding as
///   a base64 argument (Citadel's `executeCommandStream` does not write the channel
///   stdin, and base64 keeps arbitrary JSON off the remote shell's quoting rules).
///
/// One `SSHClient` is held and reused across calls (no per-request handshake —
/// closing issue #25), and every long-lived stream (status and chat subscriptions,
/// `pane.stream`, `pane.input.stream`, Gram uploads) runs as a CHANNEL on that same
/// connection rather than a connection of its own (`SharedFirstLink`). Conforms to
/// the two-method `HerdrTransport` seam.
/// Lets exactly one racer resume a continuation. Resuming a continuation twice is
/// undefined behaviour rather than a catchable error, so the guard has to be
/// atomic — a plain Bool read-then-write is a race in exactly the interleaving
/// this exists to prevent.
final class FirstPastThePost: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

public actor CitadelTransport: HerdrTransport, MachineFederationTransport, SessionListingTransport {
    private let credentials: SSHCredentials
    /// The SSH connection one-off requests share. Siblings made with
    /// `forSession(_:)` hold the SAME core, so switching herdr sessions reuses the
    /// connection instead of paying a new SSH handshake (#386).
    private let connection: SSHConnectionCore
    /// How exec channels are opened. Production execs over `connection`; tests script it.
    private let backend: ExecBackend
    /// The `api-bridge --multi` channels, one per herdr session, shared by every
    /// `forSession` sibling so `close()` on any of them closes all (#390).
    private let requestChannels: RequestChannelPool

    /// - Parameters:
    ///   - credentials: host/port/username, the Ed25519 private key, and the
    ///     passphrase. `remoteSocketPath` is unused here — the server-side
    ///     api-bridge resolves the API socket itself.
    ///   - hostKeyValidator: the raw Citadel validator, for callers that need
    ///     full control (e.g. `.acceptAnything()` in an isolated live test).
    ///     Prefer the `hostKeyPolicy` initializer, whose default pins.
    ///   - connectTimeoutNanoseconds: the connect budget. Injectable so the timeout
    ///     can be TESTED against a black-hole address in milliseconds.
    public init(
        credentials: SSHCredentials,
        hostKeyValidator: SSHHostKeyValidator,
        connectTimeoutNanoseconds: UInt64 = CitadelTransport.defaultConnectTimeoutNanoseconds
    ) {
        let connection = SSHConnectionCore(
            credentials: credentials, hostKeyValidator: hostKeyValidator,
            connectTimeoutNanoseconds: connectTimeoutNanoseconds)
        self.init(credentials: credentials, connection: connection, backend: .ssh(connection))
    }

    /// The designated initializer. `backend` replaces the SSH exec plumbing and
    /// `requestChannelSettings` the channel timers, so routing is testable without SSH.
    init(
        credentials: SSHCredentials,
        connection: SSHConnectionCore,
        backend: ExecBackend,
        requestChannelSettings: RequestChannelSettings = RequestChannelSettings()
    ) {
        self.credentials = credentials
        self.connection = connection
        self.backend = backend
        let host = credentials.host
        self.requestChannels = RequestChannelPool(
            host: host,
            settings: requestChannelSettings,
            perRequest: { requestLine, session in
                try await CitadelTransport.perRequestRoundTrip(
                    requestLine, session: session, host: host, backend: backend)
            },
            openLink: { session in
                try await backend.openLink(CitadelTransport.multiBridgeCommand(session: session))
            })
    }

    private init(credentials: SSHCredentials, sharing sibling: CitadelTransport) {
        self.credentials = credentials
        self.connection = sibling.connection
        self.backend = sibling.backend
        self.requestChannels = sibling.requestChannels
    }

    /// A transport for ANOTHER herdr session on the same machine that shares this
    /// one's SSH connection (#386): switching sessions costs no handshake. It is a
    /// separate object on purpose: a client built on it can only ever address its
    /// own session, so a late request from the previous session's screens (a
    /// terminal's resize, a reload) can never land on the same pane id in the new
    /// one. `close()` on either closes the shared connection.
    public nonisolated func forSession(_ session: String?) -> CitadelTransport {
        var scoped = credentials
        scoped.session = session
        return CitadelTransport(credentials: scoped, sharing: self)
    }

    /// The herdr session this transport addresses; nil is the default session.
    public nonisolated var session: String? { credentials.session }

    /// Pins the host key on first contact and hard-stops on change (TOFU),
    /// wrapping the policy in the nio-ssh delegate internally so a caller needs
    /// no Citadel/nio-ssh types and cannot accidentally get a trust-everything
    /// validator.
    ///
    /// The default policy (`PinningHostKeyPolicy()`) is backed by the
    /// PROCESS-WIDE `PinStore.shared`, so two transports created this way enforce
    /// one pin set (a transport recreated mid-process still hard-stops a changed
    /// key). It does NOT persist across app launches — for cross-launch TOFU a
    /// shipping client passes its own `HostKeyPolicy` here that pins against
    /// persistent (e.g. Keychain) storage; `PinStore` is in-memory only.
    public init(
        credentials: SSHCredentials,
        hostKeyPolicy: HostKeyPolicy = PinningHostKeyPolicy(),
        connectTimeoutNanoseconds: UInt64 = CitadelTransport.defaultConnectTimeoutNanoseconds
    ) {
        self.init(
            credentials: credentials,
            hostKeyValidator: .custom(PinningHostKeyValidator(
                host: credentials.host, port: credentials.port, policy: hostKeyPolicy)),
            connectTimeoutNanoseconds: connectTimeoutNanoseconds)
    }

    // MARK: - connection

    private func connectedClient() async throws -> SSHClient {
        try await connection.connectedClient()
    }

    /// Conservative ceiling on the full command line, well under the kernel's
    /// MAX_ARG_STRLEN (~131072 on a 4-KiB-page Linux host; the reviewer measured
    /// E2BIG at exactly 131072). It bounds the WHOLE string `herdrCommand` builds,
    /// wrapper included: sshd hands that entire string to the account's shell as ONE
    /// `-c` argument, so it is the single largest argv element on the host. The
    /// margin absorbs cross-platform variance. base64's 4/3 expansion means the raw
    /// request may be up to ~90 KiB — ample for every request except an enormous
    /// `agent.prompt` / `pane.send_text`, which is refused rather than failing at
    /// execve with no bridge to report it.
    ///
    /// Bounds the per-request path only. A request riding a `--multi` request
    /// channel is a stdin line, not an argument, and is bounded by the bridge's own
    /// line limit instead (`RequestChannel.maxRequestLineBytes`, 1 MiB); a line over
    /// that takes this path and is refused here exactly as before.
    static let maxCommandBytes = 120_000

    /// Default budget for a connect, handshake included.
    ///
    /// Well above a real handshake — even a slow cellular link completes in a
    /// second or two — and far below the OS's own ~75s give-up on an unroutable
    /// address. The gap between those two numbers is the whole point: 15s is long
    /// enough that no working connection is cut off, short enough that a broken
    /// one says so while the user is still looking at it.
    ///
    /// This budget is the ONLY one: it also bounds the TCP connect and Citadel's own
    /// handshake timer (`SSHClientSettings.loginTimeout`, a fixed 10 s upstream), which
    /// otherwise cut off a slow link's handshake first — measured at 5–8 s on a 600 ms,
    /// 5 % loss link, and over 10 s once other traffic shares it.
    public static let defaultConnectTimeoutNanoseconds: UInt64 = 15 * 1_000_000_000

    /// The request, base64-encoded. Kept separate from the command so the
    /// encoding contract can be tested without the shell wrapper around it.
    static func encodedRequest(for requestLine: String) -> String {
        Data(requestLine.utf8).base64EncodedString()
    }

    /// Sentinel the launcher prints to stderr when herdr is absent (see
    /// `herdrResolution`). `classifyBridgeFailure` matches it to raise
    /// `.herdrNotInstalled` rather than a generic `.bridgeFailed`. A fixed ASCII
    /// token, deliberately NOT the shell's locale-dependent "not found" wording.
    static let herdrNotInstalledSentinel = "__HERDR_NOT_INSTALLED__"

    /// POSIX `sh` that resolves herdr on the remote host into `$HERDR`: prefer
    /// `PATH`, fall back to the standard `~/.local/bin` install location — then
    /// GUARD that the resolved path is actually executable before exec'ing it.
    ///
    /// A non-interactive SSH exec runs a NON-login shell, whose `PATH` does not
    /// include `~/.local/bin` — where herdr installs by default — so a bare
    /// `herdr api-bridge` fails with "command not found". A live round-trip
    /// caught exactly this. This mirrors herdr's own remote wrapper
    /// (src/remote/unix.rs: `command -v herdr`, else `$HOME/.local/bin/herdr`).
    ///
    /// The `[ -x "$HERDR" ]` guard separates "herdr is not installed at all" from
    /// every other bridge failure: when neither PATH nor the fallback path holds an
    /// executable, it prints `herdrNotInstalledSentinel` and exits BEFORE exec, so
    /// `classifyBridgeFailure` can raise `.herdrNotInstalled` and the client can
    /// offer install guidance instead of surfacing a raw stderr line.
    ///
    /// Only `/bin/sh` ever parses this; `herdrCommand` single-quotes it for the
    /// account's shell, so it must stay `isShellLiteral`.
    static let herdrResolution =
        #"HERDR=$(command -v herdr || echo "$HOME/.local/bin/herdr"); [ -x "$HERDR" ] || { echo \#(herdrNotInstalledSentinel) >&2; exit 127; }; "#

    /// Longest word a payload is split into. Debian's `csh` (bsd-csh) refuses a word
    /// of about 8 KiB ("Word too long": 8100 bytes passed, 8189 failed), and a
    /// request near `maxCommandBytes` is 120 KB of base64.
    static let payloadWordBytes = 4096

    /// Whether every login shell reads `word` literally inside single quotes: no `'`,
    /// which ends the quote everywhere; no backslash, which fish still unescapes
    /// there; no newline, which csh and tcsh reject; no `!`, which they
    /// history-expand when interactive.
    static func isShellLiteral(_ word: String) -> Bool {
        !word.utf8.contains { byte in
            byte == UInt8(ascii: "'") || byte == UInt8(ascii: "\\") || byte == UInt8(ascii: "!")
                || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
        }
    }

    /// Whether `word` may appear unquoted in the `sh` script as one plain word.
    /// A herdr session name as `herdr --session` accepts it (`session::validate_name`):
    /// 1-64 bytes of ASCII letters, digits, `.`, `_`, `-`, and not `.` or `..`. Every one of
    /// those bytes is literal inside the single-quoted `sh -c` script.
    public static func isSessionName(_ name: String) -> Bool {
        guard (1...64).contains(name.utf8.count), name != ".", name != ".." else { return false }
        return name.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
    }

    /// The session to pass as `--session`, or nil for the default session. An invalid name
    /// is dropped rather than interpolated: it can only come from a corrupted saved value.
    static func flagSession(_ session: String?) -> String? {
        guard let session, session != "default", isSessionName(session) else { return nil }
        return session
    }

    static func isBareWord(_ word: String) -> Bool {
        !word.isEmpty && word.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || byte == UInt8(ascii: "-")
        }
    }

    /// The SSH exec command line that runs `herdr <arguments> [<payload>]` on the host.
    ///
    /// sshd does not exec this string: it runs it as `<account shell> -c <string>`,
    /// and that shell may be fish, csh or tcsh, none of which speak POSIX sh: fish
    /// rejects the `NAME=value` assignment and exits 127 before anything runs
    /// (herdrup#276), and csh and tcsh have no `$(…)` or `{ …; }`. So the account's
    /// shell sees one simple command that every shell parses identically —
    /// `/bin/sh -c '<script>' sh '<payload word>'…` — and hands the script and each
    /// payload word to `/bin/sh` unchanged. Every word is single-quoted and
    /// `isShellLiteral`, so no escaping exists for a shell to interpret differently.
    /// `/bin/sh` by absolute path: every POSIX host has it, and no `PATH` entry or
    /// shell function can shadow it.
    ///
    /// `arguments` are fixed `isBareWord` words written into the script. `payload`
    /// is split on Character boundaries into words of at most `payloadWordBytes`
    /// UTF-8 bytes for csh, and the script rejoins them into one final argument:
    /// with `IFS` empty, `"$*"` concatenates the positional parameters with no
    /// separator.
    static func herdrCommand(_ arguments: [String], payload: String? = nil, session: String? = nil) -> String {
        assert(arguments.allSatisfy(isBareWord), "an argument that is not a plain word")
        var script = herdrResolution
        if payload != nil { script += "IFS=; " }
        script += #"exec "$HERDR""#
        // `--session` is a global flag herdr strips before the subcommand runs (#347). Only a
        // NAMED session sends it: the default session is the flag's absence, which also keeps
        // every command byte-identical for machines on a herdr that predates sessions.
        if let name = flagSession(session) { script += " --session " + name }
        for argument in arguments { script += " " + argument }
        guard let payload else { return "/bin/sh -c '" + script + "'" }
        assert(isShellLiteral(payload), "a payload some login shell would not read literally")

        var command = "/bin/sh -c '" + script + #" "$*"' sh"#
        var rest = payload[...]
        // Close each word before the next Character's UTF-8 would pass the budget.
        // A Character larger than the budget is emitted alone so this terminates.
        while !rest.isEmpty {
            var end = rest.startIndex
            var used = 0
            while end < rest.endIndex {
                let nextBytes = rest[end].utf8.count
                if used > 0 && used + nextBytes > payloadWordBytes { break }
                used += nextBytes
                end = rest.index(after: end)
            }
            command += " '"
            command += rest[..<end]
            command += "'"
            rest = rest[end...]
        }
        return command
    }

    /// Classify only a positively unsupported `api-bridge` command as an
    /// incompatible installation. Exit 2 is also used for unrelated usage
    /// failures, which must retain their actual diagnostic.
    static func classifyBridgeFailure(stderr: String, exitCode: Int, host: String) -> TransportError {
        if stderr.contains(herdrNotInstalledSentinel) { return .herdrNotInstalled(host: host) }
        if exitCode == 2 && [
            "unrecognized subcommand 'api-bridge'",
            "unknown subcommand 'api-bridge'",
            "invalid subcommand 'api-bridge'",
            "unexpected argument 'api-bridge'",
            "Found argument 'api-bridge' which wasn't expected"
        ].contains(where: { stderr.contains($0) }) {
            return .herdrIncompatible(host: host)
        }
        // 127 is a shell's "could not run that command". With the sentinel ruled out,
        // herdr itself never started: the account's shell rejected the command line
        // (fish did, before herdrup#276) or herdr's exec failed. Calling that a
        // bridge that "produced no reply" pointed at a daemon that was never reached.
        if exitCode == 127 { return .remoteShellFailed(host: host, stderr: stderr) }
        return .bridgeFailed(stderr: stderr)
    }

    /// The installed bridge reports Unix-socket connect failures as a correlated
    /// JSON `transport_error` reply on stdout (normally with exit status zero).
    /// Inspect only candidate error lines; normal API replies, including large
    /// payloads, incur no JSON parse or extra Data allocation here.
    static func daemonSocketFailure(in line: String, host: String) -> TransportError? {
        guard line.contains("\"transport_error\""),
              let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: Data(line.utf8)),
              envelope.error.code == "transport_error"
        else { return nil }
        let message = envelope.error.message
        guard message.hasPrefix("api-bridge: "),
              message.contains("No such file or directory (os error 2)")
                || message.contains("Connection refused (os error 111)")
                || message.contains("Connection refused (os error 61)")
        else { return nil }
        return .daemonUnavailable(host: host)
    }

    /// The full exec command line: resolve herdr, then run
    /// `api-bridge <base64(requestLine)>`. base64 so no JSON metacharacter needs
    /// shell quoting. Throws `TransportError.requestTooLarge` rather than let the
    /// command exceed the argv limit and fail opaquely on the host (herdr#39's
    /// client contract).
    static func bridgeCommand(for requestLine: String, session: String? = nil) throws -> String {
        let command = herdrCommand(["api-bridge"], payload: encodedRequest(for: requestLine), session: session)
        let byteCount = command.utf8.count
        guard byteCount <= maxCommandBytes else {
            throw TransportError.requestTooLarge(bytes: byteCount, max: maxCommandBytes)
        }
        return command
    }

    /// The exec command line for a session's held request channel (#389).
    static func multiBridgeCommand(session: String?) -> String {
        herdrCommand(["api-bridge", "--multi"], session: session)
    }

    /// The exec command line for a held byte stream to the daemon socket — a pane's
    /// `pane.input.stream` and a gram attachment's `gram.upload.stream`:
    /// `remote-api-bridge` forwards stdin to the daemon socket for the channel's whole
    /// life, which `api-bridge` does not.
    static func inputStreamBridgeCommand(session: String?) -> String {
        herdrCommand(["remote-api-bridge"], session: session)
    }

    /// The per-request path: one exec channel running `api-bridge <base64>`.
    static func perRequestRoundTrip(
        _ requestLine: String, session: String?, host: String, backend: ExecBackend,
        onBytesReceived: ((Int) -> Void)? = nil
    ) async throws -> String {
        let output = try await backend.execute(try bridgeCommand(for: requestLine, session: session))
        return try await parseBridgeOutput(output, host: host, onBytesReceived: onBytesReceived)
    }

    // MARK: - HerdrTransport

    /// Sends one request and returns its reply line: over the session's
    /// `api-bridge --multi` channel when the host supports it and the request fits
    /// (`RequestChannelPool`), else down the per-request path. Either way a failure
    /// surfaces as the same `TransportError`.
    public func roundTrip(_ requestLine: String) async throws -> String {
        try await roundTrip(requestLine, inSession: credentials.session)
    }

    public func roundTrip(_ requestLine: String, inSession session: String?) async throws -> String {
        let reply = try await requestChannels.send(requestLine, session: session)
        // Typing-latency diagnostics: which route this request took (held channel or exec).
        TypingLatencyRecorder.shared.noteRoute(host: credentials.host, held: reply != nil)
        if let reply { return reply }
        return try await Self.perRequestRoundTrip(
            requestLine, session: session, host: credentials.host, backend: backend)
    }

    /// `roundTrip` that reports how many reply BYTES have arrived so far.
    ///
    /// A gram download is one reply line carrying base64, so nothing about it is
    /// chunked at the protocol level — but the SSH channel still delivers it in pieces,
    /// and counting those is the only progress signal a caller can have. Used by
    /// `gramGetFile` to drive a real progress bar instead of a spinner that says
    /// nothing for twenty seconds on a 40 MB video.
    ///
    /// With a callback this ALWAYS takes the per-request path, never the shared
    /// request channel. Counting one reply's bytes on the channel would be possible,
    /// but the channel is one ordered byte stream: a 40 MB reply would stall every
    /// other request queued behind it (the poll, a keystroke) for the whole download,
    /// and would run into the channel's request timeout. On its own exec channel the
    /// download has its own SSH flow-control window and its own lifetime.
    public func roundTrip(
        _ requestLine: String, onBytesReceived: ((Int) -> Void)?
    ) async throws -> String {
        guard let onBytesReceived else { return try await roundTrip(requestLine) }
        return try await Self.perRequestRoundTrip(
            requestLine, session: credentials.session, host: credentials.host, backend: backend,
            onBytesReceived: onBytesReceived)
    }

    /// The app returned to the foreground: every held request channel pings before
    /// its next request, because the link may have died while the process was
    /// suspended (#391). Without this a dead channel is only noticed after
    /// `RequestChannelSettings.idleProbeAfter` of silence or a request timeout.
    public func markRequestChannelsSuspect() async {
        await requestChannels.markSuspect()
    }

    /// Opens `pane.input.stream` (`openLine` is its request) on its own exec channel of
    /// the shared SSH connection, in this transport's session. nil when the channel
    /// cannot start or the daemon refuses: the caller keeps `pane.send_text`.
    func openPaneInput(openLine: String) async -> PaneInputChannel? {
        let link: RequestChannelLink
        do {
            link = try await backend.openLink(Self.inputStreamBridgeCommand(session: credentials.session))
        } catch {
            return nil
        }
        let channel = PaneInputChannel(link: link, openLine: openLine)
        do {
            try await channel.start()
        } catch {
            return nil
        }
        return channel
    }

    /// The herdr sessions on this machine (`herdr session list --json`, herdr >= 0.5.3), #347.
    /// Machine-level, so it never carries `--session`. Throws when the command fails, which
    /// is what an older herdr without sessions does: callers treat that as "default only".
    public func listSessions() async throws -> [HerdrSession] {
        let command = Self.herdrCommand(["session", "list", "--json"])
        let output = try await connectedClient().executeCommandStream(command)
        var stdout = Data()
        do {
            for try await chunk in output {
                if case .stdout(let bytes) = chunk {
                    stdout.append(contentsOf: bytes.readableBytesView)
                    guard stdout.count <= 256 * 1024 else {
                        throw TransportError.machineCommandFailed(stderr: "Session list returned too much output")
                    }
                }
            }
        } catch let failure as RemoteExitError {
            throw TransportError.machineCommandFailed(stderr: "herdr session list failed (exit \(failure.remoteExitCode))")
        }
        return try HerdrSession.decodeList(stdout)
    }

    /// Run exactly one fixed machine command on the connected coordinator.
    /// Profile IDs are validated before shell interpolation; no general-purpose
    /// remote command API is exposed to callers.
    public func setMachineFederation(profileID: String, enabled: Bool) async throws {
        guard profileID.count == 32, profileID.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else {
            throw TransportError.machineCommandFailed(stderr: "Invalid saved-machine profile ID")
        }
        let command = Self.herdrCommand(["machine", enabled ? "federate" : "unfederate", profileID])
        let output = try await connectedClient().executeCommandStream(command)
        var stderr = ""
        var received = 0
        do {
            for try await chunk in output {
                switch chunk {
                case .stdout(let bytes), .stderr(let bytes):
                    received += bytes.readableBytes
                    guard received <= 64 * 1024 else {
                        throw TransportError.machineCommandFailed(stderr: "Machine command returned too much output")
                    }
                    if case .stderr = chunk {
                        stderr += String(buffer: bytes)
                    }
                }
            }
        } catch let failure as RemoteExitError {
            let reason = Self.classifyBridgeFailure(
                stderr: stderr.isEmpty ? "Machine command failed (exit \(failure.remoteExitCode))" : stderr,
                exitCode: failure.remoteExitCode,
                host: credentials.host
            )
            if case .bridgeFailed(let stderr) = reason {
                throw TransportError.machineCommandFailed(stderr: stderr)
            }
            throw reason
        }
    }

    /// Consumes the api-bridge exec output stream into its single reply line, or throws
    /// a classified `TransportError`. Extracted from `roundTrip` for ONE reason: to make
    /// the reachability of the exit-code classification testable. Citadel throws
    /// `CommandFailed` at EOF on ANY non-zero exit, so the `do/catch` MUST enclose the
    /// throwing loop or the raw "command failed, exit code N" escapes and the
    /// not-installed / incompatible guidance is never reached. `SSHClient` itself is not
    /// injectable, but a test can feed this a fake `AsyncThrowingStream` that finishes
    /// `throwing:` a `RemoteExitError`, binding that the catch is present AND scoped.
    static func parseBridgeOutput(
        _ output: AsyncThrowingStream<ExecCommandOutput, Error>, host: String,
        onBytesReceived: ((Int) -> Void)? = nil
    ) async throws -> String {
        // One request, one reply line. Accumulate RAW bytes and decode UTF-8 only at
        // newline boundaries: decoding each SSH channel-data chunk on its own
        // (String(buffer:)) turns a multi-byte scalar split across a chunk boundary into
        // U+FFFD, silently corrupting the reply.
        var lines = LineAccumulator()
        var stderr = ""
        var received = 0
        do {
            for try await chunk in output {
                switch chunk {
                case .stdout(let buffer):
                    received += buffer.readableBytes
                    onBytesReceived?(received)
                    if let first = lines.append(buffer).first {
                        if let error = daemonSocketFailure(in: first, host: host) { throw error }
                        return first
                    }
                case .stderr(let buffer):
                    stderr += String(buffer: buffer)  // diagnostic text; a lossy decode is fine here
                }
            }
        } catch let failure as RemoteExitError {
            // A non-zero remote exit: Citadel throws `CommandFailed` at EOF instead of
            // ending the stream, so this catch is the ONLY place the exit status is
            // visible — without it the raw "command failed, exit code N" escapes and the
            // not-installed / incompatible guidance is never reached. A reply may still
            // have arrived first (returned above); reaching here means it did not.
            if lines.hasRemainder {
                let line = lines.flush()
                if let error = daemonSocketFailure(in: line, host: host) { throw error }
                return line
            }
            throw classifyBridgeFailure(stderr: stderr, exitCode: failure.remoteExitCode, host: host)
        }
        // Channel closed on exit 0 without a newline-terminated reply.
        if lines.hasRemainder {
            let line = lines.flush()
            if let error = daemonSocketFailure(in: line, host: host) { throw error }
            return line
        }
        // Empty stdout: surface the bridge/remote diagnostic rather than handing
        // the caller an empty string it can only fail to decode.
        if !stderr.isEmpty {
            throw classifyBridgeFailure(stderr: stderr, exitCode: 0, host: host)
        }
        throw TransportError.closedBeforeResponse
    }

    /// Opens a long-lived stream (`events.subscribe`, `pane.stream`): the request rides
    /// as the bridge's argument, and each stdout line is yielded in order until the
    /// bridge exits or the caller stops consuming.
    ///
    /// It runs as a CHANNEL on the shared SSH connection, not on a connection of its
    /// own: a new connection cost 9–13 round trips before the stream's first byte
    /// (2.8 s of a terminal's 3.9 s first frame on 3G), and on a bad link it ran into the
    /// handshake timeout and failed. `SharedFirstLink` decides where the channel runs,
    /// and how each reason the stream once had its own connection is still met.
    ///
    /// Termination finishes the channel's stdin, which closes exactly this channel.
    public nonisolated func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let host = credentials.host
            let (stdin, stdinSink) = AsyncStream<ByteBuffer>.makeStream()
            let reader = StreamLineReader(host: host, continuation: continuation, stdinSink: stdinSink)
            let task = Task {
                do {
                    let command = try Self.bridgeCommand(for: requestLine, session: credentials.session)
                    try await backend.openStreamLink(command).run(stdin: stdin) { chunk in
                        reader.receive(chunk)
                    }
                    try reader.finish()
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let failure as RemoteExitError {
                    // Apply the same evidence-based classification as roundTrip;
                    // a bare exit 2 is not proof the command is unsupported.
                    continuation.finish(throwing: reader.failure ?? Self.classifyBridgeFailure(
                        stderr: reader.stderr, exitCode: failure.remoteExitCode, host: host))
                } catch {
                    continuation.finish(throwing: reader.failure ?? error)
                }
            }
            continuation.onTermination = { _ in
                stdinSink.finish()
                task.cancel()
            }
        }
    }

    /// Opens a streaming upload channel for one gram attachment: an SSH exec channel
    /// running `herdr remote-api-bridge`, over which `GramUploadChannel` writes the
    /// `gram.upload.stream` open line and then chunk frames. Placed like every stream
    /// (`SharedFirstLink`); `GramUploadChannel` writes in small slices so the upload
    /// cannot queue megabytes ahead of the requests sharing the connection.
    ///
    /// NOT `api-bridge --duplex`: herdr removed `api-bridge` after its upstream rebase
    /// (herdr 281341f5) and restored it WITHOUT `--duplex` (1956ea4e). Since then
    /// `api-bridge` read `--duplex` as a base64 request and exited, every stream open
    /// failed, and EVERY upload fell back to 48 KiB `gram.upload_chunk` round trips
    /// (herdrup#573).
    /// `remote-api-bridge` is older than `gram.upload.stream` itself, so every host
    /// advertising `gram_upload_stream` has it.
    ///
    /// Deliberately NOT part of `HerdrTransport`: that protocol has two members,
    /// and a third would force an implementation into all 21 conformances (18 of
    /// them test doubles) for no gain. The downcast is what makes every double
    /// take the per-chunk fallback path automatically.
    public nonisolated func openUploadChannel(_ openLine: String) -> GramUploadChannel {
        GramUploadChannel(
            link: backend.openStreamLink(Self.inputStreamBridgeCommand(session: credentials.session)),
            openLine: openLine
        )
    }

    /// Closes every request channel and the SSH connection this transport shares with
    /// every `forSession` sibling. Idempotent.
    public func close() async {
        await requestChannels.close()
        await connection.close()
    }

    /// Test-only window into the request channels.
    var requestChannelPool: RequestChannelPool { requestChannels }
}

/// How `CitadelTransport` opens its exec channels: the per-request `api-bridge <base64>`
/// exec, the held channels that carry requests (`api-bridge --multi`) and keystrokes
/// (`pane.input.stream`), and the held channels of long-lived streams.
/// Production execs on the shared `SSHConnectionCore`; tests script all three.
struct ExecBackend: Sendable {
    /// Runs `command` and streams its output; the stream throws a `RemoteExitError`
    /// on a non-zero exit.
    let execute: @Sendable (_ command: String) async throws -> AsyncThrowingStream<ExecCommandOutput, Error>
    /// The link for a held channel running `command` on the shared connection. Nothing
    /// runs until `run`.
    let openLink: @Sendable (_ command: String) async throws -> RequestChannelLink
    /// The link for a long-lived stream running `command`: a channel on the shared
    /// connection while it has room, else a connection of its own (`SharedFirstLink`).
    /// Nothing, not even the connect, happens until `run`.
    let openStreamLink: @Sendable (_ command: String) -> RequestChannelLink

    static func ssh(_ connection: SSHConnectionCore) -> ExecBackend {
        ExecBackend(
            execute: { command in
                try await connection.execute(command)
            },
            openLink: { command in
                CountedSharedLink(
                    core: connection, client: try await connection.connectedClient(), command: command)
            },
            openStreamLink: { command in
                SharedFirstLink(
                    shared: { try await connection.sharedChannel(running: command) },
                    dedicated: { try await connection.dedicatedChannel(running: command) })
            })
    }
}

/// A held channel's slot on the shared connection.
struct SharedChannelSlot: Sendable {
    let link: RequestChannelLink
    /// Gives the slot back. Called exactly once, when the channel has ended.
    let release: @Sendable () async -> Void
    /// sshd never answered the channel open: the connection is dead.
    let openTimedOut: @Sendable () async -> Void
}

/// A held channel on a connection of its own; `close` closes that connection.
struct DedicatedChannel: Sendable {
    let link: RequestChannelLink
    let close: @Sendable () async -> Void
}

/// Where a long-lived stream's channel runs: on the shared SSH connection when it has
/// room, else on a connection of its own, which is how every stream used to run.
///
/// Streams had their own connections for three reasons. Each still holds:
///
/// - **Cleanup.** Citadel's `executeCommandStream` never closes its channel, so a stream
///   closed its whole connection to end. The channel now runs under `withExec`
///   (`CitadelRequestLink`), which closes exactly that channel when the stream ends.
/// - **Failure isolation.** A channel that fails ends that channel only: the bridge
///   exiting, the daemon refusing, or sshd refusing the open never touches the
///   connection or the other streams on it. The connection is dropped only when it is
///   shown dead: a channel open sshd never answers (Citadel gives up after 15 s), which
///   is how a half-open TCP connection looks, so the next open reconnects instead of
///   every stream retrying into it.
/// - **Backpressure.** Every channel has its own flow-control window (2 MiB,
///   `SSHConnectionCore.maximumPacketSize`), and NIO keeps reading the socket however
///   slowly a consumer drains its stream, so one stalled stream cannot hold up another
///   stream's bytes or a request's reply. Uploads, the one stream that WRITES in bulk,
///   write in small slices (`GramUploadChannel.maxWriteBytes`) so a request is never
///   queued behind a whole frame.
///
/// One limit is new: sshd allows only so many channels per connection (OpenSSH's
/// `MaxSessions`, 10 by default). The shared connection carries at most
/// `SSHConnectionCore.sharedHeldChannelLimit` held channels, leaving room for
/// per-request execs; a stream past that, or one whose open sshd refuses, takes a
/// connection of its own, and a per-request exec sshd refuses waits for a channel to
/// close and retries (`SSHConnectionCore.execute`).
struct SharedFirstLink: RequestChannelLink {
    /// A slot on the shared connection, or nil when it is full (or channels cannot be
    /// closed individually on this OS). Throws when the shared connection cannot connect.
    let shared: @Sendable () async throws -> SharedChannelSlot?
    let dedicated: @Sendable () async throws -> DedicatedChannel
    /// Whether an error means sshd refused the channel open. A seam only because
    /// `NIOSSHError` cannot be constructed outside NIOSSH.
    var isRefused: @Sendable (Error) -> Bool = { SharedFirstLink.isChannelRefused($0) }

    func run(
        stdin: AsyncStream<ByteBuffer>,
        onOutput: @escaping @Sendable (ExecCommandOutput) async -> Void
    ) async throws {
        if let slot = try await shared() {
            if Task.isCancelled {
                // The stream was dropped while the connection came up: open nothing.
                await slot.release()
                throw CancellationError()
            }
            do {
                try await slot.link.run(stdin: stdin, onOutput: onOutput)
                await slot.release()
                return
            } catch where isRefused(error) {
                // The connection is at sshd's channel limit right now (per-request
                // execs count too). Nothing ran: the open itself was refused, before
                // stdin was read, so the stream opens on its own connection instead.
                await slot.release()
            } catch where Self.isOpenUnanswered(error) {
                await slot.openTimedOut()
                await slot.release()
                throw error
            } catch {
                await slot.release()
                throw error
            }
        }
        try Task.checkCancellation()
        let own = try await dedicated()
        // Cancelling a task does not interrupt an await on a NIO promise, and a channel
        // close awaits the peer's CHANNEL_CLOSE, which a dead link never sends. Closing
        // the connection fails that promise, so the stream ends on cancel regardless.
        try await withTaskCancellationHandler {
            do {
                try await own.link.run(stdin: stdin, onOutput: onOutput)
            } catch {
                await own.close()
                throw error
            }
            await own.close()
        } onCancel: {
            Task { await own.close() }
        }
    }

    /// sshd refused to open the channel (OpenSSH: `MaxSessions` reached).
    static func isChannelRefused(_ error: Error) -> Bool {
        (error as? NIOSSHError)?.type == .channelSetupRejected
    }

    /// The channel open went unanswered (Citadel's 15 s channel-create timer).
    static func isOpenUnanswered(_ error: Error) -> Bool {
        if case CitadelError.channelCreationFailed? = error as? CitadelError { return true }
        return false
    }
}

/// A held channel on the shared connection, counted against
/// `SSHConnectionCore.sharedHeldChannelLimit` for as long as it runs.
struct CountedSharedLink: RequestChannelLink, @unchecked Sendable {
    let core: SSHConnectionCore
    let client: SSHClient
    let command: String

    func run(
        stdin: AsyncStream<ByteBuffer>,
        onOutput: @escaping @Sendable (ExecCommandOutput) async -> Void
    ) async throws {
        await core.retainHeldChannel(on: client)
        do {
            try await CitadelRequestLink(client: client, command: command).run(stdin: stdin, onOutput: onOutput)
        } catch {
            await core.releaseHeldChannel(on: client)
            throw error
        }
        await core.releaseHeldChannel(on: client)
    }
}

/// A stream on a connection of its own where `withExec` is unavailable (macOS 14):
/// `executeCommandStream` cannot close its channel, so the stream ends by closing the
/// connection (`DedicatedChannel.close`). stdin is never written; finishing it ends
/// the stream, as with `CitadelRequestLink`.
struct ExecStreamLink: RequestChannelLink, @unchecked Sendable {
    let client: SSHClient
    let command: String

    func run(
        stdin: AsyncStream<ByteBuffer>,
        onOutput: @escaping @Sendable (ExecCommandOutput) async -> Void
    ) async throws {
        let output = try await client.executeCommandStream(command)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in stdin {} }
            group.addTask {
                for try await chunk in output { await onOutput(chunk) }
            }
            try await group.next()
            group.cancelAll()
        }
    }
}

/// Splits a stream's stdout into lines for `CitadelTransport.stream`, decoding UTF-8
/// only at newlines. A line reporting that the daemon socket is unreachable ends the
/// stream with that error: it is recorded, and the channel's stdin finished.
final class StreamLineReader: @unchecked Sendable {
    private let lock = NSLock()
    private let host: String
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private let stdinSink: AsyncStream<ByteBuffer>.Continuation
    private var lines = LineAccumulator()
    private var stderrText = ""
    private var failed: Error?

    init(host: String, continuation: AsyncThrowingStream<String, Error>.Continuation,
         stdinSink: AsyncStream<ByteBuffer>.Continuation) {
        self.host = host
        self.continuation = continuation
        self.stdinSink = stdinSink
    }

    var failure: Error? { lock.withLock { failed } }
    var stderr: String { lock.withLock { stderrText } }

    func receive(_ chunk: ExecCommandOutput) {
        lock.withLock {
            switch chunk {
            case .stdout(let bytes):
                for line in lines.append(bytes) { deliver(line) }
            case .stderr(let bytes):
                stderrText += String(buffer: bytes)
            }
        }
    }

    /// After the channel ended cleanly: delivers an unterminated last line, and throws
    /// a daemon failure seen on the way.
    func finish() throws {
        try lock.withLock {
            if lines.hasRemainder { deliver(lines.flush()) }
            if let failed { throw failed }
        }
    }

    private func deliver(_ line: String) {
        guard failed == nil else { return }
        if let error = CitadelTransport.daemonSocketFailure(in: line, host: host) {
            failed = error
            stdinSink.finish()
            return
        }
        continuation.yield(line)
    }
}

/// The SSH connection behind one `CitadelTransport` and its `forSession` siblings.
/// Holds no herdr session: commands carry `--session` themselves.
actor SSHConnectionCore {
    private let credentials: SSHCredentials
    private let hostKeyValidator: SSHHostKeyValidator
    private var client: SSHClient?
    /// A connect in flight, so concurrent first-use awaits one attempt (see
    /// `connectedClient`) rather than each opening — and leaking — its own session.
    private var connectTask: Task<SSHClient, Error>?
    /// Bumped by `close()`. A connect that resolves after its starting generation is
    /// STALE: close() has already torn down and believes there is no live session, so
    /// the resolved client must be reaped, never installed. This closes the residual
    /// window where a handshake completing exactly as the user disconnects would
    /// otherwise re-install a live session behind close()'s back (leak).
    private var generation = 0

    let connectTimeoutNanoseconds: UInt64

    /// Connects that failed in a row, and when the last one did. When the shared
    /// connection drops, every stream on it ends at once and each reopens with its own
    /// backoff; they all join one connect (`connectTask`), and after a FAILED connect the
    /// next one waits out `reconnectBackoff`, so a host that is down is not dialled once
    /// per stream per retry.
    private var connectFailures = 0
    private var lastConnectFailure: ContinuousClock.Instant?
    let reconnectBackoff: (initial: Duration, maximum: Duration)
    static let defaultReconnectBackoff: (initial: Duration, maximum: Duration) = (.seconds(1), .seconds(15))

    /// Held channels (streams, request channels, input channels) open on each client.
    private var heldChannels: [ObjectIdentifier: Int] = [:]
    /// How many held channels the shared connection carries before a stream takes a
    /// connection of its own. OpenSSH's `MaxSessions` defaults to 10 channels per
    /// connection; held channels take at most 6, so per-request execs (the requests
    /// sent before the request channel is up, Gram previews, session lists) keep 4.
    /// A screen holds 4–6: the request channel, the status stream, a terminal's stream
    /// and input channel, the chat stream.
    static let sharedHeldChannelLimit = 6

    init(
        credentials: SSHCredentials, hostKeyValidator: SSHHostKeyValidator, connectTimeoutNanoseconds: UInt64,
        reconnectBackoff: (initial: Duration, maximum: Duration) = SSHConnectionCore.defaultReconnectBackoff
    ) {
        self.credentials = credentials
        self.hostKeyValidator = hostKeyValidator
        self.connectTimeoutNanoseconds = connectTimeoutNanoseconds
        self.reconnectBackoff = reconnectBackoff
    }

    /// The SSH maximum packet size this client offers, which swift-nio-ssh ALSO uses
    /// as every channel's receive window (`SSHChannelMultiplexer` opens each child
    /// with `targetWindowSize: maximumPacketSize`). Its default, 128 KiB, let the
    /// host have at most 128 KiB in flight per channel and topped every download at
    /// 128 KiB per round trip — about 1 MB/s of file on a 100 ms link, whatever the
    /// bandwidth (herdrup#573). 2 MiB is OpenSSH's own channel window
    /// (`CHAN_SES_WINDOW_DEFAULT`), so a host now sends as fast as it would to `ssh`.
    /// Nothing on the wire changes: the window and packet limit are what this side
    /// advertises, and sshd sends each data packet at its own size, far below this.
    static let maximumPacketSize = 2 * 1024 * 1024

    /// Returns the held client, connecting on first use or after a drop.
    ///
    /// Concurrent first-use joins ONE connect. `SSHClient.connect` is a
    /// suspension point, and actor reentrancy lets a second caller pass the
    /// `client == nil` check while the first is still connecting; without the
    /// shared `connectTask` both would open a session and all but the last would
    /// leak (a live SSH session never closed). Callers await the same in-flight
    /// task instead.
    func connectedClient() async throws -> SSHClient {
        if let client, client.isConnected { return client }

        // Capture the generation BEFORE awaiting: if close() runs during the
        // handshake it bumps `generation`, marking whatever resolves as stale.
        let gen = generation
        let task: Task<SSHClient, Error>
        if let connectTask {
            task = connectTask                      // join the in-flight attempt
        } else {
            let wait = reconnectWait()
            let created = Task<SSHClient, Error> {
                if wait > .zero { try await Task.sleep(for: wait) }
                return try await self.makeConnection()
            }
            connectTask = created
            task = created
        }
        do {
            let connected = try await task.value
            // Validate AFTER the suspension, under actor isolation. If close() ran
            // while we awaited, this session is orphaned — close() already believes
            // there is nothing to tear down, so reap it rather than installing a live
            // client behind close()'s back. BOTH the creator and any joined waiter
            // pass through this same check.
            guard gen == generation else {
                try? await connected.close()
                throw CancellationError()
            }
            client = connected
            if connectTask == task {
                connectTask = nil
                connectFailures = 0
                lastConnectFailure = nil
            }
            return connected
        } catch {
            // Only clear the slot if it still holds OUR task — never clobber a newer
            // connect started after a close() bumped the generation.
            if connectTask == task {
                connectTask = nil
                if gen == generation {
                    connectFailures += 1
                    lastConnectFailure = .now
                }
            }
            throw error
        }
    }

    /// How long the next connect waits: nothing after a success, else a doubling delay
    /// counted from the last failure, so a caller that already waited that long (a
    /// stream's own backoff, a user's retry) pays nothing extra.
    private func reconnectWait() -> Duration {
        guard connectFailures > 0, let lastConnectFailure else { return .zero }
        var delay = reconnectBackoff.initial
        for _ in 1..<min(connectFailures, 16) {
            delay = min(delay * 2, reconnectBackoff.maximum)
        }
        let elapsed = ContinuousClock.now - lastConnectFailure
        return max(.zero, min(delay, reconnectBackoff.maximum) - elapsed)
    }

    /// Runs `command` on its own exec channel of the shared connection. When sshd
    /// refuses the channel because the connection is at its channel limit (`MaxSessions`;
    /// streams now share the connection too), waits for one to close and tries again,
    /// for up to ~3 s, rather than failing the request.
    func execute(_ command: String) async throws -> AsyncThrowingStream<ExecCommandOutput, Error> {
        var delay = Duration.milliseconds(100)
        var waited = Duration.zero
        while true {
            do {
                return try await connectedClient().executeCommandStream(command)
            } catch where SharedFirstLink.isChannelRefused(error) && waited < Self.refusedExecPatience {
                try await Task.sleep(for: delay)
                waited += delay
                delay = min(delay * 2, .milliseconds(800))
            }
        }
    }
    static let refusedExecPatience = Duration.seconds(3)

    // MARK: - held channels

    /// A slot for a long-lived stream on the shared connection, or nil when the
    /// connection already carries `sharedHeldChannelLimit` held channels, or when this
    /// OS cannot close one channel by itself (`withExec` needs macOS 15; iOS 17 always
    /// has it). Throws when the shared connection cannot connect.
    func sharedChannel(running command: String) async throws -> SharedChannelSlot? {
        guard #available(macOS 15.0, *) else { return nil }
        let client = try await connectedClient()
        let key = ObjectIdentifier(client)
        // No suspension between this check and the increment: concurrent opens cannot
        // both take the last slot.
        guard heldChannels[key, default: 0] < Self.sharedHeldChannelLimit else { return nil }
        heldChannels[key, default: 0] += 1
        return SharedChannelSlot(
            link: CitadelRequestLink(client: client, command: command),
            release: { await self.releaseHeldChannel(on: client) },
            openTimedOut: { await self.drop(client) })
    }

    /// A long-lived stream on a connection of its own, as every stream ran before.
    func dedicatedChannel(running command: String) async throws -> DedicatedChannel {
        let client = try await makeConnection()
        let link: RequestChannelLink
        if #available(macOS 15.0, *) {
            link = CitadelRequestLink(client: client, command: command)
        } else {
            link = ExecStreamLink(client: client, command: command)
        }
        return DedicatedChannel(link: link, close: { try? await client.close() })
    }

    func retainHeldChannel(on client: SSHClient) {
        heldChannels[ObjectIdentifier(client), default: 0] += 1
    }

    func releaseHeldChannel(on client: SSHClient) {
        let key = ObjectIdentifier(client)
        let remaining = heldChannels[key, default: 0] - 1
        heldChannels[key] = remaining > 0 ? remaining : nil
    }

    /// Drops `client` if it is still the shared connection: sshd did not answer a channel
    /// open, so the TCP connection is dead (half-open) even though it still looks
    /// connected. Its channels end, and the next caller reconnects. A connection already
    /// replaced is left alone.
    func drop(_ client: SSHClient) async {
        guard let current = self.client, current === client else { return }
        self.client = nil
        try? await client.close()
    }

    /// Held channels open on the shared connection now. Test-only.
    var sharedHeldChannelCount: Int {
        guard let client else { return 0 }
        return heldChannels[ObjectIdentifier(client), default: 0]
    }

    func makeConnection() async throws -> SSHClient {
        let method: SSHAuthenticationMethod
        switch credentials.auth {
        case .privateKey(let pem, let passphrase):
            let privateKey = try Curve25519.Signing.PrivateKey(
                sshEd25519: Data(pem.utf8),
                decryptionKey: passphrase.map { Data($0.utf8) }
            )
            method = .ed25519(username: credentials.username, privateKey: privateKey)
        case .password(let password):
            method = .passwordBased(username: credentials.username, password: password)
        }
        // A client that resolves after a concurrent close() is reaped by the
        // generation check in connectedClient() (the only publisher of `self.client`),
        // so no cancellation handling is needed here.
        // RACE THE HANDSHAKE AGAINST A CLOCK. Without this an unroutable address —
        // a Tailscale host reached from a device that is not on the tailnet — hangs
        // at the TCP layer until the OS gives up (~75s on iOS). That is not
        // experienced as a failure; it is experienced as an endless spinner, with
        // nothing on screen to act on. A budget converts silence into an error the
        // UI can show.
        //
        // NOT a task group, and the reason is measured: a group awaits its children
        // at scope exit, and `SSHClient.connect` does not observe cancellation
        // promptly — so a group-based race returned only when the LOSING connect
        // finally gave up on its own (30s against a 0.3s budget, caught by
        // `testConnectFailsWithinTheBudgetAgainstABlackHoleAddress`). The winner
        // must be able to return while the loser unwinds unobserved.
        let host = credentials.host
        let budget = connectTimeoutNanoseconds
        var settings = SSHClientSettings(
            host: host, port: Int(credentials.port),
            authenticationMethod: { method }, hostKeyValidator: hostKeyValidator)
        settings.protocolOptions = [.maximumPacketSize(SSHConnectionCore.maximumPacketSize)]
        // ONE budget: the race below. Citadel's own timers (the TCP connect, and the
        // handshake + auth timer that upstream fixes at 10 s) are set past it so they
        // never cut a slow handshake short of the budget the app chose.
        let citadelLimit = TimeAmount.nanoseconds(Int64(clamping: budget).addingReportingOverflow(1_000_000_000).overflow
            ? .max : Int64(clamping: budget) + 1_000_000_000)
        settings.connectTimeout = citadelLimit
        settings.loginTimeout = citadelLimit
        let work = Task<SSHClient, Error> {
            try await SSHClient.connect(to: settings)
        }
        do {
            return try await withCheckedThrowingContinuation { continuation in
                // Exactly one of the two branches may resume the continuation;
                // resuming twice is undefined behaviour, not a recoverable error.
                let settled = FirstPastThePost()
                Task {
                    do {
                        let client = try await work.value
                        if settled.claim() {
                            continuation.resume(returning: client)
                        } else {
                            // The clock already won and the caller has its error.
                            // Close this rather than leaking a live session nobody
                            // holds a reference to.
                            try? await client.close()
                        }
                    } catch {
                        if settled.claim() { continuation.resume(throwing: error) }
                    }
                }
                Task {
                    try? await Task.sleep(nanoseconds: budget)
                    guard settled.claim() else { return }
                    work.cancel()
                    continuation.resume(throwing: TransportError.connectTimedOut(
                        host: host,
                        // credentials.host is already the bare host (the port is a
                        // separate field), so classify it directly rather than
                        // re-parsing a string that was never joined.
                        onTailnet: HostEndpoint(host: host, port: 22).isTailnetAddress
                    ))
                }
            }
        } catch SSHClientError.unsupportedPasswordAuthentication {
            // The server offers no password auth (e.g. `PasswordAuthentication no`).
            throw TransportError.passwordAuthUnsupported(host: credentials.host)
        } catch SSHClientError.allAuthenticationOptionsFailed {
            // Wrong password / rejected key. Host-key rejection is thrown by the
            // validator, not caught here, so it keeps its dedicated recovery path.
            throw TransportError.authenticationFailed(host: credentials.host)
        }
    }

    /// Closes the held SSH connection. Idempotent.
    public func close() async {
        // Invalidate any in-flight connect so a handshake that resolves after this
        // point is reaped by connectedClient() rather than installed post-close.
        generation &+= 1
        connectTask?.cancel()
        connectTask = nil
        // Snapshot and CLEAR the slot BEFORE awaiting teardown. Awaiting the old
        // client's close is a suspension point, and actor reentrancy lets a NEW
        // generation connect install a fresh client during it (a legitimate
        // reconnect). A trailing unconditional `client = nil` would then discard that
        // live session unclosed. Nil-before-await confines this teardown to the OLD
        // client and never clobbers a reconnect that lands mid-close.
        let old = client
        client = nil
        try? await old?.close()
    }
}

/// Accumulates raw stdout bytes and yields complete newline-delimited lines,
/// decoding UTF-8 only at line boundaries.
///
/// Decoding each SSH channel-data chunk independently (`String(buffer:)`) would
/// corrupt any multi-byte UTF-8 scalar split across a chunk boundary: the
/// incomplete tail becomes U+FFFD and its bytes are consumed, so concatenating
/// the decoded chunks can never reconstitute the character. A `\n` byte (0x0A)
/// can never fall inside a multi-byte UTF-8 sequence, so decoding only at
/// newlines keeps every line intact.
struct LineAccumulator {
    private var bytes: [UInt8] = []

    /// Appends a chunk and returns the lines it completed (newline stripped).
    mutating func append(_ buffer: ByteBuffer) -> [String] {
        append(bytes: buffer.readableBytesView)
    }

    mutating func append(_ data: Data) -> [String] {
        append(bytes: data)
    }

    private mutating func append<Chunk: Sequence>(bytes chunk: Chunk) -> [String] where Chunk.Element == UInt8 {
        bytes.append(contentsOf: chunk)
        var lines: [String] = []
        while let newline = bytes.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(String(decoding: bytes[..<newline], as: UTF8.self))
            bytes.removeSubrange(...newline)
        }
        return lines
    }

    /// Bytes remain after the last newline (an unterminated final line).
    var hasRemainder: Bool { !bytes.isEmpty }

    /// Decodes and clears whatever is left after the last newline.
    mutating func flush() -> String {
        defer { bytes.removeAll() }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// A remote command's non-zero exit, abstracted so `parseBridgeOutput`'s classification
/// path is unit-testable. A test cannot construct Citadel's `SSHClient.CommandFailed`
/// (its memberwise initialiser is internal to that module), so `parseBridgeOutput`
/// catches THIS protocol instead of the concrete type; the test injects its own
/// conforming error through a fake stream. Citadel's error conforms below.
protocol RemoteExitError: Error {
    var remoteExitCode: Int { get }
}

extension SSHClient.CommandFailed: RemoteExitError {
    var remoteExitCode: Int { exitCode }
}
