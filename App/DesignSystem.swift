import SwiftUI
import HerdrKit

// Design tokens for herdr mobile, taken from the Claude Design kit
// (herdr mobile.dc.html + DESIGN-BRIEF.md). The brief's rules are load-bearing:
// deep desaturated navy ground (never black); colour is MEANING, not decoration
// (amber = waiting on you, red = died, blue = working, green = done); monospace is
// the MACHINE voice, a proportional sans is the APP voice.
//
// Fonts: Geist (app voice) + IBM Plex Mono (machine voice) — the families the Claude
// Design is set in — are bundled under App/Fonts/ and registered via UIAppFonts.
// Typography addresses them by PostScript name, so call sites never touch Font directly.
//
// The values live in design/tokens.json, shared with Herdrup Desktop, and reach Swift as
// `DesignTokens` (App/Generated/DesignTokens.swift, written by Tools/tokens/generate.py).
// Change a colour or a font there, never here.

enum Palette {
    // Named for the Claude Design token table (herdr mobile.dc.html). Each token is a
    // ROLE, not just a colour: the app floats on `ground`; the terminal is its own
    // darker `groundMachine`, one shade under; surfaces sit above the ground; rules
    // divide them. (The earlier build shifted these — app ground was the terminal's
    // near-black and every surface was one step off; this restores the spec.)
    private typealias Dark = DesignTokens.Color.Dark
    private typealias Status = DesignTokens.Status

    static let ground = Color(hex: Dark.ground)                 // app ground — deep desaturated indigo, NEVER black
    static let groundMachine = Color(hex: Dark.groundMachine)   // terminal ONLY — its own ground, one shade under
    static let surface = Color(hex: Dark.surface)               // cards, fields, rows
    static let card = surface                                   // a card IS a surface (alias, kept for call sites)
    static let surfaceRaised = Color(hex: Dark.surfaceRaised)   // active tab, pressed state, key panel
    static let hairline = Color(hex: Dark.hairline)             // rule — hairline around a surface
    static let hairlineQuiet = Color(hex: Dark.hairlineQuiet)   // rule-quiet — section rules and dividers

    // Text tiers (ink).
    static let text = Color(hex: Dark.text)                     // ink — what matters; also the only fill on acting controls
    static let textDim = Color(hex: Dark.textDim)               // ink-second — supporting text, terminal body
    static let textFaint = Color(hex: Dark.textFaint)           // ink-third — machine metadata, ages, folder names

    // The design has NO accent colour: acting controls (Connect, Approve) are filled
    // with `text` (ink). `brand` (violet) is retired per-screen in the layout slices;
    // kept here unchanged until those call sites migrate to the ink fill.
    static let brand = Color(hex: Dark.brand)
    /// Text and glyphs ON a coloured fill (Gram's violet bubble, its send button, the selected
    /// conversation row, an agent avatar's gradient): pure white (spec #FFFFFF).
    static let onAccent = Color(hex: Dark.onAccent)
    /// Secondary text on the same fills (a selected row's preview and time): white at 82 %.
    static let onAccentDim = onAccent.opacity(Dark.onAccentDimOpacity)

    // Status = meaning. The ONLY palette that carries colour.
    static let waiting = Color(hex: Status.waiting)             // amber — an agent is asking you
    static let died = Color(hex: Status.died)                   // red — exited / crashed
    static let working = Color(hex: Status.working)             // blue — running
    static let done = Color(hex: Status.done)                   // green — finished
}

/// Type roles. The contrast encodes WHO is speaking (brief §6). Both families are
/// bundled (App/Fonts/) and addressed by PostScript name. Sizes are FIXED
/// (`fixedSize:`) — the prior build used `.system(size:)`, which does NOT scale with
/// Dynamic Type, and the layout relies on hard-coded frame heights (e.g. the reserved
/// subtitle line, the terminal keycaps) that would clip if type scaled. Keeping the
/// fixed contract avoids that regression; a Dynamic-Type pass is its own later audit.
/// A requested weight maps to the nearest of the four bundled cuts (400/500/600/700).
enum Typography {
    /// User text-size multiplier (1.0 = default). Set at the app root from the
    /// "Text size" setting; the three members below multiply their point size by
    /// it, so ALL app chrome scales together with no call-site changes. The
    /// terminal has its own font control and does not go through `Typography`.
    static var scale: CGFloat = 1

