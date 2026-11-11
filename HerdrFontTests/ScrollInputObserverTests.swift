import UIKit
import UIKit.UIGestureRecognizerSubclass
import XCTest
@testable import Herdr

/// The scroll-event observer behind the Chat's up arrow (review of #649, F1): a Mac wheel or
/// trackpad scrolls a UIScrollView without `isTracking`/`isDragging`/`isDecelerating`, so
/// `ScrollActivityObserver` watches those scroll events with a pan recognizer of its own. It
/// must see scroll events only (no touch), and leave the scroll view's own scrolling alone.
@MainActor
final class ScrollInputObserverTests: XCTestCase {
    private func attachedObserver(onScrollInput: (() -> Void)?)
        -> (ScrollActivityObserver.Coordinator, UIScrollView, UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let scrollView = UIScrollView(frame: window.bounds)
        scrollView.contentSize = CGSize(width: 400, height: 4000)
        window.addSubview(scrollView)
        let probe = ScrollActivityObserver.ProbeView()
        scrollView.addSubview(probe)
        let observer = ScrollActivityObserver.Coordinator(isEnabled: true, onChange: { _ in })
        observer.onScrollInput = onScrollInput
        observer.attach(from: probe)
        return (observer, scrollView, window)
    }

    func testAWheelOrTrackpadScrollReachesTheObserver() throws {
        var inputs = 0
        let (observer, scrollView, window) = attachedObserver(onScrollInput: { inputs += 1 })
        defer { observer.stop(); _ = window }
        let pan = try XCTUnwrap(observer.scrollInput, "the observer watches scroll events")
        XCTAssertTrue(pan.view === scrollView, "on the scroll view itself")
        XCTAssertEqual(pan.allowedScrollTypesMask, .all, "it opts in to wheel and trackpad scroll events")
        XCTAssertEqual(pan.maximumNumberOfTouches, 0, "it takes no touch: a finger stays the scroll view's")
        XCTAssertFalse(pan.cancelsTouchesInView)
        XCTAssertTrue(pan.isEnabled)
        XCTAssertTrue(observer.gestureRecognizer(pan, shouldRecognizeSimultaneouslyWith: scrollView.panGestureRecognizer),
                      "it never stops the scroll view's own pan")

        pan.state = .possible
        observer.scrolled(pan)
        XCTAssertEqual(inputs, 0, "nothing until the scroll begins")
        pan.state = .began
        observer.scrolled(pan)
        pan.state = .changed
        observer.scrolled(pan)
        XCTAssertEqual(inputs, 2, "a wheel or trackpad scroll is reader input from its first event")
        pan.state = .ended
        observer.scrolled(pan)
        XCTAssertEqual(inputs, 2)

        observer.stop()
        XCTAssertFalse(scrollView.gestureRecognizers?.contains(pan) ?? false, "stop() takes it off the scroll view")
    }

    func testWithoutAListenerTheRecognizerStaysOff() throws {
        let (observer, _, window) = attachedObserver(onScrollInput: nil)
        defer { observer.stop(); _ = window }
        XCTAssertFalse(try XCTUnwrap(observer.scrollInput).isEnabled)
        observer.onScrollInput = {}
        XCTAssertTrue(try XCTUnwrap(observer.scrollInput).isEnabled)
    }
}
