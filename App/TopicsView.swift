import HerdrKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// An omp agent's Topics (option D, jerryfane/herdr#475): the agent is a front desk (the Inbox,
// its own conversation) and every topic a permanent worker conversation under it. Inside the
// agent's page a `Topics | Chat | Terminal` switch; Topics lists the Inbox pinned first, then
// the topics by last activity. On a phone a topic opens its chat full width; on iPad (regular
// width) the topics column stays beside the open topic's chat, next to the app's agent rail.
//
// Owner and guest share all of it (owner decision 2026-11-19): only the server's
// `agent_topics` capability gates it. The owner follows `agent.topics.changed`; a guest has no
// event stream and polls `agent.topics.list` every 15 s while the view is on screen.

/// The page's Topics state, owned by the page so a switch to Chat or the Terminal and back
/// keeps the list, the open topic and each topic's loaded conversation.
@MainActor
final class TopicsModel: ObservableObject {
    @Published private(set) var topics: [AgentTopic] = []
    /// The agent's open topic suggestions, oldest first: Organise's proposals and the ones it
    /// made in the Inbox. Listed ticked above the topics.
    @Published private(set) var suggestions: [AgentTopicSuggestion] = []
    /// The agent's omp serves suggestions (`suggestions` on its list) on a server with
    /// `agent_topic_suggestions`: the list offers Organise.
    @Published private(set) var suggestionsServed = false
    /// Proposals the reader unticked; every other one is ticked.
    @Published private var unticked: Set<String> = []
    /// Organise was asked and its proposals have not arrived yet.
    @Published private(set) var organising = false
    /// What Organise is doing, or why it did not start.
    @Published private(set) var organiseNote: String?
    /// Create N topics or Not now is going through the proposals.
    @Published private(set) var settling = false
    /// Organise's end: a new proposal, or 3 minutes after it was asked, since nothing reports
    /// a turn that proposed nothing (herdrup#797).
    private var organiseWait = TopicsOrganiseWait(timeout: TopicsModel.organiseTimeout)
    /// Ends Organise at its deadline when no list comes.
    private var organiseExpiry: Task<Void, Never>?
    /// The agent's name, from its list (the proposals' heading).
    @Published private(set) var agentName = ""
    /// The first list call answered, either way.
    @Published private(set) var loaded = false
    /// The agent answered `agent.topics.list` this session: the page offers Topics.
    @Published private(set) var offered = false
    /// The server pages a topic's conversation (`agent_transcript_topic`); nil until known.
    /// False is for good: no topic chat can be shown on this server (herdrup#766, #775).
    @Published private(set) var topicTranscripts: Bool?
    /// The agent will not offer topics for this page's life (`topics_unsupported`, no
    /// `agent_topics`): discovery stopped for good. Not `agent_not_found`: a restarting agent
    /// leaves its pane without one for a moment, and its topics come back (herdrup#777). Not
    /// `topics_unsupported` while the session file holds topics either (`seed(sessions:)`).
    private(set) var refused = false
    /// Why the newest list call failed. The last list stays on screen (`topics_unreachable`
    /// keeps it, as herdr's API asks); the list shows this only while it has no topic
    /// (`listedProblem`).
    @Published private(set) var problem: String?
    /// The problem line the list shows: only while no topic is listed. Over rows that are
    /// there it said "The agent didn't answer in time." while the list itself was fine
    /// (owner, 2026-11-25), so the rows stay and say nothing.
    var listedProblem: String? { topics.isEmpty ? problem : nil }
    /// The agent answered a list this page's life: its lists, not the session file, say
    /// which topics there are from then on.
    private var listAnswered = false
    /// The session file holds topics (`topic_sessions`).
    private var sessionTopicsKnown = false
    /// The open topic: its chat on a phone, the selected row and its chat on iPad.
    @Published var selectedTopicID: String?
    /// Each topic's newest send note (queued, refused), shown under that topic's composer
    /// only: a receipt that lands after the reader moved to another topic stays with its own.
    @Published private(set) var sendNotes: [String: String] = [:]

    let target: String
    /// One conversation per topic (`TranscriptStore` keyed per agent and topic), kept while
    /// the page lives, so going back to a topic draws what was loaded at once.
    private var chats: [String: ChatModel] = [:]
    /// The list's refresh rounds: coalesced refreshes, and Start's wait for a list that
    /// started after the accept (herdrup#795).
    private let rounds = TopicsListRounds()
    /// The owner's `agent.topics.changed` stream is running; the poll is only a backstop then.
    private var eventsLive = false

    /// A guest polls this often while Topics is on screen (no event stream).
    static let pollSeconds: UInt64 = 15
    /// The owner's poll behind the event stream, for a missed event.
    static let backstopSeconds: UInt64 = 60
    /// The host caps a message at 32 KiB (`invalid_params` beyond it), as `agent.prompt`.
    static let maxMessageBytes = 32 * 1024
    /// Discovery's retry schedule (`TopicsDiscoveryBackoff.delays`). DEBUG: the UI tests'
    /// `HERDR_MOCK_TOPICS_DISCOVERY_SECONDS` shortens it, so a retry lands inside a test.
    static var discoverySchedule: [UInt64] {
        #if DEBUG
        if let seconds = ProcessInfo.processInfo.environment["HERDR_MOCK_TOPICS_DISCOVERY_SECONDS"]
            .flatMap(UInt64.init) { return [seconds] }
        #endif
        return TopicsDiscoveryBackoff.delays
    }

