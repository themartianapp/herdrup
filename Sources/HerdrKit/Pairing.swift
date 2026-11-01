import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// The phone's half of QR pairing: read the code, redeem it, get connected.
///
/// The flow this completes: `herdr pair` on the machine prints a QR carrying a single-use
/// token and the machine's SSH host-key fingerprint. The phone scans it, generates its own
/// keypair (`PairingKey`), and sends only the PUBLIC half here. The machine appends that to
/// `~/.ssh/authorized_keys`, and from then on the phone authenticates like any other host
/// entry.
///
/// WHAT PROTECTS THIS EXCHANGE. It is a plaintext line-oriented protocol, deliberately:
/// `herdr pair` binds to the machine's Tailscale address, so the bytes travel inside
/// WireGuard, and the listener is not reachable from the internet at all. The token is
/// single-use and short-lived, so a photograph of the QR is worthless once redeemed. The
/// only secret the phone ever holds — its private key — is never sent.
public enum Pairing {}

// MARK: - The payload carried by the QR

extension Pairing {
    /// The QR's contents. Field names are the wire contract with `PairingPayload` in
    /// herdr's `src/pairing.rs`; renaming one here silently breaks pairing against a
    /// released daemon, so they are short and fixed.
    public struct Payload: Codable, Sendable, Equatable {
        /// Format version. Present so an old app meets a new daemon with a real error
        /// rather than a misparse.
        public let v: Int
        /// The address to connect to — the machine's tailnet IP.
        public let host: String
        public let port: Int
        /// The SSH user to log in as.
        public let user: String
        /// Single-use pairing token.
        public let token: String
        /// The machine's SSH host-key fingerprint as `ssh-keygen -lf` prints it: `SHA256:`
        /// followed by the unpadded base64 of the 32-byte digest.
        ///
        /// EMPTY MEANS UNKNOWN, not "no pinning needed". The daemon sends an empty string
        /// when it could not read its own host key; `hostKeyFingerprint` is then `nil`, so an
        /// empty string never flows into a pin call.
        public let fp: String

        public init(v: Int, host: String, port: Int, user: String, token: String, fp: String) {
            self.v = v
            self.host = host
            self.port = port
            self.user = user
            self.token = token
            self.fp = fp
        }

        /// The host-key digest in the form the SSH verifier presents
        /// (`sshHostKeyFingerprintSHA256`): 64 lowercase hex characters.
        ///
        /// The QR and the verifier encode the same SHA-256 of the wire-form key differently.
        /// Pinning the QR text verbatim would reject the first connection to an unchanged
        /// host, so the digest is decoded here and re-encoded once, in the verifier's form.
        /// `nil` when the machine could not report its host key, or when `fp` is not a
        /// canonical 32-byte `SHA256:` digest — the caller must not pin either way.
        public var hostKeyFingerprint: String? {
            let trimmed = fp.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "SHA256:"
            guard trimmed.hasPrefix(prefix) else { return nil }
            let encoded = String(trimmed.dropFirst(prefix.count))
            // 32 bytes is 43 unpadded base64 characters. Re-encoding must reproduce the
            // input, so stray trailing bits cannot give one digest two spellings.
            guard encoded.count == 43,
                  let digest = Data(base64Encoded: encoded + "="),
                  digest.count == 32,
                  digest.base64EncodedString() == encoded + "="
            else { return nil }
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// The payload version this build speaks. Must match `PAIRING_PAYLOAD_VERSION`.
    public static let supportedPayloadVersion = 1

    /// Parse and VALIDATE a scanned QR.
    ///
    /// A camera will happily hand us any QR in the frame — a wifi code, a URL, a boarding
    /// pass. Every field is therefore checked here rather than trusted, so the failure a
    /// user sees is "that is not a herdr pairing code" instead of a socket error later.
    public static func parse(qrText: String) throws -> Payload {
        let trimmed = qrText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { throw Error.notAPairingCode }

        // Version first: a version mismatch must not be reported as a bad field, because
        // the remedy is different (update, not rescan).
        guard payload.v == supportedPayloadVersion else {
            throw Error.unsupportedVersion(payload.v)
        }
        guard !payload.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !payload.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !payload.token.isEmpty,
              (1...65535).contains(payload.port),
              // Empty means the daemon could not read its host key; anything else must
              // decode, or it is not a code a real daemon printed.
              payload.fp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || payload.hostKeyFingerprint != nil
        else { throw Error.notAPairingCode }
        return payload
    }
}

// MARK: - Errors

extension Pairing {
    public enum Error: Swift.Error, Equatable {
        /// The scanned code is not a herdr pairing payload, or a field is unusable.
        case notAPairingCode
        /// The code was made by a daemon this app does not speak.
        case unsupportedVersion(Int)
        /// Could not reach the machine at all.
        case unreachable(String)
        /// The machine refused the redemption. The message is the daemon's, which is
        /// deliberately OPAQUE — it does not say whether the token, the key, or the shape
        /// was wrong, so nothing here can be turned into a probe.
        case refused(String)
        /// Connected, but the reply was not something this protocol defines.
        case badResponse(String)

