import SwiftUI

/// Detects URLs in a plain string and returns an `AttributedString` with them as tappable link
/// runs, styled with a tint + underline. SwiftUI's `Text` does NOT auto-link a plain `String`, so
/// Gram message bodies run through this to make links clickable (a tap opens the URL via the
/// `openURL` environment). Bare URLs, `https://…`, and `www.…` are all detected by NSDataDetector.
///
/// Called from row bodies, which re-run on every page render, so the answer is cached by
/// (text, tint) and the detector is built once: a re-render costs a cache lookup, not a scan.
func linkified(_ text: String, tint: Color = Palette.brand) -> AttributedString {
    let key = LinkifiedCache.Key(text: text, tint: tint)
    if let hit = LinkifiedCache.shared.object(forKey: key) { return hit.value }
    let ns = NSMutableAttributedString(string: text)
    if let detector = LinkifiedCache.detector {
        let full = NSRange(location: 0, length: (text as NSString).length)
        detector.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let match, let url = match.url else { return }
            ns.addAttribute(.link, value: url, range: match.range)
        }
    }
    var attributed = AttributedString(ns)
    // Tint the detected link runs so they read as links; the `.link` attribute makes the tap open
    // the URL regardless. Non-URL text keeps whatever the surrounding Text sets.
    for run in attributed.runs where run.link != nil {
        attributed[run.range].foregroundColor = tint
    }
    LinkifiedCache.shared.setObject(LinkifiedCache.Box(attributed), forKey: key)
    return attributed
}

/// Auto-links bare URLs (`https://…`, `www.…`) inside an already-parsed inline Markdown
/// `AttributedString`, skipping spans that are already links or inline code.
func detectLinks(in attributed: inout AttributedString, tint: Color, underline: Bool = false) {
    guard let detector = LinkifiedCache.detector else { return }
    let plain = String(attributed.characters)
    let full = NSRange(location: 0, length: (plain as NSString).length)
    detector.enumerateMatches(in: plain, range: full) { match, _, _ in
        guard let match, let url = match.url,
              let swiftRange = Range(match.range, in: plain),
              let attrStart = AttributedString.Index(swiftRange.lowerBound, within: attributed),
              let attrEnd = AttributedString.Index(swiftRange.upperBound, within: attributed)
        else { return }
        let range = attrStart..<attrEnd
        let blocked = attributed[range].runs.contains { run in
            run.link != nil || (run.inlinePresentationIntent ?? []).contains(.code)
        }
        guard !blocked else { return }
        attributed[range].link = url
        attributed[range].foregroundColor = tint
        if underline { attributed[range].underlineStyle = .single }
    }
}

/// The shared link detector and the (text, tint) → linkified answer cache behind `linkified`.
private enum LinkifiedCache {
    /// Built once. NSDataDetector (an NSRegularExpression) is immutable and thread-safe.
    static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Bounded so a long scroll through history cannot grow it without limit; NSCache also
    /// drops entries under memory pressure. A miss only re-detects.
    static let shared: NSCache<Key, Box> = {
        let cache = NSCache<Key, Box>()
        cache.countLimit = 2000
        return cache
    }()

    final class Key: NSObject {
        let text: String
        let tint: Color
        init(text: String, tint: Color) {
            self.text = text
            self.tint = tint
        }
        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(text)
            hasher.combine(tint)
            return hasher.finalize()
        }
        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Key else { return false }
            return text == other.text && tint == other.tint
        }
    }

    final class Box {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }
}