    /// App voice — Geist (screen titles, names, buttons, labels).
    static func app(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(geistName(weight), fixedSize: size * scale)
    }
    /// Machine voice — IBM Plex Mono (terminal, pane ids, status words, counts, keys).
    static func machine(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(plexMonoName(weight), fixedSize: size * scale)
    }
    /// Uppercase micro-label for section headers (machine voice, semibold).
    /// Computed (not a `let`) so it also honors `scale`.
    static var microLabel: Font {
        .custom(DesignTokens.TypeRole.MicroLabel.postscript,
                fixedSize: CGFloat(DesignTokens.TypeRole.MicroLabel.size) * scale)
    }

    // Nearest bundled cut → its exact PostScript name. IBM Plex Mono's are irregular
    // (Regular is bare "IBMPlexMono"; Medium/SemiBold are abbreviated "-Medm"/"-SmBld").
    static func geistName(_ w: Font.Weight) -> String {
        typealias Faces = DesignTokens.Font.App.Faces
        switch w {
        case .medium: return Faces.Medium.postscript
        case .semibold: return Faces.Semibold.postscript
        case .bold, .heavy, .black: return Faces.Bold.postscript
        default: return Faces.Regular.postscript
        }
    }
    static func plexMonoName(_ w: Font.Weight) -> String {
        typealias Faces = DesignTokens.Font.Machine.Faces
        switch w {
        case .medium: return Faces.Medium.postscript
        case .semibold: return Faces.Semibold.postscript
        case .bold, .heavy, .black: return Faces.Bold.postscript
        default: return Faces.Regular.postscript
        }
    }
}

/// The VISUAL half of the status story. The CLASSIFICATION — which agent belongs
/// in which section, fail-closed, stopped-from-liveness, unknowns surfaced — is
/// HerdrKit's `AgentGroup` (Sources/HerdrKit/AgentList.swift), which is unit
/// tested on Linux. This is only the colour + heading each group renders as, so
/// the meaning and its picture cannot drift out of one file.
///
/// Colour = meaning (brief): amber = wants a look (blocked OR uninterpretable),
/// red = the pane is gone, blue = working, faint = idle. `.unrecognised` is amber
/// on purpose — "this build cannot read it" is nearer to needs-attention than to
/// nothing-to-do, the same reasoning that sorts it high.
extension AgentGroup {
    var color: Color {
        switch self {
        case .needsYou: return Color(hex: DesignTokens.Group.needsYou)
        case .stopped: return Color(hex: DesignTokens.Group.stopped)
        case .unrecognised: return Color(hex: DesignTokens.Group.unrecognised)
        case .working: return Color(hex: DesignTokens.Group.working)
        case .idle: return Color(hex: DesignTokens.Group.idle)
        }
    }

    /// Uppercase micro-label heading, from the model's own label.
    var sectionTitle: String { label.uppercased() }

    /// The label in sentence case ("Needs you", "Working"): the agent header's status line.
    var sentenceLabel: String { label.prefix(1).uppercased() + label.dropFirst() }
}

/// A subtle gradient carrying agent identity — the one place colour is allowed to
/// be decorative (brief §5, from the Termius reference). Keyed by agent kind.
enum AgentIdentity {
    static func gradient(for agent: String?) -> LinearGradient {
        linear(stops(for: agent))
    }

    /// The gradient's colours, top-leading first.
    static func stops(for agent: String?) -> [UInt32] {
        switch (agent ?? "").lowercased() {
        case let s where s.contains("claude"): return DesignTokens.AgentGradient.claude   // magenta
        case let s where s.contains("codex"):  return DesignTokens.AgentGradient.codex    // orange
        case let s where s.contains("gemini"): return DesignTokens.AgentGradient.gemini   // indigo (kept off the working blue)
        default:                                 return DesignTokens.AgentGradient.default  // violet
        }
    }

