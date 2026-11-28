import Foundation

/// The block structure of an omp reply, for the Chat view to lay out natively: paragraphs,
/// headings, lists, fenced code, GitHub tables, quotes and rules. Inline styling (bold,
/// italic, inline code, links) stays in each block's text for the view to render; only the
/// block split — the part with real logic — lives here, where it is unit-tested on Linux.
public enum ChatMarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, String)
    /// Items keep their own inline markdown. `start` is the first number of an ordered list.
    case list(ordered: Bool, start: Int, items: [ChatMarkdownListItem])
    case code(language: String?, String)
    /// A CLOSED fence whose language is a diagram the app draws: `mermaid`, or `svg` (an
    /// ```svg fence, or an ```xml fence whose document is an `<svg>`).
    /// While the closing fence has not arrived (a reply still streaming) it stays `.code`,
    /// so a half-written diagram is never sent to the renderer.
    case diagram(kind: String, source: String)
    case table(header: [String], rows: [[String]])
    case quote(String)
    case rule
}

public struct ChatMarkdownListItem: Equatable, Sendable {
    public let text: String
    /// Nesting depth, 0 for a top-level item (two spaces or a tab per level).
    public let depth: Int
    /// `- [x]` / `- [ ]` task items.
    public let checked: Bool?
    /// Non-nil only when a nested item's marker kind differs from the enclosing list's `ordered`
    /// flag (e.g. a bullet nested under an ordered item).
    public let markerOrdered: Bool?
    /// Non-nil when a nested ordered sublist starts at an explicit ordinal other than 1.
    public let orderedStart: Int?

    public init(text: String, depth: Int = 0, checked: Bool? = nil, markerOrdered: Bool? = nil, orderedStart: Int? = nil) {
        self.text = text
        self.depth = depth
        self.checked = checked
        self.markerOrdered = markerOrdered
        self.orderedStart = orderedStart
    }
}

public enum ChatMarkdown {
    public static func blocks(_ markdown: String, parseFences: Bool = true) -> [ChatMarkdownBlock] {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [ChatMarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            if parseFences, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                let closed = i < lines.count
                i += 1
                let source = code.joined(separator: "\n")
                if closed, let kind = diagramKind(language, source: source) {
                    blocks.append(.diagram(kind: kind, source: source))
                } else {
                    blocks.append(.code(language: language.isEmpty ? nil : language, source))
                }
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            if let (level, text) = heading(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: level, text))
                i += 1
                continue
            }

