#if canImport(UIKit)
import CoreText
import SwiftUI
import UIKit
import SwiftTerm
import GameController
import HerdrKit
import os

/// One-shot claim gate: `claim()` returns true to EXACTLY ONE caller, so a
/// `CheckedContinuation` raced between two tasks (a read vs a timeout) is resumed at
/// most once. Used by the scrollback backfill to bound a read that the transport may not
/// cancel — the loser is abandoned rather than awaited.
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

private struct TerminalGeometryTarget: Equatable {
    let cols: Int
    let rows: Int
    let cellWidthPx: UInt32
    let cellHeightPx: UInt32
}

/// One find-bar state: what to look for and which occurrence to sit on.
///
/// `generation` is what makes "next" work. Term and options alone cannot distinguish
/// "the user typed another character" from "the user pressed next on the same term",
/// and SwiftTerm's own engine resumes from the previous match only while the term is
/// UNCHANGED (`SearchEngine.swift:70`). So the host bumps the generation for a
/// next/previous step and leaves it alone while editing the term.
struct FindRequest: Equatable {
    var term: String
    /// Bumped once per next/previous step; `direction` says which way that step goes.
    var generation: Int = 0
    var direction: Direction = .forward

    enum Direction { case forward, backward }
}

/// A live SwiftTerm terminal for a herdr pane (#40). It consumes
/// `client.streamTerminal(pane:)` — herdr's raw PTY byte firehose — and feeds the
/// bytes to a real VT emulator, so the phone renders a grid-faithful terminal
/// instead of a reflowed snapshot.
///
/// A deliberate terminal tap gives SwiftTerm focus for direct PTY typing on iPhone,
/// iPad (software or hardware keyboard), and iOS apps running on Apple Silicon Macs.
/// SwiftTerm's delegate forwards its key→bytes translation to the PTY. The reply/Send
/// bar remains the deliberate path for agent prompts and saved messages. SCROLL
/// remains constrained: a pan on the alternate screen sends wheel/arrow sequences
/// to the agent (see `handleScrollPan`), never a keystroke.
///
/// Geometry: the view reports its own laid-out grid to the server via `setPTYSize`
/// so the stream is generated at the phone's width. While the terminal view is open
/// the phone OWNS the pane geometry (`lock:true`, Fix A): the server pins the shared
/// PTY to the phone's fit, so the agent's TUI lays out at the phone's width and fits
/// crisply with no horizontal overflow. A co-viewing desktop narrows to that width
/// while the app views the pane.
///
/// The lock is handed back with one `lock:false` (see `releaseGeometryOwnership`) on
/// teardown (`stop()`: close or LRU eviction), when the window scene goes to the background
/// (`setSceneBackgrounded`), and when a keep-mounted pane has stayed HIDDEN for
/// `TerminalSizeClaim.hiddenGraceNanos` (`setForeground`). The grace exists because releasing
/// on every hide made every switch between two loaded panes cost two winsize changes — one
/// when the TUI reclaimed its layout width, one when re-fronting re-pinned ours — and
/// therefore two full agent repaints, which read as the terminal rescrolling on every agent
/// switch. A claim that is never released (crash, kill, lost network) lapses on the short
/// `TerminalSizeClaim.leaseTTLMillis`, so another device viewing the agent is not held at
/// this device's width for long.
struct LiveTerminalView: UIViewRepresentable {
    let client: HerdrClient
    let paneID: String
    /// Called when the reader swipes horizontally to page between agents: +1 for the
    /// next agent (swipe left), -1 for the previous (swipe right). Nil (or a no-op) when
    /// there is no list context to page through. Refreshed on every update so the
    /// closure never captures a stale view.
    var onNavigate: ((Int) -> Void)? = nil
    /// Whether this pane is the one on screen. A keep-mounted pane that goes offscreen
    /// (another agent is fronted, or we're back on the list) stays subscribed and keeps the
    /// PTY width-lock for a short grace, then RELEASES it so it stops pinning a co-viewing
    /// desktop to this device's width while nobody's looking; it re-takes the lock when fronted
    /// again. Only the lock lifecycle changes — the stream and the SwiftTerm view stay warm.
    var isForeground: Bool = true
    /// Another surface (the Chat view) is drawn over this terminal, which stays mounted and
    /// sized under it. The terminal view is then hidden: on iOS 27 neither SwiftUI's
    /// `.accessibilityHidden` and `.opacity(0)` on the representable nor accessibility flags
    /// written here keep it out of the accessibility hit test, where it answered for the chat
    /// drawn above it. Hiding it stops nothing else: the stream, the emulator and the layout
    /// (frames, PTY size) keep running, and it draws again when shown.
    var accessibilityCovered: Bool = false
    /// Inactive or background (another app in front on Mac, Control Center, app switcher):
    /// the front pane's caret holds still too, like the status dot (#427).
    @Environment(\.scenePhase) private var scenePhase
    /// The host's window scene is in the background (set on `.background`, cleared on
    /// `.active`). The width-lock is released at once and not re-taken until it clears.
    /// Owned by the host, together with its return-to-front remount, so a pane that is about
    /// to be remounted is dismantled rather than re-claiming under its old viewer id first.
    var sceneBackgrounded: Bool = false
    /// Whether the terminal itself should hold keyboard focus (drive keys straight to the PTY).
    /// A deliberate tap on the terminal takes focus on every iOS idiom, including
    /// iPad software keyboards and iOS apps running on Apple Silicon Macs.
    /// Refreshed on every update.
    var wantsTerminalKeyFocus: Bool = false
    /// Guest view-only: no input or focus and no bytes to the PTY. Geometry is separate: a
    /// guest still proposes its own grid unless `fitsStreamWidth`.
    var viewOnly: Bool = false
    /// Follow the stream's grid and fit its cols to the width instead of proposing a size. A
    /// guest's session switches to this when the host refuses guest resizing.
    var fitsStreamWidth: Bool = false
    /// Called once when the host refuses this view's `pane.set_pty_size` for good
    /// (`guest_forbidden`, a host older than guest resizing). The view has already fallen
    /// back to fitting the stream to its width; the host keeps that for the session.
    var onResizeRefused: () -> Void = {}
    /// Bumped by the reply bar's chevron to request a DELIBERATE collapse, as opposed to the many
    /// incidental body passes that also see `wantsTerminalKeyFocus == false`. Only a deliberate
    /// collapse may resign the responder while a selection is held: see the resign branch in
    /// `updateUIView`, both for what went wrong when the two were indistinguishable and for why
    /// this is a monotonic token rather than a bool the host resets.
    var collapseToken: Int = 0
    /// Called after a terminal tap requests direct PTY input. The parent owns the
    /// SwiftUI focus state so a reply submission can dismiss the keyboard reliably.
    var onTerminalFocusRequest: () -> Void = {}
    /// Called on the main actor when the live stream ends (nil = closed cleanly), before
    /// the view decides whether to reconnect. Lets a host react to why it ended.
    var onStreamEnded: (Error?) -> Void = { _ in }
    /// Bumped by the host to jump this pane to its newest output. `updateUIView`
    /// compares it against the value the Coordinator last executed, so each
    /// increment performs exactly one jump.
    var jumpToTailToken: Int = 0
    /// Reports whether the pane is parked at its newest output. Invoked ONLY when
    /// the value changes, so it cannot re-render SwiftUI on every scroll frame.
    var onTailStateChange: (Bool) -> Void = { _ in }
    /// Reports what the history capsule at the top should show (see
    /// `TerminalHistoryCapsule`): an older page loading, the offer to load one, or nothing.
    /// Invoked only when the value changes.
    var onHistoryPagingChange: (TerminalHistoryPaging) -> Void = { _ in }
    /// Bumped by the host when the reader taps "Load earlier output": each increment
    /// requests one page, compared like `jumpToTailToken`.
    var loadEarlierHistoryToken: Int = 0
    /// The host's CURRENT belief about tail state, used to seed a fresh Coordinator on
    /// a remount. Without it a `streamGen` remount resets the Coordinator's baseline to
    /// `true` while the host still holds `false`, and the next jump's `atTail: true`
    /// dedupes away as "no change", leaving the pill visible after a completed jump.
    var isAtTail: Bool = true
    /// Terminal font size in points (the `terminal.fontSize` preference). Applied
    /// in-place via `Coordinator.applyFont` when it changes — re-lays-out the grid,
    /// no view recreation.
    var fontSize: CGFloat = 12.5
    /// Instant typing (`predictiveEcho` preference, a `PredictionEngine.Mode` raw value).
    /// A view-only pane never predicts whatever this says.
    var predictiveEcho: String = PredictiveEchoSetting.defaultValue
    /// Shared with the host so it can ask whether this pane's stream is alive before
    /// deciding to remount on foreground. Written by the Coordinator, read by the host.
    var liveness: StreamLiveness? = nil
    /// The host's one-shot Ctrl toggle, shared so a Ctrl tap applies to whichever
    /// input path is active: the reply field (`handleReplyChange`) or, now, direct
    /// typing into the terminal, where SwiftTerm's own `controlModifier` does the
    /// encoding and reports back when it was consumed.
    @Binding var controlArmed: Bool
    /// Monotonic count of inputs the HOST delivered on this pane's behalf — the
    /// control-bar keycaps and raw-sequence caps. They are SwiftUI buttons outside
    /// `TerminalSurfaceView`, so neither its `hitTest` nor `send` ever observes them,
    /// and a retained resize frame would otherwise stay on screen while their bytes
    /// reached the agent. A token, not a Bool, for the reason `jumpToTailToken` is one:
    /// it cannot be coalesced away by a body pass.
    var userInputToken: Int = 0
    /// The host's current find request, or nil when the find bar is closed.
    ///
    /// A VALUE, not a token: unlike a jump, a search is not a one-shot - the same
    /// request must survive body passes without re-running, and a changed term must
    /// re-run. `updateUIView` compares it against the last request the Coordinator
    /// executed, so typing one character issues exactly one search.
    ///
    /// Closing the bar (nil) clears the highlight; it does NOT jump back to the tail,
    /// because a reader who searched their way into history wants to stay there.
    var findRequest: FindRequest? = nil
    /// Reports `(index, total)` for the current term so the header can render "3 of 17",
    /// and `(0, 0)` when nothing matches. Invoked only when the pair changes.
    var onFindResult: (Int, Int) -> Void = { _, _ in }
    /// Files dropped anywhere on the terminal go to the pane's composer (#575); nil while
    /// the surface takes no drops. See `TerminalFileDrop`.
    var fileDrop: TerminalFileDrop? = nil
    /// The host's own copy of the stuck-stream threshold, so it judges staleness by the
    /// same rule the watchdog reconnects on rather than a second, drifting number.
    static var streamStuckTimeout: TimeInterval { Coordinator.streamStuckTimeout }
    /// DEBUG builds take `HERDR_STEADY_CARET` for UI tests that tap with a pane on screen: a
    /// blinking caret never lets XCUITest's "wait for the app to idle" finish (60 s a tap).
    private static let steadyCaret: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["HERDR_STEADY_CARET"] != nil
        #else
        return false
        #endif
    }()

    func makeCoordinator() -> Coordinator { Coordinator(client: client, paneID: paneID) }

    func makeUIView(context: Context) -> TerminalSurfaceView {
        // ONE TERMINAL PER COORDINATOR. On iOS 27 SwiftUI can call makeUIView again for the
        // same view identity, with the same Coordinator, while the first call is still
        // running: building the terminal view below runs a nested graph update that makes
        // the representable again (run 40790301938: `1341ms ix:b makeUIView`, `1399ms ix:b
        // makeUIView`, then `1585ms attach hadSurface=false` from the nested call and `2069ms
        // attach hadSurface=true` from the outer one, whose host is the one kept; the nested
        // call's view is freed without dismantleUIView). Each attach started a `pane.stream`,
        // so the pane opened twice and the second cancelled the first. The Coordinator's
        // stream, emulator and geometry state belong to the surface it attached first, so a
        // repeated call, nested or later, hands that surface back and SwiftUI moves it into
        // the host it keeps.
        if let mounted = context.coordinator.mountedSurface { return mounted }
        // BEFORE attach, which starts the stream and the geometry drain.
        context.coordinator.viewOnly = viewOnly
        context.coordinator.setPredictionMode(viewOnly ? .off : PredictiveEchoSetting.mode(predictiveEcho))
        context.coordinator.hostFitsStreamWidth = fitsStreamWidth
        context.coordinator.onResizeRefused = onResizeRefused
        context.coordinator.paneFontSize =
            min(max(fontSize, Coordinator.minFontSize), Coordinator.maxFontSize)
        let view = ReadOnlyTerminalView(frame: .zero, font: context.coordinator.paneFont)
        let surface = TerminalSurfaceView(terminal: view)
        context.coordinator.onNavigate = onNavigate
        context.coordinator.onTerminalFocusRequest = onTerminalFocusRequest
        context.coordinator.onStreamEnded = onStreamEnded
        // BEFORE attach, which starts the stream: the first frame must be recorded, or a
        // pane that connects while the app is backgrounding looks stale on return.
        context.coordinator.liveness = liveness
        // SEED both baselines from the host before the first `updateUIView`. A remount
        // (the header refresh bumps `streamGen`) builds a fresh Coordinator while the
        // host's `@State` survives, so defaulting them replays the last jump as a second
        // Ctrl+End and mis-dedupes the tail callback.
        context.coordinator.seedBaselines(jumpToTailToken: jumpToTailToken, atTail: isAtTail,
                                          userInputToken: userInputToken,
                                          loadEarlierHistoryToken: loadEarlierHistoryToken)
        surface.terminal.getTerminal().preservesScrollbackLayout = true
        // The nested call described above has attached its own surface by now: keep that
        // one (its stream is already open) and drop the view built here.
        if let mounted = context.coordinator.mountedSurface { return mounted }
        context.coordinator.attach(surface)
        return surface
    }

    func updateUIView(_ uiView: TerminalSurfaceView, context: Context) {
        let terminalView = uiView.terminal
        context.coordinator.onNavigate = onNavigate
        context.coordinator.onTerminalFocusRequest = onTerminalFocusRequest
        context.coordinator.onStreamEnded = onStreamEnded
        // Live accessors, refreshed every pass: a captured Bool would be a snapshot of
        // the state as it was when this body ran, which is exactly the race that makes
        // an immediate keypress after a Ctrl tap miss the modifier.
        context.coordinator.controlArmedGetter = { controlArmed }
        context.coordinator.controlArmedSetter = { controlArmed = $0 }
        // A remount builds a fresh Coordinator while the host's box survives, so re-point
        // it every pass rather than only at mount.
        context.coordinator.liveness = liveness
        context.coordinator.onTailStateChange = onTailStateChange
        context.coordinator.onHistoryPagingChange = onHistoryPagingChange
        // setForeground BEFORE performJumpToTail, deliberately. The jump sends bytes and is
        // now foreground-guarded, and a guard that reads a flag this pass has not yet
        // written is not a guard at all.
        context.coordinator.viewOnly = viewOnly
        context.coordinator.setPredictionMode(viewOnly ? .off : PredictiveEchoSetting.mode(predictiveEcho))
        context.coordinator.hostFitsStreamWidth = fitsStreamWidth
        context.coordinator.onResizeRefused = onResizeRefused
        // Before setForeground: a return to the front that also re-fronts this pane must
        // re-claim exactly once, from whichever of the two flips last.
        context.coordinator.setSceneBackgrounded(sceneBackgrounded)
        context.coordinator.setForeground(isForeground)
        // A kept-alive pane behind another pane, the list, Gram or Settings, and any pane
        // while the scene is not active, holds its caret steady: the blink is a repeating
        // animation that keeps the window compositing (#427).
        terminalView.caretBlinkPaused = !isForeground || scenePhase != .active || Self.steadyCaret
        terminalView.isHidden = accessibilityCovered
        context.coordinator.directFocusIntended = wantsTerminalKeyFocus && !viewOnly
        context.coordinator.performJumpToTail(ifTokenChanged: jumpToTailToken)
        context.coordinator.loadEarlierHistory(ifTokenChanged: loadEarlierHistoryToken)
        // Before the focus decision below: a host-delivered keycap is the user acting
        // on this pane, so it must drop a retained frame at once.
        context.coordinator.noteHostInput(ifTokenChanged: userInputToken)
        // After noteHostInput: a find is the user acting on this pane too, so any retained
        // resize frame must already be gone before the search scrolls the view underneath.
        context.coordinator.onFindResult = onFindResult
        context.coordinator.performFind(findRequest)
        uiView.dropTarget.handler = fileDrop
        // A deliberate terminal tap takes focus on every idiom; a composer/find tap
        // relinquishes it, and a background pane never keeps it. SwiftTerm selection
        // needs the responder for Copy, so incidental updates do not resign
        // mid-selection.
        //
        // A BACKGROUNDED pane drops its selection UNCONDITIONALLY and resigns if it holds
        // the responder. The clear sits OUTSIDE the first-responder test on purpose: nested
        // inside it, a pane holding a selection WITHOUT the responder kept it across
        // backgrounding, so the sentence above was still not literally true. That is the
        // third time this claim has been written wider than the code, so the code now
        // matches the claim instead of the comment being narrowed again.
        //
        // Only a FOREGROUND pane mid-selection keeps its responder, which is what stops a
        // SwiftUI body pass from hiding the Copy menu.
        if wantsTerminalKeyFocus && !viewOnly {
            if !terminalView.isFirstResponder { _ = terminalView.becomeFirstResponder() }
        } else {
            if !isForeground { terminalView.clearSelection() }
            // THE SELECTION GUARD MUST NOT OUTRANK AN EXPLICIT COLLAPSE, and it did.
            //
            // `!uiView.hasActiveSelection` exists so an incidental SwiftUI body pass cannot yank
            // the responder mid-selection and take the Copy menu with it. But the collapse chevron
            // reaches this same else-branch by clearing both focus flags, and while a word was
            // selected the guard refused the resign — so the keyboard stayed up, and because
            // clearing the flags also hides the chevron, its only dismiss affordance vanished with
            // it. The reader was left with a keyboard over 40% of the pane and no way down.
            // Measured and reported by review; the chevron was the feature added to fix exactly
            // this class of problem, so it failing in the PR's own headline flow is the worst place
            // for it.
            //
            // `collapseToken` distinguishes the two cases: an incidental pass still respects the
            // selection, while a deliberate collapse resigns regardless and keeps the selection
            // intact in the model. Resigning hides the system Copy menu, which is the honest
            // consequence of asking for the keyboard to go away — and the selection is still
            // there, so a double tap re-presents it without re-selecting. Review endorsed that
            // behaviour choice; what it rejected was my first MECHANISM for it.
            //
            // A MONOTONIC TOKEN, NOT A BOOL SET-AND-ASYNC-RESET, and this is the second defect
            // review found in this one gate. My first fix set a `collapseRequested` flag and
            // cleared it in `DispatchQueue.main.async`, intending "true for exactly the next body
            // pass". That does not hold: the GCD main-queue drain runs BEFORE SwiftUI's deferred
            // update flush, so this method would have observed the flag already false, refused the
            // resign, and reproduced the very defect it was written to fix — an INERT fix that
            // would have tested green as an unchanged bug.
            //
            // A token cannot be coalesced away. It carries no lifetime and no assumption about
            // which pass reads it: whichever pass observes a value the Coordinator has not
            // consumed is the collapse, and every later pass sees a consumed one. This is the
            // pattern `performJumpToTail(ifTokenChanged:)` already uses two dozen lines up, so
            // it is also the pattern this file had already settled on for exactly this problem.
            //
            // Consumed HERE rather than beside `performJumpToTail`, so a pass that re-requests
            // focus cannot silently eat a collapse it was never going to act on.
            let deliberateCollapse = context.coordinator.consumeCollapse(ifTokenChanged: collapseToken)
            if terminalView.isFirstResponder,
               viewOnly || !isForeground || deliberateCollapse || !terminalView.hasActiveSelection {
                terminalView.resignFirstResponder()
                // Losing the keyboard is an explicit dismissal: an armed one-shot must not
                // survive to modify whatever is typed next, in this pane or another.
                context.coordinator.cancelArmedControl()
                // A DEBUG-only probe so a UI test can observe WHICH branch resigned. Without
                // this call `fr` would only ever be sampled at gesture time and the collapse would
                // stay unobservable — which is precisely how the inert first mechanism escaped.
                // Compiled out in Release and inert without the mock env var.
                context.coordinator.publishSelectionProbe(deliberateCollapse ? "collapseResign" : "passResign")
            }
        }
        // Fitting the stream to the width owns the font, so `fontSize` is ignored.
        if context.coordinator.fitsStreamWidth {
            context.coordinator.fitFontToStreamWidth()
        } else {
            context.coordinator.applyFont(size: fontSize)
        }
        // After the focus decision above, so the native modifier matches the input path
        // that is actually live.
        context.coordinator.applyControlModifier()
    }

    static func dismantleUIView(_ uiView: TerminalSurfaceView, coordinator: Coordinator) {
        coordinator.stop()
        coordinator.mountedSurface = nil
    }

    /// Holds the terminal and, during a resize, the retained frame that covers it.
    ///
    /// The terminal object, its first responder, its gestures, its delegate and its
    /// stream are the SAME objects across every resize: only this container's bounds
    /// change. The cover is a sibling view, so it can never be mistaken for terminal
    /// content, and the capture happens HERE - before the terminal's frame is
    /// assigned - because after that assignment the old rendering is already gone.
    final class TerminalSurfaceView: UIView {
        let terminal: ReadOnlyTerminalView
        /// Called immediately before the terminal's frame changes, so the owner can
        /// retain the current frame. Returns nothing: covering is the owner's choice.
        var onGeometryWillChange: (() -> Void)?
        /// While live-anchored, the grid the CONTAINER fits. The terminal's own frame is
        /// deliberately not the container then, so its proposals would be the old grid.
        var onAnchoredFit: ((_ cols: Int, _ rows: Int) -> Void)?
        /// After a layout pass that changed the container's width (rotation, split view).
        var onWidthChange: (() -> Void)?
        private var reportedWidth: CGFloat = 0
        /// The terminal's file drop target; the pane's handler is refreshed every update.
        let dropTarget: TerminalDropTarget

        /// A software-keyboard transition on iPhone: the terminal keeps its current grid
        /// and pixel size and stays LIVE, positioned inside the moving container, until
        /// the stream commits the grid the keyboard's sweep ended on.
        private(set) var isLiveAnchored = false

        private var cover: UIView?
        private var coverContent: UIView?
        private var coverContentSize: CGSize = .zero

        var isCovered: Bool { cover != nil }
        /// Monotonic receipt for DEBUG/UI tests. Sampling `isCovered` is racy by design:
        /// a valid cover may live for only a few frames.
        private(set) var coverInstallCount = 0
        /// How long the most recently removed cover stayed up, for the same receipts: the
        /// difference between "settled promptly" and "sat until the ceiling".
        private(set) var lastCoverMilliseconds = 0
        private var coverInstalledAt: CFTimeInterval?

        init(terminal: ReadOnlyTerminalView) {
            self.terminal = terminal
            dropTarget = TerminalDropTarget()
            super.init(frame: .zero)
            clipsToBounds = true
            backgroundColor = terminal.nativeBackgroundColor
            addSubview(terminal)
            addInteraction(UIDropInteraction(delegate: dropTarget))
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            if !isLiveAnchored, terminal.frame != bounds {
                // May start a live anchor, so the target is read after it.
                onGeometryWillChange?()
            }
            guard isLiveAnchored else {
                if terminal.frame != bounds { terminal.frame = bounds }
                layoutCover()
                reportWidthChange()
                return
            }
            if terminal.getTerminal().rows == anchoredRows {
                placeAnchored(anchoredFrame())
                proposeAnchoredFit()
            } else {
                // The stream committed the container's grid: follow the container again,
                // in the same pass as the reflow, so the two land on one frame.
                endLiveAnchor()
            }
            layoutCover()
            reportWidthChange()
        }

        private func reportWidthChange() {
            guard bounds.width != reportedWidth else { return }
            reportedWidth = bounds.width
            onWidthChange?()
        }

        // MARK: live keyboard anchor
        //
        // The keyboard resizes the container over ~0.25s, but the PTY is resized once,
        // at the end. Until that grid reaches the stream, a terminal laid out at the
        // container's height would show the TOP of a grid taller than the pane (the
        // prompt cut off under the keyboard) or a short grid with a gap below. It keeps
        // its grid's pixel height instead and stays live, placed where the emulator's
        // own resize to the container's fit will leave the same rows, so the commit
        // reflows in place instead of jumping.

        private var anchoredFit: (cols: Int, rows: Int, cell: CGSize)?
        private var anchoredHeight: CGFloat = 0
        private var anchoredRows = 0

        /// Idempotent: the anchor holds the grid it started on until that grid is replaced.
        func beginLiveAnchor() {
            let rows = terminal.getTerminal().rows
            guard !isLiveAnchored, terminal.frame.height > 0 else { return }
            isLiveAnchored = true
            // Never shorter than the grid: a sweep re-anchored mid-animation (the reader
            // took control) finds the frame already squeezed.
            anchoredHeight = max(terminal.frame.height, CGFloat(rows) * terminal.cellSize.height)
            anchoredRows = rows
            // The first layout proposes the container's fit; `requestGeometry` dedups.
            anchoredFit = nil
            setNeedsLayout()
        }

        /// Back to following the container. The relayout is this view's own, so it is not
        /// reported as a geometry change: that would retain a frame for it.
        func endLiveAnchor() {
            guard isLiveAnchored else { return }
            isLiveAnchored = false
            anchoredFit = nil
            placeAnchored(bounds)
        }

        /// New output can move the cursor, and a committed grid ends the anchoring: lay
        /// out now, before the paint this output queued.
        func contentDidChange() {
            guard isLiveAnchored else { return }
            setNeedsLayout()
            layoutIfNeeded()
        }

        /// Moves the anchored terminal. A new HEIGHT leaves the scroller where the old one
        /// put it (SwiftTerm re-pins only when the emulator itself changes), which showed
        /// the top of the grid with the prompt below the view; a same-grid commit re-pins
        /// it and repaints.
        private func placeAnchored(_ frame: CGRect) {
            guard terminal.frame != frame else { return }
            let resized = terminal.frame.size != frame.size
            terminal.frame = frame
            if resized {
                let emulator = terminal.getTerminal()
                terminal.applyTerminalSize(cols: emulator.cols, rows: emulator.rows)
            }
        }

        /// Proposes the container's fit when it changes (the keyboard moving, a font
        /// change); the terminal's own frame says nothing about it while anchored.
        func proposeAnchoredFit() {
            guard isLiveAnchored, let fit = containerFit() else { return }
            if let last = anchoredFit, last.cols == fit.cols, last.rows == fit.rows,
               last.cell == fit.cell { return }
            anchoredFit = fit
            onAnchoredFit?(fit.cols, fit.rows)
        }

        /// SwiftTerm's own fit (`processSizeChange`), applied to the container.
        private func containerFit() -> (cols: Int, rows: Int, cell: CGSize)? {
            let cell = terminal.cellSize
            guard cell.width > 0, cell.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
            return (Int(bounds.width / cell.width), Int(bounds.height / cell.height), cell)
        }

        private func anchoredFrame() -> CGRect {
            let spare = bounds.height - anchoredHeight
            let y = anchoredOffset() ?? 0
            return CGRect(x: 0, y: min(max(y, min(0, spare)), max(0, spare)),
                          width: bounds.width, height: anchoredHeight)
        }

        /// How far down the container the anchored terminal must sit so its rows are
        /// exactly where they will be once the emulator is resized to the container's
        /// fit. Follows `Buffer.resize`: shrinking drops rows below the cursor first and
        /// only then scrolls the top into history; growing pulls history back down, and
        /// adds blank rows below once there is none. The scroller then bottom-aligns
        /// whatever is taller than the view. nil for a reader in history, whose place the
        /// emulator restores rather than re-flows: the view stays at the top.
        private func anchoredOffset() -> CGFloat? {
            let emulator = terminal.getTerminal()
            let cell = terminal.cellSize.height
            guard cell > 0, let fit = containerFit(), fit.rows >= 2 else { return nil }
            let rows = anchoredRows, newRows = fit.rows
            let lines = max(rows, Int((terminal.contentSize.height / cell).rounded()))
            let history = lines - rows
            guard emulator.buffer.yDisp >= history else { return nil }
            let inset = terminal.adjustedContentInset.bottom
            // The scroller's resting offset at the tail of `lines` in a view `height` tall.
            func tail(lines: Int, rows: Int, height: CGFloat) -> CGFloat {
                min(CGFloat(lines - rows) * cell, max(0, CGFloat(lines) * cell - height + inset))
            }
            // Old screen row `from` becomes new screen row `to`.
            let from: Int, to: Int, newLines: Int
            if newRows < rows {
                let belowCursor = min(rows - newRows, max(0, rows - 1 - emulator.buffer.y))
                from = rows - newRows - belowCursor
                to = 0
                newLines = lines - belowCursor
            } else {
                let pulled = emulator.isCurrentBufferAlternate ? 0 : min(newRows - rows, history)
                from = 0
                to = pulled
                newLines = lines + newRows - rows - pulled
            }
            // The alternate screen keeps no history: whatever scrolled off is gone.
            let kept = emulator.isCurrentBufferAlternate ? newRows : newLines
            let before = CGFloat(history + from) * cell
                - tail(lines: lines, rows: rows, height: anchoredHeight)
            let after = CGFloat(kept - newRows + to) * cell
                - tail(lines: kept, rows: newRows, height: bounds.height)
            return after - before
        }

        /// Snapshot of the terminal exactly as it is on screen right now, or nil when
        /// UIKit has nothing to hand back (no first paint yet).
        func captureTerminalFrame() -> UIView? {
            guard terminal.bounds.width > 0, terminal.bounds.height > 0 else { return nil }
            return terminal.snapshotView(afterScreenUpdates: false)
        }

        func installCover(_ content: UIView) {
            removeCover()
            let container = UIView(frame: bounds)
            container.clipsToBounds = true
            container.backgroundColor = terminal.nativeBackgroundColor
            container.isUserInteractionEnabled = false
            container.isAccessibilityElement = false
            container.accessibilityElementsHidden = true
            content.isUserInteractionEnabled = false
            container.addSubview(content)
            addSubview(container)
            cover = container
            coverContent = content
            coverContentSize = content.bounds.size
            coverInstallCount += 1
            coverInstalledAt = CACurrentMediaTime()
            layoutCover()
        }

        func removeCover() {
            if let installed = coverInstalledAt, cover != nil {
                lastCoverMilliseconds = Int(((CACurrentMediaTime() - installed) * 1000).rounded())
            }
            coverInstalledAt = nil
            cover?.removeFromSuperview()
            cover = nil
            coverContent = nil
        }

        private func layoutCover() {
            guard let cover, let content = coverContent else { return }
            // The CONTAINER tracks the new bounds; the retained content does NOT MOVE.
            //
            // It used to be pinned to an edge of those bounds — bottom for a tail
            // follower, top for a history reader — which is motion nobody asked for as
            // soon as the bounds themselves are animating. A keyboard dismissal grows
            // this view by the keyboard's height over ~0.25s, so a bottom-pinned picture
            // SLID DOWN the full ~300pt while it was supposed to be HIDING a reflow, and
            // a blank band opened above it. Holding the capture where it was captured is
            // the whole point: a still terminal until the new grid is ready, then one
            // change.
            //
            // The capture comes from `terminal`, whose frame IS these bounds at that
            // moment, so its captured origin is already the correct one. Growth shows
            // background at the edge the layout actually moved; a shrink clips.
            cover.frame = bounds
            content.frame = CGRect(origin: .zero, size: coverContentSize)
        }
    }

    /// A `TerminalView` that supports direct PTY typing with software and hardware
    /// keyboards on every iOS idiom without sacrificing selection and copy.
    ///
    /// SCROLL is the LIBRARY's job now. On a normal (shell) buffer the reader
    /// finger-scrolls the retained scrollback through SwiftTerm's own `UIScrollView`,
    /// native and unmodified. SwiftTerm ≥1.14.0 (we ship 1.15.0) fixed the iOS scroll
    /// wiring (issue #486 / PR #587: a `contentOffset`→`yDisp` sync plus a
    /// `terminal.userScrolling` flag), so a scrolled-up reader holds position even
    /// while output streams. We deliberately do NOT override `contentOffset`, claim the
    /// scroll delegate, or run any follow/hold logic here: doing exactly that on
    /// SwiftTerm 1.11.2 SHADOWED the (then-broken) library and dead-locked scrolling
    /// across ~7 TestFlight builds — the defect was in the library, not this file.
    /// The ONLY scroll code we keep is the ALTERNATE-screen pan
    /// (`Coordinator.handleScrollPan`), which sends wheel/arrow scroll INTO a
    /// full-screen TUI that keeps no scrollback of its own.
    final class ReadOnlyTerminalView: TerminalView {
        /// Selection/Copy and direct terminal typing both need SwiftTerm's responder.
        /// Do not hide the software keyboard on iPad or infer keyboard availability
        /// from GCKeyboard: it can be nil even for an iOS app on a Mac with a keyboard.
        /// False while view-only, so no tap (ours or SwiftTerm's) can take the responder.
        var allowsFocus = true
        override var canBecomeFirstResponder: Bool { allowsFocus }

        override init(frame: CGRect, font: UIFont?) {
            super.init(frame: frame, font: font)
            // Inset-free, matching SwiftTerm's own iOS example host: keeps the grid
            // flush and the library's scroll-offset math (`maxContentOffsetY`) free of a
            // shifting safe-area / keyboard inset.
            contentInsetAdjustmentBehavior = .never
            inputAccessoryView = nil
        }

        // MARK: - one-shot Ctrl for direct typing

        /// Called immediately before UIKit-inserted text reaches SwiftTerm's encoder,
        /// with the text and whether the insertion is an IME composition commit. The
        /// Coordinator decides whether the armed modifier applies to it.
        var onWillInsertText: ((String, Bool) -> Void)?
        /// Called when the user does something that is definitely not a Ctrl chord.
        var onCancelControl: (() -> Void)?
        var onUserInteraction: (() -> Void)?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            if event?.type == .touches { onUserInteraction?() }
            return super.hitTest(point, with: event)
        }

        /// Refreshing the native modifier HERE, not on a SwiftUI pass, is what makes
        /// "tap Ctrl, immediately type p" work: SwiftUI may not have delivered the
        /// binding change yet when the key arrives. Encoding itself stays SwiftTerm's
        /// job (legacy control bytes or negotiated Kitty CSI-u), so the pane receives
        /// exactly one properly encoded chord.
        override func insertText(_ text: String) {
            onWillInsertText?(text, markedTextRange != nil)
            super.insertText(text)
        }

        /// HARDWARE KEYS NEED THE SAME REFRESH AS SOFTWARE ONES.
        ///
        /// `insertText` re-reads the live binding immediately before encoding, which is
        /// what makes "tap Ctrl, type instantly" work. A physical key never reaches
        /// `insertText`: it is encoded from `pressesBegan`. So on iPad a control-bar cap
        /// that cleared the one-shot could still be beaten by the next hardware key,
        /// which encoded with the stale native flag and sent a chord the reader had
        /// already cancelled — measured as Ctrl+P firing after tapping Tab.
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            onWillHandleHardwareKeys?()
            super.pressesBegan(presses, with: event)
        }
        /// Refreshes the native modifier from the host's live state before a physical
        /// key is encoded.
        var onWillHandleHardwareKeys: (() -> Void)?

        /// CTRL CHORDS FROM A PHYSICAL KEYBOARD, DELIVERED AS KEY COMMANDS.
        ///
        /// SwiftTerm encodes hardware keys in `pressesBegan`, and that is enough on an
        /// iPad. It is NOT enough for a Designed-for-iPad app on a Mac, which is how
        /// this app runs on Apple Silicon: plain characters arrive through the text
        /// input system and reach the pane, while every Ctrl chord — including ones
        /// macOS does not bind, like Ctrl+G and Ctrl+X — never surfaces at all. Measured
        /// on a MacBook against `cat -v`: `abc` echoes, `^G`/`^X`/`^P`/`^A` produce
        /// nothing.
        ///
        /// `UIKeyCommand` is the delivery mechanism UIKit guarantees for hardware
        /// shortcuts on that platform. `wantsPriorityOverSystemBehavior` additionally
        /// takes the chord back from macOS's own emacs-style text bindings, which is
        /// what would otherwise swallow Ctrl+A, Ctrl+E, Ctrl+K and Ctrl+P specifically.
        ///
        /// When UIKit matches a key command it invokes the action INSTEAD of
        /// `pressesBegan`, so this cannot double-send on a platform where the press path
        /// already worked.
        private static let controlChordInputs: [String] =
            (UInt8(ascii: "a")...UInt8(ascii: "z")).map { String(UnicodeScalar($0)) }
            + ["[", "]", "\\", "^", "_", " "]

        override var keyCommands: [UIKeyCommand]? {
            return Self.controlChordInputs.map { input in
                let command = UIKeyCommand(input: input,
                                           modifierFlags: .control,
                                           action: #selector(handleControlChord(_:)))
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }

        @objc private func handleControlChord(_ command: UIKeyCommand) {
            guard let input = command.input, let scalar = input.unicodeScalars.first else { return }
            // The one-shot is spent by any chord the reader completes with a real Ctrl,
            // so an armed cap cannot leak into the next keystroke.
            onCancelControl?()
            guard let byte = Self.controlByte(for: scalar) else { return }
            send([byte])
        }

        /// The C0 byte for a control chord, matching the terminal's own mapping.
        private static func controlByte(for scalar: UnicodeScalar) -> UInt8? {
            switch scalar {
            case "a"..."z": return UInt8(scalar.value - 0x60)
            case "A"..."Z": return UInt8(scalar.value - 0x40)
            case "[": return 0x1b
            case "\\": return 0x1c
            case "]": return 0x1d
            case "^": return 0x1e
            case "_": return 0x1f
            case " ": return 0
            default: return nil
            }
        }

        /// A paste is not a chord: it must arrive verbatim, and it must not leave the
        /// modifier armed for the next keystroke.
        override func paste(_ sender: Any?) {
            onCancelControl?()
            super.paste(sender)
        }

        override func deleteBackward() {
            onCancelControl?()
            super.deleteBackward()
        }


        /// EMULATOR REPLIES ARE NOT USER INPUT, and this pane is never the primary viewer
        /// of its PTY, so it must not answer the host.
        ///
        /// SwiftTerm funnels two different things into ONE delegate callback. Typed input
        /// arrives via `AppleTerminalView.send(data:)`, which calls `recordUserInput()`
        /// first. Emulator-GENERATED answers arrive through THIS `open` TerminalDelegate
        /// bridge (`iOSTerminalView.swift:1408`): focus reports CSI I and CSI O, DA, DSR
        /// and CPR replies, OSC colour and OSC 52 answers, CSI-t window reports.
        ///
        /// Before iPhone typing existed, the delegate dropped everything on this idiom, so
        /// none of it left the phone. Enabling typing enabled the replies with it, and the
        /// desktop herdr owns the same PTY and already answers those queries, so a second
        /// answerer produces duplicate or contradictory replies to one host request.
        ///
        /// Overriding here drops ONLY the reply bridge; typed input never comes through
        /// this method, so it is untouched. Applied on EVERY idiom, not just phone: iPad
        /// with a hardware keyboard has been forwarding these since key drive shipped, and
        /// a co-viewer answering for the primary is wrong there for the same reason.
        override func send(source: Terminal, data: ArraySlice<UInt8>) {}
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }

    /// Owns the stream task and marshals frames onto the main actor. Retained by
    /// SwiftUI (via `makeCoordinator`); the `TerminalView` holds only a weak ref
    /// back through `terminalDelegate`.
    final class Coordinator: NSObject, TerminalViewDelegate, UIGestureRecognizerDelegate {
        private let client: HerdrClient
        private let paneID: String
        /// Stable per-view identity for the daemon's PTY width-lease (#137). Generated
        /// ONCE per Coordinator (= one view = one live `pane.stream`) and sent UNCHANGED
        /// on BOTH this view's `pane.stream` open AND every `pane.set_pty_size` it makes,
        /// so the lease taken by the resize is the one the daemon drops when this stream
        /// closes. A fresh UUID per instance is deliberate: sharing one id across two
        /// concurrent streams to a pane would let the FIRST close drop the shared lease
        /// while the second is still open (JARVIS review finding #2 — premature shrink).
        private let viewerID = UUID().uuidString
        private weak var view: ReadOnlyTerminalView?
        /// The container that owns the terminal and the resize cover. Same object for
        /// this coordinator's whole life; the terminal is never rebuilt for a resize.
        private weak var surface: TerminalSurfaceView?
        /// The surface `attach` was given, held strongly until `dismantleUIView`, so a repeated
        /// `makeUIView` for this Coordinator can return it instead of building a second one.
        fileprivate(set) var mountedSurface: TerminalSurfaceView?
        private var streamTask: Task<Void, Never>?
        /// The single serialized resize drain, if running. Only ever ONE at a time —
        /// it awaits each set_pty_size before the next (so remote resizes can't
        /// complete out of order) and loops until `desired == lastSent`. Cancelled on
        /// teardown.
        private var resizeTask: Task<Void, Never>?
        /// The grid this view WANTS the PTY at, together with the cell metrics that
        /// produced it, so a font change at an unchanged grid is still a new target.
        /// The drain drives `confirmedTarget` toward this. Dedup is measured against
        /// THIS, never the committed size, so a request matching the committed size
        /// while a DIFFERENT resize is in flight is not wrongly dropped.
        private var desiredTarget: TerminalGeometryTarget?
        /// When `desiredTarget` last CHANGED. The drain waits for a real quiet window
        /// measured from here (monotonic), instead of comparing two endpoint samples -
        /// a sweep that returns to an earlier width is movement, not stillness.
        private var desiredTargetChangedAt: ContinuousClock.Instant?
        /// Bumped on every new target, so a response can be told apart from the one
        /// belonging to a target the user has already superseded.
        private var targetGeneration = 0
        /// The target of the `set_pty_size` call currently in flight, if any.
        private var inflightTarget: TerminalGeometryTarget?
        /// Last target the server CONFIRMED (committed only after a successful
        /// set_pty_size). The drain stops once this equals `desiredTarget`.
        private var confirmedTarget: TerminalGeometryTarget?
        /// The EFFECTIVE winsize the daemon actually applied, from the `set_pty_size`
        /// response (#137), plus the target generation it answered. Under the
        /// width-lease arbiter this can EXCEED what this view requested — a wider
        /// co-viewer's lease wins — so it is recorded for truth but deliberately NOT
        /// fed back into `confirmedTarget`: driving the drain toward the arbiter's
        /// width would re-send forever, fighting the arbiter. The view still RENDERS
        /// the applied (wider) grid because the authoritative cols/rows arrive on
        /// `pane.stream` itself; this is the coordinator's copy of that truth.
        private var responseGeometry: (cols: Int, rows: Int)?
        private var responseGeneration = -1
        /// Whether `responseGeometry` still describes a grid the stream has NOT yet
        /// applied. Once its marker lands the claim is spent, so a later unsolicited
        /// resize back to those dimensions is treated as the server's, and covered.
        private var responseAwaitingMarker = false
        /// The grid the STREAM has actually applied to the emulator, in stream order.
        /// This - not a response, and never a local target - is what is on screen.
        private var streamAppliedGeometry: (cols: Int, rows: Int)?
        /// Bumped whenever the stream commits geometry, so a completed paint can be
        /// matched to the grid it was painted at.
        private var streamGeometryRevision = 0
        /// A lease keepalive in flight. It is NOT a target change: the drain waits for
        /// it so the two never overlap on the wire.
        private var keepaliveTask: Task<Void, Never>?
        /// Consecutive failures for the CURRENT target, so the drain's self-retry
        /// backs off and is capped; reset whenever a new target is requested.
        private var resizeRetries = 0
        /// How long a resize target must stand still before it is sent to the daemon.
        ///
        /// Long enough to swallow an animated or dragged width sweep (one proposal
        /// per frame), short enough that a deliberate single resize still feels
        /// immediate — and short enough not to hold up teardown, which awaits this task.
        static let resizeSettleDuration: Duration = .milliseconds(140)
        /// How long the presentation waits for new output to stop before it treats the
        /// current frame as the finished one (used only when the agent does not mark
        /// its frames with DEC 2026).
        static let presentationQuietDuration: Duration = .milliseconds(250)
        /// Hard ceiling on holding a retained frame: after this the reader sees the
        /// real, authoritative grid whatever the agent did or did not redraw.
        static let presentationDeadlineDuration: Duration = .seconds(1)

        // MARK: - resize presentation
        //
        // A resize is not one event: the local fit is proposed, the daemon commits a
        // grid, the stream carries that grid in order with the output it applies to,
        // and only then does the agent redraw. Showing every intermediate state means
        // showing text reflowing through sizes nobody asked for, so the last complete
        // frame is retained over the terminal until the new one is genuinely ready.

        /// Why the geometry is changing, which decides what "settled" means and whether
        /// a burst may still be retained after the reader acted (`.keyboard`).
        private enum PresentationReason { case local, server, keyboard }

        /// The floor on a sweep's window. UIKit reports 0 for an interactive (dragged)
        /// dismissal, and a window that short would close while the reader is still
        /// moving the keyboard, which is the per-frame behaviour this replaces.
        static let keyboardSweepMinimumDuration: Duration = .milliseconds(250)
        /// Added to the sweep's reported duration, so the LAST animation frame is inside
        /// the window.
        static let keyboardSweepGrace: Duration = .milliseconds(80)
        /// Consecutive rendered frames the pane must keep one size, past the window,
        /// before the sweep is taken as finished. Two, so one frame in which the
        /// animation produced no layout cannot pass for its end.
        static let keyboardSweepStillFrames = 2
        /// Whether a keyboard sweep keeps the terminal live instead of covering it. iPhone
        /// only: its keyboard is always full-width and bottom-docked, so the pane shrinks
        /// from the bottom. iPad's floating/split keyboards can move without resizing the
        /// pane, and its sweeps stay layout-driven and covered.
        static var keyboardAnchorsLive: Bool { UIDevice.current.userInterfaceIdiom == .phone }

        /// A software-keyboard transition is animating this pane's height. UIKit reports
        /// the duration up front, so the whole sweep is ONE event with a known end.
        ///
        /// The reported duration plus `keyboardSweepGrace` is only the backstop: past it,
        /// the sweep ends once the surface keeps one size for `keyboardSweepStillFrames`
        /// rendered frames, bounded by `presentationDeadlineDuration` (see
        /// `keyboardSweepDeadlineTask`). An earlier version also closed the sweep after
        /// 60ms of proposal quiet, which is wrong for any slow transition: a dragged
        /// dismissal proposes a new row count every ~85ms, so the quiet window closed the
        /// sweep mid-animation and the remaining frames committed one by one — the defect,
        /// back again, for exactly the gesture a reader controls. Review caught it (f3).
        private var keyboardSweepActive = false
        private var keyboardSweepDeadlineTask: Task<Void, Never>?
        /// The newest fit proposed during the sweep. Only this one is ever sent.
        private var deferredKeyboardTarget: (cols: Int, rows: Int)?
        /// How much of the screen the software keyboard covered after the last keyboard
        /// notification. A notification that leaves it unchanged (focus moving between
        /// the terminal and the composer, an input-mode switch) cannot resize the pane.
        private var keyboardCoveredHeight: CGFloat = 0
        /// The frame on screen at the exact composer Send event. `userTookControl`
        /// removes any old cover immediately, but the same event dismisses the keyboard
        /// before SwiftTerm can draw again. Hold this candidate briefly and consume it
        /// ONLY if that keyboard transition follows.
        private var pendingHostInputFrame: UIView?
        private var pendingHostInputFrameTask: Task<Void, Never>?

        /// A completed paint, tagged with everything that must still hold for it to
        /// count as the finished frame for the current burst.
        private struct DrawToken: Equatable {
            var presentationGeneration: Int
            var targetGeneration: Int
            var streamGeometryRevision: Int
            var cellSize: CGSize
            var alternate: Bool
        }

        private var presentationGeneration = 0
        private var presentationActive = false
        /// Set when this burst is finished with: no late acknowledgment, marker or
        /// gesture may cover the same geometry again.
        private var presentationClosed = false
        private var presentationReason: PresentationReason = .local
        private var presentationStartedOnNormalBuffer = true
        private var presentationSyncEnded = false
        private var presentationGeometrySettled = false
        private var presentationDeadlineTask: Task<Void, Never>?
        private var presentationRevealTask: Task<Void, Never>?
        private var pendingSafeRepaint = false
        private var lastCompleteDraw: DrawToken?
        private var backingDrawComplete = false
        private var lastStreamDataAt: ContinuousClock.Instant?
        private var geometryEligibleAt: ContinuousClock.Instant?
        private var presentationDeadlineReached = false
        private var synchronizedBatchBegan = false
        /// While a burst is on screen the host keeps the tail state it had, so a
        /// transient UIKit clamp or a borrowed alternate screen is not published as if
        /// the reader had decided something.
        private var tailPublishHeld = false

        // MARK: - one-shot Ctrl

        /// Live accessors for the host's `ctrlArmed` state, refreshed every SwiftUI
        /// pass so an immediate keystroke cannot read a stale snapshot.
        var controlArmedGetter: (() -> Bool)?
        var controlArmedSetter: ((Bool) -> Void)?
        /// True while THIS code is writing `controlModifier`, so SwiftTerm's reset
        /// notification for our own write is not mistaken for the user's chord being
        /// consumed (which would clear a modifier the reply field still needs).
        private var applyingControlModifier = false
        private var controlResetObserver: NSObjectProtocol?
        var directFocusIntended = false
        /// View-only (guest): sends no bytes and never takes focus. Sizing is separate.
        var viewOnly = false {
            didSet { view?.allowsFocus = !viewOnly }
        }
        /// The host asked this view to follow the stream's grid (see
        /// `LiveTerminalView.fitsStreamWidth`). Refreshed every pass.
        var hostFitsStreamWidth = false
        /// Closed by the host's first `guest_forbidden` answer to a resize; see `PTYResizeGate`.
        /// Every `set_pty_size` this view sends goes through it, including the teardown release.
        private let resizeGate = PTYResizeGate()
        /// Set once this view has reacted to the gate closing (`fallBackIfRefused`).
        private var fellBack = false
        /// See `LiveTerminalView.onResizeRefused`. Refreshed by `updateUIView`.
        var onResizeRefused: (() -> Void)?
        /// This view never sizes the PTY: the stream's grid is authoritative and its cols are
        /// fitted to the width. Geometry guards read this, never `viewOnly`.
        var fitsStreamWidth: Bool { hostFitsStreamWidth || resizeGate.isClosed }
        /// Set once the server sends an `exited` frame, so a normal stream end is
        /// distinguished from an unexpected EOF (which must surface, not freeze).
        private var sawExited = false
        /// Set when the SERVER permanently refused this pane (e.g. `pane_not_found`),
        /// as opposed to the stream dropping. A dropped stream deserves the reconnect
        /// loop; a refusal does not — the pane will never come back, so retrying just
        /// spins "connection lost; reconnecting…" forever with nothing behind it. Any
        /// path that could restart the stream (the backoff task, the heartbeat
        /// watchdog) honours this exactly like `sawExited`.
        private var paneGone = false
        /// Set in `stop()` so a LATE async `sizeChanged` callback (SwiftTerm
        /// dispatches them asynchronously) cannot start a NEW `lock:true` resize
        /// AFTER we've released geometry ownership — which would re-pin the pane and
        /// defeat the release. Once stopped, `requestGeometry` is inert.
        private var stopped = false

        /// KVO token for the terminal's `contentOffset`, which is the only signal a FINGER scroll
        /// produces that this layer can see. Retained because an `NSKeyValueObservation` stops
        /// observing the moment it is released; invalidated in `stop()`.
        private var offsetObservation: NSKeyValueObservation?

        /// Scrollback backfill: the in-flight `read` (source=.recent, ANSI) fetching history
        /// produced BEFORE the live stream connected, resolved to ANSI bytes (nil on empty /
        /// error / timeout). The first reset WITHOUT keyframe history awaits it once, to prepend
        /// history above the seed; a reset that carries keyframe history cancels it.
        private var backfillTask: Task<[UInt8]?, Never>?
        /// Set by the first reset. Gates the one-time scrollback-cap raise and the backfill
        /// prepend (a reset's own keyframe history is fed on every reset), and tells a later
        /// reset that it is a reconnect, which re-claims the pane's size.
        private var didSeedOnce = false

        /// Strips terminal graphics escape strings (kitty APC, high-volume DCS) from the raw PTY
        /// bytes before they reach SwiftTerm, which crash-loops on them (#170). Stateful — a graphics
        /// string spans stream chunks — so it is carried across `.data`/`.reset` feeds and reset at
        /// each keyframe. Only stream bytes go through it; app-generated notices are already safe.
        private var graphicsFilter = TerminalGraphicsFilter()
        private func feedFiltered(_ data: Data, into view: TerminalView) {
            let clean = graphicsFilter.filter([UInt8](data)[...])
            if !clean.isEmpty {
                view.feed(byteArray: clean[...])
                surface?.contentDidChange()
            }
        }

        /// Replace the emulator's scrollback with a keyframe's history: the rows directly
        /// above the keyframe's screen, oldest first, already at its width.
        ///
        /// The rows must end up IN SCROLLBACK, not on screen, because the seed that follows
        /// repaints the screen. After the last history row, `rows` line feeds scroll exactly
        /// the history rows off the top — no more (blank rows below them stay on screen, and
        /// the seed's clear erases them), no fewer, however short the history is.
        private func seedKeyframeHistory(_ history: Data, rows: Int, into view: TerminalView) {
            view.feed(byteArray: Self.historyResetSequence[...])
            var clean = graphicsFilter.filter([UInt8](history)[...])
            while let last = clean.last, last == 0x0A || last == 0x0D { clean.removeLast() }
            guard !clean.isEmpty else { return }
            view.feed(byteArray: clean[...])
            // SGR reset first so the scrolled-in blank rows aren't tinted by the history's colours.
            var push = [UInt8]("\u{1b}[0m".utf8)
            for _ in 0..<max(rows, 1) { push.append(contentsOf: [0x0D, 0x0A]) }
            view.feed(byteArray: push[...])
        }

        // MARK: older history, paged in above the scrollback
        //
        // A keyframe carries at most `backfillLines` rows of history, while the server keeps
        // far more. A `pane_history` server adds a cursor for the row above the oldest one
        // sent; reaching the top of the scrollback asks for the page above it, which lands
        // ABOVE everything held without moving what the reader is looking at, and brings the
        // cursor for the next page. Any server or cursor that cannot page simply ends it:
        // the terminal then holds what it held before paging existed.

        /// Rows per `pane.history` page.
        static let historyPageLines: UInt32 = 500
        /// The scrollback a paging pane may grow to; reaching it ends paging.
        static let historyScrollbackCap = 20_000
        /// How long a page that failed in transit waits before the next scroll may retry it.
        static let historyRetryDelay: Duration = .seconds(2)
        /// How long the offset must rest before a stop near the top retries a page that
        /// the moving scroll could not start.
        static let historySettleDelay: Duration = .milliseconds(300)
        #if DEBUG
        /// The contentOffset observer's paging diagnostics (see `observeContentOffset`).
        static let historyLog = Logger(subsystem: "herdrup", category: "terminal-history")
        #endif

        /// The `pane.history` token for the rows above the oldest one this emulator holds:
        /// from the latest keyframe, then from each page. nil = nothing (more) to load.
        private var historyCursor: String?
        private var historyPageTask: Task<Void, Never>?
        /// Bumped whenever the history the cursor describes is replaced (a reset, teardown):
        /// a page requested before that belongs to history that is no longer here.
        private var historyGeneration = 0
        private var historyRetryAt: ContinuousClock.Instant?
        /// `pane.history` request in flight.
        private var historyLoading = false
        /// Whether reaching the top pages by geometry alone, whatever moved it. A Mac wheel or
        /// trackpad scroll moves `contentOffset` without the `isDragging`/`isDecelerating` a
        /// finger sets, so a gesture-only gate never paged there. Disarmed on every reset,
        /// because seeding writes offset 0 before settling at the tail and must not fetch a
        /// page nobody asked for; armed once the seed rests at the tail more than a screen
        /// below the top (from there only the reader can bring the top near), by a finger
        /// scroll, or by the "Load earlier output" tap.
        private var historyArmed = false
        /// The seed has come to rest at the tail since the last reset. Until then a pane near
        /// the top is the seed passing through, and offers nothing.
        private var historySettled = false
        /// A check that runs once the offset stops near the top (see `scheduleHistorySettleCheck`).
        private var historySettleTask: Task<Void, Never>?
        /// See `LiveTerminalView.onHistoryPagingChange`. Refreshed by `updateUIView`.
        var onHistoryPagingChange: ((TerminalHistoryPaging) -> Void)?
        /// nil until the first publish, so a `streamGen` remount always replaces whatever the
        /// host showed for the coordinator it replaced.
        private var historyPaging: TerminalHistoryPaging? {
            didSet {
                guard historyPaging != oldValue, let state = historyPaging else { return }
                let publish = onHistoryPagingChange
                DispatchQueue.main.async { publish?(state) }
            }
        }
        /// Last `loadEarlierHistoryToken` acted on; seeded like the jump token.
        private var lastLoadEarlierHistoryToken = 0

        /// A keyframe replaced the history: whatever page was in flight is void, and paging
        /// restarts from this keyframe's cursor (nil = it offers none).
        private func adoptHistoryCursor(_ cursor: String?) {
            historyPageTask?.cancel()
            historyPageTask = nil
            historySettleTask?.cancel()
            historySettleTask = nil
            historyGeneration &+= 1
            historyRetryAt = nil
            historyLoading = false
            historyArmed = false
            historySettled = false
            historyCursor = cursor
            historyPaging = .hidden
            // Judged once the seed this reset feeds has landed: a pane that cannot scroll
            // never moves its offset, so no observation would judge it.
            Task { @MainActor [weak self] in self?.pageHistoryOnScroll(userDriven: false) }
        }

        /// The contentOffset observer's paging step; `userDriven` is a finger's drag or coast.
        ///
        /// Judged on the view's geometry NOW, not the offset the observation captured: the
        /// observer hops to the main actor, so a reset's seed queues hops that carry its own
        /// passing offset 0, and a hop queued before a reset can run after it. Read live, both
        /// see the settled seed, which is at the tail.
        @MainActor
        private func pageHistoryOnScroll(userDriven: Bool) {
            guard !stopped, let view else { return }
            let offsetY = view.contentOffset.y, viewportHeight = view.bounds.height
            if userDriven { historyArmed = true }
            if historyArmed {
                loadOlderHistoryIfNeeded(offsetY: offsetY, viewportHeight: viewportHeight)
                // Near the top with nothing started (a retry delay, say): try again once the
                // offset rests, since a reader parked at the top produces no more changes.
                if historyPageTask == nil, offsetY < viewportHeight {
                    scheduleHistorySettleCheck(after: Self.historySettleDelay)
                }
            } else if offsetY >= view.contentSize.height - viewportHeight
                        - CGFloat(max(cellPixels().height, 2)) / 2 {
                // At the tail (or nothing to scroll): the seed has settled. Armed AFTER the
                // check above, so this report itself cannot page; and not at all within a
                // screen of the top, where the capsule offers the page instead, so nothing is
                // fetched before anyone asks.
                historySettled = true
                if offsetY >= viewportHeight { historyArmed = true }
            }
            refreshHistoryPaging()
        }

        /// Pages once the offset has stopped near the top. One check pending at a time; it
        /// waits out a gesture still in progress and any retry delay.
        @MainActor
        private func scheduleHistorySettleCheck(after delay: Duration) {
            guard !stopped, historySettleTask == nil, historyCursor != nil else { return }
            historySettleTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled else { return }
                self.historySettleTask = nil
                guard self.historyArmed, self.historyPageTask == nil, let view = self.view,
                      view.contentOffset.y < view.bounds.height else { return }
                if view.isTracking || view.isDecelerating {
                    self.scheduleHistorySettleCheck(after: Self.historySettleDelay)
                    return
                }
                if let retryAt = self.historyRetryAt, ContinuousClock.now < retryAt {
                    self.scheduleHistorySettleCheck(after: retryAt - ContinuousClock.now)
                    return
                }
                self.loadOlderHistoryIfNeeded(offsetY: view.contentOffset.y,
                                              viewportHeight: view.bounds.height)
                self.refreshHistoryPaging()
            }
        }

        /// The reader tapped "Load earlier output": page now, past any retry delay, and let
        /// geometry page from here on. Not annotated `@MainActor`, like `performJumpToTail`:
        /// `updateUIView` calls it on the main thread.
        func loadEarlierHistory(ifTokenChanged token: Int) {
            guard token != lastLoadEarlierHistoryToken else { return }
            lastLoadEarlierHistoryToken = token
            MainActor.assumeIsolated {
                guard !stopped, let view else { return }
                historyArmed = true
                historyRetryAt = nil
                loadOlderHistoryIfNeeded(offsetY: view.contentOffset.y, viewportHeight: view.bounds.height)
                refreshHistoryPaging()
            }
        }

        /// Publishes what the capsule shows. Offered when a cursor remains, nothing is loading,
        /// and the reader is within one screen of the top of the scrollback once the seed has
        /// settled (or a scroll armed paging): a pane too short to arm itself, a wheel resting
        /// at the top, a page that failed. Before that it is a seed passing through the top.
        @MainActor
        private func refreshHistoryPaging() {
            if historyLoading {
                historyPaging = .loading
                return
            }
            guard !stopped, historyCursor != nil, let view,
                  !view.getTerminal().isCurrentBufferAlternate else {
                historyPaging = .hidden
                return
            }
            let nearTop = view.contentOffset.y < view.bounds.height
            historyPaging = (historyArmed || historySettled) && nearTop ? .offered : .hidden
        }

        /// Called on every scroll position change: within one screen of the top of the
        /// scrollback, request the page above it (one at a time).
        @MainActor
        private func loadOlderHistoryIfNeeded(offsetY: CGFloat, viewportHeight: CGFloat) {
            guard !stopped, foreground, historyPageTask == nil, let cursor = historyCursor,
                  offsetY < viewportHeight, let view,
                  !view.getTerminal().isCurrentBufferAlternate else { return }
            if let retryAt = historyRetryAt, ContinuousClock.now < retryAt { return }
            let client = self.client, pane = self.paneID, generation = historyGeneration
            historyLoading = true
            refreshHistoryPaging()
            historyPageTask = Task { @MainActor [weak self] in
                let result: Result<PaneHistoryPage, Error>
                do {
                    result = .success(try await client.paneHistory(pane: pane, cursor: cursor,
                                                                   lines: Self.historyPageLines))
                } catch {
                    result = .failure(error)
                }
                guard let self, !Task.isCancelled, generation == self.historyGeneration else { return }
                self.historyPageTask = nil
                self.historyLoading = false
                self.applyHistoryPage(result)
                // A page that moved nothing (no rows, a failure) leaves a reader parked at
                // the top with no offset change to page the next one.
                self.scheduleHistorySettleCheck(
                    after: self.historyRetryAt == nil ? Self.historySettleDelay : Self.historyRetryDelay)
                self.refreshHistoryPaging()
            }
        }

        @MainActor
        private func applyHistoryPage(_ result: Result<PaneHistoryPage, Error>) {
            guard !stopped, let view else { return }
            let page: PaneHistoryPage
            switch result {
            case .success(let answer):
                page = answer
            case .failure(is PaneHistoryError), .failure(is APIError):
                // Expired, unsupported, or the pane is gone: the same cursor will not page.
                historyCursor = nil
                return
            case .failure:
                // In transit (a dropped connection): the cursor is still good.
                historyRetryAt = ContinuousClock.now + Self.historyRetryDelay
                return
            }
            // The pane switched to its alternate screen while the page was in flight. The
            // normal screen's history is unchanged underneath, so this cursor pages it later.
            guard !view.getTerminal().isCurrentBufferAlternate else { return }
            // Its own filter: the stream's holds the state of the live bytes around this page.
            var filter = TerminalGraphicsFilter()
            let clean = filter.filter([UInt8](page.data)[...])
            guard !clean.isEmpty else {
                historyCursor = page.cursor
                return
            }
            let inserted = view.prependHistory(clean[...], maxScrollback: Self.historyScrollbackCap)
            // Nothing fit: the scrollback is at the cap, and paging ends. A page the cap cut
            // short kept its NEWEST rows, so its cursor no longer adjoins the top; that cannot
            // leave a gap, because the cut filled the scrollback and the next page inserts
            // nothing.
            historyCursor = inserted == 0 ? nil : page.cursor
            publishTopRowProbe()
        }

        /// Auto-reconnect. `reconnectBackoff` drives capped, jittered exponential backoff (reset once a
        /// fresh stream delivers a real `.reset`, i.e. it genuinely re-established). `lastStreamActivity`
        /// feeds the heartbeat watchdog: the server pings every 20s (`PING_INTERVAL`), so a long
        /// silence means a stuck / half-open stream that never errors. `streamRunID` tags each stream
        /// so a superseded (cancelled/restarted) task's `streamEnded` cannot trigger a second reconnect.
        /// `reconnectTask` is the pending backoff-delayed restart; `watchdogTask` the periodic checker.
        private var reconnectBackoff = ReconnectBackoff(initial: .milliseconds(500), maximum: .seconds(20),
                                                        jitter: 0.6...1.0)   // 0.5,1,2,4,8,16,20 s, ×0.6–1.0
        private var lastStreamActivity = Date()
        private var streamRunID = 0
        private var reconnectTask: Task<Void, Never>?
        private var watchdogTask: Task<Void, Never>?
        /// The host's liveness box, mirrored on every stream frame. Optional because the
        /// header-refresh path and the tests construct a Coordinator with no host box.
        var liveness: StreamLiveness?
        /// No stream event (data, ping, resize) for this long → treat the stream as stuck and
        /// reconnect. 2.5× the server's 20s ping, so a single dropped ping is tolerated.
        fileprivate static let streamStuckTimeout: TimeInterval = 50

        /// PTY width-lease heartbeat (#137). We ask for a short TTL (`TerminalSizeClaim`), so
        /// a stable-size FOREGROUND view — one that never fires a fresh `sizeChanged` — would
        /// silently lose its lease. This task periodically re-asserts the current committed
        /// size (carrying the same `viewerID`) to refresh the lease. Re-armed by `start()`,
        /// cancelled by `stop()`. Hidden, backgrounded and relocking panes are skipped.
        private var heartbeatTask: Task<Void, Never>?
        /// A guest's lease terms: the host clamps a guest's TTL far below the owner's.
        private var leaseTTL: UInt64 { viewOnly ? GuestTerminalSize.leaseTTLMillis : TerminalSizeClaim.leaseTTLMillis }
        private var heartbeatInterval: UInt64 {
            viewOnly ? GuestTerminalSize.leaseRenewalNanos : TerminalSizeClaim.renewalNanos
        }
        /// How long a hidden pane keeps its claim before `setForeground(false)`'s timer releases
        /// it (see `TerminalSizeClaim.hiddenGraceNanos` for why there is a grace at all). DEBUG
        /// builds take `HERDR_CLAIM_GRACE_MS` so the UI tests run in seconds.
        private static let hiddenClaimGraceNanos: UInt64 = {
            #if DEBUG
            return TerminalSizeClaim.hiddenGraceNanos(
                overrideMillis: ProcessInfo.processInfo.environment["HERDR_CLAIM_GRACE_MS"])
            #else
            return TerminalSizeClaim.hiddenGraceNanos
            #endif
        }()
        /// The pending release of a hidden pane's claim. Armed by a hide, cancelled by a re-show,
        /// a background (which releases at once) and `stop()`.
        private var hiddenReleaseTask: Task<Void, Never>?
        /// The window scene this pane is in has gone to the background (iOS suspension, sleep, a
        /// minimised Mac window). Its claim was released then; nothing may claim again until the
        /// scene comes back.
        private var sceneBackgrounded = false
        /// Whether this pane may hold a claim right now: in front, in a scene that is not in the
        /// background. Every `lock:true` path checks this, not `foreground` alone.
        private var claimsGeometry: Bool { foreground && !sceneBackgrounded }
        /// This view has sent a `lock:true` since its last release, so the daemon may hold a
        /// lease for its `viewerID`. Set as each `lock:true` goes out, cleared by the release
        /// that hands it back, so a lease is released AT MOST ONCE however many of the grace
        /// timer, a background and `stop()` (which can itself run twice, `.exited` then
        /// dismantle) reach `releaseGeometryOwnership`. A pane that never claimed (mounted
        /// hidden) sends no `lock:false` either: with no other lease left the daemon applies a
        /// release's size once as a parting handoff, a needless SIGWINCH and agent redraw for
        /// a lease that never existed.
        private var holdsClaim = false

        /// Page-between-agents callback (see `LiveTerminalView.onNavigate`), refreshed
        /// by `updateUIView`. +1 = next agent, -1 = previous.
        var onNavigate: ((Int) -> Void)?
        /// Requests SwiftUI terminal-input focus after a tap. The parent controls
        /// actual responder ownership so it can dismiss the keyboard after Send.
        var onTerminalFocusRequest: (() -> Void)?
        /// See `LiveTerminalView.onStreamEnded`. Refreshed by `updateUIView`.
        var onStreamEnded: ((Error?) -> Void)?
        /// Publishes tail state to the host (see `LiveTerminalView.onTailStateChange`).
        /// Refreshed by `updateUIView`.
        var onTailStateChange: ((Bool) -> Void)?
        /// Last `jumpToTailToken` this Coordinator executed, so one increment performs
        /// exactly one jump even though `updateUIView` runs on every body pass. SEEDED
        /// from the host at `makeUIView`, because a remount builds a fresh Coordinator
        /// while the host's token survives: defaulting to 0 would replay the last jump.
        private var lastJumpToTailToken = 0
        /// Last value published through `onTailStateChange`. Also seeded from the host,
        /// so a remount cannot dedupe away the next genuine transition.
        private var lastReportedAtTail = true

        /// Adopt the host's current jump token and tail belief WITHOUT acting on either.
        /// Called once per Coordinator, before `attach`, so a `streamGen` remount neither
        /// re-sends a jump it already performed nor swallows the next tail callback.
        func seedBaselines(jumpToTailToken: Int, atTail: Bool, userInputToken: Int,
                           loadEarlierHistoryToken: Int) {
            lastJumpToTailToken = jumpToTailToken
            lastReportedAtTail = atTail
            lastUserInputToken = userInputToken
            lastLoadEarlierHistoryToken = loadEarlierHistoryToken
        }

        /// Last host-input token acted on, seeded like the jump token so a `streamGen`
        /// remount does not replay an old keycap as a fresh user action.
        private var lastUserInputToken = 0

        /// The host delivered input on this pane's behalf. Same effect as a touch or a
        /// typed key on the surface: the retained frame goes now, and the reveal task
        /// that belonged to it cannot put it back.
        func noteHostInput(ifTokenChanged token: Int) {
            guard token != lastUserInputToken else { return }
            lastUserInputToken = token
            guard !stopped, foreground else { return }
            // These bytes bypass the key path, so no prediction can stand on them.
            prediction.reset()
            prepareHostInputFrameAndTakeControl()
        }

        /// Shared by the real host-input token and the DEBUG receipt that must perform
        /// host input + keyboard notification in one main-actor event.
        private func prepareHostInputFrameAndTakeControl() {
            // Only a covered keyboard sweep uses this picture; a live-anchored one does not.
            if !Self.keyboardAnchorsLive {
                pendingHostInputFrameTask?.cancel()
                pendingHostInputFrame = surface?.captureTerminalFrame()
                pendingHostInputFrameTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    self?.pendingHostInputFrame = nil
                    self?.pendingHostInputFrameTask = nil
                }
            }
            userTookControl()
        }

        /// Per-pane geometry-ownership generation. Each `attach` for a pane id bumps this and
        /// records the value it claimed; the releasing `lock:false` — which can be DELAYED
        /// awaiting an in-flight `lock:true` — is skipped if a NEWER coordinator has since
        /// claimed the same pane. Without it a fast A→B→A swap can leave the pane you are
        /// LOOKING at unlocked: the outgoing coordinator's release lands after the newcomer's
        /// `lock:true`, and target dedup then never re-locks it. Accessed only on the
        /// main actor (attach/stop) except the post-await read in `releaseGeometryOwnership`,
        /// which hops back via `MainActor.run` — so all access is main-actor-serialized.
        private static var geometryGeneration: [String: Int] = [:]
        private var myGeometryGeneration = 0
        /// The in-flight `lock:false` release per pane, so a re-claim (`reclaimGeometry`) can
        /// AWAIT it before re-locking — the re-lock can then never be overtaken by a reordered
        /// release that would leave the visible pane unlocked.
        private static var geometryReleaseTask: [String: Task<Void, Never>] = [:]
        /// Whether this (keep-mounted) pane is currently on screen. Only a FOREGROUND pane
        /// refreshes or re-takes the PTY width-lock; a hidden pane keeps it for the grace, then
        /// releases it (see `setForeground`), and its async `sizeChanged` tracks the grid but
        /// never re-locks.
        private var foreground = true
        /// True between a re-claim (`reclaimGeometry`) and its deferred re-lock completing —
        /// i.e. while we're awaiting the in-flight `lock:false` before re-taking the
        /// lock. During this window EVERY geometry request must NOT
        /// start a drain, or a `lock:true` could race the still-in-flight `lock:false` on a
        /// separate SSH channel and leave the VISIBLE pane unlocked. The deferred re-lock clears
        /// it and then drives toward the LIVE grid.
        private var relockPending = false
        /// Hardware-keyboard connect/disconnect observers so key-drive focus follows the keyboard
        /// live (plug in → the front pane takes focus; unplug → it resigns). Removed in `stop()`.
        private var keyboardObservers: [NSObjectProtocol] = []

        /// IBM Plex Mono (the design's MACHINE voice) with Nerd Fonts' monospaced
        /// symbols in its cascade, so IBM Plex keeps its text metrics while Core Text
        /// splits missing private-use glyphs into `HerdrupSymbols` runs for SwiftTerm to draw.
        static let minFontSize: CGFloat = 9
        static let maxFontSize: CGFloat = 24
        /// Fitting the stream's cols to the width can need a smaller font.
        static let streamFitMinFontSize: CGFloat = 4
        static let defaultFontSize: CGFloat = 12.5
        /// Terminal font size in points, driven by the `terminal.fontSize` preference.
        /// Instance (not static) so it can change at runtime: setting `view.font` from
        /// `applyFont` flows through SwiftTerm's resetFont → sizeChangeRequestHandler
        /// → requestGeometry, which re-locks the PTY at the new grid and cell metrics.
        var paneFontSize: CGFloat = 12.5
        var paneFont: UIFont {
            Self.makePaneFont(size: paneFontSize)
        }

        /// The cascade, built ONCE and immutable.
        ///
        /// `paneFont` is read on the hot path — the PTY geometry helper and the
        /// scroll/mouse gesture handlers all ask for it — and rebuilding the cascade
        /// there materialised the entire system fallback list as `CTFontDescriptor`s per
        /// wheel tick, on top of `view.font`'s setter rebuilding SwiftTerm's `FontSet`.
        ///
        /// A `[CGFloat: UIFont]` cache keyed by size would be the obvious fix and is the
        /// wrong one: `Coordinator` is deliberately NOT `@MainActor` (see `applyFont`),
        /// so a mutable static would be a data race on dictionary storage, not merely a
        /// concurrency warning under this target's Swift 5.9 mode. A `static let` is
        /// initialised exactly once under the runtime's own guarantee, and size is then
        /// applied by `UIFont(descriptor:size:)`, which does no cascade work. Safe to
        /// resolve lazily because the faces come from `UIAppFonts` at launch — nothing
        /// in this app registers a font at runtime — so the answer cannot change.
        private static let paneFontDescriptor: UIFontDescriptor? = makePaneFontDescriptor()

        static func makePaneFont(size: CGFloat) -> UIFont {
            guard let descriptor = paneFontDescriptor else {
                return UIFont(name: "IBMPlexMono", size: size)
                    ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
            }
            return UIFont(descriptor: descriptor, size: size)
        }

        /// Nil when the symbol font is missing, which sends `makePaneFont` down the plain
        /// IBM Plex path rather than inventing a cascade with nothing in it.
        private static func makePaneFontDescriptor() -> UIFontDescriptor? {
            let referenceSize = defaultFontSize
            let primary = UIFont(name: "IBMPlexMono", size: referenceSize)
                ?? UIFont.monospacedSystemFont(ofSize: referenceSize, weight: .regular)
            guard let symbols = UIFont(name: "HerdrupSymbols", size: referenceSize) else {
                return nil
            }
            let systemFallbacks =
                CTFontCopyDefaultCascadeListForLanguages(primary as CTFont, nil)
                as? [CTFontDescriptor] ?? []

            // SYMBOLS FIRST — which is only safe because the font can no longer answer
            // for anything outside the private-use area. Both directions were tried and
            // both were wrong while the font carried its upstream character map:
            //
            //  * FIRST with upstream coverage: the artifact maps 14 non-private-use
            //    codepoints (U+23FB-U+23FE, U+2630, U+2665, U+26A1, U+276C-U+2771,
            //    U+2B58) that IBM Plex Mono does not, so it won all 14 from the system.
            //    U+26A1 has Emoji_Presentation=Yes, so `⚡` in agent output came out as a
            //    monochrome Nerd glyph instead of colour emoji. That shipped.
            //  * AFTER the system fallbacks: fixes those 14 and breaks the inverse, which
            //    is worse. Apple Color Emoji still maps the legacy SoftBank private-use
            //    block U+E001-U+E537, overlapping 170 shipped Nerd codepoints — Seti
            //    U+E001-E00A, Font Awesome Extension U+E201-E253, Weather Icons
            //    U+E301-E34D — and it precedes any later entry, so those 170 vanish
            //    behind emoji.
            //
            // No single ordering satisfies both, because the conflict is the font's
            // COVERAGE, not the order. `Tools/subset-symbols-font.py` therefore ships a
            // private-use-only subset: first position beats Apple Color Emoji for the
            // 170, and the 14 reach the system because this font no longer claims them.
            var cascade: [Any] = [symbols.fontDescriptor]
            cascade.append(contentsOf: systemFallbacks)

            // The descriptor, not a font: `makePaneFont` applies the size, which is the
            // only thing the pinch gesture varies.
            return primary.fontDescriptor.addingAttributes([.cascadeList: cascade])
        }

        /// Apply a new terminal font size (clamped to [minFontSize, maxFontSize]).
        /// A no-op if unchanged; otherwise setting `view.font` recomputes the cell
        /// metrics and PROPOSES a grid (`sizeChangeRequestHandler`), which this
        /// coordinator turns into a `set_pty_size`. The emulator is not resized here:
        /// the authoritative grid still arrives in band, so the reader sees the old
        /// frame until the new one is ready rather than text reflowing under them.
        func applyFont(size: CGFloat) {
            setPaneFontSize(min(max(size, Self.minFontSize), Self.maxFontSize))
        }

        private func setPaneFontSize(_ size: CGFloat) {
            guard size != paneFontSize else { return }
            paneFontSize = size
            prediction.reset()   // the overlay is laid out in the old cell size
            beginResizePresentation(reason: .local)
            view?.font = paneFont
            publishGridProbe()
        }

        private var lastStreamWidthFit: (cols: Int, width: CGFloat, size: CGFloat)?

        /// `fitsStreamWidth`: the font at which exactly the stream's `cols` fill the container's
        /// width. Measures `"W"`'s advance like `cellPixels` (the advance scales linearly
        /// with point size) and targets SwiftTerm's pixel-snapped cell width, which rounds
        /// the advance UP to the screen scale, so `cols` cells never overflow. The grid is
        /// the stream's, untouched; a same-size commit reconciles scroller and cursor.
        func fitFontToStreamWidth() {
            guard fitsStreamWidth, let view, let cols = streamAppliedGeometry?.cols else { return }
            let width = surface?.bounds.width ?? view.bounds.width
            guard width > 0, cols > 0 else { return }
            // `updateUIView` calls this on every body pass; only new inputs re-measure.
            if let fit = lastStreamWidthFit, fit.cols == cols, fit.width == width,
               fit.size == paneFontSize { return }
            defer { lastStreamWidthFit = (cols: cols, width: width, size: paneFontSize) }
            let reference = Self.maxFontSize
            let advance = ("W" as NSString)
                .size(withAttributes: [.font: Self.makePaneFont(size: reference)]).width
            let scale = UIScreen.main.scale
            let cell = floor(width / CGFloat(cols) * scale) / scale
            guard advance > 0, cell > 0 else { return }
            // A hair under the pixel boundary, so float error cannot ceil to the next pixel.
            let fitted = reference * (cell - 0.01 / scale) / advance
            let size = min(max(fitted, Self.streamFitMinFontSize), Self.maxFontSize)
            guard abs(size - paneFontSize) >= 0.01 else { return }
            setPaneFontSize(size)
            let terminal = view.getTerminal()
            view.applyTerminalSize(cols: terminal.cols, rows: terminal.rows)
        }

        /// Scrollback backfill — so scrolling up shows output produced BEFORE this connection,
        /// for a server whose keyframes carry no history. Each mount reads the last
        /// `backfillLines` rendered rows (server `recent`, incl. scrollback, as ANSI), and the
        /// first reset without `history_b64` feeds them into SwiftTerm's scrollback ABOVE the
        /// live seed. Also the `scrollbackLines` the stream asks the server to send as history.
        static let backfillLines: UInt32 = 1000            // server clamps `recent` to 1000 rows
        /// SwiftTerm scrollback ring, raised once per connect from its ~500 default. MUST stay
        /// >= backfillLines + live tail so a full backfill is retained (not truncated). A pane
        /// whose keyframe offers older history grows to `historyScrollbackCap` instead.
        static let scrollbackCap = 4000
        /// Safety cap so a truly hung `read` can't stall the seed forever — NOT a tight budget.
        /// The read runs concurrently with the stream's fresh SSH connect (~1-2s), and the reset
        /// only arrives after that connect, so a generous cap adds little to first paint in the
        /// normal case. The server renders `recent` instantly (~5ms); the real cost is the phone
        /// transferring up to ~200 KB of ANSI over SSH/Tailscale, which the old 1.2s budget cut off
        /// (→ zero history on real panes). On timeout we skip history and paint the seed as before.
        static let backfillTimeoutNanos: UInt64 = 6_000_000_000

        init(client: HerdrClient, paneID: String) {
            self.client = client
            self.paneID = paneID
        }

        func attach(_ surface: TerminalSurfaceView) {
            let view = surface.terminal
            self.view = view
            self.surface = surface
            mountedSurface = surface
            view.allowsFocus = !viewOnly
            view.terminalDelegate = self
            prediction.attach(to: view)
            #if DEBUG
            MainActor.assumeIsolated {
                TerminalInteractionHarness.register(paneID: paneID, view: view,
                    requestFit: { [weak self] cols, rows in self?.requestGeometry(cols: cols, rows: rows) },
                    isCovered: { [weak surface] in surface?.isCovered ?? false },
                    coverInstalls: { [weak surface] in surface?.coverInstallCount ?? 0 },
                    lastCoverMilliseconds: { [weak surface] in surface?.lastCoverMilliseconds ?? 0 },
                    isForeground: { [weak self] in self?.foreground ?? false })
                HistoryPagingDriver.register(view)
            }
            #endif
            // THIS coordinator owns the grid: SwiftTerm must propose, never commit.
            // Installed BEFORE the stream starts, so the very first layout pass cannot
            // reflow the emulator to a locally guessed size ahead of the daemon's.
            view.sizeChangeRequestHandler = { [weak self] cols, rows in
                // Following the stream: its grid is authoritative; local fits are never proposed.
                guard self?.fitsStreamWidth == false else { return }
                // A live-anchored terminal is deliberately not the container's size, so
                // its fit is not the one wanted: the container's is.
                if let surface = self?.surface, surface.isLiveAnchored {
                    surface.proposeAnchoredFit()
                    return
                }
                self?.requestGeometry(cols: cols, rows: rows)
            }
            surface.onAnchoredFit = { [weak self] cols, rows in
                guard self?.fitsStreamWidth == false else { return }
                self?.requestGeometry(cols: cols, rows: rows)
            }
            view.synchronizedOutputChangeHandler = { [weak self] active in
                self?.noteSynchronizedOutput(active: active)
            }
            view.displayCompletedHandler = { [weak self] complete in
                self?.noteDisplayCompleted(complete: complete)
                // Typing-latency diagnostics: a complete frame of the pane being typed into.
                if complete, self?.foreground == true { TypingLatencyRecorder.shared.painted() }
                #if DEBUG
                if let self, let view = self.view {
                    MainActor.assumeIsolated {
                        TerminalInteractionHarness.painted(paneID: self.paneID, view: view,
                                                           cellSize: view.cellSize, complete: complete)
                    }
                }
                #endif
            }
            // The container tells us a frame change is imminent, while the current
            // rendering is still on screen and can be retained.
            surface.onGeometryWillChange = { [weak self] in
                // Following the stream never requests geometry, so a local cover could only time out.
                guard self?.fitsStreamWidth == false else { return }
                // The reason is the sweep's: a keyboard-driven relayout may retain a
                // frame even though the send that dismissed the keyboard just dropped
                // one. This fires only when the frame REALLY changes, so a keyboard
                // event that does not resize this pane still costs nothing.
                self?.beginResizePresentation(
                    reason: self?.keyboardSweepActive == true ? .keyboard : .local)
            }
            surface.onWidthChange = { [weak self] in
                self?.fitFontToStreamWidth()
            }
            view.onWillInsertText = { [weak self] text, composing in
                self?.prepareForInsertedText(text, composing: composing)
            }
            view.onWillHandleHardwareKeys = { [weak self] in
                self?.adoptNativeInputFocus()
                self?.applyControlModifier()
            }
            view.onCancelControl = { [weak self] in
                self?.adoptNativeInputFocus()
                self?.cancelArmedControl()
                self?.userTookControl()
            }
            view.onUserInteraction = { [weak self] in self?.userTookControl() }
            // SwiftTerm posts this when it CONSUMES the one-shot control modifier while
            // encoding a key. `object: view` and no queue: the clear must land on this
            // main-thread turn, before the next key is encoded.
            controlResetObserver = NotificationCenter.default.addObserver(
                forName: .terminalViewControlModifierReset, object: view, queue: nil) { [weak self] _ in
                    guard let self, !self.stopped, !self.applyingControlModifier else { return }
                    self.controlArmedSetter?(false)
                }
            // Turn the view's touch→mouse-byte conversion off: a tap should start a
            // local text selection rather than leak a mouse report to the PTY.
            // This does not alter the emulator's alternate-screen wheel handling.
            view.allowMouseReporting = false
            // Backgrounding cancels an armed Ctrl and the presentation cover.
            keyboardObservers.append(
                NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                                       object: nil, queue: .main) { [weak self] _ in
                    self?.cancelArmedControl()
                    self?.finishPresentation()
                })
            // THE SOFTWARE KEYBOARD IS A GEOMETRY EVENT, and UIKit says so up front: the
            // notification carries the animation's duration, so the sweep it is about to
            // run has a known end. Without this the only evidence of a keyboard was ~20
            // layout passes that each looked like an independent resize.
            //
            // willChangeFrame covers show, hide, height changes and the floating/split
            // iPad keyboard in one notification; willHide is kept because an interactive
            // dismissal ends there. Both funnel into the same idempotent sweep.
            for name in [UIResponder.keyboardWillChangeFrameNotification,
                         UIResponder.keyboardWillHideNotification] {
                keyboardObservers.append(
                    NotificationCenter.default.addObserver(forName: name, object: nil,
                                                           queue: .main) { [weak self] note in
                        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey]
                                        as? Double) ?? 0.25
                        var covered: CGFloat?
                        if note.name == UIResponder.keyboardWillHideNotification {
                            covered = 0
                        } else if let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                            let screen = self?.view?.window?.bounds ?? UIScreen.main.bounds
                            covered = end.intersection(screen).height
                        }
                        self?.beginKeyboardSweep(duration: duration, coveredHeight: covered)
                    })
            }
            // Claim geometry ownership for this pane (see geometryGeneration): the newest
            // attach wins, and an older coordinator's delayed release checks this before
            // unlocking.
            let gen = (Self.geometryGeneration[paneID] ?? 0) + 1
            Self.geometryGeneration[paneID] = gen
            myGeometryGeneration = gen
            // Symmetric with reclaimGeometry: on a fast evict→reopen (or a transient
            // double-mount) of the SAME pane id, a prior coordinator's ALREADY-committed
            // lock:false could otherwise overtake this fresh mount's first lock:true and strand
            // the visible pane unlocked. Defer this mount's first lock (relockPending) until any
            // pending release for this pane has landed. A fresh pane id has no entry → awaits nil
            // → clears at once.
            relockPending = true
            let pane = paneID
            Task { @MainActor [weak self] in
                await Self.geometryReleaseTask[pane]?.value   // let a prior coordinator's release land first
                guard let self, !self.stopped, self.myGeometryGeneration == gen else { return }
                self.relockPending = false
                if let target = self.desiredTarget, target.cols >= 4, target.rows >= 2 {
                    self.startGeometryDrain()
                }
            }
            // A dedicated pan that scrolls the AGENT (see handleScrollPan) — for the
            // alt screen OR any mouse-reporting program (Claude Code). It recognizes
            // SIMULTANEOUSLY with SwiftTerm's own gestures: `gestureRecognizer(_:should
            // RecognizeSimultaneouslyWith:)` returns true below, and UIKit guarantees
            // simultaneous recognition when EITHER delegate says yes — so SwiftTerm's
            // mouse-pan (which has no delegate) cannot starve this one. `allowMouseReporting` is
            // turned OFF for every pane (see attach above), so a tap/long-press starts a LOCAL
            // text selection rather than a mouse report — and under key drive it also means a
            // forwarded tap can never leak mouse bytes to the PTY.
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
            pan.delegate = self
            // On the Mac (Designed for iPad) a trackpad or wheel arrives as scroll events,
            // which a pan recognizer ignores unless it opts in; without this a Claude Code
            // pane could not be scrolled there at all.
            if Self.indirectScrollInput { pan.allowedScrollTypesMask = .all }
            view.addGestureRecognizer(pan)
            scrollPan = pan
            // Two-finger tap jumps to the live tail. Every SwiftTerm recognizer is
            // single-finger, so this needs no failure requirement and costs single,
            // double and triple tap nothing. The single-finger double tap is LEFT TO
            // SwiftTerm: it is the only gesture that word-selects AND installs the
            // drag-to-extend pan, so taking it over removed selection entirely.
            let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
            twoFingerTap.numberOfTouchesRequired = 2
            twoFingerTap.delegate = self
            twoFingerTap.cancelsTouchesInView = false
            view.addGestureRecognizer(twoFingerTap)
            // TWO TAP RECOGNIZERS, ONE JOB EACH, and the split is load-bearing.
            //
            // A single recognizer doing both jobs DESTROYS THE SELECTION IT EXISTS TO
            // ENABLE. It must not `require(toFail:)` SwiftTerm's double tap, because
            // SwiftTerm's `doubleTap` selects and presents its Copy menu WITHOUT calling
            // `becomeFirstResponder` (only its long press does) while `canPerformAction`
            // gates Copy on being first responder, so firing on tap 1 is the only thing
            // that makes Copy available. But without that failure requirement it ALSO
            // fires on tap 2, and clearing a selection there wipes the word SwiftTerm just
            // selected on the same touch-up. Both recognizers live on the same view with
            // `shouldRecognizeSimultaneouslyWith` true and UIKit does not document their
            // relative order, so it was a coin toss on whether word select survived.
            //
            // FOCUS TAP: no failure requirement, so it fires on tap 1 and establishes the
            // responder in time for tap 2's menu. Taking focus is idempotent, so firing
            // again on tap 2 costs nothing.
            let focusTap = UITapGestureRecognizer(target: self, action: #selector(handleFocusTap(_:)))
            focusTap.delegate = self
            focusTap.cancelsTouchesInView = false
            view.addGestureRecognizer(focusTap)
            // MENU TAP: repositions the Copy menu SwiftTerm puts in the wrong place, and
            // does nothing else. A review measured the menu overlapping the pane header —
            // the back chevron, the title, the NEEDS YOU badge and the refresh icon — by
            // downloading a CI artifact and looking at it. THAT MEASUREMENT IS THE FACT HERE.
            //
            // THE MECHANISM IS NOT SETTLED. I previously wrote that
            // `makeContextMenuRegionForSelection()` builds its avoid-rect from a BUFFER row
            // while the renderer subtracts `yDisp`. A second reviewer traced the same path and
            // could not confirm it: on iOS the TerminalView IS the scroll view, and
            // `calculateTapHit` returns content-space rows — the same space
            // `makeContextMenuRegionForTap(point:)` uses — so the mismatch is not visible in
            // that path. So the defect is observed and the cause is unproven, and the real fix
            // may belong upstream. This re-present is a targeted workaround, not a diagnosis.
            //
            // IT MUST WAIT FOR THE TRIPLE TAP, and this is what made the first version INERT.
            // SwiftTerm defers `doubleTap` behind `tripleTap.require(toFail:)`
            // (iOSTerminalView.swift:1078), so its selection lands about one multi-tap timeout
            // — roughly 0.3s — AFTER tap 2's touch-up. A recognizer with no failure requirement
            // fires immediately, so the async hop ran BEFORE any selection existed, found
            // `hasActiveSelection` false and returned: on a fresh double tap the menu stayed
            // over the header, and on a re-double-tap SwiftTerm's own later presentation won
            // anyway. Final placement was SwiftTerm's in every case. Mirroring the same
            // `require(toFail:)` loop `clearTap` uses puts this after SwiftTerm's own handler,
            // and also stops it firing on tap 2 of a TRIPLE tap.
            //
            // It re-presents only and does not re-select, so the word SwiftTerm just selected
            // survives. `showStandardContextMenu(at:)` DOES call `becomeFirstResponder()`
            // (iOSTerminalView.swift:1392-1396) — an earlier comment here claimed it takes no
            // responder and that was simply false. `focusTap` normally claims the responder
            // first on every idiom, but this async hop can still bypass
            // `wantsTerminalKeyFocus`; its `foreground`/`stopped` guards are necessary.
            //
            // Declared BEFORE `clearTap` so that recognizer's "every 2-tap recognizer must
            // fail" loop keeps meaning exactly that.
            let menuTap = UITapGestureRecognizer(target: self, action: #selector(handleMenuRepositionTap(_:)))
            menuTap.numberOfTapsRequired = 2
            menuTap.delegate = self
            menuTap.cancelsTouchesInView = false
            // SwiftTerm's tripleTap is its only 3-tap recognizer; requiring it to fail is what
            // orders this after SwiftTerm's own doubleTap handler.
            for gr in view.gestureRecognizers ?? [] {
                if let t = gr as? UITapGestureRecognizer, t.numberOfTapsRequired == 3 {
                    menuTap.require(toFail: t)
                }
            }
            view.addGestureRecognizer(menuTap)
            // CLEAR TAP: requires SwiftTerm's 2-tap recognizer to fail, exactly as
            // SwiftTerm guards its own `singleTap` (setupGestures does
            // `singleTap.require(toFail: doubleTap)` for this very reason). So it can only
            // fire on a GENUINE single tap, never on tap 2 of a word select. SwiftTerm's
            // doubleTap already requires its tripleTap, so this inherits the whole chain.
            let clearTap = UITapGestureRecognizer(target: self, action: #selector(handleClearSelectionTap(_:)))
            clearTap.delegate = self
            clearTap.cancelsTouchesInView = false
            for gr in view.gestureRecognizers ?? [] {
                if let t = gr as? UITapGestureRecognizer, t.numberOfTapsRequired == 2 {
                    clearTap.require(toFail: t)
                    clearTapRequirementCount += 1
                }
            }
            view.addGestureRecognizer(clearTap)
            // (Removed: the horizontal swipe-between-agents recognizers. A finger/mouse drag to
            // SELECT text was triggering them and paging to an unwanted agent; agent switching
            // stays fully reachable via the list/sidebar, and their removal frees horizontal drag
            // for SwiftTerm's drag-to-extend selection. `onNavigate` is left wired but unused.)
            style(view)
            // The finger-scroll half of the Latest pill's tail state. Wired here, after the
            // gestures, so it is live for the reader's very first drag — the pill's primary case.
            observeContentOffset(view)
            // Tests that inspect the untouched terminal need a baseline before a gesture
            // publishes its first selection reading. Inert outside the mock DEBUG app.
            publishSelectionProbe("mounted")
            startBackfill()   // fetch history CONCURRENTLY with the stream; see startBackfill
            start()
        }

        /// Jump the pane to its newest output. A mouse-mode or alt-screen agent (Claude
        /// Code) captures the wheel and keeps its own viewport, so send it Ctrl+End
        /// (`ESC[1;5F`, scroll-to-bottom plus re-enable auto-follow), read-only exactly
        /// like the scroll bytes and never a keystroke. A plain shell has native
        /// SwiftTerm scrollback, so jump its UIScrollView to the maximum offset.
        ///
        /// Deliberately NOT annotated `@MainActor`, matching `applyFont`: it is called
        /// from `updateUIView` and from a UIKit gesture handler, both already on the
        /// main thread, and the async send hops explicitly.
        func jumpToTail() {
            // `foreground` here too, matching the two byte-sending gesture handlers. Reached
            // from `updateUIView` as well as from the two-finger tap, which is why
            // `setForeground` now runs BEFORE `performJumpToTail`: guarding on a flag this
            // pass has not yet written would guard nothing.
            guard !stopped, foreground, let view else { return }
            // The reader asked for the newest output: whatever a resize was about to
            // reveal must not put them back where they were.
            userTookControl()
            let term = view.getTerminal()
            // View-only sends nothing: the jump is a local scroll whatever the agent's mode.
            if !viewOnly, term.isCurrentBufferAlternate || term.mouseMode != .off {
                // Report the tail ONLY once the send has actually landed. Reporting up
                // front cleared the pill while a rejected or dropped Ctrl+End left the
                // agent's viewport exactly where it was, so the reader lost the affordance
                // and the state lied at the same time.
                prediction.reset()   // Ctrl+End bypasses the key path
                Task { @MainActor [weak self] in
                    guard let self, !self.stopped, !self.viewOnly else { return }
                    do {
                        _ = try await self.client.sendText(pane: self.paneID, text: "\u{1b}[1;5F")
                        self.reportTailState(atTail: true)
                    } catch {
                        // Keep `lastReportedAtTail` untouched, so the pill stays up and the
                        // reader can retry. A failed jump must not read as a completed one.
                    }
                }
            } else {
                // SwiftTerm's own explicit scroll: it clears the manual-scrolling state
                // (so auto-follow re-engages), reconciles the offset even when the row is
                // unchanged, and drops the logical resize anchor. Writing contentOffset
                // directly used to be necessary; it no longer is, and it left the library
                // guessing whether the offset came from a gesture.
                view.scrollTo(row: Int.max)
                // Synchronous and cannot fail, so the tail is true right now.
                reportTailState(atTail: true)
            }
        }

        /// Executes one jump per token increment. `updateUIView` runs on every SwiftUI
        /// body pass, so the token comparison is what makes this idempotent.
        func performJumpToTail(ifTokenChanged token: Int) {
            guard token != lastJumpToTailToken else { return }
            lastJumpToTailToken = token
            jumpToTail()
        }

        /// The last find request this Coordinator executed, so a body pass that changes
        /// nothing does not re-run the search and steal the reader's position.
        private var lastFindRequest: FindRequest?
        /// The last `(index, total)` published, so an unchanged pair does not re-render
        /// the header on every pass.
        private var lastFindResult: (Int, Int)?
        var onFindResult: (Int, Int) -> Void = { _, _ in }

        /// Runs one search per CHANGE of the request, and clears the highlight when the
        /// find bar closes.
        ///
        /// Closing does NOT return to the tail. A reader who searched their way back into
        /// history is still reading it; yanking them to the newest output would undo the
        /// very thing they used search for. Following resumes the moment they scroll back
        /// down, exactly as it does after any manual scroll.
        func performFind(_ request: FindRequest?) {
            guard request != lastFindRequest else { return }
            let previous = lastFindRequest
            lastFindRequest = request
            guard let view else { return }

            guard let request, !request.term.isEmpty else {
                // Empty term or closed bar: drop the highlight, leave the viewport alone.
                view.clearSearch()
                publishFindResult(nil)
                return
            }

            // A retained resize frame must not survive a search: the view is about to
            // scroll to a match the reader would otherwise not see happen.
            userTookControl()

            // Only a next/previous step advances; editing the term restarts from the top
            // of the current match set, which is what SwiftTerm's engine does when the
            // term changes (SearchEngine.swift:70-74).
            let stepped = previous?.generation != request.generation
            let backward = request.direction == .backward
            _ = stepped && backward
                ? view.findPrevious(request.term)
                : view.findNext(request.term)

            let summary = view.searchMatchSummary(request.term)
            publishFindResult(summary)
        }

        private func publishFindResult(_ summary: (index: Int, total: Int)?) {
            let pair = summary.map { ($0.index, $0.total) } ?? (0, 0)
            if let last = lastFindResult, last == pair { return }
            lastFindResult = pair
            // ASYNC, and this is the whole reason search appeared to find nothing.
            //
            // `performFind` runs inside `updateUIView`, i.e. DURING a SwiftUI update pass.
            // Calling back synchronously mutates the host's @State while that pass is in
            // flight, and SwiftUI discards it - the search really ran (engineMatches
            // reported 99 matches on the same buffer) but the counter never moved.
            // Hopping to the next runloop turn makes it an ordinary state change.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.onFindResult(pair.0, pair.1)
            }
        }

        /// The last collapse token this Coordinator has acted on. Starts at 0, matching the
        /// host's initial `collapseToken`, so a freshly created pane does not read its own
        /// initial state as a pending collapse request.
        private var lastCollapseToken = 0

        /// True for exactly ONE `updateUIView` pass per chevron tap — the pass that observes a
        /// token the Coordinator has not consumed yet.
        ///
        /// Same shape as `performJumpToTail(ifTokenChanged:)` above and for the same reason: a
        /// SwiftUI input cannot express "for the next pass only" as a bool the host resets,
        /// because the host does not control when passes happen and any async reset races the
        /// pass it was meant for. A monotonic counter needs no such timing assumption.
        func consumeCollapse(ifTokenChanged token: Int) -> Bool {
            guard token != lastCollapseToken else { return false }
            lastCollapseToken = token
            return true
        }

        /// Publishes tail state to the host, and ONLY on a change, so scrolling cannot
        /// re-render SwiftUI on every frame.
        ///
        /// The publish is deferred one main-queue turn on purpose. `performJumpToTail`
        /// runs INSIDE `updateUIView`, and the jump reports `atTail: true`, so a
        /// synchronous call would mutate SwiftUI `@State` during a view update, which
        /// SwiftUI warns about and can re-enter. The dedupe above stays synchronous, so
        /// deferring cannot publish a stale duplicate.
        /// THE SINGLE PUBLISHER of tail state, and the single place the alternate screen is
        /// judged — deliberately here rather than in each caller.
        ///
        /// Review found the alt-screen early return I had added to `scrolled(source:position:)`
        /// was missing from `observeContentOffset`'s KVO hop, so a finger drag on an oversized
        /// alt-screen grid could still publish `atTail: false` and fight the delegate path into
        /// pill flicker. The narrow fix was to copy the guard into the KVO hop. That is a SITE
        /// fix for what is plainly a CLASS defect: two publishers, one of them guarded, and
        /// nothing stopping a third from being added unguarded.
        ///
        /// So the guard lives in the funnel every publisher already goes through, and each
        /// caller now reports what it actually observed. A future publisher inherits the
        /// alt-screen rule by construction instead of by whoever adds it remembering.
        ///
        /// WHY THE ALT SCREEN IS FORCED TO at-tail rather than left alone: a TUI pane keeps its
        /// own viewport and is served by jumpToTail's Ctrl+End path, not by this pill, so the
        /// honest report is "nothing to return to". `isCurrentBufferAlternate` is a synchronous
        /// buffer-IDENTITY check, not a heuristic, so it cannot transiently lie on a normal
        /// buffer — verified in the pinned SwiftTerm 1.15.0 by review.
        private func reportTailState(atTail: Bool) {
            // While a retained frame is on screen the reader has decided nothing: the
            // clamps UIKit performs mid-resize, and a temporarily borrowed alternate
            // screen, are not user intent. The actual state is published on reveal.
            guard !tailPublishHeld else { return }
            var atTail = atTail
            // For guests too, deliberately (#472 review f3): on the alt screen SwiftTerm pins
            // contentOffset to yDisp*cell on every frame and its scroll delegate reports
            // position 0, so a view-only "bottom" there is neither stable nor reachable by
            // scrollTo(row:). Until SwiftTerm exposes one, alt panes show no Latest pill.
            if view?.getTerminal().isCurrentBufferAlternate == true { atTail = true }
            guard atTail != lastReportedAtTail else { return }
            lastReportedAtTail = atTail
            let publish = onTailStateChange
            DispatchQueue.main.async { publish?(atTail) }
        }

        @objc private func handleTwoFingerTap(_ gr: UITapGestureRecognizer) {
            // `foreground` is defence in depth. Today a backgrounded pane is unreachable
            // because the keep-alive container renders it `opacity(0)` and
            // `allowsHitTesting(false)`, but this handler SENDS BYTES, so it should not
            // depend on a host layout decision staying the way it is.
            guard !stopped, foreground, gr.state == .ended else { return }
            // A view-only pane on the alt screen has no reachable bottom: SwiftTerm pins the
            // offset to the top row there, so `scrollTo(row: Int.max)` would jump the guest
            // UP. Same reason the Latest pill is suppressed there (see reportTailState).
            if viewOnly, view?.getTerminal().isCurrentBufferAlternate == true { return }
            jumpToTail()
        }

        /// Establishes responder ownership, and NOTHING else. Fires on tap 1 of any tap
        /// sequence because it carries no failure requirement, which is the only way the
        /// responder exists in time for SwiftTerm's double-tap menu to offer Copy:
        /// SwiftTerm's `doubleTap` selects without becoming first responder, and
        /// `canPerformAction` returns `selection.active` for Copy only to a responder.
        ///
        /// Deliberately does NOT clear a selection. Clearing here fired on tap 2 as well
        /// and wiped the word SwiftTerm had just selected on the same touch-up.
        /// Focus comes from a deliberate terminal tap, not keyboard presence;
        /// selection and Copy still use the same responder.
        @objc private func handleFocusTap(_ gr: UITapGestureRecognizer) {
            // View-only never takes focus or raises a keyboard.
            guard !stopped, foreground, !viewOnly, gr.state == .ended else { return }
            // A TAP THAT STOPS A SCROLL IS NOT A REQUEST FOR THE KEYBOARD, and treating it as one
            // is a defect the owner hit on a real iPhone: scrolling back through output would
            // "randomly" raise the keyboard, which relayouts the terminal band, resizes the PTY and
            // forces a re-render — losing the reader's place in the output they were reading.
            //
            // WHY IT FIRES AT ALL. `focusTap` is a 1-tap recognizer with NO `require(toFail:)` —
            // deliberately, because the responder must exist by tap 1 for SwiftTerm's double-tap
            // Copy menu to work — and it is attached to `TerminalView`, which IS a `UIScrollView`,
            // with `cancelsTouchesInView = false`. The universal iOS idiom for arresting momentum
            // scrolling is a single tap, so that tap lands on the terminal and the recognizer
            // cannot tell it apart from a deliberate tap on the text.
            //
            // THE FIRST VERSION OF THIS GUARD WAS INERT, and the way that was caught is worth
            // keeping. It tested `view.isDragging || view.isDecelerating` HERE, at `.ended` —
            // i.e. touch-UP. But a scroll-arresting touch cancels deceleration at touch-DOWN, so
            // both flags are already false by the time this runs and the guard never fired. The
            // evidence was in front of me and I misread it: the regression test reached the guard
            // 0 times in 6 attempts with ~1s deceleration windows, which I wrote off as unlucky
            // timing. Review read the same 0/6 as what it was — a measurement of inertness. An
            // empty result is a claim about the instrument, not about the world.
            //
            // SO THE SIGNAL IS "DID THE CONTENT JUST MOVE UNDER A FINGER", sampled from the KVO
            // observer on `contentOffset` that already drives the Latest pill. That observer
            // records a timestamp only for offset writes made while the scroll view reports
            // `isDragging || isDecelerating` — see the note there.
            //
            // THAT QUALIFIER IS THE SECOND CORRECTION, and it came from review as well. Recording
            // every offset change was worse than the bug: SwiftTerm's auto-follow writes
            // `contentOffset` on every output frame, so on a BUSY pane the timestamp was
            // permanently fresh and this guard suppressed every tap — the reader could not focus
            // the terminal at all while an agent was producing output. The flags were never the
            // wrong signal; reading them at tap `.ended` was the wrong PLACE. Inside the observer
            // they are true for exactly the writes a finger caused.
            //
            // Nothing here depends on recognizer ordering or on when UIScrollView clears its
            // state, which is what made the first version unprovable without a device.
            //
            // A tap that stops momentum arrives while the offset was changing microseconds ago, so
            // it is suppressed. A tap on a settled pane — or on a pane that is merely following
            // output — sees motion far in the past, so it focuses normally. The window is
            // deliberately short: long enough to cover the gap between the last offset change and
            // touch-up, short enough that a deliberate tap a moment after reading never waits.
            let sinceMotion = CACurrentMediaTime() - lastContentMotion
            if sinceMotion < Self.scrollSettleWindow {
                publishSelectionProbe("scrollTapIgnored")
                return
            }
            onTerminalFocusRequest?()
            // Publishes because this recognizer has NO failure requirement, so it fires on tap 1
            // of ANY tap that actually lands on the terminal. That makes it the discriminator for
            // a tap that appears to do nothing: if the probe's publisher changes to focusTap, the
            // touch reached the view and the fault is downstream in clearTap's require-to-fail
            // chain; if it does not change at all, the tap missed the terminal entirely.
            //
            // The scroll-ignored path publishes its OWN publisher name so a test can tell "the tap
            // was suppressed because the pane was scrolling" from "the tap never arrived", which
            // are otherwise identical: both leave focus untaken and the label unchanged.
            //
            // NAMED `scrollTapIgnored` AND NOT `focusTapScrollIgnored` deliberately: probe
            // assertions are substring matches, and TerminalSelectionTests already asserts
            // `contains("pub=focusTap")`. Any name with `focusTap` as a PREFIX would satisfy that
            // assertion from the suppressed path and silently weaken it — the same prefix trap that
            // made `pub=clearTap` match `pub=clearTapEntry` and greened a vacuous receipt.
            publishSelectionProbe("focusTap")
        }

        /// Clears an active selection on a GENUINE single tap. Guarded by
        /// `require(toFail:)` against SwiftTerm's 2-tap recognizer at attach time, so it
        /// cannot fire on tap 2 of a word select.
        ///
        /// SwiftTerm's own singleTap clears too, but only when the view is ALREADY first
        /// responder, so on an unfocused pane its tap was spent taking focus and the
        /// selection survived. `clearSelection()` flips `SelectionService.active`, whose
        /// setter notifies `selectionChanged(source:)`, which calls `setNeedsDisplay` and
        /// `disableSelectionPanGesture()`, so one call both redraws and removes the lazy
        /// extend pan.
        @objc private func handleClearSelectionTap(_ gr: UITapGestureRecognizer) {
            // PUBLISHES AT ENTRY, before any guard, because the previous round could not tell
            // "this handler never ran" from "it ran and bailed". CI reported pub=focusTap with the
            // selection still active, which proved the touch reached the terminal and that clearTap
            // produced nothing — but not which of those two it was. An entry publish separates
            // them: pub=clearTapEntry means the recognizer fired and something below refused,
            // pub=focusTap still means the recognizer itself never recognized.
            publishSelectionProbe("clearTapEntry(state=\(gr.state.rawValue) requires=\(clearTapRequirementCount))")
            guard !stopped, foreground, gr.state == .ended, let view else { return }
            guard view.hasActiveSelection else { return }
            view.clearSelection()
            // So a test can distinguish "the clear reached the view" from "the highlight
            // happened to stop being drawn". No-op outside UI-test builds.
            publishSelectionProbe("clearTap")
        }

        /// Re-present the Copy menu at the TAP POINT. Ordered AFTER SwiftTerm's own handler by
        /// `menuTap.require(toFail: tripleTap)` — see the `menuTap` comment in `attach` for why
        /// the first version, which had no failure requirement, was inert.
        ///
        /// Guarded on a selection actually existing, so a double tap that selects nothing —
        /// blank space past the end of a line yields an EMPTY range, which SwiftTerm still
        /// marks active but paints nothing — does not get a menu moved onto it. `foreground`
        /// is re-checked inside the hop: a pane can be backgrounded between the tap and the
        /// hop, and a hidden pane must not present a menu. Those guards also bound
        /// `showStandardContextMenu(at:)`'s undocumented `becomeFirstResponder()`, which
        /// bypasses the `wantsTerminalKeyFocus` gate.
        @objc private func handleMenuRepositionTap(_ gr: UITapGestureRecognizer) {
            guard !stopped, foreground, gr.state == .ended, let view else { return }
            let point = gr.location(in: view)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped, let view = self.view else { return }
                self.publishSelectionProbe("menuTap")   // records state even when the guards below refuse
                guard self.foreground, view.hasActiveSelection else { return }
                view.showStandardContextMenu(at: point)
            }
        }

        /// THE SELECTION PROBE — the instrument, and it exists because four consecutive CI runs
        /// of the selection receipt failed on my own measurement rather than on the product,
        /// and two confident diagnoses of why were both wrong.
        ///
        /// A UI test can only see PIXELS, so "no highlight" cannot distinguish between: the
        /// double tap never selected anything, it selected an EMPTY range, a resize wiped the
        /// selection (`processSizeChange` sets `selection.active = false` on any rows/cols
        /// change, AppleTerminalView.swift:232), or the selection exists and simply is not
        /// painted the colour the detector looks for. Those have different fixes and I have
        /// been guessing between them. This publishes the state itself into an accessibility
        /// element so the test reads SwiftTerm's answer instead of inferring one.
        ///
        /// DEBUG BUILDS ONLY, AND THE PREVIOUS VERSION OF THIS PARAGRAPH WAS FALSE. It claimed the
        /// label "carries the SELECTED LENGTH, never the selected text" while the code fourteen
        /// lines below published the text, and the paragraph fourteen lines below said so — the
        /// same comment contradicted itself, and the wrong half was the safety claim. A review
        /// caught it.
        ///
        /// The runtime env check was also the ONLY gate. `MockTransport` and `ScreenshotMock` live
        /// inside `#if DEBUG`, but this file had no `#if DEBUG` anywhere, so the probe compiled
        /// into Release and a Release build launched with `HERDR_SCREENSHOT_MOCK` set would route
        /// to a REAL pane while the probe attached to the view tree and published that pane's
        /// selected text to the accessibility layer. Now compiled out entirely, so the env var is
        /// defence in depth rather than the whole defence.
        ///
        /// What it publishes: sel, len, the selected TEXT, rows, cols, ydisp and a resize count.
        /// The text is deliberate and is what made the row-space defect findable; it is safe only
        /// because this cannot exist outside a DEBUG build fed by the canned mock transport.
        fileprivate func publishSelectionProbe(_ publisher: String) {
            #if DEBUG
            guard ProcessInfo.processInfo.environment["HERDR_SCREENSHOT_MOCK"] != nil,
                  let view else { return }
            let probe: UIView
            if let existing = selectionProbe {
                probe = existing
            } else {
                probe = UIView(frame: .zero)
                probe.isAccessibilityElement = true
                probe.accessibilityIdentifier = "terminal-selection-probe"
                view.addSubview(probe)
                selectionProbe = probe
            }
            // `getSelection()` returns the selected TEXT as `String?` (AppleTerminalView.swift
            // :2535) — an earlier version called `.getSelectedText()` on it, which is the
            // SelectionService method and does not exist here.
            //
            // THE TEXT ITSELF IS PUBLISHED, and it is the measurement that matters. Every
            // hypothesis for "SwiftTerm holds a selection and nothing is painted" has now been
            // eliminated by READING: the rows resolve to the same buffer-absolute space
            // (contentOffset.y == yDisp * cellHeight), the paint loop does consume
            // `.selectionBackgroundColor`, and `selectionChanged` does call `setNeedsDisplay`
            // on both the Metal and CoreGraphics paths. So one of those readings is wrong, and
            // the one runtime fact no public API exposes is WHICH LINE the selection landed on.
            //
            // The fixture answers it: the mock seeds uniquely numbered lines
            // ("SCROLLTEST line 007  the quick brown fox…") and `selectWordOrExpression`
            // treats digits as a selectable word, so a tap aimed at the number yields the line
            // number as the selected text. If the test taps a line the view is showing and the
            // probe reports a number from far outside the visible window, the tap's row space
            // is wrong; if it reports a visible number, the row space is fine and the defect is
            // in the drawing after all. Either answer kills a hypothesis rather than adding one.
            //
            // Safe to publish: this text is synthetic fixture content in a UI-test-only build,
            // never a real pane's output.
            let active = view.hasActiveSelection
            let selected = view.getSelection() ?? ""
            let term = view.getTerminal()
            // yDisp IS THE LAST DISCRIMINATOR, and it is public (`Terminal.buffer` is
            // `public private(set)`, `Buffer.yDisp` is `public`), so no internals are needed.
            //
            // The run at 001a092a reported a real three-character selection of "187" with ZERO
            // painted pixels, deterministically in both passes. The fixture numbers its lines, so
            // that text identifies the selection's line: "187" is 1-indexed, hence buffer row 186.
            // Publishing yDisp lets the test decide, arithmetically rather than by inference,
            // between the only two remaining explanations:
            //   186 inside [yDisp, yDisp + rows - 1]  => the selection sits on a row being drawn,
            //                                            so the PAINT is broken;
            //   186 outside that window               => the selection sits on a row nobody draws,
            //                                            so the tap's ROW SPACE is wrong after all.
            // Both were reached by reading and neither survived; this settles it by measurement.
            // `yBase` is deliberately NOT published: it is internal to SwiftTerm (Buffer.swift:43
            // declares it without `public`, unlike yDisp at 58), so reading it would not compile.
            // Checked before pushing rather than after CI said so.
            // `pub` names WHICH handler published this reading and counts publishes, so a test can
            // tell "the handler ran and did nothing" from "the handler never ran". Without it, a
            // stale reading from an earlier gesture is indistinguishable from a fresh one, and CI
            // spent a round on exactly that ambiguity: after a single tap the label still read
            // sel=1 text=<lazy>, which could have meant clearTap failed OR that the tap never
            // reached the terminal at all.
            //
            // `fr` IS THE RESPONDER STATE, added so the collapse chevron's contract is measurable
            // at all. Review rejected this PR's first collapse mechanism as inert — a bool cleared
            // in `DispatchQueue.main.async`, which drains before SwiftUI's update flush, so the
            // resign would never have run. Nothing in the suite could have caught that, because
            // "did the terminal give up the responder while keeping its selection" had no
            // observable at all: an inert fix and a working one produced identical output. That is
            // the worst shape a defect can have, so the observable comes with the fix.
            probePublishCount += 1
            probe.accessibilityLabel =
                "sel=\(active ? 1 : 0) len=\(selected.count) text=<\(selected)> "
                + "rows=\(term.rows) cols=\(term.cols) ydisp=\(term.buffer.yDisp) "
                + "fr=\(view.isFirstResponder ? 1 : 0) "
                + "hardware=\(GCKeyboard.coalesced == nil ? 0 : 1) "
                // MOTION AGE IN MILLISECONDS, published so a test can measure the guard's PREMISE
                // rather than infer it. The previous version of the scroll guard was inert and the
                // only symptom was a test that never reached it, which is indistinguishable from a
                // test whose timing never lined up. With this, a run can say "the tap arrived 40ms
                // after the last offset change" and the premise is a measurement, not a hope.
                + "motionms=\(Int((CACurrentMediaTime() - lastContentMotion) * 1000)) "
                + "resizes=\(resizeCount) pub=\(publisher)#\(probePublishCount)"
            #endif
        }

        /// DEBUG-only receipt for the guest scrollback test: the text of the grid's top row
        /// (`yDisp`, which a scroll moves) in a view-only pane, so a swipe can be shown to
        /// reveal backfilled history. Same gating as `publishSelectionProbe`: compiled out of
        /// Release, inert without `HERDR_SCREENSHOT_MOCK`, and only ever fed canned mock output.
        fileprivate func publishTopRowProbe() {
            #if DEBUG
            guard viewOnly, ProcessInfo.processInfo.environment["HERDR_SCREENSHOT_MOCK"] != nil,
                  let view else { return }
            let probe: UIView
            if let existing = topRowProbe {
                probe = existing
            } else {
                probe = UIView(frame: .zero)
                probe.isAccessibilityElement = true
                probe.accessibilityIdentifier = "terminal-top-row-probe"
                view.addSubview(probe)
                topRowProbe = probe
            }
            probe.accessibilityLabel =
                view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true) ?? ""
            publishGridProbe()
            #endif
        }

        /// DEBUG-only receipt for the guest sizing tests: the grid the emulator is at, the font,
        /// and how much of the width the grid fills (`fill=1.00` when fitted to the width).
        /// Gated exactly like `publishTopRowProbe`.
        fileprivate func publishGridProbe() {
            #if DEBUG
            guard viewOnly, ProcessInfo.processInfo.environment["HERDR_SCREENSHOT_MOCK"] != nil,
                  let view, let surface else { return }
            let probe: UIView
            if let existing = gridProbe {
                probe = existing
            } else {
                probe = UIView(frame: .zero)
                probe.isAccessibilityElement = true
                probe.accessibilityIdentifier = "terminal-grid-probe"
                view.addSubview(probe)
                gridProbe = probe
            }
            let terminal = view.getTerminal()
            let width = surface.bounds.width
            let fill = width > 0 ? CGFloat(terminal.cols) * view.cellSize.width / width : 0
            probe.accessibilityLabel = "cols=\(terminal.cols) rows=\(terminal.rows) "
                + String(format: "font=%.1f fill=%.2f", paneFontSize, fill)
            #endif
        }
        #if DEBUG
        private var gridProbe: UIView?
        #endif

        func stop() {
            stopped = true                  // no new resize/scroll may start after this
            #if DEBUG
            if let view {
                MainActor.assumeIsolated {
                    TerminalInteractionHarness.unregister(paneID: paneID, view: view)
                }
            }
            #endif
            offsetObservation?.invalidate() // no tail-state publish from a torn-down pane
            offsetObservation = nil
            // Presentation first: a torn-down pane must never be left under a retained
            // frame, and no late reveal or deadline may touch a replaced view.
            finishPresentation()
            if let observer = controlResetObserver {
                // Removed BEFORE the native reset below, so our own write cannot be read
                // as the user's chord being consumed.
                NotificationCenter.default.removeObserver(observer)
                controlResetObserver = nil
            }
            cancelArmedControl()
            view?.sizeChangeRequestHandler = nil
            view?.synchronizedOutputChangeHandler = nil
            view?.displayCompletedHandler = nil
            view?.onWillInsertText = nil
            view?.onCancelControl = nil
            view?.onWillHandleHardwareKeys = nil
            view?.onUserInteraction = nil
            surface?.onGeometryWillChange = nil
            view?.terminalDelegate = nil    // stop further SwiftTerm callbacks (sizeChanged)
            view?.isScrollEnabled = true    // restore native scroll if we disabled it mid-drag
                                            // (stop() also runs on .exited while on screen)
            scrollPan?.isEnabled = false    // no drag can send bytes to an exited/replaced pane
            scrollSendTask?.cancel()
            scrollSendTask = nil
            adoptHistoryCursor(nil)         // no page lands in a torn-down or exited pane
            // No forwarded keystroke can reach an exited/replaced pane: the send in flight is
            // cancelled and the input stream closed (frames it never acked count as lost).
            if let inputSender { MainActor.assumeIsolated { inputSender.stop() } }
            prediction.detach()
            if !viewOnly { TypingLatencyRecorder.shared.abandonUnsent() }  // queued keys never go out
            for token in keyboardObservers { NotificationCenter.default.removeObserver(token) }
            keyboardObservers.removeAll()
            keyboardSweepActive = false
            keyboardSweepDeadlineTask?.cancel()
            keyboardSweepDeadlineTask = nil
            deferredKeyboardTarget = nil
            pendingHostInputFrameTask?.cancel()
            pendingHostInputFrameTask = nil
            pendingHostInputFrame = nil
            streamTask?.cancel()
            streamTask = nil
            watchdogTask?.cancel()          // stop the stream-stuck watchdog
            watchdogTask = nil
            heartbeatTask?.cancel()         // stop the PTY width-lease keep-alive (#137)
            heartbeatTask = nil
            hiddenReleaseTask?.cancel()     // teardown releases right below
            hiddenReleaseTask = nil
            reconnectTask?.cancel()         // cancel any pending backoff restart
            reconnectTask = nil
            backfillTask?.cancel()
            backfillTask = nil
            releaseGeometryOwnership()
        }

        /// RELEASE the phone's geometry lock (Fix A) so a co-viewing desktop reclaims its own
        /// width: on teardown, when the scene goes to the background, and when a hidden pane's
        /// grace runs out. While the pane is claimed we take ownership with `lock:true`
        /// through the geometry drain so the shared PTY — and therefore the agent's TUI — lays
        /// out at the phone's width and fits crisply; releasing fires ONE best-effort
        /// `lock:false` at the last known size to hand ownership back. Fire-and-forget: errors
        /// are ignored (the TTL is the backstop); it uses the last SENT size, or the desired
        /// size if nothing was confirmed yet. A pane that stays alive re-claims through
        /// `reclaimGeometry`. Returns the release's task when one was started, so a background
        /// release can keep the app awake until it is on the wire.
        ///
        /// ORDERING (review HIGH): the release must land strictly AFTER any in-flight
        /// `lock:true` resize. We do NOT cancel the resize drain — a cancelled task's
        /// already-dispatched request can still apply server-side, and if it lands
        /// AFTER our `lock:false` the pane stays locked (desktop pinned narrow). So we
        /// hand the drain off and AWAIT it first, so its last `lock:true` round-trip
        /// completes before we send the releasing `lock:false`. A live pane's handed-off drain
        /// stops on its own (it is gated on `claimsGeometry`), and a re-claim awaits this
        /// release — and so that drain — before it starts a new one.
        @discardableResult
        private func releaseGeometryOwnership() -> Task<Void, Never>? {
            // Hand a lease back EXACTLY ONCE, and only one this view took (see holdsClaim). A
            // second release with no claim between — stop() after a grace or background
            // release, or stop()'s .exited+dismantle double call — is a no-op: nothing can claim
            // while hidden, backgrounded or stopped, so there is nothing left to release, and
            // skipping it prevents both a redundant lock:false and the prune-clobber of a newer
            // chained release's registry handle. Checked before the hand-off, so a drain that
            // never sent keeps its own handle and simply winds down.
            guard holdsClaim else { return nil }
            holdsClaim = false
            let target = confirmedTarget ?? desiredTarget
            let inflight = resizeTask
            resizeTask = nil
            let keepalive = keepaliveTask
            keepaliveTask = nil
            // Leave any existing registry entry in place on this early bail (a pane that never
            // laid out): an older release may still be in flight, and its entry is the only handle
            // a future re-lock has to await it.
            // A view following the stream never held a lease, and must never send `set_pty_size`.
            guard !fitsStreamWidth, let target, target.cols >= 4, target.rows >= 2 else { return nil }
            let cols = target.cols
            let rows = target.rows
            let client = self.client
            let pane = self.paneID
            let myGen = self.myGeometryGeneration
            let viewerID = self.viewerID   // release THIS view's lease (#137), not the pane's
            // CHAIN releases: await the PREVIOUS entry first, so awaiting the newest release
            // transitively awaits every older one. Without this, overwriting the map here would
            // orphan an older ALREADY-committed lock:false (past its generation guard), and a later
            // re-lock — which awaits only the newest entry — could send lock:true before that older
            // lock:false lands, leaving the visible pane unlocked.
            let previous = Self.geometryReleaseTask[pane]
            let gate = self.resizeGate
            let release = Task.detached {
                await previous?.value        // an older release's lock:false must land BEFORE ours
                _ = await inflight?.value    // let the in-flight lock:true finish its round-trip
                await keepalive?.value
                // If a newer coordinator OR a re-claim took this pane while we awaited, it owns
                // the lock now — releasing would unlock a pane still on screen. Bail so its
                // lock:true stands. (And if this release DID commit before the re-claim bumped the
                // generation, `reclaimGeometry` AWAITS this task before it re-locks.)
                let current = await MainActor.run { Coordinator.geometryGeneration[pane] }
                guard current == myGen else { return }
                // Through the gate, deciding NOW: the in-flight lock:true awaited above may have
                // just been refused, and a refused host must not be asked again.
                _ = try? await gate.send {
                    try await client.setPTYSize(pane: pane, cols: cols, rows: rows, lock: false, viewerID: viewerID)
                }
                // Best-effort: drop our own registry entry once settled (no newer show/hide/attach
                // bumped the generation). This only runs once past the generation guard (sent, or
                // withheld by a closed gate); a release that bailed on that guard leaves the entry for the newer owner
                // (which is correct — clearing it there could clobber a live newer release). So the
                // map holds at most one entry per pane id, overwritten by the next release.
                await MainActor.run {
                    if Coordinator.geometryGeneration[pane] == myGen { Coordinator.geometryReleaseTask[pane] = nil }
                }
            }
            Self.geometryReleaseTask[pane] = release
            return release
        }

        /// Front↔background transition for a KEEP-MOUNTED pane. A HIDE KEEPS THE PTY WIDTH-LOCK
        /// for `hiddenClaimGraceNanos`, unrefreshed, then releases it; a show cancels a pending
        /// release and RE-ASSERTS the lock (`reclaimGeometry`), which is a no-op at the PTY
        /// whenever the lease was still held. Hiding used to release immediately, and that made
        /// every agent switch reflow the shared PTY twice and repaint the agent twice — see the
        /// type comment — so a quick switch away and back must stay inside the grace.
        func setForeground(_ f: Bool) {
            guard !stopped, f != foreground else { return }
            foreground = f
            if f {
                hiddenReleaseTask?.cancel()     // back inside the grace: keep the claim
                hiddenReleaseTask = nil
                Task { @MainActor [weak self] in
                    // Re-fronting a keep-mounted pane whose geometry changed while hidden can
                    // leave the scroller and the cursor reconciled against the wrong metrics.
                    // Committing the CURRENT stream-applied grid (a same-size commit: no core
                    // reflow) reconciles them and queues one safe repaint - unlike the old
                    // unconditional full repaint, it cannot paint a grid the stream has not
                    // applied yet.
                    guard let self, let view = self.view, self.foreground, !self.stopped else { return }
                    let terminal = view.getTerminal()
                    let grid = self.streamAppliedGeometry ?? (cols: terminal.cols, rows: terminal.rows)
                    view.applyTerminalSize(cols: grid.cols, rows: grid.rows)
                }
                // Enqueued after the repaint, as before: a proposal that repaint makes is tracked
                // under `relockPending` and the re-lock then drives toward it.
                if !sceneBackgrounded { reclaimGeometry() }
            } else {
                finishPresentation()
                prediction.reset()
                cancelArmedControl()
                relockPending = false           // a hide cancels any pending re-lock intent
                // Typing goes to the pane in front: release this one's input stream. Its next
                // key opens a fresh one.
                if let inputSender { MainActor.assumeIsolated { inputSender.closeStream() } }
                // NO RELEASE YET. A `lock:false` drops this device's width lease, and if it was
                // the last one the daemon stops forcing a size (`effective_pty_size` -> None) and
                // the local TUI reclaims its own layout width: a REAL winsize change, so the agent
                // takes a SIGWINCH and reflows its whole transcript, and re-fronting re-locks at
                // our grid and makes it reflow BACK. Two redraws for a glance at another agent.
                // So the lease is held, unrefreshed (`startHeartbeat` is foreground-gated), for
                // the grace, and only a pane left hidden past it hands the width back. A pane
                // in a backgrounded scene has released already.
                guard !sceneBackgrounded else { return }
                hiddenReleaseTask?.cancel()
                let grace = Self.hiddenClaimGraceNanos
                hiddenReleaseTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: grace)
                    guard !Task.isCancelled, let self, !self.stopped, !self.foreground else { return }
                    self.hiddenReleaseTask = nil
                    self.releaseGeometryOwnership()
                }
            }
        }

        /// The host's window scene went to (or came back from) the background. Going: every
        /// pane hands its claim back AT ONCE, hidden or not — iOS is about to suspend the app,
        /// after which nothing renews or releases, and another device viewing the agent would
        /// sit at this device's width until the TTL. A background-task assertion keeps the app
        /// running until the `lock:false` is on the wire. Coming back: the pane in front
        /// re-claims (a hidden one stays released until it is shown). On iOS the host remounts
        /// the front pane on return instead, and the fresh coordinator claims for itself.
        func setSceneBackgrounded(_ backgrounded: Bool) {
            guard !stopped, backgrounded != sceneBackgrounded else { return }
            sceneBackgrounded = backgrounded
            if backgrounded {
                hiddenReleaseTask?.cancel()
                hiddenReleaseTask = nil
                relockPending = false
                guard let release = releaseGeometryOwnership() else { return }
                let assertion = MainActor.assumeIsolated {
                    BackgroundAssertion(name: "herdr.release-terminal-size")
                }
                Task { @MainActor in
                    await release.value
                    assertion.end()
                }
            } else if foreground {
                reclaimGeometry()
            }
        }

        /// Re-take this pane's PTY width-lock (a show, or the scene coming back).
        ///
        /// The VISIBLE pane is never left unlocked, because the re-assert's `lock:true` is
        /// guaranteed to be the LAST geometry op even when a `lock:false` is still in flight for
        /// this pane: (1) bumping `geometryGeneration` makes a not-yet-sent `lock:false` bail on
        /// its generation guard; (2) `relockPending` makes EVERY geometry request (the re-assert
        /// itself AND any fitting proposal in the window) defer while we await that release, so
        /// no `lock:true` can race it; the deferred re-assert then drives toward the LIVE grid.
        /// Different panes own different PTYs + generation keys, so releases/retakes across
        /// panes never contend.
        private func reclaimGeometry() {
            let gen = (Self.geometryGeneration[paneID] ?? 0) + 1
            Self.geometryGeneration[paneID] = gen
            myGeometryGeneration = gen
            // DEFEAT the drain's dedup so the re-assert genuinely re-sends. A released (or
            // lapsed) lease leaves the confirmed target stale-but-EQUAL to the desired one, so
            // without clearing it here the dedup would skip the re-lock and leave the pane at
            // whatever width the TUI reclaimed. Re-asserting when the lease was still held is
            // free: it resolves to the same size and the daemon returns early on an unchanged
            // winsize, so it cannot cause the redraw the grace exists to avoid.
            confirmedTarget = nil
            relockPending = true                // defer requests until any release lands
            let pending = Self.geometryReleaseTask[paneID]
            Task { @MainActor [weak self] in
                await pending?.value            // let any committed lock:false land FIRST
                guard let self, self.claimsGeometry, !self.stopped,
                      self.myGeometryGeneration == gen else { return }   // a newer hide/show superseded us
                self.relockPending = false
                // Re-take lock:true at THIS pane's own local fit, now last. A hidden pane
                // kept proposing its fit into `desiredTarget` without sending it.
                self.startGeometryDrain()
            }
        }

        // MARK: styling (the design's machine voice)

        private func style(_ view: ReadOnlyTerminalView) {
            view.font = paneFont
            // groundMachine #0B0D1C behind, ink #EEF0F7 text, working-blue caret —
            // the same tokens `DesignSystem.Palette` uses, so the terminal is the
            // one darker ground the design calls for.
            view.nativeBackgroundColor = Self.color(0x0B0D1C)
            view.nativeForegroundColor = Self.color(0xEEF0F7)
            view.backgroundColor = Self.color(0x0B0D1C)
            view.caretColor = Self.color(0x5B9BE8)
            view.isOpaque = true
            // A 16-colour ANSI palette close to the design (status hues in the
            // matching slots). installColors is a no-op unless given exactly 16.
            view.installColors(Self.ansiPalette)
        }

        // MARK: streaming

        /// Fetch recent rendered history (incl. scrollback) as ANSI, bounded by a timeout so it
        /// can never stall the live seed. Runs concurrently with the stream; the first reset
        /// WITHOUT keyframe history awaits this at the single point where the bytes must land
        /// above the seed, and a reset that carries keyframe history cancels it.
        private func startBackfill() {
            // View-only (a guest) backfills too: the host lets a guest `agent.read` the granted
            // agent. An older host refuses with `guest_forbidden`; the read then yields nil
            // like any failure, and the stream's reset alone is the seed.
            let client = self.client, pane = self.paneID
            backfillTask = Task { () -> [UInt8]? in
                // Race the read against the timeout and take whichever finishes FIRST, ABANDONING
                // the loser. A transport need not honour Task cancellation on the read path (the
                // held request channel stops waiting; a per-request exec may not), so we must never
                // `await` a hung read — that would leave the first .reset (and every frame queued
                // behind it) suspended forever, a blank terminal. Instead a one-shot gate resumes
                // the continuation exactly once: whichever of the read / the timeout
                // (`backfillTimeoutNanos`) fires first wins; a hung read just leaks its background
                // task and we paint the seed with no history, exactly as before the feature.
                //
                // The read is an unstructured task, so cancelling THIS task (a keyframe that
                // carries history, or stop()) does not reach it by itself: the handler forwards
                // it. A transport that ignores cancellation still leaks the read until it ends.
                let gate = ResumeGate()
                let read = Task { () -> [UInt8]? in
                    let r = try? await client.read(pane: pane, source: .recent,
                                                   format: .ansi, lines: Self.backfillLines)
                    return (r?.text).flatMap { $0.isEmpty ? nil : [UInt8]($0.utf8) }
                }
                return await withTaskCancellationHandler {
                    await withCheckedContinuation { (cont: CheckedContinuation<[UInt8]?, Never>) in
                        Task {
                            let bytes = await read.value
                            if gate.claim() { cont.resume(returning: bytes) }
                        }
                        Task {
                            try? await Task.sleep(nanoseconds: Self.backfillTimeoutNanos)
                            if gate.claim() { read.cancel(); cont.resume(returning: nil) }
                        }
                    }
                } onCancel: {
                    read.cancel()
                }
            }
        }

        private func start() {
            discardPresentationReadiness()
            streamTask?.cancel()
            sawExited = false
            // Cleared with `sawExited`, and for the same reason: a refusal is permanent for
            // the pane it was about, not for this coordinator. `start()` is only ever reached
            // deliberately once `paneGone` is set — the reconnect task is gated on it — so
            // arriving here means a manual refresh or a different pane, and both deserve a
            // real attempt. Leaving it latched would turn one dead pane into a view that can
            // never show any pane again.
            paneGone = false
            lastStreamActivity = Date()
            streamRunID &+= 1
            let myRun = streamRunID
            // Typing-latency diagnostics: keys typed from here on belong to this machine
            // and the network the phone is on now (a later switch is followed by the monitor).
            if !viewOnly {
                TypingLatencyRecorder.shared.begin(host: TypingLatencyContext.shared.hostLabel,
                                                   network: TypingLatencyContext.shared.network)
            }
            startWatchdog()
            startHeartbeat()
            streamTask = Task { [weak self] in
                guard let self else { return }
                do {
                    // Same viewerID as this view's set_pty_size: the daemon ties the
                    // width-lease taken by the resize to THIS stream, dropping it on close.
                    // Every keyframe carries the history above its screen, so a reconnect
                    // or a lagged re-seed restores scrollback, not just the visible rows.
                    for try await event in self.client.streamTerminal(
                        pane: self.paneID, scrollbackLines: Int(Self.backfillLines), viewerID: self.viewerID) {
                        if Task.isCancelled { return }
                        await self.handle(event)
                    }
                    await self.streamEnded(nil, run: myRun)
                } catch {
                    await self.streamEnded(error, run: myRun)
                }
            }
        }

        /// Heartbeat watchdog. The server pings every 20s, so if nothing has arrived for
        /// `streamStuckTimeout` the stream is stuck / half-open (a `client.isConnected` TCP that
        /// silently died and will never throw). Force a reconnect. Re-armed by each `start()`,
        /// cancelled by `stop()`.
        private func startWatchdog() {
            watchdogTask?.cancel()
            watchdogTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)   // poll every 5s
                    guard let self, !self.stopped, !self.sawExited, !self.paneGone else { return }
                    if Date().timeIntervalSince(self.lastStreamActivity) > Self.streamStuckTimeout {
                        self.scheduleReconnect("no response for \(Int(Self.streamStuckTimeout))s")
                        return   // scheduleReconnect → start() re-arms a fresh watchdog
                    }
                }
            }
        }

        /// PTY width-lease keep-alive (#137). A stable-size foreground view fires no fresh
        /// `set_pty_size` proposal, so without this its lease would lapse at the short TTL we
        /// ask for (`TerminalSizeClaim.leaseTTLMillis`) and a co-viewing desktop would reclaim
        /// the width. Every `TerminalSizeClaim.renewalNanos` we RE-ASSERT the committed tuple
        /// as a keepalive: it is explicitly NOT a geometry change, so it does not clear
        /// committed state, bump the target generation, start a resize presentation or make
        /// the reader wait behind a retained frame. Only a view that CLAIMS geometry (in front,
        /// scene not backgrounded), non-relocking, idle-drain, with a committed size
        /// refreshes, and the claim half of that is LOAD-BEARING POLICY rather than
        /// bookkeeping: a hidden pane holds its lease unrefreshed for the grace and then
        /// releases it (see `setForeground`), and a backgrounded scene has released already.
        /// Do not relax this guard to cover hidden panes: that would pin the width for as long
        /// as the app is open. Skipping while a relock is pending or a drain is in flight
        /// preserves the "at most one set_pty_size in flight per pane" invariant.
        private func startHeartbeat() {
            heartbeatTask?.cancel()
            heartbeatTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: self?.heartbeatInterval ?? TerminalSizeClaim.renewalNanos)
                    guard let self, !self.stopped else { return }
                    // Nothing unsettled: no drain, no request in flight, no target waiting
                    // to be sent, and no resize on screen. A keepalive must never overtake
                    // or duplicate a real geometry change.
                    // A target that was never confirmed (its drain gave up, e.g. the resize raced
                    // the stream's open) is retried here rather than waiting for a relayout.
                    if !self.fitsStreamWidth, self.claimsGeometry, !self.relockPending, self.resizeTask == nil,
                       self.desiredTarget != nil, self.desiredTarget != self.confirmedTarget {
                        self.resizeRetries = 0
                        self.startGeometryDrain()
                        continue
                    }
                    guard !self.fitsStreamWidth, self.claimsGeometry, !self.relockPending, self.resizeTask == nil,
                          self.inflightTarget == nil, self.keepaliveTask == nil, !self.presentationActive,
                          let target = self.confirmedTarget, self.desiredTarget == target,
                          target.cols >= 4, target.rows >= 2 else { continue }
                    await self.reassertClaim(target)
                }
            }
        }

        /// Re-send the confirmed size as a lease keepalive. Shared by the heartbeat and by a
        /// reconnect: closing a stream drops its viewer's lease on the server, so the pane goes
        /// back to the other viewers' size until this view claims it again.
        private func reassertClaim(_ target: TerminalGeometryTarget) async {
            let task = Task { @MainActor [weak self] in
                guard let self, !self.stopped, !self.fitsStreamWidth, self.claimsGeometry else { return }
                // Set before sending: a send that times out may still have reached the
                // daemon, so the later release must go out. A send the gate refused
                // (nil) provably did not, so the previous state is restored.
                let held = self.holdsClaim
                self.holdsClaim = true
                do {
                    let sent = try await self.resizeGate.send {
                        try await self.client.setPTYSize(
                            pane: self.paneID, cols: target.cols, rows: target.rows,
                            cellWidthPx: target.cellWidthPx, cellHeightPx: target.cellHeightPx,
                            lock: true, viewerID: self.viewerID, ttl: self.leaseTTL)
                    }
                    if sent == nil { self.holdsClaim = held }
                } catch {
                    self.fallBackIfRefused()
                }
            }
            keepaliveTask = task
            await task.value
            keepaliveTask = nil
        }

        /// Auto-restart a dropped or stuck stream with capped exponential backoff, instead of
        /// leaving a dead terminal that needs a manual refresh. No-op after a deliberate `stop()`
        /// or a real process `exited`; at most one restart in flight.
        @MainActor
        private func scheduleReconnect(_ reason: String) {
            guard !stopped, !sawExited, !paneGone, reconnectTask == nil else { return }
            let delay = reconnectBackoff.next()
            if let view {
                let notice = "\r\n\u{1b}[2m\(reason); reconnecting…\u{1b}[0m\r\n"
                view.feed(byteArray: [UInt8](notice.utf8)[...])
            }
            reconnectTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                guard let self, !self.stopped, !self.sawExited else { return }
                self.reconnectTask = nil
                self.start()   // re-open the stream (cancels any lingering task, re-arms the watchdog)
            }
        }

        @MainActor
        private func handle(_ event: TerminalStreamEvent) async {
            guard let view else { return }
            let now = Date()
            lastStreamActivity = now   // any event (data, ping, resize) means the stream is alive
            // Mirror to the host, which uses it to decide whether returning to the front has
            // a real gap to repair. Only REAL frames count: `start()` optimistically stamps
            // lastStreamActivity before anything arrives, and treating that as evidence would
            // make a stream that connected and then received nothing look healthy.
            liveness?.noteFrame(at: now)
            switch event {
            case .started(let started):
                // Align the emulator to the pane's real geometry the ack carries.
                applyStreamGeometry(cols: started.cols, rows: started.rows, in: view)
                // A resize that raced this stream's open (a guest's needs the stream registered)
                // gave up unconfirmed; now that the stream exists, send it again.
                if resizeTask == nil, desiredTarget != nil, desiredTarget != confirmedTarget {
                    resizeRetries = 0
                    startGeometryDrain()
                } else if didSeedOnce, resizeTask == nil, inflightTarget == nil, keepaliveTask == nil,
                          !relockPending, let target = confirmedTarget, desiredTarget == target,
                          target.cols >= 4, target.rows >= 2 {
                    // A RECONNECT. The old stream's close dropped this viewer's lease, so the
                    // pane is back at the other viewers' size (often the desktop's). Claim it
                    // again now rather than at the next heartbeat, up to 25 s away, which is
                    // how long the terminal would otherwise be laid out for the wrong screen.
                    Task { @MainActor [weak self] in await self?.reassertClaim(target) }
                }
            case .frame(let frame):
                switch frame {
                case .reset(_, _, let cols, let rows, let data, let history, let resetCursor, _):
                    reconnectBackoff.reset()   // a full keyframe = the stream genuinely (re)established
                    graphicsFilter.reset()  // fresh screen: abandon any graphics string split before this keyframe
                    let firstReset = !didSeedOnce
                    if firstReset {
                        didSeedOnce = true
                        // Raise SwiftTerm's scrollback ring ONCE (its ~500 default) so it can hold the
                        // full backfill plus the live tail — BEFORE the resize below so a resize can't
                        // reclamp the ring while history is being fed. Whether the raise then survives
                        // the LAYOUT-driven terminal.resize() (SwiftTerm's Buffer.resize must not
                        // recompute maxLength down from options.scrollback) is an SPM-dependency
                        // internal not visible here; the swipe-up XCUITest, which resizes to the real
                        // sim grid, is the actual proof that history survives.
                        view.getTerminal().changeHistorySize(Self.scrollbackCap)
                    }
                    // Size the grid to the reset's geometry FIRST (was previously between clear+seed),
                    // so nothing later in THIS reset can truncate freshly-fed history.
                    applyStreamGeometry(cols: cols, rows: rows, in: view)
                    // A keyframe replaces the screen: whatever a pending resize was waiting
                    // to reveal describes a screen that no longer exists.
                    discardPresentationReadiness()
                    // Paging restarts from this keyframe: its cursor names the row above the
                    // history it carries, and nothing else here can be paged.
                    adoptHistoryCursor(history == nil ? nil : resetCursor)
                    if let history {
                        // The keyframe carries the scrollback above its screen, captured with it
                        // on the server. It REPLACES this emulator's history on every reset — the
                        // first one, a reconnect, a lagged re-seed — so output that scrolled off
                        // while the stream was down is never missing and nothing is doubled.
                        // The mount-time backfill read is then redundant: stop it.
                        backfillTask?.cancel()
                        backfillTask = nil
                        if !stopped {
                            // A pane that can page holds up to the paging cap from now on. Raised
                            // BEFORE any output can fill the smaller ring: a ring that trims its
                            // top while the cursor still names the row above it would page the
                            // next rows in above a gap. At the cap a trim means a full ring, and a
                            // full ring takes no page.
                            if historyCursor != nil {
                                view.getTerminal().changeHistorySize(Self.historyScrollbackCap)
                            }
                            seedKeyframeHistory(history, rows: rows, into: view)
                        }
                    } else if firstReset {
                        // An older server sends no history: fall back to the separate backfill.
                        // History ABOVE the seed: feed it now so its lines scroll into SwiftTerm's
                        // scrollback; the ESC[2J below then erases only the overlapping VISIBLE rows
                        // (recent's bottom ≈ the current screen) in place — scrollback untouched — and
                        // the seed repaints them, so nothing is duplicated. Bounded (raced) await;
                        // re-check teardown before feeding a possibly-dismantled view. The trailing
                        // ESC[0m resets any SGR the history left active, so ESC[2J's background-colour
                        // erase can't tint the rows the seed does not repaint.
                        let history = await backfillTask?.value ?? nil
                        if let history, !history.isEmpty, !stopped {
                            let cleanHistory = graphicsFilter.filter(history[...])   // backfill can carry graphics too
                            if !cleanHistory.isEmpty { view.feed(byteArray: cleanHistory[...]) }
                            view.feed(byteArray: [UInt8]("\u{1b}[0m".utf8)[...])
                        }
                    }
                    // Clear the VISIBLE screen + home (NOT scrollback — see clearSequence, Fix B),
                    // then paint the full-screen seed. `lagged` resets seed identically (the server
                    // already collapsed the backlog into this keyframe).
                    view.feed(byteArray: Self.clearSequence[...])
                    if !data.isEmpty { feedFiltered(data, into: view) }
                    prediction.reset()   // a keyframe replaced the screen the guesses stood on
                    noteStreamData()
                    publishTopRowProbe()
                case .data(_, _, let data):
                    noteStreamData()
                    // Typing-latency diagnostics: only the pane being typed into can echo.
                    if foreground, !data.isEmpty { TypingLatencyRecorder.shared.outputArrived() }
                    if !data.isEmpty { feedFiltered(data, into: view) }
                    // Instant typing checks its guesses against the screen this frame made.
                    if foreground, !data.isEmpty { prediction.outputArrived() }
                    publishTopRowProbe()   // a repaint (after a resize, say) moves the top row too
                case .resize(_, _, let cols, let rows):
                    applyStreamGeometry(cols: cols, rows: rows, in: view)
                case .ping:
                    break   // heartbeat only
                case .exited:
                    sawExited = true
                    // The pane is gone: the error notice must be reachable, never behind
                    // a retained frame.
                    finishPresentation()
                    view.feed(byteArray: Self.exitedNotice[...])
                    stop()
                }
            }
        }

        /// The user-facing notice for an error the server will keep giving, or nil when the
        /// failure is transient and the reconnect loop should run.
        ///
        /// Delegates the decision to `HerdrKit.permanentStreamRefusal` so the rule is unit
        /// tested away from the view. Kept as a thin seam here because `streamEnded` is
        /// `@MainActor` and view-bound.
        static func permanentRefusalNotice(_ error: Error?) -> String? {
            guard let apiError = error as? APIError else { return nil }
            return permanentStreamRefusal(code: apiError.code)
        }

        @MainActor
        private func streamEnded(_ error: Error?, run: Int) {
            // Only the CURRENT stream's end may reconnect. A superseded task (cancelled by a
            // watchdog/refresh restart, or replaced by a newer start()) ending here must be ignored,
            // or it double-reconnects and double-counts the backoff.
            guard run == streamRunID else { return }
            finishPresentation()
            // An `exited` frame already painted the terminal's final state (the process ended, so
            // reconnecting would only re-show that). A deliberate stop() (back out / teardown) or a
            // torn-down view must not reconnect either.
            if sawExited { return }
            guard !stopped, view != nil else { return }
            onStreamEnded?(error)
            // A PERMANENT server refusal is not a dropped connection. Reconnecting cannot
            // change the answer, so retrying only spins "reconnecting…" forever over a pane
            // that will never be served. Say so once and stop.
            if let notice = Self.permanentRefusalNotice(error) {
                paneGone = true
                if let view {
                    let line = "\r\n\u{1b}[2m\(notice)\u{1b}[0m\r\n"
                    view.feed(byteArray: [UInt8](line.utf8)[...])
                }
                return
            }
            // Otherwise the feed died while the process may still be live — auto-restart with backoff
            // rather than stranding a dead terminal behind a manual refresh.
            scheduleReconnect(error == nil ? "connection closed" : "connection lost")
        }

        // MARK: geometry

        /// Commits the server's authoritative grid to the emulator, in stream order,
        /// so the bytes that follow lay out at the size they were produced for.
        ///
        /// This is the ONLY place the emulator is resized. A local fit is never
        /// applied here (it is only proposed to the daemon), and the `set_pty_size`
        /// response is not applied either: it arrives on a different operation and is
        /// not an ordering barrier for the stream bytes before it.
        @MainActor
        private func applyStreamGeometry(cols: Int, rows: Int, in view: ReadOnlyTerminalView) {
            let newCols = max(4, cols)
            let newRows = max(2, rows)
            let terminal = view.getTerminal()
            let changed = newCols != terminal.cols || newRows != terminal.rows
            if changed, foreground, !presentationActive, !isOurGeometry(cols: newCols, rows: newRows) {
                // Somebody else (a co-viewer's lease, the agent's own request) changed
                // the grid. Same cover/reveal treatment, but no reciprocal request.
                beginResizePresentation(reason: .server)
            }
            // A same-size commit is deliberate and cheap: it reconciles the scroller and
            // the cursor with the current font metrics and queues one synchronization-aware
            // repaint, without a second core reflow.
            synchronizedBatchBegan = false
            presentationSyncEnded = false
            lastCompleteDraw = nil
            if changed {
                resizeCount += 1
                prediction.reset()
            }
            view.applyTerminalSize(cols: newCols, rows: newRows)
            // A live-anchored terminal now follows the container again, in the same
            // layout pass as this reflow.
            surface?.contentDidChange()
            streamAppliedGeometry = (cols: newCols, rows: newRows)
            fitFontToStreamWidth()   // following the stream: its cols fill the width
            publishGridProbe()
            streamGeometryRevision += 1
            if let response = responseGeometry, response == (cols: newCols, rows: newRows) {
                responseAwaitingMarker = false   // the request's marker has now landed
            }
            if presentationActive, presentationReason == .server, changed {
                armPresentationDeadline(after: Self.presentationDeadlineDuration)
            }
            evaluateGeometrySettled()
        }

        /// Whether this grid is one we asked for (so a cover is already up for it).
        ///
        /// OWNERSHIP EXPIRES WHEN ITS MARKER LANDS, and it must: review found that a
        /// local move A→B left `responseGeometry` at A while the stream sat at B, so a
        /// LATER unsolicited return to A still matched "response != applied" and was
        /// classified as ours — the server reflow B→A then ran with no cover at all.
        /// `responseAwaitingMarker` is cleared the moment the stream applies the grid
        /// the response promised, so only a genuinely pending request can claim it.
        private func isOurGeometry(cols: Int, rows: Int) -> Bool {
            if resizeTask != nil || inflightTarget != nil { return true }
            guard responseAwaitingMarker, responseGeneration == targetGeneration,
                  let response = responseGeometry else { return false }
            return response.cols == cols && response.rows == rows
        }

        /// Unmanaged/public view commits may still notify the delegate. Managed fits
        /// arrive through `sizeChangeRequestHandler`; authoritative stream commits
        /// are counted at their application site and never originate a new request.
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            // Counted for the UI-test probe only: a grid change clears any active
            // selection, so a resize landing AFTER a word select silently destroys it.
            // The count lets a test say "the selection was wiped" rather than "no
            // selection appeared", which are different bugs with different fixes.
            resizeCount += 1
        }

        /// Main-thread only (called from SwiftTerm's layout/font proposal). Records the
        /// grid this view wants and ensures the drain converges to it.
        ///
        /// The model is `desiredTarget` vs `confirmedTarget`: this records the newest
        /// target; a single serialized drain drives the server toward it and stops only
        /// when they are equal. Because at most ONE `set_pty_size` is ever in flight
        /// (the drain awaits each before the next), two resizes can never complete
        /// server-side out of order. Dedup is measured against the TARGET, not the
        /// confirmed size, so a request that matches the committed size while a
        /// different resize is in flight still supersedes it. `lock:true` PINS the
        /// shared PTY to the phone's fit; `releaseGeometryOwnership` hands ownership
        /// back with a `lock:false` on teardown.
        private func requestGeometry(cols: Int, rows: Int) {
            // Teardown began — no new lock:true (review HIGH). Following the stream never sizes the PTY.
            guard !stopped, !fitsStreamWidth else { return }
            #if DEBUG
            let (cols, rows) = MainActor.assumeIsolated {
                TerminalInteractionHarness.fit(paneID: paneID, cols: cols, rows: rows)
            }
            #endif
            guard cols >= 4, rows >= 2 else { return }
            // ONE PROPOSAL PER KEYBOARD SWEEP.
            //
            // The keyboard animates this pane's height over ~0.25s and the terminal is
            // the only flexible view in it, so EVERY animation frame proposed its own
            // row count: ~20 targets, each one restarting the settle window and
            // re-arming the reveal ceiling, which is why the retained frame was released
            // a second AFTER the keyboard had already finished. Only the fit the sweep
            // ENDS on was ever asked for; the rest are frames of an animation.
            //
            // The sweep's own end (`noteKeyboardSweepProposal`) commits that last fit
            // through this same path.
            if keyboardSweepActive {
                noteKeyboardSweepProposal(cols: cols, rows: rows)
                return
            }
            let cell = cellPixels()
            let priorChange = desiredTargetChangedAt
            let target = TerminalGeometryTarget(cols: cols, rows: rows,
                                                cellWidthPx: cell.width, cellHeightPx: cell.height)
            // A repeat of the target we are already driving toward (or sitting at with a
            // drain running) is noise from another layout pass.
            if target == desiredTarget, resizeTask != nil || target == confirmedTarget {
                return
            }
            desiredTarget = target
            desiredTargetChangedAt = ContinuousClock.now
            targetGeneration += 1
            #if DEBUG
            MainActor.assumeIsolated {
                TerminalInteractionHarness.noteCommittedFit(paneID: paneID, cols: cols, rows: rows)
            }
            #endif
            resizeRetries = 0        // a new target gets a fresh retry budget
            presentationGeometrySettled = false
            geometryEligibleAt = nil
            presentationSyncEnded = false
            synchronizedBatchBegan = false
            lastCompleteDraw = nil
            if presentationClosed, resizeTask == nil,
               priorChange.map({ ContinuousClock.now - $0 >= Self.resizeSettleDuration }) ?? true {
                presentationClosed = false
            }
            // The retained frame belongs to the burst, not to one proposal: an animated
            // sweep proposes many grids and covers once.
            beginResizePresentation(reason: .local)
            armPresentationDeadline(after: Self.resizeSettleDuration + Self.presentationDeadlineDuration)
            // A hidden or backgrounded pane (or one whose re-lock is still awaiting the in-flight
            // release, `relockPending`) TRACKS the latest grid above but does not start a drain:
            // it would re-pin a co-viewing desktop, and a `lock:true` sent during the release
            // window could race the `lock:false` and strand the visible pane unlocked.
            guard claimsGeometry, !relockPending else { return }
            startGeometryDrain()
        }

        /// A keyboard transition began. Holds its grid proposals until the animation
        /// stops moving; on iPhone the terminal stays live and anchored meanwhile.
        private func beginKeyboardSweep(duration: Double, coveredHeight: CGFloat?) {
            // A notification that leaves the keyboard's on-screen height unchanged cannot
            // resize this pane. It used to install the retained frame below anyway, and
            // with no grid change nothing ever settled it, so live output froze for the
            // whole ~1 s ceiling on every focus switch between terminal and composer.
            // Tracked before the foreground guard so a pane fronted later is not stale.
            let keyboardMoved = coveredHeight.map { abs($0 - keyboardCoveredHeight) >= 1 } ?? true
            if let coveredHeight { keyboardCoveredHeight = coveredHeight }
            guard !stopped, foreground else { return }
            keyboardSweepActive = true
            // On iPhone the software keyboard is full-width and a keyboard that moves
            // always changes the pane's safe-area height. Anchor NOW, before the first
            // animation frame lays the terminal out at the container's height (which
            // would show the top of the old grid, prompt cut off under the keyboard).
            // SwiftUI may also defer `layoutSubviews` until after this sweep's deadline,
            // which made a layout-only classification miss the sweep in CI35408586711.
            //
            // iPad stays layout-driven: floating/split keyboards can post the same
            // notification without resizing the pane, and must not freeze it.
            if keyboardMoved, Self.keyboardAnchorsLive {
                beginResizePresentation(reason: .keyboard)
            }
            keyboardSweepDeadlineTask?.cancel()
            let window = max(Duration.seconds(max(0, duration)), Self.keyboardSweepMinimumDuration)
            let backstop = window + Self.keyboardSweepGrace
            keyboardSweepDeadlineTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: backstop) } catch { return }
                // THE END IS THE LAYOUT STANDING STILL, not the clock. The reported
                // duration is when UIKit's animation ends, but the layout passes that
                // carry it run on this main thread: when it is late, the band is still
                // mid-sweep here, the sweep committed an intermediate fit and every
                // later frame committed its own PTY resize (measured with the app
                // stopped 200 ms in every 260 ms: sweep closed on 50x16, then 50x18 and
                // 50x26 were each sent). Past the backstop, the sweep waits until the
                // surface keeps one size across consecutive rendered frames, so it never
                // closes earlier than before. The presentation ceiling bounds the wait,
                // because a sweep that never settles must not hold its grid forever.
                let ceiling = ContinuousClock.now + Self.presentationDeadlineDuration
                var last = self?.surface?.bounds.size
                var stillFrames = 0
                while stillFrames < Self.keyboardSweepStillFrames, ContinuousClock.now < ceiling {
                    await DisplayFrame.next()
                    guard !Task.isCancelled, let self else { return }
                    let size = self.surface?.bounds.size
                    stillFrames = size == last ? stillFrames + 1 : 0
                    last = size
                }
                guard !Task.isCancelled else { return }
                self?.endKeyboardSweep()
            }
        }

        /// Resumes on the next rendered frame. One display link per wait, invalidated on
        /// its first tick; the link retains this object until then.
        @MainActor
        private final class DisplayFrame: NSObject {
            private var continuation: CheckedContinuation<Void, Never>?
            private var link: CADisplayLink?

            static func next() async {
                let frame = DisplayFrame()
                await withCheckedContinuation { continuation in
                    frame.continuation = continuation
                    let link = CADisplayLink(target: frame, selector: #selector(tick))
                    link.add(to: .main, forMode: .common)
                    frame.link = link
                }
            }

            @objc private func tick() {
                link?.invalidate()
                link = nil
                continuation?.resume()
                continuation = nil
            }
        }

        /// A fit proposed while the keyboard is moving. Kept, not sent: the sweep's end
        /// commits it.
        private func noteKeyboardSweepProposal(cols: Int, rows: Int) {
            deferredKeyboardTarget = (cols: cols, rows: rows)
        }

        /// Closes the sweep and commits its final fit — exactly one proposal for the
        /// whole animation. Idempotent: a second notification's task, `stop()` and this
        /// may all race, and only the first caller commits.
        private func endKeyboardSweep() {
            keyboardSweepDeadlineTask?.cancel()
            keyboardSweepDeadlineTask = nil
            guard keyboardSweepActive else { return }
            keyboardSweepActive = false
            guard let target = deferredKeyboardTarget else {
                // Nothing to commit (a keyboard that did not resize this pane, or a fit
                // identical to the one already driving). A reveal held off during the
                // sweep must still be reconsidered now, or the retained frame would sit
                // until its ceiling.
                evaluatePresentationReveal()
                return
            }
            deferredKeyboardTarget = nil
            requestGeometry(cols: target.cols, rows: target.rows)
            // ALWAYS re-evaluate, even though `requestGeometry` usually does: it returns
            // early when the fit matches the target already driving, and that early
            // return is exactly the case where a reveal deferred during the sweep has
            // nothing left to wake it.
            evaluatePresentationReveal()
        }

        /// The single serialized drain. At most one `set_pty_size` in flight, and a
        /// target must stand still for `resizeSettleDuration` before it is sent.
        private func startGeometryDrain() {
            guard !stopped, !fitsStreamWidth, claimsGeometry, !relockPending, resizeTask == nil else { return }
            guard let first = desiredTarget, first != confirmedTarget else { return }
            resizeTask = Task { @MainActor [weak self] in
                // A lease keepalive already on the wire finishes first, so the two never
                // overlap: the keepalive is not a geometry change and must not be treated
                // as one, but it still owns the single in-flight slot while it runs.
                await self?.keepaliveTask?.value
                while let self, !Task.isCancelled, !self.stopped, !self.fitsStreamWidth, self.claimsGeometry,
                      let target = self.desiredTarget, target != self.confirmedTarget {
                    // A TRUE quiet window, measured monotonically from the last change.
                    // Comparing two endpoint samples called a sweep that returned to an
                    // earlier width "still", and sent mid-gesture.
                    if let changedAt = self.desiredTargetChangedAt {
                        let quiet = ContinuousClock.now - changedAt
                        if quiet < Self.resizeSettleDuration {
                            try? await Task.sleep(for: Self.resizeSettleDuration - quiet)
                            continue   // re-read: a newer target may have arrived meanwhile
                        }
                    }
                    guard !Task.isCancelled, !self.stopped, !self.fitsStreamWidth, self.claimsGeometry,
                          self.desiredTarget == target else { continue }
                    self.inflightTarget = target
                    let generation = self.targetGeneration
                    // See the keepalive: optimistic, undone only when provably unsent.
                    let held = self.holdsClaim
                    self.holdsClaim = true
                    do {
                        guard let applied = try await self.resizeGate.send({
                            try await self.client.setPTYSize(
                                pane: self.paneID, cols: target.cols, rows: target.rows,
                                cellWidthPx: target.cellWidthPx, cellHeightPx: target.cellHeightPx,
                                lock: true, viewerID: self.viewerID, ttl: self.leaseTTL)
                        }) else {
                            self.inflightTarget = nil
                            self.holdsClaim = held
                            self.fallBackIfRefused()
                            break
                        }
                        self.inflightTarget = nil
                        self.confirmedTarget = target       // confirmed: OUR request is committed
                        self.responseGeometry = (cols: applied.cols, rows: applied.rows)
                        self.responseGeneration = generation
                        self.responseAwaitingMarker =
                            self.streamAppliedGeometry.map { $0 != (cols: applied.cols, rows: applied.rows) } ?? true
                        self.resizeRetries = 0
                        self.noteGeometryResponse()
                    } catch {
                        self.inflightTarget = nil
                        if Task.isCancelled { break }
                        // A host that refuses guest resizing will refuse every retry too.
                        if self.fallBackIfRefused() { break }
                        // Retry only while this is still the target; a newer one restarts
                        // the loop with its own budget.
                        if self.desiredTarget == target {
                            if self.resizeRetries >= 3 { break }
                            self.resizeRetries += 1
                            try? await Task.sleep(nanoseconds: 500_000_000)
                        }
                    }
                }
                // Clear our own handle on natural completion only. On cancellation
                // stop() already cleared it (and may have started a new drain), so do
                // not stomp that newer task.
                if !Task.isCancelled { self?.resizeTask = nil }
            }
        }

        /// Once the host has refused resizing for good (`PTYResizeGate` closed), this view stops
        /// proposing and fits the stream to its width instead. Idempotent; returns whether the
        /// gate is closed.
        @discardableResult
        private func fallBackIfRefused() -> Bool {
            guard resizeGate.isClosed else { return false }
            guard !fellBack else { return true }
            fellBack = true
            // The retained frame was waiting for a grid that will never be committed.
            finishPresentation()
            lastStreamWidthFit = nil
            fitFontToStreamWidth()
            onResizeRefused?()
            return true
        }

        /// The daemon answered a request of ours. This records the effective geometry
        /// and lease result; it is NOT an instruction to reflow — the same grid arrives
        /// in band, in order with the output it applies to.
        private func noteGeometryResponse() {
            if let response = responseGeometry, let applied = streamAppliedGeometry,
               applied == response, let view {
                // Already at this grid (a font-only change, or a size the stream had
                // reported before the answer): reconcile metrics, no marker needed.
                view.applyTerminalSize(cols: applied.cols, rows: applied.rows)
            }
            evaluateGeometrySettled()
        }

        // MARK: retained-frame presentation

        private func currentDrawToken() -> DrawToken? {
            guard let view else { return nil }
            return DrawToken(presentationGeneration: presentationGeneration,
                             targetGeneration: targetGeneration,
                             streamGeometryRevision: streamGeometryRevision,
                             cellSize: view.cellSize,
                             alternate: view.getTerminal().isCurrentBufferAlternate)
        }

        private func beginResizePresentation(reason: PresentationReason) {
            // Following the stream: a local presentation would never settle.
            guard !stopped, foreground, !fitsStreamWidth || reason == .server else { return }
            if presentationActive {
                // A keyboard sweep is still OUR relayout, so it keeps the burst local
                // for the settled test; only the server's own commit means .server.
                if reason != .server { presentationReason = .local }
                // A sweep that starts inside a burst (the previous keyboard's grid still
                // settling) must not show the terminal cut off at the container either.
                if reason == .keyboard, Self.keyboardAnchorsLive { surface?.beginLiveAnchor() }
                return
            }
            // A gesture closes the entire in-flight burst, including its late markers.
            // Only a later, stationary-to-moving transition can retain another frame.
            //
            // A KEYBOARD SWEEP IS EXEMPT, and that exemption is the point of the
            // `.keyboard` reason. Sending on iPhone drops the retained frame on purpose
            // (`userInputToken` → `userTookControl`): the reader's keystroke must not be
            // hidden behind a stale picture. But the SAME send dismisses the keyboard,
            // and the relayout that follows is ours, not stale output — leaving it
            // uncovered is what put the raw reflow on screen for a second. The capture
            // below is taken now, i.e. AFTER the input, so nothing stale is retained.
            if presentationClosed, reason != .keyboard {
                guard resizeTask == nil, inflightTarget == nil,
                      desiredTargetChangedAt.map({ ContinuousClock.now - $0 >= Self.resizeSettleDuration }) ?? true
                else { return }
            }
            // On iPhone a keyboard sweep is not covered at all: the terminal stays live,
            // anchored in the moving pane (`beginLiveAnchor`), so it needs no picture. The
            // same holds for the sweep's own commit when input already closed its burst.
            let anchorsLive = Self.keyboardAnchorsLive
                && (reason == .keyboard || surface?.isLiveAnchored == true)
            let hostInputFrame: UIView?
            if reason == .keyboard {
                hostInputFrame = anchorsLive ? nil : pendingHostInputFrame
                pendingHostInputFrame = nil
                pendingHostInputFrameTask?.cancel()
                pendingHostInputFrameTask = nil
            } else {
                hostInputFrame = nil
            }
            presentationGeneration += 1
            presentationActive = true
            prediction.reset()   // a retained frame may cover the terminal
            presentationClosed = false
            presentationReason = reason == .server ? .server : .local
            presentationStartedOnNormalBuffer = !(view?.getTerminal().isCurrentBufferAlternate ?? false)
            presentationGeometrySettled = false
            geometryEligibleAt = nil
            presentationSyncEnded = false
            synchronizedBatchBegan = false
            presentationDeadlineReached = false
            lastCompleteDraw = nil
            pendingSafeRepaint = false
            tailPublishHeld = true
            if anchorsLive {
                surface?.beginLiveAnchor()
            } else if let surface, let image = hostInputFrame
                ?? ((backingDrawComplete || reason == .keyboard)
                    ? surface.captureTerminalFrame() : nil) {
                surface.installCover(image)
            }
            armPresentationDeadline(after: Self.presentationDeadlineDuration)
        }

        private func armPresentationDeadline(after delay: Duration) {
            guard presentationActive else { return }
            presentationDeadlineTask?.cancel()
            presentationDeadlineReached = false
            let generation = presentationGeneration
            let target = targetGeneration
            presentationDeadlineTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, self.presentationActive,
                      self.presentationGeneration == generation, self.targetGeneration == target else { return }
                self.presentationDeadlineReached = true
                self.evaluatePresentationReveal()
            }
        }

        private func evaluateGeometrySettled() {
            guard presentationActive else { return }
            let settled: Bool
            if presentationReason == .server {
                settled = streamAppliedGeometry != nil
            } else if let response = responseGeometry, let applied = streamAppliedGeometry {
                settled = responseGeneration == targetGeneration && confirmedTarget == desiredTarget && response == applied
            } else {
                settled = false
            }
            if settled && !presentationGeometrySettled {
                geometryEligibleAt = ContinuousClock.now
            }
            presentationGeometrySettled = settled
            evaluatePresentationReveal()
        }

        private func noteStreamData() {
            lastStreamDataAt = ContinuousClock.now
            // A completed backing image is not proof of the bytes now being parsed.
            lastCompleteDraw = nil
            pendingSafeRepaint = false
            if presentationActive { scheduleQuietReveal() }
        }

        private func noteSynchronizedOutput(active: Bool) {
            if !active { prediction.synchronizedOutputEnded() }
            guard presentationActive else { return }
            if active {
                synchronizedBatchBegan = true
                presentationSyncEnded = false
                lastCompleteDraw = nil
            } else if synchronizedBatchBegan {
                presentationSyncEnded = true
            }
            evaluatePresentationReveal()
        }

        private func noteDisplayCompleted(complete: Bool) {
            backingDrawComplete = complete
            pendingSafeRepaint = false
            lastCompleteDraw = complete ? currentDrawToken() : nil
            evaluatePresentationReveal()
        }

        private func scheduleQuietReveal() {
            guard presentationActive else { return }
            presentationRevealTask?.cancel()
            let generation = presentationGeneration
            presentationRevealTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: Self.presentationQuietDuration) } catch { return }
                guard let self, self.presentationGeneration == generation else { return }
                self.presentationRevealTask = nil
                self.evaluatePresentationReveal()
            }
        }

        private func evaluatePresentationReveal() {
            guard presentationActive, !stopped, let view else { return }
            // NOT WHILE THE KEYBOARD IS STILL MOVING. The sweep deliberately leaves
            // `desiredTarget` alone, so "settled" is still being judged against the
            // PRE-sweep target: a late response for that target satisfies it mid-
            // animation and the frame this burst exists for would come off while the
            // band is still sweeping. Review caught it (f4); `endKeyboardSweep`
            // re-evaluates.
            // The ceiling is exempt. Holding the reveal is a courtesy to the animation;
            // the deadline is the promise that a retained frame always comes off. In run
            // 35351892191 the two met: the ceiling fired mid-sweep, this guard swallowed
            // its only evaluation, and the cover sat there — a frozen terminal, which is
            // worse than the reflow it was hiding.
            guard !keyboardSweepActive || presentationDeadlineReached else { return }
            guard presentationGeometrySettled || presentationDeadlineReached else { return }
            let terminal = view.getTerminal()
            guard !terminal.synchronizedOutputActive else { return }
            if !presentationDeadlineReached, presentationStartedOnNormalBuffer,
               terminal.isCurrentBufferAlternate { return }
            let eligibleAt = geometryEligibleAt ?? ContinuousClock.now
            let quietStart = max(lastStreamDataAt ?? eligibleAt, eligibleAt)
            let ready = presentationDeadlineReached || presentationSyncEnded
                || ContinuousClock.now - quietStart >= Self.presentationQuietDuration
            guard ready else { scheduleQuietReveal(); return }
            if presentationDeadlineReached {
                // HARD CEILING. A repaint request is not a ceiling: when the emulator's
                // logical grid already matches, `applyTerminalSize` may produce no draw
                // callback, so nothing finishes the presentation and the retained frame
                // becomes a permanently frozen terminal. CI35369227802 reproduced that
                // in both iPhone passes. At the deadline the safer failure mode is one
                // exposed reflow, never an unbounded freeze.
                finishPresentation()
            } else if let draw = lastCompleteDraw, draw == currentDrawToken() {
                finishPresentation()
            } else if !pendingSafeRepaint {
                // Reconcile and schedule through the library's synchronization gate.
                // Never force DEC 2026 to end.
                pendingSafeRepaint = true
                view.applyTerminalSize(cols: terminal.cols, rows: terminal.rows)
            }
        }

        /// `keepingAnchor`: a live-anchored terminal is not a stale picture, so input need
        /// not end it; it ends with the grid it was holding.
        private func finishPresentation(keepingAnchor: Bool = false) {
            presentationDeadlineTask?.cancel()
            presentationDeadlineTask = nil
            presentationRevealTask?.cancel()
            presentationRevealTask = nil
            let wasActive = presentationActive
            presentationActive = false
            presentationClosed = true
            tailPublishHeld = false
            surface?.removeCover()
            if !keepingAnchor { surface?.endLiveAnchor() }
            if wasActive, !stopped, let view {
                let maxOffset = max(0, view.contentSize.height - view.bounds.height)
                reportTailState(atTail: view.contentOffset.y >= maxOffset - 1)
            }
        }

        private func discardPresentationReadiness() {
            finishPresentation()
            presentationGeneration += 1
            backingDrawComplete = false
            lastCompleteDraw = nil
            lastStreamDataAt = nil
        }

        private func userTookControl() {
            // Unless nothing will replace the anchored grid: then it goes now.
            let gridPending = keyboardSweepActive || resizeTask != nil || inflightTarget != nil
            if presentationActive { finishPresentation(keepingAnchor: gridPending) }
        }

        // MARK: native one-shot Ctrl

        func applyControlModifier() {
            guard let view else { return }
            applyingControlModifier = true
            defer { applyingControlModifier = false }
            view.controlModifier = !stopped && foreground && directFocusIntended
                && view.isFirstResponder && (controlArmedGetter?() ?? false)
        }

        func cancelArmedControl() {
            if controlArmedGetter?() == true { controlArmedSetter?(false) }
            applyingControlModifier = true
            view?.controlModifier = false
            applyingControlModifier = false
        }

        /// UIKit can make SwiftTerm first responder before the simultaneous tap
        /// recognizer updates the SwiftUI focus binding. An actual native key event
        /// is explicit intent, unlike protocol replies emitted by SwiftTerm itself.
        private func adoptNativeInputFocus() {
            guard !stopped, !viewOnly, foreground, view?.isFirstResponder == true,
                  !directFocusIntended else { return }
            directFocusIntended = true
            onTerminalFocusRequest?()
        }

        private func prepareForInsertedText(_ text: String, composing: Bool) {
            adoptNativeInputFocus()
            userTookControl()
            guard !composing, text.unicodeScalars.count == 1, let character = text.first,
                  InputRouter.controlByte(for: character) != nil else {
                cancelArmedControl()
                return
            }
            applyControlModifier()
        }

        /// Cell size from the actual mono font — the DPI hint the server stores.
        private func cellPixels() -> (width: UInt32, height: UInt32) {
            if let view {
                let cell = view.cellSize
                return (UInt32(max(1, cell.width.rounded())), UInt32(max(1, cell.height.rounded())))
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: paneFont]
            let advance = ("W" as NSString).size(withAttributes: attrs).width
            let lineHeight = paneFont.lineHeight
            return (UInt32(max(1, advance.rounded())), UInt32(max(1, lineHeight.rounded())))
        }

        // MARK: TerminalViewDelegate — terminal input

        /// Forward SwiftTerm's key→bytes translation to the PTY when the terminal
        /// owns focus, on software and hardware keyboards alike. Serialized through
        /// `enqueueInput` so a fast key burst remains ordered.
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // Mounted background panes must not receive input even if they briefly
            // retain first responder while selection/focus transitions settle.
            guard !stopped, !viewOnly, foreground, directFocusIntended,
                  let v = view, v.isFirstResponder else { return }
            userTookControl()
            TypingLatencyRecorder.shared.keyPressed()
            let batch = enqueueInput(String(decoding: data, as: UTF8.self))
            // Instant typing: the same bytes, against the screen as it is before any echo.
            // Not under a retained resize frame, which is not the screen they act on.
            prediction.userBytes(Array(data), batch: batch, allowed: surface?.isCovered != true)
        }

        /// Ordered key input to the PTY (`PaneInputSender`): each batch goes out at once as a
        /// frame on the pane's `pane.input.stream` once that is open; until then, and for a
        /// federated pane, a mock transport or a daemon without the stream, keys keep the
        /// stop-and-wait `pane.send_text` drain that coalesces a fast burst. Made on the first
        /// key, so a view-only pane never builds one. Nonisolated like `emitScroll` (called on
        /// the main thread from the delegate callback).
        private var inputSender: PaneInputSender?
        /// Instant typing for this pane (see `PredictiveEchoController`).
        private let prediction = PredictiveEchoController()

        func setPredictionMode(_ mode: PredictionEngine.Mode) {
            prediction.setMode(mode)
        }

        /// Returns the batch number `PaneInputSender.enqueue` gave `s`, 0 when not sent.
        @discardableResult
        private func enqueueInput(_ s: String) -> UInt64 {
            guard !viewOnly, !stopped, !s.isEmpty else { return 0 }
            return MainActor.assumeIsolated {
                if inputSender == nil {
                    let client = self.client
                    let pane = self.paneID
                    let sender = PaneInputSender(
                        sendText: { text in try await client.sendText(pane: pane, text: text) },
                        openStream: { await client.openPaneInput(pane: pane) })
                    sender.onAcked = { [weak self] through, failed in
                        self?.prediction.batchAcked(through, failed: failed)
                    }
                    inputSender = sender
                }
                return inputSender?.enqueue(s) ?? 0
            }
        }

        /// SwiftTerm reports a 0...1 scroll position (`TerminalViewDelegate.scrolled`).
        /// A pane whose content fits the viewport can never be scrolled away from the
        /// tail, so treat it as parked; otherwise it is at the tail only at the bottom.
        ///
        /// THIS CALLBACK IS NOT ENOUGH ON ITS OWN, and relying on it shipped a broken Latest pill.
        /// On iOS the only route to `terminalDelegate?.scrolled` is
        /// `TerminalView.scrolled(source:yDisp:)` (iOSTerminalView.swift:1481), invoked solely from
        /// `Terminal.scroll()` — i.e. when OUTPUT scrolls the buffer. A FINGER scroll takes a
        /// different path entirely: `contentOffset.didSet` calls `syncYDispFromContentOffset()`,
        /// which calls `Terminal.setViewYDisp(row)`, which assigns `buffer.yDisp` and notifies
        /// NOBODY (Terminal.swift:5616-5619). So dragging back through scrollback on a quiet pane
        /// never reached this method, `reportTailState(atTail: false)` never ran, and the pill that
        /// exists to get the reader back to the live tail never appeared — in exactly the case a
        /// reader needs it. Found by review, not by the receipt, because no test asserted the pill.
        ///
        /// `observeContentOffset()` covers the finger path. Both funnel through `reportTailState`,
        /// which stays the single publisher, judges the alternate screen for both, and dedupes —
        /// so the two sources cannot double-publish and neither can disagree with the other about
        /// the alt buffer. The alt-screen guard that used to sit in this method has moved there;
        /// see the note on `reportTailState` for why the caller is the wrong place for it.
        ///
        /// WHY THE ALT SCREEN NEEDED JUDGING AT ALL: AppleTerminalView.scrollPosition
        /// short-circuits to 0 whenever the display buffer is the alternate one
        /// (st_apple.swift:2012), while Terminal.scroll() notifies the delegate unconditionally
        /// including on that buffer (Terminal.swift:5434). So on a Claude Code pane this callback
        /// saw position 0 on EVERY output frame, and whenever the emulator grid exceeded the
        /// laid-out view — the window before PTY-size negotiation settles, or a co-viewer
        /// reclaiming the size — canScroll was true and atTail latched FALSE. The pill pinned
        /// itself visible on a TUI pane where it cannot mean anything, and tapping it was undone
        /// by the next frame.
        func scrolled(source: TerminalView, position: Double) {
            guard let view else { return }
            let canScroll = view.contentSize.height > view.bounds.height + 1
            reportTailState(atTail: !canScroll || position >= 0.999)
        }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        /// Required on the pinned SwiftTerm (v1.11.2 has no default impl for it; a
        /// later version added one). No-op: the read-only terminal never copies.
        func clipboardCopy(source: TerminalView, content: Data) {}

        // MARK: finger-scroll tail state — the Latest pill's other half

        /// KVO on the terminal's own `contentOffset`, which is the ONLY signal a finger scroll
        /// produces that this layer can see (see `scrolled(source:position:)` for why the delegate
        /// callback never fires on that path).
        ///
        /// KVO AND NOT THE SCROLL DELEGATE, deliberately. `TerminalView` is a `UIScrollView` that
        /// declares `UIScrollViewDelegate` conformance and relies on being its own delegate;
        /// assigning `view.delegate = self` to get `scrollViewDidScroll` would take that over, and
        /// this repo has already paid for that once — the project notes record scrolling broken for
        /// roughly seven builds after claiming SwiftTerm's scroll delegate. Observation is additive
        /// and cannot displace anything.
        ///
        /// The tail test is the same arithmetic the delegate path uses, expressed in offsets
        /// instead of a 0...1 position, so the two agree at the boundary: a pane whose content fits
        /// cannot be scrolled away from the tail and is therefore always parked; otherwise it is at
        /// the tail within one cell of the bottom. One cell rather than one point because
        /// `contentOffset` lands on fractional values mid-deceleration, and a stricter bound made
        /// the pill flicker on and off during a flick.
        private func observeContentOffset(_ view: TerminalView) {
            offsetObservation = view.observe(\.contentOffset, options: [.new]) { scroll, _ in
                // Read the geometry SYNCHRONOUSLY, on whatever thread KVO fired on, then hop —
                // matching this file's existing convention (`Task { @MainActor [weak self] }`) so
                // Coordinator state is only ever touched on the main actor. Deliberately NOT
                // `MainActor.assumeIsolated`: Coordinator is a plain NSObject rather than an
                // actor-isolated type, and assumeIsolated TRAPS if the assumption is wrong, which
                // would turn a diagnostic nicety into a crash on whatever thread UIKit chose.
                let offsetY = scroll.contentOffset.y
                let maxOffset = scroll.contentSize.height - scroll.bounds.height
                // USER-DRIVEN MOTION ONLY, and read HERE, synchronously, while the scroll is
                // actually happening. This is the whole correction to the previous version.
                //
                // Review found that recording EVERY offset change breaks tap-to-focus on the common
                // case: SwiftTerm's auto-follow writes `contentOffset` on every output frame, so on
                // a busy pane the timestamp is permanently fresh and the guard suppressed every tap.
                // That is a worse defect than the one it was fixing — the reader could not focus the
                // terminal at all while an agent was producing output.
                //
                // `isDragging`/`isDecelerating` are exactly the discriminator, and the reason the
                // FIRST attempt failed was WHERE it read them, not WHAT it read: at tap `.ended`
                // they are already cleared, but inside this observer they are true for precisely the
                // offset writes a finger caused. Auto-follow writes arrive with both false and are
                // therefore not motion for this purpose.
                //
                // Reading them on the KVO thread alongside the geometry also keeps this immune to
                // the ordering question the touch-down approach would have raised: nothing here
                // depends on whether a gesture delegate runs before UIScrollView updates its state.
                let userDriven = scroll.isDragging || scroll.isDecelerating
                #if DEBUG
                // Step 0 of the Mac paging report: which flags a trackpad or wheel scroll sets.
                // Only near the top, so a busy pane's auto-follow cannot flood the log.
                if offsetY < scroll.bounds.height {
                    Self.historyLog.debug("offset \(Double(offsetY), privacy: .public) of \(Double(maxOffset), privacy: .public) tracking=\(scroll.isTracking) dragging=\(scroll.isDragging) decelerating=\(scroll.isDecelerating)")
                }
                #endif
                Task { @MainActor [weak self] in
                    guard let self, !self.stopped else { return }
                    // WHEN THE CONTENT LAST MOVED UNDER A FINGER, which is the signal the focus-tap
                    // guard uses. See `handleFocusTap` for why a timestamp rather than a live flag.
                    if userDriven { self.lastContentMotion = CACurrentMediaTime() }
                    self.publishTopRowProbe()
                    self.prediction.viewScrolled()   // guesses stand only on the live screen
                    // Geometry pages once armed, whatever moved the offset (a Mac wheel or
                    // trackpad sets neither flag); a finger always may. Seeding writes offset 0
                    // before it settles at the tail while disarmed, so it fetches nothing.
                    self.pageHistoryOnScroll(userDriven: userDriven)
                    // HALF a cell, matching SwiftTerm's own auto-follow threshold rather than a
                    // number I picked. syncYDispFromContentOffset re-engages auto-follow only within
                    // max(contentOffsetTolerance, cellDimension.height / 2) (iOSTerminalView.swift
                    // :1612-1613). A full cell of slack left a HALF-CELL BAND where this reported
                    // at-tail and hid the pill while userScrolling was still true — new output would
                    // not scroll into view and the one affordance for getting back was gone. On a
                    // busy pane the delegate path corrects it on the next line; on a quiet pane it
                    // persists, which is precisely the case the pill exists for. Reported by review,
                    // along with the fact that my comment claiming this used "the same arithmetic" as
                    // the delegate path was wrong: the delegate compares a 0...1 position, this
                    // compares offsets, and they agreed only approximately.
                    let slack = CGFloat(max(self.cellPixels().height, 2)) / 2
                    let canScroll = maxOffset > 1
                    self.reportTailState(atTail: !canScroll || offsetY >= maxOffset - slack)
                }
            }
        }

        // MARK: alt-screen scroll — drag to scroll the AGENT's own view

        /// Accumulated vertical drag since the last emitted scroll tick.
        private var scrollAccum: CGFloat = 0
        /// Running as "Designed for iPad" on a Mac, where scrolling is trackpad/wheel input.
        static let indirectScrollInput = ProcessInfo.processInfo.isiOSAppOnMac
        /// The alt-screen scroll pan recognizer, disabled on teardown so a drag can't
        /// send bytes to a pane that has exited/been replaced.
        private var scrollPan: UIPanGestureRecognizer?
        /// DEBUG-ONLY diagnostic element (see `publishSelectionProbe`, which is compiled out
        /// entirely in Release). Also nil in a DEBUG build that does not launch with
        /// `HERDR_SCREENSHOT_MOCK`, so it neither allocates nor reaches the accessibility layer
        /// outside a UI-test run. The property itself is left ungated because nothing assigns it
        /// outside that block; an unused optional costs a word and one `#if` less to get wrong.
        private var selectionProbe: UIView?
        /// DEBUG-only, like `selectionProbe`: the top visible row of a view-only pane (see
        /// `publishTopRowProbe`).
        private var topRowProbe: UIView?
        /// Monotonic publish counter for the probe, so a reading can be told apart from a stale one.
        /// How recently the terminal's content must have moved for a tap to be read as
        /// "stop scrolling" rather than "give me the keyboard". Covers the gap between the last
        /// `contentOffset` change and touch-up on a scroll-arresting tap, and nothing longer: a
        /// deliberate tap a beat after reading must not wait on this.
        static let scrollSettleWindow: CFTimeInterval = 0.35
        /// `CACurrentMediaTime()` of the last observed `contentOffset` change, written by the KVO
        /// observer in `observeContentOffset`. Starts at 0, which is unreachably far in the past
        /// against a monotonic uptime clock, so a freshly attached pane never suppresses its first
        /// tap — the failure a naive "recent by default" sentinel would cause.
        private var lastContentMotion: CFTimeInterval = 0
        private var probePublishCount = 0
        /// How many 2-tap recognizers `clearTap` was made to require the failure of, captured at
        /// attach. Published by the probe so a test can see whether that chain was wired as
        /// intended rather than inferring it from behaviour.
        private var clearTapRequirementCount = 0
        /// How many times SwiftTerm has reported a grid change. Published by the probe because
        /// `processSizeChange` clears the selection on any rows/cols change, so a resize
        /// arriving late is one of the candidate explanations for a selection that vanishes —
        /// and a count is how a test tells that apart from a selection never made.
        private var resizeCount = 0
        /// Serialized scroll-send queue: bytes waiting to go to the agent, drained one
        /// send at a time by `scrollSendTask` — so a fast drag coalesces into batched
        /// writes instead of a flood of concurrent, possibly-reordered SSH channels.
        private var pendingScroll = ""
        private var scrollSendTask: Task<Void, Never>?

        /// A drag on the terminal while a full-screen or MOUSE-REPORTING agent owns the
        /// view. Two cases we handle by sending scroll INPUT to the agent (SGR
        /// mouse-wheel when it reports mouse — Claude Code enables DECSET 1000/1006 —
        /// else Up/Down arrows):
        ///  • ALTERNATE screen (vim/htop-style TUIs): no SwiftTerm scrollback to scroll.
        ///  • MOUSE MODE on a normal buffer (Claude Code "fullscreen" captures the wheel
        ///    to scroll its OWN viewport): a native scrollback scroll would move the
        ///    wrong thing / nothing.
        /// A PLAIN shell (omp: normal buffer, mouse OFF) is left to SwiftTerm's native
        /// scrollback pan (fixed in 1.15.0) — we return early. This is the ONLY byte
        /// path this read-only view opens and it emits ONLY wheel/arrow sequences —
        /// never a keystroke — so the keyboard stays fully blocked.
        @objc private func handleScrollPan(_ gr: UIPanGestureRecognizer) {
            // Restore native scroll on gesture-end FIRST — before ANY early return,
            // including the teardown guard below. Two ways the state can change under an
            // active drag: (1) the agent flips buffer/mouse mode, and (2) the agent EXITS
            // — stop() runs from handle(.exited) while the pane STAYS on screen. Either
            // must not strand isScrollEnabled=false on a live, still-visible pane
            // (reviewer). `view?` keeps this safe during teardown; only undoes a flag a
            // .began below set (idempotent otherwise).
            if gr.state == .ended || gr.state == .cancelled || gr.state == .failed {
                view?.isScrollEnabled = true
            }
            // `foreground` is defence in depth for the same reason as the two-finger tap:
            // this path SENDS BYTES, and it should not rely on the keep-alive container
            // continuing to make backgrounded panes non-hit-testable. Placed AFTER the
            // isScrollEnabled restore above, so a pane backgrounded mid-drag still gets its
            // native scroll back rather than being stranded disabled.
            // Teardown, hidden, or view-only: send nothing (view-only never begins; see below).
            guard !stopped, !viewOnly, foreground, let view else { return }
            let term = view.getTerminal()
            // omp (normal buffer + mouse off) scrolls natively; everything else we drive.
            guard term.isCurrentBufferAlternate || term.mouseMode != .off else { return }
            switch gr.state {
            case .began:
                scrollAccum = 0
                // A mouse-mode program on a NORMAL buffer still has retained scrollback;
                // suppress the native scrollback pan for this drag so it can't
                // double-scroll against the wheel we send. Moot on the alt screen (no
                // scrollback); never reached for omp (returned above).
                if term.mouseMode != .off && !term.isCurrentBufferAlternate {
                    view.isScrollEnabled = false
                }
            case .changed:
                scrollAccum += gr.translation(in: view).y
                gr.setTranslation(.zero, in: view)
                let line = max(1, paneFont.lineHeight)
                let ticks = Int(scrollAccum / line)
                guard ticks != 0 else { return }
                // Pace the wheel: a MOUSE-MODE agent (Claude Code) accelerates its own
                // scroll from the GAP between wheel events, so several events slammed into
                // one send arrive ~simultaneously and trip its fast cap (~36 lines/tick) —
                // the jumpy leaps. Emit ONE tick per frame there so the gaps land in its
                // gentle ~3-line regime → smooth, finger-proportional (its own accel still
                // supplies fling speed). The ARROW-key fallback (rare non-mouse alt-screen)
                // doesn't accelerate, so keep up to 4/frame. CONSUME ONLY the ticks we
                // emit and CARRY the rest in scrollAccum, so a fast drag isn't truncated.
                let cap = term.mouseMode != .off ? 1 : 4
                let count = min(abs(ticks), cap)
                scrollAccum -= CGFloat((ticks > 0 ? 1 : -1) * count) * line
                // Bound the carry to ONE frame's worth: keeps the decelerating-drag
                // benefit but stops scrollAccum growing unbounded when demand outruns the
                // cap — otherwise a direction REVERSAL within one touch keeps firing the
                // old direction for many frames (scrolls backwards), and in mouse mode the
                // backlog × Claude Code's own acceleration would over-scroll (reviewer).
                let maxCarry = CGFloat(cap) * line
                scrollAccum = min(max(scrollAccum, -maxCarry), maxCarry)
                emitScroll(up: ticks > 0, count: count,
                           at: gr.location(in: view), term: term)
            case .ended where Self.indirectScrollInput:
                // A wheel notch or a short trackpad scroll is a whole gesture on the Mac and
                // can end short of one line of travel; round its remainder to one tick
                // rather than dropping it, so every notch scrolls. Touch keeps its threshold.
                scrollAccum += gr.translation(in: view).y
                let line = max(1, paneFont.lineHeight)
                if abs(scrollAccum) >= line / 2 {
                    emitScroll(up: scrollAccum > 0, count: 1, at: gr.location(in: view), term: term)
                }
                scrollAccum = 0
            default:
                break
            }
        }

        /// Emit `count` scroll ticks toward the agent. Drag DOWN (`up == true`)
        /// reveals OLDER content → wheel-up (button 64); drag UP → wheel-down (65).
        /// SGR mouse-wheel is pure ASCII, safe through the String `send_text` path;
        /// with no mouse reporting, fall back to arrow keys (best-effort).
        private func emitScroll(up: Bool, count: Int, at point: CGPoint, term: SwiftTerm.Terminal) {
            guard !viewOnly, count > 0 else { return }
            prediction.reset()   // these bytes bypass the key path
            let seq: String
            if term.mouseMode != .off {
                // NOTE: SwiftTerm 1.11.2 keeps the mouse ENCODING (mouseProtocol)
                // private, so we can't read whether the app negotiated SGR (DECSET
                // 1006) vs legacy X10. We emit SGR — what Claude Code and effectively
                // every modern mouse-reporting TUI uses (X10's 223-cell limit is why
                // apps opt into 1006). An X10-only-mouse app (rare, legacy) would not
                // understand these; a documented limit of the private protocol, not a
                // runtime bug.
                let code = up ? 64 : 65
                let cw = ("W" as NSString).size(withAttributes: [.font: paneFont]).width
                let ch = paneFont.lineHeight
                let col = max(1, min(Int(point.x / max(1, cw)) + 1, max(1, term.cols)))
                let row = max(1, min(Int(point.y / max(1, ch)) + 1, max(1, term.rows)))
                seq = String(repeating: "\u{1b}[<\(code);\(col);\(row)M", count: count)
            } else {
                seq = String(repeating: up ? "\u{1b}[A" : "\u{1b}[B", count: count)
            }
            // Serialize: queue the bytes and drain ONE send at a time (coalescing all
            // pending into each batch), so a fast drag can't spawn a flood of
            // concurrent SSH channels that deliver direction changes out of order.
            // Bound the queue: if the sole send stalls under a long drag, don't
            // accumulate an unbounded burst — it could exceed CitadelTransport's
            // ~120KB argument limit (dropped) or replay a huge stale scroll when the
            // link resumes. ~4KB is far more scroll than any real drag needs; past
            // that we drop further ticks (a stalled link can't scroll smoothly anyway).
            guard pendingScroll.utf8.count + seq.utf8.count <= 4096 else { return }
            pendingScroll += seq
            guard scrollSendTask == nil else { return }   // a drain is running; it will pick this up
            scrollSendTask = Task { @MainActor [weak self] in
                while let self, !self.stopped, !self.pendingScroll.isEmpty {
                    let batch = self.pendingScroll
                    self.pendingScroll = ""
                    _ = try? await self.client.sendText(pane: self.paneID, text: batch)
                }
                self?.scrollSendTask = nil
            }
        }

        /// Coexist with the TerminalView's own scroll-view pan: on the alt screen the
        /// native pan has no range, so recognizing both simultaneously is harmless and
        /// lets our handler drive the agent scroll.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        /// The agent-scroll pan must not BEGIN when it has nothing to do, or when it
        /// would fight a selection. On a plain shell pane `handleScrollPan` returns early
        /// anyway; while a selection is active the drag belongs to SwiftTerm's lazily
        /// installed drag-to-extend pan, which has no delegate of its own and so cannot
        /// defend itself. Only this recognizer is gated, so the taps always begin.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard g === scrollPan else { return true }
            // View-only: no agent scroll; the native pan scrolls local scrollback.
            guard !viewOnly else { return false }
            guard let view, !view.hasActiveSelection else { return false }
            let term = view.getTerminal()
            return term.isCurrentBufferAlternate || term.mouseMode != .off
        }

        // MARK: palette helpers

        /// Clear the VISIBLE screen + cursor home, fed before a reset seed. NOTE we
        /// deliberately do NOT feed `ESC[3J` (clear SCROLLBACK) here (Fix B): wiping
        /// scrollback on every reset is what left the normal-buffer (shell) history
        /// un-scrollable — "it looks stuck". Dropping it lets that history accumulate
        /// in SwiftTerm so a drag-up actually reveals earlier output. (Alt-screen TUIs
        /// keep no scrollback of their own regardless; scrolling THOSE is handled by
        /// `handleScrollPan`, which sends wheel/arrow scroll INTO the agent.)
        private static let clearSequence = [UInt8]("\u{1b}[2J\u{1b}[H".utf8)
        /// Clear scrollback AND screen and home: the emulator's history is about to be
        /// replaced wholesale by a keyframe's (`seedKeyframeHistory`).
        private static let historyResetSequence = [UInt8]("\u{1b}[0m\u{1b}[3J\u{1b}[2J\u{1b}[H".utf8)
        /// The dim terminated marker shown when the process exits.
        private static let exitedNotice = [UInt8]("\r\n\u{1b}[2mprocess exited\u{1b}[0m\r\n".utf8)

        private static func color(_ hex: UInt32) -> UIColor {
            UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
        }

        /// A SwiftTerm palette entry from 8-bit hex (SwiftTerm uses 16-bit channels;
        /// 0xFF -> 0xFFFF via *257).
        private static func ansi(_ hex: UInt32) -> SwiftTerm.Color {
            SwiftTerm.Color(
                red: UInt16((hex >> 16) & 0xFF) * 257,
                green: UInt16((hex >> 8) & 0xFF) * 257,
                blue: UInt16(hex & 0xFF) * 257)
        }

        /// 16 ANSI colours (normal 0–7, bright 8–15). Status hues match the design:
        /// red = died, green = done, yellow = waiting, blue = working.
        static let ansiPalette: [SwiftTerm.Color] = [
            ansi(0x1A1D2E), ansi(0xE2584E), ansi(0x5FB37F), ansi(0xE9A63C),
            ansi(0x5B9BE8), ansi(0xB58BF0), ansi(0x4FB8C8), ansi(0xC7CBD9),
            ansi(0x3A3F5C), ansi(0xF07A70), ansi(0x7FC89A), ansi(0xF2BE63),
            ansi(0x82B6F0), ansi(0xC9A9F5), ansi(0x74CEDC), ansi(0xEEF0F7),
        ]
    }
}

/// One background-task assertion, ended exactly once: by the work it covers finishing, or by
/// iOS running out of background time, whichever comes first.
@MainActor
final class BackgroundAssertion {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.end() }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif
