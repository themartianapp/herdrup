import HerdrKit
import SwiftUI
import UIKit

/// Who is reading the chat. A guest sees the same conversation without notes or step
/// details (the server leaves them out) and answers omp's questions as the owner does,
/// unless an older host refuses guests that (`ChatModel.answersRefused`).
enum ChatViewer: Equatable {
    case owner
    case guest(name: String, ownerName: String)

    var isGuest: Bool { if case .guest = self { return true } else { return false } }
}

enum ChatStyle {
    /// The answered-question tick and a table's gains: the mockup's `--ok`.
    static let ok = Color(hex: 0x7FC89A)
    /// The readable column: the chat's cap on compact width, and the content sheet's.
    /// On regular width the reader sizes the column (`conversationColumn`).
    static let columnWidth = CGFloat(ConversationColumnWidth.readable)
}

/// Why an answer from the chat did not land, shown under the question.
struct ChatAnswerProblem: Equatable {
    let askID: String
    let message: String
    /// omp's question UI could not be driven from here; the person can still answer it in
    /// the Terminal view by hand.
    let offersTerminal: Bool
}

/// The Chat view's state for SwiftUI: HerdrKit's `TranscriptStore` republished, plus the
/// in-flight answer. Owned by the page (not the `ChatView`), so switching to the Terminal
/// and back keeps what was loaded.
@MainActor
final class ChatModel: ObservableObject {
    @Published private(set) var turns: [TranscriptTurn] = []
    @Published private(set) var working: TranscriptWorking?
    @Published private(set) var outgoing: [TranscriptOutgoingMessage] = []
    @Published private(set) var sessionModel: TranscriptModel?
    @Published private(set) var currentPlan: [TranscriptPlanItem] = []
    /// omp's `task` subagents: running, and finished since the newest prompt.
    @Published private(set) var subagents: [TranscriptSubagent] = []
    @Published private(set) var recap: TranscriptRecap?

    var hasPendingSend: Bool {
        outgoing.contains {
            switch $0.state {
            case .sending, .submitted, .unconfirmed: return true
            case .notDelivered, .previousSession, .notSeen: return false
            }
        }
    }
    @Published private(set) var loaded = false
    @Published private(set) var failure: String?
    @Published private(set) var manualRefreshing = false
    @Published var refreshReceipt: String?
    @Published private(set) var hasOlder = false
    @Published private(set) var loadingOlder = false
    @Published private(set) var olderFailed = false
    @Published private(set) var answeringAskID: String?
    @Published private(set) var answerProblem: ChatAnswerProblem?
    /// The guest's host keeps answers for the owner (a host older than guest answers): it
    /// withheld `answerable` from a question the buttons could answer, or refused a guest's
    /// answer or menu key (`guest_forbidden`). Questions wait for the owner for the session.
    @Published private(set) var answersRefused = false
    /// The server reads and answers omp's HTML-form asks (`ask_form`); nil until its ping answered.
    @Published private(set) var formsSupported: Bool?
    /// The pending forms' answers in progress, by ask id: in memory, for as long as the ask is
    /// pending, so scrolling and reloading the view keep them.
    private var formDrafts: [String: AskFormDraft] = [:]
    /// The server cannot give this agent a transcript (not omp, no session file, an older
    /// server or peer): the page shows the terminal only. Not final: an omp agent answers
    /// `transcript_unsupported` for its first seconds, until its integration reports a
    /// session (#604), so any later answer that is not a refusal clears it again.
    @Published private(set) var unsupported = false
    /// The chat's lines, flattened from `turns` and `outgoing` once per change of either
    /// (not per draw), with each row's position by id.
    fileprivate private(set) var rows: [ChatRow] = []
    fileprivate private(set) var rowIndex: [String: Int] = [:]

    let store: TranscriptStore

    /// `subagent`: the model pages that subagent's own conversation (read-only) instead.
    init(target: String, subagent: String? = nil) {
        store = TranscriptStore(target: target, subagent: subagent)
        store.onChange = { [weak self] in self?.sync() }
    }

    var target: String { store.target }

    func stageOutgoing(text: String, author: TranscriptAuthor, files: [ComposerAttachment] = []) -> String {
        stagedAt = CACurrentMediaTime()
        let id = store.stageOutgoing(text: text, author: author, files: files.map {
            TranscriptAttachment(id: $0.id.uuidString, name: $0.name, isImage: $0.isImage, messageID: $0.messageID)
        })
        followSend()
        return id
    }

    /// When the newest send was staged (`CACurrentMediaTime`). Not published: only the
    /// tail follow reads it, per frame.
    private var stagedAt = -CFTimeInterval.infinity
    /// A send was staged moments ago: the tail follow glides with its bubble
    /// (`ChatSendMotion.scrollGlideWindow`).
    var sendIsLanding: Bool { CACurrentMediaTime() - stagedAt < ChatSendMotion.scrollGlideWindow }

    func prepareOutgoing(_ id: String, client: HerdrClient) async -> Bool {
        await store.prepareOutgoing(id, client: client)
    }

    func updateOutgoing(_ id: String?, state: TranscriptSendState, wireText: String? = nil) {
        guard let id else { return }
        store.updateOutgoing(id, state: state, wireText: wireText)
        followSend()
    }

    /// The poll's interval while a send waits to show up in the transcript.
    static let fastPollSeconds: UInt64 = 3
    /// Until when a pending send keeps the poll fast: the minute before an unmatched send
    /// is demoted, plus the poll that demotes it.
    private var fastPollUntil = Date.distantPast
    /// The poll's current sleep; a staged or updated send cancels it to poll sooner.
    private var pollWait: Task<Void, Never>?

    private func followSend() {
        fastPollUntil = Date().addingTimeInterval(TranscriptOutbox.unseenAfter + TimeInterval(Self.fastPollSeconds))
        pollWait?.cancel()
    }

    func refresh(client: HerdrClient) async {
        await store.refresh(client: client)
    }

    func manualRefresh(client: HerdrClient) async {
        guard !manualRefreshing else { return }
        manualRefreshing = true
        refreshReceipt = nil
        await store.refresh(client: client)
        manualRefreshing = false
        refreshReceipt = failure.map { "Refresh failed: \($0)" } ?? "Up to date"
    }

    func loadOlder(client: HerdrClient) async {
        olderFailed = false
        do {
            try await store.loadOlder(client: client)
        } catch {
            olderFailed = true
        }
    }

    /// Answers omp's open question with one of its options. The card shows the choice at
    /// once; a refusal puts the buttons back with the reason.
    func answer(client: HerdrClient, askID: String, option: String) async {
        guard answeringAskID == nil, store.subagent == nil else { return }
        answeringAskID = askID
        answerProblem = nil
        defer { answeringAskID = nil }
        do {
            _ = try await client.agentAnswer(target: target, askID: askID, option: option)
            store.noteAnswered(askID: askID, option: option)
        } catch let error as APIError {
            switch error.code {
            case "ask_not_pending":
                // Answered elsewhere (the terminal, the lock screen): the refresh shows it.
                break
            case "guest_forbidden":
                // An older host that keeps answers for the owner: wait for them, as before.
                answersRefused = true
            case "selection_mismatch":
                answerProblem = ChatAnswerProblem(
                    askID: askID, message: "omp's options changed. Check the question in the Terminal.",
                    offersTerminal: true)
            default:
                answerProblem = ChatAnswerProblem(
                    askID: askID,
                    message: error.asksForTerminalAnswer
                        ? "This question can't be answered from the chat."
                        : "Couldn't answer: \(error.message)",
                    offersTerminal: error.asksForTerminalAnswer)
            }
        } catch is CancellationError {
            return
        } catch {
            answerProblem = ChatAnswerProblem(askID: askID, message: "Couldn't reach the agent. Try again.",
                                              offersTerminal: false)
        }
        await store.refresh(client: client)
    }

    /// The draft for a pending form ask, made on first use.
    func formDraft(askID: String, form: AskForm) -> AskFormDraft {
        if let draft = formDrafts[askID], draft.form == form { return draft }
        let draft = AskFormDraft(form: form)
        formDrafts[askID] = draft
        return draft
    }

    func probeFormSupport(client: HerdrClient) async {
        let supported = await client.advertisesAskForm()
        if formsSupported != supported { formsSupported = supported }
    }

