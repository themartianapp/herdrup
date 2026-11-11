import Foundation

// Wire types for `agent.transcript` and `agent.answer` (herdr#306–#308): an omp agent's
// conversation read from its own session file, paged by turn, for the Chat view.
//
// Decoding is deliberately forgiving below the entry level: a newer server may add entry
// kinds, statuses or note sources, and one unfamiliar value must not fail a whole page
// (the view would fall back to "unavailable" for a conversation it can mostly show).

// MARK: - Params

/// Params of `agent.transcript`. `before` and `after` are mutually exclusive (the server
/// refuses both); neither asks for the newest page. `subagent` pages that subagent's own
/// conversation (owner only) instead of the agent's.
public struct AgentTranscriptParams: Encodable, Sendable, Equatable {
    public let target: String
    public let before: String?
    public let after: String?
    public let limit: UInt32?
    public let subagent: String?

    public init(target: String, before: String? = nil, after: String? = nil, limit: UInt32? = nil,
                subagent: String? = nil) {
        self.target = target
        self.before = before
        self.after = after
        self.limit = limit
        self.subagent = subagent
    }
}

struct AgentAnswerParams: Encodable, Sendable {
    let target: String
    let askID: String
    let option: String

    enum CodingKeys: String, CodingKey {
        case target, option
        case askID = "ask_id"
    }
}

/// One field's answer for `agent.answer_form`. A field left out of `values` keeps omp's default.
public enum AskFormValue: Encodable, Sendable, Equatable {
    /// A choice field: the chosen option values (radio: exactly one), plus Other's text.
    case choice(options: [String], other: String? = nil)
    /// A text field.
    case text(String)

    enum CodingKeys: String, CodingKey { case options, other, text }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .choice(let options, let other):
            try c.encode(options, forKey: .options)
            try c.encodeIfPresent(other, forKey: .other)
        case .text(let text):
            try c.encode(text, forKey: .text)
        }
    }
}

struct AgentAnswerFormParams: Encodable, Sendable {
    let target: String
    let askID: String
    let values: [String: AskFormValue]

    enum CodingKeys: String, CodingKey {
        case target, values
        case askID = "ask_id"
    }
}

// MARK: - Entries

/// Who wrote a user turn. A guest prompt arrives as `<name> (via HerdrUp): <text>`; the
/// server strips that prefix and reports the guest here instead.
public enum TranscriptAuthor: Sendable, Equatable {
    case owner
    case guest(name: String?)
}

/// Whose request a user turn was, as herdr records it (owner decision 2026-11-06). herdr marks a
/// brokered prompt that was not the owner's (gitmoot, a script, another agent) `origin: "other"`
/// and omits the field otherwise, so `mine` also covers "unknown": an older herdr, or a prompt
/// typed straight into the terminal. Independent of `TranscriptAuthor`, which names a guest.
public enum TranscriptOrigin: Sendable, Equatable {
    case mine
    case other
}

public enum TranscriptStepStatus: String, Sendable, Equatable {
    case running, ok, error
}

public enum TranscriptNoteSource: String, Sendable, Equatable {
    case gitmoot
    case asyncResult = "async_result"
    case advisor
    case other
}

public enum TranscriptTurnEndStatus: String, Sendable, Equatable {
    case done, error, aborted
}

public struct TranscriptStep: Sendable, Equatable {
    public let tool: String
    public let intent: String
    public let status: TranscriptStepStatus
    /// Owner only; at most 300 characters.
    public let detail: String?

    public init(tool: String, intent: String, status: TranscriptStepStatus, detail: String? = nil) {
        self.tool = tool
        self.intent = intent
        self.status = status
        self.detail = detail
    }
}

public struct TranscriptNote: Sendable, Equatable {
    public let source: TranscriptNoteSource
    public let title: String
    public let from: String?
    public let body: String

    public init(source: TranscriptNoteSource, title: String, from: String? = nil, body: String) {
        self.source = source
        self.title = title
        self.from = from
        self.body = body
    }
}

