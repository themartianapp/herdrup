import HerdrKit
import SwiftUI
import UIKit

/// What the `HostEditor` sheet is working on: a brand-new host, an existing one, or an
/// existing one whose key or password is not on this device.
enum HostEditorTarget: Identifiable {
    case add
    case edit(SavedHost)
    /// The host is listed but its secret is not in this device's Keychain. Secrets are
    /// stored ThisDeviceOnly, so a phone set up from another phone gets the host list
    /// (UserDefaults) without the keys; the editor asks for the secret and connects.
    case missingSecret(SavedHost)
    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let h), .missingSecret(let h): return h.id.uuidString
        }
    }
}

/// Add or edit a saved host: nickname + host(:port) + user + private key. Saving records
/// the non-secret fields in UserDefaults and the key in the Keychain (via `SavedHostsStore`).
/// Adding also offers Save & Connect. The key is WRITE-ONLY here (never displayed — the
/// connect screen can be screenshotted onto an open port): on edit it starts blank and the
/// stored key is kept unless a new one is pasted.
struct HostEditor: View {
    let target: HostEditorTarget
    @ObservedObject var store: SavedHostsStore
    /// Save & Connect (add mode): build credentials and hand them up to connect.
    var onConnect: (SSHCredentials) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nickname: String
    @State private var host: String
    @State private var username: String
    @State private var keyPEM = ""
    @State private var showingKeySheet = false
    /// Whether this host authenticates with a key or a password (segmented picker).
    @State private var authKind: SavedAuthKind
    /// The password (password mode). Masked by a SecureField, so unlike the key it can
    /// be entered inline; write-only on edit (blank keeps the stored one).
    @State private var password = ""
    @State private var error: String?
    @State private var keyError: String?
    /// "Choose key file…" — the path that works everywhere, including the Mac build where
    /// `PasteButton` is inert.
    @State private var showingKeyImporter = false
    /// Manual paste, shown ALONGSIDE the file picker rather than behind a disclosure.
    /// Starts empty and is cleared the instant a key is accepted, so the only thing ever
    /// on screen is what the person just put there.
    @State private var manualKey = ""

    private let editing: SavedHost?
    /// Editing a host whose stored secret is absent: the secret is required again and
    /// nothing on screen may claim one is saved.
    private let secretMissing: Bool
    /// Whether a blank secret field keeps a stored one.
    private var hasSavedSecret: Bool { editing != nil && !secretMissing }

    init(target: HostEditorTarget, store: SavedHostsStore, onConnect: @escaping (SSHCredentials) -> Void) {
        self.target = target
        self.store = store
        self.onConnect = onConnect
        switch target {
        case .add:
            editing = nil
            secretMissing = false
            _nickname = State(initialValue: "")
            _host = State(initialValue: "")
            _username = State(initialValue: "")
            _authKind = State(initialValue: .key)
        case .edit(let h), .missingSecret(let h):
            editing = h
            if case .missingSecret = target { secretMissing = true } else { secretMissing = false }
            _nickname = State(initialValue: h.nickname ?? "")
            _host = State(initialValue: h.host)
            _username = State(initialValue: h.username)
            _authKind = State(initialValue: h.auth)
        }
    }

    private var endpoint: HostEndpoint? { HostEndpoint.parse(host) }
    private var trimmedUser: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedKey: String { keyPEM.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hostInvalid: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && endpoint == nil
    }
    /// Add (and a host whose secret is missing) requires the chosen secret; edit keeps
    /// the existing one when the field is left blank (whichever auth kind).
    private var canSave: Bool {
        guard endpoint != nil, !trimmedUser.isEmpty else { return false }
        if hasSavedSecret { return true }
        return authKind == .key ? !trimmedKey.isEmpty : !password.isEmpty
    }

