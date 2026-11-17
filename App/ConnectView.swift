import SwiftUI
import Foundation
import UIKit    // UIPasteboard (Copy diagnostics)
import UniformTypeIdentifiers
import StoreKit // Product / tip jar (Settings' Support section)
import UserNotifications // notification authorization status (Settings notify section)
import HerdrKit

/// Setup facts shown on more than one screen.
///
/// One definition, because the first-run screen and the post-failure guidance must not
/// drift apart — a reader who follows one and then the other has to be given the same
/// command both times.
enum HerdrSetup {
    /// Installs the fork on the machine.
    ///
    /// ONE LINE ON PURPOSE. This was four chained commands that wrapped onto four
    /// lines in the first-run card — a wall of text as the very first thing a new
    /// user is asked to do. The script selects the matching prebuilt fork release,
    /// verifies its SHA-256 checksum, and installs it under `~/.local/bin`, so the
    /// reader does not need a source checkout, Rust, Cargo, or Zig.
    ///
    /// It points at the FORK, not `herdr.dev/install.sh`: upstream's installer
    /// produces a herdr with no `api-bridge`, which this app cannot drive.
    static let installCommand =
        "curl -fsSL https://herdrup.app/install.sh | sh"
    static let pairCommand = "herdr pair"
    static let openQRCommand = "herdr pair --open"
    static let saveQRCommand = "herdr pair --qr-file ~/Desktop/herdr-pair.svg"
    /// Starts herdr (and its server, which keeps running after the window closes).
    static let startCommand = "herdr"
    /// Stops the running server so the next `startCommand` runs the installed version.
    /// It closes the agents and terminals running in herdr.
    static let stopServerCommand = "herdr server stop"

    static let tailscalePrerequisite =
        "Tailscale is connected on this iPhone and your computer."
    static let sshPrerequisite =
        "SSH is enabled on the computer. On Mac, turn on Remote Login."
}

/// #377: a machine row's press feedback. It fills `surfaceRaised` while pressed, like an
/// inset-group row, and stays filled (`held`) while that machine is connecting.
private struct ConnectRowButtonStyle: ButtonStyle {
    var held: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed || held ? Palette.surfaceRaised : Color.clear)
            .animation(.easeOut(duration: configuration.isPressed ? 0.05 : 0.2), value: configuration.isPressed || held)
    }
}

/// The connect screen: a manager of saved machines. Tap a host to connect (one tap);
/// "Add host" and hold-to-Edit open the HostEditor sheet. Constructing the transport
/// does not connect — the first request does — so this never blocks on the network.
struct ConnectView: View {
    var onConnect: (SSHCredentials) -> Void
    /// Opens the home of a machine someone shared with this phone.
    var onOpenShared: (GuestAccess) -> Void = { _ in }
    /// #377: the machine being connected to while the list is still on screen. Its row reads
    /// "Connecting…" with a spinner, and the other machine rows stop taking taps.
    var connecting: SSHCredentials? = nil