public struct TranscriptModel: Decodable, Sendable, Equatable {
    public let provider: String
    public let id: String
    /// omp's thinking (effort) level: minimal, low, medium, high, xhigh or max. Absent when
    /// thinking is off, or while `auto` has not picked a level yet.
    public let thinkingLevel: String?
    /// The level is omp's `auto`: `thinkingLevel` is what auto resolved to, if anything.
    public let thinkingAuto: Bool

    public init(provider: String, id: String, thinkingLevel: String? = nil, thinkingAuto: Bool = false) {
        self.provider = provider
        self.id = id
        self.thinkingLevel = thinkingLevel
        self.thinkingAuto = thinkingAuto
    }

    enum CodingKeys: String, CodingKey {
        case provider, id
        case thinkingLevel = "thinking_level"
        case thinkingAuto = "thinking_auto"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(provider: try c.decode(String.self, forKey: .provider),
                  id: try c.decode(String.self, forKey: .id),
                  thinkingLevel: try c.decodeIfPresent(String.self, forKey: .thinkingLevel),
                  thinkingAuto: try c.decodeIfPresent(Bool.self, forKey: .thinkingAuto) ?? false)
    }

    /// The effort as the chat words it: "high", "high (auto)" once auto picked a level,
    /// "auto" before it has; nil without a level.
    public var effort: String? {
        switch (thinkingLevel, thinkingAuto) {
        case (let level?, false): return level
        case (let level?, true): return "\(level) (auto)"
        case (nil, true): return "auto"
        case (nil, false): return nil
        }
    }

    /// The chat's model line: "claude-opus-5-5 · high", or the id alone without a level.
    public var label: String {
        effort.map { "\(id) · \($0)" } ?? id
    }

    /// "Model: anthropic, claude-opus-5-5, effort high".
    public var accessibilityLabel: String {
        "Model: \(provider), \(id)" + (effort.map { ", effort \($0)" } ?? "")
    }
}

public struct TranscriptRecap: Decodable, Sendable, Equatable {
    public let turnID: String
    public let text: String
    enum CodingKeys: String, CodingKey {
        case turnID = "turn_id"
        case text
    }
}

public enum TranscriptTaskStatus: String, Sendable, Equatable {
    case pending, completed, blocked, unknown
    case inProgress = "in_progress"
}

public struct TranscriptPlanItem: Decodable, Sendable, Equatable {
    public let text: String
    public let done: Bool
    public let status: TranscriptTaskStatus
    public let phase: String?
    public let blocker: String?

    public init(text: String, done: Bool, status: TranscriptTaskStatus? = nil,
                phase: String? = nil, blocker: String? = nil) {
        self.text = text
        self.status = status ?? (done ? .completed : .unknown)
        self.done = self.status == .completed
        self.phase = phase
        self.blocker = blocker
    }

    enum CodingKeys: String, CodingKey { case text, done, status, phase, blocker }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let status = try c.decodeIfPresent(String.self, forKey: .status).flatMap(TranscriptTaskStatus.init(rawValue:))
        self.init(text: try c.decode(String.self, forKey: .text),
                  done: try c.decodeIfPresent(Bool.self, forKey: .done) ?? false,
                  status: status,
                  phase: try c.decodeIfPresent(String.self, forKey: .phase),
                  blocker: try c.decodeIfPresent(String.self, forKey: .blocker))
    }
}

public struct TranscriptQuestion: Decodable, Sendable, Equatable {
    public let question: String
    public let options: [String]
    public let multi: Bool
    /// Index into `options` omp marked as its recommendation.
    public let recommended: Int?

    public init(question: String, options: [String], multi: Bool = false, recommended: Int? = nil) {
        self.question = question
        self.options = options
        self.multi = multi
        self.recommended = recommended
    }

    enum CodingKeys: String, CodingKey { case question, options, multi, recommended }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        question = try c.decode(String.self, forKey: .question)
        options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
        multi = try c.decodeIfPresent(Bool.self, forKey: .multi) ?? false
        recommended = try c.decodeIfPresent(Int.self, forKey: .recommended)
    }
}

