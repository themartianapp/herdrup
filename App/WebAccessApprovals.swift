import Combine
import HerdrKit
import SwiftUI

/// Browsers asking to reach the owner's machines (web owner access, WIRE-PLAN §2, I1). While the
/// app is in the foreground, signed in, with this device enrolled and the service offering
/// `web_approve`, it lists the waiting requests every few seconds (there is no push for them,
/// §5.9) and opens "Approve a browser?" for a new one. Settings › HerdrUp account lists them too.
///
/// The sheet shows only with at least one machine this device can reach over SSH (§5.6): an
/// approval from a device with no machine would write no grant, yet look like one.
@MainActor
final class WebAccessApprovals: ObservableObject {
    static let shared = WebAccessApprovals()

    /// Requests nobody has claimed yet, oldest first.
    @Published private(set) var requests: [ApprovalRequest] = []
    /// The request the sheet is open on.
    @Published var presented: ApprovalRequest?

    /// The interval between lists while in the foreground.
    static let pollInterval: UInt64 = 5_000_000_000

    private let account = HerdrUpAccount.shared
    /// Requests the sheet already opened by itself, so closing it doesn't bring it back.
    private var shown: Set<String> = []
    private var loop: Task<Void, Never>?

    private init() {}

    /// Whether the account can carry approvals now.
    var available: Bool {
        guard account.signedIn, account.health?.offers(AccountHealth.webApprove) == true else { return false }
        if case .enrolled = account.enrolment { return true }
        return false
    }

    /// The machines this device can open a session to: its saved machines with their key or
    /// password on this device.
    var machines: [WebAccessMachine] { WebAccessMachines.current() }

    /// Starts or stops the foreground poll.
    func setActive(_ active: Bool) {
        loop?.cancel()
        loop = nil
        guard active else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: Self.pollInterval)
            }
        }
    }

    /// Lists the waiting requests and opens the sheet for a new one. With pair-v1 the pair
    /// poll reads both kinds at once (`kind=any`) and hands browsers to `take`.
    func refresh() async {
        guard available else {
            requests = []
            return
        }
        // The pair poll's `kind=any` read lists browsers too.
        if PairApprovals.shared.available { return }
        guard let list = try? await BrowserApproval.pending(session: account.session) else { return }
        take(list)
    }

    /// The browsers waiting, from either list read.
    func take(_ list: [ApprovalRequest]) {
        guard available else {
            requests = []
            return
        }
        // One claimed here is answered in its open sheet; one claimed elsewhere isn't ours.
        requests = list.filter { $0.claimed == "no" }
        if presented == nil,
           let next = requests.first(where: { !shown.contains($0.id) }),
           !machines.isEmpty {
            shown.insert(next.id)
            presented = next
        }
    }

    /// Opens the sheet on `request` (from Settings).
    func open(_ request: ApprovalRequest) {
        shown.insert(request.id)
        presented = request
    }

    /// The sheet closed.
    func closed(_ request: ApprovalRequest) {
        if presented?.id == request.id { presented = nil }
        Task { await refresh() }
    }
}

/// Where the sheet's machines come from: saved machines with their secret on this device, each
/// reached through its own SSH session for the approval (WIRE-PLAN clarification, 22 Nov).
@MainActor
enum WebAccessMachines {
    static func current() -> [WebAccessMachine] {
        #if DEBUG
        if ProcessInfo.processInfo.environment["HERDR_MOCK_ACCOUNT_APPROVAL"] == "1" {
            return OwnerAccessMock.machines
        }
        #endif
        let store = SavedHostsStore.shared
        return store.hosts.compactMap { saved in
            guard case .ready(let credentials) = store.connection(for: saved) else { return nil }
            return WebAccessMachine(id: saved.id.uuidString, label: saved.label,
                                    hostItemID: saved.id.uuidString.lowercased()) {
                var creds = credentials
                creds.session = nil   // owner_access lives on the default session
                let transport = CitadelTransport(credentials: creds, hostKeyPolicy: KeychainHostKeyPolicy.shared)
                return OwnerAccessLink(client: HerdrClient(transport: transport), close: { await transport.close() })
            }
        }
    }

    /// Saved machines this device can't open now (no secret here), for the sheet's footnote.
    static func unavailable() -> [String] {
        #if DEBUG
        if ProcessInfo.processInfo.environment["HERDR_MOCK_ACCOUNT_APPROVAL"] == "1" { return [] }
        #endif
        let store = SavedHostsStore.shared
        return store.hosts.filter {
            if case .ready = store.connection(for: $0) { return false }
            return true
        }.map(\.label)
    }
}

/// One approval as the sheet runs it: claim, wait for the browser's code, check the typed one,
/// then grant on the ticked machines (or deny).
@MainActor
final class WebAccessApprovalModel: ObservableObject {
    enum Phase: Equatable {
        /// Claiming the request.
        case starting
        /// Claimed; the browser shows its code in a moment.
        case waitingForBrowser
        /// The browser shows its code: type it.
        case enterCode
        /// The code matched.
        case matched
        case working
        /// Approved: what each machine did.
        case approved(WebAccessResult)
        /// Over: denied, expired, tampered, or answered elsewhere.
        case ended(String)
    }

    let request: ApprovalRequest
    let machines: [WebAccessMachine]
    let unavailable: [String]

