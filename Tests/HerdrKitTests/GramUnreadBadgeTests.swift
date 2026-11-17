import XCTest
@testable import HerdrKit

/// The off-tab Gram badge poller (TerminalHomeView.swift) counts an `unread_only` answer with
/// `GramListAnswer.unreadBadgeCount`. A paging daemon answers with one page plus the
/// store-wide `unread_count`; counting the page's messages undercounts the badge.
final class GramUnreadBadgeTests: XCTestCase {
    private func unreadAnswer(_ line: String) async throws -> GramListAnswer {
        try await HerdrClient(transport: RecordingTransport(reply: line)).gramList(unreadOnly: true)
    }

    private static let rows = [MockWireFixtures.gramOldestRows, MockWireFixtures.gramOldestRows
        .replacingOccurrences(of: #""id":"gx1""#, with: #""id":"gx2""#)]

    /// A page of 2 unread rows out of 30: the badge says 30.
    func testPagedAnswerCountsTheDaemonsUnreadTotal() async throws {
        let line = #"{"id":"mock","result":{"type":"gram_list","messages":["#
            + Self.rows.joined(separator: ",") + #"],"has_more":true,"unread_count":30}}"#
        let answer = try await unreadAnswer(line)
        XCTAssertEqual(answer.messages?.count, 2)
        XCTAssertEqual(answer.unreadBadgeCount, 30)
    }

    /// A daemon without paging sends no `unread_count`: every unread message is in the answer.
    func testUnpagedAnswerCountsItsMessages() async throws {
        let answer = try await unreadAnswer(MockWireFixtures.gramListAnswer(rows: Self.rows, hasMore: false))
        XCTAssertNil(answer.unreadCount)
        XCTAssertEqual(answer.unreadBadgeCount, 2)
    }

    func testEmptyAnswerWithZeroUnreadIsZero() async throws {
        let answer = try await unreadAnswer(
            #"{"id":"mock","result":{"type":"gram_list","messages":[],"unread_count":0}}"#)
        XCTAssertEqual(answer.unreadBadgeCount, 0)
    }
}
