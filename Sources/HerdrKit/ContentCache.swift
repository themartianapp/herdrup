import Foundation

/// What the app last showed for each machine, on disk, so a cold start paints it before
/// the network answers and refreshes behind it (slow-network fix 4).
///
/// Four things are kept: the agent list (per machine and herdr session), the newest chat
/// page per agent, the Gram inbox's first page, and the text of each terminal's last
/// screen. The first three are kept as the exact JSON line herdr answered, recorded by
/// `HerdrClient` and decoded by the same decoders a live reply goes through, so a cached
/// screen and a fresh one cannot disagree about what a field means. The terminal is plain
/// text, no escape sequences.
///
/// - **Where.** The app passes its Caches directory: never backed up or synced, and iOS
///   may purge it under storage pressure, which is fine for content that is only a head
///   start.
/// - **Keyed by** owner (a saved machine `user@host:port`, or a guest share) and, for a
///   machine, the herdr session.
/// - **Bounded.** `budgetBytes` (20 MB) over all owners, least recently used first out.
///   A file's modification date is its last use, so the order survives a relaunch. One
///   entry over `entryLimitBytes` is not kept, so a single huge reply cannot flush the rest.
/// - **No secrets.** Only those replies and screen text are written; credentials, keys and
///   tokens never pass through here, and the owner key holds no more than the saved
///   machine list already shows.
///
/// Thread-safe: every file operation runs on one serial queue. Writes are asynchronous
/// (the caller never waits on disk to show a fresh reply); reads wait for the writes
/// queued before them, so a read always sees the newest record.
public final class ContentCache: @unchecked Sendable {
    public static let defaultBudgetBytes = 20 << 20
    public static let defaultEntryLimitBytes = 2 << 20

    /// Whose content a directory holds. Wiping an owner removes every session under it.
    public enum Owner: Hashable, Sendable {
        /// A saved machine, keyed `user@host:port` (`SessionChoice.machineKey` in the app).
        case machine(String)
        /// A guest share (`GuestAccess.id`).
        case share(String)

        var directoryName: String {
            switch self {
            case .machine(let key): return "m-" + ContentCache.fileSafe(key)
            case .share(let id): return "g-" + ContentCache.fileSafe(id)
            }
        }
    }

    public let root: URL
    public let budgetBytes: Int
    public let entryLimitBytes: Int

    private let queue = DispatchQueue(label: "herdr.content-cache")
    private let files = FileManager.default
    /// Relative path → size and last use. Built from disk on first use, then kept in step.
    private var index: [String: (bytes: Int, used: Date)]?
    private let now: @Sendable () -> Date

    public init(root: URL, budgetBytes: Int = ContentCache.defaultBudgetBytes,
                entryLimitBytes: Int = ContentCache.defaultEntryLimitBytes,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root
        self.budgetBytes = budgetBytes
        self.entryLimitBytes = entryLimitBytes
        self.now = now
    }

    /// The handle a client (and the views reading through it) uses for one machine's
    /// session, or one guest share. A share's `sharedTarget` and `sharedName` name the one
    /// agent it shows (as `GuestAccess.agentTarget` and `agentName`).
    public func scope(machine: String, session: String?) -> ContentCacheScope {
        ContentCacheScope(cache: self, owner: .machine(machine), session: session, sharedTarget: nil, sharedName: nil)
    }

    public func scope(share id: String, sharedTarget: String, sharedName: String? = nil) -> ContentCacheScope {
        ContentCacheScope(cache: self, owner: .share(id), session: nil, sharedTarget: sharedTarget,
                          sharedName: sharedName)
    }

    // MARK: Storage

    func write(_ data: Data, to path: String) {
        guard data.count <= entryLimitBytes else {
            // Too big to keep: drop any older copy too, so a stale screen cannot outlive it.
            queue.async { self.removeEntry(path) }
            return
        }
        queue.async {
            var index = self.loadIndex()
            let url = self.root.appendingPathComponent(path)
            let used = self.now()
            do {
                try self.files.createDirectory(at: url.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                // Same clock as a read stamps, so the order on disk is the order of use.
                try? self.files.setAttributes([.modificationDate: used], ofItemAtPath: url.path)
            } catch {
                return
            }
            index[path] = (data.count, used)
            self.index = index
            self.evict(keeping: path)
        }
    }

    func read(_ path: String) -> Data? {
        queue.sync {
            var index = loadIndex()
            guard index[path] != nil else { return nil }
            let url = root.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url) else {
                index[path] = nil
                self.index = index
                return nil
            }
            let used = now()
            index[path] = (data.count, used)
            self.index = index
            // The modification date is the persisted "last used", so LRU order survives a relaunch.
            try? files.setAttributes([.modificationDate: used], ofItemAtPath: url.path)
            return data
        }
    }

