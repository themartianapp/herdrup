import SwiftUI
import UIKit
import HerdrKit

/// The herdr update card in Settings › Machines, under Connection (herdrup#565, proposal B).
/// One card per state: available, updating (Download → Check → Switch over), done, failed,
/// restart needed, and too old to update itself. It replaces nothing on a server that has no
/// update to offer: then it is absent.
///
/// Drawn to the proposal: a settings group (radius 18, surface, hairline), 16 pt from the sides
/// and 10 pt under Connection, padded 16 / 18 / 18. Header: a 26 pt surfaceRaised circle with an
/// SF 13 semibold icon, 10 pt gap, Geist 15 semibold title. Text Geist 13 textDim 10 pt below;
/// notes Geist 12 textFaint 6 pt below. Done, Failed and Restart get a done / died / waiting edge
/// at 55%.
struct ServerUpdateCardView: View {
    let model: ServerUpdateModel
    /// The machine's name as the Connection row shows it.
    let host: String
    @State private var confirming = false
    @State private var receipt = CopiedCommandReceipt.shared

    static let handoffCommand = "herdr update --handoff"

    var body: some View {
        let card = model.card
        if card != .hidden {
            VStack(alignment: .leading, spacing: 0) {
                content(card)
            }
            .padding(.top, 16).padding(.horizontal, 18).padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            // `settingsGroup()` is private to HerdrApp.swift: the same group, drawn here.
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.group))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.group).stroke(Palette.hairlineQuiet, lineWidth: 1))
            .overlay {
                if let edge = edge(card) {
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.group)
                        .stroke(edge.opacity(0.55), lineWidth: 1)
                }
            }
            .padding(.horizontal, DesignTokens.Space.screenInset).padding(.top, 10)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("server-update-card")
            .onAppear { model.markSeen() }
            .onChange(of: card) { _, _ in model.markSeen() }
            .alert(confirmTitle(card), isPresented: $confirming) {
                Button("Cancel", role: .cancel) {}
                Button(isRestartLater(card) ? "Download" : "Update") { model.apply() }
            } message: {
                Text(confirmMessage(card))
            }
        }
    }

    // MARK: States

    @ViewBuilder
    private func content(_ card: ServerUpdateCard) -> some View {
        switch card {
        case .hidden:
            EmptyView()
        case .available(let old, let new, let missing, let notes, let restartLater, let reason):
            header("arrow.down.circle", Palette.waiting, "Update herdr on \(host)")
            dim(missing.isEmpty
                ? "herdr \(new) is ready. \(host) has \(old)."
                : "\(Self.sentence(missing)) need\(missing.count == 1 ? "s" : "") herdr \(new). \(host) has \(old).")
            if let notes, !notes.isEmpty {
                faint("New in \(new): \(notes)")
            }
            if restartLater {
                faint("\(Self.cantSwitch(host: host, reason: reason)) It finishes the next time herdr restarts.")
            }
            bigButton(restartLater ? "Download now, finish on restart" : "Update herdr") { confirming = true }
            faint(restartLater
                  ? "Restarting herdr closes terminals. Your layout comes back."
                  : "Takes about a minute. Terminals and agents keep running; the app reconnects by itself.")
                .padding(.top, 4)
        case .updating(let step, let fraction, let phase, let done, let total, let restartLater):
            header("arrow.triangle.2.circlepath", Palette.working, "Updating herdr")
            segments(step: step, fraction: fraction)
            Text(Self.nowLine(phase: phase, done: done, total: total, restartLater: restartLater))
                .font(Typography.app(13)).foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .accessibilityIdentifier("server-update-now")
            faint("Your terminals stay open. You can leave this screen.")
        case .done(let new, let panes, let nowOn, let diskStale):
            header("checkmark.circle.fill", Palette.done, "herdr \(new) is running")
            dim(Self.doneLine(panes: panes, nowOn: nowOn))
            if diskStale {
                faint("herdr couldn't replace its copy on disk, so a full restart would start the old version.")
            }
        case .failed(let old, let failure, let canRetry):
            failed(old: old, failure: failure, canRetry: canRetry)
        case .restartPending(let new, let reason):
            header("clock", Palette.waiting, "Downloaded. Finishes on next restart")
            dim("\(Self.cantSwitch(host: host, reason: reason)) herdr \(new) starts the next time herdr restarts.")
            faint("Restarting herdr closes terminals. Your layout comes back.")
        case .tooOld:
            tooOld
        case .unpublished(let old):
            header("clock", Palette.textDim, "A newer herdr is on its way")
            dim("This app needs a newer herdr than has been published yet. \(host) has \(old).")
        case .unsupported(let reason):
            unsupported(reason)
        }
    }

    @ViewBuilder
    private func failed(old: String, failure: ServerUpdateFailure, canRetry: Bool) -> some View {
        switch failure {
        case .needsAttention:
            header("exclamationmark.triangle.fill", Palette.died, "herdr may need a hand on \(host)")
            dim("Open a terminal there and run herdr status server. Nothing was closed.")
        case .rolledBack:
            header("exclamationmark.triangle.fill", Palette.died, "Update didn't finish")
            dim("The new version didn't pass its checks, so herdr switched back to \(old). Your terminals are fine.")
        case .lostTrack:
            header("exclamationmark.triangle.fill", Palette.died, "Lost track of the update")
            dim("\(host) stopped answering while it switched. Your terminals keep running there.")
        case .downloadStopped, .noChange, .refused:
            header("exclamationmark.triangle.fill", Palette.died, "Update didn't finish")
            dim(old.isEmpty
                ? "Nothing changed. Your terminals are fine."
                : "Nothing changed. herdr \(old) is still running, and your terminals are fine.")
        }
        if let why = Self.why(failure) {
            faint(why)
        }
        HStack(spacing: 8) {
            if case .lostTrack = failure {
                smallButton("Look again", id: "server-update-look-again") { model.lookAgain() }
            } else if canRetry {
                smallButton("Try again", id: "server-update-retry") { model.retry() }
            }
            let details = model.details
            Button { receipt.record(details) } label: {
                Text(receipt.text == details ? "Copied" : "Copy details")
                    .foregroundStyle(receipt.text == details ? Palette.done : Palette.text)
            }
            .buttonStyle(.capsule(.plain))
            .accessibilityIdentifier("server-update-copy-details")
        }
        .padding(.top, 14)
    }

    @ViewBuilder
    private var tooOld: some View {
        let old = model.runningVersion.map(ServerUpdateVersion.base)
        header("terminal", Palette.textDim, "Update herdr once on \(host)")
        dim("herdr\(old.map { " \($0)" } ?? "") can't update itself from the app. Run this once on \(host):")
        CardCommand(command: Self.handoffCommand).padding(.top, 10)
        faint("It asks before closing any terminal. After this, updates take one tap here.")
            .padding(.top, 2)
        faint("If that doesn't work, reinstall and restart herdr. Restarting closes terminals:")
            .padding(.top, 8)
        CardCommand(command: HerdrSetup.installCommand).padding(.top, 10)
        VStack(spacing: 8) {
            CardCommand(command: HerdrSetup.stopServerCommand)
            CardCommand(command: HerdrSetup.startCommand)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func unsupported(_ reason: ServerUpdateCheck.Reason?) -> some View {
        header("terminal", Palette.textDim, "Update herdr on \(host)")
        switch reason {
        case .packageManaged:
            dim("herdr on \(host) is installed by a package manager. Update it with Homebrew, mise or nix there.")
        case .windows:
            dim("herdr on Windows can't update itself from the app yet. Update it on \(host).")
        default:
            dim("herdr's folder on \(host) isn't writable, so the app can't update it. Run this on \(host):")
            CardCommand(command: Self.handoffCommand).padding(.top, 10)
        }
    }

    // MARK: Pieces

    private func header(_ symbol: String, _ tint: Color, _ title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Palette.surfaceRaised))
            Text(title)
                .font(Typography.app(15, .semibold)).foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("server-update-title")
        }
    }

    private func dim(_ text: String) -> some View {
        Text(text)
            .font(Typography.app(13)).foregroundStyle(Palette.textDim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
    }

    private func faint(_ text: String) -> some View {
        Text(text)
            .font(Typography.app(12)).foregroundStyle(Palette.textFaint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, DesignTokens.Space.stackSmall)
    }

    /// The card's main action: a full-width large filled capsule.
    private func bigButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.capsule(.filled, .large, fullWidth: true))
            .padding(.top, 14)
            .accessibilityIdentifier("server-update-button")
    }

    /// A secondary capsule (Try again, Look again).
    private func smallButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.capsule(.secondary))
            .accessibilityIdentifier(id)
    }

    /// Download, Check, Switch over: 4 pt bars 4 pt apart, the active one filling in working blue,
    /// labels Geist 12 6 pt under them (done dim, current text semibold, to come faint).
    private func segments(step: Int, fraction: Double) -> some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(Array(["Download", "Check", "Switch over"].enumerated()), id: \.offset) { index, label in
                let fill = index < step ? 1 : (index == step ? fraction : 0)
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(Palette.surfaceRaised)
                        .frame(height: 4)
                        .overlay(alignment: .leading) {
                            GeometryReader { proxy in
                                RoundedRectangle(cornerRadius: 2).fill(Palette.working)
                                    .frame(width: proxy.size.width * fill)
                            }
                        }
                    Text(label)
                        .font(Typography.app(12, index == step ? .semibold : .regular))
                        .foregroundStyle(index < step ? Palette.textDim : (index == step ? Palette.text : Palette.textFaint))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("server-update-step-\(index)")
                .accessibilityValue(index < step ? "done" : (index == step ? "current" : "next"))
            }
        }
        .padding(.top, 14)
    }

    private func edge(_ card: ServerUpdateCard) -> Color? {
        switch card {
        case .done: return Palette.done
        case .failed: return Palette.died
        case .restartPending: return Palette.waiting
        default: return nil
        }
    }

    private func isRestartLater(_ card: ServerUpdateCard) -> Bool {
        if case .available(_, _, _, _, true, _) = card { return true }
        return false
    }

    private func confirmTitle(_ card: ServerUpdateCard) -> String {
        guard case .available(_, let new, _, _, let restartLater, _) = card else { return "" }
        return restartLater ? "Download herdr \(new) to \(host)?" : "Update herdr on \(host)?"
    }

    private func confirmMessage(_ card: ServerUpdateCard) -> String {
        guard case .available(let old, let new, _, _, let restartLater, _) = card else { return "" }
        return restartLater
            ? "It installs now and starts the next time herdr restarts. Restarting herdr closes terminals; your layout comes back."
            : "From \(old) to \(new). Terminals and agents keep running; the app reconnects in a few seconds."
    }

    // MARK: Copy

    /// "Folders, avatars and answers from notifications".
    static func sentence(_ features: [ServerFeature]) -> String {
        let labels = features.map(\.label)
        let joined: String
        switch labels.count {
        case 0: joined = ""
        case 1: joined = labels[0]
        default: joined = labels.dropLast().joined(separator: ", ") + " and " + labels[labels.count - 1]
        }
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    static func megabytes(_ bytes: Int64) -> Int64 { (bytes + 524_288) / 1_048_576 }

    static func nowLine(phase: ServerUpdateAttempt.Phase, done: Int64, total: Int64, restartLater: Bool) -> String {
        switch phase {
        case .downloading:
            return total > 0 ? "Downloading \(megabytes(done)) of \(megabytes(total)) MB" : "Downloading"
        case .verifying, .testing:
            return "Checking the new version"
        case .installing:
            return "Installing. It starts the next time herdr restarts."
        case .switching, .confirming, .other:
            return restartLater ? "Installing. It starts the next time herdr restarts."
                                : "Switching over. Your terminals stay open."
        }
    }

    static func doneLine(panes: Int?, nowOn: [ServerFeature]) -> String {
        var line = panes.map { "All \($0) terminal\($0 == 1 ? "" : "s") stayed open." } ?? "Your terminals stayed open."
        if !nowOn.isEmpty {
            line += " \(sentence(nowOn)) \(nowOn.count == 1 ? "is" : "are") on."
        }
        return line
    }

    static func why(_ failure: ServerUpdateFailure) -> String? {
        switch failure {
        case .downloadStopped(let done, let total):
            return total > 0 ? "The download stopped at \(megabytes(done)) of \(megabytes(total)) MB."
                             : "The download stopped."
        case .noChange(let message), .rolledBack(let message), .needsAttention(let message):
            return message.flatMap { $0.isEmpty ? nil : $0 }
        case .refused(_, let message):
            return message.isEmpty ? nil : message
        case .lostTrack:
            return "Look again in a minute to see how it went."
        }
    }

    /// "mac-mini runs herdr as a system service, so it can't switch while running."
    static func cantSwitch(host: String, reason: ServerUpdateCheck.Reason?) -> String {
        switch reason {
        case .systemdMainProcess: return "\(host) runs herdr as a system service, so it can't switch while running."
        case .endpointGenerationChanged: return "This version changes how herdr is reached, so \(host) can't switch while running."
        case .noLiveHandoff: return "herdr on \(host) can't hand over while running."
        case .windows: return "herdr on Windows can't switch while running."
        default: return "\(host) can't switch herdr while it's running."
        }
    }
}

/// A command to run on the machine, on the card's ground, with Copy / Copied on the right
/// (Plex 13; Copy Geist 13 semibold). Shares the clipboard receipt with `CopyableCommand`.
private struct CardCommand: View {
    let command: String
    @State private var receipt = CopiedCommandReceipt.shared

    var body: some View {
        let copied = receipt.text == command
        Button { receipt.record(command) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(command)
                    .font(Typography.machine(13)).foregroundStyle(Palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                // The whole card copies; its Copy wears the plain compact capsule (all capsules,
                // owner 2026-11-24).
                HStack(spacing: 5) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                    Text(copied ? "Copied" : "Copy")
                }
                .foregroundStyle(copied ? Palette.done : Palette.text)
                .modifier(CapsuleLook(variant: .plain, size: .compact))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Palette.ground, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.card).stroke(Palette.hairlineQuiet, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(copied ? "Copied" : "Copy command: \(command)"))
    }
}
