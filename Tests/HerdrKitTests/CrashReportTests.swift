import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HerdrKit

/// The opt-in crash reports: what a report carries from a MetricKit payload (and what it
/// drops), the cap, and the reporter's gate, daily limit and offline queue.
///
/// `Fixtures/metrickit-diagnostic-payload.json` is `MXDiagnosticPayload.jsonRepresentation()`
/// shape built from the real TestFlight crash of build 238 (1.2.1, iPhone18,1): the crashed
/// thread's top 14 frames and three of thread 1's, with their real binary UUIDs and offsets.
/// Its metadata carries every key MetricKit sends besides the ones a report keeps, including
/// an Objective-C exception reason holding agent text, and a hang diagnostic of build 245.
final class CrashReportTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var directory: URL!

    override func setUp() {
        super.setUp()
        suiteName = "CrashReportTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private static let herdr = "913AE206-9644-328F-9952-176ECA385CA0"

    private func recordedPayload() throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/metrickit-diagnostic-payload.json")
        return try Data(contentsOf: url)
    }

    private func object(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    private func diagnostic(_ kind: CrashReport.Kind = .crash, tree: Data? = nil) -> CrashReport.Diagnostic {
        CrashReport.Diagnostic(kind: kind, version: "1.3.4", build: "245", os: "iPhone OS 27.2 (24C101)",
                               device: "iPhone19,4", exceptionType: 10, exceptionCode: 0, signal: 6,
                               terminationReason: "Namespace SIGNAL, Code 6 Abort trap: 6",
                               hangSeconds: kind == .hang ? 2.5 : nil, callStackTree: tree)
    }

    /// A call-stack tree of `threads` chains of `depth` frames each, thread 0 attributed.
    private func tree(threads: Int, depth: Int, binaries: Int = 4) throws -> Data {
        var stacks: [[String: Any]] = []
        for thread in 0..<threads {
            var root: [String: Any]?
            for level in (0..<depth).reversed() {
                var frame: [String: Any] = [
                    "binaryName": "Lib\(level % binaries).dylib",
                    "binaryUUID": String(format: "00000000-0000-0000-0000-%012d", level % binaries),
                    "offsetIntoBinaryTextSegment": 1_000_000 + thread * 1000 + level,
                    "address": 4_294_967_296 + level, "sampleCount": 1,
                ]
                if let root { frame["subFrames"] = [root] }
                root = frame
            }
            stacks.append(["threadAttributed": thread == 0, "callStackRootFrames": [root!]])
        }
        return try JSONSerialization.data(withJSONObject: ["callStackPerThread": true, "callStacks": stacks])
    }

    // MARK: The report

    func testAReportFromARecordedPayloadKeepsOnlyTheListedFields() throws {
        let diagnostics = CrashReport.diagnostics(fromPayload: try recordedPayload())
        XCTAssertEqual(diagnostics.map(\.kind), [.crash, .hang])
        let report = try object(CrashReport.body(for: diagnostics[0]))

        XCTAssertEqual(Set(report.keys), ["v", "kind", "version", "build", "os", "device", "exception",
                                          "termination", "binaries", "stacks"])
        XCTAssertEqual(report["v"] as? Int, 1)
        XCTAssertEqual(report["kind"] as? String, "crash")
        XCTAssertEqual(report["version"] as? String, "1.2.1")
        XCTAssertEqual(report["build"] as? String, "238")
        XCTAssertEqual(report["os"] as? String, "iPhone OS 26.6.2 (23G90)")
        XCTAssertEqual(report["device"] as? String, "iPhone18,1")
        XCTAssertEqual(report["exception"] as? [String: Int], ["type": 10, "code": 0, "signal": 6])
        XCTAssertEqual(report["termination"] as? String, "Namespace SIGNAL, Code 6 Abort trap: 6")

        // Binaries listed once each, in first-seen order; frames are [binary index, offset].
        let binaries = try XCTUnwrap(report["binaries"] as? [[String: String]])
        XCTAssertEqual(binaries.map { $0["name"]! }, ["libsystem_kernel.dylib", "libsystem_pthread.dylib", "libsystem_c.dylib",
                                                      "libswiftCore.dylib", "SwiftUICore", "Herdr", "SwiftUI"])
        XCTAssertEqual(binaries[5]["uuid"], Self.herdr)
        XCTAssertTrue(binaries.allSatisfy { Set($0.keys) == ["name", "uuid"] })
        let stacks = try XCTUnwrap(report["stacks"] as? [[String: Any]])
        XCTAssertEqual(stacks.map { $0["attributed"] as? Bool }, [true, false])
        let crashed = try XCTUnwrap(stacks[0]["frames"] as? [[Int]])
        XCTAssertEqual(crashed.count, 14)
        XCTAssertEqual(crashed[0], [0, 45520], "the top of the stack comes first")
        XCTAssertEqual(crashed[11], [5, 740520], "ChatView.userScrolling.setter in build 238")
        XCTAssertEqual(crashed[12], [5, 3347124])
        XCTAssertEqual(try XCTUnwrap(stacks[1]["frames"] as? [[Int]]), [[0, 3284], [0, 17164], [0, 16940]])
    }

    func testAReportCarriesNothingElseFromTheMetadata() throws {
        let payload = try recordedPayload()
        XCTAssertTrue(String(decoding: payload, as: UTF8.self).contains("claude-secret"), "the fixture does carry it")
        for diagnostic in CrashReport.diagnostics(fromPayload: payload) {
            let text = String(decoding: try XCTUnwrap(CrashReport.body(for: diagnostic)), as: UTF8.self)
            for dropped in ["claude-secret", "composedMessage", "NSInternalInconsistencyException", "regionFormat", "\"IT\"",
                            "89470", "4242", "com.jerryfane.herdr", "arm64e", "/private/var", "virtualMemory",
                            "isTestFlightApp", "lowPowerMode", "sampleCount", "address", "timeStamp"] {
                XCTAssertFalse(text.contains(dropped), "\(diagnostic.kind) report carries \(dropped)")
            }
        }
    }

    func testAHangReportCarriesItsDurationAndNoException() throws {
        let hang = CrashReport.diagnostics(fromPayload: try recordedPayload())[1]
        XCTAssertEqual(hang.hangSeconds, 4.25)
        let report = try object(CrashReport.body(for: hang))
        XCTAssertEqual(Set(report.keys), ["v", "kind", "version", "build", "os", "device", "hangSeconds", "binaries", "stacks"])
        XCTAssertEqual(report["kind"] as? String, "hang")
        XCTAssertEqual(report["hangSeconds"] as? Double, 4.25)
        XCTAssertEqual(report["build"] as? String, "245")
        XCTAssertEqual(report["device"] as? String, "iPhone19,4")
    }

    func testHangDurationsAsMetricKitWritesThem() {
        XCTAssertEqual(CrashReport.seconds("20 sec"), 20)
        XCTAssertEqual(CrashReport.seconds("1.5 sec"), 1.5)
        XCTAssertEqual(CrashReport.seconds("750 ms"), 0.75)
        XCTAssertNil(CrashReport.seconds("20"))
        XCTAssertNil(CrashReport.seconds("-1 sec"))
        XCTAssertNil(CrashReport.seconds(20))
    }

    func testNoReportWithoutTheFieldsTheRelayRequires() {
        var missing = diagnostic()
        missing.version = nil
        XCTAssertNil(CrashReport.body(for: missing))
        var spaced = diagnostic()
        spaced.device = "iPhone 19 Pro"
        XCTAssertNil(CrashReport.body(for: spaced))
        var longBuild = diagnostic()
        longBuild.build = String(repeating: "2", count: 33)
        XCTAssertNil(CrashReport.body(for: longBuild))
        var noOS = diagnostic()
        noOS.os = "\n"
        XCTAssertNil(CrashReport.body(for: noOS))
    }

    func testTheTerminationReasonIsPrintableASCIIOnly() throws {
        var odd = diagnostic()
        odd.terminationReason = "Namespace SPRINGBOARD,\nCode 0x8badf00d — watchdog"
        let report = try object(CrashReport.body(for: odd))
        XCTAssertEqual(report["termination"] as? String, "Namespace SPRINGBOARD,Code 0x8badf00d  watchdog")
    }

    func testAMissingOrUnreadableTreeStillSendsTheRestMarkedTruncated() throws {
        let none = try object(CrashReport.body(for: diagnostic()))
        XCTAssertEqual((none["stacks"] as? [Any])?.count, 0)
        XCTAssertNil(none["truncated"])
        let broken = try object(CrashReport.body(for: diagnostic(tree: Data("[".utf8))))
        XCTAssertEqual(broken["truncated"] as? Bool, true)
    }

    /// Some iOS releases wrote the binary's load address into `offsetIntoBinaryTextSegment`.
    func testALoadAddressInTheOffsetFieldBecomesTheOffset() throws {
        let tree = try JSONSerialization.data(withJSONObject: ["callStacks": [["threadAttributed": true, "callStackRootFrames": [
            ["binaryName": "Herdr", "binaryUUID": Self.herdr.lowercased(), "offsetIntoBinaryTextSegment": 4_368_412_672,
             "address": 4_369_153_192],
        ]]]])
        let report = try object(CrashReport.body(for: diagnostic(tree: tree)))
        let stacks = try XCTUnwrap(report["stacks"] as? [[String: Any]])
        XCTAssertEqual(stacks[0]["frames"] as? [[Int]], [[0, 740_520]])
        XCTAssertEqual((report["binaries"] as? [[String: String]])?.first?["uuid"], Self.herdr, "upper-cased")
    }

    func testAFrameWithTwoCallersBecomesTwoStacks() throws {
        func frame(_ offset: Int, _ callers: [[String: Any]] = []) -> [String: Any] {
            var frame: [String: Any] = ["binaryName": "Herdr", "binaryUUID": Self.herdr, "offsetIntoBinaryTextSegment": offset]
            if !callers.isEmpty { frame["subFrames"] = callers }
            return frame
        }
        let tree = try JSONSerialization.data(withJSONObject: ["callStacks": [["threadAttributed": true, "callStackRootFrames": [
            frame(1, [frame(2, [frame(3)]), frame(20)]),
        ]]]])
        let stacks = try XCTUnwrap(object(CrashReport.body(for: diagnostic(tree: tree)))["stacks"] as? [[String: Any]])
        XCTAssertEqual(stacks.map { $0["frames"] as? [[Int]] }, [[[0, 1], [0, 2], [0, 3]], [[0, 1], [0, 20]]])
    }

    func testAnOversizedReportDropsOtherThreadsThenFramesToFitTheCap() throws {
        // 40 threads of 300 frames: some 160 KB of frames before trimming.
        let body = try XCTUnwrap(CrashReport.body(for: diagnostic(tree: try tree(threads: 40, depth: 300))))
        XCTAssertLessThanOrEqual(body.count, CrashReport.maxBytes)
        let report = try object(body)
        XCTAssertEqual(report["truncated"] as? Bool, true)
        let stacks = try XCTUnwrap(report["stacks"] as? [[String: Any]])
        XCTAssertEqual(stacks.first?["attributed"] as? Bool, true, "the crashed thread is kept")
        XCTAssertEqual((stacks.first?["frames"] as? [[Int]])?.count, 300, "whole, while other threads can go")

        let small = try XCTUnwrap(CrashReport.body(for: diagnostic(tree: try tree(threads: 1, depth: 2000)), maxBytes: 4096))
        XCTAssertLessThanOrEqual(small.count, 4096)
        let frames = try XCTUnwrap((try object(small)["stacks"] as? [[String: Any]])?.first?["frames"] as? [[Int]])
        XCTAssertGreaterThan(frames.count, 0)
        XCTAssertLessThanOrEqual(frames.count, CrashReport.maxFramesPerStack)
    }

    /// A stack overflow's tree is thousands of frames deep: twice as many JSON levels, past
    /// what `JSONSerialization` reads. It still parses, keeping the top 512 frames.
    func testAStackOverflowsDeepTreeParsesAndKeepsItsTopFrames() throws {
        var json = #"{"callStackPerThread":true,"callStacks":[{"threadAttributed":true,"callStackRootFrames":["#
        let depth = 6000
        for level in 0..<depth {
            json += #"{"binaryUUID":"\#(Self.herdr)","offsetIntoBinaryTextSegment":\#(level),"binaryName":"Herdr","sampleCount":1"#
            json += level < depth - 1 ? #","subFrames":["# : "}"
        }
        json += String(repeating: "]}", count: depth - 1) + "]}]}"
        let report = try object(CrashReport.body(for: diagnostic(tree: Data(json.utf8))))
        XCTAssertEqual(report["truncated"] as? Bool, true)
        let frames = try XCTUnwrap((report["stacks"] as? [[String: Any]])?.first?["frames"] as? [[Int]])
        XCTAssertEqual(frames.count, CrashReport.maxFramesPerStack)
        XCTAssertEqual(frames.first, [0, 0])
        XCTAssertEqual(frames.last, [0, CrashReport.maxFramesPerStack - 1])
    }

    func testTheTokenizerReadsEscapesAndRefusesMalformedInput() {
        var tokens = JSONTokens(Data(#"{"a\"b":["x\u0041\n",-12,1.0e3,2.5,true,null,{}]}"#.utf8))
        var seen: [JSONTokens.Token] = []
        while let token = tokens.next() { seen.append(token) }
        XCTAssertFalse(tokens.failed)
        XCTAssertEqual(seen, [.objectStart, .key("a\"b"), .arrayStart, .string("xA\n"), .number(-12), .number(1000),
                              .number(nil), .bool(true), .null, .objectStart, .objectEnd, .arrayEnd, .objectEnd])
        for bad in ["{\"a\":[1}", "[1,2", "{\"a\":tru}", "\"open", "]"] {
            var tokens = JSONTokens(Data(bad.utf8))
            while tokens.next() != nil {}
            XCTAssertTrue(tokens.failed, bad)
        }
        XCTAssertNil(CrashReport.StackTree(json: Data(#"{"callStacks":[{"callStackRootFrames":[{"subFrames":[}]}]}"#.utf8)))
        XCTAssertNil(CrashReport.StackTree(json: Data("{}".utf8)), "no callStacks")
    }

    // MARK: The reporter

    /// Records every request and answers each with `status` (nil: no response).
    private final class Relay: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        private var _status: Int?

        init(status: Int?) { _status = status }

        var requests: [URLRequest] { lock.withLock { _requests } }
        var status: Int? {
            get { lock.withLock { _status } }
            set { lock.withLock { _status = newValue } }
        }

        var send: UsagePing.Send {
            { request in
                self.lock.withLock {
                    self._requests.append(request)
                    return self._status
                }
            }
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now = Date(timeIntervalSince1970: 1_794_571_200) // 2026-11-13 12:00 UTC
        var now: Date {
            get { lock.withLock { _now } }
            set { lock.withLock { _now = newValue } }
        }
    }

    private func reporter(_ relay: Relay, _ clock: Clock = Clock()) -> CrashReporter {
        CrashReporter(directory: directory, endpoint: URL(string: "https://relay.test/v1/crash")!,
                      defaults: defaults, now: { clock.now }, send: relay.send)
    }

    private var queuedCount: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).count
    }

    func testWithTheUsageCountSwitchOffNothingIsSentOrKept() async throws {
        UsagePing.setEnabled(false, in: defaults)
        let relay = Relay(status: 204)
        let sent = await reporter(relay).receive(CrashReport.diagnostics(fromPayload: try recordedPayload()))
        XCTAssertEqual(sent, 0)
        XCTAssertTrue(relay.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "nothing queued")
    }

    func testWithTheSwitchOnEachDiagnosticIsPostedAsItsReport() async throws {
        let relay = Relay(status: 204)
        let diagnostics = CrashReport.diagnostics(fromPayload: try recordedPayload())
        let sent = await reporter(relay).receive(diagnostics)
        XCTAssertEqual(sent, 2)
        XCTAssertEqual(relay.requests.count, 2)
        for (request, diagnostic) in zip(relay.requests, diagnostics) {
            XCTAssertEqual(request.url?.absoluteString, "https://relay.test/v1/crash")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.httpBody, CrashReport.body(for: diagnostic))
        }
        XCTAssertEqual(queuedCount, 0)
    }

    func testAReportThatCouldNotGoOutIsSentOnTheNextLaunch() async throws {
        let relay = Relay(status: nil)
        let clock = Clock()
        let sent = await reporter(relay, clock).receive([diagnostic()])
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(queuedCount, 1, "kept for the next launch")
        relay.status = 503
        let busy = await reporter(relay, clock).flush()
        XCTAssertEqual(busy, 0)
        XCTAssertEqual(queuedCount, 1, "a 5xx keeps it too")

        relay.status = 204
        let next = await reporter(relay, clock).flush()
        XCTAssertEqual(next, 1)
        XCTAssertEqual(queuedCount, 0)
        XCTAssertEqual(relay.requests.count, 3)
        XCTAssertEqual(Set(relay.requests.map(\.httpBody)).count, 1, "the same report each time")
    }

    func testAReportTheRelayRefusesIsDropped() async {
        let relay = Relay(status: 400)
        _ = await reporter(relay).receive([diagnostic()])
        XCTAssertEqual(queuedCount, 0)
        XCTAssertEqual(relay.requests.count, 1)
    }

    func testAtMostFiveReportsAUTCDayTheRestWaitForTheNextDay() async {
        let relay = Relay(status: 204)
        let clock = Clock()
        let sent = await reporter(relay, clock).receive(Array(repeating: diagnostic(), count: 7))
        XCTAssertEqual(sent, CrashReporter.maxPerDay)
        XCTAssertEqual(queuedCount, 2)
        let sameDay = await reporter(relay, clock).flush()
        XCTAssertEqual(sameDay, 0)

        clock.now += 86_400
        let nextDay = await reporter(relay, clock).flush()
        XCTAssertEqual(nextDay, 2)
        XCTAssertEqual(queuedCount, 0)
        XCTAssertEqual(relay.requests.count, 7)
    }

    func testTheQueueKeepsTheNewestTwenty() async {
        let relay = Relay(status: nil)
        let clock = Clock()
        let reporter = reporter(relay, clock)
        for _ in 0..<25 {
            clock.now += 1
            _ = await reporter.receive([diagnostic()])
        }
        XCTAssertEqual(queuedCount, CrashReporter.maxQueued)
    }

    func testTurningTheSwitchOffDropsTheQueueUnsent() async {
        let relay = Relay(status: nil)
        _ = await reporter(relay).receive([diagnostic(), diagnostic(.hang)])
        XCTAssertEqual(queuedCount, 2)

        UsagePing.setEnabled(false, in: defaults)
        relay.status = 204
        let sent = await reporter(relay).flush()
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(relay.requests.count, 1, "only the attempt made while it was on")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
