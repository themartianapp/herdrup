import Foundation

/// The last line of DESIGN §5.4: a sync body must never carry a secret. The bodies are their
/// own allowlisted types, so no store's secret field has anywhere to go; this scan also
/// catches a secret pasted into a free-text field (a prompt, a nickname), and `SyncChange`
/// refuses any body it flags before it can be queued.
///
/// It flags field names that name a secret, and values that hold a PEM block (`-----BEGIN`),
/// an SSH key (`ssh-ed25519 AAAA…` or a bare key blob), a 32-byte base64url or base64 string
/// (keys, invite and session tokens), a host-key pin (`SHA256:…`, or 64 hex digits), or an
/// invite or pairing link. The public ids of a share (`host_id`, `guest_id`, `node_pub`) are
/// exempt from the 32-byte rule: they are ids, and public.
public enum SyncSecretScan {
    public struct Finding: Equatable, Sendable {
        /// The body field at fault.
        public let field: String
        public let reason: String
    }

    /// Fields whose values are public ids, checked by shape instead (`SyncValidation`).
    static let idFields: Set<String> = ["host_id", "guest_id", "node_pub"]

    /// Words a field name must not contain (split at `_`).
    static let secretWords: Set<String> = [
        "password", "passphrase", "secret", "private", "key", "token", "pin", "pins", "fingerprint", "fp",
        "invite", "credential", "credentials", "code", "pairing",
    ]

    private static let patterns: [(String, NSRegularExpression)] = [
        ("pem", #"-----BEGIN"#),
        ("ssh key", #"\b(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp[0-9]+|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)(-cert-v01@openssh\.com)?\s+AAAA"#),
        ("ssh key blob", #"AAAA(B3NzaC1yc2|C3NzaC1lZDI1NTE5|E2VjZHNhLXNoYTIt|B3NzaC1kc3)"#),
        ("32-byte secret", #"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])"#),
        ("32-byte secret", #"(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{43}="#),
        ("host key pin", #"SHA256:"#),
        ("host key pin", #"(?<![0-9A-Fa-f])[0-9A-Fa-f]{64}(?![0-9A-Fa-f])"#),
        ("invite link", #"herdrup://(guest-invite|pair|account)"#),
        ("invite link", #"(?i)\bhttps?://[^\s/]+(/[^\s?#]*)?/i([/#]|$|\s)"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    /// Findings in one item body (a JSON object).
    public static func findings(inBody json: Data) -> [Finding] {
        guard let object = try? JSONSerialization.jsonObject(with: json) else {
            return [Finding(field: "body", reason: "not JSON")]
        }
        var found: [Finding] = []
        scan(object, field: "body", into: &found)
        return found
    }

    /// Findings in every body of a push request (`{changes: [{…, body}]}`).
    public static func findings(inPush json: Data) -> [Finding] {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let changes = object["changes"] as? [[String: Any]]
        else { return [Finding(field: "changes", reason: "not a push")] }
        var found: [Finding] = []
        for change in changes {
            if let id = change["id"] as? String { scanValue(id, field: "id", idField: true, into: &found) }
            if let body = change["body"] { scan(body, field: "body", into: &found) }
        }
        return found
    }

    private static func scan(_ value: Any, field: String, into found: inout [Finding]) {
        switch value {
        case let object as [String: Any]:
            for (name, inner) in object {
                let words = name.lowercased().split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "." })
                if words.contains(where: { secretWords.contains(String($0)) }) {
                    found.append(Finding(field: name, reason: "secret field name"))
                }
                scan(inner, field: name, into: &found)
            }
        case let array as [Any]:
            for inner in array { scan(inner, field: field, into: &found) }
        case let text as String:
            scanValue(text, field: field, idField: idFields.contains(field), into: &found)
        default:
            break
        }
    }

    /// An id passes the 32-byte rule (ids are random and public) but nothing else.
    private static func scanValue(_ text: String, field: String, idField: Bool, into found: inout [Finding]) {
        let range = NSRange(text.startIndex..., in: text)
        for (reason, pattern) in patterns where !(idField && reason == "32-byte secret") {
            if pattern.firstMatch(in: text, range: range) != nil {
                found.append(Finding(field: field, reason: reason))
            }
        }
    }
}
