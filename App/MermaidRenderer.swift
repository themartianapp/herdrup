import HerdrKit
import SwiftUI
import UIKit
import WebKit

/// Draws the Chat view's ```mermaid blocks (#523 item 1) with the bundled mermaid.min.js, in
/// ONE offscreen `WKWebView` shared by every diagram, and hands back a cached image.
///
/// Why images and one page rather than a live web view per diagram: each `WKWebView` is a
/// WebContent process, and live views report their height late, re-laying rows out under
/// the chat's tail-follow and older-page anchoring. An image has its size up front.
///
/// The page is first-party (the bundled library and `mermaid.html`), so it is NOT tied to the
/// reader's "JavaScript in HTML previews" switch, which is about received documents; guests
/// see diagrams too. The diagram SOURCE is untrusted (agent output), and it is contained by:
///   * mermaid's `securityLevel: 'strict'` (labels are text, the SVG is DOMPurify-sanitised,
///     click handlers are off);
///   * the page CSP (`mermaid.html`): no page script at all, so even an inline handler in
///     the SVG cannot run; mermaid and each render are injected by the app, which CSP
///     does not govern;
///   * `WebViewPolicy`'s network-block content rule list, FAIL CLOSED: no rule list, no page,
///     and the diagram falls back to its code;
///   * navigation locked after the first load, and a non-persistent data store.
///
/// Renders run one at a time (one page, one `#out`), each within a time limit: a diagram
/// that runs out of time falls back to its code, and the page is replaced so the stuck script
/// cannot hold up the next one. Results are cached in memory and on disk under
/// `MermaidDiagram.cacheKey`, so scrolling back or reopening a chat never runs mermaid again.
@MainActor
final class MermaidRenderer: NSObject {
    static let shared = MermaidRenderer()

    /// One rendered diagram: the image (its `size` is the size it is shown at, in points; its
    /// `scale` is the screen's) and the SVG for the full-screen viewer.
    final class Rendered: @unchecked Sendable {
        let key: String
        let image: UIImage
        let svg: String
        /// Read back from the disk cache rather than drawn in this launch.
        let fromDisk: Bool

        init(key: String, image: UIImage, svg: String, fromDisk: Bool) {
            self.key = key
            self.image = image
            self.svg = svg
            self.fromDisk = fromDisk
        }

        #if DEBUG
        /// UI tests only: "drawn|blank <scale>x fresh|disk". `drawn` when the raster has a
        /// drawing in it rather than one flat colour (a blank snapshot, sampled at 32×32);
        /// the scale shows it was rasterised for the screen, and `disk` that it came back
        /// from the disk cache.
        lazy var probe: String = {
            let scale = image.scale.rounded() == image.scale ? "\(Int(image.scale))" : "\(image.scale)"
            return "\(looksDrawn ? "drawn" : "blank") \(scale)x \(fromDisk ? "disk" : "fresh")"
        }()

