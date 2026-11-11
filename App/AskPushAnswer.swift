import HerdrKit
import UIKit
import UserNotifications

/// Answers an omp question from its notification's buttons (#483). iOS may launch the app in
/// the background just for this, with no screen and no live connection, so it opens its own
/// connection to the asking daemon from the saved host's Keychain secret, calls
/// `agent.answer`, and tells the user how it went with a local notification. The buttons
/// require an unlocked device, which is also what makes the saved secrets readable.
@MainActor
enum AskPushAnswer {
    private static let routesKey = "push.askRoutes.v1"

    /// Remember that `machineID` (the daemon's install id, what its question pushes name) is
    /// reached through `credentials`. Only the endpoint is stored, never the secret.
    static func recordRoute(machineID: String, credentials: SSHCredentials) {
        var routes = loadRoutes()
        routes.record(machineID: machineID, endpoint: AskAnswerEndpoint(
            host: credentials.host, port: credentials.port,
            username: credentials.username, session: credentials.session))
        guard let data = try? JSONEncoder().encode(routes) else { return }
        UserDefaults.standard.set(data, forKey: routesKey)
    }

    /// Answer `ask` with `option` (nil: a form's "Accept recommendations", `agent.answer_form`
    /// with no values) and post the follow-up notification. Returns once both are done, so the
    /// notification delegate holds the background launch open until then.
    static func answer(_ ask: AskPush, option: String?) async {
        let background = UIApplication.shared.beginBackgroundTask(withName: "herdr.ask.answer")
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }

        let candidates = loadRoutes().candidates(machineID: ask.machineID, onlySavedHost: onlySavedHost())
        // iOS gives a background action about 30 s, and one unreachable host can take its
        // whole 15 s connect timeout, so no new host is tried once that would overrun.
        let deadline = Date().addingTimeInterval(14)
        let outcome = await AskAnswerOutcome.resolve(candidates: candidates) { endpoint in
            guard Date() < deadline else { return .unreachable }
            return await attempt(ask, option: option, through: endpoint)
        }
        await post(outcome, for: ask, option: option)
    }

    private static func attempt(_ ask: AskPush, option: String?, through endpoint: AskAnswerEndpoint) async -> AskAnswerAttempt {
        guard let credentials = credentials(for: endpoint) else { return .unreachable }
        let transport = CitadelTransport(credentials: credentials, hostKeyPolicy: KeychainHostKeyPolicy.shared)
        let client = HerdrClient(transport: transport)
        let result: AskAnswerAttempt
        do {
            let status: AgentAnswerStatus
            if let option {
                status = try await client.agentAnswer(target: ask.paneID, askID: ask.askID, option: option)
            } else {
                status = try await client.agentAnswerForm(target: ask.paneID, askID: ask.askID, values: [:]).status
            }
            result = .status(status.rawValue)
        } catch let error as APIError {
            result = .refused(code: error.code)
        } catch let error as AgentAnswerFormError {
            result = .refused(code: error.code)
        } catch {
            result = .unreachable
        }
        await transport.close()
        return result
    }

    /// The saved host behind `endpoint`, with its secret, matched the way connect-from-saved
    /// parses a saved host (which may spell the port inside `host`).
    private static func credentials(for endpoint: AskAnswerEndpoint) -> SSHCredentials? {
        let store = SavedHostsStore.shared
        guard let saved = store.hosts.first(where: { saved in
            guard let parsed = HostEndpoint.parse(saved.host) else { return false }
            return parsed.host == endpoint.host && parsed.port == endpoint.port && saved.username == endpoint.username
        }) else { return nil }
        var credentials = savedCredentials(saved)
        credentials?.session = endpoint.session
        return credentials
    }

    /// A daemon never recorded (no registration since this app version) still has a way back
    /// when the phone owns a single machine: its default or last-picked session.
    private static func onlySavedHost() -> AskAnswerEndpoint? {
        let hosts = SavedHostsStore.shared.hosts
        guard hosts.count == 1, let credentials = savedCredentials(hosts[0]) else { return nil }
        return AskAnswerEndpoint(host: credentials.host, port: credentials.port, username: credentials.username,
                                 session: SessionChoice.remembered(for: credentials))
    }

    private static func savedCredentials(_ saved: SavedHost) -> SSHCredentials? {
        guard let endpoint = HostEndpoint.parse(saved.host) else { return nil }
        switch saved.auth {
        case .key:
            guard let key = SavedHostsStore.shared.key(for: saved)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty else { return nil }
            return SSHCredentials(host: endpoint.host, port: endpoint.port, username: saved.username,
                                  privateKeyPEM: key, remoteSocketPath: "")
        case .password:
            guard let password = SavedHostsStore.shared.password(for: saved), !password.isEmpty else { return nil }
            return SSHCredentials(host: endpoint.host, port: endpoint.port, username: saved.username,
                                  password: password, remoteSocketPath: "")
        }
    }

    private static func loadRoutes() -> AskAnswerRoutes {
        guard let data = UserDefaults.standard.data(forKey: routesKey),
              let routes = try? JSONDecoder().decode(AskAnswerRoutes.self, from: data) else { return AskAnswerRoutes() }
        return routes
    }

    /// The follow-up carries the pane id, so tapping it opens the agent like the question
    /// push would have, and no `herdr_ask`, so it never grows buttons of its own.
    private static func post(_ outcome: AskAnswerOutcome, for ask: AskPush, option: String?) async {
        let message = outcome.message(for: ask, option: option)
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        content.userInfo = ["pane_id": ask.paneID]
        switch outcome {
        case .answered, .alreadyAnswered: content.sound = nil
        case .sentUnconfirmed, .needsApp, .unreachable: content.sound = .default
        }
        let request = UNNotificationRequest(identifier: "herdr.ask.result.\(ask.askID)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
