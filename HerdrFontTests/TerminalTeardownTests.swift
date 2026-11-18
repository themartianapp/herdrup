import SwiftUI
import UIKit
import XCTest
@testable import Herdr

/// A terminal torn down with Ctrl armed must not touch the host's Ctrl binding from inside
/// `dismantleUIView` (#679).
///
/// The 1.2.1 (238) TestFlight abort was a SwiftUI state write from `dismantleUIView` while a
/// `UIHostingController` deallocated: `ViewGraphHost.tearDown` → `GraphHost.invalidate` →
/// `dismantleUIView` → state setter → `swift_beginAccess` fatal in `GraphHost.isUpdating`.
/// `LiveTerminalView` used to disarm Ctrl there, synchronously. The UI test that remounts the
/// terminal with refresh stayed green without the fix, because an in-graph remount does not
/// run inside `GraphHost.invalidate`. So this test tears a hosting controller down, as in the
/// crash, and judges the binding's accesses directly instead of waiting for SwiftUI to abort:
/// the binding here is a plain closure pair, so a regression fails an assertion instead of
/// crashing the test host.
@MainActor
final class TerminalTeardownTests: XCTestCase {
    /// Every access to the host's Ctrl binding made from inside the teardown: with
    /// `dismantleUIView` on the stack, or synchronously while the hosting controller is released.
    private final class ArmedBinding {
        var armed = true
        var tearingDown = false
        var accessesDuringDismantle: [String] = []
        var disarms = 0

        var binding: Binding<Bool> {
            Binding(get: { [self] in
                record("get")
                return armed
            }, set: { [self] value in
                record("set \(value)")
                if !value { disarms += 1 }
                armed = value
            })
        }

        private func record(_ access: String) {
            if tearingDown || Thread.callStackSymbols.contains(where: { $0.contains("dismantleUIView") }) {
                accessesDuringDismantle.append(access)
            }
        }
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func containsSurface(_ view: UIView) -> Bool {
        view is LiveTerminalView.TerminalSurfaceView || view.subviews.contains(where: containsSurface)
    }

    func testHostingTeardownWithControlArmedDefersTheDisarm() throws {
        let armed = ArmedBinding()
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        var host: UIHostingController<LiveTerminalView>?
        weak var hostView: UIView?
        autoreleasepool {
            let made = UIHostingController(rootView: LiveTerminalView(
                client: .init(transport: MockTransport()), paneID: "teardown:1",
                controlArmed: armed.binding))
            window.rootViewController = made
            window.makeKeyAndVisible()
            hostView = made.view
            host = made
        }
        XCTAssertTrue(spin(until: { hostView.map(containsSurface) ?? false }),
                      "the terminal must be mounted before it is torn down")
        XCTAssertTrue(armed.armed, "nothing disarms Ctrl while the terminal is up")

        // Off screen first, then released: in the crash, the hosting controller was already out
        // of the window when the presentation holding it let it go.
        autoreleasepool {
            window.rootViewController = nil
            window.isHidden = true
        }
        _ = spin(until: { false }, timeout: 0.3)
        XCTAssertTrue(host != nil && hostView != nil, "the test alone still holds the hosting controller")

        armed.tearingDown = true
        autoreleasepool { host = nil }
        armed.tearingDown = false
        XCTAssertTrue(spin(until: { hostView == nil }), "the hosting view must be torn down")

        XCTAssertEqual(armed.accessesDuringDismantle.filter { $0.hasPrefix("set") }, [],
                       "dismantleUIView must not write the host's Ctrl binding: inside "
                       + "GraphHost.invalidate a SwiftUI state write aborts the app (#679)")
        XCTAssertEqual(armed.accessesDuringDismantle.filter { $0.hasPrefix("get") }, [],
                       "nor read it: the deferred disarm decides on the next main-queue turn")
        XCTAssertTrue(spin(until: { armed.disarms == 1 }, timeout: 5),
                      "the torn-down terminal still cancels the armed Ctrl, after the teardown")
        XCTAssertFalse(armed.armed)
    }
}
