import HerdrKit
import SwiftUI
import UIKit

// omp's HTML-form `ask` (omp ≥ 18.18.3) in the chat: proposal B, the stepper (owner pick
// 2026-11-10). One field per step, then a review with Submit, answered through herdr's
// `agent.answer_form`. Older `questions[]` asks keep `ChatAskCard`.

// MARK: - The draft

/// A pending form's answers in progress (`AskFormSelections`) and the step on screen.
/// `ChatModel` keeps one per ask id while the ask is pending, so a card that scrolls out of
/// the drawn window, or a chat left for the Terminal and back, finds the selections and the
/// step where they were.
@MainActor
final class AskFormDraft: ObservableObject {
    @Published private(set) var selections: AskFormSelections
    /// `0..<fields.count`: that field; `fields.count`: the review.
    @Published var step = 0
    /// The step was opened from the review: answering it goes back there.
    @Published var editingFromReview = false
    /// What herdr refused (`ask_form_invalid`), by field name.
    @Published var errors: [String: String] = [:]

    init(form: AskForm) {
        selections = AskFormSelections(form: form)
    }

    var form: AskForm { selections.form }
    var fields: [AskFormField] { form.fields }
    var reviewStep: Int { fields.count }
    var isReviewing: Bool { step >= reviewStep }
    var currentField: AskFormField? { fields.indices.contains(step) ? fields[step] : nil }

    func state(_ field: AskFormField) -> AskFormSelections.FieldState { selections.state(field) }
    func isChanged(_ field: AskFormField) -> Bool { selections.isChanged(field) }
    func isComplete(_ field: AskFormField) -> Bool { selections.isComplete(field) }
    var isComplete: Bool { selections.isComplete }
    func answerText(_ field: AskFormField) -> String { selections.answerText(field) }
    var values: [String: AskFormValue] { selections.values }
    var localAnswers: [AskFormAnswer] { selections.answers }

    func choose(_ value: String, in field: AskFormField) { mutate(field) { $0.choose(value, in: field) } }
    func chooseOther(in field: AskFormField) { mutate(field) { $0.chooseOther(in: field) } }
    func setOther(_ text: String, in field: AskFormField) { mutate(field) { $0.setOther(text, in: field) } }
    func setText(_ text: String, in field: AskFormField) { mutate(field) { $0.setText(text, in: field) } }

    private func mutate(_ field: AskFormField, _ change: (inout AskFormSelections) -> Void) {
        change(&selections)
        errors[field.name] = nil
    }

    /// The next step: the review when this one was opened from it, else the next field.
    func advance() {
        if let field = currentField { selections.dropEmptyOther(in: field) }
        if editingFromReview {
            step = reviewStep
            editingFromReview = false
        } else {
            step = min(step + 1, reviewStep)
        }
    }

    func back() {
        editingFromReview = false
        step = max(step - 1, 0)
    }

    func edit(_ index: Int) {
        step = index
        editingFromReview = true
    }

    /// herdr refused a value: its step shows why. False when the message names no field.
    func reject(field name: String?, reason: String) -> Bool {
        guard let name, let index = fields.firstIndex(where: { $0.name == name }) else { return false }
        errors[name] = reason
        editingFromReview = true
        step = index
        return true
    }
}

// MARK: - The card

/// One form ask in the chat, by state: open (the stepper, or its read-only form), answered
/// (the numbered summary of omp's answers), timed out or cancelled (one compact line).
struct ChatAskFormCard: View {
    let ask: TranscriptAsk
    let form: AskForm
    let pending: TranscriptPendingAsk?
    let viewer: ChatViewer
    /// The server's `ask_form`; nil until its ping answered.
    let formsSupported: Bool?
    /// The pending form's draft (nil once settled).
    let draft: AskFormDraft?
    let answering: Bool
    let problem: ChatAnswerProblem?
    let answersRefused: Bool
    /// Not a subagent's read-only transcript.
    let canAnswerHere: Bool
    let onSubmit: () -> Void
    let onOpenTerminal: () -> Void

    @Environment(\.chatTextScale) private var textScale

