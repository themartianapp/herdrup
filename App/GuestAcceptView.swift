import SwiftUI
import HerdrKit

/// Shared styling for the guest screens (mock row 2), taken from the mock's tokens.
enum GuestShellStyle {
    /// The name the host labels the guest's messages with ("<name> (via HerdrUp):"): plain
    /// ink, as on the desktop; the guest screens carry no decorative colour.
    static let label = Palette.text

    /// A section heading: mono micro-label and a quiet rule.
    static func section(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(Typography.machine(12, .semibold)).tracking(1.56)
                .foregroundStyle(Palette.textFaint)
            Rectangle().fill(Palette.hairlineQuiet).frame(height: 1)
        }
        .padding(.horizontal, 16)
    }

    /// An explanatory note: a neutral card (surface and hairline), dim text.
    static func note<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(Typography.app(13)).foregroundStyle(Palette.textDim)
            .lineSpacing(2.75)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 13.5)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.hairline, lineWidth: 1))
            .padding(.horizontal, 16)
    }

    /// A key/value row inside a card.
    static func keyValue<Value: View>(_ key: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 12) {
            Text(key).font(Typography.app(15)).foregroundStyle(Palette.textDim)
            Spacer(minLength: 8)
            value().lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    /// A surface card with quiet dividers between its rows.
    static func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.hairline, lineWidth: 1))
            .padding(.horizontal, 16)
    }

    static var divider: some View {
        Rectangle().fill(Palette.hairlineQuiet).frame(height: 1)
    }
}

/// Screen G1: what an invite grants and how the guest will be labeled, shown before
/// anything connects. Accept redeems the invite with this phone's key.
///
/// An invite whose host takes accounts (`acct`, DESIGN #698 §4) offers 2A instead of a plain
/// Accept: signed out, the account's own Continue with Apple / Google (1B) above "Continue on
/// this device only"; signed in, "Add to my account" (the share opens on every device of the
/// account) or "Only this device". Not now is the close circle, so the foot holds the choice.
struct GuestAcceptView: View {
    let invite: GuestInvite
    /// This phone's key fingerprint, when the key could be read.
    let fingerprint: String?
    /// Redeems the invite, bound to the signed-in account when asked. Injected so screenshot
    /// mocks never touch the network.
    let accept: (_ bindToAccount: Bool) async throws -> GuestAccess
    let onAccepted: (GuestAccess) -> Void
    let onCancel: () -> Void

    @ObservedObject private var account = HerdrUpAccount.shared
    /// Which button is redeeming: true for Add to my account.
    @State private var accepting: Bool?
    @State private var error: String?

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        hero
                        GuestShellStyle.section("Details").padding(.top, 26).padding(.bottom, 8)
                        details
                        GuestShellStyle.note { labelNote }.padding(.top, 14)
                        if let fingerprint {
                            Text("This phone's key: \(fingerprint)")
                                .font(Typography.machine(11.5)).foregroundStyle(Palette.textFaint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 30).padding(.top, 10)
                                .accessibilityIdentifier("guest-accept-fingerprint")
                        }
                    }
                    .padding(.bottom, 16)
                }
                .scrollBounceBehavior(.basedOnSize)
                footer
            }
            .overlay(alignment: .topLeading) {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.circle(diameter: 36))
                .disabled(accepting != nil)
                .padding(.leading, 16).padding(.top, 8)
                .accessibilityLabel("Not now")
                .accessibilityIdentifier("guest-accept-close")
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 0) {
            // The invite carries no avatar, so the card shows the agent's initial tile (herdrup#538).
            AgentAvatarView(agent: nil, name: invite.agentName, size: 72, glyphSize: 34)
            .padding(.bottom, 16)
            Text("\(invite.ownerName) shared \(invite.agentName) with you")
                .font(Typography.app(24, .bold)).tracking(-0.24)
                .foregroundStyle(Palette.text)
                .accessibilityIdentifier("guest-accept-title")
            Text("You'll be able to watch it work and send it messages and files from this phone.")
                .font(Typography.app(15)).foregroundStyle(Palette.textDim)
                .lineSpacing(3.5)
                .padding(.top, 8)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 24).padding(.top, 30)
    }

    private var details: some View {
        GuestShellStyle.card {
            GuestShellStyle.keyValue("Machine") {
                Text(invite.machineLabel).font(Typography.app(15)).foregroundStyle(Palette.text)
            }
            GuestShellStyle.divider
            GuestShellStyle.keyValue("Agent") {
                Text(invite.agentName).font(Typography.machine(13.5, .medium)).foregroundStyle(Palette.text)
            }
            GuestShellStyle.divider
            GuestShellStyle.keyValue("You appear as") {
                Text(invite.guestName).font(Typography.machine(13.5, .medium)).foregroundStyle(GuestShellStyle.label)
            }
        }
    }

    private var labelNote: Text {
        let tag = Text(GuestName.label(invite.guestName).trimmingCharacters(in: .whitespaces))
            .font(Typography.machine(13, .semibold)).foregroundStyle(GuestShellStyle.label)
        return Text("Every message you send reaches \(invite.agentName) starting with \(tag). \(invite.ownerName) can see what you send and can remove access at any time.")
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let error {
                Text(error)
                    .font(Typography.app(14)).foregroundStyle(Palette.died)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .accessibilityIdentifier("guest-accept-error")
            }
            if !invite.acceptsAccount {
                // A host that can't bind shares to an account: today's Accept.
                choice("Accept", .filled, bind: false, identifier: "guest-accept")
            } else if account.signedIn {
                signedInLine
                choice("Add to my account", .filled, bind: true, identifier: "guest-accept-account")
                choice("Only this device", .secondary, bind: false, identifier: "guest-accept-this-device")
            } else {
                Text("Keep it on all your devices")
                    .font(Typography.app(13)).foregroundStyle(Palette.textFaint)
                    .padding(.bottom, 2)
                AccountSignInButtons(account: account)
                choice("Continue on this device only", .secondary, bind: false, identifier: "guest-accept-this-device")
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
        .task { if invite.acceptsAccount, !account.signedIn { await account.loadHealth() } }
    }

    /// Who "Add to my account" adds the share to: the account email when this session knows
    /// one, else the provider.
    private var signedInLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle").font(.system(size: 13)).foregroundStyle(Palette.textDim)
            if let email = account.email {
                Text("Signed in as").foregroundStyle(Palette.textDim)
                Text(email).foregroundStyle(Palette.text).lineLimit(1).truncationMode(.middle)
            } else {
                Text(account.identityLine).foregroundStyle(Palette.textDim)
            }
        }
        .font(Typography.app(13))
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("guest-accept-signed-in")
    }

    /// One of the foot's capsules. 50 pt tall, the height of the account's Continue with Apple
    /// and Google beside them. A sign-in or first sync still running holds every choice.
    private func choice(_ title: String, _ variant: CapsuleVariant, bind: Bool, identifier: String) -> some View {
        Button { Task { await run(bind: bind) } } label: {
            ZStack {
                Text(title).opacity(accepting == bind ? 0 : 1)
                if accepting == bind { ProgressView().tint(variant.ink) }
            }
            .frame(minHeight: 50)
        }
        .buttonStyle(.capsule(variant, .large, fullWidth: true))
        .disabled(accepting != nil || account.busy != nil)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    private func run(bind: Bool) async {
        accepting = bind
        error = nil
        defer { accepting = nil }
        do {
            onAccepted(try await accept(bind))
        } catch {
            self.error = GuestDevice.describe(error, machine: invite.machineLabel)
        }
    }
}

