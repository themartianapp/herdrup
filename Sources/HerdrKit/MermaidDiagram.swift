import Foundation
import Crypto

/// The platform-free parts of the Chat view's mermaid diagrams (#523 item 1): how a render
/// is keyed in the image cache, what VoiceOver reads, and the document the full-screen
/// viewer shows. The rendering itself (an offscreen WKWebView) lives in the app.
public enum MermaidDiagram {
    /// Renders are cached per column-width step, so a column that moves by a few points
    /// (rotation, a sidebar, a Mac window resize) reuses its images instead of re-rendering.
    public static let widthStep = 40

    /// The render width for a column `width` points wide: rounded DOWN to a `widthStep`, so
    /// the image never overflows the column, and never under one step.
    public static func widthBucket(_ width: Double) -> Int {
        guard width.isFinite, width > 0 else { return widthStep }
        return max(widthStep, Int(width) / widthStep * widthStep)
    }

    /// A tall diagram is shown at most this many column widths high; the full-screen viewer
    /// has the rest.
    public static let tallCap = 1.2

    /// The size a diagram drawn `width` × `height` is shown at in a column `maxWidth` wide:
    /// never wider than the column, never more than `tallCap` columns high, aspect kept.
    /// It is also the size it is rasterised at, so a long diagram never becomes a huge image.
    public static func fitted(width: Double, height: Double, maxWidth: Double) -> (width: Double, height: Double) {
        guard width > 0, height > 0, maxWidth > 0 else { return (0, 0) }
        var fit = (width: min(width, maxWidth), height: 0.0)
        fit.height = fit.width * height / width
        let cap = maxWidth * tallCap
        if fit.height > cap {
            fit = (width: cap * width / height, height: cap)
        }
        return fit
    }

    /// The cache key of one render: sha256 of the theme, the width bucket and the source,
    /// so a palette or text-size change, a new width or an edited diagram never reuse a
    /// stale image. Hex, safe as a file name.
    public static func cacheKey(source: String, theme: String, widthBucket: Int) -> String {
        let input = "\(theme)\n\(widthBucket)\n\(source)"
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// What VoiceOver reads for a rendered diagram: "Mermaid diagram" plus its first line
    /// (the diagram type and direction, e.g. `graph TD`), which is all an image can say.
    public static func accessibilityLabel(_ source: String) -> String {
        let first = source.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return first.map { "Mermaid diagram, \($0)" } ?? "Mermaid diagram"
    }

    /// The full-screen viewer's document: the rendered SVG, fitted to the screen width and
    /// pinch-zoomable, under a CSP that allows no script and no loads. The viewer also runs
    /// with JavaScript off and the network block (`HtmlWebView`), and mermaid already
    /// sanitised the SVG (`securityLevel: 'strict'`); any `<script>` element is dropped
    /// here too, so the document is inert on its own.
    public static func viewerDocument(svg: String, background: String) -> String {
        let inert = svg.replacingOccurrences(
            of: "<script\\b[\\s\\S]*?(</script\\s*>|$)",
            with: "",
            options: [.regularExpression, .caseInsensitive])
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=10, user-scalable=yes">
        <style>
        html, body { margin: 0; padding: 0; background: \(background); }
        body { padding: 16px; box-sizing: border-box; }
        svg { display: block; width: 100% !important; max-width: none !important; height: auto; }
        </style>
        </head>
        <body>\(inert)</body>
        </html>
        """
    }
}

extension MermaidDiagram {
    /// What the disk cache keeps beside a render's PNG: the SVG for the viewer and the size
    /// the image is shown at, in points. The PNG's own pixel size alone cannot say how big
    /// to draw it, because the raster's scale is the page's, not necessarily today's screen.
    public struct StoredRender: Codable, Equatable, Sendable {
        public let svg: String
        public let width: Double
        public let height: Double

        public init(svg: String, width: Double, height: Double) {
            self.svg = svg
            self.width = width
            self.height = height
        }

        /// The scale to load a PNG `pixelWidth` pixels wide at, so it draws `width` points
        /// wide again; nil when the pair cannot be right (an empty or mismatched file).
        public func scale(pixelWidth: Int) -> Double? {
            guard width > 0, pixelWidth > 0 else { return nil }
            let scale = Double(pixelWidth) / width
            return scale >= 0.5 && scale <= 8 ? scale : nil
        }
    }

    /// Where a render stopped when it failed.
    public enum RenderPhase: Sendable {
        /// Still building the page (loading mermaid, the network block, the theme).
        case settingUp
        /// The page was ready and mermaid had this diagram.
        case drawing
    }

    /// How a render failed.
    public enum RenderFailure: Sendable {
        /// Mermaid rejected the source or drew nothing.
        case diagram
        /// The page broke under it (WebContent crash, page replaced, setup failed).
        case page
        /// It ran out of time.
        case timedOut
    }

    /// Whether a failure is the diagram's own, so it is shown as code for the rest of the
    /// session instead of being tried again. A broken page, or a timeout before mermaid had
    /// the diagram, says nothing about the diagram: it gets another try on a fresh page. Nor
    /// does a timeout of a page's FIRST draw (`firstDraw`), which pays mermaid's cold start:
    /// on loaded hosted simulators that ran past its limit for the valid fixture diagram,
    /// which the session then showed as "Diagram couldn't render" for good (run 42917457759,
    /// iPad, both attempts; 42319983254, 41169998628). Only a timeout on a page that has
    /// already drawn, warm, is the diagram's.
    public static func failureIsTheDiagrams(_ failure: RenderFailure, phase: RenderPhase,
                                            firstDraw: Bool) -> Bool {
        switch failure {
        case .diagram: return true
        case .page: return false
        case .timedOut: return phase == .drawing && !firstDraw
        }
    }
}

/// The renderer's one page, apart from WebKit: which page is current, and whether a page
/// still being built may become it. Replacing the page (`recycle`) invalidates every build
/// in flight, so a build that a timed-out render started can never install itself later
/// over the page a newer render built.
public struct MermaidPageSlot<Page: AnyObject> {
    public private(set) var page: Page?
    private var generation = 0

    public init() {}

    /// The token a new build installs its page with.
    public func lease() -> Int { generation }

    /// Whether a build holding `token` is still wanted.
    public func isCurrent(_ token: Int) -> Bool { token == generation }

    /// Makes `page` the current page if its build is still wanted; false otherwise.
    @discardableResult
    public mutating func install(_ page: Page, token: Int) -> Bool {
        guard isCurrent(token) else { return false }
        self.page = page
        return true
    }

    /// Drops the current page and invalidates every build in flight; returns the old page.
    @discardableResult
    public mutating func recycle() -> Page? {
        generation &+= 1
        defer { page = nil }
        return page
    }
}
