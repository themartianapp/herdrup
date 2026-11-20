#if DEBUG
import Foundation
import HerdrKit

/// The cold-start mock (`HERDR_SCREENSHOT_MOCK=cachedhome`, slow-network fix 4). The cache
/// holds last launch's roster (`kept-alfa`, `kept-bravo`) and the last screen of
/// `fresh-charlie`'s terminal (w1:p3, a codex agent, so its page opens on the terminal). The
/// daemon answers `agent.list` after `HERDR_MOCK_LIST_DELAY` seconds (default 6) with today's
/// roster (`fresh-alfa` on the same pane, `fresh-charlie` new), and starts every pane stream
/// and backfill read `HERDR_MOCK_STREAM_DELAY` seconds late (default 0). The cache lives in
/// its own temporary directory, never the app's. No agent here is idle: the home folds idle
/// agents into a closed "Idle" row (`AgentGroup.startsCollapsed`), and the tests find each
/// row by its identifier.
///
/// `HERDR_MOCK_LIST_FAIL` makes `agent.list` fail (after the same delay), as a first
/// connection to a broken machine does: a comma-separated list of `daemonUnavailable`
/// (herdr is not running) and `incompatible` (herdr is too old), one per request in order.
/// The last one repeats, so a background poll cannot run out of failures before a Retry.
enum CachedHomeMock {
    static let keptList = #"{"id":"mock","result":{"type":"agent_list","agents":[{"pane_id":"w1:p1","name":"kept-alfa","agent":"omp","agent_status":"working","cwd":"/root/alfa"},{"pane_id":"w1:p2","name":"kept-bravo","agent":"claude","agent_status":"blocked","cwd":"/root/bravo"}]}}"#
    static let freshList = #"{"id":"mock","result":{"type":"agent_list","agents":[{"pane_id":"w1:p1","name":"fresh-alfa","agent":"omp","agent_status":"working","cwd":"/root/alfa"},{"pane_id":"w1:p3","name":"fresh-charlie","agent":"codex","agent_status":"working","cwd":"/root/charlie"}]}}"#
    /// The kept screen's marker line, which the UI test looks for.
    static let keptScreenMarker = "KEPT-SCREEN-FROM-LAST-LAUNCH"
    static let keptScreen = "$ cargo test\n   Compiling charlie v0.1.0\n\(keptScreenMarker)\ntest result: ok. 42 passed\n$ "

    private static func seconds(_ key: String, default value: Double) -> Double {
        ProcessInfo.processInfo.environment[key].flatMap(Double.init) ?? value
    }
    static var listDelaySeconds: Double { seconds("HERDR_MOCK_LIST_DELAY", default: 6) }
    static var streamDelaySeconds: Double { seconds("HERDR_MOCK_STREAM_DELAY", default: 0) }
    /// The host a failing connection names in its guidance.
    static let host = "cachedhome"

    /// The failures `HERDR_MOCK_LIST_FAIL` asks for, served in order, the last one for good.
    private final class FailureSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: [String]

        init(_ spec: String?) {
            remaining = (spec ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        /// The next failure, or nil when `agent.list` answers.
        func next() -> TransportError? {
            let kind: String? = lock.withLock {
                guard let first = remaining.first else { return nil }
                if remaining.count > 1 { remaining.removeFirst() }
                return first
            }
            switch kind {
            case nil: return nil
            case "incompatible": return .herdrIncompatible(host: CachedHomeMock.host)
            default: return .daemonUnavailable(host: CachedHomeMock.host)
            }
        }
    }
    private static let listFailures = FailureSequence(ProcessInfo.processInfo.environment["HERDR_MOCK_LIST_FAIL"])

    static func client() -> HerdrClient {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cachedhome-\(UUID().uuidString)", isDirectory: true)
        let scope = ContentCache(root: root).scope(machine: "mock@cachedhome:22", session: nil)
        scope.seedAgentList(keptList)
        scope.storeTerminalText(keptScreen, pane: "w1:p3")
        scope.cache.flush()
        return HerdrClient(transport: SlowTransport(), contentCache: scope)
    }

    private struct SlowTransport: HerdrTransport {
        private let base = MockTransport()

        func roundTrip(_ requestLine: String) async throws -> String {
            if requestLine.contains("agent.list") {
                try await Task.sleep(nanoseconds: UInt64(CachedHomeMock.listDelaySeconds * 1e9))
                if let failure = CachedHomeMock.listFailures.next() { throw failure }
                return CachedHomeMock.freshList
            }
            if requestLine.contains("agent.read") || requestLine.contains("pane.read") {
                try await Task.sleep(nanoseconds: UInt64(CachedHomeMock.streamDelaySeconds * 1e9))
            }
            return try await base.roundTrip(requestLine)
        }

        func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
            let delay = CachedHomeMock.streamDelaySeconds
            guard delay > 0, requestLine.contains("pane.stream") else { return base.stream(requestLine) }
            let base = self.base
            return AsyncThrowingStream { continuation in
                let task = Task {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
                    do {
                        for try await line in base.stream(requestLine) { continuation.yield(line) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
}
#endif