    /// DEBUG: the UI tests' `HERDR_MOCK_TOPICS_POLL_SECONDS` shortens the list poll (the mocks
    /// have no topics event stream), so a list change lands inside a test.
    static var mockPollSeconds: UInt64? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["HERDR_MOCK_TOPICS_POLL_SECONDS"].flatMap(UInt64.init)
        #else
        return nil
        #endif
    }

    init(target: String) {
        self.target = target
        columnHidden = Self.restoresColumn && UserDefaults.standard.bool(forKey: Self.columnHiddenKey(target))
    }

    /// iPad: the topics column is folded away (the "Topics" toggle, ⌥⌘T), remembered per agent.
    @Published var columnHidden = false {
        didSet {
            guard columnHidden != oldValue else { return }
            UserDefaults.standard.set(columnHidden, forKey: Self.columnHiddenKey(target))
        }
    }

    private static func columnHiddenKey(_ target: String) -> String { "topics.columnHidden." + target }

    /// DEBUG: a screenshot mock (every UI test) opens with the column showing, whatever an
    /// earlier run on the same simulator folded, so each test starts from the same page.
    private static var restoresColumn: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["HERDR_SCREENSHOT_MOCK"] == nil
        #else
        return true
        #endif
    }

    func topic(_ id: String?) -> AgentTopic? {
        guard let id else { return nil }
        return topics.first { $0.id == id }
    }

    func chatModel(for topicID: String) -> ChatModel {
        if let model = chats[topicID] { return model }
        let model = ChatModel(target: target, topic: topicID)
        chats[topicID] = model
        return model
    }

    func sendNote(for topicID: String) -> String? { sendNotes[topicID] }

    /// The topics `agent.list` read from the session file (`topic_sessions`). Listed until the
    /// agent's first list answers, so the column is never just the Inbox while the agent is
    /// slow or busy; and while they exist, `topics_unsupported` is herdr not seeing the agent
    /// in its pane for a moment, not an agent without topics.
    func seed(sessions: [AgentTopicSession]) {
        let rows = AgentTopicList.seeded(from: sessions)
        sessionTopicsKnown = !rows.isEmpty
        if sessionTopicsKnown { refused = false }
        guard !listAnswered, !rows.isEmpty, rows != topics else { return }
        topics = rows
    }

    /// Learns whether the agent offers topics (herdrup#758), on `TopicsDiscoveryBackoff`'s
    /// schedule: `topics_unsupported` stops for good; `topics_unreachable` (every omp agent
    /// without topics turned on), `agent_not_found` (an agent restarting), a timeout or a
    /// dropped connection ask again after 60 s, doubling to a 10 minute cap. The page restarts
    /// this when the agent's status or session changes and when a guest's share comes back,
    /// which starts the schedule over; for the owner (`eventsPaneID`) an `agent.topics.changed`
    /// for the pane does too, at once, even while a list is still on its way
    /// (`TopicsDiscoveryLoop.wake`, herdrup#767).
    func discover(client: HerdrClient, eventsPaneID: String? = nil) async {
        guard !offered, !refused else { return }
        let loop = TopicsDiscoveryLoop(schedule: Self.discoverySchedule) { [weak self] in
            await self?.listForDiscovery(client: client)
        }
        await withTaskGroup(of: Void.self) { group in
            if let eventsPaneID {
                group.addTask { await self.wakeDiscoveryOnTopicChanges(client: client, paneID: eventsPaneID, loop: loop) }
            }
            group.addTask { await loop.run() }
            // The loop ends the discovery; the event watcher goes with it.
            await group.next()
            group.cancelAll()
        }
    }

    private func wakeDiscoveryOnTopicChanges(client: HerdrClient, paneID: String, loop: TopicsDiscoveryLoop) async {
        do {
            for try await line in client.subscribeTopicChanges() {
                guard case .changed(let change) = line, change.paneID == paneID else { continue }
                loop.wake()
            }
        } catch {}
        // Refused or dropped: the schedule alone keeps asking. Stay until discovery ends.
        while !Task.isCancelled { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
    }

    /// One list for discovery: nil when the agent answered, else why not.
    private func listForDiscovery(client: HerdrClient) async -> Error? {
        await refresh(client: client)
        if offered { return nil }
        return lastListError ?? AgentTopicsError.unreachable
    }

    /// Brings the list up to date. Concurrent calls coalesce into one more round.
    func refresh(client: HerdrClient) async {
        await rounds.refresh { [weak self] in await self?.refreshOnce(client: client) ?? false }
    }

    /// Why the newest list call failed, for discovery; nil after one succeeds.
    private var lastListError: Error?

    /// Every list answer's open suggestions, with when it was asked for (the page's Inbox
    /// chat). Called for each answer, changed or not, so a suggestion that went back to open
    /// after a Start is seen even when the list looks the same as before.
    var onListed: (@MainActor ([AgentTopicSuggestion], Date) -> Void)?
    /// A topic a Start opened ended before its first turn while the reader was on it
    /// (`start_failed`, or gone from a list): the page goes back to the Inbox, where the
    /// suggestion shows open again.
    var onStartFailed: (@MainActor (String) -> Void)?
    /// The topics Start opened, and those that failed to start (herdrup#811).
    private var startWatch = TopicsStartWatch()

    /// One list call; true when the server answered.
    @discardableResult
    private func refreshOnce(client: HerdrClient) async -> Bool {
        var answered = false
        do {
            let requestedAt = Date()
            let list = try await client.agentTopicsList(target: target)
            listAnswered = true
            let ordered = list.ordered
            if ordered != topics { topics = ordered }
            // A topic Start opened that the list no longer has, never seen with a turn, ended
            // before its first turn, even when `start_failed` never reached this page (a guest;
            // the owner between subscriptions). A topic that ran a turn may just be out of scope.
            if let ended = startWatch.endedSelection(selected: selectedTopicID, listed: ordered) {
                leaveFailedStart(ended)
            }
            if list.agent != agentName { agentName = list.agent }
            let open = list.suggestions ?? []
            // New proposals arrived: Organise has answered.
            if organiseWait.end(open: open.map(\.id), now: Date()) { finishOrganise() }
            if open != suggestions {
                suggestions = open
                unticked.formIntersection(open.map(\.id))
            }
            onListed?(open, requestedAt)
            let served = list.suggestions != nil ? await client.advertisesTopicSuggestions() : false
            if suggestionsServed != served { suggestionsServed = served }
            if !offered { offered = true }
            let pages = await client.advertisesTopicTranscripts()
            if topicTranscripts != pages { topicTranscripts = pages }
            refused = false
            lastListError = nil
            if problem != nil { problem = nil }
            answered = true
        } catch is CancellationError {
            return false
        } catch let refusal as AgentTopicsError {
            // The session file holds topics: a `topics_unsupported` is herdr not finding the
            // agent in its pane for a moment (a newer herdr says `topics_unreachable`).
            let error = refusal == .unsupported && sessionTopicsKnown ? AgentTopicsError.unreachable : refusal
            lastListError = error
            if error.isPermanent {
                // Not an agent with topics (any more): the page goes back to Chat and Terminal.
                offered = false
                refused = true
                problem = nil
            } else {
                problem = Self.describe(error)
            }
        } catch {
            lastListError = error
            problem = Self.describe(error)
        }
        if !loaded { loaded = true }
        return answered
    }

    /// Keeps the list current while Topics is on screen: the owner's `agent.topics.changed`
    /// events for this pane with a slow backstop poll; a guest (`eventsPaneID` nil) polls.
    func follow(client: HerdrClient, eventsPaneID: String?) async {
        // Back on Topics after Organise's deadline: no stale spinner, even without a list.
        checkOrganiseClock()
        await refresh(client: client)
        await withTaskGroup(of: Void.self) { group in
            if let eventsPaneID {
                group.addTask { await self.followEvents(client: client, paneID: eventsPaneID) }
            }
            group.addTask { await self.poll(client: client) }
        }
    }

    private func poll(client: HerdrClient) async {
        while !Task.isCancelled {
            let seconds = Self.mockPollSeconds ?? (eventsLive ? Self.backstopSeconds : Self.pollSeconds)
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await refresh(client: client)
        }
    }

    private func followEvents(client: HerdrClient, paneID: String) async {
        defer { eventsLive = false }
        while !Task.isCancelled {
            do {
                for try await line in client.subscribeTopicChanges() {
                    switch line {
                    case .started:
                        eventsLive = true
                    case .changed(let change) where change.paneID == paneID:
                        if change.reason == .startFailed { startFailed(topicID: change.topicID) }
                        await refresh(client: client)
                    default:
                        break
                    }
                }
            } catch is APIError {
                return   // the server refuses the subscription: the 15 s poll keeps up
            } catch {}
            eventsLive = false
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    // MARK: Actions

    /// Starts a topic with its title and first message, then opens it. Returns why it did not
    /// start, or nil.
    func create(client: HerdrClient, title: String, message: String) async -> String? {
        guard message.utf8.count <= Self.maxMessageBytes else { return Self.tooLong }
        do {
            let id = try await client.agentTopicsNew(target: target, title: title, message: message)
            await refresh(client: client)
            selectedTopicID = id
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    func rename(client: HerdrClient, topicID: String, title: String) async -> String? {
        await act(client: client) { try await client.agentTopicsRename(target: self.target, topicID: topicID, title: title) }
    }

    func close(client: HerdrClient, topicID: String) async -> String? {
        await act(client: client) { try await client.agentTopicsClose(target: self.target, topicID: topicID) }
    }

    func reopen(client: HerdrClient, topicID: String) async -> String? {
        await act(client: client) { try await client.agentTopicsReopen(target: self.target, topicID: topicID) }
    }

    private func act(client: HerdrClient, _ call: () async throws -> Void) async -> String? {
        do {
            try await call()
            await refresh(client: client)
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    /// Draws a message to one topic in its chat at once, as a Chat send does (the caller
    /// animates it), with the files going with it; `deliver` then sends it. Nil when it is
    /// too long to send.
    func stage(topicID: String, text: String, author: TranscriptAuthor, files: [ComposerAttachment] = []) -> String? {
        sendNotes[topicID] = nil
        guard text.utf8.count <= Self.maxMessageBytes else {
            sendNotes[topicID] = Self.tooLong
            return nil
        }
        return chatModel(for: topicID).stageOutgoing(text: text, author: author, files: files)
    }

    /// Sends a staged message to its topic (`agent.topics.send`); the bubble settles as the
    /// topic's transcript shows it. False only when it surely did not reach the topic, so
    /// the caller may keep the draft for a retry.
    @discardableResult
    func deliver(client: HerdrClient, topicID: String, outgoingID id: String, text: String) async -> Bool {
        let chat = chatModel(for: topicID)
        guard await chat.prepareOutgoing(id, client: client) else { return false }
        chat.updateOutgoing(id, state: .sending, wireText: text)
        var reached = true
        do {
            let mode = try await client.agentTopicsSend(target: target, topicID: topicID, message: text)
            chat.updateOutgoing(id, state: .submitted)
            if mode == .queued { sendNotes[topicID] = "Queued: the topic reads it when its current turn ends." }
        } catch let error as AgentTopicsError {
            switch error {
            case .timeout, .other:
                // The agent may have taken it: no one-tap duplicate.
                chat.updateOutgoing(id, state: .unconfirmed)
            default:
                chat.updateOutgoing(id, state: .notDelivered(Self.describe(error)))
                reached = false
            }
            sendNotes[topicID] = Self.describe(error)
        } catch is CancellationError {
            chat.updateOutgoing(id, state: .unconfirmed)
            return true
        } catch {
            chat.updateOutgoing(id, state: .unconfirmed)
            sendNotes[topicID] = "Couldn't confirm delivery. Check the topic before sending again."
        }
        Task { await chat.refresh(client: client) }
        await refresh(client: client)
        return reached
    }

    private static let tooLong = "Messages are limited to 32 KB. Send it in parts."

    // MARK: Suggestions and Organise

    /// Asks the agent to propose topics from its Inbox (`agent.topics.organise`). It answers at
    /// once; the proposals arrive as open suggestions, ticked, at the top of the list. Nothing
    /// reports a turn that proposed nothing: Organise shows as running until a new proposal
    /// or for 3 minutes (`TopicsOrganiseWait`).
    func organise(client: HerdrClient) async {
        guard !organising else { return }
        organising = true
        organiseNote = nil
        organiseWait.start(at: Date(), open: suggestions.map(\.id))
        do {
            let queued = try await client.agentTopicsOrganise(target: target)
            organiseNote = queued ? "Organise starts when the agent's current turn ends."
                                  : "The agent is reading the Inbox to propose topics."
        } catch {
            organiseWait.stop()
            organising = false
            organiseNote = (error as? AgentTopicsError) == .organiseRunning
                ? "The agent is already organising." : Self.describe(error)
            return
        }
        // Proposals came in while the call was answering: Organise is already over.
        guard organiseWait.isRunning else {
            organiseNote = nil
            return
        }
        let seconds = organiseWait.timeout
        organiseExpiry?.cancel()
        organiseExpiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((seconds + 0.5) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.checkOrganiseClock()
        }
        await refresh(client: client)
    }

    /// Organise's deadline passed with no new proposal: it is over.
    private func checkOrganiseClock() {
        if organiseWait.end(open: nil, now: Date()) { finishOrganise() }
    }

    private func finishOrganise() {
        organiseExpiry?.cancel()
        organiseExpiry = nil
        organising = false
        organiseNote = nil
    }

    /// Organise's timeout. DEBUG: the UI tests' `HERDR_MOCK_TOPICS_ORGANISE_SECONDS` shortens it.
    static var organiseTimeout: TimeInterval {
        #if DEBUG
        if let seconds = ProcessInfo.processInfo.environment["HERDR_MOCK_TOPICS_ORGANISE_SECONDS"]
            .flatMap(TimeInterval.init) { return seconds }
        #endif
        return TopicsOrganiseWait.defaultTimeout
    }

    /// Whether a proposal is ticked (all are, until the reader unticks one).
    func isTicked(_ suggestionID: String) -> Bool { !unticked.contains(suggestionID) }

    func toggleTick(_ suggestionID: String) {
        if unticked.contains(suggestionID) { unticked.remove(suggestionID) } else { unticked.insert(suggestionID) }
    }

    var tickedCount: Int { suggestions.filter { isTicked($0.id) }.count }

    /// Create N topics: starts a topic from each ticked proposal and dismisses the rest. Returns
    /// why one did not go through, or nil.
    func createTicked(client: HerdrClient) async -> String? {
        await settleProposals(client: client, accepting: Set(suggestions.filter { isTicked($0.id) }.map(\.id)))
    }

    /// Not now: dismisses every proposal.
    func dismissProposals(client: HerdrClient) async -> String? {
        await settleProposals(client: client, accepting: [])
    }

    private func settleProposals(client: HerdrClient, accepting: Set<String>) async -> String? {
        guard !settling else { return nil }
        settling = true
        defer { settling = false }
        var failure: String?
        for suggestion in suggestions {
            do {
                if accepting.contains(suggestion.id) {
                    _ = try await client.agentTopicsAcceptSuggestion(target: target, suggestionID: suggestion.id)
                } else {
                    try await client.agentTopicsDismissSuggestion(target: target, suggestionID: suggestion.id)
                }
            } catch AgentTopicsError.alreadyAccepted, AgentTopicsError.suggestionNotFound {
                continue   // someone else got there first
            } catch is CancellationError {
                return nil
            } catch {
                failure = failure ?? Self.describe(error)
            }
        }
        unticked = []
        await refresh(client: client)
        return failure
    }

    /// Opens a topic by id (a suggestion's Start, its "Continued in topic" line), as soon as
    /// the list has it, from any round (`TopicsListRounds.waitUntilListed`): the round in
    /// flight may predate the accept, and a failed list keeps the old one (herdrup#795, #806).
    /// False when a list from after this call answered without it (a start that failed puts
    /// the suggestion back to open), or when it is still missing after the bounded rounds:
    /// the caller stays where it is.
    @discardableResult
    func open(topicID: String, client: HerdrClient) async -> Bool {
        let listed = await rounds.waitUntilListed(isListed: { topic(topicID) != nil }) { [weak self] in
            await self?.refreshOnce(client: client) ?? false
        }
        guard listed else { return false }
        selectedTopicID = topicID
        return true
    }

    /// Opens the topic a suggestion's Start (or its "Continued in topic" line) names, unless
    /// that topic's start failed (`start_failed`): then the caller stays on the Inbox.
    func openStarted(topicID: String, client: HerdrClient) async -> Bool {
        guard await open(topicID: topicID, client: client) else { return false }
        guard !startWatch.hasFailed(topicID) else {
            selectedTopicID = nil
            return false
        }
        if let listed = topic(topicID) { startWatch.didOpen(listed) }
        return true
    }

    /// `start_failed`: the topic ended before its first turn and the suggestion is open again
    /// (the agent writes its own note into the Inbox). A reader on that topic leaves it.
    private func startFailed(topicID: String) {
        startWatch.didFail(topicID)
        guard !topicID.isEmpty, selectedTopicID == topicID else { return }
        leaveFailedStart(topicID)
    }

    private func leaveFailedStart(_ topicID: String) {
        selectedTopicID = nil
        onStartFailed?(topicID)
    }

    static func describe(_ error: Error) -> String {
        guard let error = error as? AgentTopicsError else { return "Couldn't reach the agent." }
        switch error {
        case .unreachable: return "Agent not reachable"
        case .timeout: return "The agent didn't answer in time."
        case .rejected(let reason): return reason.isEmpty ? "The agent refused." : "The agent refused: \(reason)"
        case .topicNotFound: return "This topic is gone."
        case .agentNotFound: return "This agent is gone."
        case .unsupported, .notAdvertised: return "This agent has no topics."
        case .suggestionsNotAdvertised: return "This server doesn't suggest topics."
        case .suggestionNotFound: return "That suggestion is gone."
        case .alreadyAccepted: return "Someone already started that topic."
        case .organiseRunning: return "The agent is already organising."
        case .seedTooLarge:
            return "The earlier messages are too long to copy into a new topic. Try again, or start the topic without them."
        case .topicsDisabled: return "Topics are off for this agent."
        case .invalidMessageIDs: return "The agent's picked messages are no longer in its conversation."
        case .other(let api): return api.message
        }
    }
}

// MARK: - Status

/// A topic's status as plain muted text ("Working", "Idle · 1 queued", "Closed") after its mark
/// (owner picks 2026-11-24, item 12, Apple clean): the activity spinner while it works, a 7 pt
/// faint dot while idle, no mark otherwise.
struct TopicStatusText: View {
    let topic: AgentTopic
    var size: CGFloat = 13

    /// The status as words ("Working", "Idle · 2 queued"), nil for a state this app does not
    /// know. Also the topic row's accessibility value.
    static func text(for topic: AgentTopic) -> String? {
        let label: String
        switch topic.state {
        case .starting: label = "Starting"
        case .running: label = "Working"
        case .idle: label = "Idle"
        case .dead: label = "Stopped"
        case .closed: label = "Closed"
        case .unknown: return nil
        }
        return topic.queued > 0 ? "\(label) · \(topic.queued) queued" : label
    }

    var body: some View {
        if let text = Self.text(for: topic) {
            HStack(spacing: 5) {
                if topic.state.isWorking {
                    ActivitySpinner()
                } else if topic.state == .idle {
                    Circle().fill(Palette.textFaint).frame(width: 7, height: 7)
                }
                Text(text).font(Typography.app(size)).foregroundStyle(Palette.textDim).lineLimit(1)
            }
            .fixedSize()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("topic-status-\(topic.id)")
        }
    }
}

/// The faint "·" between a status and what follows it.
private struct TopicsSeparator: View {
    var size: CGFloat = 13

    var body: some View {
        Text("·").font(Typography.app(size)).foregroundStyle(Palette.textFaint)
            .padding(.horizontal, 5)
            .accessibilityHidden(true)
    }
}

/// The 1 × 18 pt rule between the header's parts ("‹ Inbox" | the title).
private struct TopicsHeaderRule: View {
    var body: some View {
        Rectangle().fill(Palette.hairline).frame(width: 1, height: 18)
    }
}

/// The Topics bar's two parts, [fold] Topics (i) and the actions: on one line, the actions at the
/// trailing edge, while both fit; otherwise the actions on a line of their own under the heading,
/// still at the trailing edge (herdrup-desktop's wrapping `.topics-head`). The heading part is
/// never squeezed. Each part is one row, so the layout below always gets exactly its two subviews.
private struct TopicsHead<Title: View, Actions: View>: View {
    @ViewBuilder var title: Title
    @ViewBuilder var actions: Actions

    var body: some View {
        TopicsHeadLayout {
            HStack(spacing: 6) { title }
            HStack(spacing: 6) { actions }
        }
    }
}

/// `TopicsHead`'s layout: the heading row first, the actions row second.
private struct TopicsHeadLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 4

    private func sizes(_ subviews: Subviews) -> (CGSize, CGSize)? {
        // `TopicsHead` always passes its two rows.
        guard subviews.count == 2 else { return nil }
        return (subviews[0].sizeThatFits(.unspecified), subviews[1].sizeThatFits(.unspecified))
    }

    private func oneLine(_ title: CGSize, _ actions: CGSize, width: CGFloat) -> Bool {
        title.width + spacing + actions.width <= width
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard case let (title, actions)? = sizes(subviews) else { return .zero }
        let width = proposal.width ?? title.width + spacing + actions.width
        if oneLine(title, actions, width: width) {
            return CGSize(width: width, height: max(title.height, actions.height))
        }
        return CGSize(width: width, height: title.height + lineSpacing + actions.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard case let (title, actions)? = sizes(subviews) else { return }
        if oneLine(title, actions, width: bounds.width) {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(title))
            subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                              proposal: ProposedViewSize(actions))
        } else {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(title))
            subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.maxY), anchor: .bottomTrailing,
                              proposal: ProposedViewSize(actions))
        }
    }
}

/// iPad, column folded (owner picks 2026-11-24, item 15, Apple clean): a "Topics" compact capsule
/// with the sidebar glyph at the left of the header brings the column back; its ⌥⌘T hint is faint
/// text beside it.
private struct TopicsColumnShowButton: View {
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "sidebar.left").font(.system(size: 13, weight: .medium))
                    Text("Topics")
                }
            }
            .buttonStyle(.capsule(.secondary, .compact))
            .accessibilityLabel("Show topics")
            .accessibilityIdentifier("topics-column-show")
            Text("⌥⌘T").font(Typography.app(12)).tracking(0.5).foregroundStyle(Palette.textFaint)
                .accessibilityHidden(true)
        }
    }
}

