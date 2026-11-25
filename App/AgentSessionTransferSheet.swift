import HerdrKit
import SwiftUI

/// Two-phase native harness transfer. Preparing is non-destructive: Herdr
/// builds and rereads the destination transcript while this agent stays live. The
/// user sees the exact visible-message and omission counts before confirmation.
struct AgentSessionTransferSheet: View {
    let client: HerdrClient
    let agent: AgentInfo
    let title: String
    let accounts: [CredentialAccount]
    let onRefresh: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var source: AgentSessionTransferHarness
    @State private var target: AgentSessionTransferHarness
    @State private var selectedAccountID: String
    @State private var transfer: AgentSessionTransferInfo?
    @State private var sourceStatus: String?
    @State private var busy = false
    @State private var errorText: String?

    init(
        client: HerdrClient,
        agent: AgentInfo,
        title: String,
        source: AgentSessionTransferHarness,
        target: AgentSessionTransferHarness,
        accounts: [CredentialAccount],
        onRefresh: @escaping () -> Void
    ) {
        self.client = client
        self.agent = agent
        self.title = title
        self.accounts = accounts
        self.onRefresh = onRefresh

        let existing = agent.sessionTransfer.flatMap { info -> AgentSessionTransferInfo? in
            guard !info.phase.isConclusive,
                  info.source == source,
                  info.target == target else { return nil }
            return info
        }
        _source = State(initialValue: source)
        _target = State(initialValue: target)
        _transfer = State(initialValue: existing)
        _selectedAccountID = State(initialValue: existing?.targetAccount ?? "")
        _sourceStatus = State(initialValue: agent.agentStatus)
    }

    private var targetAccounts: [CredentialAccount] {
        accounts.filter { $0.kind == target.rawValue }
    }

    private var selectedAccount: String? {
        selectedAccountID.isEmpty ? nil : selectedAccountID
    }

    private var selectedAccountLabel: String {
        guard let id = transfer?.targetAccount ?? selectedAccount else {
            return "Default \(target.displayName) account"
        }
        return targetAccounts.first(where: { $0.id == id })?.label ?? id
    }

