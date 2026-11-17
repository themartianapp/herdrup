import SwiftUI
import Foundation
import UIKit    // UIPasteboard (Copy diagnostics)
import UniformTypeIdentifiers
import StoreKit // Product / tip jar (Settings' Support section)
import UserNotifications // notification authorization status (Settings notify section)
import HerdrKit

/// Settings (proposal B, #572): the connected machine as a card, "suggestions" for what
/// waits, then short grouped lists with inline pickers. Preferences persist locally via
/// @AppStorage.
/// The pages Settings opens. On iPhone each is a NavigationStack push from the root list;
/// on the iPad split the sidebar IS the root list and each selects the detail column.
/// `machines` is the machine's profile page (hero, the herdr update card, Connection,
/// Federation); Gestures and the outbound links are not pages.
enum SettingsSection: Hashable, CaseIterable {
    case machines, accounts, notifications, sharedAccess, textSize, typingLatency, support

    var label: String {
        switch self {
        case .machines:      return "Machines"
        case .accounts:      return "Accounts"
        case .notifications: return "Notifications"
        case .sharedAccess:  return "Shared access"
        case .textSize:      return "Text size"
        case .typingLatency: return "Typing latency"
        case .support:       return "Support the project"
        }
    }

    /// The 24 pt glyph each row leads with.
    var icon: String {
        switch self {
        case .machines:      return "server.rack"
        case .accounts:      return "key.horizontal"
        case .notifications: return "bell"
        case .sharedAccess:  return "person.2"
        case .textSize:      return "textformat.size"
        case .typingLatency: return "gauge.with.needle"
        case .support:       return "heart"
        }
    }
}

/// The back affordance on a pushed Settings detail (iPhone). It is its OWN view so its
/// `@Environment(\.dismiss)` resolves to the NavigationStack push it sits under and pops
/// exactly that — reading dismiss on `SettingsView` itself would target the enclosing
/// tab/sheet, the wrong level. The iPad split passes `showBack: false` (its sidebar is
/// the navigation, so there is nothing to pop).
private struct SettingsBackButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        SectionBarButton(icon: "chevron.left", label: "Back") { dismiss() }
    }
}

/// Left-edge swipe-back for a pushed Settings detail screen. Holds its OWN
/// `@Environment(\.dismiss)` — like `SettingsBackButton` — so the swipe pops
/// exactly the NavigationStack push it sits under, not the enclosing tab/sheet.
/// Reuses the app's window-level `EdgeSwipeBack` recognizer (the same one the
/// terminal pane uses), which works even though the nav bar is hidden.
private struct DetailSwipeBack: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        EdgeSwipeBack { dismiss() }
    }
}

/// Store a builder, not the large Settings tuple, in the navigation tree.
/// SwiftUI evaluates this body separately when a resize mounts the compact index.
private struct SettingsIndexContent<Content: View>: View {
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View { content() }
}

struct SettingsView: View {
    let client: HerdrClient
    /// Live agents, mirrored in from the home view exactly like GramView's — the
    /// Federation section derives its remote-machine (peer) list from these.
    let agents: [AgentInfo]
    var host: String
    var connected: Bool = true
    /// Whether "Reconnect now" is safe to offer. FALSE while the connection is in
    /// the host-key-rejection state — a bare reconnect there would first-contact-
    /// trust whatever key appears next, routing around the very gate the recovery
    /// screen enforces. The row is disabled with a reason in that state.
    var canReconnect: Bool = true
    var onReconnect: () -> Void = {}
    /// Nil when Settings is a persistent tab (no close button); a modal sheet passes
    /// one and the header shows an xmark — mirrors GramView's nav-agnostic contract.
    var onClose: (() -> Void)?
    /// iPad only: the page the sidebar selected, rendered directly in the split's detail
    /// column (no NavigationStack — the split view IS the nav). Nil = iPhone (and the
    /// screenshot mock): the whole root → page flow in a NavigationStack.
    var detail: SettingsSection? = nil
    /// The connected machine's herdr update (herdrup#565): the card in Machines. Nil for
    /// guests and in screenshot fixtures drawn without it.
    var serverUpdate: ServerUpdateModel? = nil
    /// iPad only: this instance is the split's SIDEBAR, the root list itself (machine card,
    /// suggestions, groups, inline pickers). Its page rows write the selection the detail
    /// column renders, and the selected row is filled `surfaceRaised`.
    var sidebarSelection: Binding<SettingsSection?>? = nil

    @AppStorage("notify.needsInput") private var notifyNeedsInput = true
    @AppStorage("notify.dies") private var notifyDies = true
    @AppStorage("notify.finishes") private var notifyFinishes = false
    /// With `notify.finishes`: only the owner's own requests (`FinishNotifications.mine`).
    @AppStorage("notify.finishesMineOnly") private var notifyFinishesMineOnly = false
    @AppStorage("notify.gram") private var notifyGram = true
    /// About's "Share anonymous usage count" switch (absent = on). Written through
    /// `UsagePing.setEnabled`, which also deletes or makes the install ID.
    @AppStorage(UsagePing.Key.enabled) private var shareUsageCount = true
    @State private var copied = false
    /// The credential accounts (subscriptions) for the Accounts section. Fetched by
    /// this view itself (`.task` below) via the injected `client`, mirroring how the
    /// Federation section derives from the injected agents. Empty until loaded, and
    /// on an older daemon lacking `accounts.list` (the fetch is `try?`).
    @State private var accounts: [CredentialAccount] = []
    /// A pending "use this account for ALL agents of its harness" bulk swap (nil =
    /// no dialog). Set from an account row's long-press menu; the confirm fans the
    /// per-agent swap out over every same-kind agent.
    @State private var bulkSwapTarget: CredentialAccount?
    /// The account whose in-app sign-in sheet is open (nil = closed).
    @State private var loginAccount: CredentialAccount?
    /// Whether the "Add account" sheet is open.
    @State private var showAddAccount = false
    /// The account staged for a log-out confirmation (nil = none).
    @State private var logoutAccount: CredentialAccount?
    /// The account staged for a remove-from-list confirmation (nil = none).
    @State private var removeAccount: CredentialAccount?
    /// The result summary of the last bulk swap ("Moved 3 of 4 …"), shown in an
    /// alert. nil = no alert.
    @State private var bulkResult: String?
    /// The "how to set up accounts" guide sheet, opened from the Accounts section.
    @State private var showAccountsSetup = false
    /// The gestures tutorial, opened from the Help row (its persistent home now that
    /// it's no longer a tab). Presented as a child sheet over Settings.
    @State private var showGestures = false
    /// The recorder's per-(machine, network) numbers as of the page's last refresh.
    @State private var latencyReports: [TypingLatencyReport] = []
    /// "Copied ✓" feedback on the Typing latency page's Copy report row.
    @State private var latencyCopied = false
    /// The "add a machine" federation setup guide, opened from the Federation
    /// section's "How to add a machine" row. A child sheet over Settings.
    @State private var showFederationSetup = false
    /// Saved machines include profiles that have no agents yet; the agent-derived
    /// peer list remains a fallback for an older daemon without `machine.status`.
    @State private var savedMachines: [SavedMachineStatus]?
    @State private var pendingFederate: SavedMachineStatus?
    @State private var federationBusyID: String?
    @State private var federationError: String?
    /// Whether the connected machine can send push (`notifications.status`); nil until the first
    /// answer. Refreshed with the permission on appear and on foreground.
    @State private var pushAvailability: PushAvailability?
    /// The connected machine keeps turn origins (`turn_origin`), so "Only my requests" can
    /// filter; nil until asked. False shows that the choice falls back to every finished turn.
    @State private var turnOriginSupported: Bool?
    /// The tip jar (StoreKit 2). Renders nothing until products load, so the section
    /// is invisible before the App Store Connect products exist.
    @ObservedObject private var tipStore = TipStore.shared
    /// Opens the Privacy/Terms/GitHub links in the system browser. Overridable in
    /// previews/UI-tests so automated runs never actually leave the app.
    @Environment(\.openURL) private var openURL
    /// The system notification permission, so the notify section can prompt for it
    /// (notDetermined) or point to iOS Settings (denied) instead of toggling silently
    /// into a dead end. Refreshed on appear and on foreground (after a Settings trip).
    @State private var notifyAuth: UNAuthorizationStatus = .notDetermined
    @Environment(\.scenePhase) private var scenePhase
    /// The connected daemon's version + commit, from `server.staged_update` (its `staged` build is
    /// retired: updates go through the herdr update card). Fetched by this view (`.task` below) with
    /// `try?`, so a daemon too old to know the method (or a transient failure) simply leaves it nil —
    /// the version line then doesn't render, the same degrade the notify + accounts rows use.
    @State private var stagedUpdate: StagedUpdate?
    /// Settings → Shared access: guests, pending invites and the activity log, across machines.
    @StateObject private var guestAccess = GuestAccessModel()
    @Environment(\.guestMachineLabel) private var guestMachineLabel

