import Foundation

// MARK: - Guest access, owner side (guest.invite.create / guest.list / guest.revoke / guest.audit)
//
// The owner manages guests over the normal SSH connection. Every call takes an optional
// `machine` (a saved peer alias) that the coordinator routes to that peer, so a federated
// agent is shared by the daemon that actually runs it. Decoding is lenient in the same way
// as `NotificationsStatus`: unknown keys are ignored and an unknown state or event keeps
// its raw string instead of failing the whole answer.

/// Where an owner RPC about one agent goes: the daemon-local pane id plus, for a federated
/// agent, the peer alias the coordinator routes to. A federated pane id is
/// `<machineID>/<local id>`; only that exact prefix is stripped, because the local id may
/// itself contain slashes.
public struct GuestRoute: Equatable, Sendable {
    public let target: String
    public let machine: String?

    public init(paneID: String, machineID: String?) {
        if let machineID, !machineID.isEmpty, paneID.hasPrefix("\(machineID)/") {
            target = String(paneID.dropFirst(machineID.count + 1))
            machine = machineID
        } else {
            target = paneID
            machine = nil
        }
    }

    public init(agent: AgentInfo) {
        self.init(paneID: agent.paneID, machineID: agent.machineID)
    }

    /// A federated agent's `name`/`terminal_id` carry the same `<machineID>/` prefix; the
    /// daemon that owns the agent (and its guest store) knows them without it.
    public func local(_ value: String?) -> String? {
        guard let value, let machine else { return value }
        let prefix = "\(machine)/"
        return value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
    }
}

/// The agent a guest or invite is bound to (`grant` in guests.json). The grant's
/// `agent_session` (the daemon's own session identity) is not needed by the app and is
/// deliberately not decoded.
public struct GuestGrant: Decodable, Sendable, Equatable {
    public let terminalID: String?
    /// Nil for an unnamed agent.
    public let agentName: String?

    public init(terminalID: String?, agentName: String?) {
        self.terminalID = terminalID
        self.agentName = agentName
    }

    enum CodingKeys: String, CodingKey {
        case terminalID = "terminal_id"
        case agentName = "agent_name"
    }

    /// Whether this grant is the given agent, by its daemon-local identity. The durable
    /// terminal id decides when both sides have one; the agent name is the fallback for an
    /// answer that lacks it.
    public func matches(terminalID otherTerminal: String?, agentName otherName: String?) -> Bool {
        if let terminalID, let otherTerminal { return terminalID == otherTerminal }
        if let agentName, let otherName { return agentName == otherName }
        return false
    }
}

/// One outstanding or consumed invite. Never carries the secret (only its hash lives on disk).
public struct GuestInviteRecord: Decodable, Sendable, Equatable, Identifiable {
    public let inviteID: String
    public let name: String
    public let grant: GuestGrant?
    public let ownerName: String?
    public let machineLabel: String?
    public let createdMs: UInt64?
    public let expiresMs: UInt64?
    /// The guest id that accepted this invite; nil while it is unused.
    public let usedBy: String?
    /// The guest it makes will see the agent's Grams (`share_gram`). False on a daemon
    /// that predates Gram sharing.
    public let shareGram: Bool

    public var id: String { inviteID }

    public init(inviteID: String, name: String, grant: GuestGrant?, ownerName: String? = nil,
                machineLabel: String? = nil, createdMs: UInt64? = nil, expiresMs: UInt64? = nil,
                usedBy: String? = nil, shareGram: Bool = false) {
        self.inviteID = inviteID
        self.name = name
        self.grant = grant
        self.ownerName = ownerName
        self.machineLabel = machineLabel
        self.createdMs = createdMs
        self.expiresMs = expiresMs
        self.usedBy = usedBy
        self.shareGram = shareGram
    }