    @Published private(set) var phase: Phase = .starting
    @Published var typed = "" {
        didSet {
            let digits = String(typed.filter(\.isNumber).prefix(4))
            if digits != typed { typed = digits; return }
            if digits.count == 4, phase == .enterCode { Task { await check(digits) } }
        }
    }
    /// "That code doesn't match the browser's. 2 tries left."
    @Published private(set) var codeError: String?
    /// A step that failed, shown above the buttons; Approve or Deny try again.
    @Published private(set) var problem: String?
    /// A report whose outcome is unknown: Approve sends it again.
    @Published private(set) var unsure = false
    @Published var ticked: Set<String>
    @Published var scope: WebAccessScope = .terminal
    @Published var length: WebAccessLength = .thirtyDays
    @Published private(set) var expires: Date

    private var web: WebAccessApproval?
    private var waiting: Task<Void, Never>?

    init(request: ApprovalRequest, machines: [WebAccessMachine], unavailable: [String]) {
        self.request = request
        self.machines = machines
        self.unavailable = unavailable
        ticked = Set(machines.map(\.id))
        expires = Date().addingTimeInterval(TimeInterval(request.expiresIn))
    }

    /// Approved or over: nothing left to answer.
    var finished: Bool {
        switch phase {
        case .approved, .ended: return true
        default: return false
        }
    }

    var canApprove: Bool {
        (phase == .matched && !ticked.isEmpty) || (unsure && phase != .working)
    }

    var chosenMachines: [WebAccessMachine] { machines.filter { ticked.contains($0.id) } }

    func start() async {
        guard phase == .starting else { return }
        let account = HerdrUpAccount.shared
        do {
            let identity = try GuestDevice.identity()
            let approval = try await BrowserApproval.start(session: account.session, identity: identity, request: request)
            let statements = account.statements
            web = WebAccessApproval(approval: approval, approverName: HerdrUpAccount.deviceName,
                                    statement: { try await statements.statement(for: $0).jws },
                                    seqStore: UserDefaultsWebAccessSeqStore())
            expires = approval.expires
            phase = .waitingForBrowser
            waiting = Task { [weak self] in
                do {
                    try await approval.awaitReveal()
                    self?.phase = .enterCode
                } catch is CancellationError {
                } catch {
                    self?.phase = .ended(BrowserApproval.describe(error))
                }
            }
        } catch {
            phase = .ended(BrowserApproval.describe(error))
        }
    }

    /// The sheet closed: stop waiting, and remove the browser's key on any machine whose grant
    /// got no answer (such a grant is in no envelope, whatever the outcome).
    func stop() {
        waiting?.cancel()
        if let web { Task { _ = await web.cleanUp() } }
    }

    private func check(_ code: String) async {
        guard let web else { return }
        do {
            let result = try await web.checkCode(code)
            if result.ok {
                codeError = nil
                phase = .matched
            } else if result.left > 0 {
                typed = ""
                codeError = "That code doesn’t match the browser’s. \(result.left) \(result.left == 1 ? "try" : "tries") left."
            } else if result.denied {
                phase = .ended("That code didn’t match three times, so the request was denied.")
            } else {
                typed = ""
                codeError = nil
                problem = "That code didn’t match three times. Couldn’t tell the browser (\(result.denyFailure ?? "")): Deny to try again."
            }
        } catch {
            typed = ""
            codeError = BrowserApproval.describe(error)
        }
    }

    func approve() async {
        guard let web, canApprove else { return }
        let before = phase
        phase = .working
        problem = nil
        do {
            let result = try await web.approve(machines: chosenMachines, scope: scope, length: length)
            if result.unsure {
                unsure = true
                problem = (result.problem ?? "No answer from the account service.") + " Approve sends it again; Deny removes the access."
                phase = before
            } else if result.granted.isEmpty {
                problem = Self.lines(result).joined(separator: "\n")
                phase = before
            } else {
                unsure = false
                phase = .approved(result)
            }
        } catch {
            problem = Self.describe(error)
            if case BrowserApproval.Failure.ended = error {
                phase = .ended(problem ?? "")
            } else {
                phase = before
            }
        }
    }

    /// Denies the request. True when the sheet may close.
    func deny() async -> Bool {
        guard let web else { return true }
        let before = phase
        phase = .working
        do {
            try await web.deny()
            waiting?.cancel()
            return true
        } catch {
            problem = Self.describe(error)
            phase = before
            return false
        }
    }

    static func lines(_ result: WebAccessResult) -> [String] {
        var out: [String] = []
        if result.granted.isEmpty, !result.skipped.isEmpty || !result.failed.isEmpty {
            out.append("No machine took the access.")
        }
        out += result.skipped.map { "\($0.label) \($0.reason.description)." }
        out += result.failed.map { "\($0.label): \($0.reason)." }
        return out
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case WebAccessApproval.Failure.problem(let text): return text
        case WebAccessApproval.Failure.alreadyApproved:
            return "The browser was already approved. Remove it under Devices to take its access away."
        case WebAccessApproval.Failure.busy: return "Still working on this request."
        case WebAccessApproval.Failure.noMachines: return "Choose at least one machine."
        case WebAccessApproval.Failure.tooManyMachines: return "These machines don’t fit in one approval. Deselect some and try again."
        default: return BrowserApproval.describe(error)
        }
    }
}
