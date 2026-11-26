import CoreImage
import CoreImage.CIFilterBuiltins
import HerdrKit
import SwiftUI
import UIKit

// The owner's side of guest access: the pane ••• "Share with someone" sheet, the invite it
// produces, and the "Shared with <name>" chip on the pane header.

/// The owner's display name, sent with every invite as `owner_name` ("Shared by Jerry").
/// Asked the first time the owner shares; editable in Settings → Shared access.
enum GuestOwnerName {
    static let storageKey = "guest.ownerName"
    static let maxLength = 64

    static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return nil }
        return trimmed
    }
}

/// The connected machine's human label ("Jerry's Mac Studio"), injected by the root view from
/// the saved host's nickname. Empty outside a live connection.
private struct GuestMachineLabelKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    var guestMachineLabel: String {
        get { self[GuestMachineLabelKey.self] }
        set { self[GuestMachineLabelKey.self] = newValue }
    }
}

/// Colours and shapes the guest screens share.
enum GuestStyle {
    /// The label tint: how a guest's name reads wherever it reaches an agent.
    static let label = Color(hex: 0xB7A8FF)
    /// The terminal body ink, for the label preview that imitates the agent's input.
    static let terminalInk = Color(hex: 0xC9CDE0)
    static let avatar = LinearGradient(colors: [Color(hex: 0x4D557F), Color(hex: 0x343A5E)],
                                       startPoint: UnitPoint(x: 0.33, y: 0), endPoint: UnitPoint(x: 0.67, y: 1))

    static func sectionLabel(_ text: String, top: CGFloat = 18) -> some View {
        HStack(spacing: 8) {
            Text(text).font(Typography.microLabel).tracking(1.2).foregroundStyle(Palette.textFaint)
            Rectangle().fill(Palette.hairlineQuiet).frame(height: 1)
        }
        .padding(.horizontal, 16).padding(.top, top).padding(.bottom, 8)
    }

    static func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.hairline, lineWidth: 1))
            .padding(.horizontal, 16)
    }

    static var divider: some View {
        Rectangle().fill(Palette.hairlineQuiet).frame(height: 1)
    }
}

/// Owner-facing wording for a failed guest RPC.
enum GuestAdminError {
    static func message(_ error: Error, agentName: String? = nil) -> String {
        guard let api = error as? APIError else { return "Couldn't reach the machine: \(error)" }
        switch api.code {
        case "guest_invalid_name":
            return "That name isn't allowed. Use letters, digits, dot, dash or underscore."
        case "agent_not_found":
            return "\(agentName ?? "This agent") is gone."
        case "agent_not_ready":
            return "\(agentName ?? "This agent") isn't running a live session yet, so it can't be shared."
        case "machine_not_found":
            return "Herdr doesn't have this machine among its saved machines."
        case "guest_not_found":
            return "Already gone."
        case "unsupported":
            return "Guest access needs Herdr on macOS or Linux."
        case "forbidden":
            return "Only the machine's owner can manage guests."
        case "invalid_request" where api.isUnknownMethod:
            return "Update Herdr on this machine to share agents."
        default:
            return api.description
        }
    }
}

// MARK: - Share sheet

/// ••• → "Share with someone": name the guest, see exactly how their messages will reach
/// the agent, then create a one-use invite. On success the same sheet shows the invite.
struct GuestShareSheet: View {
    let client: HerdrClient
    let agent: AgentInfo
    let fallbackTitle: String

    @AppStorage(GuestOwnerName.storageKey) private var ownerName = ""
    @Environment(\.guestMachineLabel) private var hostLabel
    @State private var guestName = ""
    @State private var ownerDraft = ""
    /// Captured once: whether this is the owner's first share, so the "Your name" field does
    /// not vanish mid-edit the moment it is saved.
    @State private var askOwnerName: Bool?
    @State private var creating = false
    @State private var failure: String?
    @State private var created: GuestInviteCreated?
    /// "Share Gram": the guest also sees what this agent sends the owner. Off by default.
    @State private var shareGram = false
    @FocusState private var nameFocused: Bool

    private var route: GuestRoute { GuestRoute(agent: agent) }

    private var agentName: String {
        route.local(agent.name).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle
    }

