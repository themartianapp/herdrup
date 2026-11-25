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
    /// `changed` false: it already was so (for a cancel: herdr dropped the pending switch).
    case done(TopicsSwitchRequest, changed: Bool)
    /// herdr holds the switch until the agent finishes its turn (`scheduled`).
    case scheduled(TopicsSwitchRequest)
    /// Cancel pending switch found nothing pending: herdr had already applied (or dropped)
    /// it, so nothing was sent. `topicsEnabled` is the agent's state now.
    case noLongerPending(TopicsSwitchRequest, topicsEnabled: Bool?)
    case failed(TopicsSwitchRequest, String)

    /// How `agent.topics.set_enabled` answered `request`. A cancel sends the agent's current
    /// state, so `changed: false, scheduled: false` is herdr dropping the pending switch;
    /// `changed: true` means the agent did switch (to `request.enabled`), and is said so.
    init(_ request: TopicsSwitchRequest, _ result: AgentTopicsSwitched) {
        self = result.scheduled ? .scheduled(request) : .done(request, changed: result.changed)
    }

    var text: String {
        switch self {
        case .working(let request):
            if request.cancelsPending { return "Cancelling the pending topics switch for \(request.title)…" }
            return request.enabled ? "Restarting \(request.title) with topics…"
                                   : "Restarting \(request.title) without topics…"
        case .done(let request, let changed):
            if request.cancelsPending, !changed { return "Pending topics switch cancelled for \(request.title)." }
            if !changed { return request.enabled ? "Topics were already on for \(request.title)."
                                                 : "Topics were already off for \(request.title)." }
            return request.enabled ? "Topics are on for \(request.title)." : "Topics are off for \(request.title)."
        case .scheduled(let request):
            return "Topics will turn \(request.enabled ? "on" : "off") when \(request.title) finishes"
        case .noLongerPending(let request, let topicsEnabled):
            guard let topicsEnabled else { return "No topics switch is pending for \(request.title) any more." }
            return "The topics switch for \(request.title) already happened: topics are \(topicsEnabled ? "on" : "off")."
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

/// The switch's progress and result, 12 pt above the tab bar (the sidebar's section bar on iPad):
/// a centred neutral capsule (surface + hairline, owner picks 2026-11-24 item 16) with at most one
/// mark (the activity spinner while working, a red dot on failure) and a "Cancel" capsule while
/// herdr holds a switch for when the agent finishes. A result clears itself after a few seconds.
/// The home places it as a bottom safe-area inset, so the roster, Gram and Settings end above it.
struct TopicsSwitchBanner: View {
    @Binding var status: TopicsSwitchStatus?
    /// Drops a switch herdr holds for when the agent finishes; nil where it cannot be cancelled.
    var onCancel: ((TopicsSwitchRequest) -> Void)? = nil

    /// The gap between the capsule and the tab bar below it.
    static let bottomGap: CGFloat = 12

    var body: some View {
        if let status {
            HStack(spacing: 8) {
                if status.isWorking {
                    ActivitySpinner(diameter: 12)
                } else if case .failed = status {
                    Circle().fill(Palette.died).frame(width: 6, height: 6)
                }
                Text(status.text).font(Typography.app(13)).foregroundStyle(Palette.text)
                    .lineSpacing(3)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("topics-switch-status")
                if case .scheduled(let request) = status, let onCancel {
                    Button("Cancel") { onCancel(request) }
                        .buttonStyle(.capsule(.secondary, .compact))
                        .accessibilityIdentifier("topics-switch-cancel")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Capsule().fill(Palette.surface))
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
            .padding(.horizontal, 16)
            .padding(.bottom, Self.bottomGap)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .task(id: status) {
                guard !status.isWorking else { return }
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if self.status == status { self.status = nil }
            }
        }
    }
}