    private static func linear(_ stops: [UInt32]) -> LinearGradient {
        LinearGradient(colors: stops.map { Color(hex: $0) },
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// One glyph for the identity chip. Distinct per kind so two same-coloured
    /// icons never collide on a bare first letter (claude/codex both → "C").
    /// The marks echo each vendor: Claude's spoked asterisk, a plain C for codex.
    static func glyph(for agent: String?) -> String {
        switch (agent ?? "").lowercased() {
        // U+2731 HEAVY ASTERISK, NOT U+2733: the eight-spoked asterisk has an
        // emoji-presentation variant that iOS renders as a green emoji, ignoring
        // the white foreground. U+2731 has no emoji form, so it stays white.
        case let s where s.contains("claude"): return "\u{2731}"   // ✱
        case let s where s.contains("codex"):  return "C"
        case let s where s.contains("gemini"): return "\u{2726}"   // ✦ four-pointed star
        default:
            // First letter, but never an empty tile: an empty or whitespace kind
            // falls back to "?" like a nil one. (Two kinds sharing a first letter
            // still differ by gradient colour; a blank tile differs from nothing.)
            let first = String((agent ?? "").trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
            return first.isEmpty ? "?" : first
        }
    }

    static func glyph(forName name: String) -> String {
        AgentPresentation.initial(for: name)
    }

    static func gradient(forName name: String) -> LinearGradient {
        linear(stops(forName: name))
    }

    /// The colours for a name's stable colour index, top-leading first.
    static func stops(forName name: String) -> [UInt32] {
        switch AgentPresentation.colorIndex(for: name) {
        case 0: return DesignTokens.AgentGradient.default
        case 1: return DesignTokens.AgentGradient.claude
        case 2: return DesignTokens.AgentGradient.codex
        default: return DesignTokens.AgentGradient.gemini
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}

private struct StatusMotionKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether `TurningRing` and `ActivitySpinner` may move. False where they stay built but are
    /// not on screen: a kept-alive pane behind another tab or pane, a roster the pane covers.
    /// A repeating animation nobody can see still drives SwiftUI's display link every frame
    /// (#427: an idle Mac app at 66% CPU).
    var statusMotion: Bool {
        get { self[StatusMotionKey.self] }
        set { self[StatusMotionKey.self] = newValue }
    }
}

/// The "working" status shape — a thin broken ring, turning. Colour carries the
/// meaning (the working blue); the motion says "live" without claiming a duration.
/// It holds still while `statusMotion` is off.
struct TurningRing: View {
    var color: Color
    /// The defaults are the inline badge size, so the
    /// agent-list call site is unchanged. The sign-in flow's "starting" composition asks
    /// for a larger ring (30/2) because it is the only thing on the screen, and the same
    /// ring inline (13/1.6) while a code is in flight.
    var diameter: CGFloat = 13
    var lineWidth: CGFloat = 1.6
    @Environment(\.statusMotion) private var statusMotion
    var body: some View {
        let ring = Circle().trim(from: 0, to: 0.72)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: diameter, height: diameter)
        // Stopping means removing the motion: a repeatForever animation keeps running
        // after its value is set back without one. Each start is a new `Spinning`, fresh state.
        Group {
            if statusMotion {
                ring.modifier(Spinning())
            } else {
                ring
            }
        }
        #if DEBUG
        .modifier(StatusShapeID(id: "status-ring"))
        #endif
    }
}

private struct Spinning: ViewModifier {
    @State private var spin = false
    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear {
                StatusMotion.start(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
            }
            #if DEBUG
            .modifier(StatusMotionTally())
            #endif
    }
}

/// The status badge on a Messages-style agent row's avatar (#352). Status is SHAPE +
/// colour, never colour alone — desaturate the screen and it still sorts: ! in a circle
/// waits, × in a rounded SQUARE stopped, a turning ring works. An unreachable remote
/// agent's status is a stale last-known value, so it shows a muted offline square (gone,
/// not live), never a live badge. Idle has no badge.
enum AgentAvatarBadge: Equatable {
    case waiting, stopped, unrecognised, working, offline, none

    init(_ group: AgentGroup) {
        switch group {
        case .needsYou: self = .waiting
        case .stopped: self = .stopped
        case .unrecognised: self = .unrecognised
        case .working: self = .working
        case .idle: self = .none
        }
    }
}

/// The round avatar of a Messages-style agent row: the agent's picture (`AgentAvatarView`:
/// its photo or mascot, its initial tile by default, herdrup#538), with the status as a 22 pt badge on
/// its lower-right edge, ringed with the ground colour. The owner's roster and a guest's
/// shared-agent list draw the same avatar.
struct AgentAvatar: View {
    let name: String
    let badge: AgentAvatarBadge
    /// What VoiceOver reads for the badge: the status is colour + shape, so it is named.
    let badgeLabel: String
    var diameter: CGFloat = DesignTokens.Size.avatarPhone
    /// The fallback circle's initial size (an unknown mascot id or a missing asset).
    var glyphSize: CGFloat = DesignTokens.Size.avatarGlyphPhone
    /// The agent whose picture this is; nil draws the default.
    var info: AgentInfo? = nil
    /// The photo sheet's crop preview, shown instead of the agent's current picture.
    var preview: UIImage? = nil

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let preview {
                Image(uiImage: preview).resizable().interpolation(.high)
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Palette.hairline, lineWidth: DesignTokens.Size.hairline))
            } else {
                AgentAvatarView(agent: info, name: name, size: diameter, glyphSize: glyphSize)
            }
            badgeView
                .accessibilityLabel(Text(badgeLabel))
                .offset(x: DesignTokens.Size.statusBadgeOffset, y: DesignTokens.Size.statusBadgeOffset)
        }
    }

    @ViewBuilder
    private var badgeView: some View {
        switch badge {
        case .waiting: glyph("exclamationmark", Palette.waiting, square: false)
        case .unrecognised: glyph("questionmark", Palette.waiting, square: false)
        case .stopped: glyph("xmark", Palette.died, square: true)
        case .offline: glyph("wifi.slash", Palette.surfaceRaised, square: true, ink: Palette.textDim)
        case .working:
            TurningRing(color: Palette.working, diameter: 12, lineWidth: 2)
                .frame(width: DesignTokens.Size.statusBadge, height: DesignTokens.Size.statusBadge)
                .background(Circle().fill(Palette.ground))
                .overlay(Circle().stroke(Palette.ground, lineWidth: DesignTokens.Size.statusBadgeStroke))
        case .none:
            EmptyView()
        }
    }

    private func glyph(_ system: String, _ fill: Color, square: Bool, ink: Color = Palette.ground) -> some View {
        let shape = RoundedRectangle(cornerRadius: square ? DesignTokens.Radius.badgeSquare : 11)
        return Image(systemName: system)
            .font(.system(size: 10, weight: .heavy)).foregroundStyle(ink)
            .frame(width: DesignTokens.Size.statusBadge, height: DesignTokens.Size.statusBadge)
            .background(shape.fill(fill))
            .overlay(shape.stroke(Palette.ground, lineWidth: DesignTokens.Size.statusBadgeStroke))
    }
}

