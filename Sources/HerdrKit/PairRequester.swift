import Crypto
import Foundation

// Pairing this device from another one (pair-v1, DESIGN §13), the new device's side: make an
// SSH key S for the request, commit to it, wait for an approver to claim, reveal and show the
// code, then read the machine list the approver sealed.
//
//     POST /v1/approvals          {kind: "pair", commit, ssh_pub} → 201 {id, expires_in}
//     GET  /v1/approvals/<id>     → {state, expires_in, approver?, nonce_t?, …}
//     POST /v1/approvals/<id>/reveal {nonce_b}
//     GET  /v1/pairs/self         → {request?, envelopes: [{request_id, ssh_pub, approver_pub, approver_name, seq, sealed}]}

/// `POST /v1/approvals` for a pair request.
public struct PairRequestCreated: Decodable, Equatable, Sendable {
    public let id: String
    public let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case id
        case expiresIn = "expires_in"
    }
}

/// One device of the account asking to be paired (`GET /v1/approvals?kind=pair`), or the same
/// read from `GET /v1/approvals/<id>` when a push opened it.
public struct PairRequest: Decodable, Equatable, Sendable, Identifiable {
    /// The device asking.
    public struct Device: Decodable, Equatable, Sendable {
        public let deviceID: String
        /// Its X25519 device key (B), unpadded base64url.
        public let devicePub: String
        /// "MacBook Air".
        public let name: String
        public let platform: String

        public init(deviceID: String, devicePub: String, name: String, platform: String) {
            self.deviceID = deviceID
            self.devicePub = devicePub
            self.name = name
            self.platform = platform
        }

        enum CodingKeys: String, CodingKey {
            case name, platform
            case deviceID = "device_id"
            case devicePub = "device_pub"
        }
    }

    public let id: String
    public let device: Device
    /// The requester's commit, unpadded base64url.
    public let commit: String
    /// S, the raw ed25519 key the approver adds, unpadded base64url.
    public let sshPub: String
    /// "no", "you" or "other".
    public let claimed: String
    public let expiresIn: Int

    public init(id: String, device: Device, commit: String, sshPub: String, claimed: String, expiresIn: Int) {
        self.id = id
        self.device = device
        self.commit = commit
        self.sshPub = sshPub
        self.claimed = claimed
        self.expiresIn = expiresIn
    }

    /// The request a push named, from its state read. Nil when it isn't a pair request.
    public init?(id: String, status: ApprovalStatus) {
        guard status.kind == "pair", let device = status.device, let commit = status.commit, let sshPub = status.sshPub
        else { return nil }
        self.init(id: id, device: device, commit: commit, sshPub: sshPub,
                  claimed: status.state == .waiting ? "no" : "other", expiresIn: status.expiresIn)
    }

    enum CodingKeys: String, CodingKey {
        case id, device, commit, claimed
        case sshPub = "ssh_pub"
        case expiresIn = "expires_in"
    }
}

struct PairRequestList: Decodable {
    let requests: [PairRequest]
}

/// A pair finish or envelope replacement: `{outcome: "approved", seq, sealed}` or `{seq, sealed}`.
struct PairSealed: Encodable {
    let outcome: String?
    let seq: UInt64
    let sealed: String

    enum CodingKeys: String, CodingKey { case outcome, seq, sealed }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(outcome, forKey: .outcome)
        try c.encode(seq, forKey: .seq)
        try c.encode(sealed, forKey: .sealed)
    }
}

/// `GET /v1/pairs/self`.
public struct PairsSelf: Decodable, Equatable, Sendable {
    public struct Request: Decodable, Equatable, Sendable {
        public let id: String
        public let state: ApprovalStatus.State
        public let expiresIn: Int
        public let outcomeStored: Bool

        enum CodingKeys: String, CodingKey {
            case id, state
            case expiresIn = "expires_in"
            case outcomeStored = "outcome_stored"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            state = try c.decode(ApprovalStatus.State.self, forKey: .state)
            expiresIn = try c.decodeIfPresent(Int.self, forKey: .expiresIn) ?? 0
            outcomeStored = try c.decodeIfPresent(Bool.self, forKey: .outcomeStored) ?? false
        }
    }

    public struct Envelope: Decodable, Equatable, Sendable {
        public let requestID: String
        public let sshPub: String
        public let approverPub: String
        public let approverName: String
        public let seq: UInt64
        public let sealed: String