    /// Answers omp's pending form with the fields the person changed (`agent.answer_form`).
    /// The card shows the answers at once; a refusal keeps the draft, on the refused field's
    /// step when herdr names one.
    func answerForm(client: HerdrClient, askID: String, draft: AskFormDraft) async {
        guard answeringAskID == nil, store.subagent == nil else { return }
        answeringAskID = askID
        answerProblem = nil
        draft.errors = [:]
        defer { answeringAskID = nil }
        do {
            let result = try await client.agentAnswerForm(target: target, askID: askID, values: draft.values)
            switch result.status {
            case .answered:
                store.noteFormAnswered(askID: askID, answers: result.answers.isEmpty ? draft.localAnswers : result.answers)
            case .sentUnconfirmed:
                store.noteFormAnswered(askID: askID, answers: draft.localAnswers, confirmed: false)
            }
            formDrafts[askID] = nil
        } catch let error as AgentAnswerFormError {
            switch error {
            case .notPending:
                // Answered elsewhere (the terminal, the lock screen): the refresh shows it.
                break
            case .invalid(let field, let reason):
                let onItsStep = draft.reject(field: field, reason: reason)
                if error.asksForTerminalAnswer {
                    // A value only the Terminal can enter: the step says why, and offers it.
                    answerProblem = ChatAnswerProblem(askID: askID, message: "This answer can't be sent from the chat.",
                                                      offersTerminal: true)
                } else if !onItsStep {
                    // The text before ": " named no field of this form: herdr's whole message.
                    let message = field.map { "\($0): \(reason)" } ?? reason
                    answerProblem = ChatAnswerProblem(askID: askID, message: "Couldn't answer: \(message)",
                                                      offersTerminal: false)
                }
            case .moved:
                answerProblem = ChatAnswerProblem(
                    askID: askID, message: "The form changed in the Terminal. Finish it there.", offersTerminal: true)
            case .unsupported:
                answerProblem = ChatAnswerProblem(
                    askID: askID, message: "This form can't be answered from the chat.", offersTerminal: true)
            case .refused(let refusal):
                if refusal.code == "guest_forbidden" {
                    answersRefused = true
                } else {
                    answerProblem = ChatAnswerProblem(askID: askID, message: "Couldn't answer: \(refusal.message)",
                                                      offersTerminal: false)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            answerProblem = ChatAnswerProblem(askID: askID, message: "Couldn't reach the agent. Try again.",
                                              offersTerminal: false)
        }
        await store.refresh(client: client)
    }

    /// A guest's host refused a guest's menu key: stop offering guest answers this session.
    func noteAnswersRefused() {
        answersRefused = true
    }

    /// Keeps the chat current while it is on screen: the agent's own events where the
    /// server sends them (owner), a 3 s poll while a send waits to show up in the
    /// transcript or while omp works, and a slow poll otherwise as a backstop for a missed
    /// event (and for guests, who have no event stream).
    func follow(client: HerdrClient, paneID: String?) async {
        await store.refresh(client: client)
        await withTaskGroup(of: Void.self) { group in
            if let paneID {
                group.addTask { await self.followEvents(client: client, paneID: paneID) }
            }
            group.addTask { await self.poll(client: client) }
        }
    }

    private func poll(client: HerdrClient) async {
        while !Task.isCancelled {
            let woken = await waitForPoll()
            guard !Task.isCancelled else { return }
            // A send woke the sleep: start over at the send's faster interval.
            if woken { continue }
            await store.refresh(client: client)
        }
    }

    /// Sleeps until the next poll is due. True when a staged or updated send cut it short.
    private func waitForPoll() async -> Bool {
        let seconds: UInt64
        if hasPendingSend && Date() < fastPollUntil {
            seconds = Self.fastPollSeconds
        } else {
            seconds = store.isWorking ? 3 : 30
        }
        let wait = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            return
        }
        pollWait = wait
        await withTaskCancellationHandler {
            await wait.value
        } onCancel: {
            wait.cancel()
        }
        if pollWait == wait { pollWait = nil }
        return wait.isCancelled
    }

    private func followEvents(client: HerdrClient, paneID: String) async {
        let subscriptions = [Subscription(.paneAgentStatusChanged, paneID: paneID),
                             Subscription(.paneTurnCompleted, paneID: paneID)]
        while !Task.isCancelled {
            do {
                for try await line in client.subscribe(subscriptions) {
                    if case .event = line { await store.refresh(client: client) }
                }
            } catch is APIError {
                return   // the server refuses the subscription: polling alone keeps up
            } catch {}
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    /// Republishes the store. Each value is assigned only when it changed: an equal
    /// assignment still sends `objectWillChange`, which redraws the whole chat.
    private func sync() {
        let turnsChanged = store.turns != turns
        let outgoingChanged = store.outbox.messages != outgoing
        if turnsChanged { turns = store.turns }
        if outgoingChanged { outgoing = store.outbox.messages }
        if turnsChanged || outgoingChanged {
            rows = ChatRow.rows(turns: turns, outgoing: outgoing)
            rowIndex = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        assign(\.working, store.working)
        assign(\.sessionModel, store.model)
        assign(\.currentPlan, store.currentPlan)
        assign(\.subagents, store.subagents)
        assign(\.recap, store.recap)
        assign(\.hasOlder, store.hasOlder)
        assign(\.loadingOlder, store.loadingOlder)
        assign(\.loaded, store.loaded)
        // Only a guest of a host older than guest answers is ever withheld an answerable question.
        if store.pendingAsk?.isWithheldFromCaller == true { assign(\.answersRefused, true) }
        if let error = store.lastError as? AgentTranscriptError {
            switch error {
            case .unsupported: assign(\.unsupported, true)
            case .agentNotFound:
                assign(\.unsupported, false)
                assign(\.failure, "This agent is gone.")
            case .unavailable:
                assign(\.unsupported, false)
                assign(\.failure, "omp's session file can't be read right now.")
            case .cursorExpired:
                assign(\.unsupported, false)
                assign(\.failure, nil)
            case .subagentNotFound:
                assign(\.unsupported, false)
                assign(\.failure, "This subagent's conversation can't be found.")
            }
        } else if let error = store.lastError {
            // A guest whose host refuses the method for guests: the Chat tab goes away.
            let code = (error as? APIError)?.code
            if code == "forbidden" || code == "guest_forbidden" {
                assign(\.unsupported, true)
                assign(\.failure, nil)
            } else {
                assign(\.failure, "Couldn't load the chat.")
            }
        } else {
            assign(\.unsupported, false)
            assign(\.failure, nil)
        }
    }

    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<ChatModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}

/// A turn's prompt as its row draws it: only what the bubble shows, so comparing rows
/// does not compare the turn's whole work.
private struct ChatPrompt: Equatable {
    /// The turn's id.
    let id: String
    let text: String
    let author: TranscriptAuthor?
    let attachment: GramAttachmentPrompt.Parsed?
}

/// One line of the chat list, flattened from the turns so every row scrolls by id.
/// Built once per change of the transcript (`ChatModel.rows`); an unchanged entry gives an
/// equal row with the same id, so its view is not redrawn.
private enum ChatRow: Identifiable, Equatable {
    case day(id: String, ms: UInt64)
    case prompt(ChatPrompt)
    case item(TranscriptItem)
    case outgoing(TranscriptOutgoingMessage)

    var id: String {
        switch self {
        case .day(let id, _): return "day:" + id
        case .prompt(let prompt): return "prompt:" + prompt.id
        case .item(let item): return "item:" + item.id
        case .outgoing(let message): return "outgoing:" + message.id
        }
    }

    static func rows(turns: [TranscriptTurn], outgoing: [TranscriptOutgoingMessage]) -> [ChatRow] {
        var rows: [ChatRow] = []
        var previousMs: UInt64?
        for turn in turns {
            if turn.prompt != nil, turn.startMs > 0 {
                if ChatDay.needsSeparator(previousMs: previousMs, ms: turn.startMs) {
                    rows.append(.day(id: turn.id, ms: turn.startMs))
                }
                previousMs = turn.startMs
                rows.append(.prompt(ChatPrompt(id: turn.id, text: turn.promptText ?? "", author: turn.promptAuthor,
                                               attachment: turn.attachmentPrompt)))
            }
            for item in turn.items { rows.append(.item(item)) }
        }
        rows.append(contentsOf: outgoing.map(ChatRow.outgoing))
        return rows
    }

    var askID: String? {
        if case .item(.ask(let id, _, _)) = self { return id }
        return nil
    }

    /// The turn whose prompt this row draws.
    var promptTurnID: String? {
        if case .prompt(let prompt) = self { return prompt.id }
        return nil
    }

    /// The row's searchable text before markdown is stripped (`plainSearchText`).
    var searchSource: String {
        switch self {
        case .day: return ""
        case .prompt(let prompt):
            if let bundle = prompt.attachment {
                return ([bundle.caption] + bundle.files.map(\.name)).joined(separator: "\n")
            }
            return prompt.text
        case .outgoing(let message):
            return ([message.text] + message.files.map(\.name)).joined(separator: "\n")
        case .item(let item):
            switch item {
            case .work(let work):
                return (work.thoughts + work.steps.map { $0.intent + "\n" + ($0.detail ?? "") }).joined(separator: "\n")
            case .reply(_, let reply, _), .summary(_, let reply): return reply
            case .note(_, _, let note): return note.title + "\n" + note.body
            case .plan(_, let items):
                return items.map { [$0.phase, $0.text].compactMap { $0 }.joined(separator: "\n") }.joined(separator: "\n")
            case .ask(_, let ask, _):
                var lines = ask.questions.flatMap { [$0.question] + $0.options } + (ask.answer ?? [])
                if let form = ask.form {
                    lines = [form.intro].compactMap { $0 } + form.fields.flatMap { field in
                        [field.title, field.description].compactMap { $0 } + field.options.map(\.label)
                    } + (ask.formAnswer?.map(\.answer) ?? [])
                }
                return lines.joined(separator: "\n")
            case .turnFailed(_, _, let error): return error ?? ""
            }
        }
    }

    /// What search reads of a row: its text as rendered, without markdown syntax.
    static func plainSearchText(_ source: String) -> String {
        guard !source.isEmpty else { return "" }
        let parsed = try? AttributedString(markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return parsed.map { String($0.characters) } ?? source
    }
}

/// Each row's plain search text, kept between searches: parsing every row's markdown on
/// every keystroke and refresh is what froze long chats (herdrup#523). A row is parsed
/// again only when its content changes.
private final class ChatSearchTextCache {
    private var entries: [String: (source: String, text: String)] = [:]

    func row(for row: ChatRow) -> TranscriptSearchRow {
        let source = row.searchSource
        if let entry = entries[row.id], entry.source == source {
            return TranscriptSearchRow(id: row.id, text: entry.text)
        }
        let text = ChatRow.plainSearchText(source)
        entries[row.id] = (source, text)
        return TranscriptSearchRow(id: row.id, text: text)
    }
}

/// Where the drawn prompts are against the top of the screen, for the up arrow (owner decision
/// 2026-11-06). Rows write it as they cross the top; reading it redraws nothing.
private final class ChatPromptTops {
    /// Turn id → its prompt's top is above the viewport. Only drawn rows report.
    var above: [String: Bool] = [:]
    /// The turn the up arrow last scrolled to, so a tap before the scroll has settled still
    /// goes one further up. Valid only while the chat stays at the offset the jump left it at
    /// (`TranscriptPreviousMine.LastJump`): a drag, search, Jump to latest or any other move
    /// retires it.
    var lastJump: TranscriptPreviousMine.LastJump?
    /// Bumped per jump, so a superseded jump's settle does not record its offset.
    var jumpGeneration = 0
    /// The latest jump from the moment it was issued (`TranscriptPreviousMine.Settle`).
    var settle = TranscriptPreviousMine.Settle()
    /// A deceleration was already under way when the latest jump was issued: that one is the
    /// momentum of a drag from before the tap, and only a deceleration that starts later is
    /// the reader taking the jump over.
    var deceleratingAtIssue = false
    /// Bumped when search opens or closes. An up-arrow search reads it after every wait (an
    /// older page, the top already fetching one): the view value it captured still has no
    /// search, so this is how it learns search took over and gives up (review 18e58fbbc4ef6e41).
    var navigation = 0

    /// The reader moved the chat (a drag, a deceleration they started, a wheel or trackpad
    /// scroll): the up arrow searches from where they are now, and a pending jump stops,
    /// whatever moment of it this is (review of #649, F1).
    func readerInput() {
        guard lastJump != nil else { return }
        settle.readerInput()
        lastJump = nil
    }
}

/// A form's review asked to be shown from its top (`AskFormStepper`). Each layout of the card
/// while the review is open puts its top back in view if it went above the screen, until the
/// reader moves the chat (a drag, a deceleration, a wheel or trackpad scroll) or navigates it
/// (search, Jump to latest, the up arrow, Submit). Kept by reference: setting it redraws nothing.
private final class ChatFormReveal {
    var pending = false
}

/// Reports whether a prompt row's top is above the chat's viewport (`space`), when the row is
/// a prompt the up arrow may need; any other row is left as it is. Reports only crossings,
/// like the top sentinel, so scrolling does not redraw the chat.
private struct ChatPromptTopProbe: ViewModifier {
    let turnID: String?
    let space: String
    let report: (String, Bool) -> Void

    func body(content: Content) -> some View {
        if let turnID {
            content.onGeometryChange(for: Bool.self) { proxy in
                proxy.frame(in: .named(space)).minY < -1
            } action: { above in
                report(turnID, above)
            }
        } else {
            content
        }
    }
}

/// What a search result answers: the query and the transcript it searched.
private struct ChatSearchKey: Equatable {
    let query: String
    let turns: [TranscriptTurn]
    let outgoing: [TranscriptOutgoingMessage]

    static let none = ChatSearchKey(query: "", turns: [], outgoing: [])
}

/// Which rows the chat draws (`ChatView.drawWindow`).
private enum ChatWindow: Equatable {
    /// The newest `ChatView.renderWindow` rows: until the chat lands, and after a reload
    /// that dropped the window's top row.
    case newest
    /// From this row (never a day label) down to the tail.
    case from(String)
}

/// The omp Chat view: the conversation read from omp's session file, newest at the bottom,
/// older turns loading as the reader scrolls up (Gram's pattern). Owner and guest share it.
struct ChatView: View {
    let client: HerdrClient
    @ObservedObject var model: ChatModel
    let viewer: ChatViewer
    /// The pane id to follow events for (owner); nil for a guest, who polls.
    let eventsPaneID: String?
    /// The chat is the front, visible view: it loads the conversation (and older pages)
    /// whenever it is, live or not.
    let isActive: Bool
    /// The agent can change the conversation (an owner's agent, a guest's running share):
    /// the chat keeps itself current by events and polling. Otherwise (a paused share) it
    /// loads what the session file holds once, as it comes on screen.
    let live: Bool
    /// The agent's status as the page knows it: a change prompts a refresh.
    let agentStatus: String?
    /// The page's ground, for the top fade.
    let ground: Color
    let onOpenTerminal: () -> Void
    var findRequest: FindRequest? = nil
    /// `(index, total, capped)`: `capped` when the matches stop at `TranscriptSearch.matchCap`.
    var onFindResult: (Int, Int, Bool) -> Void = { _, _, _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ChatTextSize.storageKey) private var chatFontSize = ChatTextSize.defaultPoints
    private var textScale: CGFloat { CGFloat(chatFontSize / ChatTextSize.defaultPoints) }
    @State private var expanded: Set<String> = []
    @State private var openNote: TranscriptNote?
    @State private var atBottom = true
    @State private var followingLatest = true
    @State private var userScrolling = false
    @State private var scrollPosition = ChatScrollPosition()
    /// Where the selected search result sits, reported by its row (`ChatSearchResults`).
    @State private var searchReveal = ChatSearchReveal()
    /// The first scroll to the newest turn has landed: until then the top of the list is
    /// on screen for a moment and must not fetch older pages.
    @State private var landed = false
    /// The top of the list is within reach (40 pt) of the viewport's top.
    @State private var topVisible = false
    @State private var selectedSearchHit: String?
    /// The hits for `searchKey`, kept until the term or the transcript changes.
    @State private var searchResult = TranscriptSearchResult.empty
    @State private var searchKey = ChatSearchKey.none
    @State private var searchTexts = ChatSearchTextCache()
    @State private var openQuestionID: String?
    /// The message whose Select Text sheet is open.
    @State private var selectingText: ChatSelectableText?
    /// The subagent whose conversation is open (owner only).
    @State private var openSubagent: TranscriptSubagent?
    /// Which drawn prompts sit above the viewport, as their rows report it (the up arrow).
    @State private var promptTops = ChatPromptTops()
    /// A form's review waiting to be shown from its top (`revealFormTop`).
    @State private var formReveal = ChatFormReveal()
    /// The oldest drawn prompt on screen or below it: the up arrow searches above this turn.
    /// Nil while every drawn prompt is above the screen.
    @State private var mineBoundary: String?
    /// The up arrow is loading older pages to find the owner's previous message.
    @State private var findingPreviousMine = false
    /// The host keeps turn origins (`turn_origin`): the up arrow skips turns marked "other".
    @State private var honoursTurnOrigin = false

    /// Which rows are drawn (`drawnStart`): the newest `renderWindow` until the chat lands,
    /// then from a fixed row down, so rows arriving at the tail never push out the top of
    /// what the reader sees. Reaching the top reveals another window before any fetch.
    @State private var drawWindow = ChatWindow.newest

    /// Rows drawn at first and revealed per arrival at the top: a few screens, cheap to lay
    /// out. Every loaded row stays searchable; a hit above the window widens it.
    static var renderWindow: Int {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["HERDR_CHAT_RENDER_WINDOW"].flatMap(Int.init),
           override > 0 { return override }
        #endif
        return 40
    }

    /// How long typing must pause before the term is searched.
    private static let typingPause: Duration = .milliseconds(180)
    /// Result excerpts drawn on each side of the selected match.
    private static let renderedSearchNeighbours = 10

    /// What the search should answer now. Without a term the transcript is left out, so
    /// refreshes while the find bar is closed start no search work.
    private var liveSearchKey: ChatSearchKey {
        let query = findRequest?.term ?? ""
        return query.isEmpty ? .none : ChatSearchKey(query: query, turns: model.turns, outgoing: model.outgoing)
    }

    /// The hits whose excerpts are drawn: the selected match, its neighbours, and the first
    /// and last (where Next and Previous wrap to), so a one-letter term does not lay out
    /// hundreds of results at once.
    private var renderedSearchHits: [TranscriptSearchHit] {
        let hits = searchResult.hits
        guard !(findRequest?.term ?? "").isEmpty, !hits.isEmpty else { return [] }
        let selected = hits.firstIndex { $0.id == selectedSearchHit } ?? 0
        let lower = max(0, selected - Self.renderedSearchNeighbours)
        let upper = min(hits.count, selected + Self.renderedSearchNeighbours + 1)
        var shown = Array(hits[lower..<upper])
        if lower > 0 { shown.insert(hits[0], at: 0) }
        if upper < hits.count { shown.append(hits[hits.count - 1]) }
        return shown
    }

    /// Brings the hits up to date with the term and the transcript (searching again only
    /// when one of them changed), then selects a match and reports the count.
    private func updateSearch(_ proxy: ScrollViewProxy, step: Bool = false, reveal: Bool = false) {
        let key = liveSearchKey
        if key != searchKey {
            if key.query != searchKey.query { selectedSearchHit = nil }
            searchKey = key
            searchResult = key.query.isEmpty ? .empty
                : TranscriptSearch.search(model.rows.lazy.map { searchTexts.row(for: $0) }, query: key.query)
        }
        let hits = searchResult.hits
        guard !hits.isEmpty else {
            selectedSearchHit = nil
            onFindResult(0, 0, false)
            return
        }
        let current = hits.firstIndex { $0.id == selectedSearchHit }
        let index: Int
        if step, let current {
            index = (current + (findRequest?.direction == .backward ? hits.count - 1 : 1)) % hits.count
        } else {
            index = current ?? 0
        }
        let hit = hits[index]
        let moved = selectedSearchHit != hit.id
        selectedSearchHit = hit.id
        onFindResult(index + 1, hits.count, searchResult.capped)
        atBottom = false
        followingLatest = false
        var widened = false
        if let position = model.rowIndex[hit.rowID] {
            if position < drawnStart {
                drawWindow = windowStarting(at: position)
                widened = true
            }
            if case .item(.work(let work)) = model.rows[position] {
                expanded.insert("t:" + work.id)
                expanded.insert("s:" + work.id)
                for item in work.steps { expanded.insert("d:" + item.id) }
            }
        }
        guard moved || step || reveal || widened else { return }
        Task { @MainActor in
            await Task.yield()
            // Rows just drawn above the window are laid out before the scroll can find them.
            if widened { try? await Task.sleep(nanoseconds: 30_000_000) }
            // Centre the result by moving the scroll view itself: on iOS 27 `scrollTo` on the
            // result's id, inside its row, leaves the chat where it was. The result reports
            // its frame once laid out; a second pass corrects a frame taken before rows above
            // it (a widened window, an older page) had settled.
            var revealed = false
            for _ in 0..<12 {
                guard selectedSearchHit == hit.id, findRequest != nil else { return }
                if let frame = searchReveal.frame(of: hit.id), scrollPosition.reveal(frame) {
                    if revealed { return }
                    revealed = true
                    try? await Task.sleep(nanoseconds: 120_000_000)
                } else {
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
            }
            guard !revealed, selectedSearchHit == hit.id, findRequest != nil else { return }
            proxy.scrollTo("search:" + hit.id, anchor: .center)
        }
    }

    private static let scrollSpace = "chat-scroll"

    var body: some View {
        let hits = renderedSearchHits
        ScrollViewReader { proxy in
            transcriptScroll(proxy, hits: hits)
        }
        .overlay(alignment: .topLeading) { copyProbe }
        .background(ground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-view")
        .accessibilityValue("turns=\(model.turns.count)")
        .overlay(alignment: .top) { refreshStatus }
        .task(id: [isActive, live]) {
            guard isActive else { return }
            if live {
                await model.follow(client: client, paneID: eventsPaneID)
            } else {
                await model.refresh(client: client)
            }
        }
        .onChange(of: agentStatus) { _, _ in
            guard isActive else { return }
            Task { await model.refresh(client: client) }
        }
        .task(id: offersPreviousMine) {
            guard offersPreviousMine else { return }
            honoursTurnOrigin = await client.advertisesTurnOrigin()
        }
        .task(id: isActive) {
            guard isActive else { return }
            await model.probeFormSupport(client: client)
        }
        // Search moves the chat on its own: the up arrow then starts from what is on screen.
        // (The offset check retires a settled jump anyway; this also covers one still gliding.)
        .onChange(of: findRequest != nil) { _, _ in
            promptTops.lastJump = nil
            promptTops.navigation += 1
            formReveal.pending = false
        }
        .sheet(item: Binding(get: { openNote.map(IdentifiedNote.init) }, set: { openNote = $0?.note })) { item in
            ChatNoteSheet(note: item.note)
        }
        .sheet(isPresented: Binding(get: { openQuestionID != nil }, set: { if !$0 { openQuestionID = nil } })) {
            questionSheet
        }
        .sheet(item: $selectingText) { item in
            ChatSelectTextSheet(text: item.text)
        }
        .sheet(item: $openSubagent) { subagent in
            ChatSubagentSheet(client: client, target: model.target, subagent: subagent)
        }
        .environment(\.chatTextScale, textScale)
        .environment(\.chatSearchQuery, findRequest?.term ?? "")
        .environment(\.chatSearchReveal, searchReveal)
    }

    private func transcriptScroll(_ proxy: ScrollViewProxy, hits: [TranscriptSearchHit]) -> some View {
        ScrollView {
            transcriptColumn(proxy, hits: hits)
        }
        .coordinateSpace(name: Self.scrollSpace)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top, spacing: 0) {
            if findRequest != nil {
                searchScope(proxy).padding(.horizontal, 16).padding(.vertical, 8).background(ground)
            }
        }
        .overlay(alignment: .top) {
            LinearGradient(colors: [ground, ground.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 26)
                .allowsHitTesting(false)
        }
        // Fades rows into the composer only while there are rows under it: at the tail the
        // last line sits clear of the composer, with nothing to fade.
        .overlay(alignment: .bottom) {
            if !atBottom { ChatComposerFade(ground: ground) }
        }
        .overlay(alignment: .bottom) {
            if landed, findRequest == nil, !atBottom {
                JumpToLatestButton(label: "Jump to latest message", identifier: "chat-jump-latest") {
                    promptTops.lastJump = nil
                    formReveal.pending = false
                    scrollPosition.animateToLatest()
                    followingLatest = true
                }
                .padding(.bottom, 16)
            }
        }
        .overlay {
            if !model.loaded {
                ProgressView().tint(Palette.textDim).accessibilityIdentifier("chat-loading")
            } else if model.rows.isEmpty, model.failure == nil {
                Text("No messages yet").font(Typography.app(14 * textScale)).foregroundStyle(Palette.textFaint)
            }
        }
        // The resizer's width is the chat's whole width: the most the column can take.
        .conversationColumnResizer(.chat)
        // The up arrow sits in the bottom-right corner, clear of the reading column (owner chose
        // proposal C, 2026-11-07): a 40 pt circle whose right edge lines up with the composer's,
        // 12 pt above it. Its 44 pt tap box is 2 pt larger each side, hence 11 and 5. In the
        // composer's column (no readable cap, as there), so it stays over the composer on a
        // narrowed iPad column; and over the resizer, whose 44 pt edge band it overlaps, so a tap
        // on the arrow jumps rather than starting a resize (review 18e5a606c8b8d005 F1).
        .overlay(alignment: .bottom) {
            if landed, findRequest == nil, showsPreviousMine {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    JumpToLatestButton(label: "Jump to my previous message", identifier: "chat-jump-previous-mine",
                                       systemImage: "arrow.up", busy: findingPreviousMine, diameter: 40) {
                        jumpToPreviousMine(proxy)
                    }
                }
                .padding(.trailing, 11)
                .padding(.bottom, 5)
                .conversationColumn()
            }
        }
        .task(id: model.loaded) {
            guard model.loaded, !landed, findRequest == nil else { return }
            for _ in 0..<8 {
                scrollPosition.jumpToLatest()
                try? await Task.sleep(nanoseconds: 60_000_000)
                if scrollPosition.isAtBottom { break }
            }
            landed = true
            drawWindow = windowStarting(at: drawnStart)
        }
        // One search update per change: a new term (once typing pauses), a step (Next or
        // Previous), or a new transcript under the same term.
        .task(id: findRequest?.term ?? "") {
            guard liveSearchKey != searchKey else { return }
            if !(findRequest?.term ?? "").isEmpty {
                do { try await Task.sleep(for: Self.typingPause) } catch { return }
                guard liveSearchKey != searchKey else { return }
            }
            updateSearch(proxy)
        }
        .onChange(of: findRequest) { old, new in
            guard old?.term == new?.term, old?.generation != new?.generation else { return }
            updateSearch(proxy, step: true)
        }
        .onChange(of: liveSearchKey) { old, new in
            guard old.query == new.query else { return }
            updateSearch(proxy)
        }
    }

    /// A send's new bubble enters on `ChatSendMotion`; every other row keeps SwiftUI's
    /// default fade (and is not animated at all unless its change is).
    private func rowTransition(_ row: ChatRow) -> AnyTransition {
        guard case .outgoing = row else { return .opacity }
        return ChatSendMotion.bubbleTransition(reduceMotion: reduceMotion)
    }

    private func transcriptColumn(_ proxy: ScrollViewProxy, hits: [TranscriptSearchHit]) -> some View {
        let hitsByRow = Dictionary(grouping: hits, by: \.rowID)
        let actions = rowActions
        let probesPrompts = offersPreviousMine
        return VStack(alignment: .leading, spacing: 10) {
            topSentinel(proxy)
            ForEach(model.rows[drawnStart...]) { row in
                chatRow(row, hits: hitsByRow[row.id] ?? [], actions: actions)
                    .equatable()
                    .modifier(ChatPromptTopProbe(turnID: probesPrompts ? row.promptTurnID : nil,
                                                 space: Self.scrollSpace) { id, above in
                        promptTopChanged(id, above: above)
                    })
                    .id(row.id)
                    .transition(rowTransition(row))
            }
            sessionFooter
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        // The column is exactly the chosen width (or the chat's, if narrower) whatever its
        // rows, and the composer under it lines up. Laid out by the shared column, which reads
        // the width itself: a drag never re-runs this body, so it never re-renders the rows.
        // UI tests measure it as `chat-column`.
        .conversationColumn(cap: ChatStyle.columnWidth, probe: "chat-column")
        .background {
            ScrollActivityObserver(isEnabled: isActive, onChange: { scrolling in
                // A tap tracks too. Only an actual drag/deceleration may cancel
                // follow intent; otherwise the jump button cancels its own request.
                guard !scrolling, userScrolling else { return }
                userScrolling = false
                followingLatest = scrollPosition.isAtBottom && findRequest == nil
            }, onSample: { view in
                scrollPosition.view = view
                if view.isDragging || view.isDecelerating {
                    if !userScrolling { userScrolling = true }
                    if followingLatest { followingLatest = false }
                }
                // The reader moved the chat: the up arrow searches from where they are now,
                // and a form's review stays where they put it.
                if !view.isDecelerating { promptTops.deceleratingAtIssue = false }
                if view.isDragging || view.isDecelerating { formReveal.pending = false }
                if view.isDragging || (view.isDecelerating && !promptTops.deceleratingAtIssue) {
                    promptTops.readerInput()
                }
                if followingLatest, model.loaded, findRequest == nil,
                   !view.isTracking, !view.isDragging, !view.isDecelerating {
                    // Just after a send the tail springs with the new bubble; otherwise it jumps.
                    if model.sendIsLanding, ChatSendMotion.scrollGlides(reduceMotion: reduceMotion) {
                        scrollPosition.glideToLatest()
                    } else {
                        scrollPosition.jumpToLatest()
                    }
                }
                let bottom = scrollPosition.isAtBottom
                if atBottom != bottom { atBottom = bottom }
            }, onScrollInput: {
                // A Mac wheel or trackpad: none of the flags above (see `onScrollInput`).
                promptTops.readerInput()
                formReveal.pending = false
            })
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder private func searchScope(_ proxy: ScrollViewProxy) -> some View {
        if findRequest != nil {
            HStack {
                Text("Searching loaded history").font(Typography.app(12 * textScale))
                Spacer()
                if model.hasOlder {
                    Button("Load older") {
                        Task {
                            await model.loadOlder(client: client)
                            updateSearch(proxy, reveal: true)
                        }
                    }
                    .disabled(model.loadingOlder)
                }
            }
            .accessibilityIdentifier("chat-search-scope")
        }
    }

    @ViewBuilder private var sessionFooter: some View {
        if !model.currentPlan.isEmpty { planCard(model.currentPlan) }
        if !model.subagents.isEmpty { subagentsCard(model.subagents) }
        if live, model.failure == nil,
           agentStatus == "working" || (agentStatus == nil && model.working != nil) {
            ChatWorkingDots(intent: model.working?.intent)
        }
        recapDivider
        if let sessionModel = model.sessionModel {
            Text(sessionModel.label)
                .font(Typography.machine(11.5 * textScale))
                .foregroundStyle(Palette.textFaint)
                .padding(.leading, 4).padding(.vertical, 4)
                .accessibilityLabel(sessionModel.accessibilityLabel)
                .accessibilityIdentifier("chat-model")
        }
        if let failure = model.failure {
            Text(failure).font(Typography.app(13 * textScale)).foregroundStyle(Palette.textFaint)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("chat-failure")
        }
    }

    @ViewBuilder private var recapDivider: some View {
        if let recap = model.recap, model.working == nil,
           agentStatus != "working", !model.hasPendingSend {
            VStack(alignment: .leading, spacing: 8) {
                Rectangle().fill(Palette.hairline).frame(height: 1).accessibilityHidden(true)
                Text(ChatInline.styled(recap.text, size: 13 * textScale))
                    .foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat-recap")
        }
    }

    @ViewBuilder private var refreshStatus: some View {
        if model.manualRefreshing || model.refreshReceipt != nil {
            HStack(spacing: 10) {
                if model.manualRefreshing { ProgressView().controlSize(.small) }
                Text(model.manualRefreshing ? "Refreshing chat…" : model.refreshReceipt ?? "")
                    .font(Typography.app(13 * textScale))
                    .fixedSize(horizontal: false, vertical: true)
                if !model.manualRefreshing {
                    Button { model.refreshReceipt = nil } label: {
                        Image(systemName: "xmark").frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Dismiss refresh result")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
            .padding(8)
            .accessibilityIdentifier("chat-refresh-result")
        }
    }

    /// A row's inputs. Each is narrowed to the row (its own expanded keys, its own hits, the
    /// answer state of its own question), so a change elsewhere leaves it equal and undrawn.
    private func chatRow(_ row: ChatRow, hits: [TranscriptSearchHit], actions: ChatRowActions) -> ChatRowView {
        var keys = Set<String>()
        if !expanded.isEmpty, case .item(.work(let work)) = row {
            for key in ["t:" + work.id, "s:" + work.id] where expanded.contains(key) { keys.insert(key) }
            if keys.contains("s:" + work.id) {
                for step in work.steps where expanded.contains("d:" + step.id) { keys.insert("d:" + step.id) }
            }
        }
        var recorded = false
        if case .prompt(let prompt) = row { recorded = model.store.outbox.recordedPromptIDs.contains(prompt.id) }
        let askID = row.askID
        var formDraft: AskFormDraft?
        if case .item(.ask(let id, let ask, let pending?)) = row, let form = pending.form ?? ask.form,
           !form.fields.isEmpty {
            formDraft = model.formDraft(askID: id, form: form)
        }
        return ChatRowView(
            row: row, viewer: viewer, client: client, expanded: keys, recorded: recorded,
            answering: askID != nil && model.answeringAskID == askID,
            problem: askID != nil && model.answerProblem?.askID == askID ? model.answerProblem : nil,
            answersRefused: model.answersRefused,
            formsSupported: model.formsSupported, formDraft: formDraft,
            hits: hits, query: hits.isEmpty ? "" : searchKey.query,
            selectedHitID: hits.isEmpty ? nil : selectedSearchHit,
            actions: actions)
    }

    private var rowActions: ChatRowActions {
        ChatRowActions(
            toggle: { key in toggle(key) },
            openNote: { note in openNote = note },
            openQuestion: { id in openQuestionID = id },
            answer: { id, option in Task { await model.answer(client: client, askID: id, option: option) } },
            submitForm: { id, draft in
                // The answer moves the conversation on: the chat follows it again. Like Jump to
                // latest, that retires an up-arrow jump, whose settle would otherwise read the
                // move as one that stopped short and scroll back to its prompt, and the review's
                // reveal, which would hold the card's top on screen against the follow.
                formReveal.pending = false
                if findRequest == nil {
                    promptTops.lastJump = nil
                    followingLatest = true
                } else {
                    followingLatest = false
                }
                Task { await model.answerForm(client: client, askID: id, draft: draft) }
            },
            formReviewOpened: { frame in
                formReveal.pending = true
                revealFormTop(frame)
            },
            formReviewLaidOut: { frame in revealFormTop(frame) },
            canAnswer: model.store.subagent == nil,
            openTerminal: {
                openQuestionID = nil
                onOpenTerminal()
            },
            selectText: { text in selectingText = text })
    }

    /// A form's review is open and asked to be shown from its top (`ChatFormReveal`). A card
    /// taller than the chat, followed to its tail, would hide its top ("Check your answers"
    /// and the first answers) under the header: the chat shows the card from its top instead,
    /// and stops following until Submit. Called with each layout of the card, so the reveal
    /// lands once the step's change and the follow to the tail have; reader input ends it.
    /// The move is the app's, not reader input (`ChatPromptTops.readerInput`), but it retires
    /// an up-arrow jump still settling, so the jump's correction does not scroll back to its
    /// prompt; the up arrow then searches from the form.
    private func revealFormTop(_ frame: CGRect) {
        guard formReveal.pending, findRequest == nil else { return }
        // A drag that has begun but not been sampled yet already has the chat.
        if let view = scrollPosition.view, view.isDragging || view.isDecelerating {
            formReveal.pending = false
            return
        }
        guard scrollPosition.revealTop(frame, margin: 16, atTail: followingLatest) else { return }
        promptTops.lastJump = nil
        followingLatest = false
    }

    private var questionSheet: some View {
        ChatContentSheet {
            if let turn = model.turns.first(where: { $0.items.contains(where: { $0.id == openQuestionID }) }),
               let item = turn.items.first(where: { $0.id == openQuestionID }),
               case .ask(let id, let ask, let pending) = item {
                VStack(alignment: .leading, spacing: 12) {
                    questionCard(id: id, ask: ask, pending: pending)
                    if case .user(let text, _, _) = turn.prompt?.kind, !text.isEmpty {
                        DisclosureGroup("Show context") { ChatMarkdownView(markdown: text).textSelection(.enabled) }
                            .font(Typography.app(14 * textScale))
                    }
                }
            } else {
                Text("This question is no longer available.")
            }
        }
        .accessibilityIdentifier("chat-question-sheet")
    }

    // MARK: - Rows

    private func questionCard(id: String, ask: TranscriptAsk, pending: TranscriptPendingAsk?) -> some View {
        ChatAskCard(id: id, ask: ask, pending: pending, viewer: viewer,
                    answering: model.answeringAskID == id,
                    problem: model.answerProblem?.askID == id ? model.answerProblem : nil,
                    answersRefused: model.answersRefused,
                    onAnswer: { option in
                        Task { await model.answer(client: client, askID: id, option: option) }
                    },
                    onOpenTerminal: {
                        openQuestionID = nil
                        onOpenTerminal()
                    })
    }

    // MARK: - My previous message (the up arrow)

    /// The up arrow is for the owner's own conversation with the agent: not a guest (whose
    /// prompts are not the owner's) and not a subagent's read-only transcript.
    private var offersPreviousMine: Bool {
        viewer == .owner && model.store.subagent == nil
    }

    /// A turn the up arrow stops at is loaded above the screen, or older pages may hold one.
    private var showsPreviousMine: Bool {
        guard offersPreviousMine else { return false }
        if findingPreviousMine { return true }
        return TranscriptPreviousMine.step(in: model.turns, above: mineBoundary, hasOlder: model.hasOlder,
                                           honoursOrigin: honoursTurnOrigin) != .none
    }

    /// The oldest drawn prompt on screen or below it (`ChatPromptTops`); nil when every drawn
    /// prompt is above the screen. Rows above the drawn window are above the screen too.
    private var currentMineBoundary: String? {
        let rows = model.rows
        guard drawnStart < rows.count else { return nil }
        for row in rows[drawnStart...] {
            if let id = row.promptTurnID, promptTops.above[id] == false { return id }
        }
        return nil
    }

    private func promptTopChanged(_ turnID: String, above: Bool) {
        promptTops.above[turnID] = above
        let boundary = currentMineBoundary
        if mineBoundary != boundary { mineBoundary = boundary }
    }

    /// Where a tap searches from: above the screen, and above the last jump while the chat is
    /// still where that jump left it (its scroll may not have settled yet). Once anything else
    /// moved the chat, the screen alone decides (`TranscriptPreviousMine.searchStart`).
    private var previousMineSearchStart: String? {
        TranscriptPreviousMine.searchStart(in: model.turns, boundary: currentMineBoundary,
                                           lastJump: promptTops.lastJump,
                                           offset: scrollPosition.offset.map(Double.init))
    }

    /// Scrolls to the owner's previous message above the screen, loading older pages (as search
    /// does) until one turns up or the history ends. Never stops at a guest's prompt or, on a
    /// host with turn origins, at one herdr marked as someone else's.
    private func jumpToPreviousMine(_ proxy: ScrollViewProxy) {
        guard !findingPreviousMine else { return }
        let start = previousMineSearchStart
        let navigation = promptTops.navigation
        Task { @MainActor in
            defer { if findingPreviousMine { findingPreviousMine = false } }
            while promptTops.navigation == navigation, !Task.isCancelled {
                switch TranscriptPreviousMine.step(in: model.turns, above: start, hasOlder: model.hasOlder,
                                                   honoursOrigin: honoursTurnOrigin) {
                case .jump(let turnID):
                    await revealPrompt(turnID, proxy)
                    return
                case .none:
                    return
                case .loadOlder:
                    findingPreviousMine = true
                    if model.loadingOlder {
                        // The top of the list is already fetching that page.
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        continue
                    }
                    await model.loadOlder(client: client)
                    if model.olderFailed { return }
                }
            }
        }
    }

    /// Puts a turn's prompt at the top of the screen, drawing the rows down from it first when
    /// it is above the drawn window. Glides like the down arrow; Reduce Motion jumps.
    private func revealPrompt(_ turnID: String, _ proxy: ScrollViewProxy) async {
        let rowID = "prompt:" + turnID
        guard let index = model.rowIndex[rowID] else { return }
        promptTops.jumpGeneration += 1
        let generation = promptTops.jumpGeneration
        promptTops.lastJump = TranscriptPreviousMine.LastJump(turnID: turnID)
        // From here on, reader input takes the jump over (`ChatPromptTops.readerInput`).
        promptTops.settle = TranscriptPreviousMine.Settle()
        formReveal.pending = false
        promptTops.deceleratingAtIssue = scrollPosition.view?.isDecelerating == true
        followingLatest = false
        atBottom = false
        if index < drawnStart {
            // Undrawn, the row reports nothing: what it reported before it left the window is stale.
            promptTops.above[turnID] = nil
            drawWindow = windowStarting(at: index)
            // Rows just drawn above the window are laid out before the scroll can find them: wait
            // until the prompt's probe reports its row, which it does once the row is laid out
            // (at most a second, then the scroll goes ahead regardless).
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 16_000_000)
                // Search may have opened meanwhile; it retires this jump.
                guard isCurrentJump(turnID, generation) else { return }
                if promptTops.above[turnID] != nil { break }
            }
        }
        // The reader may have scrolled while the rows above were drawn.
        guard isCurrentJump(turnID, generation) else { return }
        if reduceMotion {
            proxy.scrollTo(rowID, anchor: .top)
        } else {
            withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(rowID, anchor: .top) }
        }
        Task { await settleJump(turnID, generation: generation, proxy) }
    }

    /// Makes sure the jump arrived, then records the offset it settled at; from then on any
    /// other move of the chat (search, a drag, Jump to latest, an older page's anchor) retires
    /// it. Samples once the glide's own 0.3 s are over (plus a frame or so of slack), so a still
    /// offset before the scroll begins is not taken for the end of it, and the glide's motion
    /// is not taken for the reader's. The jump's `TranscriptPreviousMine.Settle`, made when it
    /// was issued, decides sample by sample whether to put a prompt that stopped short back at
    /// the top. Reader input (a drag, a wheel or trackpad scroll) at any moment since the jump
    /// was issued has already retired it, and no correction follows.
    private func settleJump(_ turnID: String, generation: Int, _ proxy: ScrollViewProxy) async {
        try? await Task.sleep(nanoseconds: reduceMotion ? 50_000_000 : 400_000_000)
        while isCurrentJump(turnID, generation) {
            switch promptTops.settle.sample(offset: scrollPosition.offset.map(Double.init),
                                            contentHeight: scrollPosition.contentHeight.map(Double.init),
                                            promptAbove: promptTops.above[turnID] == true) {
            case .wait:
                try? await Task.sleep(for: TranscriptPreviousMine.Settle.sampleInterval)
            case .correct:
                proxy.scrollTo("prompt:" + turnID, anchor: .top)
                try? await Task.sleep(for: TranscriptPreviousMine.Settle.sampleInterval)
            case .settled(let offset):
                promptTops.lastJump?.offset = offset
                return
            case .retire:
                // The reader moved the chat: the up arrow searches from where they are now.
                promptTops.lastJump = nil
                return
            case .giveUp:
                return
            }
        }
    }

    /// The up arrow's jump to `turnID` is the latest one, and nothing (search, a drag, Jump to
    /// latest) has retired it since.
    private func isCurrentJump(_ turnID: String, _ generation: Int) -> Bool {
        promptTops.jumpGeneration == generation && promptTops.lastJump?.turnID == turnID
    }

    // MARK: - Top of the list

    @ViewBuilder
    private func topSentinel(_ proxy: ScrollViewProxy) -> some View {
        Group {
            if model.loadingOlder {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Palette.textDim)
                    Text("Loading earlier messages").font(Typography.app(13 * textScale)).foregroundStyle(Palette.textDim)
                }
                .accessibilityIdentifier("chat-older-loading")
            } else if model.olderFailed {
                Button { loadOlder(proxy, retry: true) } label: {
                    Text("Couldn't load earlier messages · Retry").font(Typography.app(13 * textScale, .medium))
                        .foregroundStyle(Palette.textDim)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat-older-retry")
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 1)
        .onGeometryChange(for: Bool.self) { proxyGeometry in
            proxyGeometry.frame(in: .named(Self.scrollSpace)).maxY > -40
        } action: { visible in
            topVisible = visible
            if visible { showOlder(proxy) }
        }
        // `landed` flips after the first scroll; the sentinel may already be on screen.
        .onChange(of: landed) { _, _ in if topVisible { showOlder(proxy) } }
    }

    // MARK: - The drawn window

    /// The first drawn row's index in `model.rows`: the window's top row, with the day label
    /// over it.
    private var drawnStart: Int {
        let rows = model.rows
        if case .from(let id) = drawWindow, let index = model.rowIndex[id] {
            if index > 0, case .day = rows[index - 1] { return index - 1 }
            return index
        }
        return max(0, rows.count - Self.renderWindow)
    }

    /// The window whose top is row `index` (clamped to the rows). Its top is never a day
    /// label, which comes and goes as older turns merge above it: the prompt under the label
    /// is the top, and draws its label with it. Older rows merged above a window stay
    /// undrawn until a reveal, so a fetch never lays out a whole page at once.
    private func windowStarting(at index: Int) -> ChatWindow {
        let rows = model.rows
        guard !rows.isEmpty else { return .newest }
        var index = min(max(index, 0), rows.count - 1)
        if case .day = rows[index], index + 1 < rows.count { index += 1 }
        return .from(rows[index].id)
    }

    /// The row a reveal or a fetch keeps in place: the top drawn row, or the prompt under it
    /// when that is a day label (which may go when older turns merge above it).
    private var anchorRowID: String? {
        let rows = model.rows
        var index = drawnStart
        guard index < rows.count else { return nil }
        if case .day = rows[index], index + 1 < rows.count { index += 1 }
        return rows[index].id
    }

    /// The reader reached the top: the next window of rows already loaded, else the next
    /// older page. Either way the row that was on top stays where it was. `fetches` false: a
    /// window only, as when a revealed window still does not reach the screen's top.
    private func showOlder(_ proxy: ScrollViewProxy, fetches: Bool = true) {
        guard landed, findRequest == nil else { return }
        let start = drawnStart
        guard start > 0 else {
            if fetches { loadOlder(proxy) }
            return
        }
        guard let anchor = anchorRowID else { return }
        drawWindow = windowStarting(at: start - Self.renderWindow)
        Task {
            try? await Task.sleep(nanoseconds: 30_000_000)
            proxy.scrollTo(anchor, anchor: .top)
            // The sentinel's visibility is measured again after that scroll; still in view
            // (short rows), it gets the next window, never a fetch.
            try? await Task.sleep(nanoseconds: 150_000_000)
            if topVisible, landed, findRequest == nil { showOlder(proxy, fetches: false) }
        }
    }

    /// Fetches the next older page and draws its newest window above the row that was on
    /// top, which stays where it was.
    private func loadOlder(_ proxy: ScrollViewProxy, retry: Bool = false) {
        guard landed, findRequest == nil, model.hasOlder, !model.loadingOlder, retry || !model.olderFailed else { return }
        let anchor = anchorRowID
        Task {
            await model.loadOlder(client: client)
            guard let anchor, let index = model.rowIndex[anchor] else { return }
            drawWindow = windowStarting(at: index - Self.renderWindow)
            try? await Task.sleep(nanoseconds: 30_000_000)
            proxy.scrollTo(anchor, anchor: .top)
        }
    }

    /// The UI tests' `chat-copy-probe` (`ChatCopyProbe`) and `chat-row-renders`
    /// (`ChatRowRenderProbe`), in a mock run only.
    @ViewBuilder private var copyProbe: some View {
        #if DEBUG
        if ScreenshotMock.mode != nil {
            ChatCopyProbe()
            ChatRowRenderProbe()
        }
        #endif
    }

    /// Collapsed (the default for the session) the card shows the work at hand: at most three
    /// rows from `TranscriptPlanWindow`, then "+N more"; a finished plan shows only its header.
    private func planCard(_ items: [TranscriptPlanItem]) -> some View {
        let done = items.filter(\.done).count
        let allDone = done == items.count
        let open = expanded.contains("plan")
        let shown = open ? Array(items.indices) : TranscriptPlanWindow.visible(items)
        let hidden = items.count - shown.count
        return VStack(alignment: .leading, spacing: 8) {
            Button(action: togglePlan) {
                HStack(spacing: 6) {
                    ChatRowView.chevron(open: open, color: Palette.textFaint)
                    Text("TODO · \(done) OF \(items.count)")
                        .font(Typography.machine(10.5 * textScale, .semibold)).tracking(1.2).foregroundStyle(Palette.textFaint)
                    Spacer(minLength: 8)
                    if !open, allDone {
                        Text("✓ All done").font(Typography.app(12 * textScale, .semibold)).foregroundStyle(ChatStyle.ok)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("To-do, \(done) of \(items.count) done")
            .accessibilityValue(!open && allDone ? "All done" : "")
            .accessibilityHint(open ? "Shows fewer items" : "Shows all items")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("chat-plan-toggle")
            ForEach(Array(shown.enumerated()), id: \.element) { position, index in
                let item = items[index]
                if let phase = item.phase, position == 0 || items[shown[position - 1]].phase != phase {
                    Text(phase).font(Typography.app(12 * textScale, .semibold)).foregroundStyle(Palette.textDim)
                        .padding(.top, position == 0 ? 0 : 4)
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.done ? "checkmark" :
                            item.status == .inProgress ? "arrow.right.circle.fill" :
                            item.status == .blocked ? "pause.circle" : "circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(item.done ? ChatStyle.ok :
                            item.status == .inProgress ? Palette.working : Palette.textDim)
                        .frame(width: 15).padding(.top, 3)
                    Text(item.text).font(Typography.app(14 * textScale, item.status == .inProgress ? .semibold : .regular))
                        .strikethrough(item.done, color: Palette.textFaint.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(item.done ? Palette.textFaint : Palette.textDim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityValue(item.done ? "Done" : item.status == .inProgress ? "In progress" :
                                    item.status == .blocked ? "Blocked" : item.status == .pending ? "Pending" : "Not completed")
            }
            if hidden > 0, !allDone {
                Button(action: togglePlan) {
                    Text("+\(hidden) more").font(Typography.app(12 * textScale, .semibold)).foregroundStyle(Palette.textFaint)
                        .padding(.leading, 23)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows all items")
                .accessibilityIdentifier("chat-plan-more")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-plan")
    }

    private func toggle(_ key: String) {
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
    }

    private func togglePlan() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { toggle("plan") }
    }

    /// omp's `task` subagents, like the terminal's Subagents box: each running one with what
    /// it does now and for how long, the finished ones folded into one line. An owner's row
    /// with a transcript opens that conversation read-only; a guest's rows do not open.
    private func subagentsCard(_ subagents: [TranscriptSubagent]) -> some View {
        let running = subagents.filter(\.status.isRunning)
        let finished = subagents.filter { !$0.status.isRunning }
        let open = !expanded.contains("subagents-closed")
        let showsFinished = expanded.contains("subagents-finished")
        let summary = running.isEmpty ? "\(finished.count) finished" : "\(running.count) running"
        return VStack(alignment: .leading, spacing: 8) {
            Button { toggleCard("subagents-closed") } label: {
                HStack(spacing: 6) {
                    ChatRowView.chevron(open: open, color: Palette.textFaint)
                    Text("SUBAGENTS · \(summary.uppercased())")
                        .font(Typography.machine(10.5 * textScale, .semibold)).tracking(1.2).foregroundStyle(Palette.textFaint)
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Subagents, \(summary)")
            .accessibilityHint(open ? "Hides the subagents" : "Shows the subagents")
            .accessibilityIdentifier("chat-subagents-toggle")
            if open {
                ForEach(running) { subagentRow($0) }
                if !finished.isEmpty {
                    Button { toggleCard("subagents-finished") } label: {
                        HStack(spacing: 6) {
                            ChatRowView.chevron(open: showsFinished, color: Palette.textFaint)
                            Text("\(finished.count) finished")
                                .font(Typography.app(12 * textScale, .semibold)).foregroundStyle(Palette.textFaint)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(finished.count) finished")
                    .accessibilityHint(showsFinished ? "Hides the finished subagents" : "Shows the finished subagents")
                    .accessibilityIdentifier("chat-subagents-finished")
                    if showsFinished {
                        ForEach(finished) { subagentRow($0) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-subagents")
    }

    private func subagentRow(_ subagent: TranscriptSubagent) -> some View {
        ChatSubagentRow(subagent: subagent, opens: !viewer.isGuest && subagent.hasTranscript) {
            openSubagent = subagent
        }
        .equatable()
    }

    private func toggleCard(_ key: String) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { toggle(key) }
    }
}

/// One subagent in the chat's Subagents card. Equatable on what it draws, so a refresh or a
/// toggle that leaves it alone skips it; a running row's elapsed time ticks in its own
/// `TimelineView`, so only that line redraws each second.
private struct ChatSubagentRow: View, Equatable {
    let subagent: TranscriptSubagent
    /// Tapping opens its conversation (an owner's subagent with a transcript).
    let opens: Bool
    let onOpen: () -> Void

    @Environment(\.chatTextScale) private var textScale

    nonisolated static func == (lhs: ChatSubagentRow, rhs: ChatSubagentRow) -> Bool {
        lhs.subagent == rhs.subagent && lhs.opens == rhs.opens
    }

    var body: some View {
        if opens {
            Button(action: onOpen) { content }
                .buttonStyle(.plain)
                .accessibilityLabel(spoken)
                .accessibilityHint("Opens its conversation")
                .accessibilityIdentifier("chat-subagent-row")
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(spoken)
                .accessibilityIdentifier("chat-subagent-row")
        }
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            mark.frame(width: 12)
            VStack(alignment: .leading, spacing: 2) {
                (Text(subagent.id).fontWeight(.semibold).foregroundColor(Palette.text)
                    + Text(subagent.label.map { ": \($0)" } ?? "").foregroundColor(Palette.textDim))
                    .font(Typography.app(14 * textScale))
                    .lineLimit(1)
                detail
                    .font(Typography.app(12.5 * textScale))
                    .foregroundStyle(Palette.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if opens {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.textFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var mark: some View {
        switch subagent.status {
        case .running:
            Circle().fill(Palette.working)
                .frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
        case .completed:
            Text("✓").font(Typography.app(13 * textScale, .semibold)).foregroundStyle(ChatStyle.ok)
        case .failed, .aborted:
            Text("✗").font(Typography.app(13 * textScale, .semibold)).foregroundStyle(Palette.died)
        case .unknown:
            Text("?").font(Typography.app(13 * textScale, .semibold)).foregroundStyle(Palette.textFaint)
        }
    }

    /// Running: its newest tool intent and how long it has run, ticking. Finished: how it
    /// ended and how long it took.
    @ViewBuilder private var detail: some View {
        if subagent.status.isRunning {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let nowMs = UInt64(max(context.date.timeIntervalSince1970 * 1000, 0))
                let elapsed = subagent.startedMs > 0 && nowMs > subagent.startedMs
                    ? ChatDay.duration(ms: nowMs - subagent.startedMs) : nil
                Text([subagent.lastIntent, elapsed].compactMap { $0 }.joined(separator: " · "))
            }
        } else {
            Text([statusWord.capitalized, duration].compactMap { $0 }.joined(separator: " · "))
        }
    }

    private var statusWord: String {
        switch subagent.status {
        case .running: return "running"
        case .completed: return "completed"
        case .failed: return "failed"
        case .aborted: return "aborted"
        case .unknown: return "status unknown"
        }
    }

    private var duration: String? {
        if let ms = subagent.durationMs { return ChatDay.duration(ms: ms) }
        guard let finished = subagent.finishedMs, finished > subagent.startedMs, subagent.startedMs > 0 else { return nil }
        return ChatDay.duration(ms: finished - subagent.startedMs)
    }

    private var spoken: String {
        var parts = [subagent.id]
        if let label = subagent.label, !label.isEmpty { parts.append(label) }
        parts.append(statusWord)
        if subagent.status.isRunning {
            if let intent = subagent.lastIntent { parts.append(intent) }
        } else if let duration {
            parts.append(duration)
        }
        return parts.joined(separator: ", ")
    }
}

/// A subagent's own conversation, read-only: the chat over its session file
/// (`agent.transcript` with `subagent`), with no composer. It polls while the subagent runs.
private struct ChatSubagentSheet: View {
    let client: HerdrClient
    let subagent: TranscriptSubagent
    @StateObject private var model: ChatModel
    @Environment(\.dismiss) private var dismiss

    init(client: HerdrClient, target: String, subagent: TranscriptSubagent) {
        self.client = client
        self.subagent = subagent
        _model = StateObject(wrappedValue: ChatModel(target: target, subagent: subagent.id))
    }

    var body: some View {
        NavigationStack {
            ChatView(client: client, model: model, viewer: .owner, eventsPaneID: nil, isActive: true,
                     live: subagent.status.isRunning, agentStatus: nil, ground: Palette.groundMachine,
                     onOpenTerminal: { dismiss() })
                .navigationTitle(subagent.id)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("chat-subagent-done")
                    }
                }
        }
        .accessibilityIdentifier("chat-subagent-transcript")
    }
}

/// The page that hosts the chat redraws on every composer keystroke, and builds ChatView
/// with closures that never compare equal; `.equatable()` with this comparison lets those
/// passes skip the chat. The model's changes, the environment and ChatView's own state still
/// redraw it. The closures are left out: they write the host's state, which they reach
/// through its storage, so the first ones stay current.
extension ChatView: Equatable {
    nonisolated static func == (lhs: ChatView, rhs: ChatView) -> Bool {
        MainActor.assumeIsolated {
            lhs.client === rhs.client
                && lhs.model === rhs.model
                && lhs.viewer == rhs.viewer
                && lhs.eventsPaneID == rhs.eventsPaneID
                && lhs.isActive == rhs.isActive
                && lhs.live == rhs.live
                && lhs.agentStatus == rhs.agentStatus
                && lhs.ground == rhs.ground
                && lhs.findRequest == rhs.findRequest
        }
    }
}

/// What a row's controls do. They change the chat's state (ChatView's), which comes back to
/// the row as its inputs; they never draw, so rows are compared without them.
private struct ChatRowActions {
    let toggle: (String) -> Void
    let openNote: (TranscriptNote) -> Void
    let openQuestion: (String) -> Void
    let answer: (_ askID: String, _ option: String) -> Void
    let submitForm: (_ askID: String, _ draft: AskFormDraft) -> Void
    /// A form's review opened: from now on, bring its card's top (window coordinates) into
    /// view as it lays out, until the reader moves the chat (`ChatFormReveal`).
    let formReviewOpened: (CGRect) -> Void
    /// The open review's card laid out again.
    let formReviewLaidOut: (CGRect) -> Void
    /// Questions can be answered from this chat (not a subagent's read-only transcript).
    let canAnswer: Bool
    let openTerminal: () -> Void
    let selectText: (ChatSelectableText) -> Void
}

/// One line of the chat list, drawn from its inputs alone. `Equatable` over everything it
/// draws (`.equatable()` in ChatView), so a poll, a search keystroke or a toggle elsewhere
/// that leaves a row's inputs alone skips its body. Before, every ChatView pass re-ran every
/// row: hundreds of markdown parses and long-press menus on a long session.
private struct ChatRowView: View, Equatable {
    let row: ChatRow
    let viewer: ChatViewer
    let client: HerdrClient
    /// This row's open thought, step list and step details (`t:`, `s:`, `d:` keys).
    let expanded: Set<String>
    /// The prompt is one this device sent ("In transcript").
    let recorded: Bool
    /// The question's answer is on its way, or was refused.
    let answering: Bool
    let problem: ChatAnswerProblem?
    /// The guest's host refused guest answers: the question waits for the owner.
    let answersRefused: Bool
    /// The server's `ask_form` (nil until known), and a pending form's draft.
    let formsSupported: Bool?
    let formDraft: AskFormDraft?
    /// The search's excerpts under the row. Without a hit the query and selection are left
    /// out too, so a search touches only the rows it finds.
    let hits: [TranscriptSearchHit]
    let query: String
    let selectedHitID: String?
    let actions: ChatRowActions

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.chatTextScale) private var textScale

    /// Every drawing input; an input missing here is drawn stale. The actions only write
    /// state, and the environment (text size, size class) updates the row on its own.
    nonisolated static func == (lhs: ChatRowView, rhs: ChatRowView) -> Bool {
        lhs.row == rhs.row
            && lhs.viewer == rhs.viewer
            && lhs.client === rhs.client
            && lhs.expanded == rhs.expanded
            && lhs.recorded == rhs.recorded
            && lhs.answering == rhs.answering
            && lhs.problem == rhs.problem
            && lhs.answersRefused == rhs.answersRefused
            && lhs.formsSupported == rhs.formsSupported
            && lhs.formDraft === rhs.formDraft
            && lhs.hits == rhs.hits
            && lhs.query == rhs.query
            && lhs.selectedHitID == rhs.selectedHitID
    }

    var body: some View {
        #if DEBUG
        let _ = ChatRowRenders.record()
        #endif
        VStack(alignment: .leading, spacing: 6) {
            rowView(row)
            ChatSearchResults(hits: hits, query: query, selectedID: selectedHitID)
        }
    }

    private func toggle(_ key: String) {
        actions.toggle(key)
    }

    private func askCard(id: String, ask: TranscriptAsk, pending: TranscriptPendingAsk?) -> some View {
        ChatAskCard(id: id, ask: ask, pending: pending, viewer: viewer, answering: answering, problem: problem,
                    answersRefused: answersRefused,
                    onAnswer: { option in actions.answer(id, option) },
                    onOpenTerminal: actions.openTerminal)
    }

    @ViewBuilder
    private func rowView(_ row: ChatRow) -> some View {
        switch row {
        case .day(_, let ms):
            dayLabel(ms)
        case .prompt(let prompt):
            promptBubble(prompt)
        case .item(let item):
            itemView(item)
        case .outgoing(let message):
            outgoingBubble(message)
        }
    }

    @ViewBuilder
    private func itemView(_ item: TranscriptItem) -> some View {
        switch item {
        case .work(let work):
            workView(work)
        case .reply(_, let text, _):
            ChatMarkdownView(markdown: text)
                .stableContextMenu { messageMenu(text, markdown: true, offersMarkdown: true) }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("chat-reply")
        case .note(_, let tsMs, let note):
            noteCard(note, tsMs: tsMs)
        case .plan:
            EmptyView() // The current snapshot stays visible once at the conversation's end.
        case .ask(let id, let ask, let pending):
            if let form = ask.form ?? pending?.form, !form.fields.isEmpty {
                // A form's stepper is the whole question: no "Open question" sheet.
                ChatAskFormCard(ask: ask, form: form, pending: pending, viewer: viewer,
                                formsSupported: formsSupported, draft: formDraft, answering: answering,
                                problem: problem, answersRefused: answersRefused,
                                canAnswerHere: actions.canAnswer,
                                onSubmit: { if let formDraft { actions.submitForm(id, formDraft) } },
                                onOpenTerminal: actions.openTerminal,
                                onReviewOpened: actions.formReviewOpened,
                                onReviewLaidOut: actions.formReviewLaidOut)
                    .frame(maxWidth: sizeClass == .regular ? 520 : .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    askCard(id: id, ask: ask, pending: pending)
                    Button("Open question") { actions.openQuestion(id) }
                        .font(Typography.app(13 * textScale))
                        .accessibilityIdentifier("chat-question-open")
                }
                .frame(maxWidth: sizeClass == .regular ? 520 : .infinity, alignment: .leading)
            }
        case .turnFailed(_, let status, let error):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: status == .aborted ? "stop.circle" : "exclamationmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                Text(status == .aborted ? "Stopped" : "Failed\(error.map { " · \($0)" } ?? "")")
                    .font(Typography.app(14 * textScale)).lineLimit(3)
            }
            .foregroundStyle(status == .aborted ? Palette.textFaint : Palette.died)
            .accessibilityIdentifier("chat-turn-failed")
        case .summary(_, let text):
            HStack(spacing: 10) {
                Rectangle().fill(Palette.hairlineQuiet).frame(height: 1)
                Text(text).font(Typography.app(13 * textScale)).foregroundStyle(Palette.textFaint).fixedSize()
                Rectangle().fill(Palette.hairlineQuiet).frame(height: 1)
            }
            .padding(.vertical, 4)
            .accessibilityIdentifier("chat-summary")
        }
    }

    // MARK: - Pieces

    private func dayLabel(_ ms: UInt64) -> some View {
        #if DEBUG
        let now = MockClock.pinned ?? Date()
        #else
        let now = Date()
        #endif
        let (day, time) = ChatDay.label(ms: ms, now: now)
        return (Text(day).font(Typography.app(13 * textScale, .semibold)) + Text(" " + time).font(Typography.app(13 * textScale)))
            .foregroundStyle(Palette.textFaint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .accessibilityIdentifier("chat-day")
    }

    @ViewBuilder
    private func promptBubble(_ prompt: ChatPrompt) -> some View {
        let byline = byline(for: prompt.author)
        VStack(alignment: .trailing, spacing: 4) {
            if let byline {
                Text(byline).font(Typography.app(12 * textScale, .medium)).foregroundStyle(Palette.textFaint)
                    .padding(.trailing, 6)
            }
            if let attachment = prompt.attachment {
                if !attachment.caption.isEmpty { promptText(attachment.caption) }
                ChatAttachmentBundle(files: attachment.files, client: client)
                    .frame(maxWidth: sizeClass == .regular ? 480 : 296)
            } else {
                promptText(prompt.text)
            }
            if recorded {
                Text("In transcript").font(Typography.app(11 * textScale)).foregroundStyle(Palette.textFaint)
                    .padding(.trailing, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 40)
    }

    private func promptText(_ text: String) -> some View {
        Text(text)
            .font(Typography.app(16 * textScale))
            .foregroundStyle(Palette.text)
            .lineSpacing(1)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.top, 9).padding(.bottom, 10)
            .background(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18,
                                               bottomTrailingRadius: 6, topTrailingRadius: 18)
                .fill(Palette.surfaceRaised))
            .stableContextMenu(previewCornerRadius: 18) { messageMenu(text, markdown: false) }
            .frame(maxWidth: sizeClass == .regular ? 480 : 296, alignment: .trailing)
            .accessibilityIdentifier("chat-user-bubble")
    }

    /// A message's menu, on a long press (a right click on a Mac): Copy, Copy as Markdown on
    /// a reply, and Select Text. A `stableContextMenu`, never `.contextMenu`: this view
    /// redraws on every poll and stream event, which rebuilds an open SwiftUI menu (#437).
    /// Its entries are also the message's VoiceOver actions, so Copy needs no long press.
    /// `markdown`: the text is rendered markdown (a reply or a thought), so Copy and Select
    /// Text give it as read, without the syntax. Nothing is parsed until an entry is chosen.
    @MainActor @StableMenuBuilder
    private func messageMenu(_ text: String, markdown: Bool, offersMarkdown: Bool = false) -> [StableMenuItem] {
        StableMenuItem("Copy", systemImage: "doc.on.doc") {
            ChatClipboard.write(markdown ? ChatMessageText.plain(text) : text)
        }
        if offersMarkdown {
            StableMenuItem("Copy as Markdown", systemImage: "chevron.left.forwardslash.chevron.right") {
                ChatClipboard.write(text)
            }
        }
        StableMenuItem("Select Text", systemImage: "selection.pin.in.out") {
            actions.selectText(ChatSelectableText(text: markdown ? ChatMessageText.readable(text) : AttributedString(text)))
        }
    }

    private func outgoingBubble(_ message: TranscriptOutgoingMessage) -> some View {
        let receipt: String
        switch message.state {
        case .sending: receipt = "Sending…"
        case .submitted: receipt = "Accepted by agent"
        case .unconfirmed: receipt = "Confirmation pending"
        case .notDelivered(let reason): receipt = "Not sent · \(reason)"
        case .previousSession: receipt = "Previous session · confirmation unavailable"
        case .notSeen: receipt = "Not seen in chat · check Terminal"
        }
        return VStack(alignment: .trailing, spacing: 4) {
            if !message.text.isEmpty { promptText(message.text) }
            if !message.files.isEmpty {
                ChatAttachmentBundle(files: message.files, client: client)
                    .frame(maxWidth: sizeClass == .regular ? 480 : 296)
            }
            Text(receipt).font(Typography.app(11 * textScale)).foregroundStyle(Palette.textFaint)
                .padding(.trailing, 6)
                // The server's answer cross-fades in place.
                .contentTransition(.opacity)
                .animation(ChatSendMotion.receipt, value: receipt)
                .accessibilityIdentifier("chat-send-receipt")
                .onChange(of: receipt) { _, receipt in
                    UIAccessibility.post(notification: .announcement, argument: receipt)
                }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 40)
        .accessibilityIdentifier("chat-outgoing-message")
    }

    /// Whose prompt this was, when it was not the reader's own.
    private func byline(for author: TranscriptAuthor?) -> String? {
        switch (viewer, author) {
        case (.owner, .guest(let name)?):
            return "\(name ?? "Guest") · guest"
        case (.guest(_, let owner), .owner?):
            return owner
        case (.guest(let me, _), .guest(let name)?):
            return name == me ? nil : "\(name ?? "Guest") · guest"
        default:
            return nil
        }
    }

    @ViewBuilder
    private func workView(_ work: TranscriptWork) -> some View {
        let thoughtKey = "t:" + work.id
        let stepsKey = "s:" + work.id
        VStack(alignment: .leading, spacing: 10) {
            if let thought = work.latestThought {
                Button { toggle(thoughtKey) } label: {
                    HStack(spacing: 6) {
                        Self.chevron(open: expanded.contains(thoughtKey), color: Palette.textFaint)
                        Text("Thought").font(Typography.app(14 * textScale, .semibold)).foregroundStyle(Palette.textDim)
                            .fixedSize()
                        if !expanded.contains(thoughtKey) {
                            Text(ChatInline.styled(ChatDay.firstSentence(thought), size: 14 * textScale))
                                .foregroundStyle(Palette.textFaint).lineLimit(1).truncationMode(.tail)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Thought: \(ChatDay.firstSentence(thought))")
                .accessibilityHint(expanded.contains(thoughtKey) ? "Collapses the thought" : "Shows the whole thought")
                .accessibilityIdentifier("chat-thought")
                if expanded.contains(thoughtKey) {
                    ChatMarkdownView(markdown: work.thoughts.joined(separator: "\n\n"), tone: .thought)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .stableContextMenu { messageMenu(work.thoughts.joined(separator: "\n\n"), markdown: true) }
                        .padding(.vertical, 2).padding(.leading, 12)
                        .overlay(alignment: .leading) { Rectangle().fill(Palette.hairlineQuiet).frame(width: 2) }
                        .padding(.leading, 5)
                        .accessibilityIdentifier("chat-thought-open")
                }
            }
            if !work.steps.isEmpty {
                Button { toggle(stepsKey) } label: {
                    HStack(spacing: 7) {
                        Self.chevron(open: expanded.contains(stepsKey), color: Palette.textDim)
                        stepsSummary(work)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat-steps")
                if expanded.contains(stepsKey) {
                    stepList(work)
                }
            }
        }
    }

    private func stepsSummary(_ work: TranscriptWork) -> some View {
        TimelineView(.periodic(from: .now, by: work.live ? 30 : 3600)) { context in
            let endMs = work.live ? UInt64(max(context.date.timeIntervalSince1970 * 1000, 0)) : work.endMs
            let duration = ChatDay.duration(ms: endMs > work.startMs ? endMs - work.startMs : 0)
            let count = work.steps.count == 1 ? "1 step" : "\(work.steps.count) steps"
            (Text("\(work.live ? "Working" : "Worked") for \(duration)").foregroundColor(Palette.textDim)
                + Text(" · \(count)").foregroundColor(Palette.textFaint))
                .font(Typography.app(14 * textScale))
                .lineLimit(1)
        }
    }

    private func stepList(_ work: TranscriptWork) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(work.steps) { step in
                let running = step.status == .running && work.live
                let detailKey = "d:" + step.id
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle()
                            .fill(step.status == .error ? Palette.died : running ? Palette.working : Palette.hairline)
                            .frame(width: 5, height: 5)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 2.5 }
                        // The tool omp ran, in the theme's accent, as omp's terminal titles it.
                        if !step.tool.isEmpty {
                            Text(step.tool).font(Typography.machine(11.5 * textScale, .semibold))
                                .foregroundStyle(Color(hex: ChatPalette.current.toolTitle))
                                .lineLimit(1)
                                .fixedSize()
                                .frame(minWidth: 46 * textScale, alignment: .leading)
                        }
                        Text(step.intent).font(Typography.app(13.5 * textScale))
                            .foregroundStyle(running ? Palette.textDim : Palette.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if expanded.contains(detailKey), let detail = step.detail, !detail.isEmpty {
                        Text(detail).font(Typography.machine(11.5 * textScale)).foregroundStyle(Palette.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(.leading, 12)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if step.detail != nil { toggle(detailKey) } }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Self.stepLabel(step, running: running))
                .accessibilityIdentifier(running ? "chat-step-running" : "chat-step")
            }
        }
        .padding(.vertical, 1).padding(.leading, 12)
        .overlay(alignment: .leading) { Rectangle().fill(Palette.hairlineQuiet).frame(width: 2) }
        .padding(.leading, 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-steplist")
    }

    /// A step for VoiceOver: its tool, then what it did.
    static func stepLabel(_ step: TranscriptStepRow, running: Bool) -> String {
        let label = step.tool.isEmpty ? step.intent : "\(step.tool), \(step.intent)"
        return running ? "\(label), running" : label
    }

    private func noteCard(_ note: TranscriptNote, tsMs: UInt64) -> some View {
        Button { actions.openNote(note) } label: {
            HStack(spacing: 10) {
                Image(systemName: ChatNoteStyle.icon(note.source))
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.textDim)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Palette.surfaceRaised))
                VStack(alignment: .leading, spacing: 1) {
                    Text(ChatNoteStyle.kicker(note, tsMs: tsMs))
                        .font(Typography.machine(10.5 * textScale, .semibold)).tracking(1.2)
                        .foregroundStyle(Palette.textFaint).lineLimit(1)
                    Text(ChatNoteStyle.title(note)).font(Typography.app(14.5 * textScale)).foregroundStyle(Palette.text).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textFaint)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(ChatNoteStyle.sourceName(note.source)) note: \(note.title)")
        .accessibilityHint("Opens the full message")
        .accessibilityIdentifier("chat-note")
    }

    static func chevron(open: Bool, color: Color) -> some View {
        Image(systemName: open ? "chevron.down" : "chevron.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 12, height: 12)
    }
}

#if DEBUG
/// For the UI tests: how many times a `ChatRowView` body has run, so a test can hold the
/// chat to a render budget (`chat-row-renders`).
@MainActor
enum ChatRowRenders {
    private(set) static var count = 0
    static func record() { count += 1 }
}

/// The `chat-row-renders` probe: `ChatRowRenders.count` as its label, polled. Its own view and
/// state, so the poll re-renders this probe alone, never the chat whose rows it counts.
private struct ChatRowRenderProbe: View {
    @State private var count = 0

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier("chat-row-renders")
            .accessibilityLabel("\(count)")
            .task {
                while !Task.isCancelled {
                    if ChatRowRenders.count != count { count = ChatRowRenders.count }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
    }
}
#endif

private struct IdentifiedNote: Identifiable {
    let note: TranscriptNote
    var id: String { note.title + note.body }
}

// MARK: - The question card

/// omp's `ask` question. Open and answerable: the options are buttons (the recommended
/// one, else the first, primary), for a guest as for the owner. A guest whose host refuses
/// guest answers (an older host): the options read-only with "Waiting for <owner> to
/// answer". Answered: "You chose …".
struct ChatAskCard: View {
    let id: String
    let ask: TranscriptAsk
    let pending: TranscriptPendingAsk?
    let viewer: ChatViewer
    let answering: Bool
    let problem: ChatAnswerProblem?
    /// The guest's host refused guest answers (`ChatModel.answersRefused`).
    let answersRefused: Bool
    let onAnswer: (String) -> Void
    let onOpenTerminal: () -> Void

    /// A guest who cannot answer: the question waits for the owner.
    private var waitingForOwner: String? {
        guard answersRefused, case .guest(_, let owner) = viewer else { return nil }
        return owner
    }

    private var question: TranscriptQuestion? { ask.questions.first }

    @Environment(\.chatTextScale) private var textScale

    var body: some View {
        Group {
            if let answer = ask.answer {
                answered(answer)
            } else if pending != nil {
                open
            } else {
                unanswered
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-ask")
    }

    private var questionText: String {
        ask.questions.map(\.question).joined(separator: "\n")
    }

    private func answered(_ answer: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(questionText).font(Typography.app(14 * textScale, .medium)).foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(ChatStyle.ok)
                (Text(chooser).foregroundColor(Palette.textDim)
                    + Text(answer.joined(separator: ", ")).font(Typography.app(14.5 * textScale, .semibold)).foregroundColor(Palette.text))
                    .font(Typography.app(14.5 * textScale))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat-ask-chosen")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(card)
    }

    /// Who the answer is credited to. A guest who may answer cannot tell whether they, the
    /// owner or another device chose, so the answer stands alone.
    private var chooser: String {
        switch viewer {
        case .owner: return "You chose "
        case .guest: return waitingForOwner.map { "\($0) chose " } ?? "Chosen: "
        }
    }

    private var canAnswer: Bool {
        waitingForOwner == nil && pending?.answerable == true && question != nil
    }

    private var open: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(questionText).font(Typography.app(15 * textScale, .semibold)).foregroundStyle(Palette.text)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
            let options = question?.options ?? []
            let primary = question?.recommended ?? 0
            VStack(spacing: 8) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    if canAnswer {
                        Button { onAnswer(option) } label: {
                            optionLabel(option, primary: index == primary, readOnly: false)
                        }
                        .buttonStyle(.plain)
                        .disabled(answering)
                        .accessibilityIdentifier("chat-ask-option-\(index)")
                    } else {
                        optionLabel(option, primary: false, readOnly: true)
                            .accessibilityIdentifier("chat-ask-option-\(index)")
                    }
                }
            }
            .opacity(answering ? 0.6 : 1)
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(card)
    }

    @ViewBuilder
    private var footer: some View {
        if let owner = waitingForOwner {
            HStack(spacing: 8) {
                Circle().fill(Palette.waiting).frame(width: 7, height: 7)
                Text("WAITING FOR \(owner.uppercased()) TO ANSWER")
                    .font(Typography.machine(10.5 * textScale, .semibold)).tracking(1.2).foregroundStyle(Palette.waiting)
            }
            .padding(.top, 10)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat-ask-waiting")
        } else if let problem {
            VStack(alignment: .leading, spacing: 8) {
                Text(problem.message).font(Typography.app(13 * textScale)).foregroundStyle(Palette.waiting)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("chat-ask-problem")
                if problem.offersTerminal { terminalButton }
            }
            .padding(.top, 10)
        } else if !canAnswer {
            // A multi-part or multi-select question: the chat shows it, the terminal answers it.
            terminalButton.padding(.top, 10)
        }
    }

    private var terminalButton: some View {
        Button(action: onOpenTerminal) {
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(.system(size: 12, weight: .semibold))
                Text("Answer in Terminal").font(Typography.app(14 * textScale, .semibold))
            }
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 14).frame(height: 36)
            .background(Capsule().fill(Palette.surfaceRaised))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat-ask-terminal")
    }

    private var unanswered: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(questionText).font(Typography.app(14 * textScale, .medium)).foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Text("Not answered").font(Typography.app(13 * textScale)).foregroundStyle(Palette.textFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(card)
    }

    private func optionLabel(_ option: String, primary: Bool, readOnly: Bool) -> some View {
        Text(option)
            .font(Typography.app(15 * textScale, .medium))
            .foregroundStyle(readOnly ? Palette.textDim : primary ? Palette.ground : Palette.text)
            .lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(readOnly ? Color.clear : primary ? Palette.text : Palette.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(readOnly ? Palette.hairlineQuiet : Color.clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 16).fill(Palette.surface)
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

// MARK: - Notes

enum ChatNoteStyle {
    static func icon(_ source: TranscriptNoteSource) -> String {
        switch source {
        case .gitmoot: return "envelope"
        case .asyncResult: return "tray.and.arrow.down"
        case .advisor: return "lightbulb"
        case .other: return "bell"
        }
    }

    static func sourceName(_ source: TranscriptNoteSource) -> String {
        switch source {
        case .gitmoot: return "Gitmoot"
        case .asyncResult: return "Async result"
        case .advisor: return "Advisor"
        case .other: return "Agent"
        }
    }

    /// "GITMOOT · 4:51 PM", as the mockup labels it; the sender goes after the title.
    static func kicker(_ note: TranscriptNote, tsMs: UInt64) -> String {
        let source = sourceName(note.source).uppercased()
        guard tsMs > 0 else { return source }
        let time = Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000)
            .formatted(date: .omitted, time: .shortened)
        return "\(source) · \(time.uppercased())"
    }

    /// "Review approved · herdr #305 · from herdr-kimi-review".
    static func title(_ note: TranscriptNote) -> String {
        guard let from = note.from, !from.isEmpty else { return note.title }
        return "\(note.title) · from \(from)"
    }
}

/// The full text of a note card. Notes never notify; this is the only place they open.
private struct ChatNoteSheet: View {
    let note: TranscriptNote
    @Environment(\.chatTextScale) private var textScale

    var body: some View {
        ChatContentSheet {
            VStack(alignment: .leading, spacing: 10) {
                Text(ChatNoteStyle.title(note))
                    .font(Typography.app(18 * textScale, .semibold))
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ChatNoteStyle.kicker(note, tsMs: 0))
                    .font(Typography.machine(10.5 * textScale, .semibold))
                    .foregroundStyle(Palette.textFaint)
                DisclosureGroup("Show context") {
                    ChatMarkdownView(markdown: note.body).textSelection(.enabled)
                }
                .font(Typography.app(14 * textScale))
            }
        }
        .accessibilityIdentifier("chat-note-sheet")
    }
}

// MARK: - Time

enum ChatDay {
    /// A separator before a prompt on a new day, or after an hour's quiet.
    static func needsSeparator(previousMs: UInt64?, ms: UInt64) -> Bool {
        guard let previousMs else { return true }
        let previous = Date(timeIntervalSince1970: TimeInterval(previousMs) / 1000)
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        if !Calendar.current.isDate(previous, inSameDayAs: date) { return true }
        return ms > previousMs && ms - previousMs >= 60 * 60 * 1000
    }

    /// ("Today", "2:05 PM"), ("Yesterday", …), a weekday this week, else the date.
    static func label(ms: UInt64, now: Date) -> (String, String) {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return ("Today", time) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return ("Yesterday", time) }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return (date.formatted(.dateTime.weekday(.wide)), time)
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return (date.formatted(.dateTime.month(.abbreviated).day()), time)
        }
        return (date.formatted(.dateTime.month(.abbreviated).day().year()), time)
    }

    static func duration(ms: UInt64) -> String {
        let seconds = Int(ms / 1000)
        if seconds < 60 { return "\(max(seconds, 1)) s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// The collapsed thought line: its first sentence (the line truncates the rest).
    static func firstSentence(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        if let end = line.range(of: ". ") { return String(line[..<end.lowerBound]) + "." }
        return line
    }
}