    enum CodingKeys: String, CodingKey {
        case name, grant
        case inviteID = "invite_id"
        case ownerName = "owner_name"
        case machineLabel = "machine_label"
        case createdMs = "created_ms"
        case expiresMs = "expires_ms"
        case usedBy = "used_by"
        case shareGram = "share_gram"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inviteID = try c.decode(String.self, forKey: .inviteID)
        name = try c.decode(String.self, forKey: .name)
        grant = try c.decodeIfPresent(GuestGrant.self, forKey: .grant)
        ownerName = try c.decodeIfPresent(String.self, forKey: .ownerName)
        machineLabel = try c.decodeIfPresent(String.self, forKey: .machineLabel)
        createdMs = try c.decodeIfPresent(UInt64.self, forKey: .createdMs)
        expiresMs = try c.decodeIfPresent(UInt64.self, forKey: .expiresMs)
        usedBy = try c.decodeIfPresent(String.self, forKey: .usedBy)
        shareGram = try c.decodeIfPresent(Bool.self, forKey: .shareGram) ?? false
    }

    /// Still redeemable: nobody used it and it has not expired.
    public func isPending(nowMs: UInt64) -> Bool {
        guard usedBy == nil else { return false }
        guard let expiresMs else { return true }
        return expiresMs > nowMs
    }
}

/// One accepted guest (a device key bound to one agent).
public struct GuestRecord: Decodable, Sendable, Equatable, Identifiable {
    public let guestID: String
    public let name: String
    /// `SHA256:9f3a·e71c·04bd·c21e` — the only key material the owner RPCs expose.
    public let fingerprint: String?
    /// The device class the guest reported when accepting ("iPhone", "iPad").
    public let device: String?
    public let grant: GuestGrant?
    public let createdMs: UInt64?
    /// The share's last use, from whichever of its devices.
    public let lastSeenMs: UInt64?
    public let revoked: Bool
    /// The guest sees the agent's Grams and gets pushed for new ones (`share_gram`).
    public let shareGram: Bool
    /// The guest kept the share in their HerdrUp account, so each of their signed-in
    /// devices may use it (`account_bound`). False on a daemon from before accounts.
    public let accountBound: Bool
    /// Who the share belongs to (`person`): the account's id on this machine when
    /// account-bound, else the device's fingerprint. Every share with the same person is one
    /// person to the owner, and `guest.revoke {person}` ends them all. Nil on an older daemon.
    public let person: String?
    /// The devices the account added after the one that accepted, removed ones included.
    public let devices: [GuestDeviceInfo]

    public var id: String { guestID }

    public init(guestID: String, name: String, fingerprint: String? = nil, device: String? = nil,
                grant: GuestGrant?, createdMs: UInt64? = nil, lastSeenMs: UInt64? = nil,
                revoked: Bool = false, shareGram: Bool = false, accountBound: Bool = false,
                person: String? = nil, devices: [GuestDeviceInfo] = []) {
        self.guestID = guestID
        self.name = name
        self.fingerprint = fingerprint
        self.device = device
        self.grant = grant
        self.createdMs = createdMs
        self.lastSeenMs = lastSeenMs
        self.revoked = revoked
        self.shareGram = shareGram
        self.accountBound = accountBound
        self.person = person
        self.devices = devices
    }

