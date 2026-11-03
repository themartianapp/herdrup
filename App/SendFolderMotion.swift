import HerdrKit
import SwiftUI
import UIKit

// Sending a prompt in Chat and opening or closing an agent folder (owner request 2026-11-03;
// spec: fleet-tools state herdr-round5-20261029/motion-spec-send-folders.md). Herdrup Desktop
// draws the same motion from the same values. Presentation only: the prompt is sent and the
// folder state saved in the frame of the tap, whatever these animations do afterwards.

/// Whether these motions run at all. False in the DEBUG desktop-reference mock and under
/// `HERDR_DESKTOPREF_CAPTURE`, whose screenshots need every row at rest: those already run
/// with animations disabled (`RootView`), and a transition's own animation would slip past that.
private let sendFolderMotionAllowed: Bool = {
    #if DEBUG
    return !DesktopReferenceMock.holdsStill
        && ProcessInfo.processInfo.environment["HERDR_DESKTOPREF_CAPTURE"] != "1"
    #else
    return true
    #endif
}()

enum ChatSendMotion {
    /// The new outgoing bubble's entrance, the scroll that carries the list with it, and the
    /// composer's shrink when the send clears it.
    static let bubbleSpring = Animation.spring(response: 0.32, dampingFraction: 0.86)
    /// `bubbleSpring` for UIKit's scroll offset: a response of 0.32 s is a 0.32 s spring
    /// duration, and a damping fraction of 0.86 is a bounce of 0.14.
    static let scrollSpringDuration: TimeInterval = 0.32
    static let scrollSpringBounce: CGFloat = 0.14
    /// How long after a send the tail follow springs instead of jumping: until the bubble's
    /// row has been laid out and the spring has settled.
    static let scrollGlideWindow: CFTimeInterval = 0.6
    /// The Send press: down to this scale in 60 ms (ease-out), then a spring back to 1.
    static let pressScale: CGFloat = 0.88

    /// The bubble's entrance; under Reduce Motion a 120 ms cross-fade.
    static func bubble(reduceMotion: Bool) -> Animation? {
        guard sendFolderMotionAllowed else { return nil }
        return reduceMotion ? .easeInOut(duration: 0.12) : bubbleSpring
    }

    /// Clears a Chat composer for a send. The text changes at once (nothing animates it);
    /// the card's resize reads the transaction (`composerResize`) and shrinks on the bubble's
    /// spring. `inChat` false (a Terminal send) clears exactly as before.
    @MainActor
    static func clearComposer(inChat: Bool, _ clear: () -> Void) {
        var transaction = Transaction()
        transaction.clearsForChatSend = inChat
        withTransaction(transaction, clear)
    }

    /// The composer card's resize animation: the bubble's spring when the change is a Chat
    /// send clearing it (`clearComposer`), else the card's own `otherwise`. Reduce Motion and
    /// the reference mock keep the card's own.
    static func composerResize(_ transaction: Transaction, reduceMotion: Bool,
                               otherwise: Animation?) -> Animation? {
        guard transaction.clearsForChatSend, sendFolderMotionAllowed, !reduceMotion else { return otherwise }
        return bubbleSpring
    }

    /// Whether the tail follow springs after a send (`ChatScrollPosition.glideToLatest`).
    /// Reduce Motion keeps today's jump.
    static func scrollGlides(reduceMotion: Bool) -> Bool {
        sendFolderMotionAllowed && !reduceMotion
    }

    /// The outgoing bubble rises from 14 pt lower at 0.96 scale (anchored bottom-trailing,
    /// where it lands) while it fades in; under Reduce Motion it only fades. It leaves without
    /// motion: the transcript's own copy of the prompt takes its place.
    static func bubbleTransition(reduceMotion: Bool) -> AnyTransition {
        guard sendFolderMotionAllowed else { return .identity }
        let entrance: AnyTransition = reduceMotion
            ? .opacity
            : .opacity
                .combined(with: .offset(y: 14))
                .combined(with: .scale(scale: 0.96, anchor: .bottomTrailing))
        return .asymmetric(insertion: entrance, removal: .identity)
    }

