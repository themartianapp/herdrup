import Foundation

// Shared verbatim by the notification service extension (which turns a question push into
// lock-screen buttons) and the app (which answers when one is pressed), and tested on Linux
// as the `AskPush` package target. Foundation only: the extension must not link HerdrKit,
// whose SSH stack would cost the extension's small memory budget for nothing.

/// The omp question a NeedsInput push carries as `herdr_ask` (herdr#309): only for an
/// answerable ask — one single-select question, or an HTML form whose every required field
/// has a default — on an agent local to the pushing daemon.
struct AskPush: Equatable, Sendable {
    /// The most buttons iOS shows on a notification.
    static let maxOptions = 4

    /// An omp HTML-form ask (`herdr_ask.form`): its one button accepts omp's recommendations.
    struct Form: Equatable, Sendable {
        /// How many fields the form has.
        let count: Int
        let intro: String?
    }

    /// Display name only; `paneID` is what `agent.answer` targets.
    let agent: String
    let paneID: String
    /// The pushing daemon's install id (`agent.list` `origin_machine_id`); nil when absent.
    let machineID: String?
    let askID: String
    let question: String
    /// Empty for a form.
    let options: [String]
    /// Set for an omp HTML-form ask.
    let form: Form?

    init(agent: String, paneID: String, machineID: String?, askID: String, question: String, options: [String],
         form: Form? = nil) {
        self.agent = agent
        self.paneID = paneID
        self.machineID = machineID
        self.askID = askID
        self.question = question
        self.options = options
        self.form = form
    }

    /// Nil unless the push is an owner question with 1...4 usable options, or an owner form
    /// herdr says can be accepted as recommended (`form.accept_defaults`). A guest push is
    /// refused even if it carries `herdr_ask`: guests can never answer. More than four
    /// options is refused rather than truncated, because a lock screen offering some of the
    /// choices reads as if those were all of them; the notification still opens the chat.
    init?(userInfo: [AnyHashable: Any]) {
        guard userInfo["herdr_guest"] == nil,
              let ask = userInfo["herdr_ask"] as? [String: Any],
              let paneID = Self.nonEmpty(ask["pane_id"]),
              let askID = Self.nonEmpty(ask["ask_id"]) else { return nil }
        if let form = ask["form"] as? [String: Any] {
            // A required field without a default cannot be accepted as it is: no button.
            guard form["accept_defaults"] as? Bool == true, let count = form["count"] as? Int, count > 0 else {
                return nil
            }
            self.init(agent: Self.nonEmpty(ask["agent"]) ?? "omp", paneID: paneID,
                      machineID: Self.nonEmpty(ask["machine_id"]), askID: askID,
                      question: (ask["question"] as? String) ?? "", options: [],
                      form: Form(count: count, intro: Self.nonEmpty(form["intro"])))
            return
        }
        guard let rawOptions = ask["options"] as? [Any] else { return nil }
        // The server matches the answer by option TEXT, so a blank or non-string entry is
        // unanswerable; one is enough to distrust the whole list.
        let options = rawOptions.compactMap { Self.nonEmpty($0) }
        guard options.count == rawOptions.count, (1...Self.maxOptions).contains(options.count) else { return nil }
        self.init(
            agent: Self.nonEmpty(ask["agent"]) ?? "omp",
            paneID: paneID,
            machineID: Self.nonEmpty(ask["machine_id"]),
            askID: askID,
            question: (ask["question"] as? String) ?? "",
            options: options)
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return string
    }
}

/// The notification category one question gets: one action per option, or a form's one
/// "Accept recommendations". Action titles are the option texts, so each ask needs its own
/// category. The identifier carries the second
/// it was registered (`herdr.ask.<seconds>.<ask id>`) so a later prune can tell a category
/// whose notification is still on its way from one whose notification is gone.
struct AskCategory: Equatable, Sendable {
    struct Action: Equatable, Sendable {
        let identifier: String
        let title: String
    }

    static let identifierPrefix = "herdr.ask."
    /// How long a registered category survives a prune without a delivered notification.
    /// iOS gives a service extension about 30 s, so a notification still in flight after
    /// this has been delivered (or dropped) and the delivered set is authoritative.
    static let inFlightGrace: TimeInterval = 120
    static let actionPrefix = "herdr.ask.option."
    /// A form's one action, named as herdr's own `herdr.ask_form` category names it.
    static let acceptDefaultsAction = "accept_defaults"
    static let acceptDefaultsTitle = "Accept recommendations"

    let identifier: String
    let actions: [Action]

    init(_ ask: AskPush, registeredAt: Date = Date()) {
        identifier = Self.identifierPrefix + "\(Int(registeredAt.timeIntervalSince1970)).\(ask.askID)"
        if ask.form != nil {
            actions = [Action(identifier: Self.acceptDefaultsAction, title: Self.acceptDefaultsTitle)]
            return
        }
        // The action carries the option's INDEX, not its text: the response handler reads the
        // text back from the same payload, so no option text has to survive as an identifier.
        actions = ask.options.enumerated().map { index, option in
            Action(identifier: Self.actionPrefix + String(index), title: option)
        }
    }

    /// The option index an action identifier names, or nil for any other action.
    static func optionIndex(actionIdentifier: String) -> Int? {
        guard actionIdentifier.hasPrefix(actionPrefix) else { return nil }
        return Int(actionIdentifier.dropFirst(actionPrefix.count))
    }

    /// When an ask category was registered, read back from its identifier; nil for any other
    /// category.
    static func registeredAt(_ identifier: String) -> Date? {
        guard identifier.hasPrefix(identifierPrefix),
              let seconds = Int(identifier.dropFirst(identifierPrefix.count).prefix { $0 != "." }) else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Which registered categories to keep when `adding` one. Registration replaces the
    /// app's whole set, and every question adds a category, so ask categories whose
    /// notification is gone are dropped (their buttons can no longer be pressed). An ask
    /// category registered within `inFlightGrace` is kept even when its notification is not
    /// delivered yet: another question's extension may have registered it a moment ago and
    /// still be about to show it. Anything that is not an ask category is kept untouched.
    static func retained(existing: [String], delivered: Set<String>, adding: String, now: Date = Date()) -> Set<String> {
        var keep = Set(existing.filter { identifier in
            guard identifier.hasPrefix(identifierPrefix) else { return true }
            if delivered.contains(identifier) { return true }
            guard let registered = registeredAt(identifier) else { return false }
            return now.timeIntervalSince(registered) < inFlightGrace
        })
        keep.insert(adding)
        return keep
    }
}