            if let header = tableHeader(trimmed, separator: i + 1 < lines.count ? lines[i + 1] : nil) {
                flushParagraph()
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, hasPipe(row) else { break }
                    var cells = cells(row)
                    // Pad or cut to the header's width so the grid stays rectangular.
                    if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
                    rows.append(Array(cells.prefix(header.count)))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count {
                    let q = lines[i].trimmingCharacters(in: .whitespaces)
                    guard q.hasPrefix(">") else { break }
                    quoted.append(String(q.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            if let first = listItem(line) {
                flushParagraph()
                var items = [first.item]
                var seenOrderedDepths: Set<Int> = first.ordered ? [first.item.depth] : []
                var previousDepth = first.item.depth
                i += 1
                while i < lines.count {
                    let next = lines[i]
                    if next.trimmingCharacters(in: .whitespaces).isEmpty {
                        // A blank line inside a list continues it when another top-level item of
                        // the same kind follows, or a child item indented past the parent marker
                        // width follows (preventing independent lists or thematic breaks from
                        // merging into the list, #916).
                        if i + 1 < lines.count, let after = listItem(lines[i + 1]) {
                            let sameTopLevel = after.ordered == first.ordered && after.item.depth == first.item.depth
                            let nestedChild = leadingWidth(lines[i + 1]) >= first.markerWidth
                            if sameTopLevel || nestedChild {
                                i += 1
                                continue
                            }
                        }
                        break
                    }
                    if let item = listItem(next) {
                        guard item.ordered == first.ordered || item.item.depth > 0 else { break }
                        if item.item.depth < previousDepth {
                            for depth in (item.item.depth + 1)...previousDepth {
                                seenOrderedDepths.remove(depth)
                            }
                        }
                        previousDepth = item.item.depth
                        let markerOrdered: Bool? = item.ordered == first.ordered ? nil : item.ordered
                        let orderedStart: Int?
                        if item.ordered {
                            let isSublistStart = item.item.depth > 0 && !seenOrderedDepths.contains(item.item.depth)
                            seenOrderedDepths.insert(item.item.depth)
                            orderedStart = (isSublistStart && item.number != 1) ? item.number : nil
                        } else {
                            seenOrderedDepths.remove(item.item.depth)
                            orderedStart = nil
                        }
                        let resolved = (markerOrdered == nil && orderedStart == nil)
                            ? item.item
                            : ChatMarkdownListItem(text: item.item.text, depth: item.item.depth,
                                                   checked: item.item.checked,
                                                   markerOrdered: markerOrdered,
                                                   orderedStart: orderedStart)
                        items.append(resolved)
                        i += 1
                        continue
                    }
                    // A lazy continuation line belongs to the previous item.
                    if leadingWidth(next) > 0 || !startsBlock(next.trimmingCharacters(in: .whitespaces), parseFences: parseFences) {
                        let last = items.removeLast()
                        items.append(ChatMarkdownListItem(
                            text: last.text + "\n" + next.trimmingCharacters(in: .whitespaces),
                            depth: last.depth, checked: last.checked,
                            markerOrdered: last.markerOrdered, orderedStart: last.orderedStart))
                        i += 1
                        continue
                    }
                    break
                }
                blocks.append(.list(ordered: first.ordered, start: first.number, items: items))
                continue
            }

            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    /// Computes the display marker (`"1."`, `"•"`, …) for each item in a list, tracking ordered
    /// numbering independently per nesting depth and preserving nested ordered start ordinals so
    /// nested bullets or sub-lists never consume the outer list's sequence.
    public static func listMarkers(ordered: Bool, start: Int, items: [ChatMarkdownListItem]) -> [String] {
        var nextByDepth: [Int: Int] = [:]
        var previousDepth = 0
        return items.map { item in
            if item.depth < previousDepth {
                for depth in (item.depth + 1)...previousDepth {
                    nextByDepth.removeValue(forKey: depth)
                }
            }
            previousDepth = item.depth
            let itemOrdered = item.markerOrdered ?? ordered
            guard itemOrdered else {
                nextByDepth.removeValue(forKey: item.depth)
                return "•"
            }
            let current = nextByDepth[item.depth] ?? (item.depth == 0 ? start : (item.orderedStart ?? 1))
            nextByDepth[item.depth] = current + 1
            return "\(current)."
        }
    }

    // MARK: - Pieces

    private static func startsBlock(_ trimmed: String, parseFences: Bool) -> Bool {
        (parseFences && (trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")))
            || trimmed.hasPrefix(">") || heading(trimmed) != nil || isRule(trimmed)
    }

    /// The diagram a fence's info string names (its first word, any case), if the app draws it.
    private static func diagramKind(_ language: String, source: String) -> String? {
        switch language.split(whereSeparator: \.isWhitespace).first.map({ $0.lowercased() }) {
        case "mermaid": return "mermaid"
        case "svg": return "svg"
        case "xml": return SVGDiagram.looksLikeSVG(source) ? "svg" : nil
        default: return nil
        }
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func heading(_ trimmed: String) -> (Int, String)? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return (hashes, text.trimmingCharacters(in: .whitespaces))
    }

    /// The header cells when `trimmed` opens a GitHub table: a line with a pipe outside
    /// inline code, then a delimiter row of as many cells, each dashes with optional
    /// alignment colons, three characters at least (`---`, `:--:`, `--:`). Prose with a
    /// stray pipe stays prose.
    private static func tableHeader(_ trimmed: String, separator: String?) -> [String]? {
        guard let separator, hasPipe(trimmed) else { return nil }
        let header = cells(trimmed)
        let delimiters = cells(separator.trimmingCharacters(in: .whitespaces))
        guard delimiters.count == header.count, delimiters.allSatisfy(isDelimiterCell) else { return nil }
        return header
    }

    /// `:?-+:?`, at least three characters.
    private static func isDelimiterCell(_ cell: String) -> Bool {
        var body = Substring(cell)
        if body.first == ":" { body.removeFirst() }
        if body.last == ":" { body.removeLast() }
        return cell.count >= 3 && !body.isEmpty && body.allSatisfy { $0 == "-" }
    }

    /// A pipe that separates cells: not escaped, not inside a code span.
    private static func hasPipe(_ row: String) -> Bool {
        splitCells(row).count > 1
    }

    private static func cells(_ row: String) -> [String] {
        var parts = splitCells(row)
        if parts.count > 1, parts.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { parts.removeFirst() }
        if parts.count > 1, parts.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { parts.removeLast() }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Splits on cell-separating pipes; an escaped `\|` and pipes inside backtick code stay
    /// in the cell (the escape's backslash is dropped).
    private static func splitCells(_ row: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for char in row {
            if escaped {
                if char != "|" { current.append("\\") }
                current.append(char)
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == "`" {
                inCode.toggle()
                current.append(char)
            } else if char == "|", !inCode {
                parts.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        if escaped { current.append("\\") }
        parts.append(current)
        return parts
    }

    private static func leadingWidth(_ line: String) -> Int {
        var width = 0
        for char in line {
            if char == " " { width += 1 } else if char == "\t" { width += 2 } else { break }
        }
        return width
    }

    private static func listItem(_ line: String) -> (ordered: Bool, number: Int, markerWidth: Int, item: ChatMarkdownListItem)? {
        let leading = leadingWidth(line)
        let depth = leading / 2
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Thematic breaks (`- - -`, `* * *`, `_ _ _`) take precedence over list items (#916).
        guard !isRule(trimmed) else { return nil }
        var ordered = false
        var number = 1
        let markerWidth: Int
        var rest: Substring
        if let marker = trimmed.first, "-*+".contains(marker), trimmed.dropFirst().first == " " {
            markerWidth = leading + 2
            rest = trimmed.dropFirst(2)
        } else {
            let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, digits.count <= 9 else { return nil }
            let after = trimmed.dropFirst(digits.count)
            guard let dot = after.first, dot == "." || dot == ")", after.dropFirst().first == " " else { return nil }
            ordered = true
            number = Int(digits) ?? 1
            markerWidth = leading + digits.count + 2
            rest = after.dropFirst(2)
        }
        // `[ ]` / `[x]` followed by a space or nothing: an empty task item is still one.
        var checked: Bool?
        for (box, value) in [("[ ]", false), ("[x]", true), ("[X]", true)] where rest.hasPrefix(box) {
            let after = rest.dropFirst(box.count)
            guard after.isEmpty || after.first == " " else { continue }
            checked = value
            rest = after
            break
        }
        return (ordered, number, markerWidth, ChatMarkdownListItem(
            text: rest.trimmingCharacters(in: .whitespaces), depth: depth, checked: checked))
    }
}
