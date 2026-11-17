import Combine
import Foundation
import HerdrKit

/// Holds the Gram inbox OUTSIDE the Gram page's lifetime.
///
/// The page cannot own the list. On iPad it is constructed inside the detail column's
/// `switch selectedTab` (`TerminalHomeView.swift`), so switching sections destroys the view and
/// every `@State` it holds — Agents -> Gram -> Agents -> Gram re-fetched the entire
/// store (~870 messages, ~900 KB) each time and showed a spinner while it did.
///
/// A singleton rather than an `@StateObject` on the app root for one reason: the phone
/// tab, the iPad detail column and the standalone saved-grams sheet each build their
/// own `GramView` (three call sites), and they must share one list and one digest or
/// the conditional poll would be answered against whichever copy asked last.
///
/// Only the shell lives here. The state machine is `HerdrKit.GramInbox`, which is
/// platform-free and unit-tested on Linux — this target cannot even compile there.
@MainActor
final class GramInboxStore: ObservableObject {
    static let shared = GramInboxStore()

    @Published var inbox = GramInbox()

    private init() {}
}
