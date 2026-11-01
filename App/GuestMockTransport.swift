#if DEBUG
import Foundation
import HerdrKit
import SwiftUI

/// A stand-in for the guest-gated daemon behind the relay, for the guest screenshots and
/// UI tests. It answers only the guest allowlist; every other method is recorded in
/// `forbiddenCalls` and refused with `guest_forbidden`, exactly as the host would.
///
/// `HERDR_MOCK_GUEST_FEATURES` sets what the hello advertises: `gram,push`, `push`, `gram`
/// or `none`; unset is a host older than the `features` object. Gram methods are allowed
/// only with `gram`, push registration only with `push`, as on the host.
struct GuestMockTransport: HerdrTransport {
    /// `oldHost` is a host older than guest resizing: it refuses `pane.set_pty_size`.
    enum Scenario: String { case running, paused, blocked, oldHost }

    let scenario: Scenario
    /// Hears each call's hello features, like `RelayTransport`'s.
    let onFeatures: (@Sendable (GuestFeatures) -> Void)?

    init(scenario: Scenario, onFeatures: (@Sendable (GuestFeatures) -> Void)? = nil) {
        self.scenario = scenario
        self.onFeatures = onFeatures
        _ = Self.freshGuestSettings
    }

    /// What this launch's host advertises; nil for a host that predates `features`.
    static let features: GuestFeatures? = {
        guard let raw = ProcessInfo.processInfo.environment["HERDR_MOCK_GUEST_FEATURES"] else { return nil }
        let parts = Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        return GuestFeatures(gram: parts.contains("gram"), push: parts.contains("push"))
    }()

    /// The host serves guests the shared agent's transcript (#482): its pong advertises
    /// `agent_transcript` and `agent.transcript` answers with the synthetic guest
    /// conversation. On under `HERDR_MOCK_GUEST_CHAT` or the `guestchat` mock; otherwise
    /// the host predates it and the Chat tab stays hidden.
    static let chat = ProcessInfo.processInfo.environment["HERDR_MOCK_GUEST_CHAT"] != nil
        || ScreenshotMock.mode == .guestChat

    /// `HERDR_MOCK_GUEST_OWNER_ANSWERS`: a host older than guest answers. Its transcript
    /// withholds `answerable` from the guest and it refuses `agent.answer` and
    /// `pane.send_keys` with `guest_forbidden`. Unset, the host lets the guest answer
    /// (`agent.answer`, and the menu keys while the agent is blocked).
    static let ownerOnlyAnswers = ProcessInfo.processInfo.environment["HERDR_MOCK_GUEST_OWNER_ANSWERS"] != nil

    /// The keys a guest may press while the agent waits on a menu, as the host's guest gate.
    static let menuKeys: Set<String> = [
        "Up", "Down", "Left", "Right", "Enter", "Tab", "Escape", "Space",
        "1", "2", "3", "4", "5", "6", "7", "8", "9", "y", "n",
    ]

    /// The APNs token the mock push system hands out once "permission" is granted.
    static let deviceToken = "mock-apns-token-guest"

    /// Each launch starts from the guest's default text size, so one test's A+ can't leak
    /// into the next. Once per process: the view that builds this transport re-renders.
    private static let freshGuestSettings: Void =
        UserDefaults.standard.removeObject(forKey: GuestTerminalSize.storageKey)

    static let access = GuestAccess(
        guestID: "g-7f2c",
        guestName: "plotarmordev",
        machineLabel: "Jerry's Mac Studio",
        ownerName: "Jerry",
        agentName: "llm-opt",
        agentTarget: "w1-3",
        endpoint: RelayEndpoint(
            relay: URL(string: "https://relay.herdrup.dev")!,
            hostID: "AAECAwQFBgcICQoLDA0ODw",
            hostPublicKey: Data(repeating: 7, count: 32)),
        acceptedAt: Date(timeIntervalSince1970: 1_790_000_000))

    static let invite = GuestInvite(
        relay: access.endpoint.relay,
        hostID: access.endpoint.hostID,
        hostPublicKey: access.endpoint.hostPublicKey,
        inviteID: "EBESExQVFhcYGRobHB0eHw",
        secret: "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8",
        machineLabel: access.machineLabel,
        ownerName: access.ownerName,
        agentName: access.agentName,
        guestName: access.guestName,
        expires: Date(timeIntervalSince1970: 4_102_444_800))

