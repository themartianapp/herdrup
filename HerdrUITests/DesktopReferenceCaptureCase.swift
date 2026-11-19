import CryptoKit
import XCTest

/// Shared deterministic launch, device checks and PNG provenance for desktop reference suites.
class DesktopReferenceCaptureCase: XCTestCase {
    /// jerryfane/herdrup-desktop cmd/fakeherdr/agents.json at 0b5111ed47fb2325f6caf4a383758209c6d6c9f6.
    static let fixtureName = "desktop-reference-agents"
    static let fixtureSHA256 = "f912df090a009597e326cc7df873addc242be2400e8645f5c654c2b168a081e2"
    static let clock = "2026-10-28T09:41:00Z"

    /// The served states' fixtures (HerdrUITests/Fixtures/desktop-reference-<name>.json), by
    /// name, with their sha256.
    static let servedSHA256: [String: String] = [
        "folders": "7688f3779c18e297213dd1248be390728857c228460aa6ae04cf70b06650cf84",
        "avatars": "1dcc6889466fecc87efd23bca7bc2dee6cdde450a4e75d601a7e5a28eb879592",
        "sessions": "e600054d6595f7df0abeb3ed56cfa3f346c919cf093a18c32f9f20226dd328bd",
        "federated": "0445d1690258871aac0048c1c9f77f71dfe0476808738fbc6744eb641ae1c2ad",
        "needs-you": "101ad2cba65a1a12b77ed32ae3bfbbf13da2a34d90b5a75d9021a5bcfaee2856",
    ]
    /// The uploaded picture the avatars state serves (HerdrUITests/Fixtures/desktop-reference-avatar.png).
    static let avatarSHA256 = "e4d4139d5914062cd06d5b6cbd8ade1d5fddf83c20ee575d4d83b8d81de38a4a"
    static let contentSize = "UICTContentSizeCategoryL"

