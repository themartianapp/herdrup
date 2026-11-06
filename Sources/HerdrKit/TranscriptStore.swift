import Foundation

// The Chat view's model of an omp conversation: the entries loaded so far (newest page,
// older pages scrolled in, live `after` refreshes merged by id) and the turns the view
// draws from them.

// MARK: - Turns

/// One step line inside a work group.
public struct TranscriptStepRow: Identifiable, Sendable, Equatable {
    public let id: String
    /// omp's tool name (`read`, `search`, `edit`, `bash`), drawn before the intent.
    public let tool: String
    public let intent: String
    public let status: TranscriptStepStatus
    public let detail: String?
}

/// A run of thinking and tool steps between two things worth showing (a reply, a note, a
/// question): one "Thought" line and one "Worked for … · N steps" line in the chat.
public struct TranscriptWork: Identifiable, Sendable, Equatable {
    public let id: String
    /// Non-empty thoughts, oldest first. The collapsed line shows the newest.
    public internal(set) var thoughts: [String]
    public internal(set) var steps: [TranscriptStepRow]
    public let startMs: UInt64
    /// When the work ended: the next entry's time, else the group's own last entry.
    public internal(set) var endMs: UInt64
    /// omp is still in this run (the newest group while the agent works).
    public internal(set) var live: Bool

    public var latestThought: String? { thoughts.last }
}

public enum TranscriptItem: Identifiable, Sendable, Equatable {
    case work(TranscriptWork)
    case reply(id: String, text: String, final: Bool)
    case note(id: String, tsMs: UInt64, TranscriptNote)
    case plan(id: String, [TranscriptPlanItem])
    /// `pending` is set while this is the agent's open question (`pending_ask`).
    case ask(id: String, TranscriptAsk, pending: TranscriptPendingAsk?)
    /// Only failed or interrupted turns are kept; a normal end draws nothing.
    case turnFailed(id: String, status: TranscriptTurnEndStatus, error: String?)
    case summary(id: String, text: String)

    public var id: String {
        switch self {
        case .work(let work): return work.id
        case .reply(let id, _, _), .note(let id, _, _), .plan(let id, _), .ask(let id, _, _),
             .turnFailed(let id, _, _), .summary(let id, _):
            return id
        }
    }
}

/// A user prompt and everything omp did about it. The first turn of a page may have no
/// prompt (the page began at a compaction summary, or the branch start).
public struct TranscriptTurn: Identifiable, Sendable, Equatable {
    public let id: String
    public let prompt: TranscriptEntry?
    public internal(set) var items: [TranscriptItem]
    public let startMs: UInt64
    public let attachmentPrompt: GramAttachmentPrompt.Parsed?

    init(id: String, prompt: TranscriptEntry?, items: [TranscriptItem], startMs: UInt64) {
        self.id = id
        self.prompt = prompt
        self.items = items
        self.startMs = startMs
        if case .user(let text, _, _)? = prompt?.kind {
            attachmentPrompt = GramAttachmentPrompt.parse(text)
        } else {
            attachmentPrompt = nil
        }
    }

    public var promptText: String? {
        if case .user(let text, _, _)? = prompt?.kind { return text }
        return nil
    }

    public var promptAuthor: TranscriptAuthor? {
        if case .user(_, let author, _)? = prompt?.kind { return author }
        return nil
    }

    public var promptOrigin: TranscriptOrigin? {
        if case .user(_, _, let origin)? = prompt?.kind { return origin }
        return nil
    }
}

public enum TranscriptGrouping {
    /// Groups entries (oldest first) into turns. A turn starts at each `user` entry; inside
    /// it, consecutive thinking and steps fold into one work group, while replies (including
    /// mid-task ones), notes, plans, questions and failures stand on their own in order.
    /// Only the newest plan of a turn is kept, where it arrived.
    public static func turns(
        _ entries: [TranscriptEntry],
        pendingAsk: TranscriptPendingAsk? = nil,
        working: Bool = false
    ) -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        var current: TranscriptTurn?
        var openWork: TranscriptWork?
        var pendingSeen = false