        enum CodingKeys: String, CodingKey {
            case seq, sealed
            case requestID = "request_id"
            case sshPub = "ssh_pub"
            case approverPub = "approver_pub"
            case approverName = "approver_name"
        }
    }

    public let request: Request?
    public let envelopes: [Envelope]

    enum CodingKeys: String, CodingKey { case request, envelopes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        request = try c.decodeIfPresent(Request.self, forKey: .request)
        envelopes = try c.decodeIfPresent([Envelope].self, forKey: .envelopes) ?? []
    }
}

/// What an approver sealed for this device: the machines it ticked and how each went.
public struct PairResult: Equatable, Sendable {
    public let approverName: String
    public let seq: UInt64
    public let machines: [PairEnvelope.Machine]
}

/// One pair request as the new device runs it.
public actor PairRequester {
    public enum Failure: Error, Equatable, Sendable {
        /// The approver denied it (a wrong code three times, or Deny).
        case denied
        /// Nobody approved it in time.
        case expired
        /// The service no longer has it (replaced by a newer request, or the device removed).
        case ended
        /// The approver's envelope doesn't open, or names another key: nothing in it is used.
        case tampered
    }

    public nonisolated let id: String
    /// S: its private half is what this device saves for each machine the approver added it to.
    public nonisolated let sshKey: PairingKey
    public nonisolated let expires: Date

    private let identity: GuestIdentity
    private let session: AccountSession
    private let nonceB: Data
    private let now: @Sendable () -> Date
    private let poll: @Sendable (TimeInterval) -> TimeInterval
    /// T and its name, from the claim.
    private var approverPub: Data?
    private var approverName: String?
    private var code: String?
    /// The highest envelope seq opened so far.
    private var seq: UInt64 = 0

    init(id: String, sshKey: PairingKey, identity: GuestIdentity, session: AccountSession, nonceB: Data,
         expiresIn: Int, now: @escaping @Sendable () -> Date, poll: @escaping @Sendable (TimeInterval) -> TimeInterval) {
        self.id = id
        self.sshKey = sshKey
        self.identity = identity
        self.session = session
        self.nonceB = nonceB
        self.now = now
        self.poll = poll
        expires = now().addingTimeInterval(TimeInterval(expiresIn))
    }

    /// Makes a fresh SSH key (commented `keyComment`, as `herdr pair` keys are) and asks the
    /// account's other devices to add it. `identity` is this device's enrolled key (B).
    public static func start(session: AccountSession, identity: GuestIdentity, keyComment: String,
                             now: @escaping @Sendable () -> Date = { Date() },
                             poll: @escaping @Sendable (TimeInterval) -> TimeInterval = BrowserApproval.defaultPoll)
        async throws -> PairRequester {
        let sshKey = PairingKey(comment: keyComment)
        let nonceB = ApproveV1.newNonce()
        let commit = try PairV1.commit(requesterPub: identity.publicKey, sshPub: sshKey.publicKey, nonceB: nonceB)
        let client = session.client
        let created = try await session.authorized {
            try await client.requestPair(commit: commit, sshPub: sshKey.publicKey, accessToken: $0)
        }
        return PairRequester(id: created.id, sshKey: sshKey, identity: identity, session: session, nonceB: nonceB,
                             expiresIn: created.expiresIn, now: now, poll: poll)
    }

    // MARK: The code

    /// Waits for an approver to claim the request, reveals `nonce_b` to it, and returns the
    /// code to show with the approver's name.
    public func awaitCode() async throws -> (code: String, approver: String) {
        if let code, let approverName { return (code, approverName) }
        return try await polling { [self] in
            let client = session.client
            let id = self.id
            let status = try await session.authorized { try await client.approvalState(id: id, accessToken: $0) }
            switch status.state {
            case .waiting:
                return nil
            case .claimed, .revealed:
                return try await claimed(status)
            case .denied:
                throw Failure.denied
            case .expired:
                throw Failure.expired
            case .approved:
                // Approved before this device saw the claim: only possible after a reveal it
                // sent, so the claim it read then holds.
                guard let code, let approverName else { throw Failure.tampered }
                return (code, approverName)
            }
        }
    }

    private func claimed(_ status: ApprovalStatus) async throws -> (code: String, approver: String)? {
        guard let approver = status.approver, let nonceT64 = status.nonceT else { return nil }
        guard let t = Base64URL.decode(approver.devicePub), t.count == ApproveV1.keySize,
              let nonceT = Base64URL.decode(nonceT64), nonceT.count == ApproveV1.nonceSize
        else { throw Failure.tampered }
        if let approverPub, !ApproveV1.constantTimeEqual(approverPub, t) { throw Failure.tampered }
        if status.state == .claimed {
            let client = session.client
            let id = self.id
            let nonceB = self.nonceB
            do {
                try await session.authorized { try await client.revealPair(id: id, nonceB: nonceB, accessToken: $0) }
            } catch let error as AccountError where error.status == 409 && error.code == "already_revealed" {
                // A reveal whose answer was lost: it went through.
            }
        }
        let code = try PairV1.code(requesterPub: identity.publicKey, sshPub: sshKey.publicKey, approverPub: t,
                                   nonceB: nonceB, nonceT: nonceT)
        approverPub = t
        approverName = approver.name
        self.code = code
        return (code, approver.name)
    }

    // MARK: The machines

    /// Waits for the approver's envelope and opens it. Throws `.denied` or `.expired` when the
    /// request ends without one.
    public func awaitResult() async throws -> PairResult {
        try await polling { [self] in
            let answer = try await pairsSelf()
            if let result = try open(answer) { return result }
            guard let request = answer.request, request.id == id else { throw Failure.ended }
            switch request.state {
            case .denied: throw Failure.denied
            case .expired: throw Failure.expired
            default: return nil
            }
        }
    }

    /// A newer envelope than the last one opened (the approver tried a machine again), or nil.
    public func newerResult() async throws -> PairResult? {
        try open(try await pairsSelf())
    }

    private func pairsSelf() async throws -> PairsSelf {
        let client = session.client
        return try await session.authorized { try await client.pairsSelf(accessToken: $0) }
    }

    /// Opens this request's envelope when it is newer than the last one. Only the approver
    /// that claimed (T, bound in the code the user typed) can have sealed one that opens.
    private func open(_ answer: PairsSelf) throws -> PairResult? {
        guard let envelope = answer.envelopes.first(where: { $0.requestID == id }), envelope.seq > seq else { return nil }
        guard let approverPub, let t = Base64URL.decode(envelope.approverPub),
              ApproveV1.constantTimeEqual(approverPub, t),
              Base64URL.decode(envelope.sshPub) == sshKey.publicKey
        else { throw Failure.tampered }
        let machines: [PairEnvelope.Machine]
        do {
            let plain = try PairV1.openEnvelope(requester: identity.privateKey, approverPub: t, seq: envelope.seq,
                                                sealed: envelope.sealed)
            machines = try PairEnvelope.parse(plain).machines
        } catch {
            throw Failure.tampered
        }
        seq = envelope.seq
        return PairResult(approverName: approverName ?? envelope.approverName, seq: envelope.seq, machines: machines)
    }

    // MARK: Helpers

    /// Runs `step` until it answers, on `poll`'s schedule, backing off after failed reads,
    /// until the request expires (`.expired`) or the task is cancelled.
    private func polling<T>(_ step: () async throws -> T?) async throws -> T {
        let start = now()
        var failures = 0
        while true {
            guard now() < expires else { throw Failure.expired }
            var wait = poll(now().timeIntervalSince(start))
            do {
                if let value = try await step() { return value }
                failures = 0
            } catch let error as AccountError {
                if BrowserApproval.gone(error) { throw error.status == 410 ? Failure.expired : Failure.ended }
                guard BrowserApproval.transient(error) else { throw error }
                failures = min(failures + 1, 5)
                wait = min(wait * pow(2, Double(failures)), BrowserApproval.backoffMax)
            }
            let left = expires.timeIntervalSince(now())
            try await Task.sleep(nanoseconds: UInt64(max(0, min(wait, left)) * 1_000_000_000))
        }
    }

    /// A short line for a requester error.
    public nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case Failure.denied: return "Not approved."
        case Failure.expired: return "The request expired."
        case Failure.ended: return "This request is no longer waiting."
        case Failure.tampered: return "The answer to this request didn't check out, so nothing in it was used."
        default: return BrowserApproval.describe(error)
        }
    }
}