    enum CodingKeys: String, CodingKey {
        case name, fingerprint, device, grant, revoked, person, devices
        case guestID = "guest_id"
        case createdMs = "created_ms"
        case lastSeenMs = "last_seen_ms"
        case shareGram = "share_gram"
        case accountBound = "account_bound"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guestID = try c.decode(String.self, forKey: .guestID)
        name = try c.decode(String.self, forKey: .name)
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint)
        device = try c.decodeIfPresent(String.self, forKey: .device)
        grant = try c.decodeIfPresent(GuestGrant.self, forKey: .grant)
        createdMs = try c.decodeIfPresent(UInt64.self, forKey: .createdMs)
        lastSeenMs = try c.decodeIfPresent(UInt64.self, forKey: .lastSeenMs)
        revoked = try c.decodeIfPresent(Bool.self, forKey: .revoked) ?? false
        shareGram = try c.decodeIfPresent(Bool.self, forKey: .shareGram) ?? false
        accountBound = try c.decodeIfPresent(Bool.self, forKey: .accountBound) ?? false
        person = try c.decodeIfPresent(String.self, forKey: .person).flatMap { $0.isEmpty ? nil : $0 }
        devices = try c.decodeIfPresent([GuestDeviceInfo].self, forKey: .devices) ?? []
    }

    /// The devices that may use this share now: the one that accepted (`fingerprint`,
    /// `device`) unless the owner removed it, which herdr records as a removed `devices`
    /// entry with its fingerprint, then every added device not removed.
    ///
    /// herdr keeps no last-seen time for the accepting device of its own: `last_seen_ms` is
    /// the share's, stamped by whichever device connected. An added device's connection
    /// stamps both at once, so the accepting device was the last one seen only when the
    /// share's time is newer than every added device's.
    public var usableDevices: [GuestDeviceInfo] {
        var usable: [GuestDeviceInfo] = []
        if let fingerprint, !devices.contains(where: { $0.fingerprint == fingerprint && $0.removed }) {
            var seen = lastSeenMs
            if let seenMs = seen, let newestAdded = devices.compactMap(\.lastSeenMs).max(), seenMs <= newestAdded {
                seen = nil
            }
            usable.append(GuestDeviceInfo(fingerprint: fingerprint, device: device.flatMap { $0.isEmpty ? nil : $0 },
                                      addedMs: createdMs, lastSeenMs: seen))
        }
        usable += devices.filter { !$0.removed && $0.fingerprint != fingerprint }
        return usable
    }
}

/// One device of an account-bound share (`devices[]` in `guest.list`, herdr's
/// `GuestDeviceInfo`; the app's own `GuestDevice` is this device's key).
public struct GuestDeviceInfo: Decodable, Sendable, Equatable {
    public let fingerprint: String
    /// The name the device gave when it was added ("iPhone", "Browser (Chrome on macOS)").
    public let device: String?
    public let addedMs: UInt64?
    public let lastSeenMs: UInt64?
    /// The owner removed it (`guest.remove_device`): herdr refuses it for good.
    public let removed: Bool

    public init(fingerprint: String, device: String? = nil, addedMs: UInt64? = nil,
                lastSeenMs: UInt64? = nil, removed: Bool = false) {
        self.fingerprint = fingerprint
        self.device = device
        self.addedMs = addedMs
        self.lastSeenMs = lastSeenMs
        self.removed = removed
    }

    enum CodingKeys: String, CodingKey {
        case fingerprint, device, removed
        case addedMs = "added_ms"
        case lastSeenMs = "last_seen_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fingerprint = try c.decode(String.self, forKey: .fingerprint)
        device = try c.decodeIfPresent(String.self, forKey: .device).flatMap { $0.isEmpty ? nil : $0 }
        addedMs = try c.decodeIfPresent(UInt64.self, forKey: .addedMs)
        lastSeenMs = try c.decodeIfPresent(UInt64.self, forKey: .lastSeenMs)
        removed = try c.decodeIfPresent(Bool.self, forKey: .removed) ?? false
    }
}

/// Everything one person holds on one machine: their active shares (one per agent) and the
/// devices that may use them. An account-bound person is one person whatever devices they
/// use; a plain guest is one device. Shares are grouped by herdr's `person`, or by the
/// device's fingerprint on a daemon from before accounts, which is what `person` is for a
/// plain share.
public struct GuestPerson: Sendable, Equatable, Identifiable {
    /// The grouping key: `person`, else the fingerprint, else the lone share's guest id.
    public let id: String
    /// Oldest first: the share that brought the person in names them.
    public let grants: [GuestRecord]
    /// Every device that may use at least one of the grants, by fingerprint, in the order
    /// they were added. A device removed from one grant but still on another is listed.
    public let devices: [GuestDeviceInfo]

