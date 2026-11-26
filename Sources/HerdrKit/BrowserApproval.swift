import Crypto
import Foundation

// The approver's side of browser approval (web owner access WIRE-PLAN §2.4), as HerdrUp
// Desktop runs it (`internal/account/approve_flow.go`, D1): this device lists the browsers
// waiting, claims one with `nonce_t`, waits for the browser's reveal, then finishes with the
// sealed machine list or a denial.
//
//     GET  /v1/approvals                        → {requests:[…]}
//     POST /v1/approvals/<id>/claim   {nonce_t} → 200 | 409 already_claimed
//     GET  /v1/approvals/<id>                   → {state, expires_in, outcome_stored?, approver?, nonce_t?, nonce_b?}
//     POST /v1/approvals/<id>/finish  {outcome, scope?, expires_ms?, seq?, sealed?}

/// One browser waiting for approval (`GET /v1/approvals`).
public struct ApprovalRequest: Decodable, Equatable, Sendable, Identifiable {
    public struct Browser: Decodable, Equatable, Sendable {
        public let deviceID: String
        /// The browser's X25519 key, unpadded base64url.
        public let devicePub: String
        /// "Chrome on macOS".
        public let name: String
        public let platform: String
        /// Unix milliseconds.
        public let createdMs: Int64

        public init(deviceID: String, devicePub: String, name: String, platform: String = "web", createdMs: Int64) {
            self.deviceID = deviceID
            self.devicePub = devicePub
            self.name = name
            self.platform = platform
            self.createdMs = createdMs
        }

        enum CodingKeys: String, CodingKey {
            case name, platform
            case deviceID = "device_id"
            case devicePub = "device_pub"
            case createdMs = "created_ms"
        }
    }

    public let id: String
    public let browser: Browser
    /// The browser's commit, unpadded base64url.
    public let commit: String
    /// "no", "you" or "other" (another device is approving it).
    public let claimed: String
    /// Seconds the request has left.
    public let expiresIn: Int

    public init(id: String, browser: Browser, commit: String, claimed: String, expiresIn: Int) {
        self.id = id
        self.browser = browser
        self.commit = commit
        self.claimed = claimed
        self.expiresIn = expiresIn
    }

    enum CodingKeys: String, CodingKey {
        case id, browser, commit, claimed
        case expiresIn = "expires_in"
    }
}

/// `GET /v1/approvals/<id>` as either side reads it.
public struct ApprovalStatus: Decodable, Equatable, Sendable {
    public enum State: String, Decodable, Sendable {
        /// `cancelled`: a pair request its new device withdrew (`POST /v1/approvals/<id>/cancel`).
        case waiting, claimed, revealed, denied, approved, expired, cancelled
    }

    /// The claimant, once there is one.
    public struct Approver: Decodable, Equatable, Sendable {
        /// Its X25519 device key, unpadded base64url.
        public let devicePub: String
        public let name: String

        enum CodingKeys: String, CodingKey {
            case name
            case devicePub = "device_pub"
        }
    }

    public let state: State
    /// Seconds the request has left (the service rounds up).
    public let expiresIn: Int
    public let nonceT: String?
    /// Only to the claimant, only while the request is live.
    public let nonceB: String?
    /// The service answered from an outcome it stored, not one it computed from the clock. For
    /// an expiry: no finish can be recorded after it (herdrup #801).
    public let outcomeStored: Bool
    public let approver: Approver?
    /// A pair request (`kind: "pair"`) also carries what its list entry does, so an approver
    /// opening it from a push needs no list.
    public let kind: String?
    public let sshPub: String?
    public let commit: String?
    public let device: PairRequest.Device?

    enum CodingKeys: String, CodingKey {
        case state, approver, kind, commit, device
        case expiresIn = "expires_in"
        case nonceT = "nonce_t"
        case nonceB = "nonce_b"
        case outcomeStored = "outcome_stored"
        case sshPub = "ssh_pub"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(State.self, forKey: .state)
        expiresIn = try c.decodeIfPresent(Int.self, forKey: .expiresIn) ?? 0
        nonceT = try c.decodeIfPresent(String.self, forKey: .nonceT)
        nonceB = try c.decodeIfPresent(String.self, forKey: .nonceB)
        outcomeStored = try c.decodeIfPresent(Bool.self, forKey: .outcomeStored) ?? false
        approver = try c.decodeIfPresent(Approver.self, forKey: .approver)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        sshPub = try c.decodeIfPresent(String.self, forKey: .sshPub)
        commit = try c.decodeIfPresent(String.self, forKey: .commit)
        device = try c.decodeIfPresent(PairRequest.Device.self, forKey: .device)
    }
}