    private var sourceIsIdle: Bool { sourceStatus == "idle" }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.ground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        directionHeader
                        if transfer == nil {
                            setup
                        } else {
                            transferStatus
                        }
                        if let errorText {
                            errorPanel(errorText)
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 92)
                }
            }
            .navigationTitle("Switch harness")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(Palette.textDim)
                }
            }
            .safeAreaInset(edge: .bottom) { actionBar }
        }
        .preferredColorScheme(.dark)
        .task {
            if let transfer, transfer.phase != .ready {
                busy = true
                await pollTransfer(id: transfer.id)
            } else if transfer == nil {
                await pollSourceUntilIdle()
            }
        }
        .onDisappear { onRefresh() }
    }

    private var directionHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                harnessBadge(source)
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.textFaint)
                harnessBadge(target)
            }
            Text(title)
                .font(Typography.app(22, .bold))
                .foregroundStyle(Palette.text)
            Text("Continue the same agent, pane, name, folder, and visible conversation in \(target.displayName).")
                .font(Typography.app(14))
                .foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func harnessBadge(_ harness: AgentSessionTransferHarness) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(AgentIdentity.gradient(for: harness.rawValue))
                    .frame(width: 30, height: 30)
                Text(AgentIdentity.glyph(for: harness.rawValue))
                    .font(Typography.app(14, .bold))
                    .foregroundStyle(.white)
            }
            Text(harness.displayName)
                .font(Typography.app(13, .semibold))
                .foregroundStyle(Palette.text)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.hairline, lineWidth: 1))
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionLabel("TARGET ACCOUNT")
            Picker("Target account", selection: $selectedAccountID) {
                Text("Default \(target.displayName) account").tag("")
                ForEach(targetAccounts) { account in
                    Text(account.label + (account.active ? "" : " · exhausted"))
                        .tag(account.id)
                }
            }
            .pickerStyle(.menu)
            .tint(Palette.text)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.hairline, lineWidth: 1))

            infoPanel(
                icon: "shield.lefthalf.filled",
                title: "Preparation does not stop \(source.displayName)",
                text: "Herdr reads the source once, creates a native \(target.displayName) session, and rereads the destination file. You confirm only after the counts are ready."
            )

            if !sourceIsIdle {
                infoPanel(
                    icon: "hourglass",
                    title: "Wait for this turn to finish",
                    text: "The transcript must be still while Herdr verifies it. \(title) is \(sourceStatus ?? "not idle") right now."
                )
            }
        }
    }

    @ViewBuilder
    private var transferStatus: some View {
        if let transfer {
            switch transfer.phase {
            case .preparing:
                progressPanel(
                    "Preparing \(target.displayName)",
                    "Reading and verifying both native transcripts. \(source.displayName) is still live."
                )
            case .ready:
                readyReview(transfer)
            case .verifyingCutover:
                progressPanel(
                    "Rechecking both transcripts",
                    "\(source.displayName) is still live while Herdr verifies that the reviewed source and destination files are unchanged."
                )
            case .launchingTarget, .awaitingTarget:
                progressPanel(
                    "Switching to \(target.displayName)",
                    targetReadinessText
                )
            case .rollingBack:
                progressPanel(
                    "Restoring \(source.displayName)",
                    rollbackReadinessText
                )
            case .completed:
                outcomePanel(
                    icon: "checkmark.circle.fill", color: Palette.done,
                    title: "Now running in \(target.displayName)",
                    text: "The verified target owns the same pane. You can continue the conversation there."
                )
            case .rolledBack:
                outcomePanel(
                    icon: "arrow.uturn.backward.circle.fill", color: Palette.waiting,
                    title: "Restored \(source.displayName)",
                    text: transfer.error ?? "The target could not be verified, so Herdr restored the original session and account."
                )
            case .failed:
                outcomePanel(
                    icon: "exclamationmark.triangle.fill", color: Palette.died,
                    title: "Transfer failed",
                    text: transfer.error ?? "Herdr refused the transfer. Check the agent before trying again."
                )
            case .unrecognised(let value):
                outcomePanel(
                    icon: "questionmark.circle.fill", color: Palette.waiting,
                    title: "Unknown transfer state",
                    text: "The daemon reported \(value). Update herdrup before deciding whether the harness changed."
                )
            }
        }
    }

    private func readyReview(_ transfer: AgentSessionTransferInfo) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            outcomePanel(
                icon: "checkmark.shield.fill", color: Palette.done,
                title: "Ready to switch",
                text: "\(source.displayName) is still live. Confirming interrupts it only after Herdr rechecks that both verified files are unchanged."
            )

            VStack(spacing: 0) {
                reviewRow("Visible messages", value: "\(transfer.messageCount)", strong: true)
                rowDivider
                reviewRow("Target account", value: selectedAccountLabel, strong: true)
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline, lineWidth: 1))

            sectionLabel("NOT CARRIED INTO THE VISIBLE CHAT")
            VStack(spacing: 0) {
                omissionRow("Tool records", transfer.omissions.toolRecords)
                rowDivider
                omissionRow("Reasoning records", transfer.omissions.reasoningRecords)
                rowDivider
                omissionRow("System records", transfer.omissions.systemRecords)
                rowDivider
                omissionRow("Attachments", transfer.omissions.attachmentRecords)
                rowDivider
                omissionRow("Metadata records", transfer.omissions.metadataRecords)
                rowDivider
                omissionRow("Unsupported blocks", transfer.omissions.unsupportedBlocks)
                rowDivider
                omissionRow("Sidechain records", transfer.omissions.sidechainRecords)
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline, lineWidth: 1))

            Text("Only visible user and assistant text is translated. The source transcript is never modified.")
                .font(Typography.app(12))
                .foregroundStyle(Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.hairlineQuiet).frame(height: 1)
            Group {
                if transfer == nil {
                    primaryButton(
                        busy ? "Preparing…" : "Prepare transfer",
                        systemImage: busy ? nil : "arrow.triangle.2.circlepath",
                        disabled: busy || !sourceIsIdle
                    ) { Task { await prepare() } }
                } else if transfer?.phase == .ready {
                    primaryButton(
                        busy ? "Confirming…" : "Confirm switch to \(target.displayName)",
                        systemImage: busy ? nil : "arrow.right.circle.fill",
                        disabled: busy
                    ) { Task { await confirm() } }
                } else if transfer?.phase == .completed {
                    primaryButton(
                        "Switch back to \(transfer?.source.displayName ?? source.displayName)",
                        systemImage: "arrow.uturn.backward.circle.fill",
                        disabled: false
                    ) { beginReverseTransfer() }
                } else if transfer?.phase == .rolledBack {
                    primaryButton(
                        "Try switch again", systemImage: "arrow.clockwise", disabled: false
                    ) { retryRolledBackTransfer() }
                } else if transfer?.phase.isTerminal == true {
                    primaryButton("Close", systemImage: nil, disabled: false) { dismiss() }
                } else {
                    primaryButton("Transfer in progress…", systemImage: nil, disabled: true) {}
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Palette.ground.opacity(0.98))
    }

    private func primaryButton(
        _ title: String,
        systemImage: String?,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if disabled && busy { ProgressView().tint(Palette.ground) }
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
        }
        .buttonStyle(.capsule(.filled, .large, fullWidth: true))
        .disabled(disabled)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Typography.microLabel)
            .tracking(1.1)
            .foregroundStyle(Palette.textFaint)
    }

    private var rowDivider: some View {
        Rectangle().fill(Palette.hairlineQuiet).frame(height: 1).padding(.leading, 14)
    }

    private func reviewRow(_ label: String, value: String, strong: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(Typography.app(13)).foregroundStyle(Palette.textDim)
            Spacer(minLength: 12)
            Text(value)
                .font(Typography.machine(12, strong ? .semibold : .regular))
                .foregroundStyle(strong ? Palette.text : Palette.textDim)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private func omissionRow(_ label: String, _ count: UInt64) -> some View {
        reviewRow(label, value: "\(count)", strong: count > 0)
    }

    private func infoPanel(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.working)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(Typography.app(14, .semibold)).foregroundStyle(Palette.text)
                Text(text).font(Typography.app(13)).foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline, lineWidth: 1))
    }

    private func progressPanel(_ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            TurningRing(color: Palette.working, diameter: 22, lineWidth: 2)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Typography.app(16, .semibold)).foregroundStyle(Palette.text)
                Text(text).font(Typography.app(13)).foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline, lineWidth: 1))
    }

    private func outcomePanel(
        icon: String, color: Color, title: String, text: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Typography.app(16, .semibold)).foregroundStyle(Palette.text)
                Text(text).font(Typography.app(13)).foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline, lineWidth: 1))
    }

    private func errorPanel(_ text: String) -> some View {
        outcomePanel(
            icon: "exclamationmark.triangle.fill", color: Palette.died,
            title: "Could not verify the transfer", text: text
        )
    }

    private var targetReadinessText: String {
        switch target {
        case .claude:
            return "Herdr is waiting for Claude Code's official integration to report the exact staged session. A mismatch restores \(source.displayName)."
        case .codex:
            return "Herdr is binding the exact Codex resume session and PID, then rereading the native target JSONL. The JSONL is the proof; the short observation window is not. Codex's later official report must still match."
        case .omp:
            return "Herdr is binding the exact OMP session path, active leaf, and PID, then rereading the native target tree. The transcript is the proof; the short observation window is not."
        case .unrecognised(let harness):
            return "Herdr cannot verify the unrecognised target harness \(harness)."
        }
    }

    private var rollbackReadinessText: String {
        switch source {
        case .claude:
            return "The target did not take verified ownership. Herdr is reopening the original Claude Code session and waiting for its official session report."
        case .codex:
            return "The target did not take verified ownership. Herdr is reopening the exact original Codex session and verifying its native JSONL against that session's PID."
        case .omp:
            return "The target did not take verified ownership. Herdr is reopening the exact original OMP session path and verifying its active leaf and native tree against that session's PID."
        case .unrecognised(let harness):
            return "The target did not take verified ownership. Herdr cannot automatically verify rollback for the unrecognised source harness \(harness)."
        }
    }

    @MainActor
    private func beginReverseTransfer() {
        guard let current = transfer, current.phase == .completed else { return }
        source = current.target
        target = current.source
        selectedAccountID = ""
        transfer = nil
        errorText = nil
        busy = false
        sourceStatus = nil
        Task { await pollSourceUntilIdle() }
    }

    @MainActor
    private func retryRolledBackTransfer() {
        guard transfer?.phase == .rolledBack else { return }
        selectedAccountID = ""
        transfer = nil
        errorText = nil
        busy = false
        sourceStatus = nil
        Task { await pollSourceUntilIdle() }
    }

    @MainActor
    private func prepare() async {
        guard sourceIsIdle else { return }
        busy = true
        errorText = nil
        do {
            let updated = try await client.prepareAgentSessionTransfer(
                target: agent.paneID, to: target, account: selectedAccount)
            guard let info = updated.sessionTransfer else {
                throw TransferSheetError.missingState
            }
            synchronizeTransfer(info, agentStatus: updated.agentStatus)
            await pollTransfer(id: info.id)
        } catch {
            let transportError = displayError(error)
            if await adoptDurableTransfer(expectedID: nil, includeTerminal: false),
               let recovered = transfer {
                errorText = nil
                if recovered.phase == .ready {
                    busy = false
                } else {
                    await pollTransfer(id: recovered.id)
                }
                return
            }
            busy = false
            errorText = transportError
        }
    }

    @MainActor
    private func confirm() async {
        guard let current = transfer, current.phase == .ready else { return }
        busy = true
        errorText = nil
        do {
            let updated = try await client.confirmAgentSessionTransfer(
                target: agent.paneID,
                to: current.target,
                account: current.targetAccount,
                transferID: current.id)
            guard let info = updated.sessionTransfer else {
                throw TransferSheetError.missingState
            }
            synchronizeTransfer(info, agentStatus: updated.agentStatus)
            await pollTransfer(id: info.id)
        } catch {
            let transportError = displayError(error)
            if await adoptDurableTransfer(expectedID: current.id, includeTerminal: true),
               let recovered = transfer {
                if recovered.id != current.id {
                    busy = false
                    return
                }
                if recovered.phase == .ready {
                    busy = false
                    errorText = "Herdr still reports this transfer as ready, so confirmation was not observed. You can confirm the same transaction again."
                } else if recovered.phase.isTerminal {
                    busy = false
                    errorText = nil
                    onRefresh()
                } else {
                    errorText = nil
                    await pollTransfer(id: recovered.id)
                }
                return
            }
            busy = false
            errorText = transportError
        }
    }

    @MainActor
    private func adoptDurableTransfer(
        expectedID: String?, includeTerminal: Bool
    ) async -> Bool {
        do {
            guard let updatedAgent = try await client.agentList().first(where: {
                $0.paneID == agent.paneID
                    || ($0.terminalID != nil && $0.terminalID == agent.terminalID)
            }), let durable = updatedAgent.sessionTransfer,
                  includeTerminal || !durable.phase.isConclusive else {
                return false
            }
            synchronizeTransfer(durable, agentStatus: updatedAgent.agentStatus)
            if let expectedID, durable.id != expectedID {
                busy = false
                errorText = "A different transfer replaced this transaction. Review the durable state shown here before taking another action."
            }
            return true
        } catch {
            return false
        }
    }

    @MainActor
    private func pollTransfer(id: String) async {
        for _ in 0..<400 {
            guard !Task.isCancelled else { return }
            if let current = transfer {
                if current.id != id {
                    busy = false
                    return
                }
                if current.phase == .ready {
                    busy = false
                    return
                }
                if current.phase.isTerminal {
                    busy = false
                    onRefresh()
                    return
                }
            }
            await refreshTransfer(id: id)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        busy = false
        errorText = "Herdr has not reported a final state. Close and reopen this sheet to check the same transaction. Do not assume the harness changed."
    }

    @MainActor
    private func refreshTransfer(id: String) async {
        do {
            guard let updatedAgent = try await client.agentList().first(where: {
                $0.paneID == agent.paneID || ($0.terminalID != nil && $0.terminalID == agent.terminalID)
            }) else { return }
            guard let updated = updatedAgent.sessionTransfer else { return }
            guard updated.id == id else {
                synchronizeTransfer(updated, agentStatus: updatedAgent.agentStatus)
                busy = false
                errorText = "A different transfer replaced this transaction. Close and reopen to review the current one."
                return
            }
            synchronizeTransfer(updated, agentStatus: updatedAgent.agentStatus)
            if updated.phase.isTerminal { errorText = nil }
        } catch {
            // A daemon restart can transiently drop a poll. Keep the last verified
            // phase and retry; only the deadline above turns prolonged uncertainty
            // into user-visible text.
        }
    }

    @MainActor
    private func synchronizeTransfer(
        _ durable: AgentSessionTransferInfo,
        agentStatus: String?
    ) {
        source = durable.source
        target = durable.target
        selectedAccountID = durable.targetAccount ?? ""
        sourceStatus = agentStatus
        transfer = durable
    }

    @MainActor
    private func pollSourceUntilIdle() async {
        while !Task.isCancelled, transfer == nil, !sourceIsIdle {
            if let updated = try? await client.agentList().first(where: {
                $0.paneID == agent.paneID
                    || ($0.terminalID != nil && $0.terminalID == agent.terminalID)
            }) {
                sourceStatus = updated.agentStatus
            }
            if !sourceIsIdle {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func displayError(_ error: Error) -> String {
        if let apiError = error as? APIError { return apiError.description }
        if let localError = error as? LocalizedError,
           let description = localError.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

private enum TransferSheetError: LocalizedError {
    case missingState

    var errorDescription: String? {
        "Herdr returned no session-transfer state. The source was not treated as switched."
    }
}