/// omp's `ask` (≥ 18.18.3) is one HTML form; herdr parses it into this (the contract's
/// `form`). Each field is one step of the chat's stepper.
public struct AskForm: Decodable, Sendable, Equatable {
    /// Plain text of the context before the first section or field; paragraphs split by "\n\n".
    public let intro: String?
    public let fields: [AskFormField]

    public init(intro: String? = nil, fields: [AskFormField]) {
        self.intro = intro
        self.fields = fields
    }

    enum CodingKeys: String, CodingKey { case intro, fields }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        intro = try c.decodeIfPresent(String.self, forKey: .intro)
        fields = try c.decodeIfPresent([AskFormField].self, forKey: .fields) ?? []
    }

    /// Every field the app knows how to fill: a form with any other kind is shown read-only.
    public var isFillable: Bool { !fields.isEmpty && fields.allSatisfy { $0.kind != .unknown } }
}

public enum AskFormFieldKind: String, Sendable, Equatable {
    case choice, text
    /// A kind this app does not know (a newer server).
    case unknown
}

public struct AskFormOption: Decodable, Sendable, Equatable {
    /// What `agent.answer_form` sends back.
    public let value: String
    public let label: String
    /// omp's recommendation and the default.
    public let checked: Bool
    public let disabled: Bool

    public init(value: String, label: String, checked: Bool = false, disabled: Bool = false) {
        self.value = value
        self.label = label
        self.checked = checked
        self.disabled = disabled
    }

    enum CodingKeys: String, CodingKey { case value, label, checked, disabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = try c.decode(String.self, forKey: .value)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? value
        checked = try c.decodeIfPresent(Bool.self, forKey: .checked) ?? false
        disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
    }
}

public struct AskFormField: Decodable, Sendable, Equatable, Identifiable {
    public let name: String
    public let kind: AskFormFieldKind
    /// The section's `<legend>` when the field is alone in it (or has no label of its own),
    /// else the field's own label, else nil.
    public let title: String?
    /// Plain text of the context in this field's section before it.
    public let description: String?
    /// A checkbox group or `<select multiple>`.
    public let multi: Bool
    /// Drawn from a `<select>`: no Other.
    public let select: Bool
    /// omp adds "Other: type your own" to this field.
    public let other: Bool
    public let required: Bool
    public let options: [AskFormOption]
    /// Text fields only.
    public let inputType: String?
    public let placeholder: String?
    public let value: String?
    /// Text fields: numeric `min` / `max` (herdr sends numbers only).
    public let min: Double?
    public let max: Double?
    public let minLength: Int?
    public let maxLength: Int?
    public let pattern: String?

    public var id: String { name }

    public init(name: String, kind: AskFormFieldKind, title: String? = nil, description: String? = nil,
                multi: Bool = false, select: Bool = false, other: Bool = false, required: Bool = false,
                options: [AskFormOption] = [], inputType: String? = nil, placeholder: String? = nil,
                value: String? = nil, min: Double? = nil, max: Double? = nil, minLength: Int? = nil,
                maxLength: Int? = nil, pattern: String? = nil) {
        self.name = name
        self.kind = kind
        self.title = title
        self.description = description
        self.multi = multi
        self.select = select
        self.other = other
        self.required = required
        self.options = options
        self.inputType = inputType
        self.placeholder = placeholder
        self.value = value
        self.min = min
        self.max = max
        self.minLength = minLength
        self.maxLength = maxLength
        self.pattern = pattern
    }

