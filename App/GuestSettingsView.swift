import SwiftUI
import HerdrKit

/// What the guest variant of Settings needs about the share it shows: the share itself,
/// this phone's key, the share's connection, and the two ways out of it.
struct GuestSettingsShare {
    let access: GuestAccess
    /// This phone's key fingerprint; nil while unreadable.
    let fingerprint: String?
    /// The share's open connection; nil until the home connected.
    let client: HerdrClient?
    /// Removes the share. The device key stays: it is this install's identity.
    let onLeave: () -> Void
    /// Closes the share's home onto the machine list, where this phone pairs a machine or
    /// adds an SSH host of its own. Nil where no machine list sits behind the share.
    let onConnectOwnMachine: (() -> Void)?
}

/// Settings › Shared with you, the page the share card opens: what was shared, by whom, the
/// name the guest's messages carry, notifications, this phone's key, and leaving. Nothing
/// about the owner's fleet.
struct SharedWithYouContent: View {
    let share: GuestSettingsShare

    @State private var confirmingLeave = false

    private var access: GuestAccess { share.access }

    var body: some View {
        VStack(spacing: 0) {
            GuestShellStyle.section("Shared with you").padding(.top, 20).padding(.bottom, 8)
            GuestShellStyle.card {
                GuestShellStyle.keyValue("Machine") { value(access.machineLabel) }
                GuestShellStyle.divider
                GuestShellStyle.keyValue("Shared by") { value(access.ownerName) }
                GuestShellStyle.divider
                GuestShellStyle.keyValue("Agent") { mono(access.agentName, Palette.text) }
                GuestShellStyle.divider
                GuestShellStyle.keyValue("You appear as") { mono(access.guestName, GuestShellStyle.label) }
            }

            GuestNotificationsControl(access: access, client: share.client)

            GuestShellStyle.section("This device").padding(.top, 26).padding(.bottom, 8)
            GuestShellStyle.card {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Device key")
                        .font(Typography.app(15)).foregroundStyle(Palette.textDim)
                    Text(share.fingerprint ?? "Unavailable")
                        .font(Typography.machine(13.5, .medium)).foregroundStyle(Palette.text)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("guest-settings-fingerprint")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 13)
            }
            Text("\(access.ownerName) sees the same key next to your name, so you can compare them.")
                .font(Typography.app(13)).foregroundStyle(Palette.textFaint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30).padding(.top, 8)

            Button { confirmingLeave = true } label: {
                Text("Leave share")
                    .font(Typography.app(15, .semibold)).foregroundStyle(Palette.died)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .overlay(Capsule().stroke(Palette.died.opacity(0.45), lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.top, 30)
            .accessibilityIdentifier("guest-leave")
            Text("You stop seeing \(access.agentName). To come back, \(access.ownerName) has to send a new invite.")
                .font(Typography.app(13)).foregroundStyle(Palette.textFaint)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30).padding(.top, 10)
        }
        .padding(.bottom, 8)
        .confirmationDialog("Leave \(access.machineLabel)?", isPresented: $confirmingLeave, titleVisibility: .visible) {
            Button("Leave share", role: .destructive, action: share.onLeave)
        } message: {
            Text("\(access.agentName) disappears from this phone.")
        }
    }

    private func value(_ text: String) -> some View {
        Text(text).font(Typography.app(15)).foregroundStyle(Palette.text)
    }

    private func mono(_ text: String, _ color: Color) -> some View {
        Text(text).font(Typography.machine(13.5, .medium)).foregroundStyle(color)
    }
}

/// The guest Settings' top card (proposal B's machine card, #572), for the one thing a guest
/// has: the shared agent. The avatar disc look (`AgentIdentity`), its name
/// (`text.machineCardTitle`), who shared it, and the machine it runs on. Settings wraps it in
/// the link to Shared with you and draws its background and chevron.
struct GuestShareCardLabel: View {
    let access: GuestAccess

