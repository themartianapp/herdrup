import SwiftUI

/// The glass circle that returns a scrolled-back reader to the newest content, bottom-centre
/// over the chat or the terminal. Shown only while the reader is away from the tail. An
/// overlay, not a gesture: only the circle hit-tests, so touches elsewhere reach the content.
/// The Chat also shows a smaller one in its bottom-right corner, the up arrow to the owner's
/// previous message.
struct JumpToLatestButton: View {
    let label: String
    let identifier: String
    /// The regular glass, for dense, high-contrast terminal text that clear glass would pass
    /// through almost unchanged. Chat keeps the clear glass over its softer prose.
    var regularGlass = false
    var systemImage = "arrow.down"
    /// The jump is still finding its target (the up arrow loading older pages): a spinner
    /// replaces the arrow.
    var busy = false
    /// The visible circle. The tap area stays 44 pt whatever the size.
    var diameter: CGFloat = 44
    let action: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView().controlSize(.small).tint(Palette.text)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 18 * diameter / 44, weight: .medium))
                        .foregroundStyle(Palette.text)
                }
            }
            .frame(width: diameter, height: diameter)
            .modifier(GlassCircle(regular: regularGlass, reduceTransparency: reduceTransparency))
            .frame(width: max(44, diameter), height: max(44, diameter))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(busy ? "Loading earlier messages" : "")
        .accessibilityIdentifier(identifier)
    }

    private struct GlassCircle: ViewModifier {
        let regular: Bool
        let reduceTransparency: Bool
        @ViewBuilder func body(content: Content) -> some View {
            if reduceTransparency {
                content.background(Palette.surfaceRaised, in: Circle())
            } else if #available(iOS 26.0, *) {
                content.glassEffect((regular ? Glass.regular : Glass.clear).interactive(), in: Circle())
            } else {
                content.background(regular ? Material.regularMaterial : Material.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
            }
        }
    }
}
