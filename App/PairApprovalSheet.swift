import HerdrKit
import SwiftUI

/// "Pair ‹device›?" (pair from another device, option B): step 1 types the code the new device
/// shows; step 2 ticks the machines that get its key (every reachable one is ticked; the ones
/// this device can't use are greyed with the reason). Approve adds the key one machine at a
/// time, then shows what each did, with "Try ‹machine› again" for a failure. The code boxes
/// are "Approve a browser?"'s.
struct PairApprovalSheet: View {
    @StateObject private var model: PairApprovalModel
    let onClose: () -> Void
    @FocusState private var codeFocused: Bool

    init(request: PairRequest, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: PairApprovalModel(request: request, entries: PairApprovalMachines.current()))
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    switch model.phase {
                    case .starting, .waitingForDevice, .enterCode:
                        code
                    case .matched:
                        matchedLine
                        checklist
                        footnote
                    case .working:
                        checklist
                    case .results:
                        checklist
                        resultNote
                    case .ended(let message):
                        Text(message)
                            .font(Typography.app(15)).foregroundStyle(Palette.textDim)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("pair-approve-ended")
                    }
                    if let problem = model.problem {
                        Text(problem).font(Typography.app(13)).foregroundStyle(Palette.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("pair-approve-problem")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 12)
            }
            actions
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .background(Palette.surface.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pair-approve-sheet")
        .task {
            await model.start()
            codeFocused = true
        }
        .onChange(of: model.phase) { _, phase in
            if phase == .enterCode { codeFocused = true }
        }
        .onDisappear { model.stop() }
        .interactiveDismissDisabled(!model.finished)
        .overlay(alignment: .bottomLeading) { mockFixture }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            if !showsList {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(Palette.text)
                    .frame(width: 48, height: 48)
                    .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
            }
            Text(title)
                .font(Typography.app(22, .semibold)).foregroundStyle(Palette.text)
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(Typography.app(15)).foregroundStyle(Palette.textDim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var showsList: Bool {
        switch model.phase {
        case .matched, .working, .results: return true
        default: return false
        }
    }

    private var icon: String {
        switch model.request.device.platform {
        case "ios": return "iphone"
        case "ipados": return "ipad"
        default: return "laptopcomputer"
        }
    }

    private var name: String { model.request.device.name }

    private var title: String {
        guard model.phase == .results else { return "Pair \(name)?" }
        return model.resultEntries.contains { $0.isAdded(model) } ? "Paired \(name)" : "Couldn’t pair \(name)"
    }

    private var subtitle: String? {
        switch model.phase {
        case .starting, .waitingForDevice, .enterCode:
            return "\(model.deviceLine) wants to add its key to your machines.\nType the code it shows."
        case .ended:
            return "\(model.deviceLine) wants to add its key to your machines."
        case .matched:
            return nil
        case .working:
            return "Adding its key, one machine at a time."
        case .results:
            let added = model.resultEntries.filter { $0.isAdded(model) }.map(\.label)
            if added.isEmpty { return "No machine took its key." }
            let opens = "It can open \(Self.list(added)) with its own key now."
            guard let stored = model.storedLabel else { return opens }
            return opens + " The key is listed as “\(stored)” (herdr pair --list)."
        }
    }

    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    // MARK: Step 1

    private var code: some View {
        VStack(spacing: 10) {
            ZStack {
                TextField("", text: $model.typed)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($codeFocused)
                    .foregroundStyle(.clear)
                    .tint(.clear)
                    .disabled(model.phase != .enterCode)
                    .accessibilityIdentifier("pair-approve-code")
                    .accessibilityLabel("Code shown on \(name)")
                HStack(spacing: 10) {
                    ForEach(0..<4, id: \.self) { box($0) }
                }
                .allowsHitTesting(false)
            }
            .onTapGesture { codeFocused = true }
            if let error = model.codeError {
                HStack(spacing: 6) {
                    Circle().fill(Palette.died).frame(width: 7, height: 7)
                    Text(error).font(Typography.app(14)).foregroundStyle(Palette.text)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("pair-approve-error")
            }
            HStack(spacing: 6) {
                if model.phase == .enterCode {
                    Text("Step 1 of 2").font(Typography.app(13)).foregroundStyle(Palette.textFaint)
                } else {
                    ProgressView().controlSize(.mini).tint(Palette.textFaint)
                    Text("Waiting for \(name) to show its code").font(Typography.app(13)).foregroundStyle(Palette.textFaint)
                }
                countdown
            }
        }
    }

    private func box(_ index: Int) -> some View {
        let digits = Array(model.typed)
        let active = model.phase == .enterCode && index == digits.count && codeFocused
        return ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Palette.ground)
            RoundedRectangle(cornerRadius: 10)
                .stroke(active ? Palette.text : Palette.hairline, lineWidth: active ? 2 : 1)
            if index < digits.count {
                Text(String(digits[index])).font(Typography.app(28, .medium)).monospacedDigit()
                    .foregroundStyle(Palette.text)
            } else if active {
                Rectangle().fill(Palette.text).frame(width: 2, height: 24)
            } else {
                Circle().fill(Palette.textFaint).frame(width: 6, height: 6)
            }
        }
        .frame(width: 46, height: 56)
    }

    private var countdown: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int(model.expires.timeIntervalSince(context.date)))
            Text("Expires in \(left / 60):\(String(format: "%02d", left % 60))")
                .font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.textFaint)
        }
    }

    // MARK: Step 2

    private var matchedLine: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.brand)
                Text("The code matches").font(Typography.app(13)).foregroundStyle(Palette.textDim)
                    .accessibilityIdentifier("pair-approve-matched")
                countdown
            }
            Text("Tick the machines that get its key.")
                .font(Typography.app(15)).foregroundStyle(Palette.textDim)
        }
    }

    private var checklist: some View {
        // The results list the machines that were tried, then the ones this device couldn't use.
        let shown = model.phase == .results
            ? model.resultEntries + model.entries.filter { !$0.isSent(model) && model.states[$0.id]?.usable != true }
            : model.entries
        return VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Rectangle().fill(Palette.hairlineQuiet).frame(height: 1).padding(.leading, 14) }
                machineRow(entry)
            }
        }
        .background(Palette.ground.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    private func machineRow(_ entry: PairApprovalEntry) -> some View {
        let state = model.states[entry.id] ?? .checking
        let usable = state.usable || isProgress(state)
        let ticked = model.ticked.contains(entry.id)
        return Button { model.toggle(entry) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.label).font(Typography.app(15))
                        .foregroundStyle(usable ? Palette.text : Palette.textFaint)
                    if let note = note(entry, state) {
                        Text(note).font(Typography.app(13)).foregroundStyle(usable ? Palette.textDim : Palette.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                trailing(state, ticked: ticked)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.phase != .matched || !state.usable)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pair-approve-machine-\(entry.label)")
        .accessibilityValue(value(state, ticked: ticked))
        .accessibilityAddTraits(ticked && model.phase == .matched ? .isSelected : [])
    }

    private func isProgress(_ state: PairApprovalModel.MachineState) -> Bool {
        switch state {
        case .waiting, .adding, .done: return true
        default: return false
        }
    }

    private func note(_ entry: PairApprovalEntry, _ state: PairApprovalModel.MachineState) -> String? {
        switch state {
        case .checking: return "Checking…"
        case .unreachable: return "Can’t reach it from this \(HerdrUpAccount.deviceKind) right now"
        case .needsUpdate(let version): return "Needs a herdr update (herdr \(version))"
        case .noSecret: return "Needs its key or password on this \(HerdrUpAccount.deviceKind) first"
        case .ready where entry.machine?.passwordLogin == true && model.phase == .matched:
            return "Password login here; the new device gets a key"
        default: return nil
        }
    }

    @ViewBuilder
    private func trailing(_ state: PairApprovalModel.MachineState, ticked: Bool) -> some View {
        switch state {
        case .ready:
            Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(ticked ? Palette.text : Palette.textFaint)
        case .checking:
            ProgressView().controlSize(.small).tint(Palette.textFaint)
        case .unreachable, .needsUpdate, .noSecret:
            Image(systemName: "circle").font(.system(size: 20)).foregroundStyle(Palette.hairline)
        case .waiting:
            Text("Waiting").font(Typography.app(14)).foregroundStyle(Palette.textDim)
        case .adding:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).tint(Palette.textDim)
                Text("Adding…").font(Typography.app(14)).foregroundStyle(Palette.textDim)
            }
        case .done(let status, let reason):
            switch status {
            case .added: Text("Added").font(Typography.app(14)).foregroundStyle(Palette.textDim)
            case .already: Text("Already had it").font(Typography.app(14)).foregroundStyle(Palette.textDim)
            case .failed:
                HStack(spacing: 6) {
                    Circle().fill(Palette.died).frame(width: 7, height: 7)
                    Text("Failed: \(reason ?? "failed")").font(Typography.app(14)).foregroundStyle(Palette.textDim)
                        .lineLimit(1)
                }
            }
        }
    }

    private func value(_ state: PairApprovalModel.MachineState, ticked: Bool) -> String {
        switch state {
        case .ready: return ticked ? "Ticked" : "Not ticked"
        case .checking: return "Checking"
        case .unreachable: return "Unreachable"
        case .needsUpdate(let version): return "Needs herdr update \(version)"
        case .noSecret: return "No key here"
        case .waiting: return "Waiting"
        case .adding: return "Adding"
        case .done(let status, let reason): return status == .failed ? "Failed: \(reason ?? "")" : status == .added ? "Added" : "Already had it"
        }
    }

    private var footnote: some View {
        Text("Approving adds \(name)’s key to each machine you tick (a herdr command there). Remove it with herdr pair --revoke.")
            .font(Typography.app(13)).foregroundStyle(Palette.textFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var resultNote: some View {
        if let failed = model.failedEntry {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.failureReason(failed) == "timed out" ? "\(failed.label) didn’t answer." : "\(failed.label) didn’t take the key.")
                    .font(Typography.app(14)).foregroundStyle(Palette.text)
                Text("Try again from here later, or use herdr pair there.")
                    .font(Typography.app(13)).foregroundStyle(Palette.textFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("pair-approve-failed-note")
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        switch model.phase {
        case .ended:
            Button("Done") { onClose() }
                .buttonStyle(.capsule(.filled, .large, fullWidth: true))
                .accessibilityIdentifier("pair-approve-done")
        case .results:
            VStack(spacing: 10) {
                Button("Done") { onClose() }
                    .buttonStyle(.capsule(.filled, .large, fullWidth: true))
                    .accessibilityIdentifier("pair-approve-done")
                if let failed = model.failedEntry {
                    Button {
                        Task { await model.retry(failed) }
                    } label: {
                        if model.retrying != nil { ProgressView().tint(Palette.text) } else { Text("Try \(failed.label) again") }
                    }
                    .buttonStyle(.capsule(.secondary, .large, fullWidth: true))
                    .disabled(model.retrying != nil)
                    .accessibilityIdentifier("pair-approve-retry")
                }
            }
        case .starting, .waitingForDevice, .enterCode:
            VStack(spacing: 10) {
                Button("Continue") { Task { await model.checkCode() } }
                    .buttonStyle(.capsule(.filled, .large, fullWidth: true))
                    .disabled(model.phase != .enterCode || model.typed.count < 4)
                    .accessibilityIdentifier("pair-approve-continue")
                denyButton
            }
        case .matched, .working:
            VStack(spacing: 10) {
                Button {
                    Task { await model.approve() }
                } label: {
                    if model.phase == .working {
                        ProgressView().tint(Palette.ground)
                    } else if model.unsure {
                        Text("Approve again")
                    } else {
                        Text("Approve \(model.chosen.count) \(model.chosen.count == 1 ? "machine" : "machines")")
                    }
                }
                .buttonStyle(.capsule(.filled, .large, fullWidth: true))
                .disabled(!model.canApprove)
                .accessibilityIdentifier("pair-approve-approve")
                denyButton
            }
        }
    }

    private var denyButton: some View {
        Button("Deny") {
            Task { if await model.deny() { onClose() } }
        }
        .buttonStyle(.capsule(.secondary, .large, fullWidth: true))
        .disabled(model.phase == .working)
        .accessibilityIdentifier("pair-approve-deny")
    }

    // MARK: Mock

    @ViewBuilder
    private var mockFixture: some View {
        #if DEBUG
        if ProcessInfo.processInfo.environment["HERDR_MOCK_ACCOUNT_PAIR"] == "approver" {
            // The code the mock new device shows, and the machines its envelope holds once
            // opened with the new device's key (re-read as the phase moves).
            Group {
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("fixture-pair-code")
                    .accessibilityLabel(MockAccountService.shared.server.pairCode ?? "none")
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("fixture-pair-envelope")
                    .accessibilityLabel(MockAccountService.shared.server.pairEnvelopeSummary ?? "none")
            }
            .id("\(model.phase)-\(model.retrying ?? "")-\(model.problem ?? "")")
        }
        #endif
    }
}

private extension PairApprovalEntry {
    func isAdded(_ model: PairApprovalModel) -> Bool {
        if case .done(let status, _) = model.states[id] { return status != .failed }
        return false
    }

    func isSent(_ model: PairApprovalModel) -> Bool { model.resultEntries.contains { $0.id == id } }
}

extension View {
    /// Presents "Pair ‹device›?" for `approvals.presented` from this view, when `active` (the
    /// root while the account page is closed; the account page while it is open).
    func pairApprovalSheet(_ approvals: PairApprovals, active: Bool) -> some View {
        sheet(item: Binding(
            get: { active ? approvals.presented : nil },
            set: { if $0 == nil, let request = approvals.presented { approvals.closed(request) } }
        )) { request in
            PairApprovalSheet(request: request) { approvals.closed(request) }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}
