import SwiftUI
import Foundation
import UIKit    // UIPasteboard (Copy diagnostics)
import UniformTypeIdentifiers
import StoreKit // Product / tip jar (Settings' Support section)
import UserNotifications // notification authorization status (Settings notify section)
import HerdrKit

/// One agent's pane: a styled header, the folded monospace output, and the input
/// surface (a control-key row with a Return cap, and a reply box). Input goes
/// through HerdrKit's InputRouter so intent-mode prompts submit while shell/TUI
/// keys pass through literally — the "send intent, not keystrokes" contract, not
/// a raw byte pipe. Answering a blocked agent is by typing the choice + Return;
/// there are deliberately no Approve/Reject buttons (a fixed 1/2 mapping cannot be
/// verified against an agent-specific menu — structured menu actions are a follow-up).
/// A LEFT-EDGE swipe-back for a view whose nav bar is hidden (which disables UIKit's
/// default interactive-pop). The recognizer is attached to a SHARED ANCESTOR (the window),
/// with a delegate that recognizes SIMULTANEOUSLY with everything, so it coexists with the
/// terminal scroll + the buttons rather than carving a touch dead-zone. This view itself
/// never intercepts a touch (`hitTest` → nil). Fires `action` (dismiss) on a committed
/// rightward edge swipe; removes the recognizer on teardown.
struct EdgeSwipeBack: UIViewRepresentable {
    let action: () -> Void
    func makeCoordinator() -> Coord { Coord(action: action) }
    func makeUIView(context: Context) -> UIView {
        let v = PassthroughView()
        DispatchQueue.main.async { context.coordinator.attach(from: v) }
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.action = action }
    static func dismantleUIView(_ uiView: UIView, coordinator: Coord) { coordinator.detach() }

    final class Coord: NSObject, UIGestureRecognizerDelegate {
        var action: () -> Void
        private weak var host: UIView?
        private var edge: UIScreenEdgePanGestureRecognizer?
        /// Set once `detach` runs so a still-QUEUED attach retry (attach defers via
        /// DispatchQueue.main.async while the window is nil) no-ops instead of installing a
        /// recognizer onto the window that nothing will ever remove. Without this the pane's
        /// in-place agent swaps — which dismantle+remake this overlay on every swipe — could
        /// leak an orphaned edge recognizer per swap.
        private var detached = false
        init(action: @escaping () -> Void) { self.action = action }
        func attach(from v: UIView) {
            guard !detached, edge == nil else { return }
            guard let window = v.window else {   // not in the hierarchy yet — retry next runloop
                DispatchQueue.main.async { [weak self, weak v] in
                    guard let self, !self.detached, let v else { return }
                    self.attach(from: v)
                }
                return
            }
            let g = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(fired(_:)))
            g.edges = .left
            g.delegate = self
            window.addGestureRecognizer(g)
            host = window; edge = g
        }
        func detach() { detached = true; if let g = edge { host?.removeGestureRecognizer(g) }; edge = nil; host = nil }
        @objc func fired(_ gr: UIScreenEdgePanGestureRecognizer) {
            guard gr.state == .ended, let v = gr.view else { return }
            if gr.translation(in: v).x > 40 || gr.velocity(in: v).x > 300 { action() }   // real swipe, not a twitch
        }
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
    /// Never intercepts touches — the recognizer lives on the window, not this view.
    final class PassthroughView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }
}

/// One agent's live terminal + controls. Its identity (pane id, per-pane @State, terminal
/// stream) is fixed for its lifetime — it is hosted MOUNTED by `PaneKeepAliveContainer` and
/// never torn down while its slot exists, so reopening it (and swiping/paging to it) is
/// instant, with scroll position and any typed draft preserved. `onNavigate` reports a
/// horizontal swipe (+1 next / -1 previous) up to the container, which fronts the neighbour;
/// `isForeground` drives the PTY width-lock hand-off when the pane hides/shows.
struct TerminalPaneContent: View {
    let client: HerdrClient
    let paneID: String
    let title: String
    let onNavigate: (Int) -> Void
    /// True while this pane is the one on screen. Drives the PTY-lock release/re-take
    /// (via `LiveTerminalView.isForeground`) and a status refresh on re-show; a
    /// backgrounded keep-mounted pane stays warm but drops the keyboard and stops holding
    /// the width-lock.
    let isForeground: Bool
    /// Back out to the agents list (header chevron / left-edge swipe). Replaces the old
    /// NavigationStack `dismiss` now that panes live in a keep-alive container, not a push.
    let onClose: () -> Void
    @State private var reply: String
    @StateObject private var composerKeyboard = ComposerKeyboard()
    /// Every staged attachment, in paste order. Each sends as its own gram message and
    /// they are all named by ONE prompt, so the agent gets a single turn that points at
    /// the whole set. Capped at `ComposerStaging.maxAttachments`.
    @State private var replyAttachments: [ComposerAttachment] = []
    /// The ••• "Share with someone" sheet and the guests who hold this agent (the header chip).
    @StateObject private var guestShare = GuestSharePaneModel()
    /// The roster's avatar directory: offers Avatar… in the ⋯ menu when it may edit.
    @Environment(AgentAvatarDirectory.self) private var avatars: AgentAvatarDirectory?
    @State private var editingAvatar = false
    @State private var loadingReplyAttachment = false
    /// The paperclip's attach sheet (`composerAttachPicker`), the third way in beside
    /// paste and drag-and-drop.
    @State private var showReplyAttachSheet = false
    /// Uploads each staged attachment as it is added, so Send only posts and prompts; its
    /// per-file progress drives the chips. Released with the pane, which abandons the draft.
    @State private var replyUploader = ComposerUploader()
    /// The file being posted, while a send runs.
    @State private var replySendingAttachmentID: UUID?
    @State private var replyFailedAttachmentID: UUID?
    /// The agent this pane hosts (drives identity, status badge, and input mode).
    /// Seeded from the caller's list context, then RE-RESOLVED from agent.list on
    /// every refresh so status + input mode track the LIVE pane instead of freezing
    /// at open time. Nil until the server names an agent for this pane — input
    /// stays rawKeys (the safe reading) until then. This live re-resolution is what
    /// lets a freshly-spawned agent flip rawKeys→intent once its composer appears,
    /// so a pre-filled task sends as a proper prompt.
    @State private var agent: AgentInfo?
    /// The omp Chat view (#481): its conversation, kept across Chat ↔ Terminal switches.
    @StateObject private var chatModel: ChatModel
    /// The switch position: Settings' default, or this agent's last choice this session.
    @State private var showsChat: Bool
    /// The machine answers `agent.transcript` (ping `agent_transcript`). Probed per pane.
    @State private var transcriptCapable = false
    /// The key row's height when it last showed: in Chat the terminal underneath keeps the
    /// height it has in Terminal view, so switching never resizes the PTY.
    @State private var keyRowHeight: CGFloat = ChatPaneLayout.lastKeyRowHeight
    /// Per-agent push mute, toggled from the header's ⋯ menu (keyed by this pane's
    /// public id — the same id the push payload carries).
    @ObservedObject private var mute = MuteStore.shared
    /// A drag is hovering the reply bar, so the target says so before the drop lands.
    @State private var replyDropTargeted = false
    /// A FILE drag is hovering the terminal (#575), which drops into the same reply.
    @State private var terminalDropTargeted = false
    @State private var sending = false
    /// Counts Chat sends accepted here: each plays the Send press (`ChatSendPress`).
    @State private var sendPresses = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Keycap writes share one ordered drain; prompt/attachment sends retain their
    /// own in-flight guard without throttling a rapid run of terminal keys.
    @State private var keySendTask: Task<Void, Never>?
    /// A failed key invalidates only keys queued before the failure; a new tap can retry.
    @State private var keyFailureEpoch = 0
    @State private var keySendSequence = 0
    @State private var actionNote: String?
    /// In-flight guard for the [Switch] banner action, so repeated taps don't queue multiple
    /// `/tui default` prompts (the reply box's send is gated by `sending`; this is its analogue).
    @State private var switchingTui = false
    /// True when the pane was opened with a pre-filled task (a just-spawned agent).
    /// While true, the manual send is DISABLED and `deliverPrefillIfNeeded` polls
    /// until the agent is promptable, then delivers the task as a prompt. This is
    /// what closes the early-tap hazard: a just-started pane is a booting shell, so
    /// tapping send in rawKeys would type the task literally and a later Return
    /// would EXECUTE it as a shell command — the task must go through agent.prompt,
    /// never send_text.
    @State private var pendingPrefill: Bool
    /// True while `deliverPrefillIfNeeded` is actively polling. The manual Send is
    /// withheld during this window (the auto-loop owns delivery); once it stops
    /// (delivered or timed out) the button re-enables — but ALWAYS routes a pending
    /// pre-fill through the prompt-only path, never rawKeys.
    @State private var autoDelivering = false
    /// Bumped by the header refresh button to RECONNECT the pane: changing the id below re-creates
    /// the LiveTerminalView (new Coordinator → a fresh pane.stream over a new connection, re-seeded
    /// from the current server state). Useful when the stream has gone stale or its connection dropped.
    @State private var streamGen = 0
    /// Terminal font size preference (points), app-wide via UserDefaults. Read here to
    /// drive `LiveTerminalView.fontSize` (applied in-place, no view recreation) and
    /// mutated by ⌘± and the ⋯ "Text size" control. Clamped to [9, 24].
    @AppStorage("terminal.fontSize") private var terminalFontSize: Double = 12.5
    @AppStorage(ChatTextSize.storageKey) private var chatFontSize = ChatTextSize.defaultPoints
    /// Settings › Typing › Instant typing, handed to `LiveTerminalView.predictiveEcho`.
    @AppStorage(PredictiveEchoSetting.key) private var predictiveEcho = PredictiveEchoSetting.defaultValue
    /// App foreground/background phase. On return to `.active` the front pane's
    /// live `pane.stream` has stalled (no network while backgrounded) and
    /// reconnects from the live tail, missing output produced while away — so we
    /// reseed the front pane from durable scrollback (issue #62 follow-up).
    @Environment(\.scenePhase) private var scenePhase
    /// Set when the app actually goes `.background`, so the reseed on the next
    /// `.active` fires only after a real background — not a transient `.inactive`
    /// (Control Center / a notification banner), which would flash needlessly.
    /// Also the terminal's `sceneBackgrounded`: while set, the pane hands its PTY width
    /// claim back so another device viewing the agent is not held at this one's width
    /// while the app is suspended. A transient `.inactive` keeps the claim.
    @State private var wasBackgrounded = false
    /// The live terminal's stream-liveness box. A `@State` reference type, so it SURVIVES
    /// a `streamGen` remount and keeps reading the same stream's evidence across one.
    @State private var terminalLiveness = StreamLiveness()
    /// One-shot Ctrl shared by direct terminal input and the reply field. Native
    /// encoding owns direct chords; `handleReplyChange` owns reply-field chords.
    @State private var ctrlArmed = false
    /// True while dictating into the reply: disables the field (so typing can't be
    /// overwritten by the next partial) and suppresses the ctrl-chord interception (so a
    /// single-char dictation partial can't be misread as a control chord).
    @State private var replyDictating = false
    /// Focus of the reply field, so the software keyboard can be DISMISSED — via the
    /// keyboard-toolbar chevron or a tap on the (read-only) terminal.
    @State private var replyFocused = false
    /// Terminal-input focus is explicit on touch devices. A terminal tap enables
    /// direct PTY typing; reply submission and keyboard collapse clear it so the
    /// software keyboard can genuinely dismiss instead of immediately moving focus
    /// back to the terminal.
    @State private var terminalInputFocused = false
    /// Incremented by the collapse chevron to request a DELIBERATE collapse. Without it a
    /// deliberate collapse is indistinguishable from any other pass where the terminal simply does
    /// not want key focus, and the resign is refused while a selection is held.
    ///
    /// A TOKEN, not a bool set for "the next pass" — see `LiveTerminalView.consumeCollapse`. The
    /// bool version cleared itself in `DispatchQueue.main.async`, which drains BEFORE SwiftUI's
    /// update flush, so the pane read it as already false and the collapse never happened.
    @State private var terminalCollapseToken = 0
    /// Incremented to ask the pane to jump to its newest output. LiveTerminalView
    /// performs exactly one jump per increment.
    @State private var jumpToTailToken = 0
    /// Bumped whenever the host itself delivers input to the pane (a control-bar
    /// keycap, a raw sequence cap). Those buttons live OUTSIDE the terminal surface, so
    /// the view's own touch and key paths never see them: without this the retained
    /// resize frame stayed up while their bytes reached the agent, and an input that
    /// produced no redraw looked ignored. Reported by review at d750df7.
    @State private var userInputToken = 0
    /// False while the pane is scrolled away from its newest output. Drives the
    /// "Latest" pill. Starts true so the pill stays hidden until the reader scrolls.
    @State private var terminalAtTail = true
    /// What the terminal's top history capsule shows: loading, the load-earlier offer, or nothing.
    @State private var terminalHistoryPaging = TerminalHistoryPaging.hidden
    /// Bumped by the capsule's "Load earlier output" tap; the terminal pages once per bump.
    @State private var loadEarlierHistoryToken = 0
    /// The terminal's current height: the room the composer grows over.
    @State private var terminalHeight: CGFloat = 0
    /// The note and quick-key row above the composer. With the composer's resting row,
    /// the only layout height the bottom block reserves.
    @State private var bottomChromeHeight: CGFloat = 0
    private static let replyBarTopPadding: CGFloat = 4
    private static let replyBarBottomPadding: CGFloat = 8
    /// Find-bar state. `findRequest` is nil while the bar is closed, which is also what
    /// clears the highlight — see `LiveTerminalView.performFind`.
    @State private var findOpen = false
    @State private var findTerm = ""
    /// Bumped once per next/previous step. The term alone cannot express "same term,
    /// next match", which is the whole interaction.
    @State private var findGeneration = 0
    @State private var findDirection: FindRequest.Direction = .forward
    /// `(index, total, capped)` from the terminal or the Chat, rendered as "3/17" or "3/500+".
    @State private var findMatches: (Int, Int, Bool) = (0, 0, false)
    @FocusState private var findFocused: Bool

