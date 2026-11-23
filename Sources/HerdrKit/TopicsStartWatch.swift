import Foundation

/// Topics a suggestion's Start opened, and which of them failed to start (herdrup#811, #814).
///
/// A topic that ends before its first turn sends `start_failed` (`agent.topics.changed`), and
/// the reader on it goes back to the Inbox, where the suggestion is open again. That event
/// is not enough on its own: a guest has no event stream, and the owner's page can be between
/// subscriptions when it arrives (Start switches from Chat to Topics). So every answered list
/// decides too, but only for a topic that has never been seen to start. omp also leaves live
/// topics out of its list: after a parent-session switch, and a topic whose turn settled
/// without a parked ref. So a topic seen with a turn is no longer watched, and a failure read
/// from a list lasts only until a later list has the topic again. `start_failed` is the
/// reliable signal and stays.
public struct TopicsStartWatch: Sendable, Equatable {
    /// Topics a Start (or its "Continued in topic" line) opened, not yet seen with a turn.
    private var opened: Set<String> = []
    /// `start_failed`: for good.
    private var failed: Set<String> = []
    /// Gone from a list before a turn: until a later list has them again.
    private var missing: Set<String> = []

    public init() {}

    /// A Start (or its "Continued in topic" line) opened this listed topic. Watched only if it
    /// has not been seen to start: one that already ran a turn is not a new start (herdrup#816).
    public mutating func didOpen(_ topic: AgentTopic) {
        guard !topic.id.isEmpty, topic.turns == 0, topic.state != .running else { return }
        opened.insert(topic.id)
    }

    /// `start_failed` for this topic.
    public mutating func didFail(_ topicID: String) {
        guard !topicID.isEmpty else { return }
        failed.insert(topicID)
    }

    /// The topic failed to start, so a late Start must not open it.
    public func hasFailed(_ topicID: String) -> Bool { failed.contains(topicID) || missing.contains(topicID) }

    /// After an answered list: the selected topic, when a Start opened it, it has never been
    /// seen with a turn, and the list no longer has it. It ended before its first turn, whether
    /// or not `start_failed` reached this page. Nil when the reader stays where they are.
    public mutating func endedSelection(selected: String?, listed topics: [AgentTopic]) -> String? {
        for topic in topics {
            missing.remove(topic.id)
            // Seen to start: a list that leaves it out later says nothing about its start.
            if topic.turns > 0 || topic.state == .running { opened.remove(topic.id) }
        }
        guard let selected, opened.contains(selected), !topics.contains(where: { $0.id == selected }) else {
            return nil
        }
        missing.insert(selected)
        opened.remove(selected)
        return selected
    }
}
