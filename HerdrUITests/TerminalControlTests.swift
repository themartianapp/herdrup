import XCTest
import UIKit

final class TerminalControlTests: TerminalInteractionTestCase {
    /// The UIKit-backed terminal reply editor. Its delegate owns Return submission,
    /// which SwiftUI's multiline TextField could not observe.
    private var reply: XCUIElement { app.textViews["terminal-reply-input"] }

    func testNativeHistoryCoastSurvivesComposerFocusTypingAndSend() throws {
        launch("resize", environment: ["HERDR_LONG_HISTORY": "1"])
        command("natural")
        command("history")
        anchor()
        let initial = probe()["top"] as? String
        // Keep the flick distance independent of the tablet's taller viewport.
        let flickStart = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let flickEnd = flickStart.withOffset(CGVector(dx: 0, dy: -120))
        flickStart.press(forDuration: 0, thenDragTo: flickEnd, withVelocity: .fast, thenHoldForDuration: 0)
        let reading = wait {
            ($0["top"] as? String) != initial && ($0["tail"] as? Bool) == false
        }
        let top = try XCTUnwrap(reading["top"] as? String)
        let rows = try XCTUnwrap(reading["rows"] as? Int)
        let editor = try XCTUnwrap(app.textViews.matching(identifier: "terminal-reply-input")
            .allElementsBoundByIndex.first(where: { $0.isHittable }))
        editor.tap()
        wait { ($0["rows"] as? Int ?? rows) < rows && ($0["top"] as? String) == top }
        editor.typeText("Keep my place in this history while writing a wrapped reply.")
        XCTAssertEqual(probe()["top"] as? String, top)
        let send = try XCTUnwrap(app.buttons.matching(identifier: "terminal-send-button")
            .allElementsBoundByIndex.first(where: { $0.isHittable }))
        send.tap()
        wait { ($0["prompts"] as? Int) == 1 && ($0["top"] as? String) == top }
        if UIDevice.current.userInterfaceIdiom == .pad {
            let collapse = try XCTUnwrap(app.buttons.matching(NSPredicate(format: "label == %@", "Collapse keyboard"))
                .allElementsBoundByIndex.first(where: { $0.isHittable }))
            collapse.tap()
        }
        wait { ($0["rows"] as? Int) == rows && ($0["top"] as? String) == top }
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Keyboard dismissal must preserve the reading position")
        attach("native-history-position-after-send")
    }

    /// Whether the ctrl one-shot is armed, read from the production cap's own
    /// accessibility label. Idiom-independent, and the only observable that survives a
    /// state where no keyboard is available at all.
    private var armed: Bool {
        cap("terminal-ctrl").label == "control armed"
    }

    private func chord(_ text: String) {
        cap("terminal-ctrl").tap()
        // Deliberately no wait for a SwiftUI update between arming and typing.
        app.typeText(text)
    }

    /// The accepted line, plus the PAINTED prompt when the fixture actually paints one
    /// in the viewport. The control fixture shows nothing but the prompt, so its paint
    /// is the receipt; the resize fixture seeds a hundred history records and its
    /// prompt is legitimately scrolled out, so demanding it there asserted the
    /// viewport, not the input path.
    private func input(_ expected: String, previous: Int? = nil) {
        let prompt = ("fixture> " + expected).trimmingCharacters(in: .whitespaces)
        let paintExpected = fixtureMode == "control"
        wait {
            ($0["input"] as? String) == expected
                && (previous == nil || ($0["previous"] as? Int) == previous)
                && (!paintExpected || ($0["visible"] as? String ?? "").split(separator: "\n").contains {
                    $0.trimmingCharacters(in: .whitespaces) == prompt
                })
        }
    }

    /// UIKit may deliver a native key before the simultaneous tap recognizer
    /// updates SwiftUI. Exercise the real SwiftTerm encoder and pane input path.
    func testFirstNativeKeyDeliversBeforeFocusBinding() {
        launch("control")
        let draft = reply.value as? String
        app.buttons["fixture-native-first-key"].tap()
        input("p", previous: 0)
        XCTAssertEqual(reply.value as? String, draft)
    }

    func testFirstNativeBackspaceDeliversBeforeFocusBinding() {
        launch("control")
        let before = probe()["bytes"] as? String ?? ""
        app.buttons["fixture-native-first-backspace"].tap()
        wait {
            guard let bytes = $0["bytes"] as? String, bytes != before else { return false }
            return bytes.hasSuffix("7f ") || bytes.hasSuffix("08 ")
        }
    }

    func testLegacyPreviousIsOneEventThenOrdinaryCharacter() throws {
        launch("control"); focusTerminal()
        let draft = reply.value as? String
        chord("p")
        input("second-known-command", previous: 1)
        XCTAssertEqual(probe()["legacyPrevious"] as? Int, 1)
        XCTAssertEqual(probe()["kittyPrevious"] as? Int, 0)
        XCTAssertEqual(reply.value as? String, draft, "Direct input changed the reply draft")
        typeDirect("p")
        input("second-known-commandp", previous: 1)
        attach("legacy-one-shot-followed-by-literal-p")
        chord("p"); input("first-known-command", previous: 2)
        chord("n"); input("second-known-command", previous: 2)
        chord("c"); input("", previous: 2)
        XCTAssertEqual(probe()["next"] as? Int, 1)
        XCTAssertEqual(probe()["clears"] as? Int, 1)
        attach("legacy-history-next-and-clear")
    }

