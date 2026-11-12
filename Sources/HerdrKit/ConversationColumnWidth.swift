import Foundation

/// The conversation column's width on regular width (iPad, Mac, iPhone Duo's inner display),
/// shared by Chat and Gram (#523 items 2 and 12, #541): the reader drags either edge of the
/// column to resize it around its centre, between `minimum(available:)` and the whole width
/// the conversation has (Full), with snap points at Readable, Wide and Full. The composer
/// takes the same width.
///
/// One width for both, remembered per device under `storageKey`: resizing Chat resizes Gram
/// and the other way round. A window narrower than the stored width shows the window's width
/// (`displayed`) and leaves the stored width alone, so widening the window again brings the
/// chosen width back.
public enum ConversationColumnWidth {
    public static let storageKey = "conversation.columnWidth"
    /// Where the width lived while only Chat had it. `migrate(_:)` moves it to `storageKey`.
    public static let legacyChatStorageKey = "chat.columnWidth"

    /// Moves a width stored under `legacyChatStorageKey` to `storageKey`, so a reader who sized
    /// Chat keeps that width (now Gram's too). A width already under `storageKey` wins. Run at
    /// launch, before any view reads the width.
    public static func migrate(_ defaults: UserDefaults) {
        guard let legacy = defaults.object(forKey: legacyChatStorageKey) else { return }
        if defaults.object(forKey: storageKey) == nil, let width = (legacy as? NSNumber)?.doubleValue {
            defaults.set(width, forKey: storageKey)
        }
        defaults.removeObject(forKey: legacyChatStorageKey)
    }

    /// The narrowest the column goes where the conversation has room for it (#523). A
    /// narrower conversation can still be narrowed by `travel` (`minimum(available:)`).
    public static let minimum: Double = 560
    /// How far a conversation too narrow for `minimum` can still be narrowed: 100 pt of drag
    /// on each edge. iPhone Duo's inner display held wide shows the chat 547 pt wide beside the
    /// sidebar, under 560, so its handles moved nothing until a narrow conversation had this.
    public static let travel: Double = 200
    /// The narrowest column there is: 320 pt, the sidebar's own minimum, and narrower than
    /// any phone's chat. A conversation that cannot be narrowed by `travel` without going below
    /// it is not resizable: it is shown whole, without handles, as on a phone. iPhone Duo's
    /// inner display held tall shows the chat 349 pt wide beside the sidebar.
    public static let narrowest: Double = 320
    public static let readable: Double = 720
    public static let wide: Double = 1000
    /// What Full stores: wider than any window, so it always shows as the whole width the
    /// conversation has, in this window and in a wider one.
    public static let full: Double = 100_000
    public static let defaultWidth = wide
    /// How close (in points) a dragged width must come to a snap point to land on it.
    public static let snapDistance: Double = 12
    /// One accessibility increment or decrement.
    public static let step: Double = 40

    public enum Edge: Sendable, Equatable {
        case leading, trailing
    }

    public enum Snap: String, Sendable, Equatable {
        case readable = "Readable"
        case wide = "Wide"
        case full = "Full"
    }

    public struct SnapPoint: Sendable, Equatable {
        public let width: Double
        public let snap: Snap
    }

    /// A stored value made safe to lay out: an unusable one (not finite, not positive) is the
    /// default; any other is held between `narrowest` and `full`.
    public static func sanitized(_ stored: Double) -> Double {
        guard stored.isFinite, stored > 0 else { return defaultWidth }
        return min(full, max(narrowest, stored))
    }

    /// The narrowest the column goes in a conversation `available` wide: `minimum`, or, where
    /// that would leave less than `travel` to narrow by (iPhone Duo's inner display, a portrait
    /// iPad beside the sidebar), `available` less `travel`.
    public static func minimum(available: Double) -> Double {
        max(0, min(minimum, available - travel))
    }

    /// Whether a conversation `available` wide shows the resize handles: it can be narrowed by
    /// `travel` and stay at least `narrowest`, so at least 520 pt wide. Narrower (iPhone Duo's
    /// inner display held tall beside the sidebar) it is shown whole, as on a phone.
    public static func isResizable(available: Double) -> Bool {
        available >= narrowest + travel
    }

