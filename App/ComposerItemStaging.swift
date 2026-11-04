import Foundation
import HerdrKit
import UIKit
import UniformTypeIdentifiers

/// WHICH PASTED OR DROPPED ITEMS A COMPOSER TREATS AS A FILE rather than as text, and how
/// one is staged.
///
/// Shared by the reply editor's UIKit text view (which decides whether to offer and
/// intercept Paste), the owner's pane (which stages a paste or a drop on its composer or
/// its terminal) and the guest pane (which stages a drop on its terminal), so none of them
/// can disagree about what "a file" is or stage one differently.
enum PastedFile {
    /// Concrete bytes, or a package like an .rtfd bundle — but never text, a web link or
    /// a contact card, which are ordinary pastes the reader expects to land as
    /// characters.
    ///
    /// A FILE URL is the exception, and it is the whole reason Copy in Finder or Files
    /// used to paste a path instead of attaching the file: `public.file-url` conforms to
    /// `public.url`, so the link exclusion swallowed it. A file url names bytes; a web
    /// url names a page.
    static func isAttachment(_ type: UTType) -> Bool {
        if type.conforms(to: .fileURL) { return true }
        guard type.conforms(to: .data) || type.conforms(to: .package) else { return false }
        return !type.conforms(to: .text) && !type.conforms(to: .url)
            && !type.conforms(to: .vCard) && type != .rtf && type != .flatRTFD
    }

    /// The first attachable type on the general pasteboard, read from TYPE METADATA ONLY.
    ///
    /// `UIPasteboard.types` never touches the items, so this is safe to call while UIKit
    /// builds an edit menu. Reading `itemProviders` there instead is a content read, which
    /// raises the system "Allow Paste?" prompt for anything copied in another app.
    ///
    /// A file url wins the LOOKUP when both are advertised — it is the representation
    /// that survives a cross-process copy with its name intact — but staging still
    /// prefers the file's concrete type, because a url is a reference and bytes are not.
    static func pasteboardType() -> UTType? {
        let types = UIPasteboard.general.types.lazy.compactMap { UTType($0) }
        return types.first { $0.conforms(to: .fileURL) } ?? types.first(where: isAttachment)
    }

    /// Whether the pasteboard names a FILE. Metadata only, and the one case where an
    /// accompanying text representation must not win: Finder and Files put the path on
    /// the pasteboard beside the file, and pasting that path is never what was meant.
    static func pasteboardHasFileURL() -> Bool {
        UIPasteboard.general.contains(pasteboardTypes: [UTType.fileURL.identifier])
    }

    /// The type an item is staged THROUGH, or nil when it is not a file at all.
    ///
    /// A FILE URL WINS when the item carries one. A Finder copy of a document vends
    /// the file url AND the document's ICON (com.apple.icns, which conforms to
    /// public.image), so preferring the image staged a 288 KB icon called
    /// "photo-31ec1fb2.icns" instead of the PDF the reader copied. Any image beside a
    /// file url is derived from that file — an icon, a thumbnail, or, when the file IS
    /// an image, the same bytes under a worse name.
    ///
    /// Without a file url the item is in-memory: a screenshot, an image copied out of
    /// Safari, a PDF put on the pasteboard as data. Then an image wins over any other
    /// concrete type, as before.
    static func stagingType(of types: [UTType]) -> UTType? {
        types.first(where: { $0.conforms(to: .fileURL) })
            ?? types.first(where: { $0.conforms(to: .image) })
            ?? types.first(where: isAttachment)
    }

    static func stagingType(of provider: NSItemProvider) -> UTType? {
        stagingType(of: provider.registeredTypeIdentifiers.compactMap { UTType($0) })
    }

    /// What staging one item produced: the attachment, or nil with an optional reason more
    /// specific than the composers' generic "Couldn't add that attachment."
    struct Staged: Sendable {
        var attachment: ComposerAttachment?
        var refusal: String?
    }

