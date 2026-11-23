import Foundation

// Web owner access, the approving device's side (WIRE-PLAN §2, as HerdrUp Desktop D1 runs it in
// `app/desk_web_access.go`): a browser signed in to the account asks to reach the owner's
// machines; this device shows the request, the user types the browser's 4-digit code, picks
// machines, access and time, and this device adds a grant on each machine over SSH
// (`owner_access.add`, one session per machine) and seals the machine list to the browser. The
// account service carries the request and the sealed list; it can't grant anything itself.
//
// Grants exist only for a recorded approval: they are made after the service confirms the
// request is still open, and removed again when the service definitely didn't record the
// approval. When that can't be told (no answer), the grants stay and Approve retries the same
// report.

// MARK: owner_access (herdr, protocol 2)

/// `owner_access.info`: the machine's relay identity, created on first use.
public struct OwnerAccessInfo: Decodable, Equatable, Sendable {
    /// 1 stores grants (herdr H1); 2 admits owner browsers (H2). Nil from a herdr that predates
    /// the field.
    public let `protocol`: Int?
    /// The relay's id for this machine, unpadded base64url of 16 bytes.
    public let hostID: String
    /// The machine's X25519 Noise key, unpadded base64url of 32 bytes.
    public let nodePub: String
    public let relayURL: String
    public let version: String?

    enum CodingKeys: String, CodingKey {
        case `protocol`, version
        case hostID = "host_id"
        case nodePub = "node_pub"
        case relayURL = "relay_url"
    }
}

/// One owner grant as herdr reports it. The account it is bound to is never shown.
public struct OwnerGrant: Decodable, Equatable, Sendable {
    public let grantID: String
    public let devicePub: String
    /// "chat" or "terminal".
    public let scope: String
    /// Unix milliseconds, from the machine's own clock.
    public let expiresMs: UInt64

    enum CodingKeys: String, CodingKey {
        case scope
        case grantID = "grant_id"
        case devicePub = "device_pub"
        case expiresMs = "expires_ms"
    }
}

/// `owner_access.add`'s answer.
public struct OwnerAccessAdded: Decodable, Equatable, Sendable {
    public let grant: OwnerGrant
    /// Grants for the same key this one replaced (now revoked).
    public let replaced: [String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        grant = try c.decode(OwnerGrant.self, forKey: .grant)
        replaced = try c.decodeIfPresent([String].self, forKey: .replaced) ?? []
    }

    enum CodingKeys: String, CodingKey { case grant, replaced }
}

struct OwnerAccessInfoParams: Encodable {
    func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: CodingKeys.self)
    }

    enum CodingKeys: CodingKey {}
}

struct OwnerAccessAddParams: Encodable {
    let devicePub: String
    let deviceName: String
    let scope: String
    let ttlSecs: UInt64
    let accountStatement: String
    let approvedBy: String

    enum CodingKeys: String, CodingKey {
        case scope
        case devicePub = "device_pub"
        case deviceName = "device_name"
        case ttlSecs = "ttl_secs"
        case accountStatement = "account_statement"
        case approvedBy = "approved_by"
    }
}

struct OwnerAccessRemoveParams: Encodable {
    let grantID: String

    enum CodingKeys: String, CodingKey { case grantID = "grant_id" }
}

struct OwnerAccessRemoved: Decodable {
    let removed: [String]
}

// MARK: Choices

/// What a browser may do on the machines (owner decision: "Chat and terminal" by default).
public enum WebAccessScope: String, CaseIterable, Sendable {
    case terminal
    case chat

    public var label: String { self == .terminal ? "Chat and terminal" : "Chat only" }
}

/// How long the access lasts (owner decision: 30 days at most).
public enum WebAccessLength: Int, CaseIterable, Sendable {
    case oneDay = 1
    case sevenDays = 7
    case thirtyDays = 30

    public var seconds: UInt64 { UInt64(rawValue) * 86_400 }
    public var label: String { self == .oneDay ? "1 day" : "\(rawValue) days" }
}

/// The relay origins the web app reaches (HerdrUp Desktop `internal/webrelay/relays.json`, and
/// the CSP `connect-src` in GuestRelay/public/_headers). A machine on any other relay is skipped
/// as `relay_not_allowed`: the page couldn't reach it.
public enum WebRelays {
    public static let origins = ["https://guest.herdrup.app", "https://guest.herdrup.themartian.app"]

