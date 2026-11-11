import HerdrKit
import SwiftUI

/// A ```mermaid block of a reply, drawn as a diagram (#523 item 1): a placeholder while
/// `MermaidRenderer` draws it, then the image fitted to the column (a tall diagram is capped
/// at about 1.2× the width; tap opens it full screen with pinch zoom). The header copies the
/// source or swaps the drawing for its code. If mermaid cannot draw it, the block is the
/// plain code block it was before, captioned "Diagram couldn't render".
///
/// An ```svg block (or an ```xml one holding an `<svg>`) is the same card, drawn by the same
/// renderer and caches: cleaned first (`SVGDiagram.sanitize`: no script, no loads, the
/// palette for its `var(--fg)`-style colours), then rasterised as an image. One that does
/// not parse is its code block.
///
/// Only CLOSED fences get here (`ChatMarkdown`), so a reply still streaming shows code
/// until its diagram is complete. Search still matches the source (it searches the reply
/// text, not this view).
struct ChatMermaidView: View {
    let source: String
    /// `ChatMarkdownBlock.diagram`'s kind: `mermaid` or `svg`.
    var kind = "mermaid"

    @Environment(\.chatTextScale) private var textScale
    @Environment(\.displayScale) private var displayScale
    @State private var receipt = CopiedCommandReceipt.shared
    @State private var rendered: MermaidRenderer.Rendered?
    @State private var failed = false
    @State private var showCode = false
    @State private var viewing = false
    @State private var width: CGFloat = 0
    /// DEBUG: why the render failed (`MermaidRenderer.failureNote`), on the error caption.
    @State private var failureNote = ""

    private static let shape = RoundedRectangle(cornerRadius: 12)
    private static let inset: CGFloat = 10

    private var isSVG: Bool { kind == "svg" }
    /// Accessibility identifiers: `chat-mermaid…` or `chat-svg…`.
    private var tag: String { isSVG ? "chat-svg" : "chat-mermaid" }

    /// The cleaned SVG, parsed once per source (`ChatSVG`); nil for mermaid, or when the SVG
    /// does not parse.
    private var svg: SVGDiagram.Sanitized? { isSVG ? ChatSVG.sanitized(source) : nil }

    private var request: MermaidRenderer.Request? {
        let available = width - 2 * Self.inset
        guard available > 0 else { return nil }
        var drawing = MermaidRenderer.Request.Drawing.mermaid
        if isSVG {
            guard let svg else { return nil }
            drawing = .svg(svg)
        }
        return MermaidRenderer.Request(drawing: drawing, source: source,
                                       widthBucket: MermaidDiagram.widthBucket(Double(available)),
                                       textScale: textScale, displayScale: displayScale)
    }

    /// The render for the current width if it is cached (so a row coming back on screen is
    /// drawn at its final height at once), else the last one this block had.
    private var shown: MermaidRenderer.Rendered? {
        request.flatMap { MermaidRenderer.shared.cached($0) } ?? rendered
    }

    var body: some View {
        Group {
            if (failed || (isSVG && svg == nil)) && shown == nil {
                fallback
            } else {
                card
            }
        }
        // Exactly the width the row is given (`minWidth: 0`), whatever the image inside, so
        // `width` is the column's and never the block's own. Measured from the block, an image
        // fitted to a wider column (before a turn to portrait, a fold to the cover screen or a
        // narrower split) held the block at that width: the width it reported never changed,
        // so the image never refitted, and the too-wide row widened the transcript's stack,
        // which the column centres, cutting every row off on the left (owner, 2026-11-11).
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: request) {
            guard let request else { return }
            if let hit = MermaidRenderer.shared.cached(request) {
                rendered = hit
                return
            }
            // A failure that is not the diagram's own (a page that timed out or broke) is
            // asked again, on the fresh page the renderer replaced it with
            // (`MermaidRenderer.attempts`); only then, or for the diagram's own, its code.
            for attempt in 1...MermaidRenderer.attempts {
                do {
                    rendered = try await MermaidRenderer.shared.render(request)
                    failed = false
                    return
                } catch {
                    if Task.isCancelled { return }
                    guard attempt < MermaidRenderer.attempts, MermaidRenderer.shared.mayRetry(request) else {
                        #if DEBUG
                        failureNote = MermaidRenderer.shared.failureNote(request) + " (attempt \(attempt))"
                        #endif
                        failed = true
                        return
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $viewing) { viewer }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(tag)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showCode {
                code
            } else {
                diagram
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Self.inset)
                    .padding(.bottom, Self.inset)
            }
        }
        .background(Palette.surface, in: Self.shape)
        .overlay(Self.shape.strokeBorder(Palette.hairlineQuiet, lineWidth: 1))
    }

