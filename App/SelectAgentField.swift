import CoreText
import SpriteKit
import SwiftUI
import UIKit

/// The iPad and Mac detail column before an agent is open: "Select an agent" over a quiet
/// field of terminal glyphs that wakes under the pointer or a finger, ripples on a tap, and
/// has the roster's agents type their current activity into it. Hovering a sidebar row makes
/// that agent type its line at the row's height.
///
/// Approved as proposal B ("Terminal") of the select-agent motion study, without the
/// square.grid icon above the label.
struct SelectAgentPlaceholder: View {
    let lines: [TerminalGlyphFieldView.Line]
    let spotlight: TerminalGlyphFieldView.Spotlight

    var body: some View {
        ZStack {
            TerminalGlyphField(lines: lines, spotlight: spotlight)
                .accessibilityHidden(true)
            Text("Select an agent")
                .font(Typography.app(DesignTokens.Text.Placeholder.size, DesignTokens.Text.Placeholder.weight))
                .foregroundStyle(Palette.textDim)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TerminalGlyphField: UIViewRepresentable {
    let lines: [TerminalGlyphFieldView.Line]
    let spotlight: TerminalGlyphFieldView.Spotlight

    func makeUIView(context: Context) -> TerminalGlyphFieldView {
        let view = TerminalGlyphFieldView()
        spotlight.field = view
        view.lines = lines
        return view
    }

    func updateUIView(_ view: TerminalGlyphFieldView, context: Context) {
        spotlight.field = view
        if view.lines != lines { view.lines = lines }
    }
}

/// The glyph field. The quiet resting field is one image, redrawn off the main thread every
/// couple of seconds so it twinkles. Only cells that are moving — under the lens, in a ripple,
/// or being typed — get a sprite, drawn from one glyph atlas so SpriteKit batches them. A
/// typical frame touches a few hundred sprites, never the whole column.
final class TerminalGlyphFieldView: UIView {
    /// One agent's line as it types into the field: "name › folder · activity".
    struct Line: Equatable {
        let id: String
        let text: String
        let tone: Tone
    }

    /// The status colours the field may type in; raw values index `palette`.
    enum Tone: UInt8 {
        case dim = 3, waiting = 5, working = 6, done = 7, died = 8
    }

    /// Receives sidebar-row hover without touching SwiftUI state, so hovering the roster never
    /// re-renders the home view.
    @MainActor
    final class Spotlight {
        fileprivate weak var field: TerminalGlyphFieldView?
        private var currentID: String?

        /// Called continuously while the pointer is over a row; speaks once per row entered.
        func hover(_ line: TerminalGlyphFieldView.Line, globalY: CGFloat) {
            guard line.id != currentID else { return }
            currentID = line.id
            field?.speak(line, globalY: globalY)
        }

        func end(_ id: String) {
            if currentID == id { currentID = nil }
        }
    }

    var lines: [Line] = [] {
        didSet { for line in lines { for character in line.text { _ = glyphIndex(character) } } }
    }

    // MARK: Geometry and palette (points; identical to the approved design)

    private static let cellW: CGFloat = 8
    private static let cellH: CGFloat = 15
    private static let fontSize: CGFloat = 11
    /// Atlas slots and sprites are larger than a cell so glyphs never clip or bleed.
    private static let slotW: CGFloat = 12
    private static let slotH: CGFloat = 19
    /// What the field scrambles through: unique, and the first entries of `characters`, so a
    /// resting index is also an atlas index.
    private static let scrambleCharacters: [Character] = Array("·.:-=+*#%$_/\\|[]{}<>01agen")
    /// quiet, hair, faint, dim, ink, then the status colours (see `Tone`).
    private static let palette: [UIColor] = [
        UIColor(Palette.hairlineQuiet), UIColor(Palette.hairline), UIColor(Palette.textFaint),
        UIColor(Palette.textDim), UIColor(Palette.text), UIColor(Palette.waiting),
        UIColor(Palette.working), UIColor(Palette.done), UIColor(Palette.died),
    ]
    private static let dimIndex: UInt8 = 3
    private static let restIndex = 1
    private static let ground = UIColor(Palette.groundMachine)
    /// Seconds between redraws of the resting field, and the share of cells that change.
    private static let twinklePeriod: Double = 1.6
    private static let twinkleShare = 0.05

    // MARK: Cell state

    private var cols = 0
    private var rows = 0
    /// The resting field's characters (indices into `scrambleCharacters`) and opacity.
    private var restChr: [UInt8] = []
    private var restAlpha: [Float] = []
    /// A moving cell's character (index into `characters`), energy and colour override.
    private var chr: [Int32] = []
    private var energy: [Float] = []
    private var tint: [UInt8] = []
    private var isActive: [Bool] = []
    private var active: [Int] = []

    // MARK: Glyph atlas

    private var characters: [Character] = []
    private var characterIndex: [Character: Int32] = [:]
    private var atlasCharacterCount = 0
    private var textures: [SKTexture] = []
    private lazy var font = UIFont(name: "IBMPlexMono", size: Self.fontSize)
        ?? .monospacedSystemFont(ofSize: Self.fontSize, weight: .regular)

    // MARK: Scene

    private let skView = SilentSKView()
    private let scene = FieldScene()
    private let restNode = SKSpriteNode()
    /// Sprite pairs for moving cells: an opaque square hiding the resting glyph, and the glyph.
    private var covers: [SKSpriteNode] = []
    private var glyphs: [SKSpriteNode] = []
    private var slotOfCell: [Int: Int] = [:]
    private var freeSlots: [Int] = []
    private var cursors: [SKSpriteNode] = []
    private var builtSize: CGSize = .zero
    private var builtScale: CGFloat = 0
    private var generation = 0
    private var restRenderInFlight = false
    private var restRenderPending = false
    private var atlasScale: CGFloat = 0
    private var nextTwinkle: Double = TerminalGlyphFieldView.twinklePeriod
    private static let restQueue = DispatchQueue(label: "herdr.select-agent.rest-field", qos: .utility)

    // MARK: Motion

    private struct Ripple { var x: CGFloat; var y: CGFloat; var r: CGFloat; let tone: UInt8 }
    private struct Writer {
        var cells: [(index: Int, glyph: Int32)]
        let nameLength: Int
        let tone: UInt8
        var t: Double = 0
        let hold: Double
        let speed: Double
    }
    private struct Pointer {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var inside = false
        var down = false
        var ghost = true
        var lastReal: Double = -1e9
    }

    private var ripples: [Ripple] = []
    private var writers: [Writer] = []
    private var nextWrite: Double = 1.2
    private var pointer = Pointer()
    private var clock: Double = 0
    private var lastTime: TimeInterval = 0
    private var lensRadius: CGFloat = 115
    /// The label's clear zone: centre and radii in points.
    private var quiet = (cx: CGFloat(0), cy: CGFloat(0), rx: CGFloat(1), ry: CGFloat(1))
    private var reduceMotion = UIAccessibility.isReduceMotionEnabled

    override init(frame: CGRect) {
        super.init(frame: frame)
        for character in Self.scrambleCharacters { _ = glyphIndex(character) }
        for scalar in 32...126 { _ = glyphIndex(Character(UnicodeScalar(UInt8(scalar)))) }
        for character in "›…—" { _ = glyphIndex(character) }

        backgroundColor = Self.ground
        isMultipleTouchEnabled = false
        skView.isUserInteractionEnabled = false
        skView.ignoresSiblingOrder = true
        skView.preferredFramesPerSecond = 30
        skView.isPaused = true
        addSubview(skView)
        scene.backgroundColor = Self.ground
        scene.anchorPoint = .zero
        scene.scaleMode = .resizeFill
        scene.field = self
        restNode.anchorPoint = .zero
        restNode.zPosition = 0
        skView.presentScene(scene)

        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        NotificationCenter.default.addObserver(
            self, selector: #selector(reduceMotionChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Off screen (an agent is open, or the app is elsewhere) the field costs nothing.
        skView.isPaused = window == nil
        lastTime = 0
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        skView.frame = bounds
        let scale = window?.screen.scale ?? traitCollection.displayScale
        guard bounds.size != builtSize || scale != builtScale else { return }
        rebuild(size: bounds.size, scale: scale)
    }

    @objc private func reduceMotionChanged() {
        reduceMotion = UIAccessibility.isReduceMotionEnabled
    }

    private func rebuild(size: CGSize, scale: CGFloat) {
        builtSize = size
        builtScale = scale
        generation += 1
        scene.removeAllChildren()
        covers = []
        glyphs = []
        slotOfCell = [:]
        freeSlots = []
        cursors = []
        writers = []
        ripples = []
        cols = Int(ceil(size.width / Self.cellW))
        rows = Int(ceil(size.height / Self.cellH))
        guard cols > 4, rows > 2 else { cols = 0; rows = 0; return }

        let labelFont = UIFont(name: "Geist-Medium", size: 15 * Typography.scale)
            ?? .systemFont(ofSize: 15 * Typography.scale, weight: .medium)
        let labelWidth = ("Select an agent" as NSString).size(withAttributes: [.font: labelFont]).width
        quiet = (size.width / 2, size.height / 2, labelWidth / 2 + 30, 30)

        let n = cols * rows
        let scrambleCount = UInt8(Self.scrambleCharacters.count)
        var dice = FieldDice(seed: Self.restFieldSeed)
        restChr = (0..<n).map { _ in UInt8.random(in: 0..<scrambleCount, using: &dice) }
        restAlpha = (0..<n).map { i in
            let x = CGFloat(i % cols) * Self.cellW + Self.cellW / 2
            let y = CGFloat(i / cols) * Self.cellH + Self.cellH / 2
            let edge = min(x, y, size.width - x, size.height - y)
            let vignette = min(max(edge / 120, 0.25), 1)
            let noise = 0.55 + 0.45 * sin(x * 0.021 + sin(y * 0.013) * 2.1) * cos(y * 0.017)
            let keep: CGFloat = Double.random(in: 0..<1, using: &dice) < 0.12 ? 0 : 1
            return Float(keep * vignette * quietFactor(x, y) * (0.5 + 0.5 * noise))
        }
        chr = Array(repeating: 0, count: n)
        energy = Array(repeating: 0, count: n)
        tint = Array(repeating: 0, count: n)
        isActive = Array(repeating: false, count: n)
        active = []

        // Rebuilt only when the screen scale changes (or a new character appears), not per size.
        if scale != atlasScale { buildAtlas() }
        restNode.size = size
        restNode.position = .zero
        // Plain ground until the new size's field arrives from the background render.
        restNode.texture = nil
        scene.addChild(restNode)
        renderRestField()
        for _ in 0..<4 {
            let cursor = SKSpriteNode(color: Self.palette[Int(Self.dimIndex)],
                                      size: CGSize(width: Self.cellW - 1, height: Self.cellH - 4))
            cursor.alpha = 0.8
            cursor.zPosition = 3
            cursor.isHidden = true
            scene.addChild(cursor)
            cursors.append(cursor)
        }
    }

    /// One texture per (character, colour), all cut from a single image so SpriteKit batches them.
    private func buildAtlas() {
        atlasCharacterCount = characters.count
        atlasScale = builtScale
        let across = 64
        let down = (characters.count + across - 1) / across
        let colours = Self.palette.count
        let size = CGSize(width: CGFloat(across) * Self.slotW, height: CGFloat(down * colours) * Self.slotH)
        let format = UIGraphicsImageRendererFormat()
        format.scale = builtScale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            for (ci, colour) in Self.palette.enumerated() {
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
                for (i, character) in characters.enumerated() {
                    let text = String(character) as NSString
                    let glyph = text.size(withAttributes: attributes)
                    let x = CGFloat(i % across) * Self.slotW
                    let y = CGFloat(ci * down + i / across) * Self.slotH
                    text.draw(at: CGPoint(x: x + (Self.slotW - glyph.width) / 2,
                                          y: y + (Self.slotH - glyph.height) / 2 + 0.5),
                              withAttributes: attributes)
                }
            }
        }
        let atlas = SKTexture(image: image)
        atlas.filteringMode = .linear
        textures = []
        textures.reserveCapacity(colours * characters.count)
        for ci in 0..<colours {
            for i in 0..<characters.count {
                // SpriteKit texture rects are unit coordinates with the origin at the bottom.
                let row = ci * down + i / across
                let rect = CGRect(x: CGFloat(i % across) * Self.slotW / size.width,
                                  y: 1 - CGFloat(row + 1) * Self.slotH / size.height,
                                  width: Self.slotW / size.width, height: Self.slotH / size.height)
                textures.append(SKTexture(rect: rect, in: atlas))
            }
        }
    }

    /// Draws the resting field's image off the main thread. Requests made while a render is
    /// running collapse into one follow-up, so a rotation or a window being dragged through
    /// many sizes renders only the latest one; results for a stale size are dropped.
    ///
    /// Only the CoreGraphics drawing runs on `restQueue`; SpriteKit stays on the main thread.
    /// Making and preloading the `SKTexture` on the queue aborted the app at launch (#651:
    /// `_os_unfair_lock_unowned_abort` on this queue, called from code in no registered image,
    /// while the accessibility runtime was `dlopen`ing a bundle on `AXBundleLoadQueue`).
    private func renderRestField() {
        guard !restRenderInFlight else { restRenderPending = true; return }
        restRenderInFlight = true
        restRenderPending = false
        let job = RestFieldJob(
            cols: cols, rows: rows, size: builtSize, scale: builtScale,
            characters: restChr, alpha: restAlpha,
            font: font as CTFont, lineHeight: font.lineHeight, ascender: font.ascender,
            colour: Self.palette[Self.restIndex].cgColor, ground: Self.ground.cgColor,
            glyphs: Self.scrambleCharacters, cellW: Self.cellW, cellH: Self.cellH)
        let generation = generation
        Self.restQueue.async { [weak self] in
            let image = job.render()
            DispatchQueue.main.async {
                guard let self else { return }
                self.restRenderDrawn(image, generation: generation)
            }
        }
    }

    /// On the main thread: the drawn image becomes the resting texture once SpriteKit has it
    /// in GPU memory, so swapping it in never stalls a frame.
    private func restRenderDrawn(_ image: CGImage?, generation: Int) {
        let finish = { [weak self] (texture: SKTexture?) in
            guard let self else { return }
            self.restRenderInFlight = false
            if self.generation == generation, let texture { self.restNode.texture = texture }
            if self.restRenderPending { self.renderRestField() }
        }
        guard let image, self.generation == generation else { finish(nil); return }
        let texture = SKTexture(cgImage: image)
        texture.preload { DispatchQueue.main.async { finish(texture) } }
    }

    private func texture(_ glyph: Int32, _ colour: UInt8) -> SKTexture {
        textures[Int(colour) * atlasCharacterCount + Int(glyph)]
    }

    /// A cell's resting centre in scene coordinates (origin bottom-left).
    private func home(_ i: Int) -> CGPoint {
        CGPoint(x: CGFloat(i % cols) * Self.cellW + Self.cellW / 2,
                y: builtSize.height - (CGFloat(i / cols) * Self.cellH + Self.cellH / 2))
    }

    // MARK: Input

    @objc private func hovered(_ gesture: UIHoverGestureRecognizer) {
        let p = gesture.location(in: self)
        switch gesture.state {
        case .began, .changed:
            pointer.x = p.x; pointer.y = p.y
            pointer.inside = true; pointer.ghost = false; pointer.lastReal = clock
        default:
            if !pointer.down { pointer.inside = false }
            pointer.lastReal = clock
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let p = touch.location(in: self)
        pointer.x = p.x; pointer.y = p.y
        pointer.inside = true; pointer.down = true; pointer.ghost = false; pointer.lastReal = clock
        if !reduceMotion {
            let tones: [Tone] = [.waiting, .working, .done]
            ripples.append(Ripple(x: p.x, y: p.y, r: 0, tone: tones.randomElement()!.rawValue))
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let p = touch.location(in: self)
        pointer.x = p.x; pointer.y = p.y; pointer.lastReal = clock
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }

    private func release(_ touches: Set<UITouch>) {
        pointer.down = false
        pointer.lastReal = clock
        // A finger leaves the glass; a mouse button release keeps hovering.
        if touches.first?.type != .indirectPointer { pointer.inside = false }
    }

    /// A sidebar row is hovered: that agent types its line at the row's height.
    fileprivate func speak(_ line: Line, globalY: CGFloat) {
        guard rows > 2 else { return }
        let y = convert(CGPoint(x: 0, y: globalY), from: nil).y
        let row = min(max(Int((y / Self.cellH).rounded()), 1), rows - 2)
        write(line, column: 2, row: row, hold: 3.5)
    }

    // MARK: Frame

    fileprivate func update(_ currentTime: TimeInterval) {
        // Held still, the field is its first resting picture: no autopilot, no twinkle, no
        // typing. Only the DEBUG reference screenshots ask for that.
        guard cols > 0, !Self.holdsStill else { return }
        let dt = lastTime == 0 ? 1.0 / 60 : min(0.05, currentTime - lastTime)
        lastTime = currentTime
        clock += dt
        step(dt: dt)
        apply()
        decay(dt: dt)
    }

    private func step(dt: Double) {
        // Autopilot: a slow invisible hand when nobody is pointing, so the page never looks dead.
        if !pointer.down && clock - pointer.lastReal > 3.5 {
            if reduceMotion {
                pointer.inside = false
            } else {
                pointer.ghost = true
                pointer.inside = true
                let t = clock * 0.23
                let gx = builtSize.width * (0.5 + 0.34 * sin(t * 1.3) * cos(t * 0.37))
                let gy = builtSize.height * (0.5 + 0.30 * sin(t * 0.9 + 1.2))
                let k = min(1, dt * 1.6)
                pointer.x += (gx - pointer.x) * k
                pointer.y += (gy - pointer.y) * k
            }
        }

        nextTwinkle -= dt
        if nextTwinkle <= 0 && !reduceMotion {
            nextTwinkle = Self.twinklePeriod
            let scrambleCount = UInt8(Self.scrambleCharacters.count)
            for _ in 0..<Int(Double(restChr.count) * Self.twinkleShare) {
                restChr[Int.random(in: 0..<restChr.count)] = UInt8.random(in: 0..<scrambleCount)
            }
            renderRestField()
        }

        lensRadius = pointer.ghost ? 80 : 115
        // 60 fps under a real pointer, a finger or a ripple; the slow autopilot reads the same at 30.
        let fps = pointer.ghost && ripples.isEmpty ? 30 : 60
        if skView.preferredFramesPerSecond != fps { skView.preferredFramesPerSecond = fps }
        if pointer.inside && !reduceMotion { energizeLens(radius: lensRadius) }
        advanceRipples(dt: dt)
        advanceWriters(dt: dt)
    }

    private func energizeLens(radius: CGFloat) {
        let c0 = max(0, Int((pointer.x - radius) / Self.cellW))
        let c1 = min(cols - 1, Int((pointer.x + radius) / Self.cellW))
        let r0 = max(0, Int((pointer.y - radius) / Self.cellH))
        let r1 = min(rows - 1, Int((pointer.y + radius) / Self.cellH))
        guard c0 <= c1, r0 <= r1 else { return }
        let strength: CGFloat = pointer.ghost ? 0.6 : 1
        for r in r0...r1 {
            for c in c0...c1 {
                let x = CGFloat(c) * Self.cellW + Self.cellW / 2
                let y = CGFloat(r) * Self.cellH + Self.cellH / 2
                let d = hypot(x - pointer.x, y - pointer.y)
                guard d < radius else { continue }
                let e = Float(pow(1 - d / radius, 1.4) * strength * (0.25 + 0.75 * quietFactor(x, y)))
                let i = r * cols + c
                guard e > 0.02 else { continue }
                // A cell waking under the lens starts from the character it was resting as.
                if !isActive[i] { chr[i] = Int32(restChr[i]) }
                if e > energy[i] {
                    energy[i] = e
                    if tint[i] > 4 { tint[i] = 0 }
                }
                activate(i)
            }
        }
    }

    private func advanceRipples(dt: Double) {
        let reach = hypot(builtSize.width, builtSize.height)
        ripples = ripples.compactMap { ripple in
            var ripple = ripple
            ripple.r += CGFloat(dt) * 520
            guard ripple.r <= reach else { return nil }
            let step = (Self.cellW * 0.8) / max(ripple.r, 1)
            let fade = max(0.25, 1 - ripple.r / 900)
            var a: CGFloat = 0
            while a < .pi * 2 {
                let x = ripple.x + cos(a) * ripple.r
                let y = ripple.y + sin(a) * ripple.r
                a += step
                guard x >= 0, y >= 0, x < builtSize.width, y < builtSize.height else { continue }
                let i = Int(y / Self.cellH) * cols + Int(x / Self.cellW)
                guard i < energy.count else { continue }
                let e = Float(0.9 * quietFactor(x, y) * fade)
                if e > energy[i] {
                    energy[i] = e
                    tint[i] = ripple.tone
                    chr[i] = randomScramble()
                    activate(i)
                }
            }
            return ripple
        }
    }

    private func advanceWriters(dt: Double) {
        nextWrite -= dt
        if nextWrite <= 0 && writers.count < 3 {
            nextWrite = Double.random(in: 1.4...2.6)
            let speaking = lines.filter { $0.tone != .dim }
            if let line = (speaking.isEmpty ? lines : speaking).randomElement() {
                placeAtRandom(line)
            }
        }
        cursors.forEach { $0.isHidden = true }
        let blinkOn = Int(clock * 2) % 2 == 1
        var cursorCount = 0
        writers = writers.compactMap { writer in
            var w = writer
            w.t += dt
            let shown = min(w.cells.count, Int(w.t * w.speed))
            for j in 0..<shown {
                let cell = w.cells[j]
                chr[cell.index] = cell.glyph
                let age = w.t - Double(j) / w.speed
                let e: Float = age < w.hold ? 1 : Float(max(0, 1 - (age - w.hold) * 0.8))
                energy[cell.index] = max(energy[cell.index] * 0.6, e * 0.95)
                tint[cell.index] = j < w.nameLength ? w.tone : Self.dimIndex
                activate(cell.index)
            }
            if !w.cells.isEmpty, cursorCount < cursors.count,
               shown < w.cells.count || (w.t < w.hold && blinkOn) {
                let at = w.cells[min(shown, w.cells.count - 1)].index
                var p = home(at)
                if shown >= w.cells.count { p.x += Self.cellW }
                cursors[cursorCount].position = p
                cursors[cursorCount].isHidden = false
                cursorCount += 1
            }
            return w.t > w.hold + Double(w.cells.count) / w.speed + 1.5 ? nil : w
        }
    }

    private func placeAtRandom(_ line: Line) {
        let length = line.text.count
        for _ in 0..<12 {
            let r = Int.random(in: 0..<rows)
            let c = Int.random(in: 0..<max(1, cols - length - 2))
            let y = CGFloat(r) * Self.cellH
            let x0 = CGFloat(c) * Self.cellW
            let x1 = x0 + CGFloat(length) * Self.cellW
            guard quietFactor((x0 + x1) / 2, y) >= 1, quietFactor(x0, y) >= 1, quietFactor(x1, y) >= 1 else { continue }
            write(line, column: c, row: r, hold: 2.8)
            return
        }
    }

    /// At most this many lines type at once. Hovering quickly down the sidebar replaces the
    /// oldest line rather than stacking one per row; the evicted cells simply fade.
    private static let maxWriters = 4

    private func write(_ line: Line, column: Int, row: Int, hold: Double) {
        if writers.count >= Self.maxWriters { writers.removeFirst(writers.count - Self.maxWriters + 1) }
        var cells: [(index: Int, glyph: Int32)] = []
        for (j, character) in line.text.enumerated() where column + j < cols {
            cells.append((row * cols + column + j, glyphIndex(character)))
        }
        let nameLength = line.text.firstIndex(of: "›").map { line.text.distance(from: line.text.startIndex, to: $0) }
            ?? line.text.count
        writers.append(Writer(cells: cells, nameLength: nameLength, tone: line.tone.rawValue,
                              hold: hold, speed: Double.random(in: 30...50)))
    }

    /// Pushes every moving cell to its sprite: glyph, colour, opacity and the lens's push.
    private func apply() {
        // A line typed this frame may have brought a character the atlas does not have yet.
        if characters.count != atlasCharacterCount { buildAtlas() }
        let lens = pointer.inside && !reduceMotion
        let radius = lensRadius
        let push: CGFloat = pointer.ghost ? 2.5 : 5
        for i in active {
            let slot = slotOfCell[i] ?? claimSlot(for: i)
            let e = CGFloat(energy[i])
            let colour = tint[i] != 0 ? tint[i] : (e > 0.78 ? 4 : e > 0.45 ? 3 : 2)
            let glyph = glyphs[slot]
            glyph.texture = texture(chr[i], colour)
            glyph.alpha = min(1, 0.2 + e)
            var position = home(i)
            if lens {
                let dx = position.x - pointer.x
                let dy = (builtSize.height - position.y) - pointer.y
                let d = max(hypot(dx, dy), 1)
                if d < radius {
                    let m = sin(.pi * d / radius) * push
                    position.x += dx / d * m
                    position.y -= dy / d * m
                }
            }
            glyph.position = position
        }
    }

    /// Energy fades after drawing, matching the design's per-frame order; hot cells that are
    /// not typed text keep scrambling while they fade.
    private func decay(dt: Double) {
        let dt = Float(dt)
        var survivors: [Int] = []
        survivors.reserveCapacity(active.count)
        for i in active {
            let typed = tint[i] != 0
            if !typed, Float.random(in: 0..<1) < energy[i] * dt * 22 { chr[i] = randomScramble() }
            energy[i] -= dt * (typed ? 0.35 : 1.5)
            if energy[i] <= 0.02 {
                energy[i] = 0
                tint[i] = 0
                isActive[i] = false
                releaseSlot(of: i)
            } else {
                survivors.append(i)
            }
        }
        active = survivors
    }

    // MARK: Sprite pool

    private func claimSlot(for i: Int) -> Int {
        let slot: Int
        if let free = freeSlots.popLast() {
            slot = free
        } else {
            let cover = SKSpriteNode(color: Self.ground, size: CGSize(width: Self.cellW, height: Self.cellH))
            cover.zPosition = 1
            let glyph = SKSpriteNode(texture: nil, size: CGSize(width: Self.slotW, height: Self.slotH))
            glyph.zPosition = 2
            scene.addChild(cover)
            scene.addChild(glyph)
            covers.append(cover)
            glyphs.append(glyph)
            slot = glyphs.count - 1
        }
        covers[slot].position = home(i)
        covers[slot].isHidden = false
        glyphs[slot].isHidden = false
        slotOfCell[i] = slot
        return slot
    }

    private func releaseSlot(of i: Int) {
        guard let slot = slotOfCell.removeValue(forKey: i) else { return }
        covers[slot].isHidden = true
        glyphs[slot].isHidden = true
        freeSlots.append(slot)
    }

    // MARK: Helpers

    private func randomScramble() -> Int32 {
        Int32.random(in: 0..<Int32(Self.scrambleCharacters.count))
    }

    private func glyphIndex(_ character: Character) -> Int32 {
        if let index = characterIndex[character] { return index }
        characters.append(character)
        let index = Int32(characters.count - 1)
        characterIndex[character] = index
        return index
    }

    private func activate(_ i: Int) {
        guard !isActive[i] else { return }
        isActive[i] = true
        active.append(i)
    }

    /// 0 inside the label's clear zone, rising to 1 outside it.
    private func quietFactor(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
        let ex = (x - quiet.cx) / (quiet.rx * 1.1)
        let ey = (y - quiet.cy) / (quiet.ry * 1.05)
        return min(max((ex * ex + ey * ey - 0.55) / 0.9, 0), 1)
    }

    /// The resting field's seed: nil (the system's randomness) except in the DEBUG
    /// `desktopref` mock, whose reference screenshots need the same field every run.
    private static var restFieldSeed: UInt64? {
        #if DEBUG
        return DesktopReferenceMock.glyphFieldSeed
        #else
        return nil
        #endif
    }

    /// Whether the field keeps its first resting picture. Only the DEBUG `desktopref` mock.
    private static var holdsStill: Bool {
        #if DEBUG
        return DesktopReferenceMock.holdsStill
        #else
        return false
        #endif
    }
}

/// The resting field's dice. Without a seed they are the system's; with one they are
/// SplitMix64, so the same seed draws the same field.
private struct FieldDice: RandomNumberGenerator {
    private var state: UInt64?

    init(seed: UInt64?) { state = seed }

    mutating func next() -> UInt64 {
        guard var z = state else {
            var system = SystemRandomNumberGenerator()
            return system.next()
        }
        z &+= 0x9E37_79B9_7F4A_7C15
        state = z
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Everything needed to draw the resting field, copied so it can render off the main thread.
/// CoreGraphics and CoreText calls only: the `UIFont` metrics are read on the main thread, and
/// neither UIKit nor SpriteKit is called on the queue (see `renderRestField`).
private struct RestFieldJob: @unchecked Sendable {
    let cols: Int
    let rows: Int
    let size: CGSize
    let scale: CGFloat
    let characters: [UInt8]
    let alpha: [Float]
    let font: CTFont
    let lineHeight: CGFloat
    let ascender: CGFloat
    let colour: CGColor
    let ground: CGColor
    let glyphs: [Character]
    let cellW: CGFloat
    let cellH: CGFloat

    func render() -> CGImage? {
        let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(ground)
        context.fill(CGRect(origin: .zero, size: size))
        var cg = [CGGlyph](repeating: 0, count: glyphs.count)
        var advance = [CGSize](repeating: .zero, count: glyphs.count)
        for (k, character) in glyphs.enumerated() {
            var unit = Array(String(character).utf16)
            CTFontGetGlyphsForCharacters(font, &unit, &cg[k], 1)
        }
        CTFontGetAdvancesForGlyphs(font, .horizontal, cg, &advance, cg.count)
        // Match NSString drawing: the line box centred in the cell, nudged down half a point.
        let baselineFromTop = (cellH - lineHeight) / 2 + 0.5 + ascender
        context.setFillColor(colour)
        for i in 0..<(cols * rows) {
            let a = alpha[i]
            guard a > 0.01 else { continue }
            let k = Int(characters[i])
            var position = CGPoint(
                x: CGFloat(i % cols) * cellW + (cellW - advance[k].width) / 2,
                y: size.height - (CGFloat(i / cols) * cellH + baselineFromTop))
            context.setAlpha(CGFloat(a))
            CTFontDrawGlyphs(font, &cg[k], &position, 1, context)
        }
        return context.makeImage()
    }
}

/// SpriteKit publishes every sprite as an accessibility element and ignores
/// `accessibilityElementsHidden`: with the field on screen the app exposed ~660 elements
/// instead of ~116, and every VoiceOver or UI-test query had to walk them all. The field is
/// decoration, so this view publishes nothing.
private final class SilentSKView: SKView {
    override var isAccessibilityElement: Bool { get { false } set {} }
    override var accessibilityElements: [Any]? { get { [] } set {} }
    override func accessibilityElementCount() -> Int { 0 }
}

/// Drives the field once per frame from SpriteKit's own loop, which pauses with the view.
private final class FieldScene: SKScene {
    weak var field: TerminalGlyphFieldView?

    override func update(_ currentTime: TimeInterval) {
        field?.update(currentTime)
    }
}
