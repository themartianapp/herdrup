import HerdrKit
import SwiftUI

// An agent's topic suggestion in the Inbox chat (proposal 3, "work where the things are", owner
// pick 2026-11-22): a quiet line marks where the new subject began, and at the suggestion one
// neutral card asks to start a topic. The agent picked the messages that come along; the card
// only says how many. There is no message selection. After Start the topic opens and the Inbox
// keeps one line, "Continued in topic <title>"; Not now leaves one quiet line too.

/// Where an open suggestion's subject began, above the first message the agent picked:
/// "IPAD BUILD TIMES STARTS HERE" between two hairlines.
struct ChatTopicSuggestionMark: View {
    let suggestionID: String
    let title: String

    @Environment(\.chatTextScale) private var textScale

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Palette.hairlineQuiet).frame(height: 1)
            Text("\(title.uppercased()) STARTS HERE")
                .font(Typography.app(11 * textScale, .semibold)).tracking(0.8)
                .foregroundStyle(Palette.textFaint)
                .lineLimit(1)
                .layoutPriority(1)
            Rectangle().fill(Palette.hairlineQuiet).frame(height: 1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat-topic-suggestion-mark-\(suggestionID)")
    }
}

/// One `topic_suggestion` entry. Open: the card with Start and Not now (anyone who can talk to
/// the agent, guests included). Accepted: "Continued in topic <title>", which opens the topic.
/// Dismissed: one faint line.
struct ChatTopicSuggestionCard: View {
    let id: String
    let suggestion: TranscriptTopicSuggestion
    /// Start or Not now is on its way.
    let busy: Bool
    let problem: String?
    /// The chat can act on suggestions (the agent's own conversation, not a topic's).
    let interactive: Bool
    let onStart: () -> Void
    let onDismiss: () -> Void
    /// Opens a topic by id; nil where topics cannot be opened from this chat.
    let onOpenTopic: ((String) -> Void)?

    @Environment(\.chatTextScale) private var textScale

    private var title: String { suggestion.title.isEmpty ? "Untitled topic" : suggestion.title }

    /// "12 earlier messages come along"; "1 earlier message comes along".
    static func carried(_ count: Int) -> String {
        count == 1 ? "1 earlier message comes along" : "\(count) earlier messages come along"
    }

    var body: some View {
        switch suggestion.state {
        case .open: openCard
        case .accepted: continued
        case .dismissed: dismissed
        case .unknown: EmptyView()
        }
    }

    private var openCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            (Text("New subject? Start a topic: ") + Text(title).font(Typography.app(15 * textScale, .semibold)))
                .font(Typography.app(15 * textScale))
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("chat-topic-suggestion-title")
            if !suggestion.reason.isEmpty {
                Text(suggestion.reason)
                    .font(Typography.app(13.5 * textScale)).foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if suggestion.messageCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "text.bubble").font(.system(size: 12, weight: .medium))
                    Text(Self.carried(suggestion.messageCount)).font(Typography.app(13 * textScale))
                }
                .foregroundStyle(Palette.textFaint)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chat-topic-suggestion-count")
            }
            if let problem {
                HStack(spacing: 6) {
                    Circle().fill(Palette.died).frame(width: 6, height: 6)
                    Text(problem).font(Typography.app(12.5 * textScale)).foregroundStyle(Palette.textDim)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chat-topic-suggestion-problem")
            }
            if interactive {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    button("Not now", primary: false, id: "chat-topic-suggestion-dismiss", action: onDismiss)
                    button("Start", primary: true, id: "chat-topic-suggestion-start", action: onStart)
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AskFormStyle.card)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-topic-suggestion-\(id)")
    }

    private func button(_ label: String, primary: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(Typography.app(14 * textScale, .semibold))
                .foregroundStyle(primary ? Palette.ground : Palette.text)
                .padding(.horizontal, 16).frame(minHeight: 36)
                .background(Capsule().fill(primary ? Palette.text : Palette.surfaceRaised))
                .overlay(Capsule().strokeBorder(primary ? Color.clear : Palette.hairline, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.5 : 1)
        .accessibilityIdentifier(id)
    }

    /// "Continued in topic <title>": a small neutral chip; tapping it opens the topic.
    @ViewBuilder
    private var continued: some View {
        let label = HStack(spacing: 6) {
            Image(systemName: "rectangle.stack").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textDim)
            (Text("Continued in topic ") + Text(title).font(Typography.app(13 * textScale, .semibold)))
                .font(Typography.app(13 * textScale)).foregroundStyle(Palette.textDim)
                .lineLimit(1)
            if onOpenTopic != nil, suggestion.topicID != nil {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.textFaint)
            }
        }
        .padding(.horizontal, 12).frame(minHeight: 30)
        .background(Capsule().fill(Palette.surface))
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .frame(maxWidth: .infinity)
        if let onOpenTopic, let topicID = suggestion.topicID {
            Button { onOpenTopic(topicID) } label: { label.contentShape(Capsule()) }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("chat-topic-continued-\(id)")
        } else {
            label
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chat-topic-continued-\(id)")
        }
    }

    /// One faint line: the suggestion was set aside, and by whom when it was not the reader.
    private var dismissed: some View {
        let who = suggestion.by.flatMap { $0 == "owner" || $0.isEmpty ? nil : $0 }
        return Text("Not now: \(title)" + (who.map { " · set aside by \($0)" } ?? ""))
            .font(Typography.app(12.5 * textScale)).foregroundStyle(Palette.textFaint)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .accessibilityIdentifier("chat-topic-suggestion-dismissed-\(id)")
    }
}