    public var name: String { grants.first?.name ?? "" }
    public var accountBound: Bool { grants.contains(where: \.accountBound) }
    /// The most recent use of any grant.
    public var lastSeenMs: UInt64? { grants.compactMap(\.lastSeenMs).max() }
    /// The device seen last, when herdr can tell (see `GuestRecord.usableDevices`).
    public var lastSeenDevice: GuestDeviceInfo? {
        devices.filter { $0.lastSeenMs != nil }.max { ($0.lastSeenMs ?? 0) < ($1.lastSeenMs ?? 0) }
    }

    /// What "Remove <name>" sends: one `guest.revoke {person}` for an account-bound person,
    /// so every share and device goes at once; a plain guest's share by its guest id, which a
    /// daemon from before `person` also understands.
    public var revokeTargets: [GuestRevokeTarget] {
        if accountBound, let person = grants.first(where: { $0.person != nil })?.person {
            return [.person(person)]
        }
        return grants.map { .guest($0.guestID) }
    }

    /// The grants that "Remove device" must send `guest.remove_device` for: herdr keeps the
    /// device list per share, so the device goes from each account-bound grant it may use.
    public func grantsHolding(fingerprint: String) -> [GuestRecord] {
        grants.filter { $0.accountBound && $0.usableDevices.contains { $0.fingerprint == fingerprint } }
    }

    /// Groups active shares into people, most recently seen first.
    public static func group(_ guests: [GuestRecord]) -> [GuestPerson] {
        var order: [String] = []
        var byKey: [String: [GuestRecord]] = [:]
        for guest in guests where !guest.revoked {
            let key = guest.person ?? guest.fingerprint ?? guest.guestID
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(guest)
        }
        let people = order.map { key -> GuestPerson in
            let grants = byKey[key, default: []].sorted { ($0.createdMs ?? 0) < ($1.createdMs ?? 0) }
            return GuestPerson(id: key, grants: grants, devices: merge(grants.map(\.usableDevices)))
        }
        return people.sorted { ($0.lastSeenMs ?? 0) > ($1.lastSeenMs ?? 0) }
    }

    /// One entry per fingerprint: the first name given, the earliest add, the latest use.
    private static func merge(_ lists: [[GuestDeviceInfo]]) -> [GuestDeviceInfo] {
        var merged: [GuestDeviceInfo] = []
        for device in lists.joined() {
            guard let index = merged.firstIndex(where: { $0.fingerprint == device.fingerprint }) else {
                merged.append(device)
                continue
            }
            let known = merged[index]
            merged[index] = GuestDeviceInfo(
                fingerprint: known.fingerprint, device: known.device ?? device.device,
                addedMs: [known.addedMs, device.addedMs].compactMap { $0 }.min(),
                lastSeenMs: [known.lastSeenMs, device.lastSeenMs].compactMap { $0 }.max())
        }
        return merged.sorted { ($0.addedMs ?? 0) < ($1.addedMs ?? 0) }
    }
}

/// The daemon's relay link, which runs only while a guest or pending invite exists.
public struct GuestLinkStatus: Decodable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case off, connecting, up, retrying
        /// A state a newer daemon added; kept verbatim rather than failing `guest.list`.
        case other(String)
    }

    public let state: State
    public let lastError: String?

    public init(state: State, lastError: String? = nil) {
        self.state = state
        self.lastError = lastError
    }

    enum CodingKeys: String, CodingKey {
        case state
        case lastError = "last_error"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decodeIfPresent(String.self, forKey: .state) ?? "off" {
        case "off": state = .off
        case "connecting": state = .connecting
        case "up": state = .up
        case "retrying": state = .retrying
        case let raw: state = .other(raw)
        }
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
    }
}

