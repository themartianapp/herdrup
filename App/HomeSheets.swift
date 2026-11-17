import SwiftUI
import Foundation
import UIKit    // UIPasteboard (Copy diagnostics)
import UniformTypeIdentifiers
import StoreKit // Product / tip jar (Settings' Support section)
import UserNotifications // notification authorization status (Settings notify section)
import HerdrKit

/// New agent (screen 04): pick a folder, an agent kind, and a task, then spawn a
/// real agent. HIGH-STAKES — "Start" splits a pane, launches the agent, and sends
/// the task (splitPane → startAgent → prompt), which begins spending tokens. The
/// footer says so.
struct NewAgentView: View {
    let client: HerdrClient
    /// Called after the agent is spawned, with the new pane id, the agent's
    /// (normalized) name, and the trimmed task. The caller opens that pane with the
    /// task pre-filled — the task is NOT sent here (see `start()`).
    let onStarted: (_ paneID: String, _ name: String, _ task: String) -> Void
    let onCancel: () -> Void

    @State private var folder = ""
    @State private var kind = "claude"
    @State private var task = ""
    @State private var starting = false
    @State private var errorMessage: String?
    /// The harnesses actually installed on the connected machine (`agent.kinds`), fetched on appear.
    /// Empty until loaded, or on a daemon too old to report them — then the static fallback is used.
    @State private var installedKinds: [String] = []
    /// The remote folder browser sheet (`fs.list_dir`).
    @State private var showFolderBrowser = false

    /// Static fallback kinds for a daemon that can't report installed harnesses.
    private static let kinds = ["claude", "codex", "gemini"]

    /// The kinds the picker offers: the installed harnesses, or the static list on an older daemon.
    private var menuKinds: [String] { installedKinds.isEmpty ? Self.kinds : installedKinds }

    init(client: HerdrClient,
         onStarted: @escaping (_ paneID: String, _ name: String, _ task: String) -> Void = { _, _, _ in },
         onCancel: @escaping () -> Void = {}) {
        self.client = client
        self.onStarted = onStarted
        self.onCancel = onCancel
    }