    private var machineLabel: String {
        if route.machine != nil {
            return agent.machineLabel.flatMap { $0.isEmpty ? nil : $0 } ?? route.machine ?? ""
        }
        return hostLabel.isEmpty ? "this machine" : hostLabel
    }

    private var trimmedGuestName: String { guestName.trimmingCharacters(in: .whitespaces) }
    private var nameValid: Bool { GuestName.isValid(trimmedGuestName) }
    private var ownerValid: Bool { askOwnerName != true || GuestOwnerName.normalized(ownerDraft) != nil }

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            if let created {
                GuestInviteView(created: created, agentName: agentName, machineLabel: machineLabel,
                                requestedShareGram: shareGram)
                    .transition(.opacity)
            } else {
                form
            }
        }
        .animation(.easeInOut(duration: 0.2), value: created)
        .onAppear {
            if askOwnerName == nil { askOwnerName = GuestOwnerName.normalized(ownerName) == nil }
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 4) {
                    Text("Share \(agentName)")
                        .font(Typography.app(20, .bold)).foregroundStyle(Palette.text)
                    Text("They see only this agent on \(machineLabel). No SSH, no other agents.")
                        .font(Typography.app(13)).foregroundStyle(Palette.textFaint)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 22)
                Spacer().frame(height: 18)

                if askOwnerName == true { ownerSection }

                GuestStyle.sectionLabel("THEIR NAME", top: 0)
                nameField
                if !trimmedGuestName.isEmpty && !nameValid {
                    Text("Up to 32 letters, digits, dots, dashes or underscores, starting with a letter or digit.")
                        .font(Typography.app(12.5)).foregroundStyle(Palette.died)
                        .padding(.horizontal, 18).padding(.top, 6)
                        .accessibilityIdentifier("guest-share-name-error")
                }
                labelPreview

                GuestStyle.sectionLabel("ACCESS")
                accessCard

                Button {
                    Task { await create() }
                } label: {
                    if creating { ProgressView().tint(Palette.ground) } else { Text("Create invite") }
                }
                .buttonStyle(.capsule(.filled, .large, fullWidth: true))
                .disabled(!nameValid || !ownerValid || creating)
                .padding(.horizontal, 16).padding(.top, 16)
                .accessibilityIdentifier("guest-share-create")

                if let failure {
                    Text(failure)
                        .font(Typography.app(13)).foregroundStyle(Palette.died)
                        .padding(.horizontal, 18).padding(.top, 10)
                        .accessibilityIdentifier("guest-share-error")
                }
            }
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var ownerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            GuestStyle.sectionLabel("YOUR NAME", top: 0)
            field(text: $ownerDraft, placeholder: "Jerry", identifier: "guest-owner-name")
            Text("They'll see “Shared by \(GuestOwnerName.normalized(ownerDraft) ?? "you")”. You can change it in Settings → Shared access.")
                .font(Typography.app(12.5)).foregroundStyle(Palette.textFaint)
                .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 18)
        }
    }

    private var nameField: some View {
        field(text: $guestName, placeholder: "Their name", identifier: "guest-share-name",
              invalid: !trimmedGuestName.isEmpty && !nameValid)
            .focused($nameFocused)
    }

    private func field(text: Binding<String>, placeholder: String, identifier: String,
                       invalid: Bool = false) -> some View {
        HStack(spacing: 10) {
            TextField("", text: text, prompt: Text(placeholder).foregroundStyle(Palette.textFaint))
                .font(Typography.app(16)).foregroundStyle(Palette.text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.done)
                .accessibilityIdentifier(identifier)
            Text("EDIT").font(Typography.machine(12, .medium)).tracking(0.7)
                .foregroundStyle(Palette.textFaint)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(invalid ? Palette.died : Palette.textFaint, lineWidth: 1))
        .padding(.horizontal, 16)
    }

    private var labelPreview: some View {
        let shown = nameValid ? trimmedGuestName : "their-name"
        let tag = Text(GuestName.label(shown).trimmingCharacters(in: .whitespaces))
            .foregroundStyle(GuestStyle.label).fontWeight(.semibold)
        return Text("\(agentName) will see:\n\(tag) <their message>")
            .font(Typography.machine(13))
            .foregroundStyle(GuestStyle.terminalInk)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.groundMachine))
            .padding(.horizontal, 16).padding(.top, 10)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("guest-share-label-preview")
    }

    /// The grant is fixed by the protocol: a guest always watches and always talks through
    /// the labelled composer, and never types into the PTY, because keystrokes cannot carry
    /// a name. The rows state that rather than offer choices the daemon would not honour.
    private var accessCard: some View {
        GuestStyle.card {
            accessRow("Watch the live terminal", detail: nil, on: true)
            GuestStyle.divider
            accessRow("Send messages and files", detail: "Through the composer, always labeled", on: true)
            GuestStyle.divider
            accessRow("Type into the terminal", detail: "Off: keystrokes can't carry a name", on: false)
            GuestStyle.divider
            shareGramRow
        }
    }

    private func accessRow(_ title: String, detail: String?, on: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                if on {
                    Circle().fill(Palette.text)
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(Palette.ground)
                } else {
                    Circle().stroke(Palette.hairline, lineWidth: 1.5)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typography.app(15, .semibold))
                    .foregroundStyle(on ? Palette.text : Palette.textFaint)
                if let detail {
                    Text(detail).font(Typography.app(12.5)).foregroundStyle(Palette.textFaint)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityValue(on ? "On" : "Off, not available")
        .accessibilityAddTraits(.isStaticText)
    }

    /// The one choice the owner makes: whether the guest also sees this agent's Gram. With it
    /// on, everything the agent sends the owner from now on (files included) reaches the guest
    /// too, and the guest is notified of it.
    private var shareGramRow: some View {
        Toggle(isOn: $shareGram) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Share Gram").font(Typography.app(15, .semibold)).foregroundStyle(Palette.text)
                Text("They also see what \(agentName) sends you from now on, files included, and get notified")
                    .font(Typography.app(12.5)).foregroundStyle(Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Palette.brand)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityIdentifier("guest-share-gram")
    }

    private func create() async {
        let owner: String
        if askOwnerName == true {
            guard let draft = GuestOwnerName.normalized(ownerDraft) else { return }
            ownerName = draft
            owner = draft
        } else {
            owner = GuestOwnerName.normalized(ownerName) ?? ""
        }
        creating = true
        failure = nil
        defer { creating = false }
        do {
            created = try await client.guestInviteCreate(
                target: route.target, name: trimmedGuestName, ownerName: owner,
                machineLabel: machineLabel, machine: route.machine, shareGram: shareGram)
        } catch {
            failure = GuestAdminError.message(error, agentName: agentName)
        }
    }
}

