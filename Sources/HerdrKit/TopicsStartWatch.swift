import Foundation

/// Topics a suggestion's Start opened, and which of them failed to start (herdrup#811).
///
/// A topic that ends before its first turn sends `start_failed` (`agent.topics.changed`), and
/// the reader on it goes back to the Inbox, where the suggestion is open again. That event
/// is not enough on its own: a guest has no event stream, and the owner's page can be between
/// subscriptions when it arrives (Start switches from Chat to Topics). So every answered list
/// decides too. A topic Start opened that is no longer in the list has ended, and the reader
/// on it goes back to the Inbox. The lists come one at a time (`TopicsListRounds`): one that
/// leaves it out answered after the one that listed it when Start opened it.
public struct TopicsStartWatch: Sendable, Equatable {
    /// Topics a Start (or its "Continued in topic" line) opened.
    private var opened: Set<String> = []
    /// Topics that failed to start: `start_failed`, or gone from a list after a Start opened them.
    private var failed: Set<String> = []

    public init() {}

    /// A Start opened this topic: it was in the list.
    public mutating func didOpen(_ topicID: String) {
        guard !topicID.isEmpty else { return }
        opened.insert(topicID)
    }

    /// `start_failed` for this topic.
    public mutating func didFail(_ topicID: String) {
        guard !topicID.isEmpty else { return }
        failed.insert(topicID)
    }

    /// The topic failed to start, so a late Start must not open it.
    public func hasFailed(_ topicID: String) -> Bool { failed.contains(topicID) }

    /// After an answered list: the selected topic, when a Start opened it and the list no longer
    /// has it. It ended before its first turn, whether or not `start_failed` reached this page,
    /// and it is recorded as failed. Nil when the reader stays where they are.
    public mutating func endedSelection(selected: String?, listed ids: [String]) -> String? {
        guard let selected, opened.contains(selected), !ids.contains(selected) else { return nil }
        failed.insert(selected)
        opened.remove(selected)
        return selected
    }
}
