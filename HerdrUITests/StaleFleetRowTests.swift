import XCTest

/// THE RENDER RECEIPT for the degraded-peer staleness marker.
///
/// The unit tests pin the RULE (`AgentRow.showsUnconfirmedMarker`) but cannot see the
/// view, so a review mutant that disabled the card's condition entirely
/// (`if false && row.showsUnconfirmedMarker`) compiled and survived all 415 runnable
/// HerdrKit tests. That is the gap this file closes: it asserts the marker is actually
/// on screen, so the same mutant fails here instead of shipping green.
///
/// The `list` mock roster carries a federated `mcb-air/mcb-air` row whose live status the
/// daemon blanked to "unknown" after a missed poll, with the real state moved to
/// `last_known_status: "blocked"` and `reachability: "degraded"`. That row escalates into
/// NEEDS YOU on a last-known value, so it is exactly the row that must not read as a
/// confirmed one.
///
/// Asserts on the ACCESSIBILITY IDENTIFIER, not the visible string. The chip overrides its
/// accessibility label with an explanatory sentence for VoiceOver, which means the word
/// "stale" is not findable by label. The first version of this file looked for the label
/// and failed on its first CI run for exactly that reason.
final class StaleFleetRowTests: XCTestCase {

    private let markerID = "agent-row-stale-marker"

    override func setUp() { continueAfterFailure = false }

    func testDegradedFederatedRowRendersAStalenessMarker() {
        let app = XCUIApplication.launched(mock: "list")

        // Premise first: the roster actually rendered and the federated row is present.
        // Without this a missing marker could not be told apart from a missing screen.
        XCTAssertTrue(app.staticTexts["mcb-air/mcb-air"].exists(within: 12),
                      "the degraded federated fixture row should be on the roster")

        let marker = app.descendants(matching: .any).matching(identifier: markerID)
        XCTAssertTrue(marker.firstMatch.exists(within: 4),
                      "a needs-you row resting on a last-known status must be marked stale")

        // The marker is SCOPED: the two locally blocked fixture rows are live, so exactly
        // one chip exists. A mutant that marked every row would pass the assertion above.
        XCTAssertEqual(marker.count, 1, "only the unconfirmed row should carry the marker")

        // The label is the sentence a VoiceOver reader hears, not the four-letter chip.
        XCTAssertEqual(marker.firstMatch.label, "status not confirmed on the last poll",
                       "the marker must explain itself to a screen reader")
    }
}