    /// The width the column shows: the stored width held to this conversation's minimum, or
    /// all of `available` when that is narrower. A conversation too narrow to resize
    /// (`isResizable`) has no handles, so it always shows whole: a width narrowed on a wider
    /// screen (547 pt down to 347, then folded to 349) would otherwise stay with no handle to
    /// widen it. Never written back: the stored width applies again where there is room.
    public static func displayed(stored: Double, available: Double) -> Double {
        guard isResizable(available: available) else { return max(0, available) }
        return clamped(sanitized(stored), available: available)
    }

    /// `width` held between `minimum(available:)` and `available`.
    public static func clamped(_ width: Double, available: Double) -> Double {
        min(max(0, available), max(minimum(available: available), width))
    }

    /// The snap points that fit in `available`, in label order: Readable, Wide, then Full
    /// (the whole width).
    public static func snapPoints(available: Double) -> [SnapPoint] {
        var points: [SnapPoint] = []
        if readable <= available { points.append(SnapPoint(width: readable, snap: .readable)) }
        if wide <= available { points.append(SnapPoint(width: wide, snap: .wide)) }
        points.append(SnapPoint(width: max(0, available), snap: .full))
        return points
    }

    /// `width` moved onto the nearest snap point within `snapDistance`, else unchanged.
    public static func snapped(_ width: Double, available: Double) -> Double {
        let nearest = snapPoints(available: available).min { abs($0.width - width) < abs($1.width - width) }
        guard let nearest, abs(nearest.width - width) <= snapDistance else { return width }
        return nearest.width
    }

    /// The width after dragging `edge` by `translation` points (positive is rightwards) from a
    /// column `start` wide. Both edges move, so the column stays centred and its width changes
    /// by twice the drag: wider when an edge moves outwards. Rounded to whole points, held
    /// between `minimum(available:)` and `available`, then snapped.
    public static func dragged(from start: Double, translation: Double, edge: Edge, available: Double) -> Double {
        let outwards = edge == .trailing ? translation : -translation
        return snapped(clamped((start + 2 * outwards).rounded(), available: available), available: available)
    }

    /// What to store for a width the reader chose in a conversation `available` wide: Readable and
    /// Wide as themselves, the whole width as `full` (so a wider window widens it too), any
    /// other width as it is.
    public static func stored(for width: Double, available: Double) -> Double {
        if abs(width - readable) < 0.5 { return readable }
        if abs(width - wide) < 0.5 { return wide }
        if width >= available - 0.5 { return full }
        return width
    }

    /// What a reset stores: Wide. A conversation narrower than Wide shows it as Full.
    public static let resetWidth = wide

    /// The snap point `width` sits on, if any.
    public static func snap(at width: Double, available: Double) -> Snap? {
        snapPoints(available: available).first { abs($0.width - width) < 0.5 }?.snap
    }

    /// The readout shown while dragging: "820 pt", or "720 pt · Readable" on a snap point.
    public static func readout(_ width: Double, available: Double) -> String {
        let points = "\(Int(width.rounded())) pt"
        guard let snap = snap(at: width, available: available) else { return points }
        return points + " · " + snap.rawValue
    }

    /// A handle's accessibility value: "820 points", or "720 points, Readable" on a snap point.
    public static func accessibilityValue(_ width: Double, available: Double) -> String {
        let points = "\(Int(width.rounded())) points"
        guard let snap = snap(at: width, available: available) else { return points }
        return points + ", " + snap.rawValue
    }

    /// One accessibility increment: `step` points wider, stopping on a snap point on the way,
    /// held to `available`.
    public static func incremented(_ width: Double, available: Double) -> Double {
        let target = width + step
        let crossed = snapPoints(available: available).map(\.width)
            .filter { $0 > width + 0.5 && $0 < target - 0.5 }.min()
        return clamped(crossed ?? target, available: available)
    }

    /// One accessibility decrement: `step` points narrower, stopping on a snap point on the
    /// way, held to `minimum(available:)`.
    public static func decremented(_ width: Double, available: Double) -> Double {
        let target = width - step
        let crossed = snapPoints(available: available).map(\.width)
            .filter { $0 < width - 0.5 && $0 > target + 0.5 }.max()
        return clamped(crossed ?? target, available: available)
    }
}