        private var looksDrawn: Bool {
            guard let cgImage = image.cgImage else { return false }
            let side = 32
            var pixels = [UInt8](repeating: 0, count: side * side * 4)
            let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                    bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.interpolationQuality = .medium
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
                return true
            }
            guard drew else { return false }
            return stride(from: 0, to: pixels.count, by: 4).contains { offset in
                (0..<3).contains { abs(Int(pixels[offset + $0]) - Int(pixels[$0])) > 24 }
            }
        }
        #endif
    }

    /// What to draw: the source, the column width it must fit, the chat text size (scales
    /// the drawing like the text around it) and the screen scale of the raster.
    struct Request: Equatable {
        /// A mermaid diagram, or an ```svg block already cleaned (`SVGDiagram.sanitize`),
        /// which the page draws as an `<img>`: an SVG image runs no script and loads nothing.
        enum Drawing: Equatable {
            case mermaid
            case svg(SVGDiagram.Sanitized)
        }

        var drawing: Drawing = .mermaid
        /// The block's source as written: the cache key, so an image is found by content.
        let source: String
        let widthBucket: Int
        let textScale: CGFloat
        let displayScale: CGFloat

        @MainActor var key: String {
            let theme = drawing == .mermaid ? MermaidRenderer.theme : MermaidRenderer.svgTheme
            return MermaidDiagram.cacheKey(source: source,
                                           theme: "\(theme)@\(textScale)x\(displayScale)",
                                           widthBucket: widthBucket)
        }
    }

    enum Failure: Error {
        /// The page could not be set up or broke under the render (no bundle file, no content
        /// rule list, WebContent crash, page replaced): not the diagram's fault.
        case unavailable
        /// Mermaid rejected the source, or it drew nothing.
        case invalid
    }

    private let memory: NSCache<NSString, Rendered> = {
        let cache = NSCache<NSString, Rendered>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    /// The ready page. Replacing it invalidates any page still being built for it.
    private var slot = MermaidPageSlot<WKWebView>()
    /// The page being built, not yet in `slot`; only it may navigate, once.
    private var building: WKWebView?
    private var didStartInitialLoad = false
    private var loaded: CheckedContinuation<Void, Error>?
    /// Renders one at a time, each with a time limit.
    private let queue = SerialDeadlineQueue()
    /// Diagrams that failed by their own fault this session (mermaid rejected them, or they
    /// ran out of time while mermaid had them): shown as code at once instead of retrying on
    /// every scroll. Not stored on disk, so the next launch tries again.
    private var failed = Set<String>()
    private var renders = 0
    /// The render job in progress, and how far it got. A job that timed out may still finish
    /// later; it must not touch the state of the job after it.
    private var job = 0
    private var phase: MermaidDiagram.RenderPhase = .settingUp
    /// The page's device scale, learned from each snapshot (pixels per point of
    /// `snapshotWidth`), so the next raster is asked for at the screen's scale directly.
    private var pageScale: CGFloat?

    /// Setting the page up loads the 3.6 MB library; it gets its own, longer limit, so a
    /// slow first load is never charged to a diagram.
    private static let pageTimeout: TimeInterval = 30
    /// How long one diagram may take to draw on a ready page. A diagram whose layout never
    /// ends (it is agent-written) must not leave every later diagram on its placeholder.
    private static let renderTimeout: TimeInterval = 8
    /// The FIRST draw on a fresh page gets longer: it pays mermaid's cold start (its layout
    /// code compiling, fonts loading), which on a busy device ran past `renderTimeout` and
    /// booked a valid diagram as broken for the whole session.
    private static let firstRenderTimeout: TimeInterval = 20
    /// Whether the current page has finished a draw; reset with the page (`recyclePage`).
    private var pageHasDrawn = false

    /// A render already in memory, for drawing it in the same frame a row appears (no
    /// placeholder flash, so the row's height is right from the start).
    func cached(_ request: Request) -> Rendered? {
        memory.object(forKey: request.key as NSString)
    }

    /// How many times a block asks for its diagram before it shows its code. A render that
    /// failed through no fault of the diagram's (its page timed out or broke) leaves the page
    /// replaced, and the next ask gets a fresh one: hosted CI showed a valid diagram as
    /// "Diagram couldn't render" for good after one slow page (run 42917457759, iPad, both
    /// attempts; also 42319983254, 41642629325, 41169998628), because the block never asked
    /// again.
    static let attempts = 2

    /// Whether a block whose render just failed should ask again: only when the failure was
    /// not the diagram's own (`MermaidDiagram.failureIsTheDiagrams`), which is booked for the
    /// session.
    func mayRetry(_ request: Request) -> Bool {
        !failed.contains(request.key)
    }

    #if DEBUG
    /// Why each key's last render failed, for UI tests (`ChatMermaidView`'s error caption
    /// carries it as its accessibility value): which step, and after how long.
    private var failureNotes: [String: String] = [:]
    func failureNote(_ request: Request) -> String { failureNotes[request.key] ?? "" }
    #endif
    private func note(_ key: String, _ text: String, since start: ContinuousClock.Instant) {
        #if DEBUG
        let elapsed = (ContinuousClock.now - start).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        failureNotes[key] = String(format: "%@ after %.1f s", text, seconds)
        #endif
    }

    func render(_ request: Request) async throws -> Rendered {
        let key = request.key
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if failed.contains(key) { throw Failure.invalid }
        if let stored = await Self.loadFromDisk(key: key) {
            remember(stored)
            return stored
        }
        let start = ContinuousClock.now
        if slot.page == nil {
            do {
                try await queue.run(timeout: Self.pageTimeout, { @MainActor () async throws -> Void in
                    _ = try await self.page()
                }, onTimeout: { @MainActor () async in
                    self.recyclePage()
                })
            } catch {
                note(key, error is DeadlineExceeded ? "page setup timed out (\(Int(Self.pageTimeout)) s)"
                                                    : "page setup failed", since: start)
                throw error
            }
        }
        let firstDraw = !pageHasDrawn
        let timeout = firstDraw ? Self.firstRenderTimeout : Self.renderTimeout
        return try await queue.run(timeout: timeout, { @MainActor () async throws -> Rendered in
            if let hit = self.memory.object(forKey: key as NSString) { return hit }
            if self.failed.contains(key) { throw Failure.invalid }
            self.job += 1
            let job = self.job
            self.phase = .settingUp
            do {
                let rendered = try await self.draw(request, key: key, job: job)
                self.pageHasDrawn = true
                self.remember(rendered)
                Self.saveToDisk(rendered)
                return rendered
            } catch {
                if job == self.job {
                    self.note(key, (error as? Failure) == .invalid ? "mermaid rejected it" : "the page broke while \(self.phase)",
                              since: start)
                    self.settle(key, failure: (error as? Failure) == .invalid ? .diagram : .page, firstDraw: firstDraw)
                }
                throw error
            }
        }, onTimeout: { @MainActor () async in
            self.note(key, "timed out (\(Int(timeout)) s) while \(self.phase)\(firstDraw ? ", first draw" : "")", since: start)
            self.settle(key, failure: .timedOut, firstDraw: firstDraw)
        })
    }

    /// Books a failed render: only a failure that is the diagram's own is remembered for the
    /// session (`MermaidDiagram.failureIsTheDiagrams`). Anything but a clean mermaid error
    /// replaces the page, so a stuck script or a broken page cannot hold up the next render.
    private func settle(_ key: String, failure: MermaidDiagram.RenderFailure, firstDraw: Bool) {
        if MermaidDiagram.failureIsTheDiagrams(failure, phase: phase, firstDraw: firstDraw) { failed.insert(key) }
        if failure != .diagram { recyclePage() }
    }

    private func remember(_ rendered: Rendered) {
        let pixels = rendered.image.size.width * rendered.image.scale * rendered.image.size.height * rendered.image.scale
        memory.setObject(rendered, forKey: rendered.key as NSString, cost: Int(pixels) * 4)
    }

    /// Drops the page and any page being built, and invalidates every build in flight
    /// (`MermaidPageSlot`), so a build a timed-out job started can never install itself.
    /// Nothing here holds a web view across a pending call into it (calls look the page up
    /// by identity, `live`), so dropping it closes the page and its WebContent process.
    private func recyclePage() {
        pageHasDrawn = false
        for web in [slot.recycle(), building].compactMap({ $0 }) {
            web.navigationDelegate = nil
            web.stopLoading()
        }
        building = nil
        loaded?.resume(throwing: Failure.unavailable)
        loaded = nil
    }

    /// The page with this identity if it is still the ready page or the one being built.
    private func live(_ page: ObjectIdentifier) throws -> WKWebView {
        if let ready = slot.page, ObjectIdentifier(ready) == page { return ready }
        if let building, ObjectIdentifier(building) == page { return building }
        throw Failure.unavailable
    }

    // MARK: - Drawing

    private func draw(_ request: Request, key: String, job: Int) async throws -> Rendered {
        let page = ObjectIdentifier(try await self.page())
        if job == self.job { phase = .drawing }
        renders += 1
        let result: Any
        let function: String
        var arguments: [String: Any] = ["textScale": Double(request.textScale)]
        switch request.drawing {
        case .mermaid:
            function = Self.renderFunction
            arguments["id"] = "herdr-mermaid-\(renders)"
            arguments["source"] = request.source
        case .svg(let svg):
            function = Self.imageFunction
            arguments["data"] = Data(svg.svg.utf8).base64EncodedString()
            arguments["width"] = svg.width
            arguments["height"] = svg.height
        }
        do {
            result = try await javaScript(function, arguments: arguments, on: page)
        } catch let error as NSError where error.domain == WKError.errorDomain
                    && error.code == WKError.Code.javaScriptExceptionOccurred.rawValue {
            // mermaid.render threw: the source does not parse or lay out.
            throw Failure.invalid
        } catch {
            throw Failure.unavailable
        }
        let source: String?
        if case .svg(let svg) = request.drawing { source = svg.svg } else { source = nil }
        guard let drawn = result as? [String: Any],
              let svg = source ?? drawn["svg"] as? String,
              let natural = (drawn["width"] as? NSNumber)?.doubleValue,
              let naturalHeight = (drawn["height"] as? NSNumber)?.doubleValue else { throw Failure.invalid }
        // Rasterise at the size the chat shows it (a tall diagram capped), not its full
        // length: the image stays small; the viewer zooms the SVG.
        let fit = MermaidDiagram.fitted(width: natural, height: naturalHeight,
                                        maxWidth: Double(request.widthBucket))
        guard fit.width >= 1, fit.height >= 1 else { throw Failure.invalid }
        let size = CGSize(width: ceil(fit.width), height: ceil(fit.height))
        do {
            _ = try await javaScript(
                "const el = document.getElementById('out').firstElementChild; el.style.width = width + 'px'; el.style.height = height + 'px'; return true;",
                arguments: ["width": Double(size.width), "height": Double(size.height)],
                on: page)
        } catch {
            throw Failure.unavailable
        }
        let cgImage = try await raster(size, scale: request.displayScale, on: page)
        // `size` points, whatever the raster's pixel count: the image always shows at the
        // size it was fitted to.
        let image = UIImage(cgImage: cgImage, scale: CGFloat(cgImage.width) / size.width, orientation: .up)
        return Rendered(key: key, image: image, svg: svg, fromDisk: false)
    }

    /// The top-left `size` points of the page as an image `size.width × scale` pixels wide.
    /// `snapshotWidth` is in points and WebKit multiplies it by the PAGE's device scale; an
    /// offscreen page's scale is normally the screen's, but if a snapshot shows otherwise
    /// the width is corrected (and remembered) so the raster is sharp on this screen.
    private func raster(_ size: CGSize, scale: CGFloat, on page: ObjectIdentifier) async throws -> CGImage {
        let target = Int((size.width * scale).rounded())
        var width = size.width * scale / (pageScale ?? scale)
        var image = try await snapshot(size, width: width, on: page)
        if abs(image.width - target) > 1 {
            pageScale = CGFloat(image.width) / width
            width = size.width * scale / (pageScale ?? scale)
            image = try await snapshot(size, width: width, on: page)
        } else {
            pageScale = CGFloat(image.width) / width
        }
        return image
    }

    private func snapshot(_ size: CGSize, width: CGFloat, on page: ObjectIdentifier) async throws -> CGImage {
        do {
            // Scoped so the page is not held while the snapshot is pending.
            let web = try live(page)
            // The page must cover the drawing for the snapshot to include all of it.
            if web.frame.width < size.width || web.frame.height < size.height {
                web.frame = CGRect(x: 0, y: 0, width: max(web.frame.width, size.width),
                                   height: max(web.frame.height, size.height))
            }
        }
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: size)
        config.snapshotWidth = NSNumber(value: Double(width))
        // The page is never in a window, so there are no screen updates to wait for:
        // WebKit paints the page straight into the snapshot (its software path).
        config.afterScreenUpdates = false
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try live(page).takeSnapshot(with: config) { image, _ in
                    if let cgImage = image?.cgImage, cgImage.width > 0 {
                        continuation.resume(returning: cgImage)
                    } else {
                        continuation.resume(throwing: Failure.unavailable)
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Calls `body` as an async function in the page. Completion-handler based on purpose:
    /// while the call is pending nothing holds the web view, so a replaced page can close.
    private func javaScript(_ body: String, arguments: [String: Any], on page: ObjectIdentifier) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try live(page).callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                    continuation.resume(with: result.map { $0 as Any })
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Evaluates `program` (a script, not a function body) in the page.
    private func evaluate(_ program: String, on page: ObjectIdentifier) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try live(page).evaluateJavaScript(program) { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// The ready page, set up on first use: bundled html, network block, mermaid, theme. A
    /// build that `recyclePage` invalidated while it was in flight throws and never installs.
    private func page() async throws -> WKWebView {
        if let ready = slot.page { return ready }
        let token = slot.lease()
        guard let htmlURL = Bundle.main.url(forResource: "mermaid", withExtension: "html"),
              let scriptURL = Bundle.main.url(forResource: "mermaid.min", withExtension: "js"),
              let html = try? String(contentsOf: htmlURL, encoding: .utf8),
              let script = try? String(contentsOf: scriptURL, encoding: .utf8),
              let store = WKContentRuleListStore.default() else { throw Failure.unavailable }
        // The network block is a security boundary: without it there is no page (fail closed).
        let rules: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(
                forIdentifier: "herdr.block-network",
                encodedContentRuleList: WebViewPolicy.blockNetworkRuleListJSON
            ) { list, _ in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: Failure.unavailable)
                }
            }
        }
        guard slot.isCurrent(token) else { throw Failure.unavailable }
        let page = startBuilding(rules: rules)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                let web = try live(page)
                loaded = continuation
                didStartInitialLoad = false
                web.loadHTMLString(html, baseURL: nil)
            } catch {
                continuation.resume(throwing: error)
            }
        }
        guard slot.isCurrent(token) else { throw Failure.unavailable }
        // A program, not a function body: the bundle declares its globals with `var`. The
        // trailing `true` keeps the completion value serialisable (the last statement
        // assigns the mermaid object).
        try await evaluate(script + "\n;true", on: page)
        _ = try await javaScript(
            "document.body.style.background = background; mermaid.initialize(config); return true;",
            arguments: ["config": Self.configuration, "background": Self.hex(Palette.surface)],
            on: page)
        guard slot.isCurrent(token), let web = building, ObjectIdentifier(web) == page else {
            throw Failure.unavailable
        }
        building = nil
        slot.install(web, token: token)
        return web
    }

    /// A new, empty page, held only as `building` (dropped by `recyclePage`).
    private func startBuilding(rules: WKContentRuleList) -> ObjectIdentifier {
        if let old = building {
            old.navigationDelegate = nil
            old.stopLoading()
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(rules)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1024), configuration: config)
        web.isOpaque = true
        web.backgroundColor = UIColor(Palette.surface)
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.navigationDelegate = self
        building = web
        return ObjectIdentifier(web)
    }

    /// Renders `source` into `#out` and returns the SVG and its natural size times the chat
    /// text scale (`draw` then fits it to the column).
    private static let renderFunction = """
    const out = document.getElementById('out');
    out.replaceChildren();
    try {
      const { svg } = await mermaid.render(id, source);
      out.innerHTML = svg;
      const el = out.querySelector('svg');
      if (!el) return null;
      const box = el.viewBox && el.viewBox.baseVal;
      const rect = el.getBoundingClientRect();
      const w = box && box.width > 0 ? box.width : rect.width;
      const h = box && box.height > 0 ? box.height : rect.height;
      if (!(w > 0 && h > 0)) return null;
      el.removeAttribute('width');
      el.removeAttribute('height');
      el.style.maxWidth = 'none';
      return { svg, width: w * textScale, height: h * textScale };
    } finally {
      const stray = document.getElementById('d' + id);
      if (stray) stray.remove();
    }
    """

    /// Draws a cleaned SVG (`SVGDiagram.sanitize`) into `#out` as an `<img>`, not inline: an
    /// SVG loaded as an image runs no script and fetches nothing, whatever it contains. Its
    /// size comes from the sanitizer (the root's width/height or viewBox) times the chat text
    /// scale. Null when WebKit cannot decode it, which shows the block as code.
    private static let imageFunction = """
    const out = document.getElementById('out');
    out.replaceChildren();
    const img = new Image();
    img.style.display = 'block';
    img.src = 'data:image/svg+xml;base64,' + data;
    try { await img.decode(); } catch (e) { return null; }
    if (!(img.naturalWidth > 0 && img.naturalHeight > 0)) return null;
    out.appendChild(img);
    return { width: width * textScale, height: height * textScale };
    """

    /// Mermaid's dark `base` theme in the app's palette (`Palette`), labels as SVG text
    /// (`htmlLabels: false`, no foreignObject) and nothing that runs on load.
    private static var configuration: [String: Any] {
        [
            "startOnLoad": false,
            "securityLevel": "strict",
            "suppressErrorRendering": true,
            "htmlLabels": false,
            "flowchart": ["htmlLabels": false],
            "theme": "base",
            "fontFamily": "-apple-system, 'Helvetica Neue', sans-serif",
            "themeVariables": themeVariables,
        ]
    }

    private static var themeVariables: [String: Any] {
        let surface = hex(Palette.surface), raised = hex(Palette.surfaceRaised)
        let ground = hex(Palette.ground), text = hex(Palette.text), dim = hex(Palette.textDim)
        let hairline = hex(Palette.hairline), brand = hex(Palette.brand), faint = hex(Palette.textFaint)
        return [
            "darkMode": true,
            "fontSize": "14px",
            "background": surface,
            "primaryColor": raised,
            "primaryTextColor": text,
            "primaryBorderColor": brand,
            "secondaryColor": ground,
            "secondaryTextColor": text,
            "secondaryBorderColor": hairline,
            "tertiaryColor": ground,
            "tertiaryTextColor": text,
            "tertiaryBorderColor": hairline,
            "mainBkg": raised,
            "nodeBorder": brand,
            "nodeTextColor": text,
            "textColor": text,
            "titleColor": text,
            "lineColor": dim,
            "clusterBkg": ground,
            "clusterBorder": hairline,
            "edgeLabelBackground": surface,
            "noteBkgColor": hairline,
            "noteTextColor": text,
            "noteBorderColor": faint,
            "actorBkg": raised,
            "actorBorder": brand,
            "actorTextColor": text,
            "actorLineColor": dim,
            "signalColor": dim,
            "signalTextColor": text,
            "labelBoxBkgColor": raised,
            "labelBoxBorderColor": hairline,
            "labelTextColor": text,
            "loopTextColor": text,
        ]
    }

    /// The bundled mermaid.min.js (App/Resources/Mermaid/README.md). Part of every cache key,
    /// so a new library version draws afresh instead of showing images the old one made.
    private static let libraryVersion = "11.17.2"

    /// Part of every cache key: a palette or library change re-renders instead of reusing
    /// old images.
    private static let theme: String = {
        let values = themeVariables.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return "mermaid-\(libraryVersion);base;" + values.joined(separator: ";")
    }()

    /// The CSS variables an ```svg block may use for colour (`var(--fg)`, `var(--muted)`,
    /// `var(--border)`…), as the page an agent drew it for would define them: the app's
    /// palette, so a block reads on the chat's ground. `--bg` is the card the image sits on.
    static let svgVariables: [String: String] = {
        let text = hex(Palette.text), dim = hex(Palette.textDim), faint = hex(Palette.textFaint)
        return [
            "fg": text, "text": text, "foreground": text,
            "muted": dim, "dim": dim, "secondary": dim,
            "faint": faint, "subtle": faint, "border": faint, "line": faint,
            "bg": hex(Palette.surface), "background": hex(Palette.surface),
            "surface": hex(Palette.surfaceRaised), "panel": hex(Palette.surfaceRaised),
            "accent": hex(Palette.brand),
            "ok": hex(Palette.done), "green": hex(Palette.done),
            "warn": hex(Palette.waiting), "amber": hex(Palette.waiting),
            "error": hex(Palette.died), "red": hex(Palette.died),
            "info": hex(Palette.working), "blue": hex(Palette.working),
        ]
    }()

    /// Part of every SVG cache key: a palette change, or a change to how SVGs are cleaned
    /// (`svg-N`), draws them afresh.
    static let svgTheme: String = {
        "svg-1;" + svgVariables.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
    }()

    static func hex(_ color: Color) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let byte = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    // MARK: - Disk cache

    /// `<key>.png` holds the raster; `<key>.json` the SVG and the size it is shown at
    /// (`MermaidDiagram.StoredRender`), so it reloads at that size whatever the PNG's scale.
    private nonisolated static var directory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Mermaid", isDirectory: true)
    }

    private static func loadFromDisk(key: String) async -> Rendered? {
        let stored = await Task.detached(priority: .userInitiated) { () -> (Data, MermaidDiagram.StoredRender)? in
            guard let directory = Self.directory,
                  let png = try? Data(contentsOf: directory.appendingPathComponent("\(key).png")),
                  let json = try? Data(contentsOf: directory.appendingPathComponent("\(key).json")),
                  let meta = try? JSONDecoder().decode(MermaidDiagram.StoredRender.self, from: json)
            else { return nil }
            return (png, meta)
        }.value
        guard let stored, let cgImage = UIImage(data: stored.0)?.cgImage,
              let scale = stored.1.scale(pixelWidth: cgImage.width) else { return nil }
        let image = UIImage(cgImage: cgImage, scale: CGFloat(scale), orientation: .up)
        return Rendered(key: key, image: image, svg: stored.1.svg, fromDisk: true)
    }

    private static func saveToDisk(_ rendered: Rendered) {
        guard let png = rendered.image.pngData(),
              let json = try? JSONEncoder().encode(MermaidDiagram.StoredRender(
                svg: rendered.svg,
                width: Double(rendered.image.size.width),
                height: Double(rendered.image.size.height))) else { return }
        let key = rendered.key
        Task.detached(priority: .utility) {
            guard let directory = Self.directory else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Metadata first: a PNG is only read back together with it.
            try? json.write(to: directory.appendingPathComponent("\(key).json"), options: .atomic)
            try? png.write(to: directory.appendingPathComponent("\(key).png"), options: .atomic)
        }
    }
}

extension MermaidRenderer: WKNavigationDelegate {
    /// Allow exactly the first navigation of the page being built (our `loadHTMLString`) and
    /// cancel every other, as `HtmlWebView` does: nothing a diagram draws can take the page
    /// anywhere.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if webView === building, !didStartInitialLoad {
            didStartInitialLoad = true
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === building else { return }
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === building else { return }
        loaded?.resume(throwing: Failure.unavailable)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === building else { return }
        loaded?.resume(throwing: Failure.unavailable)
        loaded = nil
    }

    /// The WebContent process died (memory pressure): drop the page; the next render builds
    /// a fresh one. Not the diagram's fault, so nothing is marked failed.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === slot.page || webView === building { recyclePage() }
    }
}
