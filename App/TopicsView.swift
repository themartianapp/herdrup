import HerdrKit
import SwiftUI
import UIKit

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
    /// The first list call answered, either way.
    @Published private(set) var loaded = false
    /// The agent answered `agent.topics.list` this session: the page offers Topics.
    @Published private(set) var offered = false
    /// The agent will not offer topics for this page's life (`topics_unsupported`, no
    /// `agent_topics`, the agent is gone): discovery stopped for good.
    private(set) var refused = false
    /// Why the newest list call failed. The last list stays on screen (`topics_unreachable`
    /// keeps it, as herdr's API asks).
    @Published private(set) var problem: String?
    /// The open topic: its chat on a phone, the selected row and its chat on iPad.
    @Published var selectedTopicID: String?
    /// Each topic's newest send note (queued, refused), shown under that topic's composer
    /// only: a receipt that lands after the reader moved to another topic stays with its own.
    @Published private(set) var sendNotes: [String: String] = [:]

    let target: String
    /// One conversation per topic (`TranscriptStore` keyed per agent and topic), kept while
    /// the page lives, so going back to a topic draws what was loaded at once.
    private var chats: [String: ChatModel] = [:]
    private var refreshing = false
    private var refreshAgain = false
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

    init(target: String) {
        self.target = target
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

    /// Learns whether the agent offers topics (herdrup#758), on `TopicsDiscoveryBackoff`'s
    /// schedule: `topics_unsupported` stops for good; `topics_unreachable` (every omp agent
    /// without topics turned on), a timeout or a dropped connection ask again after 60 s,
    /// doubling to a 10 minute cap. The page restarts this when the agent's status or session
    /// changes and when a guest's share comes back, which starts the schedule over; for the
    /// owner (`eventsPaneID`) an `agent.topics.changed` for the pane does too, at once, even
    /// while a list is still on its way (`TopicsDiscoveryLoop.wake`, herdrup#767).
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
        if refreshing {
            refreshAgain = true
            return
        }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            await refreshOnce(client: client)
        } while refreshAgain
    }

    /// Why the newest list call failed, for discovery; nil after one succeeds.
    private var lastListError: Error?

    private func refreshOnce(client: HerdrClient) async {
        do {
            let list = try await client.agentTopicsList(target: target)
            let ordered = list.ordered
            if ordered != topics { topics = ordered }
            if !offered { offered = true }
            refused = false
            lastListError = nil
            if problem != nil { problem = nil }
        } catch is CancellationError {
            return
        } catch let error as AgentTopicsError {
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
    }

    /// Keeps the list current while Topics is on screen: the owner's `agent.topics.changed`
    /// events for this pane with a slow backstop poll; a guest (`eventsPaneID` nil) polls.
    func follow(client: HerdrClient, eventsPaneID: String?) async {
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
            let seconds = eventsLive ? Self.backstopSeconds : Self.pollSeconds
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
    /// animates it); `deliver` then sends it. Nil when it is too long to send.
    func stage(topicID: String, text: String, author: TranscriptAuthor) -> String? {
        sendNotes[topicID] = nil
        guard text.utf8.count <= Self.maxMessageBytes else {
            sendNotes[topicID] = Self.tooLong
            return nil
        }
        return chatModel(for: topicID).stageOutgoing(text: text, author: author)
    }

    /// Sends a staged message to its topic (`agent.topics.send`); the bubble settles as the
    /// topic's transcript shows it.
    func deliver(client: HerdrClient, topicID: String, outgoingID id: String, text: String) async {
        let chat = chatModel(for: topicID)
        guard await chat.prepareOutgoing(id, client: client) else { return }
        chat.updateOutgoing(id, state: .sending, wireText: text)
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
            }
            sendNotes[topicID] = Self.describe(error)
        } catch is CancellationError {
            chat.updateOutgoing(id, state: .unconfirmed)
            return
        } catch {
            chat.updateOutgoing(id, state: .unconfirmed)
            sendNotes[topicID] = "Couldn't confirm delivery. Check the topic before sending again."
        }
        Task { await chat.refresh(client: client) }
        await refresh(client: client)
    }

    private static let tooLong = "Messages are limited to 32 KB. Send it in parts."

    static func describe(_ error: Error) -> String {
        guard let error = error as? AgentTopicsError else { return "Couldn't reach the agent." }
        switch error {
        case .unreachable: return "Agent not reachable"
        case .timeout: return "The agent didn't answer in time."
        case .rejected(let reason): return reason.isEmpty ? "The agent refused." : "The agent refused: \(reason)"
        case .topicNotFound: return "This topic is gone."
        case .agentNotFound: return "This agent is gone."
        case .unsupported, .notAdvertised: return "This agent has no topics."
        case .other(let api): return api.message
        }
    }
}

