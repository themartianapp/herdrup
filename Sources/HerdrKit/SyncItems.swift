import Foundation

// The sync wire types (DESIGN §5, AccountService/src/sync.ts). The bodies are their own types,
// built from the allowlisted fields of §5.1 only: they are never Codable wrappers of the app's
// stores, which hold secrets (a host's key or password, pins, invite secrets; §5.4). Each body
// checks what the service checks (§5.5), so one bad change can't refuse a whole push there.

public enum SyncCollection: String, Codable, CaseIterable, Sendable {
    case hosts
    case prompts
    case settings
    case agentPrefs = "agent_prefs"
    case shares
}

/// One synced item's identity: its collection and id.
public struct SyncKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public let collection: SyncCollection
    public let id: String

    public init(_ collection: SyncCollection, _ id: String) {
        self.collection = collection
        self.id = id
    }

    /// A saved host's item (the service takes lowercase UUIDs).
    public static func host(_ id: UUID) -> SyncKey { SyncKey(.hosts, id.uuidString.lowercased()) }
    public static func prompt(_ id: UUID) -> SyncKey { SyncKey(.prompts, id.uuidString.lowercased()) }
    public static func setting(_ key: String) -> SyncKey { SyncKey(.settings, key) }
    /// `<host item id>/<agent key>`.
    public static func agentPref(host: UUID, agent: String) -> SyncKey {
        SyncKey(.agentPrefs, host.uuidString.lowercased() + "/" + agent)
    }
    /// `<host_id>/<guest_id>`.
    public static func share(hostID: String, guestID: String) -> SyncKey { SyncKey(.shares, hostID + "/" + guestID) }

    public var description: String { "\(collection.rawValue)/\(id)" }
}

public enum SyncError: Error, Equatable, Sendable {
    /// A field (or the id) the service would refuse, named as the service names it.
    case invalid(field: String)
    /// The body holds something that looks like a secret (`SyncSecretScan`): never uploaded.
    case secretLike(field: String)
    /// The body is over the service's 16 KB per item.
    case tooLarge
}

// MARK: Bodies

/// A synced setting's value: bool, number or string.
public enum SyncValue: Equatable, Codable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

/// A saved host, without its credential: the key or password stays in this device's
/// Keychain, and a new device shows "Pair this device".
public struct SyncHost: Equatable, Codable, Sendable {
    public enum AuthKind: String, Codable, Sendable {
        case key
        case password
    }

    public var nickname: String?
    public var host: String
    public var port: Int?
    public var username: String
    public var authKind: AuthKind?
    public var label: String?

    public init(nickname: String? = nil, host: String, port: Int? = nil, username: String,
                authKind: AuthKind? = nil, label: String? = nil) {
        self.nickname = nickname
        self.host = host
        self.port = port
        self.username = username
        self.authKind = authKind
        self.label = label
    }

    enum CodingKeys: String, CodingKey {
        case nickname, host, port, username, label
        case authKind = "auth_kind"
    }
}

public struct SyncPrompt: Equatable, Codable, Sendable {
    public var title: String?
    public var text: String
    public var order: Double?

    public init(title: String? = nil, text: String, order: Double? = nil) {
        self.title = title
        self.text = text
        self.order = order
    }
}

/// App-side pins, hides and order of one agent on one saved host.
public struct SyncAgentPref: Equatable, Codable, Sendable {
    public var pinned: Bool?
    public var hidden: Bool?
    public var order: Double?

    public init(pinned: Bool? = nil, hidden: Bool? = nil, order: Double? = nil) {
        self.pinned = pinned
        self.hidden = hidden
        self.order = order
    }
}

/// A share this guest holds (#700): where to reach it and what to show, nothing secret. The
/// invite secret was spent at redemption; `relay` is the relay's base URL, never an invite link.
public struct SyncShare: Equatable, Codable, Sendable {
    public var relay: String
    public var hostID: String
    /// The host's public node key.
    public var nodePub: String
    public var guestID: String
    public var agentName: String?
    public var ownerName: String?
    public var machineLabel: String?
    public var shareGram: Bool?

    public init(relay: String, hostID: String, nodePub: String, guestID: String, agentName: String? = nil,
                ownerName: String? = nil, machineLabel: String? = nil, shareGram: Bool? = nil) {
        self.relay = relay
        self.hostID = hostID
        self.nodePub = nodePub
        self.guestID = guestID
        self.agentName = agentName
        self.ownerName = ownerName
        self.machineLabel = machineLabel
        self.shareGram = shareGram
    }

    enum CodingKeys: String, CodingKey {
        case relay
        case hostID = "host_id"
        case nodePub = "node_pub"
        case guestID = "guest_id"
        case agentName = "agent_name"
        case ownerName = "owner_name"
        case machineLabel = "machine_label"
        case shareGram = "share_gram"
    }
}

