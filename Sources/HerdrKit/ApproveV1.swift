import Crypto
import Foundation

/// Browser approval, protocol `approve-v1` (web owner access WIRE-PLAN §2.2, §2.3): a browser B
/// asks a trusted device T to let it reach the owner's machines. Each side commits before it
/// learns the other's randomness, and both show a 4-digit code over both keys, which the user
/// types on T. T then sends the machine list to B sealed between the two verified keys, so the
/// account service can neither swap a key nor a machine's `node_pub`.
///
///     commit = SHA-256("herdrup-approve-v1|commit" ‖ 0x00 ‖ B ‖ nonce_b)
///     h      = SHA-256("herdrup-approve-v1|sas" ‖ 0x00 ‖ B ‖ T ‖ nonce_b ‖ nonce_t)
///     code   = uint32_be(h[0..4]) mod 10000, 4 digits, zero-padded
///     ikm    = X25519(t, B)                        (all zero → refused)
///     k      = HKDF-SHA256(ikm, salt = B ‖ T, info = "herdrup-approve-v1|envelope", 32)
///     aad    = "herdrup-approve-v1|envelope" ‖ 0x00 ‖ B ‖ T ‖ uint64_be(seq)
///     sealed = b64url(iv(12) ‖ AES-256-GCM(k, iv, aad, json))
///
/// Every binary field is unpadded base64url. AccountService/test/vectors/approve-v1.json pins
/// it for every client (HerdrUp Desktop's `internal/account/approve.go` is the other one).
public enum ApproveV1 {
    static let commitLabel = "herdrup-approve-v1|commit"
    static let codeLabel = "herdrup-approve-v1|sas"
    static let envelopeLabel = "herdrup-approve-v1|envelope"
    public static let keySize = 32
    public static let nonceSize = 32

    /// The longest sealed envelope the account service takes (approvals.ts `MAX_SEALED_LENGTH`).
    public static let maxSealedLength = 16 * 1024

    public enum Failure: Error, Equatable, Sendable {
        /// A key or nonce of the wrong length.
        case badSize
        /// A reveal that doesn't open the commit T saw before it sent `nonce_t`, or a request
        /// whose browser key or commit can't be read: the request must be denied, never approved.
        case tampered
        /// The browser key is a low-order point: the shared secret would be all zero.
        case invalidKey
        /// A sealed envelope that isn't base64url of an IV, ciphertext and tag, or doesn't open.
        case malformedEnvelope
    }

    /// A fresh 32-byte nonce; never reuse one.
    public static func newNonce() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// The browser's commitment to `nonceB` for its key `browserPub`.
    public static func commit(browserPub: Data, nonceB: Data) throws -> Data {
        try checkSizes(keys: [browserPub], nonces: [nonceB])
        return labelled(commitLabel, [browserPub, nonceB])
    }

    /// Checks that `nonceB` opens `commit` for `browserPub`, the key and commit T was shown
    /// before it sent `nonce_t`. A mismatch is `.tampered`.
    public static func open(browserPub: Data, commit: Data, nonceB: Data) throws {
        let want = try Self.commit(browserPub: browserPub, nonceB: nonceB)
        guard commit.count == SHA256.byteCount, constantTimeEqual(want, commit) else { throw Failure.tampered }
    }

    /// The 4 digits both sides show: the browser displays it and the user types it here.
    public static func code(browserPub: Data, approverPub: Data, nonceB: Data, nonceT: Data) throws -> String {
        try checkSizes(keys: [browserPub, approverPub], nonces: [nonceB, nonceT])
        let h = labelled(codeLabel, [browserPub, approverPub, nonceB, nonceT])
        let value = h.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 10000
        let digits = String(value)
        return String(repeating: "0", count: 4 - digits.count) + digits
    }

    /// Compares a typed code with the computed one in constant time.
    public static func codeMatches(_ typed: String, _ code: String) -> Bool {
        typed.utf8.count == 4 && constantTimeEqual(Data(typed.utf8), Data(code.utf8))
    }

