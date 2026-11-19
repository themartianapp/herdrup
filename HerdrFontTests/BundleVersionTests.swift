import Foundation
import XCTest

/// THE BUILT BUNDLE VERSION, read from the built product, not the generated source plist:
/// xcodegen writes the literal "$(MARKETING_VERSION)" into App/Info.plist and Xcode
/// substitutes it during the build. Nothing set CFBundleShortVersionString for months, so
/// xcodegen's default "1.0" shipped while project.yml said 0.1, and it surfaced only when
/// Apple closed the 1.0 train (altool 90186). This hosted test runs inside the Herdr.app the
/// shard built, so Bundle.main is that app (not the test runner), and reads project.yml from
/// the checkout the test was compiled in: the simulator shares the Mac's file system. It used
/// to be a step of the ipad-script shard (macserve-ipad-script.sh); it runs in the
/// iphone-terminal UI-test shard with the other HerdrFontTests since 2026-11-19.
final class BundleVersionTests: XCTestCase {
    func testBuiltVersionIsProjectMarketingVersion() throws {
        let built = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.jerryfane.herdr", "the test host is not Herdr.app")
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("project.yml")
        let text = try String(contentsOf: project, encoding: .utf8)
        // project.yml's first MARKETING_VERSION setting is the app target's (every target
        // carries the same value; App Store Connect rejects an upload whose extensions differ).
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.contains("MARKETING_VERSION:") },
                                 "project.yml at \(project.path) has no MARKETING_VERSION setting")
        let expected = line.split(separator: ":", maxSplits: 1)[1]
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        XCTAssertFalse(expected.isEmpty, "project.yml's MARKETING_VERSION line is empty: \(line)")
        XCTAssertEqual(built, expected,
                       "built CFBundleShortVersionString (\(built ?? "none")) does not match project.yml MARKETING_VERSION (\(expected))")
    }
}
