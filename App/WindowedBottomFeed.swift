import SwiftUI
import UIKit

/// The Gram feed's scrolling, shared by the inbox and Saved: an EAGER, windowed stack read
/// oldest at the top and newest at the bottom, that opens at the newest message (or at a row
/// the owner names, just below the floating header: the inbox's first unread message),
/// reveals or fetches older history when the reader reaches the top, and keeps the reader's
/// place when it lands above them.
///
/// EAGER, NOT LAZY, AND WINDOWED. A LazyVStack here never settled while the composer's pull-up
/// editor shrank the feed: main thread at 100% in layout, the composer UI test hung on CI's
/// iPhone (also with no other change) and 2/2 locally; with this stack it passes on CI and 3/3
/// locally in 18 s. An eager stack draws every row it is given, so the owner gives it only its
/// newest window (`items`, see `GramView.renderWindow`); the top sentinel asks for more.
///
/// The OWNER keeps the state (`visibility`, `appearance`, `landed`, `anchorID`) and the
/// window, because the inbox resets them from the page while this feed is swapped out for
/// "No matches". Hooks read the owner's state when they run, not when the feed was drawn.
struct WindowedBottomFeed<Item: Identifiable, Row: View, Sentinel: View, Footer: View>: View
where Item.ID == String {
    /// The owner's `ScrollViewReader`, so the owner's own modifiers (follow a new message, the
    /// "New messages" button) scroll the same feed.
    let feed: ScrollViewProxy
    /// The drawn window, oldest at the top.
    let items: [Item]
    let spacing: CGFloat
    /// Whether there is anything older than the window: draws the sentinel at the top.
    let showsSentinel: Bool
    /// The bottom marker's id: what every scroll to the newest message targets.
    let bottomID: String
    /// The scroll view's accessibility identifier.
    let feedID: String
    /// The stack's accessibility identifier and value (how many messages it holds).
    let messagesID: String
    let messagesValue: String
    let column: FeedColumn
    /// The floating header's bottom edge (`GramView.headerBottom`, 0 until measured): rows
    /// under it are not on screen, and an anchored row may land at it.
    let visibleTop: CGFloat
    /// The filter in force: a change of it scrolls to the newest match.
    let search: String
    let visibility: FeedVisibility
    /// Bumped each time the feed comes on screen. On iPhone Gram is a persistent tab: leaving
    /// it fires every tracker's `onDisappear` (clearing what is on screen), but coming back
    /// lays the feed out exactly as before, and `onGeometryChange` reports only CHANGES, so
    /// without this nothing would say the bottom or the rows are on screen again until the
    /// reader scrolled. See `onFeedPlacementChange` and the bottom/sentinel trackers.
    @Binding var appearance: Int
    /// True once the feed has been scrolled to where it opens (the newest message, or the
    /// `openAt` row) for this appearance. The
    /// first layout starts at the TOP, before the scroll runs, so until then rows appearing
    /// are not being read and the top sentinel is not a request for older messages.
    @Binding var landed: Bool
    /// The previously-top message after older rows landed above it; the feed scrolls back
    /// to it so the reader keeps their place. Set by the owner, cleared here.
    @Binding var anchorID: String?
    /// The owner's tab-bar re-tap (`HomeTab.gram` tapped while selected), bumped to go to the
    /// newest message; nil for a feed that is not a tab's own. Non-nil also takes the feed out
    /// of the SYSTEM's scroll-to-top (`ScrollsToTopOff`), which the re-tap runs too and which
    /// in this oldest-first feed goes to the OLDEST message.
    var newestRequest: Int? = nil
    /// Runs as the feed opens, before the initial scroll is issued. Awaited, so the owner can
    /// fetch what the opening row needs first (the inbox's older unread messages); rows that
    /// appear meanwhile are not read, since the feed has not landed.
    var onOpen: () async -> Void = {}
    /// The row to open at instead of the newest message, read after `onOpen`: it goes to the
    /// top of the visible feed, just below the floating header. nil opens at the newest.
    /// The inbox names its first unread message here, the row the "N unread" rule sits on.
    /// A hook, like the others, so the initial scroll reads what `onOpen` just captured.
    var openAt: () -> String? = { nil }
    /// The feed has landed where it opens (see `finishInitialScroll`).
    var onLanded: () -> Void
    /// A row came on screen after the feed landed.
    var onRowSeen: (Item) -> Void = { _ in }
    /// The sentinel arrived on screen (or the anchor settled with it still in view): the
    /// owner reveals or fetches one older window, if armed.
    var onSentinelArrival: () -> Void
    /// The bottom marker came on screen.
    var onBottomReached: () -> Void = {}
    /// The feed went off screen.
    var onLeave: () -> Void = {}
    /// Whether a shrinking viewport keeps a reader at the bottom there (see the bottom marker).
    var followsShrink: () -> Bool = { false }
    /// Whether the sentinel may fetch as soon as the feed comes back on screen.
    var armedOnReturn: () -> Bool = { true }
    /// Whether a sentinel still in view once the anchor settled is an arrival at the top.
    var chainsAfterAnchor: () -> Bool = { true }
    @ViewBuilder var sentinel: () -> Sentinel
    @ViewBuilder var row: (Int, Item) -> Row
    @ViewBuilder var footer: () -> Footer

    /// How long a shrinking feed must stay still before the reader is kept at the bottom:
    /// longer than one frame, short enough to read as part of the keyboard/editor motion.
    private static var shrinkJumpSettleNanos: UInt64 { 150_000_000 }
    /// The id of the open row's header-clear scroll target (see the initial scroll).
    private static var openMarkerID: String { "feed-open-marker" }

    var body: some View {
        let opening = openAt()
        return ScrollView {
            VStack(spacing: spacing) {
                // The sentinel, at the TOP: the feed is oldest-first and opens at the bottom, so
                // it comes on screen only when the reader scrolls up past the oldest drawn
                // message, which is exactly when the next window is worth asking for.
                if showsSentinel {
                    sentinel()
                        // Asks when the sentinel ARRIVES on screen after the initial scroll:
                        // the first layout starts at the top and builds it although the reader
                        // never saw it. One arrival, one page: the request disarms it, and only
                        // scrolling it away again (or the anchor-restore check) re-arms it, so a
                        // page landing while it is still in view cannot chain into the next.
                        // The tracker is a background view re-identified on every appearance:
                        // a NEW view reports its geometry at once, so coming back to the tab
                        // re-reports the sentinel even though nothing moved.
                        .background {
                            Color.clear
                                .onFeedVisibilityChange { onScreen in
                                    visibility.sentinelOnScreen = onScreen
                                    if onScreen {
                                        onSentinelArrival()
                                    } else if !visibility.anchoring, !visibility.pageRequested {
                                        visibility.pageArmed = true
                                    }
                                }
                                .id(appearance)
                        }
                        .onDisappear {
                            visibility.sentinelOnScreen = false
                            if !visibility.anchoring, !visibility.pageRequested {
                                visibility.pageArmed = true
                            }
                        }
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    row(index, item)
                        // On screen, not merely built: every drawn row exists, on screen or not,
                        // and before the initial scroll the first layout sits at the top, which
                        // the reader never sees (`finishInitialScroll` hands the owner what is
                        // on screen once the feed has landed where it opens).
                        // `appearance` is part of the reported value, so a row still on screen
                        // when the tab comes back reports again (rows are not re-identified:
                        // that would rebuild every bubble).
                        .onFeedPlacementChange(appearance: appearance,
                                               visibleTop: visibleTop > 0 ? visibleTop : nil) { placement in
                            if placement.onScreen {
                                visibility.rows.insert(item.id)
                                if landed { onRowSeen(item) }
                            } else {
                                visibility.rows.remove(item.id)
                            }
                            if placement.atTop {
                                visibility.rowsAtTop.insert(item.id)
                            } else {
                                visibility.rowsAtTop.remove(item.id)
                            }
                            if placement.atVisibleTop {
                                visibility.rowsAtVisibleTop.insert(item.id)
                            } else {
                                visibility.rowsAtVisibleTop.remove(item.id)
                            }
                        }
                        .onDisappear {
                            visibility.rows.remove(item.id)
                            visibility.rowsAtTop.remove(item.id)
                            visibility.rowsAtVisibleTop.remove(item.id)
                        }
                        // The open row's second scroll target: a point the header's height
                        // above its top, for a scroll view whose `.top` anchor ignores the
                        // header's content margin (see the initial scroll).
                        .background(alignment: .top) {
                            if item.id == opening {
                                Color.clear.frame(width: 1, height: 1)
                                    .alignmentGuide(.top) { _ in max(0, visibleTop) }
                                    .id(Self.openMarkerID)
                            }
                        }
                }
                footer()
                Color.clear.frame(height: 1).id(bottomID)
                    // The reader is at the bottom while this marker is on screen (within a
                    // few points): new messages are followed in only then. Tracked by a
                    // background view re-identified on every appearance, like the sentinel,
                    // so returning to the tab says "at the bottom" again (and finishes the
                    // initial scroll) without the reader having to scroll.
                    .background {
                        Color.clear
                            .onFeedBottomChange(slack: 24) { bottom in
                                let wasAtBottom = visibility.atBottom
                                let previousHeight = visibility.viewportHeight
                                // A marker leaving the hierarchy reports no scroll view (height
                                // 0): that is not a resize, and must not count as one later.
                                if bottom.viewportHeight > 0 {
                                    visibility.viewportHeight = bottom.viewportHeight
                                }
                                // The feed's VISIBLE HEIGHT got smaller under a reader at the
                                // bottom because the keyboard came up: the scroll view keeps its
                                // top offset, so the newest rows slid under the composer. Keep
                                // the reader at the bottom, as Messages does. Only a real
                                // viewport decrease counts (an older page or a filter leaves the
                                // height alone), one jump after the resize settles.
                                // Not while the composer has grown (wrapped text, the pull-up
                                // editor): a scroll to the bottom while the editor opened locked
                                // the feed's layout on iPhone (main thread busy, UI test hung),
                                // and the tall editor is for writing, not for following.
                                let shrank = previousHeight > 0 && bottom.viewportHeight > 0
                                    && bottom.viewportHeight < previousHeight - 0.5
                                if shrank, wasAtBottom, landed, !visibility.anchoring,
                                   followsShrink() {
                                    visibility.atBottom = true
                                    visibility.shrinkJump?.cancel()
                                    visibility.shrinkJump = Task { @MainActor in
                                        try? await Task.sleep(nanoseconds: Self.shrinkJumpSettleNanos)
                                        guard !Task.isCancelled, followsShrink() else { return }
                                        feed.scrollTo(bottomID, anchor: .bottom)
                                    }
                                    return
                                }
                                visibility.atBottom = bottom.onScreen
                                guard bottom.onScreen else { return }
                                onBottomReached()
                                finishInitialScroll()
                            }
                            .id(appearance)
                    }
                    // Not the pending shrink jump: the feed's own onDisappear cancels it
                    // (this marker leaves only with the feed, but a jump scheduled just
                    // before must still run while the feed stays).
                    .onDisappear { visibility.atBottom = false }
            }
            .padding(16)
            // How many messages the feed holds, so VoiceOver can say how long the list is
            // and a UI test can count the pages loaded. On the stack as a containing
            // element, not on the ScrollView: the ScrollView's own value read back as a
            // number that matched no list the page held.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(messagesID)
            .accessibilityValue(messagesValue)
            // A conversation column, centred, so a bubble never stretches across the whole
            // detail pane on iPad / Mac.
            .feedColumn(column)
            .background { if newestRequest != nil { ScrollsToTopOff() } }
        }
        .accessibilityIdentifier(feedID)
        // A re-tap of the selected tab: to the newest message, as opening does (the same
        // bounded jump, since rows above may still be settling their heights).
        .onChange(of: newestRequest) { _, _ in
            Task { @MainActor in
                for _ in 0..<8 {
                    feed.scrollTo(bottomID, anchor: .bottom)
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    if visibility.atBottom { break }
                }
            }
        }
        // Before the `.task` below, so the scroll loop already sees fresh reports.
        .onAppear { appearance += 1 }
        // Oldest at the top, newest at the bottom: open at the newest, or at the owner's
        // `openAt` row. NOT
        // `.defaultScrollAnchor(.bottom)`: with it, growing the composer (which shrinks the
        // feed) re-anchored the feed every frame, a redraw loop that pinned the CPU and
        // hung the composer's UI test.
        .task {
            await onOpen()
            // Left while the owner was fetching: the next appearance opens afresh.
            guard !Task.isCancelled else { return }
            visibility.initialScrollIssued = true
            // A named row (the first unread message): its top to the top of the visible feed.
            // Below the header, not under it: a row whose top meets the scroll view's own top
            // sits behind the header's controls, so only the header's bottom edge counts as
            // landed here (`atVisibleTop`). The row itself first; if that puts it under the
            // header (the `.top` anchor did not count the header's content margin), the marker
            // the header's height above it. Bounded and repeated, as for the newest below,
            // since rows above may still be settling their heights. A row whose remaining
            // feed is shorter than the screen cannot rise that far: on screen with the bottom
            // marker, it has landed too.
            if let target = openAt() {
                var scrollTarget = target
                for _ in 0..<10 {
                    feed.scrollTo(scrollTarget, anchor: .top)
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    if visibility.rowsAtVisibleTop.contains(target)
                        || (visibility.rows.contains(target) && visibility.atBottom) { break }
                    if visibility.rowsAtTop.contains(target) { scrollTarget = Self.openMarkerID }
                }
                finishInitialScroll()
                return
            }
            // The first jump can land short of the bottom while rows (images, folded
            // text) still settle their heights (on iPhone it opened mid-history). Jump again after each
            // layout pass until the bottom marker is really on screen; bounded so a feed
            // that cannot reach it never spins.
            for _ in 0..<8 {
                feed.scrollTo(bottomID, anchor: .bottom)
                try? await Task.sleep(nanoseconds: 60_000_000)
                if visibility.atBottom { break }
            }
            if visibility.atBottom { finishInitialScroll() }
        }
        // A change of the search text is a deliberate change of view: once the filtered rows
        // are laid out, show the newest match at the bottom (clearing the search returns to
        // the newest message). Keyed on the text, so each change scrolls once and a newer
        // keystroke cancels the older one's scroll; the feed's first appearance only records
        // the text (the `.task` above opens it at the bottom).
        .task(id: search) {
            guard let shown = visibility.shownSearch else {
                visibility.shownSearch = search
                return
            }
            guard shown != search else { return }
            visibility.shownSearch = search
            // (The window itself is reset by its owner's onChange(of: search), which for the
            // inbox also runs while the feed is swapped for "No matches".)
            // Same bounded settle loop as the initial scroll: estimated row heights can make
            // one jump land short.
            for _ in 0..<8 {
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard !Task.isCancelled else { return }
                feed.scrollTo(bottomID, anchor: .bottom)
                try? await Task.sleep(nanoseconds: 60_000_000)
                if visibility.atBottom { break }
            }
            // The results are on screen at the newest match. A sentinel off screen now
            // arrives only when the reader scrolls up to it, so it may search older pages
            // then; one already in view (the results fit) waits for a tap. Arming on its
            // own reports alone missed a sentinel that stayed off screen across the change.
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            if !visibility.sentinelOnScreen, !visibility.pageRequested, !visibility.anchoring {
                visibility.pageArmed = true
            }
        }
        .onDisappear {
            landed = false
            visibility.initialScrollIssued = false
            // During a search the inbox's next feed waits for the reader to bring the
            // sentinel in (see the page's `onChange(of: search)`).
            visibility.pageArmed = armedOnReturn()
            visibility.anchoring = false
            visibility.shownSearch = nil
            onLeave()
            visibility.shrinkJump?.cancel()
        }
        // Older rows landed above: put the previously-top message back at the top, so the
        // insert does not move what the reader is looking at. If the sentinel is still on
        // screen once that settles (the drawn rows do not fill the feed), the reader can see
        // the top, so the next window is asked for.
        .onChange(of: anchorID) { _, id in
            guard let id else { return }
            anchorID = nil
            visibility.anchoring = true
            Task { @MainActor in
                // The inserted rows may still be settling their heights, so one
                // jump can land short (on iPhone the feed stayed at the top of the new page,
                // sentinel in view). Jump FIRST, then check after the layout pass, and
                // jump again until the row has really landed at the top: checking before
                // the first jump read the row's placement from BEFORE the insert, which
                // could end the restore without moving the feed. Bounded so a feed that
                // cannot get there (it fits on screen) never spins.
                for _ in 0..<10 {
                    feed.scrollTo(id, anchor: .top)
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    if visibility.rowsAtTop.contains(id) { break }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
                visibility.anchoring = false
                // Landed: at the top, or on screen with the bottom marker too (the whole
                // feed fits, so the row cannot be scrolled up to the top).
                let settled = visibility.rowsAtTop.contains(id)
                    || (visibility.rows.contains(id) && visibility.atBottom)
                if !visibility.sentinelOnScreen {
                    visibility.pageArmed = true
                } else if settled, chainsAfterAnchor() {
                    // The reader's place is back and the top is STILL in view: the reader
                    // can see it, so this is an arrival at the top too.
                    visibility.pageArmed = true
                    onSentinelArrival()
                }
                // Otherwise the anchor did not hold; nothing chains until the reader
                // scrolls the sentinel away and back.
            }
        }
    }

    /// The feed has landed where it opens (its bottom marker came on screen after the scroll
    /// was issued, or the `openAt` row reached the top): from now on rows that appear are
    /// being read, and the owner's
    /// `onLanded` handles what is on screen already.
    private func finishInitialScroll() {
        guard visibility.initialScrollIssued, !landed else { return }
        landed = true
        onLanded()
    }
}

/// What of a `WindowedBottomFeed` is on screen, from the rows' and bottom marker's
/// appear/disappear. A class held in the owner's `@State` so the callbacks can update it
/// without re-rendering the page.
final class FeedVisibility {
    /// Feed rows on screen (inside the scroll view's visible bounds, not merely built).
    var rows: Set<String> = []
    /// Feed rows whose top sits at the top of the visible bounds: where an anchor scroll
    /// (`scrollTo(id, anchor: .top)`) puts a row once it has really landed.
    var rowsAtTop: Set<String> = []
    /// Feed rows whose top sits at the floating header's bottom edge (at the scroll view's
    /// top when there is no header): below the header, where the feed opens at a named row.
    var rowsAtVisibleTop: Set<String> = []
    /// The bottom marker is on screen: the reader is at the newest message.
    var atBottom = false
    /// The older-messages sentinel at the top is on screen.
    var sentinelOnScreen = false
    /// An older page is being fetched for the sentinel (the inbox's `requestOlderPage`).
    var pageRequested = false
    /// The sentinel may fetch when it comes on screen. Spent by a fetch and given back only
    /// when the reader scrolls the sentinel away (so its NEXT arrival is a new one), or when
    /// the page has landed, the reader's place is restored, and the sentinel is still in
    /// view (the loaded rows do not reach the top of the feed).
    var pageArmed = true
    /// Restoring the reader's place after an older page landed: the sentinel's visibility
    /// flickers while the anchor scroll converges and must not arm or fetch meanwhile.
    var anchoring = false
    /// The initial scroll to the bottom has been asked for on this appearance.
    var initialScrollIssued = false
    /// The feed has landed on the newest message, for an owner whose drawing does not depend on
    /// it (Saved): its `landed` binding points here instead of at `@State`. The inbox keeps its
    /// own `didInitialScroll`, which its rows read.
    var landed = false
    /// The feed's visible height at the bottom marker's last report, so a shrink (keyboard
    /// up, composer grown) can be told from the reader scrolling away. 0 = not known yet.
    var viewportHeight: CGFloat = 0
    /// The pending "stay at the bottom" scroll after a shrink. Re-scheduled on every frame
    /// of the resize and run once it settles: a `scrollTo` on every animation frame of a
    /// growing editor locked the lazy feed's layout (main thread busy, UI test hung).
    var shrinkJump: Task<Void, Never>?
    /// The search text the feed last showed, so a CHANGE of it (not the feed's first
    /// appearance) scrolls to the newest match. nil until the feed has appeared.
    var shownSearch: String?
    /// The inbox's running older-messages fetch (the sentinel's, or the no-matches button's),
    /// so a new or cleared search cancels it.
    var olderFetch: Task<Void, Never>?
}

extension View {
    /// Calls `action` with whether this view is inside the nearest scroll view's visible
    /// bounds (grown by `slack` points above and below), whenever that changes. Geometry,
    /// not `onAppear`: a drawn row is not necessarily on screen, so
    /// "built" is not "on screen".
    func onFeedVisibilityChange(slack: CGFloat = 0, _ action: @escaping (Bool) -> Void) -> some View {
        onFeedPlacementChange(slack: slack) { action($0.onScreen) }
    }

    /// As `onFeedVisibilityChange`, also reporting whether the view's top sits at the top of
    /// the visible bounds (within a few points), where `scrollTo(_, anchor: .top)` puts it.
    /// Reports transitions only, not every scrolled point. `appearance` rides in the value so
    /// a new appearance reports again although the geometry is unchanged.
    ///
    /// `visibleTop` is the floating header's bottom edge in `GramView.feedPageSpace`. The feed
    /// scrolls on under the header, and its content has a top margin of the header's height,
    /// so a row anchored at the top may land at the header's bottom edge rather than at the scroll
    /// view's own top: either counts as the top, or the paging anchor would never land. Only
    /// the part of the viewport below the header counts as on screen: a row under the header's
    /// controls and fade is not being read.
    func onFeedPlacementChange(slack: CGFloat = 0, appearance: Int = 0, visibleTop: CGFloat? = nil,
                               _ action: @escaping (FeedPlacement) -> Void) -> some View {
        onGeometryChange(for: FeedPlacement.self) { proxy in
            guard let scrollBounds = proxy.bounds(of: .scrollView) else {
                return FeedPlacement(onScreen: false, atTop: false, atVisibleTop: false,
                                     appearance: appearance)
            }
            let page = proxy.frame(in: .named(GramView.feedPageSpace))
            var visible = scrollBounds
            if let visibleTop {
                // The header's bottom edge in this view's own coordinates.
                let headerEdge = visibleTop - page.minY
                if headerEdge > visible.minY {
                    visible = CGRect(x: visible.minX, y: headerEdge, width: visible.width,
                                     height: max(0, visible.maxY - headerEdge))
                }
            }
            let onScreen = visible.height > 0 && visible.insetBy(dx: 0, dy: -slack)
                .intersects(CGRect(origin: .zero, size: proxy.size))
            // `scrollBounds` is in this view's own coordinates, so its minY is how far the
            // scroll view's top lies below this view's top.
            let atScrollTop = abs(scrollBounds.minY) <= 8
            // At the header's bottom edge: the top of what the reader can see.
            let atHeaderEdge = visibleTop.map { abs(page.minY - $0) <= 8 }
            return FeedPlacement(onScreen: onScreen, atTop: atScrollTop || atHeaderEdge == true,
                                 atVisibleTop: atHeaderEdge ?? atScrollTop, appearance: appearance)
        } action: { action($0) }
    }

    /// The bottom marker's tracker: on screen (within `slack`) and the feed's visible height,
    /// so a resize under the reader is reported apart from a scroll.
    func onFeedBottomChange(slack: CGFloat, _ action: @escaping (FeedBottom) -> Void) -> some View {
        onGeometryChange(for: FeedBottom.self) { proxy in
            guard let viewport = proxy.bounds(of: .scrollView) else {
                return FeedBottom(onScreen: false, viewportHeight: 0)
            }
            let onScreen = viewport.insetBy(dx: 0, dy: -slack)
                .intersects(CGRect(origin: .zero, size: proxy.size))
            return FeedBottom(onScreen: onScreen, viewportHeight: viewport.height)
        } action: { action($0) }
    }
}

/// Where a feed view sits in the scroll view's visible bounds (`onFeedPlacementChange`).
struct FeedPlacement: Equatable {
    let onScreen: Bool
    let atTop: Bool
    /// The view's top sits at the top of the visible feed: the floating header's bottom edge
    /// when there is a header, else the scroll view's top. `atTop` also counts the scroll
    /// view's own top under a header.
    let atVisibleTop: Bool
    let appearance: Int
}

/// The bottom marker's report (`onFeedBottomChange`).
struct FeedBottom: Equatable {
    let onScreen: Bool
    let viewportHeight: CGFloat
}

/// Turns off `scrollsToTop` on the UIScrollView a SwiftUI ScrollView is drawn with, from a
/// probe in its content: the probe finds its nearest UIScrollView ancestor once it is in a
/// window. Public UIKit only. `WindowedBottomFeed` uses it for a tab's own feed, whose top is
/// the OLDEST message, so neither a re-tap of its tab nor a status-bar tap sends it there.
private struct ScrollsToTopOff: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        return probe
    }

    func updateUIView(_ uiView: Probe, context: Context) {}

    final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView {
                    scrollView.scrollsToTop = false
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

/// How wide a `WindowedBottomFeed`'s column is.
enum FeedColumn {
    /// The conversation column Chat uses too (`conversationColumn`): the reader's width on
    /// iPad and Mac, resized from the page's edge handles; the whole width on iPhone. UI tests
    /// measure it as `probe`.
    case conversation(probe: String)
    /// At most this wide, centred.
    case capped(CGFloat)
}

private extension View {
    @ViewBuilder func feedColumn(_ column: FeedColumn) -> some View {
        switch column {
        case .conversation(let probe): conversationColumn(probe: probe)
        case .capped(let cap): readableColumn(cap)
        }
    }
}