    /// Methods called that a guest may not call (anything but the allowlist), in order.
    /// Read by UI tests via GuestPaneView's DEBUG probe.
    static var forbiddenCalls: [String] { recorder.calls }

    /// The Gram, push, upload and prompt calls the host answered, with their arguments, in
    /// order (plus the files the app opened, as `opened:<name>`). Read by UI tests via the same probe.
    static var hostCalls: [String] { hostRecorder.calls }

    static let allowlist: Set<String> = [
        "ping", "agent.list", "agent.get", "agent.read", "pane.stream", "agent.prompt",
        "gram.upload_chunk", "gram.upload.discard", "gram.post", "pane.set_pty_size",
    ]

    /// Allowed only on a host that lets guests answer.
    static let answerMethods: Set<String> = ["agent.answer", "pane.send_keys"]

    /// Allowed only where the host advertises the feature (herdrup#338).
    static let gramMethods: Set<String> = ["gram.list", "gram.get_file_chunk", "gram.mark_read"]
    static let pushMethods: Set<String> = ["notifications.register_device", "notifications.unregister_device"]

    private static let recorder = CallRecorder()
    private static let hostRecorder = CallRecorder()
    private static let streamRecorder = CallRecorder()
    /// How many `pane.stream`s the guest opened (a reconnect opens another). Read by UI tests
    /// via GuestPaneView's `guest-stream-opens` probe.
    static var streamOpens: Int { streamRecorder.calls.count }
    /// The shared agent's PTY: one per process, like the host's, whichever transport value
    /// a re-rendered view built.
    private static let pty = MockPTY()
    /// The guest's Gram and read marks: one per process, like the host's store.
    private static let gram = MockGram()

    private func allows(_ method: String) -> Bool {
        if Self.gramMethods.contains(method) { return Self.features?.gram == true }
        if Self.pushMethods.contains(method) { return Self.features?.push == true }
        if Self.answerMethods.contains(method) { return !Self.ownerOnlyAnswers }
        if method == "agent.transcript" { return Self.chat }
        return Self.allowlist.contains(method) && !(scenario == .oldHost && method == "pane.set_pty_size")
    }

    /// The app opened a downloaded Gram file (for the UI tests' probe).
    static func noteOpened(_ name: String) {
        hostRecorder.append("opened:\(name)")
    }

