import CryptoKit
import XCTest

/// Actual native detail and connection surfaces, not the control/resize test harness.
final class DesktopDetailReferenceShots: DesktopReferenceCaptureCase {
    private static let inputSHA256 = "38f1ec400fd95f3c6229d7390e157c9c7b42acc246387093ce01e478ab5e887a"

    private struct Inputs: Decodable {
        let environment: [String: String]
        let writerDraft: String
        let savedHosts: [Host]

        struct Host: Codable {
            let id: String
            let host: String
            let username: String
            let nickname: String
            let authKind: String
        }
    }

    private func inputs() throws -> Inputs {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "desktop-reference-detail", withExtension: "json"))
        let data = try Data(contentsOf: url)
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), Self.inputSHA256)
        return try JSONDecoder().decode(Inputs.self, from: data)
    }

    private func launchDetail() throws -> (XCUIApplication, String, Inputs) {
        let input = try inputs()
        var environment = input.environment
        environment["HERDR_SCREENSHOT_MOCK"] = "chatview"
        let (app, device) = try launch("detail", served: "detail", sha256: Self.inputSHA256,
                                       environment: environment)
        let row = app.staticTexts["herdr-app"].firstMatch
        XCTAssertTrue(row.exists(within: 15), app.debugDescription)
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-view"].firstMatch.exists(within: 15))
        XCTAssertTrue(app.descendants(matching: .any)["chat-ask"].firstMatch.exists(within: 15))
        return (app, device, input)
    }

    func testNativeChatAndTerminalReferences() throws {
        let (app, device, _) = try launchDetail()
        capture(app, device: device, state: "detail-chat")
        app.buttons["chat-switch-terminal"].tap()
        XCTAssertTrue(app.buttons["chat-switch-terminal"].isSelected)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "terminal-surface").firstMatch.exists(within: 10))
        capture(app, device: device, state: "detail-terminal")
    }

    func testNativeInlineWriterReferences() throws {
        let (app, device, input) = try launchDetail()
        let field = app.textViews["terminal-reply-input"]
        XCTAssertTrue(field.exists(within: 10))
        field.tap()
        field.typeText(input.writerDraft)
        app.buttons["Collapse keyboard"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.gone(within: 10))
        XCTAssertEqual(field.value as? String, input.writerDraft)
        let handle = app.descendants(matching: .any)["composer-expand-handle"].firstMatch
        XCTAssertTrue(handle.exists(within: 10))
        XCTAssertEqual(handle.label, "Expand editor")
        let collapsed = field.frame
        capture(app, device: device, state: "detail-writer-collapsed")
        handle.tap()
        expectation(for: NSPredicate { _, _ in field.frame.height > collapsed.height + 40 }, evaluatedWith: field)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(handle.label, "Collapse editor")
        XCTAssertEqual(field.value as? String, input.writerDraft)
        capture(app, device: device, state: "detail-writer-expanded")
    }

    func testNativeSavedHostSelectionReference() throws {
        let input = try inputs()
        let metadata = try JSONEncoder().encode(input.savedHosts)
        let argument = "<" + metadata.map { String(format: "%02x", $0) }.joined() + ">"
        var environment = input.environment
        environment["HERDR_SCREENSHOT_MOCK"] = "onboarding"
        // Argument-domain metadata only: no Keychain writes, SSH connection or host selection.
        let (app, device) = try launch("detail", served: "detail", sha256: Self.inputSHA256,
                                       environment: environment,
                                       arguments: ["-dev.herdr.savedHosts.v1", argument])
        for host in input.savedHosts {
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", host.nickname))
                .firstMatch.exists(within: 10))
        }
        capture(app, device: device, state: "detail-host-selection")
    }
}
