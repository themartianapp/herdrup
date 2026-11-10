import UIKit

/// The scroll view owns the tail offset; row anchors remain ScrollViewReader's job.
/// A weak reference avoids retaining a kept-alive pane after its owner removes it.
@MainActor
final class ChatScrollPosition {
    weak var view: UIScrollView?

    private var bottomOffset: CGFloat? {
        guard let view else { return nil }
        return max(-view.adjustedContentInset.top,
                   view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
    }

    var isAtBottom: Bool {
        guard let view, let bottomOffset else { return false }
        return view.contentOffset.y >= bottomOffset - 8
    }

    /// The chat's vertical scroll offset, or nil before the scroll view is known. The up arrow
    /// compares it with where its last jump settled (`TranscriptPreviousMine.LastJump`).
    var offset: CGFloat? { view?.contentOffset.y }

    func jumpToLatest() {
        guard let view, let bottomOffset, abs(view.contentOffset.y - bottomOffset) > 0.5 else { return }
        view.setContentOffset(CGPoint(x: view.contentOffset.x, y: bottomOffset), animated: false)
    }

    /// The tail follow right after a Chat send: the offset springs to the tail on the new
    /// bubble's spring (`ChatSendMotion`), so the list and the bubble move together. The model
    /// offset is final at once, so the next sample finds nothing to do unless the tail moved
    /// again (the composer shrinking under it), and then the glide carries on from where it is.
    func glideToLatest() {
        guard let view, let bottomOffset, abs(view.contentOffset.y - bottomOffset) > 0.5 else { return }
        UIView.animate(springDuration: ChatSendMotion.scrollSpringDuration,
                       bounce: ChatSendMotion.scrollSpringBounce,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            view.contentOffset = CGPoint(x: view.contentOffset.x, y: bottomOffset)
        }
    }

    /// Centres `rect` (window coordinates, as SwiftUI's `.global` frames are) in the visible
    /// part of the scroll view, clamped to its scrollable range. The search reveal: on iOS 27
    /// `ScrollViewProxy.scrollTo` no longer moves the chat to a result's id inside a row.
    /// False when there is no scroll view yet.
    @discardableResult
    func reveal(_ rect: CGRect) -> Bool {
        guard let view, view.window != nil, let bottomOffset else { return false }
        let target = view.convert(rect, from: nil)
        let inset = view.adjustedContentInset
        let visibleHeight = view.bounds.height - inset.top - inset.bottom
        let centred = target.midY - inset.top - visibleHeight / 2
        let offset = min(max(centred, -inset.top), bottomOffset)
        guard abs(view.contentOffset.y - offset) > 0.5 else { return true }
        view.setContentOffset(CGPoint(x: view.contentOffset.x, y: offset), animated: false)
        return true
    }

    /// Scrolls up until the top of `rect` (window coordinates) sits `margin` below the top of
    /// the visible part, when it would otherwise be above it: now, or once the chat is at its
    /// tail when `atTail` (a chat following its latest row is about to go there). True when
    /// it moved the chat.
    @discardableResult
    func revealTop(_ rect: CGRect, margin: CGFloat, atTail: Bool) -> Bool {
        guard let view, view.window != nil, let bottomOffset else { return false }
        let inset = view.adjustedContentInset
        let wanted = max(view.convert(rect, from: nil).minY - inset.top - margin, -inset.top)
        guard wanted < (atTail ? bottomOffset : view.contentOffset.y) - 0.5 else { return false }
        view.setContentOffset(CGPoint(x: view.contentOffset.x, y: wanted), animated: false)
        return true
    }

    /// The jump button's glide to the tail. From more than two screens away it first snaps to
    /// one screen above the tail, so the glide is always one screen long. The model offset is
    /// final at once, so `isAtBottom` holds immediately and the per-tick `jumpToLatest` finds
    /// nothing to do instead of fighting the animation. Reduce Motion jumps.
    func animateToLatest() {
        guard let view, let bottomOffset, abs(view.contentOffset.y - bottomOffset) > 0.5 else { return }
        guard !UIAccessibility.isReduceMotionEnabled else { return jumpToLatest() }
        // Stops a fling still decelerating, which would otherwise carry on against the glide.
        view.setContentOffset(view.contentOffset, animated: false)
        if bottomOffset - view.contentOffset.y > 2 * view.bounds.height {
            view.setContentOffset(CGPoint(x: view.contentOffset.x, y: bottomOffset - view.bounds.height), animated: false)
        }
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            view.contentOffset = CGPoint(x: view.contentOffset.x, y: bottomOffset)
        }
    }
}
