import HerdrKit
import SwiftUI

/// How an omp agent's page opens: its Topics, the Chat view (the default) or the terminal.
/// Settings holds the default, for the owner's pages and a guest's shared panes alike; the
/// page's switch overrides it per agent for the rest of the session. Topics exists only where
/// the server serves the agent's topics (`agent_topics`); elsewhere a Topics default opens the
/// Chat view, so agents without topics look as before.
enum ChatPreference {
    static let key = "chat.ompOpensIn"
    static let topics = "topics"
    static let chat = "chat"
    static let terminal = "terminal"
    static let defaultValue = chat

    /// The page's switch position.
    enum Mode: Equatable {
        case topics, chat, terminal
    }

    /// The last switch position per pane, in memory only: a relaunch goes back to the
    /// Settings default, as the owner asked ("remembers the last choice for the session").
    @MainActor private static var sessionChoice: [String: Mode] = [:]

    /// Settings' "omp agents open in": Chat when unset or unknown.
    static var settingMode: Mode {
        switch UserDefaults.standard.string(forKey: key) ?? defaultValue {
        case terminal: return .terminal
        case topics: return .topics
        default: return .chat
        }
    }

    /// Whether Settings' "omp agents open in" says Chat (or Topics, which opens Chat where the
    /// agent has no topics): anything but Terminal, unset included.
    static var opensInChat: Bool { settingMode != .terminal }

    @MainActor static func mode(paneID: String) -> Mode {
        sessionChoice[paneID] ?? settingMode
    }

    @MainActor static func remember(paneID: String, mode: Mode) {
        sessionChoice[paneID] = mode
    }

    /// The mode a page shows for the one asked for: Topics only where the agent has them,
    /// Chat only where it has a transcript, and the terminal otherwise.
    static func resolved(_ mode: Mode, chatAvailable: Bool, topicsAvailable: Bool) -> Mode {
        switch mode {
        case .topics where topicsAvailable: return .topics
        case .topics, .chat: return chatAvailable ? .chat : .terminal
        case .terminal: return .terminal
        }
    }

    /// The Chat view exists for omp agents only; Claude Code and Codex stay on the terminal.
    static func isOmp(_ agentKind: String?) -> Bool {
        guard let kind = agentKind?.lowercased() else { return false }
        return kind == "omp" || kind.hasPrefix("omp ") || kind.hasPrefix("omp-")
    }
}

/// The owner page's `Chat | Terminal` switch, `Topics | Chat | Terminal` for an omp agent with
/// topics, `Topics | Terminal` for one whose own transcript is refused: a small centred control
/// under the header, the outlined pill (owner picks 2026-11-24, item 7, Before; herdrup-desktop
/// `.chat-terminal-switch`): a `surface` capsule with a hairline, 26 pt capsule segments in 13 pt
/// semibold, the chosen one filled `surfaceRaised` in ink, no shadow and no rule under it.
struct ChatTerminalSwitch: View {
    /// The mode the page shows (already resolved: never a mode the switch does not offer).
    @Binding var mode: ChatPreference.Mode
    /// The agent has topics: the switch offers Topics first.
    var showsTopics = false
    /// The agent's own conversation (the Inbox) can be shown: the switch offers Chat.
    var showsChat = true

    var body: some View {
        HStack(spacing: 0) {
            if showsTopics {
                segment("Topics", selected: mode == .topics, id: "chat-switch-topics") { mode = .topics }
            }
            if showsChat {
                segment("Chat", selected: mode == .chat, id: "chat-switch-chat") { mode = .chat }
            }
            segment("Terminal", selected: mode == .terminal, id: "chat-switch-terminal") { mode = .terminal }
        }
        .padding(3)
        .background(Capsule().fill(Palette.surface))
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-switch")
    }

    private func segment(_ title: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        let height = (26 * Typography.scale).rounded()
        return Button(action: action) {
            Text(title)
                .font(Typography.app(13, .semibold))
                .foregroundStyle(selected ? Palette.text : Palette.textDim)
                .padding(.horizontal, 16)
                .frame(height: height)
                .background(Capsule().fill(selected ? Palette.surfaceRaised : Color.clear))
                // Drawn 26 pt, touched over 44: the segment reaches up and down past the track.
                .contentShape(.interaction, TouchTarget(dy: max(0, (44 - height) / 2)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}
