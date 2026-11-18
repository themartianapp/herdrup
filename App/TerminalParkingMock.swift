#if DEBUG
import Foundation
import HerdrKit

/// A scripted daemon for `TerminalMemoryTests` (#687): an OLDER server, whose keyframes carry
/// no history, so the scrollback above a seed comes from the `agent.read` backfill. Each read
/// answers with rows tagged by its call number (`BACKFILL-<call> row <n>`), so a test can tell
/// a fresh backfill from rows the terminal still held. It counts the `pane.stream`s opened, so
/// a test can tell whether a pane restarted its stream.
struct TerminalParkingMockTransport: HerdrTransport {
    /// Rows each backfill read returns.
    static let backfillRows = 300

    let server = TerminalParkingMockServer()
    /// End every stream right after its keyframe, so the pane always has a reconnect pending.
    var dropsStreams = false

    func roundTrip(_ requestLine: String) async throws -> String {
        if requestLine.contains("agent.read") { return Self.backfillRead(call: server.noteRead()) }
        if requestLine.contains("pane.set_pty_size") { return MockWireFixtures.panePtySize }
        return #"{"id":"mock","error":{"code":"unknown_method","message":"not in the parking mock"}}"#
    }

    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        guard requestLine.contains("pane.stream") else {
            return AsyncThrowingStream { $0.finish(throwing: TransportError.closedBeforeResponse) }
        }
        server.noteStream()
        let drops = dropsStreams
        return AsyncThrowingStream { continuation in
            continuation.yield(MockWireFixtures.paneStreamAck)
            continuation.yield(MockWireFixtures.paneStreamReset)
            if drops {
                continuation.finish()
            } else {
                let pings = MockTransport.keepAlive(continuation)
                continuation.onTermination = { _ in pings.cancel() }
            }
        }
    }

    static func backfillRead(call: Int) -> String {
        let body = (0..<backfillRows).map { "BACKFILL-\(call) row \($0)" }.joined(separator: "\r\n")
        let payload: [String: Any] = ["id": "mock", "result": ["read": [
            "pane_id": "w1:p1", "text": body, "truncated": false,
            "source": "recent", "format": "ansi"]]]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// What the parking mock has served. Shared by the transport's copies.
final class TerminalParkingMockServer: @unchecked Sendable {
    private let lock = NSLock()
    private var streams = 0
    private var reads = 0

    var streamsOpened: Int {
        lock.lock()
        defer { lock.unlock() }
        return streams
    }

    var backfillReads: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func noteStream() {
        lock.lock()
        defer { lock.unlock() }
        streams += 1
    }

    /// Counts a read and returns its call number, from 1.
    func noteRead() -> Int {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return reads
    }
}
#endif
