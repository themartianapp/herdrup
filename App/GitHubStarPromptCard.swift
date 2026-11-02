import SwiftUI

/// The one-time "star herdrup on GitHub" card (`GitHubStarPrompt`). The pane decides when it
/// shows and what each button does; this view only draws it.
///
/// Drawn like the pane's other one-time offer (the classic-scrolling banner): a `surface`
/// card with a hairline, a primary capsule and a quiet "Not now" capsule.
struct GitHubStarPromptCard: View {
    let onStar: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "star")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textDim)
                Text("Enjoying herdrup?")
                    .font(Typography.app(14, .semibold)).foregroundStyle(Palette.text)
            }
            Text("A star on GitHub helps other people find it.")
                .font(Typography.app(12)).foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(action: onStar) {
                    Text("Star on GitHub").font(Typography.app(13, .semibold)).foregroundStyle(Palette.ground)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(Palette.text).clipShape(Capsule())
                }
                .accessibilityIdentifier("github-star-card-star")
                Button(action: onNotNow) {
                    Text("Not now").font(Typography.app(13, .semibold)).foregroundStyle(Palette.textDim)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Palette.surfaceRaised).clipShape(Capsule())
                }
                .accessibilityIdentifier("github-star-card-not-now")
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline, lineWidth: 1))
        .padding(.horizontal, 12).padding(.top, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("github-star-card")
    }
}
