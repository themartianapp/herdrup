import Combine
import HerdrKit
import SwiftUI

/// Devices of this account asking to be paired with its machines (pair-v1, DESIGN §13). A
/// `pair_request` push opens the request; while the app is in the foreground, signed in, with
/// this device enrolled and the service offering `pair_v1`, the waiting requests are also
/// listed every few seconds, and "Pair ‹device›?" opens for a new one. Settings › HerdrUp
/// account lists them under REQUESTS.
@MainActor
final class PairApprovals: ObservableObject {
    static let shared = PairApprovals()

    /// Requests nobody has claimed yet, oldest first.
    @Published private(set) var requests: [PairRequest] = []
    /// The request the sheet is open on.
    @Published var presented: PairRequest?

    static let pollInterval: UInt64 = 5_000_000_000

    private let account = HerdrUpAccount.shared
    private var shown: Set<String> = []
    private var loop: Task<Void, Never>?
    /// A pushed request that arrived before the account was ready (a cold launch from the
    /// push): opened on the next refresh.
    private var pushed: String?
    private lazy var pushRegistration = AccountPushRegistration(session: account.session)

    private init() {}

    /// Whether the account can carry pair requests now.
    var available: Bool {
        guard account.signedIn, account.health?.offers(AccountHealth.pairV1) == true else { return false }
        if case .enrolled = account.enrolment { return true }
        return false
    }

    /// Whether the list poll is redundant on this device now: the approver sheet is open (it
    /// reads its own request), or this device is waiting on its own pair request. Every list
    /// read spends the account's approval budget, which the other devices and the pairing
    /// itself share, so the poll pauses meanwhile and resumes once the screen closes.
    var pollPaused: Bool { presented != nil || DevicePairing.shared.active }

