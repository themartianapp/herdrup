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
}
