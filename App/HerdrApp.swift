import SwiftUI
import Foundation
import UIKit    // UIPasteboard (Copy diagnostics)
import UniformTypeIdentifiers
import StoreKit // Product / tip jar (Settings' Support section)
import UserNotifications // notification authorization status (Settings notify section)
import HerdrKit

// Phase 4, first real slice: terminal-first, on the merged pure-Swift transport.
// Connect over the Citadel transport, list agents, read a pane, render it.
// Termius-inspired dark. ANSI styling and gestures are follow-ups; plain
// monospace is a readable terminal v1.
@main
struct HerdrApp: App {
    // The app is otherwise pure SwiftUI; the adaptor is only for APNs registration + notification
    // callbacks, which have no SwiftUI equivalent. It bridges to PushCenter; RootView does the rest.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Start the tip-jar transaction listener at launch (mirroring PushCenter), so a
        // transaction that completes outside a purchase() call — e.g. an Ask-to-Buy
        // approved later — is finished promptly instead of waiting for Settings to open.
        _ = TipStore.shared
        // Chat's column width became the width Chat and Gram share (#541): keep the reader's.
        ConversationColumnWidth.migrate(.standard)
        #if DEBUG
        // A mock run starts with no downloaded gram files, so what a test sees (the image
        // card's fetched preview) comes from this run's canned replies, not an earlier one's.
        if ScreenshotMock.mode != nil { GramView.Downloads.invalidate() }
        // And from the default column width, so one test's choice can't leak into the next,
        // unless `HERDR_MOCK_COLUMN_WIDTH=keep` (a relaunch checking the width is remembered).
        if ScreenshotMock.mode != nil, ProcessInfo.processInfo.environment["HERDR_MOCK_COLUMN_WIDTH"] != "keep" {
            UserDefaults.standard.removeObject(forKey: ConversationColumnWidth.storageKey)
        }
        // And from no prompts sent and no star card answered, unless `HERDR_MOCK_STAR_PROMPT=keep`.
        if ScreenshotMock.mode != nil {
            GitHubStarPrompt.resetForMockLaunch(ProcessInfo.processInfo.environment, in: .standard)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .onOpenURL { url in
                    // A pairing link (herdrup://pair#…) opens its confirmation; nothing
                    // connects before the person taps Connect.
                    if PairingRouter.isPairingLink(url) {
                        PairingRouter.shared.open(url.absoluteString)
                        return
                    }
                    // A guest invite (herdrup://guest-invite#…, or the relay's https /i/… page)
                    // opens the Accept screen; everything else is the agent deep link.
                    if GuestInviteRouter.isInviteLink(url) {
                        GuestInviteRouter.shared.open(url.absoluteString)
                        return
                    }
                    guard let paneID = AgentActivityDeepLink.agentID(from: url) else { return }
                    PushCenter.shared.tapped(paneID: paneID)
                }
        }
    }
}
