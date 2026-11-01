import HerdrKit
import SwiftUI
import UIKit

/// The unread-gram count, lifted out of `GramView` so the tab bar can badge it
/// even while the Gram tab is off-screen. Owned by the session-scoped home view;
/// GramView writes it on load / mark-read while visible, and an ambient poller
/// keeps it fresh while another tab is showing.
final class GramUnreadTracker: ObservableObject {
    @Published var count = 0
}

/// The Gram page: the owner's side of the owner<->agent message channel.
///
/// The app is the OWNER. This shows the inbox (agent->owner messages the fleet
/// sent, plus the owner's own posts and their claim state) newest-first, and a
/// composer to post to the shared grab-queue or, with an "@name", one agent directly.
/// Up to `ComposerStaging.maxAttachments` files can be staged, and each sends as its own
/// message. A received file draws as a card (`GramFileCard`, `GramImageCard`) that
/// downloads and previews it; long-pressing a message opens its menu, whose Delete
/// removes it — and its file bytes — for good, which is what makes gram safe for a
/// short-lived secret like a temporary API key.
///
/// Nav-agnostic: it renders its own content, has no close control of its own (it is a
/// persistent tab), owns its polling and never blocks the caller.
struct GramView: View {
    let client: HerdrClient
    /// Shared unread count for the tab-bar badge. Optional (defaulted) so existing
    /// call sites (and the DEBUG harness) compile unchanged; written on load and
    /// mark-read so reading a message clears the badge without leaving the tab.
    var unread: GramUnreadTracker? = nil
    /// Which "conversation" is shown — Inbox (false) or Saved (true). OWNED BY THE HOST, not
    /// by this view, because on regular width the selector lives in the app's real
    /// NavigationSplitView sidebar rather than inside this page. A sibling column cannot drive
    /// a `@State` in here, so the state is hoisted and both layouts read the same binding.
    @Binding var showingSaved: Bool
    /// Bumped by the host to request a reload. The regular-width refresh affordance moved to
    /// the sidebar with the rest of the selector, and a sidebar button cannot call this view's
    /// async `load` directly — so it changes a token and `onChange` performs the load, the same
    /// one-shot-signal pattern the terminal uses for jump-to-tail and collapse.
    var refreshToken: Int = 0
    /// Bumped by the host's sidebar Read-all button, same one-shot-signal reason as
    /// `refreshToken`: a sibling column cannot call this view's async `markAllRead` directly.
    /// Defaulted so the phone call site (which has its own header button) omits it.
    var readAllToken: Int = 0
    /// The host's search text (the iPad/Mac sidebar field). When set, the feed filters by it
    /// and the page draws no search control of its own. Declared after `readAllToken` so the
    /// memberwise init keeps its order (see the sidebar call site).
    var searchText: Binding<String>? = nil
    /// Bumped by the host when the owner taps Gram while it is already selected (the iPhone
    /// tab bar, the iPad section bar): the shown feed, the inbox or Saved, goes to its newest
    /// message at the bottom, not the system's scroll-to-top (see `WindowedBottomFeed`).
    var newestToken: Int = 0

    /// The last server snapshot (newest first) and the owner's just-posted messages
    /// not yet reflected in a snapshot. `messages` composes them so a background poll
    /// can never drop an optimistic post it hasn't caught up to.
    /// The server snapshot, held in a store that OUTLIVES this view: on iPad the page
    /// is destroyed whenever the section changes, and a view-local list meant every
    /// return re-fetched the whole store behind a spinner. Accessed through
    /// `serverMessages` below so the rest of the page reads unchanged.
    @ObservedObject private var inboxStore = GramInboxStore.shared
    /// The last server snapshot, newest first. Read-only: every mutation goes through
    /// a `GramInbox` method so the digest is invalidated with the change (a locally
    /// altered list must not be re-validated by a digest the daemon issued for the
    /// list before it).
    private var serverMessages: [GramMessage] { inboxStore.inbox.messages }
    @State private var pendingPosts: [GramMessage] = []
    @State private var phase: LoadPhase = .loading
    @State private var draft: String = ""
    /// The agent the reader picked from the @ list or the agents sheet, by its exact sender
    /// ID: it addresses the draft while the draft's addressing mention still names it, so a
    /// name two agents share (a local and a relayed clientloop) goes to the one picked.
    /// Dropped when that mention is edited away.
    @State private var pickedAgent: GramAgent?
    /// The field's caret as a UTF-16 distance from the end of the draft. The field keeps that
    /// distance when the draft is replaced from here (an @ completion), so it stays right
    /// without a report from the field. 0 = the end.
    @State private var draftCaretFromEnd = 0
    /// UIKit owns the multiline field; focus is mirrored through its delegate.
    @State private var composerFocused = false
    @StateObject private var composerKeyboard = ComposerKeyboard()
    /// True while dictating into the composer, so the field is disabled (typing can't be
    /// overwritten by the next partial) while the live transcript still appends.
    @State private var draftDictating = false
    /// The Gram page's height (feed, banner and composer together, above the keyboard). The
    /// composer cannot change it: its growth only moves space between the feed and itself.
    @State private var pageHeight: CGFloat = 0
    /// The error/notice banner's height above the composer (0 without one).
    @State private var bannerHeight: CGFloat = 0
    /// Kept out of the editor's room on top of the 48 pt it already leaves: the card grows by
    /// a few points more than the editor's text height (its handle row and paddings), so the
    /// visible feed below the header must not be budgeted to the point.
    private static let feedRoomCushion: CGFloat = 12
    /// The composer card's height, for `composerAtRest` only.
    @State private var composerCardHeight: CGFloat = 0
    /// The composer's recipient hint line above the card (0 without one).
    @State private var composerHintHeight: CGFloat = 0
    /// The composer's padding around its card (top 4 + bottom 8).
    private static let composerPadding: CGFloat = 12
    /// The room the composer's pull-to-expand editor may grow into (`composerEditorRoom`):
    /// the page below the floating header, less the banner, the resting composer (hint,
    /// padding, one-row card) and the cushion. From measurements the editor cannot move, on
    /// purpose: it used to be the feed's measured height plus the card's growth, two values
    /// updated in different passes, and while the editor opened they disagreed frame after
    /// frame; SwiftUI never settled (main thread busy, the composer UI test hung on CI's iPhone).
    private var composerRoom: CGFloat {
        max(0, pageHeight - headerBottom - bannerHeight - composerHintHeight - Self.composerPadding
            - ComposerStyle.restingHeight - Self.feedRoomCushion)
    }
    /// The composer is one row (not wrapped, no editor open): only then does a shrinking feed
    /// follow the reader to the bottom.
    private var composerAtRest: Bool { composerCardHeight <= ComposerStyle.restingHeight + 1 }
    @State private var sending = false
    /// A send failure. Kept SEPARATE from load state so a successful background poll
    /// never clears it before the owner sees it.
    @State private var sendError: String?
    /// A non-fatal refresh failure while messages are already shown.
    @State private var refreshNote: String?
    /// Consecutive failed loads, reset by any success. Drives the poll backoff: a
    /// warm cache keeps `phase == .loaded` through a failure, so `phase` alone can no
    /// longer tell a healthy poll from a failing one.
    @State private var loadFailures = 0
    @State private var isLoading = false
    /// A manual refresh that arrived while a load was already running.
    ///
    /// `load` takes one at a time, and the ambient 6s poll means a tap often lands mid
    /// flight — so the tap was silently dropped and the button genuinely did nothing.
    /// The request is remembered and run once the in-flight load finishes.
    @State private var refreshQueued = false
    /// Set while a MANUAL refresh is running, so the control can show it is working. The
    /// poll deliberately does not set it: a spinner appearing every six seconds on its
    /// own is noise, and the reader did not ask for it.
    @State private var manualRefreshing = false
    /// The manual-refresh acknowledgement, in its own slot so the 6s poll cannot clear it.
    @State private var refreshAck: String?
    /// Identity for the acknowledgement's expiry, so a stale timer cannot clear a newer note.
    @State private var refreshAckToken = 0
    /// A page fetch (older messages) in flight, kept apart from `isLoading` so the head
    /// poll and a scroll-driven page never block each other.
    @State private var isLoadingPage = false
    /// A failed page fetch, shown ON the sentinel so it survives the next successful
    /// head poll (which clears `refreshNote`) and gives the reader something to tap.
    @State private var pageError: String?
    /// A search's fetch of older pages for matches is running (`loadOlderMatches`): the
    /// sentinel and the "No matches in recent messages" button say so meanwhile.
    @State private var searchingOlder = false
    /// The last bounded search of older pages for the current query found nothing: how many
    /// messages are loaded now. The sentinel says so instead of falling silent. Cleared by a
    /// new query and by a search that finds a match.
    @State private var searchedOlderWithoutMatch: Int?
    /// Saved (bookmarked) Gram messages. Whether the Saved section is showing is the host's
    /// `showingSaved` binding above, not local state.
    @ObservedObject private var savedGrams = SavedGramStore.shared
    /// On regular width this page renders the feed + composer only; the Inbox/Saved selector and
    /// the refresh action live in the app's NavigationSplitView sidebar, so there is exactly ONE
    /// sidebar on screen. iPhone keeps its single column with the header toggle.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    /// Messages with a mark-read in flight, so a re-`onAppear` (scroll) does not fire
    /// a duplicate `gram.mark_read`.
    @State private var markingRead: Set<String> = []
    /// Free-text filter when the host does not supply shared search state.
    @State private var localSearch = ""
    /// Shared across sidebar and compact header when the host supplies `searchText`.
    private var search: String {
        get { searchText?.wrappedValue ?? localSearch }
        nonmutating set {
            if let searchText { searchText.wrappedValue = newValue } else { localSearch = newValue }
        }
    }
    private var searchBinding: Binding<String> { searchText ?? $localSearch }
    /// Whether the header's search field is showing (iPhone, or a host without a sidebar
    /// field): the magnifier-then-field the terminal header uses (`InlineSearchField`).
    @State private var searchOpen = false
    /// A query entered in the sidebar must remain visible and clearable after narrowing.
    private var searchFieldIsOpen: Bool { searchOpen || !search.isEmpty }
    @FocusState private var searchFocused: Bool
    /// The "N unread" rule: where it sits (the oldest unread message) and how many there
    /// were. Captured before the first mark-read of a visit, so reading the messages does not
    /// pull the rule away from under the reader. A visit ends when Gram goes off screen (the
    /// iPhone tab keeps this `@State` across tab switches), and a capture is also redone when
    /// unread goes from none to some, so a later unread message gets its own rule.
    @State private var unreadRule: UnreadRule?
    @State private var unreadRuleCaptured = false
    /// True once the feed has been scrolled to its newest message for this appearance. The
    /// first layout starts at the TOP, before the scroll runs, so until then rows appearing
    /// are not being read and the top sentinel is not a request for older messages.
    @State private var didInitialScroll = false
    /// Shows the "New messages" button: a message arrived while the reader was up in history.
    @State private var showingNewMessages = false
    /// The previously-top message after an older page landed above it; the feed scrolls back
    /// to it so the reader keeps their place.
    @State private var pageAnchorID: String?
    /// Which feed rows (and whether the bottom marker) are on screen. A reference box: it is
    /// read only from callbacks, so updating it on every scroll must not re-render the page.
    @State private var feedVisibility = FeedVisibility()
    /// Bumped each time the feed comes on screen. On iPhone Gram is a persistent tab: leaving
    /// it fires every tracker's `onDisappear` (clearing what is on screen), but coming back
    /// lays the feed out exactly as before, and `onGeometryChange` reports only CHANGES, so
    /// without this nothing would say the bottom or the rows are on screen again until the
    /// reader scrolled. See `onFeedPlacementChange` and the bottom/sentinel trackers.
    @State private var feedAppearance = 0
    /// Text segments opened with "Read more", by message id (segment indexes). Here rather
    /// than in the row so a row that is rebuilt (a new window, a search) does not fold it
    /// again; each row is handed only its own, so opening one re-renders only that row.
    @State private var expandedTexts: [String: Set<Int>] = [:]
    /// The "Gram ›" pill's sheet: Read all, the agents seen in Gram, and the shared queue.
    @State private var showingAgentsSheet = false
    /// The floating header's bottom edge in the page's coordinate space (`feedPageSpace`):
    /// the visible top of the feed, which scrolls on under the header.
    @State private var headerBottom: CGFloat = 0
    #if DEBUG
    /// The mock transport's recorded `gram.post` calls, for the `gram-post-calls` probe.
    @State private var postCallsProbe = ""
    /// "opened:<name>" once a file has been handed to a viewer, for the `gram-opened-file`
    /// probe.
    @State private var openedFileProbe = ""
    /// The mock's `gram.get_file` calls per id ("g2=0 g3=1 g11=0 g12=0"), for the `gram-get-file-calls`
    /// probe. Polled while a mock runs: prefetches start from rows, not from a page action.
    @State private var getFileProbe = ""
    /// How many older pages the paged mock has answered, for the `gram-list-pages` probe.
    @State private var listPagesProbe = 0
    #endif
    /// This device's machine label, for a local agent's "name · machine" line.
    @Environment(\.guestMachineLabel) private var localMachine
    /// True while a Read-all pass is running, so the button disables rather than stacking passes.
    @State private var markingAllRead = false
    /// A partial-failure report from a Read-all pass. Its OWN slot rather than `refreshNote`,
    /// which the 6-second poll clears on every success — same reasoning as `sendError`.
    @State private var markAllNote: String?

    /// Files the owner picked to attach to the next post (staged on disk at pick time),
    /// empty when none are staged. Several can be staged at once; each sends as its own
    /// gram message (the wire is one-file-per-message).
    @State private var attachedFiles: [ComposerAttachment] = []
    /// The paperclip's attach sheet (`composerAttachPicker`).
    @State private var showAttachSheet = false
    /// True while a photo-library batch is loading (iCloud items can take a moment).
    /// Gates Send and the paperclip so a text-only send can't race the load and a
    /// second pick can't start concurrently.
    @State private var loadingPhoto = false
    /// Uploads each staged file as it is added, so Send only posts; its per-file progress
    /// drives the chips. Released with the page, which abandons the draft.
    @State private var uploader = ComposerUploader()
    /// The file in flight, while a send runs.
    @State private var sendingAttachmentID: UUID?
    @State private var failedAttachmentID: UUID?
    /// Dismissed the "set up gram for your agents" card. It also auto-hides once any
    /// agent has messaged (proof they've set the skill up), so this is the manual out.
    @AppStorage("gram.setupCardDismissed") private var setupCardDismissed = false
    /// The UI text-size setting. Read in `body` only to observe it: `Typography.scale`
    /// is a global static outside SwiftUI's dependency graph, so a parent re-render
    /// does not re-run this separate child struct — without this, Gram would show
    /// old-size text after a size change until it re-rendered for another reason.
    @AppStorage("ui.fontScale") private var uiFontScale: Double = 1.0
    /// Momentary "Copied ✓" on the setup card's copy button.
    @State private var setupCommandCopied = false
    /// The opened file in its viewer (`gramFileViewer`): QuickLook, or the in-app viewer
    /// for a received web document.
    @State private var preview: GramPreview?
    /// The reader's open and save downloads, and the image prefetches, live OUTSIDE the
    /// page (#574), in the connection's store (`RootView` holds it): leaving Gram for
    /// Agents (a tab switch on iPhone, a section switch on iPad, which rebuilds this view)
    /// must not end them. See `GramDownloadStore`.
    @Environment(\.gramDownloads) private var downloads
    /// The page's WAIT on the reader's download (`followHeldDownload`), not the download:
    /// cancelled when the page goes off screen, so a late completion never presents a
    /// viewer or an export picker over another tab, and started again when it comes back.
    @State private var heldWait: Task<Void, Never>?
    /// The message id whose file the owner is opening or saving, to show its card's ring.
    /// One at a time; the image prefetch never takes this slot.
    private var downloadingFileFor: String? { downloads.held?.id }
    #if DEBUG
    /// Bumped at each touch-down under the HERDR_REDRAW_ON_TOUCH mock knob: a page pass, as
    /// a poll landing mid-tap would make (DebugTouchRedraw).
    @State private var debugTouchRedraws = 0
    #endif
    /// Bytes of the reply received so far for the reader's download, against the bytes
    /// expected (`GramDownloadStore.Held.progress`). The owner's open fetches a file with
    /// `gram.get_file`, ONE base64 reply, so this counts SSH channel bytes — about 4/3 of
    /// the file — the only progress that request gives. (`gram.get_file_chunk` exists; the
    /// guest page uses it, this page does not.)
    ///
    /// STAYS NIL UNTIL A CALLBACK ACTUALLY ARRIVES. Only the Citadel transport reports
    /// bytes; a mock or a local socket reports none, and seeding this from the file
    /// size alone would pin a determinate ring at 0% for the whole download, which is
    /// exactly the lying ring the spinning one exists to avoid. The card's ring spins
    /// while this is nil.
    private var downloadBytes: (received: Int, total: Int)? { downloads.held?.progress }
    /// Bounds the image prefetches running at once (`GramImagePreview`).
    @State private var prefetchSlots = AsyncSlots(limit: GramImagePreview.maxConcurrentPrefetches)
    /// A Gram file downloaded and staged for export through the system document
    /// picker, so the owner saves it to a real, user-chosen location.
    @State private var exportFile: ExportFile?
    /// Ids the server has confirmed deleted, kept as tombstones so an in-flight poll
    /// (whose snapshot predates the delete) cannot resurrect the row for a few
    /// seconds. Cleared once the server's own snapshot also omits the id.
    @State private var deletedIDs: Set<String> = []

