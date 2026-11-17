import SwiftUI
import Foundation
import UIKit    // UIPasteboard (Copy diagnostics)
import UniformTypeIdentifiers
import StoreKit // Product / tip jar (Settings' Support section)
import UserNotifications // notification authorization status (Settings notify section)
import HerdrKit

#if DEBUG
/// Gram screenshot/UI-test harness (`HERDR_SCREENSHOT_MOCK=gram`). `GramView`'s Inbox/Saved
/// selection is a binding owned by the host (on regular width the selector lives in the app's
/// split-view sidebar), and `mockView` is a function that cannot hold `@State` — so this holds
/// it, exactly as `PagingTestHarness` holds the pane slots for its harness.
struct GramScreenshotHarness: View {
    let client: HerdrClient
    @State private var showingSaved = false

    var body: some View {
        // The machine label is the one the design's sample conversation names for local
        // senders ("vetrina · mac-studio"); a live session gets it from its connection.
        GramView(client: client, showingSaved: $showingSaved)
            .environment(\.guestMachineLabel, "mac-studio")
    }
}

/// Swipe-between-agents receipt harness (`HERDR_SCREENSHOT_MOCK=paging`). Holds three agents
/// in the REAL `PaneKeepAliveContainer`, mirroring `TerminalHomeView`'s open/navigate, so an
/// XCUITest swipe pages the front pane and the header heading changes. No LRU eviction here —
/// three panes stay mounted so swipe-back is a proven warm hit.
struct PagingTestHarness: View {
    let client: HerdrClient
    @State private var slots: [PaneSlot]
    @State private var frontID: String?

    init(client: HerdrClient) {
        self.client = client
        let sibs = [
            MockTransport.pagingAgent(kind: "ALFA", pane: "pg:a"),
            MockTransport.pagingAgent(kind: "BRAVO", pane: "pg:b"),
            MockTransport.pagingAgent(kind: "CHARLIE", pane: "pg:c"),
        ]
        _slots = State(initialValue: [PaneSlot(paneID: "pg:a", title: "ALFA", agent: sibs[0],
                                               initialReply: "", siblings: sibs)])
        _frontID = State(initialValue: "pg:a")
    }

    var body: some View {
        PaneKeepAliveContainer(
            client: client, slots: slots, frontID: frontID,
            isPresented: true,
            onClose: { frontID = nil },
            onNavigate: { slot, delta in navigate(from: slot, delta: delta) })
    }

    private func open(_ slot: PaneSlot) {
        if let i = slots.firstIndex(where: { $0.paneID == slot.paneID }) {
            let existing = slots.remove(at: i); slots.append(existing)
        } else {
            slots.append(slot)
        }
        frontID = slot.paneID
    }

    private func navigate(from slot: PaneSlot, delta: Int) {
        guard let i = slot.siblings.firstIndex(where: { $0.paneID == frontID }),
              slot.siblings.indices.contains(i + delta) else { return }
        let next = slot.siblings[i + delta]
        open(PaneSlot(paneID: next.paneID, title: next.displayName, agent: next,
                      initialReply: "", siblings: slot.siblings))
    }
}

/// Renders the received-document viewer over a file that tries to REWRITE ITSELF with
/// script, so a UI receipt can read the rendered text and see whether the Settings
/// switch let it run. Reads the same `@AppStorage` key `GramView` reads and passes it
/// to the same view, so the receipt covers the shipping wiring rather than a stand-in.
struct HtmlPreviewHarness: View {
    @AppStorage(WebViewPolicy.javaScriptDefaultsKey) private var previewJavaScript = false

    /// The paragraph says the safe thing; the script replaces it. Whichever sentence
    /// the webview ends up showing IS the answer, and it is plain DOM text, which
    /// XCUITest reads out of the web view.
    private static let document = """
    <!doctype html><meta charset="utf-8">
    <body style="font:17px -apple-system;padding:24px">
    <p id="out">script did not run</p>
    <script>document.getElementById("out").textContent = "script ran";</script>
    </body>
    """

    var body: some View {
        HtmlWebView(html: Self.document, allowsJavaScript: previewJavaScript)
            .ignoresSafeArea(edges: .bottom)
    }
}