/// The design's sizes: iPad's column as the owner picked it on 2026-11-24 (item 11, Apple clean:
/// herdrup-desktop src/topics.css), and iPhone's list screen (`compact`), which keeps its large
/// title and sizes.
private struct TopicsMetrics {
    let compact: Bool

    var headHeight: CGFloat { compact ? 52 : 50 }
    var heading: Font { compact ? Typography.app(28, .bold) : Typography.app(17, .semibold) }
    var searchHeight: CGFloat { compact ? 36 : 30 }
    var searchFont: CGFloat { compact ? 16 : 14 }
    var searchRadius: CGFloat { compact ? 10 : 9 }
    var rowTitle: CGFloat { compact ? 16 : 15 }
    var rowLine: CGFloat { compact ? 14 : 13 }
    var rowTime: CGFloat { compact ? 14 : 12 }
    var section: CGFloat { compact ? 14 : 12 }
    var sectionTop: CGFloat { compact ? 16 : 14 }
}

// MARK: - The Topics view

/// The Topics view of one agent's page: the list, and the open topic's chat. Hosted by the
/// owner's page and the guest's page alike.
struct TopicsPane: View {
    let client: HerdrClient
    @ObservedObject var model: TopicsModel
    let viewer: ChatViewer
    /// The pane id to follow topic events for (owner); nil for a guest, who polls.
    let eventsPaneID: String?
    /// The Topics view is the front, visible view.
    let isActive: Bool
    /// The agent can change its topics now (a guest's share is running).
    let live: Bool
    /// The Inbox row's second line: what the agent is doing in its own conversation.
    let inboxPreview: String?
    /// Opens the agent's own conversation (the page's Chat view).
    let onOpenInbox: () -> Void
    let onOpenTerminal: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

