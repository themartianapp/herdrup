import XCTest

/// The empty detail column on iPad and Mac: a live glyph field behind "Select an agent".
final class SelectAgentFieldTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    /// The field is decoration. SpriteKit publishes every sprite to accessibility unless told
    /// otherwise; when it did, the column grew ~550 extra elements as the field animated, and
    /// every VoiceOver and UI-test query had to walk them (seconds per query, then timeouts).
    func testFieldAddsNothingToTheAccessibilityTree() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("the empty detail column exists only in the iPad / Mac layout")
        }
        let app = XCUIApplication.launched(mock: "list")
        let label = app.staticTexts["Select an agent"]
        XCTAssertTrue(label.exists(within: 30))
        // Kept: time must pass for the field's pointer autopilot and typing to wake a few
        // hundred cells; the check is that none of them reach the accessibility tree.
        Thread.sleep(forTimeInterval: 5)

        let column = label.frame.midX
        let window = app.windows.firstMatch.frame
        let detail = CGRect(x: 2 * column - window.maxX, y: window.minY,
                            width: 2 * (window.maxX - column), height: window.height)
        var inDetail: [String] = []
        func walk(_ element: XCUIElementSnapshot) {
            if detail.contains(element.frame), !element.frame.isEmpty {
                inDetail.append("\(element.elementType.rawValue) '\(element.label)' \(element.frame)")
            }
            element.children.forEach(walk)
        }
        walk(try app.snapshot())
        // Ordinary chrome over the column measures 8 elements; with sprites published it was 631.
        XCTAssertLessThanOrEqual(inDetail.count, 24, inDetail.prefix(12).joined(separator: " | "))
        app.terminate()
    }
}