    /// The two reference iPads, by their landscape window in points.
    static let devices: [String: String] = [
        "1376x1032": "ipad-pro-13",
        "1180x820": "ipad-11",
    ]

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Hands the device back in portrait, as GramColumnTests does: AgentListChromeTests runs
    /// next on the same iPad and measures its window chrome in portrait (run 40702149432).
    override func tearDown() {
        XCUIApplication().terminate()
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    // MARK: Launch

    /// The fixture the launched state serves and its sha256, for the capture's record.
    private var served: (name: String, sha256: String)?

    /// Launches the mock in landscape at the default text size and returns the app and
    /// the device name for the attachments. Fails unless the app runs full screen on one
    /// of the reference iPads at @2x, dark, with the clock pinned. `served` names the
    /// state's fixture, desktop-reference-<served>.json; nil serves the desktop's agents.json.
    func launch(
        _ state: String, served name: String? = nil, sha256 expectedSHA256: String? = nil,
        environment: [String: String] = [:], arguments: [String] = []
    ) throws -> (XCUIApplication, String) {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("the desktop references are iPad screenshots")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment = [
            "HERDR_SCREENSHOT_MOCK": "desktopref",
            "HERDR_DESKTOPREF_STATE": state,
            "HERDR_MOCK_NOW": Self.clock,
            "TZ": "UTC",
        ]
        app.launchEnvironment.merge(environment, uniquingKeysWith: { _, value in value })
        if let name {
            let sha256 = try XCTUnwrap(expectedSHA256 ?? Self.servedSHA256[name], "no sha256 recorded for \(name)")
            app.launchEnvironment["HERDR_DESKTOPREF_SERVED"] = try vendored("desktop-reference-\(name)", "json", sha256: sha256)
            served = (name, sha256)
        } else {
            app.launchEnvironment["HERDR_DESKTOPREF_AGENT_LIST"] = try fixture()
            served = nil
        }
        if name == "avatars" { try assertServedAvatarIsTheAsset() }
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName", Self.contentSize,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launchArguments += arguments
        app.launch()

        let probe = app.otherElements["desktopref-probe"]
        XCTAssertTrue(probe.exists(within: 30), "the desktopref probe should be on screen")
        let fields = conditions(probe)
        let window = fields["window"] ?? "?"
        let device = try XCTUnwrap(Self.devices[window],
                                   "window \(window) is not a reference iPad in landscape full screen (probe: \(fields))")
        XCTAssertEqual(fields["scale"], "2", "references are @2x")
        XCTAssertEqual(fields["style"], "dark")
        XCTAssertEqual(fields["contentSize"], Self.contentSize)
        XCTAssertEqual(fields["now"], Self.clock)
        XCTAssertEqual(fields["locale"], "en_US")
        XCTAssertEqual(fields["timeZoneOffset"], "0")
        XCTAssertEqual(fields["calendar"], "gregorian")
        return (app, device)
    }

    /// The vendored fixture, checked against the sha256 the references record.
    private func fixture() throws -> String {
        try vendored(Self.fixtureName, "json", sha256: Self.fixtureSHA256)
    }

    /// A vendored file's bytes as UTF-8, checked against the sha256 the references record.
    private func vendored(_ name: String, _ ext: String, sha256: String) throws -> String {
        try XCTUnwrap(String(data: vendoredData(name, ext, sha256: sha256), encoding: .utf8))
    }

    private func vendoredData(_ name: String, _ ext: String, sha256: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext),
                                "\(name).\(ext) should be in the test bundle")
        let data = try Data(contentsOf: url)
        XCTAssertEqual(Self.sha256(data), sha256, "the vendored \(name).\(ext) is not the one the references name")
        return data
    }

    /// The avatars fixture serves exactly the committed picture, under its own sha256.
    private func assertServedAvatarIsTheAsset() throws {
        let png = try vendoredData("desktop-reference-avatar", "png", sha256: Self.avatarSHA256)
        let served = try vendoredData("desktop-reference-avatars", "json",
                                      sha256: try XCTUnwrap(Self.servedSHA256["avatars"]))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: served) as? [String: Any])
        let images = try XCTUnwrap(object["agent.avatar.get"] as? [String: Any])
        let image = try XCTUnwrap(images[Self.avatarSHA256] as? [String: Any], "the picture is not served by its sha256")
        let base64 = try XCTUnwrap(image["data_base64"] as? String)
        XCTAssertEqual(Data(base64Encoded: base64), png, "the served picture is not desktop-reference-avatar.png")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The probe's `key=value;…` accessibility value.
    private func conditions(_ probe: XCUIElement) -> [String: String] {
        let value = probe.value as? String ?? ""
        var fields: [String: String] = [:]
        for pair in value.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        return fields
    }

    // MARK: Capture

    /// Waits until three screenshots half a second apart are byte-identical, then keeps the
    /// last as `ref-<device>-<state>.png` with its conditions as `ref-<device>-<state>.json`.
    func capture(_ app: XCUIApplication, device: String, state: String) {
        let name = "ref-\(device)-\(state)"
        var previous = XCUIScreen.main.screenshot().pngRepresentation
        var identical = 0
        let deadline = Date().addingTimeInterval(30)
        var settled: XCUIScreenshot?
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            let shot = XCUIScreen.main.screenshot()
            let png = shot.pngRepresentation
            identical = png == previous ? identical + 1 : 0
            previous = png
            if identical >= 2 {
                settled = shot
                break
            }
        }
        guard let settled else {
            attach(XCUIScreen.main.screenshot(), "\(name)-unsettled")
            XCTFail("\(name): the screen never held still for a second")
            return
        }
        // The screenshot's bitmap is the panel's native portrait; its image carries the
        // rotation. Drawn upright at the same scale (a quarter turn, no resampling), in sRGB.
        let image = settled.image
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        format.preferredRange = .standard
        let upright = UIGraphicsImageRenderer(size: image.size, format: format).pngData { _ in
            image.draw(at: .zero)
        }
        let pixels = (Int(image.size.width * image.scale), Int(image.size.height * image.scale))
        XCTAssertTrue(pixels.0 > pixels.1, "\(name) should be landscape, not \(pixels.0)x\(pixels.1)")

        let shot = XCTAttachment(uniformTypeIdentifier: "public.png", name: "\(name).png",
                                 payload: upright, userInfo: nil)
        shot.lifetime = .keepAlways
        add(shot)

        var fields = conditions(app.otherElements["desktopref-probe"])
        fields["state"] = state
        fields["device"] = device
        fields["mock"] = app.launchEnvironment["HERDR_SCREENSHOT_MOCK"]
        fields["fixture"] = served.map { "desktop-reference-\($0.name).json" } ?? "\(Self.fixtureName).json"
        fields["fixtureSHA256"] = served?.sha256 ?? Self.fixtureSHA256
        fields["pixels"] = "\(pixels.0)x\(pixels.1)"
        let json = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .prettyPrinted])) ?? Data()
        let record = XCTAttachment(uniformTypeIdentifier: "public.json", name: "\(name).json",
                                   payload: json, userInfo: nil)
        record.lifetime = .keepAlways
        add(record)
    }

}
