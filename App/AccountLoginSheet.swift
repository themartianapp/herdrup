import SwiftUI
import UIKit    // UIPasteboard (tap the sign-in link to copy it)
import HerdrKit

/// In-app claude account sign-in (issue #173 follow-up), clean stepped flow — NO raw
/// terminal. It runs `claude auth login` (or setup-token) in a BACKGROUND pane pinned to
/// the account's config-home, scrapes the OAuth URL, and shows it as a tap-to-open card;
/// the user approves in the browser and pastes the code back. The command always clears
/// the global CLAUDE_CODE_OAUTH_TOKEN and pins CLAUDE_CONFIG_DIR (see `claudeLoginCommand`),
/// so credentials land in THIS account only.
///
/// The SURFACE is built to the "herdrup · account sign-in · v1" Claude Design canvas. The
/// FLOW is unchanged from the version that shipped: `start`, `scrapeLoop`, `sendCode`,
/// `pollSignedIn` and the timeout are the same code, because they encode findings that
/// were expensive to get (success is never read from the pane; failure is judged only on
/// output produced after the submission). Only the view layer was replaced.
struct AccountLoginSheet: View {
    let client: HerdrClient
    let account: CredentialAccount
    var onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// Which board is on screen. Previously every one of these was a sentence in `status`
    /// and the layout could not tell them apart, so all of them rendered as one faint line
    /// — three genuinely different situations wearing the same shape. `status` still holds
    /// the sentence; this decides the composition.
    private enum Phase: Equatable {
        case starting       // A  — nothing to do yet, a background command is running
        case linkReady      // B  — the URL is up; paste a code back
        case submitting     // B2 — a code is in flight
        case rejected       // C1 — recoverable, retry in place
        case unconfirmed    // C2 — neither success nor failure; resolve it
        case unsupported    // C3 — dead end, hand over the command instead
        case signedIn       // D  — which identity landed
    }