// MARK: - Invite

/// The invite a guest scans or opens: the QR code carries the app link, while "Copy link" and
/// "Send…" hand out the web link, which also works for someone without the app yet.
struct GuestInviteView: View {
    let created: GuestInviteCreated
    let agentName: String
    let machineLabel: String
    /// Whether the owner switched Share Gram on for this invite.
    var requestedShareGram = false

    @State private var copied = false

    /// What the daemon stored. Asked for but not stored means a Herdr older than Gram sharing.
    private var gramState: String {
        if created.invite.shareGram { return "Shared" }
        return requestedShareGram ? "Not shared · update Herdr to share Gram" : "Not shared"
    }

    private var validity: String {
        guard let start = created.invite.createdMs, let expires = created.invite.expiresMs,
              expires > start else { return "Works once" }
        let hours = Int((Double(expires - start) / 3_600_000).rounded())
        return hours >= 1 ? "Works once · expires in \(hours) h" : "Works once · expires within the hour"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("Invite for \(created.invite.name)")
                    .font(Typography.app(20, .bold)).foregroundStyle(Palette.text)
                    .padding(.top, 22)
                Text(validity)
                    .font(Typography.app(13)).foregroundStyle(Palette.textFaint)
                    .padding(.top, 4)
                GuestQRCode(text: created.url)
                    .padding(.top, 22).padding(.bottom, 18)
                GuestStyle.card {
                    row("Agent", agentName, mono: true)
                    GuestStyle.divider
                    row("Machine", machineLabel)
                    GuestStyle.divider
                    row("Shown as", "\(created.invite.name) (via HerdrUp)", mono: true, tint: GuestStyle.label)
                    GuestStyle.divider
                    row("Gram", gramState).accessibilityIdentifier("guest-invite-gram")
                }
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = created.shareableWebURL
                        copied = true   // stays: the link on the clipboard does not expire
                    } label: {
                        Text(copied ? "Copied" : "Copy link")
                    }
                    .buttonStyle(.capsule(.secondary, .large, fullWidth: true))
                    .accessibilityIdentifier("guest-invite-copy")
                    // One URL item in the path form: Messages splits a '#' link in two.
                    if let url = URL(string: created.shareableWebURL) {
                        ShareLink(item: url,
                                  message: Text("Join \(agentName) on HerdrUp")) {
                            Text("Send…")
                        }
                        .buttonStyle(.capsule(.filled, .large, fullWidth: true))
                        .accessibilityIdentifier("guest-invite-send")
                    }
                }
                .padding(.horizontal, 16).padding(.top, 16)
            }
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func row(_ key: String, _ value: String, mono: Bool = false, tint: Color = Palette.text) -> some View {
        HStack(spacing: 12) {
            Text(key).font(Typography.app(15)).foregroundStyle(Palette.textDim)
            Spacer(minLength: 8)
            Text(value)
                .font(mono ? Typography.machine(13.5, .medium) : Typography.app(15))
                .foregroundStyle(tint).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .accessibilityElement(children: .combine)
    }
}