    func testKittyHistoryUsesNativeEnhancedEncodingOnce() throws {
        launch("control")
        command("kitty"); focusTerminal()
        chord("p"); input("second-known-command", previous: 1)
        XCTAssertEqual(probe()["kittyPrevious"] as? Int, 1)
        XCTAssertEqual(probe()["legacyPrevious"] as? Int, 0)
        typeDirect("p"); input("second-known-commandp", previous: 1)
        chord("n"); input("", previous: 1)
        chord("p"); input("second-known-command", previous: 2)
        chord("c"); input("", previous: 2)
        attach("kitty-native-chords-and-unmodified-next-key")
    }

    func testTwoTapsCancelInDirectInput() throws {
        launch("control"); focusTerminal()
        cap("terminal-ctrl").tap()
        XCTAssertTrue(armed, "one tap must arm the one-shot")
        cap("terminal-ctrl").tap()
        XCTAssertFalse(armed, "a second tap must cancel it without sending anything")
        typeDirect("p")
        input("p", previous: 0)
        attach("two-taps-cancel-without-input")
    }

    /// Refresh remounts the terminal (`streamGen`), and tearing the old one down cancels an
    /// armed Ctrl. That cancel wrote the pane's `ctrlArmed` state from `dismantleUIView`,
    /// inside SwiftUI's graph teardown: an exclusivity abort (`swift_beginAccess` fatal, as in
    /// the 1.2.1 (238) TestFlight crash). Arm, refresh: the app must stay up, the one-shot
    /// must be cancelled, and the next key must arrive plain.
    func testRefreshWhileControlIsArmedDoesNotCrashOrLeak() throws {
        launch("control"); focusTerminal()
        cap("terminal-ctrl").tap()
        XCTAssertTrue(armed, "one tap must arm the one-shot")
        let refresh = try XCTUnwrap(onscreen("terminal-refresh", requiringHittable: true),
                                    "the pane's refresh button. \(elementDump())")
        refresh.tap()
        XCTAssertTrue(holds(within: 15) { ($0["opens"] as? Int ?? 0) >= 2 && ($0["covered"] as? Bool) == false },
                      "refreshing with Ctrl armed must remount the terminal, not crash the app "
                      + "(state \(app.state.rawValue), probe \(probe()))")
        XCTAssertEqual(app.state, .runningForeground, "refreshing with Ctrl armed must not crash")
        XCTAssertTrue(poll(5, every: 0.25) { !self.armed }, "the remount must cancel the one-shot")
        focusTerminal(); typeDirect("p")
        input("p", previous: 0)
        attach("refresh-while-armed-no-crash-no-leak")
    }

    /// The reply path takes the keyboard first, from a fresh launch. Typing the chord
    /// is the observable focus check; this must not depend on a SwiftUI toolbar control
    /// because the reply editor is UIKit-backed.
    func testReplyFieldStillConsumesControl() throws {
        launch("control")
        reply.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        let draft = reply.value as? String
        cap("terminal-ctrl").tap(); reply.typeText("p")
        wait { ($0["input"] as? String) == "second-known-command" && ($0["previous"] as? Int) == 1 }
        XCTAssertEqual(reply.value as? String, draft, "the reply chord leaked literal text into the draft")
        XCTAssertFalse(armed, "the reply path must consume the one-shot")
        attach("reply-field-control-preserved")
    }

    func testDeleteNonASCIICompositionAndPasteDisarm() throws {
        launch("control"); focusTerminal()
        typeDirect("x")
        cap("terminal-ctrl").tap(); typeDirect(XCUIKeyboardKey.delete.rawValue)
        input("", previous: 0)
        typeDirect("p"); input("p", previous: 0)
        chord("c"); input("")
        cap("terminal-ctrl").tap(); typeDirect("é")
        input("é", previous: 0)
        typeDirect("p"); input("ép", previous: 0)
        chord("c"); input("")
        cap("terminal-ctrl").tap(); command("ime-commit")
        input("日本", previous: 0)
        focusTerminal(); typeDirect("p"); input("日本p", previous: 0)
        chord("c"); input("")
        cap("terminal-ctrl").tap(); command("paste-batch")
        input("paste-payload", previous: 0)
        focusTerminal(); typeDirect("p"); input("paste-payloadp", previous: 0)
        chord("c"); input("")
        cap("terminal-ctrl").tap(); command("batch-insert")
        input("batch-payload", previous: 0)
        focusTerminal(); typeDirect("p"); input("batch-payloadp", previous: 0)
        attach("batch-composition-delete-and-next-key")
    }