    var body: some View {
        Group {
            if let detail {
                // iPad split: the sidebar is the root list, so render ONLY the selected
                // page here (no NavigationStack — the split view IS the nav).
                detailColumn(detail)
            } else if sidebarSelection != nil {
                // iPad split sidebar: the root list, under the column's own top bar.
                ScrollView { rootList }
                    // Pages it does not show change what the list says (an account signed
                    // in on the Accounts page, say): read the accounts again on each pick.
                    .onChange(of: sidebarSelection?.wrappedValue) { _, _ in
                        Task { accounts = (try? await client.accountsList()) ?? accounts }
                    }
            } else {
                // iPhone (and the screenshot mock): a NavigationStack whose root is the
                // list; its page rows push the same pages the iPad renders inline.
                indexStack
            }
        }
        // The gestures reference lives here now (moved out of the main tab bar);
        // reuse the same self-contained help view the first-run popup shows.
        .sheet(isPresented: $showGestures) {
            GesturesHelpView(onClose: { showGestures = false })
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        // The federation setup guide, opened from the Federation section.
        .sheet(isPresented: $showFederationSetup) {
            FederationSetupView(onClose: { showFederationSetup = false })
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            pendingFederate.map { "Federate \($0.displayLabel)?" } ?? "",
            isPresented: $pendingFederate.isPresent(),
            presenting: pendingFederate
        ) { machine in
            Button("Allow federation") { Task { await changeFederation(machine, enabled: true) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The coordinator will keep an SSH connection to this machine and can control its Herdr session.")
        }
        .alert(
            "Federation status",
            isPresented: $federationError.isPresent()
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(federationError ?? "")
        }
        // Load the tip products when Settings opens. No-ops after a successful load;
        // re-tries after a prior failure, so products created in ASC later appear.
        .task { await tipStore.loadProducts() }
        // Fetch the credential accounts for the Accounts section when Settings opens.
        // `try?` so an older daemon without `accounts.list` (or a transient failure)
        // just leaves the section empty rather than surfacing an error here.
        .task { accounts = (try? await client.accountsList()) ?? [] }
        .task {
            savedMachines = try? await client.machineStatuses()
            // A saved machine that runs no agents is only known from `machine.status`, and it
            // can still hold guests: read Shared access again once the profiles arrive.
            await loadGuestAccess()
        }
        // Fetch the daemon version. `try?` so an older daemon without `server.staged_update`
        // leaves it nil (the version line is simply absent).
        .task { stagedUpdate = try? await client.stagedUpdate() }
        // The Shared access row's summary; `try?`-style degrade lives in the model.
        .task { await loadGuestAccess() }
        // "How to set up accounts" — a step-by-step guide for adding another
        // subscription on the box (accounts live there, not in the app).
        .sheet(isPresented: $showAccountsSetup) {
            AccountsSetupView(onClose: { showAccountsSetup = false })
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        // Bulk swap: "use this account for all <kind> agents". Confirms (naming the
        // count, since it restarts each one's turn), then fans the per-agent swap
        // out sequentially and reports the outcome in an alert.
        .confirmationDialog(
            bulkSwapTarget.map { "Use \($0.label) for all \($0.kind.capitalized) agents?" } ?? "",
            isPresented: $bulkSwapTarget.isPresent(),
            presenting: bulkSwapTarget
        ) { account in
            let targets = agents.filter { $0.agent == account.kind }
            Button("Move \(targets.count) agent\(targets.count == 1 ? "" : "s")", role: .destructive) {
                let accountID = account.id
                let label = account.label
                let total = targets.count
                Task {
                    var moved = 0
                    var failed = 0
                    var lastError: String?
                    for info in targets {
                        do {
                            try await client.restartAgent(target: info.paneID, account: accountID)
                            moved += 1
                        } catch {
                            // Any failure (no_resumable_session OR anything else):
                            // count it generically and keep the REAL error to surface,
                            // rather than mislabelling every failure as "no resumable
                            // session". `\(error)` is the APIError's "code: message" —
                            // same interpolation the per-agent swap uses.
                            failed += 1
                            lastError = "\(error)"
                        }
                    }
                    if failed == 0 {
                        bulkResult = "Moved all \(moved) agent\(moved == 1 ? "" : "s") to \(label)."
                    } else {
                        bulkResult = "Moved \(moved) of \(total). \(failed) couldn't be moved"
                            + (lastError.map { ": \($0)" } ?? "") + "."
                    }
                    accounts = (try? await client.accountsList()) ?? []
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { account in
            let n = agents.filter { $0.agent == account.kind }.count
            Text("Restarts \(n) \(account.kind.capitalized) agent\(n == 1 ? "" : "s") onto "
                + "\(account.label). This interrupts each one's current turn. "
                + "Sessions reopen with --resume.")
        }
        .alert(
            "Swap subscription",
            isPresented: $bulkResult.isPresent(),
            presenting: bulkResult
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { result in
            Text(result)
        }
        // Keep the notify section honest: the iOS permission and whether this machine can push,
        // on open and again when the app returns to the foreground (the user may have flipped
        // the permission in iOS Settings, or changed Herdr's push config meanwhile).
        .onAppear { refreshNotifyAuth() }
        .task { await refreshPushAvailability() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            refreshNotifyAuth()
            Task { await refreshPushAvailability() }
        }
    }

    // MARK: Root list → pages (iPhone NavigationStack)

    /// The iPhone Settings root: the list a NavigationStack starts on. Its page rows are
    /// value-based `NavigationLink`s; the one `navigationDestination` renders the shared
    /// page bodies with a back button.
    private var indexStack: some View {
        NavigationStack {
            ZStack {
                Palette.ground.ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    Divider().overlay(Palette.hairlineQuiet)
                    ScrollView {
                        SettingsIndexContent { rootList }
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: SettingsSection.self) { section in
                detailScreen(section, showBack: true)
            }
        }
    }

    /// Proposal B's root (#572): the machine card, the suggestions that wait, then Your herd,
    /// Preferences, Help and About as short groups over the version footer. The iPhone
    /// NavigationStack root and the iPad sidebar are this same list.
    private var rootList: some View {
        VStack(alignment: .leading, spacing: 0) {
            machineCard
            suggestionsGroup
            herdGroup
            preferencesGroup
            helpGroup
            aboutGroup
            versionFooter
        }
        .padding(.top, 14)
        .padding(.bottom, 16)
    }

    /// The iPad detail column: one page, on the app ground, no back button (the sidebar
    /// list is the navigation).
    private func detailColumn(_ section: SettingsSection) -> some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            detailScreen(section, showBack: false)
        }
    }

    /// Maps a page to its body. Accounts, Notifications and Shared access reuse their
    /// section views verbatim.
    @ViewBuilder
    private func detailScreen(_ section: SettingsSection, showBack: Bool) -> some View {
        switch section {
        case .machines:      machinesDetail(showBack: showBack)
        case .accounts:      accountsDetail(showBack: showBack)
        case .notifications: notificationsDetail(showBack: showBack)
        case .sharedAccess:  sharedAccessDetail(showBack: showBack)
        case .textSize:      textSizeDetail(showBack: showBack)
        case .typingLatency: typingLatencyDetail(showBack: showBack)
        case .support:       supportDetail(showBack: showBack)
        }
    }

    /// Preferences › Text size: the app and terminal text sliders.
    private func textSizeDetail(showBack: Bool) -> some View {
        detailScaffold(title: "Text size", subtitle: "", showBack: showBack) {
            appearanceControls
        }
    }

    /// Settings › Machines, the machine's profile page: the hero, the herdr update card
    /// exactly as shipped (#566), Connection (the trouble actions, beside the machine they
    /// act on), then Federation with the herd's reach as its footer. The title carries no
    /// subtitle: the hero says it.
    private func machinesDetail(showBack: Bool) -> some View {
        detailScaffold(title: "Machines", subtitle: "", showBack: showBack) {
            machineHero
            // The herdr update card: signed in-app updates are the only update UI.
            if let serverUpdate, serverUpdate.card != .hidden {
                ServerUpdateCardView(model: serverUpdate, host: host)
            }
            connectionSection
            federationSection
            federationFooter
        }
    }

    private func accountsDetail(showBack: Bool) -> some View {
        detailScaffold(title: "Accounts", subtitle: accountsHeaderSubtitle,
                       subtitleTint: accountsHeaderTint, showBack: showBack) {
            accountsSection
                .sheet(item: $loginAccount) { account in
                    AccountLoginSheet(client: client, account: account) {
                        Task { accounts = (try? await client.accountsList()) ?? [] }
                    }
                    // The chrome every other sheet in the app gets and this one did not:
                    // full height with a grabber, so swipe-down closes it.
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                }
                .sheet(isPresented: $showAddAccount) {
                    AddAccountSheet(client: client) { refreshed, created in
                        accounts = refreshed
                        // Chain into sign-in for the new account once the add sheet
                        // has dismissed (sequential sheets on the same anchor).
                        if let created {
                            Task {
                                try? await Task.sleep(nanoseconds: 400_000_000)
                                loginAccount = created
                            }
                        }
                    }
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                }
                .confirmationDialog(
                    logoutAccount.map { "Log out \($0.label)?" } ?? "",
                    isPresented: $logoutAccount.isPresent(),
                    titleVisibility: .visible,
                    presenting: logoutAccount
                ) { account in
                    Button("Log out", role: .destructive) {
                        Task { await performLogout(account) }
                    }
                } message: { account in
                    Text("This clears \(account.label)'s saved credentials on your box. "
                        + "You can sign back in from here anytime.")
                }
                .confirmationDialog(
                    removeAccount.map { "Remove \($0.label)?" } ?? "",
                    isPresented: $removeAccount.isPresent(),
                    titleVisibility: .visible,
                    presenting: removeAccount
                ) { account in
                    Button("Remove", role: .destructive) {
                        Task { await performRemove(account) }
                    }
                } message: { account in
                    Text("This removes \(account.label) from the accounts list. "
                        + "Its saved credentials stay on your box, so you can add it back later.")
                }
        }
    }

    /// Remove an account from the list (`accounts.remove`): the daemon drops it from
    /// config.toml and returns the refreshed list. Credentials are left in place.
    private func performRemove(_ account: CredentialAccount) async {
        do {
            accounts = try await client.accountsRemove(id: account.id)
        } catch {
            bulkResult = "Couldn't remove \(account.label): \(error)"
        }
    }

    /// Log an account out by running claude's own `auth logout` in a short-lived pane
    /// pinned to the account's config-home (token cleared), then refresh the list.
    private func performLogout(_ account: CredentialAccount) async {
        guard let configDir = account.configDir,
              let cmd = claudeLogoutCommand(kind: account.kind, configDir: configDir)
        else { return }
        do {
            // Same as sign-in: a short-lived background pane the user never sees.
            let pane = try await client.splitPane(cwd: nil, focus: false)
            try await client.sendText(pane: pane, text: cmd)
            try await client.sendPaneKeys(pane: pane, keys: ["Enter"])
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            accounts = (try? await client.accountsList()) ?? accounts
            try? await client.closePane(paneID: pane)
        } catch let err {
            bulkResult = "Couldn't log out \(account.label): \(err)"
        }
    }

    private func notificationsDetail(showBack: Bool) -> some View {
        detailScaffold(title: "Notifications", subtitle: notifyHeaderSubtitle,
                       subtitleTint: notifyBlocked ? Palette.waiting : Palette.textFaint,
                       showBack: showBack) {
            notifySection
        }
    }

    private func sharedAccessDetail(showBack: Bool) -> some View {
        detailScaffold(title: "Shared access", subtitle: guestAccess.summary, showBack: showBack) {
            GuestAccessSection(client: client, model: guestAccess) { await loadGuestAccess() }
        }
        .task { await loadGuestAccess() }
        .refreshable { await loadGuestAccess() }
    }

    /// The connected machine plus every federated peer: each keeps its own guest store,
    /// which the coordinator reaches by the peer's alias.
    private func loadGuestAccess() async {
        let machines = GuestMachine.directory(
            localLabel: guestMachineLabel.isEmpty ? host : guestMachineLabel,
            savedMachines: savedMachines ?? [], agentPeers: machinePeers)
        await guestAccess.load(client: client, machines: machines)
    }

    /// About › Support the project: the tip jar. Its root row shows only once StoreKit has
    /// products, so the page is never reached empty.
    private func supportDetail(showBack: Bool) -> some View {
        detailScaffold(title: "Support the project", subtitle: "", showBack: showBack) {
            supportSection
        }
    }

    /// A detail screen shell: the custom dark header (title + subtitle + optional back
    /// button) over a scroll of the composed section views. Hides the system nav bar so
    /// the app's own header is the only chrome, matching the Gram / Gestures sheets.
    @ViewBuilder
    private func detailScaffold<Content: View>(
        title: String, subtitle: String, subtitleTint: Color = Palette.textFaint,
        showBack: Bool, @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            VStack(spacing: 0) {
                detailHeader(title, subtitle: subtitle, tint: subtitleTint, showBack: showBack)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        content()
                    }
                    .padding(.bottom, 16)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        // Hiding the nav bar kills UIKit's default interactive-pop, so re-add a
        // left-edge swipe-back on pushed detail screens (iPhone). iPad's split
        // view is the nav (showBack:false), so no gesture there.
        .overlay { if showBack { DetailSwipeBack() } }
    }

    /// The detail header: the shared small centred title, with the summary line beneath it.
    /// Back follows the bar's rule (`SectionBackSlot`): left on iPhone, Mac and a
    /// full-screen iPad, the right-hand capsule in an iPad window.
    private func detailHeader(_ title: String, subtitle: String, tint: Color, showBack: Bool) -> some View {
        VStack(spacing: 1) {
            SectionTopBar(title: title, leading: {
                if showBack { SectionBackSlot(.leading) { SettingsBackButton() } }
            }) {
                if showBack { SectionBackSlot(.trailing) { SettingsBackButton() } }
            }
            if !subtitle.isEmpty {
                Text(subtitle).font(Typography.machine(12)).foregroundStyle(tint)
                    .lineLimit(1).frame(maxWidth: .infinity)
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
    }

    // MARK: Root: the machine card and suggestions (proposal B)

    /// What the machine is called: the saved nickname when there is one, else the host.
    private var machineName: String { guestMachineLabel.isEmpty ? host : guestMachineLabel }

    /// "Connected · 14 agents". The machine count and reach are the Federation footer's.
    private var machineCardStatus: String {
        var parts = [connected ? "Connected" : "Disconnected"]
        parts.append("\(agents.count) agent\(agents.count == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    /// "herdr 0.9.3 · 4c1e9a2": the daemon's own version and commit (distinct from the app
    /// version in the footer), once `server.staged_update` has answered — nil on a daemon too
    /// old to report it. The version is static across commits, so the sha names the build.
    private var machineVersionLine: String? {
        guard let running = stagedUpdate?.runningVersion else { return nil }
        return stagedUpdate?.runningSha.map { "herdr \(running) · \($0)" } ?? "herdr \(running)"
    }

    /// The avatar disc look (`AgentIdentity`) for a machine: `agentGradient.default` and the
    /// name's first letter, never an empty disc.
    private func machineDisc(size: CGFloat) -> some View {
        let first = machineName.trimmingCharacters(in: .whitespaces).prefix(1).uppercased()
        return Text(first.isEmpty ? "?" : first)
            .font(Typography.app(size * 0.43, .bold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(AgentIdentity.gradient(for: nil)))
            .accessibilityHidden(true)
    }

    /// The connected machine leads the root, like the Apple Account card: the 60 pt disc,
    /// the name, its connection and herd, and the daemon build. It opens Machines (the
    /// iPad sidebar fills it `surfaceRaised` while Machines is the detail).
    private var machineCard: some View {
        let title = DesignTokens.Text.MachineCardTitle.self
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.group)
        return pageLink(.machines) {
            HStack(spacing: 14) {
                machineDisc(size: DesignTokens.Size.machineCardAvatar)
                VStack(alignment: .leading, spacing: 0) {
                    Text(machineName)
                        .font(Typography.app(title.size, title.weight)).foregroundStyle(Palette.text)
                        .lineLimit(1).truncationMode(.middle)
                    Text(machineCardStatus)
                        .font(Typography.app(15)).foregroundStyle(connected ? Palette.textDim : Palette.died)
                        .lineLimit(1)
                    if let machineVersionLine {
                        Text(machineVersionLine)
                            .font(Typography.machine(DesignTokens.Text.CardSubtitle.size))
                            .foregroundStyle(Palette.textFaint).lineLimit(1)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 8)
                rowChevron
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(isSelected(.machines) ? Palette.surfaceRaised : Palette.surface, in: shape)
            .contentShape(shape)
        }
        // Read as the page it opens, then the machine: "Machines, mac-mini, Connected · …".
        .accessibilityLabel(Text("Machines, \(machineName), \(machineCardStatus)"))
        .accessibilityIdentifier("settings-machine-card")
        .padding(.horizontal, DesignTokens.Space.screenInset)
    }

    /// Apple-style suggestions under the card, only while something waits: the herdr update
    /// (amber count) and an exhausted account (red count), each opening the page that acts
    /// on it. Replaces At a glance's update and exhausted lines.
    @ViewBuilder
    private var suggestionsGroup: some View {
        let exhausted = exhaustedAccounts
        if daemonUpdateAvailable || !exhausted.isEmpty {
            VStack(spacing: 0) {
                if daemonUpdateAvailable {
                    suggestionRow(.machines, title: updateSuggestionTitle, subtitle: updateSuggestionSubtitle,
                                  systemImage: "arrow.down.circle", count: 1, tint: Palette.waiting,
                                  identifier: "settings-suggestion-update")
                    if !exhausted.isEmpty { glyphDivider }
                }
                if let first = exhausted.first {
                    suggestionRow(.accounts,
                                  title: exhausted.count == 1 ? first.label : "\(exhausted.count) accounts are exhausted",
                                  subtitle: exhausted.count == 1
                                      ? "Exhausted. Its agents can move to another account."
                                      : "Their agents can move to another account.",
                                  systemImage: SettingsSection.accounts.icon, count: exhausted.count,
                                  tint: Palette.died, identifier: "settings-suggestion-exhausted")
                }
            }
            .settingsGroup()
            .padding(.horizontal, DesignTokens.Space.screenInset)
            .padding(.top, 20)
        }
    }

    /// One suggestion: a glyph row with a count badge. Its texts are one element, so the
    /// account named here is not a second "Claude Pro (personal)" beside the Accounts page.
    private func suggestionRow(
        _ section: SettingsSection, title: String, subtitle: String?, systemImage: String,
        count: Int, tint: Color, identifier: String
    ) -> some View {
        pageLink(section) {
            glyphRow(title, systemImage: systemImage, subtitle: subtitle) {
                CountPill(count: count, fill: tint)
                rowChevron
            }
            .accessibilityElement(children: .combine)
        }
        .accessibilityIdentifier(identifier)
    }

    /// The update suggestion's title: the herdr update card's state (the same cases the tab's
    /// "1" counts).
    private var updateSuggestionTitle: String {
        switch serverUpdate?.card {
        case .available(_, let new, _, _, _, _)?: return "Update herdr to \(new)"
        case .restartPending(let new, _)?: return "herdr \(new) finishes on next restart"
        case .failed?: return "herdr update needs attention"
        case .tooOld?: return "herdr needs a one-time update"
        default: return "Update herdr"
        }
    }

    /// Why the update matters, in the card's own words: "Folders and avatars need it".
    private var updateSuggestionSubtitle: String? {
        switch serverUpdate?.card {
        case .available(_, _, let missing, _, _, _)?:
            return missing.isEmpty
                ? "A newer herdr is ready for \(machineName)"
                : "\(ServerUpdateCardView.sentence(missing)) need\(missing.count == 1 ? "s" : "") it"
        case .restartPending?: return "Restarting herdr closes terminals. Your layout comes back."
        case .failed?: return "Open Machines for the update status and next steps."
        case .tooOld?: return "This version can't update itself from the app."
        default: return nil
        }
    }

    // MARK: Root groups (proposal B)

    /// Your herd: Accounts, Shared access and Notifications with their live values. The
    /// machine card is the fourth (Machines).
    private var herdGroup: some View {
        rootGroup("YOUR HERD") {
            pageRow(.accounts, value: accounts.isEmpty ? "None" : "\(accounts.count)")
            glyphDivider
            pageRow(.sharedAccess, value: sharedAccessValue)
            glyphDivider
            pageRow(.notifications, value: notifyManageValue, valueTint: notifyManageTint)
        }
    }

    /// "1 person" / "2 invites" for the Shared access row; the page header keeps the full
    /// "N people · N agents · N invites" summary.
    private var sharedAccessValue: String {
        let people = guestAccess.people.count
        if people > 0 { return "\(people) \(people == 1 ? "person" : "people")" }
        let invites = guestAccess.invites.count
        if invites > 0 { return "\(invites) invite\(invites == 1 ? "" : "s")" }
        return guestAccess.summary
    }

    /// Preferences: Text size opens its page; instant typing and omp chat are inline menu
    /// pickers and script in previews an inline switch, each with its footer as the subtitle.
    private var preferencesGroup: some View {
        rootGroup("PREFERENCES") {
            pageRow(.textSize, value: "\(Int((uiFontScale * 100).rounded()))% · \(String(format: "%g", terminalFontSize)) pt")
            glyphDivider
            glyphRow("Instant typing", systemImage: "keyboard",
                     subtitle: "Shows what you type at once and checks it against the server.") {
                menuPicker("Instant typing", value: predictiveEchoLabel, identifier: "settings-instant-typing") {
                    Picker("Instant typing", selection: $predictiveEcho) {
                        Text("Auto").tag(PredictionEngine.Mode.auto.rawValue)
                        Text("Always").tag(PredictionEngine.Mode.always.rawValue)
                        Text("Off").tag(PredictionEngine.Mode.off.rawValue)
                    }
                }
            }
            glyphDivider
            // "omp agents open in": Chat (default) or Terminal (#481). The page's switch
            // overrides it per agent for the session.
            glyphRow("omp agents open in", systemImage: "bubble.left.and.bubble.right",
                     subtitle: "Claude Code and Codex agents always open in the terminal.") {
                menuPicker("omp agents open in", value: ompOpensIn == ChatPreference.terminal ? "Terminal" : "Chat",
                           identifier: "settings-omp-opens-in") {
                    Picker("omp agents open in", selection: $ompOpensIn) {
                        Text("Chat").tag(ChatPreference.chat)
                        Text("Terminal").tag(ChatPreference.terminal)
                    }
                }
            }
            glyphDivider
            previewsRow
        }
    }

    private var predictiveEchoLabel: String {
        switch PredictiveEchoSetting.mode(predictiveEcho) {
        case .always: return "Always"
        case .off: return "Off"
        default: return "Auto"
        }
    }

    /// Help: the gestures tutorial, the typing-latency page and the issue tracker.
    private var helpGroup: some View {
        rootGroup("HELP") {
            actionGlyphRow("Gestures", systemImage: "hand.draw", subtitle: "How to move around the app") {
                showGestures = true
            }
            glyphDivider
            pageRow(.typingLatency)
            glyphDivider
            linkGlyphRow("Report a bug or request a feature", systemImage: "exclamationmark.bubble",
                         url: URL(string: "https://github.com/themartianapp/herdrup/issues")!)
        }
    }

    /// About: the tip jar (only once StoreKit has products, so it is invisible before the
    /// App Store Connect products exist), the community, the legal pages, the source and the
    /// anonymous usage-count switch.
    private var aboutGroup: some View {
        rootGroup("ABOUT") {
            if hasTipProducts {
                pageRow(.support)
                glyphDivider
            }
            discordRow
            glyphDivider
            linkGlyphRow("Privacy Policy", systemImage: "lock.shield",
                         url: URL(string: "https://herdrup.app/legal/privacy")!)
            glyphDivider
            linkGlyphRow("Terms of Service", systemImage: "doc.text",
                         url: URL(string: "https://herdrup.app/legal/terms")!)
            glyphDivider
            linkGlyphRow("Open source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right",
                         url: URL(string: "https://github.com/themartianapp/herdrup")!)
            glyphDivider
            usageCountRow
        }
    }

    /// The anonymous daily usage ping's switch, on by default. Off stops the pings and deletes
    /// the install ID at once; on again makes a new ID. A toggle drawn like `groupedToggleRow`'s,
    /// the whole row the tap target.
    private var usageCountRow: some View {
        Button {
            shareUsageCount.toggle()
            UsagePing.setEnabled(shareUsageCount, in: .standard)
        } label: {
            glyphRow("Share anonymous usage count", systemImage: "chart.bar",
                     subtitle: "Once a day: a random ID, the app version and the platform. Nothing about your agents or machines.") {
                Toggle("", isOn: .constant(shareUsageCount))
                    .labelsHidden()
                    .tint(Palette.brand)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(shareUsageCount ? "on" : "off"))
        .accessibilityIdentifier("settings-usage-count")
    }

    private var hasTipProducts: Bool {
        if case .loaded(let products) = tipStore.loadState { return !products.isEmpty }
        return false
    }

    // MARK: Root row anatomy (proposal B)

    /// A titled root group: the micro-label header (x = 32, 22 pt above, 8 below), then the
    /// rows in one `settingsGroup`, inset 16.
    private func rootGroup<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(Typography.microLabel).tracking(DesignTokens.Text.MicroLabel.tracking)
                .foregroundStyle(Palette.textFaint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32).padding(.top, 22).padding(.bottom, 8)
            VStack(spacing: 0) { rows() }
                .settingsGroup()
                .padding(.horizontal, DesignTokens.Space.screenInset)
        }
    }

    /// B's one row anatomy: today's `richActionRow` 24 pt glyph column, 12 pt to a Geist 17
    /// label with an optional Geist 14 textDim subtitle that wraps, then the trailing value
    /// or control. Min 52 pt; the group separates rows from x = 52 (`glyphDivider`).
    private func glyphRow<Glyph: View, Trailing: View>(
        _ label: String, subtitle: String? = nil, selected: Bool = false,
        @ViewBuilder glyph: () -> Glyph, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            glyph()
                .foregroundStyle(Palette.textDim)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
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
        .background(selected ? Palette.surfaceRaised : Color.clear)
        .contentShape(Rectangle())
    }

    /// A glyph row led by an SF Symbol.
    private func glyphRow<Trailing: View>(
        _ label: String, systemImage: String, subtitle: String? = nil, selected: Bool = false,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        glyphRow(label, subtitle: subtitle, selected: selected, glyph: {
            Image(systemName: systemImage).font(.system(size: 18))
        }, trailing: trailing)
    }

    /// The separator between glyph rows, from x = 52 (16 inset + 24 glyph + 12 gap).
    private var glyphDivider: some View {
        Rectangle().fill(Palette.hairlineQuiet).frame(height: 1).padding(.leading, 52)
    }

    /// The page-row chevron (textFaint). The iPad sidebar draws none: its selection says it.
    @ViewBuilder private var rowChevron: some View {
        if sidebarSelection == nil {
            Image(systemName: "chevron.right")
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.textFaint)
        }
    }

    /// The leaving-the-app mark on an outbound link row.
    private var externalGlyph: some View {
        Image(systemName: "arrow.up.right")
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.textFaint)
    }

    private func isSelected(_ section: SettingsSection) -> Bool {
        sidebarSelection?.wrappedValue == section
    }

    /// A row that opens a page: a `NavigationLink` on iPhone; on the iPad sidebar a button
    /// that selects the detail column's page.
    @ViewBuilder
    private func pageLink<Label: View>(_ section: SettingsSection, @ViewBuilder label: () -> Label) -> some View {
        let content = label()
        if let sidebarSelection {
            Button { sidebarSelection.wrappedValue = section } label: { content }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityAddTraits(sidebarSelection.wrappedValue == section ? .isSelected : [])
        } else {
            NavigationLink(value: section) { content }
                .buttonStyle(.plain)
        }
    }

    /// A page row: the section's glyph and label, an optional live value, the chevron.
    private func pageRow(
        _ section: SettingsSection, value: String = "", valueTint: Color = Palette.textDim
    ) -> some View {
        pageLink(section) {
            glyphRow(section.label, systemImage: section.icon, selected: isSelected(section)) {
                if !value.isEmpty {
                    Text(value).font(Typography.app(15)).monospacedDigit()
                        .foregroundStyle(valueTint).lineLimit(1)
                }
                rowChevron
            }
        }
    }

    /// A glyph row that acts in place (Gestures opens its sheet).
    private func actionGlyphRow(
        _ label: String, systemImage: String, subtitle: String? = nil, _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            glyphRow(label, systemImage: systemImage, subtitle: subtitle) { rowChevron }
        }
        .buttonStyle(.plain)
    }

    /// A glyph row that opens an external URL in the system browser.
    private func linkGlyphRow(_ label: String, systemImage: String, url: URL) -> some View {
        Button { openURL(url) } label: {
            glyphRow(label, systemImage: systemImage) { externalGlyph }
        }
        .buttonStyle(.plain)
    }

    /// Picker(.menu) as B draws it: the value and a chevron.up.chevron.down, Geist 17 textDim,
    /// trailing; the menu lists the choices with a checkmark.
    private func menuPicker<Choices: View>(
        _ title: String, value: String, identifier: String, @ViewBuilder choices: () -> Choices
    ) -> some View {
        let items = choices()
        return Menu {
            items
        } label: {
            HStack(spacing: 3) {
                Text(value).font(Typography.app(17))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(Palette.textDim)
            .fixedSize()
        }
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value))
        .accessibilityIdentifier(identifier)
    }

    // MARK: Index summaries (computed from live state)

    /// The federation peers, derived from the injected agents (the same source the
    /// Machines detail's `federationSection` uses).
    private var machinePeers: [PeerSummary] { PeerSummary.peerSummaries(from: agents) }

    /// This box + its federated peers.
    private var machineCount: Int { machinePeers.count + 1 }

    /// Aggregate reachability across the peers, worst case wins — a word + its colour.
    private var machinesReachability: (text: String, color: Color) {
        let offline = machinePeers.filter { $0.reachability == .offline }.count
        if offline > 0 { return ("\(offline) offline", Palette.textDim) }
        if machinePeers.contains(where: { $0.reachability == .degraded }) {
            return ("some slow", Palette.waiting)
        }
        return ("all reachable", Palette.done)
    }

    private var exhaustedAccounts: [CredentialAccount] { accounts.filter { !$0.active } }

    /// "N subscriptions · M exhausted" — the Accounts detail-header subtitle (amber when
    /// any is exhausted).
    private var accountsHeaderSubtitle: String {
        guard !accounts.isEmpty else { return "None configured yet" }
        let n = accounts.count
        var text = "\(n) subscription\(n == 1 ? "" : "s")"
        let exhausted = exhaustedAccounts.count
        if exhausted > 0 { text += " · \(exhausted) exhausted" }
        return text
    }
    private var accountsHeaderTint: Color { exhaustedAccounts.isEmpty ? Palette.textFaint : Palette.waiting }

    private var notifyOnCount: Int { [notifyNeedsInput, notifyDies, notifyFinishes, notifyGram].filter { $0 }.count }

    /// iOS is blocking the alerts the user asked for (at least one on, permission denied).
    private var notifyBlocked: Bool { anyNotifyOn && notifyAuth == .denied }

    /// "N of 4 alerts on" — the Notifications detail-header subtitle.
    private var notifyHeaderSubtitle: String { "\(notifyOnCount) of 4 alerts on" }

    /// "N on · blocked" (amber) when iOS is blocking, else "N of 4".
    private var notifyManageValue: String {
        notifyBlocked ? "\(notifyOnCount) on · blocked" : "\(notifyOnCount) of 4"
    }
    private var notifyManageTint: Color { notifyBlocked ? Palette.waiting : Palette.textDim }

    // The shared small centred title. This is a sheet or a tab, not a nav push: only a
    // modal presentation gets the close button, and swipe-down also dismisses it.
    private var header: some View {
        SectionTopBar(title: "Settings") {
            if let onClose {
                SectionBarButton(icon: "xmark", label: "Close", action: onClose)
            }
        }
    }

    /// The Machines hero: the 88 pt disc, 12 pt to the name (Geist 24/700), the connection
    /// with its dot, and the daemon build in Plex 12. The Connection status row it replaces
    /// said the same.
    private var machineHero: some View {
        let title = DesignTokens.Text.MachineHeroTitle.self
        return VStack(spacing: 0) {
            machineDisc(size: 88)
            Text(machineName)
                .font(Typography.app(title.size, title.weight)).foregroundStyle(Palette.text)
                .lineLimit(1).truncationMode(.middle)
                .padding(.top, 12)
            HStack(spacing: 6) {
                Circle().fill(connected ? Palette.done : Palette.died).frame(width: 8, height: 8)
                Text(connected ? "Connected" : "Disconnected")
                    .font(Typography.app(15)).foregroundStyle(Palette.textDim)
            }
            .padding(.top, 2)
            if let machineVersionLine {
                Text(machineVersionLine)
                    .font(Typography.machine(DesignTokens.Text.CardSubtitle.size))
                    .foregroundStyle(Palette.textFaint)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings-machine-hero")
    }

    /// Machines › Connection: the trouble actions, beside the machine they act on. Reconnect
    /// is withheld (with its reason) while a host key is rejected.
    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("CONNECTION")
            VStack(spacing: 0) {
                groupedActionRow("Reconnect now", enabled: canReconnect,
                                 note: "verify the host key first") { onReconnect() }
                rowDivider
                groupedActionRow(copied ? "Copied ✓" : "Copy diagnostics") { copyDiagnostics() }
            }
            .settingsGroup()
            .padding(.horizontal, DesignTokens.Space.screenInset)
        }
        // After a herdr update the hero names the new build. Here, not on the body's long
        // modifier chain, which is at the type checker's limit.
        .onChange(of: serverUpdate?.completedUpdates ?? 0) { _, _ in
            Task { stagedUpdate = try? await client.stagedUpdate() }
        }
    }

    /// The herd's reach under Federation: "2 machines · 14 agents · some slow".
    private var federationFooter: some View {
        let reach = machinesReachability
        return HStack(spacing: 0) {
            Text("\(machineCount) machine\(machineCount == 1 ? "" : "s") · \(agents.count) agent\(agents.count == 1 ? "" : "s") · ")
                .foregroundStyle(Palette.textFaint)
            Text(reach.text).foregroundStyle(reach.color)
        }
        .font(Typography.app(13))
        .padding(.horizontal, 32).padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings-federation-reach")
    }

    /// True when the herdr update card asks for something (the same cases the tab badge counts).
    private var daemonUpdateAvailable: Bool {
        serverUpdate?.card.badgeKey != nil
    }

    /// Saved machine profiles include ones not yet opted into federation. The
    /// agent-derived list remains the fallback for older Herdr servers.
    @ViewBuilder
    private var federationSection: some View {
        let peers = PeerSummary.peerSummaries(from: agents)
        let machines = savedMachines ?? []
        let extraPeers = peers.filter { peer in
            !machines.contains { $0.profileID == peer.alias }
        }
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("FEDERATION")
            // One group, as proposal B draws it: the machines, then "How to add a machine".
            VStack(spacing: 0) {
                if machines.isEmpty && extraPeers.isEmpty {
                    federationEmpty
                } else {
                    ForEach(Array(machines.enumerated()), id: \.element.id) { index, machine in
                        savedMachineRow(machine, peer: peers.first { $0.alias == machine.profileID })
                        if index < machines.count - 1 || !extraPeers.isEmpty { rowDivider }
                    }
                    ForEach(Array(extraPeers.enumerated()), id: \.element.id) { index, peer in
                        peerRow(peer)
                        if index < extraPeers.count - 1 { rowDivider }
                    }
                }
                rowDivider
                actionGlyphRow("How to add a machine", systemImage: "plus.circle",
                               subtitle: "Connect another computer to your home box") {
                    showFederationSetup = true
                }
            }
            .settingsGroup()
            .padding(.horizontal, DesignTokens.Space.screenInset)
        }
    }

    private func changeFederation(_ machine: SavedMachineStatus, enabled: Bool) async {
        federationBusyID = machine.profileID
        defer { federationBusyID = nil }
        do {
            try await client.setMachineFederation(profileID: machine.profileID, enabled: enabled)
        } catch {
            federationError = "Change failed: \(error)"
            return
        }
        do {
            savedMachines = try await client.machineStatuses()
        } catch {
            federationError = "Change applied, but status could not refresh: \(error)"
        }
    }

    private func savedMachineRow(_ machine: SavedMachineStatus, peer: PeerSummary?) -> some View {
        let state: String
        if machine.savedState == "disabled" {
            state = "Disabled"
        } else if machine.savedState == "coordinator_disabled" {
            state = "Coordinator off"
        } else if machine.hasFederationPolicy {
            state = machine.federationReachability ?? "Connecting"
        } else {
            state = "Not federated"
        }
        var detail = state
        if let peer {
            detail += " · \(peer.agentCount) agent\(peer.agentCount == 1 ? "" : "s")"
        }
        if machine.stale { detail += " (stale)" }
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(AgentIdentity.gradient(for: machine.displayLabel))
                    .frame(width: 40, height: 40)
                Text(AgentIdentity.glyph(for: machine.displayLabel))
                    .font(Typography.app(18, .bold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(machine.displayLabel)
                    .font(Typography.app(15, .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                Text(detail)
                    .font(Typography.app(13)).foregroundStyle(Palette.textDim)
            }
            Spacer(minLength: 8)
            if let peer { peerBadge(peer.reachability) }
            if federationBusyID == machine.profileID {
                ProgressView()
            } else {
                Button(machine.hasFederationPolicy ? "Unfederate" : "Federate") {
                    if machine.hasFederationPolicy {
                        Task { await changeFederation(machine, enabled: false) }
                    } else {
                        pendingFederate = machine
                    }
                }
                .font(Typography.app(13, .semibold))
                .disabled(federationBusyID != nil || (machine.savedState == "disabled" && !machine.hasFederationPolicy))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    /// Local-only: no agent carries a machineID, so there are no remote peers yet.
    /// Explainer copy in the section body rather than a bare empty card.
    private var federationEmpty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No saved machines yet.")
                .font(Typography.app(13)).foregroundStyle(Palette.textDim)
            Text("Save an SSH machine on your home box, then opt it into federation here.")
                .font(Typography.app(13)).foregroundStyle(Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    /// One peer: an identity disc keyed on the alias (the same circle, gradient and glyph
    /// agent cards use), the alias, an "N agent(s)" line, and a reachability badge.
    private func peerRow(_ peer: PeerSummary) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(AgentIdentity.gradient(for: peer.alias))
                    .frame(width: 40, height: 40)
                Text(AgentIdentity.glyph(for: peer.alias))
                    .font(Typography.app(18, .bold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(peer.displayName)
                    .font(Typography.app(15, .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                Text("\(peer.agentCount) agent\(peer.agentCount == 1 ? "" : "s")")
                    .font(Typography.app(13)).foregroundStyle(Palette.textDim)
            }
            Spacer(minLength: 8)
            peerBadge(peer.reachability)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    /// The peer's aggregate reachability as a badge. Offline reuses the agent list's
    /// quiet `wifi.slash` square (faint ink — offline is quiet, not the stopped-red
    /// alarm); degraded is an amber dot, reachable a quiet green dot.
    @ViewBuilder
    private func peerBadge(_ reachability: PeerReachability) -> some View {
        switch reachability {
        case .offline:
            Image(systemName: "wifi.slash")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.textDim)
                .frame(width: 26, height: 26)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.textDim.opacity(0.55), lineWidth: 1.5))
                .accessibilityLabel(Text("offline"))
        case .degraded:
            Circle().fill(Palette.waiting).frame(width: 8, height: 8)
                .accessibilityLabel(Text("degraded"))
        case .reachable:
            Circle().fill(Palette.done).frame(width: 8, height: 8)
                .accessibilityLabel(Text("reachable"))
        }
    }

    // MARK: Accounts (credential subscriptions)

    /// The credential accounts (subscriptions) configured on the home box — one row
    /// per account with its kind identity, status, and usage. Mirrors
    /// `federationSection`: a section label, a rounded/stroked card of `accountRow`s
    /// (or an empty explainer), and a trailing "How accounts work" info row. Accounts
    /// are set up on the box, so there is no in-app add flow — the info row explains.
    @ViewBuilder
    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("ACCOUNTS")
            if accounts.isEmpty {
                accountsEmpty
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                        accountRow(account)
                            // Items only write state; never rebuilt while open (see
                            // StableContextMenu.swift).
                            .stableContextMenu {
                                // Bulk swap: move every same-kind agent onto this
                                // account at once (e.g. an exhausted Claude → the
                                // spare). Shown only when there are agents to move.
                                if agents.contains(where: { $0.agent == account.kind }) {
                                    StableMenuItem("Use for all \(account.kind.capitalized) agents",
                                                   systemImage: "arrow.left.arrow.right") {
                                        bulkSwapTarget = account
                                    }
                                }
                                // Sign in / out of the account from the app — runs
                                // claude's own auth flow pinned to this account's
                                // config-home (claude only for now; needs config_dir).
                                if account.kind == "claude", account.configDir != nil {
                                    StableMenuItem("Log in", systemImage: "person.crop.circle.badge.plus") {
                                        loginAccount = account
                                    }
                                    StableMenuItem("Log out", systemImage: "rectangle.portrait.and.arrow.right",
                                                   role: .destructive) {
                                        logoutAccount = account
                                    }
                                }
                                // Remove the account from the list entirely (any kind) —
                                // drops it from config.toml; the config-home + creds stay,
                                // so it can be re-added. For clearing out junk/duplicate
                                // entries.
                                StableMenuItem("Remove account", systemImage: "trash", role: .destructive) {
                                    removeAccount = account
                                }
                            }
                        if index < accounts.count - 1 { rowDivider }
                    }
                }
                .settingsGroup()
                .padding(.horizontal, 16).padding(.top, 10)
            }
            richActionRow("Add account", systemImage: "plus.circle",
                          subtitle: "Register a new subscription, then sign in") {
                showAddAccount = true
            }
            richActionRow("How to set up accounts", systemImage: "questionmark.circle",
                          subtitle: "Manual setup on your box") {
                showAccountsSetup = true
            }
        }
    }

    /// No accounts reported (an older daemon, or none configured). Explainer copy in
    /// the section body rather than a bare empty card — mirrors `federationEmpty`.
    private var accountsEmpty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No accounts configured.")
                .font(Typography.app(13)).foregroundStyle(Palette.textDim)
            Text("Subscriptions set up on your home box appear here.")
                .font(Typography.app(13)).foregroundStyle(Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18).padding(.vertical, 14)
        .settingsGroup()
        .padding(.horizontal, 16).padding(.top, 10)
    }

    /// One account: an identity chip keyed on the KIND (the same gradient+glyph the
    /// agent cards use, so an account reads as the same family as the agents that run
    /// on it), the label as title, a "kind · plan" subtitle, and a trailing usage +
    /// status view. Mirrors `peerRow`.
    private func accountRow(_ account: CredentialAccount) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(AgentIdentity.gradient(for: account.kind))
                    .frame(width: 40, height: 40)
                Text(AgentIdentity.glyph(for: account.kind))
                    .font(Typography.app(18, .bold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(account.label)
                    .font(Typography.app(15, .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                Text(accountSubtitle(account))
                    .font(Typography.app(13)).foregroundStyle(Palette.textDim).lineLimit(1)
                if let email = account.email, !email.isEmpty {
                    Text(email)
                        .font(Typography.machine(11)).foregroundStyle(Palette.textFaint).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            accountTrailing(account)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    /// "kind" or "kind · plan" — the plan/tier name folds into the subtitle so the
    /// trailing view can stay the meter+status. Nothing extra when usage is absent.
    private func accountSubtitle(_ account: CredentialAccount) -> String {
        var parts: [String] = [account.kind]
        if let plan = account.usage?.plan ?? account.usage?.tier, !plan.isEmpty {
            parts.append(plan)
        }
        return parts.joined(separator: " · ")
    }

    /// The trailing status/usage cluster: the usage meter(s) when a percent is
    /// reported, then the status indicator — a green dot when active, a red
    /// "exhausted" pill when not (colour = meaning, like the agent status badges).
    @ViewBuilder
    private func accountTrailing(_ account: CredentialAccount) -> some View {
        // One meter per reported rate-limit window (the #144 live-usage render): loop
        // `effectiveWindows` — the real `windows` list, or a pair synthesized from the
        // older flat fields — skipping any window without a percent. Handles 0
        // (tier-only / no usage), 1, or many windows gracefully.
        let windows = (account.usage?.effectiveWindows ?? []).filter { $0.usedPercent != nil }
        // STACKED, not side by side, and the pill never wraps.
        //
        // The status sat BESIDE the meters in an HStack, and an exhausted account that
        // also reports usage — the common case, since hitting 100% is what exhausts it —
        // demanded meter width plus pill width on one line. Two things broke, both
        // visible in the owner's screenshot: `Text("exhausted")` has no line limit, so
        // under that pressure it wrapped to one letter per line and grew a ~9-line tall
        // red capsule that doubled the row height; and the width it took left the label
        // column so narrow that "Claude Pro (personal)" truncated to "C…".
        //
        // Putting the status under the meters removes the competition, and
        // `fixedSize` + `lineLimit(1)` mean the pill keeps its intrinsic width whatever
        // the row does. An active account's dot is small enough that stacking it costs
        // nothing.
        VStack(alignment: .trailing, spacing: 6) {
            if !windows.isEmpty {
                ForEach(windows) { window in
                    usageMeter(window, live: account.usage?.source == "live")
                }
            }
            if account.active {
                Circle().fill(Palette.done).frame(width: 8, height: 8)
                    .accessibilityLabel(Text("active"))
            } else {
                Text("exhausted")
                    .font(Typography.app(11, .semibold)).foregroundStyle(Palette.died)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Palette.died.opacity(0.12)))
                    .overlay(Capsule().stroke(Palette.died.opacity(0.5), lineWidth: 1))
                    .accessibilityLabel(Text("exhausted"))
            }
        }
    }

    /// A tiny usage bar + "NN% · <label>" readout for ONE window, coloured by the
    /// green→amber→red headroom ramp (colour = meaning). Appends a compact reset hint
    /// (today → time, else weekday) when the window carries `resetsAt`, and prefixes a
    /// subtle freshness dot when the snapshot is `source == "live"`.
    private func usageMeter(_ window: UsageWindow, live: Bool) -> some View {
        let clamped = max(0.0, min(100.0, window.usedPercent ?? 0))
        let fill = CGFloat(max(2.0, 34.0 * clamped / 100.0))
        return HStack(spacing: 6) {
            if live {
                Circle().fill(Palette.done).frame(width: 4, height: 4)
                    .accessibilityLabel(Text("live"))
            }
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.hairline).frame(width: 34, height: 4)
                Capsule().fill(usageColor(clamped)).frame(width: fill, height: 4)
            }
            // SPLIT, so the degradation is chosen rather than emergent.
            //
            // Two earlier shapes were both wrong. `fixedSize()` on the whole readout made
            // the meter rigid and squeezed the account label to ~70pt on a 393pt phone.
            // Making the whole readout flexible then let it absorb the entire deficit and
            // truncate the WINDOW LABEL — "42% · 5…" and "68% · w…" — so two stacked
            // meters could not be told apart, which is worse than a short name.
            //
            // The percent and window label are the meter's meaning and stay rigid; they
            // are short and bounded ("100% · weekly" is the widest). The reset hint is
            // the only genuinely optional token, so it is the one that truncates, and it
            // does so before the account label because the label column no longer holds
            // a blanket priority.
            Text(usageEssential(window, percent: clamped))
                .font(Typography.machine(11)).foregroundStyle(Palette.textDim)
                .fixedSize()
            if let hint = resetHint(window.resetsAt) {
                Text("· \(hint)")
                    .font(Typography.machine(11)).foregroundStyle(Palette.textDim)
                    .lineLimit(1)
            }
        }
        // ONE element carrying the WHOLE reading. Splitting the readout for layout must
        // not split it for VoiceOver, and the hint may be visually truncated — so the
        // spoken label is the full string, plus liveness, which was previously a separate
        // "live" element on the dot.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(
            usageMeterLabel(window, percent: clamped) + (live ? " · live" : "")))
        // A read-only readout, declared as such. Without this trait the merged container
        // carries a label but no type, so it is not exposed as a static text — and the
        // receipt asserting the window label survived queries `staticTexts`, which the
        // merge above had silently emptied of the child Texts that used to carry it.
        .accessibilityAddTraits(.isStaticText)
    }

    /// The meter's MEANING: "NN% · <window>". Rigid in the layout, because a meter whose
    /// window label truncated to "w…" cannot be distinguished from the one stacked above
    /// it. Widest real value is "100% · weekly".
    private func usageEssential(_ window: UsageWindow, percent: Double) -> String {
        "\(Int(percent.rounded()))% · \(window.label)"
    }

    /// "NN% · <label>" plus a compact reset token when present, e.g. "42% · 5h · 2h left"
    /// or "68% · weekly · Aug 31". Still used for the accessibility value, which must
    /// carry the whole reading even when the hint is visually truncated.
    private func usageMeterLabel(_ window: UsageWindow, percent: Double) -> String {
        var text = "\(Int(percent.rounded()))% · \(window.label)"
        if let hint = resetHint(window.resetsAt) { text += " · \(hint)" }
        return text
    }

    /// The reset token for a usage window: "2h left" when the reset is near, "Aug 31"
    /// when it is further out. Nil when absent or unparseable, so the meter shows no
    /// token rather than a wrong one.
    ///
    /// Both the parsing and the wording live in `HerdrKit.usageResetLabel` so they can be
    /// tested without a view. This previously parsed ISO-8601 inline and produced nothing
    /// at all against a live server, which sends epoch seconds.
    private func resetHint(_ raw: String?) -> String? {
        usageResetLabel(resetsAt: raw)
    }

    /// Usage colour by headroom: comfortable green, amber as it tightens, red at the
    /// cap. The same meaning-carrying palette as the agent status badges.
    private func usageColor(_ percent: Double) -> Color {
        switch percent {
        case ..<75:  return Palette.done
        case ..<95:  return Palette.waiting
        default:     return Palette.died
        }
    }

    private var notifySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("NOTIFY ME WHEN")
            // One bordered card holds the four toggles AND the honest status row, so
            // the group reads as a single feature rather than four stray rows plus a
            // shrinking-violet footnote.
            VStack(spacing: 0) {
                groupedToggleRow("An agent needs input", $notifyNeedsInput)
                rowDivider
                groupedToggleRow("An agent dies", $notifyDies)
                rowDivider
                finishesRow
                rowDivider
                groupedToggleRow("A gram message arrives", $notifyGram)
                if let fix = notifyPermissionFix {
                    rowDivider
                    notifyPermissionRow(fix)
                }
                rowDivider
                pushMachineRow
            }
            .settingsGroup()
            .padding(.horizontal, 16).padding(.top, 10)
        }
    }

    /// The "An agent finishes" choice, read from and written to its two stored switches.
    private var finishNotifications: Binding<FinishNotifications> {
        Binding(
            get: { FinishNotifications(notifies: notifyFinishes, mineOnly: notifyFinishesMineOnly) },
            set: { choice in
                notifyFinishesMineOnly = choice.mineOnly
                notifyFinishes = choice.notifies
            })
    }

    /// "An agent finishes": Off / Only my requests / Always (owner decision 2026-11-06). Only
    /// my requests skips turns started by gitmoot, scripts, other agents and guests; a machine
    /// whose herdr does not tell them apart pushes every finished turn, which the row says.
    private var finishesRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("An agent finishes").font(Typography.app(17)).foregroundStyle(Palette.text)
                Spacer()
                menuPicker("An agent finishes", value: finishNotifications.wrappedValue.label,
                           identifier: "settings-notify-finishes") {
                    Picker("An agent finishes", selection: finishNotifications) {
                        ForEach(FinishNotifications.allCases, id: \.self) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                }
            }
            if finishNotifications.wrappedValue == .mine, turnOriginSupported == false {
                Text("Herdr on this machine can't tell your requests apart yet, so you'll hear about every agent that finishes.")
                    .font(Typography.app(12)).foregroundStyle(Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-notify-finishes-fallback")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
        .frame(minHeight: 52)
    }

    /// Starts at the 18 pt leading inset every Settings row uses (#357), so it lines up
    /// with the first thing in each row: the label, or the status dot / icon chip of the
    /// glance and notify-callout rows.
    private var rowDivider: some View {
        Rectangle().fill(Palette.hairlineQuiet).frame(height: 1).padding(.leading, 18)
    }

    /// A toggle row WITHOUT its own border — the group around it supplies one border for
    /// all of them. #357: a standard switch (on-tint brand) replaces the ON/OFF word; the
    /// whole row stays the tap target, so tapping the label still flips it.
    private func groupedToggleRow(_ label: String, _ value: Binding<Bool>) -> some View {
        Button { value.wrappedValue.toggle() } label: {
            HStack {
                Text(label).font(Typography.app(17)).foregroundStyle(Palette.text)
                Spacer()
                Toggle("", isOn: .constant(value.wrappedValue))
                    .labelsHidden()
                    .tint(Palette.brand)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(value.wrappedValue ? "on" : "off"))
    }

    /// One status callout in the notify card: an icon chip, a title, a short explanation, and
    /// an optional action. Shared by the iOS-permission row and the machine row.
    private func notifyCallout<Action: View>(
        icon: String, tint: Color, title: String, body: String,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Palette.surfaceRaised))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Typography.app(13, .semibold)).foregroundStyle(Palette.textDim)
                Text(body)
                    .font(Typography.app(12)).foregroundStyle(Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                action()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    /// The SYSTEM notification permission, shown only when it needs fixing: if it's off (never
    /// asked, or denied), the toggles alone deliver nothing, so this offers the fix — a prompt
    /// (notDetermined) or a jump to iOS Settings (denied) — instead of failing silently.
    @ViewBuilder
    private func notifyPermissionRow(_ fix: NotifyPermissionFix) -> some View {
        switch fix {
        case .needAllow:
            notifyCallout(
                icon: "bell", tint: Palette.textDim, title: "Turn on notifications",
                body: "Allow notifications so these alerts can reach you when an agent needs you or a gram arrives."
            ) {
                Button("Allow notifications") { requestNotifications() }
                    .font(Typography.app(13, .semibold)).foregroundStyle(Palette.text)
                    .padding(.top, 2)
            }
        case .denied:
            notifyCallout(
                icon: "bell.slash", tint: Palette.waiting, title: "Notifications are off",
                body: "herdrup can't send these alerts until you allow notifications in iOS Settings."
            ) {
                Button("Open Settings") { openIOSSettings() }
                    .font(Typography.app(13, .semibold)).foregroundStyle(Palette.text)
                    .padding(.top, 2)
            }
        }
    }

    /// Whether the connected machine can actually send push, from its `notifications.status`.
    /// The iOS permission above and this are independent: both must hold for an alert to arrive.
    private var pushMachineRow: some View {
        let (icon, tint, title, body) = pushMachineCopy
        return notifyCallout(icon: icon, tint: tint, title: title, body: body) { EmptyView() }
            .accessibilityIdentifier("settings-push-machine")
    }

    private var pushMachineCopy: (String, Color, String, String) {
        switch pushAvailability {
        case nil:
            return ("bell", Palette.textFaint, "Checking this machine…", "Asking Herdr whether it can send notifications.")
        case .unreachable:
            return ("bell", Palette.textFaint, "Couldn't check this machine",
                    "Herdr didn't answer. Reopen Settings to check again.")
        case .daemonTooOld:
            return ("arrow.down.circle", Palette.waiting, "Update Herdr on this machine to get notifications",
                    "This version of Herdr can't send notifications to your iPhone.")
        case .status(let status):
            switch status.state {
            case .relayReady:
                return ("bell.badge", Palette.done, "Notifications are on",
                        "This machine sends alerts through the HerdrUp push relay.")
            case .directReady:
                return ("bell.badge", Palette.done, "Notifications are on",
                        "This machine sends alerts with its own Apple push key.")
            case .unconfigured where status.mode == "direct":
                return ("bell.slash", Palette.waiting, "This machine can't send notifications yet",
                        "Herdr is set to push directly but has no Apple push key. Set push.mode to \"auto\" in Herdr's config to use the HerdrUp relay.")
            case .unconfigured:
                return ("bell.slash", Palette.waiting, "This machine can't send notifications yet",
                        "This iPhone hasn't joined the HerdrUp push relay yet. Allow notifications, then reopen HerdrUp while connected.")
            case .off:
                return ("bell.slash", Palette.textDim, "Notifications are turned off in Herdr on this machine",
                        "Set push.mode to \"auto\" in Herdr's config on this machine to turn them on.")
            case .unsupported:
                return ("bell.slash", Palette.waiting, "This machine can't send notifications",
                        "Herdr is running without its server here. Start Herdr normally to get notifications.")
            }
        }
    }

    /// Ask the connected machine whether it can push. On appear and on foreground, so a config
    /// change or a fresh relay enrollment shows up without reconnecting.
    private func refreshPushAvailability() async {
        pushAvailability = await client.pushAvailability()
        turnOriginSupported = await client.advertisesTurnOrigin()
    }

    /// At least one alert category is on. A permission FIX is only surfaced when this is
    /// true — if every toggle is off the system permission is moot, so we neither prompt
    /// nor point to Settings (matching AppDelegate.requestAuthorizationIfWanted's gating).
    private var anyNotifyOn: Bool { notifyNeedsInput || notifyDies || notifyFinishes || notifyGram }

    private enum NotifyPermissionFix { case needAllow, denied }
    private var notifyPermissionFix: NotifyPermissionFix? {
        guard anyNotifyOn else { return nil }
        switch notifyAuth {
        case .notDetermined: return .needAllow
        case .denied: return .denied
        default: return nil
        }
    }

    private func refreshNotifyAuth() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async {
                notifyAuth = s.authorizationStatus
                guard [.authorized, .provisional, .ephemeral].contains(s.authorizationStatus) else { return }
                // Never register during a buildbox screenshot / XCUITest run — mirrors
                // AppDelegate's guard so an authorized test device can't register while the
                // Settings screen merely renders. ScreenshotMock is DEBUG-only, so is the guard.
                #if DEBUG
                guard ScreenshotMock.mode == nil else { return }
                #endif
                // (Re)register for APNs so a token actually issues — e.g. the user just
                // enabled notifications in iOS Settings. registerForRemoteNotifications is
                // idempotent, so refreshing repeatedly is harmless.
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    private func requestNotifications() {
        // Same test-mode guard as AppDelegate.requestAuthorizationIfWanted: never prompt
        // or register during a screenshot / XCUITest run.
        #if DEBUG
        guard ScreenshotMock.mode == nil else { return }
        #endif
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                if granted { UIApplication.shared.registerForRemoteNotifications() }
                refreshNotifyAuth()
            }
        }
    }

    private func openIOSSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    /// The UI text-size multiplier (same UserDefaults key RootView applies to
    /// `Typography.scale`). Writing it here re-renders the whole app at the new
    /// size — the terminal is unaffected (it has its own font control below).
    @AppStorage("ui.fontScale") private var uiFontScale: Double = 1.0
    /// Instant typing (`PredictionEngine.Mode` raw value); every open terminal reads the
    /// same key, so a change applies to the next key typed.
    @AppStorage(PredictiveEchoSetting.key) private var predictiveEcho = PredictiveEchoSetting.defaultValue
    @AppStorage(ChatPreference.key) private var ompOpensIn = ChatPreference.defaultValue

    /// The terminal font size (points), the same app-wide pref the per-agent ⋯ menu
    /// and ⌘± drive. Writing it here live-updates any open terminal (LiveTerminalView
    /// applies the new size in place via its own `@AppStorage` observer).
    @AppStorage("terminal.fontSize") private var terminalFontSize: Double = 12.5
    /// Whether a RECEIVED html/svg preview may run script. OFF by default — see
    /// `previewsRow` and `HtmlWebView`.
    @AppStorage(WebViewPolicy.javaScriptDefaultsKey) private var previewJavaScript = false

    /// "Run JavaScript in previews" — the one switch that loosens how a RECEIVED html/svg attachment
    /// is rendered. Off by default and stated plainly, because the document is written
    /// by whoever sent it: script stays off unless the reader turns it on for this
    /// device. The row under the switch has to be accurate about what stays true, and
    /// what does not: remote loads and navigation are still blocked, but a script can
    /// signal that the file was opened by a route no URL rule sees.
    private var previewsRow: some View {
        Button { previewJavaScript.toggle() } label: {
            glyphRow("Run JavaScript in previews",
                     systemImage: previewJavaScript ? "exclamationmark.triangle" : "chevron.left.forwardslash.chevron.right",
                     subtitle: previewJavaScript
                         ? "On: scripts in a previewed file will run. A file written to do so could signal that you opened it."
                         : "Off: scripts in a previewed file are ignored.") {
                Toggle("", isOn: .constant(previewJavaScript))
                    .labelsHidden()
                    .tint(Palette.brand)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(previewJavaScript ? "on" : "off"))
        .accessibilityIdentifier("settings-preview-javascript")
    }

    /// The two text-size controls — app chrome scale + terminal font — on the Preferences ›
    /// Text size page, the same on every layout. Both live
    /// here so the setting reads the same on every layout.
    @ViewBuilder
    private var appearanceControls: some View {
        // App chrome (Typography.scale), 90–140%.
        textSizeControl(
            caption: "App text — lists, menus & settings",
            value: "\(Int((uiFontScale * 100).rounded()))%",
            preview: { Text("The quick brown fox").font(Typography.app(15)) },
            canDecrease: uiFontScale > 0.9, onDecrease: { stepFontScale(-0.1) },
            canReset: uiFontScale != 1.0, onReset: { uiFontScale = 1.0 },
            canIncrease: uiFontScale < 1.4, onIncrease: { stepFontScale(0.1) }
        )
        // Terminal font (terminal.fontSize), 9–24 pt.
        textSizeControl(
            caption: "Terminal text — agent output",
            value: "\(String(format: "%g", terminalFontSize)) pt",
            preview: { Text("~ $ herdr").font(Typography.machine(15)) },
            canDecrease: terminalFontSize > 9, onDecrease: { stepTerminalFont(-1) },
            canReset: terminalFontSize != 12.5, onReset: { terminalFontSize = 12.5 },
            canIncrease: terminalFontSize < 24, onIncrease: { stepTerminalFont(1) }
        )
    }

    /// One labelled text-size control: a caption, a preview + current value, and the
    /// A−/Reset/A+ button row — the card style the appearance section has always used.
    private func textSizeControl<P: View>(
        caption: String,
        value: String,
        @ViewBuilder preview: () -> P,
        canDecrease: Bool, onDecrease: @escaping () -> Void,
        canReset: Bool, onReset: @escaping () -> Void,
        canIncrease: Bool, onIncrease: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption)
                .font(Typography.app(12, .semibold)).foregroundStyle(Palette.textFaint)
            VStack(spacing: 0) {
                HStack {
                    preview().foregroundStyle(Palette.text).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(value)
                        .font(Typography.machine(13, .bold)).foregroundStyle(Palette.textDim)
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                rowDivider
                HStack(spacing: 10) {
                    textSizeButton("A\u{2212}", enabled: canDecrease, onDecrease)
                    textSizeButton("Reset", enabled: canReset, onReset)
                    textSizeButton("A+", enabled: canIncrease, onIncrease)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
            }
            .settingsGroup()
        }
        .padding(.horizontal, 16).padding(.top, 10)
    }

    /// Step the UI scale by `delta`, rounded to 0.1 and clamped to [0.9, 1.4].
    private func stepFontScale(_ delta: Double) {
        let next = ((uiFontScale + delta) * 10).rounded() / 10
        uiFontScale = min(1.4, max(0.9, next))
    }

    /// Step the terminal font by `delta` points, clamped to [9, 24] — matches the
    /// per-agent ⋯ menu and ⌘± controls.
    private func stepTerminalFont(_ delta: Double) {
        terminalFontSize = min(24, max(9, terminalFontSize + delta))
    }

    /// #357: A− / Reset / A+ as three equal round buttons, 38 pt tall, `surfaceRaised`;
    /// a disabled step is dimmed rather than hidden so the row never changes shape.
    private func textSizeButton(_ title: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.app(15, .semibold))
                .foregroundStyle(enabled ? Palette.text : Palette.textFaint)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(Capsule().fill(Palette.surfaceRaised.opacity(enabled ? 1 : 0.5)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .disabled(!enabled)
    }

    // MARK: Typing latency (Help → Typing latency)

    /// Key-to-screen numbers from `TypingLatencyRecorder`, one block per machine and
    /// network, with the report the owner pastes back. Refreshed every second while open
    /// so it follows typing done in a terminal behind it (iPad).
    private func typingLatencyDetail(showBack: Bool) -> some View {
        detailScaffold(title: "Typing latency", subtitle: "Key press to screen, on this phone",
                       showBack: showBack) {
            Text("Type normally in a terminal, then come back here.")
                .font(Typography.app(13)).foregroundStyle(Palette.textDim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 34).padding(.top, 14)
            if latencyReports.isEmpty {
                Text("No typing measured yet.")
                    .font(Typography.app(15)).foregroundStyle(Palette.textFaint)
                    .settingsRowShell()
                    .padding(.horizontal, 16).padding(.top, 10)
            }
            ForEach(latencyReports) { report in
                sectionLabel("\(report.host) · \(report.network)".uppercased())
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(report.plainLines(), id: \.self) { line in
                        Text(line).font(Typography.app(15)).foregroundStyle(Palette.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .settingsRowShell()
                .padding(.horizontal, 16).padding(.top, 10)
            }
            sectionLabel("REPORT")
            actionRow(latencyCopied ? "Copied ✓" : "Copy report") { copyLatencyReport() }
            actionRow("Reset") {
                TypingLatencyRecorder.shared.reset()
                latencyReports = TypingLatencyRecorder.shared.report()
            }
        }
        .task {
            while !Task.isCancelled {
                latencyReports = TypingLatencyRecorder.shared.report()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func copyLatencyReport() {
        let info = Bundle.main.infoDictionary
        UIPasteboard.general.string = TypingLatencyRecorder.shared.reportText(
            appVersion: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String)
        latencyCopied = true
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); latencyCopied = false }
    }

    /// The tip jar (StoreKit 2). Renders ONLY when products are loaded — `.idle`,
    /// `.loading`, and `.unavailable` all render nothing, so the section is simply
    /// absent before the App Store Connect products exist or when offline.
    @ViewBuilder
    private var supportSection: some View {
        if case .loaded(let products) = tipStore.loadState, !products.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionLabel("SUPPORT THE PROJECT")
                VStack(spacing: 0) {
                    ForEach(Array(products.enumerated()), id: \.element.id) { index, product in
                        tipRow(product)
                        if index < products.count - 1 { rowDivider }
                    }
                }
                .settingsGroup()
                .padding(.horizontal, 16).padding(.top, 10)
                supportFeedback
            }
        }
    }

    @ViewBuilder
    private var supportFeedback: some View {
        switch tipStore.purchaseState {
        case .thankYou:
            Text("Thank you, it means a lot.")
                .font(Typography.app(12, .medium)).foregroundStyle(Palette.done)
                .padding(.horizontal, 20).padding(.top, 8)
        case .failed(let message):
            Text(message)
                .font(Typography.app(12)).foregroundStyle(Palette.died)
                .padding(.horizontal, 20).padding(.top, 8)
        case .idle, .purchasing:
            EmptyView()
        }
    }

    private func tipRow(_ product: Product) -> some View {
        Button { Task { await tipStore.purchase(product) } } label: {
            HStack(spacing: 12) {
                Image(systemName: tipGlyph(for: product.id))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.textDim)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.surfaceRaised))
                Text(product.displayName.isEmpty ? tipFallbackName(product.id) : product.displayName)
                    .font(Typography.app(15)).foregroundStyle(Palette.text)
                Spacer()
                if isPurchasing(product) {
                    ProgressView().tint(Palette.textDim)
                } else {
                    Text(product.displayPrice)
                        .font(Typography.machine(13, .semibold)).foregroundStyle(Palette.text)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .disabled(isPurchasing(product))
    }

    private func isPurchasing(_ product: Product) -> Bool {
        if case .purchasing(let id) = tipStore.purchaseState { return id == product.id }
        return false
    }

    private func tipGlyph(for id: String) -> String {
        if id == TipStore.coffeeID { return "cup.and.saucer.fill" }
        if id == TipStore.lunchID { return "fork.knife" }
        return "wineglass.fill"
    }

    private func tipFallbackName(_ id: String) -> String {
        if id == TipStore.coffeeID { return "Coffee" }
        if id == TipStore.lunchID { return "Lunch" }
        return "Dinner"
    }

    /// The root's footer: "herdrup mobile <version> (<build>)" with the design's one-line
    /// stance under it. Version + build come from the bundle (MARKETING_VERSION /
    /// CFBundleVersion), so they track the shipped build, not a hardcoded string.
    private var versionFooter: some View {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return VStack(spacing: 4) {
            Text("herdrup mobile \(short) (\(build))")
                .font(Typography.machine(12)).foregroundStyle(Palette.textFaint)
            Text("dark only, on purpose")
                .font(Typography.machine(11)).foregroundStyle(Palette.textFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
    }

    /// A page's section header: `text.microLabel` caps at x = 32, 22 pt above and 8 below
    /// (proposal B's group headers, the same as the root's).
    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(Typography.microLabel).tracking(DesignTokens.Text.MicroLabel.tracking)
            .foregroundStyle(Palette.textFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32).padding(.top, 22).padding(.bottom, 8)
    }

    /// An action row (proposal B): a brand Geist 17/600 label and no chevron, since it acts
    /// in place; a disabled one dims and says why.
    private func actionRow(_ label: String, enabled: Bool = true, note: String? = nil, _ action: @escaping () -> Void) -> some View {
        groupedActionRow(label, enabled: enabled, note: note, action)
            .settingsGroup()
            .padding(.horizontal, 16).padding(.top, 10)
    }

    /// `actionRow`'s row on its own, for a group holding several (Machines › Connection).
    private func groupedActionRow(_ label: String, enabled: Bool = true, note: String? = nil, _ action: @escaping () -> Void) -> some View {
        Button { if enabled { action() } } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(Typography.app(17, .semibold)).foregroundStyle(enabled ? Palette.brand : Palette.textFaint)
                    if !enabled, let note {
                        Text(note).font(Typography.app(11)).foregroundStyle(Palette.textFaint)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// An icon-led row with an ALWAYS-visible subtitle (unlike `actionRow`, whose
    /// `note` shows only when disabled). Used for Gestures and, via `linkRow`, the
    /// outbound Privacy/Terms links.
    private func richActionRow(
        _ label: String, systemImage: String, subtitle: String? = nil,
        trailingGlyph: String = "chevron.right", _ action: @escaping () -> Void
    ) -> some View {
        richActionRow(label, subtitle: subtitle, trailingGlyph: trailingGlyph, action: action) {
            Image(systemName: systemImage).font(.system(size: 15, weight: .semibold))
        }
    }

    /// The same row with its leading glyph supplied by the caller.
    ///
    /// Every row here uses an SF Symbol except Discord, which has no SF Symbol and draws
    /// Discord's own asset from an imageset instead. That row also opts out of the chip's
    /// tint, because its mark has to stay in Discord's colour — see `discordRow`.
    ///
    /// The chip is `accessibilityHidden`: the row's own label is the accessible name, and
    /// a decorative mark adds nothing to it.
    private func richActionRow<Leading: View>(
        _ label: String, subtitle: String? = nil,
        trailingGlyph: String = "chevron.right",
        action: @escaping () -> Void,
        @ViewBuilder leading: () -> Leading
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // #357: a plain 24 pt glyph in textDim, no tile.
                leading()
                    .foregroundStyle(Palette.textDim)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(Typography.app(17)).foregroundStyle(Palette.text)
                    if let subtitle {
                        Text(subtitle).font(Typography.app(13)).foregroundStyle(Palette.textDim)
                    }
                }
                Spacer()
                Image(systemName: trailingGlyph)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.textFaint)
            }
            .settingsRowShell()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16).padding(.top, 10)
    }

    /// The community invite, with Discord's official symbol.
    ///
    /// The mark is `Shared/Assets.xcassets/DiscordMark.imageset`, downscaled from
    /// `Discord-Symbol-Blurple.png` in Discord's own brand kit
    /// (`cdn.discordapp.com/assets/content/a736b959…zip`, `Discord_Symbol_Color/`) — their
    /// file, their blurple, not a redraw. The three scales are 33x25, 66x50 and 99x75,
    /// which are exact reductions of the 528x400 source, so no scale distorts the mark.
    /// Provenance, what was done to the file, and the trademark position are recorded in
    /// `NOTICE-Discord-Brand.txt` at the repository root — root deliberately, because
    /// `Shared/` is a sources path and a stray text file there can end up copied into the
    /// bundle as a resource.
    ///
    /// An earlier version drew `fa-discord` from the bundled Nerd Fonts subset instead.
    /// That was withdrawn on the trademark question, not the licence one: Font Awesome
    /// Free ships under CC BY 4.0 with attribution already in the bundle, but CC BY
    /// grants no trademark rights, and the row was tinting a third-party redraw grey.
    private var discordRow: some View {
        Button { openURL(Self.discordInvite) } label: {
            glyphRow("Join the Discord", glyph: {
            // DISCORD'S OWN ASSET, IN DISCORD'S OWN COLOUR, and both halves are the point.
            //
            // This was a Font Awesome redraw taken from the bundled Nerd Fonts subset,
            // tinted `Palette.textDim` grey to match the rows around it. The licence side
            // of that was clean (CC BY 4.0, attribution shipped), but CC BY grants no
            // TRADEMARK rights, and Discord's brand policy asks for the official mark in
            // an approved colour. Owner's decision was the official asset.
            //
            // `.renderingMode(.original)` is load-bearing: without it the chip's
            // `foregroundStyle(Palette.textDim)` from `richActionRow` would tint blurple
            // to grey and put us back in the same place. This is the one icon in Settings
            // that is deliberately NOT monochrome.
            //
            // Sized by WIDTH with `scaledToFit`: the mark is 1.32:1, so a square frame
            // would either letterbox it or distort it, and the 30x30 chip is square.
            Image("DiscordMark")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: 18)
            }, trailing: { externalGlyph })
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings-discord")
    }

    /// The invite. A raw code rather than a vanity URL. The previous code, TTFRHFyDXf,
    /// was believed never to expire but did (#302). This one was checked on 2026-09-28
    /// with Discord's invite API: `expires_at` is null. Nothing in the app or in CI can
    /// detect a dead invite, and correcting one needs an App Store release, so re-check
    /// it before each release; if it is ever rotated, prefer a vanity URL.
    private static let discordInvite = URL(string: "https://discord.gg/pq7qj4dDqt")!

    private func copyDiagnostics() {
        // Host + app version only — never anything sensitive (no key, ever).
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        UIPasteboard.general.string = "herdr-ios \(version), host \(host)"
        copied = true
        // Revert the confirmation so a second copy gives feedback.
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); copied = false }
    }
}
