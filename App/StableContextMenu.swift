import SwiftUI
import UIKit
import ObjectiveC

// A long-press menu that nothing rebuilds while it is open (#437).
//
// A MENU MUST NOT BE REBUILT WHILE IT IS OPEN. SwiftUI's `.contextMenu` pushes a new UIMenu
// into the open menu (`UIContextMenuInteraction.updateVisibleMenu`, with new UIActions) each
// time its modifier is evaluated again: on any body pass of the view that holds it (the
// Agents home's roster poll, a Gram poll or placement write), and twice on its own about a
// second after the menu appears. A tap landing on an item while its action was replaced was
// dropped: the touch ended on the menu, the menu stayed open and nothing ran. Equatable items
// (#436) do not stop it: the push happens whenever the modifier node runs, not only when the
// items change (hosted run 39116174699: ArchivedCloseTests, 2 of 6 iterations).
//
// So `stableContextMenu` keeps SwiftUI out of the menu. A background anchor view marks the
// view's frame; one UIKit `UIContextMenuInteraction` per scroll view (or per view controller
// root) finds the anchor under the finger, builds the UIMenu ONCE per presentation from the
// anchor's current items, and nothing updates it until it closes. SwiftUI passes only refresh
// the anchor's reference box (`StableMenuModel`), which an open menu never reads back except
// at tap time: a chosen item runs the action from the box's current items, so it acts on the
// holder's current state (a client replaced since the menu opened, say), and the action
// captured when the menu opened only if the item is no longer offered by that title.
// The preview is a snapshot of the view's frame, lifted in place with no platter, the view
// hidden behind it while the menu is up, as SwiftUI's own.

/// One entry of a `stableContextMenu`: an action, or a submenu of entries. Entries are
/// written as initializers, not `.button(...)`: a leading-dot line would continue the
/// line above it.
struct StableMenuItem {
    enum Kind {
        case action(() -> Void)
        case submenu([StableMenuItem])
    }

    let title: String
    let systemImage: String
    let destructive: Bool
    /// A greyed-out line that states something (a `.disabled` UIAction); it does nothing.
    let disabled: Bool
    let kind: Kind

    /// A menu item; `role: .destructive` draws it red, as a SwiftUI Button's role.
    init(_ title: String, systemImage: String, role: ButtonRole? = nil,
         action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        destructive = role == .destructive
        disabled = false
        kind = .action(action)
    }

    /// A disabled line: shown greyed out, never chosen, and left out of the Actions rotor.
    init(disabled title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
        destructive = false
        disabled = true
        kind = .action {}
    }

    /// A submenu, as a SwiftUI `Menu` inside a context menu.
    init(submenu title: String, systemImage: String,
         @StableMenuBuilder items: () -> [StableMenuItem]) {
        self.title = title
        self.systemImage = systemImage
        destructive = false
        disabled = false
        kind = .submenu(items())
    }
}

/// Builds `[StableMenuItem]` with `if`, `if let`, `switch` and `for` as a SwiftUI menu body.
@resultBuilder
enum StableMenuBuilder {
    static func buildExpression(_ item: StableMenuItem) -> [StableMenuItem] { [item] }
    static func buildExpression(_ items: [StableMenuItem]) -> [StableMenuItem] { items }
    static func buildBlock(_ parts: [StableMenuItem]...) -> [StableMenuItem] { parts.flatMap { $0 } }
    static func buildOptional(_ part: [StableMenuItem]?) -> [StableMenuItem] { part ?? [] }
    static func buildEither(first part: [StableMenuItem]) -> [StableMenuItem] { part }
    static func buildEither(second part: [StableMenuItem]) -> [StableMenuItem] { part }
    static func buildArray(_ parts: [[StableMenuItem]]) -> [StableMenuItem] { parts.flatMap { $0 } }
}

extension View {
    /// A long-press menu that is built when it opens and never rebuilt while open (see the
    /// top of StableContextMenu.swift). `previewCornerRadius` clips the lifted preview to a
    /// rounded rectangle, as `.contentShape(.contextMenuPreview, RoundedRectangle(...))`;
    /// nil lifts the view's whole frame. An empty item list, or a disabled view, offers no
    /// menu.
    func stableContextMenu(previewCornerRadius: CGFloat? = nil,
                           @StableMenuBuilder items: @escaping () -> [StableMenuItem]) -> some View {
        modifier(StableContextMenu(previewCornerRadius: previewCornerRadius, items: items))
    }
}

