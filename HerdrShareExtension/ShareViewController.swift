import SwiftUI
import UIKit
import UniformTypeIdentifiers
import HerdrKit

@MainActor
final class ShareViewController: UIViewController {
    private let model = ShareModel()
    private var operation: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        let child = UIHostingController(rootView: ShareSheet(model: model, cancel: { [weak self] in
            self?.finish(cancelled: true)
        }, send: { [weak self] in
            guard let self else { return }
            operation = Task {
                if await self.model.send() {
                    try? await Task.sleep(for: .milliseconds(700))
                    if !Task.isCancelled { self.finish(cancelled: false) }
                }
            }
        }))
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        child.didMove(toParent: self)
        operation = Task { await model.prepare(extensionContext?.inputItems ?? []) }
    }

    private func finish(cancelled: Bool) {
        operation?.cancel()
        model.close()
        if cancelled {
            extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}

private struct ShareRecipient: Identifiable {
    let id: String
    let name: String
    let target: String
    let machine: String
    let guest: Bool
    let client: HerdrClient
}

/// The relay invokes feature callbacks off-main; reads after agentList must see
/// the hello that authorized that request, not an asynchronously queued UI update.
private final class ShareFeatures: @unchecked Sendable {
    private let lock = NSLock()
    private var value = GuestFeatures.none
    func set(_ features: GuestFeatures) { lock.lock(); defer { lock.unlock() }; value = features }
    var gram: Bool { lock.lock(); defer { lock.unlock() }; return value.gram }
}

@MainActor
private final class ShareModel: ObservableObject {
    @Published var recipients: [ShareRecipient] = []
    @Published var selected: String?
    @Published var search = ""
    @Published var message = ""
    @Published var files: [ComposerAttachment] = []
    @Published var loading = true
    @Published var sending = false
    @Published var sent = false
    @Published var progress = 0.0
    @Published var status = "Loading shared items…"
    @Published var error: String?
    @Published var connectionErrors: [String] = []
    private var sharedText: [String] = []
    private var transports: [CitadelTransport] = []
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var inputReady = false
    private var committedRecipient: String?

    var filtered: [ShareRecipient] {
        recipients.filter { search.isEmpty || "\($0.name) \($0.machine)".localizedCaseInsensitiveContains(search) }
    }
    var canSend: Bool {
        inputReady && !loading && !sending && !sent && selected != nil &&
        (!files.isEmpty || !sharedText.isEmpty || !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    var recipientLocked: Bool { sending || committedRecipient != nil }

    func prepare(_ input: [Any]) async {
        defer { loading = false }
        do {
            for item in input.compactMap({ $0 as? NSExtensionItem }) {
                for provider in item.attachments ?? [] {
                    try Task.checkCancellation()
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        let value = try await loadItem(provider, type: UTType.fileURL.identifier)
                        guard let url = value as? URL else { throw ShareFailure("The shared file URL could not be read.") }
                        files.append(try Self.stage(url, directory: directory, suggestedName: provider.suggestedName))
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                        let value = try await loadItem(provider, type: UTType.url.identifier)
                        guard let url = value as? URL else { throw ShareFailure("The shared link could not be read.") }
                        sharedText.append(url.absoluteString)
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                        let value = try await loadItem(provider, type: UTType.plainText.identifier)
                        if let text = value as? String { sharedText.append(text) }
                        else if let data = value as? Data, let text = String(data: data, encoding: .utf8) { sharedText.append(text) }
                        else { throw ShareFailure("The shared text could not be read.") }
                    } else if let type = provider.registeredTypeIdentifiers.first(where: {
                        UTType($0)?.conforms(to: .data) == true
                    }) {
                        files.append(try await loadFile(provider, type: type))
                    } else {
                        throw ShareFailure("This item has no shareable file, link, or text representation.")
                    }
                }
            }
            inputReady = true
            status = "Finding agents…"
            await loadRecipients()
            status = files.isEmpty ? "Shared text or link" : "\(files.count) attachment(s)"
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }

    private func loadOwner(_ host: SavedHost) async {
        if Task.isCancelled { return }
        let store = SavedHostsStore.shared
        do {
            var credentials: SSHCredentials
            switch store.connection(for: host) {
            case .ready(let ready):
                credentials = ready
            case .unparseableHost:
                throw ShareFailure("Invalid host address")
            case .missingSecret:
                throw ShareFailure(host.auth == .key ? "Unlock Herdrup to access the saved key"
                                                     : "Unlock Herdrup to access the saved password")
            }
            credentials.session = SessionChoice.remembered(for: credentials)
            let transport = CitadelTransport(credentials: credentials, hostKeyPolicy: KeychainHostKeyPolicy.shared)
            transports.append(transport)
            let client = HerdrClient(transport: transport)
            let agents = try await client.agentList()
            try Task.checkCancellation()
            for agent in agents {
                guard let name = agent.name, !name.isEmpty, agent.archived == nil else { continue }
                recipients.append(ShareRecipient(id: "owner/\(host.id)/\(credentials.session ?? "default")/\(name)", name: agent.displayName, target: name,
                                                 machine: credentials.session.map { "\(host.label) · \($0)" } ?? host.label,
                                                 guest: false, client: client))
            }
        } catch is CancellationError {
        } catch { connectionErrors.append("\(host.label): \(error.localizedDescription)") }
    }

    private func loadGuest(_ access: GuestAccess, identity: GuestIdentity) async {
        if Task.isCancelled { return }
        do {
            let features = ShareFeatures()
            let client = HerdrClient(transport: access.transport(identity: identity, onFeatures: { features.set($0) }))
            let agents = try await client.agentList()
            try Task.checkCancellation()
            guard let agent = agents.first(where: { access.isSharedAgent($0) || $0.name == access.agentName }),
                  let name = agent.name, !name.isEmpty else {
                connectionErrors.append("\(access.agentName): this share is no longer available. Open Herdrup to check access.")
                return
            }
            guard features.gram else { return }
            recipients.append(ShareRecipient(id: "guest/\(access.id)", name: agent.displayName, target: name,
                                             machine: "\(access.machineLabel) · Shared by \(access.ownerName)",
                                             guest: true, client: client))
        } catch is CancellationError {
        } catch { connectionErrors.append("\(access.agentName): \(error.localizedDescription)") }
    }

    private func loadRecipients() async {
        // Independent connections overlap; one sleeping machine must not delay
        // every later machine by another full SSH connection timeout.
        await withTaskGroup(of: Void.self) { group in
            for host in SavedHostsStore.shared.hosts {
                group.addTask { @MainActor in await self.loadOwner(host) }
            }
            do {
                let data = ShareStorage.defaults.data(forKey: ShareStorage.guestsKey)
                let guests = try data.map { try JSONDecoder().decode([GuestAccess].self, from: $0) } ?? []
                if !guests.isEmpty {
                    let identity = try GuestDevice.identity()
                    for access in guests {
                        group.addTask { @MainActor in await self.loadGuest(access, identity: identity) }
                    }
                }
            } catch { connectionErrors.append(error.localizedDescription) }
        }
        let recent = ShareStorage.defaults.stringArray(forKey: ShareStorage.recentKey) ?? []
        recipients.sort {
            let a = recent.firstIndex(of: $0.id) ?? Int.max
            let b = recent.firstIndex(of: $1.id) ?? Int.max
            return a == b ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : a < b
        }
    }

    func send() async -> Bool {
        guard canSend, let recipient = recipients.first(where: { $0.id == selected }) else { return false }
        sending = true
        error = nil
        committedRecipient = recipient.id
        defer { sending = false }
        let text = (sharedText + [message]).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
        do {
            if files.isEmpty {
                _ = try await post(recipient, text: text, attachment: nil)
            } else {
                let first = files.first?.id
                let sender = GramAttachmentSender(upload: { [weak self] file in
                    try await recipient.client.gramUploadFile(fileURL: file.staged.url, onProgress: { [weak self] sent, total in
                        self?.progress = total == 0 ? 0 : Double(sent) / Double(total)
                    })
                }, post: { [weak self] file, attachment in
                    guard let self else { throw CancellationError() }
                    return try await post(recipient, text: file.id == first ? text : "", attachment: attachment)
                })
                let result = await sender.send(files, sending: { file in
                    self.status = "Sending \(file.name)…"
                    self.progress = 0
                }, update: { file in
                    if let index = self.files.firstIndex(where: { $0.id == file.id }) { self.files[index] = file }
                })
                if case .failure(let failure) = result {
                    throw ShareFailure(failure.note(failure.error.localizedDescription))
                }
            }
            var recent = ShareStorage.defaults.stringArray(forKey: ShareStorage.recentKey) ?? []
            recent.removeAll { $0 == recipient.id }
            recent.insert(recipient.id, at: 0)
            ShareStorage.defaults.set(Array(recent.prefix(50)), forKey: ShareStorage.recentKey)
            sent = true
            status = "Sent to \(recipient.name)"
            return true
        } catch is CancellationError { return false }
        catch { self.error = error.localizedDescription; return false }
    }

    private func post(_ recipient: ShareRecipient, text: String, attachment: HerdrClient.GramFileAttachment?) async throws -> String {
        if recipient.guest {
            return try await recipient.client.guestGramPost(text: text, to: recipient.target, attachment: attachment).id
        }
        return try await recipient.client.gramPost(text: text, to: recipient.target, attachment: attachment).id
    }

    func close() {
        let closing = transports
        transports.removeAll()
        Task { for transport in closing { await transport.close() } }
        try? FileManager.default.removeItem(at: directory)
    }

    private func loadItem(_ provider: NSItemProvider, type: String) async throws -> NSSecureCoding {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type) { value, error in
                if let error { continuation.resume(throwing: error) }
                else if let value { continuation.resume(returning: value) }
                else { continuation.resume(throwing: ShareFailure("The shared item could not be loaded.")) }
            }
        }
    }

    private func loadFile(_ provider: NSItemProvider, type: String) async throws -> ComposerAttachment {
        let directory = directory
        let suggestedName = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                // Provider URLs expire when this callback returns: copy before resuming.
                do {
                    if let error { throw error }
                    guard let url else { throw ShareFailure("The shared file could not be loaded.") }
                    continuation.resume(returning: try Self.stage(url, directory: directory, suggestedName: suggestedName))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    nonisolated private static func stage(_ url: URL, directory: URL, suggestedName: String?) throws -> ComposerAttachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentTypeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0,
              size <= HerdrClient.gramMaxFileBytes else {
            throw ShareFailure("Choose a non-empty file up to 100 MB; folders are not supported.")
        }
        var name = suggestedName ?? url.lastPathComponent
        if URL(fileURLWithPath: name).pathExtension.isEmpty, !url.pathExtension.isEmpty { name += "." + url.pathExtension }
        guard let staged = GramStaging.stageCopy(of: url, named: name, in: directory, maxBytes: HerdrClient.gramMaxFileBytes) else {
            throw ShareFailure("The shared file could not be copied.")
        }
        let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)
        return ComposerAttachment(name: staged.url.lastPathComponent, mime: type?.preferredMIMEType ?? "application/octet-stream",
                                  isImage: type?.conforms(to: .image) == true, staged: staged)
    }
}

private struct ShareFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private struct ShareSheet: View {
    @ObservedObject var model: ShareModel
    let cancel: () -> Void
    let send: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Send to an agent") {
                    if model.loading { ProgressView(model.status) }
                    ForEach(model.filtered) { recipient in
                        Button { model.selected = recipient.id } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(recipient.name).font(.headline)
                                    Text(recipient.machine).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.selected == recipient.id { Image(systemName: "checkmark.circle.fill") }
                            }
                        }
                        .disabled(model.recipientLocked)
                    }
                    if !model.loading && model.recipients.isEmpty {
                        Text("No agents available. Open Herdrup to connect a machine or accept an invitation. Shared agents appear only when their owner shares Gram.")
                    }
                }
                Section("Message (optional)") {
                    TextField("Add a message", text: $model.message, axis: .vertical)
                        .disabled(model.recipientLocked)
                    ForEach(model.files) { file in Text(file.name).font(.caption) }
                }
                if model.sending || model.sent {
                    Section {
                        Text(model.status)
                        if model.sending && !model.files.isEmpty { ProgressView(value: model.progress) }
                    }
                }
                if let error = model.error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if !model.connectionErrors.isEmpty {
                    Section {
                        DisclosureGroup("Unavailable connections") {
                            ForEach(Array(model.connectionErrors.enumerated()), id: \.offset) { _, message in Text(message).font(.caption) }
                        }
                    }
                }
            }
            .searchable(text: $model.search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find an agent")
            .navigationTitle("Herdrup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button("Send", action: send)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSend)
                .frame(maxWidth: .infinity)
                .padding()
                .background(.regularMaterial)
                .accessibilityIdentifier("share-send-button")
        }
    }
}
