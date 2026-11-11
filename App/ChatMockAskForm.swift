#if DEBUG
import Foundation

/// `HERDR_MOCK_CHAT_FORM=1`: the `chatview` / `guestchat` mocks' open question is omp's
/// HTML-form `ask` (omp ≥ 18.18.3) as herdr parses it: the enyo-ui form of 2026-11-10 (five
/// radio fields), plus the checkbox field the proposals added ("While it builds, send me").
///
/// - `HERDR_MOCK_CHAT_FORM_CAPABILITY=0`: the server predates `ask_form` (its ping leaves it
///   out); the form shows read-only with "Answer in Terminal".
/// - `HERDR_MOCK_CHAT_FORM_ANSWER=<code>`: `agent.answer_form` refuses with that code.
///   `ask_form_invalid` names the Other field ("form: …").
/// - `HERDR_MOCK_CHAT_FORM_STATUS=timed_out|cancelled`: the form ended unanswered.
/// - `HERDR_MOCK_CHAT_FORM_TEXTAREA=1`: a prefilled two-line `<textarea>` comes last. herdr
///   (#394) drives it: left out of `values` it keeps the prefill, `{"text":…}` replaces it,
///   and an answer longer than the editor's rows (the prefill's two) is refused with
///   "notes: too long to edit from the app; answer in the terminal".
/// - `HERDR_MOCK_CHAT_FORM_OPTIONAL=1`: an optional radio with Other and no default comes
///   after the checkbox group; left out of `values`, omp records it unanswered.
enum ChatMockAskForm {
    static let enabled = ProcessInfo.processInfo.environment["HERDR_MOCK_CHAT_FORM"] == "1"
    static let advertised = ProcessInfo.processInfo.environment["HERDR_MOCK_CHAT_FORM_CAPABILITY"] != "0"
    static let refusal = ProcessInfo.processInfo.environment["HERDR_MOCK_CHAT_FORM_ANSWER"]
    static let endedStatus = ProcessInfo.processInfo.environment["HERDR_MOCK_CHAT_FORM_STATUS"]
    static let hasTextarea = ProcessInfo.processInfo.environment["HERDR_MOCK_CHAT_FORM_TEXTAREA"] == "1"
    static let hasOptionalRadio = ProcessInfo.processInfo.environment["HERDR_MOCK_CHAT_FORM_OPTIONAL"] == "1"

    /// What herdr reports as `form_answerable` for a viewer who may answer.
    static var answerable: Bool { advertised }

