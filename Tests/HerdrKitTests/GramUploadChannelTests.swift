import XCTest

@testable import HerdrKit

/// The upload channel's teardown is the one part of this path with a deadline, and
/// a deadline is only worth having if it is provable. The bound exists because the
/// runner finishes only when NIOSSH succeeds a close promise that waits for the
/// peer's CHANNEL_CLOSE — no timer, and not interruptible by task cancellation — so
/// a stalled link would otherwise park the caller for the kernel's whole retransmit
/// budget and wedge the composer.
///
/// This mirrors `CitadelTransportTests.testConnectFailsWithinTheBudgetAgainstABlackHoleAddress`,
/// which shortens the same kind of unstructured race for the same reason.
final class GramUploadChannelTests: XCTestCase {
    /// A channel whose connection never resolves, so its runner can never finish.
    private func stalledChannel(closeGrace: UInt64) -> GramUploadChannel {
        GramUploadChannel(
            makeConnection: {
                // Far longer than any grace under test: this stands in for a
                // half-open TCP that neither completes nor errors.
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                throw CancellationError()
            },
            command: "true",
            openLine: #"{"id":"t","method":"gram.upload.stream","params":{"upload_id":"t"}}"#,
            closeGrace: closeGrace
        )
    }

    func testCloseAndWaitReturnsWithinItsGraceWhenTheRunnerNeverFinishes() async throws {
        let grace: UInt64 = 200_000_000  // 200 ms
        let channel = stalledChannel(closeGrace: grace)

        // `start()` parks until the open is acked, which never happens here — so it
        // runs detached, purely to spawn the runner `closeAndWait` must bound.
        let opening = Task { try? await channel.start() }
        // Give `start()` time to install the runner before closing.
        try await Task.sleep(nanoseconds: 50_000_000)

        let began = DispatchTime.now().uptimeNanoseconds
        await channel.closeAndWait()
        let elapsed = DispatchTime.now().uptimeNanoseconds - began

        opening.cancel()
        XCTAssertLessThan(
            elapsed, grace * 20,
            "closeAndWait took \(elapsed / 1_000_000) ms against a \(grace / 1_000_000) ms grace — the bound is not holding")
    }

    /// Idempotence AND boundedness: a second close must not hang on an
    /// already-signalled gate, and the caller's `defer`-close runs after
    /// `closeAndWait` on every real path.
    ///
    /// The timing assertion is the point of the second half. Without it this test
    /// PASSED in 60 s under the mutation that removes the bound — reporting
    /// "idempotent" while the property the file exists to prove was gone, and adding
    /// a silent minute to every mutant run.
    func testCloseAndWaitIsIdempotentAndBounded() async throws {
        let grace: UInt64 = 100_000_000  // 100 ms
        let channel = stalledChannel(closeGrace: grace)
        let opening = Task { try? await channel.start() }
        try await Task.sleep(nanoseconds: 50_000_000)

        let began = DispatchTime.now().uptimeNanoseconds
        await channel.closeAndWait()
        await channel.close()
        await channel.closeAndWait()
        let elapsed = DispatchTime.now().uptimeNanoseconds - began

        opening.cancel()
        XCTAssertLessThan(
            elapsed, grace * 40,
            "three closes took \(elapsed / 1_000_000) ms against a \(grace / 1_000_000) ms grace")
    }

    /// A frame written on a channel that was never started must fail rather than
    /// park on an ack that can never arrive.
    ///
    /// NOTE what this does and does not cover. It exercises the never-started guard
    /// (`live` is false, `framesCont` nil), which is a real caller mistake. It does
    /// NOT cover the post-close path on a LIVE channel: `live` only becomes true when
    /// the daemon acks the open, which needs a real SSH connection, so an earlier
    /// version of this test that called `close()` first was measured to pass with
    /// that call deleted — it pinned nothing. The live-then-closed path is exercised
    /// by `closeAndWait`'s own `resumeAck(.closedBeforeFrameAck)` and remains
    /// unguarded by a unit test; it needs the integration path, not a double.
    func testSendChunkOnANeverStartedChannelFailsInsteadOfHanging() async throws {
        let channel = stalledChannel(closeGrace: 100_000_000)

        do {
            try await channel.sendChunk(offset: 0, dataBase64: "aGk=")
            XCTFail("sendChunk on a channel that was never started must throw")
        } catch let error as GramUploadChannel.ChannelError {
            XCTAssertEqual(error, .closedBeforeFrameAck)
        }
    }