    public static func allowed(_ relay: String) -> Bool {
        origins.contains(trimSlash(relay))
    }

    static func trimSlash(_ text: String) -> String {
        var text = text
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

// MARK: Machines

/// A herdr owner connection to one machine, opened for the approval and closed after it.
public struct OwnerAccessLink: Sendable {
    public let client: HerdrClient
    public let close: @Sendable () async -> Void

    public init(client: HerdrClient, close: @escaping @Sendable () async -> Void) {
        self.client = client
        self.close = close
    }
}

/// One machine the sheet offers.
public struct WebAccessMachine: Identifiable, Sendable {
    public let id: String
    public let label: String
    /// The machine's id in the account's `hosts` collection ("" when it isn't synced).
    public let hostItemID: String
    /// Opens a session to the machine (its own SSH session; WIRE-PLAN clarification 22 Nov).
    public let open: @Sendable () async throws -> OwnerAccessLink

    public init(id: String, label: String, hostItemID: String,
                open: @escaping @Sendable () async throws -> OwnerAccessLink) {
        self.id = id
        self.label = label
        self.hostItemID = hostItemID
        self.open = open
    }
}

/// What an approval did on each machine.
public struct WebAccessResult: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        public let label: String
        /// For a skip, the reason the browser sees (`needs_update`, `unsupported`, `unreachable`,
        /// `relay_not_allowed`); for a failure, the error.
        public let reason: String
    }

    public var granted: [String] = []
    public var skipped: [Line] = []
    public var failed: [Line] = []
    /// The service's answer to the approval was lost (`problem` says how): the grants are kept,
    /// Approve sends the same report again and Deny removes them.
    public var unsure = false
    public var problem: String?

    public init() {}

    /// A skip reason as the sheet words it.
    public static func describe(skip reason: String) -> String {
        switch reason {
        case "needs_update": return "needs a herdr update"
        case "unsupported": return "can't share with the web"
        case "unreachable": return "couldn't be reached"
        case "relay_not_allowed": return "uses a relay the web app can't reach"
        default: return reason
        }
    }
}

// MARK: Envelope seq

/// The highest envelope seq this device used, per device key.
public struct WebAccessSeq: Codable, Equatable, Sendable {
    public let approver: String
    public let seq: UInt64

    public init(approver: String, seq: UInt64) {
        self.approver = approver
        self.seq = seq
    }
}

/// Where the last envelope seq lives, so a new one is above it after a restart.
public protocol WebAccessSeqStore: Sendable {
    func load() throws -> WebAccessSeq?
    func save(_ seq: WebAccessSeq) throws
}

public final class InMemoryWebAccessSeqStore: WebAccessSeqStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: WebAccessSeq?

    public init(_ value: WebAccessSeq? = nil) { self.value = value }

    public func load() throws -> WebAccessSeq? { lock.withLock { value } }
    public func save(_ seq: WebAccessSeq) throws { lock.withLock { value = seq } }
}

public final class UserDefaultsWebAccessSeqStore: WebAccessSeqStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "webAccess.seq.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() throws -> WebAccessSeq? {
        try defaults.data(forKey: key).map { try JSONDecoder().decode(WebAccessSeq.self, from: $0) }
    }

    public func save(_ seq: WebAccessSeq) throws {
        defaults.set(try JSONEncoder().encode(seq), forKey: key)
    }
}

// MARK: The approval

