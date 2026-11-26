import HerdrKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The composer's paperclip, shared by the Gram page, the guest pane and the terminal
/// composer so all three look and behave alike. It only asks for the attach sheet;
/// `composerAttachPicker` presents it and stages what the reader picks.
struct ComposerAttachButton: View {
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ComposerActionIcon(image: Image(systemName: "paperclip"), tint: Palette.textDim, busy: busy)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Attach file")
    }
}

/// Attachment staging for every composer (the Gram page, the terminal reply, the guest
/// pane), deliberately a TOP-LEVEL TYPE rather than statics on a view.
///
/// `View` is `@MainActor`, so everything on a view inherits that isolation — but
/// `ComposerPickedMedia`'s `FileRepresentation` importer is a nonisolated `@Sendable`
/// closure, so calling a main-actor static from it is a cross-actor call (a hard error
/// for a method). A type outside the view does NOT inherit that isolation, which is what
/// is wanted here twice over: the importer can call it directly, and copying a 100 MB
/// pick never runs on the main actor.
///
/// One staging directory per app SESSION. That level exists for the case where no
/// cleanup path runs at all: on a crash or a jetsam kill `onDisappear` never fires, so
/// staged bytes would otherwise sit in tmp untracked. A session directory makes every
/// earlier session's leftovers a single identifiable sibling for the launch-time sweep,
/// while the per-item directories inside it still give a per-chip unlink.
enum ComposerStaging {
    /// Client-side attachment cap, mirroring the server's `MAX_FILE_BYTES` (100 MiB)
    /// and inclusive as the server's is. The upload streams from disk in frames, so any
    /// size uploads fine regardless of divisibility; this is just the pre-send size gate.
    static let maxFileBytes = 100 * 1024 * 1024

    /// How many files can be staged at once, in any composer (Gram, the terminal reply,
    /// the guest). Each sends as its own gram message.
    ///
    /// 10, matching the photo picker's `maxSelectionCount`. It was cut to 3 when a staged
    /// file was held in memory as `Data`: ten 100 MB picks would have been ~1 GB
    /// resident. Staged bytes now live in a temp file and the upload reads them one frame
    /// at a time, so the resident ceiling is a single frame no matter how many files are
    /// staged or how large they are. Every composer uploads through its SERIAL
    /// `ComposerUploader` (one file at a time, and Send's own uploads queue on the same
    /// line), so one composer never has more than one upload in flight against the
    /// daemon's 1 GiB aggregate staging budget; `gram.post` consumes each staging file,
    /// and a removed or abandoned one is discarded (`gram.upload.discard`).
    static let maxAttachments = 10

    static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("gram-staging", isDirectory: true)
    static let session = root
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    /// Copy a picked file into app-owned staging, so the send streams it from disk and
    /// the app owns its lifetime. nil when the copy fails or the copied file is empty /
    /// over the cap — the caller reports it as a skip.
    ///
    /// The work is `HerdrKit.GramStaging`'s, not this file's: this target is iOS-only
    /// and cannot run on CI, and a staging bug here is silent (it renders as the same
    /// "unreadable pick" message as a genuinely bad file). In HerdrKit it is tested.
    static func copy(of source: URL, named name: String) -> StagedAttachment? {
        GramStaging.stageCopy(of: source, named: name, in: session, maxBytes: maxFileBytes)
    }

    /// Remove staging left by PREVIOUS app sessions (a crash or jetsam runs no cleanup).
    ///
    /// Called from the app root's `.task`, not the Gram page's: bytes from a killed
    /// session must be reclaimed even in a launch where the Gram tab is never opened.
    /// Off the main actor because the unlink is a synchronous recursive walk and the
    /// abandoned set can be ten 100 MB attachments.
    static func sweepAbandonedOffMainActor() async {
        let stagingRoot = root
        let current = session.lastPathComponent
        await Task.detached(priority: .utility) {
            GramStaging.sweepAbandoned(root: stagingRoot, keeping: current)
        }.value
    }
}

