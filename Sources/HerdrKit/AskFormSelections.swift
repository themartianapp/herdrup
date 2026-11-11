import Foundation

/// What the person picked on an omp form ask so far, field by field, starting from omp's
/// defaults (its recommendation). Pure, so the Chat's stepper and its tests share the rules
/// `agent.answer_form` is sent with.
public struct AskFormSelections: Sendable, Equatable {
    public struct FieldState: Sendable, Equatable {
        /// The chosen option values, in the form's order (a radio holds at most one).
        public var options: [String]
        /// Other's text; nil while Other is not chosen.
        public var other: String?
        /// A text field's value.
        public var text: String

        public init(options: [String] = [], other: String? = nil, text: String = "") {
            self.options = options
            self.other = other
            self.text = text
        }
    }

    public let form: AskForm
    /// Only what the person changed, by the field's place in the form: an untouched field reads
    /// its own default, also where two fields share a name (such a form is read-only, but each
    /// field shows its own value).
    private var edits: [Int: FieldState] = [:]

    public init(form: AskForm) {
        self.form = form
    }

    public static func defaultState(_ field: AskFormField) -> FieldState {
        FieldState(options: field.defaultValues, other: nil, text: field.value ?? "")
    }

    /// The field's place in the form. Two identical fields share the first's, which is no
    /// loss: they have the same default, and a form with duplicate names is not answerable.
    private func index(_ field: AskFormField) -> Int? { form.fields.firstIndex(of: field) }

    public func state(_ field: AskFormField) -> FieldState {
        index(field).flatMap { edits[$0] } ?? Self.defaultState(field)
    }

    private mutating func update(_ field: AskFormField, _ change: (inout FieldState) -> Void) {
        guard let index = index(field) else { return }
        var state = state(field)
        change(&state)
        edits[index] = state
    }

    /// A radio that may be left without an answer: optional, and omp checked none of it.
    private static func mayBeUnanswered(_ field: AskFormField) -> Bool {
        !field.multi && !field.required && field.defaultValues.isEmpty
    }

    /// The value as it would be sent: an Other left empty counts as not chosen.
    private func settled(_ field: AskFormField) -> FieldState {
        var state = state(field)
        if let other = state.other, other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { state.other = nil }
        return state
    }

    public func isChanged(_ field: AskFormField) -> Bool { settled(field) != Self.defaultState(field) }

    /// Picks `value`: a radio's only choice (Other closes), a checkbox toggled.
    public mutating func choose(_ value: String, in field: AskFormField) {
        update(field) { state in
            if field.multi {
                if state.options.contains(value) {
                    state.options.removeAll { $0 == value }
                } else {
                    let chosen = Set(state.options + [value])
                    state.options = field.options.map(\.value).filter(chosen.contains)
                }
            } else {
                state.options = [value]
                state.other = nil
            }
        }
    }

    /// Opens Other's text (a radio drops its option); on a checkbox group Other toggles.
    public mutating func chooseOther(in field: AskFormField) {
        update(field) { state in
            if field.multi {
                state.other = state.other == nil ? "" : nil
            } else {
                state.options = []
                if state.other == nil { state.other = "" }
            }
        }
    }

    public mutating func setOther(_ text: String, in field: AskFormField) {
        update(field) { $0.other = text }
    }

    public mutating func setText(_ text: String, in field: AskFormField) {
        update(field) { $0.text = text }
    }

    /// An Other left empty closes when its step is left: a checkbox group's, and an optional
    /// radio's without a default, which is unanswered again. Any other radio's stays open:
    /// its step cannot be left until it has text or an option.
    public mutating func dropEmptyOther(in field: AskFormField) {
        guard field.multi || Self.mayBeUnanswered(field), let other = state(field).other,
              other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        update(field) { $0.other = nil }
    }

    /// Whether the field can be left forward: a radio needs an option or Other's text unless
    /// it may be left unanswered, and a required field a value.
    public func isComplete(_ field: AskFormField) -> Bool {
        let raw = state(field)
        let state = settled(field)
        switch field.kind {
        case .choice:
            if !field.multi {
                if Self.mayBeUnanswered(field) { return true }
                if raw.other != nil { return state.other != nil }
                return !state.options.isEmpty
            }
            return !field.required || !state.options.isEmpty || state.other != nil
        case .text:
            return !field.required || !state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .unknown:
            return true
        }
    }

    public var isComplete: Bool { form.fields.allSatisfy(isComplete) }

    /// Only the changed fields: herdr keeps omp's default for every field left out, so an
    /// untouched form sends `[:]` ("accept the recommendations").
    public var values: [String: AskFormValue] {
        var values: [String: AskFormValue] = [:]
        for field in form.fields where isChanged(field) {
            let state = settled(field)
            switch field.kind {
            case .choice:
                // herdr refuses a disabled option in `values` and keeps its state itself.
                let disabled = Set(field.options.filter(\.disabled).map(\.value))
                values[field.name] = .choice(options: state.options.filter { !disabled.contains($0) },
                                             other: state.other)
            case .text: values[field.name] = .text(state.text)
            case .unknown: break
            }
        }
        return values
    }

    /// What the field's answer reads as in the review: the option labels and Other's text.
    public func answerText(_ field: AskFormField) -> String {
        let state = settled(field)
        switch field.kind {
        case .choice:
            let all = field.options.filter { state.options.contains($0.value) }.map(\.label) + (state.other.map { [$0] } ?? [])
            return all.isEmpty ? "No answer" : all.joined(separator: ", ")
        case .text:
            return state.text.isEmpty ? "No answer" : state.text
        case .unknown:
            return ""
        }
    }

    /// The answers as omp records them (`details.answers`: labels comma-joined, `Other: <text>`),
    /// for the card until the transcript reports omp's own.
    public var answers: [AskFormAnswer] {
        form.fields.filter { $0.kind != .unknown }.map { field in
            let state = settled(field)
            let answer: String
            switch field.kind {
            case .text:
                answer = state.text
            default:
                answer = (field.options.filter { state.options.contains($0.value) }.map(\.label)
                          + (state.other.map { ["Other: \($0)"] } ?? [])).joined(separator: ", ")
            }
            return AskFormAnswer(name: field.name, question: field.title ?? field.name, answer: answer)
        }
    }
}

extension AskForm {
    /// One answer as the card's answered and sent summaries show it. omp records a choice
    /// field's Other as "Other: <text>", which shows as the text, as the review showed it.
    /// Anything else shows as recorded: a text field's answer, an option labelled "Other: …",
    /// or an answer whose field this form does not have.
    public func summaryLine(_ answer: AskFormAnswer) -> String {
        let prefix = "Other: "
        guard answer.answer.hasPrefix(prefix),
              let field = fields.first(where: { $0.name == answer.name }),
              field.kind == .choice, field.other,
              !field.options.contains(where: { $0.label == answer.answer }) else { return answer.answer }
        return String(answer.answer.dropFirst(prefix.count))
    }
}
