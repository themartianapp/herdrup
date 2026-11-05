import HerdrKit
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Building blocks for Gram's final design (option D's iMessage layout and agent cards in
// option C's herdr colours; spec gram-final-d-with-c-colours.html, round 3). Every colour
// is a Palette or GramBubble token. These views draw their CONTENT only: the outer margins
// the spec gives them (time separator 16 pt above, unread rule 12 pt above, the saved
// badge's -17/-15 corner offset, 9 pt above an embedded file card) belong to the feed.

/// Sizes shared by the Gram cards.
enum GramCardMetrics {
    /// A bubble's or card's width CAP on a phone, and its FLOOR on iPad/Mac (where the cap
    /// grows with the column, `bubbleCap`).
    static let compactCardWidth: CGFloat = 295
    static let regularCardWidth: CGFloat = 520
    /// On iPad/Mac, the share of the offered width an agent's bubble may take, and yours.
    static let incomingColumnShare: CGFloat = 0.8
    static let outgoingColumnShare: CGFloat = 0.66

    /// The width CAP of a message's bubble or card (prose, code, text + file, a lone file).
    /// `column` is the width the row offers the bubble: the feed's column, less the avatar
    /// beside an agent's message. A phone keeps the fixed 295; iPad/Mac takes the sender's
    /// share of the column (an agent's 80 %, yours 66 %), never under 520, so a wide column
    /// is not left with an empty middle. The bubble is `min(this, column)`
    /// (`GramBubbleWidthLayout`), so a narrow column (split view, Slide Over, Display Zoom)
    /// shrinks it instead of clipping it at the edge. An unbounded column gets the floor.
    static func bubbleCap(column: CGFloat, incoming: Bool, regular: Bool) -> CGFloat {
        guard regular else { return compactCardWidth }
        guard column.isFinite else { return regularCardWidth }
        return max(regularCardWidth, column * (incoming ? incomingColumnShare : outgoingColumnShare))
    }

    /// An image card's size CAP: 295 x 124 on a phone, 440 x 236 on iPad/Mac. A narrower
    /// column scales it down at this aspect ratio.
    static func imageSize(_ sizeClass: UserInterfaceSizeClass?) -> CGSize {
        sizeClass == .regular ? CGSize(width: 440, height: 236) : CGSize(width: 295, height: 124)
    }
}

/// A message's bubble or card at `GramCardMetrics.bubbleCap` of the width offered to it, on
/// the sender's side (an agent's leading, yours trailing): `.frame(maxWidth:alignment:)`
/// with a cap that follows the offered width. Layout, not a width read in a body: dragging
/// the column re-runs this and never the rows' bodies (#536/#543).
struct GramBubbleWidthLayout: Layout {
    let incoming: Bool
    let regular: Bool

    /// The cap for the offered width and the proposal passed on to the bubble: the offer up
    /// to the cap. An unspecified offer (a parent asking for the ideal size) passes on as
    /// unspecified and the cap is the floor, as the fixed cap's frame did.
    private func widths(_ proposal: ProposedViewSize) -> (cap: CGFloat, child: ProposedViewSize) {
        let cap = GramCardMetrics.bubbleCap(column: proposal.width ?? .infinity,
                                            incoming: incoming, regular: regular)
        return (cap, ProposedViewSize(width: proposal.width.map { min($0, cap) }, height: proposal.height))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (cap, child) = widths(proposal)
        var size = CGSize.zero
        for subview in subviews {
            let fit = subview.sizeThatFits(child)
            size.width = max(size.width, fit.width)
            size.height = max(size.height, fit.height)
        }
        // As a `maxWidth` frame: the offered width up to the cap, so the bubble's side of the
        // row lines up whatever its length.
        size.width = min(cap, max(size.width, proposal.width ?? 0))
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        let child = widths(proposal).child
        for subview in subviews {
            subview.place(at: CGPoint(x: incoming ? bounds.minX : bounds.maxX, y: bounds.midY),
                          anchor: incoming ? .leading : .trailing, proposal: child)
        }
    }
}

extension View {
    /// This bubble or card at its sender's width cap (`GramBubbleWidthLayout`).
    func gramBubbleWidth(incoming: Bool, sizeClass: UserInterfaceSizeClass?) -> some View {
        GramBubbleWidthLayout(incoming: incoming, regular: sizeClass == .regular) { self }
    }
}

