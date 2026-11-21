import AuthenticationServices
import HerdrKit
import SwiftUI

// MARK: Onboarding 1B (#698): sign in on the first screen

/// Shows the first-launch sign-in (1B) in front of the machine list while this device has no
/// account, no saved machine and no share, until it is answered. Anyone already set up, and
/// anyone who chose "Set up without an account", gets `content` (today's machine list).
struct AccountOnboardingGate<Content: View>: View {
    @ObservedObject private var account = HerdrUpAccount.shared
    @ObservedObject private var hosts = SavedHostsStore.shared
    @ObservedObject private var shares = SharedMachinesStore.shared
    @ViewBuilder var content: () -> Content

    var body: some View {
        if account.shouldOnboard(hasMachines: !hosts.hosts.isEmpty, hasShares: !shares.machines.isEmpty) {
            AccountOnboardingView(account: account)
        } else {
            content()
        }
    }
}

/// 1B, phone and iPad: the app mark, one line on what an account brings, then Continue with
/// Apple, Continue with Google (each only when the service offers it, DESIGN §2.1) and
/// "Set up without an account", which opens today's machine list unchanged.
struct AccountOnboardingView: View {
    @ObservedObject var account: HerdrUpAccount

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 40)
                Image("AppLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .accessibilityHidden(true)
                Text("HerdrUp")
                    .font(Typography.app(30, .bold))
                    .foregroundStyle(Palette.text)
                    .padding(.top, 22)
                    .accessibilityAddTraits(.isHeader)
                Text("Sign in to bring your machines, prompts and settings to this \(HerdrUpAccount.deviceKind).")
                    .font(Typography.app(16))
                    .foregroundStyle(Palette.textDim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                    .padding(.top, 10)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 32)
                VStack(spacing: 12) {
                    if account.busy == .syncing {
                        AccountProgressLine(text: "Bringing your machines…")
                    } else {
                        AccountSignInButtons(account: account)
                    }
                    Button { account.skipOnboarding() } label: {
                        Text("Set up without an account")
                            .font(Typography.app(16, .semibold))
                            .foregroundStyle(Palette.text)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .overlay(Capsule().stroke(Palette.hairline, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(account.busy != nil)
                    .accessibilityIdentifier("account-skip")
                }
                .padding(.bottom, 22)
                Text("Keys and pairing secrets stay on this \(HerdrUpAccount.deviceKind). You can sign in later in Settings.")
                    .font(Typography.app(12))
                    .foregroundStyle(Palette.textFaint)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 310)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
            .readableColumn(420)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account-onboarding")
        .task { await account.loadHealth() }
    }
}

/// The providers this build and the service offer, as the 1B buttons. Shared by onboarding
/// and the signed-out account page.
struct AccountSignInButtons: View {
    @ObservedObject var account: HerdrUpAccount

    var body: some View {
        VStack(spacing: 12) {
            if account.offersApple {
                AppleContinueButton(busy: account.busy == .signingIn(.apple)) {
                    Task { await account.signIn(.apple) }
                }
                .frame(height: 50)
                .disabled(account.busy != nil)
            }
            if account.offersGoogle {
                Button { Task { await account.signIn(.google) } } label: {
                    HStack(spacing: 10) {
                        if account.busy == .signingIn(.google) {
                            ProgressView().tint(.black)
                        } else {
                            Text("G").font(.system(size: 19, weight: .bold, design: .rounded))
                                .foregroundStyle(Color(red: 0.26, green: 0.52, blue: 0.96))
                                .accessibilityHidden(true)
                        }
                        Text("Continue with Google").font(Typography.app(17, .semibold)).foregroundStyle(.black)
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Color.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(account.busy != nil)
                .accessibilityIdentifier("account-continue-google")
            }
            if account.health == nil && !account.healthFailed {
                AccountProgressLine(text: "Checking sign-in…")
            } else if !account.offersApple && !account.offersGoogle {
                Button { Task { await account.loadHealth() } } label: {
                    Text("Sign-in isn't available right now. Try again")
                        .font(Typography.app(14)).foregroundStyle(Palette.textDim)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("account-signin-unavailable")
            }
        }
    }
}

/// Apple's own "Continue with Apple" button (`ASAuthorizationAppleIDButton`), as Apple's
/// guidelines ask. It only starts `action`: the request itself waits for the service's nonce
/// (`HerdrUpAccount.signIn`), which a SwiftUI `SignInWithAppleButton` can't.
private struct AppleContinueButton: UIViewRepresentable {
    var busy: Bool
    var action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(authorizationButtonType: .continue, authorizationButtonStyle: .white)
        button.cornerRadius = 25
        button.accessibilityIdentifier = "account-continue-apple"
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) {
        context.coordinator.action = action
        button.alpha = busy ? 0.6 : 1
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tapped() { action() }
    }
}

private struct AccountProgressLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().tint(Palette.textDim)
            Text(text).font(Typography.app(15)).foregroundStyle(Palette.textDim)
        }
        .frame(maxWidth: .infinity, minHeight: 50)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("account-progress")
    }
}

// MARK: Settings › HerdrUp account