    /// iPad: the topics column's width. The desktop's 320 (Apple clean's 299 widened): the fold,
    /// the heading with About, and the two capsules fit on one line only this way.
    static let columnWidth: CGFloat = 320

    var body: some View {
        Group {
            if sizeClass == .regular {
                HStack(spacing: 0) {
                    // Folded, the column is gone entirely; "Topics ⌥⌘T" in the header brings it back.
                    if !model.columnHidden {
                        TopicsList(client: client, model: model, inboxPreview: inboxPreview,
                                   highlightsSelection: true, compact: false,
                                   onOpenInbox: onOpenInbox, onToggleColumn: toggleColumn)
                            .frame(width: Self.columnWidth)
                        Rectangle().fill(Palette.hairlineQuiet).frame(width: 1)
                    }
                    if let topic = model.topic(model.selectedTopicID) {
                        chat(topic, compact: false)
                    } else {
                        VStack(spacing: 0) {
                            if model.columnHidden {
                                HStack(spacing: 12) {
                                    TopicsColumnShowButton(action: toggleColumn)
                                    Spacer(minLength: 0)
                                }
                                .frame(height: 48).padding(.horizontal, 16)
                                .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairlineQuiet).frame(height: 1) }
                            }
                            Text(model.topics.isEmpty ? "Start a topic to give the agent a new line of work."
                                                      : "Choose a topic.")
                                .font(Typography.app(14)).foregroundStyle(Palette.textDim)
                                .multilineTextAlignment(.center).padding(24)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .accessibilityIdentifier("topics-placeholder")
                        }
                    }
                }
                .background { columnShortcut }
            } else if let topic = model.topic(model.selectedTopicID) {
                chat(topic, compact: true)
            } else {
                TopicsList(client: client, model: model, inboxPreview: inboxPreview,
                           highlightsSelection: false, compact: true,
                           onOpenInbox: onOpenInbox, onToggleColumn: nil)
            }
        }
        .background(Palette.groundMachine)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("topics-view")
        .task(id: isActive && live) {
            guard isActive else { return }
            if live {
                await model.follow(client: client, eventsPaneID: eventsPaneID)
            } else {
                await model.refresh(client: client)
            }
        }
    }

    private func toggleColumn() {
        model.columnHidden.toggle()
    }

    /// ⌥⌘T folds and unfolds the column from a hardware keyboard, either way.
    private var columnShortcut: some View {
        Button(action: toggleColumn) { Text("") }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func chat(_ topic: AgentTopic, compact: Bool) -> some View {
        TopicChat(client: client, model: model, chat: model.chatModel(for: topic.id), topic: topic,
                  viewer: viewer, eventsPaneID: eventsPaneID,
                  isActive: isActive && scenePhase.mountsChat, live: live, showsBack: compact,
                  onOpenInbox: onOpenInbox,
                  onShowColumn: !compact && model.columnHidden ? toggleColumn : nil,
                  onOpenTerminal: onOpenTerminal)
            .id(topic.id)
    }
}

/// The topics column: Organise and New topic, search, the Inbox pinned first, then the topics
/// by last activity in day sections, and the closed ones last.
private struct TopicsList: View {
    let client: HerdrClient
    @ObservedObject var model: TopicsModel
    let inboxPreview: String?
    /// iPad: the open topic's row is filled `surfaceRaised`, rounded, as the design draws it.
    let highlightsSelection: Bool
    /// iPhone: the list is its own screen, with a large "Topics" heading.
    let compact: Bool
    let onOpenInbox: () -> Void
    /// iPad: the column's toggle (it folds the column away); nil on iPhone.
    let onToggleColumn: (() -> Void)?

    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var composing = false
    @State private var showingAbout = false
    @State private var renaming: AgentTopic?
    @State private var renameTitle = ""
    @State private var actionNote: String?

    private var metrics: TopicsMetrics { TopicsMetrics(compact: compact) }