    var body: some View {
        Group {
            if ask.formAnswer != nil || ask.formStatus == .answered || ask.answer != nil {
                answered
            } else if let sent = ask.sentFormAnswer {
                sentState(sent)
            } else if let status = ask.formStatus {
                ended(status)
            } else if pending != nil, let draft {
                AskFormStepper(draft: draft, mode: mode, answering: answering, problem: problem,
                               onSubmit: onSubmit, onOpenTerminal: onOpenTerminal)
            } else {
                ended(nil)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-ask-form")
    }

    private var mode: AskFormStepper.Mode {
        let answerable = canAnswerHere && formsSupported == true && pending?.formAnswerable == true
            && form.isFillable && !(viewer.isGuest && answersRefused)
        if answerable { return .answer }
        // The capability is not known yet: nothing that may vanish a moment later.
        if formsSupported == nil || !canAnswerHere { return .browse(offersTerminal: false) }
        if case .guest(_, let owner) = viewer { return .waiting(owner: owner) }
        return .browse(offersTerminal: true)
    }

    /// Who answered, as `ChatAskCard` credits it.
    private var answeredBy: String {
        switch viewer {
        case .owner: return "You answered"
        case .guest(_, let owner): return answersRefused ? "\(owner) answered" : "Answered"
        }
    }

    /// One line per field, from omp's `details.answers` (else herdr's "<title>: <answer>").
    private var answerLines: [String] {
        if let answers = ask.formAnswer {
            return answers.map { answer in
                // omp writes "Other: <text>"; the summary shows the text, as the review did.
                let field = form.fields.first { $0.name == answer.name }
                if answer.answer.hasPrefix("Other: "),
                   field?.options.contains(where: { $0.label == answer.answer }) != true {
                    return String(answer.answer.dropFirst("Other: ".count))
                }
                return answer.answer
            }
        }
        return ask.answer ?? []
    }

    private var heading: String? {
        form.intro ?? form.fields.first?.title
    }

    private var answered: some View {
        let lines = answerLines
        return VStack(alignment: .leading, spacing: 0) {
            if let heading {
                Text(heading).font(Typography.app(14 * textScale, .medium)).foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
            }
            HStack(spacing: 7) {
                AskFormIcon.check.view(size: 13, weight: 3).foregroundStyle(ChatStyle.ok)
                Text("\(answeredBy) \(lines.count) of \(max(form.fields.count, lines.count))")
                    .font(Typography.app(14.5 * textScale)).foregroundStyle(Palette.textDim)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat-ask-form-answered")
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)").font(Typography.machine(12 * textScale)).foregroundStyle(Palette.textFaint)
                        .frame(width: 8 * textScale, alignment: .leading)
                    Text(line).font(Typography.app(14.5 * textScale, .medium)).foregroundStyle(Palette.text)
                        .lineLimit(1)
                }
                .padding(.top, 6)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chat-ask-form-answer-\(index)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(AskFormStyle.card)
    }

    /// Sent from here, not confirmed yet (`sent_unconfirmed`): what was sent, dimmed, until
    /// the transcript's `form_answer` replaces it.
    private func sentState(_ sent: [AskFormAnswer]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let heading {
                Text(heading).font(Typography.app(14 * textScale, .medium)).foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
            }
            HStack(spacing: 7) {
                AskFormIcon.chevronRight.view(size: 13).foregroundStyle(Palette.textDim)
                Text("Sent · waiting for omp to record it").font(Typography.app(14.5 * textScale))
                    .foregroundStyle(Palette.textDim)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat-ask-form-sent")
            ForEach(Array(sent.enumerated()), id: \.offset) { index, answer in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)").font(Typography.machine(12 * textScale)).foregroundStyle(Palette.textFaint)
                        .frame(width: 8 * textScale, alignment: .leading)
                    Text(answer.answer.hasPrefix("Other: ") ? String(answer.answer.dropFirst(7)) : answer.answer)
                        .font(Typography.app(14.5 * textScale, .medium)).foregroundStyle(Palette.textDim)
                        .lineLimit(1)
                }
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(AskFormStyle.card)
    }

    /// Timed out, cancelled, or no longer pending without an answer: one compact line.
    private func ended(_ status: AskFormStatus?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let heading {
                Text(heading).font(Typography.app(14 * textScale, .medium)).foregroundStyle(Palette.textDim)
                    .lineLimit(2)
            }
            Text(status == .timedOut ? "Timed out · not answered" : status == .cancelled ? "Cancelled" : "Not answered")
                .font(Typography.app(13 * textScale)).foregroundStyle(Palette.textFaint)
                .accessibilityIdentifier("chat-ask-form-ended")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(AskFormStyle.card)
    }
}

// MARK: - The stepper

struct AskFormStepper: View {
    enum Mode: Equatable {
        /// The person answers here.
        case answer
        /// Read-only steps (a server without `ask_form`, or controls herdr cannot drive);
        /// the Terminal answers.
        case browse(offersTerminal: Bool)
        /// A guest who cannot answer: the owner will.
        case waiting(owner: String)
    }

    @ObservedObject var draft: AskFormDraft
    let mode: Mode
    let answering: Bool
    let problem: ChatAnswerProblem?
    let onSubmit: () -> Void
    let onOpenTerminal: () -> Void

    @Environment(\.chatTextScale) private var textScale
    @FocusState private var focused: Bool

    private var interactive: Bool { mode == .answer && !answering }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 10)
            if draft.isReviewing, mode == .answer {
                review
            } else if let field = draft.currentField ?? draft.fields.last {
                fieldStep(field)
            }
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AskFormStyle.card)
        .animation(.easeOut(duration: 0.15), value: draft.step)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text(draft.isReviewing && mode == .answer ? "REVIEW" : "\(min(draft.step, draft.fields.count - 1) + 1) OF \(draft.fields.count)")
                .font(Typography.machine(11 * textScale, .semibold)).tracking(1.2)
                .foregroundStyle(Palette.textFaint)
                .accessibilityIdentifier("chat-ask-form-step")
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                ForEach(draft.fields.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(index < draft.step ? Palette.textDim : index == draft.step ? Palette.text : Palette.hairline)
                        .frame(width: 16, height: 4)
                }
            }
            .accessibilityHidden(true)
        }
    }

    // MARK: A field

    @ViewBuilder
    private func fieldStep(_ field: AskFormField) -> some View {
        if draft.step == 0, let intro = draft.form.intro {
            Text(intro).font(Typography.app(14 * textScale)).foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
        }
        Text(field.title ?? field.name).font(Typography.app(15 * textScale, .semibold)).foregroundStyle(Palette.text)
            .lineSpacing(0.5)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("chat-ask-form-title")
        if let description = field.description {
            Text(description).font(Typography.app(13.5 * textScale)).foregroundStyle(Palette.textDim)
                .lineSpacing(0.5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        VStack(spacing: 8) {
            switch field.kind {
            case .choice:
                ForEach(Array(field.options.enumerated()), id: \.offset) { index, option in
                    optionRow(option, index: index, in: field)
                }
                if field.other && !field.select { otherRow(field) }
            case .text:
                textInput(field)
            case .unknown:
                EmptyView()
            }
        }
        .padding(.top, 10)
        if let error = draft.errors[field.name] {
            Text(error).font(Typography.app(13 * textScale)).foregroundStyle(Palette.waiting)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .accessibilityIdentifier("chat-ask-form-error")
        }
    }

    private func optionRow(_ option: AskFormOption, index: Int, in field: AskFormField) -> some View {
        let selected = mode == .answer && draft.state(field).options.contains(option.value)
        let readOnly = mode != .answer
        return Button {
            draft.choose(option.value, in: field)
            focused = false
            // A radio is answered by the tap; a checkbox group waits for Next.
            if !field.multi { draft.advance() }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(Typography.app(15 * textScale, .medium))
                        .lineSpacing(0.5)
                        .fixedSize(horizontal: false, vertical: true)
                    if option.checked {
                        Text("Recommended").font(Typography.app(12.5 * textScale, .medium))
                            .foregroundStyle(selected ? Palette.ground.opacity(0.55) : Palette.textFaint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if field.multi, selected {
                    AskFormIcon.check.view(size: 15, weight: 3).padding(.top, 2)
                }
            }
            .foregroundStyle(selected ? Palette.ground : readOnly ? Palette.textDim : Palette.text)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(minHeight: 40)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(selected ? Palette.text : readOnly ? Color.clear : Palette.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(readOnly ? Palette.hairlineQuiet : Color.clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!interactive || option.disabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("chat-ask-form-option-\(index)")
    }

    @ViewBuilder
    private func otherRow(_ field: AskFormField) -> some View {
        if mode == .answer, let other = draft.state(field).other {
            VStack(alignment: .leading, spacing: 7) {
                Text("Other").font(Typography.app(12.5 * textScale, .medium)).foregroundStyle(Palette.textDim)
                // Wraps like the mockup's field, so Return arrives as a newline: it means Next.
                TextField("", text: Binding(get: { other }, set: { text in
                    guard text.contains("\n") else { return draft.setOther(text, in: field) }
                    draft.setOther(text.replacingOccurrences(of: "\n", with: ""), in: field)
                    if draft.isComplete(field) {
                        focused = false
                        draft.advance()
                    }
                }), axis: .vertical)
                    .font(Typography.app(15 * textScale))
                    .foregroundStyle(Palette.text)
                    .tint(Palette.brand)
                    .focused($focused)
                    .disabled(!interactive)
                    .submitLabel(.next)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.ground))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(focused ? Palette.textDim : Palette.hairline, lineWidth: 1))
                    .accessibilityIdentifier("chat-ask-form-other-field")
            }
            .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surfaceRaised))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat-ask-form-other-open")
        } else {
            Button {
                draft.chooseOther(in: field)
                // The field appears with this change: focus it once it is there.
                if draft.state(field).other != nil { DispatchQueue.main.async { focused = true } }
            } label: {
                Text("Other…").font(Typography.app(15 * textScale, .medium))
                    .foregroundStyle(Palette.textDim)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(mode == .answer ? Palette.hairline : Palette.hairlineQuiet, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(!interactive)
            .accessibilityIdentifier("chat-ask-form-other")
        }
    }

    private func textInput(_ field: AskFormField) -> some View {
        let state = draft.state(field)
        return TextField("", text: Binding(get: { state.text }, set: { draft.setText($0, in: field) }),
                         prompt: Text(field.placeholder ?? "").foregroundColor(Palette.textFaint),
                         axis: field.inputType == "textarea" ? .vertical : .horizontal)
            .font(Typography.app(15 * textScale))
            .foregroundStyle(mode == .answer ? Palette.text : Palette.textDim)
            .tint(Palette.brand)
            .keyboardType(Self.keyboard(field.inputType))
            .textInputAutocapitalization(["email", "url"].contains(field.inputType ?? "")
                                         ? TextInputAutocapitalization.never : .sentences)
            .focused($focused)
            .disabled(!interactive)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.ground))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(focused ? Palette.textDim : Palette.hairline, lineWidth: 1))
            .accessibilityIdentifier("chat-ask-form-text")
    }

    private static func keyboard(_ inputType: String?) -> UIKeyboardType {
        switch inputType {
        case "number": return .decimalPad
        case "email": return .emailAddress
        case "url": return .URL
        default: return .default
        }
    }

    // MARK: The review

    private var review: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Check your answers").font(Typography.app(15 * textScale, .semibold)).foregroundStyle(Palette.text)
            VStack(spacing: 0) {
                ForEach(Array(draft.fields.enumerated()), id: \.offset) { index, field in
                    Button {
                        draft.edit(index)
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(field.title ?? field.name).font(Typography.app(13 * textScale))
                                    .foregroundStyle(Palette.textDim).lineLimit(1)
                                Text(draft.answerText(field)).font(Typography.app(14.5 * textScale, .medium))
                                    .foregroundStyle(Palette.text).lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 4) {
                                if draft.isChanged(field) {
                                    Text("Changed").font(Typography.app(12.5 * textScale, .semibold))
                                        .foregroundStyle(Palette.text)
                                        .accessibilityIdentifier("chat-ask-form-changed")
                                }
                                AskFormIcon.chevronRight.view(size: 15).foregroundStyle(Palette.textFaint)
                            }
                        }
                        .padding(.vertical, 9)
                        .overlay(alignment: .top) {
                            if index > 0 { Rectangle().fill(Palette.hairlineQuiet).frame(height: 1) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(answering)
                    .accessibilityIdentifier("chat-ask-form-review-\(index)")
                }
            }
            .padding(.top, 8).padding(.bottom, 12)
            Button(action: onSubmit) {
                HStack(spacing: 8) {
                    if answering { ProgressView().tint(Palette.ground).controlSize(.small) }
                    Text(answering ? "Submitting…" : "Submit").font(Typography.app(15 * textScale, .semibold))
                }
                .foregroundStyle(Palette.ground)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(RoundedRectangle(cornerRadius: 12).fill(Palette.text))
                .opacity(draft.isComplete ? 1 : 0.5)
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(answering || !draft.isComplete)
            .accessibilityIdentifier("chat-ask-form-submit")
        }
    }

    // MARK: The footer

    @ViewBuilder
    private var footer: some View {
        switch mode {
        case .waiting(let owner):
            HStack(spacing: 8) {
                Circle().fill(Palette.waiting).frame(width: 7, height: 7)
                Text("WAITING FOR \(owner.uppercased()) TO ANSWER")
                    .font(Typography.machine(10.5 * textScale, .semibold)).tracking(1.2).foregroundStyle(Palette.waiting)
            }
            .padding(.top, 10)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat-ask-waiting")
        case .browse(let offersTerminal):
            navigation(next: .link("Next"))
            if offersTerminal { terminalButton.padding(.top, 10) }
        case .answer:
            if draft.isReviewing {
                HStack {
                    backLink
                    Spacer(minLength: 8)
                    Text("Tap an answer to change it").font(Typography.app(13 * textScale)).foregroundStyle(Palette.textFaint)
                }
                .padding(.top, 12)
                .frame(minHeight: 34 + 12)
            } else if let field = draft.currentField {
                // A radio answered by a tap moves on by itself, so its step offers the review;
                // a step that needs a confirmation (Other's text, a checkbox group, a text field)
                // offers Next.
                navigation(next: field.kind == .choice && !field.multi && draft.state(field).other == nil
                           ? .reviewAll : .button(enabled: draft.isComplete(field)))
            }
            if let problem {
                VStack(alignment: .leading, spacing: 8) {
                    Text(problem.message).font(Typography.app(13 * textScale)).foregroundStyle(Palette.waiting)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("chat-ask-problem")
                    if problem.offersTerminal { terminalButton }
                }
                .padding(.top, 10)
            }
        }
    }

    private enum Next {
        case link(String)
        case reviewAll
        case button(enabled: Bool)
    }

    private func navigation(next: Next) -> some View {
        HStack {
            backLink
            Spacer(minLength: 8)
            switch next {
            case .link(let title):
                let enabled = draft.step < draft.fields.count - 1
                Button { draft.step += 1 } label: { link(title, chevron: .chevronRight, enabled: enabled) }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                    .accessibilityIdentifier("chat-ask-form-next")
            case .reviewAll:
                Button {
                    focused = false
                    draft.editingFromReview = false
                    draft.step = draft.reviewStep
                } label: { link("Review all", chevron: .chevronRight, enabled: interactive) }
                    .buttonStyle(.plain)
                    .disabled(!interactive)
                    .accessibilityIdentifier("chat-ask-form-review-all")
            case .button(let enabled):
                Button {
                    focused = false
                    draft.advance()
                } label: {
                    Text("Next").font(Typography.app(14 * textScale, .semibold))
                        .foregroundStyle(Palette.ground)
                        .padding(.horizontal, 20).frame(height: 34)
                        .background(Capsule().fill(Palette.text))
                        .opacity(enabled ? 1 : 0.5)
                }
                .buttonStyle(.plain)
                .disabled(!enabled || !interactive)
                .accessibilityIdentifier("chat-ask-form-next")
            }
        }
        .padding(.top, 12)
        .frame(minHeight: 34 + 12)
    }

    private var backLink: some View {
        let enabled = draft.step > 0 && !answering
        return Button {
            focused = false
            draft.back()
        } label: {
            HStack(spacing: 3) {
                AskFormIcon.chevronLeft.view(size: 15)
                Text("Back").font(Typography.app(14 * textScale, .semibold))
            }
            .foregroundStyle(enabled ? Palette.textDim : AskFormStyle.disabled)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier("chat-ask-form-back")
    }

    private func link(_ title: String, chevron: AskFormIcon, enabled: Bool) -> some View {
        HStack(spacing: 3) {
            Text(title).font(Typography.app(14 * textScale, .semibold))
            chevron.view(size: 15)
        }
        .foregroundStyle(enabled ? Palette.textDim : AskFormStyle.disabled)
        .contentShape(Rectangle())
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
}

// MARK: - Style

enum AskFormStyle {
    /// A control that cannot be used right now (the first step's Back): the mockup's #3A3F66.
    static let disabled = Color(hex: 0x3A3F66)

    static var card: some View {
        RoundedRectangle(cornerRadius: 16).fill(Palette.surface)
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

/// The mockup's stroked icons (24-unit grid, round caps), drawn rather than taken from SF
/// Symbols so their weight matches the design.
enum AskFormIcon {
    case chevronLeft, chevronRight, check

    private var points: [CGPoint] {
        switch self {
        case .chevronLeft: return [CGPoint(x: 15, y: 18), CGPoint(x: 9, y: 12), CGPoint(x: 15, y: 6)]
        case .chevronRight: return [CGPoint(x: 9, y: 18), CGPoint(x: 15, y: 12), CGPoint(x: 9, y: 6)]
        case .check: return [CGPoint(x: 5, y: 12.5), CGPoint(x: 9.5, y: 17), CGPoint(x: 19, y: 7.5)]
        }
    }

    /// `weight` is the stroke in grid units (the mockup's `stroke-width`).
    func view(size: CGFloat, weight: CGFloat = 2) -> some View {
        Path { path in
            path.addLines(points.map { CGPoint(x: $0.x * size / 24, y: $0.y * size / 24) })
        }
        .stroke(style: StrokeStyle(lineWidth: weight * size / 24, lineCap: .round, lineJoin: .round))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
