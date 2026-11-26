import Crypto
import Foundation

// Pairing another device (pair-v1, DESIGN §13), the approver's side: claim the request with
// `nonce_t`, wait for the new device's reveal, check the code the user types, add the new
// device's SSH key S on each ticked machine over this device's own connection
// (`pair.add_key`), then seal the machines to it and finish. A machine that failed can be
// tried again: a new envelope with a higher seq replaces the first (`PUT …/envelope`).

/// One pair request as this device approves it.
public actor PairApproval {
    /// How many wrong codes are accepted before the request is denied.
    public static let maxCodeTries = BrowserApproval.maxCodeTries

    public nonisolated let request: PairRequest
    /// This device's key (T).
    public nonisolated let approverPub: Data
    /// When the request expires, as read at claim time.
    public nonisolated let expires: Date
    /// S as `pair.add_key` takes it: "ssh-ed25519 AAAA…".
    public nonisolated let publicKeyLine: String

    nonisolated let requesterPub: Data
    nonisolated let sshPub: Data
    private let identity: GuestIdentity
    private let session: AccountSession
    private let commit: Data
    private let nonceT: Data
    private let now: @Sendable () -> Date
    private let poll: @Sendable (TimeInterval) -> TimeInterval

    private var code: String?
    private var tries = 0
    private var matched = false
    private var locked = false
    private var done = false
    private var denied = false
    /// The seq of the last envelope the service took; 0 before the finish.
    private var seq: UInt64 = 0
    /// A finish whose outcome is unknown was sent.
    private var unsure = false

    init(request: PairRequest, identity: GuestIdentity, session: AccountSession, requesterPub: Data, sshPub: Data,
         publicKeyLine: String, commit: Data, nonceT: Data, now: @escaping @Sendable () -> Date,
         poll: @escaping @Sendable (TimeInterval) -> TimeInterval) {
        self.request = request
        self.identity = identity
        self.session = session
        self.requesterPub = requesterPub
        self.sshPub = sshPub
        self.publicKeyLine = publicKeyLine
        self.commit = commit
        self.nonceT = nonceT
        self.now = now
        self.poll = poll
        approverPub = identity.publicKey
        expires = now().addingTimeInterval(TimeInterval(request.expiresIn))
    }

    /// The devices of this account waiting to be paired.
    public static func pending(session: AccountSession) async throws -> [PairRequest] {
        let client = session.client
        return try await session.authorized { try await client.pairRequests(accessToken: $0) }
    }

    /// The pair request a push named. Throws `.ended` when it is over or isn't a pair request.
    public static func load(session: AccountSession, id: String) async throws -> PairRequest {
        let client = session.client
        let status: ApprovalStatus
        do {
            status = try await session.authorized { try await client.approvalState(id: id, accessToken: $0) }
        } catch let error as AccountError where BrowserApproval.gone(error) {
            throw BrowserApproval.Failure.ended
        }
        guard let request = PairRequest(id: id, status: status), status.state == .waiting else {
            throw BrowserApproval.Failure.ended
        }
        return request
    }

    /// Claims `request` for this device. The keys and commit are the ones in `request`, read
    /// before `nonce_t` exists.
    public static func start(session: AccountSession, identity: GuestIdentity, request: PairRequest,
                             now: @escaping @Sendable () -> Date = { Date() },
                             poll: @escaping @Sendable (TimeInterval) -> TimeInterval = BrowserApproval.defaultPoll)
        async throws -> PairApproval {
        guard let requesterPub = Base64URL.decode(request.device.devicePub), requesterPub.count == ApproveV1.keySize,
              let sshPub = Base64URL.decode(request.sshPub), sshPub.count == ApproveV1.keySize,
              let line = PairingKey.publicKeyLine(raw: sshPub),
              let commit = Base64URL.decode(request.commit), commit.count == SHA256.byteCount
        else { throw BrowserApproval.Failure.tampered }
        let nonceT = ApproveV1.newNonce()
        let client = session.client
        do {
            try await session.authorized { try await client.claimApproval(id: request.id, nonceT: nonceT, accessToken: $0) }
        } catch let error as AccountError where BrowserApproval.gone(error) || error.status == 409 || error.status == 403 {
            throw BrowserApproval.Failure.ended
        }
        return PairApproval(request: request, identity: identity, session: session, requesterPub: requesterPub,
                            sshPub: sshPub, publicKeyLine: line, commit: commit, nonceT: nonceT, now: now, poll: poll)
    }

    // MARK: Waiting for the reveal

    /// Waits for the new device's `nonce_b` and checks it against the commit. A nonce that
    /// doesn't open it denies the request and throws `.tampered`.
    public func awaitReveal() async throws {
        let start = now()
        var failures = 0
        while true {
            guard now() < expires else { throw BrowserApproval.Failure.expired }
            var wait = poll(now().timeIntervalSince(start))
            do {
                let status = try await state()
                switch status.state {
                case .revealed:
                    return try await revealed(status.nonceB)
                case .waiting, .claimed:
                    failures = 0
                default:
                    end()
                    throw BrowserApproval.Failure.ended
                }
            } catch let error as AccountError {
                if BrowserApproval.gone(error) {
                    end()
                    throw BrowserApproval.Failure.ended
                }
                guard BrowserApproval.transient(error) else { throw error }
                failures = min(failures + 1, 5)
                wait = min(wait * pow(2, Double(failures)), BrowserApproval.backoffMax)
            }
            let left = expires.timeIntervalSince(now())
            try await Task.sleep(nanoseconds: UInt64(max(0, min(wait, left)) * 1_000_000_000))
        }
    }

    private func revealed(_ nonceB64: String?) async throws {
        guard let nonceB = nonceB64.flatMap(Base64URL.decode),
              (try? PairV1.open(requesterPub: requesterPub, sshPub: sshPub, commit: commit, nonceB: nonceB)) != nil
        else {
            _ = try? await deny()
            throw BrowserApproval.Failure.tampered
        }
        code = try PairV1.code(requesterPub: requesterPub, sshPub: sshPub, approverPub: approverPub,
                               nonceB: nonceB, nonceT: nonceT)
    }

    public var codeShown: Bool { code != nil }

    // MARK: The code

    /// Compares the typed code with this device's. The last wrong one denies the request.
    public func checkCode(_ typed: String) async throws -> BrowserApproval.CodeCheck {
        if locked || done { throw BrowserApproval.Failure.ended }
        guard let code else { throw BrowserApproval.Failure.codeNotShown }
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if ApproveV1.codeMatches(typed, code) {
            matched = true
            return BrowserApproval.CodeCheck(ok: true, left: Self.maxCodeTries - tries)
        }
        tries += 1
        let left = Self.maxCodeTries - tries
        guard left == 0 else { return BrowserApproval.CodeCheck(ok: false, left: left) }
        locked = true
        do {
            try await deny()
            return BrowserApproval.CodeCheck(ok: false, left: 0, denied: true)
        } catch BrowserApproval.Failure.ended {
            return BrowserApproval.CodeCheck(ok: false, left: 0, denied: true)
        } catch {
            return BrowserApproval.CodeCheck(ok: false, left: 0, denied: false, denyFailure: BrowserApproval.describe(error))
        }
    }

    /// Whether keys may be added for this request now: the code matched and nothing ended it.
    public func ready() throws {
        if locked || done { throw BrowserApproval.Failure.ended }
        guard matched else { throw BrowserApproval.Failure.codeNotChecked }
    }

    // MARK: Finishing

    /// Seals `envelope` to the new device and finishes the request as approved (seq 1).
    /// Returns once the service has it; throws `BrowserApproval.NotRecorded` when it
    /// definitely doesn't and `OutcomeUnknown` when that can't be told (send it again).
    public func approve(_ envelope: PairEnvelope) async throws {
        if seq > 0 { return }
        do {
            try ready()
        } catch {
            // Nothing of this device's finish is in doubt: nothing was sent, nothing will be.
            if !unsure { throw BrowserApproval.NotRecorded(reason: error) }
            return try await settle(error)
        }
        let sealed: String
        do {
            sealed = try PairV1.seal(approver: identity.privateKey, requesterPub: requesterPub, seq: 1,
                                     plaintext: try envelope.json())
        } catch {
            throw BrowserApproval.NotRecorded(reason: error)
        }
        guard sealed.utf8.count <= ApproveV1.maxSealedLength else {
            throw BrowserApproval.NotRecorded(reason: PairMachines.Failure.tooManyMachines)
        }
        let client = session.client
        let id = request.id
        do {
            try await session.authorized { try await client.approvePair(id: id, seq: 1, sealed: sealed, accessToken: $0) }
        } catch {
            let refused = (error as? AccountError).flatMap(\.status).map { (400..<500).contains($0) && $0 != 429 } ?? false
            let earlier = unsure
            unsure = unsure || !refused
            if refused && !earlier { throw BrowserApproval.NotRecorded(reason: error) }
            return try await settle(error)
        }
        seq = 1
        end()
    }

    /// Sends `envelope` again with the next seq, after a machine was tried again. The service
    /// takes it for 10 minutes after the finish.
    public func resend(_ envelope: PairEnvelope) async throws {
        guard seq > 0 else { throw BrowserApproval.Failure.codeNotChecked }
        let next = seq + 1
        let sealed = try PairV1.seal(approver: identity.privateKey, requesterPub: requesterPub, seq: next,
                                     plaintext: try envelope.json())
        guard sealed.utf8.count <= ApproveV1.maxSealedLength else { throw PairMachines.Failure.tooManyMachines }
        let client = session.client
        let id = request.id
        do {
            try await session.authorized {
                try await client.replacePairEnvelope(id: id, seq: next, sealed: sealed, accessToken: $0)
            }
        } catch let error as AccountError where error.status == 409 && error.code == "stale_seq" {
            // A resend whose answer was lost took this seq: the next goes above it.
            seq = next
            throw error
        }
        seq = next
    }

    /// The seq of the last envelope the service took (0 before the finish).
    public var sentSeq: UInt64 { seq }

    private func settle(_ finishError: Error) async throws {
        if let status = try? await state() {
            switch status.state {
            case .approved:
                seq = 1
                end()
                return
            case .denied:
                end()
                throw BrowserApproval.NotRecorded(reason: finishError)
            case .expired where !unsure || status.outcomeStored:
                end()
                throw BrowserApproval.NotRecorded(reason: finishError)
            default:
                break
            }
        }
        throw BrowserApproval.OutcomeUnknown(reason: finishError)
    }

    /// Finishes the request as denied. Throws `.ended` when it was already over.
    public func deny() async throws {
        locked = true
        if denied { return }
        if done { throw BrowserApproval.Failure.ended }
        let client = session.client
        let id = request.id
        do {
            try await session.authorized { try await client.denyBrowser(id: id, accessToken: $0) }
        } catch let error as AccountError where BrowserApproval.gone(error) || error.status == 409 {
            end()
            throw BrowserApproval.Failure.ended
        }
        denied = true
        end()
    }

    private func state() async throws -> ApprovalStatus {
        let client = session.client
        let id = request.id
        return try await session.authorized { try await client.approvalState(id: id, accessToken: $0) }
    }

    private func end() {
        locked = true
        done = true
    }
}

