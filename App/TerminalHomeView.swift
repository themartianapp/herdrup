import SwiftUI
import Foundation
import UIKit    // UIPasteboard (Copy diagnostics)
import UniformTypeIdentifiers
import StoreKit // Product / tip jar (Settings' Support section)
import UserNotifications // notification authorization status (Settings notify section)
import HerdrKit

/// Non-observable storage for a roster fetched while the list is scrolling.
/// Mutating this reference deliberately does NOT invalidate SwiftUI. Only promoting
/// its value into `displayedRoster` when scrolling becomes idle redraws the list.
private final class AgentRosterPendingBuffer {
    var snapshot: AgentRosterSnapshot?
}

/// Non-observable generation storage for overlapping async roster loads. Advancing
/// this gate every poll must not itself invalidate the SwiftUI tree.
private final class AgentRosterLoadGateBuffer {
    private var gate = AgentRosterLoadGate()

    func begin() -> UInt64 { gate.begin() }
    func accepts(_ token: UInt64) -> Bool { gate.accepts(token) }
}

/// Non-observable gesture state. Scroll activity changes on the first frame of a
/// drag, so storing it in `@State` would rebuild every eager Mac row at exactly the
/// wrong time. The recovery task also lives here so arming it is render-free.
private final class AgentRosterScrollBuffer {
    var isScrolling = false
    var recoveryTask: Task<Void, Never>?

    deinit { recoveryTask?.cancel() }
}

/// Non-observable bookkeeping for the home list's live status stream. Events arrive
/// several times a second across a fleet; none of this may invalidate SwiftUI by
/// itself. Only a patched roster, published through `receiveRoster`, redraws.
private final class AgentRosterLiveEventsBuffer {
    /// Updates received while loads were in flight, replayed onto their snapshots.
    var ledger = AgentLiveUpdateLedger()
    /// An acknowledged stream is open; the 5 s poll relaxes to the backstop.
    var streaming = false
    /// The daemon refused the all-panes request despite advertising `events_v2`.
    /// Sticky for this connection so a later `agent.list` cannot re-enable it.
    var refused = false
    /// When the poll re-fetches while `streaming`: only loads that published count.
    var backstop = AgentListBackstop()
    /// Reloads asked for by events naming an agent pane the list does not show.
    var unlistedReloads = UnlistedPaneReloads()
    /// One coalesced event-driven reload at a time; `reloadAgain` queues exactly one more.
    var reloadTask: Task<Void, Never>?
    var reloadAgain = false

    deinit { reloadTask?.cancel() }
}

/// Cross-version scroll-phase observation. The probe sits inside the SwiftUI
/// ScrollView content, finds its UIKit ancestor, and samples UIKit's authoritative
/// tracking/deceleration flags on the display link. This is the same path on iOS 17,
/// iOS 18+, and macOS Designed-for-iPad, so the oldest supported runtime is not left
/// on an unprotected fallback path.
struct ScrollActivityObserver: UIViewRepresentable {
    let isEnabled: Bool
    let onChange: (Bool) -> Void
    var onSample: ((UIScrollView) -> Void)? = nil
    /// Called when a wheel or trackpad scrolls the scroll view, which sets none of the
    /// tracking/dragging/deceleration flags `onSample` sees (see `Coordinator.scrollInput`).
    var onScrollInput: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, onChange: onChange)
    }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.onSample = onSample
        context.coordinator.onScrollInput = onScrollInput
        context.coordinator.setEnabled(isEnabled)
        context.coordinator.attach(from: uiView)
    }

    static func dismantleUIView(_ uiView: ProbeView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChange: (Bool) -> Void
        var onSample: ((UIScrollView) -> Void)?
        var onScrollInput: (() -> Void)? {
            didSet { scrollInput?.isEnabled = onScrollInput != nil }
        }
        /// Sees wheel and trackpad scrolling, and nothing else. A Mac wheel or trackpad moves the
        /// offset without `isTracking`/`isDragging`/`isDecelerating` (LiveTerminalView's history
        /// paging found the same), so no flag sampled on the display link tells the reader is
        /// scrolling. A pan recognizer receives those scroll events only when it opts in
        /// (`allowedScrollTypesMask`, as LiveTerminalView's agent-scroll pan does on the Mac),
        /// and with `maximumNumberOfTouches` 0 it takes no touch at all, so a finger stays the
        /// scroll view's alone. It recognizes alongside every other recognizer and cancels
        /// nothing, so the scroll view scrolls exactly as before.
        private(set) var scrollInput: UIPanGestureRecognizer?
        private weak var scrollView: UIScrollView?
        private var displayLink: CADisplayLink?
        private var isEnabled: Bool
        private var isActive = false
        private var lastHeartbeatTimestamp: CFTimeInterval = 0
        private var attachmentAttempts = 0

        init(isEnabled: Bool, onChange: @escaping (Bool) -> Void) {
            self.isEnabled = isEnabled
            self.onChange = onChange
        }

        func setEnabled(_ enabled: Bool) {
            guard enabled != isEnabled else { return }
            isEnabled = enabled
            displayLink?.isPaused = !enabled
            if !enabled, isActive {
                isActive = false
                onChange(false)
            }
        }

        func attach(from probe: UIView) {
            guard scrollView == nil else { return }
            var ancestor = probe.superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView {
                    self.scrollView = scrollView
                    let pan = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
                    pan.allowedScrollTypesMask = .all
                    pan.maximumNumberOfTouches = 0
                    pan.cancelsTouchesInView = false
                    pan.delaysTouchesBegan = false
                    pan.delaysTouchesEnded = false
                    pan.delegate = self
                    pan.isEnabled = onScrollInput != nil
                    scrollView.addGestureRecognizer(pan)
                    scrollInput = pan
                    let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
                    link.isPaused = !isEnabled
                    link.add(to: .main, forMode: .common)
                    displayLink = link
                    return
                }
                ancestor = view.superview
            }
            guard probe.window != nil, attachmentAttempts < 4 else { return }
            attachmentAttempts += 1
            DispatchQueue.main.async { [weak self, weak probe] in
                guard let self, let probe else { return }
                self.attach(from: probe)
            }
        }

        @objc func scrolled(_ pan: UIPanGestureRecognizer) {
            guard pan.state == .began || pan.state == .changed else { return }
            onScrollInput?()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        @objc private func tick(_ link: CADisplayLink) {
            guard isEnabled, let scrollView else { return }
            onSample?(scrollView)
            let active = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
            if active {
                if !isActive {
                    isActive = true
                    lastHeartbeatTimestamp = link.timestamp
                    onChange(true)
                } else if link.timestamp - lastHeartbeatTimestamp >= 1 {
                    // Rearm the fail-safe without touching SwiftUI state. This also
                    // lets a deliberate long drag exceed the watchdog duration.
                    lastHeartbeatTimestamp = link.timestamp
                    onChange(true)
                }
            } else if isActive {
                isActive = false
                onChange(false)
            }
        }

        /// Called from `dismantleUIView`, i.e. while SwiftUI is tearing the view graph down.
        /// Writing SwiftUI state there is an exclusivity violation that aborts the app
        /// (`swift_beginAccess` fatal in `GraphHost.isUpdating`, TestFlight crash on 1.2.1
        /// (238): leaving Chat while it was still decelerating). So the final "scrolling
        /// ended" is delivered on the next main-queue turn, after the teardown finished.
        func stop() {
            displayLink?.invalidate()
            displayLink = nil
            if let scrollInput {
                scrollInput.view?.removeGestureRecognizer(scrollInput)
                self.scrollInput = nil
            }
            scrollView = nil
            if isActive {
                isActive = false
                let onChange = onChange
                DispatchQueue.main.async { onChange(false) }
            }
        }
    }

    @MainActor
    final class ProbeView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(from: self)
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            coordinator?.attach(from: self)
        }
    }
}

/// Lists the agents on the host; tapping one opens its pane. A failed load is
/// recoverable (retry, or disconnect back to the connect form).
/// The sidebar section bar's material: Apple's Liquid Glass where the system has it (iPadOS 26,
/// and macOS 26 for the iPad app on Mac), the frosted bar of #369 before that.
private struct SidebarTabBarMaterial: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .background(Palette.surfaceRaised.opacity(0.72), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.45), radius: 15, y: 6)
        }
    }
}

