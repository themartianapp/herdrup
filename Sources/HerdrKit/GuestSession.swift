import Foundation

/// What a guest holds after accepting an invite: one agent on one machine. The app
/// persists this as a "shared with you" machine.
public struct GuestAccess: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let guestID: String
    /// The name the host labels this guest's prompts with.
    public let guestName: String
    public let machineLabel: String
    public let ownerName: String
    public let agentName: String
    /// The host-local pane id of the shared agent.
    public let agentTarget: String
    public let endpoint: RelayEndpoint
    public let acceptedAt: Date
    /// Redeemed with this account's statement (herdr binds the grant to the account), so
    /// every hello for it must carry a fresh statement. Saved shares from before default to
    /// false: plain, as they were redeemed.
    public let accountBound: Bool

    public var id: String { "\(endpoint.hostID)/\(guestID)" }

    public init(
        guestID: String, guestName: String, machineLabel: String, ownerName: String,
        agentName: String, agentTarget: String, endpoint: RelayEndpoint, acceptedAt: Date,
        accountBound: Bool = false
    ) {
        self.guestID = guestID
        self.guestName = guestName
        self.machineLabel = machineLabel
        self.ownerName = ownerName
        self.agentName = agentName
        self.agentTarget = agentTarget
        self.endpoint = endpoint
        self.acceptedAt = acceptedAt
        self.accountBound = accountBound
    }

    private enum CodingKeys: String, CodingKey {
        case guestID, guestName, machineLabel, ownerName, agentName, agentTarget, endpoint, acceptedAt, accountBound
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            guestID: try container.decode(String.self, forKey: .guestID),
            guestName: try container.decode(String.self, forKey: .guestName),
            machineLabel: try container.decode(String.self, forKey: .machineLabel),
            ownerName: try container.decode(String.self, forKey: .ownerName),
            agentName: try container.decode(String.self, forKey: .agentName),
            agentTarget: try container.decode(String.self, forKey: .agentTarget),
            endpoint: try container.decode(RelayEndpoint.self, forKey: .endpoint),
            acceptedAt: try container.decode(Date.self, forKey: .acceptedAt),
            accountBound: try container.decodeIfPresent(Bool.self, forKey: .accountBound) ?? false)
    }

    /// The composer placeholder: "Message <agent> as <name>".
    public var composerPlaceholder: String { "Message \(agentName) as \(guestName)" }

    /// Whether `agent` is the one this share grants: listed by the grant's terminal id, or
    /// by its pane id (a guest's projection may omit `terminal_id`).
    public func isSharedAgent(_ agent: AgentInfo) -> Bool {
        agent.terminalID == agentTarget || agent.paneID == agentTarget
    }

    /// This share under the name the host lists its agent by now, or nil when the name is
    /// unchanged or the host does not list the shared agent (`isSharedAgent`). The grant is
    /// the agent in that terminal, so it survives the owner renaming the agent.
    public func renamed(listing agents: [AgentInfo]) -> GuestAccess? {
        guard let name = agents.first(where: isSharedAgent)?.name,
              !name.isEmpty, name != agentName else { return nil }
        return GuestAccess(guestID: guestID, guestName: guestName, machineLabel: machineLabel,
                           ownerName: ownerName, agentName: name, agentTarget: agentTarget,
                           endpoint: endpoint, acceptedAt: acceptedAt, accountBound: accountBound)
    }

    /// The name to address the shared agent by (a guest's `gram.post` `to`): the one the
    /// host lists it under now, since the saved name is stale between the owner renaming
    /// the agent and the next home poll; else the saved one.
    public func liveAgentName(listed agent: AgentInfo?) -> String {
        guard let name = agent?.name, !name.isEmpty else { return self.agentName }
        return name
    }

    /// `onFeatures` hears what the host advertises in every session's hello reply, so a
    /// share whose owner turned Gram on (or a host that learned guest push) shows it on
    /// the next call without a new accept. `statements` gives an account-bound share its
    /// statement for each hello; without one its calls fail with `.accountStatement(.signedOut)`.
    public func transport(
        identity: GuestIdentity, statements: GuestStatementSource? = nil,
        connector: RelaySocketConnector = URLSessionRelayConnector(),
        onFeatures: (@Sendable (GuestFeatures) -> Void)? = nil
    ) -> RelayTransport {
        RelayTransport(guestID: guestID, endpoint: endpoint, identity: identity,
                       account: accountBound ? .bound(statements) : .plain,
                       connector: connector, onFeatures: onFeatures)
    }
}

/// What a host offers this guest beyond the terminal and composer, from the hello reply's
/// `features` object. A host older than the object offers neither.
public struct GuestFeatures: Equatable, Hashable, Sendable {
    /// The owner shares the agent's Grams with this guest (`share_gram`).
    public var gram: Bool
    /// The host takes a guest device's push registration.
    public var push: Bool

    public static let none = GuestFeatures(gram: false, push: false)

    public init(gram: Bool, push: Bool) {
        self.gram = gram
        self.push = push
    }