    /// The secret to persist, or nil when the field is blank (edit keeps the current one).
    private func currentSecret() -> HostSecret? {
        switch authKind {
        case .key: return trimmedKey.isEmpty ? nil : .key(trimmedKey)
        case .password: return password.isEmpty ? nil : .password(password)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.ground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 10) {
                        if secretMissing {
                            caption("This phone doesn't have the \(authKind == .key ? "key" : "password") "
                                    + "for this host. Keys and passwords stay on the phone they were "
                                    + "added on, so add it here to connect.", color: Palette.textDim)
                                .padding(.bottom, 4)
                        }
                        fieldRow("Nickname", text: $nickname, placeholder: "My Mac")
                        fieldRow("Host", text: $host, placeholder: "mac.tail-scale.ts.net")
                        if hostInvalid { caption("check host or host:port", color: Palette.died) }
                        fieldRow("User", text: $username, placeholder: "jerry")
                        authPicker
                        if authKind == .key { keyRow } else { passwordRow }
                        if let error { caption(error, color: Palette.died) }

                        if editing == nil || secretMissing {
                            primaryButton("Save & Connect") { saveAndConnect() }
                            Button("Save without connecting") { if save() { dismiss() } }
                                .font(Typography.app(14)).foregroundStyle(Palette.textDim)
                                .disabled(!canSave).padding(.top, 2)
                        } else {
                            primaryButton("Save") { if save() { dismiss() } }
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle(editing == nil ? "Add host" : secretMissing ? "Reconnect" : "Edit host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Palette.textDim)
                }
            }
        }
        .sheet(isPresented: $showingKeySheet) { keySheet }
    }

    // MARK: - actions

    /// Persist the host (add or update). Returns success; sets `error` on failure.
    @discardableResult
    private func save() -> Bool {
        let secret = currentSecret()
        let ok: Bool
        if let editing {
            // nil secret = keep the stored one (blank field on edit).
            ok = store.update(editing, nickname: nickname, host: host, username: trimmedUser, secret: secret)
        } else if let secret {
            ok = store.add(nickname: nickname, host: host, username: trimmedUser, secret: secret)
        } else {
            ok = false  // add needs a secret; canSave already prevents this — defensive.
        }
        if !ok { error = "Couldn't save this host. Check the fields (a key or password is required) and try again." }
        return ok
    }

    private func saveAndConnect() {
        guard let ep = endpoint, save() else { return }
        // Add mode requires the secret, so it is in hand here — connect straight away.
        var creds: SSHCredentials
        switch authKind {
        case .key:
            creds = SSHCredentials(host: ep.host, port: ep.port, username: trimmedUser,
                                   privateKeyPEM: trimmedKey, remoteSocketPath: "")
        case .password:
            creds = SSHCredentials(host: ep.host, port: ep.port, username: trimmedUser,
                                   password: password, remoteSocketPath: "")
        }
        // A paired machine whose address didn't change still offers only its pinned key's algorithm.
        if let editing { creds.hostKeyAlgorithm = store.hosts.first { $0.id == editing.id }?.hostKeyAlgorithm }
        onConnect(creds)
        dismiss()
    }

    // MARK: - rows