/// Gram's type roles with their line heights (body 15/20, code 13/18, row preview
/// 14/18). SwiftUI has no line-height modifier, so the spacing is the line height minus
/// the bundled font's own, at the current `Typography.scale`.
enum GramType {
    /// Message text: the app's 15 pt body size (as Gram before the redesign), not iMessage's
    /// 17 pt, which read about 13% larger than every other screen at the same text size.
    static var body: Font { Typography.app(15) }
    static var bodyLineSpacing: CGFloat { lineSpacing("Geist-Regular", size: 15, lineHeight: 20) }
    static var code: Font { Typography.machine(13) }
    static var codeLineSpacing: CGFloat { lineSpacing("IBMPlexMono", size: 13, lineHeight: 18) }
    static var preview: Font { Typography.app(14) }
    static var previewLineSpacing: CGFloat { lineSpacing("Geist-Regular", size: 14, lineHeight: 18) }
    /// A folded message's "Read more" / "Show less" line: 15 pt semibold on a 20 pt line.
    static var foldToggle: Font { Typography.app(15, .semibold) }
    static var foldToggleLineHeight: CGFloat { 20 * Typography.scale }

    private static func lineSpacing(_ postScriptName: String, size: CGFloat, lineHeight: CGFloat) -> CGFloat {
        let scale = Typography.scale
        guard let font = UIFont(name: postScriptName, size: size * scale) else { return 0 }
        return max(0, lineHeight * scale - font.lineHeight)
    }
}

/// Day and time wording for the feed's separators and the sidebar rows, like Messages.
enum GramDates {
    static func clockNow() -> Date {
        #if DEBUG
        if let pinned = MockClock.pinned { return pinned }
        #endif
        return Date()
    }

    /// "Today" / "Yesterday" / a weekday within the last week / a date, plus the time.
    static func separator(for date: Date, now: Date = GramDates.clockNow(), calendar: Calendar = .current) -> (day: String, time: String) {
        let time = timeFormatter.string(from: date)
        switch day(of: date, now: now, calendar: calendar) {
        case .today: return ("Today", time)
        case .yesterday: return ("Yesterday", time)
        case .thisWeek: return (weekdayFormatter.string(from: date), time)
        case .thisYear: return (dayMonthFormatter.string(from: date), time)
        case .earlier: return (dayMonthYearFormatter.string(from: date), time)
        }
    }

    /// A sidebar row's time: the time today, then "Yesterday", a weekday, a short date.
    static func rowTime(for date: Date, now: Date = GramDates.clockNow(), calendar: Calendar = .current) -> String {
        switch day(of: date, now: now, calendar: calendar) {
        case .today: return timeFormatter.string(from: date)
        case .yesterday: return "Yesterday"
        case .thisWeek: return weekdayFormatter.string(from: date)
        case .thisYear, .earlier: return shortDateFormatter.string(from: date)
        }
    }

    private enum Day { case today, yesterday, thisWeek, thisYear, earlier }

    private static func day(of date: Date, now: Date, calendar: Calendar) -> Day {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return .yesterday }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? .max
        if (2..<7).contains(days) { return .thisWeek }
        return calendar.isDate(date, equalTo: now, toGranularity: .year) ? .thisYear : .earlier
    }

    private static func formatter(template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private static let timeFormatter = formatter(template: "jmm")
    private static let weekdayFormatter = formatter(template: "EEEE")
    private static let dayMonthFormatter = formatter(template: "EEEdMMM")
    private static let dayMonthYearFormatter = formatter(template: "dMMMyyyy")
    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()
}

// MARK: - Avatars

/// An agent's round avatar in Gram: the picture of the roster agent its routing name
/// denotes (`AgentAvatarView`, herdrup#538), so a sender looks the same here as in the agent
/// list. A federated name finds the agent on that machine; an unknown sender wears the
/// initial tile.
struct GramAvatar: View {
    let name: String
    let size: CGFloat

    var body: some View {
        AgentAvatarView(gramSender: name, size: size)
    }
}

private extension View {
    /// A ring of `color` drawn OUTSIDE the view (it cuts the avatar out of whatever it
    /// overlaps), without changing the view's layout size.
    func gramRing(_ color: Color, width: CGFloat) -> some View {
        background(Circle().fill(color).padding(-width))
    }
}

/// The first routing name of each distinct bare name, in order, at most `limit`. The full
/// name is kept so the avatar can find a federated sender on its own machine.
private func distinctAgentNames(_ names: [String], limit: Int) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for name in names {
        let bare = GramMessage.agentName(from: name)
        guard seen.insert(bare).inserted else { continue }
        result.append(name)
        if result.count == limit { break }
    }
    return result
}

/// The conversation header's avatar group: the first name (the most recent sender) as a
/// 38 pt avatar in the middle, the next two as 26 pt avatars either side, each ringed in
/// the ground. A fixed 78 x 48 box so the header does not move as senders change.
struct GramAvatarCluster: View {
    let names: [String]

