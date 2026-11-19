import HerdrKit
import SwiftUI

/// How an omp agent's page opens: its Topics, the Chat view (the default) or the terminal.
/// Settings holds the default; the page's switch overrides it per agent for the rest of the
/// session. Topics exists only where the server serves the agent's topics (`agent_topics`);
/// elsewhere a Topics default opens the Chat view, so agents without topics look as before.
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

    @MainActor static func mode(paneID: String) -> Mode {
        if let chosen = sessionChoice[paneID] { return chosen }
        switch UserDefaults.standard.string(forKey: key) ?? defaultValue {
        case terminal: return .terminal
        case topics: return .topics
        default: return .chat
        }
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

enum ChatPaneLayout {
    /// The owner page's key row height, last measured on any pane (the keycaps are the same
    /// everywhere). A page that opens in Chat has never shown its own row; this sizes the
    /// terminal under the chat as if it had. The default is the row at 100 % text.
    @MainActor static var lastKeyRowHeight: CGFloat = 52
}

/// The owner page's `Chat | Terminal` switch, `Topics | Chat | Terminal` for an omp agent with
/// topics: a small centred capsule under the header (13 pt semibold segments, 26 tall, in a
/// 1 pt hairline capsule), as in the mockup.
struct ChatTerminalSwitch: View {
    /// The mode the page shows (already resolved: never Topics without `showsTopics`).
    @Binding var mode: ChatPreference.Mode
    /// The agent has topics: the switch offers Topics first.
    var showsTopics = false

    var body: some View {
        HStack(spacing: 0) {
            if showsTopics {
                segment("Topics", selected: mode == .topics, id: "chat-switch-topics") { mode = .topics }
            }
            segment("Chat", selected: mode == .chat, id: "chat-switch-chat") { mode = .chat }
            segment("Terminal", selected: mode == .terminal, id: "chat-switch-terminal") { mode = .terminal }
        }
        .padding(3)
        .background(Capsule().fill(Palette.surface))
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-switch")
    }

    private func segment(_ title: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.app(13, .semibold))
                .foregroundStyle(selected ? Palette.text : Palette.textDim)
                .padding(.horizontal, 16)
                .frame(height: (26 * Typography.scale).rounded())
                .background(Capsule().fill(selected ? Palette.surfaceRaised : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}
