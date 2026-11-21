import Foundation
import XCTest
@testable import HerdrKit

/// `agent.dismiss_ask` (herdr presses Esc on omp's pending ask) and the pending ask's
/// `dismissable`. Every fixture is synthetic.
final class DismissAskTests: XCTestCase {

    func testDismissSendsTargetAndAskIDAndDecodesTheResult() async throws {
        let transport = RecordingTransport(reply: #"{"id":"x","result":{"dismissed":true}}"#)
        let result = try await HerdrClient(transport: transport).agentDismissAsk(target: "w1:p1", askID: "call_7")
        XCTAssertEqual(result, AgentDismissAskResult(dismissed: true))
        let (method, params) = try transport.last()
        XCTAssertEqual(method, "agent.dismiss_ask")
        XCTAssertEqual(params["target"] as? String, "w1:p1")
        XCTAssertEqual(params["ask_id"] as? String, "call_7")
        XCTAssertEqual(Set(params.keys), ["target", "ask_id"])
    }

    func testBothNoLongerPendingCodesReadAsAlreadyAnswered() async {
        let cases: [(String, AgentDismissAskError)] = [
            ("ask_not_pending", .alreadyAnswered(code: "ask_not_pending")),
            ("ask_mismatch", .alreadyAnswered(code: "ask_mismatch")),
            ("guest_forbidden", .refused(APIError(code: "guest_forbidden", message: "no"))),
        ]
        for (code, expected) in cases {
            let client = HerdrClient(transport: RecordingTransport.error(code: code, message: "no"))
            do {
                _ = try await client.agentDismissAsk(target: "w1:p1", askID: "a")
                XCTFail("\(code) should throw")
            } catch {
                XCTAssertEqual(error as? AgentDismissAskError, expected, code)
                XCTAssertEqual((error as? AgentDismissAskError)?.code, code)
            }
        }
    }

    func testPendingAskDismissableDecodes() throws {
        func pending(_ json: String) throws -> TranscriptPendingAsk {
            try JSONDecoder().decode(TranscriptPendingAsk.self, from: Data(json.utf8))
        }
        XCTAssertTrue(try pending(#"{"id":"a","questions":[],"answerable":false,"dismissable":true}"#).dismissable)
        XCTAssertFalse(try pending(#"{"id":"a","questions":[],"answerable":true}"#).dismissable,
                       "an older server sends no dismissable")
        XCTAssertFalse(try pending(#"{"id":"a","dismissable":false}"#).dismissable)
    }
}