    enum CodingKeys: String, CodingKey {
        case name, kind, title, description, multi, select, other, required, options, placeholder, value
        case min, max, pattern
        case inputType = "input_type"
        case minLength = "minlength"
        case maxLength = "maxlength"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try c.decode(String.self, forKey: .name),
            kind: (try c.decodeIfPresent(String.self, forKey: .kind)).flatMap(AskFormFieldKind.init(rawValue:))
                ?? .unknown,
            title: try c.decodeIfPresent(String.self, forKey: .title),
            description: try c.decodeIfPresent(String.self, forKey: .description),
            multi: try c.decodeIfPresent(Bool.self, forKey: .multi) ?? false,
            select: try c.decodeIfPresent(Bool.self, forKey: .select) ?? false,
            other: try c.decodeIfPresent(Bool.self, forKey: .other) ?? false,
            required: try c.decodeIfPresent(Bool.self, forKey: .required) ?? false,
            options: try c.decodeIfPresent([AskFormOption].self, forKey: .options) ?? [],
            inputType: try c.decodeIfPresent(String.self, forKey: .inputType),
            placeholder: try c.decodeIfPresent(String.self, forKey: .placeholder),
            value: try c.decodeIfPresent(String.self, forKey: .value),
            // Constraints the app does not enforce (herdr validates): one it cannot read
            // must not cost the form.
            min: (try? c.decodeIfPresent(Double.self, forKey: .min)) ?? nil,
            max: (try? c.decodeIfPresent(Double.self, forKey: .max)) ?? nil,
            minLength: (try? c.decodeIfPresent(Int.self, forKey: .minLength)) ?? nil,
            maxLength: (try? c.decodeIfPresent(Int.self, forKey: .maxLength)) ?? nil,
            pattern: try c.decodeIfPresent(String.self, forKey: .pattern))
    }

    /// The options omp preselected (its recommendation).
    public var defaultValues: [String] { options.filter(\.checked).map(\.value) }
}

/// One answered field, from omp's `details.answers` (`form_answer`).
public struct AskFormAnswer: Codable, Sendable, Equatable {
    public let name: String
    public let question: String
    /// The option label, `Other: <text>`, or comma-joined labels.
    public let answer: String

    public init(name: String, question: String, answer: String) {
        self.name = name
        self.question = question
        self.answer = answer
    }
}

/// How a form ask ended (`form_status`).
public enum AskFormStatus: String, Sendable, Equatable {
    case answered
    case timedOut = "timed_out"
    case cancelled
}

public struct TranscriptAsk: Sendable, Equatable {
    public let questions: [TranscriptQuestion]
    /// The options picked (`selectedOptions`); nil while unanswered. For a form: one
    /// "<title>: <answer>" line per field.
    public let answer: [String]?
    /// omp's HTML form; nil for an older `questions[]` ask.
    public let form: AskForm?
    /// The form's answers once omp recorded them.
    public let formAnswer: [AskFormAnswer]?
    public let formStatus: AskFormStatus?
    /// Local only, never on the wire: this device sent these answers and herdr could not
    /// confirm them yet (`sent_unconfirmed`). omp's own `form_answer` replaces them.
    public let sentFormAnswer: [AskFormAnswer]?

    public init(questions: [TranscriptQuestion], answer: [String]? = nil, form: AskForm? = nil,
                formAnswer: [AskFormAnswer]? = nil, formStatus: AskFormStatus? = nil,
                sentFormAnswer: [AskFormAnswer]? = nil) {
        self.questions = questions
        self.answer = answer
        self.form = form
        self.formAnswer = formAnswer
        self.formStatus = formStatus
        self.sentFormAnswer = sentFormAnswer
    }

    /// Answered, timed out or cancelled: nothing is waiting on it any more.
    public var isSettled: Bool { answer != nil || formStatus != nil }
}