/// Scans an invite QR code. The decoded text goes through the same `GuestInvite.resolve`
/// as a tapped or pasted link; a code that is not an invite says so and keeps scanning.
struct GuestInviteScanSheet: View {
    var onInvite: (GuestInvite) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var unavailable: QRScannerUnavailable?
    @State private var failure: String?
    /// Bumped after a rejected code, so capture restarts cleanly.
    @State private var generation = 0
    /// The scanned link being resolved (a short link's fetch); cancelled when the sheet goes.
    @State private var resolving: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.ground.ignoresSafeArea()
                if let unavailable {
                    Text(unavailableText(unavailable))
                        .font(Typography.app(14)).foregroundStyle(Palette.textDim)
                        .multilineTextAlignment(.center)
                        .padding(28)
                } else {
                    VStack(spacing: 16) {
                        QRScannerView(onFound: found, onUnavailable: { unavailable = $0 })
                            .id(generation)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        Text(failure ?? "Point the camera at the invite code someone shared with you.")
                            .font(Typography.app(14))
                            .foregroundStyle(failure == nil ? Palette.textDim : Palette.died)
                            .multilineTextAlignment(.center)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Scan invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") {
                        resolving?.cancel()
                        dismiss()
                    }.tint(Palette.text)
                }
            }
        }
        // Cancel or swipe-down while a short link is still fetching: nothing arrives later.
        .onDisappear {
            resolving?.cancel()
            resolving = nil
        }
    }

    /// A short link's sealed invite is fetched first; a failure (including no network)
    /// says why and restarts capture, so scanning again is the retry. A newer scan replaces
    /// one still resolving, and a cancelled one never delivers.
    private func found(_ text: String) {
        resolving?.cancel()
        resolving = Task { @MainActor in
            do {
                let invite = try await GuestInvite.resolve(text)
                guard !Task.isCancelled else { return }
                onInvite(invite)
                dismiss()
            } catch {
                guard !Task.isCancelled else { return }
                failure = GuestDevice.describe(error, machine: "")
                generation += 1
            }
        }
    }

    private func unavailableText(_ reason: QRScannerUnavailable) -> String {
        switch reason {
        case .permissionDenied: return "HerdrUp needs camera access to scan an invite. Turn it on in Settings, or paste the invite link instead."
        case .restricted: return "Camera access is restricted on this device. Paste the invite link instead."
        case .noCamera: return "This device has no camera to scan with. Paste the invite link instead."
        case .cameraFailed(let why): return "The camera couldn't start (\(why)). Paste the invite link instead."
        }
    }
}