/// An item's body; its case fixes the collection.
public enum SyncBody: Equatable, Sendable {
    case host(SyncHost)
    case prompt(SyncPrompt)
    /// The setting's value; the key is the item id.
    case setting(SyncValue)
    case agentPref(SyncAgentPref)
    case share(SyncShare)

    public var collection: SyncCollection {
        switch self {
        case .host: return .hosts
        case .prompt: return .prompts
        case .setting: return .settings
        case .agentPref: return .agentPrefs
        case .share: return .shares
        }
    }

    /// The body's JSON object, from its allowlisted fields only.
    func encode(to container: inout KeyedEncodingContainer<WireKeys>, forKey key: WireKeys) throws {
        switch self {
        case .host(let body): try container.encode(body, forKey: key)
        case .prompt(let body): try container.encode(body, forKey: key)
        case .setting(let value): try container.encode(SettingBody(value: value), forKey: key)
        case .agentPref(let body): try container.encode(body, forKey: key)
        case .share(let body): try container.encode(body, forKey: key)
        }
    }

    static func decode(_ collection: SyncCollection, from container: KeyedDecodingContainer<WireKeys>,
                       forKey key: WireKeys) throws -> SyncBody {
        switch collection {
        case .hosts: return .host(try container.decode(SyncHost.self, forKey: key))
        case .prompts: return .prompt(try container.decode(SyncPrompt.self, forKey: key))
        case .settings: return .setting(try container.decode(SettingBody.self, forKey: key).value)
        case .agentPrefs: return .agentPref(try container.decode(SyncAgentPref.self, forKey: key))
        case .shares: return .share(try container.decode(SyncShare.self, forKey: key))
        }
    }

    /// The body as the JSON a push carries.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        switch self {
        case .host(let body): return try encoder.encode(body)
        case .prompt(let body): return try encoder.encode(body)
        case .setting(let value): return try encoder.encode(SettingBody(value: value))
        case .agentPref(let body): return try encoder.encode(body)
        case .share(let body): return try encoder.encode(body)
        }
    }

    private struct SettingBody: Codable {
        let value: SyncValue
    }
}

enum WireKeys: String, CodingKey {
    case collection, id, rev, deleted, body
    case updatedMs = "updated_ms"
    case baseRev = "base_rev"
}

// MARK: Items and changes

/// An item as the service holds it: `{collection, id, rev, updated_ms, deleted, body}`.
/// A tombstone has `deleted` and no body.
public struct SyncItem: Equatable, Codable, Sendable {
    public let key: SyncKey
    public let rev: Int
    public let updatedMs: Int
    public let body: SyncBody?

    public var deleted: Bool { body == nil }

    public init(key: SyncKey, rev: Int, updatedMs: Int, body: SyncBody?) {
        self.key = key
        self.rev = rev
        self.updatedMs = updatedMs
        self.body = body
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKeys.self)
        let collection = try container.decode(SyncCollection.self, forKey: .collection)
        key = SyncKey(collection, try container.decode(String.self, forKey: .id))
        rev = try container.decode(Int.self, forKey: .rev)
        updatedMs = try container.decode(Int.self, forKey: .updatedMs)
        let deleted = try container.decode(Bool.self, forKey: .deleted)
        body = deleted ? nil : try SyncBody.decode(collection, from: container, forKey: .body)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKeys.self)
        try container.encode(key.collection, forKey: .collection)
        try container.encode(key.id, forKey: .id)
        try container.encode(rev, forKey: .rev)
        try container.encode(updatedMs, forKey: .updatedMs)
        try container.encode(deleted, forKey: .deleted)
        if let body { try body.encode(to: &container, forKey: .body) } else { try container.encodeNil(forKey: .body) }
    }
}

/// One change of a push: `{collection, id, base_rev?, deleted?, body?}`. Build it with
/// `upsert` or `delete`, which check it as the service would and refuse anything secret-like.
public struct SyncChange: Equatable, Codable, Sendable {
    public let key: SyncKey
    /// The revision the edit started from (0: create only). nil for background pushes: the
    /// last write to reach the service wins. A mismatch comes back as a conflict.
    public let baseRev: Int?
    public let body: SyncBody?

    public var deleted: Bool { body == nil }

    /// The service's limit on one item's body.
    public static let maxBodyBytes = 16 * 1024

    public static func upsert(_ key: SyncKey, _ body: SyncBody, baseRev: Int? = nil) throws -> SyncChange {
        let change = SyncChange(key: key, baseRev: baseRev, body: body)
        try change.validate()
        return change
    }

    public static func delete(_ key: SyncKey, baseRev: Int? = nil) throws -> SyncChange {
        let change = SyncChange(key: key, baseRev: baseRev, body: nil)
        try change.validate()
        return change
    }