public struct TranscriptEntry: Decodable, Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case user(text: String, author: TranscriptAuthor, origin: TranscriptOrigin = .mine)
        /// Markdown. `final` marks the turn's final answer; a non-final reply is text omp
        /// wrote before a tool call, a real mid-task update.
        case reply(text: String, final: Bool)
        case thinking(text: String)
        case step(TranscriptStep)
        case note(TranscriptNote)
        case plan([TranscriptPlanItem])
        case ask(TranscriptAsk)
        case turnEnd(status: TranscriptTurnEndStatus, error: String?)
        case summary(text: String)
        /// A kind this app does not know; ignored by the view (contract: clients MUST
        /// ignore unknown kinds).
        case unknown(String)
    }

    public let id: String
    public let tsMs: UInt64
    public let kind: Kind

    public init(id: String, tsMs: UInt64, kind: Kind) {
        self.id = id
        self.tsMs = tsMs
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, text, author, final, tool, intent, status, detail, source, title, from, body
        case items, questions, answer, error, origin, form
        case tsMs = "ts_ms"
        case authorName = "author_name"
        case formAnswer = "form_answer"
        case formStatus = "form_status"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        tsMs = try c.decodeIfPresent(UInt64.self, forKey: .tsMs) ?? 0
        let kindName = try c.decode(String.self, forKey: .kind)
        func text() throws -> String { try c.decodeIfPresent(String.self, forKey: .text) ?? "" }
        switch kindName {
        case "user":
            let authorName = try c.decodeIfPresent(String.self, forKey: .authorName)
            let author: TranscriptAuthor = try c.decodeIfPresent(String.self, forKey: .author) == "guest"
                ? .guest(name: authorName) : .owner
            // Only "other" is a claim; anything else (absent, unknown) stays the owner's, so
            // the up arrow never loses a turn to data it cannot read.
            let origin: TranscriptOrigin = try c.decodeIfPresent(String.self, forKey: .origin) == "other"
                ? .other : .mine
            kind = .user(text: try text(), author: author, origin: origin)
        case "reply":
            kind = .reply(text: try text(), final: try c.decodeIfPresent(Bool.self, forKey: .final) ?? false)
        case "thinking":
            kind = .thinking(text: try text())
        case "step":
            let tool = try c.decodeIfPresent(String.self, forKey: .tool) ?? ""
            let intent = try c.decodeIfPresent(String.self, forKey: .intent) ?? tool
            // An unfamiliar status is treated as finished: a step that never stops
            // "running" would keep a blue dot on forever.
            let status = (try c.decodeIfPresent(String.self, forKey: .status))
                .flatMap(TranscriptStepStatus.init(rawValue:)) ?? .ok
            kind = .step(TranscriptStep(tool: tool, intent: intent, status: status,
                                        detail: try c.decodeIfPresent(String.self, forKey: .detail)))
        case "note":
            let source = (try c.decodeIfPresent(String.self, forKey: .source))
                .flatMap(TranscriptNoteSource.init(rawValue:)) ?? .other
            kind = .note(TranscriptNote(
                source: source,
                title: try c.decodeIfPresent(String.self, forKey: .title) ?? "",
                from: try c.decodeIfPresent(String.self, forKey: .from),
                body: try c.decodeIfPresent(String.self, forKey: .body) ?? ""))
        case "plan":
            kind = .plan(try c.decodeIfPresent([TranscriptPlanItem].self, forKey: .items) ?? [])
        case "ask":
            // A form this app cannot read falls back to the `questions` herdr keeps for
            // older apps, rather than failing the page.
            kind = .ask(TranscriptAsk(
                questions: try c.decodeIfPresent([TranscriptQuestion].self, forKey: .questions) ?? [],
                answer: try c.decodeIfPresent([String].self, forKey: .answer),
                form: (try? c.decodeIfPresent(AskForm.self, forKey: .form)) ?? nil,
                formAnswer: (try? c.decodeIfPresent([AskFormAnswer].self, forKey: .formAnswer)) ?? nil,
                formStatus: (try c.decodeIfPresent(String.self, forKey: .formStatus))
                    .flatMap(AskFormStatus.init(rawValue:))))
        case "turn_end":
            let status = (try c.decodeIfPresent(String.self, forKey: .status))
                .flatMap(TranscriptTurnEndStatus.init(rawValue:)) ?? .done
            kind = .turnEnd(status: status, error: try c.decodeIfPresent(String.self, forKey: .error))
        case "summary":
            kind = .summary(text: try text())
        default:
            kind = .unknown(kindName)
        }
    }
}