/// Result of `guest.list`.
public struct GuestListing: Decodable, Sendable, Equatable {
    public let guests: [GuestRecord]
    public let invites: [GuestInviteRecord]
    public let link: GuestLinkStatus?

    public init(guests: [GuestRecord] = [], invites: [GuestInviteRecord] = [], link: GuestLinkStatus? = nil) {
        self.guests = guests
        self.invites = invites
        self.link = link
    }

    enum CodingKeys: String, CodingKey { case guests, invites, link }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guests = try c.decodeIfPresent([GuestRecord].self, forKey: .guests) ?? []
        invites = try c.decodeIfPresent([GuestInviteRecord].self, forKey: .invites) ?? []
        link = try c.decodeIfPresent(GuestLinkStatus.self, forKey: .link)
    }

    /// Guests who can still reach the agent: revoked ones stay in the store for the log.
    public var activeGuests: [GuestRecord] { guests.filter { !$0.revoked } }

    /// The active guests as people (see `GuestPerson`), most recently seen first.
    public var people: [GuestPerson] { GuestPerson.group(guests) }

    public func pendingInvites(nowMs: UInt64) -> [GuestInviteRecord] {
        invites.filter { $0.isPending(nowMs: nowMs) }
    }

    /// The non-revoked guests bound to one agent, by its daemon-local identity.
    public func activeGuests(terminalID: String?, agentName: String?) -> [GuestRecord] {
        activeGuests.filter { $0.grant?.matches(terminalID: terminalID, agentName: agentName) == true }
    }
}

/// Result of `guest.invite.create`: the stored invite plus both link forms. `url` is the
/// `herdrup://guest-invite#…` app link (the QR code); `webURL` is the https form.
public struct GuestInviteCreated: Decodable, Sendable, Equatable {
    public let invite: GuestInviteRecord
    public let url: String
    public let webURL: String

    /// The web link to copy or send. A daemon older than the path form returns
    /// `…/i#<payload>`, which Messages splits in two at the `#`; the same payload
    /// goes out as `…/i/<payload>` instead.
    public var shareableWebURL: String {
        GuestInvite.pathFormWebLink(webURL)
    }

    public init(invite: GuestInviteRecord, url: String, webURL: String) {
        self.invite = invite
        self.url = url
        self.webURL = webURL
    }

    enum CodingKeys: String, CodingKey {
        case invite, url
        case webURL = "web_url"
    }
}

/// What `guest.revoke` removes: an accepted guest (closing its live sessions), an unused
/// invite, or every share of one person (`person` from `guest.list`) at once.
public enum GuestRevokeTarget: Sendable, Equatable {
    case guest(String)
    case invite(String)
    case person(String)
}

public enum GuestAuditEvent: Sendable, Equatable {
    case accepted, connected, prompt, upload, denied, paused, revoked
    /// An account-bound person opened the share on another of their devices: `text` is its
    /// name, `fingerprint` its key.
    case deviceAdded
    /// The owner removed one device from an account-bound share (`guest.remove_device`).
    case deviceRemoved
    case other(String)

    init(raw: String) {
        switch raw {
        case "accepted": self = .accepted
        case "connected": self = .connected
        case "prompt": self = .prompt
        case "upload": self = .upload
        case "denied": self = .denied
        case "paused": self = .paused
        case "revoked": self = .revoked
        case "device_added": self = .deviceAdded
        case "device_removed": self = .deviceRemoved
        default: self = .other(raw)
        }
    }
}

public struct GuestAuditFile: Decodable, Sendable, Equatable {
    public let name: String
    public let size: UInt64?
    public let sha256: String?

    public init(name: String, size: UInt64? = nil, sha256: String? = nil) {
        self.name = name
        self.size = size
        self.sha256 = sha256
    }
}

/// One line of `audit.jsonl`, as `guest.audit` returns it (newest first).
public struct GuestAuditEntry: Decodable, Sendable, Equatable {
    public let tsMs: UInt64
    public let guestID: String?
    public let name: String?
    public let fingerprint: String?
    public let event: GuestAuditEvent
    public let pane: String?
    public let method: String?
    public let text: String?
    public let file: GuestAuditFile?