        func closeWork(at endMs: UInt64?) {
            guard var work = openWork else { return }
            if let endMs { work.endMs = max(work.endMs, endMs) }
            current?.items.append(.work(work))
            openWork = nil
        }
        func append(_ item: TranscriptItem, _ entry: TranscriptEntry) {
            closeWork(at: entry.tsMs)
            if current == nil {
                current = TranscriptTurn(id: entry.id, prompt: nil, items: [], startMs: entry.tsMs)
            }
            current?.items.append(item)
        }

        for entry in entries {
            switch entry.kind {
            case .user:
                closeWork(at: entry.tsMs)
                if let turn = current { turns.append(turn) }
                current = TranscriptTurn(id: entry.id, prompt: entry, items: [], startMs: entry.tsMs)
            case .thinking, .step:
                if current == nil {
                    current = TranscriptTurn(id: entry.id, prompt: nil, items: [], startMs: entry.tsMs)
                }
                var work = openWork ?? TranscriptWork(id: entry.id, thoughts: [], steps: [], startMs: entry.tsMs,
                                                      endMs: entry.tsMs, live: false)
                work.endMs = max(work.endMs, entry.tsMs)
                if case .thinking(let text) = entry.kind {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { work.thoughts.append(trimmed) }
                } else if case .step(let step) = entry.kind {
                    work.steps.append(TranscriptStepRow(id: entry.id, tool: step.tool, intent: step.intent,
                                                        status: step.status, detail: step.detail))
                }
                openWork = work
            case .reply(let text, let final):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                append(.reply(id: entry.id, text: text, final: final), entry)
            case .note(let note):
                append(.note(id: entry.id, tsMs: entry.tsMs, note), entry)
            case .plan(let items):
                current?.items.removeAll { if case .plan = $0 { return true }; return false }
                append(.plan(id: entry.id, items), entry)
            case .ask(let ask):
                // One card per question: its own entry, answered or open. An answer in the
                // entry wins over a `pending_ask` that has not caught up with it yet.
                if pendingAsk?.id == entry.id { pendingSeen = true }
                let pending = ask.answer == nil && pendingAsk?.id == entry.id ? pendingAsk : nil
                append(.ask(id: entry.id, ask, pending: pending), entry)
            case .turnEnd(let status, let error):
                if status == .done {
                    closeWork(at: entry.tsMs)
                } else {
                    append(.turnFailed(id: entry.id, status: status, error: error), entry)
                }
            case .summary(let text):
                closeWork(at: entry.tsMs)
                // A compaction summary opens a prompt-less turn of its own, so whatever omp
                // did after it is not drawn under the prompt from before it.
                if let turn = current { turns.append(turn) }
                current = TranscriptTurn(id: entry.id, prompt: nil, items: [.summary(id: entry.id, text: text)],
                                         startMs: entry.tsMs)
            case .unknown:
                continue
            }
        }
        if working, openWork != nil { openWork?.live = true }
        closeWork(at: nil)
        if let turn = current { turns.append(turn) }

        // The open question belongs at the end of the conversation even if its own entry is
        // not loaded (it always is on the newest page, but a server may trim differently).
        if let pendingAsk, !pendingSeen {
            let item = TranscriptItem.ask(id: pendingAsk.id,
                                          TranscriptAsk(questions: pendingAsk.questions, answer: nil),
                                          pending: pendingAsk)
            if turns.isEmpty {
                turns.append(TranscriptTurn(id: pendingAsk.id, prompt: nil, items: [item], startMs: 0))
            } else {
                turns[turns.count - 1].items.append(item)
            }
        }
        return turns
    }
}

// MARK: - Store

