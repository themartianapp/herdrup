import HerdrKit
import SwiftUI

/// An omp reply drawn as native SwiftUI, like the Claude and ChatGPT apps: no bubble, 16 pt
/// Geist on 23 pt lines, with paragraphs, lists, headings, inline code, fenced code and
/// tables. HerdrKit's `ChatMarkdown` splits the blocks; inline styling uses Foundation's
/// inline markdown so bold, italic, code and links stay inside one wrapping `Text`.
struct ChatMarkdownView: View {
    let markdown: String
    /// `.thought` draws an expanded thought: the same blocks, a step smaller and dimmer;
    /// `.context` draws an ask form's context, smaller again to sit inside the form card.
    var tone: ChatMarkdownTone = .reply

    @Environment(\.chatTextScale) private var chatTextScale
    private var textScale: CGFloat { chatTextScale * tone.scale }
    private var dim: Bool { tone.dim }
    /// Parsed once per text (`ChatMarkdownCache`): a redraw of the same reply, or the same
    /// reply drawn again after it scrolled out of the drawn window, does not parse it again.
    private var blocks: [ChatMarkdownBlock] { ChatMarkdownCache.blocks(markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: ChatMarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(ChatInline.styled(text, size: 16 * textScale, dim: dim))
                .foregroundStyle(tone.ink)
                .lineSpacing(3 * textScale)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            Text(ChatInline.styled(text, size: (level == 1 ? 23 : level == 2 ? 20 : 17) * textScale, weight: .semibold, dim: dim))
                .foregroundStyle(dim ? tone.ink : Color(hex: ChatPalette.current.heading))
                .lineSpacing(2)
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let ordered, let start, let items):
            let markers = ChatMarkdown.listMarkers(ordered: ordered, start: start, items: items)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    listRow(item, marker: markers[index])
                }
            }
            .padding(.top, 2)
        case .code(let language, let code):
            GramCodeBlock(code: code, language: language, textScale: textScale, syntax: .current)
        case .diagram(let kind, let source):
            ChatMermaidView(source: source, kind: kind)
        case .table(let header, let rows):
            ChatMarkdownTable(header: header, rows: rows, style: .chat(tone: tone, textScale: textScale))
        case .quote(let text):
            Text(ChatInline.styled(text, size: 15.5 * textScale, dim: dim))
                .foregroundStyle(Palette.textDim)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Palette.hairline).frame(width: 2)
                }
        case .rule:
            Rectangle().fill(Palette.hairlineQuiet).frame(height: 1).padding(.vertical, 4)
        }
    }

    private func listRow(_ item: ChatMarkdownListItem, marker: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if let checked = item.checked {
                    Image(systemName: checked ? "checkmark.square" : "square")
                        .font(.system(size: 13 * textScale, weight: .medium))
                } else {
                    Text(marker).font(Typography.app(16 * textScale))
                }
            }
            .foregroundStyle(tone.marker)
            .frame(minWidth: 10, alignment: .leading)
            Text(ChatInline.styled(item.text, size: 16 * textScale, dim: dim))
                .foregroundStyle(tone.ink)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(item.depth) * 18 + 20)
    }
}

/// How a markdown body is drawn: a reply in the chat's ink, or an expanded thought, which
/// must read as the agent's aside and not as its answer: the secondary ink and one type step
/// smaller (16 pt body → 15 pt), inline code and lists included. An ask form's context is
/// drawn like a thought at the card's 14 pt, under the question it introduces.
enum ChatMarkdownTone: Equatable {
    case reply
    case thought
    case context

    var dim: Bool { self != .reply }
    var ink: Color { dim ? Palette.textDim : Palette.text }
    /// List markers and checkboxes: one tier under the text.
    var marker: Color { dim ? Palette.textFaint : Palette.textDim }
    var scale: CGFloat {
        switch self {
        case .reply: 1
        case .thought: 15.0 / 16.0
        case .context: 14.0 / 16.0
        }
    }
}

/// Visual configuration for `ChatMarkdownTable`, shared by Chat and Gram bubbles.
struct MarkdownTableStyle {
    let minColumnWidth: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let cornerRadius: CGFloat
    let headerBackground: Color
    let borderColor: Color
    let dividerColor: Color
    let headerInk: Color
    let bodyInk: Color
    let gainInk: Color
    let accessibilityIdentifier: String
    let headerText: @MainActor (String) -> AttributedString
    let numberText: @MainActor (String) -> AttributedString
    let bodyText: @MainActor (String) -> AttributedString

    static func chat(tone: ChatMarkdownTone, textScale: CGFloat) -> MarkdownTableStyle {
        MarkdownTableStyle(
            minColumnWidth: 96 * textScale,
            horizontalPadding: 12,
            verticalPadding: 7,
            cornerRadius: 12,
            headerBackground: Palette.surface,
            borderColor: Palette.hairline,
            dividerColor: Palette.hairlineQuiet,
            headerInk: Palette.textDim,
            bodyInk: tone.ink,
            gainInk: ChatStyle.ok,
            accessibilityIdentifier: "chat-markdown-table",
            headerText: { ChatInline.styled($0, size: 13 * textScale, weight: .semibold, dim: tone.dim) },
            numberText: { ChatInline.styled($0, size: 13.5 * textScale, dim: tone.dim) },
            bodyText: { ChatInline.styled($0, size: 14.5 * textScale, dim: tone.dim) }
        )
    }
}

