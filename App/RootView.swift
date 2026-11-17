import SwiftUI
import Foundation
import UIKit    // UIPasteboard (Copy diagnostics)
import UniformTypeIdentifiers
import StoreKit // Product / tip jar (Settings' Support section)
import UserNotifications // notification authorization status (Settings notify section)
import HerdrKit

// Palette / Typography / status tokens now live in DesignSystem.swift.


struct RootView: View {
    // Owns the transport (so disconnect can `close()` it — that's the transport's
    // method, not the client's), the credentials (to rebuild on reconnect), and
    // the pin policy (to forget a host key on a verified rotation).
    @State private var transport: CitadelTransport?
    @State private var client: HerdrClient?
    @State private var credentials: SSHCredentials?
    #if DEBUG
    @State private var mockDisconnected = false
    #endif
    @State private var session = 0   // bumped to force a fresh load on reconnect
    /// The connected machine's sessions as last seen, so a session switch starts from them (#386).
    @State private var sessionCache = SessionSwitchCache()
    /// #377: after a machine is tapped, the machine list stays up (its row reads
    /// "Connecting…") until the first agent list arrives, the attempt fails, or a short
    /// cap passes; only then does the Agents screen slide in. `homeShown` gates that.
    @State private var homeShown = false
    /// Bumped per connect, so a superseded attempt's reveal cannot fire late.
    @State private var connectGeneration = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private let pins = KeychainHostKeyPolicy.shared
    // The APNs token + tapped-notification target live here (in PushCenter), not in the
    // `.id(session)` home view, so they survive a reconnect. RootView owns the client, so it is what
    // (re)sends the token to the server whenever a connection exists.
    @ObservedObject private var push = PushCenter.shared
    /// Per-agent push mutes (the terminal header's ⋯ menu). Observed so a toggle
    /// re-registers the device immediately (like the category prefs below).
    @ObservedObject private var mute = MuteStore.shared
    // The #90 Live Activity's per-activity push token lives here (survives reconnect like the
    // device token); RootView registers it with the server so the widget updates in the background.
    @ObservedObject private var liveActivity = LiveActivityController.shared
    // Mirror the Settings push toggles here so a change WHILE CONNECTED re-registers the new prefs
    // with the server (and can surface the permission prompt if a category was just enabled) —
    // otherwise a toggle would only take effect on the next connect/reconnect. Keys + defaults match
    // SettingsView exactly; @AppStorage observes UserDefaults app-wide, so SettingsView's writes fire
    // the onChange handlers below even though they live on different views.
    @AppStorage("notify.needsInput") private var notifyNeedsInput = true
    @AppStorage("notify.dies") private var notifyDies = true
    @AppStorage("notify.finishes") private var notifyFinishes = false
    @AppStorage("notify.finishesMineOnly") private var notifyFinishesMineOnly = false
    @AppStorage("notify.gram") private var notifyGram = true
    /// UI text-size multiplier (the "Text size" setting). Applied to `Typography`
    /// so all app chrome scales; the terminal has its own font control.
    @AppStorage("ui.fontScale") private var uiFontScale: Double = 1.0
    /// Guest access (#312): machines shared with this phone, the invite waiting on the
    /// Accept screen, and the shared machine whose home is open (it takes precedence
    /// over the owner session, which stays connected underneath).
    @ObservedObject private var sharedMachines = SharedMachinesStore.shared
    @ObservedObject private var invites = GuestInviteRouter.shared
    /// Pairing a machine (#126): the scanner, or the confirmation for a pasted or linked code.
    @ObservedObject private var pairing = PairingRouter.shared
    @State private var openGuest: GuestAccess?
    /// Whether launch already decided to open the only shared machine.
    @State private var didAutoOpenGuest = false
    /// The connection's Gram downloads (#574): here, above the tab view and the split view,
    /// so a download started on the Gram page keeps going on Agents. Cancelled when the
    /// connection goes (`disconnect`, `reconnect`, `switchSession`).
    @State private var gramDownloads = GramDownloadStore()

    #if DEBUG
    /// One stable driver instance for the whole stress-test process. Recreating it
    /// during a SwiftUI body evaluation would reset its call and gesture counters.
    private static let rosterStressDriver = RosterStressDriver()
    #endif