/// The conversation the Chat view shows, and the calls that change it: the newest page,
/// older pages as the reader scrolls up, and live refreshes of what omp appended.
///
/// Entries are kept oldest first and de-duplicated by id. A live (`after`) refresh may
/// re-send an entry that changed (a step that finished, a question that got its answer);
/// it replaces the copy in place.
@MainActor
public final class TranscriptStore {
    /// Turns per older page (the server clamps to 1...50). Nonisolated: it is the init's
    /// default argument, which the caller evaluates in its own context.
    public nonisolated static let pageTurns: UInt32 = 20
    /// Turns on the first (newest) page. A turn is everything from one prompt to the next,
    /// so on a long agent session 20 turns ran to ~1700 entries (~760 KB) before the chat
    /// could draw; the reader scrolls up for more, a `pageTurns` page at a time.
    public nonisolated static let newestPageTurns: UInt32 = 5

    public let target: String
    /// The subagent whose own conversation this store pages (read-only), or nil for the
    /// agent's.
    public let subagent: String?
    public private(set) var entries: [TranscriptEntry] = []
    public private(set) var turns: [TranscriptTurn] = []
    public private(set) var pendingAsk: TranscriptPendingAsk?
    public private(set) var working: TranscriptWorking?
    public private(set) var model: TranscriptModel?
    public private(set) var recap: TranscriptRecap?
    public private(set) var plan: [TranscriptPlanItem]?
    /// Live metadata like `plan`: the newest and every `after` page replace it (absent
    /// clears it); an older page never rolls it back.
    public private(set) var subagents: [TranscriptSubagent] = []

    public var currentPlan: [TranscriptPlanItem] {
        if let plan { return plan }
        for entry in entries.reversed() {
            if case .plan(let items) = entry.kind { return items }
        }
        return []
    }
    public private(set) var sessionID: String?
    public private(set) var outbox = TranscriptOutbox()
    /// The server has older turns than the ones loaded.
    public private(set) var hasOlder = false
    /// A page (or a failure) has been applied at least once.
    public private(set) var loaded = false
    /// Why the newest refresh failed; nil after one succeeds.
    public private(set) var lastError: Error?
    public private(set) var loadingOlder = false
    public var onChange: (() -> Void)?

    private var afterCursor: String?
    private var beforeCursor: String?
    /// Bumped whenever a newest page replaces the list, so a page fetched against the
    /// old list (older or after) is dropped instead of merged into the wrong history.
    private var generation = 0
    private var refreshing = false
    private var refreshAgain = false
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasSnapshot = false
    /// Answers sent from this device that the server has not reported yet, so the card
    /// does not flash its buttons back between the tap and the next refresh.
    private var localAnswers: [String: [String]] = [:]
    private let pageTurns: UInt32
    private let newestPageTurns: UInt32
    /// The clock that ages unmatched sends (`TranscriptOutbox.demoteUnseen`); tests inject one.
    private let now: () -> Date

    public init(target: String, subagent: String? = nil, pageTurns: UInt32 = TranscriptStore.pageTurns,
                newestPageTurns: UInt32 = TranscriptStore.newestPageTurns,
                now: @escaping () -> Date = { Date() }) {
        self.target = target
        self.subagent = subagent
        self.pageTurns = pageTurns
        self.newestPageTurns = newestPageTurns
        self.now = now
    }

    public var isWorking: Bool { working != nil }

    /// Brings the conversation up to date: the newest page on first use (or after the
    /// server forgot the cursor), otherwise only what was appended since. Concurrent calls
    /// coalesce into one more round after the one in flight.
    public func refresh(client: HerdrClient) async {
        if refreshing {
            refreshAgain = true
            await withCheckedContinuation { refreshWaiters.append($0) }
            return
        }
        refreshing = true
        defer {
            refreshing = false
            for waiter in refreshWaiters { waiter.resume() }
            refreshWaiters.removeAll(keepingCapacity: true)
        }
        repeat {
            refreshAgain = false
            await refreshOnce(client: client)
        } while refreshAgain
        // Never pending forever: a send the transcript still lacks a minute after its
        // request returned stops reading as pending, even while refreshes fail.
        if outbox.demoteUnseen(now: now()) { onChange?() }
    }

