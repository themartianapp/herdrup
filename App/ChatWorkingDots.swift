import SwiftUI

/// Three gentle pulsing dots shared by `ChatWorkingDots` and live running command rows.
/// Still in UI tests that hold motion still (`UITestMotion`), as `ActivitySpinner`.
struct ChatWorkingWave: View {
    var dotSize: CGFloat = 5
    var spacing: CGFloat = 4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1,
                                paused: reduceMotion || scenePhase != .active || UITestMotion.off)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * 4.5
            HStack(spacing: spacing) {
                ForEach(0..<3) { index in
                    Circle().fill(Palette.working)
                        .frame(width: dotSize, height: dotSize)
                        .opacity(reduceMotion ? 0.7 : 0.3 + 0.7 * max(0, sin(phase - Double(index) * 0.9)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct ChatWorkingDots: View {
    let intent: String?
    @Environment(\.chatTextScale) private var textScale

    var body: some View {
        HStack(spacing: 9) {
            ChatWorkingWave()
            Text(intent?.isEmpty == false ? intent! : "Working")
                .font(Typography.app(13 * textScale)).foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 4).padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(intent.map { "Working: \($0)" } ?? "Working")
        .accessibilityIdentifier("chat-working")
    }
}
