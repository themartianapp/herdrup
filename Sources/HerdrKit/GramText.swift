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

        var index = lines.startIndex
        while index < lines.endIndex {
            let line = lines[index]
            guard let fence = Fence(opening: line) else {
                prose.append(line)
                index += 1
                continue
            }
            if fence.marker == "~", fence.indent > 0 {
                // An indented tilde opener (e.g. inside a list item) belongs to its enclosing
                // indented block: stop scanning at a dedented non-blank line so an unclosed
                // indented tilde fence never swallows a later top-level code card (#915).
                var close: Int?
                var scan = index + 1
                while scan < lines.endIndex {
                    let candidate = lines[scan]
                    if fence.isClosed(by: candidate) {
                        close = scan
                        break
                    }
                    if candidate.contains(where: { !$0.isWhitespace }),
                       Self.leadingSpaceCount(candidate) < fence.indent {
                        break
                    }
                    scan += 1
                }
                guard let foundClose = close else {
                    prose.append(line)
                    index += 1
                    continue
                }
                flushProse()
                segments.append(.code(lines[(index + 1)..<foundClose].joined(separator: "\n"),
                                      language: fence.language))
                index = foundClose + 1
                continue
            }
            guard let close = lines[(index + 1)...].firstIndex(where: fence.isClosed(by:)) else {
                // Unclosed: the rest of the message is prose, fence line included.
                prose.append(contentsOf: lines[index...])
                break
            }
            flushProse()
            segments.append(.code(lines[(index + 1)..<close].joined(separator: "\n"),
                                  language: fence.language))
            index = close + 1
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
        let indent: Int
        let language: String?

        init?(opening line: Substring) {
            let indent = GramText.leadingSpaceCount(line)
            let body = line.drop(while: { $0 == " " || $0 == "\t" })
            guard let marker = body.first, marker == "`" || marker == "~" else { return nil }
            // CommonMark §4.5: a 4+ space indented tilde line is an indented code block, not a fence (#915).
            if marker == "~", indent > 3 { return nil }
            let count = body.prefix(while: { $0 == marker }).count
            guard count >= 3 else { return nil }
            let info = body.dropFirst(count)
            if marker == "`", info.contains("`") { return nil }
            self.marker = marker
            self.count = count
            self.indent = indent
            self.language = info.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
        }

        func isClosed(by line: Substring) -> Bool {
            let body = line.trimmingCharacters(in: .whitespaces)
            return body.count >= count && body.allSatisfy { $0 == marker }
        }
    }
}