    /// Checks the change as the service would and refuses a secret-like body (§5.4). Every way
    /// into the push queue goes through this: `upsert`, `delete`, `SyncEngine.stage`, and the
    /// queue itself before each push (a decoded or stored change was never checked).
    public func validate() throws {
        guard let body else { return try SyncValidation.check(key: key, body: nil) }
        guard body.collection == key.collection else { throw SyncError.invalid(field: "collection") }
        let json = try body.jsonData()
        // Secrets first: a key pasted into a nickname is refused as a secret, not as too long.
        if let finding = SyncSecretScan.findings(inBody: json).first { throw SyncError.secretLike(field: finding.field) }
        try SyncValidation.check(key: key, body: body)
        guard json.count <= Self.maxBodyBytes else { throw SyncError.tooLarge }
    }

    private init(key: SyncKey, baseRev: Int?, body: SyncBody?) {
        self.key = key
        self.baseRev = baseRev
        self.body = body
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKeys.self)
        let collection = try container.decode(SyncCollection.self, forKey: .collection)
        key = SyncKey(collection, try container.decode(String.self, forKey: .id))
        baseRev = try container.decodeIfPresent(Int.self, forKey: .baseRev)
        let deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        body = deleted ? nil : try SyncBody.decode(collection, from: container, forKey: .body)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireKeys.self)
        try container.encode(key.collection, forKey: .collection)
        try container.encode(key.id, forKey: .id)
        try container.encodeIfPresent(baseRev, forKey: .baseRev)
        if let body { try body.encode(to: &container, forKey: .body) } else { try container.encode(true, forKey: .deleted) }
    }
}

// MARK: Answers

/// `GET /v1/sync`'s answer. Items of a collection this build doesn't know are skipped.
public struct SyncPage: Decodable, Sendable {
    public let rev: Int
    public let changes: [SyncItem]
    public let more: Bool
    public let cursor: String?

    enum CodingKeys: String, CodingKey {
        case rev, changes, more, cursor
    }

    public init(rev: Int, changes: [SyncItem], more: Bool, cursor: String?) {
        self.rev = rev
        self.changes = changes
        self.more = more
        self.cursor = cursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rev = try container.decode(Int.self, forKey: .rev)
        more = try container.decode(Bool.self, forKey: .more)
        cursor = try container.decodeIfPresent(String.self, forKey: .cursor)
        var list = try container.nestedUnkeyedContainer(forKey: .changes)
        var changes: [SyncItem] = []
        while !list.isAtEnd {
            let probe = try list.decode(CollectionProbe.self)
            guard probe.known else { continue }
            changes.append(probe.item!)
        }
        self.changes = changes
    }

    /// Decodes one entry, skipping it when its collection is newer than this build.
    private struct CollectionProbe: Decodable {
        let item: SyncItem?
        var known: Bool { item != nil }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: WireKeys.self)
            let raw = try container.decode(String.self, forKey: .collection)
            item = SyncCollection(rawValue: raw) == nil ? nil : try SyncItem(from: decoder)
        }
    }
}

/// `POST /v1/sync`'s answer.
public struct SyncPushResult: Decodable, Sendable {
    public struct Applied: Decodable, Equatable, Sendable {
        public let collection: SyncCollection
        public let id: String
        /// 0 when a delete found nothing to delete.
        public let rev: Int
        public var key: SyncKey { SyncKey(collection, id) }
    }

    public struct Conflict: Decodable, Sendable {
        public let collection: SyncCollection
        public let id: String
        /// The service's copy (perhaps a tombstone), or nil when it holds none.
        public let server: SyncItem?
        public var key: SyncKey { SyncKey(collection, id) }
    }

    public let rev: Int
    public let applied: [Applied]
    public let conflicts: [Conflict]
}

// MARK: Validation (AccountService/src/sync.ts SCHEMAS, DESIGN §5.5)

enum SyncValidation {
    /// Synced settings and their values; every other key stays on the device.
    static func settingIsValid(key: String, value: SyncValue) -> Bool? {
        switch key {
        case "terminal.fontSize", "guest.terminal.fontSize", "chat.fontSize":
            if case .number(let n) = value { return n >= 6 && n <= 72 }
            return false
        case "ui.fontScale":
            if case .number(let n) = value { return n >= 0.5 && n <= 3 }
            return false
        case "ui.theme":
            if case .string(let s) = value { return ["system", "light", "dark"].contains(s) }
            return false
        case "guest.ownerName":
            if case .string(let s) = value { return text(s, max: 64) }
            return false
        default:
            guard isNotifyKey(key) else { return nil }
            if case .bool = value { return true }
            return false
        }
    }

    static func isSyncedSetting(_ key: String) -> Bool {
        settingIsValid(key: key, value: .bool(false)) != nil
    }

