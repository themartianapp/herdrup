import XCTest
@testable import HerdrKit

final class ConversationColumnWidthTests: XCTestCase {
    private typealias W = ConversationColumnWidth

    func testDefaultsAndStorageKey() {
        XCTAssertEqual(W.storageKey, "conversation.columnWidth")
        XCTAssertEqual(W.defaultWidth, 1000)
        XCTAssertEqual(W.minimum, 560)
        XCTAssertEqual(W.travel, 200)
        XCTAssertEqual(W.narrowest, 320)
        XCTAssertEqual(W.readable, 720)
        XCTAssertEqual(W.wide, 1000)
        XCTAssertEqual(W.snapDistance, 12)
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "herdr.conversationcolumn.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    /// A reader who sized Chat before the width was shared keeps that width: the one Chat
    /// and Gram now read.
    func testMigrationKeepsTheWidthChosenInChat() throws {
        try withDefaults { defaults in
            defaults.set(820.0, forKey: "chat.columnWidth")
            W.migrate(defaults)
            XCTAssertEqual(defaults.object(forKey: W.storageKey) as? Double, 820)
            XCTAssertNil(defaults.object(forKey: "chat.columnWidth"), "the old key is gone")
            W.migrate(defaults)
            XCTAssertEqual(defaults.object(forKey: W.storageKey) as? Double, 820, "a second launch changes nothing")
        }
    }

    func testMigrationNeverOverwritesTheSharedWidth() throws {
        try withDefaults { defaults in
            defaults.set(W.readable, forKey: W.storageKey)
            defaults.set(W.full, forKey: "chat.columnWidth")
            W.migrate(defaults)
            XCTAssertEqual(defaults.object(forKey: W.storageKey) as? Double, W.readable)
            XCTAssertNil(defaults.object(forKey: "chat.columnWidth"))
        }
    }

    func testMigrationWithoutAChatWidthStoresNothing() throws {
        try withDefaults { defaults in
            W.migrate(defaults)
            XCTAssertNil(defaults.object(forKey: W.storageKey), "the default width applies")
        }
    }

    func testDisplayedIsTheStoredWidthUpToTheAvailableWidth() {
        XCTAssertEqual(W.displayed(stored: 820, available: 1200), 820)
        XCTAssertEqual(W.displayed(stored: 1000, available: 900), 900, "a narrower window shows Full")
        XCTAssertEqual(W.displayed(stored: W.full, available: 1366), 1366, "Full is the whole width")
        XCTAssertEqual(W.displayed(stored: 300, available: 1200), 560, "a stored width is held to the minimum")
        XCTAssertEqual(W.displayed(stored: .nan, available: 1200), 1000, "an unusable value shows the default")
        XCTAssertEqual(W.displayed(stored: -5, available: 1200), 1000)
        XCTAssertEqual(W.displayed(stored: 820, available: 400), 400, "a chat narrower than the minimum is shown whole")
    }

    func testClampHoldsTheWidthBetweenMinimumAndAvailable() {
        XCTAssertEqual(W.clamped(400, available: 1200), 560)
        XCTAssertEqual(W.clamped(1500, available: 1200), 1200)
        XCTAssertEqual(W.clamped(800, available: 1200), 800)
        XCTAssertEqual(W.clamped(800, available: 500), 500)
    }

    /// A conversation too narrow for 560 to leave 200 pt to narrow by goes down 200 pt
    /// instead. iPhone Duo's inner display held wide shows the chat 547 pt wide beside the
    /// sidebar: before, its handles moved the column by nothing.
    func testANarrowConversationCanStillBeNarrowedBy200Points() {
        XCTAssertEqual(W.minimum(available: 1400), 560)
        XCTAssertEqual(W.minimum(available: 760), 560)
        XCTAssertEqual(W.minimum(available: 700), 500)
        XCTAssertEqual(W.minimum(available: 547), 347, "iPhone Duo held wide, beside the sidebar")
        XCTAssertEqual(W.clamped(300, available: 700), 500)
        XCTAssertEqual(W.dragged(from: 547, translation: -60, edge: .trailing, available: 547), 427,
                       "a drag inwards narrows the Duo's Full column")
        XCTAssertEqual(W.dragged(from: 547, translation: 60, edge: .leading, available: 547), 427)
        XCTAssertEqual(W.dragged(from: 547, translation: -400, edge: .trailing, available: 547), 347, "its minimum")
        XCTAssertEqual(W.dragged(from: 347, translation: 400, edge: .trailing, available: 547), 547, "and back to Full")
        XCTAssertEqual(W.decremented(360, available: 547), 347)
        XCTAssertEqual(W.displayed(stored: 450, available: 650), 450, "a width chosen there shows there")
        XCTAssertEqual(W.displayed(stored: 450, available: 1200), 560, "and keeps to 560 where there is room")
        XCTAssertEqual(W.displayed(stored: 300, available: 650), 450, "a stored width is held to the minimum")
    }

    /// A conversation that cannot lose 200 pt and stay 320 wide has no handles: it is shown
    /// whole, as on a phone (iPhone Duo's inner display held tall beside the sidebar).
    func testOnlyAConversationAtLeast520WideIsResizable() {
        XCTAssertTrue(W.isResizable(available: 1366))
        XCTAssertTrue(W.isResizable(available: 547))
        XCTAssertTrue(W.isResizable(available: 520))
        XCTAssertFalse(W.isResizable(available: 519))
        XCTAssertFalse(W.isResizable(available: 349))
        XCTAssertFalse(W.isResizable(available: 0))
    }

    func testSnapsWithinTwelvePointsOfReadableWideAndFull() {
        XCTAssertEqual(W.snapped(709, available: 1400), 720)
        XCTAssertEqual(W.snapped(733, available: 1400), 733, "outside the 12 pt zone")
        XCTAssertEqual(W.snapped(707, available: 1400), 707)
        XCTAssertEqual(W.snapped(1012, available: 1400), 1000)
        XCTAssertEqual(W.snapped(1390, available: 1400), 1400, "Full")
        XCTAssertEqual(W.snapped(1100, available: 1400), 1100)
        XCTAssertEqual(W.snapped(1006, available: 1010), 1010, "the nearer of Wide and Full wins")
        XCTAssertEqual(W.snapped(1003, available: 1010), 1000)
        XCTAssertEqual(W.snapPoints(available: 900).map(\.snap), [.readable, .full], "Wide does not fit")
    }

    func testDraggingAnEdgeResizesSymmetrically() {
        XCTAssertEqual(W.dragged(from: 1000, translation: -50, edge: .trailing, available: 1400), 900,
                       "the right edge inwards narrows by twice the drag")
        XCTAssertEqual(W.dragged(from: 1000, translation: 50, edge: .leading, available: 1400), 900,
                       "the left edge inwards narrows by twice the drag")
        XCTAssertEqual(W.dragged(from: 800, translation: 30, edge: .trailing, available: 1400), 860)
        XCTAssertEqual(W.dragged(from: 800, translation: -30, edge: .leading, available: 1400), 860)
        XCTAssertEqual(W.dragged(from: 800, translation: -600, edge: .trailing, available: 1400), 560, "minimum")
        XCTAssertEqual(W.dragged(from: 800, translation: 600, edge: .trailing, available: 1400), 1400, "Full")
        XCTAssertEqual(W.dragged(from: 1000, translation: -143, edge: .trailing, available: 1400), 720,
                       "714 snaps to Readable")
        XCTAssertEqual(W.dragged(from: 1000, translation: -100.3, edge: .trailing, available: 1400), 799,
                       "whole points")
    }

    func testStoredValueForAChosenWidth() {
        XCTAssertEqual(W.stored(for: 720, available: 1400), 720)
        XCTAssertEqual(W.stored(for: 1000, available: 1400), 1000)
        XCTAssertEqual(W.stored(for: 1400, available: 1400), W.full, "Full follows a wider window")
        XCTAssertEqual(W.stored(for: 860, available: 1400), 860)
        XCTAssertEqual(W.stored(for: 1000, available: 1000), 1000, "Wide when Wide is also the whole width")
    }

    func testResetIsWideOrFullWhenNarrower() {
        XCTAssertEqual(W.resetWidth, 1000)
        XCTAssertEqual(W.displayed(stored: W.resetWidth, available: 1400), 1000)
        XCTAssertEqual(W.displayed(stored: W.resetWidth, available: 820), 820)
    }

    func testReadoutNamesTheSnapPoint() {
        XCTAssertEqual(W.readout(820, available: 1400), "820 pt")
        XCTAssertEqual(W.readout(720, available: 1400), "720 pt · Readable")
        XCTAssertEqual(W.readout(1000, available: 1400), "1000 pt · Wide")
        XCTAssertEqual(W.readout(1400, available: 1400), "1400 pt · Full")
        XCTAssertEqual(W.readout(820.4, available: 1400), "820 pt")
        XCTAssertEqual(W.accessibilityValue(820, available: 1400), "820 points")
        XCTAssertEqual(W.accessibilityValue(720, available: 1400), "720 points, Readable")
    }

    func testAccessibilityStepsAreFortyPointsAndStopOnSnapPoints() {
        XCTAssertEqual(W.incremented(800, available: 1400), 840)
        XCTAssertEqual(W.decremented(800, available: 1400), 760)
        XCTAssertEqual(W.decremented(750, available: 1400), 720, "stops on Readable")
        XCTAssertEqual(W.decremented(720, available: 1400), 680, "and moves on from it")
        XCTAssertEqual(W.incremented(700, available: 1400), 720)
        XCTAssertEqual(W.incremented(980, available: 1400), 1000, "stops on Wide")
        XCTAssertEqual(W.incremented(1380, available: 1400), 1400, "held to Full")
        XCTAssertEqual(W.incremented(1400, available: 1400), 1400)
        XCTAssertEqual(W.decremented(580, available: 1400), 560, "held to the minimum")
        XCTAssertEqual(W.decremented(560, available: 1400), 560)
    }
}
