import Combine
import HerdrKit
import Network
import SwiftUI

/// Pairing this device from another one (pair-v1, DESIGN §13), the new device's side: it makes
/// its own SSH key, asks the account's other devices, shows the 4-digit code once one of them
/// claims the request, and saves the machines that device added the key to, each with the
/// host key it pinned. A machine the approver tries again later arrives as a newer envelope.
@MainActor
final class DevicePairing: ObservableObject {
    static let shared = DevicePairing()

    enum Phase: Equatable {
        case idle
        /// Sending the request.
        case asking
        /// Waiting for another device; the code shows once one claimed the request.
        case waiting(code: String?, approver: String?)
        /// Approved: the machines are saved.
        case approved(approver: String, added: Int)
        /// Not approved, expired, or a failure: a title and a line.
        case ended(title: String, message: String)
    }

    /// A machine this device got a key for, as PAIRED BY ‹approver› lists it.
    struct Paired: Identifiable, Equatable {
        enum Reach: Equatable { case checking, reachable, unreachable }
        let id: UUID
        let label: String
        let address: String
        var reach: Reach
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var expires = Date()
    /// The approver that answered last, for the section label.
    @Published private(set) var approverName: String?
    @Published private(set) var paired: [Paired] = []
    /// Machines the approver couldn't add the key to, by `identity`: the line their row shows.
    @Published private(set) var failures: [String: String] = [:]

    /// How often a newer envelope (a machine tried again) is looked for, and for how long after
    /// the approval (the service takes a retry for 10 minutes).
    static var retryPoll: UInt64 {
        #if DEBUG
        if ScreenshotMock.mode != nil { return 1_000_000_000 }
        #endif
        return 5_000_000_000
    }
    static let retryWindow: TimeInterval = 600

    private let account = HerdrUpAccount.shared
    private var task: Task<Void, Never>?

    private init() {}

    /// Whether this device can ask another one: signed in, enrolled, and the service offers
    /// `pair_v1`.
    var available: Bool {
        guard account.signedIn, account.health?.offers(AccountHealth.pairV1) == true else { return false }
        if case .enrolled = account.enrolment { return true }
        return false
    }

    var active: Bool {
        switch phase {
        case .asking, .waiting: return true
        default: return false
        }
    }

    /// Asks the account's other devices to pair this one (a fresh key and request each time).
    func ask() {
        task?.cancel()
        phase = .asking
        let session = account.session
        task = Task { [weak self] in
            do {
                let identity = try GuestDevice.identity()
                let requester = try await PairRequester.start(session: session, identity: identity,
                                                              keyComment: HerdrUpAccount.deviceName)
                guard let self, !Task.isCancelled else {
                    try? await requester.cancel()
                    return
                }
                self.requester = requester
                self.expires = requester.expires
                self.phase = .waiting(code: nil, approver: nil)
                let (code, approver) = try await requester.awaitCode()
                self.phase = .waiting(code: code, approver: approver)
                let result = try await requester.awaitResult()
                let added = self.apply(result, key: requester.sshKey.privateKeyPEM)
                self.phase = .approved(approver: result.approverName, added: added)
                await self.followRetries(requester)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self?.phase = Self.ended(error, approver: self?.approverName)
            }
        }
    }

    /// Cancel: stop waiting and withdraw the request, so an approver with it open is told it
    /// was cancelled and adds nothing.
    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
        if let requester {
            self.requester = nil
            Task { try? await requester.cancel() }
        }
    }

    /// The live request, for Cancel.
    private var requester: PairRequester?

    /// Done on the approved card: the card goes, the retry watch stays.
    func dismissCard() {
        if case .approved = phase { phase = .idle }
        if case .ended = phase { phase = .idle }
    }