/// The one way every composer (the terminal reply, the guest pane, the Gram page) drives
/// its `ComposerUploader` against its host: each file starts uploading as it is added, Send
/// waits on those uploads through `sender`, and a file that leaves the draft (its chip's X,
/// or the composer closing) is cancelled or discarded on the host.
extension ComposerUploader {
    /// Uploads a file's staged bytes to `client`'s host, reporting byte progress.
    static func upload(to client: HerdrClient) -> Upload {
        { file, progress in
            try await client.gramUploadFile(fileURL: file.staged.url, onProgress: progress)
        }
    }

    /// Drops a finished upload on `client`'s host; a host that predates the call ignores it.
    static func discard(on client: HerdrClient) -> Discard {
        { uploadID in _ = try await client.gramUploadDiscard(uploadID: uploadID) }
    }

    /// Writes each landed upload's host id into the composer's staged list, so Send posts
    /// it as a resumed send would. Through the list's `Binding`, never a closure over the
    /// view: the uploader keeps this for as long as the file is staged, and a captured
    /// view (which holds the uploader in its `@State`) would keep the uploader alive past
    /// its pane, so closing the pane would never cancel or discard the draft's uploads.
    static func record(into list: Binding<[ComposerAttachment]>) -> Uploaded {
        { id, uploadID in
            guard let index = list.wrappedValue.firstIndex(where: { $0.id == id }) else { return }
            list.wrappedValue[index].uploadID = uploadID
        }
    }

    /// Starts uploading newly staged files; each host id lands in `list` (`record(into:)`).
    func start(_ files: [ComposerAttachment], client: HerdrClient, into list: Binding<[ComposerAttachment]>) {
        start(files, client: client, uploaded: Self.record(into: list))
    }

    /// Starts uploading newly staged files; each host id goes to `uploaded`, which must not
    /// hold the uploader's owner strongly (the uploader keeps it while the file is staged).
    func start(_ files: [ComposerAttachment], client: HerdrClient, uploaded: @escaping Uploaded) {
        for file in files {
            start(file, upload: Self.upload(to: client), uploaded: uploaded, discard: Self.discard(on: client))
        }
    }

    /// Send's sender: a file still uploading is awaited, a finished one posts at once, and
    /// one with no upload (failed, paused, or lost by the host) uploads in this line. A
    /// posted file's bytes move into the download cache, so opening it later (Chat's
    /// attachment list, Gram) never downloads what this device uploaded.
    func sender(
        client: HerdrClient, into list: Binding<[ComposerAttachment]>,
        post: @escaping GramAttachmentSender.Post
    ) -> GramAttachmentSender {
        sender(client: client, uploaded: Self.record(into: list), post: post)
    }

    /// `sender(client:into:post:)` with the host ids going to `uploaded` (see
    /// `start(_:client:uploaded:)`).
    func sender(
        client: HerdrClient, uploaded: @escaping Uploaded,
        post: @escaping GramAttachmentSender.Post
    ) -> GramAttachmentSender {
        GramAttachmentSender(
            upload: { [self] file in
                try await upload(file, using: Self.upload(to: client), uploaded: uploaded,
                                 discard: Self.discard(on: client))
            },
            preUploaded: { [self] file in try await waitForUpload(file.id) },
            post: post,
            keep: { file in await GramView.Downloads.keep(file) })
    }

    /// The Send button's ring while it waits on uploads still running among `files`.
    func sendProgress(_ files: [ComposerAttachment], sending: Bool) -> Double? {
        sending ? pendingProgress(of: files.map(\.id)) : nil
    }
}

/// One picked file, already copied into app-owned staging (`ComposerStaging`), so the
/// send streams it from disk and the composer owns its lifetime.
struct ComposerPickedFile {
    let name: String
    let mime: String
    let isImage: Bool
    let staged: StagedAttachment
}