struct TerminalHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    let client: HerdrClient
    var onDisconnect: () -> Void
    var host: String = ""   // shown in the Settings sheet's connection row
    /// Canonical `host:port` key that scopes saved terminals to THIS connection (a terminal is a pane
    /// on one daemon). Empty only in the DEBUG mock, which has no real terminals.
    var hostKey: String = ""
    /// The herdr session this home shows (#347); nil is the default session.
    var session: String? = nil
    /// Switch the app to another herdr session on this machine (nil = default).
    var onSwitchSession: (String?) -> Void = { _ in }
    /// What the app last saw of each session on this machine (#386): this screen starts
    /// from it after a session switch, and keeps it current.
    var sessionCache: SessionSwitchCache? = nil
    var onReconnect: () -> Void = {}
    var onTrustHostKey: (String) -> Bool
    /// The set of panes herdr still lists; anything absent is `stopped`. `nil`
    /// means no census is available yet (the live default) — every agent is
    /// treated as live, the only safe reading. The DEBUG mock passes one so the
    /// stopped section has something to show.
    var livePaneIDs: Set<String>? = nil

    /// How often the connected agent list is re-fetched to stay live. Five seconds is
    /// the production default, and the cadence whenever no live status stream is open
    /// (an older daemon, or between reconnects). The DEBUG scroll-stress harness
    /// injects a shorter value so one UI test crosses many refresh boundaries without
    /// becoming a minute-long wall-clock test.
    var agentListPollIntervalNanoseconds: UInt64 = 5_000_000_000
    /// While an acknowledged `events_v2` status stream is open, rows update from its
    /// events and the list is re-fetched only this often, as a backstop for anything
    /// the stream cannot express.
    var agentListBackstopIntervalNanoseconds: UInt64 = 30_000_000_000
    /// DEBUG stress receipt: exercise the eager Mac stack on the iOS simulator.
    var forceEagerAgentRosterStack = false
    /// DEBUG stress-receipt hook. Normal callers leave it nil.
    var onAgentListScrollPhaseChange: ((Bool) -> Void)? = nil
    /// DEBUG branch receipt. Normal callers leave it nil.
    var onEagerAgentRosterStackAppear: (() -> Void)? = nil
    /// DEBUG invariant hook. This observes the published `@State` value independently
    /// of the state-machine decision that produced it, so an assignment bypass cannot
    /// make the receipt agree with the code under test.
    var onAgentListDisplayedRosterChange: ((Bool) -> Void)? = nil
    /// Agents, account labels, and the already-sorted list are published as one value.
    /// An unchanged fetch leaves this `@State` untouched. Scroll-time fetches go into
    /// the non-observable buffer above, so even recording a pending result cannot ask
    /// SwiftUI to lay the moving list out again.
    @State private var displayedRoster = AgentRosterSnapshot()
    @State private var pendingRoster = AgentRosterPendingBuffer()
    @State private var rosterLoadGate = AgentRosterLoadGateBuffer()
    @State private var rosterScroll = AgentRosterScrollBuffer()
    /// Whether the waiting rows are scrolled out of sight. Held, not observed: only the
    /// needs-you pill redraws when it flips (#551).
    @State private var needsYouSight = NeedsYouSight()
    /// The agent rows' swipe-right actions (#552): one pan on the list's scroll view. Held,
    /// never observed; each row observes only its own swipe.
    @State private var rowSwipes = RowSwipeController()
    @State private var liveEvents = AgentRosterLiveEventsBuffer()
    /// The daemon advertises `events_v2` (from `agent.list` `origin_capabilities`, or
    /// `ping` on a daemon without that field). Observable because it keys the stream
    /// task; it changes at most once or twice per connection.
    @State private var liveEventsSupported = false
    /// One shared time source for every status-age badge. It updates at most once
    /// per production poll interval, never once per row. `rosterClockNow` is its clock.
    @State private var rosterNow = TerminalHomeView.rosterClockNow()
    private var agents: [AgentInfo] { displayedRoster.agents }
    private var accounts: [CredentialAccount] { displayedRoster.accounts }
    @State private var error: String?
    @State private var loading = true
    @State private var rejectedFingerprint: String?
    @State private var trustFailed = false
    /// Set when the connect failed because herdr is not installed on the host
    /// (`TransportError.herdrNotInstalled`). Drives the install-guidance branch in
    /// `errorView` instead of surfacing the raw stderr. Reset at the start of each load.
    @State private var herdrMissing = false
    /// When `herdrMissing` was triggered because the host's herdr is present but too
    /// old / not the fork (`TransportError.herdrIncompatible`) rather than absent.
    /// Only swaps the guidance heading/subtitle; the fix (install/update the fork) is
    /// the same, so it reuses the same recovery screen.
    @State private var herdrIncompatibleBuild = false
    /// An installed, compatible binary whose API daemon/socket is not responding
    /// needs start/check guidance, not another install.
    @State private var unavailableDaemonHost: String?
    /// Latches the "Copied ✓" state on the install-command copy button.
    @State private var installCmdCopied = false
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    /// The agent a pending "Restart agent" confirmation is about (nil = no
    /// dialog). Set from the agent card's context menu; a restart interrupts a
    /// busy agent's turn, so it is confirmed before firing.
    @State private var restartCandidate: AgentRow?
    /// A pending "Swap subscription" confirmation: which agent, and the target
    /// account. A swap IS a full restart (kills + --resume) onto a different
    /// credential account, so it interrupts a busy turn exactly like the plain
    /// restart above — and is confirmed before firing for the same reason.
    private struct PendingSwap {
        let row: AgentRow
        let account: CredentialAccount
    }
    @State private var swapCandidate: PendingSwap?
    /// Capability-gated native harness transfer. Unlike a subscription
    /// swap, this stages a translated native session and requires review before
    /// the source runtime is interrupted.
    private struct PendingHarnessTransfer: Identifiable {
        let row: AgentRow
        let source: AgentSessionTransferHarness
        let target: AgentSessionTransferHarness
        var id: String {
            "\(row.info.paneID):\(source.rawValue):\(target.rawValue)"
        }
    }
    @State private var transferCandidate: PendingHarnessTransfer?
    @State private var sessionTransferSupported = false
    /// The daemon supports `agent.forget` (ping `agent_forget`), so archived rows offer Close (#380).
    @State private var forgetSupported = false
    /// The archived row awaiting Close confirmation.
    @State private var forgetCandidate: AgentRow?
    /// A long-press menu action that talks to the daemon, run by `.onChange(of: menuAction)`
    /// on the current client. The menus only set it.
    @State private var menuAction: RosterMenuAction?
    enum RosterMenuAction: Equatable {
        case stop(AgentRow), archive(AgentRow), unarchive(AgentRow), closeTerminal(SavedTerminal)
    }
    @State private var sessionTransferHarnesses: Set<AgentSessionTransferHarness> = []
    @State private var checkedSessionTransferCapability = false
    /// A pending rename (nil = no sheet). An agent sets its daemon `name` (a resolvable mention
    /// target — `herdr agent read <name>`); a terminal sets its pane `label` (shown in
    /// `herdr pane list`) plus the app-local row label. Identifiable so it drives a `.sheet(item:)`.
    private enum RenameTarget: Identifiable {
        case agent(AgentRow)
        case terminal(SavedTerminal)
        var id: String {
            switch self {
            case .agent(let row): return "agent:\(row.info.paneID)"
            case .terminal(let terminal): return "terminal:\(terminal.id.uuidString)"
            }
        }
    }
    @State private var renameTarget: RenameTarget?
    /// The roster's pictures for every avatar under this home, and the agent whose picture
    /// the Avatar… sheet is editing (herdrup#538).
    @State private var avatars = AgentAvatarDirectory()
    @State private var avatarRow: AgentRow?
    /// Agent folders and stars (herdrup#552). Empty on a server without `agent_groups`, and
    /// then the list shows no folder rows, no stars and no folder actions.
    @State private var groups = AgentGroupsStore()
    /// The folder a tap is opening right now, whose rows reveal one after another
    /// (`AgentFolderMotion`); cleared once that animation is done.
    @State private var folderReveal: String?
    /// The herdr update for this machine (herdrup#565); see `attachServerUpdate`.
    @State private var serverUpdate: ServerUpdateModel?
    /// The folder-name prompt (a new folder, or a rename) and its text.
    @State private var folderNaming: FolderNaming?
    @State private var folderNameText = ""
    /// The agent whose "Move to folder" choices are showing, from its swipe action.
    @State private var moveCandidate: AgentRow?
    private enum FolderNaming: Equatable {
        /// A new folder, holding `member` (an agent name) when it was made from an agent row.
        case new(member: String?)
        case rename(AgentFolder)
    }
    @State private var activeCover: ActiveCover?
    /// The terminal belongs to the persistent Agents tab; Gram and Settings own their
    /// native pages, so a covered terminal cannot receive their touches.
    @State private var selectedTab: HomeTab = .agents
    /// Both size classes share the split/detail tree; only navigation chrome adapts.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    /// Row separators are one device pixel, like the system's and Messages'.
    @Environment(\.displayScale) private var displayScale
    /// Internal only so the DEBUG desktop reference can start expanded.
    static let sidebarMinimizedKey = "ui.sidebarMinimized"
    /// The user owns regular-width visibility. Compact adaptation is a derived
    /// request, not another writer that can leave the sidebar collapsed on expansion.
    private var columnVisibility: NavigationSplitViewVisibility {
        hSizeClass == .compact || sidebarMinimized ? .detailOnly : .all
    }
    /// Whether the sidebar is MINIMISED to the icon rail, remembered across launches.
    ///
    /// There is deliberately no fully-hidden state. Hiding the column outright loses
    /// the section badges and the activity counts and leaves nothing to click, so the
    /// only way back was ⌘K on a hardware keyboard; the rail keeps a compact signal
    /// and a one-click way back, which makes a third state pure surface area.
    ///
    /// Remember deliberate changes across launches, never system adaptation.
    @AppStorage(Self.sidebarMinimizedKey) private var sidebarMinimized = false
    /// The sidebar's width, remembered across launches.
    ///
    /// `navigationSplitViewColumnWidth` takes an `ideal` but reports nothing back, and
    /// there is no SwiftUI hook for "the user dragged the divider" — so the column
    /// measures itself (see `iPadLayout`) and the settled value is stored here.
    @AppStorage("ui.sidebarWidth") private var sidebarWidth = Double(DesignTokens.Size.sidebarMin)
    /// The column's last MEASURED width, pre-persistence. Debounced into `sidebarWidth`
    /// so a transient layout value cannot become the stored preference (it would also
    /// become the new `ideal`, which is what makes a bad sample stick).
    @State private var measuredSidebarWidth: CGFloat = 0
    /// When `measuredSidebarWidth` last changed. The pre-collapse commit in
    /// `toggleSidebar` bypasses the debounce, so it needs its own way to tell a width
    /// the owner settled on from one the split view is sweeping through.
    @State private var measuredSidebarWidthAt = Date.distantPast
    /// How still a measurement must be for the PRE-COLLAPSE commit to trust it.
    ///
    /// During the split view's own column animation a new sample arrives roughly every
    /// frame (~16ms); after a divider drag the owner still has to reach the toggle,
    /// which takes far longer. 50ms separates those two cases cleanly, and unlike
    /// `sidebarWidthSettle` this is not a wait — it is a freshness test on a value
    /// that already exists.
    private static let sidebarWidthStillFor: TimeInterval = 0.05
    /// How long a measured width must hold still before it is persisted. Comfortably
    /// longer than the split view's own column animation, so a minimise/expand sweep
    /// commits once, at the width it ended on.
    private static let sidebarWidthSettle: UInt64 = 500_000_000
    /// Four 40 pt actions, the title and the system window corner must fit together.
    /// Keep the stored width, clamp and split-view modifier on the same bounds.
    private static let sidebarWidthRange: ClosedRange<CGFloat> =
        DesignTokens.Size.sidebarMin...DesignTokens.Size.sidebarMax
    /// iPad: which grouped detail the sidebar index has selected (rendered in the split's
    /// detail column). Defaults to Machines so the split opens on a section, not blank.
    @State private var settingsAnchor: SettingsSection? = .machines
    /// iPad: the ⌘/ keyboard-shortcut reference sheet.
    @State private var showShortcuts = false
    /// Terminal font size preference (points), shared app-wide via UserDefaults with the
    /// per-pane ⋯ control; driven here by ⌘+ / ⌘- / ⌘0 (Mac + hardware keyboard).
    @AppStorage("terminal.fontSize") private var terminalFontSize: Double = 12.5
    /// The UI text-size setting. Read in `body` purely to observe it, so the home
    /// re-renders at the new `Typography.scale` when it changes — WITHOUT the
    /// identity churn `.id()` would cause (which reset the tab / terminal panes).
    @AppStorage("ui.fontScale") private var uiFontScale: Double = 1.0
    /// The one-time GitHub star bar (`GitHubStarPrompt`): owner prompts sent so far (counted
    /// by the pane's `submitPrompt`) and whether the bar was answered. See `showStarPrompt`.
    @AppStorage(GitHubStarPrompt.sentPromptsKey) private var starPromptSends = 0
    @AppStorage(GitHubStarPrompt.answeredKey) private var starPromptAnswered = false
    /// The bar's measured height (it grows with the text size), for the roster's bottom margin.
    @State private var starPromptHeight: CGFloat = 56
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Unread agent→owner grams, badged on the Gram tab. Session-scoped; written
    /// by GramView while visible and by an ambient poll (below) while it isn't.
    /// Only the badge/sidebar readers observe this object: publishing a count must not
    /// rebuild the tab host while a message's context menu is handling a touch.
    @State private var gramUnread = GramUnreadTracker()
    /// Gram's Inbox/Saved selection, owned HERE rather than inside `GramView` because on regular
    /// width the selector is rendered in the split view's sidebar — a sibling column of the page
    /// it drives. Shared by both layouts, so the phone's header toggle and the sidebar rows read
    /// and write the same value.
    @State private var gramShowingSaved = false
    /// One-shot signal for the sidebar's refresh button. A sidebar button cannot call `GramView`'s
    /// async `load`, so it bumps this and the page's `onChange` performs the reload.
    @State private var gramRefreshToken = 0
    /// One-shot signal for the sidebar's Read-all button, same reason as `gramRefreshToken`:
    /// a sidebar button cannot call `GramView`'s async mark-read pass directly.
    @State private var gramReadAllToken = 0
    /// One-shot signal for a tap on Gram while it is already selected (the phone's tab bar, the
    /// iPad's section bar and rail): the feed goes to its newest message (`GramView.newestToken`).
    @State private var gramNewestToken = 0
    /// The Gram search on regular width. The field sits at the top of the sidebar (a sibling
    /// column of the page it filters), so the text lives here and reaches `GramView` as a
    /// binding; the phone keeps the page's own search toggle instead.
    @State private var gramSearch = ""
    /// Focus of the sidebar's Gram search, so ⌘F can put the cursor in it.
    @FocusState private var gramSearchFocused: Bool
    /// First launch shows the gestures tutorial once; the "Gestures" tab reopens it.
    @AppStorage("hasSeenGesturesHelp") private var hasSeenGesturesHelp = false

    /// DEBUG screenshot/UI-test modes are deterministic fixtures, not first-run
    /// product sessions. Suppress the one-time tutorial for every current and future
    /// mock mode so a clean simulator cannot cover the surface a test is measuring.
    private var shouldShowFirstRunGesturesHelp: Bool {
        #if DEBUG
        ScreenshotMock.mode == nil
        #else
        true
        #endif
    }
    /// Shown once per connect when the daemon lacks the fork features (probe ==
    /// .notFork). Advisory, dismissable — the base daemon still lists/controls agents.
    @State private var showForkNotice = false
    /// Set when the probe returns .notFork WHILE a cover (e.g. the first-run gestures
    /// sheet) is up — draining it from the sheet's onDismiss serializes the notice
    /// with `activeCover`, so the two presentations are never armed at once.
    @State private var pendingForkNotice = false

    /// The bottom tabs. Terminal is deliberately absent — a terminal fronts a
    /// keep-mounted pane over the tabs rather than being one.
    ///
    /// ONE definition of the sections (#360): the iPhone `TabView`, the iPad/Mac sidebar
    /// bar and the minimised rail all read label and icon from here, so they cannot drift.
    private enum HomeTab: Hashable, CaseIterable {
        case agents, gram, settings

        var label: String {
            switch self {
            case .agents: return "Agents"
            case .gram: return "Gram"
            case .settings: return "Settings"
            }
        }

        /// The SF Symbol. A system tab bar draws the `.fill` variant; the sidebar bar does
        /// the same explicitly with `.environment(\.symbolVariants, .fill)`.
        var icon: String {
            switch self {
            case .agents: return "square.grid.2x2"
            case .gram: return "bubble.left.and.bubble.right"
            case .settings: return "gearshape"
            }
        }
    }

    /// The only remaining MODAL covers: the new-agent form and the first-run gestures
    /// tutorial. Gram and Settings became persistent tabs (#88).
    private enum ActiveCover: Int, Identifiable {
        case newAgent, gestures
        var id: Int { rawValue }
    }

    /// Recently-opened terminals, kept MOUNTED (in `PaneKeepAliveContainer`) so reopening is
    /// instant. Most-recently-used LAST; the pane whose id == `frontID` is the one on screen,
    /// `nil` means the agents list is showing. Bounded to `maxLivePanes` (LRU eviction ⇒ that
    /// slot's view unmounts ⇒ its stream/SSH connection closes). See `open(_:)`.
    @State private var slots: [PaneSlot] = []
    @State private var frontID: String?
    /// Pane ids ever OBSERVED live in `agent.list`. A slot is pruned only once it has been seen
    /// live and then vanishes — so a still-BOOTING spawn pane (absent from agent.list by design
    /// while its composer comes up) is never reaped mid-delivery.
    @State private var everLive: Set<String> = []
    /// A tapped push deep-links to its agent (see PushCenter). Observed here (a singleton, so it
    /// survives this view's `.id(session)` remount); consumed once the list has loaded.
    @ObservedObject private var push = PushCenter.shared
    /// A freshly-spawned pane held while the New-agent cover animates away, then opened in the
    /// cover's onDismiss (fronting a keep-mounted pane, not a nav push, so the historically
    /// fragile "push while dismissing a cover" no longer applies — but the deferral is kept as
    /// cheap safety).
    @State private var pendingOpenSlot: PaneSlot?
    /// The user's opened plain-shell terminals (a singleton, so it survives this view's
    /// `.id(session)` remount). Shell panes never appear in `agent.list`, so the app tracks
    /// them here to relist and reopen. See `SavedTerminalsStore`.
    @ObservedObject private var terminalsStore = SavedTerminalsStore.shared
    /// Re-entry guard while a `New Terminal` split is in flight (also dims the row).
    @State private var creatingTerminal = false
    private static let maxLivePanes = 3
    // Only the quiet tail (idle) starts collapsed — the model forbids a
    // collapsed group from ever hiding something that wants attention.
    @State private var collapsed: Set<AgentGroup> = Set(AgentGroup.allCases.filter { $0.startsCollapsed })
    /// The Terminals section starts collapsed like the idle agents — a compact header row
    /// (TERMINALS · N) the reader expands on demand, so it never competes with the herd.
    @State private var terminalsCollapsed = true
    /// The Archived section (issue #173) starts collapsed too — archived agents are
    /// the least-active thing on screen, so they stay tucked behind an ARCHIVED · N row.
    @State private var archivedCollapsed = true
    /// The sidebar section bar's selected pill, shared so it slides between tabs.
    @Namespace private var sidebarTabSelection
    /// Sidebar-row hover → the empty detail column's glyph field. A reference, never
    /// reassigned, so hovering the roster does not invalidate this view.
    @State private var glyphFieldSpotlight = TerminalGlyphFieldView.Spotlight()
    /// The machine's running herdr sessions (#347); the pills show with two or more.
    @State private var runningSessions: [HerdrSession] = []
    /// Needs-you counts in the sessions this home is NOT on, by session name.
    @State private var otherSessionsNeedYou: [String: Int] = [:]

    /// The whole list derived once when the displayed roster changes. The grouping,
    /// fail-closed placement, stable order, count and quiet flag all live in
    /// HerdrKit's tested `AgentList`, not in SwiftUI's render path.
    private var fullList: AgentList { displayedRoster.agentList }

    /// What each agent types into the empty detail column's glyph field.
    private var glyphFieldLines: [TerminalGlyphFieldView.Line] {
        fullList.sections.flatMap { $0.rows }.map(glyphFieldLine)
    }

    private func glyphFieldLine(_ row: AgentRow) -> TerminalGlyphFieldView.Line {
        let tone: TerminalGlyphFieldView.Tone
        switch row.group {
        case .needsYou, .unrecognised: tone = .waiting
        case .stopped: tone = .died
        case .working: tone = .working
        case .idle: tone = row.status == .done ? .done : .dim
        }
        return .init(id: row.id, text: "\(row.title) › \(subtitle(row.info))", tone: tone)
    }

    /// The ordered LIVE agents a pushed pane can page through with a horizontal swipe.
    /// DELIBERATELY the full sorted live list (`AgentList.rows`, needs-you first), NOT the
    /// search-filtered/collapsed `visibleSections` — paging navigates the whole herd, not
    /// the current search view; a stopped pane is excluded since it has no stream to open.
    /// Snapshotted into the pushed pane at open time.
    private var orderedSiblings: [AgentInfo] { fullList.rows.filter(\.isLive).map(\.info) }

    /// Front a terminal, keeping it (and up to `maxLivePanes-1` others) MOUNTED. Re-opening a
    /// still-mounted pane just LRU-bumps it — instant, its stream never closed. A new pane is
    /// appended (MRU) and the least-recently-used non-front slot is evicted past the cap
    /// (removal unmounts it → `Coordinator.stop()` closes its stream + SSH connection).
    private func open(_ slot: PaneSlot) {
        if let i = slots.firstIndex(where: { $0.paneID == slot.paneID }) {
            // Already mounted → keep it warm (instant), but REFRESH its metadata: a re-open from
            // the list carries a fresh title/agent/roster. Identity is the pane id (`.id`), so
            // replacing the struct does NOT remount the pane or reset its @State. Guard so a spawn
            // re-open (`siblings:[]`, which must not page mid-delivery) can't clobber a good
            // roster, and keep the ORIGINAL one-shot prefill.
            let existing = slots.remove(at: i)
            slots.append(PaneSlot(paneID: existing.paneID, title: slot.title,
                                  agent: slot.agent ?? existing.agent,
                                  initialReply: existing.initialReply,
                                  siblings: slot.siblings.isEmpty ? existing.siblings : slot.siblings))
        } else {
            slots.append(slot)
            while slots.count > Self.maxLivePanes {
                slots.removeFirst()         // LRU is index 0 and never the just-appended new front
            }
        }
        // A fronted pane must overlay the AGENTS tab: that is where the tab-bar hide is
        // declared, so a pane opened from a push deep-link while Gram/Settings is showing
        // would otherwise leave the tab bar drawing over it. Selecting Agents keeps every
        // open path (row tap, deep-link, spawn, swipe-paging) consistent.
        selectedTab = .agents
        frontID = slot.paneID
    }

    /// Open a fresh plain-shell terminal: `pane.split` with NO `agent.start` yields a booting
    /// shell PTY (the same split the new-agent flow does, minus turning it into an agent).
    /// Remember it (so it relists — a shell pane is absent from `agent.list` by construction)
    /// and front it. The terminal drives the shell through the SAME pane-id path as any agent
    /// pane: raw keystrokes + the control bar (see `TerminalPaneContent`, `InputRouter`).
    private func createTerminal() async {
        guard !creatingTerminal else { return }   // re-entry invariant, not just .disabled
        creatingTerminal = true
        defer { creatingTerminal = false }
        do {
            let paneID = try await client.splitPane(cwd: nil)
            let terminal = terminalsStore.add(paneID: paneID, host: hostKey)
            open(PaneSlot(paneID: paneID, title: terminal.label, agent: nil,
                          initialReply: "", siblings: []))
        } catch let e {
            // `\(e)` surfaces the APIError's "code: message" (CustomStringConvertible);
            // `.localizedDescription` bridges to a useless generic NSError string.
            error = "couldn't open a terminal: \(e)"
        }
    }

    /// A roster menu's daemon action. A failure is disclosed, not swallowed; `\(e)` surfaces
    /// the APIError's "code: message" (`.localizedDescription` bridges to a generic string).
    private func run(_ action: RosterMenuAction) async {
        switch action {
        case .closeTerminal(let terminal):
            await deleteTerminal(terminal)
            return
        case .stop(let row):
            await perform(verb: "stop", title: row.title) {
                try await client.closePane(paneID: row.info.paneID)
            }
        case .archive(let row):
            await perform(verb: "archive", title: row.title) {
                // Attributed on purpose. Without `by`/`reason` the daemon records
                // `by: "api"` and no reason — the same shape it writes for a pane that
                // merely died, so a deliberate archive would be indistinguishable from
                // bookkeeping to anything reading the record later.
                try await client.archiveAgent(target: row.info.paneID,
                                              reason: HerdrKit.appArchiveReason,
                                              by: HerdrKit.appArchiveActor)
            }
        case .unarchive(let row):
            // Resume the preserved session into a fresh pane, restoring the agent's
            // identity. Target by name (or terminal id): the pane id no longer resolves.
            let target = unarchiveTarget(row.info)
            await perform(verb: "unarchive", title: row.title) {
                try await client.unarchiveAgent(target: target)
            }
        }
    }

    /// One daemon action on a roster row: run `op`, then reload the roster. A failure is
    /// disclosed as "couldn't <verb> <title>: <error>" and skips the reload.
    private func perform(verb: String, title: String, _ op: () async throws -> Void) async {
        do {
            try await op()
        } catch let e {
            error = "couldn't \(verb) \(title): \(e)"
            return
        }
        await load()
    }

    /// Close a terminal: end its shell pane server-side (best-effort — it may already have
    /// exited), unmount any live slot, and forget it. Deleting is the user's intent, so a
    /// close that fails (a gone pane) still forgets it rather than stranding a dead row.
    private func deleteTerminal(_ terminal: SavedTerminal) async {
        try? await client.closePane(paneID: terminal.paneID)
        if frontID == terminal.paneID { frontID = nil }
        slots.removeAll { $0.paneID == terminal.paneID }
        terminalsStore.delete(terminal.id, host: hostKey)
    }

    /// Front the pane a tapped push targeted (PushCenter.pendingPaneID), once the agent list has
    /// loaded so the swipe roster + identity resolve. Opens best-effort even if the agent has since
    /// gone (the pane then shows its exited state). Consumes the target so it fires once.
    private func applyDeepLink(afterLoad: Bool = false) {
        guard let paneID = push.pendingPaneID else { return }
        // A refresh completed during momentum scrolling may be buffered rather than
        // displayed. An explicit push should still resolve against that newest data;
        // reading it here does not publish or relayout the roster under the gesture.
        let sourceRoster = afterLoad ? (pendingRoster.snapshot ?? displayedRoster) : displayedRoster
        let info = sourceRoster.agents.first { $0.paneID == paneID }
        // On the onChange path (not post-load), only open once the target RESOLVES against the roster.
        // If it doesn't — an empty roster (first load) OR a stale one (agent spawned from the desktop
        // since the last refresh) — opening now would give a bare paneID title AND a sibling list that
        // doesn't contain it, so swipe-paging would be dead for that slot's whole life. Instead kick a
        // refresh (if one isn't already running) and let the post-load `afterLoad: true` call open it
        // with the fresh identity + roster. The afterLoad call always proceeds — even an unresolved
        // target opens best-effort then (the agent is genuinely gone → its pane shows the exited state).
        if !afterLoad, info == nil {
            if !loading { Task { await load() } }
            return
        }
        push.pendingPaneID = nil
        let siblings = sourceRoster.agentList.rows.filter(\.isLive).map(\.info)
        open(PaneSlot(paneID: paneID, title: info?.displayName ?? paneID, agent: info,
                      initialReply: "", siblings: siblings))
    }

    /// A tapped gram push selects the Gram tab. Like `applyDeepLink`, it is consumed on
    /// the onChange path (app already up) AND post-load (a cold-launch tap set the flag
    /// before this view existed). Leaving it armed lets a later trigger re-invoke it.
    private func openGramIfPending() {
        guard push.pendingGram else { return }
        // The fork notice (a fullScreenCover) is up: don't switch under it; its
        // onDismiss re-invokes this once it's gone.
        if showForkNotice { return }
        // A modal sheet is up, OR a spawned pane is queued to open: DEFER, do not
        // consume. Consuming here would dismiss the sheet out from under the user (e.g.
        // mid new-agent entry) and swallow the tap. Leave the push armed; the sheet's
        // onDismiss re-invokes this once it's gone (and a queued spawn wins there,
        // deliberately leaving the push pending rather than yanking the new terminal).
        if activeCover != nil || pendingOpenSlot != nil { return }
        push.pendingGram = false
        // Drop any fronted terminal so the Gram tab is visible (the pane stays MOUNTED,
        // so reopening it later is instant).
        frontID = nil
        selectedTab = .gram
    }

    /// Swipe-page from the fronted pane to its prev/next sibling (clamped). `open()`s the
    /// neighbour — instant if it is already mounted.
    private func navigate(from slot: PaneSlot, delta: Int) {
        guard let i = slot.siblings.firstIndex(where: { $0.paneID == frontID }),
              slot.siblings.indices.contains(i + delta) else { return }
        let next = slot.siblings[i + delta]
        open(PaneSlot(paneID: next.paneID, title: next.displayName, agent: next,
                      initialReply: "", siblings: slot.siblings))
    }

    /// Sections after applying the search box. Search filters the raw agents and
    /// re-derives, so counts and grouping stay honest for the filtered view.
    private var visibleSections: [(group: AgentGroup, rows: [AgentRow])] {
        guard !search.isEmpty else { return fullList.sections }
        let filtered = agents.filter {
            $0.displayName.localizedCaseInsensitiveContains(search)
                // The raw name still carries the peer's alias; keep searching it so
                // typing a profile id (or the alias shown before labels landed)
                // still finds that machine's agents.
                || ($0.name ?? "").localizedCaseInsensitiveContains(search)
                || ($0.terminalTitleStripped ?? "").localizedCaseInsensitiveContains(search)
        }
        return AgentList(agents: filtered, livePaneIDs: livePaneIDs).sections
    }

    /// The on-screen item directly above the open sidebar row: its bottom separator would
    /// touch the open row's highlight, so it is hidden (Messages does the same). A row is
    /// identified by its pane ID, a group's disclosure row ("Idle  4 ›") by `disclosureKey`,
    /// a folder row by `folderKey`.
    private func itemAboveOpenRow(_ sections: [AgentFolderLayout.Section]) -> String? {
        guard hSizeClass == .regular, let frontID else { return nil }
        var previous: String?
        for section in sections {
            let isCollapsed = search.isEmpty && collapsed.contains(section.group)
            if section.group.startsCollapsed && search.isEmpty {
                previous = Self.disclosureKey(section.group)
            }
            guard !isCollapsed else { continue }
            for item in section.items {
                switch item {
                case .agent(let row, _, _):
                    if row.info.paneID == frontID { return previous }
                    previous = row.info.paneID
                case .folder(let summary):
                    previous = Self.folderKey(summary.folder.id)
                }
            }
        }
        return nil
    }

    private static func disclosureKey(_ group: AgentGroup) -> String { "disclosure:\(group)" }

    /// The iPad (regular-width) layout: a two-column `NavigationSplitView`. Sidebar = the section
    /// pill + the agents list; detail = the selected agent's LIVE TERMINAL (or Gram / Settings for
    /// those sections). Reuses the SAME views + terminal machinery as the phone layout — only the
    /// arrangement differs. iPhone / narrow width keeps the tab-bar-with-terminal-over layout.
    private var adaptiveLayout: some View {
        GeometryReader { geometry in
        agentActions(
        NavigationSplitView(columnVisibility: .constant(columnVisibility),
                            preferredCompactColumn: .constant(.detail)) {
            ZStack {
                Palette.ground.ignoresSafeArea()
                VStack(spacing: 0) {
                    switch selectedTab {
                    case .agents:
                        header
                        if let error {
                            errorView(error)
                        } else if loading && agents.isEmpty {
                            Spacer(); ProgressView().tint(Palette.textDim); Spacer()
                        } else {
                            agentList
                        }
                    case .settings:
                        SectionTopBar(title: "Settings") { hideSidebarButton }
                        settingsIndex   // the section index; each jumps the detail pane
                    case .gram:
                        // Gram's Inbox/Saved selector belongs in THIS column, beside the section
                        // picker, the same way the agents list does. It used to render an empty
                        // Spacer() here while GramView drew its own 260pt rail in the detail
                        // pane, which put two sidebars on screen — one of them blank.
                        gramSidebar
                    }
                }
                // #360: the sections live in the iPhone tab bar's shape at the bottom of the
                // column. A safe-area inset (not an overlay) so the lists end above it and
                // can still scroll their last row into view.
                .safeAreaInset(edge: .bottom, spacing: 0) { sidebarTabBar }
            }
            // Remembered width. SwiftUI exposes no way to READ a divider drag, so the
            // column measures itself and feeds the settled value back as `ideal` on the
            // next launch. Clamped to the same min/max the modifier enforces, so a
            // stored value can never put the sidebar outside its own bounds.
            //
            // DEBOUNCED, because the stored value also drives `ideal` below and that
            // makes an intermediate measurement SELF-FULFILLING: persist 250 mid-sweep
            // and `ideal` retargets to 250, so the column settles at a width the owner
            // never chose and every later launch opens there. The measurement lands in
            // `@State` immediately (cheap, no persistence) and only reaches `AppStorage`
            // once it has stopped moving for `sidebarWidthSettle`.
            .background {
                GeometryReader { proxy in
                    Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in
                        measuredSidebarWidth = width
                        measuredSidebarWidthAt = Date()
                    }
                }
            }
            // `task(id:)` IS the debounce: a new measurement cancels the pending commit
            // and restarts the wait, so only a width that survives the interval is kept.
            .task(id: measuredSidebarWidth) {
                try? await Task.sleep(nanoseconds: Self.sidebarWidthSettle)
                guard !Task.isCancelled else { return }
                recordSidebarWidth(measuredSidebarWidth)
            }
            .navigationSplitViewColumnWidth(
                min: Self.sidebarWidthRange.lowerBound,
                ideal: sidebarWidth,
                max: Self.sidebarWidthRange.upperBound)
            .toolbar(.hidden, for: .navigationBar)
        } detail: {
            // THE RAIL STAYS AN HSTACK SIBLING, and the inset I tried is withdrawn too.
            //
            // I replaced this with `detailColumn.safeAreaInset(edge: .leading)` on the
            // theory that an inset CHANGE re-proposes the inset region while a sibling
            // insertion does not. Review held the two against the documented contract:
            // in steady state both inset the column by the rail's 64pt, so the content
            // width is identical before and after, and the entire bet rested on an
            // undocumented re-proposal property. If a stale proposal exists it comes
            // from the split view's own animated column width, which NEITHER form
            // influences. It also carried a real regression risk on this exact surface:
            // `safeAreaInset` takes a vertical alignment, which only means anything if
            // the content is not stretched to the container's height — so `sidebarRail`'s
            // `Spacer()` greed could collapse into a short, vertically centred block,
            // and `groundMachine.ignoresSafeArea()` would then bleed under the leading
            // 64pt as a dark strip above and below it.
            //
            // So this PR changes NO layout. Four guesses at the owner's geometry have been
            // refuted: a GramView anchor, a ZStack anchor, a detail frame, and this inset.
            //
            // AND IT SHIPS NO TEST EITHER. An iPad guard was carried by five reviewed heads,
            // with a sixth round reviewing its removal, because after each fix its defect only
            // moved rather than disappearing: the waiter
            // asserted on the same axis as the assertion; the wall-clock floor that
            // replaced it could return a pre-collapse rect and fail a CORRECT layout with
            // a message byte-identical to the true finding, so a red run could not be told
            // from a flake; and nothing re-checked the row existed before measuring it.
            // That last one I could only half establish, and the half I could not is the
            // point: the predicates were verified to BOTH pass on a zero rect, so IF an
            // unresolved query returns `CGRect.zero` a blank detail column greened the
            // case — but XCUITest's documented behaviour there is unspecified, it may
            // instead raise, and no run ever settled it. Untrustworthy either way, which
            // is enough. The owner has since confirmed the symptom does not occur on
            // iPad and can no longer reproduce it on the Mac, so the guard could not have
            // seen its target either way. If it returns, the instrument is a TestFlight
            // build and the owner's account of what preceded it, not another commit here.
            HStack(spacing: 0) {
                // Compact adaptation never changes the user's regular-width choice.
                // No transition: a sliding rail animates the detail column's width, and
                // every intermediate width reflows the live terminal (see `toggleSidebar`).
                if hSizeClass == .regular && columnVisibility == .detailOnly { sidebarRail }
                detailColumn
            }
            // A floor under the detail column, so a window just wider than two columns keeps
            // them side by side. Without it the split's automatic minimum for the detail does
            // not fit beside the 320 pt sidebar: on iOS 27 a 715 pt iPad window (full screen
            // dragged into a window) went secondaryOnly, `columnVisibility` became
            // `.detailOnly` and the sidebar collapsed to the rail (CI 40847167282). The same
            // floor keeps the columns side by side on iPhone Duo held tall (669 pt).
            .navigationSplitViewColumnWidth(min: DesignTokens.Size.sidebarMin,
                                            ideal: DesignTokens.Size.sidebarMin)
            // NO SIZE CONTRACT IS ADDED HERE, AND THE ONE I TRIED IS WITHDRAWN.
            //
            // It was `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)`,
            // on the theory that an undersized page was being centre-placed by the split
            // view. Review refuted the premise with the code: `detailColumn`'s ZStack has
            // `Palette.groundMachine.ignoresSafeArea()` as its first child, and that is a
            // `Color` (DesignSystem.swift:21) — no intrinsic size, accepts any finite
            // proposal — so the ZStack already fills, and a flexible frame cannot enlarge
            // a child that is not small. Inert. The same premise was refuted once before,
            // at #268, when I put the modifier one level lower.
            //
            // I also claimed here that it was WORSE than inert in the overflow case, by
            // clamping the reported size and sending the whole excess off the bottom. That
            // was wrong, and the rule I asserted does not exist. Apple's contract for
            // `frame(minWidth:...maxHeight:alignment:)` adopts the proposal unconditionally
            // only when BOTH constraints are given in a dimension. With a MAXIMUM only, it
            // reports "the proposed size, clamped to that maximum" when the proposal
            // exceeds the child, and "the size of this view" otherwise. The maximum here
            // was `.infinity`, for which that clamp is the identity — so for THIS modifier
            // an overflowing child was reported at its own oversized size and placed as
            // before. Inert there too, not harmful. (State the clamp when quoting the rule
            // generally: at a finite maximum it does bound the result.)
            //
            // So the vertical half of the owner's report is UNDIAGNOSED and unmeasured,
            // deliberately: four diagnoses were refuted and the instrument built to tell
            // them apart false-failed on correct layouts, so it was removed rather than
            // recalibrated a fourth time.
            .toolbar(.hidden, for: .navigationBar)
        }
        .navigationSplitViewStyle(.balanced)
        // Visibility is derived above, with no system-writeback or restoration race.
        .tint(Palette.brand)
        // Hardware-keyboard shortcuts (iPad): ⌘K minimises/expands the sidebar, ⌘/ opens the
        // shortcut reference. Hidden zero-size buttons carry the key bindings.
        .background { keyboardShortcuts }
        .sheet(isPresented: $showShortcuts) {
            ShortcutsSheet(onClose: { showShortcuts = false })
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        )
        // NavigationSplitView consumes corner insets before passing its environment
        // to the sidebar; pass the window controls' corner on for the shared bar.
        .environment(\.sectionWindowControls, sectionWindowControls(geometry))
        }
    }

    /// The detail column's content, factored out so the rail can sit beside it.
    private var detailColumn: some View {
        ZStack(alignment: .topLeading) {
                Palette.groundMachine.ignoresSafeArea()
                // One tab tree and one terminal container survive compact/regular changes.
                // Only the surrounding navigation chrome and the Agents list placement vary.
                TabView(selection: tabSelection) {
                    ZStack(alignment: .topLeading) {
                        Group {
                            if hSizeClass == .regular {
                                // The tab paints its own opaque background over the detail
                                // ground, so the field brings that ground under the status bar,
                                // home indicator and side bands itself, or they show black. The
                                // field stays inside the safe area so "Select an agent" keeps the
                                // column's centre (the leading inset lies under the sidebar).
                                SelectAgentPlaceholder(lines: glyphFieldLines, spotlight: glyphFieldSpotlight)
                                    .background { Palette.groundMachine.ignoresSafeArea() }
                            } else {
                                agentsTab
                            }
                        }
                        // The tab owns native presentation; the pane tree stays in this
                        // same slot across both size classes and tab switches.
                        PaneKeepAliveContainer(
                            client: client, slots: slots, frontID: frontID,
                            isPresented: selectedTab == .agents,
                            onClose: { frontID = nil; Task { await load() } },
                            onNavigate: { slot, delta in navigate(from: slot, delta: delta) })
                            .opacity(frontID != nil ? 1 : 0)
                            .offset(x: frontID != nil ? 0 : 40)
                            .allowsHitTesting(frontID != nil)
                            .animation(.easeOut(duration: 0.26), value: frontID != nil)
                    }
                    .tag(HomeTab.agents)
                    .tabItem { Label(HomeTab.agents.label, systemImage: HomeTab.agents.icon) }
                    .toolbar(hSizeClass == .regular || frontID != nil ? .hidden : .visible, for: .tabBar)

                    GramView(client: client, unread: gramUnread,
                             showingSaved: $gramShowingSaved,
                             refreshToken: gramRefreshToken,
                             readAllToken: gramReadAllToken,
                             searchText: $gramSearch,
                             newestToken: gramNewestToken,
                             roster: orderedSiblings)
                        .tag(HomeTab.gram)
                        .tabItem { Label(HomeTab.gram.label, systemImage: HomeTab.gram.icon) }
                        .modifier(GramUnreadBadge(unread: gramUnread))
                        .toolbar(hSizeClass == .regular ? .hidden : .visible, for: .tabBar)

                    SettingsView(
                        client: client,
                        agents: agents,
                        host: host,
                        connected: error == nil && !loading,
                        canReconnect: rejectedFingerprint == nil,
                        onReconnect: onReconnect,
                        detail: hSizeClass == .regular ? (settingsAnchor ?? .machines) : nil,
                        serverUpdate: serverUpdate)
                        .tag(HomeTab.settings)
                        .badge(settingsBadge)
                        .tabItem { Label(HomeTab.settings.label, systemImage: HomeTab.settings.icon) }
                        .toolbar(hSizeClass == .regular ? .hidden : .visible, for: .tabBar)
                }
                // The bar is only visible in compact, where tab items use the text colour.
                // Regular hides it, and its content keeps the split view's brand tint
                // (Settings actions, Gram controls), as before the tab tree was shared.
                .tint(hSizeClass == .regular ? Palette.brand : Palette.text)
        }
    }

    /// Zero-opacity buttons that exist only to register ⌘K / ⌘/ (and ⌘F on Gram) with the
    /// responder chain.
    private var keyboardShortcuts: some View {
        ZStack {
            Button("Toggle sidebar") { toggleSidebar() }
            .keyboardShortcut("k", modifiers: .command)
            Button("Shortcuts") { showShortcuts = true }
                .keyboardShortcut("/", modifiers: .command)
            // Terminal font zoom (Mac + hardware keyboard). ⌘+ registers from "=" (its
            // unshifted key), ⌘- shrinks, ⌘0 resets — the standard zoom idiom.
            Button("Zoom in") { terminalFontSize = min(terminalFontSize + 1, 24) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom out") { terminalFontSize = max(terminalFontSize - 1, 9) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Reset zoom") { terminalFontSize = 12.5 }
                .keyboardShortcut("0", modifiers: .command)
            // The sidebar owns Gram's ⌘F only at regular width. The compact header
            // registers its own shortcut against the same search state.
            if selectedTab == .gram && hSizeClass == .regular {
                Button("Search Gram") { focusGramSearch() }
                    .keyboardShortcut("f", modifiers: .command)
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The iPad Settings sidebar (proposal B, #572): the root list itself — machine card,
    /// suggestions, Your herd, Preferences with their inline pickers, Help and About — whose
    /// page rows select the detail column's page, the selected one filled `surfaceRaised`.
    private var settingsIndex: some View {
        SettingsView(
            client: client,
            agents: agents,
            host: host,
            connected: error == nil && !loading,
            canReconnect: rejectedFingerprint == nil,
            onReconnect: onReconnect,
            serverUpdate: serverUpdate,
            sidebarSelection: $settingsAnchor)
    }

    /// Gram's sidebar column, as the design draws it: the shared section bar (Back, the small
    /// centred title with the amber unread count, and the sidebar toggle / Read all / Refresh
    /// capsule), a mic-less search field, and the channel's two conversations as Messages rows.
    ///
    /// This is the SAME column the agents list uses. Gram previously drew its own rail inside the
    /// detail pane while this column rendered a blank `Spacer()`, so the reader saw two sidebars
    /// and the left one was empty. Selecting a row writes `gramShowingSaved` and typing writes
    /// `gramSearch`; the page reads both as bindings, so the detail pane filters and swaps in
    /// place with no navigation, and the page shows no search control of its own.
    private var gramSidebar: some View {
        GramUnreadContent(unread: gramUnread) { count in
            VStack(alignment: .leading, spacing: 0) {
                SectionTopBar(title: "Gram", count: count, leading: {
                    SectionBackSlot(.leading) { sectionBackButton }
                }) {
                    hideSidebarButton
                    SectionBackSlot(.trailing) { sectionBackButton }
                    if !gramShowingSaved, count > 0 {
                        SectionBarButton(icon: "envelope.open", label: "Read all") { gramReadAllToken += 1 }
                    }
                    SectionBarButton(icon: "arrow.clockwise", label: "Refresh") { gramRefreshToken += 1 }
                }
                sidebarSearchField(text: $gramSearch, focus: $gramSearchFocused,
                                   identifier: "gram-search-field", height: 40, outlined: true)
                    .padding(.top, 2)
                GramSidebarConversations(showingSaved: $gramShowingSaved, unreadCount: count)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// ⌘F on Gram: the cursor goes to the sidebar search. A minimised sidebar is opened first;
    /// the field only mounts with its column, so the focus waits out the column's animation.
    private func focusGramSearch() {
        guard columnVisibility == .detailOnly else {
            gramSearchFocused = true
            return
        }
        toggleSidebar()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { gramSearchFocused = true }
    }

    /// Gram's two conversations in the sidebar, as Messages rows. "Gram" is the channel: the two
    /// most recent agent senders' avatars, the newest message as the preview and its time, and
    /// the amber dot while anything is unread. "Saved" is the local bookmarks: the newest saved
    /// message and its time. Selecting a row writes `showingSaved`, which the page reads.
    ///
    /// Its own view, observing the two stores itself, so a poll or a bookmark re-renders these
    /// two rows rather than the whole home view.
    private struct GramSidebarConversations: View {
        @Binding var showingSaved: Bool
        let unreadCount: Int
        @ObservedObject private var inboxStore = GramInboxStore.shared
        @ObservedObject private var savedStore = SavedGramStore.shared

        var body: some View {
            let messages = inboxStore.inbox.messages   // newest first
            let senders = Self.recentAgentSenders(in: messages)
            let newestSaved = savedStore.saved.first   // newest first
            VStack(spacing: 2) {
                conversation(identifier: "gram-conversation-gram", selected: !showingSaved,
                             select: { showingSaved = false }) {
                    GramConversationRow(
                        title: "Gram",
                        avatarNames: senders,
                        // No agent has written yet: the channel's own symbol in place of faces.
                        systemImage: senders.isEmpty ? "bubble.left.and.bubble.right.fill" : nil,
                        preview: messages.first.map { Self.preview(of: $0) } ?? AttributedString(),
                        time: messages.first?.createdAt,
                        unread: unreadCount > 0,
                        selected: !showingSaved)
                }
                conversation(identifier: "gram-conversation-saved", selected: showingSaved,
                             select: { showingSaved = true }) {
                    GramConversationRow(
                        title: "Saved",
                        avatarNames: [],
                        systemImage: "bookmark.fill",
                        preview: newestSaved.map { Self.preview(of: $0) }
                            ?? AttributedString("No saved messages yet"),
                        time: newestSaved?.createdAt,
                        unread: false,
                        selected: showingSaved)
                }
            }
        }

        /// The row as a plain button carrying the id tests and VoiceOver use, with the
        /// selected trait on the current conversation.
        private func conversation<Row: View>(identifier: String, selected: Bool,
                                             select: @escaping () -> Void,
                                             @ViewBuilder row: () -> Row) -> some View {
            Button(action: select, label: row)
                .buttonStyle(.plain)
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 14))
                .hoverEffect(.highlight)
                .accessibilityIdentifier(identifier)
                .accessibilityAddTraits(selected ? .isSelected : [])
        }

        /// The two most recent distinct agents that wrote, by bare name, newest first.
        private static func recentAgentSenders(in messages: [GramMessage]) -> [String] {
            var names: [String] = []
            for message in messages where message.isFromAgent {
                let name = message.senderAgentName
                if !names.contains(name) { names.append(name) }
                if names.count == 2 { break }
            }
            return names
        }

        /// "You: **vetrina** great, ship it." for the owner's posts (the addressee in bold;
        /// a shared-queue post has none), "clientloop: Scaffold is up…" for an agent's.
        private static func preview(of message: GramMessage) -> AttributedString {
            let body = summary(message.text, fileName: message.attachmentPreview)
            guard !message.isFromAgent else {
                return AttributedString("\(message.senderAgentName): \(body)")
            }
            var line = AttributedString("You: ")
            if let to = message.to {
                var name = AttributedString(GramMessage.agentName(from: to))
                name.inlinePresentationIntent = .stronglyEmphasized
                line += name
                line += AttributedString(" ")
            }
            line += AttributedString(body)
            return line
        }

        /// A saved copy keeps the sender as displayed (`hetzner-1/clientloop`); the row shows
        /// the bare name, like the channel row.
        private static func preview(of saved: SavedGram) -> AttributedString {
            let body = summary(saved.text, fileName: saved.attachmentPreview)
            let sender = saved.fromAgent ? GramMessage.agentName(from: saved.from) : "You"
            return AttributedString("\(sender): \(body)")
        }

        /// The message as one line of prose: fences dropped (their code kept), runs of
        /// whitespace and newlines collapsed. A file with no caption reads as its name (an
        /// expired one as "<name> (expired)").
        private static func summary(_ text: String, fileName: String?) -> String {
            let pieces = GramText.segments(text).map { segment -> String in
                switch segment {
                case .text(let prose): return prose
                case .code(let code, _): return code
                }
            }
            let flat = pieces.joined(separator: " ")
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            return flat.isEmpty ? (fileName ?? "") : flat
        }
    }

    private var hideSidebarButton: some View {
        SectionBarButton(icon: "sidebar.leading", label: "Minimise sidebar",
                         identifier: "terminal-sidebar-toggle", action: toggleSidebar)
            .help("Minimise sidebar (⌘K)")
    }
    /// The sections as the iPhone tab bar, at the bottom of the sidebar (#360): the same
    /// items, `.fill` symbols, 10 pt labels, white selected tab (`.tint(Palette.text)` on
    /// iPhone) and the system red Gram count. iPadOS has no system tab bar inside a split
    /// view's sidebar column, so it is drawn to the iPhone bar's metrics: 62 pt tall,
    /// 31 pt corners, 14 pt from the column's sides.
    ///
    /// Liquid Glass (owner 2026-10-05): on iPadOS 26 / macOS 26 the bar is Apple's own glass,
    /// the same material as the iPhone tab bar, and the selected pill slides between tabs.
    /// The list scrolls underneath (the bar is a safe-area inset), which is what the glass
    /// shows. Earlier systems keep the frosted bar. It follows the sidebar's width but never
    /// grows past `sidebarTabBarMaxWidth`, centred, so a wide sidebar doesn't stretch it.
    private var sidebarTabBar: some View {
        GramUnreadContent(unread: gramUnread) { count in
            HStack(spacing: 0) {
                ForEach(HomeTab.allCases, id: \.self) { tab in
                    sidebarTabItem(tab, badge: tabBadgeCount(for: tab, gram: count))
                }
            }
        }
        .animation(.smooth(duration: 0.3), value: selectedTab)
        .padding(4)
        .frame(height: DesignTokens.Size.tabBar)
        .modifier(SidebarTabBarMaterial())
        .frame(maxWidth: Self.sidebarTabBarMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14).padding(.bottom, 12).padding(.top, 6)
    }

    /// About three iPhone tab items wide; the sidebar ranges 250-460 pt.
    private static let sidebarTabBarMaxWidth: CGFloat = DesignTokens.Size.tabBarMaxWidth

    /// Selects a section. Gram tapped while it is already selected goes to its newest message
    /// (`gramNewestToken`): the feed is oldest-first, so "back to the start" is its BOTTOM.
    private func select(_ tab: HomeTab) {
        if tab == .gram, selectedTab == .gram { gramNewestToken += 1 }
        selectedTab = tab
    }

    /// The phone's tab bar selection, through `select`: the TabView sets it again with the
    /// selected tab when that tab is tapped, which is how a re-tap of Gram is seen. Gram's
    /// feed opts out of the tab bar's own scroll-to-top (see `WindowedBottomFeed`); Agents
    /// and Settings keep it.
    private var tabSelection: Binding<HomeTab> {
        Binding(get: { selectedTab }, set: { select($0) })
    }

    private func sidebarTabItem(_ tab: HomeTab, badge: Int) -> some View {
        let selected = selectedTab == tab
        return Button { select(tab) } label: {
            VStack(spacing: 1) {
                Image(systemName: tab.icon)
                    .environment(\.symbolVariants, .fill)
                    .font(.system(size: 21, weight: .medium))
                    .frame(height: 28)
                    .overlay(alignment: .topTrailing) { tabBadge(badge).offset(x: 12, y: -3) }
                Text(tab.label).font(.system(size: DesignTokens.Text.TabLabel.size,
                                             weight: DesignTokens.Text.TabLabel.weight))
            }
            .foregroundStyle(selected ? Palette.text : Palette.textDim)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                // One pill, moved between tabs, so a selection change slides instead of blinking.
                if selected {
                    Capsule().fill(Color.white.opacity(0.12))
                        .matchedGeometryEffect(id: "sidebar-tab-selection", in: sidebarTabSelection)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(tab.label)
        .accessibilityValue(badgeValue(tab, badge))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The system tab badge: a red capsule with the count, as `.badge` draws on iPhone.
    @ViewBuilder
    private func tabBadge(_ count: Int) -> some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: DesignTokens.Text.BadgeCount.size,
                              weight: DesignTokens.Text.BadgeCount.weight)).monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 18)
                .background(Capsule().fill(Color(uiColor: .systemRed)))
                .accessibilityHidden(true)
        }
    }

    /// The minimise / restore control. ⌘K was the only trigger before, bound to a
    /// zero-opacity button, and the navigation bar is hidden in both columns — so on
    /// an iPad without a hardware keyboard, or on the Mac build where a click is the
    /// expected gesture, there was nothing to hit. A 44 pt round button (#360).
    private func sidebarToggleButton(icon: String, hint: String, minimize: Bool) -> some View {
        Button { toggleSidebar() } label: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.text)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Palette.surfaceRaised))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(minimize ? "Minimise sidebar" : "Expand sidebar")
        .accessibilityIdentifier("terminal-sidebar-toggle")
        .help(hint)
    }

    /// Records a measured sidebar width, ignoring anything that is not a real resize.
    ///
    /// Ignore compact adaptation, minimised columns, out-of-bounds animation samples
    /// and sub-point jitter. The caller also requires a settled measurement.
    private func recordSidebarWidth(_ width: CGFloat) {
        guard hSizeClass == .regular, !sidebarMinimized else { return }
        guard Self.sidebarWidthRange.contains(width) else { return }
        guard abs(width - CGFloat(sidebarWidth)) >= 1 else { return }
        sidebarWidth = Double(width)
    }

    /// Minimises or expands the sidebar, WITHOUT animating it.
    ///
    /// An animated width change is not cosmetic here: the detail column holds a live
    /// terminal, and every intermediate width makes SwiftTerm reflow the grid and fire
    /// `sizeChanged` -> `sendPTYSize`, so one animated collapse costs dozens of
    /// reflows and a `set_pty_size` round-trip for each distinct width. That is the
    /// visible re-scrolling/re-wrapping churn. One step = one reflow.
    ///
    /// Only explicit user actions change the persisted regular-width choice.
    private func toggleSidebar() {
        let minimize = !sidebarMinimized
        // Commit any pending measurement before collapsing: the debounce is 500ms, and
        // a drag followed straight away by a minimise would otherwise lose the width
        // the owner just chose. Runs while the column is still open, so the layout
        // guard in `recordSidebarWidth` passes.
        //
        // Only a STILL measurement, though. This path bypasses the debounce, and the
        // split view sweeps intermediate widths through `measuredSidebarWidth` during
        // its own ~0.3s column animation — so minimising again inside that window (⌘K
        // key repeat, an impatient double-tap) would otherwise persist a width the
        // owner never chose, and because the stored value feeds `ideal` the column
        // would then open there on every later launch. That is exactly the
        // self-fulfilling corruption the debounce exists to prevent, and bypassing it
        // must not reopen the hole.
        if minimize,
           Date().timeIntervalSince(measuredSidebarWidthAt) >= Self.sidebarWidthStillFor {
            recordSidebarWidth(measuredSidebarWidth)
        }
        sidebarMinimized = minimize
    }

    /// The minimised sidebar: a 64pt icon rail that keeps the section badges and the
    /// activity counts visible and is one click from expanding.
    ///
    /// It lives in the DETAIL column rather than as a narrow sidebar column on
    /// purpose. `NavigationSplitView` enforces its own minimum sidebar width on iPad,
    /// so a 64pt column is not reliably honoured, and a control whose width the
    /// platform may override is not something to ship untested on a device. Rendering
    /// the rail ourselves is exact on both platforms.
    private var sidebarRail: some View {
        let activity = fullList.activityContent
        return VStack(spacing: 6) {
            sidebarToggleButton(
                icon: "sidebar.left", hint: "Expand sidebar (⌘K)", minimize: false)
                .padding(.bottom, 2)
            GramUnreadContent(unread: gramUnread) { count in
                ForEach(HomeTab.allCases, id: \.self) { tab in
                    railSectionButton(tab, badge: tabBadgeCount(for: tab, gram: count))
                }
            }
            // Gated on the same condition as the counts below it: a separator with
            // nothing on its far side is precisely the zero-value noise those counts
            // are suppressed to avoid, and the quiet state is the COMMON rendering.
            if fullList.needsYouCount > 0 || activity.workingCount > 0 {
                Divider().overlay(Palette.hairlineQuiet)
                    .padding(.horizontal, 10).padding(.vertical, 4)
            }
            // The counts are the reason to minimise rather than hide. `needsYou` is the
            // ROSTER's STRICT count (`AgentList.needsYouCount`), deliberately NOT
            // `activityContent.needsYouCount`: that one folds `.unrecognised` rows into
            // the total for the section-less Live Activity, so it would print a BIGGER
            // number than the expanded list's NEEDS YOU section this rail stands in for.
            // One unrecognised agent and the two surfaces would disagree one click apart.
            //
            // The same fold is why the wording spec (`AgentList.needsYouSummary`) hedges
            // unrecognised agents as "N may need you": they are unconfirmed, not facts. A
            // bare number cannot carry that hedge, so the rail shows only what IS confirmed.
            railCount(fullList.needsYouCount, tone: Palette.waiting, label: "need you")
            railCount(activity.workingCount, tone: Palette.working, label: "working")
            Spacer()
        }
        .frame(width: DesignTokens.Size.rail)
        .padding(.top, 12)
        // The top bars' clearance from the glass: on iPhone Duo's inner display held wide the
        // status bar is on the side, so the rail starts at the window's top edge, and its
        // expand button sat 12 pt from the glass, 4 pt above the terminal bar's controls
        // beside it. It now keeps their 16 pt. No change where there is a status bar above
        // or window chrome (iPad, Mac).
        .topEdgeClearance(base: 12, rowHeight: DesignTokens.Size.topBarRow)
        .background(Palette.ground)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Palette.hairlineQuiet).frame(width: 0.5).ignoresSafeArea()
        }
    }

    /// A rail section icon. Tapping selects the section AND expands, which is the
    /// predictable reading of a click on a minimised menu; the chevron above expands
    /// without changing section.
    private func railSectionButton(_ tab: HomeTab, badge: Int = 0) -> some View {
        Button {
            select(tab)
            // Selecting a rail section explicitly expands the regular-width sidebar.
            sidebarMinimized = false
        } label: {
            Image(systemName: tab.icon)
                .environment(\.symbolVariants, .fill)
                .font(.system(size: 18, weight: .medium))
                .overlay(alignment: .topTrailing) { tabBadge(badge).offset(x: 11, y: -6) }
                .foregroundStyle(selectedTab == tab ? Palette.text : Palette.textDim)
                .frame(width: 44, height: 40)
                .background(selectedTab == tab ? Color.white.opacity(0.12) : Color.clear,
                            in: Capsule())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(tab.label)
        .accessibilityValue(badgeValue(tab, badge))
    }

    /// The count a section's tab carries: Gram's unread messages, Settings' herdr update.
    private func tabBadgeCount(for tab: HomeTab, gram: Int) -> Int {
        switch tab {
        case .gram: return gram
        case .settings: return settingsBadge
        case .agents: return 0
        }
    }

    private func badgeValue(_ tab: HomeTab, _ badge: Int) -> String {
        guard badge > 0 else { return "" }
        return tab == .settings ? "\(badge) update" : "\(badge) unread"
    }

    /// One activity count. Rendered only when non-zero: a rail of zeroes is noise.
    @ViewBuilder
    private func railCount(_ count: Int, tone: Color, label: String) -> some View {
        if count > 0 {
            VStack(spacing: 2) {
                Circle().fill(tone).frame(width: 6, height: 6)
                Text("\(count)")
                    .font(Typography.machine(13, .semibold))
                    .foregroundStyle(Palette.text)
            }
            .frame(width: 40)
            .padding(.vertical, 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(count) \(label)")
        }
    }

    private struct GramUnreadContent<Content: View>: View {
        @ObservedObject var unread: GramUnreadTracker
        private let content: (Int) -> Content

        init(unread: GramUnreadTracker, @ViewBuilder content: @escaping (Int) -> Content) {
            self.unread = unread
            self.content = content
        }

        var body: some View { content(unread.count) }
    }

    private struct GramUnreadBadge: ViewModifier {
        @ObservedObject var unread: GramUnreadTracker

        func body(content: Content) -> some View {
            content.badge(unread.count == 0 ? nil : Text("\(unread.count)"))
        }
    }

    var body: some View {
        // Observe the text-size setting so the home re-renders at the new
        // `Typography.scale` on change (identity unchanged → @State preserved).
        let _ = uiFontScale
        return adaptiveLayout
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if ScreenshotMock.mode != nil { StatusMotionProbe() }
        }
        .onAppear {
            guard ScreenshotMock.mode == .resize, slots.isEmpty else { return }
            let fixtures = TerminalInteractionHarness.agents
            for fixture in fixtures.reversed() {
                open(PaneSlot(paneID: fixture.paneID, title: fixture.displayName,
                              agent: fixture, initialReply: "", siblings: fixtures))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: TerminalInteractionHarness.navigateNotification)) { note in
            guard ScreenshotMock.mode == .resize else { return }
            if note.object as? String == "close" {
                if let frontID { slots.removeAll { $0.paneID == frontID } }
                frontID = slots.last?.paneID
            } else if let slot = slots.first(where: { $0.paneID != frontID }) {
                open(slot)
            }
        }
        #endif
        // Connect-scoped lifecycle, attached to the PERSISTENT ROOT, not a tab: a
        // TabView re-runs a tab's .task / .onAppear every time that tab re-appears, so
        // keeping these here fires load / fork-probe / first-run / deep-links ONCE per
        // connect (this view is .id(session)-scoped) rather than on every tab switch —
        // which otherwise re-showed the fork notice and cancelled an in-flight load.
        //
        // Load the agent list on connect, then keep it LIVE with a periodic refresh.
        // Without the poll the list was fetched only once per connect (plus after a
        // local spawn / close), so a server-side change — a new agent, a
        // working → needs-you → exit transition, an agent that died — stayed invisible
        // until the user reconnected to force a fresh load. agent.list is small JSON
        // (cheap, unlike a screen fetch), and load() is stale-while-revalidate: a
        // failed refresh keeps the last-good list rather than blanking it, and the
        // spinner shows only while the list is empty. Still one .task, .id(session)-
        // scoped, so tab switches never restart or duplicate it.
        //
        // While the live status stream below is open, rows update from its events and
        // this loop only re-fetches once the backstop interval has passed since the
        // last load that published (event-driven reloads count; a failed load does
        // not, so the next tick retries it). The tick itself stays at the poll
        // interval, so a dropped stream falls back to the 5 s cadence on the next tick
        // rather than after a full backstop. Without the stream this is the plain
        // 5 s poll it always was.
        .task {
            await load()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: agentListPollIntervalNanoseconds)
                if liveEvents.backstop.isDue(
                    streaming: liveEvents.streaming,
                    interval: .nanoseconds(Int64(agentListBackstopIntervalNanoseconds)),
                    now: .now) {
                    await load()
                }
                // EVERY POLL, not only on a change. Recovery after the reader swipes
                // the banner away cannot hang off `.onChange(of: fullList)` below: that
                // fires when the roster MOVES, which is exactly what a blocked agent
                // waiting for an answer does not do. `recoverIfEnded` mints only when
                // nothing is live and pushes no content otherwise, so a stable roster
                // costs one predicate per poll rather than an ActivityKit update.
                LiveActivityController.shared.recoverIfEnded(
                    LiveActivityController.state(from: fullList)
                )
            }
        }
        // The roster menus' daemon actions, on the current client (see `menuAction`).
        .onChange(of: menuAction) { _, action in
            guard let action else { return }
            menuAction = nil
            Task { await run(action) }
        }
        // DEBUG mock knob: a home redraw at every touch-down (DebugTouchRedraw).
        .onAppear { DebugTouchRedraw.installIfEnabled() }
        .onReceive(NotificationCenter.default.publisher(for: DebugTouchRedraw.touchDown)) { _ in
            rosterNow = Self.rosterClockNow()
        }
        // The live status stream (herdr events v2): one all-panes `events.subscribe`
        // held while the app is not backgrounded and the daemon advertises
        // `events_v2`. Keyed on both, so backgrounding cancels the task, which closes
        // the SSH channel, and returning reopens it; leaving the view cancels it too.
        .task(id: liveEventsSupported && scenePhase != .background) {
            guard liveEventsSupported, scenePhase != .background else { return }
            await runLiveEvents()
        }
        // Ambient unread-gram poll for the tab badge, running ONLY while the Gram
        // tab is not showing — GramView keeps its own 6s poll while visible and
        // writes the count on load / mark-read. Keyed on selectedTab so it
        // restarts on tab change and idles on Gram: exactly one poller is live.
        .task(id: selectedTab) {
            guard selectedTab != .gram else { return }
            while !Task.isCancelled {
                // Unconditional on purpose: `unread_only` is a small answer already,
                // and this poller keeps no list to compare a digest against. The count is
                // the daemon's `unread_count` when it sends one: a paging daemon answers
                // with one page, which would undercount (`unreadBadgeCount`).
                if let count = try? await client.gramList(unreadOnly: true).unreadBadgeCount {
                    gramUnread.count = count
                }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
        // Keep the session Live Activity (#90) in step with the herd: push a fresh
        // summary whenever the derived list changes, and once on appear so a
        // freshly-connected session reflects its agents right away. A no-op when the
        // user has Live Activities off — the controller guards that.
        .onChange(of: fullList, initial: true) { _, list in
            LiveActivityController.shared.update(LiveActivityController.state(from: list))
        }
        // If the daemon lacks the fork features, surface the advisory notice. Only a
        // DEFINITIVE not-fork flips it — network/other errors stay quiet (see
        // probeFork). If a cover is already up (e.g. the first-run gestures sheet the
        // onAppear below opens), DEFER — the sheet's onDismiss drains it.
        .task {
            guard await client.probeFork() == .notFork else { return }
            if activeCover == nil { showForkNotice = true } else { pendingForkNotice = true }
        }
        // One-time: fold any pre-per-host (global) terminal list into THIS host on first connect, so
        // the owner keeps their named terminals on their main box. Idempotent — a no-op after the
        // first migration and when there's nothing legacy pending.
        // Legacy terminals predate sessions, so they belong to the default session's bucket.
        .task(id: hostKey) {
            if !hostKey.isEmpty, session == nil { terminalsStore.migrateLegacyIfNeeded(host: hostKey) }
        }
        .onAppear { seedFromSessionCache() }
        .task { await watchSessions() }
        // First launch: show the gestures tutorial once — but NOT over a pending push
        // deep-link (openGramIfPending / applyDeepLink would dismiss it to show Gram or
        // the pane, wasting the one-shot). Burn the seen-flag ONLY when we present.
        .onAppear {
            if shouldShowFirstRunGesturesHelp,
                !hasSeenGesturesHelp,
                activeCover == nil,
                !push.pendingGram,
                push.pendingPaneID == nil
            {
                hasSeenGesturesHelp = true
                activeCover = .gestures
            }
        }
        // A push tapped while already loaded deep-links immediately, regardless of the
        // selected tab (open() selects Agents); the cold-launch / just-loaded case is
        // handled at the end of load().
        .onChange(of: push.pendingPaneID) { _, newValue in if newValue != nil { applyDeepLink() } }
        .onChange(of: push.pendingGram) { _, newValue in if newValue { openGramIfPending() } }
        // ONE item-based sheet, not two stacked isPresented presentations (stacked
        // presentation modifiers on a single view are historically fragile). A SHEET
        // (not a full-screen cover) so it presents bottom-up and swipe-down dismisses
        // it — the header close buttons still work too. onDismiss applies a queued
        // open AFTER the sheet is fully gone.
        .sheet(item: $activeCover, onDismiss: {
            // A just-spawned pane wins the foreground: open it and DON'T let a racing
            // gram push immediately drop it (the push stays pending — its notification
            // is still there — so the new agent's terminal is not yanked away). Else
            // apply any deferred gram tap now that the sheet is fully gone.
            if let slot = pendingOpenSlot {
                pendingOpenSlot = nil
                open(slot)
            } else {
                openGramIfPending()
            }
            // A fork notice deferred behind this sheet fires now — but only if nothing
            // else claimed the foreground, so the fullScreenCover never races the sheet.
            if pendingForkNotice && activeCover == nil {
                pendingForkNotice = false
                showForkNotice = true
            }
        }) { cover in
            Group {
                switch cover {
                case .newAgent:
                    NewAgentView(
                        client: client,
                        // Spawn done: queue the new pane, then dismiss the sheet; the
                        // onDismiss opens the pane with the task pre-filled.
                        onStarted: { paneID, name, task in
                            pendingOpenSlot = PaneSlot(paneID: paneID, title: name, agent: nil,
                                                       initialReply: task, siblings: [])
                            activeCover = nil
                        },
                        onCancel: { activeCover = nil })
                case .gestures:
                    GesturesHelpView(onClose: { activeCover = nil })
                }
            }
            // Full-height bottom-up sheet with a grabber, so swipe-down closes it.
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        // Advisory full-screen notice when the daemon lacks the fork features.
        // Dismissable — it never blocks basic use. onDismiss drains anything that
        // arrived WHILE it was up (a gram push / pane deep-link deferred against it),
        // so those never armed a competing presentation over the cover.
        .fullScreenCover(isPresented: $showForkNotice, onDismiss: {
            openGramIfPending()
            applyDeepLink()
        }) {
            ForkNoticeView(onDismiss: { showForkNotice = false })
        }
        .onChange(of: agents, initial: true) { _, roster in
            avatars.client = client
            avatars.update(agents: roster)
            groups.attach(client: client, host: hostKey)
        }
        .environment(avatars)
        .task { attachServerUpdate() }
        // An update landed: the new server may support what the old one didn't (folders,
        // avatars, …). Ask it again instead of keeping the old answer for this home's life.
        .onChange(of: serverUpdate?.completedUpdates ?? 0) { _, _ in
            checkedSessionTransferCapability = false
            Task { await load() }
        }
    }

    /// The herdr update for this machine (herdrup#565), kept across reconnects by host and
    /// session, since an update's handoff drops the connection this home was built on. A guest
    /// never gets here (`GuestHomeView`), and a non-owner is refused by the server.
    private func attachServerUpdate() {
        let key = "\(hostKey)#\(session ?? "")"
        #if DEBUG
        // Screenshot fixtures are drawn without the card, except the update mock's.
        if let mock = ScreenshotMock.mode {
            guard mock == .serverUpdate else { return }
            if serverUpdate == nil { ServerUpdateModel.reset(host: key) }
            let model = ServerUpdateModel.forHost(key, displayName: host)
            model.follower = ServerUpdateMock.follower
            serverUpdate = model
            model.attach(client: client)
            return
        }
        #endif
        let model = ServerUpdateModel.forHost(key, displayName: host)
        serverUpdate = model
        model.attach(client: client)
    }

    /// The Settings tab's "1": a herdr update to look at.
    private var settingsBadge: Int { serverUpdate?.showsBadge == true ? 1 : 0 }

    /// The Agents tab: the app-drawn header plus the agents list (or the first-load
    /// spinner / error). It carries the connect lifecycle — load, fork-probe, the
    /// first-run gestures tutorial, and the push deep-link hooks. Terminal is not a
    /// tab; it fronts a keep-mounted pane over the whole TabView.
    /// The per-agent action presenters — the Restart / Swap-subscription confirmation dialogs and the
    /// Rename sheet — applied to BOTH `agentsTab` (iPhone) and `iPadLayout` (iPad/Mac). The shared
    /// `agentList` context menus set `restartCandidate` / `swapCandidate` / `renameTarget`; these
    /// presenters used to live only on the iPhone tab, so on iPad and Mac the menu actions set state
    /// nothing observed and rename/restart/swap were silent no-ops.
    @ViewBuilder
    private func agentActions<Content: View>(_ content: Content) -> some View {
        folderActions(content)
            .confirmationDialog(
                "Restart agent?",
                isPresented: $restartCandidate.isPresent(),
                presenting: restartCandidate
            ) { row in
                Button("Restart", role: .destructive) {
                    let target = row.info.paneID
                    let title = row.title
                    Task {
                        await perform(verb: "restart", title: title) {
                            try await client.restartAgent(target: target)
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { row in
                Text(
                    "Interrupts \(row.title)'s current turn. Its session is preserved and reopened with --resume."
                )
            }
            .confirmationDialog(
                "Swap subscription?",
                isPresented: $swapCandidate.isPresent(),
                presenting: swapCandidate
            ) { cand in
                Button("Swap", role: .destructive) {
                    let target = cand.row.info.paneID
                    let title = cand.row.title
                    let accountID = cand.account.id
                    Task {
                        await perform(verb: "swap", title: title) {
                            try await client.restartAgent(target: target, account: accountID)
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { cand in
                Text(
                    "Switches \(cand.row.title) to \(cand.account.label) and restarts it. This interrupts its current turn. The session is reopened with --resume on the new subscription."
                )
            }
            .sheet(item: $renameTarget) { target in
                renameSheet(for: target)
            }
            .sheet(item: $avatarRow) { row in
                AgentAvatarSheet(agent: row.info, name: row.title,
                                 badge: row.info.isUnreachable ? .offline : AgentAvatarBadge(row.group),
                                 badgeLabel: row.info.isUnreachable ? "offline" : row.group.label)
            }
            .sheet(item: $transferCandidate) { candidate in
                AgentSessionTransferSheet(
                    client: client,
                    agent: candidate.row.info,
                    title: candidate.row.title,
                    source: candidate.source,
                    target: candidate.target,
                    accounts: accounts,
                    onRefresh: { Task { await load() } }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
    }

    /// The folder prompts (#552), on both layouts like `agentActions`: the swipe's "Move to
    /// folder" choices, the folder-name field (a new folder, or a rename), and a save that
    /// failed.
    private func folderActions<Content: View>(_ content: Content) -> some View {
        content
            .confirmationDialog("Move to folder", isPresented: $moveCandidate.isPresent(),
                                presenting: moveCandidate) { row in
                moveDialogButtons(row)
            } message: { row in
                Text("Move \(row.title) to a folder")
            }
            .alert(folderNamingTitle, isPresented: $folderNaming.isPresent(), presenting: folderNaming) { naming in
                TextField("Folder name", text: $folderNameText)
                    .accessibilityIdentifier("folder-name-field")
                Button("Cancel", role: .cancel) {}
                Button(folderNamingConfirm(naming)) { commitFolderName(naming) }
            }
            .alert("Couldn't save folders", isPresented: $groups.error.isPresent(),
                   presenting: groups.error) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
    }

    private var folderNamingTitle: String {
        if case .rename = folderNaming { return "Rename folder" }
        return "New folder"
    }

    private func folderNamingConfirm(_ naming: FolderNaming) -> String {
        if case .rename = naming { return "Rename" }
        return "Create"
    }

    private var agentsTab: some View {
        NavigationStack {
            ZStack {
                Palette.ground.ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    if let error {
                        errorView(error)
                    } else if loading && agents.isEmpty {
                        // Spinner ONLY on a genuine first load (or after reconnect clears
                        // `agents`). A re-entry with data in hand refreshes silently rather
                        // than blanking the still-valid list to a spinner.
                        Spacer(); ProgressView().tint(Palette.textDim); Spacer()
                    } else {
                        agentList
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    /// The rename form for an agent or a terminal. Agent names are coerced to the server grammar
    /// (`AgentName.normalize`) and set daemon-side (`agent.rename`) so they resolve as mention
    /// targets; the list refreshes via `load()`. Terminal names are free-form and dual-written —
    /// `pane.rename` (daemon label, visible in `herdr pane list`) plus the app-local row label.
    @ViewBuilder
    private func renameSheet(for target: RenameTarget) -> some View {
        switch target {
        case .agent(let row):
            RenameSheet(
                title: "Rename agent",
                fieldLabel: "AGENT NAME",
                placeholder: "e.g. planner",
                current: row.info.name ?? "",
                footnote: "Lowercase letters, digits, - and _. Another agent can then read this one by name.",
                normalize: AgentName.normalize
            ) { newName in
                let paneID = row.info.paneID
                let title = row.title
                Task {
                    await perform(verb: "rename", title: title) {
                        try await client.renameAgent(target: paneID, name: newName)
                    }
                    // The server moved its folder membership and star to the new name.
                    await groups.refresh(force: true)
                }
            }
        case .terminal(let terminal):
            RenameSheet(
                title: "Rename terminal",
                fieldLabel: "TERMINAL NAME",
                placeholder: "e.g. build logs",
                current: terminal.label,
                footnote: "Shows in herdr pane list, so you can tell an agent to check this terminal by name.",
                normalize: { $0 }
            ) { newLabel in
                let paneID = terminal.paneID
                let id = terminal.id
                Task {
                    do {
                        try await client.renamePane(paneID: paneID, label: newLabel)
                        terminalsStore.rename(id, to: newLabel, host: hostKey)
                    } catch let e {
                        error = "couldn't rename terminal: \(e)"
                    }
                }
            }
        }
    }

    // MARK: chrome

    /// One bar on every device: a small centred "Agents" title, Back and the New terminal /
    /// New agent actions. Back sits on the left on iPhone, Mac and a full-screen iPad; in an
    /// iPad window the system window controls take the left corner, so it joins the
    /// right-hand capsule (`SectionBackSlot`). The old "N need you" subtitle is gone: the
    /// rows' amber marks and the minimised rail's counts carry it.
    private var header: some View {
        SectionTopBar(title: "Agents", leading: {
            SectionBackSlot(.leading) { sectionBackButton }
        }) {
            if hSizeClass == .regular { hideSidebarButton }
            SectionBackSlot(.trailing) { sectionBackButton }
            // A plain shell terminal: a small icon so agents stay the priority (the
            // re-entry guard in createTerminal absorbs an eager double-tap).
            SectionBarButton(icon: "terminal", label: "New terminal") {
                Task { await createTerminal() }
            }
            SectionBarButton(icon: "plus", label: "New agent") { activeCover = .newAgent }
        }
    }

    private var sectionBackButton: some View {
        SectionBarButton(icon: "chevron.left", label: "Back",
                         identifier: "agents-back", action: onDisconnect)
    }

    /// The top of the roster's scroll content: the search field and session pills, which
    /// scroll away with the list.
    private var rosterTitleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 0) {
                searchField
                if runningSessions.count >= 2 {
                    SessionPills(
                        sessions: runningSessions,
                        current: session,
                        needsYou: sessionNeedsYou,
                        onSelect: { onSwitchSession($0.default ? nil : $0.name) }
                    )
                    .padding(.top, 4).padding(.bottom, 6)
                }
            }
        }
    }

    /// Agents that need you in each running session, for the pills: this session's count
    /// is the live roster's; the others come from `watchSessions`' periodic peek.
    private var sessionNeedsYou: [String: Int] {
        var counts = otherSessionsNeedYou
        if let here = runningSessions.first(where: { $0.default ? (session ?? "default") == "default" : $0.name == session }) {
            counts[here.name] = fullList.needsYouCount
        }
        return counts
    }

    /// Keeps the session pills current (#347): the machine's running herdr sessions and how
    /// many agents need you in each of the others, every 15 s. A machine whose herdr has no
    /// sessions (or a failed listing) shows no pills. If the session this home is on is no
    /// longer running (stopped since it was remembered), it moves back to the default one.
    @MainActor
    private func watchSessions() async {
        while !Task.isCancelled {
            if let listed = try? await client.listSessions() {
                let running = listed.filter(\.running)
                if let session, session != "default", !running.contains(where: { $0.name == session }) {
                    onSwitchSession(nil)
                    return
                }
                runningSessions = running
                sessionCache?.setRunningSessions(running)
                var counts: [String: Int] = [:]
                if running.count >= 2 {
                    for other in running where (other.default ? "default" : other.name) != (session ?? "default") {
                        let otherSession = other.default ? nil : other.name
                        if let agents = try? await client.agentList(inSession: otherSession) {
                            counts[other.name] = AgentList(agents: agents).needsYouCount
                            sessionCache?.store(agents, session: otherSession)
                        }
                    }
                }
                otherSessionsNeedYou = counts
            } else {
                runningSessions = []
            }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
        }
    }

    /// After a session switch (#386), start from what the app already knows instead of an
    /// empty screen: the running sessions (so the pills don't vanish and reappear), their
    /// needs-you counts, and this session's agents if seen in the last minute. The first
    /// load replaces all of it. Never overwrites a list a load has already published.
    private func seedFromSessionCache() {
        guard let sessionCache else { return }
        if runningSessions.isEmpty, !sessionCache.runningSessions.isEmpty {
            runningSessions = sessionCache.runningSessions
            var counts: [String: Int] = [:]
            for other in runningSessions where (other.default ? "default" : other.name) != (session ?? "default") {
                if let agents = sessionCache.roster(for: other.default ? nil : other.name) {
                    counts[other.name] = AgentList(agents: agents).needsYouCount
                }
            }
            otherSessionsNeedYou = counts
        }
        if agents.isEmpty, let cached = sessionCache.roster(for: session) {
            receiveRoster(agents: cached, accounts: [])
        }
    }

    /// The agent search: a plain text field with Clear once there is text. No mic: the
    /// owner found dictating a name to filter the list useless.
    private var searchField: some View {
        sidebarSearchField(text: $search, focus: $searchFocused, identifier: "agent-search")
    }

    /// A sidebar search field: magnifier, text, and Clear once there is text. Shared by the
    /// agents list and Gram's sidebar. Deliberately no mic on either (owner rule): dictating a
    /// filter was useless, and the Gram composer below keeps dictation where it helps.
    /// `outlined` adds the 1 pt hairline the Gram design draws around its field.
    private func sidebarSearchField(text: Binding<String>, focus: FocusState<Bool>.Binding,
                                    identifier: String, height: CGFloat = DesignTokens.Size.searchField,
                                    outlined: Bool = false) -> some View {
        HStack(spacing: DesignTokens.Space.stackSmall) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.textDim)
                .accessibilityHidden(true)
            TextField("Search", text: text)
                .font(Typography.app(DesignTokens.Text.Search.size, DesignTokens.Text.Search.weight))
                .foregroundStyle(Palette.text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused(focus)
                .accessibilityIdentifier(identifier)
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.textFaint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface)
        .clipShape(Capsule())
        .overlay {
            if outlined { Capsule().strokeBorder(Palette.hairline, lineWidth: DesignTokens.Size.hairline) }
        }
        .padding(.horizontal, DesignTokens.Space.screenInset).padding(.bottom, 6)
    }

    // MARK: list

    private var agentList: some View {
        agentRosterScroll
    }

    /// macOS runs this iOS target through UIKit's Designed-for-iPad compatibility
    /// runtime. Mutating a lazy stack's sections during momentum scrolling could pin
    /// SwiftUI's main thread, so Mac alone uses an eager stack. Native iPhone/iPad keep
    /// lazy rows so large herds do not build every card and status badge off-screen.
    private var agentRosterScroll: some View {
        agentRosterScrollContent
            .onDisappear { setAgentListScrolling(false) }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { setAgentListScrolling(false) }
            }
    }

    private var agentRosterScrollContent: some View {
        ScrollView {
            agentRosterStack
                .coordinateSpace(name: agentRosterContentSpace)
                .background {
                    ScrollActivityObserver(
                        isEnabled: agentRosterIsVisible,
                        onChange: setAgentListScrolling,
                        onSample: { scrollView in
                            needsYouSight.sample(scrollView)
                            rowSwipes.attach(scrollView)
                        }
                    )
                }
        }
        .accessibilityIdentifier("agent-roster-scroll")
        // Keep the complete displayed population available to VoiceOver and UI
        // receipts. Unlike counting row Buttons, this includes collapsed sections.
        .accessibilityValue("\(fullList.rows.count) agents")
        .onChange(of: displayedRoster) { _, _ in
            onAgentListDisplayedRosterChange?(rosterScroll.isScrolling)
        }
        // A covered or hidden roster keeps its rows built; their working rings must not
        // keep turning behind the pane or another tab.
        .environment(\.statusMotion, agentRosterIsVisible && Self.rosterStatusMayMove)
        // Pinned under the top bar (the sidebar's top on iPad and Mac). An overlay, so it
        // never takes part in the list's layout. Hidden while searching: the filtered list
        // may not show the waiting rows at all.
        .overlay(alignment: .top) {
            NeedsYouPill(
                sight: needsYouSight,
                waiting: search.isEmpty ? fullList.rows.filter { $0.group == .needsYou } : [],
                onScrollToTop: { needsYouSight.scrollToTop() },
                onOpen: { row in
                    open(PaneSlot(paneID: row.info.paneID, title: row.title, agent: row.info,
                                  initialReply: "", siblings: orderedSiblings))
                }
            )
        }
        // The one-time GitHub star bar, floating over the bottom of the roster: just above
        // the tab bar on iPhone, above the sidebar's section bar on iPad. It covers the list
        // rather than moving it; the margin lets the last row scroll clear of it.
        .contentMargins(.bottom, showStarPrompt ? starPromptHeight + Self.starPromptBottomGap + 12 : 0,
                        for: .scrollContent)
        .overlay(alignment: .bottom) {
            if showStarPrompt {
                GitHubStarPromptCard(
                    onStar: {
                        starPromptAnswered = true
                        openURL(GitHubStarPrompt.repositoryURL)
                    },
                    onNotNow: { starPromptAnswered = true })
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { starPromptHeight = $0 }
                    .padding(.horizontal, 16)
                    .padding(.bottom, Self.starPromptBottomGap)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: showStarPrompt)
    }

    private static let starPromptBottomGap: CGFloat = 12

    /// Whether to show the one-time GitHub star bar: after `GitHubStarPrompt.threshold` owner
    /// prompts, until Star or × answers it. Only the owner's home draws it, so guests never
    /// see it (their home is `GuestHomeView`, and their sends never reach `submitPrompt`).
    private var showStarPrompt: Bool {
        // Screenshot mocks and UI tests keep their pixels unless they opt in.
        #if DEBUG
        if ScreenshotMock.mode != nil, !GitHubStarPrompt.mockShowsCard(ProcessInfo.processInfo.environment) {
            return false
        }
        #endif
        return GitHubStarPrompt.isDue(sentPrompts: starPromptSends, answered: starPromptAnswered)
    }

    /// Compact layouts cover the roster when a terminal is fronted. Regular layouts
    /// keep it beside the terminal unless the user minimises the sidebar.
    private var agentRosterIsVisible: Bool {
        guard selectedTab == .agents, scenePhase == .active else { return false }
        if hSizeClass == .regular {
            return columnVisibility != .detailOnly
        }
        return frontID == nil
    }

    /// The roster's "now", behind every row's time-in-state age (`compactTimeInState` in
    /// `card`), the only relative time the list and sidebar draw. In DEBUG a screenshot
    /// mock may pin it with `HERDR_MOCK_NOW` (`MockClock`), so an age reads the same on
    /// every run.
    static func rosterClockNow() -> Date {
        #if DEBUG
        if let pinned = MockClock.pinned { return pinned }
        #endif
        return Date()
    }

    /// Whether the roster's working rings may turn at all. False only in the DEBUG
    /// `desktopref` mock, whose reference screenshots need the ring at rest.
    private static var rosterStatusMayMove: Bool {
        #if DEBUG
        return !DesktopReferenceMock.holdsStill
        #else
        return true
        #endif
    }

    /// Eager on the Mac (see `agentRosterScroll`), and wherever the list shows folders (#552).
    /// With folders, the lazy stack's first vertical scroll never settled: the main thread
    /// spun in SwiftUI's lazy placement (LazySubviewPlacements / LazyStack.place) for good and
    /// the app never went idle (CI runs 40538770025 and 40545816526, sampled). Run 40550430715
    /// narrowed it: the folders list hung lazy with or without swipe actions, and answered in
    /// 4 s eager. The stack's children are whole sections (each an eager VStack of its rows),
    /// so being lazy only ever skipped building an off-screen section; RosterStress scrolls an
    /// 80-agent roster eagerly.
    @ViewBuilder
    private var agentRosterStack: some View {
        if ProcessInfo.processInfo.isiOSAppOnMac || forceEagerAgentRosterStack || groups.document != nil {
            VStack(alignment: .leading, spacing: 0) {
                rosterTitleBlock
                agentRosterRows
            }
            .onAppear { onEagerAgentRosterStackAppear?() }
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                rosterTitleBlock
                agentRosterRows
            }
        }
    }

    @ViewBuilder
    private var agentRosterRows: some View {
        if agents.isEmpty {
            emptyLine("no agents")
        } else if visibleSections.isEmpty {
            // Agents exist but the search matched none — say so, rather
            // than leave a blank scroll that reads as "no agents".
            emptyLine("no matches")
        } else {
            let layout = rosterLayout
            let aboveOpen = itemAboveOpenRow(layout.sections)
            ForEach(layout.sections, id: \.group) { section in
                // The needs-you pill (#551) counts every waiting agent, those inside a closed
                // folder too; the folder row sits in this section, so the section's sight
                // still says whether anything waiting is on screen.
                if section.group == .needsYou && search.isEmpty {
                    sectionView(section, aboveOpen: aboveOpen)
                        .reportsWaitingRowsBottom(to: needsYouSight)
                } else {
                    sectionView(section, aboveOpen: aboveOpen)
                }
            }
            // Folders with none of their agents here, so they can still be renamed or deleted.
            if search.isEmpty && !layout.emptyFolders.isEmpty {
                emptyFoldersSection(layout.emptyFolders, aboveOpen: aboveOpen)
            }
        }
        // Archived agents sit below the live herd (above terminals) and only
        // when there are some. Hidden during a search (that filters live agents).
        if search.isEmpty && !fullList.archived.isEmpty {
            archivedSection
        }
        // Terminals sit BELOW the herd and only when you have some — agents
        // are the priority. Open one from the header's terminal button.
        // Hidden during an agent search (that filters agents, not shells).
        if search.isEmpty && !terminalsStore.terminals(host: hostKey).isEmpty {
            terminalsSection
        }
    }

    @MainActor
    private func rosterRefreshState() -> AgentRosterRefreshState {
        AgentRosterRefreshState(
            displayed: displayedRoster,
            pending: pendingRoster.snapshot,
            isScrolling: rosterScroll.isScrolling
        )
    }

    @MainActor
    private func armAgentListScrollRecovery() {
        let buffer = rosterScroll
        buffer.recoveryTask?.cancel()
        buffer.recoveryTask = Task { @MainActor [weak buffer] in
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                return
            }
            guard buffer?.isScrolling == true else { return }
            // A missing framework idle transition must degrade to one delayed roster
            // promotion, never permanent suppression of every future refresh.
            setAgentListScrolling(false)
        }
    }

    @MainActor
    private func setAgentListScrolling(_ scrolling: Bool) {
        if scrolling {
            armAgentListScrollRecovery()
        } else {
            rosterScroll.recoveryTask?.cancel()
            rosterScroll.recoveryTask = nil
        }
        let current = rosterRefreshState()
        let next = current.settingScrolling(scrolling)
        guard next != current else { return }
        pendingRoster.snapshot = next.pending
        if next.displayed != displayedRoster { displayedRoster = next.displayed }
        rosterScroll.isScrolling = next.isScrolling
        if !next.isScrolling {
            rosterNow = Self.rosterClockNow()
            updateLiveAgentBookkeeping()
        }
        onAgentListScrollPhaseChange?(next.isScrolling)
    }

    /// Publish one internally-consistent roster, or coalesce it into the
    /// non-observable scroll-time buffer. Equality gating inside the pure state
    /// transform means an unchanged response performs no SwiftUI state write.
    @MainActor
    private func receiveRoster(agents: [AgentInfo], accounts: [CredentialAccount]) {
        let snapshot = AgentRosterSnapshot(
            agents: agents,
            accounts: accounts,
            livePaneIDs: livePaneIDs
        )
        let current = rosterRefreshState()
        let next = current.receiving(snapshot)
        pendingRoster.snapshot = next.pending
        if next.displayed != displayedRoster { displayedRoster = next.displayed }
        let now = Self.rosterClockNow()
        if !rosterScroll.isScrolling,
           now.timeIntervalSince(rosterNow) >= 5 {
            rosterNow = now
        }
    }

    /// Clear a recovered load's error flags without assigning identical `@State`
    /// values on every poll. Those no-op writes still invalidate SwiftUI and can force
    /// the eager Mac roster through layout during a gesture.
    @MainActor
    private func clearSuccessfulLoadState() {
        if error != nil { error = nil }
        if rejectedFingerprint != nil { rejectedFingerprint = nil }
        if trustFailed { trustFailed = false }
        if herdrMissing { herdrMissing = false }
        if herdrIncompatibleBuild { herdrIncompatibleBuild = false }
        if unavailableDaemonHost != nil { unavailableDaemonHost = nil }
        if loading { loading = false }
    }

    /// Reconcile pane liveness only against the roster that is actually displayed.
    /// A scroll-time fetch stays entirely in the non-observable pending buffer, so a
    /// newly-added or removed pane cannot invalidate the list before idle promotion.
    @MainActor
    private func updateLiveAgentBookkeeping() {
        guard !rosterScroll.isScrolling else { return }
        let live = Set(displayedRoster.agents.map(\.paneID))
        if !live.isSubset(of: everLive) {
            everLive.formUnion(live)
        }
        let retainedSlots = slots.filter {
            $0.paneID == frontID || !everLive.contains($0.paneID) || live.contains($0.paneID)
        }
        if retainedSlots.count != slots.count {
            slots = retainedSlots
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text).font(Typography.app(DesignTokens.Text.Empty.size, DesignTokens.Text.Empty.weight))
            .foregroundStyle(Palette.textDim)
            .frame(maxWidth: .infinity).padding(.top, 44)
    }

    // MARK: terminals

    /// The Terminals section: the user's opened shell panes (each reopens its live PTY). Shown
    /// below the agents and only when non-empty, so agents stay the priority. Open a new one
    /// from the header's terminal button; long-press a row to close it.
    private var terminalsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                terminalsCollapsed.toggle()
            } label: {
                HStack(spacing: 8) {
                    // Count shown when collapsed (so the tally is legible while shut);
                    // expanded, the rows speak for themselves.
                    Text(terminalsCollapsed
                        ? "TERMINALS · \(terminalsStore.terminals(host: hostKey).count)" : "TERMINALS")
                        .font(Typography.microLabel).tracking(DesignTokens.Text.MicroLabel.tracking)
                        .foregroundStyle(Palette.textFaint)
                    Image(systemName: terminalsCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.textFaint)
                    Rectangle().fill(Palette.hairline).frame(height: DesignTokens.Size.hairline)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, DesignTokens.Space.screenInset).padding(.top, 10)

            if !terminalsCollapsed {
                ForEach(terminalsStore.terminals(host: hostKey)) { terminal in
                    Button {
                        open(PaneSlot(paneID: terminal.paneID, title: terminal.label, agent: nil,
                                      initialReply: "", siblings: []))
                    } label: {
                        terminalCard(terminal)
                    }
                    .buttonStyle(.plain)
                    // Items only write state (see `menuAction`); never rebuilt while open
                    // (StableContextMenu.swift).
                    .stableContextMenu {
                        // Rename = set the pane's daemon `label` (shown in `herdr pane list`) so you
                        // can tell an agent to check this terminal by name, + the app-local row label.
                        StableMenuItem("Rename", systemImage: "pencil") {
                            renameTarget = .terminal(terminal)
                        }
                        StableMenuItem("Close terminal", systemImage: "xmark.circle", role: .destructive) {
                            menuAction = .closeTerminal(terminal)
                        }
                    }
                }
            }
        }
    }

    // MARK: archived

    /// The Archived section (issue #173): agents whose pane was released but whose
    /// session the daemon preserved, so they can be resumed. Collapsed by default and
    /// pinned at the bottom (below agents, above terminals) — an archived agent needs
    /// nothing from you. Structurally mirrors `terminalsSection`. Long-press a row to
    /// Unarchive (resume it into a fresh pane). Archived rows are NOT tappable to a
    /// terminal — there is no live pane to open.
    private var archivedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // #352: a plain list row ("Archived  1 ›") at the end of the roster, not a header.
            disclosureRow("Archived", count: fullList.archived.count, open: !archivedCollapsed) {
                archivedCollapsed.toggle()
            }

            if !archivedCollapsed {
                ForEach(fullList.archived) { row in
                    archivedCard(row)
                        // Items only write state (see `menuAction`); never rebuilt while open
                        // (StableContextMenu.swift).
                        .stableContextMenu {
                            StableMenuItem("Unarchive", systemImage: "arrow.uturn.up") {
                                menuAction = .unarchive(row)
                            }
                            if forgetSupported {
                                StableMenuItem("Close", systemImage: "xmark", role: .destructive) {
                                    forgetCandidate = row
                                }
                            }
                        }
                }
            }
        }
        .confirmationDialog(
            forgetCandidate.map { "Close \($0.title)?" } ?? "Close?",
            isPresented: $forgetCandidate.isPresent(),
            titleVisibility: .visible,
            presenting: forgetCandidate
        ) { row in
            Button("Close", role: .destructive) {
                let archived = row.info
                let title = row.title
                Task {
                    await perform(verb: "close", title: title) {
                        try await client.forgetAgent(archived)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It leaves the Archived list. Its transcript stays on the machine.")
        }
    }

    /// The unarchive target: an archived agent's pane id is released, so resolve it by
    /// name, falling back to the terminal id, then pane id.
    private func unarchiveTarget(_ info: AgentInfo) -> String {
        info.name ?? info.terminalID ?? info.paneID
    }

    /// A dimmed agent card for the Archived section: same shape as `card`, an archive
    /// glyph instead of the live status badge, and provenance ("archived by X · reason")
    /// as the subtitle.
    private func archivedCard(_ row: AgentRow) -> some View {
        HStack(spacing: DesignTokens.Space.stackLarge) {
            ZStack {
                AgentAvatarView(agent: row.info, name: row.title, size: 40, glyphSize: 17)
                    .opacity(0.5)
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(Typography.app(DesignTokens.Text.CardTitle.size, DesignTokens.Text.CardTitle.weight))
                    .foregroundStyle(Palette.textDim)
                Text(archivedSubtitle(row.info))
                    .font(Typography.machine(DesignTokens.Text.CardSubtitle.size, DesignTokens.Text.CardSubtitle.weight))
                    .foregroundStyle(Palette.textFaint).lineLimit(1)
            }
            Spacer(minLength: DesignTokens.Space.stackMedium)
        }
        .padding(DesignTokens.Space.stackLarge)
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
            .stroke(Palette.hairline, lineWidth: DesignTokens.Size.hairline))
        .padding(.horizontal, DesignTokens.Space.screenInset).padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// "archived by X · reason" from the `archived` provenance block; degrades to
    /// "archived" when the daemon didn't record a `by`.
    private func archivedSubtitle(_ info: AgentInfo) -> String {
        let by = (info.archived?.by).map { "archived by \($0)" } ?? "archived"
        if let reason = info.archived?.reason, !reason.isEmpty { return "\(by) · \(reason)" }
        return by
    }

    private func terminalCard(_ terminal: SavedTerminal) -> some View {
        HStack(spacing: DesignTokens.Space.stackLarge) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.tile).fill(Palette.surfaceRaised)
                    .frame(width: 40, height: 40)
                Image(systemName: "terminal")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.textDim)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(terminal.label)
                    .font(Typography.app(DesignTokens.Text.CardTitle.size, DesignTokens.Text.CardTitle.weight))
                    .foregroundStyle(Palette.text)
                Text("shell")
                    .font(Typography.machine(DesignTokens.Text.CardSubtitle.size, DesignTokens.Text.CardSubtitle.weight))
                    .foregroundStyle(Palette.textFaint)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.textFaint)
        }
        .padding(.horizontal, DesignTokens.Space.screenInset).padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// Reopen a durable transaction from its recorded target even while the row's
    /// detected agent is nil or already changed. Without a transaction, only exact
    /// native harness kinds participate; guessing would offer a transfer the server
    /// must refuse.
    private func sessionTransferSource(for info: AgentInfo) -> AgentSessionTransferHarness? {
        if let activeTransfer = info.sessionTransfer,
           !activeTransfer.phase.isConclusive {
            return activeTransfer.source
        }
        switch info.agent?.lowercased() {
        case "claude": return .claude
        case "codex": return .codex
        case "omp": return .omp
        default: return nil
        }
    }

    private func sessionTransferTargets(for info: AgentInfo) -> [AgentSessionTransferHarness] {
        if let activeTransfer = info.sessionTransfer,
           !activeTransfer.phase.isConclusive {
            return [activeTransfer.target]
        }
        guard let source = sessionTransferSource(for: info),
              sessionTransferHarnesses.contains(source) else { return [] }
        return [AgentSessionTransferHarness.claude, .codex, .omp].filter {
            $0 != source && sessionTransferHarnesses.contains($0)
        }
    }

    private func sectionView(_ section: AgentFolderLayout.Section, aboveOpen: String?) -> some View {
        let group = section.group
        // An active search overrides collapse — a match inside IDLE must not stay
        // hidden behind a shut section the user did not open.
        let isCollapsed = search.isEmpty && collapsed.contains(group)
        // Compute the paging list once per section, not inside the per-row button closure
        // (which SwiftUI evaluates eagerly for every row). `orderedSiblings` now filters
        // the cached roster list and performs no sorting.
        let siblings = orderedSiblings
        return VStack(alignment: .leading, spacing: 0) {
            // #352: no section headers. Needs you, working and stopped rows follow each
            // other in that order; a collapsible group (Idle) is one plain row at the end
            // ("Idle  4 ›") that opens its rows underneath. An active search shows the rows
            // without the disclosure, as before. The count includes the agents in its folders.
            if group.startsCollapsed && search.isEmpty {
                disclosureRow(group.sectionTitle.capitalized, count: section.agentCount, open: !isCollapsed,
                              separator: aboveOpen != Self.disclosureKey(group)) {
                    if isCollapsed { collapsed.remove(group) } else { collapsed.insert(group) }
                }
            }

            if !isCollapsed {
                let reveal = AgentFolderMotion.revealPositions(section.items, folderID: folderReveal)
                ForEach(section.items) { item in
                    switch item {
                    case let .agent(row, starred, folderID):
                        agentRowButton(row, starred: starred, indented: folderID != nil,
                                       aboveOpen: aboveOpen, siblings: siblings)
                            .transition(folderID == nil ? .opacity
                                        : AgentFolderMotion.memberTransition(revealPosition: reveal[item.id],
                                                                             reduceMotion: reduceMotion))
                    case let .folder(summary):
                        folderRow(summary, aboveOpen: aboveOpen)
                    }
                }
            }
        }
    }

    /// One agent in the list: tap opens its pane, swipe right stars it or moves it to a
    /// folder (#552), long-press offers every quick action.
    private func agentRowButton(_ row: AgentRow, starred: Bool, indented: Bool,
                                aboveOpen: String?, siblings: [AgentInfo]) -> some View {
        Button {
            open(PaneSlot(paneID: row.info.paneID, title: row.title,
                          agent: row.info, initialReply: "", siblings: siblings))
        } label: {
            card(row, separator: aboveOpen != row.info.paneID, starred: starred, indented: indented)
        }
        .buttonStyle(.plain)
        // Over the sidebar on iPad / Mac, the hovered agent speaks in the empty
        // detail column's glyph field. No state changes here.
        .onContinuousHover(coordinateSpace: .global) { phase in
            switch phase {
            case .active(let location):
                glyphFieldSpotlight.hover(glyphFieldLine(row), globalY: location.y)
            case .ended:
                glyphFieldSpotlight.end(row.id)
            }
        }
        // Bind UI receipts to the tappable row, not a Text child whose
        // `isHittable` is false because the parent Button owns the hit.
        .accessibilityIdentifier("agent-row-\(row.info.paneID)")
        // VoiceOver should expose the same status section that visually
        // classifies this agent. The scroll receipt also uses this value
        // to prove an existing row moved, independently of row count.
        .accessibilityValue(row.group.label)
        // Long-press an agent → quick actions. Items only write state (see
        // `menuAction`); never rebuilt while open (StableContextMenu.swift).
        .stableContextMenu {
            // Stop = close the pane (`pane.close`, the only stop RPC — its
            // inverse is start), then reload.
            StableMenuItem("Stop agent", systemImage: "stop.circle", role: .destructive) {
                menuAction = .stop(row)
            }
            // Rename = set the agent's daemon `name`, which becomes a resolvable
            // mention target (another agent can `herdr agent read <name>`).
            StableMenuItem("Rename", systemImage: "pencil") {
                renameTarget = .agent(row)
            }
            // Avatar… = pick this agent's mascot or photo (herdrup#538). Owner
            // only, on a daemon that stores avatars.
            if avatars.canEdit {
                StableMenuItem("Avatar…", systemImage: "person.crop.circle") {
                    avatarRow = row
                }
            }
            // Star and Move to folder (#552): the swipe's choices, on a server
            // with folders.
            if let name = row.info.name, let document = groups.document {
                StableMenuItem(starred ? "Unstar" : "Star", systemImage: starred ? "star.slash" : "star") {
                    groups.apply(.setStar(name, !starred))
                }
                StableMenuItem(submenu: "Move to folder", systemImage: "folder") {
                    folderMenuItems(for: name, in: document)
                }
            }
            // Restart = close the agent's session and reopen it with
            // --resume in place (keeps the pane). It interrupts a busy
            // agent's turn, so it routes through a confirmation.
            StableMenuItem("Restart agent", systemImage: "arrow.clockwise") {
                restartCandidate = row
            }
            // Harness transfer is deliberately not a restart shortcut. It
            // first builds and verifies a native destination transcript,
            // then opens a review sheet whose explicit confirm performs the
            // cutover. Local-only: the server denies filesystem-authority
            // transfer requests over federation.
            let transferTargets = sessionTransferTargets(for: row.info)
            let hasActiveTransfer = row.info.sessionTransfer
                .map { !$0.phase.isConclusive } ?? false
            if row.info.machineID == nil,
               (sessionTransferSupported || hasActiveTransfer),
               let source = sessionTransferSource(for: row.info),
               !transferTargets.isEmpty {
                StableMenuItem(
                    submenu: transferTargets.count == 1
                        ? "Switch to \(transferTargets[0].displayName)"
                        : "Switch harness",
                    systemImage: "arrow.left.arrow.right"
                ) {
                    for target in transferTargets {
                        StableMenuItem(target.displayName, systemImage: "arrow.right") {
                            transferCandidate = PendingHarnessTransfer(
                                row: row,
                                source: source,
                                target: target
                            )
                        }
                    }
                }
            }
            // Swap = restart the agent onto a DIFFERENT credential account
            // of the same kind (an agent runs only on its own kind's
            // subscriptions). Shown only when the daemon reported at least
            // one same-kind account. The list still INCLUDES the account the
            // agent is already on — swapping to it is a legitimate way to
            // restart — but that one is now marked, because the daemon reports
            // the current account (`account`) and the menu no longer has to
            // guess. Picking an account does NOT fire immediately: it stages a
            // confirmation (swapCandidate), because a swap is a full
            // turn-interrupting restart, and even swapping to the current
            // account restarts (interrupts) the agent rather than being a no-op.
            let swapTargets = accounts.filter { $0.kind == row.info.agent }
            if !swapTargets.isEmpty {
                StableMenuItem(submenu: "Swap subscription", systemImage: "arrow.left.arrow.right") {
                    for acct in swapTargets {
                        StableMenuItem(
                            acct.label
                                + (acct.id == row.info.account ? " (current)" : "")
                                + (acct.active ? "" : " (exhausted)"),
                            systemImage: acct.id == row.info.account
                                ? "person.crop.circle.fill"
                                : "person.crop.circle"
                        ) {
                            swapCandidate = PendingSwap(row: row, account: acct)
                        }
                    }
                }
            }
            // Archive = release the pane but PRESERVE the session so it can be
            // resumed later (`agent.archive`, issue #173). Reversible via the
            // Archived section's Unarchive, so it fires directly (no confirm).
            // The daemon REJECTS archiving a mid-turn agent unless forced, so a
            // working agent surfaces that error rather than being torn off a turn.
            StableMenuItem("Archive", systemImage: "archivebox") {
                menuAction = .archive(row)
            }
        }
        // Swipe right: Star / Unstar and Move to folder, on a server with folders.
        // Outermost, so the row's identifier and value stay on the row itself.
        .leadingSwipeActions(folderSwipeActions(row, starred: starred), id: row.id, in: rowSwipes)
    }

    // MARK: folders and stars (#552)

    /// The list's sections with folders and stars applied. With nothing from the server (an
    /// older server, a guest, or before the first read) it is the plain list. An active search
    /// shows a match inside a closed folder: every folder counts as open.
    private var rosterLayout: AgentFolderLayout {
        let open = search.isEmpty
            ? groups.openFolders
            : Set(groups.document?.folders.map(\.id) ?? [])
        return AgentFolderLayout(sections: visibleSections, groups: groups.document, openFolders: open)
    }

    /// A folder: tap opens or closes it in place (kept on this device), long-press renames,
    /// deletes or moves it.
    private func folderRow(_ summary: AgentFolderSummary, aboveOpen: String?) -> some View {
        let folder = summary.folder
        return Button {
            // Saved in this frame; the animation only draws the change.
            let opening = !summary.isOpen
            withAnimation(AgentFolderMotion.toggle(opening: opening, reduceMotion: reduceMotion),
                          completionCriteria: .logicallyComplete) {
                folderReveal = opening && AgentFolderMotion.reveals ? folder.id : nil
                groups.toggleOpen(folder.id)
            } completion: {
                if folderReveal == folder.id { folderReveal = nil }
            }
        } label: {
            AgentFolderRow(summary: summary, sidebar: hSizeClass == .regular,
                           separator: aboveOpen != Self.folderKey(folder.id))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("agent-folder-\(folder.id)")
        .accessibilityLabel("\(folder.name), \(summary.agentCountText), \(summary.summaryLine)")
        .accessibilityValue("\(summary.isOpen ? "expanded" : "collapsed"), \(summary.waitingCount) waiting, \(summary.stoppedCount) stopped")
        .stableContextMenu {
            if let document = groups.document {
                let ordered = document.orderedFolders
                StableMenuItem("Rename", systemImage: "pencil") {
                    folderNameText = folder.name
                    folderNaming = .rename(folder)
                }
                if ordered.first?.id != folder.id {
                    StableMenuItem("Move up", systemImage: "arrow.up") {
                        groups.apply(.moveFolder(folder.id, by: -1))
                    }
                }
                if ordered.last?.id != folder.id {
                    StableMenuItem("Move down", systemImage: "arrow.down") {
                        groups.apply(.moveFolder(folder.id, by: 1))
                    }
                }
                // The agents go back to the list; nothing about them changes.
                StableMenuItem("Delete folder", systemImage: "trash", role: .destructive) {
                    groups.apply(.deleteFolder(folder.id))
                }
            }
        }
    }

    /// Folders none of whose agents are in the list, after the live herd, so they can still be
    /// renamed or deleted.
    private func emptyFoldersSection(_ folders: [AgentFolderSummary], aboveOpen: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(folders, id: \.folder.id) { summary in
                folderRow(summary, aboveOpen: aboveOpen)
            }
        }
    }

    private static func folderKey(_ folderID: String) -> String { "folder:\(folderID)" }

    /// The swipe-right actions of an agent row: Star or Unstar, and Move to folder. None on a
    /// server without folders, and none for an agent with no name to file it under.
    private func folderSwipeActions(_ row: AgentRow, starred: Bool) -> [RowSwipeAction] {
        guard groups.document != nil, let name = row.info.name else { return [] }
        return [
            RowSwipeAction(title: starred ? "Unstar" : "Star",
                           systemImage: starred ? "star.slash.fill" : "star.fill",
                           tint: Palette.waiting, identifier: "agent-swipe-star") {
                groups.apply(.setStar(name, !starred))
            },
            RowSwipeAction(title: "Move", systemImage: "folder.fill", tint: Palette.brand,
                           identifier: "agent-swipe-move") {
                moveCandidate = row
            },
        ]
    }

    /// The long-press "Move to folder" submenu: every other folder, a new one, and out of the
    /// one it is in.
    @StableMenuBuilder
    private func folderMenuItems(for name: String, in document: AgentGroupsDocument) -> [StableMenuItem] {
        let current = document.folder(containing: name)
        for folder in document.orderedFolders.filter({ $0.id != current?.id }) {
            StableMenuItem(folder.name, systemImage: "folder") {
                groups.apply(.move(name, toFolder: folder.id))
            }
        }
        StableMenuItem("New folder…", systemImage: "folder.badge.plus") {
            beginNewFolder(member: name)
        }
        if let current {
            StableMenuItem("Remove from \(current.name)", systemImage: "folder.badge.minus") {
                groups.apply(.removeFromFolder(name))
            }
        }
    }

    /// The swipe's "Move" choices, as a confirmation dialog.
    @ViewBuilder
    private func moveDialogButtons(_ row: AgentRow) -> some View {
        if let name = row.info.name, let document = groups.document {
            let current = document.folder(containing: name)
            ForEach(document.orderedFolders.filter { $0.id != current?.id }) { folder in
                Button(folder.name) { groups.apply(.move(name, toFolder: folder.id)) }
            }
            Button("New folder…") { beginNewFolder(member: name) }
            if let current {
                Button("Remove from \(current.name)") { groups.apply(.removeFromFolder(name)) }
            }
        }
        Button("Cancel", role: .cancel) {}
    }

    private func beginNewFolder(member: String?) {
        folderNameText = ""
        folderNaming = .new(member: member)
    }

    private func commitFolderName(_ naming: FolderNaming) {
        switch naming {
        case .new(let member):
            groups.createFolder(named: folderNameText, member: member)
        case .rename(let folder):
            if let name = AgentGroupsDocument.folderName(folderNameText) {
                groups.apply(.renameFolder(folder.id, to: name))
            }
        }
    }

    /// A plain roster row that opens or closes a group (#352): label, count and a chevron,
    /// on the ground with an inset divider like the agent rows.
    private func disclosureRow(_ title: String, count: Int, open: Bool, separator: Bool = true,
                               _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Space.stackMedium) {
                Text(title)
                    .font(Typography.app(DesignTokens.Text.DisclosureTitle.size, DesignTokens.Text.DisclosureTitle.weight))
                    .foregroundStyle(Palette.text)
                Spacer(minLength: DesignTokens.Space.stackMedium)
                Text("\(count)")
                    .font(Typography.app(DesignTokens.Text.DisclosureCount.size, DesignTokens.Text.DisclosureCount.weight))
                    .foregroundStyle(Palette.textDim)
                    .monospacedDigit()
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.textFaint)
            }
            .padding(.leading, DesignTokens.Space.rowLead).padding(.trailing, DesignTokens.Space.rowTrail)
            .frame(minHeight: DesignTokens.Size.disclosureRow)
            .overlay(alignment: .bottom) {
                if separator {
                    Rectangle().fill(Palette.hairlineQuiet).frame(height: 1 / displayScale)
                        .padding(.leading, DesignTokens.Space.rowLead).padding(.trailing, DesignTokens.Space.rowTrail)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityValue(open ? "expanded" : "collapsed")
    }

    /// #352: a Messages-style row. Full width on the ground (no card), a 52 pt round avatar
    /// with the status as a small badge on it, the name over a two-line preview, and an inset
    /// divider. A waiting agent is marked by its "!" badge and a bright preview only; the old
    /// amber dot left of the avatar duplicated the badge and was removed at the owner's request.
    /// Every marker the card had stays: account, time in state, no account, stale, offline.
    /// `starred` draws the star after the name (#552); `indented` is an agent shown under its
    /// open folder.
    private func card(_ row: AgentRow, separator: Bool = true, starred: Bool = false,
                      indented: Bool = false) -> some View {
        // Fixed two-line rows; scale the text area with the app's text-size setting.
        // The selected sidebar row retains its rounded highlight.
        let sidebar = hSizeClass == .regular
        let avatar = sidebar ? DesignTokens.Size.avatarSidebar : DesignTokens.Size.avatarPhone
        let isOpen = sidebar && frontID == row.info.paneID
        let nameSize = sidebar ? DesignTokens.Text.RowName.size : DesignTokens.Text.RowNamePhone.size
        let nameWeight = sidebar ? DesignTokens.Text.RowName.weight : DesignTokens.Text.RowNamePhone.weight
        return HStack(alignment: .center, spacing: 0) {
            // The row's leading inset (where the needs-you dot used to sit).
            // An agent inside an open folder sits one step in, under the folder's picture.
            Color.clear.frame(width: indented ? DesignTokens.Space.rowLeadIndented : DesignTokens.Space.rowLead,
                              height: 1)
            AgentAvatar(name: row.title,
                        badge: row.info.isUnreachable ? .offline : AgentAvatarBadge(row.group),
                        badgeLabel: row.info.isUnreachable ? "offline" : row.group.label,
                        diameter: avatar,
                        glyphSize: sidebar ? DesignTokens.Size.avatarGlyphSidebar : DesignTokens.Size.avatarGlyphPhone,
                        info: row.info)
            .padding(.trailing, DesignTokens.Space.avatarGap)
            VStack(alignment: .leading, spacing: DesignTokens.Space.stackTight) {
                HStack(spacing: DesignTokens.Space.stackSmall) {
                    Text(row.title).font(.system(size: nameSize * Typography.scale, weight: nameWeight)).foregroundStyle(Palette.text)
                        .lineLimit(1)
                    if starred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.waiting)
                            .accessibilityLabel("starred")
                    }
                    rowMarkers(row)
                    Spacer(minLength: DesignTokens.Space.stackSmall)
                    // How long the agent has been in its current state ("5m/2h/3d"), derived
                    // from the daemon's status_since (#173). Absent on an older server / before
                    // the first transition — then nothing, never a wrong value. `rosterNow`
                    // is one shared clock advanced by successful idle polls, rather than a
                    // separate TimelineView and timer for every off-screen agent row.
                    if let age = compactTimeInState(
                        sinceUnixMs: row.info.statusSinceUnixMs,
                        nowUnixMs: UInt64(rosterNow.timeIntervalSince1970 * 1000)
                    ) {
                        Text(age)
                            .font(Typography.app(sidebar ? DesignTokens.Text.RowAge.size : DesignTokens.Text.RowAgePhone.size))
                            .foregroundStyle(Palette.textDim)
                            .monospacedDigit()
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textFaint)
                        .accessibilityHidden(true)
                }
                // The preview: what it is doing (folder · activity). A waiting agent's reads in
                // the primary colour, like an unread message.
                Text(subtitle(row.info))
                    .font(.system(size: (sidebar ? DesignTokens.Text.RowPreview.size
                                                 : DesignTokens.Text.RowPreviewPhone.size) * Typography.scale))
                    .foregroundStyle(row.group == .needsYou ? Palette.text : Palette.textDim)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                // Which account this agent is actually on. Shown only when the daemon
                // reports one, so an older server or a default-account agent renders
                // exactly as before rather than gaining an empty line.
                if let account = accountDisplayLabel(
                    accountID: row.info.account,
                    accounts: accounts
                ) {
                    Text(account)
                        .font(Typography.machine(DesignTokens.Text.AccountLabel.size))
                        .foregroundStyle(row.info.hasUnresolvedAccount ? Palette.died : Palette.textFaint)
                        .lineLimit(1)
                }
            }
            .padding(.trailing, DesignTokens.Space.rowTrail)
            .frame(maxWidth: .infinity)
            .frame(height: (sidebar ? DesignTokens.Size.agentRow : DesignTokens.Size.agentRowPhone) * max(1, Typography.scale),
                   alignment: .center)
            // The divider starts where the text starts, not under the avatar, and is one
            // device pixel. The open row's highlight replaces it, and the row above the open
            // row drops its own so no line touches the highlight.
            .overlay(alignment: .bottom) {
                if !isOpen && separator {
                    Rectangle().fill(Palette.hairline).frame(height: 1 / displayScale)
                        .padding(.trailing, DesignTokens.Space.rowTrail)
                }
            }
        }
        .background {
            if isOpen {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.selection).fill(Palette.surfaceRaised)
                    .padding(.horizontal, DesignTokens.Size.selectionInset)
            }
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }

    /// The no-account and stale pills, after the name.
    @ViewBuilder
    private func rowMarkers(_ row: AgentRow) -> some View {
            // The recorded account is gone from the registry, so this agent REFUSES to
            // resume rather than come back on the default account and write to the wrong
            // transcript. A person has to re-register the account, so it is a pill with
            // text, not a colour cue: shape and colour, never colour alone.
            if row.info.hasUnresolvedAccount {
                Text("no account")
                    .font(Typography.app(DesignTokens.Text.MarkerPill.size, DesignTokens.Text.MarkerPill.weight))
                    .foregroundStyle(Palette.died)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Palette.died.opacity(0.12)))
                    .overlay(Capsule().stroke(Palette.died.opacity(0.5), lineWidth: DesignTokens.Size.hairline))
            }
            // A DEGRADED peer (the daemon's 1 to 2 missed polls) still renders a live
            // status badge, and `resolvedGroup` can surface a LAST-KNOWN blocked row into
            // needs-you, so without a marker a stale guess reads exactly like a colleague
            // genuinely waiting. Mark the row instead of suppressing the badge: hiding the
            // needs-you signal would be the worse error of the two.
            if row.showsUnconfirmedMarker {
                Text("stale")
                    .font(Typography.app(DesignTokens.Text.MarkerPill.size, DesignTokens.Text.MarkerPill.weight))
                    .foregroundStyle(Palette.textDim)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Palette.textDim.opacity(0.12)))
                    // The LABEL is replaced for VoiceOver, so the visible word "stale" is no
                    // longer findable by label. Carry an explicit identifier as well, which is
                    // what the UI receipt asserts on. Without it the receipt failed on its
                    // first CI run looking for a label that the modifier above had overwritten.
                    .accessibilityIdentifier("agent-row-stale-marker")
                    .accessibilityLabel(Text("status not confirmed on the last poll"))
            }
    }

    /// "folder · activity": folder is the last path component of `cwd`, activity
    /// is the stripped terminal title. Either may be missing; the pane id is the
    /// last resort so a row is never subtitle-less.
    private func subtitle(_ info: AgentInfo) -> String {
        let folder = info.cwd
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty || $0 == "/" ? nil : $0 }
        switch (folder, info.activityText) {
        case let (f?, a?): return "\(f) · \(a)"
        case let (f?, nil): return f
        case let (nil, a?): return a
        case (nil, nil): return info.paneID
        }
    }

    // MARK: error / host-key recovery (functional, restyled to the tokens)

    @ViewBuilder
    private func errorView(_ error: String) -> some View {
        Spacer()
        VStack(spacing: 14) {
            // A connect that failed because herdr is not installed gets its OWN
            // recovery screen (heading + install command + instructions link),
            // not the raw stderr — a brand-new user has no way to read the shell
            // diagnostic and know they need to go install the fork.
            if herdrMissing {
                herdrInstallGuidance
            } else if let host = unavailableDaemonHost {
                VStack(spacing: 10) {
                    Text("herdr isn't running on \(host)")
                        .font(Typography.app(18, .semibold)).foregroundStyle(Palette.died)
                    Text("herdr is installed, but it isn't running. Start it on that computer, then retry:")
                        .font(Typography.app(13)).foregroundStyle(Palette.textDim)
                        .multilineTextAlignment(.center)
                    CopyableCommand(command: HerdrSetup.startCommand)
                    Button("retry") { Task { await load() } }
                        .font(Typography.app(15, .semibold)).foregroundStyle(Palette.text)
                }
            } else {
                Text(error).font(Typography.machine(13)).foregroundStyle(Palette.died)
                    .multilineTextAlignment(.center)
                if let fingerprint = rejectedFingerprint {
                    VStack(spacing: 8) {
                        Text("the host key changed. the server now presents:")
                            .font(Typography.app(12)).foregroundStyle(Palette.textDim)
                        Text(fingerprint).font(Typography.machine(11)).foregroundStyle(Palette.text)
                            .textSelection(.enabled).multilineTextAlignment(.center)
                        Text("trust it ONLY if this exactly matches the key you verified out of band.")
                            .font(Typography.app(12)).foregroundStyle(Palette.textDim).multilineTextAlignment(.center)
                    }
                    Button("trust this key & reconnect") { trustFailed = !onTrustHostKey(fingerprint) }
                        .font(Typography.app(15, .semibold)).foregroundStyle(Palette.died)
                    if trustFailed {
                        Text("could not save the verified key to the keychain; not reconnecting. try again.")
                            .font(Typography.app(12)).foregroundStyle(Palette.died).multilineTextAlignment(.center)
                    }
                }
                // Plain retry ONLY for non-host-key errors. After a host-key
                // rejection a bare reconnect could first-contact-trust whatever key
                // next appears (bypassing the fingerprint the user must verify), so
                // the only routes then are "trust this key" above or disconnect.
                if rejectedFingerprint == nil {
                    Button("retry") { Task { await load() } }
                        .font(Typography.app(15, .semibold)).foregroundStyle(Palette.text)
                }
            }
        }
        .padding(24)
        Spacer()
    }

    /// The install one-liner, kept where BOTH screens that show it can reach it.
    ///
    /// It used to be `private static` on this view alone, which is why the first-run
    /// screen could not show it: the only place explaining how to install herdr was
    /// `herdrInstallGuidance`, reachable only AFTER a successful SSH login — visible
    /// solely to people who had already solved the problem it explains.
    private static var herdrInstallCommand: String { HerdrSetup.installCommand }

    /// Shown in place of the raw stderr when the connect failed because herdr is not
    /// installed (`herdrMissing`). Mirrors `ForkNoticeView`'s language and reuses the
    /// Gram setup card's command-box + Copy idiom, plus the shared install link.
    @ViewBuilder private var herdrInstallGuidance: some View {
        Image(systemName: "arrow.triangle.branch")
            .font(.system(size: 34, weight: .regular))
            .foregroundStyle(Palette.waiting)
        VStack(spacing: 8) {
            Text(herdrIncompatibleBuild ? "herdr here is too old" : "herdr isn't installed here")
                .font(Typography.app(20, .bold)).foregroundStyle(Palette.text)
                .multilineTextAlignment(.center)
            Text(herdrIncompatibleBuild
                 ? "herdrup runs the herdr daemon on your machine over SSH. The herdr on this host can't run the app bridge. It's too old, or isn't the jerryfane/herdr fork. Update or install the fork, then reconnect."
                 : "herdrup runs the herdr daemon on your machine over SSH. It isn't installed yet. Install the jerryfane/herdr fork, then reconnect.")
                .font(Typography.app(14)).foregroundStyle(Palette.textDim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Copy box: run this on the machine, then reconnect.
        VStack(alignment: .leading, spacing: 10) {
            Text("Run this on your machine, then reconnect:")
                .font(Typography.app(13)).foregroundStyle(Palette.textDim)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Self.herdrInstallCommand)
                .font(Typography.machine(11)).foregroundStyle(Palette.textDim)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.groundMachine))
            Button {
                UIPasteboard.general.string = Self.herdrInstallCommand
                installCmdCopied = true
            } label: {
                Text(installCmdCopied ? "Copied ✓" : "Copy command")
                    .font(Typography.app(13, .semibold)).foregroundStyle(Palette.ground)
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Palette.text))
            }
        }
        .padding(.top, 4)
        // Full instructions (every install variant) + retry once it's installed.
        InstallInstructionsLink(label: "Full install instructions")
        Button("retry") { Task { await load() } }
            .font(Typography.app(15, .semibold)).foregroundStyle(Palette.text)
            .padding(.top, 2)
    }

    @MainActor
    private func load() async {
        // Main-actor isolation prevents simultaneous mutation, not out-of-order
        // completion across awaits. Only the most recently STARTED load may publish.
        let loadToken = rosterLoadGate.begin()
        // Live updates received from here on may postdate this load's snapshot; they
        // are replayed onto it below so a slower reload cannot undo them.
        let liveMark = liveEvents.ledger.mark
        let startedAt = ContinuousClock.now
        // Spinner ONLY when there is nothing to show yet (genuine first load, or after a
        // reconnect cleared `agents` via `.id(session)`). A re-entry with a populated list
        // refreshes silently — stale-while-revalidate — instead of blanking to a spinner.
        if agents.isEmpty, !loading { loading = true }
        defer {
            if rosterLoadGate.accepts(loadToken), loading { loading = false }
        }
        do {
            let listing = try await client.agentListing()
            guard rosterLoadGate.accepts(loadToken) else { return }
            if let origin = listing.originCapabilities {
                setLiveEventsSupported(origin.eventsV2)
            }
            liveEvents.backstop.loadSucceeded(startedAt: startedAt)
            liveEvents.unlistedReloads.loadPublished(startedAt: startedAt)
            liveEvents.ledger.settle(through: liveMark)
            let fetched = liveEvents.ledger.replay(onto: listing.agents, after: liveMark)

            // Agent state is the latency-sensitive payload. Publish it immediately
            // with the freshest account roster already in memory; never make visible
            // statuses wait behind the best-effort accounts.list request. A later
            // account response causes a second publication only when account data
            // actually changed, because receiveRoster is equality-gated.
            let latestAccounts = rosterRefreshState().latest.accounts
            receiveRoster(agents: fetched, accounts: latestAccounts)
            sessionCache?.store(fetched, session: session)

            clearSuccessfulLoadState()
            // Prune keep-mounted panes whose agent is gone (Stopped / vanished) so no dead
            // terminal lingers warm — but only a slot that was ONCE seen live and has now
            // vanished (never a still-booting spawn pane, which is absent by design while its
            // composer comes up — pruning it would cancel its one-shot prefill delivery). Never
            // prune the FRONT pane, so the reader isn't yanked off an exited terminal.
            updateLiveAgentBookkeeping()
            applyDeepLink(afterLoad: true)   // agents + roster loaded — front any pending push target
            openGramIfPending()              // a cold-launch gram tap opens the Gram page once loaded

            // Refresh account labels independently. A transient failure, or an older
            // daemon without accounts.list, keeps the freshest successful value. The
            // post-await generation check prevents a stalled older load from replacing
            // either the visible or pending snapshot after a newer load completes.
            if let fetchedAccounts = try? await client.accountsList() {
                guard rosterLoadGate.accepts(loadToken) else { return }
                // Replayed again: live updates may have landed during this await.
                receiveRoster(agents: liveEvents.ledger.replay(onto: listing.agents, after: liveMark),
                              accounts: fetchedAccounts)
            } else {
                guard rosterLoadGate.accepts(loadToken) else { return }
            }

            // Ping once per connected HomeView to feature-detect the transactional
            // transfer API, and `events_v2` on a daemon whose agent.list predates
            // `origin_capabilities`. Missing capabilities on an older daemon are a
            // successful negative result; a transport error is retried on the next load.
            if !checkedSessionTransferCapability {
                do {
                    let capabilities = try await client.serverCapabilities()
                    guard rosterLoadGate.accepts(loadToken) else { return }
                    if listing.originCapabilities == nil {
                        setLiveEventsSupported(capabilities?.eventsV2 == true)
                    }
                    sessionTransferSupported = capabilities?.agentSessionTransfer == true
                    forgetSupported = capabilities?.agentForget == true
                    avatars.canEdit = capabilities?.agentAvatar == true
                    groups.setSupported(capabilities?.agentGroups == true)
                    // PARSED HERE, IN THE SAME BLOCK THAT MARKS THE CHECK DONE.
                    //
                    // My first conflict resolution kept BOTH this gated probe and the
                    // one main added, so a transient failure of the first left
                    // `sessionTransferHarnesses` empty while the second set
                    // `checkedSessionTransferCapability` and suppressed any retry — an
                    // OMP-capable daemon would then offer NO transfer target for the
                    // lifetime of this HomeView. Consolidated to one probe, and
                    // populating the set and setting the flag are now inseparable.
                    if sessionTransferSupported {
                        if let advertised = capabilities?.agentSessionTransferHarnesses {
                            sessionTransferHarnesses = Set(advertised.filter { harness in
                                switch harness {
                                case .claude, .codex, .omp:
                                    return true
                                case .unrecognised:
                                    return false
                                }
                            })
                        } else {
                            // Older transfer-capable daemons predate the explicit list
                            // and support exactly Claude Code and Codex.
                            sessionTransferHarnesses = [.claude, .codex]
                        }
                    } else {
                        sessionTransferHarnesses = []
                    }
                    checkedSessionTransferCapability = true
                } catch {
                    guard rosterLoadGate.accepts(loadToken) else { return }
                    // Keep the control hidden and retry on a later refresh. Existing
                    // transfer state still makes the menu visible so a Ready/rollback
                    // transaction can always be reopened.
                }
            }
            // Folders and stars: the first load after the ping reads the document, later
            // loads re-read it at most once a minute. Off the roster's path, so a slow
            // answer never holds the list back.
            Task { await groups.refresh() }
        } catch {
            // A stale failure must not replace a newer success, clear its deep link,
            // or turn a recovered connection back into an error screen.
            guard rosterLoadGate.accepts(loadToken) else { return }
            liveEvents.backstop.loadFailed()
            let rejected: String?
            var notInstalled = false
            var incompatibleBuild = false
            var daemonHost: String?
            if let transportError = error as? TransportError {
                if case .hostKeyRejected(_, let fingerprint) = transportError {
                    rejected = fingerprint
                } else {
                    rejected = nil
                    if case .herdrNotInstalled = transportError { notInstalled = true }
                    // herdr is present but can't run the app bridge (too old / not the
                    // fork). Same recovery screen — the remedy is install/update the fork
                    // — with a heading that fits (see `herdrInstallGuidance`).
                    if case .herdrIncompatible = transportError {
                        notInstalled = true
                        incompatibleBuild = true
                    }
                    if case .daemonUnavailable(let host) = transportError {
                        daemonHost = host
                    }
                }
            } else {
                rejected = nil
            }
            // A BACKGROUND refresh failure keeps the stale-but-good list rather than blowing it
            // away into the error screen. Surface the error only when there is nothing to show —
            // EXCEPT a host-key rejection, which always surfaces (a mid-session key change must
            // never be hidden behind a cached list).
            if agents.isEmpty || rejected != nil {
                self.error = "\(error)"
                rejectedFingerprint = rejected
                // Only when this is the surfaced error do we drive the install-guidance
                // branch; a no-herdr connect always has an empty list, so it surfaces here.
                herdrMissing = notInstalled
                herdrIncompatibleBuild = incompatibleBuild
                unavailableDaemonHost = daemonHost
            }
            // DROP a pending deep-link this failed load couldn't service, rather than leave it armed:
            // a push targets a just-now event, so firing it after some much-later successful load would
            // yank the reader into a stale pane (an agent that may have finished long ago). If it was
            // already opened by the onChange path, this is nil already. They can reopen from the list.
            push.pendingPaneID = nil
            // Same for a pending gram tap: a message does not go stale like a pane,
            // but popping the Gram cover on some much-later successful load is a
            // surprise; drop it for the same reason and consistency.
            push.pendingGram = false
        }
    }

    // MARK: Live status stream

    /// Records the daemon's `events_v2` advertisement. Writes the observable flag
    /// only on a change, and never re-enables a request the daemon already refused.
    @MainActor
    private func setLiveEventsSupported(_ advertised: Bool) {
        let supported = advertised && !liveEvents.refused
        if supported != liveEventsSupported { liveEventsSupported = supported }
    }

    /// Holds the all-panes status subscription until the task is cancelled
    /// (background, capability loss, or the view going away), reconnecting with
    /// backoff whenever the stream ends: the SSH channel dropped, the daemon
    /// restarted, or the silence watchdog gave up on a half-open connection.
    @MainActor
    private func runLiveEvents() async {
        var backoff = ReconnectBackoff()
        defer { liveEvents.streaming = false }
        while !Task.isCancelled {
            var acknowledged = false
            do {
                for try await line in client.subscribeAgentStatus() {
                    if case .started = line {
                        acknowledged = true
                        liveEvents.streaming = true
                        // Anything that changed while no stream was open (first
                        // connect, or the gap before this reconnect) is only in
                        // agent.list.
                        requestRosterReload()
                    } else {
                        // Only a stream that delivers something counts as healthy,
                        // so a daemon that acknowledges and hangs up at once still
                        // backs off instead of reconnecting every second.
                        backoff.reset()
                        receiveLiveEvent(line)
                    }
                }
            } catch is APIError where !acknowledged {
                // The daemon refused the request itself (it advertised events_v2 but
                // rejects entries without pane_id). Retrying cannot help; the 5 s
                // poll carries on for this connection.
                liveEvents.streaming = false
                liveEvents.refused = true
                liveEventsSupported = false
                return
            } catch {
                // A dropped or silent stream: reconnect below.
            }
            liveEvents.streaming = false
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: backoff.next())
        }
    }

    /// Patches the listed row a status or turn event names; lifecycle events,
    /// `lagged`, and status or turn events for an agent pane the list does not show
    /// yet reload agent.list (coalesced by `requestRosterReload`, and once per
    /// unlisted pane until a later load publishes).
    @MainActor
    private func receiveLiveEvent(_ line: AgentStatusStreamLine) {
        let now = Date()
        if let update = line.liveUpdate {
            liveEvents.ledger.record(update, receivedAt: now)
        }
        let latest = rosterRefreshState().latest
        switch latest.agents.effect(of: line, receivedAt: now) {
        case .patch(let patched):
            receiveRoster(agents: patched, accounts: latest.accounts)
        case .reload:
            requestRosterReload()
        case .reloadForUnlistedPane(let pane):
            if liveEvents.unlistedReloads.request(pane, at: .now) { requestRosterReload() }
        case .ignore:
            break
        }
    }

    /// Coalesces event-driven reloads: a burst of pane lifecycle events costs one
    /// load in flight plus at most one queued behind it.
    @MainActor
    private func requestRosterReload() {
        guard liveEvents.reloadTask == nil else {
            liveEvents.reloadAgain = true
            return
        }
        let buffer = liveEvents
        buffer.reloadTask = Task { @MainActor in
            repeat {
                buffer.reloadAgain = false
                await load()
            } while buffer.reloadAgain && !Task.isCancelled
            buffer.reloadTask = nil
        }
    }
}
