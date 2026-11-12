import HerdrKit
import SwiftUI
import UIKit

/// The conversation column's width as laid out, in Chat and Gram (#523 items 2 and 12, #541).
/// On regular width (iPad, Mac) it is the reader's chosen width (`ConversationColumnWidth`),
/// up to the width the conversation has; on compact width (iPhone) it is `compact`, the
/// surface's own cap.
enum ConversationColumnLayout {
    static func width(stored: Double, available: CGFloat, regular: Bool, compact: CGFloat) -> CGFloat {
        guard regular else { return compact }
        // Before the first measurement the chosen width stands, so the column never lays out
        // at zero for a frame.
        guard available > 0 else { return CGFloat(ConversationColumnWidth.sanitized(stored)) }
        return CGFloat(ConversationColumnWidth.displayed(stored: stored, available: Double(available)))
    }
}

/// Where a column resizer sits: names its handles for VoiceOver and the UI tests
/// (`chat-width-handle-left`, `gram-width-readout`).
enum ConversationSurface: String {
    case chat, gram

    var name: String {
        switch self {
        case .chat: return "Chat"
        case .gram: return "Gram"
        }
    }

    var resizeHint: String {
        switch self {
        case .chat: return "Drag to resize the chat. Double-tap to reset to Wide."
        case .gram: return "Drag to resize Gram. Double-tap to reset to Wide."
        }
    }
}

extension View {
    /// Lays the view out in the conversation column, centred: while `active`, the reader's
    /// chosen width on regular width (`ConversationColumnLayout`) and at most `cap` on compact
    /// width; otherwise at most `cap`. Chat's composer, and Gram's feed, header and composer.
    ///
    /// The width is read here, not by the page: a drag re-lays out what this wraps without
    /// re-running the page's body, and so without re-rendering its rows. `probe` names the
    /// column's frame for the UI tests (mock runs only).
    func conversationColumn(_ active: Bool = true, cap: CGFloat = .infinity, probe: String? = nil) -> some View {
        modifier(ConversationColumnFrame(active: active, cap: cap, probe: probe))
    }

    /// Lays the conversation column's resizer (`ConversationColumnResizer`) over this view on
    /// regular width, with this view's width as the most the column can take, when that is
    /// wide enough to resize (`ConversationColumnWidth.isResizable`). `readoutTop` keeps the
    /// readout clear of chrome floating over the view's top.
    func conversationColumnResizer(_ surface: ConversationSurface, readoutTop: CGFloat = 0) -> some View {
        modifier(ConversationColumnResizing(surface: surface, readoutTop: readoutTop))
    }
}

private struct ConversationColumnFrame: ViewModifier {
    let active: Bool
    let cap: CGFloat
    let probe: String?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage(ConversationColumnWidth.storageKey) private var stored = ConversationColumnWidth.defaultWidth
    /// The whole width the column could take.
    @State private var available: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // Both bounds, so the column is exactly its width whatever it holds.
            .frame(minWidth: 0, maxWidth: active
                   ? ConversationColumnLayout.width(stored: stored, available: available,
                                                    regular: sizeClass == .regular, compact: cap)
                   : cap)
            // At the bottom: Chat and Gram open at their newest rows, so it is on screen.
            .background(alignment: .bottom) { widthProbe(probe) }
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
    }
}

/// A UI-test probe (mock runs only) naming a width: a 1 pt strip along an edge of what it
/// backs, so its frame gives the width and edges without an accessibility element over the
/// rows (which would stand between a test's press and a bubble).
@ViewBuilder private func widthProbe(_ identifier: String?) -> some View {
    #if DEBUG
    if let identifier, ScreenshotMock.mode != nil {
        Color.clear
            .frame(height: 1)
            .accessibilityElement()
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(identifier)
            .allowsHitTesting(false)
    }
    #endif
}

