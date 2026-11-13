import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Opt-in crash and hang reports from MetricKit (owner decision 2026-11-13). They go to the
/// guest relay's `POST /v1/crash` only while Settings › About › "Share anonymous usage count"
/// (`UsagePing.Key.enabled`) is on, and carry no agent names, text or identifiers: the app
/// version and build, the OS version, the device model, the exception type, code and signal,
/// the termination reason, a hang's duration, and each thread's stack as binary names, UUIDs
/// and offsets into the binary's text segment. Nothing else MetricKit reports is ever read
/// (not the region format, PID, exception message or memory region info).
///
/// UIKit- and MetricKit-free so it tests on Linux: the app turns each `MXCrashDiagnostic` and
/// `MXHangDiagnostic` into a `CrashReport.Diagnostic` and hands it to a `CrashReporter`.
public enum CrashReport {
    public static let endpoint = UsagePing.relay.appendingPathComponent("v1/crash")
    /// The relay's cap on a report body. A report that would be larger drops the threads
    /// MetricKit did not attribute the crash to, then trims frames, and says so in `truncated`.
    public static let maxBytes = 65_536
    /// Frames kept per thread, from the top of the stack.
    public static let maxFramesPerStack = 512
    /// Frames kept across all threads.
    public static let maxFrames = 8_192

    public enum Kind: String, Sendable {
        case crash
        case hang
    }

    /// What the app reads from one MetricKit diagnostic: these fields and nothing else.
    public struct Diagnostic: Sendable, Equatable {
        public var kind: Kind
        public var version: String?
        public var build: String?
        public var os: String?
        public var device: String?
        public var exceptionType: Int?
        public var exceptionCode: Int?
        public var signal: Int?
        public var terminationReason: String?
        public var hangSeconds: Double?
        /// `MXCallStackTree.jsonRepresentation()`.
        public var callStackTree: Data?

        public init(kind: Kind, version: String?, build: String?, os: String?, device: String?,
                    exceptionType: Int? = nil, exceptionCode: Int? = nil, signal: Int? = nil,
                    terminationReason: String? = nil, hangSeconds: Double? = nil,
                    callStackTree: Data?) {
            self.kind = kind
            self.version = version
            self.build = build
            self.os = os
            self.device = device
            self.exceptionType = exceptionType
            self.exceptionCode = exceptionCode
            self.signal = signal
            self.terminationReason = terminationReason
            self.hangSeconds = hangSeconds
            self.callStackTree = callStackTree
        }
    }

    // MARK: A whole payload's JSON

    /// The crash and hang diagnostics in `MXDiagnosticPayload.jsonRepresentation()`. The app
    /// reads MetricKit's typed properties instead; this reads recorded payloads (tests, and a
    /// DEBUG launch's `HERDR_MOCK_METRICKIT_PAYLOAD`) through the same `Diagnostic`, taking from
    /// `diagnosticMetaData` only the keys the typed path reads.
    public static func diagnostics(fromPayload json: Data) -> [Diagnostic] {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return [] }
        func read(_ key: String, _ kind: Kind) -> [Diagnostic] {
            (root[key] as? [[String: Any]] ?? []).map { entry in
                let meta = entry["diagnosticMetaData"] as? [String: Any] ?? [:]
                let tree = entry["callStackTree"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                return Diagnostic(kind: kind,
                                  version: meta["appVersion"] as? String,
                                  build: meta["appBuildVersion"] as? String,
                                  os: meta["osVersion"] as? String,
                                  device: meta["deviceType"] as? String,
                                  exceptionType: kind == .crash ? integer(meta["exceptionType"]) : nil,
                                  exceptionCode: kind == .crash ? integer(meta["exceptionCode"]) : nil,
                                  signal: kind == .crash ? integer(meta["signal"]) : nil,
                                  terminationReason: kind == .crash ? meta["terminationReason"] as? String : nil,
                                  hangSeconds: kind == .hang ? seconds(meta["hangDuration"]) : nil,
                                  callStackTree: tree)
            }
        }
        return read("crashDiagnostics", .crash) + read("hangDiagnostics", .hang)
    }

