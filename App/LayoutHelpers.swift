import SwiftUI
import Foundation
import UIKit    // UIPasteboard (Copy diagnostics)
import UniformTypeIdentifiers
import StoreKit // Product / tip jar (Settings' Support section)
import UserNotifications // notification authorization status (Settings notify section)
import HerdrKit

/// Caps a column at a readable width and centers it. On a wide canvas (iPad /
/// macOS) an edge-to-edge single column of cards drifts far past a comfortable
/// measure; capping then re-expanding centers the capped column in the available
/// space. On iPhone (narrower than the cap) it is inert — the inner cap never
/// binds, so the layout is unchanged.
struct ReadableColumn: ViewModifier {
    let cap: CGFloat
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: cap)
            .frame(maxWidth: .infinity)
    }
}

/// The kit's row shell: transparent fill, a 1px hairline border, and the tap
/// shape confined to the card (so the outer gutter/gap is not a tap target).
extension View {
    func rowShell() -> some View {
        self
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    /// `rowShell` for a Settings row (#357): a single-row group, min 52 pt, drawn without
    /// the outline like every Settings group since proposal B (#572).
    func settingsRowShell() -> some View {
        self
            .padding(.horizontal, 18).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .settingsGroup()
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.group))
    }

    /// One inset group (#357 "HerdrUp voice"): `surface`, radius 18, clipping its rows. The
    /// connect screen passes `outline: true` to keep the 1 pt `hairlineQuiet` outline; Settings
    /// (proposal B, #572) drops the stroke.
    func settingsGroup(outline: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.group)
        return self
            .background(Palette.surface)
            .clipShape(shape)
            .overlay { if outline { shape.stroke(Palette.hairlineQuiet, lineWidth: 1) } }
    }
}

extension View {
    /// Center + cap a column at a comfortable reading width on wide canvases;
    /// inert on iPhone (narrower than `cap`). See `ReadableColumn`. Module-wide so the
    /// connect screen, Settings and Gram's feed share one definition.
    func readableColumn(_ cap: CGFloat = 560) -> some View {
        modifier(ReadableColumn(cap: cap))
    }
}