    private var shown: [AgentTopic] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.topics }
        return model.topics.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || ($0.lastActivity?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    /// One line of the list: a section heading or a topic. Flat, with each topic keyed by its
    /// own id whatever section it is in: with nested per-section ForEach, a topic that moved
    /// section (closed, reopened) kept drawing its old row in the lazy stack.
    private enum Line: Identifiable {
        case heading(String)
        case topic(AgentTopic)

        var id: String {
            switch self {
            case .heading(let title): return "heading:" + title
            case .topic(let topic): return "topic:" + topic.id
            }
        }

        var topicID: String? {
            if case .topic(let topic) = self { return topic.id }
            return nil
        }
    }

    /// Open topics by day (Today, This week, Earlier), then Closed: sentence-case labels.
    private var lines: [Line] {
        let calendar = Calendar.current
        let now = GramDates.clockNow()
        let startOfToday = calendar.startOfDay(for: now)
        let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
        var today: [AgentTopic] = [], week: [AgentTopic] = [], earlier: [AgentTopic] = [], closed: [AgentTopic] = []
        for topic in shown {
            if topic.state == .closed {
                closed.append(topic)
                continue
            }
            let date = Date(timeIntervalSince1970: Double(topic.activityUnixMs) / 1000)
            if date >= startOfToday { today.append(topic) }
            else if date >= weekAgo { week.append(topic) }
            else { earlier.append(topic) }
        }
        return [("Today", today), ("This week", week), ("Earlier", earlier), ("Closed", closed)]
            .filter { !$0.1.isEmpty }
            .flatMap { title, topics in [Line.heading(title)] + topics.map(Line.topic) }
    }

    private func isSelected(_ topicID: String?) -> Bool {
        highlightsSelection && topicID != nil && model.selectedTopicID == topicID
    }

    /// The hairline above a topic row: only between two rows, and never touching the
    /// selected row's rounded fill.
    private func ruled(_ index: Int, in lines: [Line]) -> Bool {
        guard index > 0, let current = lines[index].topicID, let previous = lines[index - 1].topicID else {
            return false
        }
        return !isSelected(current) && !isSelected(previous)
    }

    var body: some View {
        let lines = self.lines
        VStack(spacing: 0) {
            head
            searchField
            if let note = actionNote ?? model.listedProblem {
                HStack(spacing: 6) {
                    Circle().fill(Palette.died).frame(width: 6, height: 6)
                    Text(note).font(Typography.app(12)).foregroundStyle(Palette.textDim).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.bottom, 6)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("topics-problem")
            } else if let note = model.organiseNote {
                Text(note).font(Typography.app(12)).foregroundStyle(Palette.textDim).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 6)
                    .accessibilityIdentifier("topics-organise-note")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    inboxRow
                    if !model.suggestions.isEmpty && search.isEmpty {
                        proposals
                    }
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        switch line {
                        case .heading(let title):
                            sectionLabel(title)
                        case .topic(let topic):
                            row(topic, ruled: ruled(index, in: lines))
                        }
                    }
                    if model.loaded && model.topics.isEmpty && model.problem == nil {
                        Text("No topics yet. A topic is a lasting line of work with its own conversation.")
                            .font(Typography.app(13)).foregroundStyle(Palette.textDim)
                            .padding(.horizontal, 10).padding(.top, 16)
                            .accessibilityIdentifier("topics-empty")
                    } else if !search.isEmpty && shown.isEmpty {
                        Text("No topic matches.")
                            .font(Typography.app(13)).foregroundStyle(Palette.textDim)
                            .padding(.horizontal, 10).padding(.top, 16)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("topics-list")
            if !model.suggestions.isEmpty {
                proposalsBar
            }
        }
        .sheet(isPresented: $composing) {
            NewTopicSheet { title, message in
                await model.create(client: client, title: title, message: message)
            }
        }
        .alert("Rename topic", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameTitle)
                .accessibilityIdentifier("topics-rename-field")
            Button("Rename") {
                guard let topic = renaming else { return }
                let title = renameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                renaming = nil
                guard !title.isEmpty, title != topic.title else { return }
                Task { actionNote = await model.rename(client: client, topicID: topic.id, title: title) }
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    /// [fold] Topics (i) … Organise  New topic (owner picks 2026-11-24, item 11, Apple clean with
    /// Before's buttons): the fold is the column's one icon, About sits beside the heading, and
    /// the actions are compact capsules. When they don't fit beside the heading (a narrow column, a
    /// large text size), they take a line of their own at the trailing edge.
    private var head: some View {
        TopicsHead {
            if let onToggleColumn {
                Button(action: onToggleColumn) {
                    Image(systemName: "sidebar.left").font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Palette.textDim)
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide topics")
                .accessibilityIdentifier("topics-column-toggle")
                .padding(.trailing, -6)
            }
            HStack(spacing: 4) {
                Text("Topics").font(metrics.heading).foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityAddTraits(.isHeader)
                aboutButton
            }
        } actions: {
            if model.suggestionsServed {
                // The agent proposes topics from its Inbox (proposal 3). While it works, the
                // spinner takes the label's place in a slot the label sizes, so the capsule
                // keeps its width and the bar never wraps for it.
                Button { Task { await model.organise(client: client) } } label: {
                    ZStack {
                        Text("Organise").opacity(model.organising ? 0 : 1)
                        if model.organising { ProgressView().controlSize(.mini).tint(Palette.textDim) }
                    }
                }
                .buttonStyle(.capsule(.secondary, .compact))
                .disabled(model.organising)
                .accessibilityLabel("Organise")
                .accessibilityIdentifier("topics-organise")
            }
            Button("New topic") { composing = true }
                .buttonStyle(.capsule(.secondary, .compact))
                .accessibilityIdentifier("topics-new")
        }
        .frame(minHeight: metrics.headHeight)
        .padding(.leading, onToggleColumn == nil ? 16 : 8).padding(.trailing, onToggleColumn == nil ? 16 : 10)
    }

    /// "Search topics" after a magnifying glass (owner picks 2026-11-24, item 11).
    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: metrics.searchFont - 1, weight: .medium))
                .foregroundStyle(Palette.textFaint)
                .accessibilityHidden(true)
            TextField("", text: $search, prompt: Text("Search topics").foregroundColor(Palette.textFaint))
                .textFieldStyle(.plain)
                .font(Typography.app(metrics.searchFont))
                .foregroundStyle(Palette.text)
                .tint(Palette.text)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("topics-search-field")
        }
        .padding(.horizontal, compact ? 10 : 9)
        .frame(height: metrics.searchHeight)
        .background(RoundedRectangle(cornerRadius: metrics.searchRadius).fill(Palette.surface))
        .contentShape(Rectangle())
        .onTapGesture { searchFocused = true }
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    /// "Today", "This week", "Closed": sentence case, muted.
    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(Typography.app(metrics.section, .semibold)).foregroundStyle(Palette.textDim)
            .padding(.horizontal, 10).padding(.top, metrics.sectionTop).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    /// The agent's own conversation, pinned first, as a row like the topics: it opens the
    /// page's Chat view.
    private var inboxRow: some View {
        Button(action: onOpenInbox) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Inbox").font(Typography.app(metrics.rowTitle, .semibold)).foregroundStyle(Palette.text)
                Text(inboxPreview?.isEmpty == false ? inboxPreview! : "The agent's own conversation")
                    .font(Typography.app(metrics.rowLine)).foregroundStyle(Palette.textDim).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("topics-inbox-row")
    }

    /// The agent's proposals, in the list itself above the topics (proposal 3): each ticked
    /// until the reader unticks it, with its message count and the agent's reason. Ticking picks
    /// topics to create, never messages: the agent picked those.
    private var proposals: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel(model.agentName.isEmpty ? "Suggested by the agent" : "Suggested by \(model.agentName)")
                .accessibilityIdentifier("topics-proposals-heading")
            ForEach(model.suggestions) { suggestion in
                proposalRow(suggestion)
            }
        }
    }

    private func proposalRow(_ suggestion: AgentTopicSuggestion) -> some View {
        let ticked = model.isTicked(suggestion.id)
        let title = suggestion.title.isEmpty ? "Untitled topic" : suggestion.title
        return Button { model.toggleTick(suggestion.id) } label: {
            HStack(alignment: .top, spacing: 10) {
                // The tick is a working control: it picks the topics Create makes.
                Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(ticked ? Palette.text : Palette.textFaint)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title).font(Typography.app(metrics.rowTitle, .semibold))
                            .foregroundStyle(ticked ? Palette.text : Palette.textDim)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if suggestion.messageCount > 0 {
                            Text(suggestion.messageCount == 1 ? "1 message" : "\(suggestion.messageCount) messages")
                                .font(Typography.app(metrics.rowTime)).foregroundStyle(Palette.textFaint)
                                .fixedSize()
                        }
                    }
                    if !suggestion.reason.isEmpty {
                        Text(suggestion.reason).font(Typography.app(metrics.rowLine)).foregroundStyle(Palette.textDim)
                            .lineLimit(2)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.settling)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(ticked ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(title)
        .accessibilityValue([ticked ? "Ticked" : "Not ticked", suggestion.reason]
            .filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityIdentifier("topics-proposal-\(suggestion.id)")
    }

    /// Not now · Create N topics under the list while there are proposals (owner picks 2026-11-24,
    /// item 13: Apple clean dimensions, curved like Before): a quiet 55 pt bar with a hairline on
    /// top, Not now a secondary capsule and Create N topics the filled one.
    private var proposalsBar: some View {
        let count = model.tickedCount
        let createLabel: String = count == 1 ? "Create 1 topic" : "Create \(count) topics"
        return HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button("Not now") {
                Task { actionNote = await model.dismissProposals(client: client) }
            }
            .buttonStyle(.capsule(.secondary, .compact))
            .accessibilityIdentifier("topics-proposals-dismiss")
            Button(createLabel) {
                Task { actionNote = await model.createTicked(client: client) }
            }
            .buttonStyle(.capsule(.filled, .compact))
            .disabled(count == 0)
            .accessibilityIdentifier("topics-proposals-create")
        }
        .disabled(model.settling)
        .padding(.horizontal, 16)
        .frame(height: 55)
        // The desktop's quiet fill: the surface at 55 % over the ground.
        .background { Palette.surface.opacity(0.55).background(Palette.ground) }
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairlineQuiet).frame(height: 1) }
    }

    private func row(_ topic: AgentTopic, ruled: Bool) -> some View {
        let selected = isSelected(topic.id)
        let closed = topic.state == .closed
        return Button {
            model.selectedTopicID = topic.id
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(topic.title.isEmpty ? "Untitled topic" : topic.title)
                        .font(Typography.app(metrics.rowTitle, closed ? .medium : .semibold))
                        .foregroundStyle(closed ? Palette.textDim : Palette.text)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if topic.activityUnixMs > 0 {
                        Text(GramDates.rowTime(for: Date(timeIntervalSince1970: Double(topic.activityUnixMs) / 1000)))
                            .font(Typography.app(metrics.rowTime)).monospacedDigit().foregroundStyle(Palette.textFaint)
                            .fixedSize()
                    }
                }
                // "Working · Drawing the waiting state…": the status in words, then the last step.
                HStack(spacing: 0) {
                    TopicStatusText(topic: topic, size: metrics.rowLine)
                    if let activity = topic.lastActivity, !activity.isEmpty {
                        TopicsSeparator(size: metrics.rowLine)
                        Text(activity).font(Typography.app(metrics.rowLine)).foregroundStyle(Palette.textDim)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Palette.surfaceRaised : Color.clear))
            .overlay(alignment: .top) {
                if ruled { Rectangle().fill(Palette.hairlineQuiet).frame(height: 1).padding(.horizontal, 10) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The title is the row's name; its status and last activity are its value.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(topic.title.isEmpty ? "Untitled topic" : topic.title)
        .accessibilityValue([TopicStatusText.text(for: topic), topic.lastActivity]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityIdentifier("topic-row-\(topic.id)")
        .stableContextMenu {
            StableMenuItem("Rename…", systemImage: "pencil") {
                renameTitle = topic.title
                renaming = topic
            }
            if topic.state == .closed {
                StableMenuItem("Reopen", systemImage: "arrow.uturn.backward") {
                    Task { actionNote = await model.reopen(client: client, topicID: topic.id) }
                }
            } else {
                StableMenuItem("Close", systemImage: "archivebox") {
                    Task { actionNote = await model.close(client: client, topicID: topic.id) }
                }
            }
        }
    }
}

extension TopicsList {
    /// About topics (owner picks 2026-11-24, item 11): the faint (i) beside the heading, what
    /// topics are. A bottom sheet on iPhone, a popover pointing at it on iPad. It takes 24 pt of
    /// the bar; its touch area reaches 10 pt past each edge, 44 pt square.
    private var aboutButton: some View {
        Button { showingAbout = true } label: {
            Image(systemName: "info.circle").font(.system(size: 15, weight: .regular))
                .foregroundStyle(Palette.textFaint)
                .frame(width: 24, height: 24)
                .contentShape(.interaction, TouchTarget(dx: 10, dy: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About topics")
        .accessibilityIdentifier("topics.about")
        .popover(isPresented: $showingAbout, arrowEdge: .top) {
            AboutTopicsView()
                .frame(idealWidth: 380, idealHeight: 560)
                .presentationCompactAdaptation(.sheet)
                .presentationDetents([.medium, .large])
        }
    }
}

/// "About topics": what a topic is, the Inbox, starting, parallel work and closing.
private struct AboutTopicsView: View {
    @Environment(\.dismiss) private var dismiss

    /// Heading, then its text.
    private static let sections: [[String]] = [
        ["One subject each",
         "Topics are separate conversations with the same agent, one per subject (for example \"Q4 board pack\"). Each keeps its own history, so subjects don't mix."],
        ["The Inbox",
         "The Inbox is the agent's main conversation. Messages from outside (other agents, Gram, reviews) arrive there. Replies to something a topic started go back to that topic."],
        ["Starting a topic",
         "Tap New topic and give it a title and a first message. Topics are not created automatically. The short summary under each topic is written automatically after each reply."],
        ["Working in parallel",
         "Several topics can work at the same time. A topic can look at another topic's conversation, and the Inbox knows what every topic is doing."],
        ["Closing",
         "Closing a topic keeps everything: it writes a closing note, and you can reopen it later. Nothing is deleted."],
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Self.sections, id: \.self) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section[0]).font(Typography.app(15, .semibold)).foregroundStyle(Palette.text)
                            Text(section[1]).font(Typography.app(14)).foregroundStyle(Palette.textDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Palette.ground.ignoresSafeArea())
            .navigationTitle("About topics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("topics-about-done")
                }
            }
        }
        .accessibilityIdentifier("topics-about-sheet")
    }
}

/// New topic: a title and the first message, which starts its first turn.
private struct NewTopicSheet: View {
    /// Starts the topic; returns why it did not start, or nil.
    let start: (_ title: String, _ message: String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var message = ""
    @State private var starting = false
    @State private var problem: String?

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                field("TITLE") {
                    TextField("e.g. Q4 board pack", text: $title)
                        .accessibilityIdentifier("topics-new-title")
                }
                field("FIRST MESSAGE") {
                    TextField("What should this topic work on?", text: $message, axis: .vertical)
                        .lineLimit(4...10)
                        .accessibilityIdentifier("topics-new-message")
                }
                if let problem {
                    Text(problem).font(Typography.app(13)).foregroundStyle(Palette.textDim)
                        .accessibilityIdentifier("topics-new-problem")
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.ground.ignoresSafeArea())
            .navigationTitle("New topic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("topics-new-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(starting ? "Starting…" : "Start") {
                        starting = true
                        problem = nil
                        Task {
                            let failure = await start(trimmedTitle, trimmedMessage)
                            starting = false
                            if let failure { problem = failure } else { dismiss() }
                        }
                    }
                    .disabled(trimmedTitle.isEmpty || trimmedMessage.isEmpty || starting)
                    .accessibilityIdentifier("topics-new-start")
                }
            }
        }
        .tint(Palette.text)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(Typography.microLabel).tracking(1).foregroundStyle(Palette.textFaint)
            content()
                .font(Typography.app(16)).foregroundStyle(Palette.text)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surface))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline, lineWidth: 1))
        }
    }
}