private struct ConversationColumnResizing: ViewModifier {
    let surface: ConversationSurface
    let readoutTop: CGFloat
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The wrapped view's width: the most the column can take.
    @State private var available: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // The width the column can take, for the UI tests (`gram-width-area`).
            .background(alignment: .top) { widthProbe("\(surface.rawValue)-width-area") }
            .overlay {
                // No handles where the column has no room to narrow (iPhone Duo's inner
                // display held tall beside the sidebar): there a drag could not move it.
                if sizeClass == .regular, ConversationColumnWidth.isResizable(available: Double(available)) {
                    ConversationColumnResizer(surface: surface, available: available, readoutTop: readoutTop)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
    }
}

/// The two edge handles that resize the conversation column on regular width, and the
/// readout shown while one is dragged. Laid over the whole conversation; only the handles
/// hit-test, so scrolling and text selection elsewhere are untouched. Chat and Gram share
/// the one stored width, so resizing either resizes both.
///
/// Dragging either edge resizes around the centre (each point of drag is two of width) between
/// `ConversationColumnWidth.minimum(available:)` (560 pt, less on a narrower conversation) and
/// the conversation's whole width, snapping to Readable, Wide and Full. A double tap
/// (double click on the Mac) resets to Wide. On the Mac nothing is drawn at rest; a hover shows
/// the edge's hairline and grip, as it does on an iPad with a pointer. On touch the grip shows
/// faintly at rest so it can be found.
private struct ConversationColumnResizer: View {
    let surface: ConversationSurface
    /// The conversation's whole width.
    let available: CGFloat
    let readoutTop: CGFloat

    @AppStorage(ConversationColumnWidth.storageKey) private var stored = ConversationColumnWidth.defaultWidth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: ConversationColumnWidth.Edge?
    @State private var dragging: ConversationColumnWidth.Edge?
    @State private var dragStartWidth: Double?
    @State private var readoutShown = false
    @State private var hideReadout: Task<Void, Never>?
    /// A new readout per showing: see the overlay in `body`.
    @State private var readoutShowing = 0

    /// The Mac: a pointer, so a narrower hit band and nothing drawn at rest.
    private static let onMac = ProcessInfo.processInfo.isiOSAppOnMac
    private static let hitWidth: CGFloat = onMac ? 20 : 44
    private static let readoutHold: Duration = {
        #if DEBUG
        // UI tests read the readout after XCUITest releases the drag.
        if let seconds = ProcessInfo.processInfo.environment["HERDR_COLUMN_WIDTH_READOUT_HOLD"].flatMap(Double.init) {
            return .milliseconds(Int(seconds * 1000))
        }
        #endif
        return .milliseconds(600)
    }()

    private var availableWidth: Double { Double(available) }
    private var width: Double { ConversationColumnWidth.displayed(stored: stored, available: availableWidth) }

    var body: some View {
        // On the column's edges, but never past the conversation's own: at Full the bands sit
        // just inside, so they never cover the sidebar or the window edge.
        let reach = max(0, min(CGFloat(width), available - Self.hitWidth) / 2)
        ZStack {
            handle(.leading).offset(x: -reach)
            handle(.trailing).offset(x: reach)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Each showing inserts a NEW readout (`id`). Re-showing the one that is fading out
        // revived a view in its removal transition, and iOS 27 left it out for good: in CI
        // 40850683066 a drag began 59 ms into the 0.15 s fade and the readout never came back.
        // With a fresh identity the old one finishes fading while the new one fades in. It
        // stays inserted and removed rather than kept transparent: an always-mounted readout
        // stayed in the accessibility tree at rest despite `accessibilityHidden` (40865545206).
        .overlay(alignment: .top) {
            ZStack {
                if readoutShown { readout.id(readoutShowing).transition(.opacity) }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: readoutShown)
        }
    }

    private var readout: some View {
        Text(ConversationColumnWidth.readout(width, available: availableWidth))
            .font(Typography.machine(12))
            .tracking(0.3)
            .foregroundStyle(Palette.text)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color(hex: 0x40466E).opacity(0.96), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
            .shadow(color: .black.opacity(0.7), radius: 10, y: 6)
            .padding(.top, 14 + readoutTop)
            .allowsHitTesting(false)
            .accessibilityIdentifier("\(surface.rawValue)-width-readout")
    }

    private func handle(_ edge: ConversationColumnWidth.Edge) -> some View {
        let active = dragging == edge
        // Hover only happens with a pointer (the Mac, or an iPad with a trackpad or mouse).
        let shown = dragging != nil || hovered == edge
        return ZStack {
            Rectangle()
                .fill(Palette.hairline)
                .frame(width: 1)
                .opacity(shown ? 1 : 0)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(active ? Color(hex: 0xCCD2E6).opacity(0.9) : Palette.textDim.opacity(0.6))
                .frame(width: 4, height: 40)
                .opacity(shown ? 1 : (Self.onMac ? 0 : 0.25))
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: shown)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: active)
        .frame(width: Self.hitWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .background { if !Self.onMac { ColumnResizePointer() } }
        .onHover { inside in
            if inside { hovered = edge } else if hovered == edge { hovered = nil }
        }
        .gesture(drag(edge))
        // Its own recogniser, beside the drag rather than ahead of it, so the drag is never
        // held back waiting for the tap to fail. Counting taps inside the drag stopped
        // working on iOS 27: a quick double tap reaches the drag as ONE sequence (its first
        // `onChanged` arrives after the second touch begins, `onEnded` once), so it never
        // saw two taps (CI 40847167282).
        .simultaneousGesture(TapGesture(count: 2).onEnded { reset() })
        .accessibilityElement()
        .accessibilityIdentifier("\(surface.rawValue)-width-handle-\(edge == .leading ? "left" : "right")")
        .accessibilityLabel("\(surface.name) width")
        .accessibilityValue(ConversationColumnWidth.accessibilityValue(width, available: availableWidth))
        .accessibilityHint(surface.resizeHint)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: choose(ConversationColumnWidth.incremented(width, available: availableWidth))
            case .decrement: choose(ConversationColumnWidth.decremented(width, available: availableWidth))
            @unknown default: break
            }
        }
        .accessibilityAction { reset() }
    }

