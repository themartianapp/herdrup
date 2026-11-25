import HerdrKit
import SwiftUI
import UIKit

// The agent page's header controls (#358), shared by the owner's terminal pane
// (`TerminalPaneContent`) and a guest's shared-agent page (`GuestPaneView`): the round back
// button, the top-right capsule and its buttons, the ⋯ menu's label and the sections both
// pages offer, and the "Latest" pill over the terminal.

/// The 44 pt round back button at the header's leading edge.
struct PaneHeaderBackButton: View {
    var identifier: String?
    let action: () -> Void

    @ViewBuilder var body: some View {
        let button = Button(action: action) {
            Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
        }
        .buttonStyle(.circle(diameter: 44))
        .accessibilityLabel("Back")
        if let identifier { button.accessibilityIdentifier(identifier) } else { button }
    }
}

/// The header's top-right capsule: its buttons side by side (40 × 44 each) on one
/// `surfaceRaised` capsule.
struct PaneHeaderCapsule<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) { content() }
            .padding(.horizontal, 2)
            .background(Capsule().fill(Palette.surfaceRaised))
    }
}

/// Refresh the active surface; terminal callers reconnect, chat callers retain loaded history.
struct PaneHeaderRefreshButton: View {
    let identifier: String
    var refreshing = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if refreshing { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .medium)) }
            }
                .foregroundStyle(Palette.text)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(refreshing)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(refreshing ? "Refreshing" : "Refresh")
    }
}

/// The ⋯ menu's label. While this agent's notifications are off it shows a struck bell in
/// amber, so the state reads at a glance without opening the menu.
struct PaneActionsMenuLabel: View {
    let notificationsOff: Bool

    var body: some View {
        Image(systemName: notificationsOff ? "bell.slash" : "ellipsis")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(notificationsOff ? Palette.waiting : Palette.text)
            .frame(width: 40, height: 44)
            .contentShape(Rectangle())
    }
}

/// ⋯ → Copy screen / Copy recent output: the pane's text as `agent.read` returns it, onto
/// the pasteboard.
struct TerminalCopyMenuSection: View {
    let client: HerdrClient
    let paneID: String

    var body: some View {
        Section {
            Button {
                Task {
                    if let out = try? await client.read(pane: paneID, source: .visible, format: .text) {
                        UIPasteboard.general.string = out.text
                    }
                }
            } label: { Label("Copy screen", systemImage: "doc.on.doc") }
            Button {
                Task {
                    if let out = try? await client.read(pane: paneID, source: .recentUnwrapped, format: .text) {
                        UIPasteboard.general.string = out.text
                    }
                }
            } label: { Label("Copy recent output", systemImage: "doc.on.clipboard") }
        }
    }
}

/// ⋯ → Text size: Increase, Decrease and Reset of the page's own terminal text size.
struct TerminalTextSizeMenuSection: View {
    let increaseID: String
    let decreaseID: String
    let onIncrease: () -> Void
    let onDecrease: () -> Void
    let onReset: () -> Void

    var body: some View {
        Section("Text size") {
            Button(action: onIncrease) { Label("Increase", systemImage: "textformat.size.larger") }
                .accessibilityIdentifier(increaseID)
            Button(action: onDecrease) { Label("Decrease", systemImage: "textformat.size.smaller") }
                .accessibilityIdentifier(decreaseID)
            Button(action: onReset) { Label("Reset", systemImage: "arrow.counterclockwise") }
        }
    }
}

/// What the capsule at the top of a terminal shows (see `TerminalHistoryCapsule`).
enum TerminalHistoryPaging: Equatable {
    case hidden
    /// Older history exists above the top and nothing is loading: tap to load a page.
    case offered
    case loading
}

/// Shown at the top of the terminal while it is within a screen of the top of its history
/// and older history exists. Loading, it is a status in the words and ink of Gram's "Loading
/// older messages…" sentinel, and touches pass through to the terminal, which keeps scrolling
/// underneath. Otherwise it is a "Load earlier output" control, Chat's Retry for a terminal:
/// the way to the next page when no scroll will reach it (a wheel resting at the top, a pane
/// too short to scroll, keyboard or VoiceOver). Same surface capsule in both states, so the
/// switch does not jump.
struct TerminalHistoryCapsule: View {
    let state: TerminalHistoryPaging
    /// Identifier prefix: `<prefix>-history-loading` and `<prefix>-load-earlier`.
    var identifierPrefix = "terminal"
    let loadEarlier: () -> Void

    @ViewBuilder var body: some View {
        switch state {
        case .hidden:
            EmptyView()
        case .loading:
            capsule {
                ProgressView().controlSize(.small).tint(Palette.textFaint)
                Text("Loading earlier output…")
            }
            .foregroundStyle(Palette.textFaint)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("\(identifierPrefix)-history-loading")
        case .offered:
            Button(action: loadEarlier) {
                capsule {
                    Image(systemName: "arrow.up.to.line").font(.system(size: 11, weight: .semibold))
                    Text("Load earlier output")
                }
                .foregroundStyle(Palette.textDim)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Load earlier output"))
            .accessibilityIdentifier("\(identifierPrefix)-load-earlier")
        }
    }

    private func capsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .font(Typography.app(12))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Palette.surface).clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
            .padding(.top, 8)
    }
}
