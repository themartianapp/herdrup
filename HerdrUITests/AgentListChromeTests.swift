import XCTest
import UIKit

final class AgentListChromeTests: XCTestCase {
    func testBackReturnsFromAgentsToMachines() {
        let app = XCUIApplication.launched(mock: "list")
        let back = app.buttons[UIDevice.current.userInterfaceIdiom == .pad ? "agents-back" : "Back"].firstMatch
        XCTAssertTrue(back.exists(within: 10))
        if UIDevice.current.userInterfaceIdiom == .pad {
            let window = app.windows.firstMatch
            // iPadOS can restore a compact window from an earlier launch. Resize only
            // a full-screen window: a minimum-size window cannot shrink any further.
            if window.frame.minX == 0 && window.frame.minY == 0 {
                window.coordinate(withNormalizedOffset: CGVector(dx: 0.997, dy: 0.997))
                    .press(forDuration: 0.3, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.82)))
            }
            XCTAssertTrue(window.frame.minX > 0 || window.frame.minY > 0,
                          "Back must be exercised in a system window, not just full screen")
        }
        XCTAssertTrue(back.isHittable)
        back.tap()
        XCTAssertTrue(app.staticTexts["connect to your machine"].exists(within: 5))
    }

    /// iPad: Back leads in full screen (no window controls on the left), joins the
    /// right-hand capsule in a window, and in a window the bar sits inside the window's
    /// top edge instead of touching it. Named to run first in this class: the next test
    /// leaves the window shrunk, and iPadOS restores that size on later launches.
    func testAIPadBackFollowsFullScreenAndWindowMode() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("iPad window modes only")
        }
        continueAfterFailure = false
        let app = XCUIApplication.launched(mock: "list")
        let window = app.windows.firstMatch
        let back = app.buttons["agents-back"].firstMatch
        let title = app.staticTexts["Agents"].firstMatch
        let newAgent = app.buttons["New agent"].firstMatch
        XCTAssertTrue(back.exists(within: 10))

        let startedFullScreen = window.frame.minX == 0 && window.frame.minY == 0
        if startedFullScreen {
            attach(app, "ipad-fullscreen-back-left")
            XCTAssertLessThan(back.frame.maxX, title.frame.minX, "full screen: Back is left of the title")
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.997, dy: 0.997))
                .press(forDuration: 0.3, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.82)))
        }
        XCTAssertTrue(window.frame.minX > 0 || window.frame.minY > 0, "must be in a window")
        XCTAssertTrue(back.exists(within: 5))
        window.waitForSettledFrame()
        attach(app, "ipad-window-back-right")
        XCTAssertGreaterThan(back.frame.minX, title.frame.maxX, "window: Back joins the right-hand capsule")
        // The window controls' pill is ~21.5 pt tall, centred ~31.5 pt below the window's
        // top; the sidebar panel starts 10 pt down. The capsules match the pill instead of
        // a 44 pt capsule flush against the panel's top edge.
        assertLinesUpWithWindowControls(newAgent, in: window, "Agents")
        XCTAssertTrue(back.isHittable)
        // Gram's header is built from the same bar: it must sit inside the edge too.
        let refresh = app.buttons["Refresh"].firstMatch
        for _ in 0..<3 where !refresh.exists {
            app.buttons["Gram"].firstMatch.tap()
            _ = refresh.exists(within: 3)
        }
        XCTAssertTrue(refresh.exists, "Gram should open with its header")
        refresh.waitForSettledFrame()   // the section switch may still be animating
        attach(app, "ipad-window-gram")
        assertLinesUpWithWindowControls(refresh, in: window, "Gram")
        if !startedFullScreen {
            // The window survived from an earlier run; the window case above still ran.
            throw XCTSkip("started in a restored window: the full-screen half was not exercised")
        }
    }

    /// Pixels, not element frames: a control's frame includes its 44 pt tap band, so it is
    /// the same either way. Just inside the capsule's left edge (no glyph there), the
    /// capsule colour must show at the controls' centre line and NOT 4 pt below the
    /// panel's top edge, where the old 44 pt capsule began.
    private func assertLinesUpWithWindowControls(_ control: XCUIElement, in window: XCUIElement,
                                                 _ section: String) {
        let shot = XCUIScreen.main.screenshot()
        guard let image = shot.image.cgImage,
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return XCTFail("\(section): no screenshot to measure")
        }
        // The sampler reads 8-bit RGB(A)/BGR(A) with any alpha byte last.
        let alphaFirst = [CGImageAlphaInfo.first, .premultipliedFirst, .noneSkipFirst]
            .contains(CGImageAlphaInfo(rawValue: image.alphaInfo.rawValue) ?? .none)
        guard image.bitsPerComponent == 8, image.bitsPerPixel >= 24, !alphaFirst else {
            return XCTFail("\(section): unexpected screenshot format \(image.bitsPerComponent)/\(image.bitsPerPixel) \(image.alphaInfo.rawValue)")
        }
        let scale = CGFloat(image.width) / shot.image.size.width
        func luminance(_ x: CGFloat, _ y: CGFloat) -> Int {
            let px = Int(x * scale), py = Int(y * scale)
            let i = py * image.bytesPerRow + px * (image.bitsPerPixel / 8)
            return (Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2])) / 3
        }
        let x = control.frame.minX + 3
        let capsule = luminance(x, window.frame.minY + 31.5)
        let panel = luminance(control.frame.midX, window.frame.minY + 60)  // below the bar
        let nearEdge = luminance(x, window.frame.minY + 14)
        XCTAssertGreaterThan(abs(capsule - panel), 6, "\(section): the capsule should show on the controls' line")
        XCTAssertLessThan(abs(nearEdge - panel), 4,
                          "\(section): the capsule must not reach up to the panel's top edge")
    }

    func testSearchFiltersAndClears() {
        let app = XCUIApplication.launched(mock: "list")
        let search = app.textFields["agent-search"]
        XCTAssertTrue(search.exists(within: 10))
        XCTAssertFalse(app.buttons["Clear search"].exists, "nothing to clear yet")
        search.tap()
        search.typeText("jarvis")
        XCTAssertTrue(app.staticTexts["jarvis"].exists)
        XCTAssertFalse(app.staticTexts["vetrina"].exists)
        app.buttons["Clear search"].tap()
        XCTAssertTrue(app.staticTexts["vetrina"].exists(within: 5))
        XCTAssertFalse(app.buttons["Clear search"].exists)
    }

    func testTabletSidebarCanHideAndRestoreInEverySection() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("Tablet split view") }
        let app = XCUIApplication.launched(mock: "list")
        for section in ["Agents", "Gram", "Settings"] {
            if section != "Agents" { app.buttons[section].firstMatch.tap() }
            let hide = app.buttons["Minimise sidebar"].firstMatch
            XCTAssertTrue(hide.exists(within: 10), section)
            hide.tap()
            let restore = app.buttons["Expand sidebar"].firstMatch
            XCTAssertTrue(restore.exists(within: 5), section)
            restore.tap()
            XCTAssertTrue(hide.exists(within: 5), section)
        }
    }
}
