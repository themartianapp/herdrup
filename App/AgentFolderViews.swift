import SwiftUI
import UIKit
import HerdrKit

// Agent folders and stars in the Agents list (herdrup#552, proposal B): the folder row, its
// picture, and the swipe-right actions on an agent row.

/// A folder as one row: its agents' avatars, the name and agent count, the line that says who
/// needs you, and the amber (waiting) and red (stopped) counts. Drawn to the agent card's
/// metrics so the two sit together in the list and the iPad/Mac sidebar.
struct AgentFolderRow: View {
    let summary: AgentFolderSummary
    let sidebar: Bool
    let separator: Bool
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Color.clear.frame(width: DesignTokens.Space.rowLead, height: 1)
            AgentFolderPicture(members: Array(summary.members.prefix(4)),
                               diameter: sidebar ? DesignTokens.Size.avatarSidebar : DesignTokens.Size.avatarPhone)
                .padding(.trailing, DesignTokens.Space.avatarGap)
            VStack(alignment: .leading, spacing: DesignTokens.Space.stackTight) {
                HStack(spacing: DesignTokens.Space.stackSmall) {
                    Text(summary.folder.name)
                        .font(.system(size: (sidebar ? DesignTokens.Text.RowName.size
                                                     : DesignTokens.Text.RowNamePhone.size) * Typography.scale,
                                      weight: sidebar ? DesignTokens.Text.RowName.weight
                                                      : DesignTokens.Text.RowNamePhone.weight))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                    Text(summary.agentCountText)
                        .font(Typography.app(sidebar ? DesignTokens.Text.RowAge.size : DesignTokens.Text.RowAgePhone.size))
                        .foregroundStyle(Palette.textDim)
                        .lineLimit(1)
                    Spacer(minLength: DesignTokens.Space.stackSmall)
                    if summary.waitingCount > 0 {
                        CountPill(count: summary.waitingCount, fill: Palette.waiting)
                    }
                    if summary.stoppedCount > 0 {
                        CountPill(count: summary.stoppedCount, fill: Palette.died)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textFaint)
                        .rotationEffect(.degrees(summary.isOpen ? 90 : 0))
                        .animation(AgentFolderMotion.chevron(reduceMotion: reduceMotion), value: summary.isOpen)
                        .accessibilityHidden(true)
                }
                Text(summary.summaryLine)
                    .font(.system(size: (sidebar ? DesignTokens.Text.RowPreview.size
                                                 : DesignTokens.Text.RowPreviewPhone.size) * Typography.scale))
                    .foregroundStyle(summary.waitingCount > 0 ? Palette.text : Palette.textDim)
                    .lineLimit(1)
            }
            .padding(.trailing, DesignTokens.Space.rowTrail)
            .frame(maxWidth: .infinity)
            .frame(height: (sidebar ? DesignTokens.Size.agentRow : DesignTokens.Size.agentRowPhone) * max(1, Typography.scale),
                   alignment: .center)
            .overlay(alignment: .bottom) {
                if separator {
                    Rectangle().fill(Palette.hairline).frame(height: 1 / displayScale)
                        .padding(.trailing, DesignTokens.Space.rowTrail)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

/// The amber / red count capsule (`text.countPill`, 22 pt, ground ink): a closed folder's
/// waiting and stopped counts, and the badges on Settings' suggestions rows.
struct CountPill: View {
    let count: Int
    let fill: Color

    var body: some View {
        Text("\(count)")
            .font(Typography.app(DesignTokens.Text.CountPill.size, DesignTokens.Text.CountPill.weight))
            .monospacedDigit()
            .foregroundStyle(Palette.ground)
            .padding(.horizontal, 7)
            .frame(minWidth: 22, minHeight: 22)
            .background(Capsule().fill(fill))
    }
}

/// The folder picture: up to four of its agents' own avatars (photo, mascot or initial tile,
/// as their rows draw them) in a round tile, two to a line. Each cell is found by its agent:
/// `folder-avatar-<name>`, its value the kind drawn (`mascot:<id>`, `image`, `initial`).
/// Plain stacks: no lazy container inside a row of the lazy roster.
struct AgentFolderPicture: View {
    let members: [AgentRow]
    let diameter: CGFloat

    var body: some View {
        let cell = (diameter - 17) / 2
        let lines = stride(from: 0, to: members.count, by: 2).map { Array(members[$0..<min($0 + 2, members.count)]) }
        VStack(spacing: 3) {
            ForEach(lines.indices, id: \.self) { line in
                HStack(spacing: 3) {
                    ForEach(lines[line]) { row in
                        AgentAvatarView(agent: row.info, name: row.title, size: cell,
                                        accessibilityID: "folder-avatar-\(row.title)")
                    }
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .background(Circle().fill(Palette.surfaceRaised))
        .overlay(Circle().stroke(Palette.hairline, lineWidth: 1))
    }
}

/// One action behind an agent row, revealed by swiping right.
struct RowSwipeAction: Identifiable {
    let title: String
    let systemImage: String
    let tint: Color
    let identifier: String
    let action: () -> Void
    var id: String { identifier }
}

extension View {
    /// Swipe right to reveal `actions` at the row's leading edge (Mail's leading swipe). No
    /// actions, no swipe. The swipe itself is `swipes`' one pan on the list's scroll view; this
    /// row observes only its own `RowSwipeController.Box`, so a swipe redraws that row only.
    func leadingSwipeActions(_ actions: [RowSwipeAction], id: String,
                             in swipes: RowSwipeController) -> some View {
        modifier(LeadingSwipeActions(actions: actions, id: id, swipes: swipes))
    }
}

private struct LeadingSwipeActions: ViewModifier {
    let actions: [RowSwipeAction]
    let id: String
    let swipes: RowSwipeController

    private static let actionWidth: CGFloat = 76
    private var revealWidth: CGFloat { CGFloat(actions.count) * Self.actionWidth }

    func body(content: Content) -> some View {
        if actions.isEmpty {
            content
        } else {
            let box = swipes.box(id)
            let width = revealWidth
            let offset = min(max(0, (box.revealed ? width : 0) + box.drag), width + 24)
            // The actions sit behind the row, as tall as it, and show as it slides right.
            content
                .offset(x: offset)
                .background(alignment: .leading) {
                    if offset > 0 || box.revealed {
                        HStack(spacing: 0) {
                            ForEach(actions) { action in
                                Button {
                                    swipes.close(id)
                                    action.action()
                                } label: {
                                    VStack(spacing: 4) {
                                        Image(systemName: action.systemImage)
                                            .font(.system(size: 17, weight: .semibold))
                                        Text(action.title)
                                            .font(Typography.app(12, .semibold))
                                    }
                                    .foregroundStyle(Palette.ground)
                                    .frame(width: Self.actionWidth)
                                    .frame(maxHeight: .infinity)
                                    .background(action.tint)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(action.identifier)
                            }
                        }
                    }
                }
                .overlay {
                    // While open, a tap on the row closes the actions instead of opening it.
                    if box.revealed {
                        Color.clear
                            .contentShape(Rectangle())
                            .offset(x: offset)
                            .onTapGesture { swipes.close(id) }
                    }
                }
                .clipped()
                // A UIKit marker over the row's frame, for the list's pan to find it under the
                // finger (like `stableContextMenu`'s anchor). No per-row geometry reader in the
                // roster: the marker costs nothing while the list scrolls.
                .background(RowSwipeMarker(id: id, revealWidth: width, swipes: swipes))
        }
    }
}

/// The swipe-right gesture of the Agents list's rows (herdrup#552): ONE horizontal
/// `UIPanGestureRecognizer` on the list's `UIScrollView`, like a table view's swipe, rather
/// than a gesture on every row.
///
/// A gesture on each row does not work in the roster: a SwiftUI `DragGesture` on the rows
/// never saw a swipe inside the ScrollView (CI run 40477652920). This pan is UIKit's alone:
/// SwiftUI's gesture graph never sees it, the scroll view's own pan runs beside it untouched,
/// and it begins only for a sideways swipe that starts on a row with actions.
///
/// Not observable itself: each row observes its own `Box`, so a swipe redraws one row.
@MainActor
final class RowSwipeController: NSObject, UIGestureRecognizerDelegate {
    /// One row's swipe: how far the finger has moved it, and whether its actions are open.
    @Observable @MainActor
    final class Box {
        var drag: CGFloat = 0
        var revealed = false
    }

    private var boxes: [String: Box] = [:]
    /// The swipeable rows' markers now in a window.
    private let markers = NSHashTable<RowSwipeMarkerView>.weakObjects()
    private weak var scrollView: UIScrollView?
    private var pan: UIPanGestureRecognizer?
    /// The row under the pan in progress, and how wide its actions are.
    private var swiping: (id: String, revealWidth: CGFloat)?

    private static let spring = Animation.spring(response: 0.3, dampingFraction: 0.86)

    /// The row's box, made on first use. A plain dictionary write: it invalidates nothing.
    func box(_ id: String) -> Box {
        if let box = boxes[id] { return box }
        let box = Box()
        boxes[id] = box
        return box
    }

    func add(_ marker: RowSwipeMarkerView) { markers.add(marker) }
    func remove(_ marker: RowSwipeMarkerView) { markers.remove(marker) }

    func close(_ id: String) {
        guard let box = boxes[id], box.revealed || box.drag != 0 else { return }
        withAnimation(Self.spring) {
            box.revealed = false
            box.drag = 0
        }
    }

    /// Puts the pan on the list's scroll view; called from the list's display-link sample, so
    /// it costs a pointer comparison per frame once attached.
    func attach(_ scrollView: UIScrollView) {
        guard scrollView !== self.scrollView else { return }
        if let pan { pan.view?.removeGestureRecognizer(pan) }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        scrollView.addGestureRecognizer(pan)
        self.pan = pan
        self.scrollView = scrollView
    }

    /// The row with actions under `point` (in `view`). Looked up only when a pan begins.
    private func row(at point: CGPoint, in view: UIView) -> RowSwipeMarkerView? {
        markers.allObjects.first { marker in
            marker.window != nil && marker.bounds.contains(view.convert(point, to: marker))
        }
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: pan.view).x
        switch pan.state {
        case .began:
            guard let view = pan.view, let marker = row(at: pan.location(in: view), in: view) else { return }
            let id = marker.rowID
            // One row open at a time, like Mail.
            for (other, box) in boxes where other != id && (box.revealed || box.drag != 0) {
                withAnimation(Self.spring) {
                    box.revealed = false
                    box.drag = 0
                }
            }
            swiping = (id, marker.revealWidth)
            box(id).drag = translation
        case .changed:
            guard let id = swiping?.id else { return }
            box(id).drag = translation
        case .ended:
            guard let swipe = swiping else { return }
            let id = swipe.id, width = swipe.revealWidth
            swiping = nil
            // Where a flick would carry the row, as SwiftUI's predictedEndTranslation does.
            let predicted = translation + pan.velocity(in: pan.view).x * 0.2
            let box = self.box(id)
            withAnimation(Self.spring) {
                box.revealed = (box.revealed ? width : 0) + predicted > width / 2
                box.drag = 0
            }
        case .cancelled, .failed:
            guard let id = swiping?.id else { return }
            swiping = nil
            let box = self.box(id)
            withAnimation(Self.spring) { box.drag = 0 }
        default:
            break
        }
    }

    // MARK: UIGestureRecognizerDelegate

    /// Only a sideways swipe that starts on a row with actions; anything else stays the list's.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan, let pan, let view = pan.view else { return false }
        let velocity = pan.velocity(in: view)
        guard abs(velocity.x) > abs(velocity.y) * 1.5 else { return false }
        return row(at: pan.location(in: view), in: view) != nil
    }

    /// The scroll view's own pan is left exactly as it is.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other === scrollView?.panGestureRecognizer
    }
}

/// Marks a swipeable row's frame in UIKit for `RowSwipeController`. It draws nothing, takes no
/// touches, and SwiftUI updates it only when the row's id or action width changes.
private struct RowSwipeMarker: UIViewRepresentable {
    let id: String
    let revealWidth: CGFloat
    let swipes: RowSwipeController

    func makeUIView(context: Context) -> RowSwipeMarkerView {
        let view = RowSwipeMarkerView()
        view.isUserInteractionEnabled = false
        view.swipes = swipes
        view.rowID = id
        view.revealWidth = revealWidth
        return view
    }

    func updateUIView(_ view: RowSwipeMarkerView, context: Context) {
        if view.rowID != id { view.rowID = id }
        if view.revealWidth != revealWidth { view.revealWidth = revealWidth }
    }
}

final class RowSwipeMarkerView: UIView {
    weak var swipes: RowSwipeController?
    var rowID = ""
    var revealWidth: CGFloat = 0

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { swipes?.add(self) } else { swipes?.remove(self) }
    }
}
