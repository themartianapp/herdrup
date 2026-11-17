import SwiftUI
import Foundation
import UIKit    // UIPasteboard (Copy diagnostics)
import UniformTypeIdentifiers
import StoreKit // Product / tip jar (Settings' Support section)
import UserNotifications // notification authorization status (Settings notify section)
import HerdrKit

#if DEBUG
/// Canned-response transport for the screenshot mock. Its wire answers are
/// `MockWireFixtures` (Tests/HerdrKitTests/MockWireFixtures.swift, compiled into this
/// target too), which MockWireFixtureTests decodes through the real HerdrClient path
/// (the app target can't be compiled on Linux).
struct MockTransport: HerdrTransport {
    /// When true, `pane.stream` seeds MANY lines of scrollback (for the omp UI scroll
    /// receipt) instead of the short screenshot seed. Default false keeps the
    /// buildbox screenshot fixtures unchanged.
    var scrollback = false
    /// When set, this pane is a Claude-Code stand-in (mouse-mode on the normal buffer) that
    /// scrolls in RESPONSE to SGR wheel events the app sends — for the ccscroll receipt.
    var ccDriver: CCScrollDriver?
    /// When true, `pane.stream` keeps APPENDING output after the seed, so SwiftTerm's
    /// auto-follow writes `contentOffset` on every frame. The busy-pane state: the scroll-tap
    /// guard must still let a tap take focus here, and two earlier versions of it did not.
    var busyOutput = false
    /// When true, `agent.read` (source=recent, ansi) returns MANY numbered lines of history
    /// while `pane.stream` seeds only the SHORT one-screen reset — so the scrollback a swipe
    /// reveals can ONLY come from the connect-time backfill path. For the backfill receipt.
    var backfill = false
    /// When set, `pane.stream` carries history only inside its keyframes and `agent.read`
    /// returns none; see `KeyframeHistoryDriver`. For the reconnect and redundant-read receipts.
    var keyframeHistory: KeyframeHistoryDriver?
    /// When set, `pane.stream` and `pane.history` page older history; see `HistoryPagingDriver`.
    var historyPaging: HistoryPagingDriver?
    /// Stateful agent-list source for the refresh-during-scroll regression receipt.
    var rosterDriver: RosterStressDriver?
    var interactionDriver: TerminalInteractionDriver?
    /// Stateful daemon for the live status stream receipt (ping, agent.list and
    /// the all-panes events.subscribe); other requests fall through to the canned
    /// answers below.
    var liveEventsDriver: LiveEventsDriver?