    private var header: some View {
        let copied = receipt.text == source
        return HStack(spacing: 14) {
            Text(isSVG ? "SVG" : "Mermaid")
                .font(Typography.app(11.5))
                .foregroundStyle(Palette.textDim)
            Spacer(minLength: 0)
            Button { receipt.record(source) } label: {
                Text(copied ? "Copied" : "Copy source")
                    .font(Typography.app(12, .semibold))
                    .foregroundStyle(copied ? Palette.done : Palette.text)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("\(tag)-copy")
            Button { showCode.toggle() } label: {
                Text(showCode ? (isSVG ? "Show image" : "Show diagram") : "Show code")
                    .font(Typography.app(12, .semibold))
                    .foregroundStyle(Palette.text)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("\(tag)-toggle")
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, 7)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var diagram: some View {
        if let shown {
            let size = fitted(shown.image.size)
            Button { viewing = true } label: {
                Image(uiImage: shown.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSVG ? SVGDiagram.accessibilityLabel(source) : MermaidDiagram.accessibilityLabel(source))
            .accessibilityValue(Self.drawnProbe(shown))
            .accessibilityHint(isSVG ? "Opens the image full screen" : "Opens the diagram full screen")
            .accessibilityIdentifier("\(tag)-image")
        } else {
            ProgressView()
                .tint(Palette.textDim)
                .frame(maxWidth: .infinity)
                .frame(height: max(120, (width - 2 * Self.inset) * 0.5))
                .accessibilityLabel(isSVG ? "Rendering image" : "Rendering diagram")
                .accessibilityIdentifier("\(tag)-placeholder")
        }
    }

    /// The image's size in the column (`MermaidDiagram.fitted`): the render was already drawn
    /// to fit, so this only shrinks it while a new width's render is on its way.
    private func fitted(_ natural: CGSize) -> CGSize {
        let fit = MermaidDiagram.fitted(width: natural.width, height: natural.height,
                                        maxWidth: max(1, width - 2 * Self.inset))
        return CGSize(width: fit.width, height: fit.height)
    }

    /// UI tests read this (`MermaidRenderer.Rendered.probe`): drawn or blank, the raster's
    /// scale, fresh or from disk. Empty in release.
    private static func drawnProbe(_ rendered: MermaidRenderer.Rendered) -> String {
        #if DEBUG
        return rendered.probe
        #else
        return ""
        #endif
    }

    private var code: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(source)
                .font(Typography.machine(13 * textScale))
                .foregroundStyle(Palette.text)
                .lineSpacing(3)
                .fixedSize()
                .padding(.horizontal, 12).padding(.bottom, 10)
        }
    }

    /// It cannot be drawn: the code block, as before diagrams existed, and why.
    private var fallback: some View {
        VStack(alignment: .leading, spacing: 4) {
            GramCodeBlock(code: source, language: kind, textScale: textScale, syntax: .current)
            Text(isSVG ? "SVG couldn't render" : "Diagram couldn't render")
                .font(Typography.app(12 * textScale))
                .foregroundStyle(Palette.textFaint)
                .accessibilityIdentifier("\(tag)-error")
                .accessibilityValue(failureNote)
        }
    }

    private var viewer: some View {
        NavigationStack {
            HtmlWebView(html: MermaidDiagram.viewerDocument(svg: shown?.svg ?? "",
                                                            background: MermaidRenderer.hex(Palette.ground)))
                .ignoresSafeArea(edges: .bottom)
                .accessibilityIdentifier("\(tag)-viewer")
                .navigationTitle(isSVG ? "SVG" : "Diagram")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { viewing = false }
                            .accessibilityIdentifier("\(tag)-viewer-done")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button(receipt.text == source ? "Copied" : "Copy source") { receipt.record(source) }
                    }
                }
        }
    }
}

/// Each ```svg block's cleaned document, parsed once per source: a row's body runs on every
/// redraw (typing, scrolling), and the parse must not run with it.
@MainActor
enum ChatSVG {
    private final class Entry {
        let value: SVGDiagram.Sanitized?
        init(_ value: SVGDiagram.Sanitized?) { self.value = value }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 64
        return cache
    }()

    static func sanitized(_ source: String) -> SVGDiagram.Sanitized? {
        if let hit = cache.object(forKey: source as NSString) { return hit.value }
        let value = SVGDiagram.sanitize(source, variables: MermaidRenderer.svgVariables)
        cache.setObject(Entry(value), forKey: source as NSString)
        return value
    }
}
