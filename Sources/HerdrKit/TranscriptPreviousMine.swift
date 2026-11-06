import Foundation

/// The Chat's up arrow (`chat-jump-previous-mine`): the owner's previous message above what the
/// reader sees, one further up per tap (owner decision 2026-11-06). It never stops at a guest's
/// prompt, nor, on a host that keeps turn origins, at one herdr marked as someone else's
/// (gitmoot, a script, another agent). Pure, so the choice is tested without a view.
public enum TranscriptPreviousMine {
    public enum Step: Equatable, Sendable {
        /// Scroll to this turn's prompt.
        case jump(turnID: String)
        /// No such turn is loaded above: fetch the next older page and ask again.
        case loadOlder
        /// No such turn above, and no older history: the button hides.
        case none
    }

    /// The turn is one the button stops at: a prompt the owner wrote, with a time (the chat
    /// draws no prompt row without one), and, when `honoursOrigin`, not marked "other". Without
    /// turn origins on the host every owner-authored prompt counts.
    public static func stops(at turn: TranscriptTurn, honoursOrigin: Bool) -> Bool {
        guard turn.startMs > 0, turn.promptAuthor == .owner else { return false }
        return !honoursOrigin || turn.promptOrigin != .other
    }

    /// What a tap does. `turns` are oldest first, as loaded; the search runs from just above
    /// the turn `above` (exclusive) towards the oldest. `above` is the oldest turn whose prompt
    /// is on screen or below it; nil (every drawn prompt is above the screen) or an id no
    /// longer loaded searches every loaded turn. `hasOlder`: the server has older pages.
    public static func step(in turns: [TranscriptTurn], above: String?, hasOlder: Bool,
                            honoursOrigin: Bool) -> Step {
        let end = above.flatMap { id in turns.firstIndex { $0.id == id } } ?? turns.count
        if let turn = turns[..<end].last(where: { stops(at: $0, honoursOrigin: honoursOrigin) }) {
            return .jump(turnID: turn.id)
        }
        return hasOlder ? .loadOlder : .none
    }

    /// The turn the up arrow last scrolled to, and the scroll offset that jump left the chat
    /// at. It stands for "where the reader is" only while the chat is still there: anything
    /// else that moves the chat (a drag, search, Jump to latest, an older page's anchor) leaves
    /// another offset and so retires it, without each mover having to know about it.
    public struct LastJump: Equatable, Sendable {
        public let turnID: String
        /// The offset once the jump's scroll settled; nil while it is still under way, when a
        /// quick second tap must still go one further up.
        public var offset: Double?

        /// How far the chat may drift (layout rounding, a row settling) and still be where
        /// the jump left it.
        public static let tolerance = 4.0

        public init(turnID: String, offset: Double? = nil) {
            self.turnID = turnID
            self.offset = offset
        }

        /// The chat is still where this jump put it (or the jump has not settled yet).
        public func holds(at currentOffset: Double?) -> Bool {
            guard let offset else { return true }
            guard let currentOffset else { return false }
            return abs(currentOffset - offset) <= Self.tolerance
        }
    }

    /// The `above` a tap passes to `step`: the oldest prompt on screen (`boundary`), or the last
    /// jump's turn when that is older and the chat has not moved since (its scroll may not have
    /// settled, so the screen does not show it yet). A jump the chat has moved away from is
    /// ignored: the reader is wherever the screen says.
    public static func searchStart(in turns: [TranscriptTurn], boundary: String?, lastJump: LastJump?,
                                   offset: Double?) -> String? {
        guard let lastJump, lastJump.holds(at: offset),
              let lastIndex = turns.firstIndex(where: { $0.id == lastJump.turnID }) else { return boundary }
        guard let boundary, let boundaryIndex = turns.firstIndex(where: { $0.id == boundary }) else {
            return lastJump.turnID
        }
        return lastIndex < boundaryIndex ? lastJump.turnID : boundary
    }
}