    func roundTrip(_ requestLine: String) async throws -> String {
        if let interactionDriver {
            return try await interactionDriver.roundTrip(requestLine)
        }
        if let liveEventsDriver, let answer = await liveEventsDriver.answer(requestLine) {
            return answer
        }
        // ccscroll receipt: any request may carry an SGR wheel event the app sent
        // (via sendText); the driver scrolls the stand-in Claude Code if so.
        ccDriver?.received(requestLine)
        if let avatar = AgentAvatarMockServer.answer(requestLine) { return avatar }
        if AgentAvatarMockServer.enabled, requestLine.contains(#""method":"ping""#) {
            return #"{"id":"mock","result":{"type":"pong","version":"0.9.4","protocol":22,"capabilities":{"agent_avatar":true}}}"#
        }
        // `HERDR_MOCK_TURN_ORIGIN=1`: a herdr that keeps turn origins, so Settings' "Only my
        // requests" has no fallback note. Unset, the mock's ping predates capabilities.
        if ProcessInfo.processInfo.environment["HERDR_MOCK_TURN_ORIGIN"] == "1",
           requestLine.contains(#""method":"ping""#) {
            return #"{"id":"mock","result":{"type":"pong","version":"0.9.4","protocol":22,"capabilities":{"turn_origin":true}}}"#
        }
        if requestLine.contains("notifications.status") { return Self.notificationsStatus }
        if requestLine.contains("accounts.list") { return MockWireFixtures.accountsList }
        if requestLine.contains("agent.list") {
            if let rosterDriver {
                return try await rosterDriver.nextAgentList()
            }
            return AgentAvatarMockServer.overlay(MockWireFixtures.agentList)
        }
        if requestLine.contains("pane.history"), let historyPaging {
            return try await historyPaging.page(requestLine)
        }
        if requestLine.contains("agent.read") {
            if let keyframeHistory { return try await keyframeHistory.read(requestLine) }
            return backfill ? Self.backfillRead() : MockWireFixtures.agentRead
        }
        if requestLine.contains("gram.mark_read") {
            Self.gramOwnerReads.markRead(Self.requestParamID(requestLine))
            return #"{"id":"mock","result":{}}"#
        }
        if requestLine.contains("gram.list") {
            // Read state as of when the request arrived, as the daemon computes it.
            let reads = Self.gramOwnerReads.ids
            let list: String
            if Self.gramPaged { list = Self.gramPagedList(requestLine) }
            else if Self.gramImageCount > 0 { list = Self.gramListWithImages }
            else if Self.gramExpiresSaved { list = await Self.gramListExpiringSaved() }
            else if Self.gramHtml { list = Self.gramListWithHtml }
            else { list = Self.gramNewer ? Self.gramListWithNewer : MockWireFixtures.gramList }
            let answer = Self.applyingOwnerReads(reads, to: Self.gramAllRead ? Self.markingAllRead(list) : list)
            if Self.gramHoldsPollAcrossRead, Self.isGramHeadPoll(requestLine) {
                await Self.gramOwnerReads.holdPastNextRead()
            }
            return answer
        }
        if requestLine.contains("gram.post") {
            return Self.recordGramPost(requestLine) ? MockWireFixtures.gramPosted : Self.gramPostRefused
        }
        if requestLine.contains("gram.get_file") {
            let id = Self.recordGramGetFile(requestLine)
            if let delay = Self.gramFileDelay(for: id) {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            // g3 is the list fixture's image, and `gi<n>` the image mock's: a real PNG, so
            // the card decodes a preview. gh1 is the HTML mock's report.
            if id == "gh1" { return MockWireFixtures.gramHtmlContent }
            return id == "g3" || id.hasPrefix("gi") ? Self.gramImageContent : MockWireFixtures.gramFileContent
        }
        if requestLine.contains("gram.upload.discard") {
            return #"{"id":"mock","result":{"type":"gram_upload_discarded","discarded":true}}"#
        }
        if requestLine.contains("gram.upload_chunk") { return MockWireFixtures.gramOk }
        if requestLine.contains("gram.delete") { return MockWireFixtures.gramOk }
        if requestLine.contains("agent.prompt") { return Self.agentPrompted }
        if requestLine.contains("pane.set_pty_size") { return MockWireFixtures.panePtySize }
        return #"{"id":"mock","result":{}}"#
    }

    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        if let interactionDriver { return interactionDriver.stream(requestLine) }
        if let liveEventsDriver, requestLine.contains("events.subscribe") {
            return liveEventsDriver.stream()
        }
        // `pane.stream` (the live terminal): reply with the stream_started ack, then a reset
        // seed, then STAY OPEN — so the DEBUG pane shows a rendered SwiftTerm terminal, not an
        // empty one. The scrollback seed (UI test) feeds 200 lines so there is real history to
        // scroll; the default seed is the short screenshot one.
        //
        // IT MUST NOT FINISH, and finishing was a real fixture defect with a long tail. A live
        // `pane.stream` never ends, so the app treats an ended stream as a DROP and reconnects
        // with capped backoff — correct product behaviour. Against a mock that finished
        // immediately, every reconnect re-delivered the reset and appended another 200 lines,
        // forever. Measured in CI at head 18e1daca: the probe reported ydisp=3598 in one pass and
        // ydisp=3777 in the next, a buffer of thousands of lines in a fixture that seeds 200, and
        // growing by one seed per reconnect between passes.
        //
        // The consequences all looked like unrelated bugs:
        //   - The scroll view's contentSize tracked roughly 200 lines while `yDisp` ran past 3500,
        //     so a tap resolved to buffer row 186 while the DRAWN window was 3598...3621. The
        //     selection was real and off-screen, which is why the highlight was never painted and
        //     why four rounds of hunting in SwiftTerm's renderer found nothing wrong with it.
        //   - `testBackfillMakesHistoryScrollable`'s "terminal is static when untouched" premise
        //     failed at diff 0.08549 against a 0.02 ceiling, because content genuinely kept
        //     arriving.
        //
        // Not finishing is sufficient: the stream's storage holds the continuation for as long as
        // the consumer iterates, so the pane simply waits for frames that never come — exactly
        // what a quiet live pane looks like. This is what the ccDriver branch below has always
        // done, for the same reason.
        if requestLine.contains("pane.stream") {
            if let historyPaging { return historyPaging.stream() }
            if let keyframeHistory { return keyframeHistory.stream() }
            if let driver = ccDriver {
                // Claude-Code stand-in: keep the stream OPEN so the driver can push
                // redraws in response to wheel events the app sends.
                //
                // IT PINGS TOO, for the same reason the plain branch does. A review flagged this
                // branch as the remaining instance of the defect class the plain branch just fixed:
                // held open but SILENT, so a ccDriver pane left idle past the 50s stall
                // watchdog would be re-seeded mid-test. No current test mounts one that long, so
                // this is latent rather than active — which is exactly when it is cheap to close,
                // and leaving one branch of a two-branch function wrong is how the plain branch's
                // bug survived as long as it did.
                return AsyncThrowingStream { continuation in
                    continuation.yield(MockWireFixtures.paneStreamAck)
                    driver.attach(continuation)
                    let pings = Self.keepAlive(continuation)
                    continuation.onTermination = { _ in pings.cancel() }
                }
            }
            let reset = scrollback ? Self.scrollbackResetFrame() : MockWireFixtures.paneStreamReset
            return AsyncThrowingStream { continuation in
                continuation.yield(MockWireFixtures.paneStreamAck)
                continuation.yield(reset)
                // AND THEN KEEP PINGING, because silence is not the same as being alive.
                //
                // Removing finish() stopped the reconnect-on-stream-end loop, but left this mock
                // MUTE — and the app's stall watchdog treats a mute stream as a stuck one. It
                // polls every 5s and, at 50s without any event (streamStuckTimeout), writes
                // "no response for 50s; reconnecting…" into the terminal and re-runs start(),
                // which delivers another ack and another 200-line reset. So the re-seed returned
                // by a slower route: a review measured testTerminalScrollsWhenSwiped taking 85.5s
                // against this fixture with the pane mounted from launch, which is well past the
                // 50s threshold.
                //
                // A real daemon pings about every 20s, which is what the 50s timeout is sized
                // against (2.5x, so one dropped ping is tolerated). The fixture now does the same
                // thing, and `.ping` is a first-class frame in the wire protocol
                // (HerdrKit/Wire.swift:649, decoded at :705) carrying nothing but seq and epoch —
                // so it refreshes lastStreamActivity without touching the emulator, the buffer, or
                // the rendered frame. That last property matters: several UI tests assert the
                // terminal is byte-identical when untouched, so a keepalive that DREW anything
                // would trade one false failure for another.
                let pings = Self.keepAlive(continuation)
                // BUSY-PANE OUTPUT: emit a line about eight times a second so SwiftTerm's
                // auto-follow writes `contentOffset` on every frame, growing scrollback exactly
                // as a working agent's does.
                //
                // FRAME TYPE IS `data`, and getting that wrong is why the first version of this
                // mock produced NOTHING. StreamFrame accepts only reset/data/resize/ping/exited
                // (Wire.swift:708-729) and decoding is deliberately STRICT — an unknown frame
                // throws, which tears the stream down and reconnects, so my invented "append"
                // yielded a reconnect loop and no output at all. The busy-pane test caught it by
                // measuring its own premise (ydisp must advance) rather than assuming it.
                //
                // EVERY LINE LOOKS DIFFERENT, for the reason `scrollbackResetFrame` records.
                // The lines used to share one sentence, so once the screen was full of them a
                // 2 s window of real streaming (~16 rows of scroll) changed only the digits:
                // CI 37732782216 measured diff=0.002 against the receipt's 0.005 floor while
                // its attached screenshots showed lines 0003-0036 become 0023-0056. A per-line
                // letter and bar length make a scroll change most rows, and the bar stays short
                // enough not to wrap on a portrait iPhone grid.
                let busy = Task { [busyOutput] in
                    guard busyOutput else { return }
                    var n = 1
                    var seq: UInt64 = 10_000
                    let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        guard !Task.isCancelled else { break }
                        let letter = letters[n % letters.count]
                        let bar = String(repeating: letter, count: 4 + (n * 7) % 26)
                        let line = String(format: "BUSY line %04d %@ %@\r\n", n, String(letter), bar)
                        let b64 = Data(line.utf8).base64EncodedString()
                        continuation.yield("{\"stream\":\"pane.bytes\",\"frame\":\"data\",\"seq\":\(seq),\"epoch\":7,\"data_b64\":\"\(b64)\"}")
                        n += 1; seq += 1
                    }
                }
                // Stop pinging when the consumer goes away, so a torn-down pane does not leave a
                // timer running for the life of the process.
                continuation.onTermination = { _ in pings.cancel(); busy.cancel() }
                // DELIBERATELY NO finish(): a finished stream is a dropped stream. See above.
            }
        }
        return AsyncThrowingStream { $0.finish() }
    }

    /// A reset frame carrying 200 DISTINCT numbered lines so the terminal has real
    /// scrollback and a swipe visibly changes the rendered content. Hides the cursor
    /// (ESC[?25l) so an un-swiped terminal renders byte-identically frame to frame —
    /// which makes the UI test's "did the content move?" an exact before/after image
    /// compare with no blinking-cursor false positive. Same reset shape as
    /// `paneStreamReset`; base64 built at runtime (DEBUG/UI-test-only, not a fixture).
    ///
    /// EVERY ROW LOOKS DIFFERENT, not just its three-digit number. The rows used to
    /// share one sentence, so a real scroll of a whole screen changed only the digits:
    /// measured at head 45ba03b the pixel difference after three firm drags was 0.0289
    /// against ScrollTests' 0.10 floor, and the receipt failed while the screenshots it
    /// attached showed the top line moving from 170 to 085 — a working scroll reported
    /// as the dead-scroll symptom. A per-row letter and a per-row bar length make a
    /// one-screen shift change most of the pixels, so the floor now separates a real
    /// scroll from a dead one instead of separating nothing.
    static func scrollbackResetFrame() -> String {
        var body = "\u{1b}[?25l"   // hide cursor: static frames stay byte-identical
        for i in 1...200 { body += Self.variedLine("SCROLLTEST", i, digits: 3) }
        body += "SCROLLTEST end, swipe down to reveal earlier lines"
        let b64 = Data(body.utf8).base64EncodedString()
        return "{\"stream\":\"pane.bytes\",\"frame\":\"reset\",\"seq\":0,\"epoch\":7,\"cols\":80,\"rows\":24,\"data_b64\":\"\(b64)\"}"
    }

    /// An `agent.read` response (source=recent, format=ansi) carrying ~1000 DISTINCT numbered
    /// lines as ANSI — the history the app's connect-time backfill prepends into SwiftTerm's
    /// scrollback. `\r\n` endings (no staircase), cursor hidden (ESC[?25l) so static frames stay
    /// byte-identical for the before/after image compare. Built at runtime (DEBUG/UI-test only);
    /// JSONSerialization escapes the ESC + control bytes in the `text` field.
    ///
    /// Rows differ by more than their number, for the reason `scrollbackResetFrame`
    /// records: one shared sentence made a real one-screen scroll a ~3% pixel change,
    /// which is not a signal the receipt's 10% floor can read.
    static func backfillRead() -> String {
        var body = "\u{1b}[?25l"   // hide cursor: static frames stay byte-identical
        for i in 1...1000 { body += Self.variedLine("BACKFILL", i, digits: 4) }
        body += "BACKFILL end, swipe down to reveal earlier lines"
        let payload: [String: Any] = ["id": "mock", "result": ["read": [
            "pane_id": "w1:p1", "text": body, "truncated": false,
            "source": "recent", "format": "ansi"]]]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return String(data: data, encoding: .utf8) ?? MockWireFixtures.agentRead
    }

    /// Row `n` of the scroll and backfill fixtures: "<prefix> line <n> <letter> <bar>", the
    /// letter and the bar length (8 + (n*7) % 44) varying with `n` so a one-screen scroll
    /// changes most of the pixels (see `scrollbackResetFrame`). `digits` zero-pads `n`.
    /// The busy-output lines use a different bar on purpose and do not come from here.
    static func variedLine(_ prefix: String, _ n: Int, digits: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let letter = letters[n % letters.count]
        let bar = String(repeating: letter, count: 8 + (n * 7) % 44)
        return String(format: "\(prefix) line %0\(digits)d %@ %@\r\n", n, String(letter), bar)
    }

    /// `notifications.status` for the Settings mock. `HERDR_MOCK_PUSH_STATE` picks the daemon's
    /// answer: a status `state` (default `relay_ready`), or `legacy` for a daemon that predates
    /// the method and rejects the request line. Both shapes are decoded in PushRelayTests.
    static var notificationsStatus: String {
        let state = ProcessInfo.processInfo.environment["HERDR_MOCK_PUSH_STATE"] ?? "relay_ready"
        if state == "legacy" {
            return #"{"id":"","error":{"code":"invalid_request","message":"invalid request: unknown variant `notifications.status`"}}"#
        }
        return #"{"id":"mock","result":{"type":"notifications_status","state":"\#(state)","mode":"auto","relay_url":"https://push.herdrup.app","devices":1,"relay_devices":1}}"#
    }

    /// `MockWireFixtures.agentRead` under its old name, for the agent.read callers not yet
    /// moved (their lines are being edited on another branch).

    /// `HERDR_MOCK_GRAM_PAGED=1`: `gram.list` answers as a store two pages deeper than
    /// `gramList`, so the Gram paging UI test can scroll to the top. The first page is
    /// `gramList`'s rows with `has_more`, so its oldest row (g9) is the cursor; `before_id`
    /// g9 answers `gramOlderRows` (24 rows, more than a screen, `has_more`), and `before_id` go24 answers
    /// `gramOldestRows` (one row, the end). Mirrored in MockWireFixtureTests, where every
    /// answer is machine-checked to decode and page contiguously.
    static var gramPaged: Bool {
        ProcessInfo.processInfo.environment["HERDR_MOCK_GRAM_PAGED"] == "1"
    }

    static func gramPagedList(_ requestLine: String) -> String {
        if requestLine.contains(#""before_id":"g9""#) {
            GramPagingMock.shared.served(1)
            return MockWireFixtures.gramListAnswer(rows: [MockWireFixtures.gramOlderRows], hasMore: true)
        }
        if requestLine.contains(#""before_id":"go24""#) {
            GramPagingMock.shared.served(2)
            return MockWireFixtures.gramListAnswer(rows: [MockWireFixtures.gramOldestRows], hasMore: false)
        }
        // A head poll asks for max(page, loaded) rows, so a daemon's answer covers every page
        // the client already holds. Answering with the first page alone would cut the older
        // rows off the list on the next poll.
        let pages = [MockWireFixtures.gramListRows, MockWireFixtures.gramOlderRows, MockWireFixtures.gramOldestRows].prefix(GramPagingMock.shared.depth + 1)
        return MockWireFixtures.gramListAnswer(rows: Array(pages), hasMore: pages.count < 3)
    }

    /// `MockWireFixtures.gramPosted` under its old name, for the gram.post caller not yet
    /// moved (its line is being edited on another branch).

    /// Every `gram.post` the app sent, in order: its `to` (nil for the shared queue), its
    /// `text`, and its attachment as `name@upload_id`. Read by the Gram UI tests via
    /// GramView's DEBUG `gram-post-calls` probe.
    static var gramPostLog: [(to: String?, text: String, file: String?)] { gramPostRecorder.posts }

    /// `gramPostLog` as the probe's accessibility value: one `to=<name|queue> text=<text>`
    /// per post, plus ` file=<name>@<upload_id>` for an attachment, separated by newlines.
    static var gramPostLogSummary: String {
        gramPostLog.map { post in
            "to=\(post.to ?? "queue") text=\(post.text)" + (post.file.map { " file=\($0)" } ?? "")
        }.joined(separator: "\n")
    }

    /// The refusal `HERDR_MOCK_GRAM_POST_FAIL` answers an attachment post with.
    static let gramPostRefused =
        #"{"id":"mock","error":{"code":"internal","message":"The gram store is busy."}}"#

    private static let gramPostRecorder = GramPostRecorder()

    /// `gram.get_file` calls answered per message id, for GramView's DEBUG
    /// `gram-get-file-calls` probe: "g2=0 g3=1 g11=0 g12=0", the list fixture's two files
    /// and two expired files always listed, then any other id asked for.
    static var gramGetFileSummary: String {
        let counts = gramGetFileRecorder.counts
        let listed = ["g2", "g3", "g11", "g12"]
        let ids = listed + counts.keys.filter { !listed.contains($0) }.sorted()
        return ids.map { "\($0)=\(counts[$0] ?? 0)" }.joined(separator: " ")
    }

    /// `HERDR_MOCK_GRAM_EXPIRE_SAVED=1`: the store expires the list fixture's files (g2's zip,
    /// g3's image) once the owner has saved their message, so the next `gram.list` answers a
    /// saved one with its file as `expired_file` (herdr#298). A copy saved while its file was
    /// live must then stop offering it in Saved.
    static var gramExpiresSaved: Bool {
        ProcessInfo.processInfo.environment["HERDR_MOCK_GRAM_EXPIRE_SAVED"] == "1"
    }

    @MainActor
    static func gramListExpiringSaved() -> String {
        var list = MockWireFixtures.gramList
        for (id, name) in [("g2", "amigo-poc-scaffold.zip"), ("g3", "vetrina-live.png")]
        where SavedGramStore.shared.isSaved(id) {
            list = list.replacingOccurrences(of: #""file":{"name":"\#(name)""#,
                                             with: #""expired_file":{"name":"\#(name)""#)
        }
        return list
    }

    private static let gramGetFileRecorder = GramGetFileRecorder()

    private static func recordGramGetFile(_ requestLine: String) -> String {
        let id = requestParamID(requestLine)
        gramGetFileRecorder.record(id)
        return id
    }

    /// The request's `params.id` ("" when absent).
    private static func requestParamID(_ requestLine: String) -> String {
        let object = (try? JSONSerialization.jsonObject(with: Data(requestLine.utf8))) as? [String: Any]
        return (object?["params"] as? [String: Any])?["id"] as? String ?? ""
    }

    /// The ids `gram.mark_read` has marked: like the daemon, later `gram.list` answers report
    /// them read. Without this every poll after a Read all put the count straight back.
    private static let gramOwnerReads = GramOwnerReads()

    /// `list` with the messages in `reads` marked read and `unread_count`, when the answer
    /// carries one, lowered to match. Untouched (byte for byte) while nothing was read.
    private static func applyingOwnerReads(_ reads: Set<String>, to list: String) -> String {
        guard !reads.isEmpty,
              var object = (try? JSONSerialization.jsonObject(with: Data(list.utf8))) as? [String: Any],
              var result = object["result"] as? [String: Any],
              var messages = result["messages"] as? [[String: Any]]
        else { return list }
        var newlyRead = 0
        for index in messages.indices {
            guard let id = messages[index]["id"] as? String, reads.contains(id),
                  messages[index]["direction"] as? String == "agent_to_owner",
                  messages[index]["read_by_owner"] as? Bool == false else { continue }
            messages[index]["read_by_owner"] = true
            newlyRead += 1
        }
        result["messages"] = messages
        if let count = result["unread_count"] as? Int { result["unread_count"] = max(0, count - newlyRead) }
        object["result"] = result
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return list }
        return String(decoding: data, as: UTF8.self)
    }

    /// `HERDR_MOCK_GRAM_HOLD_POLL=1`: every head `gram.list` after the page's first (its
    /// polls, a Refresh) is answered with the read state of when it ARRIVED, held until a
    /// second after the next `gram.mark_read` (or 4 s without one). A Refresh tapped just
    /// before Read all is then in flight across the pass and lands after it, as a slow
    /// round trip can.
    static var gramHoldsPollAcrossRead: Bool {
        ProcessInfo.processInfo.environment["HERDR_MOCK_GRAM_HOLD_POLL"] == "1"
    }

    /// The page's own refresh: not Read all's `unread_only` fetch, not an older page.
    private static func isGramHeadPoll(_ requestLine: String) -> Bool {
        !requestLine.contains("\"unread_only\":true") && !requestLine.contains("\"before_id\"")
    }

    /// `HERDR_MOCK_GRAM_FILE_DELAY=g3=10`: seconds `gram.get_file` waits before answering
    /// for that id (comma-separated pairs), so a UI test can hold a download in flight.
    private static func gramFileDelay(for id: String) -> Double? {
        guard let spec = ProcessInfo.processInfo.environment["HERDR_MOCK_GRAM_FILE_DELAY"] else { return nil }
        for pair in spec.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0] == id, let seconds = Double(parts[1]) { return seconds }
        }
        return nil
    }

    /// `HERDR_MOCK_GRAM_NEWER=1`: `gram.list` answers `gramList` with `gramNewerRows` above
    /// its newest message, so the image (g3) sits above the fold on every device when the
    /// feed opens at the newest. `=unread`: the newer agent messages are unread too, so more
    /// unread messages lie below the fold than one screen from the first unread shows.
    static var gramNewer: Bool { gramNewerSetting == "1" || gramNewerSetting == "unread" }

    private static var gramNewerSetting: String? {
        ProcessInfo.processInfo.environment["HERDR_MOCK_GRAM_NEWER"]
    }

    static var gramListWithNewer: String {
        MockWireFixtures.gramList.replacingOccurrences(
            of: #""messages":["#,
            with: #""messages":["# + gramNewerRows(unread: gramNewerSetting == "unread") + ",")
    }

    /// `HERDR_MOCK_GRAM_READ=1`: every message in `gram.list` answers read, so the feed has
    /// nothing unread and opens at the newest message.
    static var gramAllRead: Bool {
        ProcessInfo.processInfo.environment["HERDR_MOCK_GRAM_READ"] == "1"
    }

    private static func markingAllRead(_ list: String) -> String {
        list.replacingOccurrences(of: #""read_by_owner":false"#, with: #""read_by_owner":true"#)
    }

    /// `HERDR_MOCK_GRAM_HTML=1`: `gram.list` answers `gramList` with `gramHtmlRow` above its
    /// newest message: an HTML file, which opens in the web viewer rather than QuickLook.
    static var gramHtml: Bool {
        ProcessInfo.processInfo.environment["HERDR_MOCK_GRAM_HTML"] == "1"
    }

    static var gramListWithHtml: String {
        MockWireFixtures.gramList.replacingOccurrences(of: #""messages":["#, with: #""messages":["# + MockWireFixtures.gramHtmlRow + ",")
    }

    /// `HERDR_MOCK_GRAM_IMAGES=N`: `gram.list` answers `gramList` with N image messages (each
    /// `gram.get_file` answers the g3 PNG) above its newest message, each followed by a
    /// three-line text, so a scroll through the feed keeps carrying pictures on and off screen.
    static var gramImageCount: Int {
        Int(ProcessInfo.processInfo.environment["HERDR_MOCK_GRAM_IMAGES"] ?? "") ?? 0
    }

    static var gramListWithImages: String {
        let rows = (1...gramImageCount).reversed().map { n in
            let at = 1723041360000 + UInt64(n) * 120_000
            let text = #"{"id":"gt\#(n)","direction":"agent_to_owner","from":"vetrina","text":"Frame \#(n) notes.\nLine two.\nLine three.","created_unix_ms":\#(at + 60_000),"read_by_owner":true}"#
            let image = #"{"id":"gi\#(n)","direction":"agent_to_owner","from":"vetrina","text":"","created_unix_ms":\#(at),"read_by_owner":true,"file":{"name":"frame-\#(n).png","size":413,"mime":"image/png","sha256":"9f2c0a1b7d3e4f5061728394a5b6c7d8e9f0a1b2c3d4e5f60718293a4b5c6d7e"}}"#
            return text + "," + image
        }.joined(separator: ",")
        return MockWireFixtures.gramList.replacingOccurrences(of: #""messages":["#, with: #""messages":["# + rows + ",")
    }

    /// Fourteen five-line messages, newer than g1 and newest first: taller together than any
    /// screen the tests run on. Read, or with the agents' seven unread.
    static func gramNewerRows(unread: Bool) -> String {
        (1...14).reversed().map { n in
            let fromAgent = !n.isMultiple(of: 2)
            let from = fromAgent
                ? #""direction":"agent_to_owner","from":"vetrina""#
                : #""direction":"owner_to_agent","from":"owner","to":"vetrina""#
            let read = !(unread && fromAgent)
            return #"{"id":"gn\#(n)",\#(from),"text":"Status \#(n).\nLine two.\nLine three.\nLine four.\nLine five.","created_unix_ms":\#(1723041360000 + n * 60000),"read_by_owner":\#(read)}"#
        }.joined(separator: ",")
    }

    /// Records a `gram.post`; false when the post is to be refused.
    private static func recordGramPost(_ requestLine: String) -> Bool {
        let object = (try? JSONSerialization.jsonObject(with: Data(requestLine.utf8))) as? [String: Any]
        let params = object?["params"] as? [String: Any] ?? [:]
        let file = (params["file"] as? [String: Any]).map {
            "\($0["name"] as? String ?? "")@\($0["upload_id"] as? String ?? "")"
        }
        return gramPostRecorder.append(
            to: params["to"] as? String, text: params["text"] as? String ?? "", file: file)
    }

    /// The `gram.get_file` reply for the list fixture's image (g3): a 32 x 18 gradient PNG,
    /// small enough to inline, real enough for the card's ImageIO decode.
    static let gramImageContent =
        #"{"id":"mock","result":{"type":"gram_file_content","name":"vetrina-live.png","mime":"image/png","size":413,"data_base64":"iVBORw0KGgoAAAANSUhEUgAAACAAAAASCAIAAAC1qksFAAABZElEQVR42o2SPUsDQRCGZ+b+lkUKkQgKKQIKYhpLO4lIAgqmsrK0UBC0sLVXRMTCwsLCwsb/st5tbvfma3NCCHOz7zvPzOzixtovYaiaH1RkAgxEbVDlgAmIKSurJMDNwU+ytU7Kn8TyyeZ0I5UkWgm4vf5N6BQSBlWuhBTsBBgNv7QNA2m1h0QP2axUZHC89akrGltPRc/SAXZGH05FsIZegUFCBOyN38UEYGxghgCNjDxJShmc7L7abOwR3HyM2cWKIzZBBhzsP7dZtyLwHjuADUgtIE2J08On9kOe6YoKCektmbxoFwLeXLwlABttBVIIugx5lgZwd/li1U0G4sXqIzZBgdS1u3xF57PHfExKLQNibDFlCbkETI8e/IqQ3pKty5GOl01Qr+jk+J6LiPMNkjhAKXM30oLz2a1sTU1Qrgh5LUwgATUSz06vxcWqir1IGaSVsgkWiysqqP+DXO2t//8AaXuKJu4OmmAAAAAASUVORK5CYII="}}"#

    static let agentPrompted =
        #"{"id":"mock","result":{"type":"agent_prompted","delivery":"submitted"}}"#


    /// `MockWireFixtures.paneStreamAck` under its old name, for the stream caller not yet
    /// moved (its neighbours are being edited on another branch).
    /// A keepalive `pane.stream` ping, the frame a real daemon sends about every 20s and the one
    /// the 50s stall watchdog is sized against. Carries only `seq` and `epoch`
    /// (HerdrKit/Wire.swift:705 decodes exactly those), so it proves the stream is alive without
    /// touching the emulator or changing a single rendered pixel — which several UI tests depend
    /// on, since they assert the terminal is byte-identical while untouched.
    static func paneStreamPing(seq: UInt64, epoch: UInt64) -> String {
        #"{"stream":"pane.bytes","frame":"ping","seq":\#(seq),"epoch":\#(epoch)}"#
    }

    /// Sends `paneStreamPing` on `continuation` every 20 s, as the server does, until the
    /// returned task is cancelled; every open mock stream needs it, because the app's stall
    /// watchdog treats a silent stream as a stuck one (see `stream(_:)`). The caller cancels
    /// the task in `onTermination`.
    static func keepAlive(_ continuation: AsyncThrowingStream<String, Error>.Continuation) -> Task<Void, Never> {
        Task {
            var seq: UInt64 = 1
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)   // 20s, like the server
                guard !Task.isCancelled else { break }
                continuation.yield(paneStreamPing(seq: seq, epoch: 7))
                seq += 1
            }
        }
    }

    /// A decoded blocked agent for the pane screenshot: status "blocked" groups
    /// as NEEDS YOU, so the pane renders its status badge. No composer field, so
    /// input falls to rawKeys — fine for a static shot.
    static let demoPaneAgent: AgentInfo? = try? JSONDecoder().decode(
        AgentInfo.self,
        from: Data(#"{"pane_id":"w1:p1","name":"jarvis","agent":"claude","agent_status":"blocked","cwd":"/root/herdr-ios","terminal_title_stripped":"asking to run tests"}"#.utf8))

    /// A distinctively-named agent for the `paging` receipt. Name == kind == cwd folder (all the same
    /// distinctive word), so the deduped header heading collapses to just that word (e.g. "ALFA") —
    /// which an XCUITest asserts CHANGES after a swipe fronts the neighbour. The `frontIs` CONTAINS
    /// match still keys off that word. Force-decoded: the literal is fixed + valid.
    static func pagingAgent(kind: String, pane: String) -> AgentInfo {
        try! JSONDecoder().decode(AgentInfo.self, from: Data(
            #"{"pane_id":"\#(pane)","name":"\#(kind)","agent":"\#(kind)","agent_status":"idle","cwd":"/root/\#(kind)"}"#.utf8))
    }
}

/// The `gram.post` calls MockTransport answered (`to`, `text`, and `name@upload_id` for an
/// attachment), in order, shared across the transport values the app builds. Read through
/// `MockTransport.gramPostLog`.
final class GramPostRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(to: String?, text: String, file: String?)] = []
    /// `HERDR_MOCK_GRAM_POST_FAIL=N`: the first N attachment posts are refused.
    private var failures = Int(ProcessInfo.processInfo.environment["HERDR_MOCK_GRAM_POST_FAIL"] ?? "") ?? 0

    var posts: [(to: String?, text: String, file: String?)] { lock.withLock { stored } }

    /// Records the post; false when `HERDR_MOCK_GRAM_POST_FAIL` refuses it.
    func append(to: String?, text: String, file: String?) -> Bool {
        lock.withLock {
            stored.append((to: to, text: text, file: file))
            guard file != nil, failures > 0 else { return true }
            failures -= 1
            return false
        }
    }
}

/// The mock daemon's read state: the ids `gram.mark_read` marked, which later `gram.list`
/// answers report read (`MockTransport.applyingOwnerReads`), plus what
/// `HERDR_MOCK_GRAM_HOLD_POLL` needs to hold a poll across the next mark.
final class GramOwnerReads: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Set<String> = []
    private var marks = 0
    private var headLists = 0

    var ids: Set<String> { lock.withLock { stored } }

    func markRead(_ id: String) {
        lock.withLock {
            stored.insert(id)
            marks += 1
        }
    }

    /// The page's first head list answers at once. Every later one (a poll, a Refresh)
    /// waits up to 4 s for the next `markRead`; when one comes, it answers a second after
    /// it, past the end of a Read-all pass.
    func holdPastNextRead() async {
        let (first, marksBefore) = lock.withLock { () -> (Bool, Int) in
            headLists += 1
            return (headLists == 1, marks)
        }
        guard !first else { return }
        let deadline = Date().addingTimeInterval(4)
        while lock.withLock({ marks }) == marksBefore {
            guard Date() < deadline else { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
}

/// The `gram.get_file` calls MockTransport answered, counted per message id. Read through
/// `MockTransport.gramGetFileSummary`.
final class GramGetFileRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Int] = [:]

    var counts: [String: Int] { lock.withLock { stored } }

    func record(_ id: String) {
        lock.withLock { stored[id, default: 0] += 1 }
    }
}

/// The paged Gram mock's server side (`HERDR_MOCK_GRAM_PAGED=1`): how many older pages it
/// has served, so a head poll answers with everything the client has loaded, and how many
/// older-page requests (`before_id`) it answered, for GramView's DEBUG `gram-list-pages`
/// probe (a search must not fetch history the reader did not ask for).
final class GramPagingMock: @unchecked Sendable {
    static let shared = GramPagingMock()
    private let lock = NSLock()
    private var servedPages = 0
    private var requests = 0

    var depth: Int { lock.withLock { servedPages } }
    var pageRequests: Int { lock.withLock { requests } }

    func served(_ page: Int) {
        lock.withLock {
            servedPages = max(servedPages, page)
            requests += 1
        }
    }
}
#endif