/// A QR code for the invite's app link, rendered crisp (nearest-neighbour) on white.
struct GuestQRCode: View {
    let text: String

    var body: some View {
        Group {
            if let image = Self.image(for: text) {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
            } else {
                Color.white
            }
        }
        .frame(width: 118, height: 118)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
        .accessibilityElement()
        .accessibilityLabel("Invite QR code")
        .accessibilityIdentifier("guest-invite-qr")
    }

    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Pane chip + presenter

/// "Shared with plotarmordev" beside the pane's status pill while a guest has the agent.
struct GuestShareChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Typography.app(12, .medium)).foregroundStyle(Palette.textDim)
            .lineLimit(1)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .overlay(Capsule().stroke(Palette.hairline, lineWidth: 1))
            .accessibilityIdentifier("guest-share-chip")
    }
}

/// Per-pane share state: whether the sheet is open and which guests hold this agent.
@MainActor
final class GuestSharePaneModel: ObservableObject {
    @Published var isSharing = false
    @Published private(set) var guests: [GuestRecord] = []

    var chipText: String? {
        guard let first = guests.first else { return nil }
        return guests.count == 1 ? "Shared with \(first.name)" : "Shared with \(first.name) +\(guests.count - 1)"
    }

    /// Reads the agent's own daemon (through the coordinator for a federated agent). A failed
    /// read keeps the last answer: the chip should not blink off on a transient error.
    func refresh(client: HerdrClient, agent: AgentInfo?) async {
        guard let agent else {
            guests = []
            return
        }
        let route = GuestRoute(agent: agent)
        guard let listing = try? await client.guestList(machine: route.machine) else { return }
        guests = listing.activeGuests(terminalID: route.local(agent.terminalID),
                                      agentName: route.local(agent.name))
    }
}

/// Hangs the share sheet and the guest refresh off the pane header.
struct GuestSharePresenter: ViewModifier {
    @ObservedObject var model: GuestSharePaneModel
    let client: HerdrClient
    let agent: AgentInfo?
    let fallbackTitle: String
    let isForeground: Bool

    func body(content: Content) -> some View {
        content
            .task(id: "\(agent?.paneID ?? "")|\(agent?.terminalID ?? "")|\(isForeground)") {
                if isForeground { await model.refresh(client: client, agent: agent) }
            }
            .sheet(isPresented: $model.isSharing, onDismiss: {
                Task { await model.refresh(client: client, agent: agent) }
            }) {
                if let agent {
                    GuestShareSheet(client: client, agent: agent, fallbackTitle: fallbackTitle)
                        .presentationDetents([.fraction(0.8), .large])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(Palette.ground)
                        .presentationCornerRadius(30)
                }
            }
    }
}