/// The newest ask with no answer yet (`pending_ask`).
public struct TranscriptPendingAsk: Decodable, Sendable, Equatable {
    public let id: String
    public let questions: [TranscriptQuestion]
    /// Single question, single-select, at least one option, and this caller may answer
    /// (false for guests of a host older than guest answers): only then can the chat's
    /// buttons answer it. Always false for a form (`formAnswerable` instead).
    public let answerable: Bool
    /// omp's HTML form; nil for an older `questions[]` ask.
    public let form: AskForm?
    /// herdr can drive this form's terminal dialog for this caller (`agent.answer_form`).
    public let formAnswerable: Bool

    /// Whether the chat's buttons could answer this question's shape: one single-select
    /// question with options, exactly the server's rule for `answerable`.
    public var hasAnswerableShape: Bool {
        guard form == nil, questions.count == 1, let only = questions.first else { return false }
        return !only.multi && !only.options.isEmpty
    }

    /// The question's shape is answerable but the server says this caller may not answer
    /// it: a host that keeps answers for the owner.
    public var isWithheldFromCaller: Bool { hasAnswerableShape && !answerable }

    public init(id: String, questions: [TranscriptQuestion], answerable: Bool, form: AskForm? = nil,
                formAnswerable: Bool = false) {
        self.id = id
        self.questions = questions
        self.answerable = answerable
        self.form = form
        self.formAnswerable = formAnswerable
    }

    enum CodingKeys: String, CodingKey {
        case id, questions, answerable, form
        case formAnswerable = "form_answerable"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        questions = try c.decodeIfPresent([TranscriptQuestion].self, forKey: .questions) ?? []
        answerable = try c.decodeIfPresent(Bool.self, forKey: .answerable) ?? false
        form = (try? c.decodeIfPresent(AskForm.self, forKey: .form)) ?? nil
        formAnswerable = try c.decodeIfPresent(Bool.self, forKey: .formAnswerable) ?? false
    }
}

/// What omp is doing right now, from its newest running step.
public struct TranscriptWorking: Decodable, Sendable, Equatable {
    public let intent: String
    public let tool: String
    public let sinceMs: UInt64

    public init(intent: String, tool: String, sinceMs: UInt64) {
        self.intent = intent
        self.tool = tool
        self.sinceMs = sinceMs
    }

    enum CodingKeys: String, CodingKey {
        case intent, tool
        case sinceMs = "since_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tool = try c.decodeIfPresent(String.self, forKey: .tool) ?? ""
        intent = try c.decodeIfPresent(String.self, forKey: .intent) ?? tool
        sinceMs = try c.decodeIfPresent(UInt64.self, forKey: .sinceMs) ?? 0
    }
}

public enum TranscriptSubagentStatus: String, Sendable, Equatable {
    case running, completed, failed, aborted, unknown

    public var isRunning: Bool { self == .running }
}

/// A subagent the agent spawned with omp's `task` tool, as the page's live metadata: every
/// one still running, plus those that finished since the newest prompt.
public struct TranscriptSubagent: Decodable, Sendable, Equatable, Identifiable {
    /// omp's agent (job) id, e.g. `AppHeadReview`.
    public let id: String
    /// The agent type, e.g. `reviewer`; may be empty.
    public let agent: String
    /// omp's progress description, else the spawn's name.
    public let label: String?
    /// The start of the assignment (owner only).
    public let task: String?
    public let status: TranscriptSubagentStatus
    public let startedMs: UInt64
    public let finishedMs: UInt64?
    public let durationMs: UInt64?
    /// The intent of the subagent's newest tool call, and when it started.
    public let lastIntent: String?
    public let lastMs: UInt64?
    /// The subagent's own conversation can be paged (`agent.transcript` with `subagent`).
    public let hasTranscript: Bool