    /// Copies one pasted or dropped item into composer staging (`ComposerStaging`, so the
    /// same per-file size cap as the paperclip), read through `type` from
    /// `stagingType(of:)`.
    static func stage(_ provider: NSItemProvider, as type: UTType) async -> Staged {
        // A file url is a REFERENCE, not bytes: loading it as a file representation
        // yields a temp file containing the path text. Resolve it to the real file and
        // copy from there, inside a security scope, because a document picked outside the
        // app's container is only readable while that scope is open.
        if type.conforms(to: .fileURL) {
            let objectResult: Staged? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url.map(stageReferencedFile))
                }
            }
            if let objectResult { return objectResult }
            // A pasteboard item can advertise public.file-url bytes alongside its
            // Finder icon without vending an NSURL object. Read that same reference,
            // not the image representation or a temporary file containing URL text.
            return await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    let source = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    guard let source, source.isFileURL else {
                        continuation.resume(returning: Staged())
                        return
                    }
                    continuation.resume(returning: stageReferencedFile(source))
                }
            }
        }

        let typeIdentifier = type.identifier
        let isImage = type.conforms(to: .image)
        let ext = type.preferredFilenameExtension ?? (isImage ? "jpg" : "dat")
        let name: String = {
            var candidate = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if candidate.isEmpty {
                let stem = isImage ? "photo" : "file"
                candidate = "\(stem)-\(UUID().uuidString.prefix(8).lowercased()).\(ext)"
            }
            if URL(fileURLWithPath: candidate).pathExtension.isEmpty { candidate += ".\(ext)" }
            return GramStaging.safeFileName(candidate)
        }()
        let mime = type.preferredMIMEType ?? (isImage ? "image/jpeg" : "application/octet-stream")

        let fromFile: ComposerAttachment? = await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { source, _ in
                // The url is only valid inside this handler, so the copy happens here.
                let attachment = source.flatMap { url in
                    ComposerStaging.copy(of: url, named: name).map {
                        ComposerAttachment(name: name, mime: mime, isImage: isImage, staged: $0)
                    }
                }
                continuation.resume(returning: attachment)
            }
        }
        if let fromFile { return Staged(attachment: fromFile) }

        // In-memory pasteboards can vend encoded bytes but no file URL.
        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                let attachment = data.flatMap {
                    GramStaging.stageData($0, named: name, in: ComposerStaging.session,
                                          maxBytes: ComposerStaging.maxFileBytes)
                        .map { ComposerAttachment(name: name, mime: mime, isImage: isImage, staged: $0) }
                }
                continuation.resume(returning: Staged(attachment: attachment))
            }
        }
    }

    /// Stages a DROP of several items one after another, into the shape a paperclip pick
    /// produces, so a composer that takes picks (the guest pane) takes a drop through the
    /// very same callback. Items that are not files are skipped; at most `room` stage, and
    /// the rest are named in the note in the attach picker's wording.
    static func stageAll(_ providers: [NSItemProvider], room: Int) async -> ComposerPickOutcome {
        var outcome = ComposerPickOutcome()
        var refusals: [String] = []
        var bad = 0
        var capped = 0
        for provider in providers {
            guard let type = stagingType(of: provider) else { continue }
            guard outcome.files.count < room else {
                capped += 1
                continue
            }
            let staged = await stage(provider, as: type)
            guard let file = staged.attachment else {
                if let refusal = staged.refusal { refusals.append(refusal) } else { bad += 1 }
                continue
            }
            outcome.files.append(ComposerPickedFile(name: file.name, mime: file.mime,
                                                    isImage: file.isImage, staged: file.staged))
        }
        var parts: [String] = []
        if bad > 0 { parts.append(bad == 1 ? "1 item too large or unreadable" : "\(bad) items too large or unreadable") }
        if capped > 0 { parts.append("\(capped) over the \(ComposerStaging.maxAttachments)-file limit") }
        let skipped = parts.isEmpty ? nil : "Skipped: " + parts.joined(separator: "; ") + "."
        let notes = refusals + (skipped.map { [$0] } ?? [])
        outcome.note = notes.isEmpty ? nil : notes.joined(separator: " ")
        return outcome
    }

    /// Stages the file a file url names, under the file's own name.
    private static func stageReferencedFile(_ source: URL) -> Staged {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]
        let values = try? source.resourceValues(forKeys: keys)
        // A DIRECTORY, refused before the copy. `stageCopy` would happily recurse a whole
        // folder into tmp and only then fail its size check, which is an unbounded copy
        // for a message that cannot carry it.
        if values?.isDirectory == true {
            return Staged(refusal: "Folders can't be attached — pick the files inside.")
        }
        // An iCloud placeholder has no bytes yet. Ask for the download and say so,
        // instead of reporting the generic "couldn't add" for a file the reader can
        // plainly see in Files.
        if values?.isUbiquitousItem == true,
           values?.ubiquitousItemDownloadingStatus != .current {
            try? FileManager.default.startDownloadingUbiquitousItem(at: source)
            return Staged(refusal: "\(source.lastPathComponent) isn't downloaded yet — "
                + "opening it in Files once will fetch it.")
        }
        let name = GramStaging.safeFileName(source.lastPathComponent)
        guard !name.isEmpty,
              let staged = ComposerStaging.copy(of: source, named: name)
        else { return Staged() }
        let fileType = UTType(filenameExtension: source.pathExtension)
        return Staged(attachment: ComposerAttachment(
            name: name,
            mime: fileType?.preferredMIMEType ?? "application/octet-stream",
            isImage: fileType?.conforms(to: .image) ?? false,
            staged: staged))
    }
}
