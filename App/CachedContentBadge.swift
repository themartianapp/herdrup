import SwiftUI

/// The subtle mark a screen wears while it shows what `AppContentCache` kept from the last
/// launch and the refresh behind it has not answered yet (slow-network fix 4).
///
/// Always placed as an overlay, never in the layout: when fresh data swaps in, the mark
/// goes and nothing under it moves, so the reader's scroll position holds.
struct CachedContentBadge: View {
    let identifier: String

    /// The badge while `isShown`, fading in and out on its own: the animation is scoped to
    /// it, so the fresh rows that land in the same update are not animated.
    static func shown(_ isShown: Bool, identifier: String) -> some View {
        ZStack {
            if isShown { CachedContentBadge(identifier: identifier).padding(.top, 6) }
        }
        .animation(.easeOut(duration: 0.2), value: isShown)
    }

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini).tint(Palette.textDim)
            Text("Updating…")
                .font(Typography.app(12, .medium))
                .foregroundStyle(Palette.textDim)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Palette.surfaceRaised))
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Showing saved content, updating")
        .accessibilityIdentifier(identifier)
        .transition(.opacity)
    }
}
