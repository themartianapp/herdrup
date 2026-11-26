import SwiftUI

struct ChatWorkingDots: View {
    let intent: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.chatTextScale) private var textScale

    var body: some View {
        HStack(spacing: 9) {
            // Still in UI tests that hold motion still (`UITestMotion`), as `ActivitySpinner`.
            TimelineView(.animation(minimumInterval: 0.1,
                                    paused: reduceMotion || scenePhase != .active || UITestMotion.off)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate * 4.5
                HStack(spacing: 4) {
                    ForEach(0..<3) { index in
                        Circle().fill(Palette.working)
                            .frame(width: 5, height: 5)
                            .opacity(reduceMotion ? 0.7 : 0.3 + 0.7 * max(0, sin(phase - Double(index) * 0.9)))
                    }
                }
            }
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
