import Foundation
import NIOSSH
import NIOCore
import Crypto

// Host-key pinning, transport-independent.
//
// This lived in SSHTransport.swift while libssh2 was the only transport, but the
// pinning policy is not a libssh2 mechanic — it is the trust decision the whole
// client depends on. It moved here so it survives the libssh2 removal, and so
// the pure-Swift transport can share exactly the same policy rather than
// reimplement TOFU against Citadel's validator.

/// What the caller decides when a host key is seen.
public enum HostKeyDecision: Sendable, Equatable {
    /// Accept and remember this fingerprint.
    case trust
    /// Refuse the connection.
    case reject
}

/// Consulted on every connect. A changed key is never silently accepted: the
/// policy compares and pins as one operation, and a change is refused.
public protocol HostKeyPolicy: Sendable {
    /// Decide, compare and pin as ONE operation.
    ///
    /// A split lookup-then-callback interface is a TOFU race: two concurrent
    /// first connections can both observe no pin, trust different keys, and
    /// overwrite each other — silently violating hard-stop-on-change at exactly
    /// the moment pinning is supposed to establish trust. Keyed by host AND
    /// port, since two hosts can share a name on different ports.
    func evaluate(host: String, port: UInt16, presented: String) -> HostKeyDecision
}

/// Pins on first contact and hard-stops on change.
public struct PinningHostKeyPolicy: HostKeyPolicy {
    private let store: PinStore

    /// Defaults to the PROCESS-WIDE `.shared` store, so a default-constructed
    /// policy — and thus `CitadelTransport`'s default — shares one pin set rather
    /// than each transport trusting first contact independently. Pass an explicit
    /// `PinStore()` for an isolated store (tests do this).
    public init(store: PinStore = .shared) {
        self.store = store
    }

    /// Compare-and-pin under a single lock, so concurrent first contacts cannot
    /// both win. A key that differs from the pin is always refused: a changed
    /// host key is indistinguishable from interception, and this transport
    /// carries an operator's whole fleet.
    public func evaluate(host: String, port: UInt16, presented: String) -> HostKeyDecision {
        store.compareAndPin(key: "\(host):\(port)", presented: presented)
    }

    public func pinnedFingerprint(for host: String, port: UInt16 = 22) -> String? {
        store.pinned(key: "\(host):\(port)")
    }

    /// In-memory pin store, process-lifetime only.
    ///
    /// A fresh `PinStore()` per transport would let a transport recreated after
    /// an app restart trust a substituted key as first contact, so the default
    /// policy uses the process-wide `.shared` store (all default transports in a
    /// process share pins).
    ///
    /// This type is IN-MEMORY ONLY and is NOT a persistence seam — it is a
    /// concrete final class with no storage backend to override, so it cannot be
    /// made Keychain-backed. Cross-LAUNCH TOFU is achieved instead by supplying a
    /// custom `HostKeyPolicy` (the one-method protocol `CitadelTransport(...,
    /// hostKeyPolicy:)` accepts) that compares-and-pins against persistent
    /// storage such as the Keychain. Keeping no platform storage here is what
    /// lets the type build on Linux.
    public final class PinStore: @unchecked Sendable {
        private let lock = NSLock()
        private var pins: [String: String] = [:]

        /// Process-wide store backing the default pinning policy, so two
        /// transports created with the default initializer enforce one pin set
        /// rather than each trusting first contact independently.
        public static let shared = PinStore()

        public init() {}

        /// Read-only inspection, for tests and diagnostics.
        public func pinned(key: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return pins[key]
        }

        /// Seeds a pin. Expressed through the same atomic primitive so there is
        /// no separate write path to misuse.
        @discardableResult
        public func pin(host: String, port: UInt16 = 22, fingerprint: String) -> HostKeyDecision {
            compareAndPin(key: "\(host):\(port)", presented: fingerprint)
        }

        /// THE ONLY WRITE PATH. Structural, not merely careful: with no separate
        /// lookup-then-store API, the racy split form cannot be written at all.
        /// A concurrency test can only ever sample a race — the reviewer showed
        /// the previous one let the split form survive 492 times in 500 — so the
        /// guarantee has to come from the shape of the interface, not from a
        /// test that hopes to catch it.
        func compareAndPin(key: String, presented: String) -> HostKeyDecision {
            lock.lock(); defer { lock.unlock() }
            if let existing = pins[key] {
                return existing == presented ? .trust : .reject
            }
            pins[key] = presented
            return .trust
        }
    }
}