    private func followRetries(_ requester: PairRequester) async {
        let until = Date().addingTimeInterval(Self.retryWindow)
        while Date() < until, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.retryPoll)
            guard let newer = try? await requester.newerResult() else { continue }
            _ = apply(newer, key: requester.sshKey.privateKeyPEM)
        }
    }

    private static func ended(_ error: Error, approver: String?) -> Phase {
        let who = approver ?? "Your other device"
        let kind = HerdrUpAccount.deviceKind
        let tail = "Ask again for a new code, or pair with herdr pair instead."
        switch error {
        case PairRequester.Failure.denied:
            return .ended(title: "Not approved", message: "\(who) didn’t approve this \(kind).\n\(tail)")
        case PairRequester.Failure.expired:
            return .ended(title: "The request expired", message: "No device approved this \(kind) in 10 minutes.\n\(tail)")
        default:
            return .ended(title: "Not paired", message: "\(PairRequester.describe(error))\n\(tail)")
        }
    }

    // MARK: Saving

    /// The account's rule for one machine: user, lowercased host without a trailing dot, port.
    static func identity(user: String, host: String, port: Int) -> String {
        var h = host.lowercased()
        if h.hasSuffix(".") { h.removeLast() }
        return "\(user)@\(h):\(port)"
    }

    static func identity(_ saved: SavedHost) -> String? {
        guard let endpoint = HostEndpoint.parse(saved.host) else { return nil }
        return identity(user: saved.username, host: endpoint.host, port: Int(endpoint.port))
    }

    /// Pins each added machine's host key, then saves the key S for it (on the saved machine
    /// with the same identity, or as a new one). Returns how many machines were saved.
    @discardableResult
    private func apply(_ result: PairResult, key pem: String) -> Int {
        approverName = result.approverName
        let store = SavedHostsStore.shared
        var saved = 0
        var probe: [Paired] = []
        for machine in result.machines {
            let id = Self.identity(user: machine.user, host: machine.host, port: machine.port)
            guard machine.status != .failed else {
                failures[id] = "\(result.approverName) couldn’t add the key: \(machine.reason ?? "it failed")"
                continue
            }
            guard let port = UInt16(exactly: machine.port),
                  let fingerprint = HostKeyRecorder.fingerprint(ofOpenSSHKey: machine.hostKey) else {
                failures[id] = "\(result.approverName) sent no usable host key for it"
                continue
            }
            let existing = store.hosts.first { Self.identity($0) == id }
            let pinHost = existing.flatMap { HostEndpoint.parse($0.host)?.host } ?? machine.host
            guard KeychainHostKeyPolicy.shared.pin(host: pinHost, port: port, fingerprint: fingerprint) else {
                failures[id] = "Couldn’t save its host key on this \(HerdrUpAccount.deviceKind)"
                continue
            }
            let savedID: UUID
            if let existing {
                guard store.update(existing, nickname: existing.nickname ?? "", host: existing.host,
                                   username: existing.username, secret: .key(pem)) else {
                    failures[id] = "Couldn’t save its key on this \(HerdrUpAccount.deviceKind)"
                    continue
                }
                savedID = existing.id
            } else {
                guard store.add(nickname: machine.nickname, host: Self.address(machine.host, port: machine.port),
                                username: machine.user, secret: .key(pem)),
                      let added = store.hosts.first else {
                    failures[id] = "Couldn’t save its key on this \(HerdrUpAccount.deviceKind)"
                    continue
                }
                savedID = added.id
            }
            failures[id] = nil
            saved += 1
            let label = store.hosts.first { $0.id == savedID }?.label ?? machine.nickname
            let entry = Paired(id: savedID, label: label, address: machine.host, reach: .checking)
            if let index = paired.firstIndex(where: { $0.id == savedID }) {
                paired[index] = entry
            } else {
                paired.append(entry)
            }
            probe.append(entry)
        }
        for entry in probe {
            guard let saved = store.hosts.first(where: { $0.id == entry.id }),
                  let endpoint = HostEndpoint.parse(saved.host) else { continue }
            Task { [weak self] in
                let reachable = await PairReachability.reachable(host: endpoint.host, port: endpoint.port)
                guard let self, let index = self.paired.firstIndex(where: { $0.id == entry.id }) else { return }
                self.paired[index].reach = reachable ? .reachable : .unreachable
            }
        }
        return saved
    }

    /// `host` or `host:port` as the saved list writes it (brackets around an IPv6 literal).
    static func address(_ host: String, port: Int) -> String {
        guard port != 22 else { return host }
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// The failure line for a saved machine, if the approver couldn't add the key there.
    func failure(for saved: SavedHost) -> String? {
        Self.identity(saved).flatMap { failures[$0] }
    }
}

/// Whether this device can open a TCP connection to a machine's SSH port right now.
enum PairReachability {
    static func reachable(host: String, port: UInt16, timeout: TimeInterval = 5) async -> Bool {
        #if DEBUG
        // A mock run opens no socket: every host answers but those listed.
        if ScreenshotMock.mode != nil {
            let unreachable = ProcessInfo.processInfo.environment["HERDR_MOCK_PAIR_UNREACHABLE"] ?? ""
            return !unreachable.split(separator: ",").contains { $0 == host }
        }
        #endif
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        return await withCheckedContinuation { continuation in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: true) }
                    connection.cancel()
                case .failed, .cancelled:
                    if once.claim() { continuation.resume(returning: false) }
                case .waiting:
                    if once.claim() { continuation.resume(returning: false) }
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: false) }
                connection.cancel()
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}

// MARK: - Views

