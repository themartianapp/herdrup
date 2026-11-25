import HerdrKit
import SwiftUI

/// "Approve a browser?" (approval-flow option D, screen 5): the code first, then Machines,
/// Access and For as rows that open in place, the terminal warning while terminal access is
/// chosen, and Deny / Approve. On iPad it is a centred form sheet.
struct WebAccessApprovalSheet: View {
    @StateObject private var model: WebAccessApprovalModel
    let onClose: () -> Void

    private enum Row { case machines, access, length }
    @State private var open: Row?
    @FocusState private var codeFocused: Bool

    init(request: ApprovalRequest, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: WebAccessApprovalModel(
            request: request, machines: WebAccessMachines.current(), unavailable: WebAccessMachines.unavailable()))
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    switch model.phase {
                    case .approved(let result):
                        approved(result)
                    case .ended(let message):
                        ended(message)
                    default:
                        code
                        rows
                        footnotes
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
        // A container element, so its id doesn't replace the buttons' and rows' own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("web-approve-sheet")
        .task {
            await model.start()
            codeFocused = true
        }
        .onDisappear { model.stop() }
        // Once claimed, the request is this device's to answer: Deny or Approve, not a swipe.
        .interactiveDismissDisabled(!model.finished)
        .overlay(alignment: .bottomLeading) { mockFixture }
    }

