#if DEBUG
import Foundation
import HerdrKit

/// The cold-start mock (`HERDR_SCREENSHOT_MOCK=cachedhome`, slow-network fix 4): the cache
/// holds last launch's roster (`kept-alfa`, `kept-bravo`), and the daemon answers
/// `agent.list` only after `HERDR_MOCK_LIST_DELAY` seconds (default 6) with today's
/// (`fresh-alfa` on the same pane, `fresh-charlie` new). The cache lives in its own temporary
/// directory, never the app's.
enum CachedHomeMock {
    static let keptList = #"{"id":"mock","result":{"type":"agent_list","agents":[{"pane_id":"w1:p1","name":"kept-alfa","agent":"omp","agent_status":"idle","cwd":"/root/alfa"},{"pane_id":"w1:p2","name":"kept-bravo","agent":"claude","agent_status":"blocked","cwd":"/root/bravo"}]}}"#
    static let freshList = #"{"id":"mock","result":{"type":"agent_list","agents":[{"pane_id":"w1:p1","name":"fresh-alfa","agent":"omp","agent_status":"working","cwd":"/root/alfa"},{"pane_id":"w1:p3","name":"fresh-charlie","agent":"codex","agent_status":"idle","cwd":"/root/charlie"}]}}"#

    static var listDelaySeconds: Double {
        ProcessInfo.processInfo.environment["HERDR_MOCK_LIST_DELAY"].flatMap(Double.init) ?? 6
    }

    static func client() -> HerdrClient {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cachedhome-\(UUID().uuidString)", isDirectory: true)
        let scope = ContentCache(root: root).scope(machine: "mock@cachedhome:22", session: nil)
        scope.seedAgentList(keptList)
        return HerdrClient(transport: SlowListTransport(), contentCache: scope)
    }

    private struct SlowListTransport: HerdrTransport {
        private let base = MockTransport()

        func roundTrip(_ requestLine: String) async throws -> String {
            if requestLine.contains("agent.list") {
                try await Task.sleep(nanoseconds: UInt64(CachedHomeMock.listDelaySeconds * 1e9))
                return CachedHomeMock.freshList
            }
            return try await base.roundTrip(requestLine)
        }

        func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> { base.stream(requestLine) }
    }
}
#endif
