import XCTest
import UIKit

/// FILES DROPPED ON THE TERMINAL attach to the composer (herdrup#575).
///
/// The drags are real UIKit drag sessions inside the app: the control fixture's
/// `fixture-drag-*` sources carry the items a Finder or Files drag carries, and
/// `press(forDuration:thenDragTo:…)` lifts and carries them onto the terminal surface. A
/// drag from ANOTHER app (Finder, Files) cannot be synthesised by XCUITest, so the source
/// is in-process; the drop target, the providers and the composer path are the real ones.
final class TerminalDropTests: TerminalInteractionTestCase {
    private func source(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Lift `identifier`'s items, carry them onto the middle of the terminal, and hover
    /// there long enough for the drop target to light up before letting go.
    private func drag(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let from = source(identifier)
        XCTAssertTrue(from.waitForExistence(timeout: 10), "the fixture drag source should exist", file: file, line: line)
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "the terminal should be on screen", file: file, line: line)
        from.press(forDuration: 1.5, thenDragTo: terminal, withVelocity: .slow, thenHoldForDuration: 1.5)
    }

    /// A file url (Finder's drag of a document), a PDF's bytes (a Files drag) and a text
    /// snippet, dropped in ONE drag on the terminal: both files stage as composer chips
    /// under their own names and start uploading at once, exactly as on the composer bar;
    /// the text lands nowhere. Send then posts those uploads without uploading again.
    func testFilesDroppedOnTheTerminalStageInTheComposerAndUploadEarly() {
        launch("control")
        let reply = app.textViews["terminal-reply-input"]
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        XCTAssertEqual(probe()["dropTargets"] as? Int, 0)

        drag("fixture-drag-files")

        let note = app.staticTexts["terminal-action-note"]
        let noteChip = app.staticTexts["dragged-note.txt"]
        let pdfChip = app.staticTexts["dragged-report.pdf"]
        XCTAssertTrue(noteChip.waitForExistence(timeout: 15),
                      "the dropped file url should stage as a chip — note=\(note.exists ? note.label : "none") receipt=\(probe())")
        XCTAssertTrue(pdfChip.waitForExistence(timeout: 10),
                      "the dropped PDF should stage its own chip — note=\(note.exists ? note.label : "none")")
        attach("terminal-drop-staged")
        XCTAssertGreaterThanOrEqual(probe()["dropTargets"] as? Int ?? 0, 1,
                                    "the drag should have lit the terminal's drop target")

        // Uploaded on drop (herdrup#523 item 11), nothing posted or prompted before Send.
        let noteBytes = "dragged from finder".utf8.count
        let uploaded = wait { ($0["uploadedBytes"] as? Int ?? 0) > noteBytes }
        XCTAssertEqual(uploaded["gramPosts"] as? Int, 0, "dropping files must not post them")
        XCTAssertEqual(uploaded["prompts"] as? Int, 0, "dropping files must not prompt the agent")
        // The text item in the same drag is not an attachment and is typed nowhere.
        XCTAssertEqual(reply.value as? String ?? "", "", "the dragged text must not reach the reply")
        XCTAssertFalse((uploaded["input"] as? String ?? "").contains("dragged-text-snippet"),
                       "the dragged text must not reach the terminal: \(uploaded)")

        let send = app.buttons["terminal-send-button"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "dropped files should be sendable without text")
        send.tap()
        let delivered = wait { ($0["prompts"] as? Int) == 1 && ($0["gramPosts"] as? Int) == 2 }
        XCTAssertEqual(delivered["uploadedBytes"] as? Int, uploaded["uploadedBytes"] as? Int,
                       "Send should post the uploads made at drop time, not upload again")
        XCTAssertEqual(delivered["uploadDiscards"] as? Int, 0, "sent uploads are consumed, not discarded")
        XCTAssertTrue(poll(15, every: 0.25) { !noteChip.exists && !pdfChip.exists },
                      "both chips should clear once the prompt is delivered")
    }

    /// Plain text dragged onto the terminal keeps today's behaviour: the terminal is not a
    /// drop target for it, so it never lights up and nothing is staged or typed. Ends with
    /// the drop highlight's screenshot.
    func testATextDragOnTheTerminalIsNotADrop() {
        launch("control")
        let reply = app.textViews["terminal-reply-input"]
        XCTAssertTrue(reply.waitForExistence(timeout: 10))

        drag("fixture-drag-text")

        Thread.sleep(forTimeInterval: 1)
        let after = probe()
        XCTAssertEqual(after["dropTargets"] as? Int, 0, "a text-only drag must not light the terminal: \(after)")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "terminal-attachment").firstMatch.exists,
                       "a text drag stages nothing")
        XCTAssertEqual(reply.value as? String ?? "", "", "and types nothing into the reply")
        XCTAssertFalse((after["input"] as? String ?? "").contains("dragged-text-snippet"),
                       "or into the terminal: \(after)")
        XCTAssertEqual(after["uploadedBytes"] as? Int, 0)

        // The highlight a file drag shows, held on by the fixture: XCUITest cannot take a
        // screenshot while its own drag is in flight.
        command("drop-highlight-on")
        Thread.sleep(forTimeInterval: 0.5)
        attach("terminal-drop-highlight")
        command("drop-highlight-off")
    }
}