/// "Pair this device": how to add this device's key to the account's machines.
struct PairThisDeviceSheet: View {
    let machineCount: Int
    let approveAvailable: Bool
    let onApprove: () -> Void
    let onQR: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let kind = HerdrUpAccount.deviceKind
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Pair this device").font(Typography.app(19, .semibold)).foregroundStyle(Palette.text)
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.capsule(.secondary))
                    .accessibilityIdentifier("pair-device-sheet-cancel")
            }
            Text("This \(kind) has \(machineCount) \(machineCount == 1 ? "machine" : "machines") from your account, but no key for \(machineCount == 1 ? "it" : "them") yet. Choose how to add one.")
                .font(Typography.app(15)).foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
            if approveAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Approve from another device", action: onApprove)
                        .buttonStyle(.capsule(.filled, .large, fullWidth: true))
                        .accessibilityIdentifier("pair-device-approve-option")
                    caption("Your other iPhone, iPad or Mac adds this \(kind)’s key to the machines you tick. Nothing to type on the machines.")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Button(action: onQR) {
                    Label("Use herdr pair (QR)", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.capsule(approveAvailable ? .secondary : .filled, .large, fullWidth: true))
                .accessibilityIdentifier("pair-device-qr-option")
                caption("On each machine run herdr pair, then scan the code it prints.")
            }
            caption("Machines that log in with a password switch to a key on this \(kind).")
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pair-device-sheet")
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(Typography.app(13)).foregroundStyle(Palette.textFaint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// PAIR THIS ‹DEVICE›: the request while it waits (the code, Cancel, the expiry and three
/// steps), and how it ended.
struct PairThisDeviceCard: View {
    @ObservedObject var pairing: DevicePairing
    let onQR: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch pairing.phase {
            case .idle:
                EmptyView()
            case .asking:
                status("Asking your account…")
            case .waiting(let code, _):
                waiting(code)
            case .approved(let approver, let added):
                Text("Approved on \(approver)").font(Typography.app(19, .semibold)).foregroundStyle(Palette.text)
                Text(added == 0
                     ? "\(approver) couldn’t add this \(HerdrUpAccount.deviceKind)’s key to any machine. The machines below say why."
                     : "This \(HerdrUpAccount.deviceKind) has its own key on \(added) \(added == 1 ? "machine" : "machines") now.")
                    .font(Typography.app(14)).foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Done") { pairing.dismissCard() }
                    .buttonStyle(.capsule(.secondary))
                    .accessibilityIdentifier("pair-device-done")
            case .ended(let title, let message):
                Text(title).font(Typography.app(19, .semibold)).foregroundStyle(Palette.text)
                    .accessibilityIdentifier("pair-device-ended")
                Text(message).font(Typography.app(14)).foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Ask again") { pairing.ask() }
                        .buttonStyle(.capsule(.filled))
                        .accessibilityIdentifier("pair-device-ask-again")
                    Button("Use herdr pair (QR)") {
                        pairing.dismissCard()
                        onQR()
                    }
                    .buttonStyle(.capsule(.secondary))
                    .accessibilityIdentifier("pair-device-use-qr")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsGroup(outline: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pair-device-card")
    }

    private func status(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(Palette.textDim)
            Text(text).font(Typography.app(14)).foregroundStyle(Palette.textDim)
        }
    }

    @ViewBuilder
    private func waiting(_ code: String?) -> some View {
        let name = HerdrUpAccount.deviceName
        let kind = HerdrUpAccount.deviceKind
        status("Waiting for your other device")
        Text("Approve on your iPhone, iPad or Mac").font(Typography.app(19, .semibold)).foregroundStyle(Palette.text)
        Text(code == nil
             ? "HerdrUp there asks to pair \(name). The code shows here once it opens the request."
             : "HerdrUp there asks to pair \(name). Type these 4 digits there.")
            .font(Typography.app(14)).foregroundStyle(Palette.textDim)
            .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 10) {
            ForEach(0..<4, id: \.self) { index in
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Palette.surfaceRaised)
                    if let code, index < code.count {
                        Text(String(Array(code)[index])).font(Typography.app(30, .medium)).monospacedDigit()
                            .foregroundStyle(Palette.text)
                    } else {
                        Circle().fill(Palette.textFaint).frame(width: 6, height: 6)
                    }
                }
                .frame(width: 52, height: 62)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("pair-device-code")
        .accessibilityLabel(code ?? "No code yet")
        HStack(spacing: 12) {
            Button("Cancel") { pairing.cancel() }
                .buttonStyle(.capsule(.secondary))
                .accessibilityIdentifier("pair-device-cancel")
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(pairing.expires.timeIntervalSince(context.date)))
                (Text("Expires in ").font(Typography.app(14)).foregroundColor(Palette.textDim)
                 + Text("\(left / 60):\(String(format: "%02d", left % 60))")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundColor(Palette.text))
            }
        }
        VStack(spacing: 0) {
            step(1, "Open HerdrUp", "On your iPhone, iPad or Mac, signed in to the same account.")
            step(2, "Pair \(name)?", "Opens by itself and names this \(kind).")
            step(3, code.map { "Type \($0)" } ?? "Type the code", "Then tick the machines and Approve.")
        }
        Text("This \(kind) made its own key. Your machines accept it only after you approve it.")
            .font(Typography.app(12.5)).foregroundStyle(Palette.textFaint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("\(number)").font(Typography.app(14, .semibold)).foregroundStyle(Palette.textDim)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typography.app(16)).foregroundStyle(Palette.text)
                Text(detail).font(Typography.app(13)).foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}
