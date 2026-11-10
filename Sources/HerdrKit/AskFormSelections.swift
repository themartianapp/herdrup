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
    private var states: [String: FieldState]

    public init(form: AskForm) {
        self.form = form
        states = Dictionary(form.fields.map { ($0.name, Self.defaultState($0)) },
                            uniquingKeysWith: { first, _ in first })
    }

    public static func defaultState(_ field: AskFormField) -> FieldState {
        FieldState(options: field.defaultValues, other: nil, text: field.value ?? "")
    }

    public func state(_ field: AskFormField) -> FieldState { states[field.name] ?? Self.defaultState(field) }

    /// The value as it would be sent: an Other left empty counts as not chosen.
    private func settled(_ field: AskFormField) -> FieldState {
        var state = state(field)
        if let other = state.other, other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { state.other = nil }
        return state
    }

    public func isChanged(_ field: AskFormField) -> Bool { settled(field) != Self.defaultState(field) }

    /// Picks `value`: a radio's only choice (Other closes), a checkbox toggled.
    public mutating func choose(_ value: String, in field: AskFormField) {
        var state = state(field)
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
        states[field.name] = state
    }

    /// Opens Other's text (a radio drops its option); on a checkbox group Other toggles.
    public mutating func chooseOther(in field: AskFormField) {
        var state = state(field)
        if field.multi {
            state.other = state.other == nil ? "" : nil
        } else {
            state.options = []
            if state.other == nil { state.other = "" }
        }
        states[field.name] = state
    }

    public mutating func setOther(_ text: String, in field: AskFormField) {
        states[field.name, default: Self.defaultState(field)].other = text
    }

    public mutating func setText(_ text: String, in field: AskFormField) {
        states[field.name, default: Self.defaultState(field)].text = text
    }

    /// A checkbox group's Other left empty is dropped when the step is left.
    public mutating func dropEmptyOther(in field: AskFormField) {
        guard field.multi, let other = state(field).other,
              other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        states[field.name, default: Self.defaultState(field)].other = nil
    }

    /// Whether the field can be left forward: a radio needs an option or Other's text, a
    /// radio's Other needs its text, and a required field a value.
    public func isComplete(_ field: AskFormField) -> Bool {
        let raw = state(field)
        let state = settled(field)
        switch field.kind {
        case .choice:
            if !field.multi {
                if raw.other != nil { return state.other != nil }
                return !state.options.isEmpty || !field.required && field.defaultValues.isEmpty
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
            case .choice: values[field.name] = .choice(options: state.options, other: state.other)
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