/// The account page's body (Settings › HerdrUp account). Signed out: what an account does and
/// the sign-in buttons. Signed in: who, what syncs, this device and the others (rename,
/// remove), Sign out, and Delete account (DESIGN §6.1).
struct HerdrUpAccountContent: View {
    @ObservedObject var account: HerdrUpAccount
    @ObservedObject private var hosts = SavedHostsStore.shared
    @ObservedObject private var prompts = SavedPromptsStore.shared
    @State private var renaming: AccountDevice?
    @State private var newName = ""
    @State private var removing: AccountDevice?
    @State private var confirmSignOut = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if account.signedIn {
                signedIn
            } else {
                signedOut
            }
        }
        .padding(.top, 8)
        .task {
            if account.health == nil { await account.loadHealth() }
            if account.signedIn { await account.refreshDevices() }
        }
        .onAppear { account.screenVisible = true }
        .onDisappear { account.screenVisible = false }
        .accountNoticeAlert(account)
        .alert("Rename device", isPresented: $renaming.isPresent()) {
            TextField("Name", text: $newName)
                .accessibilityIdentifier("account-rename-field")
            Button("Rename") {
                if let device = renaming { Task { await account.renameDevice(device, to: newName) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(removing.map { "Remove \($0.name)?" } ?? "", isPresented: $removing.isPresent(),
                            titleVisibility: .visible, presenting: removing) { device in
            Button("Remove device", role: .destructive) { Task { await account.removeDevice(device) } }
            Button("Cancel", role: .cancel) {}
        } message: { device in
            Text(device.current
                 ? "This signs this \(HerdrUpAccount.deviceKind) out of the account. Its machines and prompts stay here."
                 : "\(device.name) is signed out of the account and can no longer open shares bound to it.")
        }
        .confirmationDialog("Sign out of your HerdrUp account?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await account.signOut() } }
                .accessibilityIdentifier("account-confirm-sign-out")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your machines and prompts stay on this \(HerdrUpAccount.deviceKind). Changes stop syncing until you sign in again.")
        }
        .confirmationDialog("Delete your HerdrUp account?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) { Task { await account.deleteAccount() } }
                .accessibilityIdentifier("account-confirm-delete")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the account, its devices and everything synced to it. \(deleteProviderLine) Your machines and prompts stay on this \(HerdrUpAccount.deviceKind).")
        }
    }

    private var deleteProviderLine: String {
        account.profile?.provider == .google
            ? "To confirm, sign in with Google again."
            : "To confirm, sign in with Apple again."
    }

    // MARK: Signed out

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Sign in to bring your machines and prompts to every device you use. Keys, passwords and pairing secrets never leave this \(HerdrUpAccount.deviceKind).")
                .font(Typography.app(15)).foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("account-signed-out")
            AccountSignInButtons(account: account)
            if account.busy == .syncing { AccountProgressLine(text: "Bringing your machines…") }
        }
        .padding(.horizontal, DesignTokens.Space.screenInset + 4)
        .padding(.top, 12)
    }

    // MARK: Signed in

    @ViewBuilder
    private var signedIn: some View {
        group(nil) {
            row(account.identityLine, systemImage: "person.crop.circle.fill",
                subtitle: account.profile?.provider == .google ? "Google" : "Apple") { EmptyView() }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("account-identity")
        }
        group("SYNCED") {
            row("Machines", systemImage: "desktopcomputer") { value("\(syncedCount(.hosts))") }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("account-synced-machines")
            divider
            row("Prompts", systemImage: "text.bubble") { value("\(syncedCount(.prompts))") }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("account-synced-prompts")
            divider
            Button { account.syncNow() } label: {
                row(account.syncing ? "Syncing…" : "Sync now", systemImage: "arrow.triangle.2.circlepath",
                    subtitle: lastSyncLine) {
                    if account.syncing { ProgressView().tint(Palette.textDim) }
                }
            }
            .buttonStyle(.plain)
            .disabled(account.syncing)
            .accessibilityIdentifier("account-sync-now")
        }
        footnote("Keys, passwords and host-key pins stay on each device. A machine from your account asks for its key or a pairing the first time you open it here.")
        group("DEVICES") {
            if case .failed(let code) = account.enrolment {
                Button { Task { await account.enrolThisDevice() } } label: {
                    row("This \(HerdrUpAccount.deviceKind) isn't added", systemImage: "exclamationmark.triangle",
                        subtitle: enrolmentProblem(code)) {
                        Text("Try again").font(Typography.app(15)).foregroundStyle(Palette.textDim)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("account-enrolment-failed")
                if !account.devices.isEmpty { divider }
            }
            ForEach(Array(account.devices.enumerated()), id: \.element.id) { index, device in
                if index > 0 { divider }
                deviceRow(device)
            }
            if account.devices.isEmpty, account.enrolment == .enrolling || account.enrolment == .unknown {
                row("Loading devices…", systemImage: "iphone") { ProgressView().tint(Palette.textDim) }
            }
        }
        group(nil) {
            Button { confirmSignOut = true } label: {
                row("Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
                    if account.busy == .signingOut { ProgressView().tint(Palette.textDim) }
                }
            }
            .buttonStyle(.plain)
            .disabled(account.busy != nil)
            .accessibilityIdentifier("account-sign-out")
        }
        group(nil) {
            Button { confirmDelete = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "trash").font(.system(size: 18)).frame(width: 24, height: 24)
                    Text("Delete account").font(Typography.app(17))
                    Spacer(minLength: 8)
                    if account.busy == .deleting { ProgressView().tint(Palette.died) }
                }
                .foregroundStyle(Palette.died)
                .padding(.horizontal, 16).frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(account.busy != nil)
            .accessibilityIdentifier("account-delete")
        }
        footnote("Deleting removes the account and everything synced to it from HerdrUp's servers. Machines and prompts stay on this \(HerdrUpAccount.deviceKind).")
    }

    private func deviceRow(_ device: AccountDevice) -> some View {
        row(device.name, systemImage: Self.icon(for: device.platform),
            subtitle: device.current ? "This \(HerdrUpAccount.deviceKind)" : Self.platformName(device.platform)) {
            Menu {
                Button { afterMenuCloses { newName = device.name; renaming = device } } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) { afterMenuCloses { removing = device } } label: {
                    Label("Remove", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 20)).foregroundStyle(Palette.textDim)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Manage \(device.name)")
            .accessibilityIdentifier("account-device-menu-\(device.current ? "current" : device.id)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account-device-\(device.current ? "current" : device.id)")
    }

    /// Runs `present` once the menu's popover (iPad, Mac) has gone: an alert asked for while
    /// it is still dismissing is dropped there.
    private func afterMenuCloses(_ present: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            present()
        }
    }

    private func syncedCount(_ collection: SyncCollection) -> Int {
        switch collection {
        case .hosts: return account.syncedCounts.hosts
        case .prompts: return account.syncedCounts.prompts
        default: return 0
        }
    }

    private var lastSyncLine: String? {
        guard let last = account.lastSync else { return nil }
        return "Last synced " + last.date.formatted(date: .omitted, time: .shortened)
    }

    private func enrolmentProblem(_ code: String) -> String {
        switch code {
        case "too_many_devices": return "The account has 20 devices. Remove one, then try again."
        case "device_in_other_account": return "Its device key belongs to another HerdrUp account."
        default: return "Sync works; shares bound to the account need it. It's tried again next time."
        }
    }

    static func icon(for platform: String) -> String {
        switch platform {
        case "ios": return "iphone"
        case "ipados": return "ipad"
        case "macos": return "laptopcomputer"
        case "web": return "globe"
        default: return "desktopcomputer"
        }
    }

    static func platformName(_ platform: String) -> String {
        switch platform {
        case "ios": return "iPhone"
        case "ipados": return "iPad"
        case "macos": return "Mac"
        case "windows": return "Windows"
        case "linux": return "Linux"
        case "web": return "Web"
        default: return platform
        }
    }

    // MARK: Row anatomy (Settings' glyph rows)

    private func group<Rows: View>(_ title: String?, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title).font(Typography.microLabel).tracking(DesignTokens.Text.MicroLabel.tracking)
                    .foregroundStyle(Palette.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32).padding(.bottom, 8)
            }
            VStack(spacing: 0) { rows() }
                .settingsGroup()
                .padding(.horizontal, DesignTokens.Space.screenInset)
        }
        .padding(.top, 22)
    }

    private func row<Trailing: View>(_ label: String, systemImage: String, subtitle: String? = nil,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 18)).foregroundStyle(Palette.textDim)
                .frame(width: 24, height: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(Typography.app(17)).foregroundStyle(Palette.text)
                if let subtitle {
                    Text(subtitle).font(Typography.app(14)).foregroundStyle(Palette.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 11)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func value(_ text: String) -> some View {
        Text(text).font(Typography.app(15)).monospacedDigit().foregroundStyle(Palette.textDim)
    }

    private var divider: some View {
        Rectangle().fill(Palette.hairlineQuiet).frame(height: 1).padding(.leading, 52)
    }

    private func footnote(_ text: String) -> some View {
        Text(text).font(Typography.app(13)).foregroundStyle(Palette.textFaint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 32).padding(.top, 8)
    }
}

// MARK: Notices

extension View {
    /// The account's notices (refusals, sync problems, deletion) as an alert. `device_in_other_account`
    /// offers to sign out of this account. The root passes `root: true` and stands back while
    /// the account page, which may sit in a sheet the root can't present over, shows them.
    func accountNoticeAlert(_ account: HerdrUpAccount, root: Bool = false) -> some View {
        alert(account.notice?.title ?? "", isPresented: Binding(
            get: { account.notice != nil && !(root && account.screenVisible) },
            set: { if !$0 { account.notice = nil } }
        ), presenting: account.notice) { notice in
            if notice.action == .signOut {
                Button("Sign out", role: .destructive) { Task { await account.signOut() } }
                    .accessibilityIdentifier("account-notice-sign-out")
                Button("Not now", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { notice in
            Text(notice.message)
        }
    }
}