/// The activity indicator (owner picks 2026-11-24, items 6 and 12): eight spokes in the working
/// blue, fading round behind the leading one, one step per spoke, 0.8 s a turn. The in-progress
/// mark beside "Working" in the agent's header, the topic rows and the topic's header; herdrup-desktop
/// draws the same (`.activity-spinner`, src/buttons.css). Like `TurningRing`, it holds still while
/// `statusMotion` is off, and in UI tests run with animations off (a clock that ticks forever would
/// hold up XCUITest's idle wait).
struct ActivitySpinner: View {
    var color: Color = Palette.working
    var diameter: CGFloat = 11
    @Environment(\.statusMotion) private var statusMotion

    /// The spokes' opacities, leading spoke first (desktop's conic stops).
    private static let fades: [Double] = [1, 0.86, 0.72, 0.58, 0.46, 0.36, 0.28, 0.22]
    private static let step: TimeInterval = 0.1

    var body: some View {
        Group {
            if statusMotion && !UITestMotion.off {
                TimelineView(.periodic(from: .now, by: Self.step)) { context in
                    spokes(Int(context.date.timeIntervalSinceReferenceDate / Self.step) % 8)
                }
                #if DEBUG
                .modifier(StatusMotionTally())
                #endif
            } else {
                spokes(0)
            }
        }
        .frame(width: diameter, height: diameter)
        #if DEBUG
        .modifier(StatusShapeID(id: "status-spinner"))
        #endif
    }