    private func fieldRow(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(label).font(Typography.app(15)).foregroundStyle(Palette.textDim)
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(Typography.machine(15)).foregroundStyle(Palette.text)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Choose how this host authenticates. Switching hides/shows the key vs password row.
    private var authPicker: some View {
        Picker("Auth", selection: $authKind) {
            Text("Key").tag(SavedAuthKind.key)
            Text("Password").tag(SavedAuthKind.password)
        }
        .pickerStyle(.segmented)
        .padding(.vertical, 2)
    }

    /// The password field. A SecureField masks the value, so unlike the key it is safe
    /// to enter inline; on edit it starts blank and the stored password is kept unless a
    /// new one is typed. Stored in the Keychain (device-only), same as the key.
    private var passwordRow: some View {
        HStack {
            Text("Password").font(Typography.app(15)).foregroundStyle(Palette.textDim)
            SecureField(hasSavedSecret ? "saved · type to replace" : "password", text: $password)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(Typography.machine(15)).foregroundStyle(Palette.text)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// The key row NEVER renders the key itself — only whether one is set (the connect
    /// screen is screenshotted onto an open port, so the PEM must not be on screen).
    private var keyRow: some View {
        Button { showingKeySheet = true } label: {
            HStack {
                Text("Key").font(Typography.app(15)).foregroundStyle(Palette.textDim)
                Spacer()
                if !keyPEM.isEmpty {
                    Text(hasSavedSecret ? "new key" : "ed25519 key")
                        .font(Typography.machine(15)).foregroundStyle(Palette.text)
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.done)
                } else if hasSavedSecret {
                    Text("saved · tap to replace").font(Typography.app(15)).foregroundStyle(Palette.textFaint)
                } else {
                    Text("Add private key").font(Typography.app(15)).foregroundStyle(Palette.textFaint)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    /// The key is NEVER rendered on screen (the connect screen can be screenshotted onto
    /// an open tailnet port, and a screen recording would otherwise capture it). Instead
    /// it is pasted from the clipboard straight into memory / the Keychain, and only a
    /// "key set" confirmation is shown.
    private var keySheet: some View {
        NavigationStack {
            ZStack {
                Palette.ground.ignoresSafeArea()
                // Scrolled, matching the main form above. With two routes on screen —
                // file button, caption, PasteButton, rule, a 110pt editor, accept button,
                // the "Key set" row and an error line — this overflows a small iPhone,
                // and raising the keyboard for the paste field guarantees it.
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // The old copy said the key comes from the clipboard and is "never
                        // displayed". Both stopped being true here: there are two routes now,
                        // and the paste field shows the key while it is being pasted. A
                        // security claim left standing after the property it described is gone
                        // is worse than no claim, so it says what is actually true instead.
                        Text("Pick your ed25519 private key file, or paste the key below. It is stored in the Keychain on this device only, and sent over the SSH connection.")
                            .font(Typography.app(13)).foregroundStyle(Palette.textDim)

                        // FILE FIRST, and deliberately so. herdrup runs on macOS as a
                        // "Designed for iPad" app (SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD),
                        // where the PasteButton below is inert — the Mac pasteboard does not
                        // surface a matching payload type to the iOS compatibility layer, so
                        // the control stays disabled and there is NOTHING ELSE on this sheet.
                        // A Mac user was therefore hard-blocked from adding a host at all.
                        //
                        // The file path also happens to be the natural one on a Mac: the key
                        // is already at ~/.ssh/id_ed25519, and reading it renders nothing.
                        Button { showingKeyImporter = true } label: {
                            Label("Choose key file…", systemImage: "folder")
                                .font(Typography.app(16, .semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 15)
                                .background(Palette.text).foregroundStyle(Palette.ground)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)

                        caption("Your key is usually at ~/.ssh/id_ed25519. That folder is "
                                + "hidden — in the file picker press ⇧⌘. to show hidden files, "
                                + "or ⇧⌘G and type the path.", color: Palette.textFaint)

                        // System PasteButton, NOT a programmatic UIPasteboard read: the tap
                        // itself is the paste consent, so it never shows the "Allow Paste"
                        // permission prompt (which was the iPad App Review failure) and still
                        // hands us the key WITHOUT rendering it. Auto-disables when the
                        // clipboard holds no text — which on the Mac build is always.
                        PasteButton(payloadType: String.self) { items in
                            // The action can run off the main actor; hop before touching @State.
                            Task { @MainActor in ingestKey(items.first) }
                        }
                        .labelStyle(.titleAndIcon)
                        .tint(Palette.text)
                        .buttonBorderShape(.roundedRectangle(radius: 12))
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)

                        // The second route, a PEER of the file picker rather than something
                        // hidden behind a disclosure. Pasting into a field the user focused is
                        // their own action, so it triggers no "Allow Paste" prompt — what got
                        // this app rejected under 2.1a was a PROGRAMMATIC pasteboard read, not
                        // a person pressing Cmd-V.
                        HStack(spacing: 10) {
                            Rectangle().fill(Palette.surface).frame(height: 1)
                            Text("or paste it").font(Typography.app(12))
                                .foregroundStyle(Palette.textFaint)
                            Rectangle().fill(Palette.surface).frame(height: 1)
                        }
                        .padding(.vertical, 2)

                        TextEditor(text: $manualKey)
                            .font(Typography.machine(12))
                            .frame(height: 110)
                            .scrollContentBackground(.hidden)
                            .background(Palette.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        Button("Use pasted key") {
                            ingestKey(manualKey)
                            // Drop the visible copy as soon as it is accepted.
                            if keyError == nil { manualKey = "" }
                        }
                        .font(Typography.app(15, .semibold))
                        .foregroundStyle(manualKey.isEmpty ? Palette.textFaint : Palette.text)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .disabled(manualKey.isEmpty)

                        if !keyPEM.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.done)
                                Text("Key set").font(Typography.app(15)).foregroundStyle(Palette.text)
                                Spacer(minLength: 8)
                                Button("Clear") { keyPEM = ""; keyError = nil }
                                    .font(Typography.app(14)).foregroundStyle(Palette.died)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        if let keyError { caption(keyError, color: Palette.died) }
                        Spacer(minLength: 0)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Private key")
            .fileImporter(
                isPresented: $showingKeyImporter,
                allowedContentTypes: [.item],  // an SSH key has no UTType and no extension
                allowsMultipleSelection: false
            ) { result in
                importKeyFile(result)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingKeySheet = false }.foregroundStyle(Palette.textDim)
                }
            }
        }
    }

    /// Read a private key the user picked in the file browser.
    ///
    /// This is the path that unblocks macOS, where `PasteButton` never enables. The file
    /// is read and discarded — nothing is copied into the app's container, and the key is
    /// not rendered.
    private func importKeyFile(_ result: Result<[URL], Swift.Error>) {
        switch result {
        case .failure(let err):
            keyError = "Couldn't open that file: \(err.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            // A file picked outside the sandbox is security-scoped; without this the read
            // fails with a permission error that reads like a missing file.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                // A public key is the easy mistake to make here (id_ed25519.pub sits right
                // next to the private one and sorts adjacent in the picker), and the
                // generic "expected a PEM block" message would not explain it.
                if text.hasPrefix("ssh-") || url.pathExtension == "pub" {
                    keyError = "That's the PUBLIC key. Pick the file WITHOUT the .pub "
                        + "ending — usually id_ed25519."
                    return
                }
                ingestKey(text)
            } catch {
                keyError = "Couldn't read that file: \(error.localizedDescription)"
            }
        }
    }

    /// Accept a PEM key from ANY of the three routes: the file picker, the system
    /// `PasteButton`, or the manual paste field.
    ///
    /// Loosely sanity-checks that it looks like a PEM private key, so a stray string
    /// isn't stored as a key. Note what is NOT here: a programmatic `UIPasteboard` read.
    /// That triggers the system paste-permission prompt, which is what failed iPad App
    /// Review under 2.1a — every route above hands the string in instead.
    private func ingestKey(_ raw: String?) {
        // Source-agnostic wording: a message naming the clipboard would be wrong for two
        // of the three callers.
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            keyError = "That was empty. Choose your private key file, or paste the key."
            return
        }
        guard s.contains("PRIVATE KEY") else {
            keyError = "That doesn't look like a private key. It should start with "
                + "-----BEGIN OPENSSH PRIVATE KEY-----."
            return
        }
        keyPEM = s
        keyError = nil
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.app(16, .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 15)
                .background(canSave ? Palette.text : Palette.surface)
                .foregroundStyle(canSave ? Palette.ground : Palette.textFaint)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(!canSave)
        .padding(.top, 6)
    }

    private func caption(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Typography.app(12)).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
    }
}