    private var trimmedFolder: String { folder.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// A folder must be ABSOLUTE (or blank = follow the focused pane). The phone
    /// cannot expand "~" or a relative path — the remote $HOME is unknown here —
    /// and the server would silently drop a non-directory and spawn in $HOME. So
    /// reject anything non-absolute at the form rather than run in the wrong place.
    private var folderValid: Bool { trimmedFolder.isEmpty || trimmedFolder.hasPrefix("/") }
    private var canStart: Bool {
        !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && folderValid && !starting
    }
    /// The agent's name — the folder's basename, else the kind. herdr validates
    /// the name; a duplicate surfaces as a start error rather than being guessed.
    private var derivedName: String {
        let f = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !f.isEmpty {
            let base = URL(fileURLWithPath: f).lastPathComponent
            if !base.isEmpty && base != "/" { return base }
        }
        return kind
    }

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        sectionLabel("WHERE")
                        folderRow
                        sectionLabel("WHO")
                        agentRow
                        sectionLabel("WHAT")
                        taskEditor
                        if let errorMessage {
                            Text(errorMessage).font(Typography.machine(12)).foregroundStyle(Palette.died)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16).padding(.top, 10)
                        }
                        startButton
                        Text("Starts a real agent and begins spending tokens.")
                            .font(Typography.app(12)).foregroundStyle(Palette.textFaint)
                            .frame(maxWidth: .infinity).multilineTextAlignment(.center)
                            .padding(.horizontal, 24).padding(.top, 10)
                    }
                    .padding(.bottom, 16)
                }
            }
        }
        // Under a .sheet a swipe-down is an unguarded exit, but a spawn keeps running
        // off-screen and its queued pane would be stranded (pendingOpenSlot never
        // drains, then fires on an unrelated sheet close). Block interactive dismissal
        // mid-spawn — the same invariant the Cancel button's .disabled(starting) holds.
        .interactiveDismissDisabled(starting)
        // Fetch the machine's installed harnesses so the picker offers only those. `try?` degrades to
        // the static list on an older daemon (no agent.kinds). Keep the selection valid.
        .task {
            let kinds = (try? await client.agentKinds())?.filter { $0.installed }.map(\.kind) ?? []
            if !kinds.isEmpty {
                installedKinds = kinds
                if !kinds.contains(kind) { kind = kinds.first ?? kind }
            }
        }
        // The remote folder browser (fs.list_dir). On pick, fill the folder field.
        .sheet(isPresented: $showFolderBrowser) {
            FolderBrowser(client: client, initialPath: trimmedFolder.isEmpty ? nil : trimmedFolder) { picked in
                folder = picked
            }
        }
    }

    private var header: some View {
        // Title centered (ZStack) with Cancel pinned left — the design centers screen
        // titles. Cancel is a secondary affordance → dim, not the retired violet accent.
        ZStack {
            Text("New agent").font(Typography.app(17, .semibold)).foregroundStyle(Palette.text)
            HStack {
                Button("Cancel") { onCancel() }.font(Typography.app(15)).foregroundStyle(Palette.textDim)
                    .disabled(starting)   // no dismiss mid-spawn — the op would keep running off-screen
                Spacer()
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private func sectionLabel(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text(text).font(Typography.microLabel).tracking(1.2).foregroundStyle(Palette.textFaint)
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
        .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 8)
    }

    private var folderRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Folder").font(Typography.app(15)).foregroundStyle(Palette.textDim)
                TextField("/root/project", text: $folder)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(Typography.machine(15)).foregroundStyle(Palette.text)
                // Browse the machine's folders instead of typing (fs.list_dir). Manual entry stays.
                Button { showFolderBrowser = true } label: {
                    Image(systemName: "folder").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.textDim)
                }
                .accessibilityLabel("Browse folders")
            }
            .rowShell()
            if !folderValid {
                Text("use an absolute path (starts with /), or leave blank to use the current folder")
                    .font(Typography.app(12)).foregroundStyle(Palette.died).padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 16)
    }

    private var agentRow: some View {
        HStack {
            Text("Agent").font(Typography.app(15)).foregroundStyle(Palette.textDim)
            Spacer()
            Menu {
                ForEach(menuKinds, id: \.self) { k in Button(k) { kind = k } }
            } label: {
                HStack(spacing: 6) {
                    Text(kind).font(Typography.machine(15)).foregroundStyle(Palette.text)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.textFaint)
                }
            }
        }
        .rowShell()
        .padding(.horizontal, 16).padding(.top, 10)
    }

    private var taskEditor: some View {
        TextEditor(text: $task)
            .font(Typography.app(15)).foregroundStyle(Palette.text)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 90)
            .padding(8)
            .background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 12))   // filled card, per the mockup
            .overlay(alignment: .topLeading) {
                if task.isEmpty {
                    Text("What should it do?").font(Typography.app(15)).foregroundStyle(Palette.textFaint)
                        .padding(.horizontal, 13).padding(.top, 16).allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 16).padding(.top, 10)
    }

    private var startButton: some View {
        Button { start() } label: {
            HStack(spacing: 8) {
                if starting { ProgressView().tint(.white) }
                Text(starting ? "Starting…" : "Start")
                    .font(Typography.app(16, .semibold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 15)
            .background(canStart ? Palette.text : Palette.surface)
            .foregroundStyle(canStart ? Palette.ground : Palette.textFaint)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(!canStart)
        .padding(.horizontal, 16).padding(.top, 16)
    }

    /// The spawn: split a pane in the folder, then start the agent once the new
    /// pane's shell can take it (`startAgentWhenShellReady`, herdrup#435). It does NOT
    /// send the task here. `agent.start` only initiates launch; `agent.prompt`
    /// refuses (agent_not_ready) for a variable, sometimes-long window until the
    /// agent registers as a promptable known agent with a composer, and there is no
    /// reliable client-pollable readiness flag to wait on (interactive_ready is not
    /// populated on this path). So rather than auto-deliver into a not-ready agent
    /// (or spin on a poll that never flips), we hand the pane + task back to the
    /// caller, which opens the agent's terminal with the task PRE-FILLED. The
    /// terminal's input router sends it as a proper prompt the moment the pane
    /// reports a composer (InputMode.intent) — one deliberate tap, no lost task.
    ///
    /// Failure is surfaced honestly by WHERE it failed:
    ///   - before the agent starts (split failed) → nothing to clean up.
    ///   - after the split but the start failed → the pane is an orphan with no
    ///     live agent, so close it (safe) and a retry starts clean.
    private func start() {
        guard !starting else { return }   // re-entry invariant, not just Button.disabled
        starting = true
        errorMessage = nil
        let cwd = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskText = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = AgentName.normalize(derivedName)   // to the server grammar BEFORE splitting
        let chosenKind = kind
        Task {
            defer { starting = false }
            var createdPane: String?
            do {
                let paneID = try await client.splitPane(cwd: cwd.isEmpty ? nil : cwd)
                createdPane = paneID
                _ = try await client.startAgentWhenShellReady(name: name, kind: chosenKind,
                                                              paneID: paneID)
                onStarted(paneID, name, taskText)
            } catch let startError {
                if let pane = createdPane {
                    // startAgent failed after the split left an orphan pane; close
                    // it so a retry does not accumulate empty panes. Disclose if the
                    // cleanup ALSO failed — otherwise an invisible agent-less pane
                    // lingers server-side and the next retry looks clean when it is
                    // not.
                    do {
                        try await client.closePane(paneID: pane)
                        errorMessage = "couldn't start the agent: \(startError)"
                    } catch {
                        errorMessage = "couldn't start the agent (\(startError)); also failed to "
                            + "clean up the empty pane (\(error)). It may need closing manually"
                    }
                } else {
                    errorMessage = "couldn't create the pane: \(startError)"
                }
            }
        }
    }
}

/// A remote folder browser over `fs.list_dir`, for choosing an agent's working directory. Lists the
/// current directory's SUBFOLDERS (files are hidden — a cwd is a folder), tap to descend, ".." to go
/// up, "Use this folder" to pick the resolved path. Degrades with a clear message on a daemon that
/// lacks the method — the caller's manual path field stays available.
struct FolderBrowser: View {
    let client: HerdrClient
    let initialPath: String?
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var dirs: [String] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.ground.ignoresSafeArea()
                VStack(spacing: 0) {
                    Text(path.isEmpty ? "…" : path)
                        .font(Typography.machine(13)).foregroundStyle(Palette.textDim)
                        .lineLimit(1).truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    Divider().overlay(Palette.hairlineQuiet)
                    content
                    Button { onPick(path); dismiss() } label: {
                        Text("Use this folder").font(Typography.app(16, .semibold)).foregroundStyle(Palette.ground)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Palette.text))
                    }
                    .disabled(loading || error != nil || path.isEmpty)
                    .opacity((loading || error != nil || path.isEmpty) ? 0.5 : 1)
                    .padding(16)
                }
            }
            .navigationTitle("Choose folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Palette.textDim)
                }
            }
            .task { await load(initialPath) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            VStack { ProgressView().tint(Palette.textDim) }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.top, 40)
        } else if let error {
            VStack(spacing: 8) {
                Text(error).font(Typography.app(13)).foregroundStyle(Palette.died).multilineTextAlignment(.center)
                Text("Type a path in the folder field instead.")
                    .font(Typography.app(12)).foregroundStyle(Palette.textFaint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    if path != "/" {
                        folderRow(icon: "arrow.up", label: "..") { Task { await load(parent(of: path)) } }
                        divider
                    }
                    ForEach(dirs, id: \.self) { name in
                        folderRow(icon: "folder", label: name) { Task { await load(join(path, name)) } }
                        if name != dirs.last { divider }
                    }
                    if dirs.isEmpty {
                        Text("No subfolders here").font(Typography.app(13)).foregroundStyle(Palette.textFaint)
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                }
            }
        }
    }

    private func folderRow(icon: String, label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.textDim).frame(width: 22)
                Text(label).font(Typography.machine(15)).foregroundStyle(Palette.text).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.textFaint)
            }
            .padding(.horizontal, 16).padding(.vertical, 13).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Rectangle().fill(Palette.hairlineQuiet).frame(height: 1).padding(.leading, 16)
    }

    private func load(_ target: String?) async {
        loading = true
        error = nil
        do {
            let listing = try await client.listDir(path: target)
            path = listing.path
            dirs = listing.entries.filter(\.isDir).map(\.name)
        } catch let apiError as APIError {
            // `self.error` — a bare `catch` binds an implicit `error`, so unqualified would shadow.
            self.error = "Couldn't open that folder (\(apiError.code))."
        } catch {
            self.error = "Folder browsing needs the herdr fork updated on this machine."
        }
        loading = false
    }

    /// The parent path, staying absolute (root's parent is root).
    private func parent(of p: String) -> String {
        let trimmed = (p != "/" && p.hasSuffix("/")) ? String(p.dropLast()) : p
        let up = (trimmed as NSString).deletingLastPathComponent
        return up.isEmpty ? "/" : up
    }

    private func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/" + name : base + "/" + name
    }
}