    /// The wheel with its leading spoke at `lead` (0 = 12 o'clock), the fade trailing anticlockwise.
    private func spokes(_ lead: Int) -> some View {
        ZStack {
            ForEach(0..<8, id: \.self) { index in
                Capsule()
                    .fill(color.opacity(Self.fades[index]))
                    .frame(width: max(1.5, diameter * 0.17), height: diameter * 0.3)
                    .offset(y: -diameter * 0.33)
                    .rotationEffect(.degrees(Double(lead - index) * 45))
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

private enum StatusMotion {
    /// Starts a status shape's repeating animation once the update that showed it is over.
    /// Started inside that update, the one coming back with a tab switch (Agents → Gram →
    /// Agents) never ran: the ring sat still (build 203).
    static func start(_ animation: Animation, _ change: @escaping () -> Void) {
        DispatchQueue.main.async { withAnimation(animation, change) }
    }
}

#if DEBUG
/// For the UI tests: how many `TurningRing`s and `ActivitySpinner`s are moving right now (their
/// `Spinning` motion or the spinner's clock is in the view tree), so a test can hold a screen to
/// "nothing hidden animates" (`status-motion`). Whether a shown shape really moves, the
/// tests see on screen.
@MainActor
enum StatusMotionCount {
    fileprivate(set) static var count = 0
}

private struct StatusMotionTally: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { StatusMotionCount.count += 1 }
            .onDisappear { StatusMotionCount.count -= 1 }
    }
}

/// For the UI tests, in the screenshot mock only: the status shape as an element of its own,
/// so a test can photograph it and see whether it moves. The label is left to the call site.
private struct StatusShapeID: ViewModifier {
    let id: String
    func body(content: Content) -> some View {
        if ScreenshotMock.mode != nil {
            content.accessibilityElement().accessibilityIdentifier(id)
        } else {
            content
        }
    }
}

/// The `status-motion` probe: `StatusMotionCount.count` as its label, polled. Its own view and
/// state, so the poll re-renders this probe alone.
struct StatusMotionProbe: View {
    @State private var count = 0

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier("status-motion")
            .accessibilityLabel("\(count)")
            .allowsHitTesting(false)
            .task {
                while !Task.isCancelled {
                    if StatusMotionCount.count != count { count = StatusMotionCount.count }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
    }
}
#endif

// MARK: - Buttons

/// The one button (owner, 2026-11-24: "Lets make all capsules"): every labelled button and text
/// action is a capsule at rest, weight 600, in the heights herdrup-desktop uses (`src/buttons.css`):
/// regular 34 pt / 14, large 44 pt / 15 (a sheet's or dialog's actions), compact 28 pt / 13 (an
/// action in a line of text or a dense bar). The variant changes the fill, never the shape.
/// Icon-only buttons are circles (`CircleIconButtonStyle`). List rows, menu items, cards, inputs
/// and the segments of a segmented control draw their own shapes; system dialogs and toolbar
/// items are drawn by iOS.
enum CapsuleVariant {
    /// Ink fill, ground label: the place's main action (Start, Create, Approve, Submit).
    case filled
    /// Raised fill, hairline, ink label: the default.
    case secondary
    /// A see-through ink tint, no border: text-weight actions (Copy, Dismiss, Back).
    case plain
    /// No fill, the died ink on the label and a tinted hairline (Revoke).
    case destructive

    var ink: Color {
        switch self {
        case .filled: return Palette.ground
        case .secondary, .plain: return Palette.text
        case .destructive: return Palette.died
        }
    }

    var fill: Color {
        switch self {
        case .filled: return Palette.text
        case .secondary: return Palette.surfaceRaised
        case .plain: return Palette.text.opacity(0.08)
        case .destructive: return .clear
        }
    }

    var stroke: Color? {
        switch self {
        case .secondary: return Palette.hairline
        case .destructive: return Palette.died.opacity(0.45)
        case .filled, .plain: return nil
        }
    }
}

enum CapsuleSize {
    case compact, regular, large

    var height: CGFloat {
        switch self {
        case .compact: return 28
        case .regular: return 34
        case .large: return 44
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .compact: return 13
        case .regular: return 14
        case .large: return 15
        }
    }

    var paddingX: CGFloat {
        switch self {
        case .compact: return 12
        case .regular: return 16
        case .large: return 22
        }
    }
}

/// The capsule's look on any label: `CapsuleButtonStyle`'s body, and the label of a control whose
/// button is something larger (the install command's Copy, inside the command's card).
struct CapsuleLook: ViewModifier {
    var variant: CapsuleVariant
    var size: CapsuleSize
    var fullWidth = false
    /// A place with its own text size (the chat's) scales the capsule with it.
    var textScale: CGFloat = 1
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let height = (size.height * Typography.scale * textScale).rounded()
        content
            .font(Typography.app(size.fontSize * textScale, .semibold))
            .foregroundStyle(variant.ink)
            .padding(.horizontal, size.paddingX)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .background(Capsule().fill(variant.fill))
            .overlay {
                if let stroke = variant.stroke { Capsule().strokeBorder(stroke, lineWidth: 1) }
            }
            // At least 44 pt to touch: the compact and regular capsules reach past their edges,
            // up and down only, so a neighbour in the same row never loses its taps.
            .contentShape(.interaction, TouchTarget(outset: max(0, (44 - height) / 2)))
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// A capsule's touch area: its frame, `outset` taller above and below.
private struct TouchTarget: Shape {
    var outset: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: 0, dy: -outset))
    }
}

struct CapsuleButtonStyle: ButtonStyle {
    var variant: CapsuleVariant = .secondary
    var size: CapsuleSize = .regular
    var fullWidth = false
    var textScale: CGFloat = 1

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(CapsuleLook(variant: variant, size: size, fullWidth: fullWidth, textScale: textScale))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

extension ButtonStyle where Self == CapsuleButtonStyle {
    /// `.buttonStyle(.capsule(.filled, .large))`: the one button, see `CapsuleVariant`.
    static func capsule(_ variant: CapsuleVariant = .secondary, _ size: CapsuleSize = .regular,
                        fullWidth: Bool = false, textScale: CGFloat = 1) -> CapsuleButtonStyle {
        CapsuleButtonStyle(variant: variant, size: size, fullWidth: fullWidth, textScale: textScale)
    }
}

/// An icon-only button: the capsule with equal width and height, a circle (owner, 2026-11-24).
/// Touchable over at least 44 pt.
struct CircleIconButtonStyle: ButtonStyle {
    var variant: CapsuleVariant = .secondary
    var diameter: CGFloat = 28
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let size = (diameter * Typography.scale).rounded()
        configuration.label
            .font(.system(size: (size * 0.43).rounded(), weight: .semibold))
            .foregroundStyle(variant.ink)
            .frame(width: size, height: size)
            .background(Circle().fill(variant.fill))
            .overlay {
                if let stroke = variant.stroke { Circle().strokeBorder(stroke, lineWidth: 1) }
            }
            .contentShape(.interaction, Circle().inset(by: -max(0, (44 - size) / 2)))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.5)
    }
}

extension ButtonStyle where Self == CircleIconButtonStyle {
    /// `.buttonStyle(.circle())`: an icon-only button, see `CircleIconButtonStyle`.
    static func circle(_ variant: CapsuleVariant = .secondary, diameter: CGFloat = 28) -> CircleIconButtonStyle {
        CircleIconButtonStyle(variant: variant, diameter: diameter)
    }
}

extension Binding {
    /// A `Bool` binding that is true while the wrapped optional holds a value, and clears it
    /// when set to false: the `isPresented:` of an alert or dialog driven by optional state.
    func isPresent<Wrapped>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(get: { wrappedValue != nil }, set: { if !$0 { wrappedValue = nil } })
    }
}