    /// The bubble's delivery line cross-fades when the server answers; nothing moves.
    static var receipt: Animation? {
        sendFolderMotionAllowed ? .easeInOut(duration: 0.15) : nil
    }

    /// A send the composer accepted locally: the light impact, and whether the Send slot
    /// plays its press (`ChatSendPress`). Under Reduce Motion neither happens.
    @MainActor
    static func acceptSend(reduceMotion: Bool) -> Bool {
        guard sendFolderMotionAllowed, !reduceMotion else { return false }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        return true
    }
}

private struct ChatSendClearKey: TransactionKey {
    static let defaultValue = false
}

extension Transaction {
    /// The change is a Chat send clearing the composer (`ChatSendMotion.clearComposer`).
    var clearsForChatSend: Bool {
        get { self[ChatSendClearKey.self] }
        set { self[ChatSendClearKey.self] = newValue }
    }
}

/// The Send press, on the composer's trailing action slot rather than the Send button:
/// clearing the composer swaps Send for Saved Prompts in the same frame, so the press plays at
/// the tap's place on whatever stands there. The slot must be one stable container (not a
/// `Group`) so the press survives that swap.
struct ChatSendPress: ViewModifier {
    /// Counts accepted sends; each change plays the press once.
    let trigger: Int

    func body(content: Content) -> some View {
        content.phaseAnimator([1, ChatSendMotion.pressScale], trigger: trigger) { view, scale in
            view.scaleEffect(scale)
        } animation: { scale in
            scale < 1 ? .easeOut(duration: 0.06) : .spring(duration: 0.1, bounce: 0.25)
        }
    }
}

enum AgentFolderMotion {
    /// Opening: the rows' space grows and the rows below move down on this spring.
    static let open = Animation.spring(response: 0.30, dampingFraction: 0.9)
    /// Closing: faster, no stagger; the rows fade out together while the space collapses.
    static let close = Animation.spring(response: 0.24, dampingFraction: 1.0)
    /// Each revealed row starts this much later than the one above it…
    static let stagger: Double = 0.018
    /// …up to this many rows; the rest appear with the last of them.
    static let staggerRows = 6

    /// The tap's animation. Under Reduce Motion the height changes at once (nil).
    static func toggle(opening: Bool, reduceMotion: Bool) -> Animation? {
        guard sendFolderMotionAllowed, !reduceMotion else { return nil }
        return opening ? open : close
    }

    /// Whether a tap that opens a folder reveals its rows (`memberTransition`).
    static var reveals: Bool { sendFolderMotionAllowed }

    /// The chevron turns 0° ↔ 90° in 200 ms; under Reduce Motion it switches.
    static func chevron(reduceMotion: Bool) -> Animation? {
        guard sendFolderMotionAllowed, !reduceMotion else { return nil }
        return .easeInOut(duration: 0.2)
    }

    /// Where each agent of the folder being revealed sits in it, by list item id.
    static func revealPositions(_ items: [AgentListItem], folderID: String?) -> [String: Int] {
        guard let folderID else { return [:] }
        var positions: [String: Int] = [:]
        for item in items {
            if case let .agent(_, _, folder) = item, folder == folderID { positions[item.id] = positions.count }
        }
        return positions
    }

    /// An agent row under an open folder. `revealPosition` is its place in a folder a tap is
    /// opening now: it fades in sliding down 6 pt, 18 ms after the row above it (under Reduce
    /// Motion a 120 ms fade, the space already there). It leaves by fading while the close
    /// spring collapses its space; under Reduce Motion at once, with the space.
    /// Any other insertion keeps SwiftUI's default fade.
    static func memberTransition(revealPosition: Int?, reduceMotion: Bool) -> AnyTransition {
        guard sendFolderMotionAllowed else { return .identity }
        let insertion: AnyTransition
        if let revealPosition {
            if reduceMotion {
                insertion = AnyTransition.opacity.animation(.easeInOut(duration: 0.12))
            } else {
                let delay = Double(min(revealPosition, staggerRows - 1)) * stagger
                insertion = AnyTransition.opacity.combined(with: .offset(y: -6)).animation(open.delay(delay))
            }
        } else {
            insertion = .opacity
        }
        return .asymmetric(insertion: insertion, removal: reduceMotion ? .identity : .opacity)
    }
}