    func roundTrip(_ requestLine: String) async throws -> String {
        onFeatures?(Self.features ?? .none)
        let method = Self.method(of: requestLine)
        let id = Self.requestID(of: requestLine)
        guard allows(method) else {
            Self.recorder.append(method)
            return Self.errorLine(id: id, code: "guest_forbidden", message: "guests can't call \(method)")
        }
        let params = Self.object(requestLine)?["params"] as? [String: Any] ?? [:]
        switch method {
        case "gram.list":
            Self.hostRecorder.append("gram.list")
            guard let page = Self.gram.list(beforeID: params["before_id"] as? String) else {
                return Self.errorLine(id: id, code: "internal", message: "gram store busy")
            }
            return Self.encode(id: id, result: ["type": "guest_gram_list", "messages": page.messages,
                                                "has_more": page.hasMore])
        case "gram.mark_read":
            let ids = params["ids"] as? [String] ?? []
            Self.hostRecorder.append("gram.mark_read:\(ids.sorted().joined(separator: ","))")
            Self.gram.markRead(ids)
            return #"{"id":"\#(id)","result":{"type":"ok"}}"#
        case "gram.get_file_chunk":
            let file = params["id"] as? String ?? ""
            let offset = params["offset"] as? Int ?? 0
            Self.hostRecorder.append("gram.get_file_chunk:\(file)@\(offset)")
            guard let chunk = Self.gram.chunk(id: file, offset: offset) else {
                return Self.errorLine(id: id, code: "guest_forbidden", message: "not a Gram you can see")
            }
            return Self.encode(id: id, result: chunk)
        case "notifications.register_device":
            let prefs = ["notify_needs_input", "notify_dies", "notify_finishes", "notify_gram"]
                .map { "\($0)=\(params[$0] as? Bool ?? false)" }
            Self.hostRecorder.append("notifications.register_device:"
                + (["device_token=\(params["device_token"] as? String ?? "")",
                    "platform=\(params["platform"] as? String ?? "")"] + prefs).joined(separator: ","))
            return #"{"id":"\#(id)","result":{"type":"ok"}}"#
        case "notifications.unregister_device":
            Self.hostRecorder.append("notifications.unregister_device:\(params["device_token"] as? String ?? "")")
            return #"{"id":"\#(id)","result":{"type":"ok"}}"#
        default:
            break
        }
        switch method {
        case "ping":
            if Self.chat {
                return #"{"id":"\#(id)","result":{"type":"pong","version":"0.9.4","protocol":22,"capabilities":{"agent_transcript":true}}}"#
            }
            return #"{"id":"\#(id)","result":{"type":"pong"}}"#
        case "agent.transcript":
            return ChatMockConversation.guest.transcript(id: id, params: params)
        case "agent.list":
            return #"{"id":"\#(id)","result":{"type":"agent_list","agents":[\#(sharedAgentJSON),\#(Self.otherAgentJSON)]}}"#
        case "agent.get":
            return #"{"id":"\#(id)","result":{"type":"agent_info","agent":\#(sharedAgentJSON)}}"#
        case "agent.answer":
            // Only the shared agent, as `agent.prompt`.
            guard params["target"] as? String == Self.access.agentTarget else {
                Self.recorder.append(method)
                return Self.errorLine(id: id, code: "guest_forbidden", message: "not your agent")
            }
            Self.hostRecorder.append("agent.answer:\(params["option"] as? String ?? "")")
            return ChatMockConversation.guest.answer(id: id, params: params)
        case "pane.send_keys":
            // The shared agent's pane, only while it waits on a menu, and only menu keys:
            // a guest never types into the pane.
            let keys = params["keys"] as? [String] ?? []
            guard params["pane_id"] as? String == Self.access.agentTarget, awaitingMenu,
                  !keys.isEmpty, keys.allSatisfy(Self.menuKeys.contains)
            else {
                Self.recorder.append("\(method):\(keys.joined(separator: ","))")
                return Self.errorLine(id: id, code: "guest_forbidden", message: "guests can't send those keys now")
            }
            Self.hostRecorder.append("pane.send_keys:\(keys.joined(separator: ","))")
            return #"{"id":"\#(id)","result":{"type":"ok"}}"#
        case "gram.upload.discard":
            // A guest drops its own staged upload (a removed chip, an abandoned draft).
            let uploadID = params["upload_id"] as? String ?? ""
            Self.hostRecorder.append("gram.upload.discard:\(uploadID)")
            let discarded = Self.gram.discard(uploadID: uploadID)
            return #"{"id":"\#(id)","result":{"type":"gram_upload_discarded","discarded":\#(discarded)}}"#
        case "agent.read":
            if scenario == .paused {
                return Self.errorLine(id: id, code: "guest_paused", message: "llm-opt isn't running")
            }
            return Self.readLine(id: id, text: Self.history + transcript)
        case "agent.prompt", "gram.upload_chunk", "gram.post":
            // Everything that reaches the agent is refused while it isn't running.
            if scenario == .paused {
                return Self.errorLine(id: id, code: "guest_paused", message: "llm-opt isn't running")
            }
            switch method {
            case "agent.prompt":
                Self.hostRecorder.append("agent.prompt:\(params["text"] as? String ?? "")")
                return #"{"id":"\#(id)","result":{"type":"agent_prompted","delivery":"submitted"}}"#
            case "gram.upload_chunk":
                let uploadID = params["upload_id"] as? String ?? ""
                let offset = params["offset"] as? Int ?? 0
                Self.hostRecorder.append("gram.upload_chunk:\(uploadID)@\(offset)")
                let bytes = Data(base64Encoded: params["data_base64"] as? String ?? "")?.count ?? 0
                Self.gram.stage(uploadID: uploadID, bytes: bytes)
                return #"{"id":"\#(id)","result":{"type":"ok"}}"#
            default:
                let file = (params["file"] as? [String: Any]).map {
                    (uploadID: $0["upload_id"] as? String ?? "", name: $0["name"] as? String ?? "",
                     mime: $0["mime"] as? String ?? "")
                }
                let call = "gram.post:" + (file.map { "\($0.name)@\($0.uploadID)" } ?? "")
                if Self.gram.refusesAsInProgress() {
                    Self.hostRecorder.append(call + "=upload_in_progress")
                    return Self.errorLine(id: id, code: "upload_in_progress",
                                          message: "read the upload connection to EOF")
                }
                guard let message = Self.gram.post(text: params["text"] as? String ?? "",
                                                   to: params["to"] as? String ?? "", file: file) else {
                    Self.hostRecorder.append(call + "=no_staged_upload")
                    return Self.errorLine(id: id, code: "invalid_params",
                                          message: "no staged upload with that id; upload the file chunks first")
                }
                Self.hostRecorder.append(call + "=\(message["id"] as? String ?? "")")
                // The host's guest projection (`project_gram_sent`): no direction, claim or
                // read fields, unlike the owner's `gram.post` reply.
                return Self.encode(id: id, result: ["type": "gram_sent", "message": message])
            }
        case "pane.set_pty_size":
            if scenario == .paused {
                return Self.errorLine(id: id, code: "guest_paused", message: "llm-opt isn't running")
            }
            // The host's guest bounds; a lock applies the size (a release changes nothing here)
            // and needs the guest's stream open on the pane first.
            let params = Self.object(requestLine)?["params"] as? [String: Any]
            let lock = params?["lock"] as? Bool ?? false
            if lock, !Self.pty.hasStream {
                return Self.errorLine(id: id, code: "guest_no_stream",
                                      message: "open the agent's stream before resizing it")
            }
            if lock, let cols = params?["cols"] as? Int, let rows = params?["rows"] as? Int {
                Self.pty.resize(cols: min(max(cols, 20), 500), rows: min(max(rows, 5), 300),
                                redraw: transcript)
            }
            let applied = Self.pty.geometry
            return #"{"id":"\#(id)","result":{"type":"pane_pty_size","pane_id":"\#(Self.access.agentTarget)","cols":\#(applied.cols),"rows":\#(applied.rows),"locked":\#(lock)}}"#
        default:
            return #"{"id":"\#(id)","result":{}}"#
        }
    }

    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        onFeatures?(Self.features ?? .none)
        let method = Self.method(of: requestLine)
        let id = Self.requestID(of: requestLine)
        guard allows(method) else {
            Self.recorder.append(method)
            let refusal = Self.errorLine(id: id, code: "guest_forbidden", message: "guests can't call \(method)")
            return AsyncThrowingStream { continuation in
                continuation.yield(refusal)
                continuation.finish()
            }
        }
        guard method == "pane.stream" else { return AsyncThrowingStream { $0.finish() } }
        Self.streamRecorder.append(method)
        if scenario == .paused {
            // The host refuses a stream while the shared agent is not in the foreground.
            let refusal = Self.errorLine(id: id, code: "guest_paused", message: "llm-opt isn't running")
            return AsyncThrowingStream { continuation in
                continuation.yield(refusal)
                continuation.finish()
            }
        }
        // A live stream never ends on its own (an end is a drop the view reconnects from),
        // so hold it open and ping like the daemon does.
        let transcript = transcript
        return AsyncThrowingStream { continuation in
            let token = UUID()
            let grid = Self.pty.attach(continuation, token: token)
            continuation.yield(#"{"id":"\#(id)","result":{"type":"stream_started","pane_id":"w1-3","epoch":3,"cols":\#(grid.cols),"rows":\#(grid.rows),"base_seq":0,"resync":true}}"#)
            continuation.yield(#"{"stream":"pane.bytes","frame":"reset","seq":0,"epoch":3,"cols":\#(grid.cols),"rows":\#(grid.rows),"data_b64":"\#(Data(transcript.utf8).base64EncodedString())"}"#)
            let pings = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    guard !Task.isCancelled else { break }
                    continuation.yield(#"{"stream":"pane.bytes","frame":"ping","seq":\#(Self.pty.nextSeq()),"epoch":3}"#)
                }
            }
            continuation.onTermination = { _ in
                pings.cancel()
                Self.pty.detach(token: token)
            }
        }
    }