    private var findRequest: FindRequest? {
        guard findOpen else { return nil }
        return FindRequest(term: findTerm, generation: findGeneration, direction: findDirection)
    }
    /// One-time gate for the "switch Claude Code to smooth (classic) scrolling" banner.
    /// Persisted app-wide via UserDefaults, so once the reader answers it once — Switch
    /// OR dismiss, for ANY Claude Code pane — it never shows again. See `showTuiBanner`.
    @AppStorage("tui.classicPrompted") private var tuiClassicPrompted = false

    private let router = InputRouter()

    /// `initialReply` pre-fills the reply box — used when opening a freshly-spawned
    /// agent's pane with the new-agent task ready to send. The agent is not
    /// promptable at spawn; the task is delivered automatically (as a prompt) the
    /// moment the pane reports a composer — never typed raw into the still-booting
    /// pane. A non-empty `initialReply` puts the view into the pending-delivery
    /// state.
    init(client: HerdrClient, paneID: String, title: String, agent: AgentInfo? = nil,
         initialReply: String = "", isForeground: Bool = true,
         onNavigate: @escaping (Int) -> Void = { _ in }, onClose: @escaping () -> Void = {}) {
        self.client = client
        self.paneID = paneID
        self.title = title
        self.isForeground = isForeground
        self.onNavigate = onNavigate
        self.onClose = onClose
        _agent = State(initialValue: agent)
        _reply = State(initialValue: initialReply)
        _pendingPrefill = State(initialValue: !initialReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        _chatModel = StateObject(wrappedValue: ChatModel(target: paneID))
        _showsChat = State(initialValue: ChatPreference.showsChat(paneID: paneID))
    }

    private var group: AgentGroup? { agent.map { AgentRow(info: $0).group } }
    /// The page offers the Chat view: an omp agent whose machine serves `agent.transcript`,
    /// unless the server's latest answer is that it cannot give this agent a transcript.
    private var chatAvailable: Bool {
        transcriptCapable && ChatPreference.isOmp(agent?.agent) && !chatModel.unsupported
    }
    /// An omp agent on a transcript-capable machine whose transcript was refused. A just-started
    /// agent is refused for its first seconds, until omp's integration reports a session
    /// (#604); the page keeps asking so Chat appears without restarting the app.
    private var chatRecoveryNeeded: Bool {
        transcriptCapable && ChatPreference.isOmp(agent?.agent) && chatModel.unsupported
    }
    /// Gaps between transcript retries while Chat is refused, in seconds. The last one repeats.
    private static let chatRecoveryDelays: [UInt64] = [1, 2, 4, 8, 15, 30, 60]
    private var showingChat: Bool { chatAvailable && showsChat }

    private func setShowsChat(_ value: Bool) {
        if findOpen { toggleFind() }
        showsChat = value
        ChatPreference.remember(paneID: paneID, showsChat: value)
        if value {
            terminalInputFocused = false
        }
    }
    /// The pane header label: the agent's NAME first (matching the list), then the model (kind) and
    /// the cwd folder as context — each appended only when it adds information. E.g.
    /// "herdr-app · claude · herdr-ios"; a name equal to its kind or folder collapses to just the name.
    private var heading: String {
        let name = agent?.displayName ?? title
        var parts: [String] = []
        if !name.isEmpty { parts.append(name) }                       // never a leading " · " for an empty name
        if let kind = agent?.agent, !kind.isEmpty, !parts.contains(kind) { parts.append(kind) }
        if let cwd = agent?.cwd {
            let folder = URL(fileURLWithPath: cwd).lastPathComponent
            // Dedup the folder against BOTH name and kind, and drop the non-folders URL yields for a
            // root/empty cwd ("/" and "." respectively).
            if !folder.isEmpty, folder != "/", folder != ".", !parts.contains(folder) { parts.append(folder) }
        }
        return parts.isEmpty ? title : parts.joined(separator: " · ")   // fall back so the header is never blank
    }
    // Send is withheld only while the auto-delivery loop is actively polling (it
    // owns delivery then). A pending pre-fill does NOT disable the button once the
    // loop stops — instead the button ROUTES a pre-fill through the prompt-only
    // path (see the replyBar action), so it can never fall to rawKeys send_text.
    private var hasReplyContent: Bool {
        !replyAttachments.isEmpty || !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var canSend: Bool {
        hasReplyContent && !sending && !replyDictating && !loadingReplyAttachment
    }

    /// Whether to offer the one-time "switch to smooth (classic) scrolling" banner:
    /// ONLY for Claude Code panes (agent kind contains "claude") and only until the reader
    /// has answered it once (`tuiClassicPrompted`). Deliberately gates on agent KIND + the
    /// one-shot flag, not on probing the alt-screen/mouse state — simpler, and correct
    /// even after the switch since the flag suppresses any re-show. codex/gemini/plain
    /// shells never see it.
    private var showTuiBanner: Bool {
        // Never render during a buildbox screenshot or an XCUITest run. The banner takes its own
        // ~150pt of flow space above the terminal, which would push the scroll receipts' hard-coded
        // dy:0.35 drag origin off the scroll view — their scroll/ccscroll mocks seat a claude-kind
        // pane — reproducing the exact movedDiff~0 dead-scroll failure those receipts exist to catch.
        // ScreenshotMock is #if DEBUG-only and this view builds in ALL configs, so the guard is
        // DEBUG-gated (a bare reference breaks the Release/Distribution archive; release has no mock
        // harness, so nothing to suppress there). Same guard shape AppDelegate uses for push/prompts.
        #if DEBUG
        if ScreenshotMock.mode != nil { return false }
        #endif
        // contains("claude") to stay consistent with DesignSystem's agent-kind colour/glyph mapping,
        // so a claude-family kind is classified uniformly everywhere.
        return (agent?.agent?.contains("claude") ?? false) && !tuiClassicPrompted
    }

    /// The UI text-size setting. Read in `body` only to observe it, so the pane
    /// CHROME (header/keycaps, which use Typography) re-renders at the new
    /// Typography.scale even while kept mounted. Terminal CONTENT is insulated —
    /// it uses its own `terminal.fontSize`, unaffected by this.
    @AppStorage("ui.fontScale") private var uiFontScale: Double = 1.0

    var body: some View {
        // Observe the text-size setting so the pane chrome re-renders at the new scale.
        let _ = uiFontScale
        return ZStack {
            // The terminal is its own ground — one shade under the app (groundMachine
            // #0B0D1C vs ground #13162A). Per the design, the output IS the ground and
            // the chrome floats over it; this is that base shade.
            Palette.groundMachine.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                // omp agents on a machine with `agent_transcript`: the Chat | Terminal switch
                // (#481). Other agents and older servers keep exactly today's page.
                if chatAvailable {
                    ChatTerminalSwitch(showsChat: Binding(get: { showsChat }, set: { setShowsChat($0) }))
                        .padding(.top, 2).padding(.bottom, 4)
                        .accessibilityHidden(!isForeground)
                }
                // A one-time, dismissible offer to move Claude Code off its laggy
                // fullscreen renderer onto the smooth inline "classic" one. Sits BELOW
                // the header and ABOVE the terminal so it takes its own flow space and
                // never covers output or fights the header/edge-back gestures; Claude
                // Code panes only, shown at most once (see showTuiBanner).
                if showTuiBanner { tuiBanner }
                // The live terminal: a real SwiftTerm VT fed by the pane.stream raw
                // byte firehose (#40), full-bleed as the machine ground. A terminal
                // tap enables direct PTY input; the reply bar remains the deliberate
                // prompt path for agent messages.
                LiveTerminalView(client: client, paneID: paneID,
                                 onNavigate: onNavigate, isForeground: isForeground,
                                 // Chat covers the terminal: its UIKit views leave
                                 // accessibility too (see `accessibilityCovered`).
                                 accessibilityCovered: showingChat,
                                 // Releases the width claim while the scene is in the
                                 // background; cleared with the remount decision below.
                                 sceneBackgrounded: wasBackgrounded,
                                 // The find and reply fields own their own responders.
                                 // Terminal focus is never inferred from device idiom.
                                 wantsTerminalKeyFocus: isForeground && !replyFocused && !findFocused
                                     && !showingChat
                                     && terminalInputFocused,
                                 // Set by the collapse chevron so the resign in updateUIView can
                                 // tell a deliberate dismissal from an incidental body pass.
                                 collapseToken: terminalCollapseToken,
                                 onTerminalFocusRequest: {
                                     replyFocused = false
                                     terminalInputFocused = true
                                 },
                                 jumpToTailToken: jumpToTailToken,
                                 onTailStateChange: { terminalAtTail = $0 },
                                 onHistoryPagingChange: { terminalHistoryPaging = $0 },
                                 loadEarlierHistoryToken: loadEarlierHistoryToken,
                                 // The host's current belief, so a `streamGen` remount seeds a
                                 // fresh Coordinator instead of replaying the last jump.
                                 isAtTail: terminalAtTail,
                                 fontSize: CGFloat(terminalFontSize),
                                 predictiveEcho: predictiveEcho,
                                 // Read on foreground to tell a suspended stream from a
                                 // still-running one; see the scenePhase handler below.
                                 liveness: terminalLiveness,
                                 controlArmed: $ctrlArmed,
                                 userInputToken: userInputToken,
                                 findRequest: showingChat ? nil : findRequest,
                                 onFindResult: { index, total in
                                     if !showingChat { findMatches = (index, total, false) }
                                 },
                                 // A file dropped anywhere on the terminal joins the reply,
                                 // exactly as one dropped on the composer bar does (#575).
                                 // Off in Chat, where the terminal is hidden under it.
                                 fileDrop: showingChat ? nil : TerminalFileDrop(
                                     onTargetChange: { terminalDropTargeted = $0 },
                                     onDrop: { acceptDroppedFiles($0) }))
                    // Reconnect on refresh: a new id re-creates the view → fresh stream/connection.
                    .id(streamGen)
                    .accessibilityIdentifier("terminal-surface")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { terminalHeight = $0 }
                    // A small horizontal inset so the grid gets a clean, symmetric
                    // margin instead of the last column hugging the right edge.
                    .padding(.horizontal, 8)
                    // The composer's drop highlight, around the whole terminal while a
                    // file drag hovers it. An overlay that never hit-tests, so the drop
                    // still lands on the terminal surface underneath.
                    .overlay {
                        if terminalDropTargeted && !showingChat {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Palette.brand, lineWidth: 2)
                                .allowsHitTesting(false)
                                .accessibilityIdentifier("terminal-drop-highlight")
                        }
                    }
                    // NOTE: do NOT attach a SwiftUI .onTapGesture here. A tap gesture on
                    // this UIViewRepresentable competes with the wrapped UIScrollView's
                    // native pan and starves terminal scroll drags. LiveTerminalView's
                    // UIKit recognizer owns the explicit direct-input tap instead.
                    // A visible, one-finger replacement for the double tap that used to
                    // jump to the tail (given back to SwiftTerm, which needs it for word
                    // select). An OVERLAY, not a gesture, for the reason stated above:
                    // only the button itself hit-tests, taps elsewhere reach the terminal.
                    .overlay(alignment: .bottom) {
                        ZStack {
                            // Not under Chat: there it is invisible, and on iOS 27 still an
                            // accessibility element over the chat.
                            if !terminalAtTail && !showingChat {
                                JumpToLatestButton(label: "Jump to latest output", identifier: "terminal-jump-latest",
                                                   regularGlass: true) { jumpToTailToken += 1 }
                                    .padding(.bottom, 16)
                            }
                        }
                        .animation(.easeInOut(duration: 0.15), value: terminalAtTail)
                    }
                    // An overlay for the same reason: only the offer capsule hit-tests, and
                    // the loading one lets touches through to the terminal.
                    .overlay(alignment: .top) {
                        ZStack {
                            TerminalHistoryCapsule(state: terminalHistoryPaging) { loadEarlierHistoryToken += 1 }
                        }
                        .animation(.easeInOut(duration: 0.15), value: terminalHistoryPaging)
                    }
                    // In Chat the terminal stays mounted under it (its stream stays warm for
                    // the switch back) at the height it has with the key row showing, so the
                    // switch never resizes the PTY.
                    .padding(.bottom, showingChat ? keyRowHeight : 0)
                    .opacity(showingChat ? 0 : 1)
                    .allowsHitTesting(!showingChat)
                    .accessibilityHidden(showingChat)
                    .overlay {
                        // Only the front pane's chat is mounted, and none in the background
                        // (`ScenePhase.mountsChat`): a kept-alive pane keeps its ChatModel, so
                        // fronting it again draws its newest window at once, but not hours of
                        // drawn rows that every relayout (a rotation, the background
                        // snapshots) would have to lay out again.
                        if showingChat, isForeground, scenePhase.mountsChat {
                            ChatView(client: client, model: chatModel, viewer: .owner, eventsPaneID: paneID,
                                     isActive: isForeground, live: true, agentStatus: agent?.agentStatus,
                                     ground: Palette.groundMachine,
                                     onOpenTerminal: { setShowsChat(false) },
                                     findRequest: findRequest,
                                     onFindResult: { index, total, capped in findMatches = (index, total, capped) })
                            // A composer keystroke redraws this page; the chat skips it
                            // (`ChatView ==`), so typing never re-evaluates the transcript.
                            .equatable()
                        }
                    }
                // THE COMPOSER FLOATS OVER THE TERMINAL. Only its resting row (plus the
                // note and the quick keys above it) takes layout height. Every extra line,
                // the toolbar, attachments, the drag handle and the editor draw upward
                // over the terminal's bottom rows instead of taking them away. Each of
                // those used to change the terminal's size, which sent set_pty_size, made
                // the agent redraw its whole screen and froze the terminal behind a
                // snapshot for up to a second: the "reload" felt while only typing (#301).
                Color.clear
                    .frame(height: bottomChromeHeight + ComposerStyle.restingHeight
                        + Self.replyBarTopPadding + Self.replyBarBottomPadding)
                    .overlay(alignment: .bottom) {
                        VStack(spacing: 0) {
                            VStack(spacing: 0) {
                                if let note = actionNote {
                                    Text(note).font(Typography.app(12)).foregroundStyle(Palette.textDim)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 4)
                                        // Identified so a failing receipt can quote the refusal instead of
                                        // reporting only that nothing happened.
                                        .accessibilityIdentifier("terminal-action-note")
                                }
                                // Chat hides the key row: the composer is its only input.
                                if !showingChat {
                                    controlBar
                                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                            keyRowHeight = height
                                            ChatPaneLayout.lastKeyRowHeight = height
                                        }
                                }
                            }
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomChromeHeight = $0 }
                            // The terminal's height no longer depends on the composer, so it
                            // is a stable measure of the room the composer grows over.
                            replyBar
                                .environment(\.composerEditorRoom, terminalHeight)
                                // In Chat on iPad and Mac, the composer takes the conversation
                                // column's width, centred under it; the terminal keeps the full width.
                                .conversationColumn(showingChat)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        // Opaque, so rows the composer grows over do not show through the
                        // gaps between the keycaps and around the card.
                        .background(Palette.groundMachine)
                    }
            }
        }
        // Left-edge swipe → back to the agents list. Edge-only, so it never fights the
        // terminal scroll. Rendered ONLY for the front pane: EdgeSwipeBack attaches its
        // recognizer to the WINDOW, so N keep-mounted panes would otherwise stack N
        // recognizers that all fire on one edge swipe.
        .overlay { if isForeground { EdgeSwipeBack { onClose() } } }
        // Kept-alive panes behind the front one, Gram or Settings hold their status dot still,
        // and so does the front one while the scene is inactive, like the roster's rings.
        .environment(\.statusMotion, isForeground && scenePhase == .active)
        #if DEBUG
        // The control harness's "reply-dictation" fills the reply through this binding,
        // exactly as `MicButton` does with partial results.
        .onReceive(NotificationCenter.default.publisher(for: TerminalInteractionHarness.replyTextNotification)) { note in
            guard ScreenshotMock.mode == .control, let text = note.object as? String else { return }
            reply = text
        }
        // The harness's drop highlight switch, for a screenshot of the terminal drop target.
        .onReceive(NotificationCenter.default.publisher(for: TerminalInteractionHarness.dropHighlightNotification)) { note in
            guard ScreenshotMock.mode == .control, let on = note.object as? Bool else { return }
            terminalDropTargeted = on
        }
        #endif
        // Hardware-keyboard shortcuts for this pane. Foreground only: N keep-mounted panes
        // would otherwise register N identical Command-F bindings, and UIKit would pick one
        // arbitrarily — quite possibly a hidden pane's.
        .background { if isForeground { paneKeyboardShortcuts } }
        // Runs ONCE per slot lifetime now (the pane stays mounted, so paneID never changes):
        // the one-shot prefill delivery + first status resolve.
        .task(id: paneID) {
            await refresh()
            await deliverPrefillIfNeeded()
        }
        .task(id: paneID) {
            transcriptCapable = (try? await client.serverCapabilities())?.agentTranscript ?? false
        }
        // While the server refuses this omp agent a transcript, ask again: soon after it
        // starts, then less often, and at once when its status changes (its first turn writes
        // the session). Front only; a success clears `unsupported`, which ends the loop.
        .task(id: [chatRecoveryNeeded ? "retry" : "", isForeground ? "front" : "", agent?.agentStatus ?? ""]) {
            guard chatRecoveryNeeded, isForeground else { return }
            await chatModel.refresh(client: client)
            var attempt = 0
            while chatModel.unsupported, !Task.isCancelled {
                let delays = Self.chatRecoveryDelays
                let seconds = delays[min(attempt, delays.count - 1)]
                attempt += 1
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await chatModel.refresh(client: client)
            }
        }
        // Re-resolve status each time the pane returns to the front; drop either
        // keyboard owner when it backgrounds so a hidden keep-mounted pane cannot
        // retain the software keyboard. Leaving the pane stops its attachments' uploads
        // (a send already waiting on one keeps it); coming back picks them up again.
        .onChange(of: isForeground) { _, nowFront in
            if nowFront {
                replyUploader.resume()
                Task { await refresh() }
            } else {
                replyUploader.pause()
                ctrlArmed = false
                replyFocused = false
                terminalInputFocused = false
            }
        }
        .onDisappear { ctrlArmed = false }
        // When the app returns to the foreground, reseed the FRONT pane the same way the
        // header refresh button does (bump streamGen → remount → a fresh keyframe, which
        // carries the scrollback on current servers; startBackfill()'s read is the fallback
        // for servers without keyframe history) — BUT ONLY IF THE STREAM ACTUALLY STOPPED.
        //
        // #62's fix keyed the reseed on scene phase alone, which is a PROXY, and the proxy
        // is only true on iOS. There the app is suspended, the stream really did stall, and
        // output produced while away is lost until a manual refresh, so a reseed repairs a
        // genuine gap. On a Mac the process keeps running while another Space or app is
        // front: frames keep arriving, nothing is lost, and the reseed then destroys a
        // perfectly live terminal — remounting throws away the reader's SELECTION and
        // scroll position, which is the whole point of the selection work in #203/#215.
        //
        // So judge the FACT instead. `terminalLiveness` records when a frame last arrived,
        // and the server pings every 20s, so a still-connected stream is at most ~20s stale
        // while `streamStuckTimeout` (50s, 2.5× the ping) is the Coordinator's own
        // definition of a dead stream. Reusing that one constant keeps the host and the
        // watchdog from drifting apart on what "dead" means.
        //
        // Gated on isForeground so only the visible pane pays a reseed; hidden keep-mounted
        // panes reseed when next front.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { ctrlArmed = false }
            switch phase {
            case .background:
                wasBackgrounded = true
            case .active:
                // WHY THE PLATFORM CHECK IS HERE AND STALENESS IS NOT ENOUGH ALONE, found by
                // review. On iOS the process is SUSPENDED, so `lastFrameAt` freezes at the
                // instant of suspension and never advances while away. Return within 50s and
                // staleness reads false — yet the gap is real, because a suspended socket
                // received nothing. A daemon that windows history into its keyframes repairs
                // that gap on the in-place reconnect; an older one does not (its reconnect
                // repaints only the visible screen, the backfill runs only from `attach`), so
                // a mid-session reconnect against it leaves the scrolled-off output missing.
                // That would narrow #62's repair to backgrounds longer than 50s.
                //
                // So the two platforms are asked different questions, because their facts
                // differ. On iOS a real background IS a real gap — always reseed, exactly as
                // before this change. Only on a Mac, where the process keeps running and
                // frames keep arriving, is staleness the honest test.
                //
                // Note this is NOT the "two-line platform gate" rejected while designing
                // this: that version used the platform alone to SUPPRESS the reseed, which
                // would also have suppressed a legitimate one under App Nap. Here the
                // platform WIDENS (iOS always reseeds) and staleness still governs the Mac,
                // so an App-Nap-suspended Mac window reads stale and reseeds correctly.
                let streamDied = !ProcessInfo.processInfo.isiOSAppOnMac
                    || terminalLiveness.isStale(
                        timeout: LiveTerminalView.streamStuckTimeout
                    )
                if wasBackgrounded && isForeground && streamDied { streamGen += 1 }
                wasBackgrounded = false
            default:
                break
            }
        }
    }

    // MARK: header

    /// One bar (#358): back, the title block (heading over status · live time), and one
    /// capsule holding Find, Reconnect and the ⋯ actions. The bar's height is constant in
    /// every state (44 pt at 100 % text, scaled with the app text size up to 62 pt), so opening
    /// find, a pane with no agent status, or a status change can never resize the terminal
    /// underneath (a height change resizes the PTY and reflows the buffer).
    private var header: some View {
        HStack(spacing: 10) {
            PaneHeaderBackButton { onClose() }
            if findOpen {
                findField
            } else {
                titleBlock
                // The guest-share chip is taller than the status line, so it sits beside the
                // title block (vertically centred) rather than inside the fixed-height bar's
                // second line.
                if let chip = guestShare.chipText { GuestShareChip(text: chip) }
            }
            PaneHeaderCapsule {
                InlineSearchToggle(isOpen: findOpen, identifier: "terminal-find",
                                   target: CGSize(width: 40, height: 44)) { toggleFind() }
                PaneHeaderRefreshButton(identifier: "terminal-refresh",
                                        refreshing: showingChat && chatModel.manualRefreshing) {
                    refreshActivePane()
                }
                // Per-agent actions (⋯), only for an agent pane — as before, where they lived
                // on the status row that exists only when the pane has a status group.
                if group != nil { agentActionsMenu }
            }
        }
        // Fixed across find / status / no-status states, but scaled with the app's text
        // size: at 140 % the title (16 pt) over the status line (11 pt) needs ~47 pt and
        // would overflow a plain 44 pt bar. The height then changes only when the user
        // changes Settings → Text size, a deliberate one-off, never while working.
        .frame(height: max(44, (44 * Typography.scale).rounded()))
        // A keep-mounted BACKGROUND pane still renders its header, so without this every
        // loaded pane publishes its own "terminal-refresh"/"terminal-find"/"terminal-actions"
        // to the accessibility tree. VoiceOver could then land on a hidden pane's controls,
        // and an automation query for one button legitimately matches several.
        .accessibilityHidden(!isForeground)
        .padding(.horizontal, 16).padding(.top, 6)
        // Off the glass where nothing sits above the pane (iPhone Duo's side status bar).
        .topEdgeClearance(base: 6, rowHeight: 44)
        .padding(.bottom, 8)
        .background(Palette.groundMachine)
        .modifier(GuestSharePresenter(model: guestShare, client: client, agent: agent,
                                      fallbackTitle: title, isForeground: isForeground))
    }

    /// The heading, with the agent's status underneath: pulsing dot + status word and the
    /// live time in that status.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(heading).font(Typography.app(16, .semibold))
                .foregroundStyle(Palette.text).lineLimit(1)
            if let group {
                HStack(spacing: 6) {
                    PulsingDot(color: group.color, active: group == .working)
                    Text(group.sectionTitle).font(Typography.microLabel).tracking(1)
                        .foregroundStyle(group.color)
                    if let sinceMs = statusSinceMs {
                        let start = Date(timeIntervalSince1970: Double(sinceMs) / 1000)
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(elapsedLabel(ctx.date.timeIntervalSince(start)))
                                .font(Typography.machine(11)).monospacedDigit()
                                .foregroundStyle(Palette.textFaint)
                        }
                    }
                }
                .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// When the agent entered its current status — the SAME anchor the list card's
    /// time-in-state badge uses (`status_since_unix_ms`, daemon #173), so the two
    /// screens cannot disagree about one fact.
    ///
    /// This used to read `lastCompletedTurn.completedUnixMs` and call it an
    /// approximation of the current turn's start. For an IDLE agent that happens to be
    /// exact — it went idle precisely when its last turn completed — which is why idle
    /// always matched and the bug hid. For a WORKING agent it is the moment the
    /// PREVIOUS turn finished, so the header over-counted by the entire idle gap before
    /// the current turn began. The real field existed all along; the header was never
    /// repointed at it when the list badge was.
    ///
    /// The completed-turn value stays as the fallback for a daemon too old to report
    /// `status_since` — a slightly-off timer beats no timer.
    private var statusSinceMs: Int64? {
        statusAnchorUnixMs(statusSinceUnixMs: agent?.statusSinceUnixMs,
                           lastCompletedUnixMs: agent?.lastCompletedTurn?.completedUnixMs)
    }

    /// Compact elapsed-time label: "45s", "1m 20s", "12m", "1h 5m". Seconds show only
    /// for the first ten minutes, where they read as motion; past that the minute (then
    /// hour) is enough.
    private func elapsedLabel(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let s = total % 60, m = (total / 60) % 60, h = total / 3600
        if h > 0 { return "\(h)h \(m)m" }
        if m >= 10 { return "\(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    /// The header's ⋯ overflow — the per-agent mute today, and the home for future
    /// per-agent actions. When muted, the button shows a struck bell so the state reads
    /// at a glance without opening the menu.
    private var agentActionsMenu: some View {
        Menu {
            TerminalCopyMenuSection(client: client, paneID: paneID)
            TerminalTextSizeMenuSection(
                increaseID: "terminal-font-increase", decreaseID: "terminal-font-decrease",
                onIncrease: {
                    if showingChat { chatFontSize = ChatTextSize.stepped(chatFontSize, by: 1) }
                    else { terminalFontSize = min(terminalFontSize + 1, 24) }
                },
                onDecrease: {
                    if showingChat { chatFontSize = ChatTextSize.stepped(chatFontSize, by: -1) }
                    else { terminalFontSize = max(terminalFontSize - 1, 9) }
                },
                onReset: {
                    if showingChat { chatFontSize = ChatTextSize.defaultPoints }
                    else { terminalFontSize = 12.5 }
                })
            if agent != nil {
                Button {
                    guestShare.isSharing = true
                } label: { Label("Share with someone", systemImage: "person.badge.plus") }
                .accessibilityIdentifier("terminal-share")
            }
            if agent != nil, avatars?.canEdit == true {
                AgentAvatarMenuButton { editingAvatar = true }
            }
            Button {
                mute.toggle(paneID)
            } label: {
                Label(mute.isMuted(paneID) ? "Unmute notifications" : "Mute notifications",
                      systemImage: mute.isMuted(paneID) ? "bell" : "bell.slash")
            }
            Button(role: .destructive) {
                Task {
                    try? await client.closePane(paneID: paneID)
                    onClose()   // the pane is gone → back to the agents list
                }
            } label: {
                Label("Close agent", systemImage: "xmark.circle")
            }
        } label: {
            PaneActionsMenuLabel(notificationsOff: mute.isMuted(paneID))
        }
        .accessibilityIdentifier("terminal-actions")
        .sheet(isPresented: $editingAvatar) {
            if let agent {
                AgentAvatarSheet(agent: agent, name: title,
                                 badge: group.map(AgentAvatarBadge.init) ?? .none,
                                 badgeLabel: group?.label ?? "")
            }
        }
    }

    private func refreshActivePane() {
        if showingChat {
            Task { await chatModel.manualRefresh(client: client) }
        } else {
            streamGen += 1
            Task { await refresh() }
        }
    }

    /// Hardware-keyboard shortcuts for this pane, carried by hidden zero-size buttons —
    /// the same pattern the split view uses for Command-K and Command-slash
    /// (`keyboardShortcuts`, :1931-1947).
    ///
    /// Why not `UIKeyCommand` on the terminal view, where the Ctrl chords live? Because
    /// Ctrl chords have to be TAKEN BACK from macOS's emacs-style text bindings, which is
    /// what `wantsPriorityOverSystemBehavior` is for (LiveTerminalView.swift:436-447).
    /// Command chords have no such competitor: the vendored terminal declares no
    /// `keyCommands`, and its `pressesBegan` has no branch for a Command-modified letter,
    /// so the press walks up the responder chain to these buttons untouched.
    @ViewBuilder private var paneKeyboardShortcuts: some View {
        Button("Find in terminal") {
            if findOpen { findFocused = true } else { toggleFind() }
        }
        .keyboardShortcut("f", modifiers: .command)
        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)

        Button("Refresh active view") { refreshActivePane() }
        .keyboardShortcut("r", modifiers: .command)
        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)

        // Escape closes the find bar, matching every other find bar. Only bound while the
        // bar is open, so it cannot swallow an Escape the terminal wants — vi users press
        // it constantly, and stealing it would be a far worse bug than missing shortcut.
        if findOpen {
            Button("Close search") { toggleFind() }
                .keyboardShortcut(.escape, modifiers: [])
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
    }

    /// The inline find field, shared with Gram's header (`InlineSearchField`).
    ///
    /// Replaces the heading rather than adding a header row: growing the header would
    /// resize the terminal mid-search and reflow the buffer under the reader, moving the
    /// very match they are looking at.
    private var findField: some View {
        InlineSearchField(
            placeholder: "Find",
            text: $findTerm,
            focus: $findFocused,
            matches: (index: findMatches.0, total: findMatches.1, capped: findMatches.2),
            onNext: { stepFind(.forward) },
            onPrevious: { stepFind(.backward) },
            identifierPrefix: "terminal-find"
        )
    }

    /// Opens the find bar and takes focus, or closes it and hands focus back.
    ///
    /// Closing clears the term, which is what drops the highlight (`findRequest` goes nil).
    /// It deliberately does NOT jump to the tail: a reader who searched into history is
    /// still reading history.
    private func toggleFind() {
        if findOpen {
            findOpen = false
            findTerm = ""
            findMatches = (0, 0, false)
            findFocused = false
        } else {
            findOpen = true
            findFocused = true
            // An armed one-shot Ctrl would otherwise encode the next keystroke as a control
            // byte — including one typed into the find field.
            ctrlArmed = false
        }
    }

    /// One next/previous step. The generation bump is what tells the Coordinator this is a
    /// step rather than an edit of the term.
    private func stepFind(_ direction: FindRequest.Direction) {
        guard !findTerm.isEmpty else { return }
        findDirection = direction
        findGeneration += 1
    }

    // MARK: classic-renderer banner

    /// The one-time offer to switch Claude Code from its laggy fullscreen renderer to the
    /// smooth inline "classic" one. A compact `surface` card with a hairline border (the
    /// kit's card shell), reusing the existing tokens: Geist app voice, ink text tiers, and
    /// the same ink-fill primary button as the send/keycap controls. Purely additive — it
    /// touches neither the scroll code, the PTY width-lock, nor the pane lifecycle.
    private var tuiBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textDim)
                Text("Smoother scrolling for Claude Code")
                    .font(Typography.app(14, .semibold)).foregroundStyle(Palette.text)
                Spacer(minLength: 8)
                Button { dismissTuiBanner() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textFaint).frame(width: 28, height: 28)
                }
                .accessibilityLabel(Text("Dismiss"))
            }
            Text("Claude Code opens in fullscreen mode, which makes scrolling here laggy. "
                 + "Switch to smooth (classic) scrolling? You can switch back to fullscreen "
                 + "anytime with /tui fullscreen.")
                .font(Typography.app(12)).foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { switchToClassicTui() } label: {
                    Text("Switch").font(Typography.app(13, .semibold)).foregroundStyle(Palette.ground)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(Palette.text).clipShape(Capsule())
                }
                .disabled(switchingTui)
                .opacity(switchingTui ? 0.5 : 1)
                Button { dismissTuiBanner() } label: {
                    Text("Not now").font(Typography.app(13, .semibold)).foregroundStyle(Palette.textDim)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Palette.surfaceRaised).clipShape(Capsule())
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline, lineWidth: 1))
        .padding(.horizontal, 12).padding(.top, 10)
    }

    /// [Switch] sends `/tui default` with `waitUntil: anyAgentStatus`. A confirmed
    /// delivery closes the banner; an uncertain result also closes it rather than
    /// inviting a duplicate send. Genuine non-delivery keeps the retry available.
    /// Claude Code persists the slash command in ~/.claude/settings.json, so one
    /// successful switch also changes future agents on that host.
    private func switchToClassicTui() {
        // Coalesce repeated taps: without this each tap would queue another /tui default prompt
        // (the reply box's send is already gated by `sending`; the banner had no equivalent).
        guard !switchingTui else { return }
        switchingTui = true
        let pane = paneID
        // A confirmed send dismisses the banner. An uncertain result also dismisses
        // it: leaving a one-tap retry after the PTY may have received /tui default
        // would queue a duplicate. The note directs the reader to the terminal.
        Task {
            defer { switchingTui = false }
            do {
                _ = try await client.prompt(pane: pane, text: "/tui default",
                                            waitUntil: HerdrClient.anyAgentStatus, timeoutMs: 6000)
                tuiClassicPrompted = true
                actionNote = "Switched. Claude Code will open in smooth-scroll mode from now on"
            } catch let error as APIError {
                if PromptRejection(error).mayHaveReachedAgent {
                    tuiClassicPrompted = true
                    actionNote = Self.promptRejectionNote(for: error)
                } else {
                    actionNote = "Couldn't switch. Tap Switch to try again"
                }
            } catch {
                actionNote = "Couldn't switch. Tap Switch to try again"
            }
        }
    }

    /// [Not now] / ✕ — asked once, for ALL agents: set the one-time flag so the banner
    /// never nags again (persisted app-wide via @AppStorage).
    private func dismissTuiBanner() { tuiClassicPrompted = true }

    // MARK: input

    // No Approve/Reject buttons: a fixed "1"/"2" mapping assumes a two-option
    // menu shape the server never guarantees, and both reviewers found it could
    // submit the OPPOSITE of the label (a menu with a broader grant at 2). Until
    // the option list is delivered as structured data, the reader answers by
    // typing the choice and pressing Return — which is the safe, verifiable path.
    // The keycap row is HORIZONTALLY SCROLLABLE so it can hold more than fits the
    // phone's width (esc/arrows/tab plus Shift+Tab, Ctrl, ^C, Return) without
    // collapsing each cap. Caps are intrinsic width (not maxWidth:.infinity, which
    // would expand infinitely inside a horizontal scroll view).
    //
    // #359: related keys share one group shape, a Space key follows esc, and Return is
    // PINNED outside the scroll view so it is always one tap away on iPhone.
    private var controlBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    keyCap(label: "esc", key: "Escape")
                    keyCap(label: "space", key: "Space", minWidth: 84)
                    ComposerKeyGroup {
                        keyCap(image: "ComposerKeyLeft", key: "Left", grouped: true)
                        ComposerKeyDivider()
                        keyCap(image: "ComposerKeyUp", key: "Up", grouped: true)
                        ComposerKeyDivider()
                        keyCap(image: "ComposerKeyDown", key: "Down", grouped: true)
                        ComposerKeyDivider()
                        keyCap(image: "ComposerKeyRight", key: "Right", grouped: true)
                    }
                    // End (end-of-line cursor) + the two scroll jumps for a mouse-mode agent
                    // like Claude Code: Ctrl+Home = jump to TOP, Ctrl+End = jump to BOTTOM
                    // (and re-enable auto-follow). ESC[1;5H / ESC[1;5F are the xterm Ctrl+Home
                    // / Ctrl+End sequences Claude Code's readline keymap honors (End alone is a
                    // cursor key there, not a scroll — hence the two Ctrl jumps for scrolling).
                    ComposerKeyGroup {
                        keyCap(label: "end", key: "End", grouped: true)
                        ComposerKeyDivider()
                        rawCap(label: "Jump to top", image: "ComposerKeyTop", sequence: "\u{1b}[1;5H", grouped: true)
                        ComposerKeyDivider()
                        // Jump to the newest output. Routed through the pane rather than a raw
                        // byte sequence, so a plain shell scrolls its own scrollback while a
                        // mouse-mode agent gets Ctrl+End. Deliberately NOT disabled on
                        // `sending || pendingPrefill` like the keycaps: this is local view
                        // navigation, not input to the agent.
                        Button { jumpToTailToken += 1 } label: {
                            ComposerQuickKeyLabel(text: "Jump to latest output", imageName: "ComposerKeyLatest",
                                                  grouped: true)
                        }
                        .accessibilityLabel(Text("Jump to latest output"))
                    }
                    ComposerKeyGroup {
                        keyCap(label: "tab", key: "Tab", grouped: true)
                        ComposerKeyDivider()
                        // Shift+Tab (CBT / back-tab, ESC[Z) — cycles Claude-Code modes. A
                        // raw escape sequence, not a named key: delivered verbatim to the PTY.
                        rawCap(label: "S-Tab", sequence: "\u{1b}[Z", grouped: true)
                    }
                    ComposerKeyGroup {
                        // Sticky Ctrl: arm, then the next typed char becomes its control byte.
                        ctrlCap
                        ComposerKeyDivider()
                        // ^P (previous prompt/history) — a one-tap control sequence for
                        // navigating OMP's prompt history without first arming Ctrl.
                        rawCap(label: "^P", sequence: "\u{10}", grouped: true)
                        ComposerKeyDivider()
                        // ^C (interrupt) — the common one-tap case; a raw control byte.
                        rawCap(label: "^C", sequence: "\u{03}", grouped: true)
                    }
                }
                .padding(.leading, 24).padding(.trailing, 12).padding(.vertical, 8)
            }
            // Keys fade out just before the pinned Return instead of sliding under it.
            .mask(
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 16)
                }
            )
            // The submit affordance rawKeys needs — typing never submits, so Return is the
            // deliberate second action. Highlighted, and pinned so it never scrolls away.
            keyCap(image: "ComposerKeyEnter", key: "Enter", primary: true)
                .padding(.trailing, 16)
        }
    }

    private func keyCap(label: String? = nil, image: String? = nil, key: String, primary: Bool = false,
                        grouped: Bool = false, minWidth: CGFloat = 44) -> some View {
        Button { ctrlArmed = false; send(.key(key)) } label: {
            ComposerQuickKeyLabel(text: label ?? key, imageName: image, primary: primary,
                                  grouped: grouped, minWidth: minWidth)
        }
        // Only a real prompt/attachment transaction or pending prefill blocks
        // keycaps; ordinary key writes are ordered without a cooldown.
        .disabled(sending || pendingPrefill)
        .accessibilityLabel(Text(key))
    }

    /// A cap that sends a raw byte SEQUENCE (a control byte or an escape sequence)
    /// straight to the PTY via `pane.send_text` — for keys herdr's named allow-list
    /// does not cover (Shift+Tab = `ESC[Z`, `^C` = `\u{03}`). Routed through the
    /// `.rawSequence` action so it is delivered verbatim, not newline-refused.
    private func rawCap(label: String, image: String? = nil, sequence: String, grouped: Bool = false) -> some View {
        Button { ctrlArmed = false; send(.rawSequence(sequence)) } label: {
            ComposerQuickKeyLabel(text: label, imageName: image, grouped: grouped)
        }
        .disabled(sending || pendingPrefill)
        .accessibilityLabel(Text(label))
    }

    /// One-shot Ctrl for direct terminal input and the reply field. Native terminal
    /// encoding owns direct chords; `handleReplyChange` owns reply-field chords.
    /// Tapping twice cancels without sending input.
    private var ctrlCap: some View {
        Button { ctrlArmed.toggle() } label: {
            ComposerQuickKeyLabel(text: "ctrl", armed: ctrlArmed, grouped: true)
        }
        .disabled(sending || pendingPrefill)
        .accessibilityLabel(Text(ctrlArmed ? "control armed" : "control"))
        .accessibilityIdentifier("terminal-ctrl")
    }
    @ViewBuilder
    private var replyAttachmentStrip: some View {
        if !replyAttachments.isEmpty || loadingReplyAttachment {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(replyAttachments) { attachment in
                        replyAttachmentChip(attachment)
                    }
                    if loadingReplyAttachment {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Adding attachment…").font(Typography.app(12))
                        }
                        .foregroundStyle(Palette.textDim)
                        .padding(12)
                        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 15))
                        .accessibilityIdentifier("terminal-attachment-loading")
                    }
                }
                .padding(.horizontal, 7)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func replyAttachmentChip(_ attachment: ComposerAttachment) -> some View {
        ComposerAttachmentChip(
            name: attachment.name, size: attachment.size, isImage: attachment.isImage,
            state: .for(attachment, upload: replyUploader.phase(of: attachment.id), sending: sending,
                        sendingID: replySendingAttachmentID, failedID: replyFailedAttachmentID),
            // A file still uploading can go: removing it cancels its upload. Only a send
            // in flight holds the strip, so the batch it is delivering stays whole.
            canRemove: !sending,
            onRemove: { removeReplyAttachment(attachment) },
            onRetry: { replyUploader.retry(attachment.id) }
        )
        .accessibilityIdentifier("terminal-attachment")
    }


    private var replyBar: some View {
        AdaptiveComposer(
            text: reply,
            isFocused: replyFocused,
            hasAccessory: !replyAttachments.isEmpty || loadingReplyAttachment,
            showsLeading: composerKeyboard.isVisible && !findFocused && (replyFocused || terminalInputFocused),
            isRecording: replyDictating
        ) { editorHeight in
            ComposerTextField(
                text: $reply,
                // Dictation owns the field; an upload must not resign its first responder.
                isEnabled: !replyDictating,
                isFocused: replyFocused,
                onFocusChange: { focused in
                    replyFocused = focused
                    if focused { terminalInputFocused = false }
                },
                isPresented: isForeground,
                onChange: { oldValue, newValue in
                    handleReplyChange(old: oldValue, new: newValue)
                },
                onReturn: { currentText in
                    guard !sending, !replyDictating,
                          !replyAttachments.isEmpty
                            || !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { return }
                    ctrlArmed = false
                    sendTapped(currentText)
                },
                onPasteFile: pasteReplyAttachment,
                fixedHeight: editorHeight
            )
            .frame(minWidth: 0, maxWidth: .infinity)
        } accessory: {
            replyAttachmentStrip
        } leading: {
            Button {
                terminalCollapseToken += 1
                ctrlArmed = false
                replyFocused = false
                terminalInputFocused = false
            } label: {
                ComposerActionIcon(image: Image("ComposerKeyboard"))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Collapse keyboard")
        } actions: {
            HStack(spacing: 4) {
                ComposerAttachButton(busy: loadingReplyAttachment) { openReplyAttachSheet() }
                    .disabled(sending || autoDelivering || loadingReplyAttachment)
                    .accessibilityIdentifier("terminal-attach-button")
                MicButton(text: $reply,
                          isActive: isForeground && !autoDelivering, recording: $replyDictating,
                          onStart: { ctrlArmed = false })
                    .fixedSize()
                    .disabled(sending || autoDelivering)
                // One slot for Send and Saved Prompts, so the Send press survives the swap
                // the clearing composer makes in the same frame.
                ZStack {
                    if !hasReplyContent {
                        SavedPromptsMenu(onSelect: usePrompt)
                            .disabled(sending || autoDelivering || replyDictating)
                    } else {
                        Button {
                            sendTapped()
                            terminalInputFocused = false
                            // A device behaviour, not layout: only the iPhone keyboard is always
                            // docked full-width over the pane, hiding the reply just sent and the
                            // agent's answer, so Send puts it away there. iPad's can float or be
                            // hardware and stays up. Holds on both iPhone Duo displays (idiom .phone).
                            if UIDevice.current.userInterfaceIdiom == .phone {
                                terminalCollapseToken += 1
                                replyFocused = false
                            }
                        } label: {
                            ComposerActionIcon(image: Image("ComposerSend"), primary: true, busy: sending,
                                               progress: replyUploader.sendProgress(replyAttachments, sending: sending))
                        }
                        .disabled(!canSend)
                        .fixedSize()
                        .accessibilityLabel("Send reply")
                        .accessibilityIdentifier("terminal-send-button")
                    }
                }
                .modifier(ChatSendPress(trigger: sendPresses))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.top, Self.replyBarTopPadding).padding(.bottom, Self.replyBarBottomPadding)
        // DRAG AND DROP, the other half of "get a file in from a Mac or an iPad". The
        // whole bar is the target, not just the field: a dragged file is aimed at the
        // composer, and a 40-point text view is a cruel thing to hit with a trackpad.
        // `.item` covers everything a Finder or Files drag vends, and each provider goes
        // through the SAME staging path as a paste, so the cap, the type rule and the
        // named-agent guard are shared rather than re-stated.
        .onDrop(of: [.item], isTargeted: $replyDropTargeted) { providers in
            acceptDroppedFiles(providers)
        }
        // THE PAPERCLIP, the same sheet and pickers as the Gram page and the guest pane.
        // Picks land in the same chip strip and send through the same
        // `sendPromptWithAttachments` as a paste or a drop.
        .composerAttachPicker(
            isPresented: $showReplyAttachSheet, loading: $loadingReplyAttachment,
            room: { ComposerStaging.maxAttachments - replyAttachments.count }
        ) { outcome in
            let picked = outcome.files.map {
                ComposerAttachment(name: $0.name, mime: $0.mime, isImage: $0.isImage, staged: $0.staged)
            }
            replyAttachments += picked
            startReplyUploads(picked)
            actionNote = outcome.note
        }
        .overlay {
            if replyDropTargeted {
                RoundedRectangle(cornerRadius: 28)
                    .strokeBorder(Palette.brand, lineWidth: 2)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
            }
        }
    }
    /// Stages every DROPPED file, one after another.
    ///
    /// A drop hands over the whole selection at once, and staging is serialised by
    /// `loadingReplyAttachment`: calling the paste handler for all of them in a loop
    /// staged the first and dropped the rest on that guard — silently, because it is the
    /// one bail-out with no note — while SwiftUI played the accept animation for the
    /// whole drag. So each provider waits for the previous one to land.
    ///
    /// Only the FILES in a drop are staged: a text item beside them (a Finder drag also
    /// vends the path as text) is not an attachment, and handing it to the paste handler
    /// declined it and stopped the loop before the files after it. The composer bar and
    /// the terminal (#575) both drop through here.
    ///
    /// Returns true when at least one provider is worth staging, which is what tells
    /// SwiftUI the drop was accepted.
    private func acceptDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        let files = TerminalFileDrop.files(in: providers)
        guard !files.isEmpty else { return false }
        Task { @MainActor in
            for provider in files {
                // Up to five seconds per file: a staged copy of a large document off a
                // network volume is slow, and abandoning the rest of the drag is worse
                // than waiting.
                for _ in 0..<100 where loadingReplyAttachment {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                guard !loadingReplyAttachment else { break }
                // A decline is either the cap or a pane that cannot take attachments;
                // both have set their note, and both apply to every remaining file.
                guard pasteReplyAttachment(provider) else { break }
            }
        }
        return true
    }

    /// Stages a pasted FILE of any kind — a photo, a PDF, a log, a zip — as the reply's
    /// attachment. Returns false when this composer cannot take it (a send in flight, a
    /// pane with no named intent agent, or an item that vends no file type), so the caller
    /// pastes normally instead of swallowing the gesture.
    ///
    /// Only IMAGES used to be accepted, which made "paste a photo" work and "paste the log
    /// you just copied" silently do nothing. The delivery path never cared: staging, the
    /// Gram upload channel and the prompt reference are all byte-agnostic, so the image
    /// restriction was in the type filter alone.
    @discardableResult
    private func pasteReplyAttachment(_ provider: NSItemProvider) -> Bool {
        guard !sending, !loadingReplyAttachment, replyTakesAttachment() else { return false }
        // Which representation to stage, and how, is `PastedFile`'s rule, shared with the
        // guest pane's terminal drop.
        guard let type = PastedFile.stagingType(of: provider) else { return false }
        loadingReplyAttachment = true
        ctrlArmed = false
        Task { @MainActor in
            let staged = await PastedFile.stage(provider, as: type)
            finishReplyAttachmentPaste(staged.attachment)
            if let refusal = staged.refusal { actionNote = refusal }
        }
        return true
    }

    /// Whether the reply can take one more attachment, the gate every way in shares:
    /// under the count cap and addressed to a named agent. Uploading to Gram does not
    /// require a ready prompt; the host separately decides whether to accept the prompt.
    private func replyTakesAttachment() -> Bool {
        guard replyAttachments.count < ComposerStaging.maxAttachments else {
            actionNote = "Up to \(ComposerStaging.maxAttachments) attachments at a time."
            return false
        }
        guard agent?.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            actionNote = "Choose a named agent to attach files."
            return false
        }
        return true
    }

    private func openReplyAttachSheet() {
        guard !sending, !loadingReplyAttachment, replyTakesAttachment() else { return }
        ctrlArmed = false
        showReplyAttachSheet = true
    }

    private func finishReplyAttachmentPaste(_ attachment: ComposerAttachment?) {
        loadingReplyAttachment = false
        guard let attachment else {
            actionNote = "Couldn't add that attachment."
            return
        }
        // Belt and braces: `loadingReplyAttachment` already serialises pastes, so this
        // cannot currently fire. It stays because it is the only place that knows the
        // staged bytes exist, and a future concurrent paste path would otherwise append
        // past the cap and leak the temp file.
        guard replyAttachments.count < ComposerStaging.maxAttachments else {
            try? FileManager.default.removeItem(at: attachment.staged.dir)
            actionNote = "Up to \(ComposerStaging.maxAttachments) attachments at a time."
            return
        }
        replyAttachments.append(attachment)
        startReplyUploads([attachment])
        actionNote = nil
    }

    /// Starts uploading newly staged files at once, so Send only has to post them.
    private func startReplyUploads(_ files: [ComposerAttachment]) {
        replyUploader.start(files, client: client, into: $replyAttachments)
    }

    private func removeReplyAttachment(_ attachment: ComposerAttachment) {
        guard let current = replyAttachments.first(where: { $0.id == attachment.id }) else { return }
        replyAttachments.removeAll { $0.id == attachment.id }
        // Cancels a running upload, deletes the staged bytes, and discards a finished upload.
        replyUploader.remove(current)
        // An attachment dropped AFTER its gram message posted (a batch that failed
        // halfway) must not leave that message behind in the agent's inbox.
        if let messageID = current.messageID {
            Task { try? await client.gramDelete(id: messageID) }
        }
    }



    /// Insert a saved prompt into the reply field and send it — the same path a typed reply
    /// takes (`sendTapped` → mode-aware `send(.submitText)` → confirmed `agent.prompt`).
    private func usePrompt(_ p: SavedPrompt) {
        reply = p.text
        sendTapped()
    }

    /// Routes a reader action through InputRouter, then executes the plan. A
    /// refusal is shown, never a silent no-op; a rejection surfaces a clear reason.
    private func send(_ action: InputAction) {
        // EVERY EXPLICIT HOST-SIDE INPUT cancels a retained resize frame, not just the
        // control-bar caps: this funnel also carries the reply submit, the saved-prompt
        // send and the raw sequences. The automatic pre-fill delivery is excluded on
        // purpose — nobody touched anything, so there is no user act to honour.
        if !autoDelivering { userInputToken += 1 }
        if case .submitText(let text) = action, !replyAttachments.isEmpty {
            sendPromptWithAttachments(text, attachments: replyAttachments)
            return
        }
        let mode = agent.map { router.mode(for: $0) } ?? .rawKeys
        let plan = router.plan(action: action, pane: paneID, mode: mode)
        let outgoingModel = showingChat && !autoDelivering ? chatModel : nil
        let outgoingID: String?
        if case .submitText(let text) = action, !text.isEmpty {
            // The bubble enters (and the chat follows it) on the send motion; staged now.
            outgoingID = withAnimation(ChatSendMotion.bubble(reduceMotion: reduceMotion)) {
                outgoingModel?.stageOutgoing(text: text, author: .owner)
            }
        } else {
            outgoingID = nil
        }
        if outgoingID != nil { acceptChatSend() }
        // CLEARED NOW, NOT WHEN THE ROUND TRIP RETURNS.
        //
        // The composer is content-sized and the terminal takes whatever height is left,
        // so clearing the text RESIZES THE PTY. Doing it on the reply meant a second
        // resize hundreds of milliseconds to seconds after the keyboard had already
        // caused one: two reflows, two agent repaints and two retained frames for a
        // single send, the later one landing while the reader was still watching the
        // first settle. Clearing here folds that height change into the keyboard's own
        // sweep.
        //
        // It is still only ever THIS text: restored below if the send was refused or
        // did not land, and never over something typed since (the composer stays
        // editable for the whole round trip — see the `isEnabled` comment in replyBar).
        let clearedReply: String?
        if case .submitText(let text) = action, reply == text, !text.isEmpty {
            clearedReply = text
            // In Chat a multi-line composer shrinks with the bubble; the text clears at once.
            ChatSendMotion.clearComposer(inChat: outgoingModel != nil) { reply = "" }
        } else {
            clearedReply = nil
        }
        // An attachment batch keeps its caption until every upload and its prompt
        // have completed; its separate path above owns the late clear.
        func restoreClearedReply() {
            guard let clearedReply, reply.isEmpty else { return }
            reply = clearedReply
        }
        let isKeyAction: Bool
        switch plan {
        case .keys, .rawText: isKeyAction = true
        default: isKeyAction = false
        }
        // Keep rapid taps responsive, but dispatch their writes in order. A failure
        // cancels keys already queued behind it rather than silently changing a chord.
        let precedingKeySend = keySendTask
        let queuedEpoch = keyFailureEpoch
        let sequence: Int?
        if isKeyAction {
            keySendSequence += 1
            sequence = keySendSequence
        } else {
            sequence = nil
            sending = true
        }
        let task = Task {
            if let precedingKeySend { await precedingKeySend.value }
            defer {
                if !isKeyAction { sending = false }
                if let sequence, keySendSequence == sequence { keySendTask = nil }
            }
            if isKeyAction && keyFailureEpoch != queuedEpoch {
                outgoingModel?.updateOutgoing(outgoingID, state: .notDelivered("An earlier key send failed."))
                return
            }
            if let outgoingModel, let outgoingID,
               !(await outgoingModel.prepareOutgoing(outgoingID, client: client)) {
                restoreClearedReply()
                return
            }
            do {
                switch plan {
                case .prompt(let pane, let text):
                    try await submitPrompt(pane: pane, text: text, outgoingModel: outgoingModel, outgoingID: outgoingID)
                case .text(let pane, let text):
                    try await client.sendText(pane: pane, text: text)
                    outgoingModel?.updateOutgoing(outgoingID, state: .unconfirmed)
                    actionNote = nil
                case .rawText(let pane, let text):
                    try await client.sendText(pane: pane, text: text)
                    outgoingModel?.updateOutgoing(outgoingID, state: .unconfirmed)
                    actionNote = nil
                case .keys(let pane, let keys):
                    try await client.sendKeys(pane: pane, keys: keys)
                    outgoingModel?.updateOutgoing(outgoingID, state: .unconfirmed)
                    actionNote = nil
                case .refused(let reason):
                    actionNote = "not sent: \(reason)"
                    outgoingModel?.updateOutgoing(outgoingID, state: .notDelivered(reason))
                    restoreClearedReply()
                    return
                }
                // The live stream provides output; only a prompt send needs to
                // re-resolve agent status and input mode.
                if !isKeyAction { await refresh() }
            } catch let apiError as APIError {
                outgoingModel?.updateOutgoing(outgoingID, state: TranscriptSendState(rejection: apiError))
                if isKeyAction { keyFailureEpoch += 1 }
                if case .prompt = plan {
                    actionNote = Self.promptRejectionNote(for: apiError)
                    // A post-write/unknown rejection must not put text back for
                    // another tap; a definite pre-write rejection can be retried.
                    if !PromptRejection(apiError).mayHaveReachedAgent {
                        restoreClearedReply()
                    }
                } else if isKeyAction {
                    let prefix = apiError.code == "timeout"
                        ? "Key delivery uncertain — check the terminal"
                        : "send failed: \(apiError)"
                    let suffix = sequence.map { keySendSequence > $0 } == true
                        ? "; later queued keys were not sent" : ""
                    actionNote = prefix + suffix
                } else {
                    actionNote = "send failed: \(apiError)"
                    restoreClearedReply()
                }
            } catch {
                outgoingModel?.updateOutgoing(outgoingID, state: .unconfirmed)
                if isKeyAction {
                    keyFailureEpoch += 1
                    let suffix = sequence.map { keySendSequence > $0 } == true
                        ? "; later queued keys were not sent" : ""
                    actionNote = "Key delivery uncertain — check the terminal before trying again" + suffix
                } else if case .prompt = plan {
                    // A transport failure does not prove whether the server wrote
                    // bytes before losing the response. Don't invite a blind resend.
                    actionNote = "couldn't confirm delivery — check the terminal before sending again"
                } else {
                    actionNote = "send failed: \(error)"
                    restoreClearedReply()
                }
            }
            // The request returned: look for the prompt in the transcript now, not at the
            // next agent event or poll. Off this task, so the composer is not held for it.
            if let outgoingModel, outgoingID != nil {
                Task { await outgoingModel.refresh(client: client) }
            }
        }
        if isKeyAction { keySendTask = task }
    }
    /// Posts every staged attachment (`GramAttachmentSender`), then submits ONE prompt
    /// naming them all. Each file has been uploading since it was added (`replyUploader`),
    /// so Send posts the uploaded ones at once and waits on any still uploading.
    ///
    /// A file that already uploaded or already posted is skipped on a retry: the sender
    /// writes each attachment's `uploadID` / `messageID` back into `replyAttachments` as
    /// soon as it is known, so tapping Send again after a mid-batch failure re-sends only
    /// what did not land.
    private func sendPromptWithAttachments(_ text: String, attachments: [ComposerAttachment]) {
        // The destination is captured BEFORE the first await: `agent` is re-resolved on
        // every refresh, and a batch can span minutes.
        guard !sending else { return }
        guard let target = agent?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty
        else {
            actionNote = "Choose a named agent to attach files."
            return
        }

        let outgoingModel = showingChat ? chatModel : nil
        let outgoingID = withAnimation(ChatSendMotion.bubble(reduceMotion: reduceMotion)) {
            outgoingModel?.stageOutgoing(text: text, author: .owner, files: attachments)
        }
        if outgoingID != nil { acceptChatSend() }
        sending = true
        let precedingKeySend = keySendTask
        // Each file has been uploading since it was added: the sender posts the ones that
        // landed at once, waits on the rest (the Send button shows what is left), and only
        // uploads a file whose pre-upload failed or the host lost.
        let sender = replyUploader.sender(client: client, into: $replyAttachments, post: { _, attachment in
            try await client.gramPost(
                text: "Attachment from the terminal composer.", to: target, attachment: attachment
            ).id
        })
        Task {
            if let precedingKeySend { await precedingKeySend.value }
            replyFailedAttachmentID = nil
            defer { sending = false; replySendingAttachmentID = nil }
            if let outgoingModel, let outgoingID,
               !(await outgoingModel.prepareOutgoing(outgoingID, client: client)) { return }
            let result = await sender.send(
                attachments,
                sending: { replySendingAttachmentID = $0.id }
            ) { file in
                guard let index = replyAttachments.firstIndex(where: { $0.id == file.id }) else { return }
                replyAttachments[index] = file
            }
            let delivered: [GramAttachmentPrompt.Delivered]
            switch result {
            case .success(let files):
                delivered = files
            case .failure(let failure):
                replyFailedAttachmentID = failure.attachment.id
                actionNote = failure.note("send failed: \(failure.error)")
                outgoingModel?.updateOutgoing(outgoingID, state: .notDelivered("Attachment upload did not complete."))
                return
            }
            replySendingAttachmentID = nil

            let prompt = GramAttachmentPrompt.text(text, delivered: delivered)
            // A rejection that may still have reached the agent (`PromptRejection`)
            // counts as DELIVERED here, exactly like a confirmed submit: the prompt is
            // in the agent's PTY, so keeping the chips and the caption would make the
            // one-tap retry submit it a second time (the grams themselves are
            // remembered by message id; it is the prompt that would duplicate). Only a
            // genuine non-delivery keeps everything for the retry.
            do {
                try await submitPrompt(pane: paneID, text: prompt, outgoingModel: outgoingModel, outgoingID: outgoingID)
            } catch let apiError as APIError {
                outgoingModel?.updateOutgoing(outgoingID, state: TranscriptSendState(rejection: apiError))
                guard PromptRejection(apiError).mayHaveReachedAgent else {
                    actionNote = GramAttachmentSender.progressNote(
                        Self.promptRejectionNote(for: apiError),
                        delivered: delivered.count, total: attachments.count)
                    return
                }
                actionNote = Self.promptRejectionNote(for: apiError)
            } catch {
                outgoingModel?.updateOutgoing(outgoingID, state: .unconfirmed)
                actionNote = "couldn't confirm delivery — check the terminal before sending again"
            }
            // The prompt request returned: look for it in the transcript now.
            if let outgoingModel {
                Task { await outgoingModel.refresh(client: client) }
            }
            // Only a definite pre-write rejection keeps the chips and caption
            // for a one-tap retry. A lost response may follow a PTY write, so
            // unknown delivery also clears them rather than duplicating a prompt.
            let deliveredIDs = Set(attachments.map(\.id))
            replyAttachments.removeAll { deliveredIDs.contains($0.id) }
            // Each post consumed its upload: nothing left on the host to discard.
            replyUploader.forget(deliveredIDs)
            if reply == text { reply = "" }
            try? await Task.sleep(nanoseconds: 300_000_000)
            await refresh()
        }
    }


    /// While the Ctrl toggle is armed, consume the next TYPED character and send it
    /// as its control byte instead of adding it to the message. Only reacts to a
    /// single added character (typing) — not deletion or the programmatic clear
    /// after a send — so a backspace can never be misread as a chord.
    private func handleReplyChange(old: String, new: String) {
        // A dictation append (even a single-char first partial) must never be read as a
        // ctrl chord — only real typing arms and fires one.
        guard !replyDictating else { return }
        guard ctrlArmed else { return }
        // Treat ONLY a clean single-char APPEND as a chord: `new` must be `old`
        // plus one trailing character. A mid-cursor insertion or paste (where the
        // added char is NOT the suffix) must NOT be read as a chord — otherwise
        // `removeLast()` would delete the wrong character and `new.last` would send
        // the wrong Ctrl byte (a spurious ^C could interrupt the pane; review HIGH).
        // In that case leave the text untouched and just disarm.
        guard new.count == old.count + 1, new.hasPrefix(old), let typed = new.last else {
            ctrlArmed = false
            return
        }
        guard let ctrl = InputRouter.controlByte(for: typed) else {
            // No control code for this character (a digit, space, emoji…): disarm
            // without consuming it, so the character stays as ordinary text.
            ctrlArmed = false
            return
        }
        ctrlArmed = false
        reply.removeLast()     // the appended char was a chord, not message text
        send(.rawSequence(String(ctrl)))
    }

    /// A successful PTY write is not proof that the agent submitted a turn.
    /// Keep its receipt visible rather than inviting a duplicate send.
    private func submitPrompt(pane: String, text: String,
                              outgoingModel: ChatModel? = nil, outgoingID: String? = nil) async throws {
        outgoingModel?.updateOutgoing(outgoingID, state: .sending, wireText: text)
        let result = try await client.prompt(
            pane: pane, text: text,
            waitUntil: HerdrClient.anyAgentStatus, timeoutMs: 6000)
        // This pane is the owner's: a delivered prompt counts toward the GitHub star card.
        GitHubStarPrompt.recordPrompt(author: .owner, delivery: result, in: .standard)
        switch result {
        case .submitted:
            actionNote = nil
            outgoingModel?.updateOutgoing(outgoingID, state: .submitted)
        case .writtenToPty:
            outgoingModel?.updateOutgoing(outgoingID, state: .unconfirmed)
            actionNote = outgoingModel == nil ? "Sent to terminal; agent submission not verified" : nil
        case nil:
            outgoingModel?.updateOutgoing(outgoingID, state: .unconfirmed)
            actionNote = outgoingModel == nil ? "couldn't confirm delivery — check the terminal before sending again" : nil
        }
    }

    /// Maps a prompt rejection to a note the reader can act on — no more silent
    /// non-delivery, and no false "send failed" for text the agent may already have.
    ///
    /// Driven by the same `PromptRejection` the send paths use to decide whether to
    /// hand the text back, so the note can never say "failed" while the composer stays
    /// empty, or "sent" while the text comes back for a resend.
    private static func promptRejectionNote(for error: APIError) -> String {
        switch PromptRejection(error) {
        case .unconfirmed:
            return "Couldn't tell whether the prompt reached the terminal — check before sending again"
        case .writtenUnverified:
            return "Sent to terminal; agent submission not verified"
        case .submittedStatusUnknown:
            return "Prompt submitted; requested agent state not confirmed — check the terminal"
        case .leftInComposer:
            return "left unsubmitted in the agent's prompt — tap Enter to send it"
        case .notDelivered:
            break
        }
        switch error.code {
        case "agent_blocked", "agent_input_pending":
            // The agent is showing a menu (plan-approval / question). Routing normally
            // switches to raw keys when this is detected; if a send still races the
            // status here, tell the reader they can type the answer or use the keycaps.
            return "agent is asking — type your answer or use the keys, then Enter"
        case "agent_not_ready":
            return "agent not ready, try again"
        case "agent_prompt_not_received":
            return "not delivered, try again"
        default:
            return "send failed: \(error)"
        }
    }

    // MARK: data

    /// The live terminal (`LiveTerminalView`) renders the pane output itself from
    /// the raw byte stream, so refreshing here is only about the agent: re-resolve
    /// it so the status badge and input mode track the live pane. (There is no
    /// snapshot read anymore — the stream is the source of truth for output.)
    private func refresh() async {
        await reresolveAgent()
    }

    /// Re-resolves this pane's agent so the status badge and input mode track the
    /// live pane — a fresh spawn flips rawKeys→intent HERE once its composer is up.
    /// A failed lookup or an absent pane KEEPS the prior value: never downgrade a
    /// known agent to nil (would drop intent → rawKeys). It ALSO keeps the prior
    /// agent when the live entry is the same agent but has transiently LOST its
    /// composer (a server hiccup / restart) — flipping intent → rawKeys there would
    /// re-expose the raw-send path for a pane that was promptable a tick ago.
    private func reresolveAgent() async {
        guard let live = try? await client.agentList().first(where: { $0.paneID == paneID }) else { return }
        // Hold the prior agent ONLY when the SAME NAMED agent transiently loses its
        // composer (a server hiccup) — flipping intent → rawKeys there would
        // re-expose the raw-send path for a pane promptable a tick ago. Identity is
        // the agent NAME, not the kind: replacing one claude with another claude
        // must ADOPT the new one, not inherit stale composer/status. An unnamed or
        // renamed live entry is a different identity → adopt (fail loud, not sticky).
        let sameNamedAgent = live.name != nil && live.name == agent?.name
        let priorWasIntent = agent.map { router.mode(for: $0) == .intent } ?? false
        let liveLostComposer = sameNamedAgent && router.mode(for: live) != .intent
        // A genuine MENU/blocked state is NOT a transient composer hiccup — adopt it so
        // the app can drive the menu with raw keys (answer a plan-approval / AskUserQuestion).
        // Only hold the prior intent agent for a true composer blip (composer nil, not blocked).
        if priorWasIntent && liveLostComposer && !live.isAwaitingMenuInput { return }
        agent = live
    }

    /// One prompt-only delivery attempt for a pending pre-fill. The tested
    /// `prefillDelivery` decision governs it: with a pending pre-fill it yields
    /// `.prompt` (deliver) or `.waitForComposer` (do nothing) — NEVER a raw path —
    /// so a pre-filled task can never be typed into a booting shell. Returns whether
    /// it delivered.
    @discardableResult
    private func deliverPrefillOnce() async -> Bool {
        let ready = (try? await client.isPromptable(pane: paneID)) == true
        switch router.prefillDelivery(pendingPrefill: pendingPrefill, isPromptable: ready) {
        case .prompt:
            do {
                let delivery = try await client.prompt(pane: paneID, text: reply)
                // The owner's task from New Agent is a prompt like any other (#602).
                GitHubStarPrompt.recordPrompt(author: .owner, delivery: delivery, in: .standard)
                reply = ""
                pendingPrefill = false
                actionNote = nil
                await refresh()
                return true
            } catch {
                return false   // composer present but herdr not ready yet, or transient
            }
        case .waitForComposer, .normalReply:
            return false
        }
    }

    /// Auto-delivers a pre-filled task once the agent becomes promptable. Polls
    /// (refreshing the visible pane each tick so the boot is watchable) and delivers
    /// ONLY via prompt. Bounded polling: after ~120s it stops polling to save
    /// round-trips but KEEPS the task protected (pendingPrefill stays true), so the
    /// re-enabled Send still routes through the prompt-only path — never rawKeys.
    /// Nothing is lost and the shell-execution hazard cannot reappear.
    private func deliverPrefillIfNeeded() async {
        guard pendingPrefill else { return }
        autoDelivering = true
        defer { autoDelivering = false }
        let maxTicks = 80                       // 80 × 1.5s ≈ 120s
        var ticks = 0
        while pendingPrefill && !Task.isCancelled {
            if reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pendingPrefill = false; return }
            if await deliverPrefillOnce() { return }
            actionNote = "starting \(title)…"
            ticks += 1
            if ticks >= maxTicks {
                // Give up the AUTO-deliver but NEVER trap the reader: release the lock so
                // the reply bar is fully usable and a manual Send goes through the normal
                // path. The typed task stays in the field for one tap.
                pendingPrefill = false
                actionNote = "couldn't auto-send, tap Send to deliver it"
                return
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }     // don't spin after teardown
            // The live terminal already shows the boot as it streams; no snapshot
            // read is needed to keep the pane visible while we wait to deliver.
        }
    }

    /// The reply-bar send action. A pending pre-fill is delivered PROMPT-ONLY
    /// (never rawKeys, at any time); a normal reply uses the usual routing.
    private func sendTapped(_ text: String? = nil) {
        // An explicit Send ALWAYS takes over from any pending auto-deliver and goes
        // through the normal prompt path (`send` → agent.prompt, server-gated). It must
        // never be gated on the pre-fill delivery succeeding — that is exactly what could
        // trap the reader on a stuck pre-fill with the reply bar locked.
        pendingPrefill = false
        send(.submitText(text ?? reply))
    }

    /// A Chat send staged its bubble: the light impact and the Send press (none under
    /// Reduce Motion).
    private func acceptChatSend() {
        if ChatSendMotion.acceptSend(reduceMotion: reduceMotion) { sendPresses += 1 }
    }
}