/// DEBUG-only screenshot and UI-test mode: renders the app's views from MockTransport and
/// the other mocks below — no connection, no key, so the buildbox can screenshot them
/// SAFELY (the app otherwise launches to the empty ConnectView). Enable by launching with
/// env `HERDR_SCREENSHOT_MOCK=<mode>` (one of the names `mode` parses; anything else is
/// `list`), or the `-herdrScreenshotMock` launch argument, which also gives `list`.
enum ScreenshotMock {
    case onboarding, pairingGuidance, forkNotice, list, rosterStress, pane, settings, scroll, ccscroll, busyScroll, paging, backfill, keyframeHistory, keyframeHistoryRead, historyPaging, gram, resize, control, htmlPreview, widgets
    case guestAccept, guest, guestPane, guestPaused, guestBlocked, guestOldHost
    // A guest's machine with several shared agents, one of them unavailable.
    case guestMachine
    // Guest access, owner side: the pane with its share sheet, and Settings → Shared access.
    case share, sharedAccess
    // The home list's live status stream: an events_v2 daemon, and an older one.
    case liveEvents, liveEventsLegacy
    // The Agents home on a daemon that advertises `agent_forget`: archived rows offer Close (#380).
    case archivedClose
    // The Agents home on a machine with three running herdr sessions: the session pills (#347).
    case sessions
    // The omp Chat view (#481): the Agents home over `ChatMockTransport`, and a guest's
    // shared omp agent with its Chat tab (#482).
    case chatView, guestChat
    // The Agents home with a long roster and `HERDR_MOCK_WAITING` agents asking (#551).
    case needsYou
    // The Agents home with two agent folders and a star, over a daemon that keeps them in
    // memory (#552); `HERDR_MOCK_GROUPS=off` is a server without folders.
    case folders
    // The Agents home on "mac-mini", whose herdr updates itself from the app (#565):
    // `HERDR_MOCK_UPDATE` picks the state (see `ServerUpdateMock`).
    case serverUpdate
    // Herdrup Desktop's pixel-parity references (herdrup-desktop#16): the Agents home over
    // the desktop's fake herdr agent.list, held still (DesktopReferenceMock).
    case desktopReference

    static var mode: ScreenshotMock? {
        let env = ProcessInfo.processInfo.environment["HERDR_SCREENSHOT_MOCK"]?.lowercased()
        let arg = ProcessInfo.processInfo.arguments.contains("-herdrScreenshotMock")
        guard env != nil || arg else { return nil }
        switch env {
        case "resize": return .resize
        case "control": return .control
        case "onboarding": return .onboarding
        case "pairing-guidance": return .pairingGuidance
        case "fork-notice": return .forkNotice
        case "rosterstress": return .rosterStress
        case "liveevents": return .liveEvents
        case "archivedclose": return .archivedClose
        case "sessions": return .sessions
        case "needsyou": return .needsYou
        case "folders": return .folders
        case "serverupdate": return .serverUpdate
        case "desktopref": return .desktopReference
        case "liveevents-legacy": return .liveEventsLegacy
        case "pane": return .pane
        case "settings": return .settings
        case "share": return .share
        case "sharedaccess": return .sharedAccess
        // `htmlpreview` renders the received-document viewer over a file whose script
        // REWRITES the page, so a receipt can read off the rendered text whether the
        // Settings switch let it run. Same view and same @AppStorage key the Gram page
        // uses, so the wiring under test is the shipping one.
        case "htmlpreview": return .htmlPreview
        // `widgets` renders the Live Activity views themselves — the same file the
        // widget extension compiles — over a bright and a dark backdrop, so the layout
        // and its contrast can be LOOKED at. XCUITest cannot see a real Live Activity.
        case "widgets": return .widgets
        // `scroll` drives the omp scroll receipt: a real SwiftTerm pane seeded with 200
        // distinct lines of scrollback so a swipe visibly moves the content.
        case "scroll": return .scroll
        // `ccscroll` drives the Claude-Code scroll receipt: a real SwiftTerm pane put
        // into mouse-mode on the normal buffer (like Claude Code) whose stand-in
        // agent redraws shifted content when it RECEIVES an SGR wheel event — so a swipe
        // proves drag → app emits wheel → content moves.
        case "ccscroll": return .ccscroll
        // `busyscroll` drives the BUSY-PANE focus receipt: a real SwiftTerm pane whose stream
        // keeps emitting output, so SwiftTerm's auto-follow writes `contentOffset` continuously.
        // That is the state in which the first two versions of the scroll-tap guard suppressed
        // every tap and left the terminal unfocusable while an agent was working.
        case "busyscroll": return .busyScroll
        // `paging` drives the swipe-between-agents receipt: three distinctively-named agents
        // in the keep-mounted container; a swipe fronts the neighbour and the header changes.
        case "paging": return .paging
        // `backfill` drives the scrollback-backfill receipt: the LIVE stream carries only a
        // short one-screen seed, while agent.read (recent, ansi) returns ~1000 lines of history
        // — so scrollback the swipe reveals can ONLY have come from the connect-time backfill.
        case "backfill": return .backfill
        // `keyframehistory` drives the reconnect-history receipt: agent.read has NO history,
        // the first stream DROPS after its keyframe, and history arrives only inside the
        // keyframes (`history_b64`) — so a swipe can reveal earlier output only if the app
        // seeds scrollback from the keyframe of the in-place reconnect.
        case "keyframehistory": return .keyframeHistory
        // `keyframehistoryread` drives the redundant-history-read receipt: EVERY keyframe
        // carries history, as on a current server, and agent.read (source=recent) is held
        // before it answers, so the `keyframe-history-reads` probe shows whether the app
        // cancelled the mount-time read once the first keyframe made it redundant.
        case "keyframehistoryread": return .keyframeHistoryRead
        // `historypaging` drives the history-paging receipt: see `HistoryPagingDriver`.
        case "historypaging": return .historyPaging
        // `gram` renders the Gram page from a canned owner-view gram.list — the
        // messages, unread badge, claim states, and composer, for a layout FYI.
        case "gram": return .gram
        // Guest access (#312): the invite accept screen, the guest home and the view-only
        // pane in each state, all over GuestMockTransport.
        case "guestaccept": return .guestAccept
        case "guest": return .guest
        case "guestmachine": return .guestMachine
        case "guestpane": return .guestPane
        case "guestpaused": return .guestPaused
        case "guestblocked": return .guestBlocked
        // A host older than guest resizing: it refuses the guest's `pane.set_pty_size`.
        case "guestoldhost": return .guestOldHost
        // `chatview`: the owner's Agents home whose omp agent opens in Chat, over a synthetic
        // paged transcript (`ChatMockTransport`). `guestchat`: the guest's view-only pane of a
        // shared omp agent on a host that serves guests its transcript.
        case "chatview": return .chatView
        case "guestchat": return .guestChat
        default: return .list
        }
    }
}