    public init(tsMs: UInt64, guestID: String?, name: String?, fingerprint: String? = nil,
                event: GuestAuditEvent, pane: String? = nil, method: String? = nil,
                text: String? = nil, file: GuestAuditFile? = nil) {
        self.tsMs = tsMs
        self.guestID = guestID
        self.name = name
        self.fingerprint = fingerprint
        self.event = event
        self.pane = pane
        self.method = method
        self.text = text
        self.file = file
    }

    enum CodingKeys: String, CodingKey {
        case name, fingerprint, event, pane, method, text, file
        case tsMs = "ts_ms"
        case guestID = "guest_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tsMs = try c.decode(UInt64.self, forKey: .tsMs)
        guestID = try c.decodeIfPresent(String.self, forKey: .guestID)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint)
        event = GuestAuditEvent(raw: try c.decode(String.self, forKey: .event))
        pane = try c.decodeIfPresent(String.self, forKey: .pane)
        method = try c.decodeIfPresent(String.self, forKey: .method)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        file = try c.decodeIfPresent(GuestAuditFile.self, forKey: .file)
    }
}

/// One machine whose guest store the owner's Settings reads. `alias` nil is the connected
/// machine; a peer is addressed by its saved-profile alias, which the coordinator routes.
public struct GuestMachine: Hashable, Sendable {
    public let alias: String?
    public let label: String

    public init(alias: String?, label: String) {
        self.alias = alias
        self.label = label
    }

    /// Every machine that can hold guests: the connected one first, then the UNION of the
    /// federated saved machine profiles and the peers that currently expose agents, by alias.
    /// A federated machine running no agents still keeps its guests and invites, so it must
    /// be listed; an agent-derived peer covers an older daemon without `machine.status`. A
    /// saved profile that has not opted into federation is not a routable peer (the
    /// coordinator would refuse the request), so it is skipped unless its agents already
    /// name it. Peers sort by label; a saved profile's label wins over the agent-derived one.
    public static func directory(localLabel: String, savedMachines: [SavedMachineStatus],
                                 agentPeers: [PeerSummary]) -> [GuestMachine] {
        var labels: [String: String] = [:]
        for peer in agentPeers { labels[peer.alias] = peer.displayName }
        for saved in savedMachines where saved.hasFederationPolicy || labels[saved.profileID] != nil {
            let label = saved.displayLabel.trimmingCharacters(in: .whitespaces)
            labels[saved.profileID] = label.isEmpty ? (labels[saved.profileID] ?? saved.profileID) : label
        }
        let peers = labels
            .map { GuestMachine(alias: $0.key, label: $0.value) }
            .sorted { ($0.label, $0.alias ?? "") < ($1.label, $1.alias ?? "") }
        return [GuestMachine(alias: nil, label: localLabel)] + peers
    }
}

// MARK: Request params

struct GuestInviteCreateParams: Encodable {
    let target: String
    let name: String
    let ownerName: String
    let machineLabel: String
    let ttlSecs: UInt64?
    let machine: String?
    let shareGram: Bool

    enum CodingKeys: String, CodingKey {
        case target, name, machine
        case ownerName = "owner_name"
        case machineLabel = "machine_label"
        case ttlSecs = "ttl_secs"
        case shareGram = "share_gram"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(target, forKey: .target)
        try c.encode(name, forKey: .name)
        try c.encode(ownerName, forKey: .ownerName)
        try c.encode(machineLabel, forKey: .machineLabel)
        try c.encodeIfPresent(ttlSecs, forKey: .ttlSecs)
        try c.encodeIfPresent(machine, forKey: .machine)
        try c.encode(shareGram, forKey: .shareGram)
    }
}

