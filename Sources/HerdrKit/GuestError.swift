import Foundation

/// Why a guest connection failed, in the terms the guest UI needs.
public enum GuestError: Error, Equatable, CustomStringConvertible {
    /// No host socket is connected to the relay (close 4503, or from an older relay
    /// 503 `host_offline` before the upgrade), or it dropped mid-session (close 1001).
    case hostOffline
    /// The host already has 32 relay sessions open (close 4504, or from an older relay
    /// 503 `host_busy`).
    case hostBusy
    /// Too many connects from this network (close 4429, or from an older relay 429
    /// `rate_limited`).
    case rateLimited
    /// The relay rejected the request as invalid (404 `not_found`, 426
    /// `upgrade_required`, or any other unexpected status).
    case relayRejected(status: Int, code: String?)
    /// The relay closed the socket because a message exceeded its size limit (1009).
    case messageTooLarge
    /// The socket closed with a code this client does not expect.
    case connectionClosed(code: Int, reason: String?)
    /// The host refused the Noise handshake (message 2 `{"ok":false}`).
    case refused(GuestRefusal)
    /// The Noise channel failed: bad keys, or a forged or malformed message.
    case secureChannelFailed(String)
    /// The shared agent is not the pane's foreground program (`guest_paused`).
    case paused
    /// The owner revoked this guest (`guest_revoked`).
    case revoked
    /// The host does not allow guests to call this method (`guest_forbidden`).
    case forbidden

    /// The guest-access API error codes.
    public static func fromAPICode(_ code: String) -> GuestError? {
        switch code {
        case "guest_paused": return .paused
        case "guest_revoked": return .revoked
        case "guest_forbidden": return .forbidden
        case "host_offline": return .hostOffline
        default: return nil
        }
    }

    /// Classifies any error a guest call can throw, or nil when it is not guest-specific.
    public static func classify(_ error: Error) -> GuestError? {
        if let guest = error as? GuestError { return guest }
        if let api = error as? APIError { return fromAPICode(api.code) }
        return nil
    }

    /// True when retrying cannot help: the grant is gone for good.
    public var isAccessLost: Bool {
        switch self {
        case .revoked: return true
        case .refused(let refusal): return refusal.meansRevoked
        default: return false
        }
    }

    public var description: String {
        switch self {
        case .hostOffline: return "the machine is offline"
        case .hostBusy: return "the machine has too many open sessions; try again shortly"
        case .rateLimited: return "too many connection attempts; try again in a minute"
        case .relayRejected(let status, let code):
            return "the relay rejected the connection (HTTP \(status)\(code.map { " \($0)" } ?? ""))"
        case .messageTooLarge: return "the message was too large for the relay"
        case .connectionClosed(1003, _):
            return "the relay rejected a malformed message"
        case .connectionClosed(let code, let reason):
            return "the relay closed the connection (\(code)\(reason.map { ": \($0)" } ?? ""))"
        case .refused(let refusal): return refusal.description
        case .secureChannelFailed(let why): return "secure connection failed: \(why)"
        case .paused: return "the agent isn't running"
        case .revoked: return "your access was revoked"
        case .forbidden: return "guests can't do that"
        }
    }
}

/// The reasons a host gives in a refused message 2.
public enum GuestRefusal: Equatable, Sendable, CustomStringConvertible {
    case unknown
    case revoked
    case inviteUsed
    case inviteExpired
    case inviteInvalid
    case other(String)

    public init(code: String) {
        switch code {
        case "unknown": self = .unknown
        case "revoked": self = .revoked
        case "invite_used": self = .inviteUsed
        case "invite_expired": self = .inviteExpired
        case "invite_invalid": self = .inviteInvalid
        default: self = .other(code)
        }
    }

    /// A returning guest the host no longer knows has lost access as surely as a
    /// revoked one: the owner removed them.
    public var meansRevoked: Bool {
        switch self {
        case .unknown, .revoked: return true
        default: return false
        }
    }

    public var description: String {
        switch self {
        case .unknown: return "this machine no longer knows this phone"
        case .revoked: return "your access was revoked"
        case .inviteUsed: return "this invite was already used"
        case .inviteExpired: return "this invite has expired"
        case .inviteInvalid: return "this invite is not valid"
        case .other(let code): return "the machine refused the connection (\(code))"
        }
    }
}