    var body: some View {
        let shown = distinctAgentNames(names, limit: 3)
        ZStack(alignment: .topLeading) {
            if shown.count > 1 { side(shown[1], x: 0) }
            if shown.count > 2 { side(shown[2], x: 52) }
            if let main = shown.first {
                GramAvatar(name: main, size: 38)
                    .gramRing(Palette.ground, width: 2)
                    .offset(x: 20, y: 2)
            }
        }
        .frame(width: 78, height: 48, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func side(_ name: String, x: CGFloat) -> some View {
        GramAvatar(name: name, size: 26)
            .gramRing(Palette.ground, width: 2)
            .offset(x: x, y: 16)
    }
}

// MARK: - Text

/// A long message shown whole up to eight lines. Past that, the eighth line ends in "…" and
/// a separate "Read more" line sits under the text inside the bubble; once open, "Show less"
/// takes the same place. No overlay and no fade (gram-fixes). The caller holds `isExpanded`
/// so the state survives the row being recycled.
///
/// The body font is the 15/20 body and its colour is inherited, so the caller tints it for its
/// side. `toggleTint` colours the Read more / Show less line: brand violet in an agent's
/// bubble, `onAccent` in the owner's violet one.
struct GramFoldingText: View {
    let text: AttributedString
    @Binding var isExpanded: Bool
    var toggleTint: Color = Palette.brand

    static let foldedLineLimit = 8

    @State private var fullHeight: CGFloat = 0
    @State private var foldedHeight: CGFloat = 0

    private var folds: Bool { fullHeight > foldedHeight + 0.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            bodyText
                .lineLimit(isExpanded ? nil : Self.foldedLineLimit)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                // Measured at the shown text's width: the whole text, and eight lines of it.
                .background(alignment: .topLeading) { probes }
            if folds { foldToggle }
        }
    }

    private var bodyText: some View {
        Text(text)
            .font(GramType.body)
            .lineSpacing(GramType.bodyLineSpacing)
    }

    private var foldToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            Text(isExpanded ? "Show less" : "Read more")
                .font(GramType.foldToggle)
                .foregroundStyle(toggleTint)
                .lineLimit(1)
                .frame(minHeight: GramType.foldToggleLineHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(isExpanded ? "gram-show-less" : "gram-read-more")
    }

    private var probes: some View {
        ZStack(alignment: .topLeading) {
            bodyText
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
            bodyText
                .lineLimit(Self.foldedLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { foldedHeight = $0 }
        }
        // `.hidden()`, not opacity 0: an invisible copy still sits in the accessibility tree
        // (the probe test found the report three times there, so VoiceOver read it three
        // times) and its full height counted in the bubble's frame. Hidden views keep their
        // layout, so the measurements still arrive.
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Bubbles

extension View {
    /// The bubble's tail (`BubbleTail`) behind a part that ends in text, curving out of the
    /// bottom corner on the sender's side, in the side's fill. `shown` false draws nothing.
    func gramBubbleTail(mine: Bool, shown: Bool) -> some View {
        background(alignment: mine ? .bottomTrailing : .bottomLeading) {
            if shown {
                BubbleTail()
                    .fill(mine ? GramBubble.outFill : GramBubble.inFill)
                    .frame(width: 24, height: 22)
                    .scaleEffect(x: mine ? -1 : 1, y: 1)
                    .offset(x: mine ? 6 : -6)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// A message's text and its card file (a document, or a file the store expired), as every
/// Gram page draws them: a plain bubble for prose alone, a card (the whole width the caller's
/// `gramBubbleWidth` cap offers) once there is code or a file, and the bare file card for a
/// file with no text. Prose folds past eight lines (`GramFoldingText`); the caller holds the
/// fold state, by segment index. `card` draws the file card, `embedded` when text sits above it.
struct GramTextPart<Card: View>: View {
    let segments: [GramTextSegment]
    let mine: Bool
    let hasCard: Bool
    let isExpanded: (Int) -> Binding<Bool>
    @ViewBuilder let card: (_ embedded: Bool) -> Card

    private var fill: Color { mine ? GramBubble.outFill : GramBubble.inFill }
    private var bubbleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: GramBubble.radius, style: .continuous)
    }

    var body: some View {
        let hasCode = segments.contains { if case .code = $0 { return true } else { return false } }
        if segments.isEmpty, hasCard {
            card(false)
        } else if hasCode || hasCard {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    switch segment {
                    case .text(let text):
                        prose(text, index: index)
                            .padding(.horizontal, 12)
                            .padding(.top, 7)
                    case .code(let code, let language):
                        GramCodeBlock(code: code, language: language)
                            .padding(.horizontal, 8)
                            .padding(.top, 7)
                    }
                }
                if hasCard {
                    card(true)
                        .padding(.top, 9)
                } else {
                    Color.clear.frame(height: 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill)
            .clipShape(bubbleShape)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    if case .text(let text) = segment {
                        prose(text, index: index)
                    }
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .background(fill, in: bubbleShape)
        }
    }

    /// Your text in `onAccent` on the violet fill, an agent's in the body ink; links and the
    /// Read more line tinted to match.
    private func prose(_ text: String, index: Int) -> some View {
        GramFoldingText(
            text: linkified(text, tint: mine ? Palette.onAccent : Palette.brand),
            isExpanded: isExpanded(index),
            toggleTint: mine ? Palette.onAccent : Palette.brand
        )
        .foregroundStyle(mine ? Palette.onAccent : Palette.text)
    }
}

/// A message drawn outside the inbox's feed (a Saved copy, a guest's Gram) with the inbox's
/// parts: the sender's `GramAvatar` beside an agent's message, the text part
/// (`GramTextPart`) in its side's fill with the tail, and the file as the inbox's file or
/// expired card. Never grouped: each stands alone, so every agent message carries its avatar
/// and every part that ends in text its tail. Your messages sit on the right, without an
/// avatar, as in the inbox. `header` is the page's line above the bubble (who, when, and the
/// page's own controls); `menu` is the bubble's long-press menu.
struct GramLoneMessage<Header: View, Card: View>: View {
    let text: String
    /// The sender as `GramAvatar` takes it (a federated `<machine>/<name>` shows its name).
    let sender: String
    let mine: Bool
    let hasCard: Bool
    let menu: () -> [StableMenuItem]
    @ViewBuilder let header: () -> Header
    @ViewBuilder let card: (_ embedded: Bool) -> Card

    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The text segments the reader opened with Read more. Row state: a row redrawn from
    /// scratch folds again, which a list of standalone messages can afford.
    @State private var expanded: Set<Int> = []

    var body: some View {
        let segments = GramText.segments(text)
        VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
            header()
                .padding(mine ? .trailing : .leading, mine ? 2 : GramBubble.groupIndent + 12)
            HStack(alignment: .bottom, spacing: GramBubble.groupIndent - GramBubble.avatarSize) {
                if !mine {
                    GramAvatar(name: sender, size: GramBubble.avatarSize)
                }
                if !segments.isEmpty || hasCard {
                    GramTextPart(segments: segments, mine: mine, hasCard: hasCard,
                                 isExpanded: isExpanded, card: card)
                        .gramBubbleTail(mine: mine, shown: !segments.isEmpty && !hasCard)
                        .stableContextMenu(previewCornerRadius: GramBubble.radius, items: menu)
                        .gramBubbleWidth(incoming: !mine, sizeClass: sizeClass)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private func isExpanded(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(index) },
            set: { open in
                if open { expanded.insert(index) } else { expanded.remove(index) }
            }
        )
    }
}

// MARK: - Code

/// A fenced code block: monospaced 13/18 on the machine ground, with Copy. One line shows
/// only a copy glyph beside the code; several lines get a header with the language and
/// "Copy". Long lines scroll sideways rather than wrap, so a command keeps its shape.
///
/// Copy WRITES the pasteboard only (never reads it: a programmatic read raises the system
/// paste prompt), through the receipt `CopyableCommand` uses, so only the block whose code
/// is actually on the clipboard says "Copied", and only for a moment.
///
/// With a `syntax` palette (the chat's, `ChatPalette`) the block takes the theme's code
/// background, border and text, and a known language is highlighted off the main thread
/// (`ChatCodeHighlights`); the plain code shows until then. Gram passes none.
struct GramCodeBlock: View {
    let code: String
    let language: String?
    /// The chat's text-size scale (`chatTextScale`) for the code; Gram keeps 1.
    var textScale: CGFloat = 1
    var syntax: ChatPalette?

    @State private var receipt = CopiedCommandReceipt.shared
    /// The highlighted code, kept with its key: a streaming reply's block keeps its identity
    /// while its code grows, and must not show an older highlight.
    @State private var highlighted: Highlighted?

    private struct Highlighted {
        let key: ChatCodeHighlights.Key
        let text: AttributedString
    }

    /// What to highlight, or nil to draw the code plain (Gram, or a language the
    /// highlighter does not know).
    private var highlightKey: ChatCodeHighlights.Key? {
        guard let syntax, let known = CodeLanguage(fence: language) else { return nil }
        return ChatCodeHighlights.Key(code: code, language: known, palette: syntax)
    }

    private var copied: Bool { receipt.text == code }
    private var isOneLine: Bool { !code.contains("\n") }
    private static let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)

    var body: some View {
        Group {
            if isOneLine {
                HStack(spacing: 8) {
                    codeText
                    copyButton {
                        copyGlyph(size: 14, tint: Palette.textDim)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .padding(.vertical, 3)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if let language, !language.isEmpty {
                            Text(language)
                                .font(Typography.app(11.5))
                                .foregroundStyle(Palette.textDim)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        // An acting control: ink, like the file card's actions.
                        copyButton {
                            HStack(spacing: 4) {
                                copyGlyph(size: 11, tint: Palette.text)
                                Text(copied ? "Copied" : "Copy")
                                    .font(Typography.app(12, .semibold))
                                    .foregroundStyle(copied ? Palette.done : Palette.text)
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                    }
                    codeText
                }
                .padding(.horizontal, 10)
                .padding(.top, 7)
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(syntax.map { Color(hex: $0.codeBackground) } ?? Palette.groundMachine, in: Self.shape)
        .overlay(Self.shape.strokeBorder(syntax.map { Color(hex: $0.codeBorder) } ?? Palette.hairline, lineWidth: 1))
        .task(id: highlightKey) {
            guard let highlightKey, highlighted?.key != highlightKey else { return }
            let text = await ChatCodeHighlights.highlight(highlightKey)
            guard !Task.isCancelled else { return }
            highlighted = Highlighted(key: highlightKey, text: text)
        }
    }

    private var codeText: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            codeLine
                .font(textScale == 1 ? GramType.code : Typography.machine(13 * textScale))
                .lineSpacing(GramType.codeLineSpacing * textScale)
                .foregroundStyle(syntax.map { Color(hex: $0.codeText) } ?? Palette.text)
                .fixedSize()
                .accessibilityIdentifier("gram-code-text")
        }
    }

    private var codeLine: Text {
        guard let key = highlightKey else { return Text(code) }
        if let highlighted, highlighted.key == key { return Text(highlighted.text) }
        // A block drawn again reads its highlight at once, with no plain frame first.
        if let cached = ChatCodeHighlights.cached(key) { return Text(cached) }
        return Text(code)
    }

    private func copyGlyph(size: CGFloat, tint: Color) -> some View {
        Image(systemName: copied ? "checkmark" : "doc.on.doc")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(copied ? Palette.done : tint)
    }

    private func copyButton<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Button(action: { receipt.record(code) }, label: label)
            .buttonStyle(.plain)
            .accessibilityLabel(Text(copied ? "Copied" : "Copy code"))
            .accessibilityIdentifier("gram-code-copy")
    }
}

// MARK: - Attachments

private func sizeLabel(_ byteCount: Int?) -> String? {
    byteCount.map { GramFile.displaySize(of: UInt64(max(0, $0))) }
}

/// A download the reader asked for (an open or a save), drawn on its card as the composer's
/// upload ring and spoken as the card's value. `fraction` is nil while the size is unknown,
/// and the ring spins.
struct GramCardDownload: Equatable {
    var fraction: Double?
    /// "Downloading, 1.2 MB of 3.4 MB", or "Downloading" while the total is unknown.
    var spoken: String

    /// The owner's download: `gram.get_file`'s ONE base64 reply, so `progress` counts reply
    /// bytes, about 4/3 of the file (`GramFile.downloadedLabel` scales the spoken figure back).
    /// No measurement spins the ring rather than drawing a share that nothing drives.
    static func reply(_ progress: (received: Int, total: Int)?, fileSize: UInt64) -> GramCardDownload {
        guard let p = progress,
              let label = GramFile.downloadedLabel(received: p.received, total: p.total, fileSize: fileSize)
        else {
            return GramCardDownload(fraction: nil, spoken: "Downloading")
        }
        return GramCardDownload(fraction: min(1, Double(p.received) / Double(p.total)),
                                spoken: "Downloading, \(label)")
    }

    /// The guest's download: `gram.get_file_chunk` pieces, so `progress` is in file bytes.
    static func chunked(_ progress: (received: Int, total: Int)?) -> GramCardDownload {
        guard let p = progress, p.total > 0 else {
            return GramCardDownload(fraction: nil, spoken: "Downloading")
        }
        let size = { GramFile.displaySize(of: UInt64(max(0, $0))) }
        return GramCardDownload(fraction: min(1, Double(p.received) / Double(p.total)),
                                spoken: "Downloading, \(size(p.received)) of \(size(p.total))")
    }
}

/// An attached image: the picture once the feed has fetched it, else a placeholder naming
/// the file. The whole card is the Open button; Save to Files is in the message's context
/// menu and the card's accessibility actions. The card keeps the spec's shape until the
/// picture is known, then takes the picture's (see `GramThumbnails.boxSize`).
struct GramImageCard: View {
    let name: String
    let byteCount: Int?
    let thumbnail: UIImage?
    let download: GramCardDownload?
    let onOpen: () -> Void
    let onSave: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let box = GramThumbnails.boxSize(for: thumbnail?.size, in: GramCardMetrics.imageSize(sizeClass))
        let shape = RoundedRectangle(cornerRadius: GramBubble.radius, style: .continuous)
        Button(action: onOpen) {
            // min(box width, available width), with the height following the box's aspect
            // ratio: the clear base takes the proposed width (capped below) and the picture
            // fills it from the top.
            Color.clear
                .aspectRatio(box.width / box.height, contentMode: .fit)
                .overlay(alignment: .top) { picture }
                .clipped()
                .overlay {
                    // The placeholder draws its own ring in place of its glyph.
                    if let download, thumbnail != nil {
                        ring(download)
                            .padding(9)
                            .background(Palette.surface.opacity(0.82), in: Circle())
                    }
                }
                .frame(maxWidth: box.width)
                .clipShape(shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(["Open \(name)", sizeLabel(byteCount)].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(download?.spoken ?? "")
        .accessibilityIdentifier("gram-attachment-open")
        .accessibilityAction(named: "Save to Files", onSave)
    }

    @ViewBuilder
    private var picture: some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Palette.surfaceRaised
                VStack(spacing: 8) {
                    if let download {
                        ring(download)
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 28))
                            .foregroundStyle(Palette.textFaint)
                    }
                    (Text(name).foregroundStyle(Palette.textDim)
                        + Text(sizeLabel(byteCount).map { " · \($0)" } ?? "").foregroundStyle(Palette.textFaint))
                        .font(Typography.app(13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 12)
                }
            }
        }
    }

    private func ring(_ download: GramCardDownload) -> some View {
        TransferRing(progress: download.fraction).frame(width: 28, height: 28)
    }
}

/// Image cards' decoded pictures, kept in memory by message id so a row the feed rebuilds
/// draws its picture on its first frame instead of decoding it again.
enum GramThumbnails {
    /// The narrowest and widest shapes a picture card takes; a picture beyond them is
    /// cropped, so a tall screenshot or a panorama never draws as a sliver.
    static let minAspect: CGFloat = 3.0 / 4.0
    static let maxAspect: CGFloat = 4

    private static let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    static func cached(id: String) -> UIImage? {
        memory.object(forKey: id as NSString)
    }

    static func remove(id: String) {
        memory.removeObject(forKey: id as NSString)
    }

    static func removeAll() {
        memory.removeAllObjects()
    }

    /// The card's size cap for a picture of `size`: the spec while the picture is unknown,
    /// then the picture's shape (clamped to `minAspect`...`maxAspect`) as large as fits in
    /// the spec's width and height.
    static func boxSize(for size: CGSize?, in spec: CGSize) -> CGSize {
        guard let size, size.width > 0, size.height > 0 else { return spec }
        let aspect = min(max(size.width / size.height, minAspect), maxAspect)
        let width = min(spec.width, spec.height * aspect)
        return CGSize(width: width, height: width / aspect)
    }

    /// The picture in the file at `url`, decoded off the main thread at the pixel size a
    /// card of at most `spec` points shows it at, and kept under `id`. nil when the file is
    /// not a decodable image, or the session ended while decoding (sign-out wipes this
    /// cache with the downloads, and a late decode must not refill it).
    static func load(id: String, url: URL, spec: CGSize, scale: CGFloat) async -> UIImage? {
        if let hit = cached(id: id) { return hit }
        let epoch = GramView.Downloads.currentEpoch
        let image = await Task.detached(priority: .userInitiated) {
            decode(url: url, spec: spec, scale: scale)
        }.value
        guard let image, GramView.Downloads.currentEpoch == epoch else { return nil }
        memory.setObject(image, forKey: id as NSString,
                         cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0)
        return image
    }

    /// Downsampled with ImageIO, so a large photo is never decoded at full size: the
    /// longest side is what filling the picture's card box needs, never more than the
    /// file's own.
    private static func decode(url: URL, spec: CGSize, scale: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              pixelWidth > 0, pixelHeight > 0
        else { return nil }
        // EXIF orientations 5-8 turn the picture a quarter: it draws with its sides swapped.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let drawn = (5...8).contains(orientation)
            ? CGSize(width: pixelHeight, height: pixelWidth)
            : CGSize(width: pixelWidth, height: pixelHeight)
        let box = boxSize(for: drawn, in: spec)
        let fill = max(box.width / drawn.width, box.height / drawn.height)
        let longest = max(drawn.width, drawn.height)
        let maxPixels = max(1, min(longest, (longest * fill * scale).rounded(.up)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// An attached file: a document icon labelled with the extension, the name and
/// "<kind> · <size>". The whole card is the Open button; Save to Files is in the message's
/// context menu and the card's accessibility actions (none where the page cannot save: the
/// guest's). A download the reader started draws as a ring on the icon. On its own it is an
/// agent card (bubble fill, card radius, the whole width its message's `gramBubbleWidth` cap
/// offers); `embedded` draws it inside a card that has text above it, so it has no background
/// or corners of its own and opens with the hairline that divides the two (the caller leaves
/// 9 pt between its text and this).
struct GramFileCard: View {
    let name: String
    let kind: String
    let byteCount: Int?
    let download: GramCardDownload?
    let onOpen: () -> Void
    let onSave: (() -> Void)?
    var embedded = false
    /// The page's UI-test handle: the inbox and Saved share one, the guest's is per message.
    var identifier = GramFileCard.ownerIdentifier
    static let ownerIdentifier = "gram-attachment-open"

    /// The file's kind as Files names it ("ZIP archive"), from its extension, then its mime.
    static func kind(name: String, mime: String) -> String {
        let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? UTType(mimeType: mime)
        return type?.localizedDescription ?? ""
    }

    var body: some View {
        if embedded {
            card
        } else {
            card
                .frame(maxWidth: .infinity)
                .background(GramBubble.inFill)
                .clipShape(RoundedRectangle(cornerRadius: GramBubble.radius, style: .continuous))
        }
    }

    private var detail: String {
        [kind.isEmpty ? nil : kind, sizeLabel(byteCount)].compactMap { $0 }.joined(separator: " · ")
    }

    private var card: some View {
        Button(action: onOpen) {
            VStack(spacing: 0) {
                if embedded { rule }
                HStack(spacing: 10) {
                    GramDocumentIcon(label: String((name as NSString).pathExtension.uppercased().prefix(4)))
                        .overlay {
                            if let download {
                                TransferRing(progress: download.fraction)
                                    .frame(width: 22, height: 22)
                                    .padding(4)
                                    .background(Palette.surfaceRaised, in: Circle())
                            }
                        }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(name)
                            .font(Typography.app(15, .semibold))
                            .foregroundStyle(Palette.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !detail.isEmpty {
                            Text(detail)
                                .font(Typography.app(13))
                                .foregroundStyle(Palette.textDim)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.top, 9)
                .padding(.bottom, 10)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(name)")
        .accessibilityValue(download?.spoken ?? detail)
        .accessibilityIdentifier(identifier)
        .accessibilityActions {
            if let onSave { Button("Save to Files", action: onSave) }
        }
    }

    private var rule: some View {
        Rectangle().fill(Palette.hairline).frame(height: 1)
    }
}

/// An attachment the store's size budget expired (herdr#298): the file card's place and
/// shape, but nothing to open. A muted icon, the file's name and "No longer available ·
/// <size>"; not a button, no download ring, no Save to Files. Image or file alike: there is
/// no picture to show. `embedded` and `identifier` as in `GramFileCard`.
struct GramExpiredFileCard: View {
    let name: String
    let byteCount: Int?
    var embedded = false
    var identifier = GramExpiredFileCard.ownerIdentifier
    static let ownerIdentifier = "gram-attachment-expired"

    var body: some View {
        if embedded {
            card
        } else {
            card
                .frame(maxWidth: .infinity)
                .background(GramBubble.inFill)
                .clipShape(RoundedRectangle(cornerRadius: GramBubble.radius, style: .continuous))
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            if embedded { Rectangle().fill(Palette.hairline).frame(height: 1) }
            HStack(spacing: 10) {
                Image(systemName: "clock.badge.xmark")
                    .font(.system(size: 22))
                    .foregroundStyle(Palette.textFaint)
                    .frame(width: 32, height: 40)
                VStack(alignment: .leading, spacing: 0) {
                    Text(name)
                        .font(Typography.app(15, .semibold))
                        .foregroundStyle(Palette.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text((["No longer available", sizeLabel(byteCount)] as [String?]).compactMap { $0 }
                        .joined(separator: " · "))
                        .font(Typography.app(13))
                        .foregroundStyle(Palette.textFaint)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), no longer available")
        .accessibilityIdentifier(identifier)
    }
}

/// A 32 x 40 page with a folded-looking corner and the file's extension at its foot.
private struct GramDocumentIcon: View {
    let label: String

    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3,
                               bottomTrailingRadius: 3, topTrailingRadius: 9, style: .continuous)
            .fill(Palette.textDim)
            .frame(width: 32, height: 40)
            .overlay(alignment: .bottom) {
                Text(label)
                    .font(Typography.app(8, .bold))
                    .foregroundStyle(Palette.ground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 2)
                    .padding(.bottom, 6)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Feed marks

/// The saved mark, drawn like an iMessage tapback on the bubble's top corner: a violet
/// 32 x 30 badge with a white bookmark and two trailing dots, all ringed in the ground.
/// The feed places it (overlay top-trailing, offset x +15, y -17) and gives that bubble
/// 12 pt more room above.
struct GramSavedBadge: View {
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Circle().fill(GramBubble.outFill)
                .frame(width: 4.5, height: 4.5)
                .gramRing(Palette.ground, width: 1.5)
                .offset(x: -5, y: 7)
            Circle().fill(GramBubble.outFill)
                .frame(width: 9, height: 9)
                .gramRing(Palette.ground, width: 2)
                .offset(x: 0, y: 2)
            Image(systemName: "bookmark.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.onAccent)
                .frame(width: 32, height: 30)
                .background(GramBubble.outFill, in: Capsule())
                .background(Capsule().fill(Palette.ground).padding(-2))
        }
        .frame(width: 32, height: 30)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Saved")
        .accessibilityIdentifier("gram-saved-badge")
    }
}

/// A centred time mark between messages: "**Today** 14:32".
struct GramTimeSeparator: View {
    let date: Date

    var body: some View {
        let parts = GramDates.separator(for: date)
        (Text(parts.day).font(Typography.app(11, .semibold)) + Text(" \(parts.time)").font(Typography.app(11)))
            .foregroundStyle(Palette.textFaint)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The amber "N unread" rule above the first unread message.
struct GramUnreadRule: View {
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            line
            Text("\(count) unread")
                .font(Typography.app(11, .semibold))
                .foregroundStyle(Palette.waiting)
                .lineLimit(1)
                .fixedSize()
            line
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) unread")
        .accessibilityIdentifier("gram-unread-rule")
    }

    private var line: some View {
        Rectangle().fill(Palette.waiting.opacity(0.45)).frame(height: 1)
    }
}

// MARK: - Sidebar

/// One conversation in the iPad/Mac sidebar, like a Messages row: stacked avatars of the
/// latest senders (or a symbol, e.g. Saved's bookmark), the title and time, and a two-line
/// preview. Selected rows fill with your bubble's violet; unread ones get the amber dot.
/// The row is only the label: the caller wraps it in a Button and owns its identifier and
/// selected trait. `avatarNames` are most recent first.
struct GramConversationRow: View {
    let title: String
    let avatarNames: [String]
    let systemImage: String?
    let preview: AttributedString
    let time: Date?
    let unread: Bool
    let selected: Bool

    private static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    private var secondary: Color { selected ? Palette.onAccentDim : Palette.textDim }

    var body: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(Typography.app(16, .semibold))
                        .foregroundStyle(selected ? Palette.onAccent : Palette.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let time {
                        Text(GramDates.rowTime(for: time))
                            .font(Typography.app(14))
                            .foregroundStyle(selected ? Palette.onAccentDim : Palette.textFaint)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                Text(preview)
                    .font(GramType.preview)
                    .lineSpacing(GramType.previewLineSpacing)
                    .foregroundStyle(secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, minHeight: 74, maxHeight: 74)
        .background {
            if selected { Self.shape.fill(GramBubble.outFill) }
        }
        .overlay(alignment: .leading) {
            if unread {
                Circle().fill(Palette.waiting)
                    .frame(width: 10, height: 10)
                    .padding(.leading, 7)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Self.shape)
        .accessibilityElement(children: .combine)
        .accessibilityValue(unread ? "Unread" : "")
    }

    @ViewBuilder
    private var avatar: some View {
        let names = distinctAgentNames(avatarNames, limit: 2)
        if let systemImage {
            symbolAvatar(systemImage)
        } else if names.count == 2 {
            // Two 29 pt avatars stacked corner to corner in a 44 pt square; the front one is
            // ringed in the row's own fill so it cuts cleanly out of the back one.
            ZStack(alignment: .topLeading) {
                GramAvatar(name: names[0], size: 29)
                GramAvatar(name: names[1], size: 29)
                    .gramRing(selected ? GramBubble.outFill : Palette.ground, width: 2)
                    .offset(x: 15, y: 15)
            }
            .frame(width: 44, height: 44, alignment: .topLeading)
        } else if let name = names.first {
            GramAvatar(name: name, size: 44)
        } else {
            symbolAvatar("bubble.left.and.bubble.right.fill")
        }
    }

    private func symbolAvatar(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(Palette.brand)
            .frame(width: 44, height: 44)
            .background(Palette.surfaceRaised, in: Circle())
            .accessibilityHidden(true)
    }
}