    @ObservedObject private var savedHosts = SavedHostsStore.shared
    @ObservedObject private var sharedMachines = SharedMachinesStore.shared
    /// The invite-code scanner (guest access, #312), and what it read: handed to the
    /// router once the sheet is gone, so the Accept cover never races its dismissal.
    @State private var showingInviteScan = false
    @State private var scannedInvite: GuestInvite?
    /// The add/edit sheet target; nil = closed.
    @State private var editorTarget: HostEditorTarget?
    @State private var showingOwnerSetup = false

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    header
                    if !savedHosts.hosts.isEmpty {
                        savedHostsSection
                    }
                    if sharedMachines.machines.isEmpty {
                        if savedHosts.hosts.isEmpty { emptyState }
                        scanButton
                        addHostButton
                    } else {
                        sharedSection
                        DisclosureGroup("Connect your own machine", isExpanded: $showingOwnerSetup) {
                            VStack(spacing: 18) {
                                emptyState
                                scanButton
                                addHostButton
                            }
                            .padding(.top, 12)
                        }
                        .foregroundStyle(Palette.text)
                        .accessibilityIdentifier("owner-setup-disclosure")
                    }
                    // Someone shared an agent: their invite, as a QR code or a link.
                    inviteButtons
                }
                .padding(22)
                // Cap + center the column on iPad/macOS so the host list doesn't
                // stretch edge to edge; inert on iPhone (narrower than the cap).
                .readableColumn()
            }
        }
        // Add / edit a host. Save & Connect (add) hands credentials up via onConnect.
        .sheet(item: $editorTarget) { target in
            HostEditor(target: target, store: savedHosts) { creds in
                editorTarget = nil
                onConnect(creds)
            }
        }
        .sheet(isPresented: $showingInviteScan, onDismiss: {
            guard let invite = scannedInvite else { return }
            scannedInvite = nil
            GuestInviteRouter.shared.pending = PendingGuestInvite(invite: invite)
        }) {
            GuestInviteScanSheet { scannedInvite = $0 }
        }
    }

    /// Machines other people shared: each opens its guest home over the relay.
    private var sharedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            connectSectionLabel("SHARED WITH YOU")
            VStack(spacing: 0) {
                ForEach(Array(sharedMachines.groups.enumerated()), id: \.element.id) { index, group in
                    let access = group.accesses[0]
                    if index > 0 { connectRowDivider }
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onOpenShared(access)
                    } label: {
                        connectRow(icon: "person.2", title: access.machineLabel,
                                   subtitle: "\(group.accesses.map(\.agentName).joined(separator: ", ")) · shared by \(access.ownerName)")
                    }
                    .buttonStyle(ConnectRowButtonStyle(held: false))
                    .disabled(connecting != nil)
                    .accessibilityIdentifier("shared-machine-row")
                }
            }
            .settingsGroup(outline: true)
        }
    }

    // MARK: #374 inset groups (the Settings look of #357)

    // Native UI type on the host picker; retain the app's text-size preference.
    private func connectFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * Typography.scale, weight: weight)
    }

    /// A section label above a group: today's uppercase label, inset 18 pt to line up with the
    /// rows' leading glyph (as Settings' labels do), no rule.
    private func connectSectionLabel(_ text: String) -> some View {
        Text(text).font(connectFont(12, .semibold)).tracking(1.4).foregroundStyle(Palette.textDim)
            .padding(.horizontal, 18)
    }

    /// One machine row inside a group: plain glyph, name over the second line, chevron.
    private func connectRow(icon: String, title: String, subtitle: String,
                            connecting: Bool = false) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .regular)).foregroundStyle(Palette.textDim)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(connectFont(17)).foregroundStyle(Palette.text).lineLimit(1)
                // #377: while this machine connects, the second line says so.
                Text(connecting ? "Connecting…" : subtitle)
                    .font(connectFont(14))
                    .foregroundStyle(connecting ? Palette.text : Palette.textDim).lineLimit(1)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 8)
            ZStack {
                if connecting {
                    ProgressView().controlSize(.small).tint(Palette.textDim)
                        .transition(.opacity)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.textFaint)
                        .transition(.opacity)
                }
            }
            .frame(width: 20)
        }
        .animation(.easeInOut(duration: 0.15), value: connecting)
        .padding(.horizontal, 18).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// The saved machine `connecting` points at: same host, port and user.
    private func isConnecting(_ saved: SavedHost) -> Bool {
        guard let connecting, let ep = HostEndpoint.parse(saved.host) else { return false }
        return ep.host == connecting.host && ep.port == connecting.port && saved.username == connecting.username
    }

    /// Between rows of a group; starts where the row text starts (18 + 22 + 14).
    private var connectRowDivider: some View {
        Rectangle().fill(Palette.hairlineQuiet).frame(height: 1).padding(.leading, 54)
    }

    /// Someone shared an agent: scan their invite QR, or paste the link. Scan is a
    /// full-width button like Add host so it is easy to find; Paste is the smaller
    /// fallback. The system PasteButton reads the clipboard only when tapped, so there
    /// is no "Allow Paste" prompt (see HostEditor).
    private var inviteButtons: some View {
        VStack(spacing: 10) {
            Button { showingInviteScan = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "qrcode.viewfinder").font(.system(size: 15, weight: .semibold))
                    Text("Scan invite").font(connectFont(15, .semibold))
                }
                .foregroundStyle(Palette.text)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Palette.surface, in: Capsule())
            }
            .buttonStyle(.plain)
            PasteButton(payloadType: String.self) { items in
                Task { @MainActor in
                    if let text = items.first { GuestInviteRouter.shared.open(text) }
                }
            }
            .labelStyle(.titleAndIcon)
            .tint(Palette.surfaceRaised)
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
            .accessibilityLabel("Paste invite link")
        }
    }

    private var scanButton: some View {
        Button { PairingRouter.shared.scan() } label: {
            HStack(spacing: 8) {
                Image(systemName: "qrcode.viewfinder").font(.system(size: 16, weight: .semibold))
                Text("Scan pairing code").font(connectFont(16, .semibold))
            }
            .foregroundStyle(Palette.ground)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Palette.text, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // Identity header (#374): the app logo (the Lamb) above a large left-aligned name and one
    // line of intent. The icon carries its own dark ground, so it reads as the app mark.
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image("AppLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("herdrup")
                    .font(connectFont(34, .bold))
                    .foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                Text(sharedMachines.machines.isEmpty ? "connect to your machine" : "your shared agents")
                    .font(connectFont(16))
                    .foregroundStyle(Palette.textDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// The first screen a new user ever sees, and the one that blocked one.
    ///
    /// What it said before: "Add a machine to connect over your Tailscale network." That
    /// assumed the reader already knew herdr runs on a computer, that a daemon has to be
    /// installed there, and what Tailscale is — the word "herdr" did not appear anywhere
    /// on this screen, and the page that DOES explain it was unreachable until after a
    /// successful SSH login, i.e. visible only to people who had already solved it.
    ///
    /// So it now says what the app is, and gives the one command that starts everything.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("herdrup controls coding agents running on your computer.")
                .font(connectFont(17, .semibold)).foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                Text("BEFORE PAIRING")
                    .font(connectFont(12, .semibold)).tracking(1.1)
                    .foregroundStyle(Palette.textDim)
                prerequisiteRow(
                    HerdrSetup.tailscalePrerequisite,
                    systemImage: "network",
                    identifier: "pairing-prerequisite-tailscale")
                prerequisiteRow(
                    HerdrSetup.sshPrerequisite,
                    systemImage: "lock.open",
                    identifier: "pairing-prerequisite-ssh")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18).padding(.vertical, 14)
            .settingsGroup(outline: true)

            Text("Then, on your computer, run:")
                .font(connectFont(13)).foregroundStyle(Palette.textDim)

            VStack(spacing: 8) {
                CopyableCommand(command: HerdrSetup.installCommand)
                Text("then").font(connectFont(12)).foregroundStyle(Palette.textDim)
                CopyableCommand(command: HerdrSetup.pairCommand)
                Text("scan the code it prints, then start herdr").font(connectFont(12))
                    .foregroundStyle(Palette.textDim)
                CopyableCommand(command: HerdrSetup.startCommand)
            }

            // Pairing only authorises this phone; it doesn't start herdr. Without a running
            // herdr the app connects to a machine with nothing to talk to.
            Text("herdr keeps running after you close the terminal. No keys to copy.")
                .font(connectFont(13)).foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
    }

    private func prerequisiteRow(_ text: String, systemImage: String, identifier: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.textFaint)
                .frame(width: 15)
            Text(text)
                .font(connectFont(12.5))
                .foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private var addHostButton: some View {
        Button { editorTarget = .add } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
                Text("Add host").font(connectFont(15, .semibold))
            }
            .foregroundStyle(Palette.text)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Palette.surface, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var savedHostsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            connectSectionLabel("SAVED")
            VStack(spacing: 0) {
                ForEach(Array(savedHosts.hosts.enumerated()), id: \.element.id) { index, saved in
                    if index > 0 { connectRowDivider }
                    savedHostRow(saved)
                }
            }
            .settingsGroup(outline: true)
        }
    }

    private func savedHostRow(_ saved: SavedHost) -> some View {
        let busy = isConnecting(saved)
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            tapSavedHost(saved)
        } label: {
            connectRow(icon: "desktopcomputer", title: saved.label, subtitle: secondaryLine(saved),
                       connecting: busy)
        }
        .buttonStyle(ConnectRowButtonStyle(held: busy))
        .disabled(connecting != nil)
        .accessibilityValue(busy ? "Connecting" : "")
        // Hold to manage: Edit opens the editor pre-filled (as Reconnect when the secret is
        // not on this phone, so it never claims one is saved); Remove drops it. Never
        // rebuilt while open (see StableContextMenu.swift).
        .stableContextMenu {
            StableMenuItem("Edit", systemImage: "pencil") {
                editorTarget = savedHosts.secret(for: saved) == nil ? .missingSecret(saved) : .edit(saved)
            }
            StableMenuItem("Remove", systemImage: "trash", role: .destructive) { savedHosts.delete(saved) }
        }
    }

    /// The secondary line: with a nickname, show `user@host`; without, just the user
    /// (the host is already the row's title, so it isn't repeated).
    private func secondaryLine(_ saved: SavedHost) -> String {
        let hasNickname = (saved.nickname?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        return hasNickname ? "\(saved.username)@\(saved.host)" : saved.username
    }

    /// One-tap connect from a saved host. If the secret is not on this device, open the
    /// editor in reconnect mode, which says so and asks for it, rather than a silent dead tap.
    private func tapSavedHost(_ saved: SavedHost) {
        switch savedHosts.connection(for: saved) {
        case .ready(let creds): onConnect(creds)
        case .unparseableHost: editorTarget = .edit(saved)
        case .missingSecret: editorTarget = .missingSecret(saved)
        }
    }
}
