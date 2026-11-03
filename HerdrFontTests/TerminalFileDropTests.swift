import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Herdr

/// The terminal's file drop (herdrup#575): which dragged items the terminal offers to the
/// composer, and how a batch of them stages. The drag itself is driven end to end in
/// `TerminalDropTests`; these pin the rule on item providers built the way Finder, Files
/// and a text drag build them, since a `UIDropSession` cannot be constructed in a test.
final class TerminalFileDropTests: XCTestCase {
    private var staged: [URL] = []

    override func tearDown() {
        for dir in staged { try? FileManager.default.removeItem(at: dir) }
        staged = []
        super.tearDown()
    }

    func testADropKeepsItsFilesAndImagesInOrderAndLeavesTextAndLinks() {
        let pdf = pdfProvider(named: "report.pdf")
        let text = NSItemProvider(object: "echo hello" as NSString)
        let file = fileURLProvider(named: "notes.txt", contents: "from finder")
        let link = NSItemProvider(object: URL(string: "https://example.com/page")! as NSURL)
        let image = NSItemProvider()
        image.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { done in
            done(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { _ in }, nil)
            return nil
        }

        let files = TerminalFileDrop.files(in: [pdf, text, file, link, image])

        XCTAssertEqual(files.count, 3, "the PDF, the file url and the image are files; the text and the link are not")
        XCTAssertTrue(files[0] === pdf && files[1] === file && files[2] === image, "in drag order")
    }

    /// Plain text keeps today's behaviour on the terminal: nothing. The target refuses a
    /// drag with no file in it (so it never lights up), and a composer drop of it stages
    /// nothing.
    func testATextOnlyDragOffersTheTerminalNothing() async {
        let providers = [NSItemProvider(object: "ls -la" as NSString),
                         NSItemProvider(object: URL(string: "https://example.com")! as NSURL)]
        XCTAssertTrue(TerminalFileDrop.files(in: providers).isEmpty)
        let outcome = await PastedFile.stageAll(providers, room: ComposerStaging.maxAttachments)
        XCTAssertTrue(outcome.files.isEmpty)
        XCTAssertNil(outcome.note, "text is skipped silently, not reported as a failed file")
    }

    /// Several files in one drop each stage, under their own names, through the paste
    /// path's staging (a file url resolves to the file it names, not its path text).
    func testSeveralDroppedFilesEachStageUnderTheirOwnNames() async throws {
        let providers = [fileURLProvider(named: "dragged-note.txt", contents: "dragged from finder"),
                         NSItemProvider(object: "a text snippet" as NSString),
                         pdfProvider(named: "dragged-report.pdf")]

        let outcome = await PastedFile.stageAll(providers, room: ComposerStaging.maxAttachments)
        staged += outcome.files.map(\.staged.dir)

        XCTAssertEqual(outcome.files.map(\.name), ["dragged-note.txt", "dragged-report.pdf"])
        XCTAssertNil(outcome.note)
        let note = try XCTUnwrap(outcome.files.first)
        XCTAssertEqual(try String(contentsOf: note.staged.url, encoding: .utf8), "dragged from finder",
                       "the file's bytes are staged, not the path text")
        XCTAssertEqual(outcome.files.last?.mime, "application/pdf")
        XCTAssertFalse(outcome.files.contains(where: \.isImage))
    }

    /// The composer's count cap holds for a drop: only the room left stages, and the rest
    /// are named in the picker's wording.
    func testADropBeyondTheAttachmentCapStagesOnlyTheRoomLeft() async {
        let providers = [pdfProvider(named: "one.pdf"), pdfProvider(named: "two.pdf"), pdfProvider(named: "three.pdf")]

        let outcome = await PastedFile.stageAll(providers, room: 1)
        staged += outcome.files.map(\.staged.dir)

        XCTAssertEqual(outcome.files.map(\.name), ["one.pdf"])
        XCTAssertEqual(outcome.note, "Skipped: 2 over the \(ComposerStaging.maxAttachments)-file limit.")
    }

    /// A folder is refused before any copy, with the paste path's own note.
    func testADroppedFolderIsRefusedWithItsNote() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dropped-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let outcome = await PastedFile.stageAll([fileURLProvider(at: folder)], room: 5)

        XCTAssertTrue(outcome.files.isEmpty)
        XCTAssertEqual(outcome.note, "Folders can't be attached — pick the files inside.")
    }

    private func pdfProvider(named name: String) -> NSItemProvider {
        let page = CGRect(x: 0, y: 0, width: 40, height: 20)
        let pdf = UIGraphicsPDFRenderer(bounds: page).pdfData { $0.beginPage() }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.pdf.identifier, visibility: .all) { done in
            done(pdf, nil)
            return nil
        }
        provider.suggestedName = name
        return provider
    }

    private func fileURLProvider(named name: String, contents: String) -> NSItemProvider {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? Data(contents.utf8).write(to: url, options: .atomic)
        return fileURLProvider(at: url)
    }

    /// What a Finder or Files drag of a document vends: a `public.file-url` naming it.
    private func fileURLProvider(at url: URL) -> NSItemProvider {
        let provider = NSItemProvider(object: url as NSURL)
        if !provider.registeredTypeIdentifiers.contains(UTType.fileURL.identifier) {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier,
                                                visibility: .all) { done in
                done(url.dataRepresentation, nil)
                return nil
            }
        }
        return provider
    }
}
