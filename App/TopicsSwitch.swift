import HerdrKit
import SwiftUI

// The owner's per-agent Topics switch (`agent.topics.set_enabled`, `agent_topics_switch`): an
// item in the agents list's long-press menu, next to Restart agent (proposal 3, owner pick
// 2026-11-22). Turning it on or off restarts the agent on (or off) the omp build with topics;
// the conversation and the name stay. Guests have no agents list, so they never see it.

/// One confirmed-or-pending switch: which agent, and whether topics go on or off.
struct TopicsSwitchRequest: Equatable {
    let paneID: String
    let title: String
    /// True: turn topics on.
    let enabled: Bool
    /// The agent was working when the menu opened: the confirmation offers to wait for it.
    var busy = false
    /// "Cancel pending switch": `enabled` is the agent's current state, which drops the
    /// switch herdr was holding for when the agent goes idle.
    var cancelsPending = false

    static func title(_ request: TopicsSwitchRequest) -> String {
        request.enabled ? "Turn on topics for \(request.title)?" : "Turn off topics for \(request.title)?"
    }

    static func message(_ request: TopicsSwitchRequest) -> String {
        let restart = request.enabled
            ? "herdr restarts it on the omp build with topics. Its conversation and name stay."
            : "herdr restarts it on the standard omp build. Its conversation and name stay; its topics stay saved."
        // A confirmation dialog's buttons carry no subtitle: the line under Switch now is here.
        return request.busy ? "\(request.title) is working. \(restart)\n\nSwitch now: Stops what it's doing" : restart
    }
}

/// The switch at work, or how it ended.
enum TopicsSwitchStatus: Equatable {
    case working(TopicsSwitchRequest)
    /// `changed` false: it already was so.
    case done(TopicsSwitchRequest, changed: Bool)
    /// herdr holds the switch until the agent finishes its turn (`scheduled`).
    case scheduled(TopicsSwitchRequest)
    case failed(TopicsSwitchRequest, String)

    var text: String {
        switch self {
        case .working(let request):
            if request.cancelsPending { return "Cancelling the pending topics switch for \(request.title)…" }
            return request.enabled ? "Restarting \(request.title) with topics…"
                                   : "Restarting \(request.title) without topics…"
        case .done(let request, let changed):
            if request.cancelsPending { return "Pending topics switch cancelled for \(request.title)." }
            if !changed { return request.enabled ? "Topics were already on for \(request.title)."
                                                 : "Topics were already off for \(request.title)." }
            return request.enabled ? "Topics are on for \(request.title)." : "Topics are off for \(request.title)."
        case .scheduled(let request):
            return "Topics will turn \(request.enabled ? "on" : "off") when \(request.title) finishes"
        case .failed(let request, let why):
            if request.cancelsPending { return "Couldn't cancel the pending switch: " + why }
            return (request.enabled ? "Couldn't turn on topics: " : "Couldn't turn off topics: ") + why
        }
    }

    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }

    static func describe(_ error: Error) -> String {
        switch error as? AgentTopicsSwitchError {
        case .buildMissing?: return "this server has no omp build with topics."
        case .notOmp?: return "only omp agents have topics."
        case .guestForbidden?: return "only the owner can switch topics."
        case .directoryUnavailable?: return "the agent's folder is not available."
        case .notAdvertised?: return "this server has no Topics switch."
        case .other(let api)?: return api.message
        case nil: return "couldn't reach the server."
        }
    }
}

/// The switch's progress and result at the foot of the agents list: a neutral capsule with a
/// hairline and at most one status dot. A result clears itself after a few seconds.
struct TopicsSwitchBanner: View {
    @Binding var status: TopicsSwitchStatus?

    var body: some View {
        if let status {
            HStack(spacing: 8) {
                if status.isWorking {
                    ProgressView().controlSize(.small).tint(Palette.textDim)
                } else if case .failed = status {
                    Circle().fill(Palette.died).frame(width: 6, height: 6)
                }
                Text(status.text).font(Typography.app(13)).foregroundStyle(Palette.text).lineLimit(2)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Capsule().fill(Palette.surface))
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
            .padding(.horizontal, 16).padding(.bottom, 12)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("topics-switch-status")
            .task(id: status) {
                guard !status.isWorking else { return }
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if self.status == status { self.status = nil }
            }
        }
    }
}