// MARK: - Status

/// A topic's status as the list and the chat header draw it: a neutral pill with one small
/// coloured dot, or plain text for a closed topic. Never a coloured card or row.
struct TopicStatusPill: View {
    let topic: AgentTopic

    /// The status as words ("Working", "Closed · 2 queued"), nil for a state this app does not
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

    private var dot: Color? {
        switch topic.state {
        case .starting, .running: return Palette.working
        case .idle: return Palette.done
        case .dead: return Palette.died
        case .closed, .unknown: return nil
        }
    }

    var body: some View {
        if let text = Self.text(for: topic) {
            if let dot {
                HStack(spacing: 5) {
                    Circle().fill(dot).frame(width: 6, height: 6)
                    Text(text).font(Typography.app(11, .medium)).foregroundStyle(Palette.textDim)
                }
                .padding(.horizontal, 8).frame(height: 20)
                .background(Capsule().fill(Palette.surface))
                .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                .fixedSize()
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("topic-status-\(topic.id)")
            } else {
                Text(text).font(Typography.app(11, .medium)).foregroundStyle(Palette.textFaint)
                    .fixedSize()
                    .accessibilityIdentifier("topic-status-\(topic.id)")
            }
        }
    }
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

    var body: some View {
        Group {
            if sizeClass == .regular {
                HStack(spacing: 0) {
                    TopicsList(client: client, model: model, inboxPreview: inboxPreview,
                               highlightsSelection: true, onOpenInbox: onOpenInbox)
                        .frame(width: 340)
                    Rectangle().fill(Palette.hairlineQuiet).frame(width: 1)
                    if let topic = model.topic(model.selectedTopicID) {
                        chat(topic, showsBack: false)
                    } else {
                        Text(model.topics.isEmpty ? "Start a topic to give the agent a new line of work."
                                                  : "Choose a topic.")
                            .font(Typography.app(14)).foregroundStyle(Palette.textDim)
                            .multilineTextAlignment(.center).padding(24)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityIdentifier("topics-placeholder")
                    }
                }
            } else if let topic = model.topic(model.selectedTopicID) {
                chat(topic, showsBack: true)
            } else {
                TopicsList(client: client, model: model, inboxPreview: inboxPreview,
                           highlightsSelection: false, onOpenInbox: onOpenInbox)
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

    @ViewBuilder
    private func chat(_ topic: AgentTopic, showsBack: Bool) -> some View {
        TopicChat(client: client, model: model, chat: model.chatModel(for: topic.id), topic: topic,
                  viewer: viewer, eventsPaneID: eventsPaneID,
                  isActive: isActive && scenePhase.mountsChat, live: live, showsBack: showsBack,
                  onOpenTerminal: onOpenTerminal)
            .id(topic.id)
    }
}

/// The topics column: New topic, search, the Inbox pinned first, then the topics by last
/// activity in day sections, and the closed ones last.
private struct TopicsList: View {
    let client: HerdrClient
    @ObservedObject var model: TopicsModel
    let inboxPreview: String?
    /// iPad: the open topic's row is filled `surfaceRaised`, as the app's sidebars do.
    let highlightsSelection: Bool
    let onOpenInbox: () -> Void

    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var composing = false
    @State private var renaming: AgentTopic?
    @State private var renameTitle = ""
    @State private var actionNote: String?

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
    }

    /// Open topics by day (Today, This week, Earlier), then Closed.
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Topics").font(Typography.app(17, .semibold)).foregroundStyle(Palette.text)
                Spacer(minLength: 0)
                Button { composing = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.pencil").font(.system(size: 14, weight: .semibold))
                        Text("New topic").font(Typography.app(14, .semibold))
                    }
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, 12).frame(height: 34)
                    .background(Capsule().fill(Palette.surface))
                    .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("topics-new")
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
            InlineSearchField(placeholder: "Search topics", text: $search, focus: $searchFocused,
                              identifierPrefix: "topics-search")
                .padding(.horizontal, 16).padding(.bottom, 8)
            if let note = actionNote ?? model.problem {
                HStack(spacing: 6) {
                    Circle().fill(Palette.died).frame(width: 6, height: 6)
                    Text(note).font(Typography.app(12)).foregroundStyle(Palette.textDim).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.bottom, 6)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("topics-problem")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    inboxRow
                    ForEach(lines) { line in
                        switch line {
                        case .heading(let title):
                            Text(title.uppercased())
                                .font(Typography.microLabel).tracking(1)
                                .foregroundStyle(Palette.textFaint)
                                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
                        case .topic(let topic):
                            row(topic)
                        }
                    }
                    if model.loaded && model.topics.isEmpty && model.problem == nil {
                        Text("No topics yet. A topic is a lasting line of work with its own conversation.")
                            .font(Typography.app(13)).foregroundStyle(Palette.textDim)
                            .padding(.horizontal, 16).padding(.top, 16)
                            .accessibilityIdentifier("topics-empty")
                    } else if !search.isEmpty && shown.isEmpty {
                        Text("No topic matches.")
                            .font(Typography.app(13)).foregroundStyle(Palette.textDim)
                            .padding(.horizontal, 16).padding(.top, 16)
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("topics-list")
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

    /// The agent's own conversation, pinned first: it opens the page's Chat view.
    private var inboxRow: some View {
        Button(action: onOpenInbox) {
            HStack(spacing: 12) {
                Image(systemName: "tray")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.text)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Palette.surface))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline, lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Inbox").font(Typography.app(15, .semibold)).foregroundStyle(Palette.text)
                    Text(inboxPreview?.isEmpty == false ? inboxPreview! : "The agent's own conversation")
                        .font(Typography.app(13)).foregroundStyle(Palette.textDim).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textFaint)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("topics-inbox-row")
    }

    private func row(_ topic: AgentTopic) -> some View {
        let selected = highlightsSelection && model.selectedTopicID == topic.id
        return Button {
            model.selectedTopicID = topic.id
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(topic.title.isEmpty ? "Untitled topic" : topic.title)
                        .font(Typography.app(15, .semibold))
                        .foregroundStyle(topic.state == .closed ? Palette.textDim : Palette.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    TopicStatusPill(topic: topic)
                    if topic.activityUnixMs > 0 {
                        Text(GramDates.rowTime(for: Date(timeIntervalSince1970: Double(topic.activityUnixMs) / 1000)))
                            .font(Typography.machine(11)).foregroundStyle(Palette.textFaint)
                            .fixedSize()
                    }
                }
                if let activity = topic.lastActivity, !activity.isEmpty {
                    Text(activity).font(Typography.app(13)).foregroundStyle(Palette.textDim).lineLimit(1)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Palette.surfaceRaised : Color.clear)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.hairlineQuiet).frame(height: 1).padding(.leading, 16)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The title is the row's name; its status and last activity are its value.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(topic.title.isEmpty ? "Untitled topic" : topic.title)
        .accessibilityValue([TopicStatusPill.text(for: topic), topic.lastActivity]
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
    let showsBack: Bool
    let onOpenTerminal: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var keyboard = ComposerKeyboard()
    @State private var reply = ""
    @State private var focused = false
    @State private var dictating = false
    @State private var sending = false
    @State private var sendPresses = 0
    @State private var actionNote: String?

    private var closed: Bool { topic.state == .closed }
    private var canCompose: Bool { live && !closed }
    private var hasContent: Bool { !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var author: TranscriptAuthor {
        if case .guest(let name, _) = viewer { return .guest(name: name) }
        return .owner
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            // The server lists topics but cannot page a topic's conversation (`agent_topics`
            // without `agent_transcript_topic`, or it refused the transcript): say so, and offer
            // no composer that could not show what it sent (herdrup#766).
            if chat.unsupported {
                unavailable
            } else {
                ChatView(client: client, model: chat, viewer: viewer, eventsPaneID: eventsPaneID,
                         isActive: isActive, live: live, agentStatus: topic.state.rawValue,
                         ground: Palette.groundMachine, onOpenTerminal: onOpenTerminal)
                    .equatable()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // This topic's own note only: a late receipt for another topic stays with that one.
                if let note = actionNote ?? model.sendNote(for: topic.id) {
                    Text(note).font(Typography.app(12)).foregroundStyle(Palette.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 4)
                        .accessibilityIdentifier("topic-send-note")
                }
                composer
                    .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 8)
                    .conversationColumn()
            }
        }
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

    private var header: some View {
        HStack(spacing: 10) {
            if showsBack {
                PaneHeaderBackButton(identifier: "topic-back") {
                    focused = false
                    model.selectedTopicID = nil
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(topic.title.isEmpty ? "Untitled topic" : topic.title)
                    .font(Typography.app(15, .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                    .accessibilityIdentifier("topic-chat-title")
                TopicStatusPill(topic: topic)
            }
            Spacer(minLength: 0)
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
                Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.text).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Topic actions")
            .accessibilityIdentifier("topic-actions")
        }
        .padding(.horizontal, showsBack ? 8 : 16).padding(.vertical, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairlineQuiet).frame(height: 1) }
    }

    private var composer: some View {
        AdaptiveComposer(
            text: reply,
            isFocused: focused,
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
            EmptyView()
        } leading: {
            Button { focused = false } label: {
                ComposerActionIcon(image: Image("ComposerKeyboard"))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Collapse keyboard")
        } actions: {
            HStack(spacing: 4) {
                MicButton(text: $reply, isActive: isActive, recording: $dictating)
                    .fixedSize()
                    .disabled(!canCompose || sending)
                ZStack {
                    Button { send() } label: {
                        ComposerActionIcon(image: Image("ComposerSend"), primary: true, busy: sending)
                    }
                    .disabled(!canCompose || sending || dictating || !hasContent)
                    .fixedSize()
                    .accessibilityLabel("Send to topic")
                    .accessibilityIdentifier("topic-send-button")
                }
                .modifier(ChatSendPress(trigger: sendPresses))
            }
            .buttonStyle(.plain)
        }
        .opacity(canCompose ? 1 : 0.45)
        .disabled(!canCompose)
    }

    private func send() {
        guard canCompose, !sending, !dictating, hasContent else { return }
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        // The bubble enters (and the chat follows it) on the send motion; staged now.
        guard let id = withAnimation(ChatSendMotion.bubble(reduceMotion: reduceMotion), {
            model.stage(topicID: topic.id, text: text, author: author)
        }) else { return }
        sending = true
        actionNote = nil
        if ChatSendMotion.acceptSend(reduceMotion: reduceMotion) { sendPresses += 1 }
        ChatSendMotion.clearComposer(inChat: true) { reply = "" }
        Task {
            defer { sending = false }
            await model.deliver(client: client, topicID: topic.id, outgoingID: id, text: text)
        }
    }
}