    /// A drag that starts with the finger, so the column follows it at once. Global space,
    /// because the handle moves with the column while it is dragged.
    private func drag(_ edge: ConversationColumnWidth.Edge) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStartWidth ?? width
                if dragStartWidth == nil { dragStartWidth = start }
                guard abs(value.translation.width) >= 1 || dragging != nil else { return }
                if dragging == nil {
                    dragging = edge
                    showReadout()
                }
                let next = ConversationColumnWidth.dragged(from: start, translation: Double(value.translation.width),
                                                   edge: edge, available: availableWidth)
                stored = ConversationColumnWidth.stored(for: next, available: availableWidth)
            }
            .onEnded { _ in
                dragStartWidth = nil
                if dragging != nil {
                    dragging = nil
                    scheduleReadoutHide()
                }
            }
    }

    private func choose(_ next: Double) {
        stored = ConversationColumnWidth.stored(for: next, available: availableWidth)
    }

    private func reset() {
        stored = ConversationColumnWidth.resetWidth
        showReadout()
        scheduleReadoutHide()
    }

    private func showReadout() {
        hideReadout?.cancel()
        hideReadout = nil
        if !readoutShown { readoutShowing += 1 }
        readoutShown = true
    }

    private func scheduleReadoutHide() {
        hideReadout?.cancel()
        hideReadout = Task { @MainActor in
            do { try await Task.sleep(for: Self.readoutHold) } catch { return }
            readoutShown = false
        }
    }
}

/// The iPad's resize pointer over a handle (with a trackpad or mouse): a vertical beam with
/// left and right arrows. Takes hover events only, so touches still reach the handle's SwiftUI
/// gesture. Not on the Mac: a Designed-for-iPad app cannot name AppKit's column-resize cursor
/// (SwiftUI's `pointerStyle` is macOS/visionOS only), and a beam there would read as a text
/// cursor; the hover hairline and grip mark the edge instead.
private struct ColumnResizePointer: UIViewRepresentable {
    func makeUIView(context: Context) -> HoverOnlyView {
        let view = HoverOnlyView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.addInteraction(UIPointerInteraction(delegate: context.coordinator))
        return view
    }

    func updateUIView(_ view: HoverOnlyView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class HoverOnlyView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard event?.type == .hover else { return nil }
            return super.hitTest(point, with: event)
        }
    }

    final class Coordinator: NSObject, UIPointerInteractionDelegate {
        func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
            let style = UIPointerStyle(shape: .verticalBeam(length: 24), constrainedAxes: [])
            style.accessories = [UIPointerAccessory.arrow(.left), UIPointerAccessory.arrow(.right)]
            return style
        }
    }
}