// MARK: - Citadel / nio-ssh bridge

/// SHA256 fingerprint of a host key's SSH wire format, hex-encoded.
///
/// Stable across connections to the same unchanged host and collision-resistant
/// — the two properties a pin needs. Computed over the same wire encoding
/// `NIOSSHPublicKey.write(to:)` produces (the "ssh-ed25519"/etc. type tag plus
/// the key material), so two distinct keys cannot collapse to one pin, and a
/// key type change registers as a change too.
public func sshHostKeyFingerprintSHA256(_ key: NIOSSHPublicKey) -> String {
    var buffer = ByteBuffer()
    key.write(to: &buffer)
    let digest = SHA256.hash(data: Data(buffer.readableBytesView))
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// Bridges a `HostKeyPolicy` to Citadel/nio-ssh's host-key validation, so the
/// pure-Swift transport pins exactly the way the libssh2 one did.
///
/// nio-ssh hands the presented `NIOSSHPublicKey` to this delegate, which must
/// succeed or fail a promise. It computes the pin fingerprint, asks the policy
/// (which compares-and-pins atomically), and FAILS the promise on rejection —
/// stopping the handshake before any authentication or command runs, so a
/// changed or unknown host key never sees the private key or a request.
///
/// One instance per target: nio-ssh's delegate is handed only the key, never the
/// endpoint, so the host/port the pin is keyed by must be captured here.
public final class PinningHostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    private let host: String
    private let port: UInt16
    private let policy: HostKeyPolicy

    public init(host: String, port: UInt16, policy: HostKeyPolicy) {
        self.host = host
        self.port = port
        self.policy = policy
    }

    public func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fingerprint = sshHostKeyFingerprintSHA256(hostKey)
        switch policy.evaluate(host: host, port: port, presented: fingerprint) {
        case .trust:
            (policy as? HostKeyRecorder)?.record(String(openSSHPublicKey: hostKey))
            validationCompletePromise.succeed(())
        case .reject:
            validationCompletePromise.fail(TransportError.hostKeyRejected(host: host, fingerprint: fingerprint))
        }
    }
}

/// A `HostKeyPolicy` that decides exactly as `base` does and keeps the key it trusted, as one
/// OpenSSH line ("ssh-ed25519 AAAA…"). An approver pairing another device sends that line
/// with each machine, so the new device pins the very key this one checked.
public final class HostKeyRecorder: HostKeyPolicy, @unchecked Sendable {
    private let base: HostKeyPolicy
    private let lock = NSLock()
    private var line: String?

    public init(_ base: HostKeyPolicy) {
        self.base = base
    }

    public func evaluate(host: String, port: UInt16, presented: String) -> HostKeyDecision {
        base.evaluate(host: host, port: port, presented: presented)
    }

    /// The host key of the last connection `base` trusted, or nil before one.
    public var trustedKey: String? { lock.withLock { line } }

    func record(_ openSSHLine: String) {
        lock.withLock { line = openSSHLine }
    }

    /// The pin `base` keeps for an OpenSSH host key line (`sshHostKeyFingerprintSHA256`), or
    /// nil for a line that isn't one. A host certificate pins the key it certifies: this app
    /// never negotiates certificate host-key algorithms, so the host shows it that plain key.
    public static func fingerprint(ofOpenSSHKey line: String) -> String? {
        plainKey(line).map(sshHostKeyFingerprintSHA256)
    }

    /// The host-key algorithm of the key `fingerprint(ofOpenSSHKey:)` pins ("ssh-ed25519",
    /// "ecdsa-sha2-nistp256"; a certificate's certified key), or nil for a line that isn't one.
    /// A paired machine offers only this one (`SSHCredentials.hostKeyAlgorithm`).
    public static func algorithm(ofOpenSSHKey line: String) -> String? {
        plainKey(line).flatMap { String(openSSHPublicKey: $0).split(separator: " ").first.map(String.init) }
    }

    private static func plainKey(_ line: String) -> NIOSSHPublicKey? {
        guard let key = try? NIOSSHPublicKey(openSSHPublicKey: line.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return NIOSSHCertifiedPublicKey(key)?.key ?? key
    }
}