/// A compact reference of the iPad hardware-keyboard shortcuts, shown by ⌘/.
struct ShortcutsSheet: View {
    var onClose: () -> Void = {}

    private let rows: [(keys: String, label: String)] = [
        ("⌘ K", "Show or hide the sidebar"),
        ("⌘ /", "This shortcut list"),
        ("⌘ F", "Search Gram (in Gram)"),
        ("⌘ +", "Increase terminal font size"),
        ("⌘ −", "Decrease terminal font size"),
        ("⌘ 0", "Reset terminal font size"),
    ]

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Keyboard Shortcuts")
                        .font(Typography.app(20, .semibold))
                        .foregroundStyle(Palette.text)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Palette.textDim)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                Divider().overlay(Palette.hairlineQuiet)
                VStack(spacing: 0) {
                    ForEach(rows, id: \.keys) { row in
                        HStack(spacing: 14) {
                            Text(row.keys)
                                .font(Typography.machine(14, .semibold))
                                .foregroundStyle(Palette.text)
                                .frame(minWidth: 54, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.surfaceRaised))
                            Text(row.label)
                                .font(Typography.app(15))
                                .foregroundStyle(Palette.textDim)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                }
                Text("Arrow keys, Tab and control keys pass straight through to the focused terminal.")
                    .font(Typography.app(13))
                    .foregroundStyle(Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.top, 8)
                Spacer(minLength: 0)
            }
        }
    }
}