    // MARK: - Fixtures

    /// The pane's grid until a guest sizes it: a desktop-wide terminal, far wider than a phone
    /// (the guest's report: fitted to the width, it was unreadable).
    static let cols = 120
    static let rows = 30

    /// `HERDR_MOCK_STILL=1`: the running agent reads idle. The WORKING pill and the home row's
    /// spinner animate forever, which keeps XCUITest from ever seeing the app idle.
    private static let still = ProcessInfo.processInfo.environment["HERDR_MOCK_STILL"] == "1"

    /// The blocked agent waits on its question until the guest answers it in the chat.
    private var awaitingMenu: Bool {
        scenario == .blocked && !ChatMockConversation.guest.isAnswered
    }

    /// A guest sees a FIXED projection of an agent: exactly these keys, and name, agent and
    /// display_agent may be null. No cwd, titles, workspace, tab or session.
    private var sharedAgentJSON: String {
        let status = switch scenario {
        case .running, .oldHost: Self.still ? "idle" : "working"
        case .paused: "idle"
        case .blocked: awaitingMenu ? "blocked" : Self.still ? "idle" : "working"
        }
        let running = scenario != .paused
        return #"{"terminal_id":"w1-3","avatar":{"style":"mascot","mascot":"pip","sha256":null,"updated_unix_ms":1723041000000},"pane_id":"w1-3","name":"llm-opt","agent":"omp","display_agent":"omp","agent_status":"\#(status)","guest_running":\#(running)}"#
    }