    /// A started channel whose daemon is played by the test: the connection never
    /// resolves, so frames stay queued, and acks are fed through `handleLine`.
    private func openedChannel() async throws -> GramUploadChannel {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("Streaming uploads require macOS 15; macOS 14 uses per-chunk uploads")
        }
        let channel = stalledChannel(closeGrace: 200_000_000)
        let start = Task { try await channel.start() }
        // The open line's ack. `start` parks until it lands (or picks it up if it
        // lands first), so no ordering between the two is needed.
        await channel.handleLine(#"{"id":"t","result":{"type":"ok"}}"#)
        try await start.value
        return channel
    }

    /// herdrup#573: one frame in flight idled the link for a round trip per
    /// 512 KiB. `maxFramesInFlight - 1` frames must now be written without waiting,
    /// the next must park until the OLDEST ack, and `finish` until the last one.
    func testFramesRideAheadOfTheirAcksUpToTheWindow() async throws {
        let channel = try await openedChannel()
        let window = GramUploadChannel.maxFramesInFlight
        XCTAssertGreaterThan(window, 1)
        for index in 0..<(window - 1) {
            try await channel.sendChunk(offset: UInt64(index), dataBase64: "aGk=")
        }

        let returned = Locked(false)
        let parked = Task {
            try await channel.sendChunk(offset: UInt64(window), dataBase64: "aGk=")
            returned.set(true)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(returned.value, "a full window must wait for an ack")
        await channel.handleLine(#"{"seq":1,"ok":true}"#)
        try await parked.value
        XCTAssertTrue(returned.value)

        let finished = Locked(false)
        let finish = Task {
            try await channel.finish()
            finished.set(true)
        }
        for seq in 2..<window {
            await channel.handleLine(#"{"seq":\#(seq),"ok":true}"#)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(finished.value, "finish must wait for the last frame's ack")
        await channel.handleLine(#"{"seq":\#(window),"ok":true}"#)
        try await finish.value
        XCTAssertTrue(finished.value)
        await channel.close()
    }

    /// With frames in flight a rejection can arrive while nobody waits on it; it
    /// must surface on the next call instead of being lost.
    func testAFrameErrorBetweenCallsIsThrownByTheNext() async throws {
        let channel = try await openedChannel()
        try await channel.sendChunk(offset: 0, dataBase64: "aGk=")
        await channel.handleLine(#"{"seq":1,"error":{"code":"offset_mismatch","message":"bad offset"}}"#)
        do {
            try await channel.finish()
            XCTFail("finish must rethrow the frame error")
        } catch let error as GramUploadChannel.ChannelError {
            XCTAssertEqual(error, .remoteError(APIError(code: "offset_mismatch", message: "bad offset")))
        }
        await channel.close()
    }

    /// Acks come in order; one for a later frame is a disagreement about what landed.
    func testAnOutOfOrderAckIsFatal() async throws {
        let channel = try await openedChannel()
        try await channel.sendChunk(offset: 0, dataBase64: "aGk=")
        try await channel.sendChunk(offset: 3, dataBase64: "aGk=")
        await channel.handleLine(#"{"seq":2,"ok":true}"#)
        do {
            try await channel.finish()
            XCTFail("an out-of-order ack must fail the upload")
        } catch let GramUploadChannel.ChannelError.remoteError(error) {
            XCTAssertEqual(error.code, "invalid_sequence")
        }
        await channel.close()
    }

    private final class Locked<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ value: Value) { lock.lock(); stored = value; lock.unlock() }
    }

    /// Every `upload_id` is distinct, since the daemon keys its staging file and its
    /// single-writer claim on it — a repeat would collide with a live upload.
    func testMintedUploadIDsAreDistinctAndSafePathComponents() {
        let ids = (0..<64).map { _ in HerdrClient.mintUploadID() }
        XCTAssertEqual(Set(ids).count, ids.count, "upload ids must not repeat")
        for id in ids {
            XCTAssertTrue(id.hasPrefix("app-"))
            XCTAssertTrue(
                id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" },
                "\(id) is not a safe single path component")
        }
    }
}