// MARK: - A topic's chat

/// One topic's conversation: `agent.transcript` with `topic`, and a composer that sends to
/// this topic only (`agent.topics.send`).
private struct TopicChat: View {
    let client: HerdrClient
    @ObservedObject var model: TopicsModel
    @ObservedObject var chat: ChatModel
    let topic: AgentTopic
    let viewer: ChatViewer
    let eventsPaneID: String?
    let isActive: Bool
    let live: Bool
    /// iPhone: the topic is its own screen, with "‹ Topics" back to the list.
    let showsBack: Bool
    /// iPad: "‹ Inbox" in the header opens the agent's own conversation (the Chat view).
    let onOpenInbox: () -> Void
    /// iPad, column folded: "Topics ⌥⌘T" at the header's left brings the column back.
    let onShowColumn: (() -> Void)?
    let onOpenTerminal: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var keyboard = ComposerKeyboard()
    @State private var reply = ""
    @State private var focused = false
    @State private var dictating = false
    @State private var sending = false
    @State private var sendPresses = 0
    @State private var actionNote: String?
    /// The draft's files: the paperclip's picks, pastes and drops, each uploading to the
    /// machine from the moment it is added, as in the Inbox's composer.
    @State private var attachments: [ComposerAttachment] = []
    @State private var loadingAttachment = false
    @State private var showAttachSheet = false
    @State private var uploader = ComposerUploader()
    @State private var sendingAttachmentID: UUID?
    @State private var failedAttachmentID: UUID?
    @State private var dropTargeted = false
    /// The chat's whole height, its header's and the send note's: the composer's editor
    /// room is measured from these, never from the composer itself (`composerEditorRoom`).
    @State private var pageHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    @State private var noteHeight: CGFloat = 0