    /// Not shared with this guest; the UI must never show it.
    private static let otherAgentJSON =
        #"{"terminal_id":"term_jarvis","pane_id":"w1-1","name":"jarvis","agent":"claude","display_agent":null,"agent_status":"idle","guest_running":false}"#

    private static let esc = "\u{1b}["
    private static let body = esc + "38;2;201;205;224m"
    private static let faint = esc + "38;2;110;117;150m"
    private static let white = esc + "38;2;255;255;255m"
    private static let blue = esc + "38;2;91;155;232m"
    private static let green = esc + "38;2;95;179;127m"
    private static let amber = esc + "38;2;233;166;60m"
    private static let you = esc + "38;2;231;215;255m"
    private static let tag = esc + "1;38;2;183;168;255m"
    /// The guest's own prompt row: a brand tint over the machine ground, to the right edge.
    private static let highlight = esc + "48;2;24;25;53m"
    private static let reset = esc + "0m"
    private static let eol = esc + "K" + reset + "\r\n"
    /// The agent's TUI hides the cursor while it works, as in the mock.
    private static let hideCursor = esc + "?25l"

    private static var runningTranscript: String {
        faint + "~/repos/llm-opt" + reset + "\r\n"
            + "\r\n"
            + highlight + you + "❯ " + tag + "plotarmordev (via HerdrUp):" + reset + highlight + you
            + " can you rerun the" + eol
            + highlight + you + "TensorFold bench against our Q5 build and send" + eol
            + highlight + you + "me the table?" + eol
            + "\r\n"
            + blue + "●" + body + " Reading bench/tensorfold.sh" + reset + "\r\n"
            + blue + "●" + body + " Running bench/tensorfold.sh --q5 …" + reset + "\r\n"
            + body + "   decode   " + white + "41.2 tok/s" + body + "  " + green + "(+36%)" + reset + "\r\n"
            + body + "   prefill  " + white + "1,180 tok/s" + reset + "\r\n"
            + blue + "●" + body + " Writing results/tensorfold-q5.md" + reset + hideCursor
    }

    private static var blockedTranscript: String {
        faint + "~/repos/llm-opt" + reset + "\r\n"
            + "\r\n"
            + blue + "●" + body + " Writing results/tensorfold-q5.md" + reset + "\r\n"
            + amber + "?" + reset + " " + white + "Delete old results/tensorfold-*.md (3 files)?" + reset + "\r\n"
            + "  " + white + "❯ Yes" + reset + "\r\n"
            + body + "    No" + reset + hideCursor
    }

    private var transcript: String {
        scenario == .blocked ? Self.blockedTranscript : Self.runningTranscript
    }

    /// Rows in `history`, the scrollback from before the guest connected.
    static let historyRows = 200

    /// What `agent.read` (source recent) returns above the current screen: numbered rows,
    /// so a test can tell backfilled scrollback from anything the stream painted.
    private static var history: String {
        (1...historyRows).map { row in
            faint + "earlier " + String(format: "%03d", row) + body + "  warm-up bench pass" + reset + "\r\n"
        }.joined()
    }