    func testExplicitKeycapAndKeyboardDismissalDisarm() throws {
        launch("control"); focusTerminal()
        cap("terminal-ctrl").tap()
        cap("Tab").tap()
        typeDirect("p"); input("p", previous: 0)
        chord("c"); input("")
        cap("terminal-ctrl").tap()
        let physicalKeyboard = try XCTUnwrap(probe()["physicalKeyboard"] as? Bool)
        // A full software keyboard is what needs dismissing. GCKeyboard (the probe) can
        // report a keyboard while the full software keyboard is still on screen, so it is
        // printed for the record, not used to choose the expectation.
        let keyboard = app.keyboards.firstMatch
        let softwareKeyboard = keyboard.exists && keyboard.frame.height >= 150
        print("Keyboard dismissal: software=\(softwareKeyboard), physical=\(physicalKeyboard)")
        if softwareKeyboard {
            XCTAssertNotNil(onscreen("Collapse keyboard", timeout: 5),
                            "a visible software keyboard must be dismissible")
            onscreen("Collapse keyboard")?.tap()
            wait { ($0["focused"] as? Bool) == false }
        } else {
            XCTAssertNil(onscreen("Collapse keyboard", timeout: 2),
                         "a hidden software keyboard (or a hardware keyboard's shortcut bar) needs no dismissal")
            // No dismissal occurred, so explicitly cancel the armed chord.
            cap("terminal-ctrl").tap()
            XCTAssertFalse(armed, "a second tap must cancel the one-shot")
        }
        focusTerminal(); typeDirect("p"); input("p", previous: 0)
        attach("explicit-key-and-keyboard-dismissal-no-leak")
    }

func testDictationStartDisarmsEvenIfPermissionIsDenied() throws {
        launch("control"); focusTerminal()
        cap("terminal-ctrl").tap()
        XCTAssertTrue(armed)
        onscreen("Dictate", timeout: 5)?.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // Permissions may already be settled by another case on this simulator.
        // Refuse recording when prompted; starting alone must consume armed Ctrl.
        for _ in 0..<2 {
            let deny = springboard.buttons["Don’t Allow"].firstMatch
            let asciiDeny = springboard.buttons["Don't Allow"].firstMatch
            if deny.waitForExistence(timeout: 2) { deny.tap() }
            else if asciiDeny.exists { asciiDeny.tap() }
        }
        if app.buttons["Stop dictation"].exists { app.buttons["Stop dictation"].tap() }
        if app.alerts.firstMatch.exists { app.alerts.buttons["OK"].tap() }
        // DICTATION MUST ACTUALLY HAVE STARTED for its disarm to be owed: production
        // clears the one-shot in MicButton's `onStart`, and `replyDictating` disables
        // the reply field while the mic is live. A simulator with no audio input never
        // starts it, and asserting the disarm there would fail on a state the app was
        // never in.
        let started = poll(5, every: 0.25) { !reply.isEnabled }
        guard started || !armed else {
            throw XCTSkip("dictation never started in this environment (no audio input), so no disarm is owed. \(elementDump())")
        }
        // STARTING dictation is what must disarm, and the production cap's own label is
        // the observable for it. Asserting it here rather than only through a later
        // keystroke matters: a denied-permission session can leave the phone with no
        // keyboard at all, and then "no character arrived" says nothing about the
        // modifier.
        XCTAssertFalse(armed, "starting dictation must consume the armed one-shot")
        attach("dictation-start-disarmed")
        // iOS can show a second, delayed system opt-in after the microphone
        // permission prompts. Decline it before refocusing: XCTest otherwise
        // taps its privacy link as an interruption and sends the next key nowhere.
        let dictationOptIn = springboard.alerts["Enable Dictation?"]
        if dictationOptIn.waitForExistence(timeout: 5) {
            dictationOptIn.buttons["Not Now"].tap()
        }
        // The ordinary-key half needs an input path, and a dictation attempt can leave
        // the phone with no keyboard: `focusTerminal` restores the responder, but iOS
        // does not always bring the keyboard back. The disarm above is the receipt this
        // case exists for; deliver a key too whenever the environment still can, rather
        // than failing on a keyboard the app does not control.
        focusTerminal()
        guard canTypeDirectly else {
            attach("dictation-no-input-path-after-permission-flow")
            return
        }
        typeDirect("p"); input("p", previous: 0)
        attach("dictation-start-no-modifier-leak")
    }