/// Fit ordinary tables to the available width; scroll only when readable columns cannot fit.
struct ChatMarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    let style: MarkdownTableStyle
    private let columns: Int
    @State private var viewportWidth: CGFloat = 0

    init(header: [String], rows: [[String]], style: MarkdownTableStyle) {
        self.header = header
        self.rows = rows
        self.style = style
        columns = max(1, rows.reduce(header.count) { max($0, $1.count) })
    }

    var body: some View {
        let cellWidth = max(style.minColumnWidth, floor(viewportWidth / CGFloat(columns)))
        let innerWidth = max(1, cellWidth - style.horizontalPadding * 2)
        let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        Text(style.headerText(column < header.count ? header[column] : ""))
                            .foregroundStyle(style.headerInk)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: innerWidth, alignment: .leading)
                            .padding(.horizontal, style.horizontalPadding)
                            .padding(.vertical, style.verticalPadding)
                    }
                }
                .background(style.headerBackground)
                ForEach(rows.indices, id: \.self) { index in
                    Rectangle().fill(style.dividerColor).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            cell(column < rows[index].count ? rows[index][column] : "", innerWidth: innerWidth)
                        }
                    }
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(style.borderColor, lineWidth: 1))
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(style.accessibilityIdentifier)
    }

    private func cell(_ value: String, innerWidth: CGFloat) -> some View {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let numeric = (trimmed.first.map { $0.isNumber || "+-−$".contains($0) } ?? false)
            && trimmed.contains(where: \.isNumber)
        return Group {
            if numeric {
                Text(style.numberText(trimmed))
                    .monospacedDigit()
                    .foregroundStyle(trimmed.hasPrefix("+") ? style.gainInk : style.bodyInk)
            } else {
                Text(style.bodyText(value))
                    .foregroundStyle(style.bodyInk)
            }
        }
        .multilineTextAlignment(numeric ? .trailing : .leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: innerWidth, alignment: numeric ? .trailing : .leading)
        .padding(.horizontal, style.horizontalPadding)
        .padding(.vertical, style.verticalPadding)
    }
}

/// Parsed markdown kept by text, so a view drawn again for the same text does not parse it
/// again: reply blocks (`ChatMarkdownView`), Gram prose blocks (`GramTextPart`), and inline
/// styles (`ChatInline`, which a long chat calls hundreds of times per pass for the collapsed
/// thoughts alone). Each cache is bounded and starts over when full, so a long session cannot
/// grow it without end.
@MainActor
enum ChatMarkdownCache {
    private static var blocksByText = BoundedCache<String, [ChatMarkdownBlock]>(limit: 400)
    private static var gramBlocksByText = BoundedCache<String, [GramProseBlock]>(limit: 400)

    static func blocks(_ markdown: String) -> [ChatMarkdownBlock] {
        blocksByText.value(for: markdown) { ChatMarkdown.blocks(markdown) }
    }

    static func gramProseBlocks(_ markdown: String) -> [GramProseBlock] {
        gramBlocksByText.value(for: markdown) { GramText.proseBlocks(markdown) }
    }

    struct BoundedCache<Key: Hashable, Value> {
        let limit: Int
        private var values: [Key: Value] = [:]

        init(limit: Int) { self.limit = limit }

        mutating func value(for key: Key, make: () -> Value) -> Value {
            if let value = values[key] { return value }
            let value = make()
            store(value, for: key)
            return value
        }

        func cached(_ key: Key) -> Value? { values[key] }

        mutating func store(_ value: Value, for key: Key) {
            if values.count >= limit { values.removeAll(keepingCapacity: true) }
            values[key] = value
        }
    }
}

/// Inline Markdown presentation choices shared between `ChatInline` and Gram's `GramInline`.
struct InlineMarkdownAppearance {
    let size: CGFloat
    let weight: Font.Weight
    let codeSizeOffset: CGFloat
    let codeBackground: Color
    let codeForeground: Color
    let linkForeground: Color
    let underlineLinks: Bool
}

@MainActor
enum ChatInline {
    private struct Key: Hashable {
        let markdown: String
        let size: CGFloat
        let weight: Font.Weight
        let dim: Bool
    }
    private static var cache = ChatMarkdownCache.BoundedCache<Key, AttributedString>(limit: 2000)

    /// Inline markdown (bold, italic, `code`, links, strikethrough) as one attributed string
    /// in the app's fonts. Anything it cannot parse shows as the literal text. Kept per text,
    /// size, weight and tone (`ChatMarkdownCache`). `dim` (an expanded thought) draws inline
    /// code in the secondary ink like the text around it.
    static func styled(_ markdown: String, size: CGFloat, weight: Font.Weight = .regular, dim: Bool = false) -> AttributedString {
        cache.value(for: Key(markdown: markdown, size: size, weight: weight, dim: dim)) {
            render(markdown, appearance: InlineMarkdownAppearance(
                size: size,
                weight: weight,
                codeSizeOffset: 2.5,
                codeBackground: Palette.surface,
                codeForeground: dim ? Palette.textDim : Palette.text,
                linkForeground: Palette.working,
                underlineLinks: false
            ))
        }
    }

    /// Parses inline Markdown with Foundation's inline parser and applies `appearance`.
    static func render(_ markdown: String, appearance: InlineMarkdownAppearance) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        var styled = (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
        for run in styled.runs {
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                styled[run.range].font = Typography.machine(max(appearance.size - appearance.codeSizeOffset, 10))
                styled[run.range].backgroundColor = appearance.codeBackground
                styled[run.range].foregroundColor = appearance.codeForeground
                continue
            }
            var font = Typography.app(appearance.size, intent.contains(.stronglyEmphasized) ? .semibold : appearance.weight)
            if intent.contains(.emphasized) { font = font.italic() }
            styled[run.range].font = font
            if intent.contains(.strikethrough) { styled[run.range].strikethroughStyle = .single }
            if run.link != nil {
                styled[run.range].foregroundColor = appearance.linkForeground
                if appearance.underlineLinks { styled[run.range].underlineStyle = .single }
            }
        }
        return styled
    }
}
