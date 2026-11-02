import Foundation

/// The one-time bar asking the owner to star HerdrUp on GitHub (owner request, 2026-11-01).
///
/// After `threshold` successful owner prompts the owner's agents home shows ONE dismissible
/// bar. Either answer, "Star" (opens the repo) or × ("Not now"), retires it for good. Guests
/// (shared-agent viewers) never see it and their sends never count.
///
/// A prompt is one owner message the server accepted for delivery from the app's composers
/// (Chat or the terminal reply bar): `agent.prompt` returned a `PromptDelivery`. Raw keys
/// typed into the terminal never reach here, and a rejected or unconfirmed send is not one.
///
/// State lives in `UserDefaults` under `sentPromptsKey` and `answeredKey`; the app reads both
/// through `@AppStorage`, so the card appears as soon as the fifth send lands.
public enum GitHubStarPrompt {
    public static let repositoryURL = URL(string: "https://github.com/themartianapp/herdrup")!
    public static let threshold = 5
    public static let sentPromptsKey = "starPrompt.sentPrompts"
    public static let answeredKey = "starPrompt.answered"

    /// Whether a send counts toward the threshold: the owner's, and delivered.
    public static func counts(author: TranscriptAuthor, delivery: PromptDelivery?) -> Bool {
        author == .owner && delivery != nil
    }

    /// Records one send. Counting stops at the threshold and once answered: nothing reads
    /// the count past either.
    public static func recordPrompt(author: TranscriptAuthor, delivery: PromptDelivery?, in defaults: UserDefaults) {
        guard counts(author: author, delivery: delivery), !defaults.bool(forKey: answeredKey) else { return }
        let sent = defaults.integer(forKey: sentPromptsKey)
        guard sent < threshold else { return }
        defaults.set(sent + 1, forKey: sentPromptsKey)
    }

    public static func isDue(sentPrompts: Int, answered: Bool) -> Bool {
        !answered && sentPrompts >= threshold
    }

    public static func isDue(in defaults: UserDefaults) -> Bool {
        isDue(sentPrompts: defaults.integer(forKey: sentPromptsKey), answered: defaults.bool(forKey: answeredKey))
    }

    /// Either button: the card never shows again.
    public static func markAnswered(in defaults: UserDefaults) {
        defaults.set(true, forKey: answeredKey)
    }

    // MARK: Mock runs

    /// Screenshot mocks and UI tests never show the card unless this is `1` (fresh state on
    /// launch) or `keep` (a relaunch that checks the answer was remembered). Without it the
    /// existing reference captures and UI tests are unchanged.
    public static let mockEnvironmentKey = "HERDR_MOCK_STAR_PROMPT"

    public static func mockShowsCard(_ environment: [String: String]) -> Bool {
        let value = environment[mockEnvironmentKey]
        return value == "1" || value == "keep"
    }

    /// A mock launch starts from no sends and no answer unless the flag is `keep`, so one
    /// run's state cannot leak into the next.
    public static func resetForMockLaunch(_ environment: [String: String], in defaults: UserDefaults) {
        guard environment[mockEnvironmentKey] != "keep" else { return }
        defaults.removeObject(forKey: sentPromptsKey)
        defaults.removeObject(forKey: answeredKey)
    }
}
