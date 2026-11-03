import UIKit
import HerdrKit

/// The app side of the anonymous daily usage ping (`UsagePing` in HerdrKit): RootView calls
/// `foregrounded()` each time its scene becomes active, and `UsagePing` sends at most one ping
/// per UTC day, fire-and-forget.
///
/// Release builds ping the guest relay. DEBUG builds never ping it: every UI test, screenshot /
/// mock mode and reference capture runs a DEBUG build, and so does a developer's own phone,
/// which is not an install to count. A DEBUG launch pings only when `HERDR_USAGE_PING_URL`
/// names a stub endpoint to ping instead.
@MainActor
enum UsagePingLaunch {
    private static let pinger: UsagePing? = {
        #if DEBUG
        guard let stub = ProcessInfo.processInfo.environment["HERDR_USAGE_PING_URL"],
              let endpoint = URL(string: stub)
        else { return nil }
        return UsagePing(endpoint: endpoint)
        #else
        return UsagePing()
        #endif
    }()

    static func foregrounded() {
        guard let pinger else { return }
        let process = ProcessInfo.processInfo
        let platform = UsagePing.Platform(isiOSAppOnMac: process.isiOSAppOnMac,
                                          isMacCatalystApp: process.isMacCatalystApp,
                                          isPad: UIDevice.current.userInterfaceIdiom == .pad)
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        Task { await pinger.pingIfDue(platform: platform, version: version, build: build) }
    }
}