    /// Seals `plaintext` (the envelope JSON) from `approver` to the browser with key
    /// `browserPub`, at sequence `seq`. `iv` is for the vectors; leave it nil.
    public static func seal(approver: Curve25519.KeyAgreement.PrivateKey, browserPub: Data, seq: UInt64,
                            plaintext: Data, iv: Data? = nil) throws -> String {
        try seal(label: envelopeLabel, approver: approver, requesterPub: browserPub, seq: seq, plaintext: plaintext, iv: iv)
    }

    /// Opens `sealed` as the browser (holding `b`) from `approverPub` at `seq`. The browser side
    /// is TypeScript; this is for tests.
    public static func openEnvelope(browser: Curve25519.KeyAgreement.PrivateKey, approverPub: Data, seq: UInt64,
                                    sealed: String) throws -> Data {
        try open(label: envelopeLabel, requester: browser, approverPub: approverPub, seq: seq, sealed: sealed)
    }

    /// The §12.3 envelope under `label`: approve-v1's, or pair-v1's (`PairV1`), which also binds
    /// `bound` (S and the request id) in the AAD before the seq. The requester's key comes first
    /// in the salt and the AAD.
    static func seal(label: String, approver: Curve25519.KeyAgreement.PrivateKey, requesterPub: Data, seq: UInt64,
                     bound: Data = Data(), plaintext: Data, iv: Data?) throws -> String {
        let approverPub = approver.publicKey.rawRepresentation
        let key = try envelopeKey(label: label, privateKey: approver, peerPub: requesterPub,
                                  browserPub: requesterPub, approverPub: approverPub)
        let nonce = try iv.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
        let aad = aad(label: label, browserPub: requesterPub, approverPub: approverPub, bound: bound, seq: seq)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        return Base64URL.encode(Data(nonce) + box.ciphertext + box.tag)
    }

    static func open(label: String, requester: Curve25519.KeyAgreement.PrivateKey, approverPub: Data, seq: UInt64,
                     bound: Data = Data(), sealed: String) throws -> Data {
        let requesterPub = requester.publicKey.rawRepresentation
        let key = try envelopeKey(label: label, privateKey: requester, peerPub: approverPub,
                                  browserPub: requesterPub, approverPub: approverPub)
        guard let raw = Base64URL.decode(sealed), raw.count >= 12 + 16 else { throw Failure.malformedEnvelope }
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: raw.prefix(12)),
                                            ciphertext: raw.dropFirst(12).dropLast(16), tag: raw.suffix(16))
            return try AES.GCM.open(box, using: key,
                                    authenticating: aad(label: label, browserPub: requesterPub, approverPub: approverPub,
                                                        bound: bound, seq: seq))
        } catch {
            throw Failure.malformedEnvelope
        }
    }

    /// The length of `seal`'s result for an `n`-byte plaintext: base64url of the AES-GCM nonce,
    /// ciphertext and tag.
    public static func sealedLength(_ n: Int) -> Int {
        let bytes = 12 + n + 16
        return (bytes * 8 + 5) / 6
    }

    // MARK: Internals

    static func labelled(_ label: String, _ parts: [Data]) -> Data {
        var hash = SHA256()
        hash.update(data: Data(label.utf8) + [0])
        for part in parts { hash.update(data: part) }
        return Data(hash.finalize())
    }

    static func checkSizes(keys: [Data], nonces: [Data]) throws {
        guard keys.allSatisfy({ $0.count == keySize }), nonces.allSatisfy({ $0.count == nonceSize }) else {
            throw Failure.badSize
        }
    }

    private static func envelopeKey(label: String, privateKey: Curve25519.KeyAgreement.PrivateKey, peerPub: Data,
                                    browserPub: Data, approverPub: Data) throws -> SymmetricKey {
        try checkSizes(keys: [peerPub, browserPub, approverPub], nonces: [])
        let ikm: Data
        do {
            ikm = try DeviceEnroller.sharedSecret(privateKey: privateKey, publicKey: peerPub)
        } catch {
            throw Failure.invalidKey
        }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: browserPub + approverPub,
                                      info: Data(label.utf8), outputByteCount: 32)
    }

    private static func aad(label: String, browserPub: Data, approverPub: Data, bound: Data, seq: UInt64) -> Data {
        var aad = Data(label.utf8) + [0] + browserPub + approverPub + bound
        withUnsafeBytes(of: seq.bigEndian) { aad.append(contentsOf: $0) }
        return aad
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}