    func contains(_ path: String) -> Bool {
        queue.sync { loadIndex()[path] != nil }
    }

    /// Removes everything kept for `owner`: a forgotten machine, a share the guest left.
    public func wipe(_ owner: Owner) {
        queue.sync {
            let prefix = owner.directoryName + "/"
            try? files.removeItem(at: root.appendingPathComponent(owner.directoryName))
            if var index {
                for key in index.keys where key.hasPrefix(prefix) { index[key] = nil }
                self.index = index
            }
        }
    }

    /// Removes everything.
    public func wipeAll() {
        queue.sync {
            try? files.removeItem(at: root)
            index = [:]
        }
    }

    /// Bytes currently kept. Waits for queued writes.
    public var totalBytes: Int {
        queue.sync { loadIndex().values.reduce(0) { $0 + $1.bytes } }
    }

    /// Returns once every write queued so far is on disk (another process, or another
    /// instance over the same directory, then sees it).
    public func flush() {
        queue.sync {}
    }

    private func removeEntry(_ path: String) {
        var index = loadIndex()
        guard index[path] != nil else { return }
        try? files.removeItem(at: root.appendingPathComponent(path))
        index[path] = nil
        self.index = index
    }

    /// Drops the least recently used entries until the total fits the budget. Never the
    /// entry just written: it is what the screen shows now.
    private func evict(keeping fresh: String) {
        guard var index else { return }
        var total = index.values.reduce(0) { $0 + $1.bytes }
        guard total > budgetBytes else { return }
        let oldestFirst = index.filter { $0.key != fresh }.sorted { $0.value.used < $1.value.used }
        for (path, entry) in oldestFirst where total > budgetBytes {
            try? files.removeItem(at: root.appendingPathComponent(path))
            index[path] = nil
            total -= entry.bytes
        }
        self.index = index
    }

    private func loadIndex() -> [String: (bytes: Int, used: Date)] {
        if let index { return index }
        var built: [String: (bytes: Int, used: Date)] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        // Symlinks resolved on both sides (iOS's /var is /private/var), so the relative
        // path is the one `write` used.
        let base = root.resolvingSymlinksInPath().path
        if let walk = files.enumerator(at: root, includingPropertiesForKeys: keys) {
            for case let url as URL in walk {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true else { continue }
                let full = url.resolvingSymlinksInPath().path
                guard full.hasPrefix(base + "/") else { continue }
                // Anything in the tree counts, including a temporary file an interrupted
                // atomic write left behind, so it ages out like any entry.
                let relative = String(full.dropFirst(base.count + 1))
                built[relative] = (values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
            }
        }
        index = built
        return built
    }

    /// A path component for any key: URL-safe base64, or a hash when that would be too
    /// long for one file name. Reversibility is not needed, stability is.
    static func fileSafe(_ key: String) -> String {
        let encoded = Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard encoded.count > 120 else { return encoded }
        // FNV-1a, 64-bit: stable across launches and platforms (unlike `Hasher`).
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "h" + String(hash, radix: 16) + "-" + String(key.utf8.count)
    }
}

/// One machine's herdr session (or one guest share) inside a `ContentCache`. Handed to
/// `HerdrClient`, which records the replies a cold start paints from; the views read the
/// same values back through `client.contentCache`.
public struct ContentCacheScope: Sendable {
    public let cache: ContentCache
    public let owner: ContentCache.Owner
    /// The herdr session; nil is the default session. Always nil for a share.
    public let session: String?
    /// For a guest share: the one agent the share shows. Nothing about any other agent is
    /// kept, even when the host's reply carries it.
    public let sharedTarget: String?
    /// The shared agent's name, for a host whose list omits its ids (as the guest home
    /// matches it).
    public let sharedName: String?

    private var directory: String {
        switch owner {
        case .machine:
            let name = (session?.isEmpty == false && session != "default") ? session! : "default"
            return owner.directoryName + "/s-" + ContentCache.fileSafe(name)
        case .share:
            return owner.directoryName
        }
    }