private struct StableContextMenu: ViewModifier {
    let previewCornerRadius: CGFloat?
    let items: () -> [StableMenuItem]
    /// The menu's preview (a snapshot) stands in for the view while the menu is up, so the
    /// view itself is hidden, as SwiftUI's `.contextMenu` does: nothing of it (a bubble's
    /// tail, a badge) shows beside the clipped preview.
    @State private var lifted = false
    /// What the anchor offers, kept for the view's life: the anchor holds only this, so a
    /// redraw of the view never updates the anchor's UIView. The items are built only when
    /// the menu opens (or VoiceOver asks), never per redraw.
    @State private var menu = StableMenuModel()
    /// A disabled view offers no menu, and so no menu actions to VoiceOver either.
    @Environment(\.isEnabled) private var isEnabled
    /// The menu's entries are accessibility actions only while VoiceOver or Switch Control
    /// runs: building them is the menu's whole cost, and on a long chat every message has one.
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControl

    func body(content: Content) -> some View {
        // Plain stores into the model the anchor reads when a menu opens; nothing observes
        // them, so they draw nothing.
        menu.items = items
        menu.previewCornerRadius = previewCornerRadius
        menu.isEnabled = isEnabled
        menu.setLifted = { lifted = $0 }
        return content
            .opacity(lifted ? 0 : 1)
            .background(StableMenuAnchor(model: menu).accessibilityHidden(true))
            // The long press belongs to the host's interaction, which VoiceOver does not see
            // on this element, so the same entries are its Actions rotor. Submenu entries are
            // flattened as "Submenu, Entry"; titles and actions are the menu's own. SwiftUI
            // lists accessibility actions last-declared first, so they are declared in reverse
            // to read in the menu's order.
            .accessibilityActions {
                if isEnabled && (voiceOver || switchControl) {
                    ForEach(Array(Self.flattened(items()).reversed().enumerated()), id: \.offset) { _, entry in
                        Button(entry.title, action: entry.action)
                    }
                }
            }
    }

    /// Every action of a menu, depth first, a submenu's entries prefixed with its title.
    static func flattened(_ items: [StableMenuItem], prefix: String = "")
        -> [(title: String, action: () -> Void)] {
        items.flatMap { item -> [(title: String, action: () -> Void)] in
            let title = prefix.isEmpty ? item.title : "\(prefix), \(item.title)"
            if item.disabled { return [] }
            switch item.kind {
            case .action(let action): return [(title, action)]
            case .submenu(let children): return flattened(children, prefix: title)
            }
        }
    }
}

/// What an anchor offers: stored by its view's modifier on every SwiftUI update, read when a
/// menu opens and when one of its items is chosen.
@MainActor
final class StableMenuModel {
    var items: () -> [StableMenuItem] = { [] }
    var previewCornerRadius: CGFloat?
    /// The view's `isEnabled`: a disabled view offers no menu, as with `.contextMenu`.
    var isEnabled = true
    /// Hides (true) or shows the view while its preview stands in for it.
    var setLifted: (Bool) -> Void = { _ in }

    /// The current action at `path` (titles from the top level down), if still offered.
    func currentAction(at path: [String]) -> (() -> Void)? {
        var level = items()
        for (depth, title) in path.enumerated() {
            guard let item = level.first(where: { $0.title == title }) else { return nil }
            switch item.kind {
            case .action(let action):
                return depth == path.count - 1 ? action : nil
            case .submenu(let children):
                level = children
            }
        }
        return nil
    }
}

/// Holds only the modifier's model, the same object for the view's life, so SwiftUI finds
/// nothing changed and does not update the anchor when the view redraws.
private struct StableMenuAnchor: UIViewRepresentable {
    let model: StableMenuModel

    func makeUIView(context: Context) -> StableMenuAnchorView {
        StableMenuAnchorView(model: model)
    }

    func updateUIView(_ view: StableMenuAnchorView, context: Context) {
        view.model = model
    }
}