    public init(id: String, agent: String = "", label: String? = nil, task: String? = nil,
                status: TranscriptSubagentStatus, startedMs: UInt64, finishedMs: UInt64? = nil,
                durationMs: UInt64? = nil, lastIntent: String? = nil, lastMs: UInt64? = nil,
                hasTranscript: Bool = false) {
        self.id = id
        self.agent = agent
        self.label = label
        self.task = task
        self.status = status
        self.startedMs = startedMs
        self.finishedMs = finishedMs
        self.durationMs = durationMs
        self.lastIntent = lastIntent
        self.lastMs = lastMs
        self.hasTranscript = hasTranscript
    }

    enum CodingKeys: String, CodingKey {
        case id, agent, label, task, status
        case startedMs = "started_ms"
        case finishedMs = "finished_ms"
        case durationMs = "duration_ms"
        case lastIntent = "last_intent"
        case lastMs = "last_ms"
        case hasTranscript = "has_transcript"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id),
                  agent: try c.decodeIfPresent(String.self, forKey: .agent) ?? "",
                  label: try c.decodeIfPresent(String.self, forKey: .label),
                  task: try c.decodeIfPresent(String.self, forKey: .task),
                  status: try c.decodeIfPresent(String.self, forKey: .status)
                    .flatMap(TranscriptSubagentStatus.init(rawValue:)) ?? .unknown,
                  startedMs: try c.decodeIfPresent(UInt64.self, forKey: .startedMs) ?? 0,
                  finishedMs: try c.decodeIfPresent(UInt64.self, forKey: .finishedMs),
                  durationMs: try c.decodeIfPresent(UInt64.self, forKey: .durationMs),
                  lastIntent: try c.decodeIfPresent(String.self, forKey: .lastIntent),
                  lastMs: try c.decodeIfPresent(UInt64.self, forKey: .lastMs),
                  hasTranscript: try c.decodeIfPresent(Bool.self, forKey: .hasTranscript) ?? false)
    }
}

/// Result of `agent.transcript` (`type: "agent_transcript"`), entries oldest first.
public struct AgentTranscriptPage: Decodable, Sendable, Equatable {
    public let agent: String?
    public let paneID: String?
    public let sessionID: String?
    public let entries: [TranscriptEntry]
    /// Cursor for the next older page; nil once the page reached the first turn.
    public let before: String?
    /// Pass back as `after` to fetch what was appended since this page.
    public let after: String?
    public let pendingAsk: TranscriptPendingAsk?
    public let working: TranscriptWorking?
    public let model: TranscriptModel?
    public let plan: [TranscriptPlanItem]?
    public let recap: TranscriptRecap?
    /// The subagents omp's `task` tool spawned (running, and finished this turn); nil when none.
    public let subagents: [TranscriptSubagent]?

    public init(agent: String? = nil, paneID: String? = nil, sessionID: String? = nil,
                entries: [TranscriptEntry], before: String? = nil, after: String? = nil,
                pendingAsk: TranscriptPendingAsk? = nil, working: TranscriptWorking? = nil,
                model: TranscriptModel? = nil, plan: [TranscriptPlanItem]? = nil,
                recap: TranscriptRecap? = nil, subagents: [TranscriptSubagent]? = nil) {
        self.agent = agent
        self.paneID = paneID
        self.sessionID = sessionID
        self.entries = entries
        self.before = before
        self.after = after
        self.pendingAsk = pendingAsk
        self.working = working
        self.model = model
        self.plan = plan
        self.recap = recap
        self.subagents = subagents
    }

    enum CodingKeys: String, CodingKey {
        case agent, entries, before, after, working, model, plan, recap, subagents
        case paneID = "pane_id"
        case sessionID = "session_id"
        case pendingAsk = "pending_ask"
    }
}

/// Why `agent.transcript` produced no page.
public enum AgentTranscriptError: Error, Equatable, Sendable {
    case agentNotFound
    /// Not an omp agent, or herdr knows no session file for it; the Terminal view stays.
    case unsupported
    /// The session file is missing or unreadable right now.
    case unavailable
    /// The cursor is unknown to the server; restart from the newest page.
    case cursorExpired
    /// `subagent` names no subagent conversation of this agent (or the reader is a guest).
    case subagentNotFound
}