/// What one pick produced: the files that staged, and a note naming what did not
/// (nil when everything staged), in the wording every composer shows.
struct ComposerPickOutcome {
    var files: [ComposerPickedFile] = []
    var note: String?
}

extension View {
    /// The attach sheet and the two system pickers behind it.
    ///
    /// The paperclip sets `isPresented`; a Telegram-style sheet picks the source, and
    /// the RIGHT system picker opens once that sheet has finished dismissing (presenting
    /// one sheet while another is dismissing drops the second on iOS). Picks are staged
    /// here, bounded by `ComposerStaging.maxFileBytes` each and by `room()` in number,
    /// so every composer enforces the same limits. `loading` is true while a photo batch
    /// loads (iCloud items can take a moment) and gates the composer's own send.
    func composerAttachPicker(
        isPresented: Binding<Bool>,
        loading: Binding<Bool>,
        room: @escaping () -> Int,
        onPick: @escaping (ComposerPickOutcome) -> Void
    ) -> some View {
        modifier(ComposerAttachPicker(isPresented: isPresented, loading: loading,
                                      room: room, onPick: onPick))
    }
}

private struct ComposerAttachPicker: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var loading: Bool
    let room: () -> Int
    let onPick: (ComposerPickOutcome) -> Void

    private enum Source { case photos, file }
    @State private var pending: Source?
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, onDismiss: presentPending) {
                sheet
                    .presentationDetents([.height(190)])
                    .presentationDragIndicator(.visible)
            }
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $photoItems,
                maxSelectionCount: ComposerStaging.maxAttachments,
                matching: .any(of: [.images, .videos])
            )
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []  // reset now so re-picking the same items fires onChange again
                Task { await stagePhotos(items) }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item],
                          allowsMultipleSelection: true) { stageFiles($0) }
    }

    private var sheet: some View {
        VStack(spacing: 18) {
            Text("Attach")
                .font(Typography.app(14, .semibold)).foregroundStyle(Palette.textDim)
                .padding(.top, 16)
            HStack(spacing: 20) {
                option(icon: "photo.on.rectangle.angled", label: "Photo & Video", id: "composer-attach-photos") {
                    pending = .photos
                    isPresented = false
                }
                option(icon: "doc", label: "File", id: "composer-attach-file") {
                    pending = .file
                    isPresented = false
                }
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity)
        .background(Palette.ground.ignoresSafeArea())
    }

    private func option(icon: String, label: String, id: String,
                        _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold)).foregroundStyle(Palette.text)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Palette.surface))
                    .overlay(Circle().stroke(Palette.hairline, lineWidth: 1))
                Text(label).font(Typography.app(13, .medium)).foregroundStyle(Palette.textDim)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func presentPending() {
        defer { pending = nil }
        switch pending {
        case .photos: showPhotoPicker = true
        case .file:
            #if DEBUG
            // The UI-test harness cannot drive the out-of-process document picker, so
            // it hands over a picked file here and it takes the picker's own callback.
            if let urls = TerminalInteractionHarness.pickedFiles() {
                stageFiles(.success(urls))
                return
            }
            #endif
            showFileImporter = true
        case nil: break
        }
    }

    /// Stages picked documents as COPIES ON DISK. Importer URLs are security-scoped,
    /// so the copy happens inside the access window; the URL is unreadable after it.
    /// A KNOWN size within the cap is required BEFORE copying: an unstat-able URL is
    /// treated as over-cap, never staged, so a multi-gigabyte pick with no reported
    /// size cannot fall through to an unbounded copy. Bad picks are COLLECTED into one
    /// note, so one bad file among several still stages the good ones.
    private func stageFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        var outcome = ComposerPickOutcome()
        var bad: [String] = []
        var capped = 0
        let available = room()
        for url in urls {
            guard outcome.files.count < available else {
                capped += 1
                continue
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = GramStaging.safeFileName(url.lastPathComponent)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size <= ComposerStaging.maxFileBytes,
                  let staged = ComposerStaging.copy(of: url, named: name)
            else {
                bad.append(url.lastPathComponent)
                continue
            }
            let type = UTType(filenameExtension: url.pathExtension)
            outcome.files.append(ComposerPickedFile(
                name: name, mime: type?.preferredMIMEType ?? "application/octet-stream",
                isImage: type?.conforms(to: .image) ?? false, staged: staged))
        }
        outcome.note = Self.skipNote(
            bad: bad.isEmpty ? nil : "too large or unreadable: \(bad.joined(separator: ", "))",
            capped: capped)
        onPick(outcome)
    }

    /// Loads photo-library picks SERIALLY (bounded disk pressure, stable order), each
    /// through `ComposerPickedMedia` so the size cap is enforced on the exported file
    /// before it is copied — the same invariant the document path holds.
    private func stagePhotos(_ items: [PhotosPickerItem]) async {
        loading = true
        defer { loading = false }
        var outcome = ComposerPickOutcome()
        var bad = 0
        var capped = 0
        let available = room()
        for item in items {
            guard outcome.files.count < available else {
                capped += 1
                continue
            }
            // A nil transferable = couldn't produce a file; a nil `staged` = rejected by
            // the size guard, or the copy failed.
            guard let media = try? await item.loadTransferable(type: ComposerPickedMedia.self),
                  let staged = media.staged
            else {
                bad += 1
                continue
            }
            let (name, mime, isImage) = Self.photoNameAndMime(for: item)
            outcome.files.append(ComposerPickedFile(name: name, mime: mime, isImage: isImage, staged: staged))
        }
        outcome.note = Self.skipNote(
            bad: bad == 0 ? nil : bad == 1 ? "1 item too large or unreadable" : "\(bad) items too large or unreadable",
            capped: capped)
        onPick(outcome)
    }

    private static func skipNote(bad: String?, capped: Int) -> String? {
        var parts: [String] = []
        if let bad { parts.append(bad) }
        if capped > 0 { parts.append("\(capped) over the \(ComposerStaging.maxAttachments)-file limit") }
        guard !parts.isEmpty else { return nil }
        return "Skipped: " + parts.joined(separator: "; ") + "."
    }

    /// A filename, MIME and image flag for a library pick from its concrete content type
    /// (HEIC, JPEG, MOV, …). The name carries a short unique discriminator so three
    /// photos don't all arrive as "image.heic" — identical chips for the reader and a
    /// name collision for any receiving agent that stores attachments by name.
    private static func photoNameAndMime(for item: PhotosPickerItem) -> (String, String, Bool) {
        let disc = UUID().uuidString.prefix(8).lowercased()
        let type = item.supportedContentTypes.first
        let isMovie = type?.conforms(to: .movie) == true
        if let type, let ext = type.preferredFilenameExtension, let mime = type.preferredMIMEType {
            return ("\(isMovie ? "video" : "image")-\(disc).\(ext)", mime, !isMovie)
        }
        return isMovie ? ("video-\(disc).mov", "video/quicktime", false) : ("image-\(disc).jpg", "image/jpeg", true)
    }
}

/// A photo-library pick copied into app-owned staging. PhotosUI exports the item to a
/// temp file and DELETES it when the closure returns, so the copy has to happen inside
/// `FileRepresentation`; the importer stats that export and rejects an over-cap (or
/// unstat-able) pick THERE — `staged == nil` — before any copy.
///
/// Rejection is a VALUE, not a thrown error: `loadTransferable` routes through
/// NSItemProvider's Obj-C error bridge, across which a Swift error type may not survive.
private struct ComposerPickedMedia: Transferable {
    let staged: StagedAttachment?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            guard let size = try? received.file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size <= ComposerStaging.maxFileBytes
            else { return ComposerPickedMedia(staged: nil) }
            return ComposerPickedMedia(staged: ComposerStaging.copy(
                of: received.file, named: received.file.lastPathComponent))
        }
    }
}