/// `guest.update`: change an accepted guest's grant options.
struct GuestUpdateParams: Encodable {
    let guestID: String
    let shareGram: Bool
    let machine: String?

    enum CodingKeys: String, CodingKey {
        case machine
        case guestID = "guest_id"
        case shareGram = "share_gram"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(guestID, forKey: .guestID)
        try c.encode(shareGram, forKey: .shareGram)
        try c.encodeIfPresent(machine, forKey: .machine)
    }
}

struct GuestListParams: Encodable {
    let machine: String?

    enum CodingKeys: String, CodingKey { case machine }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(machine, forKey: .machine)
    }
}

struct GuestRevokeParams: Encodable {
    let target: GuestRevokeTarget
    let machine: String?

    enum CodingKeys: String, CodingKey {
        case machine, person
        case guestID = "guest_id"
        case inviteID = "invite_id"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch target {
        case .guest(let id): try c.encode(id, forKey: .guestID)
        case .invite(let id): try c.encode(id, forKey: .inviteID)
        case .person(let person): try c.encode(person, forKey: .person)
        }
        try c.encodeIfPresent(machine, forKey: .machine)
    }
}

/// `guest.remove_device`: one device off one account-bound share, for good.
struct GuestRemoveDeviceParams: Encodable {
    let guestID: String
    let fingerprint: String
    let machine: String?

    enum CodingKeys: String, CodingKey {
        case fingerprint, machine
        case guestID = "guest_id"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(guestID, forKey: .guestID)
        try c.encode(fingerprint, forKey: .fingerprint)
        try c.encodeIfPresent(machine, forKey: .machine)
    }
}

/// Result of `guest.remove_device`: the share as it is now.
struct GuestDeviceRemovedResult: Decodable {
    let guest: GuestRecord
}

struct GuestAuditParams: Encodable {
    /// The daemon caps a page at 500 entries.
    static let maxLimit = 500

    let guestID: String?
    let limit: Int
    let beforeMs: UInt64?
    let machine: String?

    enum CodingKeys: String, CodingKey {
        case limit, machine
        case guestID = "guest_id"
        case beforeMs = "before_ms"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(guestID, forKey: .guestID)
        try c.encode(min(max(limit, 1), Self.maxLimit), forKey: .limit)
        try c.encodeIfPresent(beforeMs, forKey: .beforeMs)
        try c.encodeIfPresent(machine, forKey: .machine)
    }
}

struct GuestAuditResult: Decodable {
    let entries: [GuestAuditEntry]
}

/// Sends a setting that the owner can flip faster than the daemon answers (Share Gram per
/// guest), so the daemon always ends on the owner's last choice. One request per key is in
/// flight at a time; flips made meanwhile collapse into the newest value, which is sent when
/// the running request finishes, unless it is already what was sent. Only the call that
/// started the run gets `.finished`, once, after the final value went out; the calls it
/// absorbed get `.queued`.
@MainActor
public final class LatestValueSender<Key: Hashable, Value: Equatable> {
    public enum Outcome: Equatable {
        /// A running request for this key will send the value.
        case queued
        /// The last value went out; `failed` says whether the daemon refused it.
        case finished(failed: Bool)
    }

    private var desired: [Key: Value] = [:]
    private var running: Set<Key> = []

    public init() {}

    /// The value the owner last chose for `key` while it is still being sent; nil when idle.
    public func pending(_ key: Key) -> Value? { desired[key] }

    public func submit(_ value: Value, for key: Key,
                       send: @escaping @MainActor (Value) async throws -> Void) async -> Outcome {
        desired[key] = value
        guard !running.contains(key) else { return .queued }
        running.insert(key)
        defer {
            running.remove(key)
            desired[key] = nil
        }
        var sent: Value?
        var failed = false
        while let next = desired[key], next != sent {
            sent = next
            do {
                try await send(next)
                failed = false
            } catch {
                failed = true
            }
        }
        return .finished(failed: failed)
    }
}