    var body: some View {
        let title = DesignTokens.Text.MachineCardTitle.self
        let size = DesignTokens.Size.machineCardAvatar
        let first = access.agentName.prefix(1).uppercased()
        HStack(spacing: 14) {
            Text(first.isEmpty ? "?" : first)
                .font(Typography.app(size * 0.43, .bold)).foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(AgentIdentity.gradient(for: nil)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(access.agentName)
                    .font(Typography.app(title.size, title.weight)).foregroundStyle(Palette.text)
                    .lineLimit(1)
                Text("Shared by \(access.ownerName)")
                    .font(Typography.app(15)).foregroundStyle(Palette.textDim).lineLimit(1)
                Text(access.machineLabel)
                    .font(Typography.machine(DesignTokens.Text.CardSubtitle.size))
                    .foregroundStyle(Palette.textFaint).lineLimit(1)
                    .padding(.top, 2)
            }
        }
    }
}

/// The guest's Notifications control for one share (herdrup#343): what this phone does
/// for the shared agent, why when it isn't working, and the one action that changes it.
/// It also re-checks iOS's permission whenever it shows or the app returns, so turning
/// notifications on in iOS Settings registers at once.
struct GuestNotificationsControl: View {
    let access: GuestAccess
    let client: HerdrClient?

    @ObservedObject private var push = GuestPushCenter.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var working = false

    var body: some View {
        let status = push.status(for: access)
        VStack(spacing: 0) {
            GuestShellStyle.section("Notifications").padding(.top, 26).padding(.bottom, 8)
            GuestShellStyle.card {
                GuestShellStyle.keyValue("Notifications") {
                    Text(label(status))
                        .font(Typography.app(15, .semibold))
                        .foregroundStyle(status == .on ? Palette.done : Palette.text)
                        .accessibilityIdentifier("guest-push-status")
                }
                if let action = status.action {
                    GuestShellStyle.divider
                    Button {
                        run(action)
                    } label: {
                        Text(title(action))
                            .font(Typography.app(15, .semibold))
                            .foregroundStyle(action == .turnOff ? Palette.textDim : Palette.text)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(working)
                    .accessibilityIdentifier("guest-push-action")
                }
            }
            Text(detail(status))
                .font(Typography.app(13))
                .foregroundStyle(isFailure(status) ? Palette.died : Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30).padding(.top, 8)
                .accessibilityIdentifier("guest-push-detail")
        }
        .task(id: client.map { ObjectIdentifier($0) }) { await push.refresh(access, client: client) }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await push.refresh(access, client: client) }
        }
    }

    private func title(_ action: GuestPushAction) -> String {
        switch action {
        case .turnOn: return "Turn on"
        case .turnOff: return "Turn off"
        case .openSettings: return "Open Settings"
        case .retry: return "Try again"
        }
    }

    private func run(_ action: GuestPushAction) {
        guard action != .openSettings else {
            push.openSettings()
            return
        }
        working = true
        Task {
            await push.perform(action, access, client: client)
            working = false
        }
    }

    private func label(_ status: GuestPushPolicy.Status) -> String {
        switch status {
        case .unavailable: return push.hostFeatures[access.id] == nil ? "Checking…" : "Not available"
        case .on: return "On"
        case .off: return "Off"
        case .denied: return "Off in iOS Settings"
        case .failed: return "Not working"
        }
    }

    private func detail(_ status: GuestPushPolicy.Status) -> String {
        let gram = push.hostFeatures[access.id]?.gram == true
        let kinds = gram ? "needs \(access.ownerName), finishes or stops, and when it sends a Gram"
                         : "needs \(access.ownerName), finishes or stops"
        switch status {
        case .unavailable:
            return push.hostFeatures[access.id] == nil
                ? "Waiting for \(access.machineLabel)."
                : "\(access.machineLabel) can't send notifications to guests yet."
        case .on: return "You hear when \(access.agentName) \(kinds)."
        case .off: return "Turn on to hear when \(access.agentName) \(kinds)."
        case .denied: return "iOS doesn't let HerdrUp notify you. Turn on Allow Notifications in Settings."
        case .failed(let reason): return reason
        }
    }

    private func isFailure(_ status: GuestPushPolicy.Status) -> Bool {
        if case .failed = status { return true }
        return false
    }
}
