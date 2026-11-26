import Foundation
import Citadel
import Crypto
import NIOCore

/// The keypair a phone generates for itself during QR pairing.
///
/// THE PRIVATE HALF NEVER LEAVES THE DEVICE. Pairing sends only `authorizedKeysLine`
/// to the machine, which appends it to `~/.ssh/authorized_keys`; the private key goes
/// straight into the Keychain via `SavedHostsStore.add`. Nothing secret is ever in the
/// QR code, on the wire, or in a log — the QR carries a single-use token, and the token
/// is worthless once redeemed.
///
/// This exists because the app had NO way to make a key. `HostEditor` asks the user to
/// paste an ed25519 PEM from the clipboard, which means generating one on a computer
/// first — the exact step that blocked a new user at the first screen.
public struct PairingKey: Sendable {
    /// OpenSSH-format private key ("-----BEGIN OPENSSH PRIVATE KEY-----"), the shape
    /// `SavedHostsStore` stores and `CitadelTransport` parses back.
    public let privateKeyPEM: String
    /// One `authorized_keys` line: `ssh-ed25519 <base64> <comment>`.
    public let authorizedKeysLine: String
    /// The SHA256 fingerprint of the PUBLIC key, in OpenSSH's display form
    /// (`SHA256:<base64 without padding>`), for showing the user which key was added.
    public let publicKeyFingerprint: String
    /// The raw 32-byte ed25519 public key (pair-v1's S).
    public let publicKey: Data

    /// Generate a fresh keypair. The comment lands in both the private key and the
    /// `authorized_keys` line, so a person reading either can tell where it came from
    /// and revoke it without guessing.
    public init(comment: String) {
        let key = Curve25519.Signing.PrivateKey()
        self.init(key: key, comment: comment)
    }

    /// Testable seam: build from a supplied key so a round-trip test can compare against
    /// a known input rather than only against itself.
    public init(key: Curve25519.Signing.PrivateKey, comment: String) {
        // Citadel already writes the OpenSSH container (cipher `none`, kdf `none`,
        // duplicated checksum, 8-byte block padding). Hand-rolling that encoding would
        // be the riskiest part of pairing for no gain — and getting the padding subtly
        // wrong fails at authentication time, on someone else's machine.
        self.privateKeyPEM = key.makeSSHRepresentation(comment: comment)
        self.authorizedKeysLine = Self.authorizedKeysLine(for: key.publicKey, comment: comment)
        self.publicKeyFingerprint = Self.fingerprint(for: key.publicKey)
        self.publicKey = key.publicKey.rawRepresentation
    }

    /// `ssh-ed25519 <base64 blob>` for a raw 32-byte ed25519 key, with no comment: what
    /// `pair.add_key` takes. Nil for a key that isn't 32 bytes.
    public static func publicKeyLine(raw: Data) -> String? {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return nil }
        return authorizedKeysLine(for: key, comment: "")
    }

    /// The wire encoding of an ed25519 public key: `string "ssh-ed25519"` followed by
    /// `string <32 raw bytes>`, each length-prefixed with a big-endian UInt32. This is
    /// the same blob that goes in `authorized_keys` and that the fingerprint hashes.
    static func publicKeyBlob(_ publicKey: Curve25519.Signing.PublicKey) -> Data {
        var out = Data()
        func writeString(_ bytes: Data) {
            var len = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(bytes)
        }
        writeString(Data("ssh-ed25519".utf8))
        writeString(publicKey.rawRepresentation)
        return out
    }

    static func authorizedKeysLine(for publicKey: Curve25519.Signing.PublicKey,
                                   comment: String) -> String {
        let b64 = publicKeyBlob(publicKey).base64EncodedString()
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "ssh-ed25519 \(b64)" : "ssh-ed25519 \(b64) \(trimmed)"
    }

    /// OpenSSH prints fingerprints as unpadded base64 of the SHA256 over the key blob —
    /// matching `ssh-keygen -lf`, so what the app shows and what the machine prints are
    /// the same string.
    static func fingerprint(for publicKey: Curve25519.Signing.PublicKey) -> String {
        let digest = SHA256.hash(data: publicKeyBlob(publicKey))
        let b64 = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return "SHA256:\(b64)"
    }
}
