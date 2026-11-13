import HerdrKit
import SwiftUI
import UIKit

// MARK: - Adapters

/// The app's real store, seen through the coordinator's protocol.
///
/// `add` already has the contract the coordinator needs: it persists the secret FIRST and
/// returns false WITHOUT recording the host if that fails, so a false here never leaves a
/// half-written host behind.
extension SavedHostsStore: PairingCoordinator.HostStore {
    @MainActor
    func addPairedHost(nickname: String, host: String, username: String,
                       privateKeyPEM: String) -> Bool {
        add(nickname: nickname, host: host, username: username, secret: .key(privateKeyPEM))
    }
}

/// The app's real pin store, seen through the coordinator's protocol. The signature already
/// matches; this states the conformance rather than re-implementing anything.
extension KeychainHostKeyPolicy: PairingCoordinator.HostKeyPinner {}

// MARK: - Routing

/// A pairing sheet to show: the scanner (`payload` nil), or the confirmation for a code
/// that arrived as a link or a paste. Identifiable so a second link opened while one is
/// showing replaces it rather than being ignored.
struct PendingPairing: Identifiable {
    let id = UUID()
    let payload: Pairing.Payload?
}

/// Where every pairing enters the app (the scan button, a paste, a `herdrup://pair#` link).
/// RootView presents the ONE pairing sheet from here, so a link opened while the scanner is
/// up replaces it instead of failing to present over it. It routes the presentation only:
/// what happens after pairing is the sheet's `onPaired`, handled by RootView.
@MainActor
final class PairingRouter: ObservableObject {
    static let shared = PairingRouter()

    @Published var pending: PendingPairing?
    /// Why the last link or paste could not be read, shown as an alert.
    @Published var failure: String?

    /// Opens the scanner.
    func scan() { pending = PendingPairing(payload: nil) }

    /// Reads `text` (a link or the raw JSON) and shows its confirmation, or says why not.
    /// Never connects: that takes the Connect on the confirmation.
    func open(_ text: String) {
        do {
            pending = PendingPairing(payload: try Pairing.parse(code: text))
            failure = nil
        } catch {
            failure = ((error as? Pairing.Error) ?? .notAPairingCode).userFacingMessage
        }
    }

    static func isPairingLink(_ url: URL) -> Bool {
        Pairing.isPairingLink(url.absoluteString)
    }
}

// MARK: - The sheet

/// Scan or paste a pairing code, check what it is, and connect.
///
/// This view owns the CAMERA and the PHASES. It owns no pairing logic: parsing is
/// `Pairing.parse`, and everything after the person confirms is `PairingCoordinator` — both
/// in HerdrKit, both tested. What is left here is deliberately the part with no decisions
/// in it, because this file cannot be built or run on the machine it was written on.
struct PairingSheet: View {
    @ObservedObject var store: SavedHostsStore
    /// The machine this phone is connected to now, if any. Pairing does not drop it; the
    /// person is asked before switching to the new one.
    var activeConnection: String? = nil
    /// Called with the paired host's nickname once the person chooses to open it.
    var onPaired: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .scanning
    /// Bumped to rebuild the scanner after a failure, which restarts capture cleanly
    /// rather than reaching into the controller.
    @State private var scannerGeneration = 0
    /// The typed or pasted code in the fallback field.
    @State private var typedCode = ""

    /// `initialPayload`: a code that arrived as a link or a paste; the sheet opens on its
    /// confirmation instead of the camera.
    init(store: SavedHostsStore, initialPayload: Pairing.Payload? = nil,
         activeConnection: String? = nil, onPaired: @escaping (String) -> Void) {
        self.store = store
        self.activeConnection = activeConnection
        self.onPaired = onPaired
        _phase = State(initialValue: initialPayload.map(Phase.confirm) ?? .scanning)
    }

