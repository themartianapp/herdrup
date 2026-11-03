import UIKit

/// FILES DROPPED ANYWHERE ON A TERMINAL attach to that pane's composer (herdrup#575).
///
/// The composer bar was the only drop target, so a file dragged from Finder or Files onto
/// the terminal — the biggest thing on screen, and where the reader is looking — was
/// refused. The pane hands its terminal one of these, and the terminal surface's
/// `TerminalDropTarget` routes a drop to `onDrop`, which is the pane's composer drop path:
/// the same staging, size cap, count cap, early upload and notes as a drop on the bar.
///
/// A drop that carries no file (plain text, a web link) is not offered to the terminal
/// at all, so it shows no highlight and nothing happens, exactly as before; SwiftTerm has
/// no text drop of its own to preserve. nil on `LiveTerminalView` means the surface takes
/// no drops: the pane is in Chat, or (for a guest) the composer cannot attach right now.
struct TerminalFileDrop {
    /// The drag entered (true) or left, ended or dropped (false): drives the highlight.
    let onTargetChange: (Bool) -> Void
    /// The dropped FILES (never the text-only items beside them), in drag order. Returns
    /// whether the composer took the drop.
    let onDrop: ([NSItemProvider]) -> Bool

    /// The providers in a drag that a composer would stage, in order. Text, links and
    /// contact cards are left out — the composer's paste rule (`PastedFile`), so a drop
    /// and a paste can never disagree about what a file is.
    static func files(in providers: [NSItemProvider]) -> [NSItemProvider] {
        providers.filter { PastedFile.stagingType(of: $0) != nil }
    }
}

/// The UIKit drop target on the terminal surface. UIKit, not a SwiftUI `.onDrop` on the
/// representable: the surface is a SwiftTerm scroll view whose pans and long presses must
/// stay untouched, and an interaction on the view itself is found by UIKit's own hit test
/// wherever the terminal is, with no SwiftUI geometry in between.
///
/// Touching only the item METADATA until the drop lands (`registeredTypeIdentifiers`):
/// loading content before `performDrop` is not allowed, and is not needed to decide.
@MainActor
final class TerminalDropTarget: NSObject, UIDropInteractionDelegate {
    var handler: TerminalFileDrop? {
        // Turned off mid-drag (the pane switched to Chat): the old handler clears its
        // highlight, since the new nil one cannot.
        didSet {
            guard handler == nil, targeted else { return }
            targeted = false
            oldValue?.onTargetChange(false)
        }
    }
    private var targeted = false

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        handler != nil && !TerminalFileDrop.files(in: session.items.map(\.itemProvider)).isEmpty
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: handler == nil ? .cancel : .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) {
        setTargeted(true)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
        setTargeted(false)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
        setTargeted(false)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        setTargeted(false)
        let files = TerminalFileDrop.files(in: session.items.map(\.itemProvider))
        guard !files.isEmpty else { return }
        _ = handler?.onDrop(files)
    }

    /// Reports only CHANGES, so a drag that hovers sends the pane one update on entry and
    /// one on exit rather than a body pass per `sessionDidUpdate`.
    private func setTargeted(_ value: Bool) {
        guard targeted != value else { return }
        targeted = value
        #if DEBUG
        if value { TerminalInteractionHarness.noteTerminalDropTargeted() }
        #endif
        handler?.onTargetChange(value)
    }
}