    /// Reads `features` from a decoded hello reply; anything missing or not a bool is off.
    public init(helloReply: [String: Any]) {
        let features = helloReply["features"] as? [String: Any]
        self.init(gram: features?["gram"] as? Bool ?? false, push: features?["push"] as? Bool ?? false)
    }

    /// Whether the host serves many requests on one session (`multi_request`, herdr #356).
    /// Read by the transport only: it is not a feature the app shows, compares or saves.
    static func multiRequest(helloReply: [String: Any]) -> Bool {
        (helloReply["features"] as? [String: Any])?["multi_request"] as? Bool ?? false
    }
}

public enum GuestSession {
    private struct AcceptHello: Encodable {
        let v = 1
        let inviteID: String
        let secret: String
        let device: String
        /// This account's statement for the host: redeeming with it binds the share to the
        /// account ("Add to my account"). Absent for a plain share.
        let account: String?

        enum CodingKeys: String, CodingKey {
            case v, secret, device, account
            case inviteID = "invite_id"
        }
    }

    /// Redeems `invite` with this device's key. The host binds the key to the guest
    /// it creates, so every later connection with the same key is this guest.
    ///
    /// With `bindToAccount` the hello also carries the signed-in account's statement for
    /// this device at the invite's host (`statements`), so the share belongs to the account
    /// and opens on its other devices. That needs an invite with `"acct": 1`; when no
    /// statement can be had it throws `GuestError.accountStatement` and redeems nothing,
    /// rather than redeeming a plain share instead.
    public static func accept(
        _ invite: GuestInvite, identity: GuestIdentity, device: String = "iPhone",
        bindToAccount: Bool = false, statements: GuestStatementSource? = nil,
        now: Date = Date(), connector: RelaySocketConnector = URLSessionRelayConnector()
    ) async throws -> GuestAccess {
        if invite.isExpired(now: now) { throw GuestInvite.Failure.expired }
        let endpoint = RelayEndpoint(relay: invite.relay, hostID: invite.hostID, hostPublicKey: invite.hostPublicKey)
        var account: String?
        if bindToAccount {
            guard invite.acceptsAccount else { throw GuestError.accountStatement(.notOffered) }
            account = try await GuestStatements.fetch(for: invite.hostID, from: statements).jws
        }
        let hello = try JSONEncoder().encode(AcceptHello(
            inviteID: invite.inviteID, secret: invite.secret, device: device, account: account))
        let session = try await RelaySession.open(endpoint: endpoint, identity: identity, hello: hello, connector: connector)
        session.close()
        return try access(from: session.reply, invite: invite, endpoint: endpoint, now: now, accountBound: account != nil)
    }

    static func access(
        from reply: [String: Any], invite: GuestInvite, endpoint: RelayEndpoint, now: Date, accountBound: Bool = false
    ) throws -> GuestAccess {
        func text(_ value: Any?) -> String? {
            guard let string = value as? String, !string.isEmpty else { return nil }
            return string
        }
        let agent = reply["agent"] as? [String: Any]
        guard let guestID = text(reply["guest_id"]), let target = text(agent?["target"]) else {
            throw GuestError.secureChannelFailed("the host's acceptance is incomplete")
        }
        return GuestAccess(
            guestID: guestID,
            guestName: text(reply["name"]) ?? invite.guestName,
            machineLabel: text(reply["machine_label"]) ?? invite.machineLabel,
            ownerName: text(reply["owner_name"]) ?? invite.ownerName,
            agentName: text(agent?["name"]) ?? invite.agentName,
            agentTarget: target,
            endpoint: endpoint,
            acceptedAt: now,
            accountBound: accountBound)
    }
}

/// Where a guest gets this account's statements for hosts (DESIGN §3.3): the app's
/// `StatementCache`, which keeps each one until less than two minutes remain.
public protocol GuestStatementSource: Sendable {
    /// A statement saying this device's guest key belongs to the account, for `host`.
    func statement(for host: String) async throws -> StatementCache.Statement
}

extension StatementCache: GuestStatementSource {}

enum GuestStatements {
    /// The statement for `host`, or `GuestError.accountStatement` saying why there is none.
    static func fetch(for host: String, from source: GuestStatementSource?) async throws -> StatementCache.Statement {
        guard let source else { throw GuestError.accountStatement(.signedOut) }
        do {
            return try await source.statement(for: host)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GuestError.accountStatement(AccountStatementFailure(error))
        }
    }

    /// herdr's in-band refresh (src/guest/link/session.rs `Refresh`): one whole transport
    /// message of an account-bound session, which the host checks and never forwards to the API.
    static func refreshMessage(_ jws: String) -> Data {
        // A JSON string of the statement; a JWS is base64url and dots, so this only quotes it.
        let quoted = (try? JSONSerialization.data(withJSONObject: jws, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            ?? Data("\"\"".utf8)
        return Data(#"{"t":"account.refresh","account":"#.utf8) + quoted + Data("}".utf8)
    }
}