// MARK: Machines

/// A herdr owner connection to one machine for the approval, and the host key it checked.
public struct PairLink: Sendable {
    public let client: HerdrClient
    /// The host key the connection trusted, one OpenSSH line (`HostKeyRecorder.trustedKey`).
    public let hostKey: @Sendable () -> String?
    public let close: @Sendable () async -> Void

    public init(client: HerdrClient, hostKey: @escaping @Sendable () -> String?,
                close: @escaping @Sendable () async -> Void) {
        self.client = client
        self.hostKey = hostKey
        self.close = close
    }
}

/// One saved machine the approver can offer.
public struct PairMachine: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let host: String
    public let port: Int
    public let user: String
    /// The machine logs in with a password here; the new device gets a key for it.
    public let passwordLogin: Bool
    public let open: @Sendable () async throws -> PairLink

    public init(id: String, label: String, host: String, port: Int, user: String, passwordLogin: Bool,
                open: @escaping @Sendable () async throws -> PairLink) {
        self.id = id
        self.label = label
        self.host = host
        self.port = port
        self.user = user
        self.passwordLogin = passwordLogin
        self.open = open
    }
}

/// Whether a machine can take the new device's key from here.
public enum PairMachineCheck: Equatable, Sendable {
    case ready
    /// No connection from this device right now.
    case unreachable
    /// herdr there has no `pair.add_key` (its version, for the row).
    case needsUpdate(version: String)
}

