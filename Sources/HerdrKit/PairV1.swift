import Crypto
import Foundation

/// Pairing a new device from one already paired, protocol `pair-v1` (pair-from-device PLAN,
/// AccountService DESIGN §13): approve-v1 generalised to a native requester. The new device N
/// (X25519 device key B) makes an ed25519 SSH key S for the request and commits to it; an
/// approver A (key T) claims, N reveals, and both show a 4-digit code over B, S and T that the
/// user types on A. A then adds S to the machines it ticks and seals their addresses and pinned
/// host keys to N.
///
///     commit = SHA-256("herdrup-pair-v1|commit" ‖ 0x00 ‖ B ‖ S ‖ nonce_b)
///     h      = SHA-256("herdrup-pair-v1|sas"    ‖ 0x00 ‖ B ‖ S ‖ T ‖ nonce_b ‖ nonce_t)
///     code   = uint32_be(h[0..4]) mod 10000, 4 digits, zero-padded
///     sealed = approve-v1's envelope (§12.3) under "herdrup-pair-v1|envelope"
///
/// S is the raw 32-byte ed25519 public key. It is bound in both hashes, so the service can't
/// swap the key the approver adds. AccountService/test/vectors/pair-v1.json pins it.
public enum PairV1 {
    static let commitLabel = "herdrup-pair-v1|commit"
    static let codeLabel = "herdrup-pair-v1|sas"
    static let envelopeLabel = "herdrup-pair-v1|envelope"

    /// N's commitment to `nonceB` for its device key `requesterPub` and SSH key `sshPub`.
    public static func commit(requesterPub: Data, sshPub: Data, nonceB: Data) throws -> Data {
        try ApproveV1.checkSizes(keys: [requesterPub, sshPub], nonces: [nonceB])
        return ApproveV1.labelled(commitLabel, [requesterPub, sshPub, nonceB])
    }

    /// Checks that `nonceB` opens `commit` for the keys the approver was shown before it sent
    /// `nonce_t`. A mismatch is `.tampered`.
    public static func open(requesterPub: Data, sshPub: Data, commit: Data, nonceB: Data) throws {
        let want = try Self.commit(requesterPub: requesterPub, sshPub: sshPub, nonceB: nonceB)
        guard commit.count == SHA256.byteCount, ApproveV1.constantTimeEqual(want, commit) else {
            throw ApproveV1.Failure.tampered
        }
    }

    /// The 4 digits both sides show: N displays it and the user types it on the approver.
    public static func code(requesterPub: Data, sshPub: Data, approverPub: Data, nonceB: Data, nonceT: Data) throws -> String {
        try ApproveV1.checkSizes(keys: [requesterPub, sshPub, approverPub], nonces: [nonceB, nonceT])
        let h = ApproveV1.labelled(codeLabel, [requesterPub, sshPub, approverPub, nonceB, nonceT])
        let value = h.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 10000
        let digits = String(value)
        return String(repeating: "0", count: 4 - digits.count) + digits
    }

    /// Seals the envelope JSON from `approver` to N (`requesterPub`) at `seq`. `iv` is for the
    /// vectors; leave it nil.
    public static func seal(approver: Curve25519.KeyAgreement.PrivateKey, requesterPub: Data, seq: UInt64,
                            plaintext: Data, iv: Data? = nil) throws -> String {
        try ApproveV1.seal(label: envelopeLabel, approver: approver, requesterPub: requesterPub, seq: seq,
                           plaintext: plaintext, iv: iv)
    }

    /// Opens an envelope as N (holding `b`) from `approverPub` at `seq`.
    public static func openEnvelope(requester: Curve25519.KeyAgreement.PrivateKey, approverPub: Data, seq: UInt64,
                                    sealed: String) throws -> Data {
        try ApproveV1.open(label: envelopeLabel, requester: requester, approverPub: approverPub, seq: seq, sealed: sealed)
    }
}

/// What the approver seals to the new device (PLAN "Envelope JSON", at most 16 KB sealed): the
/// machines it ticked, each with the host key it pins and what adding S did there.
public struct PairEnvelope: Codable, Equatable, Sendable {
    public struct Machine: Codable, Equatable, Sendable {
        public enum Status: String, Codable, Sendable {
            case added, already, failed
        }

        public let nickname: String
        public let host: String
        public let port: Int
        public let user: String
        /// The approver's pinned host key, one OpenSSH line ("ssh-ed25519 AAAA…").
        public let hostKey: String
        public let status: Status
        public let reason: String?

        public init(nickname: String, host: String, port: Int, user: String, hostKey: String,
                    status: Status, reason: String? = nil) {
            self.nickname = nickname
            self.host = host
            self.port = port
            self.user = user
            self.hostKey = hostKey
            self.status = status
            self.reason = reason
        }

        /// The key S is on the machine: added now, or already there.
        public var hasKey: Bool { status != .failed }

        enum CodingKeys: String, CodingKey {
            case nickname, host, port, user, status, reason
            case hostKey = "host_key"
        }
    }

    public let v: Int
    public let machines: [Machine]

    public init(machines: [Machine]) {
        v = 1
        self.machines = machines
    }

    /// The JSON the approver seals (stable key order, no escaped slashes).
    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Reads an opened envelope. Anything but version 1 is refused.
    public static func parse(_ data: Data) throws -> PairEnvelope {
        let envelope = try JSONDecoder().decode(PairEnvelope.self, from: data)
        guard envelope.v == 1 else { throw ApproveV1.Failure.malformedEnvelope }
        return envelope
    }
}