/// Marks the frame of a view with a `stableContextMenu`. Draws nothing and takes no touch:
/// the long press is seen by its host's interaction (`StableMenuHost`).
final class StableMenuAnchorView: UIView {
    fileprivate(set) var model: StableMenuModel
    private weak var host: StableMenuHost?

    init(model: StableMenuModel) {
        self.model = model
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        rehost()
    }

    /// A move between superviews in the same window does not call `didMoveToWindow`, but
    /// can put the anchor under a different scroll view: re-resolve the host then too.
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        rehost()
    }

    private func rehost() {
        let next = window == nil ? nil : StableMenuHost.host(for: self)
        guard next !== host else { return }
        host?.remove(self)
        host = next
        next?.add(self)
    }
}

/// One `UIContextMenuInteraction` for every anchor under a view: the nearest scroll view
/// above the anchors (where the long press lands, and which nothing floating over it can
/// pass a touch to), else the root view of their view controller.
@MainActor
final class StableMenuHost: NSObject, UIContextMenuInteractionDelegate {
    private static var key: UInt8 = 0

    /// One menu this interaction opened (or is opening).
    private final class Presentation {
        let anchor: StableMenuAnchorView
        /// The preview: holds a snapshot of the view, taken at the press and again once the
        /// menu is up (see `willDisplayMenuFor`).
        let preview = UIView()
        var displayed = false
        init(anchor: StableMenuAnchorView) { self.anchor = anchor }
    }

    private let anchors = NSHashTable<StableMenuAnchorView>.weakObjects()
    /// By configuration identifier. A press that never opened its menu leaves an entry,
    /// dropped at the next press.
    private var presented: [NSString: Presentation] = [:]