    var body: some View {
        // Apply the user's text-size multiplier before the tree renders. Do NOT
        // key the content on it (`.id()`) — that would change identity and reset
        // the home tab / terminal panes / scroll on every step. Instead, the
        // views that render chrome observe `@AppStorage("ui.fontScale")` (Settings
        // directly; the home reads it too), so their bodies
        // re-run at the new `Typography.scale` with their @State intact.
        Typography.scale = CGFloat(min(1.4, max(0.9, uiFontScale)))
        return Group {
            #if DEBUG
            if let mock = ScreenshotMock.mode {
                if ProcessInfo.processInfo.environment["HERDR_DESKTOPREF_CAPTURE"] == "1" {
                    let _ = DesktopReferenceMock.prepared
                    mockView(mock)
                        .transaction { $0.disablesAnimations = true; $0.animation = nil }
                        .overlay(alignment: .topLeading) { DesktopReferenceProbe().frame(width: 1, height: 1) }
                } else {
                    mockView(mock)
                }
            } else {
                liveContent
            }
            #else
            liveContent
            #endif
        }
        .preferredColorScheme(.dark)
        .environment(\.gramDownloads, gramDownloads)
        .fullScreenCover(item: $invites.pending) { pending in
            inviteAccept(pending.invite)
        }
        .alert("Can't open this invite", isPresented: Binding(
            get: { invites.failure != nil },
            set: { if !$0 { invites.failure = nil } }
        )) {
            if invites.retryText != nil {
                Button("Try Again") { invites.retry() }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(invites.failure ?? "")
        }
        .sheet(item: $pairing.pending) { pending in
            PairingSheet(store: SavedHostsStore.shared, initialPayload: pending.payload,
                         activeConnection: activeConnectionLabel) { nickname in
                openPairedMachine(nickname)
            }
        }
        .alert("Can't use this pairing code", isPresented: Binding(
            get: { pairing.failure != nil },
            set: { if !$0 { pairing.failure = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pairing.failure ?? "")
        }
        .onAppear { autoOpenSharedMachine() }
        // A tapped push for an agent shared with this phone opens that share (its home picks
        // the Gram tab or the terminal), in place of whatever screen is showing. A share the
        // phone no longer holds opens nothing.
        .onReceive(push.$pendingGuest) { route in
            guard let route else { return }
            guard let share = route.access(in: sharedMachines.machines) else {
                push.pendingGuest = nil
                return
            }
            if openGuest?.id != share.id { openGuest = share }
        }
        // Shares with push on hold this phone's token too: a new one is registered with each.
        .onChange(of: push.deviceToken) { _, _ in
            GuestPushCenter.shared.deviceTokenChanged(shares: sharedMachines.machines)
        }
        // Reclaim gram attachment staging left by a PREVIOUS session (a crash or a
        // jetsam kill runs no cleanup) here rather than on the Gram page: bytes from a
        // killed session — up to ten 100 MB attachments — would otherwise survive every
        // launch in which the user never opens the Gram tab.
        .task { await ComposerStaging.sweepAbandonedOffMainActor() }
        // Back in the foreground the held request channels may have died with the
        // network while the app was suspended (#391): have each ping before its next
        // request instead of letting that request find out by timing out.
        // Going to the background, close the guest relay sessions kept open between
        // calls (a suspended socket dies with the network); the next call connects afresh.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { RelayTransport.closeReusedSessions() }
            guard phase == .active, let transport else { return }
            Task { await transport.markRequestChannelsSuspect() }
        }
        // The anonymous daily usage ping: on launch and on every return to the foreground,
        // connected or not; `UsagePing` sends at most one a UTC day (see `UsagePingLaunch`).
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { UsagePingLaunch.foregrounded() }
        }
    }

    @ViewBuilder
    private var liveContent: some View {
        if let openGuest {
            SharedMachineHomeView(
                access: openGuest,
                onBack: { self.openGuest = nil },
                onLeave: { self.openGuest = nil })
            .id(openGuest.id)
        } else if let client, let credentials, homeShown {
            TerminalHomeView(
                client: client,
                onDisconnect: { disconnect() },
                host: credentials.host,
                hostKey: SessionChoice.storeKey(credentials),
                session: credentials.session,
                onSwitchSession: { switchSession(to: $0) },
                sessionCache: sessionCache,
                onReconnect: { reconnect() },
                onTrustHostKey: { fingerprint in trustAndReconnect(credentials, fingerprint: fingerprint) }
            )
            .id(session)
            .environment(\.guestMachineLabel, Self.hostLabel(for: credentials))
            // A device token can arrive AFTER connect (the APNs callback is async + independent of
            // SSH); register it whenever it lands while connected.
            .onChange(of: push.deviceToken) { _, _ in registerPush() }
            // The Live Activity push token also arrives async (after start) and can rotate; register
            // it whenever it lands so the server can push widget updates while the app is closed.
            // initial: true so a token that arrived BEFORE this connected subtree mounted (or a
            // reclaimed activity's existing token) is registered on appear, not silently missed.
            .onChange(of: liveActivity.pushToken, initial: true) { _, _ in registerActivityPush() }
            // A push-category toggle flipped in Settings while connected: re-register the new prefs
            // (and prompt if a category was just enabled), instead of waiting for a reconnect.
            .onChange(of: notifyNeedsInput) { _, _ in pushPrefsChanged() }
            .onChange(of: notifyDies) { _, _ in pushPrefsChanged() }
            .onChange(of: notifyFinishes) { _, _ in pushPrefsChanged() }
            .onChange(of: notifyFinishesMineOnly) { _, _ in pushPrefsChanged() }
            .onChange(of: notifyGram) { _, _ in pushPrefsChanged() }
            // A per-agent mute toggled in the terminal header: re-register the new set
            // so the daemon starts/stops skipping that pane's pushes immediately.
            .onChange(of: mute.mutedPanes) { _, _ in registerPush() }
            .transition(reduceMotion ? .opacity : .push(from: .trailing))
        } else {
            ConnectView(onConnect: { connect($0) }, onOpenShared: { openGuest = $0 },
                        connecting: client == nil ? nil : credentials)
            .transition(reduceMotion ? .opacity : .push(from: .trailing))
        }
    }

    /// The machine this phone is connected to, named as the confirmation shows it, so pairing
    /// another asks before replacing it (as a scanned code always has).
    private var activeConnectionLabel: String? {
        guard client != nil, let credentials else { return nil }
        return Self.hostLabel(for: credentials)
    }

    /// The person tapped "Open it" on a machine they just paired: close what is showing (the
    /// session, a shared machine's home — the share stays in the list) and connect to it,
    /// here and now. Nothing is handed to the machine list to act on later, so returning to
    /// that list never connects by itself.
    private func openPairedMachine(_ nickname: String) {
        let store = SavedHostsStore.shared
        openGuest = nil
        if client != nil { disconnect() }
        // Just saved with its key, so this is ready. If not, the machine list shows the new
        // row, and tapping it explains what is missing.
        guard let saved = store.hosts.first(where: { $0.nickname == nickname }),
              case .ready(let creds) = store.connection(for: saved)
        else { return }
        #if DEBUG
        // The mock list (`list`) stands in for a connection with its own flag.
        if ScreenshotMock.mode != nil {
            mockDisconnected = false
            return
        }
        #endif
        connect(creds)
    }

    private func autoOpenSharedMachine() {
        #if DEBUG
        guard ScreenshotMock.mode == nil else { return }
        #endif
        guard !didAutoOpenGuest else { return }
        didAutoOpenGuest = true
        if SavedHostsStore.shared.hosts.isEmpty, sharedMachines.groups.count == 1 {
            openGuest = sharedMachines.groups.first?.accesses.first
        }
    }

    /// The Accept screen for an invite that arrived as a link, a paste or a scan.
    private func inviteAccept(_ invite: GuestInvite) -> some View {
        GuestAcceptView(
            invite: invite,
            fingerprint: try? GuestDevice.identity().fingerprint,
            accept: {
                let identity = try GuestDevice.identity()
                return try await GuestSession.accept(invite, identity: identity, device: UIDevice.current.model)
            },
            onAccepted: { access in
                sharedMachines.add(access)
                invites.pending = nil
                openGuest = access
            },
            onCancel: { invites.pending = nil })
    }

    /// Send the APNs token (with the current category prefs) to the server, if we have both a live
    /// client and a token. Idempotent + fire-and-forget — a server without the method just throws.
    /// The relay capability rides along when enrollment succeeded (usually from cache); without it
    /// the token is still registered, so a machine with its own APNs key keeps pushing.
    private func registerPush(with explicitClient: HerdrClient? = nil, credentials explicitCredentials: SSHCredentials? = nil) {
        // Prefer the client the caller JUST built (connect/reconnect pass it in) over the @State
        // `client`, which the SwiftUI setter may not have published through yet on the same tick.
        guard let client = explicitClient ?? self.client, let token = push.deviceToken else { return }
        let routeCredentials = explicitCredentials ?? credentials
        Task { @MainActor in
            let capability = await PushCenter.relay.capability(kind: .device, token: token)
            // Read the prefs AFTER enrolling (which can take up to its timeout), so a toggle
            // flipped meanwhile is not overwritten by this call's older snapshot.
            let p = PushCenter.Prefs.current
            let muted = Array(MuteStore.shared.mutedPanes)
            do {
                try await client.registerDevice(token: token, needsInput: p.needsInput, dies: p.dies, finishes: p.finishes, gram: p.gram, mutedPanes: muted, relayCapability: capability)
            } catch {
                return
            }
            // This daemon may now push questions with answer buttons (#483); they name it by its
            // install id, so remember which connection reaches that id for when one is pressed.
            guard let routeCredentials,
                  let machineID = try? await client.agentListing().originMachineID else { return }
            AskPushAnswer.recordRoute(machineID: machineID, credentials: routeCredentials)
        }
    }

    /// Register the current Live Activity push token with the server, if we have both a live client
    /// and a token. Idempotent + best-effort — mirrors registerPush; a server without the method
    /// just throws, and the widget still updates in the foreground.
    private func registerActivityPush(with explicitClient: HerdrClient? = nil) {
        guard let client = explicitClient ?? self.client, let token = liveActivity.pushToken else { return }
        Task {
            let capability = await PushCenter.relay.capability(kind: .activity, token: token)
            try? await client.registerActivity(token: token, relayCapability: capability)
        }
    }

    /// A push-category toggle changed while connected: re-register the current prefs with the server so the
    /// change takes effect immediately (registerPush is a no-op until a device token exists), AND request the
    /// permission prompt — so a user who connected with every category OFF (nothing to prompt for then) and
    /// later enables one gets asked NOW, instead of never. requestAuthorizationIfWanted self-guards on
    /// `anyEnabled` and skips under ScreenshotMock, and iOS shows the alert at most once per install (later
    /// calls return the existing status silently), so this is safe + idempotent to call on every toggle.
    private func pushPrefsChanged() {
        registerPush()
        AppDelegate.requestAuthorizationIfWanted()
    }

    #if DEBUG
    /// Renders a screen from MockTransport (no connection, no key) so the buildbox
    /// can screenshot the list/pane views safely.
    @ViewBuilder
    private func mockView(_ mode: ScreenshotMock) -> some View {
        let mockClient = HerdrClient(transport: MockTransport())
        switch mode {
        case .resize, .control:
            TerminalInteractionRoot(control: mode == .control)
        case .onboarding:
            ConnectView { _ in }
        case .pairingGuidance:
            ZStack {
                Palette.ground.ignoresSafeArea()
                PairingCommandGuidance().padding(24)
            }
        case .forkNotice:
            ForkNoticeView(onDismiss: {})
        case .list:
            if mockDisconnected {
                ConnectView { _ in mockDisconnected = false }
            } else {
                TerminalHomeView(client: mockClient, onDisconnect: { mockDisconnected = true },
                                 onTrustHostKey: { _ in false }, livePaneIDs: MockWireFixtures.demoLivePaneIDs)
            }
        case .archivedClose:
            TerminalHomeView(client: HerdrClient(transport: ForgetCapableMockTransport()), onDisconnect: {},
                             onTrustHostKey: { _ in false }, livePaneIDs: MockWireFixtures.demoLivePaneIDs)
        case .needsYou:
            VStack(spacing: 0) {
                if NeedsYouMockTransport.manualWaiting {
                    Button("Start waiting") { NeedsYouMockTransport.startWaiting() }
                        .accessibilityIdentifier("fixture-start-waiting")
                        .buttonStyle(.bordered)
                        .padding(8)
                }
                TerminalHomeView(client: HerdrClient(transport: NeedsYouMockTransport()), onDisconnect: {},
                                 onTrustHostKey: { _ in false })
            }
        case .folders:
            let _ = AgentFoldersMockTransport.prepared
            TerminalHomeView(client: HerdrClient(transport: AgentFoldersMockTransport()), onDisconnect: {},
                             onTrustHostKey: { _ in false }, livePaneIDs: AgentFoldersMockTransport.livePaneIDs)
        case .serverUpdate:
            TerminalHomeView(client: HerdrClient(transport: ServerUpdateMockTransport()), onDisconnect: {},
                             host: ServerUpdateMock.host, onTrustHostKey: { _ in false },
                             livePaneIDs: MockWireFixtures.demoLivePaneIDs)
        case .desktopReference:
            // Herdrup Desktop's reference screenshots (herdrup-desktop#16): no animation, so
            // every capture of a state is the same picture. See DesktopReferenceMock.
            let _ = DesktopReferenceMock.prepared
            TerminalHomeView(client: HerdrClient(transport: DesktopReferenceMockTransport()), onDisconnect: {},
                             host: DesktopReferenceMock.state == .settings ? "reference-hub" : "",
                             onTrustHostKey: { _ in false })
                .transaction { $0.disablesAnimations = true; $0.animation = nil }
                .overlay(alignment: .topLeading) { DesktopReferenceProbe().frame(width: 1, height: 1) }
        case .sessions:
            SessionsMockHome()
        case .liveEvents, .liveEventsLegacy:
            // The live status stream receipt: `liveevents` is an events_v2 daemon whose
            // rows change only through streamed events, `liveevents-legacy` an older
            // daemon that must keep the 5 s agent.list poll.
            LiveEventsHarness(driver: LiveEventsDriver.shared)
        case .rosterStress:
            // Many rows move between sections while the UI test continuously scrolls.
            // The short poll interval is DEBUG-only and turns several production poll
            // boundaries into a bounded simulator receipt.
            ZStack(alignment: .topTrailing) {
                TerminalHomeView(
                    client: HerdrClient(transport: MockTransport(rosterDriver: Self.rosterStressDriver)),
                    onDisconnect: {},
                    onTrustHostKey: { _ in false },
                    agentListPollIntervalNanoseconds: 50_000_000,
                    forceEagerAgentRosterStack: true,
                    onAgentListScrollPhaseChange: Self.rosterStressDriver.recordScrolling,
                    onEagerAgentRosterStackAppear: Self.rosterStressDriver.recordEagerStackVisible,
                    onAgentListDisplayedRosterChange: Self.rosterStressDriver.recordRosterPublication
                )
                // Let the UI test establish a real top-of-list precondition before
                // scroll-time refreshes begin. This DEBUG-only transparent control
                // avoids making corrective precondition gestures change the roster.
                RosterStressArmControl(driver: Self.rosterStressDriver)
                    // CLEAR OF THE CONTROL CENTER CORNER. Pinned top-trailing it sat at
                    // (380,84), inside the top-right region where a downward system swipe
                    // starts, and a synthesized tap whose touch-up arrived late was taken
                    // by the system gesture gate: CI 39116174699 logged `touch cancelled
                    // ... _UISystemGestureGateGestureRecognizer=ended` for it, the driver
                    // never armed, and the receipt failed later as "not promoted after
                    // returning to idle". Inset from both edges, and trailing of the
                    // rows' centre so it never covers a row's hit point.
                    .padding(.top, 160)
                    .padding(.trailing, 48)
            }
        case .pane:
            NavigationStack {
                TerminalPaneContent(client: mockClient, paneID: "w1:p1", title: "jarvis",
                                 agent: MockTransport.demoPaneAgent)
            }
        case .settings:
            SettingsView(client: mockClient, agents: [], host: "mac.tail-scale.ts.net")
        case .share:
            GuestShareMock.paneView()
        case .sharedAccess:
            GuestShareMock.settingsView()
        case .htmlPreview:
            HtmlPreviewHarness()
        case .widgets:
            WidgetGallery()
        case .scroll:
            // A REAL SwiftTerm pane (not a stub) fed 200 lines of scrollback, so the
            // HerdrUITests swipe exercises the actual library scroll path — the only
            // test that proves the SwiftTerm 1.15.0 scroll fix on device.
            NavigationStack {
                TerminalPaneContent(client: HerdrClient(transport: MockTransport(scrollback: true)),
                                 paneID: "w1:p1", title: "scrolltest",
                                 agent: MockTransport.demoPaneAgent)
            }
        case .ccscroll:
            // A REAL SwiftTerm pane in mouse-mode on the normal buffer (Claude Code's shape).
            // CCScrollDriver stands in for Claude Code: it redraws shifted
            // content when the app SENDS it an SGR wheel event, so the HerdrUITests
            // swipe proves the mouse-mode scroll path end to end.
            NavigationStack {
                TerminalPaneContent(client: HerdrClient(transport: MockTransport(ccDriver: CCScrollDriver.shared)),
                                 paneID: "w1:p1", title: "claude",
                                 agent: MockTransport.demoPaneAgent)
            }
        case .busyScroll:
            // A REAL SwiftTerm pane that keeps RECEIVING OUTPUT, so auto-follow writes
            // contentOffset continuously. The receipt is the INVERSE of the scroll-tap guard:
            // on a pane merely following output, a tap MUST still take focus. Review found
            // that recording every contentOffset write suppressed exactly this case — the
            // common one while an agent is working.
            NavigationStack {
                TerminalPaneContent(client: HerdrClient(transport: MockTransport(scrollback: true, busyOutput: true)),
                                 paneID: "w1:p1", title: "busytest",
                                 agent: MockTransport.demoPaneAgent)
            }
        case .backfill:
            // A REAL SwiftTerm pane whose LIVE stream carries only the short one-screen seed,
            // while agent.read (source=recent, ansi) returns ~1000 numbered lines of history —
            // so the scrollback a swipe-up reveals can ONLY have come from the connect-time
            // backfill (the scrollback receipt for open/refresh history).
            NavigationStack {
                TerminalPaneContent(client: HerdrClient(transport: MockTransport(backfill: true)),
                                 paneID: "w1:p1", title: "backfill",
                                 agent: MockTransport.demoPaneAgent)
            }
        case .keyframeHistory:
            // A REAL SwiftTerm pane whose stream drops once and reconnects in place. History
            // exists ONLY in the reconnect's keyframe — the reconnect-history receipt.
            NavigationStack {
                TerminalPaneContent(client: HerdrClient(transport: MockTransport(keyframeHistory: KeyframeHistoryDriver())),
                                 paneID: "w1:p1", title: "keyframehistory",
                                 agent: MockTransport.demoPaneAgent)
            }
        case .keyframeHistoryRead:
            // A REAL SwiftTerm pane on a current (herdr#301) server: every keyframe carries
            // history and the mount-time history read is held, so the probe shows whether the
            // app cancels that read once the first keyframe has made it redundant.
            NavigationStack {
                TerminalPaneContent(client: HerdrClient(transport: MockTransport(
                                        keyframeHistory: KeyframeHistoryDriver(historyFromFirstKeyframe: true))),
                                 paneID: "w1:p1", title: "keyframehistoryread",
                                 agent: MockTransport.demoPaneAgent)
            }
            .overlay(alignment: .topLeading) { KeyframeHistoryReadProbe() }
        case .historyPaging:
            // A REAL SwiftTerm pane on a `pane_history` server: scrolling near the top of the
            // keyframe's history pages older rows in; the probe logs each request's cursor.
            NavigationStack {
                TerminalPaneContent(client: HerdrClient(transport: MockTransport(historyPaging: HistoryPagingDriver())),
                                 paneID: "w1:p1", title: "historypaging",
                                 agent: MockTransport.demoPaneAgent)
            }
            .overlay(alignment: .topLeading) { HistoryPagingProbe() }
        case .paging:
            // Three distinctively-named agents in the real keep-mounted container. A swipe
            // fronts the neighbour and the header heading changes (ALFA→BRAVO→ALFA) — the
            // swipe-between-agents receipt. The pane ids are NOT in the mock agent.list, so
            // reresolveAgent leaves the seeded identity in place and the header stays stable.
            PagingTestHarness(client: mockClient)
        case .gram:
            // The Gram page over a mock that answers gram.list with a canned owner view. The
            // harness owns the Inbox/Saved binding (see GramScreenshotHarness); the messages +
            // claim states are the FYI.
            GramScreenshotHarness(client: mockClient)
        case .guestAccept:
            // Accept is injected: it returns the mock share without touching the network,
            // then lands on guest home exactly like a live accept.
            if let openGuest {
                mockGuestHome(openGuest)
            } else {
                GuestAcceptView(
                    invite: GuestMockTransport.invite,
                    fingerprint: try? GuestDevice.identity().fingerprint,
                    accept: { GuestMockTransport.access },
                    onAccepted: { access in
                        sharedMachines.add(access)
                        openGuest = access
                    },
                    onCancel: {})
            }
        case .guest:
            // After Leave the in-memory store is empty and the phone is back on onboarding.
            if let access = sharedMachines.machines.first {
                mockGuestHome(access)
            } else {
                ConnectView { _ in }
            }
        case .guestMachine:
            // Three shares on one machine; the store empties as the test removes them.
            if let access = sharedMachines.machines.first {
                SharedMachineHomeView(access: access, connect: GuestMockTransport.connection(for:),
                                      onBack: nil, onLeave: {})
            } else {
                ConnectView { _ in }
            }
        case .guestPane, .guestPaused, .guestBlocked, .guestOldHost:
            GuestPaneMockHost(
                scenario: mode == .guestPaused ? .paused : mode == .guestBlocked ? .blocked
                    : mode == .guestOldHost ? .oldHost : .running)
        case .chatView:
            ChatViewMockHome()
        case .guestChat:
            GuestPaneMockHost(scenario: .blocked)
        }
    }

    /// Guest home over the mock relay: the running scenario, whose agent.list also
    /// carries an agent that was not shared, which the home must not show.
    private func mockGuestHome(_ access: GuestAccess) -> some View {
        GuestHomeView(
            access: access,
            connect: { try GuestMockTransport.connection(for: access) },
            onBack: nil,
            onLeave: { openGuest = nil })
    }
    #endif

    /// The saved host's NICKNAME when there is one (falling back to the raw host/IP), so the
    /// lock screen and guest invites read "My Mac" rather than an address. Match the saved
    /// record the SAME way connect-from-saved does (HostEndpoint.parse): `saved.host` may be
    /// "host:port" while `creds.host`/`creds.port` are already parsed apart, so a raw string
    /// compare would miss any host saved with an explicit port.
    private static func hostLabel(for creds: SSHCredentials) -> String {
        let saved = SavedHostsStore.shared.hosts.first { saved in
            guard let ep = HostEndpoint.parse(saved.host) else { return false }
            return ep.host == creds.host && ep.port == creds.port && saved.username == creds.username
        }
        return saved?.label ?? creds.host
    }

    private func connect(_ picked: SSHCredentials) {
        // Reopen the herdr session last picked on this machine (#347). If it has stopped
        // since, the home view's session check switches back to the default one.
        var creds = picked
        if creds.session == nil { creds.session = SessionChoice.remembered(for: creds) }
        let newTransport = CitadelTransport(credentials: creds, hostKeyPolicy: pins)
        let newClient = HerdrClient(transport: newTransport)
        sessionCache = SessionSwitchCache()   // another machine's sessions must not seed this one
        credentials = creds
        transport = newTransport
        client = newClient
        // Bring up the session Live Activity (#90) in a "connecting" state; the home
        // view's onChange pushes real agent status the moment the first list arrives.
        LiveActivityController.shared.start(hostLabel: Self.hostLabel(for: creds), state: LiveActivityController.connecting)
        // Typing-latency diagnostics (Settings > Typing latency) label this machine by its
        // nickname, and join the transport's address-keyed route counts to that name.
        TypingLatencyContext.shared.connected(host: creds.host, label: Self.hostLabel(for: creds))
        // PRE-WARM: start the SSH handshake + first agent fetch the instant Connect
        // is tapped, so it overlaps the ConnectView→TerminalHomeView transition
        // instead of following it. The transport dedups concurrent connects, so this
        // and the home view's own load() coalesce into ONE session — no double
        // connect. Result is discarded; the view re-fetches (and reuses the warm
        // connection). Best-effort: a failure here surfaces normally in load().
        //
        // #377: the same fetch also decides WHEN the Agents screen appears. The machine list
        // stays up (its row reads "Connecting…") until this first list arrives or fails, or
        // 10 s pass, so the Agents screen slides in already filled. A failure still reveals
        // it: the error and host-key recovery live there.
        homeShown = false
        connectGeneration += 1
        let generation = connectGeneration
        // The fetch is an unstructured task that is only AWAITED, never cancelled: the home
        // view's own load() coalesces onto the same connection, so cancelling it when the cap
        // wins would tear down the attempt the Agents screen is about to use.
        //
        // Two independent triggers race to one guarded reveal. NOT a task group: a group
        // awaits every child before it returns, and `warm.value` ignores cancellation, so the
        // cap could never end the wait before the fetch did (#384).
        let warm = Task { _ = try? await newClient.agentList() }
        Task { @MainActor in
            await warm.value
            revealHome(generation: generation)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            revealHome(generation: generation)
        }
        registerPush(with: newClient, credentials: creds)   // re-send a cached token to the freshly-connected server
        registerActivityPush(with: newClient)   // and any existing Live Activity token (reclaimed activity)
        // Request the notification permission PROMPT here — push can now actually deliver: the build
        // carries the aps-environment entitlement AND the server runs the 2c APNs sender. This is the
        // call the 2b scaffolding deferred: 2b left it out on purpose (iOS grants alert authorization
        // exactly once per install, and prompting while the stack was dormant — no entitlement, no
        // server RPC — would have burned that one-shot grant on a capability that could not deliver, so
        // a "Don't Allow" tap would permanently opt the user out even after push went live). Now that
        // both exist it is safe: requestAuthorizationIfWanted only prompts when a notify.* category is
        // enabled and no screenshot/UITest mock is active, and a later call just returns the existing
        // status silently. On grant it registers for remote notifications; the token reaches the server
        // via AppDelegate.didRegisterForRemoteNotificationsWithDeviceToken → registerPush.
        AppDelegate.requestAuthorizationIfWanted()
    }

    /// Shows the Agents screen for connect attempt `generation` (#377): the first of "first
    /// list arrived or failed" and "10 s passed" wins; the later one, or one from a superseded
    /// attempt, does nothing.
    private func revealHome(generation: Int) {
        guard generation == connectGeneration, client != nil, !homeShown else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35)) {
            homeShown = true
        }
    }

    private func disconnect() {
        // Unregister the Live Activity token, THEN close the transport — in ONE task so the
        // unregister reaches the server over the still-open connection before close tears it down.
        // Independent tasks would race, and close winning would strand the registration
        // server-side. Capture token + client before we drop them below.
        let closing = transport
        let activityToken = liveActivity.pushToken
        let liveClient = client
        Task {
            if let token = activityToken, let liveClient {
                try? await liveClient.unregisterActivity(token: token)
            }
            await closing?.close()
        }
        client = nil
        transport = nil
        credentials = nil
        sessionCache = SessionSwitchCache()
        LiveActivityController.shared.end()   // tear down the #90 Live Activity with the session
        // Downloaded gram files are readable without a connection, so they must not
        // survive the session that fetched them.
        GramView.Downloads.invalidate()
        // And the downloads still running end with it (#574: they outlive the Gram page,
        // not the connection). After the epoch bump, so one landing now is refused.
        gramDownloads.cancelAll()
    }

    /// Drops and re-establishes the connection with the RETAINED credentials —
    /// the transport is rebuilt and `session` bumped so the home view re-loads.
    /// Distinct from disconnect(): the user stays connected, they do not fall back
    /// to re-entering host/key. No pin change, so the existing pin still guards.
    private func reconnect() {
        guard let creds = credentials else { return }
        let closing = transport
        Task { await closing?.close() }
        // The running Gram downloads ride the closed transport: end them, so the page
        // offers a fresh open on the new connection instead of a ring that only fails.
        gramDownloads.cancelAll()
        let newTransport = CitadelTransport(credentials: creds, hostKeyPolicy: pins)
        let newClient = HerdrClient(transport: newTransport)
        transport = newTransport
        client = newClient
        session += 1
        registerPush(with: newClient, credentials: creds)   // the reconnect built a fresh client actor — re-register the token with it
        registerActivityPush(with: newClient)   // re-register the Live Activity token with the fresh client too
    }

    /// Moves the app to another herdr session on the same machine (#347): each session is
    /// its own herdr server, so this is a reconnect with the new session, which rebuilds
    /// the client and remounts the home (agents, terminals, Gram) for that server.
    /// nil is the default session. Remembered per machine for the next connect.
    private func switchSession(to name: String?) {
        guard var creds = credentials, let current = transport else { return }
        let next = (name == "default") ? nil : name
        guard creds.session != next else { return }
        creds.session = next
        credentials = creds
        SessionChoice.remember(next, for: creds)
        // Same machine, same SSH connection (#386): only the herdr session changes, so
        // there is no handshake to pay. A NEW client on a transport scoped to the new
        // session, rather than retargeting the old one, so nothing the previous
        // session's screens still send can reach the same pane id in this one. The
        // old transport is not closed: it shares the connection.
        let scoped = current.forSession(next)
        let newClient = HerdrClient(transport: scoped)
        transport = scoped
        client = newClient
        session += 1
        // Another herdr server, whose message ids are not these: the downloads go too.
        gramDownloads.cancelAll()
        registerPush(with: newClient, credentials: creds)      // each session is its own herdr server
        registerActivityPush(with: newClient)
    }

    /// A verified key rotation: pin the EXACT fingerprint the user verified out
    /// of band (from the rejection), then reconnect. Because the pin is bound to
    /// that fingerprint before reconnecting, a substituted key during the
    /// reconnect is rejected — there is no re-TOFU window. Bumping `session`
    /// recreates the home view so its load re-runs.
    /// Returns false (without reconnecting) if the verified key could not be
    /// persisted — reconnecting then would reopen a first-contact TOFU window.
    private func trustAndReconnect(_ creds: SSHCredentials, fingerprint: String) -> Bool {
        guard pins.pin(host: creds.host, port: creds.port, fingerprint: fingerprint) else { return false }
        reconnect()   // pin bound above; the reconnect reuses `pins`, so the just-verified key is trusted
        return true
    }
}
