import XCTest
@testable import HerdrKit

final class MermaidDiagramTests: XCTestCase {

    func testWidthBucketRoundsDownToAStepAndNeverBelowOne() {
        XCTAssertEqual(MermaidDiagram.widthBucket(358), 320)
        XCTAssertEqual(MermaidDiagram.widthBucket(360), 360)
        XCTAssertEqual(MermaidDiagram.widthBucket(719.5), 680)
        XCTAssertEqual(MermaidDiagram.widthBucket(12), 40)
        XCTAssertEqual(MermaidDiagram.widthBucket(0), 40)
        XCTAssertEqual(MermaidDiagram.widthBucket(.nan), 40)
    }

    func testFittedKeepsAspectWithinTheColumnAndCapsTallDiagrams() {
        // Smaller than the column: drawn at its own size.
        XCTAssertTrue(MermaidDiagram.fitted(width: 200, height: 100, maxWidth: 320) == (200, 100))
        // Wider than the column: shrunk to the column width.
        XCTAssertTrue(MermaidDiagram.fitted(width: 640, height: 320, maxWidth: 320) == (320, 160))
        // Taller than 1.2 columns: capped at 1.2 columns high, narrower to keep its aspect.
        let tall = MermaidDiagram.fitted(width: 300, height: 3000, maxWidth: 320)
        XCTAssertEqual(tall.height, 384, accuracy: 0.001)
        XCTAssertEqual(tall.width, 38.4, accuracy: 0.001)
        XCTAssertTrue(MermaidDiagram.fitted(width: 0, height: 10, maxWidth: 320) == (0, 0))
    }

    /// The image cache must never hand back a render made for another diagram, theme or width,
    /// and must hit for the same three.
    func testCacheKeyCoversSourceThemeAndWidth() {
        let key = MermaidDiagram.cacheKey(source: "graph TD\nA-->B", theme: "dark", widthBucket: 320)
        XCTAssertEqual(key, MermaidDiagram.cacheKey(source: "graph TD\nA-->B", theme: "dark", widthBucket: 320))
        XCTAssertEqual(key.count, 64)
        XCTAssertTrue(key.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertNotEqual(key, MermaidDiagram.cacheKey(source: "graph TD\nA-->C", theme: "dark", widthBucket: 320))
        XCTAssertNotEqual(key, MermaidDiagram.cacheKey(source: "graph TD\nA-->B", theme: "dark@1.2", widthBucket: 320))
        XCTAssertNotEqual(key, MermaidDiagram.cacheKey(source: "graph TD\nA-->B", theme: "dark", widthBucket: 360))
    }

    func testAccessibilityLabelNamesTheFirstLine() {
        XCTAssertEqual(MermaidDiagram.accessibilityLabel("\n  sequenceDiagram  \n  A->>B: hi"),
                       "Mermaid diagram, sequenceDiagram")
        XCTAssertEqual(MermaidDiagram.accessibilityLabel(" \n"), "Mermaid diagram")
    }

    func testViewerDocumentIsInertAndKeepsTheDrawing() {
        let svg = #"<svg viewBox="0 0 10 10"><script>alert(1)</script><SCRIPT type="x">x</SCRIPT ><g><text>Node</text></g></svg>"#
        let doc = MermaidDiagram.viewerDocument(svg: svg, background: "#13162A")
        XCTAssertFalse(doc.lowercased().contains("<script"))
        XCTAssertFalse(doc.contains("alert(1)"))
        XCTAssertTrue(doc.contains(#"<svg viewBox="0 0 10 10"><g><text>Node</text></g></svg>"#))
        XCTAssertTrue(doc.contains("default-src 'none'"))
        XCTAssertTrue(doc.contains("background: #13162A"))
    }

    /// The disk cache's round trip: whatever scale the PNG was rasterised at, it reloads at
    /// the size it was shown at (a 3× raster of a 320 pt diagram is 960 px and reloads at
    /// scale 3, so 320 pt again; read at the screen's scale alone, a 1× raster would have
    /// come back at a third of its size).
    func testStoredRenderReloadsAtTheSizeItWasShownAt() throws {
        let stored = MermaidDiagram.StoredRender(svg: "<svg/>", width: 320, height: 180)
        let decoded = try JSONDecoder().decode(MermaidDiagram.StoredRender.self,
                                               from: JSONEncoder().encode(stored))
        XCTAssertEqual(decoded, stored)
        for pixels in [320, 640, 960] {
            let scale = try XCTUnwrap(decoded.scale(pixelWidth: pixels))
            XCTAssertEqual(Double(pixels) / scale, 320, accuracy: 0.0001)
        }
        XCTAssertEqual(decoded.scale(pixelWidth: 960), 3)
        XCTAssertNil(decoded.scale(pixelWidth: 0), "An empty PNG is not a render")
        XCTAssertNil(decoded.scale(pixelWidth: 100_000), "A PNG that does not belong to this size is not reused")
        XCTAssertNil(MermaidDiagram.StoredRender(svg: "", width: 0, height: 0).scale(pixelWidth: 960))
    }

    /// Only the diagram's own failures keep it on its code for the session; a broken page, a
    /// timeout before mermaid had the diagram, or a timeout of a cold page's first draw leaves
    /// it free to try again.
    func testOnlyTheDiagramsOwnFailuresAreRemembered() {
        for firstDraw in [false, true] {
            XCTAssertTrue(MermaidDiagram.failureIsTheDiagrams(.diagram, phase: .drawing, firstDraw: firstDraw))
            XCTAssertFalse(MermaidDiagram.failureIsTheDiagrams(.timedOut, phase: .settingUp, firstDraw: firstDraw))
            XCTAssertFalse(MermaidDiagram.failureIsTheDiagrams(.page, phase: .drawing, firstDraw: firstDraw))
            XCTAssertFalse(MermaidDiagram.failureIsTheDiagrams(.page, phase: .settingUp, firstDraw: firstDraw))
        }
        XCTAssertTrue(MermaidDiagram.failureIsTheDiagrams(.timedOut, phase: .drawing, firstDraw: false),
                      "a warm page ran out of time on this diagram")
        XCTAssertFalse(MermaidDiagram.failureIsTheDiagrams(.timedOut, phase: .drawing, firstDraw: true),
                       "a cold page's first draw ran out of time: run 42917457759's valid fixture diagram")
    }
}

final class MermaidPageSlotTests: XCTestCase {
    private final class Page {}

    /// A page build that a timed-out render started must never install itself after the
    /// renderer replaced the page, neither over nothing nor over the newer build's page.
    func testABuildStartedBeforeARecycleNeverInstalls() {
        var slot = MermaidPageSlot<Page>()
        let staleToken = slot.lease()
        XCTAssertTrue(slot.isCurrent(staleToken))

        slot.recycle()  // the render that started the build timed out
        XCTAssertFalse(slot.isCurrent(staleToken))

        let freshToken = slot.lease()
        let fresh = Page()
        XCTAssertTrue(slot.install(fresh, token: freshToken))
        XCTAssertFalse(slot.install(Page(), token: staleToken), "The stale build finishing late")
        XCTAssertTrue(slot.page === fresh)
    }

    func testRecycleDropsTheCurrentPageAndHandsItBack() {
        var slot = MermaidPageSlot<Page>()
        let page = Page()
        let token = slot.lease()
        XCTAssertTrue(slot.install(page, token: token))
        XCTAssertTrue(slot.recycle() === page)
        XCTAssertNil(slot.page)
        XCTAssertNil(slot.recycle())
    }
}