    /// Starts or stops the foreground poll. A list refused for a spent budget is read again
    /// after a growing wait.
    func setActive(_ active: Bool) {
        loop?.cancel()
        loop = nil
        guard active else { return }
        loop = Task { [weak self] () async -> Void in
            var failures = 0
            while !Task.isCancelled {
                var wait = TimeInterval(Self.pollInterval) / 1_000_000_000
                if let self, !self.pollPaused {
                    if let error = await self.refresh(), BrowserApproval.rateLimited(error) {
                        failures = min(failures + 1, 5)
                        wait = BrowserApproval.backoff(wait, failures: failures, after: error)
                    } else {
                        failures = 0
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    /// Lists the waiting requests and opens the sheet for a new one. One `kind=any` read
    /// serves browsers too: their list goes to `WebAccessApprovals`, which doesn't poll itself
    /// while this one is available. Returns why the list couldn't be read.
    @discardableResult
    func refresh() async -> Error? {
        guard available else {
            requests = []
            return nil
        }
        if let id = pushed {
            pushed = nil
            await openPushed(id)
        }
        let inbox: ApprovalInbox
        do {
            inbox = try await PairApproval.inbox(session: account.session)
        } catch {
            return error
        }
        WebAccessApprovals.shared.take(inbox.browsers)
        requests = inbox.pairs.filter { $0.claimed == "no" }
        if presented == nil, let next = requests.first(where: { !shown.contains($0.id) }) {
            shown.insert(next.id)
            presented = next
        }
        return nil
    }

    /// A `pair_request` push named `id` (tapped, or arrived while in the foreground).
    func openPushed(_ id: String) async {
        guard available else {
            pushed = id
            return
        }
        guard presented?.id != id else { return }
        guard let request = try? await PairApproval.load(session: account.session, id: id) else { return }
        shown.insert(id)
        presented = request
    }

    /// Opens the sheet on `request` (from Settings).
    func open(_ request: PairRequest) {
        shown.insert(request.id)
        presented = request
    }

    /// The sheet closed.
    func closed(_ request: PairRequest) {
        if presented?.id == request.id { presented = nil }
        Task { await refresh() }
    }

    /// Tells the account service where to push pair requests: this device's PushRelay
    /// capability, sent once per device and capability.
    func registerPush() {
        #if DEBUG
        if ScreenshotMock.mode != nil { return }
        #endif
        guard available, case .enrolled(let device) = account.enrolment,
              let token = PushCenter.shared.deviceToken else { return }
        let registration = pushRegistration
        Task { () async -> Void in
            guard let capability = await PushCenter.relay.capability(kind: .device, token: token) else { return }
            _ = await registration.register(capability: capability, deviceID: device.id)
        }
    }

    /// Signed out: the next sign-in registers again.
    func forgetPush() {
        let registration = pushRegistration
        Task { await registration.forget() }
    }
}

/// One saved machine as the approver's checklist shows it.
struct PairApprovalEntry: Identifiable {
    let id: String
    let label: String
    /// Nil when this device has no key or password for it.
    let machine: PairMachine?
}

/// Where the approver's machines come from: every saved machine, each reached through its own
/// SSH session with a recorder that keeps the host key it trusted (sent to the new device).
@MainActor
enum PairApprovalMachines {
    static func current() -> [PairApprovalEntry] {
        #if DEBUG
        if ProcessInfo.processInfo.environment["HERDR_MOCK_ACCOUNT_PAIR"] == "approver" {
            return PairMachinesMock.entries()
        }
        #endif
        let store = SavedHostsStore.shared
        return store.hosts.compactMap { saved in
            guard let endpoint = HostEndpoint.parse(saved.host) else { return nil }
            guard case .ready(let credentials) = store.connection(for: saved) else {
                return PairApprovalEntry(id: saved.id.uuidString, label: saved.label, machine: nil)
            }
            let machine = PairMachine(id: saved.id.uuidString, label: saved.label, host: endpoint.host,
                                      port: Int(endpoint.port), user: saved.username,
                                      passwordLogin: saved.auth == .password) {
                var creds = credentials
                creds.session = nil   // pair.add_key is an owner call on the default session
                let recorder = HostKeyRecorder(KeychainHostKeyPolicy.shared)
                let transport = CitadelTransport(credentials: creds, hostKeyPolicy: recorder)
                return PairLink(client: HerdrClient(transport: transport), hostKey: { recorder.trustedKey },
                                close: { await transport.close() })
            }
            return PairApprovalEntry(id: saved.id.uuidString, label: saved.label, machine: machine)
        }
    }
}

/// One pair approval as the sheet runs it: claim, wait for the new device's reveal, check the
/// typed code (step 1), then add its key on the ticked machines and seal them to it (step 2).
@MainActor
final class PairApprovalModel: ObservableObject {
    enum Phase: Equatable {
        case starting
        /// Claimed; the new device shows its code in a moment.
        case waitingForDevice
        /// Step 1: type the code.
        case enterCode
        /// Step 2: tick the machines.
        case matched
        /// Adding the key, one machine at a time.
        case working
        /// Finished: what each machine did.
        case results
        /// Over: denied, expired, tampered, or answered elsewhere.
        case ended(String)
    }

    /// A machine's state in the checklist and the results.
    enum MachineState: Equatable {
        case checking
        case ready
        case unreachable
        case needsUpdate(String)
        case noSecret
        case waiting
        case adding
        case done(PairEnvelope.Machine.Status, String?)

        var usable: Bool { self == .ready }
    }

    let request: PairRequest
    let entries: [PairApprovalEntry]

    @Published private(set) var phase: Phase = .starting
    @Published var typed = "" {
        didSet {
            let digits = String(typed.filter(\.isNumber).prefix(4))
            if digits != typed { typed = digits }
        }
    }
    @Published private(set) var codeError: String?
    @Published private(set) var problem: String?
    /// The finish was sent but its outcome is unknown: Approve sends it again.
    @Published private(set) var unsure = false
    @Published private(set) var states: [String: MachineState] = [:]
    @Published var ticked: Set<String> = []
    @Published private(set) var expires: Date
    /// The machine "Try ‹machine› again" is running on.
    @Published private(set) var retrying: String?

    private var approval: PairApproval?
    private var links: [String: PairLink] = [:]
    private var untouched: Set<String>
    /// The envelope's machines, in checklist order.
    private var sent: [String: PairEnvelope.Machine] = [:]
    /// The label herdr stored beside the key (its reply's, not the one sent), for the results.
    @Published private(set) var storedLabel: String?
    private var waiting: Task<Void, Never>?
    private var checks: Task<Void, Never>?
    private var watch: Task<Void, Never>?

    init(request: PairRequest, entries: [PairApprovalEntry]) {
        self.request = request
        self.entries = entries
        untouched = Set(entries.map(\.id))
        expires = Date().addingTimeInterval(TimeInterval(request.expiresIn))
        for entry in entries { states[entry.id] = entry.machine == nil ? .noSecret : .checking }
    }

    var finished: Bool {
        switch phase {
        case .results, .ended: return true
        default: return false
        }
    }

    var chosen: [PairApprovalEntry] { entries.filter { ticked.contains($0.id) && states[$0.id]?.usable == true } }

    var canApprove: Bool { (phase == .matched && !chosen.isEmpty) || (unsure && phase != .working) }

    /// The machines the new device got (or not), for the results.
    var resultEntries: [PairApprovalEntry] { entries.filter { sent[$0.id] != nil } }

    /// The first machine that failed, for "Try ‹machine› again".
    var failedEntry: PairApprovalEntry? { resultEntries.first { sent[$0.id]?.status == .failed } }

    func failureReason(_ entry: PairApprovalEntry) -> String? { sent[entry.id]?.reason }

    func toggle(_ entry: PairApprovalEntry) {
        guard states[entry.id]?.usable == true, phase == .matched else { return }
        untouched.remove(entry.id)
        if ticked.contains(entry.id) { ticked.remove(entry.id) } else { ticked.insert(entry.id) }
    }

    func start() async {
        guard phase == .starting else { return }
        startChecks()
        do {
            let identity = try GuestDevice.identity()
            let approval = try await PairApproval.start(session: HerdrUpAccount.shared.session, identity: identity,
                                                        request: request)
            self.approval = approval
            expires = approval.expires
            phase = .waitingForDevice
            waiting = Task { [weak self] () async -> Void in
                do {
                    try await approval.awaitReveal()
                    self?.phase = .enterCode
                    self?.watchOpen(approval)
                } catch is CancellationError {
                } catch {
                    self?.phase = .ended(Self.endedLine(error))
                }
            }
        } catch {
            phase = .ended(Self.endedLine(error))
        }
    }

    /// Probes every machine while the code is typed: reachable ones are ticked (unless the
    /// user already changed them) and keep their connection for the add.
    private func startChecks() {
        checks = Task { [weak self] () async -> Void in
            guard let entries = self?.entries else { return }
            await withTaskGroup(of: (String, PairMachineCheck, PairLink?).self) { group in
                for entry in entries {
                    guard let machine = entry.machine else { continue }
                    let id = entry.id
                    group.addTask {
                        let (check, link) = await PairMachines.check(machine)
                        return (id, check, link)
                    }
                }
                for await (id, check, link) in group {
                    guard let self else {
                        await link?.close()
                        continue
                    }
                    self.record(id: id, check: check, link: link)
                }
            }
        }
    }

    private func record(id: String, check: PairMachineCheck, link: PairLink?) {
        switch check {
        case .ready:
            states[id] = .ready
            links[id] = link
            if untouched.contains(id) { ticked.insert(id) }
        case .unreachable:
            states[id] = .unreachable
        case .needsUpdate(let version):
            states[id] = .needsUpdate(version)
        }
    }

    /// While the code is typed and the machines ticked, the request is read on the foreground
    /// poll's cadence: a cancel or an expiry ends the sheet as soon as the service says so.
    private func watchOpen(_ approval: PairApproval) {
        watch?.cancel()
        watch = Task { [weak self] () async -> Void in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.watchInterval)
                guard let self, !Task.isCancelled, !self.finished else { return }
                guard self.phase == .enterCode || self.phase == .matched else { continue }
                do {
                    try await approval.stillOpen()
                } catch let error where error is BrowserApproval.Failure {
                    guard self.phase == .enterCode || self.phase == .matched else { continue }
                    self.phase = .ended(Self.endedLine(error))
                    return
                } catch {
                    // A failed read: the next one tells.
                }
            }
        }
    }

    private static var watchInterval: UInt64 {
        #if DEBUG
        if ScreenshotMock.mode != nil { return 1_000_000_000 }
        #endif
        return PairApprovals.pollInterval
    }

    /// The sheet closed: stop waiting and close the connections.
    func stop() {
        waiting?.cancel()
        checks?.cancel()
        watch?.cancel()
        let open = Array(links.values)
        links = [:]
        Task { for link in open { await link.close() } }
    }

    func checkCode() async {
        guard let approval, phase == .enterCode, typed.count == 4 else { return }
        do {
            let result = try await approval.checkCode(typed)
            if result.ok {
                codeError = nil
                phase = .matched
            } else if result.left > 0 {
                typed = ""
                codeError = "That code doesn’t match. \(result.left) \(result.left == 1 ? "try" : "tries") left."
            } else if result.denied {
                phase = .ended("That code didn’t match three times, so the request was denied.")
            } else {
                typed = ""
                codeError = nil
                problem = "That code didn’t match three times. Couldn’t tell the other device (\(result.denyFailure ?? "")): Deny to try again."
            }
        } catch {
            typed = ""
            codeError = BrowserApproval.describe(error)
        }
    }

    /// Adds the key on each ticked machine, one at a time, then seals the list to the new
    /// device and finishes the request.
    func approve() async {
        guard let approval, canApprove else { return }
        let before = phase
        phase = .working
        problem = nil
        if !unsure {
            // A request the new device cancelled (or that ended) adds nothing.
            do {
                try await approval.stillOpen()
            } catch let error where error is BrowserApproval.Failure {
                phase = .ended(Self.endedLine(error))
                return
            } catch {
                // A failed read: the finish tells.
            }
            let machines = chosen
            for entry in machines { states[entry.id] = .waiting }
            let label = PairMachines.label(requester: request.device.name, approver: HerdrUpAccount.deviceName)
            for entry in machines {
                guard let machine = entry.machine else { continue }
                states[entry.id] = .adding
                let added = await PairMachines.add(machine, link: links[entry.id],
                                                   publicKeyLine: approval.publicKeyLine, label: label)
                record(added, for: entry)
            }
        }
        do {
            try await approval.approve(envelope())
            unsure = false
            phase = .results
        } catch let error as BrowserApproval.OutcomeUnknown {
            unsure = true
            problem = "\(BrowserApproval.describe(error.reason)) Approve sends it again; Deny ends the request."
            phase = before
        } catch {
            problem = BrowserApproval.describe(error)
            let reason = (error as? BrowserApproval.NotRecorded)?.reason ?? error
            if let failure = reason as? BrowserApproval.Failure, failure == .ended || failure == .cancelled {
                phase = .ended(Self.endedLine(failure))
            } else {
                phase = before
            }
        }
    }

    /// "Try ‹machine› again": adds the key there once more and sends the new list (a higher seq).
    func retry(_ entry: PairApprovalEntry) async {
        guard let approval, let machine = entry.machine, retrying == nil else { return }
        retrying = entry.id
        problem = nil
        states[entry.id] = .adding
        let label = PairMachines.label(requester: request.device.name, approver: HerdrUpAccount.deviceName)
        let added = await PairMachines.add(machine, link: links[entry.id], publicKeyLine: approval.publicKeyLine,
                                           label: label)
        record(added, for: entry)
        do {
            try await approval.resend(envelope())
        } catch {
            problem = "Couldn’t send it to \(request.device.name): \(BrowserApproval.describe(error))"
        }
        retrying = nil
    }

    private func record(_ added: PairMachines.Added, for entry: PairApprovalEntry) {
        links[entry.id] = added.link
        sent[entry.id] = added.machine
        states[entry.id] = .done(added.machine.status, added.machine.reason)
        if let stored = added.storedLabel, !stored.isEmpty { storedLabel = stored }
    }

    private func envelope() -> PairEnvelope {
        PairEnvelope(machines: entries.compactMap { sent[$0.id] })
    }

    /// Denies the request. True when the sheet may close.
    func deny() async -> Bool {
        guard let approval else { return true }
        let before = phase
        phase = .working
        do {
            try await approval.deny()
            waiting?.cancel()
            return true
        } catch {
            problem = BrowserApproval.describe(error)
            phase = before
            return false
        }
    }

    private static func endedLine(_ error: Error) -> String {
        switch error {
        case BrowserApproval.Failure.ended: return "This request ended: it was answered elsewhere, or it expired before anyone approved it."
        case BrowserApproval.Failure.cancelled: return "This request was cancelled."
        default: return BrowserApproval.describe(error)
        }
    }

    /// "HerdrUp on macOS", for the sheet's first line.
    var deviceLine: String {
        switch request.device.platform {
        case "macos": return "HerdrUp on macOS"
        case "ios": return "HerdrUp on iOS"
        case "ipados": return "HerdrUp on iPadOS"
        case "linux": return "HerdrUp Desktop on Linux"
        case "windows": return "HerdrUp Desktop on Windows"
        default: return "HerdrUp on \(request.device.platform)"
        }
    }
}