    /// The `ping` capabilities fragment: `,"ask_form":true` when advertised.
    static var capability: String { advertised ? #","ask_form":true"# : "" }

    static let askID = "call_ask_enyo"

    private static func radio(_ name: String, _ title: String, _ description: String?,
                              _ options: [(String, String)], checked: String) -> [String: Any] {
        field(name, title, description, multi: false, options: options, checked: [checked])
    }

    private static func field(_ name: String, _ title: String, _ description: String?, multi: Bool,
                              options: [(String, String)], checked: [String]) -> [String: Any] {
        [
            "name": name, "kind": "choice", "title": title, "description": description.map { $0 as Any } ?? NSNull(),
            "multi": multi, "select": false, "other": true, "required": false,
            "options": options.map { value, label in
                ["value": value, "label": label, "checked": checked.contains(value), "disabled": false] as [String: Any]
            },
            "input_type": NSNull(), "placeholder": NSNull(), "value": NSNull(),
            "min": NSNull(), "max": NSNull(), "minlength": NSNull(), "maxlength": NSNull(), "pattern": NSNull(),
        ]
    }

    static let intro = "Before enyo-ui starts building from iteration 5, five choices. My recommendation is preselected."

    private static let baseFields: [[String: Any]] = [
        radio("where", "Where to build",
              "lenscale.ai is public today (the 1 Nov landing). preview.lenscale.ai already sits behind Cloudflare Zero Trust with Jerry, Nicola and @lenscale.ai allowed.",
              [("preview", "preview.lenscale.ai: already hidden, no Cloudflare change; lenscale.ai keeps the current landing until you say launch"),
               ("apex", "Hide lenscale.ai now: visitors (e.g. from Mario's chat or LinkedIn) hit a login page until launch, and search engines drop it")],
              checked: "preview"),
        radio("who", "Who may see it",
              "The other lenscale apps (admin, preview, app) also allow Nicola's Gmail (nicolachiappini1997@gmail.com).",
              [("same", "Same as the others: your Gmail, Nicola's Gmail, any @lenscale.ai address"),
               ("only", "Only your Gmail and @lenscale.ai addresses")],
              checked: "same"),
        radio("scope", "What first", nil,
              [("site", "The public site (pages 01–13) first; the app pages (14–24) next, restyling app.lenscale.ai"),
               ("both", "Site and app together (slower to a first usable result)")],
              checked: "site"),
        radio("picks", "Open picks in iteration 5 (logo 8 provisional, 4 pricing titles, 3 demo question sets)", nil,
              [("provisional", "Use logo 8, the first pricing title and question set 1 as provisional; change any time"),
               ("owner", "I'll pick first; the build waits")],
              checked: "provisional"),
        radio("form", "Where 'Book a demo' requests go", nil,
              [("dashboard", "A row in the Team dashboard (Partners) and a Gram to you"),
               ("email", "Email to an @lenscale.ai inbox (write which in Other)")],
              checked: "dashboard"),
        // Added for the proposals: a checkbox field.
        field("updates", "While it builds, send me", "Choose any.", multi: true,
              options: [("gram", "A Gram when each page is ready"),
                        ("preview", "Preview links after each page group"),
                        ("evening", "A summary every evening")],
              checked: ["gram", "preview"]),
    ]

    /// An optional radio omp checked nothing of: it may be left unanswered.
    private static let tone = field("tone", "Tone of the landing copy", "Optional.", multi: false,
                                    options: [("calm", "Calm and plain"), ("bold", "Bold and short")], checked: [])

    /// The choice fields.
    static var fields: [[String: Any]] { baseFields + (hasOptionalRadio ? [tone] : []) }

    static let textareaValue = "Keep the 1 Nov palette.\nNo stock photos on the landing."

    /// omp's prefilled `<textarea>`, as herdr lists it.
    private static let notes: [String: Any] = [
        "name": "notes", "kind": "text", "title": "Anything else for the build", "description": "Optional.",
        "multi": false, "select": false, "other": false, "required": false, "options": [[String: Any]](),
        "input_type": "textarea", "placeholder": "Notes for enyo-ui", "value": textareaValue,
        "min": NSNull(), "max": NSNull(), "minlength": NSNull(), "maxlength": NSNull(), "pattern": NSNull(),
    ]

    static var allFields: [[String: Any]] { fields + (hasTextarea ? [notes] : []) }

    static var form: [String: Any] { ["intro": intro, "fields": allFields] }

    /// The `questions` herdr keeps for older apps: one per choice field.
    static var questions: [[String: Any]] {
        fields.map { field in
            let options = field["options"] as? [[String: Any]] ?? []
            return [
                "question": field["title"] as? String ?? "",
                "options": options.map { $0["label"] as? String ?? "" },
                "multi": field["multi"] as? Bool ?? false,
                "recommended": options.firstIndex { $0["checked"] as? Bool == true }.map { $0 as Any } ?? NSNull(),
            ]
        }
    }

    /// `values` checked as herdr checks them, then omp's `details.answers`. A refusal is
    /// `(code, message)`.
    static func answers(for values: [String: Any]) -> Result<[[String: String]], MockRefusal> {
        let names = Set(allFields.compactMap { $0["name"] as? String })
        if let unknown = values.keys.first(where: { !names.contains($0) }) {
            return .failure(MockRefusal(code: "ask_form_invalid", message: "\(unknown): unknown field"))
        }
        var answers: [[String: String]] = []
        if hasTextarea {
            var text = textareaValue
            if let value = values["notes"] as? [String: Any] {
                text = value["text"] as? String ?? ""
                // The editor shows the prefill's rows (2 to 10); herdr types no more.
                let rows = min(max(textareaValue.split(separator: "\n", omittingEmptySubsequences: false).count, 2), 10)
                if text.split(separator: "\n", omittingEmptySubsequences: false).count > rows {
                    return .failure(MockRefusal(code: "ask_form_invalid",
                                                message: "notes: too long to edit from the app; answer in the terminal"))
                }
            }
            answers.append(["name": "notes", "question": "Anything else for the build", "answer": text])
        }
        for field in fields {
            let name = field["name"] as? String ?? ""
            let title = field["title"] as? String ?? name
            let options = field["options"] as? [[String: Any]] ?? []
            let multi = field["multi"] as? Bool ?? false
            var chosen = options.filter { $0["checked"] as? Bool == true }.compactMap { $0["value"] as? String }
            var other: String?
            if let value = values[name] as? [String: Any] {
                chosen = value["options"] as? [String] ?? []
                other = value["other"] as? String
                let known = Set(options.compactMap { $0["value"] as? String })
                if let bad = chosen.first(where: { !known.contains($0) }) {
                    return .failure(MockRefusal(code: "ask_form_invalid", message: "\(name): no option \(bad)"))
                }
                if !multi, chosen.count + (other == nil ? 0 : 1) != 1 {
                    return .failure(MockRefusal(code: "ask_form_invalid",
                                                message: "\(name): pick exactly one option or Other"))
                }
            }
            let labels = options.filter { chosen.contains($0["value"] as? String ?? "") }
                .compactMap { $0["label"] as? String }
            let answer = (labels + (other.map { ["Other: \($0)"] } ?? [])).joined(separator: ", ")
            answers.insert(["name": name, "question": title, "answer": answer], at: answers.count - (hasTextarea ? 1 : 0))
        }
        return .success(answers)
    }

    struct MockRefusal: Error {
        let code: String
        let message: String
    }
}
#endif
