import SwiftUI
import HerdrKit

/// Add a brand-new credential account from the app. Picks a kind + label, calls
/// `accounts.create` (the daemon derives a fresh config-home + id, writes config.toml,
/// reloads), then hands back the refreshed list + the new account so the caller can
/// chain into sign-in. No credential is written here — that's the login step.
///
/// Built to the "herdrup · account sign-in · v1" Claude Design canvas. It was a plain
/// system `Form` with no design tokens at all — the biggest style break in the feature.
/// There are only two questions here, which is not enough to justify a Form: the kind
/// becomes three identity tiles you can SEE rather than a picker you have to open, and
/// the label becomes one mono field, because a label is config data.
struct AddAccountSheet: View {
    let client: HerdrClient
    /// (refreshed accounts, the newly created account if found).
    var onCreated: ([CredentialAccount], CredentialAccount?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind = "claude"
    @State private var label = ""
    @State private var busy = false
    @State private var errorText: String?

    private let kinds = ["claude", "codex", "kimi"]

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().overlay(Palette.hairlineQuiet)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        kindSection
                        labelSection
                        if let errorText {
                            Text(errorText)
                                .font(Typography.machine(12))
                                .foregroundStyle(Palette.died)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                        }
                        createSection
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Add account")
                    .font(Typography.app(20, .semibold))
                    .foregroundStyle(Palette.text)
                Text("Another subscription on your box")
                    .font(Typography.app(12))
                    .foregroundStyle(Palette.textFaint)
            }
            Spacer(minLength: 8)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textDim)
            }
            .buttonStyle(.circle(diameter: 36))
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var kindSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("KIND")
            HStack(spacing: 10) {
                ForEach(kinds, id: \.self) { value in
                    kindTile(value)
                }
            }
            .padding(.horizontal, 16)
            Text("kind decides which harness signs in")
                .font(Typography.machine(10))
                .foregroundStyle(Palette.textFaint)
                .padding(.horizontal, 16)
        }
    }

    /// An identity tile, not a picker row: the same gradient + glyph the agent cards and
    /// account rows use, so the choice looks like the thing it will become. `kimi` has no
    /// case in `AgentIdentity`, so it takes the default violet and its first letter —
    /// which is identity, not the retired brand accent.
    private func kindTile(_ value: String) -> some View {
        let picked = value == kind
        return Button {
            kind = value
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(AgentIdentity.gradient(for: value))
                        .frame(width: 40, height: 40)
                    Text(AgentIdentity.glyph(for: value))
                        .font(Typography.app(18, .bold))
                        .foregroundStyle(.white)
                }
                HStack(spacing: 4) {
                    if picked {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Palette.text)
                    }
                    Text(value)
                        .font(Typography.machine(11))
                        .foregroundStyle(picked ? Palette.text : Palette.textFaint)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(picked ? Palette.surfaceRaised : Palette.surface.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(picked ? Palette.hairline : Palette.hairlineQuiet, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value)
        .accessibilityAddTraits(picked ? [.isSelected] : [])
    }

    private var labelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("LABEL")
            TextField("Claude · work", text: $label)
                .font(Typography.machine(13))
                .foregroundStyle(Palette.text)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 11).fill(Palette.surface))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Palette.hairline, lineWidth: 1))
                .padding(.horizontal, 16)
            Text("how it reads in accounts, and in an agent's menu")
                .font(Typography.machine(10))
                .foregroundStyle(Palette.textFaint)
                .padding(.horizontal, 16)
        }
    }

    private var createSection: some View {
        VStack(spacing: 8) {
            let ready = !label.trimmingCharacters(in: .whitespaces).isEmpty && !busy
            Button { Task { await create() } } label: {
                HStack(spacing: 8) {
                    if busy { TurningRing(color: Palette.ground) }
                    Text(busy ? "Adding…" : "Add account")
                }
            }
            .buttonStyle(.capsule(.filled, .large, fullWidth: true))
            .disabled(!ready)
            Text("sign in to it next, or later, from accounts")
                .font(Typography.machine(10))
                .foregroundStyle(Palette.textFaint)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    /// The app's section micro-label: uppercase mono with a rule running off to the right.
    private func sectionLabel(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(Typography.microLabel)
                .tracking(1.2)
                .foregroundStyle(Palette.textFaint)
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
        .padding(.horizontal, 16)
    }

    private func create() async {
        busy = true
        errorText = nil
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let refreshed = try await client.accountsCreate(kind: kind, label: trimmed)
            let created = refreshed.last(where: { $0.kind == kind && $0.label == trimmed })
            onCreated(refreshed, created)
            dismiss()
        } catch {
            errorText = "Couldn't add the account — check the connection to your box and try again."
        }
        busy = false
    }
}