/// Result of `agent.answer`. `sentUnconfirmed`: the keys reached omp's question UI but
/// herdr could not see the selection land; the next transcript refresh tells.
public enum AgentAnswerStatus: String, Decodable, Sendable, Equatable {
    case answered
    case sentUnconfirmed = "sent_unconfirmed"
}

struct AgentAnswerResult: Decodable {
    let status: AgentAnswerStatus
}

/// Result of `agent.answer_form` (`type: "ask_form_answered"`): what omp recorded.
public struct AgentAnswerFormResult: Decodable, Sendable, Equatable {
    /// `answered`: omp's result matched what herdr typed. `sentUnconfirmed`: the keys went in
    /// but the result did not show in time, or differs; the next refresh tells.
    public let status: AgentAnswerStatus
    /// omp's `details.answers` (empty when the result has not arrived).
    public let answers: [AskFormAnswer]

    public init(status: AgentAnswerStatus, answers: [AskFormAnswer]) {
        self.status = status
        self.answers = answers
    }

    enum CodingKeys: String, CodingKey { case status, answers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = (try c.decodeIfPresent(String.self, forKey: .status)).flatMap(AgentAnswerStatus.init(rawValue:))
            ?? .answered
        answers = try c.decodeIfPresent([AskFormAnswer].self, forKey: .answers) ?? []
    }
}

/// Why `agent.answer_form` did not answer.
public enum AgentAnswerFormError: Error, Sendable, Equatable {
    /// Already answered, timed out or cancelled (`ask_not_pending`).
    case notPending
    /// herdr refused a value (`ask_form_invalid`): `field` is the text before the message's
    /// first ": ", which names a field when the form has one by that name
    /// (`AskFormDraft.reject`); field names are any text, spaces included.
    case invalid(field: String?, reason: String)
    /// omp's terminal form is no longer in its starting state, e.g. someone is answering it
    /// in the Terminal (`ask_form_moved`).
    case moved
    /// The form has controls herdr cannot drive (`ask_unsupported`).
    case unsupported
    /// Any other refusal (`forbidden`, `guest_forbidden`, an unknown agent…).
    case refused(APIError)

    init(_ error: APIError) {
        switch error.code {
        case "ask_not_pending": self = .notPending
        case "ask_form_moved": self = .moved
        case "ask_unsupported": self = .unsupported
        case "ask_form_invalid":
            // herdr's message is "<field name>: <reason>".
            if let colon = error.message.range(of: ": "), colon.lowerBound > error.message.startIndex {
                self = .invalid(field: String(error.message[..<colon.lowerBound]),
                                reason: String(error.message[colon.upperBound...]))
                return
            }
            self = .invalid(field: nil, reason: error.message)
        default: self = .refused(error)
        }
    }

    /// The server's error code.
    public var code: String {
        switch self {
        case .notPending: return "ask_not_pending"
        case .invalid: return "ask_form_invalid"
        case .moved: return "ask_form_moved"
        case .unsupported: return "ask_unsupported"
        case .refused(let error): return error.code
        }
    }

    /// The person can still answer by hand in the Terminal view: herdr cannot drive the form,
    /// or refused a value only the Terminal can enter (a textarea answer too long for omp's
    /// editor, a form whose first field is a textarea: "…; answer in the terminal").
    public var asksForTerminalAnswer: Bool {
        switch self {
        case .moved, .unsupported: return true
        case .invalid(_, let reason): return reason.hasSuffix("answer in the terminal")
        case .notPending, .refused: return false
        }
    }
}

extension APIError {
    /// `agent.answer` could not drive omp's question UI (an older omp, or the selector is not
    /// on screen); the person can still answer by hand in the Terminal view.
    public var asksForTerminalAnswer: Bool {
        code == "ask_unsupported" || code == "ask_ui_not_found"
    }
}