    private func refreshOnce(client: HerdrClient) async {
        guard let after = afterCursor else {
            await reload(client: client)
            return
        }
        let version = generation
        do {
            let page = try await client.agentTranscript(target: target, after: after, subagent: subagent)
            guard version == generation else { return }
            if let session = page.sessionID, let known = sessionID, session != known {
                // omp started a new session in this pane: the old cursor's history is not
                // this conversation any more.
                await reload(client: client)
                return
            }
            mergeAfter(page)
        } catch AgentTranscriptError.cursorExpired {
            guard version == generation else { return }
            await reload(client: client)
        } catch is CancellationError {
            return
        } catch {
            guard version == generation else { return }
            lastError = error
            loaded = true
            onChange?()
        }
    }

    /// Replaces everything with the newest page.
    public func reload(client: HerdrClient) async {
        generation += 1
        let version = generation
        do {
            let page = try await client.agentTranscript(target: target, limit: newestPageTurns, subagent: subagent)
            guard version == generation else { return }
            applyNewest(page)
        } catch is CancellationError {
            return
        } catch {
            guard version == generation else { return }
            lastError = error
            loaded = true
            onChange?()
        }
    }

    /// The next older page, prepended. A failure is thrown for the caller to show where
    /// the reader asked for it (the top of the list); a page fetched before a reload
    /// replaced the list is dropped.
    public func loadOlder(client: HerdrClient) async throws {
        guard hasOlder, !loadingOlder, let before = beforeCursor else { return }
        loadingOlder = true
        onChange?()
        // Every exit clears the flag; the success path clears it before merging so the
        // change notification that shows the new page also re-enables "Load older".
        defer {
            if loadingOlder {
                loadingOlder = false
                onChange?()
            }
        }
        let version = generation
        let page: AgentTranscriptPage
        do {
            page = try await client.agentTranscript(target: target, before: before, limit: pageTurns,
                                                    subagent: subagent)
        } catch AgentTranscriptError.cursorExpired {
            guard version == generation else { return }
            // The file was replaced under us: the history we hold is no longer pageable.
            hasOlder = false
            beforeCursor = nil
            return
        } catch {
            guard version == generation, !(error is CancellationError) else { return }
            throw error
        }
        guard version == generation else { return }
        loadingOlder = false
        mergeOlder(page)
    }

    /// Shows an answer the reader just sent before the server reports it.
    public func noteAnswered(askID: String, option: String) {
        localAnswers[askID] = [option]
        if pendingAsk?.id == askID { pendingAsk = nil }
        regroup()
    }

    /// Draw the local message before the request starts. This never submits or retries it.
    @discardableResult
    public func stageOutgoing(text: String, author: TranscriptAuthor, files: [TranscriptAttachment] = []) -> String {
        let id = outbox.stage(text: text, author: author, entries: entries, sessionID: sessionID,
                             baselineReady: hasSnapshot, files: files)
        onChange?()
        return id
    }

    public func updateOutgoing(_ id: String, state: TranscriptSendState, wireText: String? = nil) {
        outbox.update(id, state: state, wireText: wireText, now: now())
        onChange?()
    }

    /// A first-page send is already visible locally. Establish its history boundary
    /// before writing, so an old identical prompt cannot be mistaken for its echo.
    public func prepareOutgoing(_ id: String, client: HerdrClient) async -> Bool {
        if !hasSnapshot {
            if refreshing {
                await withCheckedContinuation { refreshWaiters.append($0) }
            } else {
                await refresh(client: client)
            }
        }
        guard hasSnapshot else {
            updateOutgoing(id, state: .notDelivered("Chat could not load. Retry or use Terminal."))
            return false
        }
        outbox.prepare(id, entries: entries, sessionID: sessionID)
        return true
    }

    // MARK: Merging (internal for tests)

