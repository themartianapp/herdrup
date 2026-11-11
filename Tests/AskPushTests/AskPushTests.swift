import XCTest
@testable import AskPush

/// A question push (herdr#309) as APNs hands it to the app and the extension. Synthetic.
private func questionPush(
    options: [Any] = ["Yes", "No"], dropping: String? = nil, extra: [String: Any] = [:]
) -> [AnyHashable: Any] {
    var ask: [String: Any] = [
        "agent": "builder", "pane_id": "w1:p3", "machine_id": "machine_abc",
        "ask_id": "call_42", "question": "Ship it?", "options": options,
    ]
    if let dropping { ask.removeValue(forKey: dropping) }
    var userInfo: [AnyHashable: Any] = [
        "aps": ["alert": ["title": "builder asks", "body": "Ship it?"], "category": "herdr.ask", "mutable-content": 1],
        "pane_id": "w1:p3", "workspace_id": "w1", "herdr_ask": ask,
    ]
    for (key, value) in extra { userInfo[key] = value }
    return userInfo
}

final class AskPushPayloadTests: XCTestCase {
    func testQuestionPushDecodes() throws {
        let ask = try XCTUnwrap(AskPush(userInfo: questionPush()))
        XCTAssertEqual(ask, AskPush(agent: "builder", paneID: "w1:p3", machineID: "machine_abc",
                                    askID: "call_42", question: "Ship it?", options: ["Yes", "No"]))
    }

    func testPushesWithoutAQuestionGetNoButtons() {
        // Today's NeedsInput, finish and gram pushes carry no herdr_ask.
        XCTAssertNil(AskPush(userInfo: ["aps": ["alert": ["title": "t"]], "pane_id": "w1:p3", "workspace_id": "w1"]))
        XCTAssertNil(AskPush(userInfo: ["aps": [:], "pane_id": "", "gram": true]))
        XCTAssertNil(AskPush(userInfo: [:]))
        XCTAssertNil(AskPush(userInfo: ["herdr_ask": "not an object"]))
    }

    func testGuestPushNeverGetsButtons() {
        XCTAssertNil(AskPush(userInfo: questionPush(extra: ["herdr_guest": ["host_id": "h1"]])))
    }

    func testMissingIdentifiersRefuseTheQuestion() {
        XCTAssertNil(AskPush(userInfo: questionPush(dropping: "pane_id")))
        XCTAssertNil(AskPush(userInfo: questionPush(dropping: "ask_id")))
        XCTAssertNil(AskPush(userInfo: questionPush(dropping: "options")))
        XCTAssertNil(AskPush(userInfo: questionPush(extra: ["herdr_ask": ["pane_id": " ", "ask_id": "a", "options": ["x"]]])))
    }

    func testOptionalFieldsFallBack() throws {
        let noMachine = try XCTUnwrap(AskPush(userInfo: questionPush(dropping: "machine_id")))
        XCTAssertNil(noMachine.machineID)
        let noAgent = try XCTUnwrap(AskPush(userInfo: questionPush(dropping: "agent")))
        XCTAssertEqual(noAgent.agent, "omp")
        let noQuestion = try XCTUnwrap(AskPush(userInfo: questionPush(dropping: "question")))
        XCTAssertEqual(noQuestion.question, "")
    }

    func testOptionCountIsOneToFour() {
        XCTAssertNil(AskPush(userInfo: questionPush(options: [])))
        XCTAssertEqual(AskPush(userInfo: questionPush(options: ["a"]))?.options, ["a"])
        XCTAssertEqual(AskPush(userInfo: questionPush(options: ["a", "b", "c", "d"]))?.options.count, 4)
        XCTAssertNil(AskPush(userInfo: questionPush(options: ["a", "b", "c", "d", "e"])),
                     "a lock screen must not offer only some of the choices")
    }

    func testAnUnusableOptionRefusesTheWholeList() {
        XCTAssertNil(AskPush(userInfo: questionPush(options: ["Yes", 2])))
        XCTAssertNil(AskPush(userInfo: questionPush(options: ["Yes", "  "])))
    }
}