    private var agentsPath: String { directory + "/agents.json" }
    private var gramPath: String { directory + "/gram.json" }
    private func transcriptPath(target: String, subagent: String?) -> String {
        directory + "/chat-" + ContentCache.fileSafe(subagent.map { target + "\u{1F}" + $0 } ?? target) + ".json"
    }
    private func terminalPath(pane: String) -> String {
        directory + "/term-" + ContentCache.fileSafe(pane) + ".txt"
    }

    private func shows(_ target: String) -> Bool { sharedTarget.map { $0 == target } ?? true }

    // MARK: Reads (the cold-start paint)

    /// The last `agent.list` answer, or nil when none is kept (or it no longer decodes).
    public func agents() -> AgentListing? {
        guard let data = cache.read(agentsPath),
              let result = try? JSONDecoder().decode(ResultEnvelope<AgentListResult>.self, from: data).result
        else { return nil }
        return AgentListing(agents: result.agents, originCapabilities: result.originCapabilities,
                            originMachineID: result.originMachineID)
    }

    /// Whether an agent list is kept, without reading it.
    public func hasAgents() -> Bool { cache.contains(agentsPath) }

    /// The newest chat page last fetched for `target`.
    public func transcript(target: String, subagent: String? = nil) -> AgentTranscriptPage? {
        guard shows(target), let data = cache.read(transcriptPath(target: target, subagent: subagent)) else { return nil }
        return try? JSONDecoder().decode(ResultEnvelope<AgentTranscriptPage>.self, from: data).result
    }

    /// Whether a chat page is kept for `target`, without reading it.
    public func hasTranscript(target: String) -> Bool {
        shows(target) && cache.contains(transcriptPath(target: target, subagent: nil))
    }

    /// The Gram inbox's last first page. Never for a guest: a share has no owner inbox.
    public func gramHead() -> GramListAnswer? {
        guard sharedTarget == nil, let data = cache.read(gramPath),
              let result = try? JSONDecoder().decode(ResultEnvelope<GramListResult>.self, from: data).result,
              result.messages != nil
        else { return nil }
        return GramListAnswer(messages: result.messages, digest: result.digest, storeID: result.storeID,
                              hasMore: result.hasMore, unreadCount: result.unreadCount)
    }

    /// The text of `pane`'s last screen, one line per row.
    public func terminalText(pane: String) -> String? {
        guard shows(pane), let data = cache.read(terminalPath(pane: pane)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Writes

    public func storeTerminalText(_ text: String, pane: String) {
        guard shows(pane) else { return }
        cache.write(Data(text.utf8), to: terminalPath(pane: pane))
    }

    /// `responseLine` is herdr's whole `agent.list` reply. For a guest, only the shared
    /// agent's row is kept.
    func recordAgentList(_ responseLine: String) {
        guard let sharedTarget else {
            cache.write(Data(responseLine.utf8), to: agentsPath)
            return
        }
        guard let filtered = Self.keepingOnlyAgent(sharedTarget, named: sharedName, in: responseLine) else { return }
        cache.write(filtered, to: agentsPath)
    }

    func recordTranscript(_ responseLine: String, target: String, subagent: String?) {
        guard shows(target) else { return }
        cache.write(Data(responseLine.utf8), to: transcriptPath(target: target, subagent: subagent))
    }

    func recordGramHead(_ responseLine: String) {
        guard sharedTarget == nil else { return }
        cache.write(Data(responseLine.utf8), to: gramPath)
    }

    /// The reply with every agent but the shared one removed. Matched as the guest home
    /// matches it: by terminal or pane id (`GuestAccess.isSharedAgent`), else the first
    /// row with its name.
    static func keepingOnlyAgent(_ target: String, named name: String?, in responseLine: String) -> Data? {
        guard var envelope = (try? JSONSerialization.jsonObject(with: Data(responseLine.utf8))) as? [String: Any],
              var result = envelope["result"] as? [String: Any],
              let agents = result["agents"] as? [[String: Any]] else { return nil }
        let byID = agents.first {
            ($0["terminal_id"] as? String) == target || ($0["pane_id"] as? String) == target
        }
        let byName = name.flatMap { name in agents.first { ($0["name"] as? String) == name } }
        result["agents"] = (byID ?? byName).map { [$0] } ?? []
        envelope["result"] = result
        return try? JSONSerialization.data(withJSONObject: envelope)
    }
}
