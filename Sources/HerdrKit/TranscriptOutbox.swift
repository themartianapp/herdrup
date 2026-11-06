import Foundation

/// Delivery and appearance in the transcript are different facts. In particular, writing
/// bytes to a terminal is not confirmation that the agent accepted a prompt.
public enum TranscriptSendState: Sendable, Equatable {
    case sending
    case submitted
    case unconfirmed
    case notDelivered(String)
    case previousSession
    /// Still unmatched a minute after the request returned, or after the agent finished a
    /// later turn: no longer pending. It still matches if the prompt shows up after all.
    case notSeen

    public init(rejection error: APIError) {
        switch PromptRejection(error) {
        case .notDelivered: self = .notDelivered(error.message)
        case .submittedStatusUnknown: self = .submitted
        default: self = .unconfirmed
        }
    }
}

public struct TranscriptOutgoingMessage: Identifiable, Sendable, Equatable {
    public let id: String
    public let text: String
    public let author: TranscriptAuthor
    public fileprivate(set) var state: TranscriptSendState
    public fileprivate(set) var files: [TranscriptAttachment]
    fileprivate var wireText: String
    fileprivate var existingPromptIDs: Set<String>
    fileprivate var sessionID: String?
    fileprivate var baselineReady: Bool
    /// When the prompt request returned (`submitted` or `unconfirmed`); the minute before
    /// demotion counts from here, so a long attachment upload does not use it up.
    fileprivate var handedOverAt: Date?
    /// A prompt this message did not match was recorded after it was sent; the end of
    /// that turn means this one was not recorded as sent.
    fileprivate var laterPromptSeen = false
}

/// A local display buffer, never a retry queue. Reconciliation consumes each new prompt
/// at most once, so two identical sends cannot both disappear when only one is recorded.
/// Matching says only that the text is now in the transcript, not which device wrote it.
/// Text is compared as the agent records it: trimmed, with CRLF and CR read as LF.
public struct TranscriptOutbox: Sendable, Equatable {
    public private(set) var messages: [TranscriptOutgoingMessage] = []
    public private(set) var recordedPromptIDs: Set<String> = []
    private var lastSessionID: String?

    public init() {}

    @discardableResult
    public mutating func stage(text: String, author: TranscriptAuthor,
                               entries: [TranscriptEntry], sessionID: String?, baselineReady: Bool = true,
                               files: [TranscriptAttachment] = []) -> String {
        let id = UUID().uuidString
        let existing = Set(entries.compactMap { entry -> String? in
            if case .user = entry.kind { return entry.id }
            return nil
        })
        messages.append(TranscriptOutgoingMessage(id: id, text: text, author: author,
                                                 state: .sending, files: files, wireText: text,
                                                 existingPromptIDs: existing, sessionID: sessionID,
                                                 baselineReady: baselineReady))
        return id
    }

    public mutating func update(_ id: String, state: TranscriptSendState, wireText: String? = nil,
                                now: Date = Date()) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].state = state
        switch state {
        case .submitted, .unconfirmed:
            if messages[index].handedOverAt == nil { messages[index].handedOverAt = now }
        default:
            break
        }
        if let wireText {
            messages[index].wireText = wireText
            if let parsed = GramAttachmentPrompt.parse(wireText) { messages[index].files = parsed.files }
        }
    }

    public mutating func prepare(_ id: String, entries: [TranscriptEntry], sessionID: String?) {
        guard let index = messages.firstIndex(where: { $0.id == id }), !messages[index].baselineReady else { return }
        messages[index].existingPromptIDs = Set(entries.compactMap { entry -> String? in
            if case .user = entry.kind { return entry.id }
            return nil
        })
        messages[index].sessionID = sessionID
        messages[index].baselineReady = true
    }

    public mutating func reconcile(_ entries: [TranscriptEntry], sessionID: String?) {
        if let previous = lastSessionID, let current = sessionID, previous != current {
            recordedPromptIDs.removeAll(keepingCapacity: true)
        }
        if let sessionID { lastSessionID = sessionID }
        for index in messages.indices {
            if case .notDelivered = messages[index].state { continue }
            if let before = messages[index].sessionID, let now = sessionID, before != now {
                // Keep the user's text available, but never match or resend it into a
                // replacement session merely because the same words appear there.
                messages[index].state = .previousSession
            }
        }
        for entry in entries {
            switch entry.kind {
            case .user(let text, let author, _):
                guard !recordedPromptIDs.contains(entry.id) else { continue }
                let recorded = Self.normalized(text)
                if let index = messages.firstIndex(where: { message in
                    switch message.state {
                    case .notDelivered, .previousSession: return false
                    default: break
                    }
                    return message.baselineReady && !message.existingPromptIDs.contains(entry.id)
                        && Self.normalized(message.wireText) == recorded && message.author == author
                }) {
                    recordedPromptIDs.insert(entry.id)
                    messages.remove(at: index)
                    continue
                }
                for index in messages.indices where messages[index].isAwaitingRecord
                    && !messages[index].existingPromptIDs.contains(entry.id) {
                    messages[index].laterPromptSeen = true
                }
            case .turnEnd:
                for index in messages.indices where messages[index].isAwaitingRecord
                    && messages[index].laterPromptSeen {
                    messages[index].state = .notSeen
                }
            default:
                continue
            }
        }
    }

    /// Demotes a prompt still unmatched `after` seconds after its request returned.
    /// Returns whether anything changed.
    @discardableResult
    public mutating func demoteUnseen(now: Date, after: TimeInterval = TranscriptOutbox.unseenAfter) -> Bool {
        var changed = false
        for index in messages.indices where messages[index].isAwaitingRecord {
            guard let since = messages[index].handedOverAt, now.timeIntervalSince(since) >= after else { continue }
            messages[index].state = .notSeen
            changed = true
        }
        return changed
    }

    /// How long a returned prompt may stay unmatched before it stops reading as pending.
    public static let unseenAfter: TimeInterval = 60

    /// The text as the agent records a submitted prompt: trimmed of surrounding spaces and
    /// newlines, with CRLF and a lone CR read as LF.
    static func normalized(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var afterCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n", afterCR {
                afterCR = false
                continue
            }
            afterCR = scalar == "\r"
            scalars.append(afterCR ? "\n" : scalar)
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension TranscriptOutgoingMessage {
    /// The request returned and the prompt is not in the transcript yet.
    var isAwaitingRecord: Bool {
        switch state {
        case .submitted, .unconfirmed: return baselineReady
        default: return false
        }
    }
}