    func applyNewest(_ page: AgentTranscriptPage) {
        let newest = Self.unique(page.entries)
        let outboxBefore = outbox
        outbox.reconcile(page.entries, sessionID: page.sessionID)
        // A reload that brings back exactly what is shown (an expired cursor, a poll racing a
        // reload) has nothing new to draw: no regroup, no change notification.
        let unchanged = loaded && lastError == nil && hasSnapshot
            && newest == entries && (page.before != nil) == hasOlder
            && page.model == model && page.plan == plan && page.recap == recap
            && (page.subagents ?? []) == subagents
            && page.pendingAsk == pendingAsk && page.working == working
            && page.sessionID == sessionID && outbox == outboxBefore
        hasSnapshot = true
        model = page.model
        plan = page.plan
        subagents = page.subagents ?? []
        recap = page.recap
        entries = newest
        beforeCursor = page.before
        hasOlder = page.before != nil
        afterCursor = page.after
        sessionID = page.sessionID
        pendingAsk = page.pendingAsk
        working = page.working
        lastError = nil
        loaded = true
        guard !unchanged else { return }
        regroup()
    }

    func mergeOlder(_ page: AgentTranscriptPage) {
        let known = Set(entries.map(\.id))
        entries = Self.unique(page.entries.filter { !known.contains($0.id) }) + entries
        beforeCursor = page.before
        hasOlder = page.before != nil
        regroup()
    }

    /// Merges a live (`after`) page. Most polls bring nothing (or re-send entries unchanged):
    /// then the turns are not regrouped and `onChange` is not called, so the chat does not
    /// redraw for them. Only entries, the open question or whether omp works change the
    /// turns; the model, plan, recap and outbox only need the change notification.
    func mergeAfter(_ page: AgentTranscriptPage) {
        let outboxBefore = outbox
        outbox.reconcile(page.entries, sessionID: page.sessionID ?? sessionID)
        var entriesChanged = false
        if !page.entries.isEmpty {
            var index: [String: Int] = [:]
            for (position, entry) in entries.enumerated() { index[entry.id] = position }
            for entry in page.entries {
                if let position = index[entry.id] {
                    guard entries[position] != entry else { continue }
                    entries[position] = entry
                } else {
                    index[entry.id] = entries.count
                    entries.append(entry)
                }
                entriesChanged = true
            }
        }
        if let after = page.after { afterCursor = after }
        if let session = page.sessionID { sessionID = session }
        let regroups = entriesChanged || page.pendingAsk != pendingAsk
            || (page.working == nil) != (working == nil)
        let notifies = regroups || page.working != working
            || page.model != model || page.plan != plan || page.recap != recap
            || (page.subagents ?? []) != subagents
            || outbox != outboxBefore || lastError != nil || !loaded
        model = page.model
        plan = page.plan
        subagents = page.subagents ?? []
        recap = page.recap
        pendingAsk = page.pendingAsk
        working = page.working
        lastError = nil
        loaded = true
        if regroups {
            regroup()
        } else if notifies {
            onChange?()
        }
    }

    private func regroup() {
        // A server-reported answer (or a newer pending question) supersedes the local one.
        for entry in entries {
            if case .ask(let ask) = entry.kind, ask.answer != nil { localAnswers[entry.id] = nil }
        }
        let shown = entries.map { entry -> TranscriptEntry in
            guard let answer = localAnswers[entry.id], case .ask(let ask) = entry.kind else { return entry }
            return TranscriptEntry(id: entry.id, tsMs: entry.tsMs,
                                   kind: .ask(TranscriptAsk(questions: ask.questions, answer: answer)))
        }
        let pending = pendingAsk.flatMap { localAnswers[$0.id] == nil ? $0 : nil }
        turns = TranscriptGrouping.turns(shown, pendingAsk: pending, working: working != nil)
        onChange?()
    }

    private static func unique(_ entries: [TranscriptEntry]) -> [TranscriptEntry] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.id).inserted }
    }
}