    static func host(for anchor: StableMenuAnchorView) -> StableMenuHost? {
        var candidate = anchor.superview
        var root: UIView?
        while let view = candidate {
            if view is UIScrollView { root = view; break }
            if view.next is UIViewController { root = view; break }
            candidate = view.superview
        }
        guard let view = root ?? anchor.window else { return nil }
        if let existing = objc_getAssociatedObject(view, &key) as? StableMenuHost { return existing }
        let host = StableMenuHost()
        view.addInteraction(UIContextMenuInteraction(delegate: host))
        objc_setAssociatedObject(view, &key, host, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return host
    }

    func add(_ anchor: StableMenuAnchorView) { anchors.add(anchor) }
    func remove(_ anchor: StableMenuAnchorView) { anchors.remove(anchor) }

    /// The smallest shown, enabled anchor whose frame holds `location` (in `view`).
    private func anchor(at location: CGPoint, in view: UIView) -> StableMenuAnchorView? {
        var best: (anchor: StableMenuAnchorView, area: CGFloat)?
        for anchor in anchors.allObjects where anchor.model.isEnabled && isShown(anchor, in: view) {
            let point = view.convert(location, to: anchor)
            guard anchor.bounds.contains(point) else { continue }
            let area = anchor.bounds.width * anchor.bounds.height
            if best == nil || area < best!.area { best = (anchor, area) }
        }
        return best?.anchor
    }

    /// `anchor` is under `view` and neither it nor a view between them is hidden.
    private func isShown(_ anchor: StableMenuAnchorView, in view: UIView) -> Bool {
        var current: UIView? = anchor
        while let step = current, step !== view {
            if step.isHidden || step.alpha < 0.01 { return false }
            current = step.superview
        }
        return current === view
    }

    private func presentation(_ configuration: UIContextMenuConfiguration) -> Presentation? {
        (configuration.identifier as? NSString).flatMap { presented[$0] }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let view = interaction.view, let anchor = anchor(at: location, in: view) else { return nil }
        // Built here, once: the open menu keeps these elements until it closes.
        let items = anchor.model.items()
        guard !items.isEmpty else { return nil }
        let menu = UIMenu(children: items.map { element($0, path: [], anchor: anchor) })
        for (stale, entry) in presented where !entry.displayed {
            entry.anchor.model.setLifted(false)
            presented[stale] = nil
        }
        let id = UUID().uuidString as NSString
        presented[id] = Presentation(anchor: anchor)
        return UIContextMenuConfiguration(identifier: id, previewProvider: nil) { _ in menu }
    }

    private func element(_ item: StableMenuItem, path: [String],
                         anchor: StableMenuAnchorView) -> UIMenuElement {
        let path = path + [item.title]
        var image = UIImage(systemName: item.systemImage)
        // A destructive item's title is red and its icon stays in the label colour, as a
        // SwiftUI `Button(role: .destructive)` in a `.contextMenu` draws it.
        if item.destructive { image = image?.withTintColor(.label, renderingMode: .alwaysOriginal) }
        switch item.kind {
        case .action(let opened):
            return UIAction(title: item.title, image: image,
                            attributes: item.destructive ? .destructive : item.disabled ? .disabled : []) { [weak anchor] _ in
                (anchor?.model.currentAction(at: path) ?? opened)()
            }
        case .submenu(let children):
            return UIMenu(title: item.title, image: image,
                          children: children.map { element($0, path: path, anchor: anchor) })
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configuration: UIContextMenuConfiguration,
                                highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        guard let entry = presentation(configuration), let view = interaction.view else { return nil }
        if entry.preview.subviews.isEmpty {
            guard snapshot(entry, in: view) else { return nil }
        }
        return targetedPreview(entry, in: view)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configuration: UIContextMenuConfiguration,
                                dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        guard let entry = presentation(configuration), !entry.preview.subviews.isEmpty,
              let view = interaction.view, entry.anchor.window != nil else { return nil }
        // Back to where the view is now (a roster update may have moved it).
        return targetedPreview(entry, in: view)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                animator: (any UIContextMenuInteractionAnimating)?) {
        guard let entry = presentation(configuration) else { return }
        entry.displayed = true
        // The first snapshot was taken mid-press, so a button in it may draw pressed. The menu
        // cancelled that press: once the lift has run, show the view as it draws now, then
        // hide the view itself behind its preview until the menu has closed (as SwiftUI's
        // menu does: nothing of it, a bubble's tail or a badge, shows beside the preview).
        let refresh = { [weak self, weak entry, weak view = interaction.view] in
            guard let self, let entry, let view, entry.displayed, entry.anchor.window != nil else { return }
            _ = self.snapshot(entry, in: view)
            entry.anchor.model.setLifted(true)
        }
        if let animator { animator.addCompletion(refresh) } else { refresh() }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                willEndFor configuration: UIContextMenuConfiguration,
                                animator: (any UIContextMenuInteractionAnimating)?) {
        guard let id = configuration.identifier as? NSString else { return }
        presented[id]?.displayed = false
        let forget: () -> Void = { [weak self] in
            self?.presented.removeValue(forKey: id)?.anchor.model.setLifted(false)
        }
        if let animator { animator.addCompletion(forget) } else { forget() }
    }

    /// Puts a snapshot of the anchor's frame (as `view` draws it now) in the preview.
    private func snapshot(_ entry: Presentation, in view: UIView) -> Bool {
        let frame = entry.anchor.convert(entry.anchor.bounds, to: view)
        guard frame.width > 0, frame.height > 0,
              let image = view.resizableSnapshotView(from: frame, afterScreenUpdates: false,
                                                     withCapInsets: .zero) else { return false }
        entry.preview.subviews.forEach { $0.removeFromSuperview() }
        entry.preview.bounds = CGRect(origin: .zero, size: frame.size)
        image.frame = entry.preview.bounds
        image.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        entry.preview.addSubview(image)
        return true
    }

    private func targetedPreview(_ entry: Presentation, in view: UIView) -> UITargetedPreview {
        let frame = entry.anchor.convert(entry.anchor.bounds, to: view)
        let parameters = UIPreviewParameters()
        // The snapshot draws only the view (the page's ground is behind the scroll view), so
        // no platter: the preview looks like the view, as SwiftUI's own.
        parameters.backgroundColor = .clear
        if let radius = entry.anchor.model.previewCornerRadius {
            parameters.visiblePath = UIBezierPath(roundedRect: CGRect(origin: .zero, size: frame.size),
                                                  cornerRadius: radius)
        }
        let target = UIPreviewTarget(container: view, center: CGPoint(x: frame.midX, y: frame.midY))
        return UITargetedPreview(view: entry.preview, parameters: parameters, target: target)
    }
}
