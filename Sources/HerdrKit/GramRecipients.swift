import Foundation

/// An agent Gram can write to: the "@" list, the pill sheet's "Write to" rows.
public struct GramRecipient: Identifiable, Equatable, Sendable {
    /// The routing name `gram.post` takes as `to`, which is also the `from` the agent's own
    /// grams carry: a local agent's name, or a federated one's `<alias>/<name>`.
    public let from: String
    /// The bare name an "@" types.
    public let name: String
    /// The machine shown when another recipient has the same name; nil for this device.
    public let machine: String?
    public var id: String { from }

    public init(from: String, name: String, machine: String?) {
        self.from = from
        self.name = name
        self.machine = machine
    }
}

public enum GramRecipients {
    /// Everyone Gram can address: the agents that wrote in `messages` first, most recent
    /// first (`messages` is newest first), then every other addressable agent of `roster`
    /// by name, A to Z. Alphabetical rather than board order because the board sorts by
    /// status, which moves agents around while the owner is typing a name. One entry per
    /// routing name, so two agents with the same bare name on different machines stay apart.
    ///
    /// `localMachine` labels a local agent (no machine of its own), empty for none.
    public static func build(messages: [GramMessage], roster: [AgentInfo],
                             localMachine: String) -> [GramRecipient] {
        let local = localMachine.isEmpty ? nil : localMachine
        var seen = Set<String>()
        var result: [GramRecipient] = []
        for message in messages where message.isFromAgent {
            guard seen.insert(message.from).inserted else { continue }
            result.append(GramRecipient(from: message.from, name: message.senderAgentName,
                                        machine: message.senderMachine ?? local))
        }
        var others: [GramRecipient] = []
        for info in roster {
            guard let from = routingName(of: info), seen.insert(from).inserted else { continue }
            let machine = info.machineID == nil
                ? local
                : (info.machineLabel.flatMap { $0.isEmpty ? nil : $0 } ?? info.machineID)
            others.append(GramRecipient(from: from, name: GramMessage.agentName(from: from), machine: machine))
        }
        others.sort {
            switch $0.name.localizedCaseInsensitiveCompare($1.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return $0.from < $1.from
            }
        }
        return result + others
    }

    /// The `to` that reaches `info` through `gram.post`, or nil when the daemon would refuse
    /// it (herdr `is_live_agent_name`): an archived or unnamed agent has no live name. A
    /// federated agent goes by its `<alias>/<name>`: when the daemon reports `gram_reachable`
    /// (herdr #403; it reports it on every remote row once it has the capability), that
    /// decides; an older daemon gives only reachability, so the agent is listed while its
    /// peer is `reachable` (degraded is refused there too), and a relay policy that disallows
    /// the peer surfaces as the daemon's error on send.
    static func routingName(of info: AgentInfo) -> String? {
        guard !info.isArchived, let name = info.name, !name.isEmpty else { return nil }
        if info.machineID != nil {
            if let gramReachable = info.gramReachable { return gramReachable ? name : nil }
            if info.reachability != "reachable" { return nil }
        }
        return name
    }
}
