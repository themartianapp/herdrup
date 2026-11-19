import XCTest

extension XCUIApplication {
    /// The app under test, with animations off (`HERDR_NO_ANIMATIONS`, App/UITestMotion.swift):
    /// no UIKit or SwiftUI animation, layers at 100x, a steady terminal caret. Each action's
    /// "wait for the app to idle" otherwise waits out every animation, and a blinking caret
    /// or a turning ring never lets it finish (60 s a tap). A test that is about motion
    /// launches with `HERDR_NO_ANIMATIONS=0`.
    static func forUITest() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_NO_ANIMATIONS"] = "1"
        return app
    }

    /// A new app launched into the `HERDR_SCREENSHOT_MOCK` fixture `mock`, with
    /// `environment` added to its launch environment (a key there wins over the mock).
    static func launched(mock: String, environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication.forUITest()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = mock
        app.launchEnvironment.merge(environment) { _, new in new }
        app.launch()
        return app
    }

    var terminalSurface: XCUIElement {
        // String subscripts also compare labels/values. A first-match walk can
        // time out fetching those unrelated attributes after app reactivation.
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", "terminal-surface"))
            .firstMatch
    }
}
