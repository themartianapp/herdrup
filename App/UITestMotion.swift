import SwiftUI
import UIKit

/// UI tests run with animations off (`HERDR_NO_ANIMATIONS=1`, set by the UI tests' launch
/// helper `XCUIApplication.forUITest()`). XCUITest waits for the app to idle before and after
/// every action, and that wait lasts as long as any animation in flight: a spring, a sheet, a
/// blinking caret. On #694's iphone-terminal shard it took 796 s of the 3,560 s of test time,
/// and a caret that never stopped made PagingTests' single test take 255 s.
///
/// Off means: UIKit animations off (`UIView.setAnimationsEnabled`), every window's layer
/// time at 100x for what UIKit still animates (system transitions, the keyboard), SwiftUI's
/// implicit and explicit animations dropped at the root (`uiTestMotion()`), Chat's send and
/// folder transitions off, and the terminal caret steady. DEBUG only; a test about motion
/// (StatusMotionTests) launches with `HERDR_NO_ANIMATIONS=0`.
enum UITestMotion {
    static let off: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["HERDR_NO_ANIMATIONS"] == "1"
        #else
        return false
        #endif
    }()

    /// Called once at launch, before the first window exists.
    @MainActor static func applyAtLaunch() {
        guard off else { return }
        UIView.setAnimationsEnabled(false)
        // Windows come and go (scenes, the keyboard's text-effects window): speed each up as
        // it becomes visible.
        NotificationCenter.default.addObserver(forName: UIWindow.didBecomeVisibleNotification,
                                               object: nil, queue: .main) { note in
            MainActor.assumeIsolated { (note.object as? UIWindow)?.layer.speed = 100 }
        }
    }
}

extension View {
    /// The root's SwiftUI animations off while `UITestMotion.off`; otherwise the view as it is.
    @ViewBuilder func uiTestMotion() -> some View {
        if UITestMotion.off {
            transaction { $0.disablesAnimations = true; $0.animation = nil }
        } else {
            self
        }
    }
}
