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
    /// Dismiss on the couldn't-start note: the note goes, the suggestion stays open.
    let onDismissProblem: () -> Void
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

    /// A plain card ("Topics · A, revised"): the question, the agent's reason, how many earlier
    /// messages come along, then "Not now" as a word and "Start" as the one filled button. A
    /// start that failed leaves one line under it with a red dot and "Dismiss".
    private var openCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                (Text("New subject? Start a topic: ") + Text(title).font(Typography.app(15 * textScale, .semibold)))
                    .font(Typography.app(15 * textScale))
                    .foregroundStyle(Palette.text)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("chat-topic-suggestion-title")
                if !suggestion.reason.isEmpty {
                    Text(suggestion.reason)
                        .font(Typography.app(14 * textScale)).foregroundStyle(Palette.textDim)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if suggestion.messageCount > 0 {
                    Text(Self.carried(suggestion.messageCount)).font(Typography.app(13 * textScale))
                        .foregroundStyle(Palette.textFaint)
                        .accessibilityIdentifier("chat-topic-suggestion-count")
                }
                if interactive {
                    HStack(spacing: 18) {
                        Spacer(minLength: 0)
                        Button(action: onDismiss) {
                            Text("Not now").font(Typography.app(14 * textScale, .medium))
                                .foregroundStyle(Palette.textDim)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                        .opacity(busy ? 0.5 : 1)
                        .accessibilityIdentifier("chat-topic-suggestion-dismiss")
                        Button(action: onStart) {
                            Text("Start").font(Typography.app(14 * textScale, .semibold))
                                .foregroundStyle(Palette.ground)
                                .padding(.horizontal, 16).frame(height: 32)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.text))
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                        .opacity(busy ? 0.5 : 1)
                        .accessibilityIdentifier("chat-topic-suggestion-start")
                    }
                    .padding(.top, -2).padding(.bottom, -6)
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline, lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat-topic-suggestion-\(id)")
            if let problem {
                problemNote(problem)
            }
        }
    }

    /// "<why it couldn't start>   Dismiss": one line, the one red dot, no card.
    private func problemNote(_ problem: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Palette.died).frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 2 }
            Text(problem).font(Typography.app(14 * textScale)).foregroundStyle(Palette.textDim)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("chat-topic-suggestion-problem")
            Button(action: onDismissProblem) {
                Text("Dismiss").font(Typography.app(14 * textScale, .medium)).foregroundStyle(Palette.text)
                    .padding(.leading, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat-topic-suggestion-problem-dismiss")
        }
        .padding(.top, -12).padding(.bottom, -12)
        .accessibilityElement(children: .contain)
    }

    /// "Continued in topic <title>": a centred line with the title underlined as a link;
    /// tapping it opens the topic.
    @ViewBuilder
    private var continued: some View {
        let linked = onOpenTopic != nil && suggestion.topicID != nil
        let label = (Text("Continued in topic ")
            + Text(title).font(Typography.app(13.5 * textScale, .medium)).foregroundColor(Palette.text)
                .underline(linked, color: Palette.hairline))
            .font(Typography.app(13.5 * textScale)).foregroundStyle(Palette.textDim)
            .lineLimit(1)
            .frame(minHeight: 30)
            .frame(maxWidth: .infinity)
        if let onOpenTopic, let topicID = suggestion.topicID {
            Button { onOpenTopic(topicID) } label: { label.contentShape(Rectangle()) }
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
