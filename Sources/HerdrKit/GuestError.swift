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
    /// A hello that must carry this account's statement (an account-bound grant, or a
    /// redemption that binds) could not get one. Never answered by a plain hello instead.
    case accountStatement(AccountStatementFailure)

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
        case .accountStatement(let failure): return failure.description
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
    /// herdr's account codes (src/guest/account.rs `codes`), in a refused hello or as the
    /// close reason of an account-bound session.
    /// An account-bound share's hello carried no statement.
    case accountRequired
    /// Malformed, badly signed, or for another issuer, host or device.
    case statementInvalid
    /// Expired or not yet valid; also the close at an account-bound session's deadline.
    case statementExpired
    /// The host could not refresh the account keys recently enough; retry later.
    case accountKeysStale
    /// The host has `[guest] accounts = false`.
    case accountsDisabled
    /// The statement names another account than the share's.
    case accountMismatch
    /// The owner removed this device from the share.
    case deviceRemoved
    case other(String)

    public init(code: String) {
        switch code {
        case "unknown": self = .unknown
        case "revoked": self = .revoked
        case "invite_used": self = .inviteUsed
        case "invite_expired": self = .inviteExpired
        case "invite_invalid": self = .inviteInvalid
        case "account_required": self = .accountRequired
        case "statement_invalid": self = .statementInvalid
        case "statement_expired": self = .statementExpired
        case "account_keys_stale": self = .accountKeysStale
        case "accounts_disabled": self = .accountsDisabled
        case "account_mismatch": self = .accountMismatch
        case "device_removed": self = .deviceRemoved
        default: self = .other(code)
        }
    }

    /// A returning guest the host no longer knows has lost access as surely as a
    /// revoked one: the owner removed them.
    public var meansRevoked: Bool {
        switch self {
        case .unknown, .revoked, .deviceRemoved: return true
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
        case .accountRequired: return "this share needs your HerdrUp account; sign in to open it"
        case .statementInvalid: return "the machine didn't accept your account's proof for this device"
        case .statementExpired: return "your account's proof for this device expired; try again"
        case .accountKeysStale: return "the machine couldn't check your account right now; try again shortly"
        case .accountsDisabled: return "this machine doesn't take HerdrUp accounts"
        case .accountMismatch: return "this share belongs to another HerdrUp account"
        case .deviceRemoved: return "the owner removed this device from the share"
        case .other(let code): return "the machine refused the connection (\(code))"
        }
    }
}

/// Why an account statement for a guest hello could not be had (`GuestError.accountStatement`).
public enum AccountStatementFailure: Error, Equatable, Sendable, CustomStringConvertible {
    /// No HerdrUp account is signed in on this device.
    case signedOut
    /// The account service could not be reached.
    case unreachable
    /// The account service refused, or answered without a statement for this host.
    case refused(String)
    /// The invite's host does not take statements (no `"acct": 1`).
    case notOffered

    /// Classifies what fetching a statement threw.
    public init(_ error: Error) {
        switch error {
        case let failure as AccountStatementFailure: self = failure
        case let account as AccountError:
            switch account {
            case .signedOut: self = .signedOut
            case .unreachable: self = .unreachable
            case .malformedResponse: self = .refused("malformed_response")
            case .refused(_, let code, _, _, _): self = .refused(code)
            }
        case let cache as StatementCache.Failure:
            switch cache {
            case .invalidHostID: self = .refused("invalid_host_id")
            case .missingStatement: self = .refused("missing_statement")
            }
        default: self = .unreachable
        }
    }

    public var description: String {
        switch self {
        case .signedOut: return "sign in to your HerdrUp account to open this share"
        case .unreachable: return "couldn't reach your HerdrUp account; check your connection and try again"
        case .refused(let code): return "your HerdrUp account refused this device (\(code))"
        case .notOffered: return "this machine doesn't take HerdrUp accounts"
        }
    }
}
