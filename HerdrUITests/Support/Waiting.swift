import XCTest

/// Whether `condition` holds within `timeout`, checked every `interval` seconds.
///
/// JUDGES EVERY READ IT STARTS, INCLUDING ONE MORE AFTER THE DEADLINE. One accessibility
/// query can take seconds on a slow runner, and a waiter that gives up at its deadline
/// while that read is still in flight (as `XCTNSPredicateExpectation` does) fails on a
/// state that already matched. This is the GramTests `waitForPredicate` pattern (#440).
/// An `interval` of 0 re-checks without sleeping.
func poll(_ timeout: TimeInterval, every interval: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        if interval > 0 { Thread.sleep(forTimeInterval: interval) }
    } while Date() < deadline
    return condition()
}

/// The value `sample` reads once it has held still: `matches` consecutive comparisons, each
/// between two reads at least `interval` apart, found it equal (and `accept` true). `stable`
/// is false when `timeout` passed first; `value` is then the last read, for the message.
///
/// EVERY COMPARISON SPANS A REAL INTERVAL. Two reads taken back to back agree while a change
/// is still on its way: a DEBUG counter that publishes every 250 ms reads the same twice
/// before pending renders land, a decelerating frame reads the same twice within one
/// accessibility snapshot. So the first read is followed by a sleep, never compared at once.
/// Pick `interval` at least the probe's publish period (≥ 0.3 s for the render counters);
/// for frames, equal reads spanning ≥ 0.25 s (`matches: 2` at 0.15 s, or one match at 0.25 s
/// where each read is a slow query). Like `poll`, it judges a read started before the deadline.
func waitForStable<Value: Equatable>(timeout: TimeInterval, interval: TimeInterval, matches: Int = 1,
                                     accept: (Value) -> Bool = { _ in true },
                                     _ sample: () -> Value) -> (value: Value, stable: Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    var last = sample()
    var agreed = 0
    while true {
        Thread.sleep(forTimeInterval: interval)
        let now = sample()
        agreed = now == last && accept(now) ? agreed + 1 : 0
        last = now
        if agreed >= matches { return (now, true) }
        if Date() >= deadline { return (now, false) }
    }
}

extension XCTestCase {
    /// Polls the label of the element identified `id` until `condition` holds, and returns
    /// it. Otherwise FAILS THE TEST with the last label read, so the failure shows what the
    /// app actually said.
    @discardableResult
    func pollLabel(_ app: XCUIApplication, _ id: String, _ what: String, timeout: TimeInterval = 10,
                   file: StaticString = #filePath, line: UInt = #line,
                   _ condition: (String) -> Bool) -> String {
        let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
        var last = ""
        let met = poll(timeout, every: 0.3) {
            guard element.exists else { return false }
            last = element.label
            return condition(last)
        }
        if !met { XCTFail("\(what): \(id) = \(last)", file: file, line: line) }
        return last
    }
}

/// `waitForExistence(timeout:)` and `waitForNonExistence(timeout:)` without their blind first
/// second. XCTest's waiter first checks ONE SECOND after the call, so every wait cost at least a
/// second even for an element already on screen: #694's iphone-terminal shard spent 498 s in 480
/// such waits. These check at once, then every 0.2 s, and judge a read still in flight at the
/// deadline (`poll`). Same condition, same timeout.
extension XCUIElement {
    func exists(within timeout: TimeInterval) -> Bool {
        poll(timeout, every: 0.2) { exists }
    }

    func gone(within timeout: TimeInterval) -> Bool {
        poll(timeout, every: 0.2) { !exists }
    }
}

/// Hittability under a continuously re-sorting roster is a state to WAIT for, not to
/// sample. XCTest has `waitForExistence` but no hittable equivalent, so these poll it
/// the same way — bounded, and failing by returning false so the caller's message,
/// which names the bound, is the one that shows up.
///
/// THEY POLL HITTABILITY, NOT EXISTENCE, and the distinction is the whole point.
/// Existence is satisfied by an element that is in the hierarchy but scrolled
/// off-screen or occluded — precisely the state the original assertion was written to
/// rule out. A bounded wait on existence would be green against a roster that never
/// becomes reachable at all.
///
/// AN ELEMENT WITH NO ON-SCREEN FRAME IS NOT YET HITTABLE, NOT AN ERROR. Asked about an
/// element that exists but whose frame is empty or lies wholly off the screen,
/// `isHittable` does not answer false: XCTest records "Failed to determine hittability …
/// Activation point invalid and no suggested hit points based on element frame" and the
/// test stops. DesktopGramReferenceShots.testGramMixedLatestReference hit that on
/// ipad-script (j_e583ccf1 on iPad 11, j_f6303b1f on iPad Pro). In j_e583ccf1 it asked about
/// "1 unread" 0.86 s after opening Gram and failed; earlier in the same job, on iPad Pro 13,
/// it asked 1.24 s after and the element was hittable at once. So these check the frame
/// first (a frame read of an existing element never raises) and ask for hittability only
/// once the element has a hit point to give.
///
/// THE BOUND IS THE SCREEN (SpringBoard's frame), NOT `XCUIApplication().frame`. In an iPad
/// window shrunk out of full screen the app's frame did not contain its own Back button:
/// SettingsTests.testCompactSettingsSurviveResizeAndResume, window {{329, 359}, {375, 543}},
/// waited 5 s on a Back button XCTest had found every 0.1 s (j_e5656147), where main's
/// plain `isHittable` passed. The screen holds every window, in every orientation.
extension XCUIElement {

    func waitForHittable(timeout: TimeInterval) -> Bool {
        let screen = Self.screenFrame
        return poll(timeout, every: 0.1) { hasFrame(on: screen) && isHittable }
    }

    func waitForNotHittable(timeout: TimeInterval) -> Bool {
        let screen = Self.screenFrame
        return poll(timeout, every: 0.1) { !hasFrame(on: screen) || !isHittable }
    }

    /// The screen in the current orientation: SpringBoard's frame, read once per wait.
    private static var screenFrame: CGRect {
        XCUIApplication(bundleIdentifier: "com.apple.springboard").frame
    }

    /// Exists with a non-empty frame that overlaps `screen`.
    private func hasFrame(on screen: CGRect) -> Bool {
        guard exists else { return false }
        let frame = frame
        guard !frame.isEmpty else { return false }
        return !frame.intersection(screen).isEmpty
    }

    /// iPadOS animates a restored or resized window into place; frames read during that
    /// animation, and taps aimed with them, are wrong. Two reads 0.3 s apart agree, or 6 s.
    func waitForSettledFrame() {
        _ = waitForStable(timeout: 6, interval: 0.3) { frame }
    }
}
