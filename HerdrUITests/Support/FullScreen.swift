import XCTest
import UIKit

/// iPadOS KEEPS A WINDOW'S SIZE FOR LATER LAUNCHES, even across a reinstall. A test that
/// shrinks the app into a window (AgentListChromeTests) used to leave every later launch in
/// that window: run 40537708095 ran NeedsYouPill and the first ChatUX cases in a 715-722 pt
/// window, with no room for the chat column and pixel probes off the window, failing four
/// ChatUX cases that pass full screen. ui-shard.sh therefore ran AgentListChromeTests last
/// on its iPad, in a script shard of its own. Now no test relies on its position: a test
/// that leaves full screen restores it in its tear-down (`restoreFullScreenAfterTest`), and
/// every launch through `launched(mock:)` returns a window left behind to full screen
/// first, so the `ipad` UI-test shard can run the class in any order.
extension XCUIApplication {
    /// Full screen as the window-mode tests read it: the window's origin is the screen's.
    var isFullScreen: Bool {
        let frame = windows.firstMatch.frame
        return frame.minX == 0 && frame.minY == 0
    }

    /// iPad: when the app's window is not full screen, drags its bottom-right corner to the
    /// screen's, up to three times, and fails the calling test unless the window then fills
    /// the screen. iPadOS resizes a floating window around its centre (SettingsTests), so a
    /// corner dragged to the screen's corner asks for more than the screen and the window
    /// settles at full size. A no-op on iPhone and on a window already full screen.
    func restoreFullScreen(file: StaticString = #filePath, line: UInt = #line) {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        if state != .runningForeground {
            activate()
        }
        let window = windows.firstMatch
        guard window.exists(within: 10) else {
            return XCTFail("no app window to return to full screen", file: file, line: line)
        }
        window.waitForSettledFrame()
        let screen = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 where !isFullScreen {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.997, dy: 0.997))
                .press(forDuration: 0.3, thenDragTo: screen.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)))
            window.waitForSettledFrame()
        }
        XCTAssertTrue(isFullScreen,
                      "the app window stayed at \(window.frame) after three drags to the screen's corner: "
                      + "later launches would inherit that window", file: file, line: line)
    }
}

extension XCTestCase {
    /// For a test that takes the app out of full screen: returns it to full screen when the
    /// test ends, failed or not, so the next test (in any order) launches full screen.
    func restoreFullScreenAfterTest(_ app: XCUIApplication) {
        addTeardownBlock { app.restoreFullScreen() }
    }
}