    /// `hangDuration` as MetricKit writes it in JSON: "20 sec", "1.5 sec" or "750 ms".
    static func seconds(_ value: Any?) -> Double? {
        guard let text = value as? String else { return nil }
        let parts = text.split(separator: " ")
        guard parts.count == 2, let number = Double(parts[0]), number.isFinite, number >= 0 else { return nil }
        switch parts[1] {
        case "sec", "s": return number
        case "ms": return number / 1000
        default: return nil
        }
    }

    // MARK: The report

    /// The report's JSON body, at most `maxBytes`, or nil when the diagnostic lacks a field the
    /// relay requires (version, build, OS or device) or has one it would refuse.
    public static func body(for diagnostic: Diagnostic, maxBytes: Int = maxBytes) -> Data? {
        guard let version = diagnostic.version, isToken(version, extra: "._-", max: 32),
              let build = diagnostic.build, isToken(build, extra: "._-", max: 32),
              let os = printable(diagnostic.os, limit: 64),
              let device = diagnostic.device, isToken(device, extra: ",._-", max: 32)
        else { return nil }

        var fields: [String: Any] = ["v": 1, "kind": diagnostic.kind.rawValue, "version": version,
                                     "build": build, "os": os, "device": device]
        switch diagnostic.kind {
        case .crash:
            var exception: [String: Int] = [:]
            exception["type"] = diagnostic.exceptionType.flatMap(safeInteger)
            exception["code"] = diagnostic.exceptionCode.flatMap(safeInteger)
            exception["signal"] = diagnostic.signal.flatMap(safeInteger)
            if !exception.isEmpty { fields["exception"] = exception }
            if let reason = printable(diagnostic.terminationReason, limit: 512) { fields["termination"] = reason }
        case .hang:
            if let seconds = diagnostic.hangSeconds, seconds.isFinite, (0...86_400).contains(seconds) {
                fields["hangSeconds"] = (seconds * 1000).rounded() / 1000
            }
        }

        var tree = StackTree(binaries: [], stacks: [])
        // A tree MetricKit gave but that does not parse still sends the rest, marked truncated.
        var truncated = false
        if let json = diagnostic.callStackTree {
            if let parsed = StackTree(json: json) { tree = parsed } else { truncated = true }
        }
        if tree.limit(perStack: maxFramesPerStack, total: maxFrames) { truncated = true }

        func encode() -> Data? {
            var all = fields
            all["binaries"] = tree.binaries.map { ["name": $0.name, "uuid": $0.uuid] }
            all["stacks"] = tree.stacks.map { ["attributed": $0.attributed, "frames": $0.frames.map { [$0.binary, $0.offset] }] }
            if truncated { all["truncated"] = true }
            return try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys])
        }
        // Over the cap: drop unattributed threads from the last, then halve the frames kept.
        while let data = encode() {
            if data.count <= maxBytes { return data }
            truncated = true
            if let last = tree.stacks.lastIndex(where: { !$0.attributed }) {
                tree.stacks.remove(at: last)
            } else {
                let frames = tree.stacks.reduce(0) { $0 + $1.frames.count }
                guard frames > 0 else { return nil }
                _ = tree.limit(perStack: maxFramesPerStack, total: frames / 2)
            }
            tree.dropUnusedBinaries()
        }
        return nil
    }

    /// Each thread's stack, its frames top first, with the binaries they name listed once.
    struct StackTree {
        struct Binary: Hashable {
            var name: String
            var uuid: String
        }

        struct Frame {
            var binary: Int
            var offset: Int
        }

        struct Stack {
            var attributed: Bool
            var frames: [Frame]
        }

        var binaries: [Binary]
        var stacks: [Stack]

        init(binaries: [Binary], stacks: [Stack]) {
            self.binaries = binaries
            self.stacks = stacks
        }

        /// Parses `MXCallStackTree.jsonRepresentation()`. Each frame's `subFrames` are its
        /// callers. For crashes and hangs every thread is a chain; should a frame ever have
        /// more than one caller, each further branch becomes a stack of its own. Read with
        /// `JSONTokens` and walked without recursion, so a stack overflow's deep chain parses
        /// and cannot overflow this thread's stack. Only frames' `binaryName`, `binaryUUID`,
        /// `offsetIntoBinaryTextSegment` and `address`, and stacks' `threadAttributed`, are read.
        init?(json: Data) {
            enum Role { case root, callStacks, callStack, frames, frame }
            struct Level {
                var role: Role
                var key: String? = nil
                var stack: Int? = nil
                var frame: Int? = nil
            }
            struct Node {
                var parent: Int?
                var stack: Int
                var name: String?
                var uuid: String?
                var offset: Int?
                var address: Int?
            }
            var tokens = JSONTokens(json)
            var levels: [Level] = []
            var nodes: [Node] = []
            var attributed: [Bool] = []
            var sawRoot = false
            var sawCallStacks = false
            while let token = tokens.next() {
                switch token {
                case .key(let key):
                    levels[levels.count - 1].key = key
                case .objectStart:
                    guard let parent = levels.last else {
                        guard !sawRoot else { return nil }
                        sawRoot = true
                        levels.append(Level(role: .root))
                        continue
                    }
                    switch parent.role {
                    case .callStacks:
                        attributed.append(false)
                        levels.append(Level(role: .callStack, stack: attributed.count - 1))
                    case .frames:
                        nodes.append(Node(parent: parent.frame, stack: parent.stack!))
                        levels.append(Level(role: .frame, stack: parent.stack, frame: nodes.count - 1))
                    default:
                        tokens.skip(after: token)
                    }
                case .arrayStart:
                    guard let parent = levels.last else { return nil }
                    switch (parent.role, parent.key) {
                    case (.root, "callStacks"):
                        sawCallStacks = true
                        levels.append(Level(role: .callStacks))
                    case (.callStack, "callStackRootFrames"), (.frame, "subFrames"):
                        levels.append(Level(role: .frames, stack: parent.stack, frame: parent.frame))
                    default:
                        tokens.skip(after: token)
                    }
                case .objectEnd, .arrayEnd:
                    levels.removeLast()
                case .string(let text):
                    guard let level = levels.last, level.role == .frame, let frame = level.frame else { continue }
                    if level.key == "binaryName" { nodes[frame].name = text }
                    if level.key == "binaryUUID" { nodes[frame].uuid = text }
                case .number(let value):
                    guard let level = levels.last, level.role == .frame, let frame = level.frame else { continue }
                    if level.key == "offsetIntoBinaryTextSegment" { nodes[frame].offset = value }
                    if level.key == "address" { nodes[frame].address = value }
                case .bool(let value):
                    guard let level = levels.last, level.role == .callStack, level.key == "threadAttributed",
                          let stack = level.stack
                    else { continue }
                    attributed[stack] = value
                case .null:
                    continue
                }
            }
            guard !tokens.failed, sawRoot, levels.isEmpty, sawCallStacks else { return nil }

            var children = [[Int]](repeating: [], count: nodes.count)
            var roots = [[Int]](repeating: [], count: attributed.count)
            for (i, node) in nodes.enumerated() {
                if let parent = node.parent { children[parent].append(i) } else { roots[node.stack].append(i) }
            }
            var binaries: [Binary] = []
            var index: [Binary: Int] = [:]
            var stacks: [Stack] = []
            walk: for (stack, firsts) in roots.enumerated() {
                // (frame, the frames above it on its stack) still to walk.
                var pending: [(Int, [Frame])] = firsts.reversed().map { ($0, []) }
                while let (first, above) = pending.popLast() {
                    var next: Int? = first
                    var frames = above
                    while let current = next {
                        let node = nodes[current]
                        let binary = Binary(name: CrashReport.printable(node.name, limit: 128) ?? "?",
                                            uuid: CrashReport.uuid(node.uuid))
                        let slot: Int
                        if let known = index[binary] {
                            slot = known
                        } else {
                            slot = binaries.count
                            binaries.append(binary)
                            index[binary] = slot
                        }
                        frames.append(Frame(binary: slot, offset: CrashReport.offset(node.offset, address: node.address)))
                        for branch in children[current].dropFirst().reversed() { pending.append((branch, frames)) }
                        next = children[current].first
                        if frames.count > CrashReport.maxFramesPerStack { break }
                    }
                    if !frames.isEmpty { stacks.append(Stack(attributed: attributed[stack], frames: frames)) }
                    if stacks.count > 1_024 { break walk }
                }
            }
            self.binaries = binaries
            self.stacks = stacks
        }

        /// Keeps the top `perStack` frames of each stack and `total` frames in all, attributed
        /// stacks first. True when any frame was dropped.
        mutating func limit(perStack: Int, total: Int) -> Bool {
            var budget = total
            var dropped = false
            let order = stacks.indices.sorted { (stacks[$0].attributed ? 0 : 1, $0) < (stacks[$1].attributed ? 0 : 1, $1) }
            for i in order {
                let keep = max(0, min(stacks[i].frames.count, perStack, budget))
                if keep < stacks[i].frames.count {
                    stacks[i].frames.removeLast(stacks[i].frames.count - keep)
                    dropped = true
                }
                budget -= keep
            }
            stacks.removeAll { $0.frames.isEmpty }
            if dropped { dropUnusedBinaries() }
            return dropped
        }

        mutating func dropUnusedBinaries() {
            var used = Set<Int>()
            for stack in stacks { for frame in stack.frames { used.insert(frame.binary) } }
            var remap: [Int: Int] = [:]
            var kept: [Binary] = []
            for (old, binary) in binaries.enumerated() where used.contains(old) {
                remap[old] = kept.count
                kept.append(binary)
            }
            binaries = kept
            for s in stacks.indices {
                for f in stacks[s].frames.indices { stacks[s].frames[f].binary = remap[stacks[s].frames[f].binary]! }
            }
        }
    }

    // MARK: Field checks

    /// The offset into the binary's text segment. Some iOS releases wrote the binary's load
    /// address into `offsetIntoBinaryTextSegment`; no text segment is 4 GB, so a value that
    /// large is the load address and the offset is `address` minus it.
    static func offset(_ raw: Int?, address: Int?) -> Int {
        let raw = raw ?? 0
        if raw >= 1 << 32, let address, address >= raw { return address - raw }
        return raw >= 0 ? safeInteger(raw) ?? 0 : 0
    }

    /// An upper-case UUID, or all zeros when MetricKit gave none.
    static func uuid(_ value: Any?) -> String {
        if let text = (value as? String)?.uppercased(), let parsed = UUID(uuidString: text) { return parsed.uuidString }
        return "00000000-0000-0000-0000-000000000000"
    }

    /// Integers JSON keeps exactly everywhere (JavaScript's safe range).
    static func safeInteger(_ value: Int) -> Int? {
        abs(value) <= 9_007_199_254_740_991 ? value : nil
    }

    static func integer(_ value: Any?) -> Int? {
        // No `is Bool` check: on Apple platforms a JSON 0 or 1 is an NSNumber that also casts
        // to Bool, so it would refuse exception code 0.
        if let int = value as? Int { return int }
        if let double = value as? Double, double.rounded() == double { return Int(exactly: double) }
        return nil
    }

    /// Printable ASCII only, trimmed, at most `limit` bytes; nil when nothing is left.
    static func printable(_ value: Any?, limit: Int) -> String? {
        guard let text = value as? String else { return nil }
        let kept = String(decoding: text.utf8.filter { (0x20...0x7E).contains($0) }.prefix(limit), as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        return kept.isEmpty ? nil : kept
    }

    /// 1 to `max` characters of ASCII letters, digits and `extra`.
    static func isToken(_ text: String, extra: String, max: Int) -> Bool {
        let allowed = Set(extra.utf8)
        return (1...max).contains(text.utf8.count) && text.utf8.allSatisfy {
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || allowed.contains($0)
        }
    }
}