/// What the approver reports with an approval: the scope and expiry it gave, and the machine
/// list sealed to the browser.
public struct ApprovalReport: Encodable, Equatable, Sendable {
    public let scope: String
    public let expiresMs: Int64
    public let seq: UInt64
    public let sealed: String

    enum CodingKeys: String, CodingKey {
        case scope, seq, sealed
        case expiresMs = "expires_ms"
    }
}

struct ApprovalList: Decodable {
    let requests: [ApprovalRequest]
}

struct FinishApproved: Encodable {
    let report: ApprovalReport

    enum CodingKeys: String, CodingKey { case outcome }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("approved", forKey: .outcome)
        try report.encode(to: encoder)
    }
}

/// One browser approval as this device runs it: claim with a fresh `nonce_t`, wait for the
/// browser to reveal `nonce_b`, check it against the commit seen before claiming, and approve
/// only once the user has typed the browser's code.
public actor BrowserApproval {
    public enum Failure: Error, Equatable, Sendable {
        /// The browser or the service ended the request (denied, expired, or answered
        /// elsewhere) before this device finished it.
        case ended
        /// Approving before the user typed the browser's code correctly (§2.2 step 5).
        case codeNotChecked
        /// A code typed before the browser revealed its nonce.
        case codeNotShown
        /// Too little time left to add grants on the machines and report them.
        case ending
        /// The reveal doesn't open the commit, or the request's key or commit is unreadable.
        /// The request was denied.
        case tampered
        /// The request ran out before the browser showed its code.
        case expired
        /// The device asking cancelled its request (pair requests only).
        case cancelled
    }

    /// An approval the service didn't record: it refused it, or the request ended without it.
    /// The browser never sees grants made for it, so the caller removes them.
    public struct NotRecorded: Error, Sendable {
        public let reason: Error
    }

    /// The service's answer to a finish was lost, and the request's state can't yet tell
    /// whether it was recorded.
    public struct OutcomeUnknown: Error, Sendable {
        public let reason: Error
    }

    /// One typed code's outcome. `left` is how many more codes may be typed; with none left
    /// the request can't be approved here any more, `denied` says the service took the denial,
    /// and `denyFailure` why it didn't.
    public struct CodeCheck: Equatable, Sendable {
        public let ok: Bool
        public let left: Int
        public var denied = false
        public var denyFailure: String?
    }

    /// How many wrong codes are accepted before the request is denied, so it can't be approved
    /// by guessing.
    public static let maxCodeTries = 3

    /// Every 2 s for the first minute, then every 5 s (WIRE-PLAN §2.4).
    public static let defaultPoll: @Sendable (TimeInterval) -> TimeInterval = { $0 < 60 ? 2 : 5 }
    /// The longest wait between reads after failed ones.
    static let backoffMax: TimeInterval = 30

    public nonisolated let request: ApprovalRequest
    /// This device's key (T), the one the service records from the session.
    public nonisolated let approverPub: Data
    nonisolated let browserPub: Data
    private let identity: GuestIdentity
    private let session: AccountSession
    private let commit: Data
    private let nonceT: Data
    private let now: @Sendable () -> Date
    private let poll: @Sendable (TimeInterval) -> TimeInterval
    /// When the request expires, as the list said at claim time.
    public nonisolated let expires: Date

    private var code: String?
    private var tries = 0
    private var matched = false
    /// This device won't approve the request any more (a denial was asked for, or too many
    /// wrong codes), whether or not the service has taken the denial yet.
    private var locked = false
    /// The service has the request's outcome, or the request is over.
    private var done = false
    /// The service took this device's denial; no approval of this request ever will be.
    private var denied = false
    /// A finish this device sent has an unknown outcome. An expiry the service only computed
    /// may still be followed by that finish being recorded; a stored one stops it.
    private var unsure = false

    init(request: ApprovalRequest, identity: GuestIdentity, session: AccountSession, browserPub: Data,
         commit: Data, nonceT: Data, now: @escaping @Sendable () -> Date,
         poll: @escaping @Sendable (TimeInterval) -> TimeInterval) {
        self.request = request
        self.identity = identity
        self.session = session
        self.browserPub = browserPub
        self.commit = commit
        self.nonceT = nonceT
        self.now = now
        self.poll = poll
        approverPub = identity.publicKey
        expires = now().addingTimeInterval(TimeInterval(request.expiresIn))
    }

    /// The browsers waiting for this account's approval.
    public static func pending(session: AccountSession) async throws -> [ApprovalRequest] {
        let client = session.client
        return try await session.authorized { try await client.approvals(accessToken: $0) }
    }

    /// Claims `request` for this device (`identity` is its enrolled device key). The browser
    /// key and commit are the ones in `request`, read before `nonce_t` exists.
    public static func start(session: AccountSession, identity: GuestIdentity, request: ApprovalRequest,
                             now: @escaping @Sendable () -> Date = { Date() },
                             poll: @escaping @Sendable (TimeInterval) -> TimeInterval = BrowserApproval.defaultPoll)
        async throws -> BrowserApproval {
        guard let browserPub = Base64URL.decode(request.browser.devicePub), browserPub.count == ApproveV1.keySize,
              let commit = Base64URL.decode(request.commit), commit.count == SHA256.byteCount
        else { throw Failure.tampered }
        let nonceT = ApproveV1.newNonce()
        let client = session.client
        do {
            try await session.authorized { try await client.claimApproval(id: request.id, nonceT: nonceT, accessToken: $0) }
        } catch let error as AccountError where Self.gone(error) || error.status == 409 {
            throw Failure.ended
        }
        return BrowserApproval(request: request, identity: identity, session: session, browserPub: browserPub,
                               commit: commit, nonceT: nonceT, now: now, poll: poll)
    }

    // MARK: Waiting for the reveal

    /// Waits for the browser's `nonce_b` and checks it. A nonce that doesn't open the commit
    /// denies the request and throws `.tampered`. A busy or unreachable service is read again,
    /// more slowly, until the request expires (`.expired`) or the task is cancelled.
    public func awaitReveal() async throws {
        let start = now()
        var failures = 0
        while true {
            guard now() < expires else { throw Failure.expired }
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
                    throw Failure.ended
                }
            } catch let error as AccountError {
                if Self.gone(error) {
                    end()
                    throw Failure.ended
                }
                guard Self.transient(error) else { throw error }
                failures = min(failures + 1, 5)
                wait = min(wait * pow(2, Double(failures)), Self.backoffMax)
            }
            let left = expires.timeIntervalSince(now())
            try await Task.sleep(nanoseconds: UInt64(max(0, min(wait, left)) * 1_000_000_000))
        }
    }

    private func revealed(_ nonceB64: String?) async throws {
        guard let nonceB = nonceB64.flatMap(Base64URL.decode),
              (try? ApproveV1.open(browserPub: browserPub, commit: commit, nonceB: nonceB)) != nil
        else {
            _ = try? await deny()
            throw Failure.tampered
        }
        code = try ApproveV1.code(browserPub: browserPub, approverPub: approverPub, nonceB: nonceB, nonceT: nonceT)
    }

    /// Whether the browser has revealed and the code can be typed.
    public var codeShown: Bool { code != nil }

    // MARK: The code

    /// Compares the code the user typed with this device's. The last wrong code locks the
    /// approval and denies the request.
    public func checkCode(_ typed: String) async throws -> CodeCheck {
        if locked || done { throw Failure.ended }
        guard let code else { throw Failure.codeNotShown }
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if ApproveV1.codeMatches(typed, code) {
            matched = true
            return CodeCheck(ok: true, left: Self.maxCodeTries - tries)
        }
        tries += 1
        let left = Self.maxCodeTries - tries
        guard left == 0 else { return CodeCheck(ok: false, left: left) }
        locked = true
        do {
            try await deny()
            return CodeCheck(ok: false, left: 0, denied: true)
        } catch Failure.ended {
            return CodeCheck(ok: false, left: 0, denied: true)
        } catch {
            return CodeCheck(ok: false, left: 0, denied: false, denyFailure: BrowserApproval.describe(error))
        }
    }

    /// Whether grants may be made for this request now: the user typed the browser's code and
    /// nothing ended or locked the approval.
    public func ready() throws {
        if locked || done { throw Failure.ended }
        guard matched else { throw Failure.codeNotChecked }
    }

    /// Checks with the service, just before grants are made, that the request is still
    /// revealed to this device with at least `min` left, so no machine gets a grant the service
    /// would then refuse to record. Returns the request's deadline, counted from before the
    /// read (the service rounds the time left up to a second, so one second less).
    public func live(min: TimeInterval) async throws -> Date {
        try ready()
        let start = now()
        let status: ApprovalStatus
        do {
            status = try await state()
        } catch let error as AccountError where Self.gone(error) {
            end()
            throw Failure.ended
        }
        guard status.state == .revealed else {
            end()
            throw Failure.ended
        }
        let deadline = start.addingTimeInterval(TimeInterval(status.expiresIn - 1))
        guard deadline.timeIntervalSince(now()) >= min else { throw Failure.ending }
        return deadline
    }

    // MARK: Finishing

    /// Finishes the request as approved with the machine list (envelope JSON) sealed to the
    /// browser at `seq`. Returns once the service has the approval (also when only its reply
    /// was lost), throws `NotRecorded` when the service definitely doesn't have it, and
    /// `OutcomeUnknown` when that can't be told. Sent again after an unknown outcome, it reports
    /// what the service has.
    public func approve(scope: String, expiresMs: Int64, seq: UInt64, envelope: Data) async throws {
        do {
            try ready()
        } catch {
            // Locked or over since an earlier report: only the service knows whether that
            // report was recorded.
            return try await settle(error)
        }
        let sealed: String
        do {
            sealed = try ApproveV1.seal(approver: identity.privateKey, browserPub: browserPub, seq: seq, plaintext: envelope)
        } catch {
            throw NotRecorded(reason: error)
        }
        let report = ApprovalReport(scope: scope, expiresMs: expiresMs, seq: seq, sealed: sealed)
        let client = session.client
        let id = request.id
        do {
            try await session.authorized { try await client.approveBrowser(id: id, report: report, accessToken: $0) }
        } catch {
            // A refusal (a 4xx other than 429: the finish is one transaction, herdrup #792)
            // didn't record this finish; anything else may yet be recorded.
            let refused = (error as? AccountError).flatMap(\.status).map { (400..<500).contains($0) && $0 != 429 } ?? false
            let earlier = unsure
            unsure = unsure || !refused
            if refused && !earlier {
                // The only finish this device sent was refused, and only the claimant
                // finishes: whatever the request is now, it holds no approval from here.
                throw NotRecorded(reason: error)
            }
            return try await settle(error)
        }
        end()
    }

    /// Decides what the finishes this device sent did, from the request's state: approved
    /// means one went through (only the claimant finishes); denied means none can be; expired
    /// means none can be only when none had an unknown outcome or the expiry is stored. Still
    /// revealed proves nothing, since a sent finish may yet be applied.
    private func settle(_ finishError: Error) async throws {
        if let read = try? await outcome(), read.1 {
            end()
            if read.0 == .approved { return }
            throw NotRecorded(reason: finishError)
        }
        throw OutcomeUnknown(reason: finishError)
    }

    /// The request's state as the service has it now. `final` says it is the request's outcome
    /// for this device: approved, denied, or expired when no finish of this device has an
    /// unknown outcome or this very read says the expiry is stored (`outcome_stored`). A
    /// request the service no longer knows is an error: its outcome can't be told.
    public func outcome() async throws -> (ApprovalStatus.State, Bool) {
        let status = try await state()
        switch status.state {
        case .approved, .denied: return (status.state, true)
        case .expired: return (status.state, !unsure || status.outcomeStored)
        default: return (status.state, false)
        }
    }

    /// Finishes the request as denied. Locks the approval at once, and returns when the service
    /// took this device's denial (now or on an earlier `deny`); throws `.ended` when the request
    /// was already over some other way (nothing is sent then).
    public func deny() async throws {
        locked = true
        if denied { return }
        if done { throw Failure.ended }
        let client = session.client
        let id = request.id
        do {
            try await session.authorized { try await client.denyBrowser(id: id, accessToken: $0) }
        } catch let error as AccountError where Self.gone(error) || error.status == 409 {
            end()
            throw Failure.ended
        }
        denied = true
        end()
    }

    // MARK: Helpers

    private func state() async throws -> ApprovalStatus {
        let client = session.client
        let id = request.id
        return try await session.authorized { try await client.approvalState(id: id, accessToken: $0) }
    }

    private func end() {
        locked = true
        done = true
    }

    /// An answer that says the request no longer exists or is over for this device.
    static func gone(_ error: AccountError) -> Bool {
        error.status == 404 || error.status == 410
    }

    /// A failed read worth repeating: no answer, a rate limit, or a server error.
    static func transient(_ error: AccountError) -> Bool {
        switch error {
        case .refused(let status, _, _, _): return status == 429 || status >= 500
        case .signedOut: return false
        case .unreachable, .malformedResponse: return true
        }
    }

    /// A short line for an approval error, for the sheet.
    public nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case Failure.ended: return "This request is no longer waiting."
        case Failure.codeNotChecked: return "Enter the code shown in the browser first."
        case Failure.codeNotShown: return "The browser hasn't shown its code yet."
        case Failure.ending: return "This request is about to expire. Ask the browser for a new one."
        case Failure.tampered: return "This request was tampered with. It was denied."
        case Failure.expired: return "This request expired before the browser showed its code."
        case Failure.cancelled: return "This request was cancelled."
        case let error as NotRecorded: return describe(error.reason)
        case let error as OutcomeUnknown: return "Couldn't tell whether the browser was approved (\(describe(error.reason)))."
        case AccountError.unreachable: return "The HerdrUp account service can't be reached."
        case AccountError.signedOut: return "Signed out of HerdrUp."
        case AccountError.refused(let status, let code, _, _): return code.isEmpty ? "Refused (\(status))." : "Refused: \(code)."
        default: return String(describing: error)
        }
    }
}

extension AccountError {
    /// The HTTP status of a refusal.
    public var status: Int? {
        if case .refused(let status, _, _, _) = self { return status }
        return nil
    }
}