        /// What to show a person. The daemon's refusal text is intentionally uninformative,
        /// so the app supplies the actionable sentence instead of surfacing it raw.
        public var userFacingMessage: String {
            switch self {
            case .notAPairingCode:
                return "That code isn't a herdr pairing code. On your computer, run "
                    + "`herdr pair` and scan the code it prints."
            case .unsupportedVersion:
                return "This pairing code was made by a newer version of herdr. "
                    + "Update the app, then scan it again."
            case .unreachable:
                return "Couldn't reach that computer. Check both devices are on the same "
                    + "Tailscale network, then run `herdr pair` again."
            case .refused:
                return "The computer turned down this code. Pairing codes work once and "
                    + "expire — run `herdr pair` again for a fresh one."
            case .badResponse:
                return "Got an unexpected reply from that computer. Run `herdr pair` again."
            }
        }
    }
}

// MARK: - Redeeming

extension Pairing {
    /// The request sent to the machine. Field names are the contract with `PairRedeem` in
    /// `src/pairing.rs`; `type` is spelled via CodingKeys because it is a Swift keyword.
    struct RedeemRequest: Codable, Equatable {
        let kind: String
        let token: String
        let publicKey: String
        let device: String

        enum CodingKeys: String, CodingKey {
            case kind = "type"
            case token
            case publicKey = "public_key"
            case device
        }
    }

    /// Must equal `PAIR_REDEEM_KIND`.
    static let redeemKind = "pair.redeem"

    /// Encode the redemption as the single line the daemon reads.
    ///
    /// Separated from the socket so the wire format is testable without a server, and so
    /// the one place that could leak a private key is a pure function you can read.
    static func redeemLine(token: String, publicKeyLine: String, deviceLabel: String) throws -> Data {
        let request = RedeemRequest(
            kind: redeemKind,
            token: token,
            publicKey: publicKeyLine,
            device: deviceLabel)
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)  // the daemon reads exactly one line
        return data
    }

    /// Redeem a scanned code: hand the machine this device's PUBLIC key.
    ///
    /// Blocking, by design — it is one short request/response and the caller runs it off
    /// the main actor. A synchronous core is what lets the whole protocol be tested against
    /// a real socket on Linux, where the app's own networking stack does not exist.
    ///
    /// - Parameter publicKeyLine: an `authorized_keys` line, from `PairingKey`. NEVER a
    ///   private key; the daemon validates the shape and refuses anything else.
    public static func redeem(
        payload: Payload,
        publicKeyLine: String,
        deviceLabel: String,
        timeout: TimeInterval = 15
    ) throws {
        let line = try redeemLine(
            token: payload.token, publicKeyLine: publicKeyLine, deviceLabel: deviceLabel)

        let fd = try connectSocket(host: payload.host, port: payload.port, timeout: timeout)
        defer { platformClose(fd) }

        try writeAll(fd: fd, data: line)
        let reply = try readLine(fd: fd)

        guard let replyData = reply.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: replyData) as? [String: Any],
              let type = object["type"] as? String
        else { throw Error.badResponse(reply.isEmpty ? "connection closed" : reply) }

        switch type {
        case "pair.ok":
            return
        case "pair.error":
            throw Error.refused((object["message"] as? String) ?? "pairing refused")
        default:
            throw Error.badResponse(type)
        }
    }

    /// Async wrapper for callers driving this from SwiftUI.
    public static func redeem(
        payload: Payload,
        publicKeyLine: String,
        deviceLabel: String,
        timeout: TimeInterval = 15
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try redeem(
                payload: payload, publicKeyLine: publicKeyLine,
                deviceLabel: deviceLabel, timeout: timeout)
        }.value
    }
}

// MARK: - Sockets

extension Pairing {
    /// Connect to a numeric IPv4 address.
    ///
    /// DELIBERATELY NO DNS. The payload is generated by `herdr pair`, which always writes a
    /// literal tailnet address, so accepting a hostname would only add a resolver — and a
    /// name in a scanned QR is a way to point the phone somewhere the machine did not.
    static func connectSocket(host: String, port: Int, timeout: TimeInterval) throws -> Int32 {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            throw Error.unreachable("not an IPv4 address: \(host)")
        }

        let fd = socket(AF_INET, sockStream, 0)
        guard fd >= 0 else { throw Error.unreachable("could not open a socket") }

        // Bound both ways: a machine that accepts and then says nothing must not hang the
        // pairing screen forever.
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        withUnsafePointer(to: &tv) { p in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, p, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, p, socklen_t(MemoryLayout<timeval>.size))
        }

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                platformConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            platformClose(fd)
            throw Error.unreachable("\(host):\(port) — \(String(cString: strerror(code)))")
        }
        return fd
    }

    static func writeAll(fd: Int32, data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while sent < data.count {
                let n = send(fd, base.advanced(by: sent), data.count - sent, 0)
                if n > 0 {
                    sent += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    throw Error.unreachable("send failed: \(String(cString: strerror(errno)))")
                }
            }
        }
    }

    /// Read one newline-terminated line, bounded.
    ///
    /// The cap matters even though the peer is our own daemon: this runs before any
    /// authentication, so a wrong or hostile listener must not be able to grow the phone's
    /// memory by never sending a newline.
    static func readLine(fd: Int32, limit: Int = 8 * 1024) throws -> String {
        var out = [UInt8]()
        var byte: UInt8 = 0
        while out.count < limit {
            let n = recv(fd, &byte, 1, 0)
            if n == 1 {
                if byte == 0x0A { break }
                out.append(byte)
            } else if n == 0 {
                break  // peer closed; caller reports whatever arrived
            } else if errno == EINTR {
                continue
            } else {
                throw Error.unreachable("read failed: \(String(cString: strerror(errno)))")
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}