    // MARK: - Wire helpers

    /// The host's guest projection of an `agent.read` reply: the rendered text and the
    /// fields HerdrKit decodes, nothing about the owner's workspace.
    private static func readLine(id: String, text: String) -> String {
        let reply: [String: Any] = ["id": id, "result": [
            "type": "pane_read",
            "read": ["pane_id": access.agentTarget, "source": "recent", "format": "ansi",
                     "text": text, "truncated": false],
        ]]
        guard let data = try? JSONSerialization.data(withJSONObject: reply) else {
            return errorLine(id: id, code: "internal_error", message: "mock read")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func errorLine(id: String, code: String, message: String) -> String {
        #"{"id":"\#(id)","error":{"code":"\#(code)","message":"\#(message)"}}"#
    }

    private static func encode(id: String, result: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": id, "result": result]) else {
            return errorLine(id: id, code: "internal_error", message: "mock encode")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The guest's projection of llm-opt's Gram since the grant: three of its Grams (one with
    /// the results file, two unread) and the guest's own attachment post. Read marks are the
    /// guest's own. Files are served in 1 KiB pieces, so a download takes several.
    private final class MockGram: @unchecked Sendable {
        static let chunkBytes = 1024
        private let lock = NSLock()
        private var messages: [[String: Any]]
        private var files: [String: (name: String, mime: String, data: Data)]
        private var postSeq = 0
        /// Bytes staged under each `upload_id` by `gram.upload_chunk`; a post consumes its upload.
        private var staged: [String: Int] = [:]
        /// `HERDR_MOCK_GUEST_STALE_UPLOAD`: the host has lost the first upload a post names, so
        /// that post is refused as one is after an earlier post already used its upload.
        private var loseNextUpload = ProcessInfo.processInfo.environment["HERDR_MOCK_GUEST_STALE_UPLOAD"] != nil
        /// `HERDR_MOCK_GUEST_POST_IN_PROGRESS=N`: the first N posts are refused with
        /// `upload_in_progress`, as the host does while it has not yet reaped the upload
        /// connection. The upload stays staged, so asking again succeeds.
        private var inProgressPosts =
            Int(ProcessInfo.processInfo.environment["HERDR_MOCK_GUEST_POST_IN_PROGRESS"] ?? "") ?? 0

        /// Whether this post is one `HERDR_MOCK_GUEST_POST_IN_PROGRESS` refuses.
        func refusesAsInProgress() -> Bool {
            lock.withLock {
                guard inProgressPosts > 0 else { return false }
                inProgressPosts -= 1
                return true
            }
        }

        /// `HERDR_MOCK_GUEST_OLDER_PAGE_FAILS_ONCE`: the Gram has an older page beyond the
        /// newest one, and the first ask for it fails (as a dropped relay hop or a busy store
        /// would); asking again answers it. The newest page then also carries 30 older
        /// fillers (gm-f1 newest), so the feed is taller than any screen and the older page is
        /// asked for only once the reader scrolls up to the top, as in a real Gram.
        private let olderPage: [[String: Any]]
        private var failOlderPage = ProcessInfo.processInfo.environment["HERDR_MOCK_GUEST_OLDER_PAGE_FAILS_ONCE"] != nil

        init() {
            let now = UInt64(Date().timeIntervalSince1970 * 1000)
            let minute: UInt64 = 60_000
            let table = Data(Self.resultsMarkdown.utf8)
            files = ["gm-4": ("tensorfold-q5.md", "text/markdown", table)]
            messages = [
                ["id": "gm-4", "direction": "agent_to_owner", "from": "llm-opt",
                 "text": "Here's the Q5 table: decode is up 36% over Q4, prefill flat.",
                 "created_unix_ms": now - 2 * minute, "read": false,
                 "file": ["name": "tensorfold-q5.md", "size": table.count, "mime": "text/markdown", "sha256": "5e1f"]],
                ["id": "gm-3", "direction": "owner_to_agent", "from": "plotarmordev (via HerdrUp)",
                 "text": "Attachment from plotarmordev.", "created_unix_ms": now - 9 * minute, "read": true,
                 "file": ["name": "prompt-set-v2.jsonl", "size": 49_152, "mime": "application/jsonl", "sha256": "77aa"]],
                ["id": "gm-2", "direction": "agent_to_owner", "from": "llm-opt",
                 "text": "Bench started on the Q5 build, about ten minutes.",
                 "created_unix_ms": now - 12 * minute, "read": false],
                ["id": "gm-1", "direction": "agent_to_owner", "from": "llm-opt",
                 "text": "Picked up plotarmordev's request for a TensorFold rerun.",
                 "created_unix_ms": now - 14 * minute, "read": true],
                // The host's store expired this caption-less picture's bytes (herdr#298).
                ["id": "gm-0", "direction": "agent_to_owner", "from": "llm-opt", "text": "",
                 "created_unix_ms": now - 20 * minute, "read": true,
                 "expired_file": ["name": "q4-baseline.png", "size": 873_472, "mime": "image/png", "sha256": "9c0d"]],
            ]
            guard ProcessInfo.processInfo.environment["HERDR_MOCK_GUEST_OLDER_PAGE_FAILS_ONCE"] != nil else {
                olderPage = []
                return
            }
            messages += (1...30).map { index in
                ["id": "gm-f\(index)", "direction": "agent_to_owner", "from": "llm-opt",
                 "text": "Rerun checkpoint \(index) saved.",
                 "created_unix_ms": now - (20 + UInt64(index)) * minute, "read": true]
            }
            olderPage = [
                ["id": "gm-older-1", "direction": "agent_to_owner", "from": "llm-opt",
                 "text": "Q4 baseline archived; starting on the Q5 build.",
                 "created_unix_ms": now - 60 * minute, "read": true],
                ["id": "gm-older-2", "direction": "agent_to_owner", "from": "llm-opt",
                 "text": "Joined the TensorFold rerun queue.",
                 "created_unix_ms": now - 70 * minute, "read": true],
            ]
        }

        /// The newest page (`beforeID` nil), or the older page below the newest one; nil
        /// when this ask is the one `HERDR_MOCK_GUEST_OLDER_PAGE_FAILS_ONCE` fails.
        func list(beforeID: String?) -> (messages: [[String: Any]], hasMore: Bool)? {
            lock.withLock {
                guard let beforeID else { return (messages, !olderPage.isEmpty) }
                guard messages.contains(where: { $0["id"] as? String == beforeID }) else { return ([], false) }
                if failOlderPage {
                    failOlderPage = false
                    return nil
                }
                return (olderPage, false)
            }
        }

        func markRead(_ ids: [String]) {
            lock.withLock {
                for index in messages.indices where ids.contains(messages[index]["id"] as? String ?? "") {
                    messages[index]["read"] = true
                }
            }
        }

        func stage(uploadID: String, bytes: Int) {
            lock.withLock { staged[uploadID, default: 0] += bytes }
        }

        /// Drops a staged upload; false when none is staged under that id.
        func discard(uploadID: String) -> Bool {
            lock.withLock { staged.removeValue(forKey: uploadID) != nil }
        }

        /// Stores the guest's post and returns the host's guest projection of it, or nil when
        /// its file's upload isn't staged (the host's `invalid_params`).
        func post(text: String, to: String,
                  file: (uploadID: String, name: String, mime: String)?) -> [String: Any]? {
            lock.withLock {
                var info: [String: Any]?
                if let file {
                    if loseNextUpload {
                        loseNextUpload = false
                        staged[file.uploadID] = nil
                    }
                    guard let size = staged.removeValue(forKey: file.uploadID) else { return nil }
                    info = ["name": file.name, "size": size, "mime": file.mime, "sha256": "1b00"]
                }
                postSeq += 1
                let id = "gp-\(postSeq)"
                let from = "plotarmordev (via HerdrUp)"
                let created = UInt64(Date().timeIntervalSince1970 * 1000)
                var stored: [String: Any] = [
                    "id": id, "direction": "owner_to_agent", "from": from,
                    "text": text, "created_unix_ms": created, "read": true,
                ]
                var projected: [String: Any] = [
                    "id": id, "from": from, "to": to, "text": text, "created_unix_ms": created,
                ]
                if let info {
                    stored["file"] = info
                    projected["file"] = info
                }
                messages.insert(stored, at: 0)
                return projected
            }
        }

        /// One piece of a visible file, in the host's `gram_file_chunk` shape; nil for a
        /// message the guest can't see or one without bytes here.
        func chunk(id: String, offset: Int) -> [String: Any]? {
            guard let file = lock.withLock({ files[id] }), offset >= 0, offset <= file.data.count else { return nil }
            let end = min(offset + Self.chunkBytes, file.data.count)
            return ["type": "gram_file_chunk", "name": file.name, "mime": file.mime, "size": file.data.count,
                    "sha256": "5e1f", "offset": offset,
                    "data_base64": file.data[offset..<end].base64EncodedString()]
        }

        private static var resultsMarkdown: String {
            var rows = ["# TensorFold · Q5 build", "", "| pass | decode tok/s | prefill tok/s |", "|---|---|---|"]
            for pass in 1...120 {
                rows.append("| \(pass) | \(41 + pass % 3).\(pass % 10) | 1,1\(80 + pass % 9) |")
            }
            rows += ["", "Decode is up 36% over the Q4 build; prefill is flat."]
            return rows.joined(separator: "\n")
        }
    }

    private static func object(_ requestLine: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(requestLine.utf8))) as? [String: Any]
    }

    private static func method(of requestLine: String) -> String {
        object(requestLine)?["method"] as? String ?? ""
    }

    private static func requestID(of requestLine: String) -> String {
        object(requestLine)?["id"] as? String ?? "mock"
    }

    private final class CallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []

        var calls: [String] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func append(_ method: String) {
            lock.lock()
            stored.append(method)
            lock.unlock()
        }
    }

    /// The shared agent's PTY and its one live stream. A locked resize changes the winsize
    /// and, like the agent's TUI on SIGWINCH, redraws at it: the in-band `resize` frame, then
    /// the repaint. An unchanged winsize sends nothing, as the host skips a no-op resize.
    private final class MockPTY: @unchecked Sendable {
        typealias Continuation = AsyncThrowingStream<String, Error>.Continuation
        private let lock = NSLock()
        private var cols = GuestMockTransport.cols
        private var rows = GuestMockTransport.rows
        private var seq: UInt64 = 1
        private var live: (token: UUID, continuation: Continuation)?

        var hasStream: Bool {
            lock.lock()
            defer { lock.unlock() }
            return live != nil
        }

        var geometry: (cols: Int, rows: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (cols, rows)
        }

        func attach(_ continuation: Continuation, token: UUID) -> (cols: Int, rows: Int) {
            lock.lock()
            defer { lock.unlock() }
            live = (token, continuation)
            return (cols, rows)
        }

        func detach(token: UUID) {
            lock.lock()
            if live?.token == token { live = nil }
            lock.unlock()
        }

        func nextSeq() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            seq += 1
            return seq
        }

        func resize(cols newCols: Int, rows newRows: Int, redraw: String) {
            lock.lock()
            guard newCols != cols || newRows != rows else {
                lock.unlock()
                return
            }
            cols = newCols
            rows = newRows
            let resizeSeq = seq + 1
            seq += 2
            let continuation = live?.continuation
            lock.unlock()
            // Yielded outside the lock: a terminating stream detaches under it.
            let repaint = Data(("\u{1b}[H\u{1b}[2J" + redraw).utf8).base64EncodedString()
            continuation?.yield(#"{"stream":"pane.bytes","frame":"resize","seq":\#(resizeSeq),"epoch":3,"cols":\#(newCols),"rows":\#(newRows)}"#)
            continuation?.yield(#"{"stream":"pane.bytes","frame":"data","seq":\#(resizeSeq + 1),"epoch":3,"data_b64":"\#(repaint)"}"#)
        }
    }
}

/// The guest pane over the mock host, holding what `GuestHomeView` holds for a live share:
/// the features the host advertises and the pane's tab.
struct GuestPaneMockHost: View {
    let scenario: GuestMockTransport.Scenario
    @StateObject private var features = GuestFeaturesModel()
    @State private var tab: GuestPaneTab = .terminal

    var body: some View {
        GuestPaneView(
            client: HerdrClient(transport: GuestMockTransport(scenario: scenario, onFeatures: features.sink())),
            access: GuestMockTransport.access, features: features, tab: $tab, onClose: {})
    }
}
#endif