    static func check(key: SyncKey, body: SyncBody?) throws {
        guard isValidID(key) else { throw SyncError.invalid(field: "id") }
        guard let body else { return }
        switch body {
        case .host(let host):
            try field("nickname", host.nickname.map { text($0, max: 64) })
            try field("host", text(host.host, max: 253) && !host.host.isEmpty
                      && !host.host.unicodeScalars.contains(where: { $0.properties.isWhitespace }))
            try field("port", host.port.map { (1...65535).contains($0) })
            try field("username", text(host.username, max: 64) && !host.username.isEmpty)
            try field("label", host.label.map { text($0, max: 64) })
        case .prompt(let prompt):
            try field("title", prompt.title.map { text($0, max: 128) })
            try field("text", !prompt.text.isEmpty && prompt.text.utf8.count <= 8192 && noControls(prompt.text, lines: true))
            try field("order", prompt.order.map(isOrder))
        case .setting(let value):
            try field("value", settingIsValid(key: key.id, value: value) == true)
        case .agentPref(let pref):
            try field("order", pref.order.map(isOrder))
        case .share(let share):
            let parts = key.id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            try field("relay", isRelayBase(share.relay))
            try field("host_id", isB64(share.hostID, count: 22) && share.hostID == parts.first)
            try field("node_pub", isB64(share.nodePub, count: 43))
            try field("guest_id", isB64(share.guestID, count: 22) && share.guestID == parts.last)
            try field("agent_name", share.agentName.map { text($0, max: 128) })
            try field("owner_name", share.ownerName.map { text($0, max: 64) })
            try field("machine_label", share.machineLabel.map { text($0, max: 128) })
        }
    }

    private static func field(_ name: String, _ valid: Bool?) throws {
        if valid == false { throw SyncError.invalid(field: name) }
    }

    static func isValidID(_ key: SyncKey) -> Bool {
        switch key.collection {
        case .hosts, .prompts:
            return isLowercaseUUID(key.id)
        case .settings:
            return isSyncedSetting(key.id)
        case .agentPrefs:
            guard let slash = key.id.firstIndex(of: "/") else { return false }
            let agent = String(key.id[key.id.index(after: slash)...])
            return isLowercaseUUID(String(key.id[..<slash])) && !agent.isEmpty && text(agent, max: 128)
        case .shares:
            let parts = key.id.split(separator: "/", omittingEmptySubsequences: false)
            return parts.count == 2 && parts.allSatisfy { isB64(String($0), count: 22) }
        }
    }

    static func isLowercaseUUID(_ text: String) -> Bool {
        UUID(uuidString: text) != nil && text == text.lowercased() && text.count == 36
    }

    static func isB64(_ text: String, count: Int) -> Bool {
        text.utf8.count == count && text.utf8.allSatisfy(isB64Byte)
    }

    static func isB64Byte(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
            || byte == 0x2D || byte == 0x5F
    }

    /// At most `max` code points, no control characters.
    static func text(_ value: String, max: Int) -> Bool {
        value.unicodeScalars.count <= max && noControls(value, lines: false)
    }

    static func noControls(_ value: String, lines: Bool) -> Bool {
        !value.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .control && !(lines && ["\t", "\n", "\r"].contains(scalar))
        }
    }

    static func isOrder(_ value: Double) -> Bool {
        value.isFinite && abs(value) <= 9_007_199_254_740_991
    }

    /// `notify.<name>`: a lowercase letter, then at most 47 letters or digits.
    static func isNotifyKey(_ key: String) -> Bool {
        guard key.hasPrefix("notify.") else { return false }
        let name = Array(key.utf8.dropFirst("notify.".count))
        guard let first = name.first, first >= 0x61 && first <= 0x7A, name.count <= 48 else { return false }
        return name.allSatisfy { ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) }
    }

    /// A relay's base URL: http(s), no credentials, query or fragment, and no segment of the
    /// resolved path that is (or decodes to) `i`, so an invite link can't ride in it. Dot
    /// segments are resolved first, as sync.ts (WHATWG URL) does, so `/x/../i/…` is refused and
    /// `/foo/../bar` is fine.
    static func isRelayBase(_ value: String) -> Bool {
        guard value.count <= 256, !value.contains(where: { $0.isWhitespace || $0 == "?" || $0 == "#" || $0 == "\\" }),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              components.host?.isEmpty == false, components.user == nil, components.password == nil
        else { return false }
        var resolved: [String] = []
        for segment in components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).dropFirst() {
            switch segment.lowercased() {
            case ".", "%2e": continue
            case "..", ".%2e", "%2e.", "%2e%2e": _ = resolved.popLast()
            default: resolved.append(String(segment))
            }
        }
        for segment in resolved {
            guard let decoded = segment.removingPercentEncoding else { return false }
            if decoded == "i" { return false }
        }
        return true
    }
}