    @State private var method: ClaudeLoginMethod = .oauth
    @State private var paneID: String?
    @State private var signInURL: URL?
    @State private var code: String = ""
    @State private var status: String = "Starting sign-in…"
    @State private var phase: Phase = .starting
    @State private var signedIn = false
    @State private var scrapeTask: Task<Void, Never>?
    /// A code has been submitted and we are waiting on the harness. While true the input is
    /// replaced by a spinner — so it MUST be cleared on failure too, or a mistyped code
    /// leaves the user on a spinner with no way to retry.
    @State private var submitting = false
    /// The pane text as it stood when the last code was submitted.
    ///
    /// Failure is judged ONLY on output produced after this point. The pane buffer is
    /// cumulative, so a rejected first attempt leaves "invalid code" sitting in it forever
    /// — and a retry would then be failed instantly by the previous attempt's message, no
    /// matter how good the new code is.
    @State private var submitBaseline: String = ""
    /// Briefly shown after the link is copied, so the tap has a visible result.
    @State private var copied = false
    /// Once the link has been opened or copied, step 1's control demotes to an outline —
    /// the ink fill belongs to whatever you should do NEXT, which by then is step 2.
    @State private var linkUsed = false
    /// Wall-clock since the current wait began, for the mono metadata line. The design asks
    /// the waiting states to say what is running and for how long, rather than only that
    /// something is.
    @State private var waitedSeconds: Int = 0
    /// The account's email as the daemon reported it BEFORE this attempt started.
    /// Sign-in is confirmed by this going from absent to present — see `pollSignedIn`.
    @State private var baselineEmail: String??
    /// The identity actually signed in, shown on success. Worth surfacing: an OAuth
    /// page approves whoever the BROWSER is signed in as, so a "new" account can end
    /// up holding the same person as an existing one. Naming it makes that obvious
    /// immediately instead of days later in the accounts list.
    @State private var signedInEmail: String?

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().overlay(Palette.hairlineQuiet)
                board
            }
        }
        .task { await start() }
        // THE ONLY PATH EVERY DISMISSAL TAKES. `finish()` covers the ✕ and a confirmed
        // success, but a SWIPE-DOWN calls neither — and that left a live
        // `claude auth login` pane running on the box, which the user could later
        // stumble onto in the terminal tab with no idea where it came from.
        .onDisappear { cleanupPane() }
        .onReceive(tick) { _ in
            // Only the two waiting boards show an elapsed count.
            if phase == .starting || phase == .submitting { waitedSeconds += 1 }
        }
    }

    // MARK: - chrome

    /// The `AccountsSetupView` header, not a system nav bar: title, a mono subtitle naming
    /// the account, and a round ✕. The identity chip joins it so the sheet names its
    /// account the way an Accounts row does.
    private var header: some View {
        HStack(spacing: 12) {
            identityChip(size: 34, corner: 9, glyph: 15)
            VStack(alignment: .leading, spacing: 1) {
                Text(phase == .signedIn ? "Signed in" : "Sign in")
                    .font(Typography.app(20, .semibold))
                    .foregroundStyle(Palette.text)
                // Mono because `kind · label` is machine data — the one place this
                // deviates from the brief's "12pt textFaint", and deliberately.
                Text("\(account.kind) · \(account.label)")
                    .font(Typography.machine(12))
                    .foregroundStyle(Palette.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { finish() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textDim)
            }
            .buttonStyle(.circle(diameter: 36))
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var board: some View {
        switch phase {
        case .starting: centred { startingBoard }
        case .linkReady, .submitting, .rejected: stepsBoard
        case .unconfirmed: centred { unconfirmedBoard }
        case .unsupported: centred { unsupportedBoard }
        case .signedIn: centred { signedInBoard }
        }
    }

    /// The states with nothing to DO are centred; only the two working boards are
    /// top-aligned, because those are a task. Previously every state was stacked at the
    /// top of a scroll view, so waiting and success were two lines above an empty screen.
    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer(minLength: 0)
            content()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
    }

    // MARK: - A · starting

    private var startingBoard: some View {
        VStack(spacing: 14) {
            TurningRing(color: Palette.working, diameter: 30, lineWidth: 2)
            VStack(spacing: 6) {
                Text(status)
                    .font(Typography.app(16, .semibold))
                    .foregroundStyle(Palette.text)
                    .multilineTextAlignment(.center)
                Text(runningMetadata)
                    .font(Typography.machine(11))
                    .foregroundStyle(Palette.textFaint)
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
            }
            pendingSteps
            methodFooter
        }
    }

    /// What is actually running, and for how long — the mono half of the one status line.
    private var runningMetadata: String {
        let verb = method == .oauth ? "claude auth login" : "claude setup-token"
        return "\(verb) · background · \(waitedSeconds)s"
    }

    /// The two steps, shown greyed before there is anything to do with them, so the shape
    /// of what is coming is visible while waiting.
    private var pendingSteps: some View {
        VStack(alignment: .leading, spacing: 10) {
            pendingStepRow("01", "Open the sign-in page")
            Rectangle().fill(Palette.hairlineQuiet).frame(height: 1)
            pendingStepRow("02", "Paste the code you get back")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surface.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairlineQuiet, lineWidth: 1))
        .padding(.top, 6)
    }

    private func pendingStepRow(_ number: String, _ title: String) -> some View {
        HStack(spacing: 10) {
            numeralTile(number)
            Text(title).font(Typography.app(14)).foregroundStyle(Palette.textFaint)
            Spacer(minLength: 0)
        }
    }

    // MARK: - B / B2 / C1 · the steps

    private var stepsBoard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // ONE grouped stack with a divider, not two floating cards that happen to
                // be numbered — so the sequence reads as a sequence.
                VStack(alignment: .leading, spacing: 0) {
                    stepOne
                    Rectangle().fill(Palette.hairlineQuiet).frame(height: 1)
                    stepTwo
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surface))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline, lineWidth: 1))
                methodFooter
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
    }

    private var stepOne: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepHeading("01", "Open the sign-in page")
            if let url = signInURL {
                if linkUsed {
                    outlineControl(linkUsed ? "Open sign-in page again" : "Open sign-in page") {
                        openURL(url)
                    }
                } else {
                    inkControl("Open sign-in page", icon: "safari") {
                        openURL(url)
                        linkUsed = true
                    }
                }
                Button {
                    UIPasteboard.general.string = url.absoluteString
                    copied = true
                    linkUsed = true
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        copied = false
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(url.absoluteString)
                            .font(Typography.machine(11))
                            .foregroundStyle(Palette.text)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.surfaceRaised))
                        if copied {
                            copiedChip
                        } else {
                            Text("tap to copy · sign in on another device")
                                .font(Typography.machine(10))
                                .foregroundStyle(Palette.textFaint)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "Sign-in link copied" : "Copy sign-in link")
            }
        }
        .padding(14)
    }

    /// Shape AND colour, never colour alone — a tick beside the word, not a green flash.
    private var copiedChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
            Text("link copied").font(Typography.machine(10, .semibold))
        }
        .foregroundStyle(Palette.done)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Palette.surfaceRaised))
    }

    private var stepTwo: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepHeading("02", "Paste the code you get back")
            if submitting {
                // The input is REPLACED, not disabled, and the wait names who it is
                // waiting on and for how long.
                HStack(spacing: 9) {
                    TurningRing(color: Palette.working)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Signing you in…")
                            .font(Typography.app(14))
                            .foregroundStyle(Palette.text)
                        Text("code sent · waiting on \(account.kind) · \(waitedSeconds)s")
                            .font(Typography.machine(10))
                            .foregroundStyle(Palette.textFaint)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
                Text("the field comes back either way — it never ends on a spinner")
                    .font(Typography.machine(10))
                    .foregroundStyle(Palette.textFaint)
            } else {
                if phase == .rejected {
                    // Recoverable, so the recovery lives where it happens: a pill and a
                    // sentence inside step 2, with the typed code kept.
                    statusPill("needs another go", tone: Palette.waiting)
                    Text(status)
                        .font(Typography.app(13))
                        .foregroundStyle(Palette.textDim)
                }
                TextField("code or URL from the browser", text: $code, axis: .vertical)
                    .font(Typography.machine(12))
                    .foregroundStyle(Palette.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(1...3)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.surfaceRaised))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(phase == .rejected ? Palette.waiting.opacity(0.4) : Color.clear,
                                    lineWidth: 1)
                    )
                let ready = !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                inkControl("Sign in") { Task { await sendCode() } }
                    .disabled(!ready)
                Text(phase == .rejected
                     ? "your code is kept · codes expire, so fetch a fresh one if this repeats"
                     : "the code is a one-time grant · it expires in a few minutes")
                    .font(Typography.machine(10))
                    .foregroundStyle(Palette.textFaint)
            }
        }
        .padding(14)
    }

    // MARK: - C2 · couldn't confirm

    private var unconfirmedBoard: some View {
        VStack(spacing: 14) {
            // A new mark: the unconfirmed outcome had no shape in the kit. Amber follows
            // AgentGroup.unrecognised, which is already amber on the same reasoning —
            // "cannot be read" is nearer to needs-you than to nothing-to-do.
            statusMark("questionmark", tone: Palette.waiting)
            Text("Couldn't confirm the sign-in")
                .font(Typography.app(17, .semibold))
                .foregroundStyle(Palette.text)
                .multilineTextAlignment(.center)
            Text("It may have worked. Accounts reads each identity off your box — if \(account.label) now has an email, you are in.")
                .font(Typography.app(13))
                .lineSpacing(3)
                .foregroundStyle(Palette.textDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 290)
            Text("no identity after 45s · pane closed")
                .font(Typography.machine(11))
                .foregroundStyle(Palette.textFaint)
            VStack(spacing: 8) {
                inkControl("Check Accounts") { finish() }
                outlineControl("Try again") { Task { await start() } }
            }
            .padding(.top, 2)
        }
    }

    // MARK: - C3 · not supported

    private var unsupportedBoard: some View {
        VStack(spacing: 14) {
            // Deliberately colourless: nothing is waiting, running or dead here, so no
            // status hue may appear. The only colour is the identity chip.
            Text("—")
                .font(Typography.machine(15))
                .foregroundStyle(Palette.textDim)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Palette.surface))
                .overlay(Circle().stroke(Palette.hairline, lineWidth: 1))
            Text("Sign-in isn't supported for \(account.kind) accounts yet")
                .font(Typography.app(17, .semibold))
                .foregroundStyle(Palette.text)
                .multilineTextAlignment(.center)
            Text("Nothing to retry from here. Log in on the box pointed at this account's folder and it turns up in Accounts by itself.")
                .font(Typography.app(13))
                .lineSpacing(3)
                .foregroundStyle(Palette.textDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 290)
            monoCard(caption: "On your box", body: unsupportedCommand)
            Button { finish() } label: {
                Text("Got it")
                    .font(Typography.app(15, .semibold))
                    .foregroundStyle(Palette.textDim)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.plain)
        }
    }

    /// Lifted from `AccountsSetupView`'s own instructions rather than written here, so the
    /// two screens cannot drift into telling the user different things.
    private var unsupportedCommand: String {
        let dir = account.configDir ?? "~/.\(account.kind)"
        let envVar = account.kind == "codex" ? "CODEX_HOME" : "\(account.kind.uppercased())_HOME"
        return "\(envVar)=\(dir) \(account.kind)"
    }

    // MARK: - D · signed in

    private var signedInBoard: some View {
        VStack(spacing: 14) {
            statusMark("checkmark", tone: Palette.done)
            Text("Signed in to \(account.label)")
                .font(Typography.app(17, .semibold))
                .foregroundStyle(Palette.text)
                .multilineTextAlignment(.center)
            // The outcome is WHICH IDENTITY LANDED, so it is drawn as the Accounts row you
            // are about to be returned to.
            HStack(spacing: 12) {
                identityChip(size: 40, corner: 10, glyph: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.label)
                        .font(Typography.app(15, .semibold))
                        .foregroundStyle(Palette.text)
                    Text(signedInEmail ?? "resolving identity…")
                        .font(Typography.machine(12))
                        .foregroundStyle(Palette.textDim)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.hairline, lineWidth: 1))
            Text("read back from your box · returning to accounts")
                .font(Typography.machine(11))
                .foregroundStyle(Palette.textFaint)
        }
    }

    // MARK: - shared pieces

    private func stepHeading(_ number: String, _ title: String) -> some View {
        HStack(spacing: 10) {
            numeralTile(number)
            Text(title).font(Typography.app(15, .semibold)).foregroundStyle(Palette.text)
            Spacer(minLength: 0)
        }
    }

    /// The step numeral: mono on a raised tile. It used to be white on a violet circle —
    /// the violet is retired, and a number is machine data anyway.
    private func numeralTile(_ number: String) -> some View {
        Text(number)
            .font(Typography.machine(10, .semibold))
            .foregroundStyle(Palette.textDim)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.surfaceRaised))
    }

    /// The acting control: the filled capsule (ink fill, ground label), as Approve elsewhere.
    private func inkControl(_ title: String, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon { Image(systemName: icon).font(.system(size: 13, weight: .semibold)) }
                Text(title)
            }
        }
        .buttonStyle(.capsule(.filled, .large, fullWidth: true))
    }

    private func outlineControl(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.capsule(.secondary, .large, fullWidth: true))
    }

    /// The capsule idiom, same geometry as the "exhausted" and "no account" pills.
    private func statusPill(_ text: String, tone: Color) -> some View {
        Text(text)
            .font(Typography.machine(11, .semibold))
            .foregroundStyle(tone)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(tone.opacity(0.12)))
            .overlay(Capsule().stroke(tone.opacity(0.5), lineWidth: 1))
    }

    private func statusMark(_ symbol: String, tone: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(tone)
            .frame(width: 30, height: 30)
            .background(Circle().fill(tone.opacity(0.12)))
            .overlay(Circle().stroke(tone.opacity(0.5), lineWidth: 1.5))
    }

    /// `AccountsSetupView`'s captioned mono chip.
    private func monoCard(caption: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption)
                .font(Typography.app(12, .semibold))
                .foregroundStyle(Palette.textFaint)
            Text(body)
                .font(Typography.machine(12))
                .foregroundStyle(Palette.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.surfaceRaised))
        }
    }

    private func identityChip(size: CGFloat, corner: CGFloat, glyph: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner)
                .fill(AgentIdentity.gradient(for: account.kind))
                .frame(width: size, height: size)
            Text(AgentIdentity.glyph(for: account.kind))
                .font(Typography.app(glyph, .bold))
                .foregroundStyle(.white)
        }
    }

    /// The method switch, as a bordered footer row rather than a floating violet link.
    @ViewBuilder
    private var methodFooter: some View {
        // C2 deliberately has none: the flow already ran, and that screen resolves it.
        if phase != .signedIn && phase != .unsupported && phase != .unconfirmed {
            Button {
                method = (method == .oauth) ? .setupToken : .oauth
                Task { await start() }
            } label: {
                VStack(spacing: 3) {
                    Text(method == .oauth ? "Use a setup token instead" : "Use browser sign-in instead")
                        .font(Typography.app(13.5, .medium))
                        .foregroundStyle(Palette.textDim)
                    Text(method == .oauth ? "swaps to setup-token · starts over" : "swaps to browser sign-in · starts over")
                        .font(Typography.machine(10))
                        .foregroundStyle(Palette.textFaint)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Palette.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - flow (unchanged)

    private func start() async {
        guard let configDir = account.configDir,
              let cmd = claudeLoginCommand(kind: account.kind, configDir: configDir, method: method)
        else {
            status = "Sign-in isn't supported for \(account.kind) accounts yet."
            phase = .unsupported
            return
        }
        scrapeTask?.cancel()
        if let old = paneID { try? await client.closePane(paneID: old); paneID = nil }
        signInURL = nil
        signedIn = false
        submitting = false
        submitBaseline = ""
        copied = false
        linkUsed = false
        waitedSeconds = 0
        baselineEmail = nil
        signedInEmail = nil
        code = ""
        status = "Starting sign-in…"
        phase = .starting
        do {
            // Background: the user never sees this pane, so it must not take focus.
            let pane = try await client.splitPane(cwd: nil, focus: false)
            paneID = pane
            try await client.sendText(pane: pane, text: cmd)
            try await client.sendPaneKeys(pane: pane, keys: ["Enter"])
            status = "Getting your sign-in link…"
            scrapeTask = Task { await scrapeLoop(pane: pane) }
        } catch {
            status = "Couldn't start sign-in — check the connection to your box and try again."
            phase = .unconfirmed
        }
    }

    private func scrapeLoop(pane: String) async {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for _ in 0..<150 {  // ~10 min at 4s
            if Task.isCancelled { return }
            if let read = try? await client.read(pane: pane, source: .recentUnwrapped, format: .text) {
                let text = read.text
                if signInURL == nil, let detector {
                    let range = NSRange(text.startIndex..., in: text)
                    if let url = detector.matches(in: text, range: range)
                        .compactMap({ $0.url })
                        .first(where: { $0.scheme == "https" }) {
                        signInURL = url
                        status = "Open the link, approve, then paste the code below."
                        phase = .linkReady
                    }
                }
                // FAILURE is still read from the pane, and only from output produced
                // after the submission (see `submitBaseline`) — the harness does print
                // its rejections.
                if submitting, claudeLoginOutcome(from: outputSinceSubmit(text)) == .failed {
                    submitting = false
                    status = "That code didn't work — check it and try again."
                    phase = .rejected
                }
                // If the harness DOES print a success line (the setup-token path can),
                // use it only to poll immediately rather than to declare success. The
                // probe below stays the sole authority on whether an identity landed;
                // this just saves a tick.
                if claudeLoginOutcome(from: text) == .signedIn, await pollSignedIn() {
                    return
                }
            }
            // SUCCESS is NOT read from the pane.
            //
            // It used to be, by matching phrases like "login successful" in the
            // terminal text — and it silently never fired, because
            // `claude auth login --claudeai` is an INTERACTIVE TUI that renders a
            // screen instead of printing those lines. Real sign-ins completed and
            // wrote credentials while this sheet sat there and then claimed "no
            // response", which is the worst possible way to be wrong: it reports
            // failure over something that worked.
            //
            // The daemon already reads each account's identity out of its config-home,
            // so ask IT. Verified against the live box: a logged-out config-home
            // reports no email (whether or not it has a `.claude.json`), and one gets
            // set the moment a login lands. That makes absent -> present an
            // authoritative signal with no phrase matching and no extra pane.
            if await pollSignedIn() { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
        }
    }

    /// Asks the daemon whether this account's identity has appeared yet. Returns true
    /// when sign-in is confirmed (and closes the sheet).
    ///
    /// Only an absent -> present transition counts. Re-signing in to an account that
    /// ALREADY has an identity cannot be confirmed this way — the email is rewritten
    /// with the same value — so that case falls through to the timeout rather than
    /// claiming a success it did not observe.
    private func pollSignedIn() async -> Bool {
        guard let accounts = try? await client.accountsList(),
              let mine = accounts.first(where: { $0.id == account.id })
        else { return false }
        if baselineEmail == nil { baselineEmail = .some(mine.email) }
        let before = baselineEmail ?? nil
        guard signInConfirmed(baseline: before, current: mine.email), let now = mine.email
        else { return false }

        signedIn = true
        signedInEmail = now
        submitting = false
        status = "Signed in as \(now)."
        phase = .signedIn
        // Long enough to read as an outcome — and long enough to notice WHICH identity
        // it was — then hand the user back to a refreshed Accounts list.
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        if !Task.isCancelled { finish() }
        return true
    }

    private func sendCode() async {
        guard let pane = paneID else { return }
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        // Freeze what the pane already said, so the previous attempt's rejection cannot
        // fail this one before it is even answered.
        submitBaseline = (try? await client.read(pane: pane, source: .recentUnwrapped, format: .text))?.text ?? ""
        submitting = true
        waitedSeconds = 0
        status = "Signing you in…"
        phase = .submitting
        do {
            try await client.sendText(pane: pane, text: value)
            try await client.sendPaneKeys(pane: pane, keys: ["Enter"])
            armSubmitTimeout(for: value)
        } catch {
            // Never leave the spinner up on a send that did not happen.
            submitting = false
            status = "Couldn't send the code — check the connection to your box and try again."
            phase = .rejected
        }
    }

    /// The pane output produced since the last submission. Falls back to the whole buffer
    /// when the baseline is no longer a prefix — the rolling window scrolled past it —
    /// which at worst costs one extra retry prompt rather than a stuck spinner.
    private func outputSinceSubmit(_ text: String) -> String {
        guard !submitBaseline.isEmpty else { return text }
        guard text.hasPrefix(submitBaseline) else { return text }
        return String(text.dropFirst(submitBaseline.count))
    }

    /// Bounds the wait that the spinner hides the input behind.
    ///
    /// Success and explicit failure both arrive via the scrape loop, but neither is
    /// guaranteed: the harness can print something we do not recognise, or nothing at all.
    /// Without this the input would never come back and the sign-in could not be retried —
    /// the spinner would simply be the last thing that ever happened. On expiry the typed
    /// code is restored rather than discarded, so a long token does not have to be pasted
    /// again.
    private func armSubmitTimeout(for submitted: String) {
        Task {
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled, submitting, !signedIn else { return }
            submitting = false
            if code.isEmpty { code = submitted }
            status = "Couldn't confirm the sign-in. Check Accounts — it may have worked."
            phase = .unconfirmed
        }
    }

    private func finish() {
        // Pane teardown belongs to `cleanupPane` via `.onDisappear`, so there is ONE
        // owner rather than two paths that must each remember. `dismiss()` triggers it.
        onFinished()
        dismiss()
    }

    /// Cancel the scrape and close the background pane. Idempotent: it clears `paneID`
    /// first, so being called twice (finish → dismiss → onDisappear) closes once.
    private func cleanupPane() {
        scrapeTask?.cancel()
        guard let pane = paneID else { return }
        paneID = nil
        Task { try? await client.closePane(paneID: pane) }
    }
}