public enum PairMachines {
    public enum Failure: Error, Equatable, Sendable {
        /// The sealed list would pass the service's 16 KB.
        case tooManyMachines
    }

    /// How long a machine gets to connect and answer, per step.
    public static let timeout: TimeInterval = 15

    /// The label herdr writes beside the key: "‹N› (approved on ‹A›)", printable, one line,
    /// at most 80 characters (the requester's name is shortened to fit).
    public static func label(requester: String, approver: String) -> String {
        func clean(_ text: String) -> String {
            String(text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f && !CharacterSet.newlines.contains($0) })
                .trimmingCharacters(in: .whitespaces)
        }
        let a = String(clean(approver).prefix(40))
        let tail = " (approved on \(a.isEmpty ? "another device" : a))"
        let room = max(1, 80 - tail.count)
        let n = String(clean(requester).prefix(room))
        return (n.isEmpty ? "device" : n) + tail
    }

    /// Opens `machine` and asks herdr what it supports. The link stays open for `add` when the
    /// machine is ready; otherwise it is closed.
    public static func check(_ machine: PairMachine, timeout: TimeInterval = PairMachines.timeout) async
        -> (PairMachineCheck, PairLink?) {
        let link: PairLink
        do {
            link = try await WebAccessApproval.withDeadline(timeout, machine.open) { late in
                if case .success(let link) = late { await link.close() }
            }
        } catch {
            return (.unreachable, nil)
        }
        do {
            let client = link.client
            let (version, capabilities) = try await WebAccessApproval.withDeadline(timeout, {
                try await client.serverVersionAndCapabilities()
            }, late: { _ in })
            guard capabilities?.pairAddKey == true else {
                await link.close()
                return (.needsUpdate(version: version), nil)
            }
            return (.ready, link)
        } catch {
            await link.close()
            return (.unreachable, nil)
        }
    }

    /// Adds `publicKeyLine` on `machine` over `link` (or a fresh connection) and says how it
    /// went, as the envelope carries it. A host key the connection didn't record fails the
    /// machine: the new device would have nothing to pin.
    public static func add(_ machine: PairMachine, link: PairLink?, publicKeyLine: String, label: String,
                           timeout: TimeInterval = PairMachines.timeout) async -> (PairEnvelope.Machine, PairLink?) {
        func failed(_ reason: String, hostKey: String = "") -> PairEnvelope.Machine {
            PairEnvelope.Machine(nickname: machine.label, host: machine.host, port: machine.port, user: machine.user,
                                 hostKey: hostKey, status: .failed, reason: reason)
        }
        var opened = link
        if opened == nil {
            do {
                opened = try await WebAccessApproval.withDeadline(timeout, machine.open) { late in
                    if case .success(let link) = late { await link.close() }
                }
            } catch {
                return (failed(describe(error)), nil)
            }
        }
        guard let link = opened else { return (failed("couldn't be reached"), nil) }
        do {
            let client = link.client
            let added = try await WebAccessApproval.withDeadline(timeout, {
                try await client.pairAddKey(publicKey: publicKeyLine, label: label)
            }, late: { _ in })
            guard let hostKey = link.hostKey(), !hostKey.isEmpty else {
                return (failed("its host key wasn't recorded"), link)
            }
            return (PairEnvelope.Machine(nickname: machine.label, host: machine.host, port: machine.port, user: machine.user,
                                         hostKey: hostKey, status: added.added ? .added : .already), link)
        } catch {
            return (failed(describe(error), hostKey: link.hostKey() ?? ""), link)
        }
    }

    /// "timed out", "couldn't be reached", or herdr's refusal.
    public static func describe(_ error: Error) -> String {
        switch error {
        case WebAccessApproval.Failure.timedOut: return "timed out"
        case let error as APIError: return error.message.isEmpty ? error.code : error.message
        case is TransportError: return "couldn't be reached"
        default: return "couldn't be reached"
        }
    }
}

/// `pair.add_key`'s params.
struct PairAddKeyParams: Encodable {
    let publicKey: String
    let label: String

    enum CodingKeys: String, CodingKey {
        case label
        case publicKey = "public_key"
    }
}

/// `pair.add_key`'s answer: whether the key was added now (false: it was already there), its
/// fingerprint ("SHA256:…") and the label written.
public struct PairKeyAdded: Decodable, Equatable, Sendable {
    public let added: Bool
    public let fingerprint: String
    public let label: String

    enum CodingKeys: String, CodingKey { case added, fingerprint, label }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        added = try c.decode(Bool.self, forKey: .added)
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
    }
}
