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
extension XCUIElement {

    func waitForHittable(timeout: TimeInterval) -> Bool {
        poll(timeout, every: 0.1) { isHittable }
    }

    func waitForNotHittable(timeout: TimeInterval) -> Bool {
        poll(timeout, every: 0.1) { !isHittable }
    }

    /// iPadOS animates a restored or resized window into place; frames read during that
    /// animation, and taps aimed with them, are wrong.
    func waitForSettledFrame() {
        var last = frame
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.3)
            let now = frame
            if now == last { return }
            last = now
        }
    }
}
