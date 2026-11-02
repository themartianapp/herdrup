import SwiftUI

/// The one-time "star HerdrUp on GitHub" bar (`GitHubStarPrompt`), proposal D: a raised
/// capsule floating over the owner's agents list, just above the tab bar. The home decides
/// when it shows and what each button does; this view only draws it.
///
/// Geometry from the proposal: 56 tall (it grows with the text size), a 40 pt ground-filled
/// circle holding a star, the title and subtitle, an ink "Star" pill, and a 36 pt × target.
/// Narrower than `compactWidth` (the 320 pt iPad sidebar leaves a ~288 pt capsule) the circle
/// goes and the text starts 16 pt in, so the title keeps its one line beside the pill.
struct GitHubStarPromptCard: View {
    let onStar: () -> Void
    let onNotNow: () -> Void

    /// Below this capsule width the star circle is dropped (the same rule as the desktop app).
    static let compactWidth: CGFloat = 340
    @State private var compact = false

    var body: some View {
        HStack(spacing: 0) {
            if !compact {
                Image(systemName: "star.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(Palette.text)
                    .frame(width: 40, height: 40)
                    .background(Palette.ground, in: Circle())
                    .padding(.leading, 8)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Enjoying HerdrUp?")
                    .font(Typography.app(15, .semibold)).foregroundStyle(Palette.text)
                    .frame(minHeight: 19 * Typography.scale)
                    .accessibilityIdentifier("github-star-card-title")
                Text("Star it on GitHub")
                    .font(Typography.app(13)).foregroundStyle(Palette.textDim)
                    .frame(minHeight: 17 * Typography.scale)
                    .accessibilityIdentifier("github-star-card-subtitle")
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, compact ? 16 : 11)
            Button(action: onStar) {
                Text("Star")
                    .font(Typography.app(15, .semibold)).foregroundStyle(Palette.ground)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 32)
                    .background(Palette.text, in: Capsule())
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Star on GitHub")
            .accessibilityIdentifier("github-star-card-star")
            Button(action: onNotNow) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.textDim)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .accessibilityLabel("Not now")
            .accessibilityIdentifier("github-star-card-not-now")
        }
        .padding(.vertical, 8)
        .frame(minHeight: 56)
        .onGeometryChange(for: Bool.self) { $0.size.width < Self.compactWidth } action: { compact = $0 }
        .background(Palette.surfaceRaised, in: Capsule())
        .overlay(Capsule().stroke(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 15, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Enjoying HerdrUp? Star it on GitHub")
        .accessibilityIdentifier("github-star-card")
    }
}