    // MARK: Header and code

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 22))
                .foregroundStyle(Palette.text)
                .frame(width: 48, height: 48)
                .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
            Text("Approve a browser?")
                .font(Typography.app(22, .semibold)).foregroundStyle(Palette.text)
            Text("\(model.request.browser.name) wants to reach your machines.\nType the code it shows.")
                .font(Typography.app(15)).foregroundStyle(Palette.textDim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var code: some View {
        VStack(spacing: 10) {
            ZStack {
                // One field behind the four boxes takes the digits (and the code from the
                // keyboard's suggestion bar).
                TextField("", text: $model.typed)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($codeFocused)
                    .foregroundStyle(.clear)
                    .tint(.clear)
                    .disabled(model.phase != .enterCode)
                    .accessibilityIdentifier("web-approve-code")
                    .accessibilityLabel("Code shown in the browser")
                HStack(spacing: 10) {
                    ForEach(0..<4, id: \.self) { box($0) }
                }
                .allowsHitTesting(false)
            }
            .onTapGesture { codeFocused = true }
            status
        }
    }

    private func box(_ index: Int) -> some View {
        let digits = Array(model.typed)
        let active = model.phase == .enterCode && index == digits.count && codeFocused
        let matched = model.phase == .matched || model.phase == .working && model.typed.count == 4
        return ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Palette.ground)
            RoundedRectangle(cornerRadius: 12)
                .stroke(active ? Palette.text : matched ? Palette.brand : Palette.hairline, lineWidth: active ? 2 : 1)
            if index < digits.count {
                Text(String(digits[index])).font(Typography.app(28, .semibold)).foregroundStyle(Palette.text)
            } else if active {
                Rectangle().fill(Palette.text).frame(width: 2, height: 28)
            } else {
                Circle().fill(Palette.textFaint).frame(width: 6, height: 6)
            }
        }
        .frame(width: 62, height: 72)
    }

    @ViewBuilder
    private var status: some View {
        if let error = model.codeError {
            HStack(spacing: 6) {
                Circle().fill(Palette.died).frame(width: 7, height: 7)
                Text(error).font(Typography.app(14)).foregroundStyle(Palette.text)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("web-approve-error")
        }
        HStack(spacing: 6) {
            switch model.phase {
            case .starting, .waitingForBrowser:
                ProgressView().controlSize(.mini).tint(Palette.textFaint)
                Text("Waiting for the browser to show its code").font(Typography.app(13)).foregroundStyle(Palette.textFaint)
            case .matched:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.brand)
                Text("The code matches").font(Typography.app(13)).foregroundStyle(Palette.textDim)
                    .accessibilityIdentifier("web-approve-matched")
            default:
                ProgressView().controlSize(.mini).tint(Palette.textFaint)
            }
            countdown
        }
    }

    private var countdown: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int(model.expires.timeIntervalSince(context.date)))
            Text("Expires in \(left / 60):\(String(format: "%02d", left % 60))")
                .font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.textFaint)
        }
    }

    // MARK: Rows

    private var rows: some View {
        VStack(spacing: 0) {
            rowHeader(.machines, "Machines", value: machinesValue)
            if open == .machines {
                VStack(spacing: 0) {
                    ForEach(model.machines) { machine in
                        Button {
                            if model.ticked.contains(machine.id) { model.ticked.remove(machine.id) } else { model.ticked.insert(machine.id) }
                        } label: {
                            HStack {
                                Text(machine.label).font(Typography.app(15)).foregroundStyle(Palette.text)
                                Spacer()
                                Image(systemName: model.ticked.contains(machine.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(model.ticked.contains(machine.id) ? Palette.text : Palette.textFaint)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("web-approve-machine-\(machine.label)")
                        .accessibilityAddTraits(model.ticked.contains(machine.id) ? .isSelected : [])
                    }
                }
                .padding(.bottom, 6)
            }
            divider
            rowHeader(.access, "Access", value: model.scope.label)
            if open == .access {
                segmented(WebAccessScope.allCases, selection: $model.scope, label: \.label, id: "web-approve-scope")
                    .padding(.horizontal, 14).padding(.bottom, 10)
            }
            if model.scope == .terminal {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 13))
                    Text("Terminal access is a shell on these machines: it can do anything you can do there.")
                        .font(Typography.app(13)).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Palette.textDim)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.hairline))
                .padding(.horizontal, 14).padding(.bottom, 12)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("web-approve-terminal-warning")
            }
            divider
            rowHeader(.length, "For", value: lengthValue)
            if open == .length {
                segmented(WebAccessLength.allCases, selection: $model.length, label: \.label, id: "web-approve-length")
                    .padding(.horizontal, 14).padding(.bottom, 10)
            }
        }
        .background(Palette.ground.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        .disabled(model.phase == .working || model.unsure)
    }

    private func rowHeader(_ row: Row, _ title: String, value: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { open = open == row ? nil : row }
        } label: {
            HStack(spacing: 12) {
                Text(title).font(Typography.app(15)).foregroundStyle(Palette.textDim)
                    .frame(width: 84, alignment: .leading)
                Text(value).font(Typography.app(15, .semibold)).foregroundStyle(Palette.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: open == row ? "chevron.up" : "chevron.down")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.textFaint)
            }
            .padding(.horizontal, 14).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("web-approve-row-\(title.lowercased())")
    }

    private func segmented<Value: Hashable>(_ values: [Value], selection: Binding<Value>, label: KeyPath<Value, String>,
                                            id: String) -> some View {
        HStack(spacing: 0) {
            ForEach(values, id: \.self) { value in
                let on = selection.wrappedValue == value
                Button { selection.wrappedValue = value } label: {
                    Text(value[keyPath: label]).font(Typography.app(14, on ? .semibold : .regular))
                        .foregroundStyle(on ? Palette.text : Palette.textDim)
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(on ? Palette.surfaceRaised : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(id)-\(value[keyPath: label])")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.hairline))
    }

    private var divider: some View {
        Rectangle().fill(Palette.hairlineQuiet).frame(height: 1).padding(.leading, 14)
    }

    private var machinesValue: String {
        let names = model.chosenMachines.map(\.label)
        return names.isEmpty ? "None" : names.joined(separator: ", ")
    }

    private var lengthValue: String {
        let until = Date().addingTimeInterval(TimeInterval(model.length.seconds))
        return "\(model.length.label), until \(until.formatted(.dateTime.day().month(.abbreviated)))"
    }

    @ViewBuilder
    private var footnotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.unavailable.isEmpty {
                Text("\(model.unavailable.joined(separator: ", ")) \(model.unavailable.count == 1 ? "needs its" : "need their") key or password on this \(HerdrUpAccount.deviceKind) first.")
            }
            if let problem = model.problem {
                Text(problem).foregroundStyle(Palette.text)
                    .accessibilityIdentifier("web-approve-problem")
            }
        }
        .font(Typography.app(13)).foregroundStyle(Palette.textFaint)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Outcomes

    private func approved(_ result: WebAccessResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Approved on \(result.granted.joined(separator: ", "))", systemImage: "checkmark.circle.fill")
                .font(Typography.app(16, .semibold)).foregroundStyle(Palette.text)
            Text("\(model.request.browser.name) has \(model.scope == .terminal ? "chat and terminal" : "chat") access for \(model.length.label). Remove it under Devices to end it sooner.")
                .font(Typography.app(14)).foregroundStyle(Palette.textDim)
            ForEach(WebAccessApprovalModel.lines(result), id: \.self) { line in
                Text(line).font(Typography.app(13)).foregroundStyle(Palette.textFaint)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("web-approve-result")
    }

    private func ended(_ message: String) -> some View {
        Text(message)
            .font(Typography.app(15)).foregroundStyle(Palette.textDim)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("web-approve-ended")
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        switch model.phase {
        case .approved, .ended:
            Button("Done") { onClose() }
                .buttonStyle(SheetButtonStyle(filled: true))
                .accessibilityIdentifier("web-approve-done")
        default:
            VStack(spacing: 10) {
                Button {
                    Task { await model.approve() }
                } label: {
                    if model.phase == .working { ProgressView().tint(Palette.onAccent) } else { Text(model.unsure ? "Approve again" : "Approve") }
                }
                .buttonStyle(SheetButtonStyle(filled: true))
                .disabled(!model.canApprove)
                .accessibilityIdentifier("web-approve-approve")
                Button("Deny") {
                    Task { if await model.deny() { onClose() } }
                }
                .buttonStyle(SheetButtonStyle(filled: false))
                .disabled(model.phase == .working)
                .accessibilityIdentifier("web-approve-deny")
            }
        }
    }

    // MARK: Mock

    @ViewBuilder
    private var mockFixture: some View {
        #if DEBUG
        if ProcessInfo.processInfo.environment["HERDR_MOCK_ACCOUNT_APPROVAL"] == "1" {
            // The code the mock browser shows, for the UI test to type (re-read as the phase moves).
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier("fixture-browser-code")
                .accessibilityLabel(MockAccountService.shared.server.browserCode ?? "none")
                .id(String(describing: model.phase))
        }
        #endif
    }
}

private struct SheetButtonStyle: ButtonStyle {
    let filled: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.app(16, .semibold))
            // The filled button is drawn in the text colour (near white), so its label takes the
            // ground colour, as the other filled buttons do (AddAccountSheet).
            .foregroundStyle(filled ? Palette.ground : Palette.text)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(filled ? Palette.text.opacity(enabled ? 1 : 0.35) : .clear)
            )
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(filled ? .clear : Palette.hairline))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

extension View {
    /// Presents "Approve a browser?" for `approvals.presented` from this view, when `active`
    /// (the root while the account page is closed; the account page while it is open, since a
    /// sheet can't be presented from under another). A sheet on iPad is a centred form sheet.
    func webAccessApprovalSheet(_ approvals: WebAccessApprovals, active: Bool) -> some View {
        sheet(item: Binding(
            get: { active ? approvals.presented : nil },
            set: { if $0 == nil, let request = approvals.presented { approvals.closed(request) } }
        )) { request in
            WebAccessApprovalSheet(request: request) { approvals.closed(request) }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}
