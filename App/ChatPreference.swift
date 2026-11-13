import HerdrKit
import SwiftUI

/// How an omp agent's page opens: the Chat view (the default) or the terminal. Settings
/// holds the default; the page's switch overrides it per agent for the rest of the session.
enum ChatPreference {
    static let key = "chat.ompOpensIn"
    static let chat = "chat"
    static let terminal = "terminal"
    static let defaultValue = chat

    /// The last switch position per pane, in memory only: a relaunch goes back to the
    /// Settings default, as the owner asked ("remembers the last choice for the session").
    @MainActor private static var sessionChoice: [String: Bool] = [:]

    @MainActor static func showsChat(paneID: String) -> Bool {
        if let chosen = sessionChoice[paneID] { return chosen }
        return (UserDefaults.standard.string(forKey: key) ?? defaultValue) != terminal
    }

    @MainActor static func remember(paneID: String, showsChat: Bool) {
        sessionChoice[paneID] = showsChat
    }

    /// The Chat view exists for omp agents only; Claude Code and Codex stay on the terminal.
    static func isOmp(_ agentKind: String?) -> Bool {
        guard let kind = agentKind?.lowercased() else { return false }
        return kind == "omp" || kind.hasPrefix("omp ") || kind.hasPrefix("omp-")
    }
}

/// The owner page's `Chat | Terminal` switch: a small centred capsule under the header
/// (13 pt semibold segments, 26 tall, in a 1 pt hairline capsule), as in the mockup.
struct ChatTerminalSwitch: View {
    @Binding var showsChat: Bool

    var body: some View {
        HStack(spacing: 0) {
            segment("Chat", selected: showsChat, id: "chat-switch-chat") { showsChat = true }
            segment("Terminal", selected: !showsChat, id: "chat-switch-terminal") { showsChat = false }
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