/// A single-field rename form (agent name or terminal label), styled like `SavePromptSheet`.
/// `normalize` coerces the input to the target's grammar — identity for a free-form terminal label,
/// `AgentName.normalize` for an agent. It applies to the TRIMMED input, so what's shown as "saved as"
/// is exactly what's sent. The preview line appears only when normalization changes the input (the
/// agent case), so the user isn't surprised by "Build Logs" → "build-logs". Owns its own field state.
struct RenameSheet: View {
    let title: String
    let fieldLabel: String
    let placeholder: String
    let current: String
    let footnote: String
    let normalize: (String) -> String
    var onSave: (String) -> Void

    @State private var value: String
    @Environment(\.dismiss) private var dismiss

    init(title: String, fieldLabel: String, placeholder: String, current: String, footnote: String,
         normalize: @escaping (String) -> String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.fieldLabel = fieldLabel
        self.placeholder = placeholder
        self.current = current
        self.footnote = footnote
        self.normalize = normalize
        self.onSave = onSave
        _value = State(initialValue: current)
    }

    private var trimmed: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var effective: String { normalize(trimmed) }
    private var canSave: Bool { !trimmed.isEmpty && !effective.isEmpty }
    private var showPreview: Bool { canSave && effective != trimmed }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.ground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(fieldLabel).font(Typography.microLabel).foregroundStyle(Palette.textFaint)
                            .padding(.leading, 4)
                        TextField(placeholder, text: $value)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(Typography.app(15)).foregroundStyle(Palette.text)
                            .padding(.horizontal, 16).padding(.vertical, 14)
                            .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12))
                        if showPreview {
                            Text("Will be saved as \(effective)")
                                .font(Typography.machine(12)).foregroundStyle(Palette.textDim)
                                .padding(.leading, 4)
                        }
                        Text(footnote).font(Typography.app(12)).foregroundStyle(Palette.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 4).padding(.top, 2)
                        Button {
                            onSave(effective); dismiss()
                        } label: {
                            Text("Save").font(Typography.app(16, .semibold)).foregroundStyle(Palette.ground)
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.text))
                        }
                        .disabled(!canSave).opacity(canSave ? 1 : 0.5).padding(.top, 6)
                    }
                    .padding(20)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Palette.textDim)
                }
            }
        }
    }
}