/// The on-disk queue of report bodies and their sending: at most `maxPerDay` accepted reports
/// per UTC day, oldest first. A report the relay did not answer, or answered 429 or 5xx, stays
/// queued for the next launch; one it refused as malformed (other 4xx) is deleted. With the
/// usage-count switch off nothing is queued or sent, and the queue is deleted.
public actor CrashReporter {
    public static let maxPerDay = 5
    public static let maxQueued = 20

    public enum Key {
        /// The UTC day (`yyyy-MM-dd`) and count of the reports the relay accepted that day.
        public static let sentDay = "crashReports.sentDay"
        public static let sentCount = "crashReports.sentCount"
    }

    private let directory: URL
    private let endpoint: URL
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let send: UsagePing.Send
    private var sending = false
    /// Orders reports queued within the same millisecond.
    private var enqueued = 0

    public init(directory: URL,
                endpoint: URL = CrashReport.endpoint,
                defaults: UserDefaults = .standard,
                now: @escaping @Sendable () -> Date = { Date() },
                send: UsagePing.Send? = nil) {
        self.directory = directory
        self.endpoint = endpoint
        self.defaults = defaults
        self.now = now
        self.send = send ?? Self.urlSessionSend()
    }

    /// Queues a report for each diagnostic (when the switch is on), then sends what today
    /// allows. Returns how many the relay accepted.
    @discardableResult
    public func receive(_ diagnostics: [CrashReport.Diagnostic]) async -> Int {
        guard UsagePing.isEnabled(in: defaults) else {
            discardQueue()
            return 0
        }
        for diagnostic in diagnostics {
            guard let body = CrashReport.body(for: diagnostic) else { continue }
            enqueue(body)
        }
        return await flush()
    }

    /// Sends queued reports, oldest first, up to today's allowance. Called on launch so a
    /// report that could not go out last time goes now.
    @discardableResult
    public func flush() async -> Int {
        guard UsagePing.isEnabled(in: defaults) else {
            discardQueue()
            return 0
        }
        guard !sending else { return 0 }
        sending = true
        defer { sending = false }
        var accepted = 0
        for file in queued() {
            let today = UsagePing.utcDay(now())
            let sentToday = defaults.string(forKey: Key.sentDay) == today ? defaults.integer(forKey: Key.sentCount) : 0
            guard sentToday < Self.maxPerDay else { break }
            guard let body = try? Data(contentsOf: file) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = UsagePing.timeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            // An opt-out while the queue was being read stops here.
            guard UsagePing.isEnabled(in: defaults) else {
                discardQueue()
                break
            }
            let status = await send(request)
            guard let status, status != 429, status < 500 else { break }
            try? FileManager.default.removeItem(at: file)
            if (200..<300).contains(status) {
                defaults.set(today, forKey: Key.sentDay)
                defaults.set(sentToday + 1, forKey: Key.sentCount)
                accepted += 1
            }
        }
        return accepted
    }

    /// Deletes every queued report.
    public nonisolated func discardQueue() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Queued report files, oldest first.
    func queued() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Writes a report as `<ms since 1970, 15 digits>-<sequence, 6 digits>-<uuid>.json`, so
    /// names sort oldest first, then drops the oldest beyond `maxQueued`.
    private func enqueue(_ body: Data) {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        func padded(_ value: Int64, _ width: Int) -> String {
            let digits = String(value)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        enqueued += 1
        let name = padded(Int64(now().timeIntervalSince1970 * 1000), 15) + "-" + padded(Int64(enqueued), 6)
            + "-" + UUID().uuidString + ".json"
        try? body.write(to: directory.appendingPathComponent(name), options: .atomic)
        let files = queued()
        for file in files.prefix(max(0, files.count - Self.maxQueued)) { try? manager.removeItem(at: file) }
    }

    private static func urlSessionSend() -> UsagePing.Send {
        let session = URLSession(configuration: UsagePing.pingConfiguration())
        return { request in
            guard let (_, response) = try? await session.data(for: request) else { return nil }
            return (response as? HTTPURLResponse)?.statusCode
        }
    }
}
