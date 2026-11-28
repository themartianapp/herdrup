import Foundation

/// One piece of a gram's text: prose, or a fenced code block.
public enum GramTextSegment: Equatable, Sendable {
    case text(String)
    case code(String, language: String?)
}

/// Prose-only Markdown blocks rendered inside a Gram text segment (fenced code blocks are
/// already extracted by `GramText.segments(_:)`, so `.code` and `.diagram` never appear here).
public enum GramProseBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, String)
    case list(ordered: Bool, start: Int, items: [ChatMarkdownListItem])
    case table(header: [String], rows: [[String]])
    case quote(String)
    case rule
}

/// Splits a gram's text into prose and fenced ```` ``` ```` / `~~~` code blocks, so the app can
/// draw code in its own monospaced inset with a Copy button.
///
/// The rules, kept deliberately small:
/// - A fence is a line that starts (after optional indentation) with three or more backticks
///   (`` ` ``) or tildes (`~`). What follows the fence run is the info string; its first word is
///   the language. A backtick fence whose info string holds a backtick is not a fence
///   (CommonMark), so ```` ```inline``` ```` stays prose.
/// - The block closes on a line of only the matching fence character, at least as many as the
///   opening run.
/// - An opening fence that never closes is prose: it and everything after it read as text.
/// - The newline next to a fence belongs to the fence, so `"Run:\n```\nls\n```\nDone"` is
///   `Run:`, `ls`, `Done`. Prose that is only whitespace (between adjacent fences) is dropped.
/// - CRLF line endings read as LF.
public enum GramText {
    public static func segments(_ text: String) -> [GramTextSegment] {
        // `\r\n` is ONE Character in Swift, so it never equals "\n": normalise first.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        var segments: [GramTextSegment] = []
        var prose: [Substring] = []

        func flushProse() {
            let joined = prose.joined(separator: "\n")
            prose.removeAll()
            if joined.contains(where: { !$0.isWhitespace }) { segments.append(.text(joined)) }
        }

        var enclosingIndents: [Int] = []
        var failedTildeBlock: (end: Int, blockIndent: Int, minCount: Int)?
        var index = lines.startIndex
        while index < lines.endIndex {
            let line = lines[index]
            let isBlank = !line.contains(where: { !$0.isWhitespace })
            let lineIndent = isBlank ? 0 : Self.leadingSpaceCount(line)
            if !isBlank {
                while let top = enclosingIndents.last, lineIndent < top {
                    enclosingIndents.removeLast()
                }
            }
            let blockIndent = enclosingIndents.last ?? 0
            if let fence = Fence(opening: line, blockIndent: blockIndent) {
                if let close = Self.findClose(
                    for: fence,
                    from: index + 1,
                    blockIndent: blockIndent,
                    in: lines,
                    failedTildeBlock: &failedTildeBlock
                ) {
                    flushProse()
                    segments.append(.code(lines[(index + 1)..<close].joined(separator: "\n"),
                                          language: fence.language))
                    index = close + 1
                    continue
                }
                if blockIndent > 0, fence.marker == "~" {
                    prose.append(line)
                    index += 1
                    continue
                }
                // Unclosed top-level fence: the rest of the message is prose, fence line included.
                prose.append(contentsOf: lines[index...])
                break
            }
            if !isBlank, let col = Self.listContentColumn(line) {
                enclosingIndents.append(col)
            }
            prose.append(line)
            index += 1
        }
        flushProse()
        return segments
    }

    /// Splits a Gram prose segment (already separated from closed fenced code blocks by
    /// `segments(_:)`) into prose-only Markdown blocks without re-parsing block fences, so inline
    /// triple-backtick spans (e.g. ```` ``` `42` ``` ````) and unclosed fences remain prose.
    public static func proseBlocks(_ text: String) -> [GramProseBlock] {
        ChatMarkdown.blocks(text, parseFences: false).compactMap { block in
            switch block {
            case .paragraph(let s): return .paragraph(s)
            case .heading(let level, let s): return .heading(level: level, s)
            case .list(let ordered, let start, let items): return .list(ordered: ordered, start: start, items: items)
            case .table(let header, let rows): return .table(header: header, rows: rows)
            case .quote(let s): return .quote(s)
            case .rule: return .rule
            case .code, .diagram: return nil
            }
        }
    }

    /// True when parsed prose blocks contain a GitHub-flavored Markdown table (used to widen
    /// the bubble to its cap so table columns have room).
    public static func hasTable(_ blocks: [GramProseBlock]) -> Bool {
        blocks.contains {
            if case .table = $0 { return true } else { return false }
        }
    }