/// `MockTransport` behind a daemon whose `ping` advertises `agent_forget` (#380), so the
/// archived rows offer Close. The plain mock's ping does not decode, which is the
/// older-daemon path where Close stays hidden.
struct ForgetCapableMockTransport: HerdrTransport {
    private let base = MockTransport()
    func roundTrip(_ requestLine: String) async throws -> String {
        if requestLine.contains(#""method":"ping""#) {
            return #"{"id":"mock","result":{"type":"pong","version":"0.9.4","protocol":16,"capabilities":{"agent_forget":true}}}"#
        }
        return try await base.roundTrip(requestLine)
    }
    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> { base.stream(requestLine) }
}

/// The `sessions` mock's stand-in for RootView's session switch (#386): a tap on a pill
/// remounts the home on a client for that session, sharing one `SessionSwitchCache`,
/// exactly as RootView does on a real machine.
struct SessionsMockHome: View {
    @State private var session: String? = "work"
    @State private var generation = 0
    @State private var cache = SessionSwitchCache()

    var body: some View {
        TerminalHomeView(
            client: HerdrClient(transport: SessionsMockTransport(session: session, startedOn: generation)),
            onDisconnect: {}, session: session,
            onSwitchSession: { next in
                session = next
                generation += 1
            },
            sessionCache: cache,
            onTrustHostKey: { _ in false },
            livePaneIDs: MockWireFixtures.demoLivePaneIDs)
        .id(generation)
    }
}

/// `MockTransport` on a machine with three running herdr sessions (work, personal and
/// default) for the session pills receipt (#347). Every session answers with the demo list.
struct SessionsMockTransport: SessionListingTransport {
    private let base = MockTransport()
    /// The session this client addresses, and whether it was reached by a switch.
    let session: String?
    let startedOn: Int

    init(session: String? = "work", startedOn: Int = 0) {
        self.session = session
        self.startedOn = startedOn
    }

    /// After a switch, this session's own `agent.list` is slow (4 s), as on a machine far
    /// away, while the pills' peeks at other sessions answer at once. So the agents can
    /// only appear quickly from what the app already knew (#386).
    func roundTrip(_ requestLine: String) async throws -> String {
        if startedOn > 0, requestLine.contains(#""agent.list""#) {
            try await Task.sleep(nanoseconds: 4_000_000_000)
        }
        return try await base.roundTrip(requestLine)
    }
    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> { base.stream(requestLine) }
    func listSessions() async throws -> [HerdrSession] {
        [HerdrSession(name: "personal", running: true, default: false),
         HerdrSession(name: "work", running: true, default: false),
         HerdrSession(name: "scratch", running: false, default: false),
         HerdrSession(name: "default", running: true, default: true)]
    }
    func roundTrip(_ requestLine: String, inSession session: String?) async throws -> String {
        try await base.roundTrip(requestLine)
    }
}
#endif
