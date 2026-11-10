import Foundation
import XCTest
@testable import HerdrKit

/// omp's HTML-form `ask` (omp ≥ 18.18.3) on the wire (herdr's `form`, `form_answer`,
/// `form_status`, `form_answerable`, `capabilities.ask_form`), `agent.answer_form`, and the
/// stepper's selections. The form is the enyo-ui ask of 2026-11-10 (two of its fields) plus
/// the proposals' checkbox field.
final class AskFormDecodingTests: XCTestCase {

    static let formJSON = #"""
    {"intro":"Before enyo-ui starts building from iteration 5, five choices.",
     "fields":[
      {"name":"where","kind":"choice","title":"Where to build","description":"lenscale.ai is public today.",
       "multi":false,"select":false,"other":true,"required":false,
       "options":[{"value":"preview","label":"preview.lenscale.ai","checked":true,"disabled":false},
                  {"value":"apex","label":"Hide lenscale.ai now","checked":false,"disabled":false}],
       "input_type":null,"placeholder":null,"value":null,"min":null,"max":null,"minlength":null,"maxlength":null,"pattern":null},
      {"name":"form","kind":"choice","title":"Where 'Book a demo' requests go","description":null,
       "multi":false,"select":false,"other":true,"required":false,
       "options":[{"value":"dashboard","label":"A row in the Team dashboard","checked":true,"disabled":false},
                  {"value":"email","label":"Email to an inbox","checked":false,"disabled":false}]},
      {"name":"updates","kind":"choice","title":"While it builds, send me","description":"Choose any.",
       "multi":true,"select":false,"other":true,"required":false,
       "options":[{"value":"gram","label":"A Gram when each page is ready","checked":true},
                  {"value":"preview","label":"Preview links after each page group","checked":true},
                  {"value":"evening","label":"A summary every evening","checked":false}]},
      {"name":"notes","kind":"text","title":"Anything else?","multi":false,"select":false,"other":false,
       "required":false,"options":[],"input_type":"textarea","placeholder":"Optional","value":null,
       "min":1,"max":20.5,"minlength":2,"maxlength":200,"pattern":null}
     ]}
    """#

    static func form() throws -> AskForm {
        try JSONDecoder().decode(AskForm.self, from: Data(formJSON.utf8))
    }

    private func decodePage(_ json: String) throws -> AgentTranscriptPage {
        try JSONDecoder().decode(AgentTranscriptPage.self, from: Data(json.utf8))
    }

    func testFormAskDecodesTheFormItsAnswerAndStatus() throws {
        let page = try decodePage(#"""
        {"type":"agent_transcript","entries":[
          {"id":"a1","ts_ms":5,"kind":"ask",
           "questions":[{"question":"Where to build","options":["preview.lenscale.ai","Hide lenscale.ai now"],"multi":false,"recommended":0}],
           "answer":["Where to build: Hide lenscale.ai now"],
           "form":\#(Self.formJSON),
           "form_answer":[{"name":"where","question":"Where to build","answer":"Hide lenscale.ai now"},
                          {"name":"form","question":"Where 'Book a demo' requests go","answer":"Other: demo@lenscale.ai"}],
           "form_status":"answered"},
          {"id":"a2","ts_ms":6,"kind":"ask","questions":[],"form":\#(Self.formJSON),"form_status":"timed_out"},
          {"id":"a3","ts_ms":7,"kind":"ask","questions":[],"form":\#(Self.formJSON),"form_status":"cancelled"}
         ],"before":null,"after":"a"}
        """#)
        guard case .ask(let answered) = page.entries[0].kind else { return XCTFail("not an ask") }
        let form = try XCTUnwrap(answered.form)
        XCTAssertEqual(form.intro, "Before enyo-ui starts building from iteration 5, five choices.")
        XCTAssertEqual(form.fields.map(\.name), ["where", "form", "updates", "notes"])
        XCTAssertEqual(form.fields[0].kind, .choice)
        XCTAssertEqual(form.fields[0].description, "lenscale.ai is public today.")
        XCTAssertEqual(form.fields[0].defaultValues, ["preview"])
        XCTAssertTrue(form.fields[0].other)
        XCTAssertTrue(form.fields[2].multi)
        XCTAssertEqual(form.fields[2].defaultValues, ["gram", "preview"])
        let notes = form.fields[3]
        XCTAssertEqual(notes.kind, .text)
        XCTAssertEqual(notes.inputType, "textarea")
        XCTAssertEqual(notes.placeholder, "Optional")
        XCTAssertEqual(notes.min, 1)
        XCTAssertEqual(notes.max, 20.5)
        XCTAssertEqual(notes.minLength, 2)
        XCTAssertEqual(notes.maxLength, 200)
        XCTAssertTrue(form.isFillable)
        XCTAssertEqual(answered.formAnswer?.map(\.answer), ["Hide lenscale.ai now", "Other: demo@lenscale.ai"])
        XCTAssertEqual(answered.formStatus, .answered)
        XCTAssertTrue(answered.isSettled)
        // The old fields stay for older apps.
        XCTAssertEqual(answered.questions.first?.question, "Where to build")
        XCTAssertEqual(answered.answer, ["Where to build: Hide lenscale.ai now"])

        guard case .ask(let timedOut) = page.entries[1].kind, case .ask(let cancelled) = page.entries[2].kind else {
            return XCTFail("not asks")
        }
        XCTAssertEqual(timedOut.formStatus, .timedOut)
        XCTAssertNil(timedOut.answer)
        XCTAssertTrue(timedOut.isSettled, "a timed-out form waits on nothing")
        XCTAssertEqual(cancelled.formStatus, .cancelled)
    }

    func testOldQuestionsAskDecodesAsBefore() throws {
        let page = try decodePage(#"""
        {"type":"agent_transcript","entries":[
          {"id":"a1","ts_ms":5,"kind":"ask","questions":[{"question":"Merge?","options":["Yes","No"],"multi":false,"recommended":0}]}
         ],"before":null,"after":"a",
         "pending_ask":{"id":"a1","questions":[{"question":"Merge?","options":["Yes","No"],"multi":false}],"answerable":true}}
        """#)
        guard case .ask(let ask) = page.entries[0].kind else { return XCTFail("not an ask") }
        XCTAssertEqual(ask, TranscriptAsk(questions: [TranscriptQuestion(question: "Merge?", options: ["Yes", "No"],
                                                                          recommended: 0)]))
        XCTAssertNil(ask.form)
        XCTAssertFalse(ask.isSettled)
        let pending = try XCTUnwrap(page.pendingAsk)
        XCTAssertNil(pending.form)
        XCTAssertFalse(pending.formAnswerable)
        XCTAssertTrue(pending.answerable)
        XCTAssertTrue(pending.hasAnswerableShape)
    }

    func testPendingFormAskCarriesTheFormAndFormAnswerable() throws {
        let page = try decodePage(#"""
        {"type":"agent_transcript","entries":[],"before":null,"after":"a",
         "pending_ask":{"id":"a1","questions":[{"question":"Where to build","options":["preview.lenscale.ai","Hide lenscale.ai now"],"multi":false}],
                        "answerable":false,"form":\#(Self.formJSON),"form_answerable":true}}
        """#)
        let pending = try XCTUnwrap(page.pendingAsk)
        XCTAssertEqual(pending.form?.fields.count, 4)
        XCTAssertTrue(pending.formAnswerable)
        XCTAssertFalse(pending.answerable)
        XCTAssertFalse(pending.hasAnswerableShape, "a form is never answered with the old buttons")
        XCTAssertFalse(pending.isWithheldFromCaller, "a form never marks the guest's host as owner-only")
    }

    /// A field kind this app does not know keeps the page and the form, read-only.
    func testUnknownFieldKindKeepsTheFormReadOnly() throws {
        let form = try JSONDecoder().decode(AskForm.self, from: Data(#"""
        {"intro":null,"fields":[{"name":"x","kind":"slider","title":"X"}]}
        """#.utf8))
        XCTAssertEqual(form.fields.first?.kind, .unknown)
        XCTAssertFalse(form.isFillable)
    }

    func testAskFormCapabilityDecodes() throws {
        func capabilities(_ json: String) throws -> ServerCapabilities {
            try JSONDecoder().decode(ServerCapabilities.self, from: Data(json.utf8))
        }
        XCTAssertTrue(try capabilities(#"{"agent_answer":true,"ask_form":true}"#).askForm)
        XCTAssertFalse(try capabilities(#"{"agent_answer":true}"#).askForm, "an older server has no ask_form")
    }
}

final class AskFormClientTests: XCTestCase {

    func testAnswerFormSendsOnlyTheGivenValuesAndDecodesTheAnswers() async throws {
        let transport = RecordingTransport(reply: #"""
        {"id":"x","result":{"type":"ask_form_answered","status":"answered",
         "answers":[{"name":"where","question":"Where to build","answer":"Hide lenscale.ai now"}]}}
        """#)
        let client = HerdrClient(transport: transport)
        let result = try await client.agentAnswerForm(target: "w1:p1", askID: "call_7", values: [
            "where": .choice(options: ["apex"]),
            "form": .choice(options: [], other: "ops@lenscale.ai"),
            "notes": .text("Ship it"),
        ])
        XCTAssertEqual(result.status, .answered)
        XCTAssertEqual(result.answers, [AskFormAnswer(name: "where", question: "Where to build", answer: "Hide lenscale.ai now")])
        let (method, params) = try transport.last()
        XCTAssertEqual(method, "agent.answer_form")
        XCTAssertEqual(params["target"] as? String, "w1:p1")
        XCTAssertEqual(params["ask_id"] as? String, "call_7")
        let values = try XCTUnwrap(params["values"] as? [String: [String: Any]])
        XCTAssertEqual(Set(values.keys), ["where", "form", "notes"])
        XCTAssertEqual(values["where"]?["options"] as? [String], ["apex"])
        XCTAssertNil(values["where"]?["other"], "no Other key unless Other was chosen")
        XCTAssertEqual(values["form"]?["options"] as? [String], [])
        XCTAssertEqual(values["form"]?["other"] as? String, "ops@lenscale.ai")
        XCTAssertEqual(values["notes"]?["text"] as? String, "Ship it")
    }

    func testAcceptingTheRecommendationsSendsEmptyValues() async throws {
        let transport = RecordingTransport(reply: #"{"id":"x","result":{"type":"ask_form_answered","status":"sent_unconfirmed","answers":[]}}"#)
        let result = try await HerdrClient(transport: transport).agentAnswerForm(target: "w1:p1", askID: "a", values: [:])
        XCTAssertEqual(result.status, .sentUnconfirmed)
        XCTAssertEqual(result.answers, [])
        let values = try XCTUnwrap(try transport.last().params["values"] as? [String: Any])
        XCTAssertTrue(values.isEmpty)
    }

    func testAnswerFormRefusalsAreTyped() async {
        let cases: [(String, String, AgentAnswerFormError)] = [
            ("ask_not_pending", "already answered", .notPending),
            ("ask_form_moved", "the form is not at its start", .moved),
            ("ask_unsupported", "unsupported control", .unsupported),
            ("ask_form_invalid", "form: Other needs text", .invalid(field: "form", reason: "Other needs text")),
            ("ask_form_invalid", "pick exactly one option", .invalid(field: nil, reason: "pick exactly one option")),
            ("ask_form_invalid", "notes: too long to edit from the app; answer in the terminal",
             .invalid(field: "notes", reason: "too long to edit from the app; answer in the terminal")),
            ("forbidden", "no", .refused(APIError(code: "forbidden", message: "no"))),
        ]
        for (code, message, expected) in cases {
            let client = HerdrClient(transport: RecordingTransport.error(code: code, message: message))
            do {
                _ = try await client.agentAnswerForm(target: "w1:p1", askID: "a", values: [:])
                XCTFail("\(code) should throw")
            } catch {
                XCTAssertEqual(error as? AgentAnswerFormError, expected, "\(code): \(message)")
                XCTAssertEqual((error as? AgentAnswerFormError)?.code, code)
            }
        }
        XCTAssertTrue(AgentAnswerFormError.moved.asksForTerminalAnswer)
        XCTAssertTrue(AgentAnswerFormError.unsupported.asksForTerminalAnswer)
        XCTAssertFalse(AgentAnswerFormError.notPending.asksForTerminalAnswer)
        XCTAssertFalse(AgentAnswerFormError.invalid(field: "x", reason: "y").asksForTerminalAnswer)
        // herdr #394: values only the Terminal can enter.
        XCTAssertTrue(AgentAnswerFormError.invalid(
            field: "notes", reason: "too long to edit from the app; answer in the terminal").asksForTerminalAnswer)
        XCTAssertTrue(AgentAnswerFormError.invalid(
            field: "notes", reason: "the form's first field cannot be edited from the app; answer in the terminal")
            .asksForTerminalAnswer)
    }

    func testAdvertisesAskFormReadsThePing() async {
        let yes = HerdrClient(transport: RecordingTransport(
            reply: #"{"id":"x","result":{"type":"pong","version":"1","protocol":22,"capabilities":{"ask_form":true}}}"#))
        let no = HerdrClient(transport: RecordingTransport(
            reply: #"{"id":"x","result":{"type":"pong","version":"1","protocol":22,"capabilities":{"agent_answer":true}}}"#))
        let advertised = await yes.advertisesAskForm()
        let missing = await no.advertisesAskForm()
        XCTAssertTrue(advertised)
        XCTAssertFalse(missing)
    }
}

final class AskFormSelectionsTests: XCTestCase {

    func testUntouchedFormSendsNoValuesAndReadsAsTheRecommendations() throws {
        let form = try AskFormDecodingTests.form()
        let selections = AskFormSelections(form: form)
        XCTAssertEqual(selections.values, [:], "an untouched form accepts omp's recommendations")
        XCTAssertTrue(selections.isComplete)
        XCTAssertFalse(form.fields.contains { selections.isChanged($0) })
        XCTAssertEqual(selections.answerText(form.fields[2]), "A Gram when each page is ready, Preview links after each page group")
        XCTAssertEqual(selections.answers.map(\.answer), [
            "preview.lenscale.ai", "A row in the Team dashboard",
            "A Gram when each page is ready, Preview links after each page group", "",
        ])
    }

    func testChangedRadioOtherAndCheckboxAreTheOnlyValuesSent() throws {
        let form = try AskFormDecodingTests.form()
        let (whereField, formField, updates) = (form.fields[0], form.fields[1], form.fields[2])
        var selections = AskFormSelections(form: form)

        selections.choose("apex", in: whereField)
        XCTAssertTrue(selections.isChanged(whereField))

        selections.chooseOther(in: formField)
        XCTAssertFalse(selections.isComplete(formField), "Other chosen needs its text")
        selections.setOther("Both: a dashboard row and email to demo@lenscale.ai", in: formField)
        XCTAssertTrue(selections.isComplete(formField))

        selections.choose("evening", in: updates)
        selections.choose("gram", in: updates)
        XCTAssertEqual(selections.state(updates).options, ["preview", "evening"], "kept in the form's order")

        XCTAssertEqual(selections.values, [
            "where": .choice(options: ["apex"]),
            "form": .choice(options: [], other: "Both: a dashboard row and email to demo@lenscale.ai"),
            "updates": .choice(options: ["preview", "evening"]),
        ])
        XCTAssertEqual(selections.answerText(formField), "Both: a dashboard row and email to demo@lenscale.ai")
        XCTAssertEqual(selections.answers[1].answer, "Other: Both: a dashboard row and email to demo@lenscale.ai",
                       "as omp records Other")

        // Picking an option again closes Other; back to the default is no change at all.
        selections.choose("dashboard", in: formField)
        XCTAssertNil(selections.state(formField).other)
        XCTAssertFalse(selections.isChanged(formField))
        selections.choose("preview", in: whereField)
        XCTAssertEqual(Set(selections.values.keys), ["updates"])
    }

    func testEmptyOtherIsNotAChangeAndACheckboxGroupDropsIt() throws {
        let form = try AskFormDecodingTests.form()
        let updates = form.fields[2]
        var selections = AskFormSelections(form: form)
        selections.chooseOther(in: updates)
        XCTAssertEqual(selections.state(updates).other, "")
        XCTAssertFalse(selections.isChanged(updates), "an empty Other is not an answer")
        XCTAssertTrue(selections.isComplete(updates))
        selections.dropEmptyOther(in: updates)
        XCTAssertNil(selections.state(updates).other)
    }

    func testTextFieldValue() throws {
        let form = try AskFormDecodingTests.form()
        let notes = form.fields[3]
        var selections = AskFormSelections(form: form)
        selections.setText("Ship it", in: notes)
        XCTAssertEqual(selections.values, ["notes": .text("Ship it")])
        XCTAssertEqual(selections.answerText(notes), "Ship it")
    }

    func testRequiredRadioWithoutADefaultBlocksUntilPicked() {
        let field = AskFormField(name: "env", kind: .choice, title: "Env", required: true,
                                 options: [AskFormOption(value: "a", label: "A"), AskFormOption(value: "b", label: "B")])
        var selections = AskFormSelections(form: AskForm(fields: [field]))
        XCTAssertFalse(selections.isComplete)
        selections.choose("b", in: field)
        XCTAssertTrue(selections.isComplete)
        XCTAssertEqual(selections.values, ["env": .choice(options: ["b"])])
    }
}

@MainActor
final class AskFormStoreTests: XCTestCase {

    private static func page(_ entries: String, pendingAsk: String) -> String {
        #"{"id":"x","result":{"type":"agent_transcript","session_id":"s1","entries":[\#(entries)],"before":null,"after":"a","pending_ask":\#(pendingAsk),"working":null}}"#
    }

    private static let askEntry = #"{"id":"a1","ts_ms":1,"kind":"ask","questions":[],"form":\#(AskFormDecodingTests.formJSON)}"#
    private static let pending = #"{"id":"a1","questions":[],"answerable":false,"form":\#(AskFormDecodingTests.formJSON),"form_answerable":true}"#

    func testLocalFormAnswerReplacesTheStepperUntilTheServerReportsIt() async throws {
        let transport = RecordingTransport { _, _ in Self.page(Self.askEntry, pendingAsk: Self.pending) }
        let client = HerdrClient(transport: transport)
        let store = TranscriptStore(target: "w1:p1")
        await store.refresh(client: client)
        guard case .ask(_, let open, let pending)? = store.turns.last?.items.last else { return XCTFail("no ask") }
        XCTAssertNotNil(pending?.form)
        XCTAssertTrue(pending?.formAnswerable == true)
        XCTAssertNotNil(open.form)

        let answers = [AskFormAnswer(name: "where", question: "Where to build", answer: "Hide lenscale.ai now")]
        store.noteFormAnswered(askID: "a1", answers: answers)
        XCTAssertNil(store.pendingAsk)
        guard case .ask(_, let answered, let after)? = store.turns.last?.items.last else { return XCTFail("no ask") }
        XCTAssertNil(after, "an answered form offers no stepper")
        XCTAssertEqual(answered.formAnswer, answers)
        XCTAssertEqual(answered.formStatus, .answered)
        XCTAssertNotNil(answered.form)

        // A refresh that still reports the form open keeps the answer sent from here.
        await store.refresh(client: client)
        guard case .ask(_, let kept, let again)? = store.turns.last?.items.last else { return XCTFail("no ask") }
        XCTAssertNil(again)
        XCTAssertEqual(kept.formAnswer, answers)
    }

    /// `sent_unconfirmed`: the card shows what was sent, not as omp's answer, until the
    /// transcript's `form_answer` arrives and replaces it.
    func testUnconfirmedFormAnswerShowsSentUntilTheTranscriptAnswers() async throws {
        var answered = false
        let recorded = #"{"id":"a1","ts_ms":1,"kind":"ask","questions":[],"form":\#(AskFormDecodingTests.formJSON),"form_answer":[{"name":"where","question":"Where to build","answer":"Hide lenscale.ai now"}],"form_status":"answered","answer":["Where to build: Hide lenscale.ai now"]}"#
        let transport = RecordingTransport { _, _ in
            answered ? Self.page(recorded, pendingAsk: "null") : Self.page(Self.askEntry, pendingAsk: Self.pending)
        }
        let client = HerdrClient(transport: transport)
        let store = TranscriptStore(target: "w1:p1")
        await store.refresh(client: client)
        let sent = [AskFormAnswer(name: "where", question: "Where to build", answer: "Hide lenscale.ai now")]
        store.noteFormAnswered(askID: "a1", answers: sent, confirmed: false)
        guard case .ask(_, let waiting, let pending)? = store.turns.last?.items.last else { return XCTFail("no ask") }
        XCTAssertNil(pending, "no stepper once sent")
        XCTAssertEqual(waiting.sentFormAnswer, sent)
        XCTAssertNil(waiting.formAnswer, "not shown as omp's answer before omp records it")

        // A refresh still reporting the form open keeps "Sent".
        await store.refresh(client: client)
        guard case .ask(_, let still, nil)? = store.turns.last?.items.last else { return XCTFail("no ask") }
        XCTAssertEqual(still.sentFormAnswer, sent)

        answered = true
        await store.refresh(client: client)
        guard case .ask(_, let done, nil)? = store.turns.last?.items.last else { return XCTFail("no ask") }
        XCTAssertNil(done.sentFormAnswer)
        XCTAssertEqual(done.formAnswer, sent)
        XCTAssertEqual(done.formStatus, .answered)
    }

    /// A stale `pending_ask` for a form that already timed out adds no live stepper.
    func testEndedFormIsNotPending() async throws {
        let ended = #"{"id":"a1","ts_ms":1,"kind":"ask","questions":[],"form":\#(AskFormDecodingTests.formJSON),"form_status":"timed_out"}"#
        let transport = RecordingTransport { _, _ in Self.page(ended, pendingAsk: Self.pending) }
        let store = TranscriptStore(target: "w1:p1")
        await store.refresh(client: HerdrClient(transport: transport))
        XCTAssertEqual(store.turns.flatMap(\.items).count, 1)
        guard case .ask(_, let ask, let pending)? = store.turns.last?.items.last else { return XCTFail("no ask") }
        XCTAssertNil(pending)
        XCTAssertEqual(ask.formStatus, .timedOut)
    }

    /// The pending form's entry is not on the loaded page: the card still gets the form.
    func testPendingFormWithoutItsEntryKeepsTheForm() async throws {
        let transport = RecordingTransport { _, _ in
            Self.page(#"{"id":"u1","ts_ms":1,"kind":"user","text":"Go","author":"owner"}"#, pendingAsk: Self.pending)
        }
        let store = TranscriptStore(target: "w1:p1")
        await store.refresh(client: HerdrClient(transport: transport))
        guard case .ask(let id, let ask, _)? = store.turns.last?.items.last else { return XCTFail("no ask") }
        XCTAssertEqual(id, "a1")
        XCTAssertEqual(ask.form?.fields.count, 4)
    }
}

/// Replays herdr's replies captured from a scratch server driving a REAL omp 18.18.6 form
/// ask (herdr feat/ask-form caa0c14a): the pending page, `agent.answer_form`, and the page
/// once omp recorded the answer. The live wire shape, not hand-written JSON.
@MainActor
final class AskFormLiveCaptureTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/live-askform-\(name).json")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testCapturedFormAskDecodesAnswersAndSettles() async throws {
        let pendingPage = try fixture("transcript-pending")
        let answeredPage = try fixture("transcript-answered")
        let answerReply = try fixture("answer-form")
        var answered = false
        let transport = RecordingTransport { method, _ in
            if method == "agent.answer_form" {
                answered = true
                return answerReply
            }
            return answered ? answeredPage : pendingPage
        }
        let client = HerdrClient(transport: transport)
        let store = TranscriptStore(target: "w1:p1")
        await store.refresh(client: client)

        let pending = try XCTUnwrap(store.pendingAsk)
        let form = try XCTUnwrap(pending.form)
        XCTAssertTrue(pending.formAnswerable)
        XCTAssertFalse(pending.answerable)
        XCTAssertEqual(form.intro, "Smoke test.")
        XCTAssertEqual(form.fields.map(\.name), ["colour", "extras"])
        XCTAssertEqual(form.fields.map(\.multi), [false, true])
        XCTAssertTrue(form.isFillable)
        guard case .ask(_, _, let open)? = store.turns.flatMap(\.items).last(where: {
            if case .ask = $0 { return true } else { return false }
        }) else { return XCTFail("no ask card") }
        XCTAssertEqual(open?.id, pending.id, "the card carries the pending form")

        var selections = AskFormSelections(form: form)
        selections.choose("blue", in: form.fields[0])
        selections.choose("cheese", in: form.fields[1])
        selections.choose("olives", in: form.fields[1])
        selections.chooseOther(in: form.fields[1])
        selections.setOther("basil", in: form.fields[1])
        let result = try await client.agentAnswerForm(target: "w1:p1", askID: pending.id, values: selections.values)
        XCTAssertEqual(result.status, .answered)
        XCTAssertEqual(result.answers.map(\.answer), selections.answers.map(\.answer),
                       "the app's own reading of the answers matches omp's")
        let sent = try XCTUnwrap(try transport.last().params["values"] as? [String: [String: Any]])
        XCTAssertEqual(sent["colour"]?["options"] as? [String], ["blue"])
        XCTAssertEqual(sent["extras"]?["options"] as? [String], ["olives"])
        XCTAssertEqual(sent["extras"]?["other"] as? String, "basil")

        store.noteFormAnswered(askID: pending.id, answers: result.answers)
        await store.refresh(client: client)
        XCTAssertNil(store.pendingAsk)
        guard case .ask(_, let ask, let after)? = store.turns.flatMap(\.items).last(where: {
            if case .ask = $0 { return true } else { return false }
        }) else { return XCTFail("no ask card") }
        XCTAssertNil(after)
        XCTAssertEqual(ask.formStatus, .answered)
        XCTAssertEqual(ask.formAnswer?.map(\.answer), ["Blue", "Olives, Other: basil"])
        XCTAssertEqual(ask.answer, ["Colour: Blue", "Extras: Olives, Other: basil"])
    }
}