    private enum Phase: Equatable {
        case scanning
        case unavailable(QRScannerUnavailable)
        /// A valid code, waiting for the person's Connect. Nothing is sent before it.
        case confirm(Pairing.Payload)
        case pairing
        case failed(String)
        case paired(String)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.ground.ignoresSafeArea()
                content
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Palette.textDim)
                }
            }
        }
    }

    private var title: String {
        if case .confirm = phase { return "Pair this machine?" }
        return "Scan to connect"
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .scanning:
            scanner
        case .unavailable(let reason):
            ScrollView {
                VStack(spacing: 0) {
                    message(
                        title: "Can't use the camera",
                        body: reason.message + " Or paste the pairing code.",
                        systemImage: "camera.fill",
                        tint: Palette.textDim,
                        primary: reason.offersSettings ? ("Open Settings", openSettings) : nil)
                    pasteSection.padding(.horizontal, 20)
                }
            }
        case .confirm(let payload):
            confirmation(payload)
        case .pairing:
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(Palette.text)
                Text("Connecting…").font(Typography.app(15)).foregroundStyle(Palette.textDim)
            }
        case .failed(let why):
            message(
                title: "Pairing didn't work",
                body: why,
                systemImage: "exclamationmark.triangle.fill",
                tint: Palette.died,
                primary: ("Try again", { phase = .scanning; scannerGeneration += 1 }))
        case .paired(let nickname):
            // Pairing only authorises this phone; it doesn't start herdr, so say how.
            message(
                title: "Connected",
                body: "\(nickname) is saved on this device. If herdr isn't running on that "
                    + "computer yet, start it there:"
                    + (activeConnection.map {
                        "\n\nOpening it closes \($0)." } ?? ""),
                systemImage: "checkmark.seal.fill",
                tint: Palette.done,
                command: HerdrSetup.startCommand,
                primary: ("Open it", { dismiss(); onPaired(nickname) }),
                secondary: activeConnection.map { ("Stay on \($0)", { dismiss() }) })
        }
    }

    private var scanner: some View {
        ScrollView {
            VStack(spacing: 0) {
                ZStack {
                    QRScannerView(onFound: handleCode, onUnavailable: { phase = .unavailable($0) })
                        .id(scannerGeneration)
                    // A frame to aim with. Without one people hold the phone too close and the
                    // code never fills the sensor, which reads as "the scanner is broken".
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Palette.text.opacity(0.85), lineWidth: 3)
                        .frame(width: 230, height: 230)
                        .allowsHitTesting(false)
                }
                .frame(height: 360)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20)

                pasteSection
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                PairingCommandGuidance()
                    .padding(20)
            }
        }
    }

    /// Pasting instead of scanning: a page (Deimos Forge) can offer "Copy pairing code" next
    /// to its QR. The system PasteButton reads the clipboard only when tapped, so there is no
    /// "Allow Paste" prompt; the field is the fallback for typing or a long-press paste.
    private var pasteSection: some View {
        VStack(spacing: 10) {
            PasteButton(payloadType: String.self) { items in
                Task { @MainActor in
                    if let text = items.first { handleCode(text) }
                }
            }
            .labelStyle(.titleAndIcon)
            .tint(Palette.surfaceRaised)
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
            .accessibilityLabel("Paste pairing code")
            .accessibilityIdentifier("pairing-paste-button")

            HStack(spacing: 8) {
                TextField("Or paste the code here", text: $typedCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(Typography.machine(13))
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
                    .submitLabel(.go)
                    .onSubmit(useTypedCode)
                    .accessibilityIdentifier("pairing-code-field")
                Button("Use", action: useTypedCode)
                    .disabled(typedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .foregroundStyle(Palette.text)
                    .accessibilityIdentifier("pairing-code-submit")
            }
        }
    }

    /// What the code says, before anything is sent: the machine, the login, and the host key
    /// the connection will be pinned to. The token is never shown.
    private func confirmation(_ payload: Pairing.Payload) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("This code pairs this device with a machine. Connect only if you "
                     + "started pairing on it.")
                    .font(Typography.app(14)).foregroundStyle(Palette.textDim)
                VStack(alignment: .leading, spacing: 12) {
                    confirmRow("Host", payload.host, id: "pairing-confirm-host")
                    confirmRow("User", payload.user, id: "pairing-confirm-user")
                    confirmRow("SSH port", String(payload.sshPort ?? 22), id: "pairing-confirm-port")
                    confirmRow("Host key",
                               payload.fp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                   ? "Not reported by the machine" : payload.fp,
                               id: "pairing-confirm-fingerprint")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                if let activeConnection {
                    Text("You're connected to \(activeConnection). Pairing keeps that "
                         + "connection; you choose whether to switch afterwards.")
                        .font(Typography.app(13)).foregroundStyle(Palette.textDim)
                        .accessibilityIdentifier("pairing-confirm-active")
                }
                Button { connect(payload) } label: {
                    Text("Connect").font(Typography.app(16, .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Palette.text).foregroundStyle(Palette.ground)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pairing-confirm-connect")
            }
            .padding(24)
        }
    }

    private func confirmRow(_ label: String, _ value: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(Typography.app(11, .semibold)).tracking(1.2)
                .foregroundStyle(Palette.textDim)
            Text(value).font(Typography.machine(14)).foregroundStyle(Palette.text)
                .textSelection(.enabled)
                .accessibilityIdentifier(id)
        }
    }

    private func message(
        title: String, body: String, systemImage: String, tint: Color,
        command: String? = nil,
        primary: (String, () -> Void)?,
        secondary: (String, () -> Void)? = nil
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage).font(.system(size: 40)).foregroundStyle(tint)
            Text(title).font(Typography.app(19, .semibold)).foregroundStyle(Palette.text)
            Text(body).font(Typography.app(14)).foregroundStyle(Palette.textDim)
                .multilineTextAlignment(.center)
            if let command {
                CopyableCommand(command: command)
            }
            if let (label, action) = primary {
                Button(action: action) {
                    Text(label).font(Typography.app(16, .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Palette.text).foregroundStyle(Palette.ground)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            if let (label, action) = secondary {
                Button(label, action: action)
                    .font(Typography.app(15)).foregroundStyle(Palette.textDim)
            }
        }
        .padding(28)
    }

    // MARK: - Actions

    /// A scanned, pasted or typed string. Parsing happens FIRST and on this thread, because
    /// it is cheap and because a QR that is not a pairing code (a URL, a wifi code — a camera
    /// reports whatever is in frame) must not put the sheet into a state it then has to back
    /// out of. A valid code goes to the confirmation; nothing is sent before Connect.
    private func handleCode(_ raw: String) {
        do {
            phase = .confirm(try Pairing.parse(code: raw))
            typedCode = ""
        } catch let error as Pairing.Error {
            phase = .failed(error.userFacingMessage)
        } catch {
            phase = .failed(Pairing.Error.notAPairingCode.userFacingMessage)
        }
    }

    private func useTypedCode() {
        let code = typedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        handleCode(code)
    }

    private func connect(_ payload: Pairing.Payload) {
        phase = .pairing
        let coordinator = PairingCoordinator(store: store, pinner: KeychainHostKeyPolicy.shared)
        let label = UIDevice.current.name
        // Not in a detached task: `completePairing` is `@MainActor`, and sends only the
        // blocking socket round trip off the main thread. The pin and the store write stay
        // on it, because `addPairedHost` mutates an `@Published` property and SwiftUI does
        // not allow that from a background thread (#664).
        Task {
            do {
                let nickname = try await coordinator.completePairing(
                    payload: payload, deviceLabel: label)
                phase = .paired(nickname)
            } catch let failure as PairingCoordinator.Failure {
                phase = .failed(failure.userFacingMessage)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// The command help below the camera, split out so the exact first-run guidance has a
/// deterministic UI-test surface without requiring camera hardware in CI.
struct PairingCommandGuidance: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("On your computer, run")
                .font(Typography.app(13))
                .foregroundStyle(Palette.textDim)
            Text(HerdrSetup.pairCommand)
                .font(Typography.machine(16, .semibold))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text("then point the camera at the code it prints.")
                .font(Typography.app(13)).foregroundStyle(Palette.textDim)

            VStack(spacing: 3) {
                Text("QR looks distorted? Open a clean version with")
                Text(HerdrSetup.openQRCommand)
                    .font(Typography.machine(12, .medium))
                    .foregroundStyle(Palette.text)
                Text("Or save an SVG with")
                    .padding(.top, 2)
                Text(HerdrSetup.saveQRCommand)
                    .font(Typography.machine(11, .medium))
                    .foregroundStyle(Palette.text)
            }
            .font(Typography.app(11.5))
            .foregroundStyle(Palette.textFaint)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("pairing-qr-fallback")
        }
        .multilineTextAlignment(.center)
    }
}