        func testAppDeactivationDisarmsBeforeNextDirectKey() throws {
        launch("control"); focusTerminal()
        cap("terminal-ctrl").tap()
        XCUIDevice.shared.press(.home)
        app.activate()
        // WAIT FOR THE APP TO BE SERVING SNAPSHOTS AGAIN before any query. The first
        // (cold) iPad run failed here with "Failed to get matching snapshots: Timed out
        // while evaluating UI query" — the accessibility hierarchy is not ready the
        // instant `activate()` returns, and the retry passed, which is exactly the
        // shape of failure the workflow refuses to let a warm rerun hide.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30),
                      "the app did not return to the foreground")
        XCTAssertTrue(app.staticTexts["terminal-interaction-probe"].waitForExistence(timeout: 30),
                      "the probe never came back after reactivation")
        focusTerminal(); typeDirect("p"); input("p", previous: 0)
        attach("app-deactivation-no-modifier-leak")
    }

    func testPaneSwitchAndTypingDuringCoverDoNotLeakOrRearm() throws {
        launch("resize"); focusTerminal()
        cap("terminal-ctrl").tap(); command("switch")
        wait { ($0["pane"] as? String) == "ix:b" }
        focusTerminal(); typeDirect("p"); input("p", previous: 0)
        command("switch")
        wait { ($0["pane"] as? String) == "ix:a" }
        focusTerminal(); typeDirect("p"); input("p", previous: 0)
        command("delayed"); command("120x24")
        typeDirect("x")
        wait { ($0["covered"] as? Bool) == false && ($0["input"] as? String) == "px" }
        settled(cols: 120)
        input("px", previous: 0)
        attach("typing-cancels-cover-without-input-replay")
    }

    /// PASTED, not typed. Return now submits instead of inserting, so `typeText("\n\n")`
    /// never reaches the buffer and a typing version of this test passed because newlines
    /// are uninsertable — not because `canSend` trims them. Pasting is the only route that
    /// still puts a newline-only string in the composer, so it is the route that pins the
    /// trimming rule.
    func testReplyContainingOnlyNewlinesIsNotSendable() {
        launch("control")
        let field = app.textViews["terminal-reply-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        command("newline-pasteboard")

        field.tap()
        field.press(forDuration: 1)
        let paste = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Paste"))
            .firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        XCTAssertEqual(field.value as? String, "\n\n",
                       "the newlines must actually reach the composer for this to test anything")
        XCTAssertFalse(app.buttons["terminal-send-button"].exists,
                       "a newline-only reply should stay unsendable")

        field.typeText("message")
        XCTAssertTrue(app.buttons["terminal-send-button"].waitForExistence(timeout: 5),
                      "visible text should make the reply sendable")
    }

    func testTypingKeepsReplyFocusedAcrossStateUpdates() {
        launch("control")
        let field = app.textViews["terminal-reply-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))

        field.tap()
        field.typeText("w")
        field.typeText("ord")
        XCTAssertEqual(field.value as? String, "word")
    }

    func testCopiedPhotoOffersPasteAndSendsAttachment() {
        launch("control")
        let field = app.textViews["terminal-reply-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        command("photo-pasteboard")

        XCTAssertTrue(pasteIntoReply(field),
                      "a copied photo should offer Paste in the reply editor")

        let chip = replyAttachmentChip
        XCTAssertTrue(chip.waitForExistence(timeout: 10),
                      "pasting a photo should stage a visible attachment")
        let send = app.buttons["terminal-send-button"]
        XCTAssertTrue(send.waitForExistence(timeout: 5),
                      "a photo should be sendable without caption text")
        XCTAssertTrue(poll(5, every: 0.25) { send.exists && send.isEnabled && send.isHittable },
                      "the staged photo's send action must accept a tap")
        send.tap()
        XCTAssertTrue(poll(15, every: 0.25) { !chip.exists },
                      "the photo should upload, post to the agent, and clear after prompt delivery")
    }

    /// The SAME path with a non-image file (a PDF), because the composer only accepted
    /// images at first: "paste a photo" worked while "paste the file you just copied" was a
    /// silent no-op. Nothing in staging, upload or the prompt reference is image-specific,
    /// so this receipt exists to keep the type filter from narrowing back.
    func testCopiedFileOffersPasteAndSendsAttachment() {
        launch("control")
        let field = app.textViews["terminal-reply-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        command("file-pasteboard")

        XCTAssertTrue(pasteIntoReply(field),
                      "a copied file should offer Paste in the reply editor")

        let chip = replyAttachmentChip
        XCTAssertTrue(chip.waitForExistence(timeout: 10),
                      "pasting a file should stage a visible attachment")
        let send = app.buttons["terminal-send-button"]
        XCTAssertTrue(send.waitForExistence(timeout: 5),
                      "a file should be sendable without caption text")
        send.tap()
        XCTAssertTrue(poll(15, every: 0.25) { !chip.exists },
                      "the file should upload, post to the agent, and clear after prompt delivery")
    }

    /// TWO attachments in one reply. The composer used to hold a single one and a second
    /// paste REPLACED the first — silently, after deleting its staged bytes — so this
    /// pins the count through the whole path: both chips staged, both delivered, both
    /// cleared by the one prompt that names them.
    func testTwoPastedFilesAreBothStagedAndSentTogether() {
        launch("control")
        let field = app.textViews["terminal-reply-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        // BY NAME, not by counting elements carrying the chip identifier: SwiftUI
        // propagates an identifier to every child of the chip, so a count there reports
        // glyph + label + remove button per attachment, not attachments.
        let photoChip = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "photo-")).firstMatch
        let fileChip = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "file-")).firstMatch

        command("photo-pasteboard")
        XCTAssertTrue(pasteIntoReply(field), "the photo should offer Paste")
        XCTAssertTrue(photoChip.waitForExistence(timeout: 10), "the photo should stage a chip")

        command("file-pasteboard")
        XCTAssertTrue(pasteIntoReply(field), "the file should offer Paste too")
        let note = app.staticTexts["terminal-action-note"]
        XCTAssertTrue(fileChip.waitForExistence(timeout: 10),
                      "the file should stage its own chip — note=\(note.exists ? note.label : "none")")
        XCTAssertTrue(photoChip.exists,
                      "a second paste must ADD an attachment, not replace the first")
        attach("terminal-composer-files")

        let send = app.buttons["terminal-send-button"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
        for chip in [photoChip, fileChip] {
            XCTAssertTrue(poll(20, every: 0.25) { !chip.exists },
                          "both attachments should post and clear once the prompt is delivered")
        }
    }

    /// COPY IN FINDER OR FILES, which is how a Mac or iPad reader gets a file into the
    /// composer with Command-V. That pasteboard carries the file url AND the path as
    /// text, and the composer used to defer to the text: it pasted "/…/dropped-note.txt"
    /// and attached nothing. The chip must carry the file's real name.
    func testACopiedFileURLAttachesTheFileRatherThanItsPath() {
        launch("control")
        let field = app.textViews["terminal-reply-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        command("file-url-pasteboard")

        XCTAssertTrue(pasteIntoReply(field), "a copied file should offer Paste")

        let chip = app.staticTexts["dropped-note.txt"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10),
                      "the file itself should stage, named as it is on disk")
        XCTAssertEqual(field.value as? String ?? "", "",
                       "and its path must not be pasted as text")
    }

    /// A MAC FINDER COPY of a document also puts the document's ICON on the pasteboard,
    /// as an image. The composer preferred images, so copying a PDF attached a 288 KB
    /// .icns named "photo-….icns" — reported from TestFlight build 143. The file url
    /// names what the reader actually copied, so it wins whenever one is present.
    func testACopiedDocumentBeatsItsFinderIcon() {
        launch("control")
        let field = app.textViews["terminal-reply-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        command("finder-document-pasteboard")

        XCTAssertTrue(pasteIntoReply(field), "a copied document should offer Paste")

        XCTAssertTrue(app.staticTexts["quarterly-report.pdf"].waitForExistence(timeout: 10),
                      "the document should stage under its own name, not its icon")
        let icons = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", ".icns"))
        XCTAssertEqual(icons.count, 0, "and no icon should be staged beside it")
    }

    /// THE PAPERCLIP (TestFlight 176 feedback). The owner's terminal composer offers the
    /// guest composer's attach button, beside the mic in the one-row composer. A file
    /// picked through its sheet stages a chip and sends exactly as a paste does: its
    /// bytes uploaded as soon as it is picked, then on Send one gram posted (without
    /// uploading again) and one prompt naming it.
    func testAttachButtonPicksAFileThatUploadsAndPrompts() {
        launch("control")
        let paperclip = app.buttons["terminal-attach-button"]
        XCTAssertTrue(paperclip.waitForExistence(timeout: 10),
                      "the terminal composer should offer the paperclip")
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(abs(paperclip.frame.midY - reply.frame.midY), 4,
                                 "at rest the paperclip sits in the composer's one row, beside the text")
        attach("terminal-composer-attach-rest")

        paperclip.tap()
        let file = app.buttons["composer-attach-file"]
        XCTAssertTrue(file.waitForExistence(timeout: 5), "the paperclip should open the attach sheet")
        XCTAssertTrue(app.buttons["composer-attach-photos"].exists,
                      "the sheet should offer the photo library as well as files")
        attach("terminal-composer-attach-sheet")
        file.tap()

        let chip = app.staticTexts["picked-notes.txt"]
        let note = app.staticTexts["terminal-action-note"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10),
                      "the picked file should stage a chip — note=\(note.exists ? note.label : "none")")
        attach("terminal-composer-attach-chip")

        // The bytes go up as soon as the file is picked (herdrup#523 item 11), but nothing
        // reaches the agent until Send: no gram post, no prompt.
        let size = "picked through the paperclip".utf8.count
        let uploaded = wait { ($0["uploadedBytes"] as? Int) == size }
        XCTAssertEqual(uploaded["gramPosts"] as? Int, 0, "picking a file must not post it")
        XCTAssertEqual(uploaded["prompts"] as? Int, 0, "picking a file must not prompt the agent")

        let send = app.buttons["terminal-send-button"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "a picked file should be sendable without text")
        send.tap()
        let delivered = wait {
            ($0["prompts"] as? Int) == 1 && ($0["gramPosts"] as? Int) == 1
        }
        XCTAssertEqual(delivered["uploadedBytes"] as? Int, size,
                       "Send should post the upload made at pick time, not upload the file again")
        XCTAssertEqual(delivered["uploadDiscards"] as? Int, 0, "a sent file's upload is consumed, not discarded")
        XCTAssertTrue((delivered["lastPrompt"] as? String ?? "").contains("File picked-notes.txt attached"),
                      "the prompt should name the picked file: \(delivered["lastPrompt"] ?? "")")
        XCTAssertTrue(poll(15, every: 0.25) { !chip.exists },
                      "the chip should clear once the prompt is delivered")
        Thread.sleep(forTimeInterval: 1)
        let settled = probe()
        XCTAssertEqual(settled["prompts"] as? Int, 1, "one prompt: \(settled)")
        XCTAssertEqual(settled["gramPosts"] as? Int, 1, "one post: \(settled)")
    }

    /// The staged-attachment chip. A container, so it is matched across element types
    /// rather than assumed to be an `otherElement`.
    private var replyAttachmentChip: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "terminal-attachment").firstMatch
    }

    /// Focus the editor before its one long-press, then use the real Paste action.
    /// A press on an unfocused editor can only place the caret on iOS 27.
    private func pasteIntoReply(_ field: XCUIElement) -> Bool {
        field.tap()
        field.press(forDuration: 1)
        let paste = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Paste"))
            .firstMatch
        guard paste.waitForExistence(timeout: 5) else { return false }
        paste.tap()
        return true
    }

    /// One row at rest; once the text wraps the buttons drop to a toolbar underneath and
    /// the text grows upward above them. Send never moves vertically, and the field never
    /// overlaps it. (The pull-to-expand handle is covered in GramTests: this harness's
    /// terminal has no spare room for the editor with the keyboard up.)
    func testReplyComposerStartsAsOneRowThenDropsToToolbarAndScrolls() {
        launch("control")
        let field = app.textViews["terminal-reply-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))

        field.tap()
        field.typeText("one")
        let send = app.buttons["terminal-send-button"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.6)
        let oneLine = field.frame
        let sendBottom = send.frame.maxY
        XCTAssertEqual(oneLine.midY, send.frame.midY, accuracy: 4,
                       "a one-line reply shares a single row with the send button")
        XCTAssertLessThan(oneLine.maxX, send.frame.minX, "the text sits beside the buttons")

        field.typeText(String(repeating: " wrapped", count: 60))
        Thread.sleep(forTimeInterval: 0.6)
        let wrapped = field.frame
        XCTAssertGreaterThan(wrapped.height, oneLine.height)
        XCTAssertEqual(send.frame.maxY, sendBottom, accuracy: 2)
        XCTAssertLessThanOrEqual(wrapped.maxY, send.frame.minY + 1,
                                 "wrapped text moves above a toolbar holding the buttons")
        XCTAssertGreaterThan(wrapped.width, oneLine.width, "the wrapped text gets the full width")
        XCTAssertTrue(send.isHittable)
        attach("terminal-composer-toolbar")

        field.typeText(String(repeating: " overflow", count: 20) + " tail-token")
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(field.frame.height, wrapped.height, accuracy: 2)
        XCTAssertEqual(send.frame.maxY, sendBottom, accuracy: 2)
        XCTAssertTrue((field.value as? String)?.contains("tail-token") == true)
        let lower = field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let upper = field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        lower.press(forDuration: 0.05, thenDragTo: upper)
        field.typeText(" after-scroll")
        XCTAssertTrue((field.value as? String)?.contains("after-scroll") == true,
                      "scrolling overflow text should keep the composer focused and editable")
        command("reply-multiline-pasteboard")
        // The first tap puts the caret at the end of the visible text; a second tap ON
        // that caret opens the edit menu. Not a long press: over text, iOS 27's long press
        // only drives the loupe and lifts with no edit menu (an empty field still gets one,
        // see `pasteIntoReply`), where iOS 26 showed the menu on lift.
        let end = field.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.8))
        end.tap()
        end.tap()
        let paste = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Paste"))
            .firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        XCTAssertTrue((field.value as? String)?.contains("pasted-tail") == true,
                      "a multiline paste should remain in the scrolling composer")
        field.typeText(" after-paste")
        // The caret after the paste is wherever the coordinate tap placed it.
        // The contract here is that the multiline paste remains and the composer stays
        // focused/editable afterward — not that a normalized tap maps past the last
        // glyph. A 5pt inset legitimately changes that coordinate mapping.
        XCTAssertTrue((field.value as? String)?.contains("after-paste") == true,
                      "typing after a multiline paste should keep the composer editable")
        XCTAssertTrue(send.isHittable)
    }

    /// Owner report (2026-10-09): during a long dictation the reply field stayed at the top,
    /// so the newest words ran on out of sight. Dictation writes through the reply binding,
    /// not by typing, so the field must follow the end of text it didn't type itself.
    /// Proof: a tap at the field's bottom-right lands at the very end of the text only if
    /// the last line is what's on screen.
    func testDictatedReplyKeepsItsNewestTextInView() {
        launch("control")
        let field = app.textViews["terminal-reply-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        command("reply-dictation")
        XCTAssertTrue(poll(8, every: 0.25) { (field.value as? String)?.hasSuffix("dictation-tail") == true },
                      "the dictated text should arrive in the reply field")
        Thread.sleep(forTimeInterval: 0.6)
        attach("terminal-composer-dictation")

        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.88)).tap()
        field.typeText("Z")
        let value = field.value as? String ?? ""
        XCTAssertTrue(value.hasSuffix("dictation-tailZ"),
                      "the field should show the newest dictated line; the tap landed mid-text: …\(value.suffix(60))")
    }

    /// Wraps just past one row, then deletes until the text fits again: the composer must
    /// return to a single row (after the hysteresis margin), with text still in it.
    /// Device-width independent: it types word by word until the toolbar appears.
    func testReplyComposerReturnsToOneRowWhenTextFitsAgain() {
        launch("control")
        let field = app.textViews["terminal-reply-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("wrap")
        let send = app.buttons["terminal-send-button"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        func inToolbar() -> Bool { field.frame.maxY <= send.frame.minY + 1 }
        func inOneRow() -> Bool { abs(field.frame.midY - send.frame.midY) <= 4 }
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertTrue(inOneRow(), "premise: a short reply starts in one row")

        var words = 0
        while !inToolbar() && words < 80 {
            field.typeText(" wrap")
            words += 1
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(inToolbar(), "premise: the text wrapped into the toolbar layout")

        // One key per call: a single long string of deletes loses keystrokes.
        var deleted = 0
        while !inOneRow() && deleted < 40 {
            field.typeText(XCUIKeyboardKey.delete.rawValue)
            deleted += 1
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(inOneRow(), "text that fits again returns to the single row")
        XCTAssertFalse(((field.value as? String) ?? "").isEmpty, "it returns before the field is empty")
    }


    /// A KEYBOARD IS ONE RESIZE, NOT TWENTY.
    ///
    /// The terminal is the only flexible view in the pane, so the keyboard's animation
    /// sweeps its height through every intermediate value and each one used to be
    /// committed as its own grid. Every commit restarted the settle window and re-armed
    /// the reveal ceiling, so the retained frame outlived the keyboard by about a
    /// second — the 1-2s of movement after sending that this exists to remove.
    ///
    /// `commits` counts proposals that survived coalescing, so this tells "the sweep was
    /// taken as one event" from "every animation frame was taken as its own resize".
    ///
    /// A BOUND OF TWO, NOT AN EQUALITY OF ONE. Measured in run 35329283397, a real
    /// simulator sweep commits the fit it ends on and then, once the emulator has
    /// actually reflowed to that grid, at most one reconciliation fit — the terminal's
    /// own scroller/cell metrics settling, which is a separate event from the animation.
    /// What must never return is a count that scales with the animation's frames, and
    /// this bound is the assertion for that: before this change the same sweep committed
    /// on the order of fifteen to twenty.
    func testKeyboardSweepCommitsOneGrid() {
        launch("control")
        XCTAssertTrue(app.textViews["terminal-reply-input"].waitForExistence(timeout: 10))
        wait { ($0["covered"] as? Bool) == false && ($0["rows"] as? Int ?? 0) >= 2 }
        let openRows = probe()["rows"] as? Int ?? 0
        var commits = probe()["commits"] as? Int ?? 0

        command("keyboard-show")
        wait { ($0["covered"] as? Bool) == false && ($0["rows"] as? Int ?? 0) < openRows }
        let shown = (probe()["commits"] as? Int ?? 0) - commits
        XCTAssertLessThanOrEqual(shown, 2,
                                 "the keyboard's arrival committed \(shown) grids: \(probe())")
        attach("keyboard-show-one-commit")

        commits = probe()["commits"] as? Int ?? 0
        command("keyboard-hide")
        wait { ($0["covered"] as? Bool) == false && ($0["rows"] as? Int ?? 0) == openRows }
        let hidden = (probe()["commits"] as? Int ?? 0) - commits
        XCTAssertLessThanOrEqual(hidden, 2,
                                 "the keyboard's dismissal committed \(hidden) grids: \(probe())")
        XCTAssertEqual(probe()["commitRows"] as? Int, openRows,
                       "the last commit must be the fit the sweep ENDED on")
        attach("keyboard-hide-one-commit")
    }

    /// THE TERMINAL STAYS LIVE WHILE THE KEYBOARD RISES. A keyboard sweep used to freeze
    /// the terminal behind a snapshot, cut off at the keyboard's top edge, until the
    /// agent redrew at the new grid about half a second later. Now the terminal keeps
    /// its grid, sits so its prompt row stays above the keyboard, and keeps painting.
    ///
    /// The journal samples what is ON SCREEN (rows fully inside the pane, from the
    /// snapshot while one covers it) every frame for the whole sweep, because the
    /// window between the keyboard moving and the new grid landing is shorter than a
    /// probe round trip.
    func testKeyboardShowKeepsTheTerminalLive() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone,
                          "iPad keyboard sweeps stay layout-driven and covered")
        let open = naturalFixture()
        let openRows = open["rows"] as? Int ?? 0
        let serial = open["sweepSerial"] as? Int ?? 0

        command("keyboard-show-live")
        let shown = wait {
            ($0["sweepSerial"] as? Int ?? 0) > serial && ($0["sweepOpen"] as? Bool) == false
                && ($0["covered"] as? Bool) == false
        }
        XCTAssertGreaterThan(shown["sweepSamples"] as? Int ?? 0, 10, "premise: the sweep was sampled: \(shown)")
        XCTAssertEqual(shown["sweepMarkSeenRows"] as? Int, openRows,
                       "output written while the keyboard rose must be on screen before the new grid "
                       + "lands, not after (seen \(shown["sweepMarkSeenMs"] ?? "-") ms late): \(shown)")
        XCTAssertEqual(shown["sweepPromptMisses"] as? Int, 0,
                       "the prompt row must stay on screen for the whole sweep: \(shown)")
        XCTAssertEqual(shown["coverInstalls"] as? Int, open["coverInstalls"] as? Int,
                       "a keyboard sweep must not freeze the terminal behind a snapshot: \(shown)")
        XCTAssertEqual((shown["requests"] as? Int ?? 0) - (open["requests"] as? Int ?? 0), 1,
                       "one keyboard transition is one PTY resize: \(shown)")
        let settled = wait { ($0["rows"] as? Int ?? 0) == ($0["commitRows"] as? Int ?? -1) }
        XCTAssertLessThan(settled["rows"] as? Int ?? 0, openRows, "the grid follows the keyboard: \(settled)")
        XCTAssertTrue((settled["visible"] as? String ?? "").contains(shown["sweepMark"] as? String ?? "?"),
                      "the live line survives the reflow: \(settled)")
        attach("keyboard-show-live")
    }

    /// The same for the keyboard going away: the pane grows, the terminal keeps its grid
    /// at the bottom (a band of ground above it) until the new grid lands, then fills.
    func testKeyboardHideKeepsTheTerminalLive() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone,
                          "iPad keyboard sweeps stay layout-driven and covered")
        let open = naturalFixture()
        let openRows = open["rows"] as? Int ?? 0
        command("keyboard-show")
        let up = wait {
            ($0["sweepOpen"] as? Bool) == false && ($0["covered"] as? Bool) == false
                && ($0["rows"] as? Int ?? 0) < openRows
                && ($0["rows"] as? Int ?? 0) == ($0["commitRows"] as? Int ?? -1)
        }
        let serial = up["sweepSerial"] as? Int ?? 0

        command("keyboard-hide")
        let hidden = wait {
            ($0["sweepSerial"] as? Int ?? 0) > serial && ($0["sweepOpen"] as? Bool) == false
                && ($0["covered"] as? Bool) == false
        }
        XCTAssertEqual(hidden["sweepPromptMisses"] as? Int, 0,
                       "the prompt row must stay on screen for the whole sweep: \(hidden)")
        XCTAssertEqual(hidden["coverInstalls"] as? Int, up["coverInstalls"] as? Int,
                       "a keyboard sweep must not freeze the terminal behind a snapshot: \(hidden)")
        XCTAssertEqual((hidden["requests"] as? Int ?? 0) - (up["requests"] as? Int ?? 0), 1,
                       "one keyboard transition is one PTY resize: \(hidden)")
        let settled = wait { ($0["rows"] as? Int ?? 0) == ($0["commitRows"] as? Int ?? -1) }
        XCTAssertEqual(settled["rows"] as? Int, openRows, "the grid returns to the open fit: \(settled)")
        attach("keyboard-hide-live")
    }

    /// The resize fixture (a full screen of history above the prompt) at the pane's real
    /// fit rather than its pinned 80x24, settled.
    private func naturalFixture() -> [String: Any] {
        launch("resize")
        command("natural")
        return wait {
            ($0["covered"] as? Bool) == false && ($0["rows"] as? Int ?? 0) >= 2
                && ($0["rows"] as? Int) == ($0["commitRows"] as? Int)
                && ($0["cols"] as? Int) == ($0["commitCols"] as? Int)
        }
    }

    /// TYPING NEVER RESIZES THE TERMINAL (#301). The composer floats over the terminal:
    /// wrapping into the toolbar, growing to five lines, the drag handle and the editor
    /// all draw over the terminal's bottom rows. Each used to change the terminal's
    /// size, so the PTY was resized, the agent redrew its whole screen and a frozen
    /// snapshot covered the terminal while it did.
    func testComposerGrowthNeverResizesTheTerminal() {
        launch("control")
        let field = reply
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("one")
        let send = app.buttons["terminal-send-button"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        // Focus may move the keyboard (or a hardware keyboard's bar): let that settle
        // before taking the baseline.
        Thread.sleep(forTimeInterval: 1.5)
        wait { ($0["covered"] as? Bool) == false }
        let before = probe()
        let oneLine = field.frame

        field.typeText(String(repeating: " wrapped", count: 60))
        let handle = app.descendants(matching: .any)["composer-expand-handle"].firstMatch
        if handle.waitForExistence(timeout: 3) {
            handle.tap()
            Thread.sleep(forTimeInterval: 0.8)
            handle.tap()
        }
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertGreaterThan(field.frame.height, oneLine.height, "premise: the composer grew")
        let after = probe()
        XCTAssertEqual(after["rows"] as? Int, before["rows"] as? Int,
                       "composer growth must not change the terminal grid: \(after)")
        XCTAssertEqual(after["commits"] as? Int, before["commits"] as? Int,
                       "composer growth must not resize the PTY: \(after)")
        XCTAssertEqual(after["coverInstalls"] as? Int, before["coverInstalls"] as? Int,
                       "composer growth must not freeze the terminal behind a snapshot: \(after)")
        attach("terminal-composer-floats-over-terminal")
    }

    /// A KEYBOARD NOTIFICATION THAT MOVES NOTHING FREEZES NOTHING (#301). With the
    /// keyboard up, moving focus between the terminal and the composer makes UIKit post
    /// a keyboard notification with the same frame. On iPhone that used to install the
    /// retained frame, and with no grid change nothing ever settled it, so live output
    /// froze until the ~1 s ceiling on every switch.
    func testUnchangedKeyboardNotificationDoesNotFreezeTheTerminal() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone,
                          "iPad never retains a frame up front for a keyboard notification")
        launch("control")
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        wait { ($0["covered"] as? Bool) == false && ($0["rows"] as? Int ?? 0) >= 2 }
        let openRows = probe()["rows"] as? Int ?? 0
        command("keyboard-show")
        wait { ($0["covered"] as? Bool) == false && ($0["rows"] as? Int ?? 0) < openRows }
        let before = probe()

        command("keyboard-nudge")
        Thread.sleep(forTimeInterval: 1.5)
        let after = probe()
        XCTAssertEqual(after["coverInstalls"] as? Int, before["coverInstalls"] as? Int,
                       "a keyboard that did not move must not retain a frame "
                       + "(last cover \(after["lastCoverMs"] ?? "-") ms): \(after)")
        XCTAssertEqual(after["rows"] as? Int, before["rows"] as? Int)
        XCTAssertEqual(after["commits"] as? Int, before["commits"] as? Int)
    }

}