    /// True when parsed blocks contain multiple blocks or any non-paragraph block (lists,
    /// headings, tables, quotes, rules); false for a single paragraph so plain prose keeps
    /// the exact 8-line `GramFoldingText` layout.
    public static func isRichMarkdown(_ blocks: [GramProseBlock]) -> Bool {
        guard blocks.count == 1 else { return blocks.count > 1 }
        if case .paragraph = blocks[0] { return false }
        return true
    }

    /// Finds the closing fence line index for `fence`, bounded by `blockIndent` when inside an
    /// indented list item so unclosed nested tilde fences never swallow later code cards (#915),
    /// while preserving top-level 1..3-space fences and list-indented 4+-space fences (#922).
    /// Failed nested tilde scans record `(end, blockIndent, minCount)` so repeated unclosed
    /// openers inside the same block stay O(N) (#923).
    private static func findClose(
        for fence: Fence,
        from start: Int,
        blockIndent: Int,
        in lines: [Substring],
        failedTildeBlock: inout (end: Int, blockIndent: Int, minCount: Int)?
    ) -> Int? {
        if fence.marker == "~", blockIndent > 0 {
            if let failed = failedTildeBlock,
               start <= failed.end,
               blockIndent >= failed.blockIndent,
               fence.count >= failed.minCount {
                return nil
            }
            var maxCloserCount = 0
            var scan = start
            while scan < lines.endIndex {
                let candidate = lines[scan]
                if candidate.contains(where: { !$0.isWhitespace }),
                   leadingSpaceCount(candidate) < blockIndent {
                    break
                }
                let trimmed = candidate.trimmingCharacters(in: .whitespaces)
                if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "~" }) {
                    if trimmed.count >= fence.count { return scan }
                    maxCloserCount = max(maxCloserCount, trimmed.count)
                }
                scan += 1
            }
            failedTildeBlock = (end: scan, blockIndent: blockIndent, minCount: max(3, maxCloserCount + 1))
            return nil
        }
        return lines[start...].firstIndex(where: fence.isClosed(by:))
    }

    private static func listContentColumn(_ line: Substring) -> Int? {
        let leading = leadingSpaceCount(line)
        let body = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = body.first else { return nil }
        // Reject thematic breaks (`- - -`, `* * *`, `_ _ _`).
        let compact = body.filter { $0 != " " && $0 != "\t" }
        if compact.count >= 3, "-*_".contains(first), compact.allSatisfy({ $0 == first }) {
            return nil
        }
        let markerLen: Int
        let afterMarker: Substring
        if "-*+".contains(first), let sp = body.dropFirst().first, sp == " " || sp == "\t" {
            markerLen = 1
            afterMarker = body.dropFirst()
        } else {
            let digits = body.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, digits.count <= 9 else { return nil }
            let rest = body.dropFirst(digits.count)
            guard let dot = rest.first, dot == "." || dot == ")",
                  let sp = rest.dropFirst().first, sp == " " || sp == "\t" else { return nil }
            markerLen = digits.count + 1
            afterMarker = rest.dropFirst()
        }
        let padding = afterMarker.prefix { $0 == " " || $0 == "\t" }
        let padWidth = afterMarker.dropFirst(padding.count).isEmpty
            ? 1
            : padding.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        return leading + markerLen + padWidth
    }

    private static func leadingSpaceCount(_ line: Substring) -> Int {
        var count = 0
        for ch in line {
            if ch == " " { count += 1 }
            else if ch == "\t" { count += 4 }
            else { break }
        }
        return count
    }

    private struct Fence {
        let marker: Character
        let count: Int
        let language: String?

        init?(opening line: Substring, blockIndent: Int) {
            let indent = GramText.leadingSpaceCount(line)
            let body = line.drop(while: { $0 == " " || $0 == "\t" })
            guard let marker = body.first, marker == "`" || marker == "~" else { return nil }
            // CommonMark §4.5: 4+ spaces relative to the enclosing block is indented code, not a fence (#915, #922).
            if marker == "~", indent - blockIndent > 3 { return nil }
            let count = body.prefix(while: { $0 == marker }).count
            guard count >= 3 else { return nil }
            let info = body.dropFirst(count)
            if marker == "`", info.contains("`") { return nil }
            self.marker = marker
            self.count = count
            self.language = info.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
        }

        func isClosed(by line: Substring) -> Bool {
            let body = line.trimmingCharacters(in: .whitespaces)
            return body.count >= count && body.allSatisfy { $0 == marker }
        }
    }
}