final class AskCategoryTests: XCTestCase {
    func testOneAuthenticatedActionPerOptionInOrder() throws {
        let ask = try XCTUnwrap(AskPush(userInfo: questionPush(options: ["Merge", "Wait", "Abort"])))
        let category = AskCategory(ask, registeredAt: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(category.identifier, "herdr.ask.1000.call_42")
        XCTAssertEqual(AskCategory.registeredAt(category.identifier), Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(category.actions, [
            .init(identifier: "herdr.ask.option.0", title: "Merge"),
            .init(identifier: "herdr.ask.option.1", title: "Wait"),
            .init(identifier: "herdr.ask.option.2", title: "Abort"),
        ])
    }

    func testEachAskGetsItsOwnCategory() throws {
        let first = try XCTUnwrap(AskPush(userInfo: questionPush()))
        let second = try XCTUnwrap(AskPush(userInfo: questionPush(extra: [
            "herdr_ask": ["pane_id": "w1:p3", "ask_id": "call_43", "options": ["Yes", "No"]],
        ])))
        XCTAssertNotEqual(AskCategory(first).identifier, AskCategory(second).identifier)
    }

    func testOptionIndexParsesOnlyOurActions() {
        XCTAssertEqual(AskCategory.optionIndex(actionIdentifier: "herdr.ask.option.3"), 3)
        XCTAssertNil(AskCategory.optionIndex(actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier"))
        XCTAssertNil(AskCategory.optionIndex(actionIdentifier: "herdr.ask.option.x"))
        XCTAssertNil(AskCategory.optionIndex(actionIdentifier: "herdr.ask.call_42"))
    }

    func testRegistrationDropsAskCategoriesNoLongerOnScreen() {
        let now = Date(timeIntervalSince1970: 10_000)
        let keep = AskCategory.retained(
            existing: ["herdr.ask.9000.old", "herdr.ask.9000.shown", "herdr.ask.unparsable", "someone.else"],
            delivered: ["herdr.ask.9000.shown", ""],
            adding: "herdr.ask.10000.new",
            now: now)
        XCTAssertEqual(keep, ["herdr.ask.9000.shown", "someone.else", "herdr.ask.10000.new"])
    }

    /// Two questions pushed moments apart: the second extension registers while the first
    /// notification is still on its way, so the first category is not delivered yet. It
    /// must survive, or the first notification shows without buttons (#488 review f1).
    func testACategoryStillInFlightSurvivesTheNextRegistration() {
        let now = Date(timeIntervalSince1970: 10_000)
        let first = "herdr.ask.\(10_000 - 2).call_42"
        let expired = "herdr.ask.\(10_000 - Int(AskCategory.inFlightGrace)).call_41"
        let keep = AskCategory.retained(existing: [first, expired], delivered: [],
                                        adding: "herdr.ask.10000.call_43", now: now)
        XCTAssertEqual(keep, [first, "herdr.ask.10000.call_43"])
    }
}

final class AskActionRouteTests: XCTestCase {
    func testButtonAnswersWithThatOptionsText() throws {
        let route = AskActionRoute(actionIdentifier: "herdr.ask.option.1", userInfo: questionPush())
        let ask = try XCTUnwrap(AskPush(userInfo: questionPush()))
        XCTAssertEqual(route, .answer(ask, option: "No"))
    }

    func testTappingTheNotificationIsNotAnAnswer() {
        XCTAssertEqual(AskActionRoute(actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier",
                                      userInfo: questionPush()), .other)
    }

    func testIndexOutsideTheOptionsIsNotAnAnswer() {
        XCTAssertEqual(AskActionRoute(actionIdentifier: "herdr.ask.option.2", userInfo: questionPush()), .other)
        XCTAssertEqual(AskActionRoute(actionIdentifier: "herdr.ask.option.-1", userInfo: questionPush()), .other)
    }

    func testGuestPushNeverAnswers() {
        let guest = questionPush(extra: ["herdr_guest": ["host_id": "h1"]])
        XCTAssertEqual(AskActionRoute(actionIdentifier: "herdr.ask.option.0", userInfo: guest), .other)
    }
}

final class AskAnswerRoutesTests: XCTestCase {
    private let mac = AskAnswerEndpoint(host: "mac.local", port: 22, username: "jo", session: nil)
    private let macWork = AskAnswerEndpoint(host: "mac.local", port: 22, username: "jo", session: "work")
    private let box = AskAnswerEndpoint(host: "10.0.0.2", port: 2222, username: "root", session: nil)

    func testRecordedMachineResolvesNewestFirst() {
        var routes = AskAnswerRoutes()
        routes.record(machineID: "m1", endpoint: mac)
        routes.record(machineID: "m1", endpoint: macWork)
        routes.record(machineID: "m2", endpoint: box)
        XCTAssertEqual(routes.candidates(machineID: "m1", onlySavedHost: box), [macWork, mac])
        XCTAssertEqual(routes.candidates(machineID: "m2", onlySavedHost: nil), [box])
        routes.record(machineID: "m1", endpoint: mac)
        XCTAssertEqual(routes.candidates(machineID: "m1", onlySavedHost: nil), [mac, macWork], "re-recording moves it first, once")
    }

    func testEndpointMovesToAReinstalledMachine() {
        var routes = AskAnswerRoutes()
        routes.record(machineID: "old", endpoint: mac)
        routes.record(machineID: "new", endpoint: mac)
        XCTAssertEqual(routes.candidates(machineID: "old", onlySavedHost: nil), [])
        XCTAssertEqual(routes.machines.keys.sorted(), ["new"])
    }

    func testPerMachineCap() {
        var routes = AskAnswerRoutes()
        for n in 0..<6 {
            routes.record(machineID: "m1", endpoint: .init(host: "h", port: 22, username: "u", session: "s\(n)"))
        }
        XCTAssertEqual(routes.candidates(machineID: "m1", onlySavedHost: nil).map(\.session),
                       ["s5", "s4", "s3", "s2"])
    }

    func testUnknownMachineFallsBackToTheOnlySavedHost() {
        let routes = AskAnswerRoutes()
        XCTAssertEqual(routes.candidates(machineID: "m9", onlySavedHost: mac), [mac])
        XCTAssertEqual(routes.candidates(machineID: nil, onlySavedHost: mac), [mac])
        XCTAssertEqual(routes.candidates(machineID: "m9", onlySavedHost: nil), [])
    }

    func testRoutesSurviveCoding() throws {
        var routes = AskAnswerRoutes()
        routes.record(machineID: "m1", endpoint: macWork)
        let decoded = try JSONDecoder().decode(AskAnswerRoutes.self, from: JSONEncoder().encode(routes))
        XCTAssertEqual(decoded, routes)
    }
}

final class AskAnswerOutcomeTests: XCTestCase {
    private let a = AskAnswerEndpoint(host: "a", port: 22, username: "u", session: nil)
    private let b = AskAnswerEndpoint(host: "b", port: 22, username: "u", session: nil)

    /// Runs `resolve` with scripted attempts, returning the outcome and who was asked.
    private func resolve(_ script: [String: AskAnswerAttempt], candidates: [AskAnswerEndpoint]? = nil)
        async -> (AskAnswerOutcome, [String]) {
        var asked: [String] = []
        let outcome = await AskAnswerOutcome.resolve(candidates: candidates ?? [a, b]) { endpoint in
            asked.append(endpoint.host)
            return script[endpoint.host] ?? .unreachable
        }
        return (outcome, asked)
    }

    func testAnsweredStopsAtTheFirstDaemon() async {
        let (outcome, asked) = await resolve(["a": .status("answered"), "b": .status("answered")])
        XCTAssertEqual(outcome, .answered)
        XCTAssertEqual(asked, ["a"])
    }

    func testSentUnconfirmed() async {
        let (outcome, _) = await resolve(["a": .status("sent_unconfirmed")])
        XCTAssertEqual(outcome, .sentUnconfirmed)
    }

    func testAskNotPendingMeansAlreadyAnswered() async {
        let (outcome, asked) = await resolve(["a": .refused(code: "ask_not_pending"), "b": .status("answered")])
        XCTAssertEqual(outcome, .alreadyAnswered)
        XCTAssertEqual(asked, ["a"], "a refused answer is final: never sent twice")
    }

    func testWrongSessionTriesTheNextEndpoint() async {
        let (outcome, asked) = await resolve(["a": .refused(code: "agent_not_found"), "b": .status("answered")])
        XCTAssertEqual(outcome, .answered)
        XCTAssertEqual(asked, ["a", "b"])
    }

    func testUnreachableTriesTheNextEndpoint() async {
        let (outcome, asked) = await resolve(["b": .status("answered")])
        XCTAssertEqual(outcome, .answered)
        XCTAssertEqual(asked, ["a", "b"])
    }

    func testTerminalOnlyQuestionNeedsTheApp() async {
        for code in ["ask_unsupported", "ask_ui_not_found", "selection_mismatch", "forbidden", "unknown_method"] {
            let (outcome, asked) = await resolve(["a": .refused(code: code), "b": .status("answered")])
            XCTAssertEqual(outcome, .needsApp, code)
            XCTAssertEqual(asked, ["a"], code)
        }
    }

    func testAgentGoneEverywhereNeedsTheApp() async {
        let (outcome, _) = await resolve(["a": .refused(code: "agent_not_found"), "b": .refused(code: "pane_not_found")])
        XCTAssertEqual(outcome, .needsApp)
    }

    func testNothingReachableOrNoRoute() async {
        let (down, _) = await resolve([:])
        XCTAssertEqual(down, .unreachable)
        let (none, asked) = await resolve([:], candidates: [])
        XCTAssertEqual(none, .unreachable)
        XCTAssertEqual(asked, [])
    }

    func testFollowUpMessages() throws {
        let ask = try XCTUnwrap(AskPush(userInfo: questionPush()))
        XCTAssertEqual(AskAnswerOutcome.answered.message(for: ask, option: "Yes").body, "You chose “Yes”.")
        XCTAssertEqual(AskAnswerOutcome.answered.message(for: ask, option: "Yes").title, "builder")
        XCTAssertEqual(AskAnswerOutcome.alreadyAnswered.message(for: ask, option: "Yes").body,
                       "This question was already answered.")
        XCTAssertEqual(AskAnswerOutcome.needsApp.message(for: ask, option: "Yes").body, "Open herdrup to answer: Ship it?")
        XCTAssertEqual(AskAnswerOutcome.unreachable.message(for: ask, option: "Yes").title, "Couldn't reach builder")
    }
}

// MARK: - Form pushes (omp's HTML-form ask)

/// A form push as herdr sends it: `options` empty, `form` with its count, intro and whether
/// every required field has a default. Synthetic.
private func formPush(acceptDefaults: Any = true, count: Any = 6) -> [AnyHashable: Any] {
    [
        "aps": ["alert": ["title": "enyo-ui asks", "body": "6 choices · recommended preselected"],
                "category": "herdr.ask_form", "mutable-content": 1],
        "pane_id": "w1:p3", "workspace_id": "w1",
        "herdr_ask": [
            "agent": "enyo-ui", "pane_id": "w1:p3", "machine_id": "machine_abc", "ask_id": "call_form",
            "question": "Before enyo-ui starts building, five choices.", "options": [] as [String],
            "form": ["count": count, "intro": "Before enyo-ui starts building, five choices.",
                     "accept_defaults": acceptDefaults] as [String: Any],
        ] as [String: Any],
    ]
}

final class AskFormPushTests: XCTestCase {
    func testFormPushDecodesWithItsForm() throws {
        let ask = try XCTUnwrap(AskPush(userInfo: formPush()))
        XCTAssertEqual(ask.askID, "call_form")
        XCTAssertEqual(ask.paneID, "w1:p3")
        XCTAssertEqual(ask.options, [])
        XCTAssertEqual(ask.form, AskPush.Form(count: 6, intro: "Before enyo-ui starts building, five choices."))
    }

    func testFormWithoutDefaultsForEveryRequiredFieldGetsNoButton() {
        XCTAssertNil(AskPush(userInfo: formPush(acceptDefaults: false)))
        XCTAssertNil(AskPush(userInfo: formPush(acceptDefaults: "yes")))
        XCTAssertNil(AskPush(userInfo: formPush(count: 0)))
        var guest = formPush()
        guest["herdr_guest"] = ["host_id": "h1"]
        XCTAssertNil(AskPush(userInfo: guest), "a guest never answers from the lock screen")
    }

    func testFormCategoryHasTheOneAcceptAction() throws {
        let ask = try XCTUnwrap(AskPush(userInfo: formPush()))
        let category = AskCategory(ask, registeredAt: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(category.identifier, "herdr.ask.1000.call_form")
        XCTAssertEqual(category.actions, [AskCategory.Action(identifier: "accept_defaults", title: "Accept recommendations")])
    }

    func testAcceptActionRoutesToTheFormAndOptionActionsDoNot() throws {
        let ask = try XCTUnwrap(AskPush(userInfo: formPush()))
        XCTAssertEqual(AskActionRoute(actionIdentifier: "accept_defaults", userInfo: formPush()), .acceptRecommendations(ask))
        XCTAssertEqual(AskActionRoute(actionIdentifier: "herdr.ask.option.0", userInfo: formPush()), .other)
        XCTAssertEqual(AskActionRoute(actionIdentifier: "accept_defaults", userInfo: questionPush()), .other,
                       "a single question has no accept action")
    }

    func testFormFollowUpMessages() throws {
        let ask = try XCTUnwrap(AskPush(userInfo: formPush()))
        XCTAssertEqual(AskAnswerOutcome.answered.message(for: ask, option: nil).body, "You accepted the recommendations.")
        XCTAssertEqual(AskAnswerOutcome.alreadyAnswered.message(for: ask, option: nil).body, "This form was already answered.")
        XCTAssertEqual(AskAnswerOutcome.needsApp.message(for: ask, option: nil).body,
                       "Open herdrup to answer: Before enyo-ui starts building, five choices.")
    }
}
