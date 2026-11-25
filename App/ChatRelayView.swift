import HerdrKit
import SwiftUI

/// A message the Inbox handed to a topic, or a topic to the Inbox (`relay`): drawn like the
/// agent's text, on the left with no card or colour, under a small "From Inbox" / "From topic
/// Trip" line, and folded after about six lines with "Show all".
struct ChatRelayView: View {
    let relay: TranscriptRelay

    @Environment(\.chatTextScale) private var textScale
    @State private var expanded = false
    /// The body's whole height, measured unfolded.
    @State private var fullHeight: CGFloat = 0

    /// About six lines of a reply's 16 pt paragraphs with their spacing.
    private var foldHeight: CGFloat { 6 * 24 * textScale }
    private var folds: Bool { fullHeight > foldHeight + 4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(relay.label)
                .font(Typography.app(12 * textScale)).foregroundStyle(Palette.textFaint)
                .lineLimit(1)
                .accessibilityIdentifier("chat-relay-from")
            ChatMarkdownView(markdown: relay.text)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                .frame(height: folds && !expanded ? foldHeight : nil, alignment: .top)
                .clipped()
            if folds {
                Button(expanded ? "Show less" : "Show all") { expanded.toggle() }
                    .font(Typography.app(13 * textScale, .semibold)).foregroundStyle(Palette.textDim)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat-relay-toggle")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-relay")
    }
}