    // The pre-send size gate and the count cap both live on `ComposerStaging`
    // (nonisolated, so the photo importer and the terminal composer can read them):
    // `ComposerStaging.maxFileBytes` and `ComposerStaging.maxAttachments`.

    /// The list the page renders: optimistic posts first, then the server snapshot
    /// with those posts de-duped out once the server reflects them.
    private var messages: [GramMessage] {
        let pendingIDs = Set(pendingPosts.map(\.id))
        return (pendingPosts + serverMessages.filter { !pendingIDs.contains($0.id) })
            .filter { !deletedIDs.contains($0.id) }
    }

    /// Inbox rows after the search filter. Matches message text, the sender, the recipient,
    /// and an attachment's filename — a reader looking for "the key I sent keephair" searches
    /// by any of those, and matching only `text` would miss the last two.
    ///
    /// DELIBERATELY SEPARATE from `messages`: the unfiltered set is what `unreadCount`,
    /// `markReadIfNeeded` and `markAllRead` read, so an active search can never make the
    /// badge lie or hide a message from a Read-all pass. Do not fold the filter into
    /// `messages` itself.
    private var visibleMessages: [GramMessage] {
        guard !search.isEmpty else { return messages }
        return messages.filter { message in
            message.text.localizedCaseInsensitiveContains(search)
                || message.from.localizedCaseInsensitiveContains(search)
                || message.senderName.localizedCaseInsensitiveContains(search)
                || (message.to ?? "").localizedCaseInsensitiveContains(search)
                || ((message.file ?? message.expiredFile)?.name ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    /// Saved rows after the same filter. `SavedGram` has no `to`, so sender + text + filename.
    private var visibleSaved: [SavedGram] {
        guard !search.isEmpty else { return savedGrams.saved }
        return savedGrams.saved.filter { saved in
            saved.text.localizedCaseInsensitiveContains(search)
                || saved.from.localizedCaseInsensitiveContains(search)
                || ((saved.file ?? saved.expiredFile)?.name ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    /// Where the "N unread" rule sits and the count it shows (see `unreadRule`).
    private struct UnreadRule: Equatable {
        let messageID: String
        let count: Int
    }

    /// The newest message in the whole loaded list (not the search-filtered one): what the
    /// feed follows in when it changes to a newer message.
    private struct FeedTip: Equatable {
        let id: String
        let createdUnixMs: UInt64
    }

    private var feedTip: FeedTip? {
        messages.max { $0.createdUnixMs < $1.createdUnixMs }
            .map { FeedTip(id: $0.id, createdUnixMs: $0.createdUnixMs) }
    }

    /// How many of the newest visible messages the feed draws (see `feedEntries`). Grows by
    /// a window each time the reader reaches the top; a new search starts it over.
    @State private var renderLimit = GramView.renderWindow
    /// 80 messages: two pages and change, a few screens of history, cheap to lay out.
    static var renderWindow: Int {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["HERDR_GRAM_RENDER_WINDOW"].flatMap(Int.init),
           override > 0 { return override }
        #endif
        return 80
    }
    /// Loaded messages older than the drawn window: the top sentinel reveals them, no fetch.
    private var hasHiddenOlder: Bool { visibleMessages.count > renderLimit }
    /// The top sentinel searches older history for matches rather than loading the next page:
    /// a search is active. Search covers the loaded messages only (the daemon has no search),
    /// so reaching the top of the results is how the reader asks for older matches.
    private var sentinelSearchesOlder: Bool { !search.isEmpty }

    /// The newest `renderLimit` of the visible messages, oldest first, with their separators,
    /// unread rule and groups. Everything the feed draws comes from here.
    private var feedEntries: [GramFeedEntry] {
        GramFeedEntry.entries(oldestFirst: Array(visibleMessages.prefix(renderLimit).reversed()),
                              unreadRule: unreadRule.map { ($0.messageID, $0.count) })
    }

    private enum LoadPhase: Equatable {
        case loading
        case loaded
        /// The server does not offer gram yet (older daemon), or another load error.
        case unavailable(String)
    }

    var body: some View {
        // Observe the text-size setting so Gram re-renders at the new Typography.scale.
        let _ = uiFontScale
        #if DEBUG
        let _ = debugTouchRedraws
        #endif
        return Group {
            if hSizeClass == .regular {
                iPadBody
            } else {
                phoneBody
            }
        }
        .background(Palette.ground.ignoresSafeArea())
        .background { gramKeyboardShortcuts }
        #if DEBUG
        .overlay(alignment: .topLeading) { postCallsProbeView }
        // Mock knob HERDR_REDRAW_ON_TOUCH: a Gram pass at every touch-down (DebugTouchRedraw).
        .onAppear { DebugTouchRedraw.installIfEnabled() }
        .onReceive(NotificationCenter.default.publisher(for: DebugTouchRedraw.touchDown)) { _ in
            debugTouchRedraws &+= 1
        }
        #endif
        // Poll while the page is open so new agent messages appear without a manual
        // refresh (the gram store has no event stream); the loop ends when the view
        // goes away (task cancellation).
        .task { await pollLoop() }
        // A new visit's rule: unread went from none to some (a poll brought one in after
        // everything was read), so the old capture says nothing about it.
        .onChange(of: unreadCount) { old, new in
            if old == 0, new > 0 { captureUnreadRule() }
        }
        // The sidebar's refresh button bumps `refreshToken`; consume the change here so a
        // sibling column can drive this view's async reload without owning its state. Guarded on
        // a real change (SwiftUI may re-run the body for unrelated reasons) and on `initial:
        // false` so it refreshes in place instead of dropping back to the loading phase.
        .onChange(of: refreshToken) { old, new in
            guard new != old else { return }
            // Same path as the phone header's button, so the sidebar affordance cannot
            // be silently swallowed by an in-flight poll either.
            Task { await manualRefresh() }
        }
        // The sidebar's Read-all button bumps `readAllToken` for the same reason refresh does.
        .onChange(of: readAllToken) { old, new in
            guard new != old else { return }
            Task { await markAllRead() }
        }
        // A filter typed in Inbox has no meaning in Saved, and leaving it set would greet the
        // just-selected section with "No matches", which reads as a bug. Only the page's OWN
        // field: a host's sidebar search (`searchText`) is the reader's and outlives the switch.
        .onChange(of: showingSaved) { _, _ in localSearch = "" }
        // An inherited sidebar query opens the compact editor. Keep that editing intent
        // after the final backspace; only the explicit close action dismisses the field.
        .onChange(of: offersOwnSearch && !search.isEmpty, initial: true) { _, inheritedQuery in
            if inheritedQuery { searchOpen = true }
        }
        // A new search (or clearing it) starts from the newest window again, and ends the
        // previous query's search of older history. On the page, not the feed: from "No
        // matches" the feed is unmounted, and a reset inside it would miss the clear.
        .onChange(of: search) { _, new in
            renderLimit = Self.renderWindow
            feedVisibility.olderFetch?.cancel()
            searchedOlderWithoutMatch = nil
            feedVisibility.olderFetch = nil
            feedVisibility.pageRequested = false
            searchingOlder = false
            // During a search only the reader's own arrival at the top searches older
            // history: a short result list shows the sentinel at once, which asks nothing.
            feedVisibility.pageArmed = new.isEmpty
        }
        // The "Gram ›" pill: Read all, the agents seen in Gram, and the shared queue.
        .sheet(isPresented: $showingAgentsSheet) { agentsSheet }
        // Paperclip → the shared attach sheet and pickers; picks stage straight into
        // `attachedFiles` under the shared size and count limits.
        .composerAttachPicker(
            isPresented: $showAttachSheet, loading: $loadingPhoto,
            room: { ComposerStaging.maxAttachments - attachedFiles.count }
        ) { outcome in
            let picked = outcome.files.map {
                ComposerAttachment(name: $0.name, mime: $0.mime,
                                   isImage: $0.mime.hasPrefix("image/"), staged: $0.staged)
            }
            attachedFiles += picked
            // Upload at once, so Send only has to post them.
            uploader.start(picked, client: client, into: $attachedFiles)
            sendError = outcome.note
        }
        // A tapped file chip opens through the shared viewer (GramFileViewer.swift):
        // HTML/SVG in the in-app web viewer, everything else in QuickLook.
        .gramFileViewer($preview)
        // Explicit "Save to Files…" (from a file chip's context menu): export through
        // the system document picker so the file lands where the owner picks — the real
        // Finder ~/Documents / ~/Downloads on Mac, the Files picker on iPhone/iPad.
        // QuickLook's own "Save to Files" resolves to the hidden app-sandbox container
        // on the Designed-for-iPad Mac build, so saves there appear to vanish.
        .sheet(item: $exportFile) { export in
            FileExportPicker(url: export.url) {
                // asCopy already copied it to the chosen location; drop our temp.
                try? FileManager.default.removeItem(at: export.dir)
                exportFile = nil
            }
            .ignoresSafeArea()
        }
        // Gram is a persistent tab: coming back picks up the uploads leaving it stopped,
        // and waits again on a download the reader started before leaving (#574): its ring
        // is back on the card and the file opens when it lands.
        .onAppear {
            uploader.resume()
            followHeldDownload()
        }
        .onDisappear {
            // Gram went off screen: the next time it shows, the "N unread" rule is captured
            // afresh instead of staying on a message read during this visit.
            unreadRuleCaptured = false
            // Stop WAITING on the reader's download, never the download (#574: this used to
            // cancel it, so a switch to Agents lost it). It keeps running in the store and
            // lands in the cache; a wait left running would present the viewer or the export
            // picker over another tab, and strand a temp file after the viewer's cleanup ran.
            heldWait?.cancel()
            heldWait = nil
            // Leaving Gram stops its attachments' uploads (a send already waiting on one
            // keeps it); `onAppear` resumes them.
            uploader.pause()
            // Staged attachment bytes are deliberately NOT removed here. Gram is a
            // persistent tab (see HerdrApp's TabView), so `onDisappear` fires on a
            // plain tab switch while this view's `@State` — including the chips in
            // `attachedFiles` — survives. Unlinking here would delete the bytes of an
            // attachment still shown in the composer, and make its retry unfixable.
            // The staged bytes are released on chip-X, after a successful send, and
            // for a killed session by the next launch's staging sweep.
        }
        // Don't let a swipe-down (the new sheet dismissal) abandon an in-flight send
        // or a photo load mid-way — the chunked upload would keep running off-screen.
        .interactiveDismissDisabled(sending || loadingPhoto)
    }

    // MARK: - Layout roots

    /// The page's coordinate space: the floating header's bottom edge and the feed's rows are
    /// compared in it (`onFeedPlacementChange(visibleTop:)`).
    static let feedPageSpace = "gram-page"

    /// iPhone / compact width: a single column — the feed with the nav bar (back, the senders'
    /// avatar group over the "Gram ›" pill, search and Saved) floating over its top, then the
    /// banner and the composer.
    private var phoneBody: some View {
        VStack(spacing: 0) {
            content
                .gramFloatingHeader {
                    header
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.frame(in: .named(Self.feedPageSpace)).maxY
                        } action: { if abs($0 - headerBottom) > 0.5 { headerBottom = $0 } }
                }
            measuredBanner
            composer
                .environment(\.composerEditorRoom, composerRoom)
                // The composer must ALWAYS fit: it holds the only way to send. Without a
                // priority it is just another default-priority row, so when attachments add
                // the chips strip and the progress block the stack's minimum can exceed the
                // window - and a VStack overflows rather than clipping, putting the send
                // button below the bottom edge, and with no keyboard send the composer
                // becomes unreachable.
                //
                // This used to claim the split-view host anchors that overflow at the top.
                // It does not, and never did — cited line 1885 was `.tint(Palette.brand)`.
                // `TerminalHomeView.iPadLayout`'s detail closure adds NO frame, so an
                // oversized page is reported oversized and the excess is split between
                // top and bottom. A round of PR #269 briefly added a top-anchoring
                // `.frame(maxWidth:maxHeight:alignment:.topLeading)` there; I described it
                // as causing exactly the failure above, and that was wrong too. A frame
                // given only MAXIMUM constraints reports the child's own size when the
                // child exceeds the proposal, so it neither clamped the overflow nor
                // re-anchored it. Cited by SYMBOL deliberately: the line number was stale
                // on the day it was written and shifted again twice since.
                .layoutPriority(1)
                // Above the feed: the @-mention list floats up over the messages.
                .zIndex(1)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if abs($0 - pageHeight) > 0.5 { pageHeight = $0 } }
        .coordinateSpace(.named(Self.feedPageSpace))
    }

    /// The banner in a stack that reports its height, 0 included (an empty view would not).
    private var measuredBanner: some View {
        VStack(spacing: 0) { bannerView }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if abs($0 - bannerHeight) > 0.5 { bannerHeight = $0 } }
    }

    /// Regular width: the message feed with the avatar-group header floating over its top,
    /// then the composer. The Inbox/Saved selector, search, Read all and refresh are rendered
    /// by the host in the app's real `NavigationSplitView` sidebar, exactly like the agents list.
    ///
    /// This page used to draw its OWN 260pt rail here, which on iPad and Mac put a second
    /// sidebar next to the split view's own column — and that column was rendering an empty
    /// `Spacer()` for this section, so the screen showed one empty system sidebar and one
    /// hand-rolled one. Reuses the SAME `content` / `bannerView` / `composer` as the phone, so
    /// every send/attach/poll behaviour is identical.
    ///
    /// The feed, header, banner and composer share the conversation column Chat uses
    /// (`conversationColumn`), at the one width the reader sets from either page's edge
    /// handles (#541). The column reads the width itself, so a drag never re-runs this body.
    private var iPadBody: some View {
        VStack(spacing: 0) {
            content
                // Under the floating header: its trailing controls sit at the column's edge,
                // and stay tappable there; the readout shows below it.
                .conversationColumnResizer(.gram, readoutTop: headerBottom)
                .gramFloatingHeader {
                    iPadHeader
                        .conversationColumn()
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.frame(in: .named(Self.feedPageSpace)).maxY
                        } action: { if abs($0 - headerBottom) > 0.5 { headerBottom = $0 } }
                }
            // The banner and composer share the feed's column, so the field lines up under
            // the messages instead of spanning the whole detail pane.
            measuredBanner
                .conversationColumn()
            composer
                .environment(\.composerEditorRoom, composerRoom)
                .conversationColumn()
                .layoutPriority(1)   // see phoneBody: the composer must always fit
                .zIndex(1)           // see phoneBody: the @-mention list floats over the feed
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if abs($0 - pageHeight) > 0.5 { pageHeight = $0 } }
        .coordinateSpace(.named(Self.feedPageSpace))
    }

    /// iPad / Mac: the same avatar group and "Gram ›" pill as the phone, centred at the top
    /// of the column, and at the right the phone's glass capsule: Saved alone while the
    /// host's sidebar owns search (`searchText`), search and Saved for a host that does not.
    private var iPadHeader: some View {
        VStack(spacing: 8) {
            ZStack {
                headerIdentity
                HStack {
                    Spacer(minLength: 0)
                    headerTrailing
                }
            }
            if offersOwnSearch, searchFieldIsOpen { searchField.frame(maxWidth: 420) }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
    }

    /// The header's inline field, shared with the terminal pane (`InlineSearchField`).
    /// No match counter or chevrons: Gram FILTERS the list rather than walking matches,
    /// so the result count is the list itself.
    private var searchField: some View {
        InlineSearchField(
            placeholder: "Search messages",
            text: searchBinding,
            focus: $searchFocused,
            matches: nil,
            onNext: nil,
            onPrevious: nil,
            identifierPrefix: "gram-search"
        )
    }

    private var canFilter: Bool { showingSaved || phase == .loaded }

    /// Shared state does not imply a visible sidebar: compact layouts own their controls.
    private var offersOwnSearch: Bool {
        canFilter && (searchText == nil || hSizeClass != .regular)
    }

    /// Opens the field and takes focus, or closes it and clears the term — clearing is
    /// what restores the unfiltered list, so a hidden field can never leave the list
    /// silently filtered.
    private func toggleSearch() {
        if searchFieldIsOpen {
            searchOpen = false
            search = ""
            searchFocused = false
        } else {
            searchOpen = true
            searchFocused = true
        }
    }

    /// Command-F opens search or focuses the visible field. Only a regular-width host
    /// supplying shared search state owns the sidebar shortcut instead.
    private var gramKeyboardShortcuts: some View {
        Button("Find in Gram") {
            if searchFieldIsOpen { searchFocused = true } else { toggleSearch() }
        }
        .keyboardShortcut("f", modifiers: .command)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
        .disabled(!offersOwnSearch)
    }

    /// A load error / send error, shown ABOVE the composer in every phase — the
    /// composer is enabled in all states, so a failure must be visible in all states
    /// (empty inbox, pre-deploy daemon, or a loaded list alike).
    @ViewBuilder
    private var bannerView: some View {
        if let text = sendError ?? markAllNote ?? refreshAck ?? refreshNote {
            Text(text)
                .font(Typography.app(12))
                .foregroundStyle(Palette.died)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)
        }
    }

    // MARK: - Header

    /// The phone's nav bar: a glass back capsule with the amber unread count on the left
    /// (the count alone when this is a tab rather than a cover), the senders' avatar group
    /// over the "Gram ›" pill in the middle, and one glass capsule with search and Saved on
    /// the right. The search field opens as its own row under the bar.
    private var header: some View {
        VStack(spacing: 8) {
            ZStack {
                headerIdentity
                HStack(alignment: .center) {
                    headerLeading
                    Spacer(minLength: 0)
                    headerTrailing
                }
            }
            if offersOwnSearch, searchFieldIsOpen { searchField }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    /// The unread count, when there is one.
    @ViewBuilder
    private var headerLeading: some View {
        if unreadCount > 0 {
            unreadCountText
                .padding(.horizontal, 13)
                .frame(minWidth: 44, minHeight: 44)
                .gramGlass(Capsule())
                .accessibilityLabel("\(unreadCount) unread")
        }
    }

    private var unreadCountText: some View {
        Text(verbatim: "\(unreadCount)")
            .font(Typography.app(17, .medium))
            .monospacedDigit()
            .foregroundStyle(Palette.waiting)
    }

    /// Search (when there is something to filter) and the Inbox / Saved toggle.
    private var headerTrailing: some View {
        HStack(spacing: 0) {
            if offersOwnSearch {
                InlineSearchToggle(isOpen: searchFieldIsOpen, identifier: "gram-search",
                                   target: CGSize(width: 40, height: 44)) { toggleSearch() }
            }
            // A filled bookmark means the Saved section is showing.
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showingSaved.toggle() }
            } label: {
                Image(systemName: showingSaved ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(showingSaved ? Palette.brand : Palette.text)
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("Saved")
            .accessibilityIdentifier("gram-saved-toggle")
            .accessibilityAddTraits(showingSaved ? .isSelected : [])
        }
        .padding(.horizontal, 2)
        .gramGlass(Capsule())
    }

    /// The pill's word: "Saved" while the Saved list shows on iPhone, where the bookmark toggle
    /// is the only other sign of it. On iPad/Mac the sidebar's selected row already says so.
    private var headerTitle: String {
        showingSaved && hSizeClass != .regular ? "Saved" : "Gram"
    }

    /// The most recent distinct agent senders' avatars over the "Gram ›" pill (or "Saved ›",
    /// see `headerTitle`), which opens the agents sheet (Read all, the agents seen in Gram,
    /// the shared queue).
    private var headerIdentity: some View {
        Button { showingAgentsSheet = true } label: {
            VStack(spacing: -6) {
                GramAvatarCluster(names: messages.filter(\.isFromAgent).map(\.from))
                    .accessibilityHidden(true)
                HStack(spacing: 2) {
                    Text(headerTitle)
                        .font(Typography.app(13, .semibold))
                        .foregroundStyle(Palette.text)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Palette.textFaint)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .gramGlass(Capsule())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The Button stays the accessibility element (button trait, label "Gram" or "Saved");
        // hiding the avatars and chevron keeps the label to the pill's word.
        .accessibilityLabel(headerTitle)
        .accessibilityHint("Shows the agents in Gram and Read all")
        .accessibilityIdentifier("gram-header-pill")
    }

    /// An agent seen in Gram, for the pill's sheet.
    private struct GramAgent: Identifiable {
        /// The raw `from`, which is also the address a reply goes to.
        let from: String
        let name: String
        let machine: String?
        var id: String { from }
    }

    /// The agents seen in Gram, most recent first.
    private var gramAgents: [GramAgent] {
        var seen = Set<String>()
        var result: [GramAgent] = []
        for message in messages where message.isFromAgent {
            guard seen.insert(message.from).inserted else { continue }
            result.append(GramAgent(from: message.from, name: message.senderAgentName,
                                    machine: message.senderMachine ?? (localMachine.isEmpty ? nil : localMachine)))
        }
        return result
    }

    /// The pill's sheet: Read all (and Refresh), then who to write to — an agent seen in
    /// Gram or the shared queue. Choosing one puts that agent's "@name" at the start of the
    /// draft (or takes it off, for the queue) and closes it.
    private var agentsSheet: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { await markAllRead() }
                    } label: {
                        Label("Read all", systemImage: "envelope.open")
                    }
                    .disabled(markingAllRead || unreadCount == 0)
                    .accessibilityLabel("Read all")
                    .accessibilityValue(unreadCount > 0 ? "\(unreadCount) unread" : "")
                    Button {
                        Task { await manualRefresh() }
                    } label: {
                        HStack {
                            Label("Refresh", systemImage: "arrow.clockwise")
                            Spacer(minLength: 0)
                            if manualRefreshing { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(manualRefreshing)
                    .accessibilityLabel("Refresh")
                }
                Section("Write to") {
                    let shared = sharedNames
                    ForEach(gramAgents) { agent in
                        Button {
                            address(agent)
                            showingAgentsSheet = false
                        } label: {
                            HStack(spacing: 12) {
                                GramAvatar(name: agent.from, size: 32)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: agentTitle(agent, shared: shared))
                                        .font(Typography.app(16, .semibold))
                                        .foregroundStyle(Palette.text)
                                    if let machine = agent.machine, !shared.contains(agent.name.lowercased()) {
                                        Text(verbatim: machine)
                                            .font(Typography.app(13))
                                            .foregroundStyle(Palette.textDim)
                                    }
                                }
                                Spacer(minLength: 0)
                                if isAddressed(agent) {
                                    Image(systemName: "checkmark").foregroundStyle(Palette.brand)
                                }
                            }
                        }
                        .accessibilityIdentifier("gram-recipient-\(agentKey(agent, shared: shared))")
                    }
                    Button {
                        addressQueue()
                        showingAgentsSheet = false
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "tray.and.arrow.down")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Palette.textDim)
                                .frame(width: 32, height: 32)
                                .background(Palette.surfaceRaised, in: Circle())
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Shared queue")
                                    .font(Typography.app(16, .semibold))
                                    .foregroundStyle(Palette.text)
                                Text("Any agent can grab it")
                                    .font(Typography.app(13))
                                    .foregroundStyle(Palette.textDim)
                            }
                            Spacer(minLength: 0)
                            if isAddressed(nil) {
                                Image(systemName: "checkmark").foregroundStyle(Palette.brand)
                            }
                        }
                    }
                    .accessibilityIdentifier("gram-recipient-queue")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.ground)
            .navigationTitle("Gram")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingAgentsSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// The badge and the Read-all control read the WHOLE store's count, which the
    /// daemon sends: counting the loaded window would hide Read-all exactly when every
    /// unread message is older than the first page, and would disagree with the tab
    /// badge, which already comes from the inbox. Optimistic posts are the owner's own
    /// and never unread, so they are not added here.
    private var unreadCount: Int { inboxStore.inbox.unreadCount }

    // MARK: - Content

    private var content: some View {
        Group {
            if showingSaved { savedContent } else { inboxContent }
        }
        // Let a drag on the message feed dismiss the keyboard too, so the composer
        // never gets stuck covering the tab bar with no way out.
        .scrollDismissesKeyboard(.interactively)
    }

    /// Shown when the list HAS rows but the active search matches none of them. A distinct
    /// state from "nothing here yet": a blank scroll after typing reads as an empty inbox,
    /// which is the bug the agents list already avoids the same way.
    ///
    /// `hasOlder` is passed IN because this view is shared with the Saved section, which is
    /// local and complete by construction: there "No matches" is the whole answer. In the
    /// inbox a search covers the LOADED messages (the daemon has no search), so while older
    /// history exists it says so and offers the bounded search of older pages that reaching
    /// the top of a result list runs (`searchOlderMessages`).
    private func noMatches(hasOlder: Bool, loadedCount: Int) -> some View {
        centered {
            VStack(spacing: 8) {
                Image(systemName: hasOlder && pageError != nil ? "exclamationmark.triangle" : "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(Palette.textFaint)
                if hasOlder {
                    Text("No matches in recent messages")
                        .font(Typography.app(15, .medium))
                        .foregroundStyle(Palette.textDim)
                    Text(pageError.map { "\($0) Nothing in the \(loadedCount) loaded matches “\(search)”." }
                         ?? "Nothing in the \(loadedCount) most recent messages matches “\(search)”.")
                        .font(Typography.app(13))
                        .foregroundStyle(Palette.textFaint)
                        .multilineTextAlignment(.center)
                    Button { searchOlderMessages() } label: {
                        HStack(spacing: 6) {
                            if searchingOlder { ProgressView().controlSize(.small).tint(Palette.ground) }
                            Text(searchingOlder ? "Searching older messages…" : "Search older messages")
                        }
                        .font(Typography.app(14, .semibold))
                        .foregroundStyle(Palette.ground)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Palette.text))
                    }
                    .disabled(searchingOlder)
                    .padding(.top, 6)
                    .accessibilityIdentifier("gram-search-older")
                } else {
                    Text("No matches")
                        .font(Typography.app(15, .medium))
                        .foregroundStyle(Palette.textDim)
                    Text("Nothing in this list matches “\(search)”.")
                        .font(Typography.app(13))
                        .foregroundStyle(Palette.textFaint)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 32)
        }
    }

    /// The Saved section: locally-kept copies of bookmarked messages. Rendered from the local
    /// store (independent of the poll), so a saved message survives even after the original is
    /// deleted from the server. Read like the inbox: oldest at the top, opening at the newest,
    /// drawn a window at a time (`GramSavedFeed`).
    @ViewBuilder
    private var savedContent: some View {
        if savedGrams.saved.isEmpty {
            centered {
                VStack(spacing: 8) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 28))
                        .foregroundStyle(Palette.textFaint)
                    Text("No saved messages yet")
                        .font(Typography.app(15, .medium))
                        .foregroundStyle(Palette.textDim)
                    Text("Tap the bookmark on a message to keep it here.")
                        .font(Typography.app(13))
                        .foregroundStyle(Palette.textFaint)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)
            }
        } else if visibleSaved.isEmpty {
            // Saved is local and complete: there is nothing older to search.
            noMatches(hasOlder: false, loadedCount: savedGrams.saved.count)
        } else {
            GramSavedFeed(
                saved: visibleSaved,
                search: search,
                headerBottom: headerBottom,
                newestToken: newestToken,
                downloadingFileFor: downloadingFileFor,
                downloadBytes: downloadBytes,
                onOpenFile: { s in openFile(id: s.id, expectedBytes: Self.expectedReplyBytes(for: s.file?.size ?? 0)) },
                onSaveFile: { s in saveFile(id: s.id, expectedBytes: Self.expectedReplyBytes(for: s.file?.size ?? 0)) },
                onCancelDownload: { s in cancelDownload(id: s.id) },
                // UNSAVE DOES NOT EVICT. Unsaving stops keeping the message in the Saved
                // tab; the message itself may still be in the inbox, and discarding its
                // bytes here would re-download the next open — defeating the feature.
                // Bytes go on DELETE (the message is gone), on sign-out, or by the LRU ceiling.
                onUnsave: { s in savedGrams.remove(s.id) }
            )
        }
    }

    /// `phase`, corrected for a warm store.
    ///
    /// `phase` is `@State`, so on iPad it resets to `.loading` on every remount (the
    /// page is rebuilt inside the detail column's `switch selectedTab`). `load()` puts
    /// it right, but SwiftUI starts a `.task` only AFTER the first body evaluation, so
    /// the body runs once with `.loading` and would flash a spinner over a list that
    /// is already in hand. Deriving the render from the STORE removes the dependency
    /// on when `.task` first runs, which is the difference between "renders the
    /// previous list immediately" — what the design claims — and "within one
    /// main-actor turn".
    private var effectivePhase: LoadPhase {
        if case .loading = phase, inboxStore.inbox.hasLoaded { return .loaded }
        return phase
    }

    @ViewBuilder
    private var inboxContent: some View {
        switch effectivePhase {
        case .loading:
            centered { ProgressView().tint(Palette.textDim) }
        case .unavailable(let message):
            centered {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                        .font(.system(size: 28))
                        .foregroundStyle(Palette.textFaint)
                    Text(message)
                        .font(Typography.app(14))
                        .foregroundStyle(Palette.textDim)
                        .multilineTextAlignment(.center)
                    Button { Task { await load(initial: true) } } label: {
                        Text("Retry")
                            .font(Typography.app(14, .semibold))
                            .foregroundStyle(Palette.ground)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Palette.text))
                    }
                }
                .padding(.horizontal, 32)
            }
        case .loaded where messages.isEmpty && !shouldShowSetupCard:
            centered {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                        .foregroundStyle(Palette.textFaint)
                    Text("No messages yet")
                        .font(Typography.app(15, .medium))
                        .foregroundStyle(Palette.textDim)
                    Text("Agents you message, and their replies, appear here.")
                        .font(Typography.app(13))
                        .foregroundStyle(Palette.textFaint)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)
            }
        // Must sit ABOVE `case .loaded:` — Swift evaluates cases in order, so below it this
        // is unreachable. `!messages.isEmpty` is load-bearing: an EMPTY inbox showing the setup
        // card falls through to `case .loaded:` (the case above needs `!shouldShowSetupCard`),
        // and without it one keystroke would replace the only affordance telling the owner how
        // to give their agents gram with "No matches" about a list that never had rows.
        case .loaded where !search.isEmpty && !messages.isEmpty && visibleMessages.isEmpty:
            noMatches(hasOlder: inboxStore.inbox.nextCursor != nil, loadedCount: messages.count)
        case .loaded:
            ScrollViewReader { feed in
            // Given only the newest `renderLimit` messages (`feedEntries`, see
            // `WindowedBottomFeed` on why the stack is eager and windowed); older loaded ones are
            // revealed by the top sentinel without a fetch.
            WindowedBottomFeed(
                feed: feed,
                items: feedEntries,
                spacing: 0,
                showsSentinel: hasHiddenOlder || inboxStore.inbox.nextCursor != nil,
                bottomID: Self.feedBottomID,
                feedID: "gram-feed",
                messagesID: "gram-feed-messages",
                messagesValue: "\(visibleMessages.count) messages",
                column: .conversation(probe: "gram-column"),
                visibleTop: headerBottom,
                search: search,
                visibility: feedVisibility,
                appearance: $feedAppearance,
                landed: $didInitialScroll,
                anchorID: $pageAnchorID,
                newestRequest: newestToken,
                onOpen: { if !unreadRuleCaptured { captureUnreadRule() } },
                onLanded: feedLanded,
                // Read when it is ON SCREEN, once the feed has landed on the newest message.
                onRowSeen: { entry in markReadIfNeeded(entry.message) },
                onSentinelArrival: requestOlderPage,
                onBottomReached: { showingNewMessages = false },
                onLeave: { showingNewMessages = false },
                // Only while the composer is one row (see `composerAtRest`).
                followsShrink: { composerAtRest },
                // During a search the next feed waits for the reader to bring the sentinel in
                // (see the page's `onChange(of: search)`).
                armedOnReturn: { search.isEmpty },
                // Not into another search of older pages: that is bounded per arrival, and a
                // result list that fits on screen would otherwise walk the whole store.
                chainsAfterAnchor: { search.isEmpty || hasHiddenOlder },
                sentinel: { inboxSentinel },
                row: { index, entry in inboxRow(index: index, entry: entry) },
                footer: { if shouldShowSetupCard { setupCard.padding(.top, 14) } }
            )
            // Follow a NEW message in only when the reader is at the bottom or just sent it;
            // otherwise offer the "New messages" button. Keyed on the unfiltered newest
            // message, and only when it is newer than the last one, so a delete or an older
            // page never moves the reader (a search change scrolls on its own, in the feed).
            .onChange(of: feedTip) { old, new in
                guard didInitialScroll, let new, new.createdUnixMs > (old?.createdUnixMs ?? 0) else { return }
                if feedVisibility.atBottom || pendingPosts.contains(where: { $0.id == new.id }) {
                    feed.scrollTo(Self.feedBottomID, anchor: .bottom)
                } else {
                    showingNewMessages = true
                }
            }
            .overlay(alignment: .bottom) {
                if showingNewMessages {
                    Button {
                        showingNewMessages = false
                        withAnimation(.easeOut(duration: 0.25)) {
                            feed.scrollTo(Self.feedBottomID, anchor: .bottom)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 13, weight: .semibold))
                            Text("New messages")
                                .font(Typography.app(15, .semibold))
                        }
                        .foregroundStyle(Palette.text)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background(Capsule().fill(Palette.surfaceRaised))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                    .transition(.opacity)
                    .accessibilityIdentifier("gram-new-messages")
                }
            }
            // Same path as the buttons: a pull that lands inside a poll must not be
            // swallowed either.
            .refreshable { await manualRefresh() }
            }
        }
    }

    /// The inbox feed's top sentinel: the feed is oldest-first and opens at the bottom, so it
    /// comes on screen only when the reader scrolls up past the oldest loaded message, which is
    /// exactly when the next page is worth fetching (see `requestOlderPage`). A failed page says
    /// so and becomes a tap target, instead of spinning forever with nothing left to re-trigger
    /// it. During a search the same arrival searches older pages for matches
    /// (`loadOlderMatches`), and the sentinel says so; it is a tap target then too, since a
    /// result list that fits on screen cannot be scrolled to bring it in.
    private var inboxSentinel: some View {
        Button {
            // A tap retries a failed page, or searches older pages: a fresh,
            // reader-asked fetch.
            pageError = nil
            feedVisibility.pageArmed = true
            requestOlderPage()
        } label: {
            HStack(spacing: 8) {
                if let pageError {
                    GramPageFailureLabel(message: pageError)
                } else if sentinelSearchesOlder && !searchingOlder {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                    // Names both ways: a short result list cannot be scrolled.
                    // After a bounded search found nothing older: true even with
                    // matches from the newer messages shown below.
                    Text(searchedOlderWithoutMatch.map {
                        "No older matches in \($0) messages. Tap or scroll up to search further"
                    } ?? "Tap or scroll up to search older messages")
                } else {
                    ProgressView().controlSize(.small)
                    Text(sentinelSearchesOlder ? "Searching older messages…" : "Loading older messages…")
                }
            }
            .font(Typography.app(12))
            .foregroundStyle(Palette.textFaint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .disabled(pageError == nil && !(sentinelSearchesOlder && !searchingOlder))
        .accessibilityIdentifier("gram-loading-older")
    }

    /// One inbox feed row with what draws above it: its time separator and the unread rule.
    private func inboxRow(index: Int, entry: GramFeedEntry) -> some View {
        GramFeedRow(index: index, entry: entry) {
            GramRow(
                message: entry.message,
                isDownloadingFile: downloadingFileFor == entry.message.id,
                downloadProgress: downloadingFileFor == entry.message.id ? downloadBytes : nil,
                // Not before the feed has landed on the newest message: the
                // first layout passes through the top rows, never seen.
                feedLanded: didInitialScroll,
                visibleTop: headerBottom,
                appearance: feedAppearance,
                isSaved: savedGrams.isSaved(entry.message.id),
                expandedSegments: expandedTexts[entry.id] ?? [],
                fontScale: uiFontScale,
                onOpenFile: { openFile(id: entry.message.id, expectedBytes: Self.expectedReplyBytes(for: entry.message.file?.size ?? 0)) },
                onSaveFile: { saveFile(id: entry.message.id, expectedBytes: Self.expectedReplyBytes(for: entry.message.file?.size ?? 0)) },
                onCancelDownload: { cancelDownload(id: entry.message.id) },
                onPrefetchImage: { await prefetchImage(entry.message) },
                onToggleSave: { savedGrams.toggle(entry.message) },
                onDelete: { delete(entry.message) },
                onSetExpanded: { segment, open in setExpanded(entry.id, segment: segment, open) },
                startsGroup: entry.startsGroup,
                endsGroup: entry.endsGroup,
                localMachine: localMachine
            )
            // A page render (a keystroke, a poll, another file's progress) skips
            // every row whose inputs are unchanged (`GramRow.==`).
            .equatable()
        }
    }

    private static let feedBottomID = "gram-feed-bottom"

    private func centered<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        VStack { Spacer(); inner(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The one-liner an agent runs to install the gram skill (from the fork's raw URL).
    private static let setupCommand =
        "curl -fsSL https://raw.githubusercontent.com/jerryfane/herdr/master/"
        + "skills/herdrup-gram-skill/SKILL.md --create-dirs "
        + "-o ~/.claude/skills/herdrup-gram-skill/SKILL.md"

    /// Show the "set up gram" card until an agent has actually messaged (proof the
    /// skill is in use) or the owner dismisses it.
    ///
    /// Reads the LOADED window on purpose, now that the window is a page. The store that
    /// most needs this card is the one where no agent ever replied, and requiring every
    /// page to be loaded would hide it there until the reader scrolled to the end. An
    /// agent reply sitting in an older page only costs a card that is one tap to
    /// dismiss; suppressing the card costs the reader the only instructions there are.
    private var shouldShowSetupCard: Bool {
        !setupCardDismissed && !messages.contains(where: \.isFromAgent)
    }

    /// A dismissable card teaching the owner how to give their agents the gram skill:
    /// the install command + a Copy button. Auto-hides once an agent messages.
    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Set up gram for your agents")
                        .font(Typography.app(15, .semibold))
                        .foregroundStyle(Palette.text)
                    Text("Paste this to your agents so they can message you here.")
                        .font(Typography.app(13))
                        .foregroundStyle(Palette.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button { setupCardDismissed = true } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textFaint)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Palette.surfaceRaised))
                }
            }
            Text(Self.setupCommand)
                .font(Typography.machine(11))
                .foregroundStyle(Palette.textDim)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.groundMachine))
            Button {
                UIPasteboard.general.string = Self.setupCommand
                setupCommandCopied = true
            } label: {
                Text(setupCommandCopied ? "Copied ✓" : "Copy command")
                    .font(Typography.app(13, .semibold))
                    .foregroundStyle(Palette.ground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Palette.text))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.hairline, lineWidth: 1))
    }

    // MARK: - Composer

    /// The agent terminal's composer (`TerminalHomeView.replyBar`): one card holding the
    /// field, the paperclip, the mic and saved prompts, with send taking the saved-prompts
    /// place once there is something to send; same paddings. Mirrored rather than shared:
    /// the terminal's controls are woven into its own send, Ctrl and collapse state in
    /// HerdrApp.swift, so a common builder would have to change the terminal's behaviour.
    ///
    /// The recipient is in the text (mock D): "@name" sends to one agent, no "@" goes to the
    /// shared queue (`GramMention`, `draftAddress`). While an "@" is being typed at the caret,
    /// the matching agents are listed above the card; the addressing mention is drawn in the
    /// brand colour in the field. A draft that cannot be addressed (a leading "@" naming no
    /// agent, or a typed name several agents share) says why above the card and cannot be sent.
    @ViewBuilder
    private var composer: some View {
        let address = draftAddress
        let matches = mentionMatches
        VStack(spacing: 0) {
            if matches.isEmpty, let hint = Self.hint(for: address.route) {
                Text(hint)
                    .font(Typography.app(12, .semibold))
                    .foregroundStyle(Palette.waiting)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .accessibilityIdentifier("gram-composer-hint")
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHintHeight = $0 }
                    .onDisappear { composerHintHeight = 0 }
            }
            AdaptiveComposer(
                text: draft,
                isFocused: composerFocused,
                hasAccessory: !attachedFiles.isEmpty,
                showsLeading: composerKeyboard.isVisible && composerFocused,
                isRecording: draftDictating
            ) { editorHeight in
                ComposerTextField(
                    text: $draft,
                    isEnabled: !draftDictating,
                    isFocused: composerFocused,
                    onFocusChange: { composerFocused = $0 },
                    placeholder: "Queue, or @ an agent…",
                    accessibilityIdentifier: "gram-composer-input",
                    capitalization: .sentences,
                    autocorrection: .default,
                    onCommandReturn: {
                        guard canSend else { return }
                        Task { await send() }
                    },
                    fixedHeight: editorHeight,
                    accentRanges: address.accent.map { [NSRange($0, in: draft)] } ?? [],
                    onSelectionChange: { offset, length in
                        let fromEnd = max(0, length - offset)
                        if fromEnd != draftCaretFromEnd { draftCaretFromEnd = fromEnd }
                    }
                )
                .frame(minWidth: 0, maxWidth: .infinity)
            } accessory: {
                if !attachedFiles.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(attachedFiles) { file in attachmentChip(file) }
                        }
                        .padding(.horizontal, 7)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            } leading: {
                Button {
                    composerFocused = false
                } label: {
                    ComposerActionIcon(image: Image("ComposerKeyboard"))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Collapse keyboard")
            } actions: {
                HStack(spacing: 4) {
                    ComposerAttachButton(busy: loadingPhoto) { showAttachSheet = true }
                        .disabled(sending || loadingPhoto)
                        .accessibilityIdentifier("gram-attach-button")
                    MicButton(text: $draft, recording: $draftDictating)
                        .fixedSize()
                        .disabled(sending || loadingPhoto)
                    if !hasDraftContent {
                        SavedPromptsMenu { prompt in
                            draft = prompt.text
                            Task { await send() }
                        }
                        .disabled(sending || loadingPhoto || draftDictating)
                        .accessibilityIdentifier("gram-saved-prompts")
                    } else {
                        Button {
                            Task { await send() }
                        } label: {
                            ComposerActionIcon(image: Image("ComposerSend"), primary: true, busy: sending,
                                               progress: uploader.sendProgress(attachedFiles, sending: sending))
                        }
                        .disabled(!canSend)
                        .fixedSize()
                        .accessibilityLabel("Send gram")
                        .accessibilityIdentifier("gram-send-button")
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }
                .buttonStyle(.plain)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerCardHeight = $0 }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .background(Palette.ground)
        // The @-mention list floats 8 pt above the composer, over the feed, without moving it.
        .overlay(alignment: .topLeading) {
            if !matches.isEmpty {
                mentionList(matches)
                    .padding(.leading, 12)
                    .alignmentGuide(.top) { $0[.bottom] + 8 }
            }
        }
        // A pick holds only while the draft's addressing mention still names that agent.
        .onChange(of: draft) { _, text in
            guard let picked = pickedAgent else { return }
            let named = GramMention.resolve(text, knownNames: mentionNames).recipient
            if named?.caseInsensitiveCompare(picked.name) != .orderedSame { pickedAgent = nil }
        }
    }

    /// Mock D's list: "Send to one agent", the agents matching the "@" being typed (avatar,
    /// name, machine), and the reminder that no "@" means the shared queue.
    private func mentionList(_ agents: [GramAgent]) -> some View {
        let shared = sharedNames
        return VStack(alignment: .leading, spacing: 0) {
            Text("Send to one agent")
                .font(Typography.app(12, .semibold))
                .foregroundStyle(Palette.textDim)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 4)
            ForEach(agents) { agent in
                Button { pickMention(agent) } label: {
                    HStack(spacing: 12) {
                        GramAvatar(name: agent.from, size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: agentTitle(agent, shared: shared))
                                .font(Typography.app(15, .semibold))
                                .foregroundStyle(Palette.text)
                            if let machine = agent.machine, !shared.contains(agent.name.lowercased()) {
                                Text(verbatim: machine)
                                    .font(Typography.app(13))
                                    .foregroundStyle(Palette.textDim)
                            }
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("gram-mention-\(agentKey(agent, shared: shared))")
            }
            Text("No @ and it goes to the shared queue.")
                .font(Typography.app(13))
                .foregroundStyle(Palette.textDim)
                .padding(.horizontal, 16)
                .padding(.top, 9)
                .padding(.bottom, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
                .padding(.top, 4)
        }
        .padding(.vertical, 6)
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: 18).fill(Palette.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 17, y: 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gram-mention-list")
    }

    /// The bare names an "@" can address: the agents seen in Gram, once each. Two agents may
    /// share one; `draftAddress` tells them apart.
    private var mentionNames: [String] {
        var seen = Set<String>()
        return gramAgents.map(\.name).filter { seen.insert($0.lowercased()).inserted }
    }

    /// Bare names (lowercased) that more than one agent in Gram carries.
    private var sharedNames: Set<String> {
        var seen = Set<String>()
        var shared = Set<String>()
        for agent in gramAgents where !seen.insert(agent.name.lowercased()).inserted {
            shared.insert(agent.name.lowercased())
        }
        return shared
    }

    /// An agent's row title: its name, with its machine when another agent has the same name
    /// ("clientloop · hetzner-1").
    private func agentTitle(_ agent: GramAgent, shared: Set<String>) -> String {
        guard shared.contains(agent.name.lowercased()) else { return agent.name }
        return "\(agent.name) · \(agent.machine ?? "this device")"
    }

    /// A row's identifier suffix: the bare name, or the full sender ID when the name is shared.
    private func agentKey(_ agent: GramAgent, shared: Set<String>) -> String {
        shared.contains(agent.name.lowercased()) ? agent.from : agent.name
    }

    /// The field's caret in `draft`; nil (the end) when the offset is not a character boundary.
    private var draftCaret: String.Index? {
        let utf16 = draft.utf16
        let offset = min(utf16.count, max(0, utf16.count - draftCaretFromEnd))
        guard let index = utf16.index(utf16.startIndex, offsetBy: offset, limitedBy: utf16.endIndex)
        else { return nil }
        return index.samePosition(in: draft)
    }

    /// Every agent matching the "@" being typed at the caret, names starting with the query
    /// first; empty when no "@" is being typed there (or nothing matches).
    private var mentionMatches: [GramAgent] {
        guard let active = GramMention.activeQuery(in: draft, cursor: draftCaret) else { return [] }
        let query = active.query.lowercased()
        guard !query.isEmpty else { return gramAgents }
        let starting = gramAgents.filter { $0.name.lowercased().hasPrefix(query) }
        let containing = gramAgents.filter {
            !$0.name.lowercased().hasPrefix(query) && $0.name.lowercased().contains(query)
        }
        return starting + containing
    }

    /// Replaces the "@" being typed at the caret with the picked agent's "@name ", and binds
    /// the mention to that exact agent. The field keeps the caret's distance from the end, so
    /// it lands after the inserted name.
    private func pickMention(_ agent: GramAgent) {
        guard let active = GramMention.activeQuery(in: draft, cursor: draftCaret) else { return }
        draft = GramMention.complete(draft, replacing: active.range, with: agent.name)
        pickedAgent = agent
    }

    /// Where the draft goes.
    private enum DraftRoute {
        /// No mention: the shared queue.
        case queue
        /// One agent, by its exact sender ID.
        case agent(GramAgent)
        /// A typed name several agents share and none was picked for.
        case ambiguous(String)
        /// A leading "@token" that names no agent in Gram ("" for a bare "@").
        case unknown(String)
    }

    private struct DraftAddress {
        let route: DraftRoute
        /// What is posted: the text with a leading addressing mention taken off.
        let body: String
        /// The addressing mention starts the draft (so `body` lacks it).
        let leading: Bool
        /// The addressing mention's range in the draft, drawn in the brand colour; nil unless
        /// the route is one agent.
        let accent: Range<String.Index>?
    }

    /// Where the draft goes and what it says (`GramMention.resolve`). The first known mention
    /// addresses it: the agent picked for it, or the one agent with that name; a name several
    /// agents share and nobody picked is ambiguous. A leading "@token" that names no agent is
    /// never quietly sent to the shared queue (its files could be secrets). No mention at all:
    /// the shared queue.
    private var draftAddress: DraftAddress {
        let names = mentionNames
        let resolved = GramMention.resolve(draft, knownNames: names)
        let leading = resolved.recipient != nil && resolved.body != draft
        if let token = GramMention.leadingToken(in: draft), !leading {
            return DraftAddress(route: .unknown(token), body: resolved.body, leading: false, accent: nil)
        }
        guard let name = resolved.recipient else {
            return DraftAddress(route: .queue, body: resolved.body, leading: false, accent: nil)
        }
        let route: DraftRoute
        if let picked = pickedAgent, picked.name.caseInsensitiveCompare(name) == .orderedSame {
            route = .agent(picked)
        } else {
            let named = gramAgents.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            route = named.count == 1 ? .agent(named[0]) : .ambiguous(name)
        }
        var accent: Range<String.Index>?
        if case .agent = route { accent = GramMention.ranges(in: draft, knownNames: names).first }
        return DraftAddress(route: route, body: resolved.body, leading: leading, accent: accent)
    }

    /// Why the draft cannot be sent as it stands, if it cannot.
    private static func hint(for route: DraftRoute) -> String? {
        switch route {
        case .queue, .agent: return nil
        case .ambiguous(let name): return "Several agents are called \(name): pick one"
        case .unknown(let token):
            return token.isEmpty ? "Pick an agent after @" : "No agent called @\(token) in Gram"
        }
    }

    /// Whether the draft goes to `agent` (by sender ID), or with nil to the shared queue.
    private func isAddressed(_ agent: GramAgent?) -> Bool {
        switch draftAddress.route {
        case .queue: return agent == nil
        case .agent(let addressed): return addressed.from == agent?.from
        case .ambiguous, .unknown: return false
        }
    }

    /// The pill sheet's "Write to" an agent: that exact agent addresses the draft, as "@name "
    /// at the start in place of a leading mention (or a leading "@token" naming no one).
    private func address(_ agent: GramAgent) {
        draft = GramMention.addressing(draft, to: agent.name, knownNames: mentionNames)
        pickedAgent = agent
    }

    /// The pill sheet's "Shared queue": takes off every mention that would address the
    /// draft, wherever it is, and a leading "@token" naming no one.
    private func addressQueue() {
        draft = GramMention.unaddressed(draft, knownNames: mentionNames)
        pickedAgent = nil
    }

    /// Something typed or attached: send takes the saved-prompts place.
    private var hasDraftContent: Bool {
        !attachedFiles.isEmpty || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool {
        // Also blocked while a photo is loading, so tapping Send mid-load can't fire a
        // text-only message that races the attachment in behind it, and while dictating
        // (see MicButton): sending mid-dictation would clear the field, then the next
        // recognition partial would restore the just-sent text and re-enable a duplicate.
        guard !sending, !loadingPhoto, !draftDictating else { return false }
        let address = draftAddress
        switch address.route {
        case .queue, .agent: break
        case .ambiguous, .unknown: return false
        }
        // A bare "@vetrina" has no message: the body without the mention must say something.
        return !attachedFiles.isEmpty
            || !address.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    #if DEBUG
    /// For the UI tests: the `gram.post` calls the mock transport answered, one
    /// `to=<name|queue> text=<text>` per line (`MockTransport.gramPostLogSummary`), as the
    /// LABEL of `gram-post-calls` (the GuestPaneView probes' pattern). Not the value: on the
    /// iPhone tab an element with an empty value reads back the tab's badge ("3").
    /// Refreshed after each send. Beside it, `gram-opened-file`: "opened:<name>" once a file
    /// reached a viewer, "none" before; `gram-get-file-calls`: the mock's `gram.get_file`
    /// calls per id (`MockTransport.gramGetFileSummary`); `gram-list-pages`: how many older
    /// pages (`before_id` requests) the paged mock answered; and `gram-row-renders`
    /// (`GramRowRenderProbe`).
    private var postCallsProbeView: some View {
        ZStack {
            Color.clear
                .accessibilityElement()
                .accessibilityIdentifier("gram-get-file-calls")
                .accessibilityLabel(getFileProbe.isEmpty ? "none" : getFileProbe)
            Color.clear
                .accessibilityElement()
                .accessibilityIdentifier("gram-post-calls")
                .accessibilityLabel(postCallsProbe.isEmpty ? "none" : postCallsProbe)
            Color.clear
                .accessibilityElement()
                .accessibilityIdentifier("gram-opened-file")
                .accessibilityLabel(openedFileProbe.isEmpty ? "none" : openedFileProbe)
            Color.clear
                .accessibilityElement()
                .accessibilityIdentifier("gram-list-pages")
                .accessibilityLabel("\(listPagesProbe)")
            GramRowRenderProbe()
        }
        .frame(width: 1, height: 1)
        .allowsHitTesting(false)
        .task {
            guard ScreenshotMock.mode != nil else { return }
            while !Task.isCancelled {
                let summary = MockTransport.gramGetFileSummary
                if summary != getFileProbe { getFileProbe = summary }
                let pages = GramPagingMock.shared.pageRequests
                if pages != listPagesProbe { listPagesProbe = pages }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }
    #endif

    private func attachmentChip(_ file: ComposerAttachment) -> some View {
        // A file still uploading can go: removing it cancels its upload. Only a send in
        // flight holds the strip, so the batch it is delivering stays whole.
        ComposerAttachmentChip(
            name: file.name, size: file.size, isImage: file.isImage,
            state: attachmentState(file), canRemove: !sending,
            onRemove: { removeAttachment(file.id) },
            onRetry: { uploader.retry(file.id) }
        )
        .accessibilityIdentifier("gram-attachment")
    }

    private func attachmentState(_ file: ComposerAttachment) -> ComposerAttachmentState {
        .for(file, upload: uploader.phase(of: file.id), sending: sending,
             sendingID: sendingAttachmentID, failedID: failedAttachmentID)
    }

    private func removeAttachment(_ id: UUID) {
        guard let current = attachedFiles.first(where: { $0.id == id }) else { return }
        attachedFiles.removeAll { $0.id == id }
        // Cancels a running upload, deletes the staged bytes, and discards a finished upload.
        uploader.remove(current)
    }

    // MARK: - Actions

    /// Load once, then poll while the page is visible so a new agent message appears
    /// without a manual refresh (the gram store has no event stream). Backs off when
    /// the server can't serve gram (a pre-deploy daemon), so a failing `gram.list`
    /// isn't hit every few seconds. Ends when the view goes away (task cancelled).
    ///
    /// The backoff is keyed on CONSECUTIVE FAILURES, not on `phase`. Keying it on
    /// `.unavailable` stopped working once the store outlived the page: both catch
    /// arms only escalate to `.unavailable` when there is nothing to show, so a
    /// remount against a daemon that has lost gram now has a warm cache, keeps
    /// `phase == .loaded`, and would retry every 6s forever over the SSH channel the
    /// terminal shares — for exactly the case the cache was added to serve.
    private func pollLoop() async {
        await load(initial: true)
        while !Task.isCancelled {
            // `.unavailable` implies a failure, so the counter alone covers both.
            try? await Task.sleep(nanoseconds: loadFailures > 0 ? 30_000_000_000 : 6_000_000_000)
            if Task.isCancelled { break }
            await load(initial: false)
        }
    }

    /// A refresh the READER asked for: acknowledged, never dropped, and it reports the
    /// outcome truthfully.
    ///
    /// The plain `load(initial:)` was wired directly to the button, which made the
    /// control look dead in two ways. It returns early when a load is already running —
    /// and with a 6s ambient poll a tap often lands inside one — so the tap did nothing;
    /// and on an unchanged store it returns without altering a pixel, so a successful
    /// refresh was indistinguishable from a broken button.
    private func manualRefresh() async {
        if isLoading {
            // Run it after the in-flight load rather than discarding it, and say so now,
            // because the whole point is that a tap is never silently swallowed.
            refreshQueued = true
            acknowledge("Refreshing…", expiring: false)
            return
        }
        manualRefreshing = true
        defer { manualRefreshing = false }
        switch await load(initial: false) {
        case .unchanged: acknowledge("Up to date")
        case .updated: acknowledge("Refreshed")
        case .failed: acknowledge(nil)   // `load` already wrote the failure to refreshNote
        }
    }

    /// Show a manual-refresh acknowledgement in ITS OWN slot.
    ///
    /// Not `refreshNote`: `load` clears that on every success, including every 6s poll,
    /// so an acknowledgement put there survives only until the next poll — measured as a
    /// median 3.2s but as little as 0.16s depending on where the tap lands in the cycle,
    /// which is the same "dead button" impression this set out to remove. This file
    /// already established the pattern twice, for `markAllNote` and `pageError`, both of
    /// which were given their own slots for exactly this reason.
    ///
    /// Expiry is owned by a token so a later acknowledgement cannot be cleared by an
    /// earlier one's timer.
    private func acknowledge(_ text: String?, expiring: Bool = true) {
        refreshAck = text
        guard let text, expiring else { return }
        refreshAckToken += 1
        let token = refreshAckToken
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if refreshAckToken == token, refreshAck == text { refreshAck = nil }
        }
    }

    /// What a load actually did, so a manual refresh can say something TRUE.
    ///
    /// Derived from the digest answer, not from a list-length delta. A delta is wrong in
    /// three real cases: at the refresh ceiling (a reader holding 500 gets the newest 500,
    /// so N arrivals push N out and the count does not move), against a concurrent
    /// server-side trim or delete (which offsets the delta to zero), and when the server
    /// first reflects the reader's own optimistic post (which would report "1 new message"
    /// about their own text).
    private enum LoadOutcome { case unchanged, updated, failed }

    @discardableResult
    private func load(initial: Bool) async -> LoadOutcome {
        // One load at a time: overlapping loads would race each other.
        guard !isLoading else { return .unchanged }
        isLoading = true
        defer {
            isLoading = false
            // A tap that arrived mid-load is honoured now rather than lost.
            if refreshQueued {
                refreshQueued = false
                Task { await manualRefresh() }
            }
        }
        // A warm cache means there is something to render RIGHT NOW, so leave
        // `.loading` before touching the network.
        //
        // `phase` is `@State`, and on iPad this page is rebuilt inside the detail
        // column's `switch selectedTab` — the same destruction that motivated moving
        // the messages out of the view. So the phase resets to `.loading` on every
        // section switch, and merely declining to SET `.loading` (as this guard used
        // to) could not help: it was already `.loading` from the initialiser, and the
        // spinner rendered over a list that was already in hand. The cache saved the
        // bytes and none of the latency, which was the whole point.
        //
        // This also stops a failed refresh from spinning forever: both catch arms
        // below escalate to `.unavailable` only when there is nothing to show, and
        // otherwise leave `phase` alone — which, before this line, meant `.loading`
        // for good, with a "Showing the last loaded messages" banner above an empty
        // spinner and no Retry.
        if inboxStore.inbox.hasLoaded, phase == .loading { phase = .loaded }
        if initial && !inboxStore.inbox.hasLoaded && messages.isEmpty { phase = .loading }
        do {
            // Conditional on the digest we hold. An unchanged store answers in a few
            // hundred bytes; only a real change ships the list.
            //
            // The limit COVERS WHAT IS LOADED, not just the first page. A changed answer
            // replaces the list (see GramInbox.apply — a head page says nothing about
            // what is older), so asking for one page would collapse a reader 200 rows
            // deep back to 40 every time a message arrived, and the sentinel would then
            // walk them down again one page at a time. Refreshing the whole window keeps
            // their place and still costs a fraction of the store; beyond the daemon's
            // own clamp there is nothing to gain by asking for more.
            // Reads confirmed while this request is out stay read (`GramInbox.apply`).
            let readStamp = inboxStore.inbox.readStamp
            let answer = try await client.gramList(
                ifUnchangedDigest: inboxStore.inbox.conditionalDigest,
                limit: min(max(Self.pageSize, inboxStore.inbox.messages.count),
                           Self.maxRefreshLimit))
            let changed = inboxStore.inbox.apply(answer, readStamp: readStamp)
            // A saved copy whose file the store has since expired stops offering it.
            savedGrams.expireFiles(in: answer.messages ?? [])
            phase = .loaded
            refreshNote = nil
            loadFailures = 0
            // Nothing moved: the reconciliation below would compute the same result
            // from the same list, so skip it (the common case on a 6s poll).
            guard changed || !answer.isUnchanged else { return .unchanged }
            // Keep the tab badge in step with what we just loaded.
            unread?.count = inboxStore.inbox.unreadCount
            // Drop optimistic posts the server now reflects; unconfirmed ones stay
            // visible via `messages` (gram.post writes synchronously, so any in-flight
            // load started BEFORE a post can no longer discard it).
            let serverIDs = Set(inboxStore.inbox.messages.map(\.id))
            pendingPosts.removeAll { serverIDs.contains($0.id) }
            // Retire delete-tombstones the server has confirmed gone; keep only those
            // it still returns (a poll that raced the delete), which stay suppressed.
            deletedIDs.formIntersection(serverIDs)
            return .updated
        } catch let error as APIError where error.code == "gram_unavailable" {
            loadFailures += 1
            if messages.isEmpty {
                phase = .unavailable("Gram isn't available on this server yet.")
            } else {
                refreshNote = "Gram is unavailable right now."
            }
            return .failed
        } catch {
            // A daemon predating the gram build answers an unknown-method error, NOT
            // `gram_unavailable`, so a first-load failure gets one honest message
            // covering both "not deployed yet" and "couldn't reach it", plus a Retry.
            loadFailures += 1
            if messages.isEmpty {
                phase = .unavailable(
                    "Gram isn't available on this server yet, or the messages couldn't load.")
            } else {
                refreshNote = "Refresh failed. Showing the last loaded messages."
            }
            return .failed
        }
    }

    /// How many messages one page carries.
    ///
    /// 40 fills more than a screen on every idiom, so the reader never sees the
    /// sentinel do its work on the first draw, and it is small enough that the open
    /// costs a few tens of KB instead of the ~900 KB the whole store weighs. Older
    /// pages are the same size: a scroll that keeps going should keep costing the same.
    static let pageSize = 40

    /// Ceiling for the head refresh, matching the daemon's own `GRAM_LIST_MAX_LIMIT`.
    /// A reader who has paged past it keeps scrolling through the sentinel; the refresh
    /// simply stops growing.
    static let maxRefreshLimit = 500

    /// Ask for the page older than everything loaded. Driven by the sentinel at the end
    /// of the list, so it runs exactly when the reader reaches the bottom.
    ///
    /// Its own in-flight flag, NOT `isLoading`: the 6-second head poll and a page fetch
    /// answer different questions, and sharing one flag would make each starve the
    /// other precisely while the reader is scrolling. Both WAIT for each other rather
    /// than bailing: bailing left the sentinel spinning with nothing to re-trigger it.
    ///
    /// The inbox's `generation` is read BEFORE the request and handed back with the
    /// answer, so a page built on a cursor that a head replacement has since invalidated
    /// is dropped instead of landing below rows the new head no longer contains. A drop
    /// is then RETRIED here, because the cursor may not have moved — an in-place row
    /// change (a queue item being grabbed) counts as a change — and the sentinel's task
    /// is keyed on the cursor, so nothing else would re-fire.
    ///
    /// Returns whether the loaded list actually grew, so a search looping over older pages
    /// (`loadOlderMatches`) can tell a page that landed from a stuck one.
    @discardableResult
    private func loadMore() async -> Bool {
        await waitWhile { isLoadingPage }
        guard !isLoadingPage else { return false }
        isLoadingPage = true
        defer { isLoadingPage = false }
        for _ in 0..<2 {
            await waitWhile { isLoading }
            guard let cursor = inboxStore.inbox.nextCursor else { return false }
            let generation = inboxStore.inbox.generation
            do {
                let answer = try await client.gramList(limit: Self.pageSize, beforeID: cursor)
                if inboxStore.inbox.appendPage(answer, generation: generation) {
                    savedGrams.expireFiles(in: answer.messages ?? [])
                    pageError = nil
                    return true
                }
                // Refused as stale, or an answer of ids already held. Retry once against
                // the current generation; a second miss ends the attempt without a note,
                // since nothing failed — the list simply did not grow.
                guard inboxStore.inbox.generation != generation else { return false }
            } catch {
                // A cancelled fetch is not a failure: the reader changed or cleared the
                // search (which cancels its fetch) or left. Reporting it would flash an
                // error for every keystroke.
                guard !Task.isCancelled else { return false }
                // Surfaced ON the sentinel, not in `refreshNote`: a successful head poll
                // clears that note within six seconds and the reader would be left with a
                // spinner, no message and no way to retry.
                pageError = "Couldn't load older messages."
                return false
            }
        }
        return false
    }

    /// Up to two seconds of yielding while `condition` holds. Two seconds because that
    /// is the scale of one gram round trip on the shared SSH channel; past that the
    /// caller reports rather than waits.
    private func waitWhile(_ condition: () -> Bool) async {
        for _ in 0..<20 where condition() {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// How many older pages one arrival at the top of a search's results may fetch looking
    /// for a match. The daemon has no search, so search covers the loaded messages; this
    /// bounds what reaching the top costs when the next match is far back.
    static let searchPagesPerArrival = 5

    /// During a search: fetch older pages until one adds a match, at most
    /// `searchPagesPerArrival` of them, then stop. Run by the sentinel's arrival
    /// (`loadOlderPage`) and by the "No matches in recent messages" button
    /// (`searchOlderMessages`). Returns whether a match was added.
    ///
    /// Overlap is serialised by `loadMore`, which waits for the page in flight and appends
    /// under a generation check. A search change cancels the task running this
    /// (`FeedVisibility.olderFetch`), so it stops at the next page boundary and leaves
    /// `searchingOlder` to the new query.
    private func loadOlderMatches() async -> Bool {
        let query = search
        let before = visibleMessages.count
        searchingOlder = true
        defer { if !Task.isCancelled { searchingOlder = false } }
        for _ in 0..<Self.searchPagesPerArrival {
            guard !Task.isCancelled, search == query, await loadMore() else { return false }
            if visibleMessages.count > before {
                searchedOlderWithoutMatch = nil
                return true
            }
        }
        if !Task.isCancelled, search == query { searchedOlderWithoutMatch = messages.count }
        return false
    }

    /// The "No matches in recent messages" button: the same bounded search of older pages.
    /// The feed is not on screen, so this owns the fetch itself; a match brings the feed
    /// back, which opens at the newest match.
    private func searchOlderMessages() {
        guard !searchingOlder else { return }
        pageError = nil
        feedVisibility.olderFetch?.cancel()
        feedVisibility.olderFetch = Task { @MainActor in
            guard await loadOlderMatches(), !Task.isCancelled else { return }
            renderLimit = max(renderLimit, visibleMessages.count)
        }
    }


    private func send() async {
        let address = draftAddress
        let text = address.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachedFiles
        // Capture the destination BEFORE any await. Otherwise the draft's "@name" could
        // change mid-upload and a file (possibly a secret) would post to a different agent
        // than the one addressed when Send was tapped. The field is also disabled while
        // sending, but capturing is the real guarantee. A draft that names no agent, or
        // names several, is never sent (to the shared queue or anywhere).
        let to: String?
        switch address.route {
        case .queue: to = nil
        case .agent(let agent): to = agent.from
        case .ambiguous, .unknown: return
        }
        // A file with no caption is fine; an empty text-only message is not.
        guard (!text.isEmpty || !files.isEmpty), !sending else { return }
        sending = true
        // Drop the keyboard the moment the message is committed, so the composer
        // stops covering the tab bar (the field has no Return-to-send to resign it).
        composerFocused = false
        defer {
            sending = false
            sendingAttachmentID = nil
            #if DEBUG
            postCallsProbe = MockTransport.gramPostLogSummary
            #endif
        }
        sendError = nil
        failedAttachmentID = nil

        // Text-only: the unchanged single-message path.
        guard !files.isEmpty else {
            do {
                let posted = try await client.gramPost(text: text, to: to)
                draft = ""
                pendingPosts.removeAll { $0.id == posted.id }
                pendingPosts.insert(posted, at: 0)
            } catch let error as APIError {
                sendError = error.message
            } catch {
                sendError = "Couldn't send. Try again."
            }
            return
        }

        // One post per file (the wire is one-file-per-message), through the shared
        // `GramAttachmentSender`. Each file has been uploading since it was added
        // (`uploader`): the ones that landed post at once, the rest are awaited. The text
        // rides as the FIRST file's caption; the rest post with no text. `draft` is
        // cleared the instant that first message posts, so a retry of the remaining files
        // never re-sends the caption onto a different file.
        let captionID = files.first?.id
        let sender = uploader.sender(client: client, into: $attachedFiles, post: { file, attachment in
            let posted = try await client.gramPost(
                text: file.id == captionID ? text : "", to: to, attachment: attachment)
            // Optimistic: kept in `pendingPosts`, so a concurrent poll's snapshot
            // cannot drop it; de-duped by id, reconciled once the server reflects it.
            pendingPosts.removeAll { $0.id == posted.id }
            pendingPosts.insert(posted, at: 0)
            if file.id == captionID { draft = "" }
            return posted.id
        })
        let result = await sender.send(files, sending: { sendingAttachmentID = $0.id }) { file in
            guard let index = attachedFiles.firstIndex(where: { $0.id == file.id }) else { return }
            attachedFiles[index] = file
        }
        // Keep only the not-yet-sent files staged, so a failure leaves the rest ready
        // for a one-tap retry (the failed file keeps its upload id, so the retry posts
        // the bytes already uploaded); a full success clears the strip. Already-sent
        // messages are live and are not rolled back.
        let posted = Set(attachedFiles.filter { $0.messageID != nil }.map(\.id))
        attachedFiles.removeAll { posted.contains($0.id) }
        // Each post consumed its upload: nothing left on the host to discard.
        uploader.forget(posted)
        if case .failure(let failure) = result {
            failedAttachmentID = failure.attachment.id
            let reason: String
            if let error = failure.error as? APIError {
                // A post still refused after the sender's retries means the daemon has
                // not reaped the upload connection at all. The bytes are staged and
                // complete, so this is a retry rather than a failure — but the raw
                // daemon sentence ("read the upload connection to EOF") would be
                // meaningless to the owner.
                reason = error.code == "upload_in_progress"
                    ? "Still finishing the last upload. Tap Send again."
                    : error.message
            } else {
                reason = "Couldn't send. Try again."
            }
            sendError = failure.note(reason)
        }
    }

    /// Open a message's file, downloading it only the FIRST time.
    ///
    /// A gram message is immutable, so its id names one set of bytes forever. Before
    /// this, every open re-fetched them over SSH — the page's cleanup deleted the temp
    /// file on dismissal, so reopening a large attachment made the reader wait through
    /// the whole transfer again for a file the device had already received. A cache hit
    /// now presents immediately and touches the network not at all.
    ///
    /// `expectedBytes` comes from the ROW, not from a lookup: the Saved tab is local
    /// and outlives the server copy, so resolving a size through the inbox returned nil
    /// for exactly the rows the saved bar was added for. Each caller passes the size it
    /// already renders.
    private func openFile(id: String, expectedBytes: Int? = nil) {
        guard downloadingFileFor == nil else { return }

        // CACHE HIT: no task, no spinner, no request. Presented synchronously so the
        // reader sees the file on the same frame as the tap.
        //
        // The bytes are read ONLY when a viewer needs them. QuickLook takes the cached
        // file by URL, so reading it here would pull a whole video into memory on the
        // main actor and then discard it — the exact case this feature exists to make
        // fast. Markdown and web documents do need the bytes, and the routing decision
        // needs only the name and the stored mime.
        if let hit = Downloads.cached(id: id) {
            if GramPreviewRouter.needsBytes(name: hit.name, mime: hit.mime) {
                guard let data = try? Data(contentsOf: hit.url, options: .mappedIfSafe) else {
                    sendError = "Couldn't open the file."
                    return
                }
                present(data: data, name: hit.name, mime: hit.mime, cachedAt: hit.url)
            } else {
                // nil bytes: QuickLook opens the cached file itself.
                present(data: nil, name: hit.name, mime: hit.mime, cachedAt: hit.url)
            }
            return
        }

        // The download is the connection's, not this page's (#574): it runs on through a
        // switch to Agents and lands in the cache; the page only waits on it.
        guard downloads.start(id: id, purpose: .open, expectedBytes: expectedBytes, transfer: transfer(id)) else { return }
        followHeldDownload()
    }

    /// Waits on the reader's open or save and finishes it here when it lands: presents the
    /// file, or hands it to the export picker. Run when the reader starts one and again each
    /// time the page comes on screen, so a download started before a switch to Agents has
    /// its ring back and opens when it lands (#574). Going off screen ends the WAIT, never
    /// the download: one that lands while the reader is away is simply in the cache, and
    /// the next tap opens it at once; one that failed meanwhile is reported on return.
    private func followHeldDownload() {
        if let failure = downloads.takeFailure() {
            reportDownloadFailure(failure.error, purpose: failure.purpose)
        }
        guard let held = downloads.held else { return }
        heldWait?.cancel()
        let wait = downloads.join(id: held.id)
        // Captured before the wait: a disconnect that wipes the cache meanwhile bumps it,
        // and the export below must not write the payload back to disk after sign-out.
        let epoch = Downloads.currentEpoch
        heldWait = Task {
            do {
                // Reserve before scheduling this task: even an immediate cache fill
                // must deliver the requested open/save to the active page.
                guard let fetched = try await wait() else { return }
                // The page went off screen as it landed: present nothing over another tab.
                if Task.isCancelled { return }
                switch held.purpose {
                case .open:
                    present(data: fetched.data, name: fetched.name, mime: fetched.mime, cachedAt: fetched.cached?.url)
                case .save:
                    try stageExport(name: fetched.name, data: fetched.data, epoch: epoch)
                }
            } catch is CancellationError {
                // The page went off screen, or the download was cancelled: nothing to report.
            } catch {
                reportDownloadFailure(error, purpose: held.purpose)
            }
        }
    }

    private func reportDownloadFailure(_ error: Error, purpose: GramDownloadStore.Purpose) {
        let verb = purpose == .open ? "open" : "save"
        if let error = error as? APIError {
            sendError = "Couldn't \(verb) the file: \(error.message)"
        } else {
            sendError = "Couldn't \(verb) the file."
        }
    }

    /// Show already-held bytes in the right viewer (`GramPreviewRouter`). Shared by the
    /// cache-hit and post-download paths so both render a markdown or web document
    /// identically. `cachedAt` is the cache entry for the ORIGINAL bytes when one exists.
    @MainActor
    private func present(data: Data?, name: String, mime: String = "", cachedAt: URL? = nil) {
        #if DEBUG
        openedFileProbe = "opened:\(name)"
        #endif
        do {
            preview = try GramPreviewRouter.preview(data: data, name: name, mime: mime, cachedAt: cachedAt)
        } catch {
            sendError = "Couldn't open the file."
        }
    }

    /// Download a file and hand it to the system document-export picker, which saves it
    /// to a real, user-chosen location (Finder ~/Documents / ~/Downloads on Mac, Files
    /// on iOS). Unlike QuickLook's "Save to Files", this does not land in the hidden
    /// app-sandbox container on Mac, so the saved file is where the owner expects it.
    private func saveFile(id: String, expectedBytes: Int? = nil) {
        guard downloadingFileFor == nil else { return }

        // Already downloaded once: export from the cache rather than fetching the same
        // bytes again. The picker needs its own copy under the file's real name, so the
        // cached file is COPIED into a per-export dir — the export must not hand the
        // picker a file that eviction can delete underneath it.
        if let hit = Downloads.cached(id: id) {
            do {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let fileURL = dir.appendingPathComponent(hit.name)
                try FileManager.default.copyItem(at: hit.url, to: fileURL)
                exportFile = ExportFile(url: fileURL, dir: dir)
                return
            } catch {
                // Fall through to a fresh download rather than failing the save.
            }
        }

        // The connection's download, as an open's (#574); `followHeldDownload` exports it.
        guard downloads.start(id: id, purpose: .save, expectedBytes: expectedBytes, transfer: transfer(id)) else { return }
        followHeldDownload()
    }

    /// Hands downloaded bytes to the export picker under the file's real name.
    private func stageExport(name: String, data: Data, epoch: Int) throws {
        // The SAME window the epoch exists for applies to the export copy: the bytes can
        // land after disconnect() wiped the cache but before the wait is cancelled. Writing
        // the export dir then would leave the whole payload on disk after sign-out — the
        // cache guard alone does not cover it.
        guard Downloads.currentEpoch == epoch else { return }
        // A per-export temp dir so the file keeps its real name (the picker uses the
        // file's own name) without colliding with the preview temp file.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent(GramStaging.safeFileName(name))
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        exportFile = ExportFile(url: fileURL, dir: dir)
    }

    /// The reader's cancel of their own open or save (the message's menu): the transfer
    /// ends, and the next open starts afresh.
    private func cancelDownload(id: String) {
        downloads.cancel(id: id)
    }

    /// The message's file from the daemon, stored in the download cache. Run by the
    /// connection's `GramDownloadStore` as the ONE transfer for that id: an open, a save and
    /// the image prefetch of the same file share it, and its progress draws on the card
    /// while the reader's own open or save of this id runs. Captures the client, never the
    /// page: it outlives the page.
    private func transfer(_ id: String) -> GramDownloadStore.Transfer {
        let client = client
        return { report in
            let epoch = Downloads.currentEpoch
            let (name, mime, data) = try await client.gramGetFile(id: id, onBytesReceived: report)
            // Cancelled (the reader's cancel, the session's end, or the last prefetch
            // scrolled away): stop before writing any file, so a late completion can't
            // strand one.
            try Task.checkCancellation()
            // Keep the bytes for next time. A failure here is not an error: an open
            // proceeds from a temp file and the next open simply downloads again. Written
            // OFF the main actor: a camera-size picture is megabytes, and writing it here
            // stalled the feed's scrolling. `store` checks the epoch before and after.
            let cached = await Task.detached(priority: .userInitiated) {
                Downloads.store(data, id: id, name: name, mime: mime, epoch: epoch)
            }.value
            return (name, mime, data, cached)
        }
    }

    /// Fetch an image attachment into the download cache so its card shows the picture
    /// before the owner opens it; the card decodes it from there (`GramRow.loadThumbnail`).
    /// Called by the card while it is on screen, and cancelled with it.
    ///
    /// The rules (`GramImagePreview`): images only, none over the size cap (those keep the
    /// placeholder until opened), at most two at once. It never takes `downloadingFileFor`,
    /// so an open or save of any file is never refused or delayed by it, and an open of
    /// this image while it runs adopts its transfer (`GramDownloadStore`) rather than starting one.
    private func prefetchImage(_ message: GramMessage) async {
        guard let file = message.file, GramImagePreview.shouldPrefetch(file),
              await Self.cachedOffMain(message.id) == nil
        else { return }
        do {
            try await prefetchSlots.acquire()
        } catch {
            return   // scrolled away while queued
        }
        defer { prefetchSlots.release() }
        // An open may have cached it while this waited for a slot.
        guard await Self.cachedOffMain(message.id) == nil else { return }
        // A failure leaves the placeholder; a tap still opens normally.
        _ = try? await downloads.fetch(id: message.id, transfer: transfer(message.id))
    }

    /// `Downloads.cached` reads the file's metadata from disk: off the main thread on paths
    /// that run while the reader scrolls.
    nonisolated static func cachedOffMain(_ id: String) async -> CachedGramFile? {
        await Task.detached(priority: .userInitiated) { Downloads.cached(id: id) }.value
    }

    /// The reply size to expect for a file of `size` bytes, in WIRE bytes: base64
    /// inflates it by 4/3 and the JSON envelope adds a few hundred.
    static func expectedReplyBytes(for size: UInt64) -> Int? {
        guard size > 0 else { return nil }
        return Int(Double(size) * 4.0 / 3.0) + 512
    }

    /// Downloaded gram files, kept so a second open does not re-fetch over SSH.
    ///
    /// In CACHES, not `temporaryDirectory`, and that distinction is the feature: the
    /// page's cleanup unlinks temp files on dismissal, which is exactly why reopening a
    /// file downloaded it again. Caches survives the page, is excluded from backup by
    /// the system, and may be purged under storage pressure — a purge costs one
    /// re-download, never correctness.
    ///
    /// The work is `HerdrKit.GramFileCache`'s, not this file's, for the same reason
    /// staging is: this target cannot run on CI, and a cache that never hits is
    /// invisible — the open still works, it is merely slow again.
    enum Downloads {
        static let root: URL = {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            return base.appendingPathComponent("gram-downloads", isDirectory: true)
        }()

        static func cached(id: String) -> CachedGramFile? {
            GramFileCache.cached(id: id, in: root)
        }

        /// Session epoch. Sign-out bumps it BEFORE wiping, and a store carrying a stale
        /// epoch is refused — see `invalidate()` for why that is needed.
        private static let lock = NSLock()
        private static var epoch = 0

        static var currentEpoch: Int { lock.withLock { epoch } }

        /// Store bytes downloaded during `epoch`. Refused when the session has ended
        /// since, and re-checked AFTER the write, because `disconnect()` can wipe the
        /// root while this is mid-flight and a late write would otherwise leave an
        /// attachment on disk after sign-out.
        @discardableResult
        static func store(
            _ data: Data, id: String, name: String, mime: String, epoch storeEpoch: Int
        ) -> CachedGramFile? {
            guard currentEpoch == storeEpoch else { return nil }
            let stored = GramFileCache.store(data, id: id, name: name, mime: mime, in: root)
            guard currentEpoch == storeEpoch else {
                GramFileCache.remove(id: id, in: root)
                return nil
            }
            return stored
        }

        /// Keep a file this device just posted, under its message id, by moving its staged
        /// copy in: an open from Chat's attachment list or Gram is then a cache hit and
        /// never downloads the bytes this device uploaded. Off the main actor, with the
        /// same epoch rule as `store`.
        static func keep(_ file: ComposerAttachment) async {
            let epoch = currentEpoch
            await Task.detached(priority: .utility) {
                guard currentEpoch == epoch, let id = file.messageID else { return }
                GramFileCache.keep(file, in: root)
                if currentEpoch != epoch { GramFileCache.remove(id: id, in: root) }
            }.value
        }

        static func remove(id: String) {
            GramFileCache.remove(id: id, in: root)
            GramThumbnails.remove(id: id)
        }

        /// Sign-out and account removal: downloaded bytes must not survive the account
        /// that could read them.
        ///
        /// The epoch is bumped FIRST. `disconnect()` then cancels the connection's
        /// downloads (`GramDownloadStore.cancelAll`), but cancellation is cooperative: a
        /// download whose bytes have already landed can still reach `store` after the
        /// wipe. Bumping first makes that store a no-op, and `store` re-checks afterwards
        /// so a write that slipped through is removed again.
        static func invalidate() {
            lock.withLock { epoch += 1 }
            GramFileCache.removeAll(in: root)
            GramThumbnails.removeAll()
        }

        /// Whether `url` is a cache entry, so the page's temp-file cleanup leaves it
        /// alone. Standardized first, so a `/private/var` vs `/var` difference cannot
        /// make a cached file look temporary and get unlinked.
        ///
        /// Compared by PATH COMPONENTS, not by string prefix: `hasPrefix` on the raw
        /// path also accepts a sibling directory like `gram-downloads-old`, which would
        /// exempt files that are not ours from cleanup and leave them on disk.
        static func isCached(_ url: URL) -> Bool {
            let rootParts = root.standardizedFileURL.pathComponents
            let urlParts = url.standardizedFileURL.pathComponents
            guard urlParts.count > rootParts.count else { return false }
            return Array(urlParts.prefix(rootParts.count)) == rootParts
        }
    }

    /// Delete a message (and its file bytes) after the server confirms — so a
    /// failed delete leaves the row in place rather than lying that it's gone.
    private func delete(_ message: GramMessage) {
        Task {
            do {
                try await client.gramDelete(id: message.id)
                // Tombstone it so an in-flight poll (snapshot predating the delete)
                // can't briefly resurrect the row; cleared in `load` once the server
                // no longer returns it.
                deletedIDs.insert(message.id)
                inboxStore.inbox.remove(id: message.id)
                pendingPosts.removeAll { $0.id == message.id }
                // The downloaded copy must not outlive the message it came from: a
                // deleted gram's attachment stays readable on disk otherwise.
                Downloads.remove(id: message.id)
            } catch let error as APIError {
                sendError = "Couldn't delete: \(error.message)"
            } catch {
                sendError = "Couldn't delete. Try again."
            }
        }
    }

    /// Anchors the "N unread" rule on the oldest unread message, BEFORE anything is marked
    /// read, so reading does not move or erase it under the reader. No unread clears it.
    private func captureUnreadRule() {
        unreadRuleCaptured = true
        let unread = messages.filter(\.isUnread)
        unreadRule = unread.last.map { UnreadRule(messageID: $0.id, count: unread.count) }
    }

    /// The feed has landed on the newest message (`WindowedBottomFeed` saw its bottom marker
    /// come on screen after the scroll was issued): from now on rows that appear are being
    /// read. The rows already on screen are read one turn later, once this layout pass's
    /// appear/disappear callbacks have dropped the top rows the first layout built.
    private func feedLanded() {
        Task { @MainActor in
            for message in messages where feedVisibility.rows.contains(message.id) {
                markReadIfNeeded(message)
            }
            // A feed that fits shows the top too.
            if feedVisibility.sentinelOnScreen { requestOlderPage() }
        }
    }

    /// The sentinel's automatic fetch: ONE older page per arrival of the sentinel on screen
    /// (see `FeedVisibility.pageArmed`), never before the initial scroll, and not over a
    /// failure (that waits for the reader's tap on the sentinel). During a search, one
    /// bounded search of older pages per arrival instead (`loadOlderMatches`). Held in
    /// `FeedVisibility.olderFetch`, so a new or cleared search cancels it.
    private func requestOlderPage() {
        guard didInitialScroll, feedVisibility.pageArmed, !feedVisibility.anchoring,
              !feedVisibility.pageRequested, pageError == nil else { return }
        feedVisibility.pageArmed = false
        feedVisibility.pageRequested = true
        feedVisibility.olderFetch = Task { @MainActor in
            let grew = await loadOlderPage()
            // Cancelled by a search change, which has already reset the flags for the new query.
            guard !Task.isCancelled else { return }
            feedVisibility.pageRequested = false
            // Nothing landed, so no anchor scroll will re-arm: the next arrival may fetch.
            if !grew { feedVisibility.pageArmed = true }
        }
    }

    /// One older window: loaded messages above the drawn window first (no fetch), else the
    /// next page from the daemon, drawn whole; during a search, older pages until one adds
    /// a match (`loadOlderMatches`). Then the previously-top message is scrolled back to the
    /// top so the reader keeps their place (see `pageAnchorID`). Returns whether the feed grew.
    private func loadOlderPage() async -> Bool {
        let top = feedEntries.first?.id
        if hasHiddenOlder {
            // A reveal from a task the next keystroke already cancelled must not move the
            // window or anchor the new query's feed.
            guard !Task.isCancelled else { return false }
            renderLimit += Self.renderWindow
        } else {
            let grew: Bool
            if search.isEmpty {
                grew = await loadMore()
            } else {
                grew = await loadOlderMatches()
            }
            // Cancelled: the search changed while the page was in flight, and the new
            // query's feed must not be scrolled to the old one's anchor.
            guard grew, !Task.isCancelled else { return false }
            renderLimit = max(renderLimit, visibleMessages.count)
        }
        if let top { pageAnchorID = top }
        return true
    }

    /// Opens or folds one "Read more" segment of a message.
    private func setExpanded(_ id: String, segment: Int, _ open: Bool) {
        if open {
            expandedTexts[id, default: []].insert(segment)
        } else {
            expandedTexts[id]?.remove(segment)
            if expandedTexts[id]?.isEmpty == true { expandedTexts[id] = nil }
        }
    }

    private func markReadIfNeeded(_ message: GramMessage) {
        if !unreadRuleCaptured { captureUnreadRule() }
        // Skip if already read or a mark-read is already in flight for it (onAppear
        // re-fires on scroll).
        guard message.isUnread, !markingRead.contains(message.id) else { return }
        markingRead.insert(message.id)
        Task {
            defer { markingRead.remove(message.id) }
            do {
                try await client.gramMarkRead(id: message.id)
                // Flip the local copy only after the server confirms — an unread
                // agent->owner message always lives in the server snapshot.
                inboxStore.inbox.markRead(id: message.id)
                // Reading a message clears it from the badge immediately.
                unread?.count = inboxStore.inbox.unreadCount
            } catch {
                // Leave it unread; the next poll re-surfaces it.
            }
        }
    }

    /// Marks EVERY unread message read, ignoring any active search — the button says "Read all"
    /// and the badge must reach zero, so marking only the filtered matches would leave a
    /// non-zero badge with no visible cause. Serial, not a TaskGroup: this sends one id per
    /// `gram.mark_read` (current herdr also takes an `ids` list, but an older daemon takes
    /// only `id`), so a serial loop is both the existing idiom and the one that cannot
    /// flood a forwarded SSH connection.
    private func markAllRead() async {
        guard !markingAllRead else { return }
        markingAllRead = true
        defer { markingAllRead = false }
        markAllNote = nil
        // Snapshot the ids first: `serverMessages` is mutated inside the loop and a poll may
        // replace it mid-pass, so iterating the live array could skip or repeat a message.
        //
        // The ids come from an unread-ONLY fetch, not from the loaded window. The inbox
        // is paged, so the window holds the newest messages and an older unread one
        // would otherwise be left unread while the badge — counted by the daemon over
        // the whole store — kept showing it. That fetch is small by construction; on a
        // daemon that cannot page it returns the same ids the window would have given.
        var pending: [String]
        do {
            let unreadAnswer = try await client.gramList(unreadOnly: true)
            pending = (unreadAnswer.messages ?? []).filter(\.isUnread).map(\.id)
        } catch {
            pending = serverMessages.filter { $0.isUnread }.map(\.id)
        }
        // Ids this pass actually marked, re-applied after the loop: `load` REPLACES
        // `serverMessages` wholesale, so a poll landing mid-pass reverts the flips written
        // below and the badge would still show a count after a fully successful pass.
        var marked: Set<String> = []
        var attempted = 0
        var failed = 0
        // Two passes: an id a row's own `onAppear` had in flight when we first reached it is
        // retried once, by which time that Task has cleared its entry — otherwise "Read all"
        // could silently leave it unread if that Task's own call failed (its catch is a no-op).
        for _ in 0..<2 {
            var stillInFlight: [String] = []
            for id in pending {
                // Reusing the existing in-flight set is what stops a duplicate `gram.mark_read`.
                guard !markingRead.contains(id) else { stillInFlight.append(id); continue }
                // Someone else's pass already read it; nothing left to do for this id.
                // An id absent from the window is NOT skipped: it came from the
                // unread-only fetch, so it is unread and simply older than the page.
                if let loaded = serverMessages.first(where: { $0.id == id }), !loaded.isUnread {
                    continue
                }
                markingRead.insert(id)
                attempted += 1
                do {
                    try await client.gramMarkRead(id: id)
                    marked.insert(id)
                    inboxStore.inbox.markRead(id: id)
                } catch {
                    failed += 1
                }
                markingRead.remove(id)
            }
            pending = stillInFlight
            if pending.isEmpty { break }
        }
        // Whatever array is current now, the ids we confirmed read are read. Ids still in flight
        // elsewhere are left to their own Task, which flips them on success.
        for id in marked { inboxStore.inbox.markRead(id: id) }
        unread?.count = inboxStore.inbox.unreadCount
        // Partial failure is reported, not swallowed: the badge will still show a count and the
        // reader needs to know why. Its OWN slot, not `refreshNote` — the 6-second poll clears
        // that one unconditionally on success, so the explanation would outlive the badge by
        // seconds at most. `sendError` carries the same reasoning (see its declaration).
        markAllNote = failed == 0 ? nil : "\(failed) of \(attempted) could not be marked read."
    }
}

/// A Gram file staged for export, plus the temp dir holding it (removed once the
/// export picker finishes copying it to the chosen location).
private struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
    let dir: URL
}

/// Wraps `UIDocumentPickerViewController(forExporting:asCopy:)` so a downloaded Gram
/// file saves to a real, user-chosen location — the Finder save panel (real
/// ~/Documents / ~/Downloads) on Mac, the Files picker on iPhone/iPad. QuickLook's
/// built-in "Save to Files" maps "Documents" to the hidden app-sandbox container on
/// the Designed-for-iPad Mac build, which is why saved files seem to disappear.
private struct FileExportPicker: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onFinish() }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onFinish() }
    }
}

/// The Saved section's feed, read like the inbox: oldest at the top and the newest at the
/// bottom, on the inbox's `WindowedBottomFeed`. It draws only the newest
/// `GramView.renderWindow` saved messages, and reaching the top reveals the next older
/// window, putting the previously-top message back at the top so the reader keeps their
/// place. Saved is local and complete, so a reveal never fetches, and there is no read
/// tracking or composer resize to follow. A search filters `saved` before it gets here and
/// starts over from the newest window.
private struct GramSavedFeed: View {
    /// The saved messages to show, newest first (the store's order), after the search filter.
    let saved: [SavedGram]
    let search: String
    /// The floating header's bottom edge (`GramView.headerBottom`): rows under it are not on
    /// screen, and an anchored row may land at it.
    let headerBottom: CGFloat
    /// `GramView.newestToken`: a re-tap of the selected Gram tab goes to the newest saved.
    let newestToken: Int
    let downloadingFileFor: String?
    let downloadBytes: (received: Int, total: Int)?
    let onOpenFile: (SavedGram) -> Void
    let onSaveFile: (SavedGram) -> Void
    let onCancelDownload: (SavedGram) -> Void
    let onUnsave: (SavedGram) -> Void

    /// How many of the newest saved messages are drawn. Grows by a window per arrival at the
    /// top; a new search starts it over.
    @State private var renderLimit = GramView.renderWindow
    /// The previously-top message after a reveal; the feed scrolls back to it.
    @State private var anchorID: String?
    /// Bumped each time the feed comes on screen, so its trackers report again (see
    /// `WindowedBottomFeed.appearance`).
    @State private var appearance = 0
    @State private var visibility = FeedVisibility()
    /// The feed has landed on the newest saved message (the first layout starts at the top, and
    /// the sentinel it builds there was never seen). In `visibility`, not `@State`: nothing
    /// drawn depends on it, and re-rendering this feed when it lands left the reveal's anchor
    /// short of the top on iPad (the previously-top row stayed low, the oldest in view).
    private var landed: Binding<Bool> {
        Binding(get: { visibility.landed }, set: { visibility.landed = $0 })
    }

    private var hasHiddenOlder: Bool { saved.count > renderLimit }
    /// The drawn window, oldest at the top.
    private var drawn: [SavedGram] { Array(saved.prefix(renderLimit).reversed()) }

    var body: some View {
        let rows = drawn
        ScrollViewReader { feed in
            WindowedBottomFeed(
                feed: feed,
                items: rows,
                spacing: 14,
                showsSentinel: hasHiddenOlder,
                bottomID: "gram-saved-bottom",
                feedID: "gram-saved-feed",
                // How many saved messages are drawn, so a UI test can tell the window from all.
                messagesID: "gram-saved-messages",
                messagesValue: "\(rows.count) of \(saved.count) saved",
                column: .conversation(probe: "gram-column"),
                visibleTop: headerBottom,
                search: search,
                visibility: visibility,
                appearance: $appearance,
                landed: landed,
                anchorID: $anchorID,
                newestRequest: newestToken,
                // A feed that fits shows the top too.
                onLanded: { if visibility.sentinelOnScreen { revealOlder() } },
                onSentinelArrival: revealOlder,
                sentinel: {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading older saved messages…")
                    }
                    .font(Typography.app(12))
                    .foregroundStyle(Palette.textFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("gram-saved-older")
                },
                row: { _, s in
                    SavedGramRow(
                        saved: s,
                        isDownloadingFile: downloadingFileFor == s.id,
                        downloadProgress: downloadingFileFor == s.id ? downloadBytes : nil,
                        onOpenFile: { onOpenFile(s) },
                        onSaveFile: { onSaveFile(s) },
                        onCancelDownload: { onCancelDownload(s) },
                        onUnsave: { onUnsave(s) }
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("gram-saved-\(s.id)")
                },
                footer: { EmptyView() }
            )
            .onChange(of: search) { _, _ in renderLimit = GramView.renderWindow }
        }
    }

    /// One older window per arrival of the sentinel, after the feed has landed. The message on
    /// top now is put back at the top once the window is drawn above it.
    private func revealOlder() {
        guard visibility.landed, visibility.pageArmed, !visibility.anchoring, hasHiddenOlder else { return }
        visibility.pageArmed = false
        let top = drawn.first?.id
        renderLimit += GramView.renderWindow
        if let top { anchorID = top }
    }
}

#if DEBUG
/// For the UI tests: how many times a `GramRow` body has run, so a test can hold the feed to
/// a render budget (`gram-row-renders`).
@MainActor
enum GramRowRenders {
    private(set) static var count = 0
    static func record() { count += 1 }
}

/// The `gram-row-renders` probe: `GramRowRenders.count` as its label, polled. Its own view and
/// state, so the poll re-renders this probe alone, never the page whose rows it counts.
private struct GramRowRenderProbe: View {
    @State private var count = 0

    var body: some View {
        Color.clear
            .accessibilityElement()
            .accessibilityIdentifier("gram-row-renders")
            .accessibilityLabel("\(count)")
            .task {
                guard ScreenshotMock.mode != nil else { return }
                while !Task.isCancelled {
                    if GramRowRenders.count != count { count = GramRowRenders.count }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
    }
}
#endif

/// One feed row with what draws around it: a time separator, the unread rule, and whether it
/// opens or closes a sender group. Shared by the owner's inbox and a guest's Gram tab.
struct GramFeedEntry: Identifiable {
    let message: GramMessage
    /// The time separator above the row, when the gap from the previous one is over an
    /// hour or the day changed (and above the first row).
    let separator: Date?
    /// The unread rule above the row.
    let unreadCount: Int?
    let startsGroup: Bool
    let endsGroup: Bool
    var id: String { message.id }
    var startsAfterMarker: Bool { separator != nil || unreadCount != nil }

    /// `rows` (oldest first) with their separators, the unread rule above `unreadRule`'s
    /// message, and their sender groups. A separator or the rule breaks a group.
    static func entries(oldestFirst rows: [GramMessage],
                        unreadRule: (messageID: String, count: Int)? = nil) -> [GramFeedEntry] {
        let calendar = Calendar.current
        let markers: [(separator: Date?, unread: Int?)] = rows.indices.map { index in
            let date = rows[index].createdAt
            let separates = index == 0
                || date.timeIntervalSince(rows[index - 1].createdAt) > 3600
                || !calendar.isDate(date, inSameDayAs: rows[index - 1].createdAt)
            let unread = unreadRule?.messageID == rows[index].id ? unreadRule?.count : nil
            return (separates ? date : nil, unread)
        }
        func breaks(_ index: Int) -> Bool { markers[index].separator != nil || markers[index].unread != nil }
        return rows.indices.map { index in
            let next = index + 1
            return GramFeedEntry(
                message: rows[index],
                separator: markers[index].separator,
                unreadCount: markers[index].unread,
                startsGroup: index == 0 || breaks(index) || !GramRow.sameRun(rows[index - 1], rows[index]),
                endsGroup: next == rows.count || breaks(next) || !GramRow.sameRun(rows[index], rows[next])
            )
        }
    }
}

/// One feed row with what draws above it (its time separator and the unread rule) and the
/// feed's gaps: 2 pt inside a sender group, 10 pt between groups.
struct GramFeedRow<Row: View>: View {
    let index: Int
    let entry: GramFeedEntry
    @ViewBuilder let row: () -> Row

    var body: some View {
        VStack(spacing: 0) {
            if let date = entry.separator {
                GramTimeSeparator(date: date)
                    .padding(.top, index == 0 ? 0 : 16)
            }
            if let count = entry.unreadCount {
                GramUnreadRule(count: count)
                    .padding(.top, index == 0 && entry.separator == nil ? 0 : 12)
            }
            row()
                .padding(.top, index == 0 && !entry.startsAfterMarker ? 0 : (entry.startsGroup ? 10 : 2))
        }
    }
}

/// One message in the feed: option D's iMessage layout in herdr's colours (round 3).
///
/// An agent's group opens with a "name · machine" line and carries the sender's avatar
/// beside its last bubble; the owner's own posts sit on the right with a status line
/// ("Grabbed by …" / "Delivered to …"). Prose folds past four lines, fenced code draws in a
/// monospaced inset with Copy, an image attachment shows as a picture card and any other
/// file as a file card, sharing one card with the text when the message has both. A file
/// the store expired draws as a file card with nothing to open (`GramExpiredFileCard`).
///
/// `viewer` says whose feed it is: the owner's inbox, or a guest's copy of the one agent
/// shared with them (`GuestGramList`), which draws the same rows with less to do.
struct GramRow: View, Equatable {
    /// Who reads the feed, and so what a row offers.
    enum Viewer: Equatable {
        /// The owner's inbox: every action, image previews, the owner's file downloads.
        case owner
        /// A guest: Copy only (no Save, Delete or Save to Files); every file draws as a card,
        /// opened by the guest's bounded piece-by-piece download (`gram.get_file_chunk`),
        /// never from the owner's download cache; the cards carry the guest identifiers.
        case guest
    }

    let message: GramMessage
    var isDownloadingFile: Bool
    /// Reply bytes received against bytes expected for THIS row's download, when the
    /// transport reports them. nil means no measurement — the card's ring spins rather
    /// than showing a share that is not driven by anything.
    var downloadProgress: (received: Int, total: Int)?
    /// The feed has landed on the newest message: before that its first layout passes
    /// through rows the reader never sees, so an image card must not fetch for them.
    var feedLanded: Bool
    /// The floating header's bottom edge in `GramView.feedPageSpace` (0 until measured): an
    /// image card under the header is not on screen.
    var visibleTop: CGFloat = 0
    /// The feed's appearance count (`GramView.feedAppearance`), so an image card still on
    /// screen when the tab comes back reports again.
    var appearance = 0
    var isSaved: Bool
    /// The text segments of THIS message the reader opened with "Read more" (by segment
    /// index). Owned by the page, so a rebuilt row does not fold the text again.
    var expandedSegments: Set<Int> = []
    /// The UI text-size setting. Not drawn from directly (`Typography.scale` is a global),
    /// but compared in `==`: without it a size change would leave every row at the old size.
    var fontScale: Double = 1
    var onOpenFile: () -> Void
    var onSaveFile: () -> Void
    /// Ends the reader's own open or save of this file (`GramDownloadStore.cancel`): it
    /// outlives the page now, so leaving no longer stops it (#574). The owner's only.
    var onCancelDownload: () -> Void = {}
    /// Fetches the image attachment into the download cache without opening it (see
    /// `GramView.prefetchImage`); returns when it is cached, refused or failed.
    var onPrefetchImage: () async -> Void
    var onToggleSave: () -> Void
    var onDelete: () -> Void
    /// Opens (true) or folds (false) a text segment, by index.
    var onSetExpanded: (Int, Bool) -> Void
    /// The first message of a sender group: draws the sender line.
    var startsGroup = true
    /// The last message of a group: draws the avatar and the bubble tail.
    var endsGroup = true
    /// This device's own machine label, for a local sender's "name · machine" line (a
    /// federated sender carries its own). Empty when unknown: the line shows the name only.
    var localMachine = ""
    var viewer: Viewer = .owner

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.displayScale) private var displayScale
    /// The image attachment's picture, decoded once its bytes are in the download cache.
    @State private var thumbnail: UIImage?
    /// The image card is inside the feed's visible bounds (its own placement report, see
    /// `imageCard`). Row state, not page state: see there.
    @State private var onScreen = false

    /// The card is on screen and the feed has landed: only then does it fetch a preview it
    /// does not have.
    private var isOnScreen: Bool { feedLanded && onScreen }

    /// Everything the row draws from, closures excluded (they only act). The feed applies
    /// `.equatable()`, so a page render (a composer keystroke, a poll, another file's
    /// download progress) skips every row whose inputs are unchanged. An input missing here
    /// is drawn stale, so every new drawing input belongs in this list. The feed's landing,
    /// header edge and appearance matter to an image card only, so a text row ignores them.
    nonisolated static func == (lhs: GramRow, rhs: GramRow) -> Bool {
        lhs.message == rhs.message
            && lhs.isDownloadingFile == rhs.isDownloadingFile
            && lhs.downloadProgress?.received == rhs.downloadProgress?.received
            && lhs.downloadProgress?.total == rhs.downloadProgress?.total
            && lhs.isSaved == rhs.isSaved
            && lhs.expandedSegments == rhs.expandedSegments
            && lhs.fontScale == rhs.fontScale
            && lhs.startsGroup == rhs.startsGroup
            && lhs.endsGroup == rhs.endsGroup
            && lhs.localMachine == rhs.localMachine
            && lhs.viewer == rhs.viewer
            && (lhs.message.file?.isImage != true
                || (lhs.feedLanded == rhs.feedLanded
                    && lhs.visibleTop == rhs.visibleTop
                    && lhs.appearance == rhs.appearance))
    }

    private var mine: Bool { !message.isFromAgent }
    private var imageFile: GramFile? {
        guard viewer == .owner, let file = message.file, file.isImage else { return nil }
        return file
    }
    private var documentFile: GramFile? {
        guard let file = message.file, viewer == .guest || !file.isImage else { return nil }
        return file
    }
    /// The attachment drawn as a card in the text part, below any text: a document, or any
    /// file the store expired (image or not: there is no picture left to show).
    private var hasCard: Bool { documentFile != nil || message.expiredFile != nil }

    var body: some View {
        #if DEBUG
        let _ = GramRowRenders.record()
        #endif
        let segments = GramText.segments(message.text)
        let hasTextPart = !segments.isEmpty || hasCard
        VStack(alignment: mine ? .trailing : .leading, spacing: 0) {
            if startsGroup && !mine {
                senderLine
                    .padding(.leading, GramBubble.groupIndent + 12)
                    .padding(.bottom, 2)
            }
            HStack(alignment: .bottom, spacing: GramBubble.groupIndent - GramBubble.avatarSize) {
                if !mine {
                    if endsGroup {
                        GramAvatar(name: message.from, size: GramBubble.avatarSize)
                    } else {
                        Color.clear.frame(width: GramBubble.avatarSize, height: GramBubble.avatarSize)
                    }
                }
                VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                    // The tail goes only on a part that ENDS IN TEXT: never on a picture, a
                    // bare file card, or a text + file card (the card comes last).
                    if hasTextPart {
                        chrome(textPart(segments), first: true,
                               tail: !segments.isEmpty && !hasCard && imageFile == nil)
                    }
                    if let image = imageFile {
                        chrome(imageCard(image), first: !hasTextPart, tail: false)
                    }
                }
                // The message's drawn bubble(s), for UI tests that measure it (a line-limited
                // Text's own frame is not its drawn height). Children stay accessible.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("gram-bubble-\(message.id)")
            }
            if let status = statusLine {
                status
                    .font(Typography.app(11, .medium))
                    .foregroundStyle(message.grabbedBy != nil ? Palette.done : Palette.textFaint)
                    .padding(.top, 3)
                    .padding(.trailing, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        // Room for the saved badge, which sits above the bubble's top edge.
        .padding(.top, isSaved ? 12 : 0)
    }

    /// "name · machine": the bare name is its own Text (UI tests find it by its label) and
    /// the machine part is a separate span at 75 % opacity.
    private var senderLine: some View {
        HStack(spacing: 0) {
            Text(verbatim: message.senderAgentName)
            if let machine = message.senderMachine ?? (localMachine.isEmpty ? nil : localMachine) {
                Text(verbatim: " · \(machine)")
                    .opacity(0.75)
            }
        }
        .font(Typography.app(11))
        .foregroundStyle(Palette.textDim)
        .lineLimit(1)
    }

    /// One part of the message (its text card, or its picture) with what every part
    /// shares: the tail on the group's last text part, the saved badge on the first part,
    /// the context menu, and the width cap (`gramBubbleWidth`, of the width the avatar
    /// leaves). The cap is applied AFTER the background so a short bubble still hugs its text.
    /// `tail` says the part ends in text and is the message's last part; the tail then
    /// shows on the group's last message only, in the bubble's own fill.
    private func chrome<Content: View>(_ content: Content, first: Bool, tail: Bool) -> some View {
        content
            .gramBubbleTail(mine: mine, shown: tail && endsGroup)
            .overlay(alignment: .topTrailing) {
                if first && isSaved {
                    GramSavedBadge().offset(x: 15, y: -17)
                }
            }
            // Never rebuilt by a feed pass while open (see StableContextMenu.swift); the
            // preview lifts the bubble's shape.
            .stableContextMenu(previewCornerRadius: GramBubble.radius) { menu }
            .gramBubbleWidth(incoming: !mine, sizeClass: sizeClass)
    }

    /// The message's one menu, on every part of it (the attachment cards included): the
    /// file's Save to Files (or, while the reader's download of it runs, its cancel), then
    /// the message actions.
    @StableMenuBuilder
    private var menu: [StableMenuItem] {
        if message.file != nil && viewer == .owner {
            if isDownloadingFile {
                StableMenuItem("Cancel Download", systemImage: "xmark.circle", action: onCancelDownload)
            } else {
                StableMenuItem("Save to Files", systemImage: "square.and.arrow.down", action: onSaveFile)
            }
        }
        if !message.text.isEmpty {
            StableMenuItem("Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = message.text
            }
        }
        if viewer == .owner {
            StableMenuItem(isSaved ? "Unsave" : "Save", systemImage: isSaved ? "bookmark.slash" : "bookmark",
                           action: onToggleSave)
            StableMenuItem("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }

    /// The text and any card file (a document, or a file the store expired), drawn by the
    /// shared `GramTextPart`; the fold state is the page's.
    private func textPart(_ segments: [GramTextSegment]) -> some View {
        GramTextPart(
            segments: segments, mine: mine, hasCard: hasCard,
            isExpanded: { index in
                Binding(
                    get: { expandedSegments.contains(index) },
                    set: { open in onSetExpanded(index, open) }
                )
            },
            card: card(embedded:)
        )
    }

    /// The text part's file card: the document's, or the expired file's, which has nothing
    /// to open.
    @ViewBuilder
    private func card(embedded: Bool) -> some View {
        if let file = documentFile {
            fileCard(file, embedded: embedded)
        } else if let expired = message.expiredFile {
            GramExpiredFileCard(name: expired.name, byteCount: Int(clamping: expired.size), embedded: embedded,
                                identifier: viewer == .guest ? "guest-gram-expired-\(message.id)"
                                                             : GramExpiredFileCard.ownerIdentifier)
        }
    }

    private func fileCard(_ file: GramFile, embedded: Bool) -> some View {
        GramFileCard(
            name: file.name,
            kind: GramFileCard.kind(name: file.name, mime: file.mime),
            byteCount: Int(clamping: file.size),
            download: download,
            onOpen: onOpenFile,
            onSave: viewer == .owner ? onSaveFile : nil,
            embedded: embedded,
            identifier: viewer == .guest ? "guest-gram-file-\(message.id)" : GramFileCard.ownerIdentifier
        )
        // A second tap while its own download runs does nothing; the value says why.
        .disabled(isDownloadingFile)
    }

    private func imageCard(_ file: GramFile) -> some View {
        GramImageCard(
            name: file.name,
            byteCount: Int(clamping: file.size),
            // From memory on the first frame of a rebuilt row, so it never flashes the
            // placeholder or changes shape twice.
            thumbnail: thumbnail ?? GramThumbnails.cached(id: message.id),
            download: download,
            onOpen: onOpenFile,
            onSave: onSaveFile
        )
        .disabled(isDownloadingFile)
        #if DEBUG
        // For the UI tests: "preview" once the card draws its picture, "placeholder" before.
        // Its own element, so the card's value stays the spoken download state.
        .background {
            Color.clear
                .accessibilityElement()
                .accessibilityIdentifier("gram-image-preview-\(message.id)")
                .accessibilityLabel((thumbnail ?? GramThumbnails.cached(id: message.id)) == nil ? "placeholder" : "preview")
        }
        #endif
        // On screen (the feed has landed), and again when an open ends: an image over the
        // prefetch cap is cached by opening it.
        .task(id: isOnScreen && !isDownloadingFile) { await loadThumbnail() }
        // This card's own on-screen state, below the floating header (the rule the feed's
        // read tracking uses). Row-local: a picture entering or leaving the screen re-renders
        // this row alone, never the page and every other bubble with it.
        .onFeedPlacementChange(appearance: appearance, visibleTop: visibleTop > 0 ? visibleTop : nil) { placement in
            if onScreen != placement.onScreen { onScreen = placement.onScreen }
        }
        .onDisappear { if onScreen { onScreen = false } }
    }

    /// The image attachment's picture: from memory when the feed drew it before, else decoded
    /// from the download cache, which `onPrefetchImage` fills for an image under the prefetch
    /// cap and an open fills for the rest. Runs only while the card is on screen (the task
    /// is keyed on it); scrolling it away cancels a prefetch still queued or running (unless
    /// an open is waiting on it). A picture already decoded shows regardless (`imageCard`).
    private func loadThumbnail() async {
        guard imageFile != nil, thumbnail == nil else { return }
        if let hit = GramThumbnails.cached(id: message.id) {
            thumbnail = hit
            return
        }
        // Off screen, or an open of this file is running: the task restarts when that
        // changes (after an open the file is cached).
        guard isOnScreen, !isDownloadingFile else { return }
        // The disk cache lookup reads the file's metadata: off the main thread, so a card
        // scrolling on screen never stalls the scroll on disk I/O.
        let id = message.id
        let lookup = { await GramView.cachedOffMain(id) }
        if await lookup() == nil {
            // A card a fling only flies past never fetches: it must stay on screen a moment.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await onPrefetchImage()
        }
        guard !Task.isCancelled, let cached = await lookup() else { return }
        thumbnail = await GramThumbnails.load(id: message.id, url: cached.url,
                                              spec: GramCardMetrics.imageSize(sizeClass), scale: displayScale)
    }

    /// This row's open or save as its card draws and speaks it (`GramCardDownload.reply`).
    private var download: GramCardDownload? {
        guard isDownloadingFile, let file = message.file else { return nil }
        return viewer == .guest ? .chunked(downloadProgress) : .reply(downloadProgress, fileSize: file.size)
    }

    /// Whether two messages (oldest first) belong to one group: the same side, and the same
    /// agent (theirs) or the same recipient (yours).
    static func sameRun(_ a: GramMessage, _ b: GramMessage) -> Bool {
        guard a.isFromAgent == b.isFromAgent else { return false }
        return a.isFromAgent ? a.from == b.from : a.to == b.to
    }

    /// Your post's state, first word semibold: who grabbed a queue item, whom a direct
    /// post went to, or that a queue item is still waiting.
    private var statusLine: Text? {
        guard mine else { return nil }
        if let grabber = message.grabbedBy {
            return status("Grabbed", "by \(GramMessage.agentName(from: grabber))")
        }
        if let to = message.to {
            return status("Delivered", "to \(GramMessage.agentName(from: to))")
        }
        return status("Unclaimed", "in the shared queue")
    }

    private func status(_ verb: String, _ rest: String) -> Text {
        Text("\(Text(verbatim: verb).fontWeight(.semibold)) \(rest)")
    }

    static func age(from date: Date) -> String {
        let seconds = max(0, GramDates.clockNow().timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86400))d"
        }
    }
}

/// Metrics for Gram's message bubbles (round 3: option D's layout in herdr's colours).
enum GramBubble {
    static let radius: CGFloat = 18
    /// Agents' bubbles: surfaceRaised.
    static let inFill = Palette.surfaceRaised
    /// Your bubbles: the brand violet darkened so white text passes contrast.
    static let outFill = Color(hex: 0x5A4ED6)
    /// The sender's avatar beside an agent group's last bubble.
    static let avatarSize: CGFloat = 28
    /// How far an agent group sits in from the feed's edge: the avatar plus an 8 pt gap.
    static let groupIndent: CGFloat = 36
    /// The guest's Gram feed's width cap (#354 follow-up); the owner's feeds follow the
    /// conversation column on iPad and Mac (`conversationColumn`). About the
    /// width of a Messages conversation on iPad, so a long message wraps at a readable measure
    /// and your bubbles on the right stay near the agents' on the left.
    static let columnCap: CGFloat = 720
}

/// The bubble's tail: one smooth shape drawn BEHIND the bubble (no layered mask), curving
/// out of the bottom corner. Drawn for the left side in a 24 x 22 box whose x = 6 is the
/// bubble's edge; mirror it for the right.
struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24, sy = rect.height / 22
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var path = Path()
        path.move(to: p(6, 0))
        path.addLine(to: p(6, 12))
        path.addCurve(to: p(0, 22), control1: p(6, 16.8), control2: p(3.8, 20.3))
        path.addCurve(to: p(24, 22), control1: p(7, 22.7), control2: p(14, 22.3))
        path.addLine(to: p(24, 0))
        path.closeSubpath()
        return path
    }
}

extension View {
    /// The spec's glass for Gram's floating controls (nav capsules, the pill): Liquid Glass on
    /// iOS 26; before it, surfaceRaised at 72 % over a blur, with a hairline edge.
    @ViewBuilder
    func gramGlass<S: InsettableShape>(_ shape: S) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background {
                shape.fill(Palette.surfaceRaised.opacity(0.72))
                    .background(.ultraThinMaterial, in: shape)
            }
            .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1).allowsHitTesting(false))
        }
    }
}

/// Gram's ground fading out downward where the feed meets the chrome above it: ground, ground
/// at 85 % by 55 %, then clear. Behind the owner's floating header, and at the top of a
/// guest's Gram tab.
struct GramGroundFade: View {
    var body: some View {
        LinearGradient(stops: [.init(color: Palette.ground, location: 0),
                               .init(color: Palette.ground.opacity(0.85), location: 0.55),
                               .init(color: Palette.ground.opacity(0), location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// A feed's top sentinel once an older page failed: the failure and a retry, so the sentinel
/// becomes a tap target instead of spinning with nothing left to re-trigger it. The owner's
/// inbox and a guest's Gram tab; the caller's HStack lays out the icon and text.
struct GramPageFailureLabel: View {
    let message: String

    var body: some View {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: 12, weight: .semibold))
        Text("\(message) Tap to retry.")
    }
}

/// Gram's header floating over the feed: no band, the messages scroll on up under its glass
/// controls, over a ground fade that covers the status bar and the controls only. An OVERLAY,
/// not a safe-area bar or inset: the scroll view's safe area stays the page's own, so the
/// header cannot feed back into the feed's layout (with a safe-area bar, a feed squeezed
/// to about the bar's height on iPhone never finished laying out). The scroll CONTENT gets a
/// top margin of the header's height instead, so the feed opens and pages with its rows
/// below the controls, and the top of the history is never under them.
private struct GramFloatingHeader<Bar: View>: ViewModifier {
    let bar: Bar
    /// The header's height, as the scroll content's top margin. Only the bar's own content
    /// sets it; it remains independent of the feed's current content.
    @State private var barHeight: CGFloat = 0

    func body(content: Content) -> some View {
        // Keep the header stable as the feed switches between messages and "No matches".
        // Give it a higher sibling layer than the native scroll view, so the visible
        // search controls also own touches when the message feed returns.
        ZStack(alignment: .top) {
            VStack(spacing: 0) { content }
                .contentMargins(.top, barHeight, for: .scrollContent)
            bar
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if abs(height - barHeight) > 0.5 { barHeight = height }
                    }
                    .background {
                        GramGroundFade()
                            .ignoresSafeArea(edges: .top)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .accessibilitySortPriority(1)
                    .zIndex(1)
        }
        .accessibilityElement(children: .contain)
    }
}

private extension View {
    /// See `GramFloatingHeader`.
    func gramFloatingHeader<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        modifier(GramFloatingHeader(bar: bar()))
    }
}