/// One browser approval with its machines: the code, the grants, the report, and denying.
/// One step at a time (`busy`).
public actor WebAccessApproval {
    public enum Failure: Error, Equatable, Sendable {
        case busy
        case noMachines
        /// The sealed list for these machines wouldn't fit what the service takes.
        case tooManyMachines
        /// Deny after the service already recorded the approval.
        case alreadyApproved
        case timedOut
        /// A step that didn't complete; the text says what and what to do.
        case problem(String)
    }

    /// How long one machine's grant may take (SSH, info, statement, add); a machine is started
    /// only with that much time left before the report must go. `reportTime` is kept for the
    /// report.
    public static let grantTime: TimeInterval = 30
    public static let reportTime: TimeInterval = 30
    /// The `owner_access` protocol of a machine that admits owner browsers (herdr H2). 1 only
    /// stores grants: a grant there couldn't let the browser in.
    public static let ownerProtocol = 2

    struct Grant: Sendable {
        let machine: WebAccessMachine
        let grantID: String
    }

    struct Pending: Sendable {
        let scope: String
        let expiresMs: Int64
        let seq: UInt64
        let envelope: Data
        var grants: [Grant]
        let result: WebAccessResult
    }

    struct Envelope: Encodable {
        let v = 1
        let seq: UInt64
        let issuedUnix: Int64
        let approver: String
        var machines: [Machine] = []
        var skipped: [Skipped] = []

        struct Machine: Encodable {
            let hostItemID: String
            let label: String
            let relay: String
            let hostID: String
            let nodePub: String
            let grantID: String
            let scope: String
            let expiresUnix: Int64

            enum CodingKeys: String, CodingKey {
                case label, relay, scope
                case hostItemID = "host_item_id"
                case hostID = "host_id"
                case nodePub = "node_pub"
                case grantID = "grant_id"
                case expiresUnix = "expires_unix"
            }
        }

        struct Skipped: Encodable {
            let hostItemID: String
            let label: String
            let reason: String
            let version: String?

            enum CodingKeys: String, CodingKey {
                case label, reason, version
                case hostItemID = "host_item_id"
            }
        }

        enum CodingKeys: String, CodingKey {
            case v, seq, approver, machines, skipped
            case issuedUnix = "issued_unix"
        }

        func json() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return try encoder.encode(self)
        }
    }

    enum GrantOutcome {
        case granted(Envelope.Machine)
        case skipped(String, version: String?)
        case failed(String)
    }

    public nonisolated let approval: BrowserApproval
    private let approverName: String
    private let statement: @Sendable (String) async throws -> String
    private let seqStore: WebAccessSeqStore
    private let now: @Sendable () -> Date
    private let grantTime: TimeInterval
    private let reportTime: TimeInterval
    private var busy = false
    /// A report sent without a known outcome, and the grants it carries.
    private var pending: Pending?

    /// `statement` is this device's account statement (JWS) for a host id (`StatementCache`).
    public init(approval: BrowserApproval, approverName: String,
                statement: @escaping @Sendable (String) async throws -> String,
                seqStore: WebAccessSeqStore, now: @escaping @Sendable () -> Date = { Date() },
                grantTime: TimeInterval = WebAccessApproval.grantTime,
                reportTime: TimeInterval = WebAccessApproval.reportTime) {
        self.approval = approval
        self.approverName = Self.truncate(approverName, 64)
        self.statement = statement
        self.seqStore = seqStore
        self.now = now
        self.grantTime = grantTime
        self.reportTime = reportTime
    }

    /// Whether an approval's report is waiting on an unknown outcome (its grants stand).
    public var reportPending: Bool { pending != nil }

    /// Compares the code the user typed.
    public func checkCode(_ typed: String) async throws -> BrowserApproval.CodeCheck {
        try begin()
        defer { busy = false }
        return try await approval.checkCode(typed)
    }

    /// Adds a grant for the browser on each of `machines` and sends it the sealed list.
    /// Machines that fail are reported, not fatal; with none granted the request stays open so
    /// the user can retry or deny. After a lost answer it sends the same report again, whatever
    /// was chosen.
    public func approve(machines: [WebAccessMachine], scope: WebAccessScope,
                        length: WebAccessLength) async throws -> WebAccessResult {
        try begin()
        defer { busy = false }
        if let pending { return try await report(pending) }
        // No grant on any machine before the user typed the browser's code.
        try await approval.ready()
        guard !machines.isEmpty else { throw Failure.noMachines }
        guard Self.fits(machines, approver: approverName) else { throw Failure.tooManyMachines }
        // The request must still be open, with time to grant and report, before any machine
        // changes: a grant the service then can't record would be access nobody approved.
        let deadline = try await approval.live(min: grantTime + reportTime)
        let reportBy = deadline.addingTimeInterval(-reportTime)
        let seq = try nextSeq()
        var envelope = Envelope(seq: seq, issuedUnix: Int64(now().timeIntervalSince1970), approver: approverName)
        let expires = now().addingTimeInterval(TimeInterval(length.seconds))
        var result = WebAccessResult()
        var grants: [Grant] = []
        let browser = approval.request.browser
        for machine in machines {
            let left = reportBy.timeIntervalSince(now())
            guard left >= grantTime else {
                result.failed.append(.init(label: machine.label, reason: "not reached before this request expires"))
                continue
            }
            let params = OwnerAccessAddParams(
                devicePub: browser.devicePub, deviceName: Self.truncate(browser.name, 64), scope: scope.rawValue,
                ttlSecs: length.seconds, accountStatement: "", approvedBy: approverName)
            switch await grant(on: machine, params, within: min(grantTime, left)) {
            case .failed(let reason):
                result.failed.append(.init(label: machine.label, reason: reason))
            case .skipped(let reason, let version):
                result.skipped.append(.init(label: machine.label, reason: reason))
                envelope.skipped.append(.init(hostItemID: machine.hostItemID, label: machine.label, reason: reason, version: version))
            case .granted(let entry):
                result.granted.append(machine.label)
                envelope.machines.append(entry)
                grants.append(Grant(machine: machine, grantID: entry.grantID))
            }
        }
        guard !envelope.machines.isEmpty else { return result }
        return try await report(Pending(scope: scope.rawValue, expiresMs: Int64(expires.timeIntervalSince1970 * 1000),
                                        seq: seq, envelope: try envelope.json(), grants: grants, result: result))
    }

    /// Denies the request. Returns only once the service took the denial (or the request was
    /// already over); on an error the sheet keeps the request so Deny can be tried again.
    /// Grants waiting on a report with no known outcome are removed once this denial was taken,
    /// or once the service shows the request ended with no report of this device recorded.
    public func deny() async throws {
        try begin()
        defer { busy = false }
        var ended = false
        do {
            try await approval.deny()
        } catch BrowserApproval.Failure.ended {
            ended = true
        } catch {
            throw Failure.problem("Couldn't deny (\(BrowserApproval.describe(error))). Deny to try again.")
        }
        guard var pending else { return }
        // Taken by the service, the denial is the outcome. Otherwise the request was over
        // before it, and only the service knows how.
        if ended {
            let read: (ApprovalStatus.State, Bool)
            do {
                read = try await approval.outcome()
            } catch {
                throw Failure.problem("Couldn't tell whether the browser was approved (\(BrowserApproval.describe(error))). Deny to try again.")
            }
            switch read {
            case (.approved, _):
                self.pending = nil
                throw Failure.alreadyApproved
            case (.expired, false):
                throw Failure.problem("The request expired while a report's outcome was unknown, and the account service may never say how it ended. Unless it does, the access added on \(Self.labels(pending.grants)) stays until it expires there or is removed on those machines. Deny only checks again.")
            case (let state, false):
                throw Failure.problem("The request is still \(state.rawValue). Deny to try again.")
            default:
                break
            }
        }
        // The ones that couldn't be removed stay pending for the next Deny.
        pending.grants = await removeGrants(pending.grants)
        guard pending.grants.isEmpty else {
            self.pending = pending
            throw Failure.problem("Denied, but couldn't remove the access added on \(Self.labels(pending.grants)). Deny to try again.")
        }
        self.pending = nil
    }

    // MARK: Steps

    private func begin() throws {
        guard !busy else { throw Failure.busy }
        busy = true
    }

    /// Sends the approval with its grants. Recorded: done. Definitely not recorded: the grants
    /// are removed and the reason thrown. Unknown: the grants stay, the report is kept for the
    /// next Approve or Deny, and the result says `unsure`.
    private func report(_ p: Pending) async throws -> WebAccessResult {
        var result = p.result
        do {
            try await approval.approve(scope: p.scope, expiresMs: p.expiresMs, seq: p.seq, envelope: p.envelope)
            pending = nil
            return result
        } catch let refused as BrowserApproval.NotRecorded {
            pending = nil
            let why = BrowserApproval.describe(refused)
            let failed = await removeGrants(p.grants)
            if !failed.isEmpty {
                throw Failure.problem("The browser wasn't approved (\(why)), and the access added on \(Self.labels(failed)) couldn't be removed.")
            }
            throw Failure.problem("The browser wasn't approved: \(why)")
        } catch {
            pending = p
            result.unsure = true
            result.problem = BrowserApproval.describe(error)
            return result
        }
    }

    /// The grant on one machine: `owner_access.info` for its relay id, a statement for that
    /// host, then `owner_access.add`. A machine that can't take owner grants is skipped with
    /// the envelope's reason.
    private func grant(on machine: WebAccessMachine, _ params: OwnerAccessAddParams,
                       within seconds: TimeInterval) async -> GrantOutcome {
        let statement = self.statement
        do {
            return try await Self.withTimeout(seconds) {
                let link: OwnerAccessLink
                do {
                    link = try await machine.open()
                } catch {
                    return .skipped("unreachable", version: nil)
                }
                do {
                    let outcome = try await Self.grant(on: machine, link.client, params, statement: statement)
                    await link.close()
                    return outcome
                } catch {
                    await link.close()
                    throw error
                }
            }
        } catch Failure.timedOut {
            return .failed("timed out")
        } catch {
            return .failed(Self.describe(error))
        }
    }

    private static func grant(on machine: WebAccessMachine, _ client: HerdrClient, _ params: OwnerAccessAddParams,
                              statement: @Sendable (String) async throws -> String) async throws -> GrantOutcome {
        let info: OwnerAccessInfo
        do {
            info = try await client.ownerAccessInfo()
        } catch let error as APIError where HerdrClient.isUnknownMethod(error, "owner_access.info") {
            return .skipped("needs_update", version: nil)
        } catch let error as APIError where error.code == "owner_access_unsupported" {
            return .skipped("unsupported", version: nil)
        }
        guard let version = info.protocol, version >= ownerProtocol else {
            return .skipped("needs_update", version: info.version)
        }
        guard WebRelays.allowed(info.relayURL) else { return .skipped("relay_not_allowed", version: info.version) }
        let jws = try await statement(info.hostID)
        let added = try await client.ownerAccessAdd(
            devicePub: params.devicePub, deviceName: params.deviceName, scope: params.scope, ttlSecs: params.ttlSecs,
            accountStatement: jws, approvedBy: params.approvedBy)
        return .granted(Envelope.Machine(
            hostItemID: machine.hostItemID, label: machine.label, relay: WebRelays.trimSlash(info.relayURL),
            hostID: info.hostID, nodePub: info.nodePub, grantID: added.grant.grantID, scope: added.grant.scope,
            expiresUnix: Int64(added.grant.expiresMs / 1000)))
    }

    /// Removes grants made for an approval that wasn't recorded; returns the ones it couldn't.
    private func removeGrants(_ grants: [Grant]) async -> [Grant] {
        var failed: [Grant] = []
        for grant in grants {
            do {
                try await Self.withTimeout(grantTime) {
                    let link = try await grant.machine.open()
                    do {
                        _ = try await link.client.ownerAccessRemove(grantID: grant.grantID)
                    } catch {
                        await link.close()
                        throw error
                    }
                    await link.close()
                }
            } catch {
                failed.append(grant)
            }
        }
        return failed
    }

    /// The next envelope seq: the clock in milliseconds, above any seq this key used before,
    /// saved before it is used. The service keeps the highest seq per browser and approver and
    /// refuses one not above it; this device can't read that value, so each report takes a
    /// fresh, larger one, also after a restart and a clock set back.
    private func nextSeq() throws -> UInt64 {
        let key = Base64URL.encode(approval.approverPub)
        let stored = try seqStore.load()
        let last = stored?.approver == key ? stored?.seq ?? 0 : 0
        let next = max(UInt64(max(0, now().timeIntervalSince1970 * 1000)), last + 1)
        try seqStore.save(WebAccessSeq(approver: key, seq: next))
        return next
    }

    // MARK: Helpers

    /// Whether the sealed list for `machines` fits what the service takes, each counted as
    /// granted with every field at its longest.
    static func fits(_ machines: [WebAccessMachine], approver: String) -> Bool {
        let relay = WebRelays.origins.max { $0.count < $1.count } ?? ""
        var envelope = Envelope(seq: .max, issuedUnix: .max, approver: approver)
        envelope.machines = machines.map {
            Envelope.Machine(hostItemID: $0.hostItemID, label: $0.label, relay: relay,
                             hostID: String(repeating: "h", count: 22), nodePub: String(repeating: "n", count: 43),
                             grantID: String(repeating: "g", count: 22), scope: "terminal", expiresUnix: .max)
        }
        guard let plain = try? envelope.json() else { return false }
        return ApproveV1.sealedLength(plain.count) <= ApproveV1.maxSealedLength
    }

    static func truncate(_ text: String, _ count: Int) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(count))
    }

    static func labels(_ grants: [Grant]) -> String {
        grants.map(\.machine.label).joined(separator: ", ")
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let error as APIError: return error.message.isEmpty ? error.code : "\(error.code): \(error.message)"
        case StatementCache.Failure.missingStatement: return "the account service gave no statement for this machine"
        default: return BrowserApproval.describe(error)
        }
    }

    static func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                                         _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw Failure.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Failure.timedOut }
            return first
        }
    }
}