    /// The composer's padding around its card (top 4 + bottom 8).
    private static let composerPadding: CGFloat = 12
    /// Kept above the open editor, as Gram's feed cushion.
    private static let roomCushion: CGFloat = 12
    /// How far the composer's pull-to-expand editor may grow over the conversation, as in
    /// the Inbox and Gram: the chat below the header, less the send note, the resting
    /// composer and a cushion.
    private var composerRoom: CGFloat {
        max(0, pageHeight - headerHeight - noteHeight - Self.composerPadding
            - ComposerStyle.restingHeight - Self.roomCushion)
    }

    private var closed: Bool { topic.state == .closed }
    private var canCompose: Bool { live && !closed }
    private var canAttach: Bool { canCompose && !sending && !loadingAttachment }
    private var hasContent: Bool {
        !attachments.isEmpty || !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var author: TranscriptAuthor {
        if case .guest(let name, _) = viewer { return .guest(name: name) }
        return .owner
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            // The server lists topics but cannot page a topic's conversation (no
            // `agent_transcript_topic`): say so, and offer no composer that could not show what
            // it sent (herdrup#766). Decided by the capability, which does not change, not by the
            // chat's latest answer: a `transcript_unsupported` while the agent or its session
            // starts is passing, and the mounted chat keeps following and recovers (#775).
            if model.topicTranscripts == false {
                unavailable
            } else {
                // The topic's own state says it works, as the agent's status does for the
                // Inbox; otherwise the page's `working` decides, as in the Inbox.
                ChatView(client: client, model: chat, viewer: viewer, eventsPaneID: eventsPaneID,
                         isActive: isActive, live: live, agentStatus: topic.state.isWorking ? "working" : nil,
                         ground: Palette.groundMachine, onOpenTerminal: onOpenTerminal)
                    .equatable()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // This topic's own note only: a late receipt for another topic stays with that one.
                if let note = actionNote ?? model.sendNote(for: topic.id) {
                    Text(note).font(Typography.app(12)).foregroundStyle(Palette.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 4)
                        .accessibilityIdentifier("topic-send-note")
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { noteHeight = $0 }
                        .onDisappear { noteHeight = 0 }
                }
                composer
                    .environment(\.composerEditorRoom, composerRoom)
                    .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 8)
                    .conversationColumn()
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeight = $0 }
        .background(Palette.groundMachine)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("topic-chat")
        .chatSheets(client: client, model: chat, viewer: viewer, presents: isActive, onOpenTerminal: onOpenTerminal)
    }

