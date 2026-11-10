import Foundation

// App-side half of the lock-screen question buttons: what a pressed button means, which
// saved connection reaches the asking daemon, and what to tell the user afterwards. The
// I/O (SSH, `agent.answer`, posting the notification) stays in App/AskPushAnswer.swift;
// everything here is pure so it is tested on Linux.

/// What a notification response asks the app to do.
enum AskActionRoute: Equatable, Sendable {
    /// One of the question's buttons: answer `ask` with `option`.
    case answer(AskPush, option: String)
    /// A form's "Accept recommendations": `agent.answer_form` with no values.
    case acceptRecommendations(AskPush)
    /// Anything else (the notification itself was tapped): the usual tap routing.
    case other

    init(actionIdentifier: String, userInfo: [AnyHashable: Any]) {
        if actionIdentifier == AskCategory.acceptDefaultsAction {
            guard let ask = AskPush(userInfo: userInfo), ask.form != nil else {
                self = .other
                return
            }
            self = .acceptRecommendations(ask)
            return
        }
        guard let index = AskCategory.optionIndex(actionIdentifier: actionIdentifier),
              let ask = AskPush(userInfo: userInfo),
              ask.form == nil, ask.options.indices.contains(index) else {
            self = .other
            return
        }
        self = .answer(ask, option: ask.options[index])
    }
}

/// A non-secret way back to one herdr daemon: the saved host it was reached through and
/// the herdr session. The secret stays in the Keychain under the matching saved host.
struct AskAnswerEndpoint: Codable, Equatable, Sendable {
    let host: String
    let port: UInt16
    let username: String
    /// nil is the default session.
    let session: String?
}

/// Which endpoints reach each daemon, by the install id its question pushes name as
/// `machine_id`. Recorded whenever the phone registers for that daemon's pushes, so every
/// daemon that can push a question has an entry. Newest first.
struct AskAnswerRoutes: Codable, Equatable, Sendable {
    /// Sessions on one machine share its install id, so a machine can have several.
    static let maxPerMachine = 4

    private(set) var machines: [String: [AskAnswerEndpoint]] = [:]

    mutating func record(machineID: String, endpoint: AskAnswerEndpoint) {
        // An endpoint reaches exactly one install: if herdr was reinstalled behind it, the
        // old id's entry is stale. Dropping it everywhere also bounds the store by the
        // phone's own saved hosts.
        for (id, endpoints) in machines {
            let rest = endpoints.filter { $0 != endpoint }
            machines[id] = rest.isEmpty ? nil : rest
        }
        machines[machineID] = Array(([endpoint] + (machines[machineID] ?? [])).prefix(Self.maxPerMachine))
    }

    /// Where to send the answer, in order. `onlySavedHost` (the phone's single saved host, if
    /// it has exactly one) covers a daemon never recorded — e.g. an app updated while
    /// connected, which has not re-registered since — where there is no other candidate.
    func candidates(machineID: String?, onlySavedHost: AskAnswerEndpoint?) -> [AskAnswerEndpoint] {
        if let machineID, let endpoints = machines[machineID], !endpoints.isEmpty { return endpoints }
        return onlySavedHost.map { [$0] } ?? []
    }
}

/// The result of one `agent.answer` attempt through one endpoint.
enum AskAnswerAttempt: Equatable, Sendable {
    /// The server's `status` (`answered` / `sent_unconfirmed`).
    case status(String)
    /// The server refused with this `error.code`.
    case refused(code: String)
    /// The daemon could not be reached or did not reply.
    case unreachable
}

/// What came of pressing a button, and what the follow-up notification says.
enum AskAnswerOutcome: Equatable, Sendable {
    case answered
    /// The keys reached omp but the server did not see the answer land.
    case sentUnconfirmed
    /// `ask_not_pending`: answered already (from the chat, the terminal, or another tap).
    /// The server is the exactly-once guard, so this is a success, not an error.
    case alreadyAnswered
    /// The server cannot answer this question from here; the app or terminal can.
    case needsApp
    /// No saved connection reached the asking daemon.
    case unreachable

    /// Tries `candidates` in order. A daemon that does not know the agent is the wrong
    /// session or a stale route, so the next candidate gets a turn; any other server answer
    /// is final, so a question is never sent twice by this loop.
    static func resolve(
        candidates: [AskAnswerEndpoint],
        attempt: (AskAnswerEndpoint) async -> AskAnswerAttempt
    ) async -> AskAnswerOutcome {
        var reachedADaemon = false
        for endpoint in candidates {
            switch await attempt(endpoint) {
            case .status(let status):
                return status == "answered" ? .answered : .sentUnconfirmed
            case .refused(let code) where code == "agent_not_found" || code == "pane_not_found":
                reachedADaemon = true
            case .refused(let code):
                return code == "ask_not_pending" ? .alreadyAnswered : .needsApp
            case .unreachable:
                continue
            }
        }
        return reachedADaemon ? .needsApp : .unreachable
    }

    /// The local notification posted after the attempt. `option` is nil for a form's
    /// "Accept recommendations".
    func message(for ask: AskPush, option: String?) -> (title: String, body: String) {
        guard let option else { return formMessage(for: ask) }
        switch self {
        case .answered:
            return (ask.agent, "You chose “\(option)”.")
        case .sentUnconfirmed:
            return (ask.agent, "Sent “\(option)”. Open herdrup if \(ask.agent) doesn't continue.")
        case .alreadyAnswered:
            return (ask.agent, "This question was already answered.")
        case .needsApp:
            return ("Couldn't answer \(ask.agent)", "Open herdrup to answer: \(ask.question)")
        case .unreachable:
            return ("Couldn't reach \(ask.agent)", "Open herdrup to answer: \(ask.question)")
        }
    }

    private func formMessage(for ask: AskPush) -> (title: String, body: String) {
        let what = ask.form?.intro ?? ask.question
        switch self {
        case .answered:
            return (ask.agent, "You accepted the recommendations.")
        case .sentUnconfirmed:
            return (ask.agent, "Sent the recommendations. Open herdrup if \(ask.agent) doesn't continue.")
        case .alreadyAnswered:
            return (ask.agent, "This form was already answered.")
        case .needsApp:
            return ("Couldn't answer \(ask.agent)", "Open herdrup to answer: \(what)")
        case .unreachable:
            return ("Couldn't reach \(ask.agent)", "Open herdrup to answer: \(what)")
        }
    }
}