    private var unavailable: some View {
        VStack(spacing: 8) {
            Text("This server can't show topic conversations")
                .font(Typography.app(15, .semibold)).foregroundStyle(Palette.text)
                .accessibilityIdentifier("topic-chat-unavailable")
            Text("Update herdr on this machine to read and send to topics here. The Terminal still shows the agent.")
                .font(Typography.app(13)).foregroundStyle(Palette.textDim)
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String { topic.title.isEmpty ? "Untitled topic" : topic.title }

    @ViewBuilder
    private var header: some View {
        if showsBack { phoneHeader } else { padHeader }
    }

    /// iPad: [Topics ⌥⌘T |] ‹ Inbox | Title · status … ⋯, one 48 pt row (owner picks 2026-11-24,
    /// item 14, Apple clean with Before's buttons): ‹ Inbox a compact capsule, the 16 pt title,
    /// ••• a circle.
    private var padHeader: some View {
        HStack(spacing: 12) {
            if let onShowColumn {
                TopicsColumnShowButton(action: onShowColumn)
                TopicsHeaderRule()
            }
            Button(action: onOpenInbox) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("Inbox")
                }
            }
            .buttonStyle(.capsule(.secondary, .compact))
            .accessibilityLabel("Inbox")
            .accessibilityIdentifier("topic-inbox-link")
            TopicsHeaderRule()
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(Typography.app(16, .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                    .accessibilityIdentifier("topic-chat-title")
                TopicStatusText(topic: topic, size: 13)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actionsMenu
        }
        .frame(height: 48)
        .padding(.leading, 16).padding(.trailing, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairlineQuiet).frame(height: 1) }
    }

    /// iPhone: ‹ Topics … Terminal ⋯, then the title large, and "• Working · herdr-app" under
    /// it. ‹ Topics and Terminal are compact capsules and ••• a circle (item 14); the title
    /// keeps the large-title scale. The topic is full screen here, without the page's
    /// Topics | Chat | Terminal switch, so Terminal opens the agent's pane from the topic: a
    /// topic runs inside the agent's one omp, with no terminal of its own.
    private var phoneHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    focused = false
                    model.selectedTopicID = nil
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Topics")
                    }
                }
                .buttonStyle(.capsule(.secondary, .compact))
                .accessibilityLabel("Topics")
                .accessibilityIdentifier("topic-back")
                Spacer(minLength: 8)
                Button {
                    focused = false
                    onOpenTerminal()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "terminal").font(.system(size: 11, weight: .semibold))
                        Text("Terminal")
                    }
                }
                .buttonStyle(.capsule(.secondary, .compact))
                .accessibilityLabel("Terminal")
                .accessibilityIdentifier("topic-terminal")
                .padding(.trailing, 8)
                actionsMenu
            }
            .frame(height: 50)
            .padding(.leading, 16).padding(.trailing, 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typography.app(22, .bold)).foregroundStyle(Palette.text).lineLimit(2)
                    .accessibilityIdentifier("topic-chat-title")
                HStack(spacing: 0) {
                    TopicStatusText(topic: topic, size: 13)
                    if !model.agentName.isEmpty {
                        TopicsSeparator(size: 13)
                        Text(model.agentName).font(Typography.app(13)).foregroundStyle(Palette.textDim).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.bottom, 10)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairlineQuiet).frame(height: 1) }
    }

    /// ⋯: Close or Reopen.
    private var actionsMenu: some View {
        Menu {
            if closed {
                Button {
                    Task { actionNote = await model.reopen(client: client, topicID: topic.id) }
                } label: { Label("Reopen", systemImage: "arrow.uturn.backward") }
            } else {
                Button {
                    Task { actionNote = await model.close(client: client, topicID: topic.id) }
                } label: { Label("Close", systemImage: "archivebox") }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.circle(diameter: 30))
        .accessibilityLabel("Topic actions")
        .accessibilityIdentifier("topic-actions")
    }

    /// The Inbox's composer, piece for piece: the paperclip's sheet and pickers, pasted and
    /// dropped files, the chip strip with each file uploading as it is added, the mic,
    /// Saved Prompts in Send's slot while the draft is empty, and the pull-to-expand editor.
    private var composer: some View {
        AdaptiveComposer(
            text: reply,
            isFocused: focused,
            hasAccessory: !attachments.isEmpty || loadingAttachment,
            showsLeading: keyboard.isVisible && focused,
            isRecording: dictating
        ) { editorHeight in
            ComposerTextField(
                text: $reply,
                isEnabled: canCompose && !dictating,
                isFocused: focused,
                onFocusChange: { focused = $0 },
                placeholder: "",
                accessibilityIdentifier: "topic-composer-input",
                capitalization: .sentences,
                autocorrection: .default,
                onChange: { _, _ in actionNote = nil },
                onCommandReturn: { send() },
                onPasteFile: { stageFiles([$0]) },
                fixedHeight: editorHeight
            )
            .frame(minWidth: 0, maxWidth: .infinity)
            .overlay(alignment: .leading) {
                if reply.isEmpty && !dictating {
                    Text(closed ? "Closed. Reopen it to continue." : "Message \(topic.title.isEmpty ? "this topic" : topic.title)")
                        .font(Typography.app(16)).foregroundStyle(Palette.textDim)
                        .lineLimit(1).allowsHitTesting(false)
                }
            }
        } accessory: {
            attachmentStrip
        } leading: {
            Button { focused = false } label: {
                ComposerActionIcon(image: Image("ComposerKeyboard"))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Collapse keyboard")
        } actions: {
            HStack(spacing: 4) {
                ComposerAttachButton(busy: loadingAttachment) { openAttachSheet() }
                    .disabled(!canAttach)
                    .accessibilityIdentifier("topic-attach-button")
                MicButton(text: $reply, isActive: isActive, recording: $dictating)
                    .fixedSize()
                    .disabled(!canCompose || sending)
                // One slot for Send and Saved Prompts, so the Send press survives the swap
                // the clearing composer makes in the same frame.
                ZStack {
                    if hasContent {
                        Button { send() } label: {
                            ComposerActionIcon(image: Image("ComposerSend"), primary: true, busy: sending,
                                               progress: uploader.sendProgress(attachments, sending: sending))
                        }
                        .disabled(!canCompose || sending || dictating || loadingAttachment)
                        .fixedSize()
                        .accessibilityLabel("Send to topic")
                        .accessibilityIdentifier("topic-send-button")
                    } else {
                        // A saved prompt fills the composer and goes to this topic, like a typed one.
                        SavedPromptsMenu { prompt in
                            reply = prompt.text
                            send()
                        }
                        .disabled(!canCompose || sending || dictating || loadingAttachment)
                        .accessibilityIdentifier("topic-saved-prompts")
                    }
                }
                .modifier(ChatSendPress(trigger: sendPresses))
            }
            .buttonStyle(.plain)
        }
        .opacity(canCompose ? 1 : 0.45)
        .disabled(!canCompose)
        // A file dragged from Files or a Mac lands like a paste, anywhere on the bar.
        .onDrop(of: [.item], isTargeted: $dropTargeted) { stageFiles($0) }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 28)
                    .strokeBorder(Palette.brand, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .composerAttachPicker(
            isPresented: $showAttachSheet, loading: $loadingAttachment,
            room: { ComposerStaging.maxAttachments - attachments.count }
        ) { outcome in addPicked(outcome) }
        // Leaving the topic stops its uploads (a send waiting on one keeps it); closing it
        // for good releases the uploader, which cancels and discards them.
        .onDisappear { uploader.pause() }
        .onAppear { uploader.resume() }
    }

    @ViewBuilder
    private var attachmentStrip: some View {
        if !attachments.isEmpty || loadingAttachment {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachmentChip($0) }
                    if loadingAttachment {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Adding attachment…").font(Typography.app(12))
                        }
                        .foregroundStyle(Palette.textDim)
                        .padding(12)
                        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 15))
                    }
                }
                .padding(.horizontal, 7)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func attachmentChip(_ file: ComposerAttachment) -> some View {
        let state = ComposerAttachmentState.for(
            file, upload: uploader.phase(of: file.id), sending: sending,
            sendingID: sendingAttachmentID, failedID: failedAttachmentID)
        // A file still uploading can go: removing it cancels its upload. Only a send in
        // flight holds the strip, so the batch it is delivering stays whole.
        return ComposerAttachmentChip(
            name: file.name, size: file.staged.size, isImage: file.isImage, state: state,
            canRemove: !sending,
            onRemove: { removeAttachment(file) },
            onRetry: { uploader.retry(file.id) }
        )
        .accessibilityIdentifier("topic-attachment")
    }

    /// Files go to the agent as Grams addressed to it by name, the name its topics list
    /// carries; nil until the first list answers.
    private var attachTarget: String? { model.agentName.isEmpty ? nil : model.agentName }

    private func takesAttachment() -> Bool {
        guard attachments.count < ComposerStaging.maxAttachments else {
            actionNote = "Up to \(ComposerStaging.maxAttachments) attachments at a time."
            return false
        }
        guard attachTarget != nil else {
            actionNote = "Files can be attached once the agent's topics have loaded."
            return false
        }
        return true
    }

    private func openAttachSheet() {
        guard canAttach, takesAttachment() else { return }
        showAttachSheet = true
    }

    /// Stages pasted or dropped files by the composer's paste and drop rule (`PastedFile`)
    /// within the attachment cap, then adds them exactly as a paperclip pick. False when
    /// none is a file this composer takes, so a paste falls back to text.
    private func stageFiles(_ providers: [NSItemProvider]) -> Bool {
        let files = TerminalFileDrop.files(in: providers)
        guard canAttach, !files.isEmpty, takesAttachment() else { return false }
        let room = ComposerStaging.maxAttachments - attachments.count
        loadingAttachment = true
        Task { @MainActor in
            let outcome = await PastedFile.stageAll(files, room: room)
            loadingAttachment = false
            addPicked(outcome)
        }
        return true
    }

    /// Staged picks, pastes or drops join the draft and start uploading at once, so Send
    /// only has to post them and send the message.
    private func addPicked(_ outcome: ComposerPickOutcome) {
        let picked = outcome.files.map {
            ComposerAttachment(name: $0.name, mime: $0.mime, isImage: $0.isImage, staged: $0.staged)
        }
        attachments += picked
        uploader.start(picked, client: client, into: $attachments)
        actionNote = outcome.note
    }

    private func removeAttachment(_ file: ComposerAttachment) {
        guard let current = attachments.first(where: { $0.id == file.id }) else { return }
        attachments.removeAll { $0.id == file.id }
        // Cancels a running upload, deletes the staged bytes, and discards a finished upload.
        uploader.remove(current)
        // A file dropped after its Gram posted (a batch that failed halfway) must not stay
        // behind in the agent's Gram inbox.
        if let messageID = current.messageID, !viewer.isGuest {
            Task { try? await client.gramDelete(id: messageID) }
        }
    }

    private func send() {
        guard canCompose, !sending, !dictating, !loadingAttachment, hasContent else { return }
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let batch = attachments
        // The bubble enters (and the chat follows it) on the send motion; staged now.
        guard let id = withAnimation(ChatSendMotion.bubble(reduceMotion: reduceMotion), {
            model.stage(topicID: topic.id, text: text, author: author, files: batch)
        }) else { return }
        sending = true
        actionNote = nil
        if ChatSendMotion.acceptSend(reduceMotion: reduceMotion) { sendPresses += 1 }
        let clearedReply = reply
        ChatSendMotion.clearComposer(inChat: true) { reply = "" }
        Task {
            defer { sending = false; sendingAttachmentID = nil }
            failedAttachmentID = nil
            // The Inbox's way: each file posts as a Gram to the agent, then one message names
            // them all with how to fetch them (`GramAttachmentPrompt`). The topic runs in the
            // agent's own omp, so `herdr gram get-file` finds them there too.
            var message = text
            if !batch.isEmpty {
                guard let delivered = await postAttachments(batch) else {
                    chat.updateOutgoing(id, state: .notDelivered("Attachment upload did not complete."))
                    if reply.isEmpty { reply = clearedReply }
                    return
                }
                message = GramAttachmentPrompt.text(text, delivered: delivered)
            }
            let reached = await model.deliver(client: client, topicID: topic.id, outgoingID: id, text: message)
            guard !batch.isEmpty else { return }
            if reached {
                // Each file's staged bytes went when its Gram posted: nothing left to discard.
                let sentIDs = Set(batch.map(\.id))
                attachments.removeAll { sentIDs.contains($0.id) }
                uploader.forget(sentIDs)
            } else if reply.isEmpty {
                // Not delivered: the chips (their Grams remembered) and the text stay for a retry.
                reply = clearedReply
            }
        }
    }

    /// Posts each file as a Gram to the agent (`GramAttachmentSender`), remembering each
    /// step so a retry resumes rather than re-sends; nil when one failed.
    private func postAttachments(_ batch: [ComposerAttachment]) async -> [GramAttachmentPrompt.Delivered]? {
        guard let target = attachTarget else {
            actionNote = "Files can be attached once the agent's topics have loaded."
            return nil
        }
        let guestName: String? = { if case .guest(let name, _) = viewer { return name } else { return nil } }()
        let topicTitle = title
        let sender = uploader.sender(client: client, into: $attachments, post: { [client] _, attachment in
            if let guestName {
                return try await client.guestGramPost(
                    text: "Attachment from \(guestName) for the topic \(topicTitle).", to: target,
                    attachment: attachment
                ).id
            }
            return try await client.gramPost(
                text: "Attachment for the topic \(topicTitle).", to: target, attachment: attachment
            ).id
        })
        let result = await sender.send(batch, sending: { sendingAttachmentID = $0.id }) { file in
            guard let index = attachments.firstIndex(where: { $0.id == file.id }) else { return }
            attachments[index] = file
        }
        switch result {
        case .success(let delivered):
            return delivered
        case .failure(let failure):
            failedAttachmentID = failure.attachment.id
            actionNote = failure.note("Send failed: \(failure.error)")
            return nil
        }
    }
}
