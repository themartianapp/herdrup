import HerdrKit
import SwiftUI

// Settings → Shared access: everyone the owner has shared an agent with, across the connected
// machine and its federated peers, the invites nobody has used yet, and the activity log.

@MainActor
final class GuestAccessModel: ObservableObject {
    struct Person: Identifiable {
        let guest: GuestRecord
        let machine: GuestMachine
        var id: String { "\(machine.alias ?? "")|\(guest.guestID)" }
    }

    struct Invite: Identifiable {
        let invite: GuestInviteRecord
        let machine: GuestMachine
        var id: String { "\(machine.alias ?? "")|\(invite.inviteID)" }
    }

    struct LogLine: Identifiable {
        let id: String
        let entry: GuestAuditEntry
        let agentName: String?
        let device: String?
    }

    struct TroubledLink: Identifiable {
        let machine: GuestMachine
        let status: GuestLinkStatus
        var id: GuestMachine { machine }
    }

    struct Failure: Identifiable {
        let machine: GuestMachine
        let message: String
        var id: String { machine.alias ?? "" }
    }

    @Published private(set) var people: [Person] = []
    @Published private(set) var invites: [Invite] = []
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var failures: [Failure] = []
    /// Machines whose people loaded but whose `guest.audit` failed: the log is unknown there,
    /// not empty, and must say so.
    @Published private(set) var logFailures: [Failure] = []
    /// Relay links that are trying and failing, worth telling the owner about.
    @Published private(set) var troubledLinks: [TroubledLink] = []
    @Published private(set) var loaded = false

    private struct MachineResult {
        let machine: GuestMachine
        let listing: GuestListing?
        let entries: [GuestAuditEntry]
        let error: Error?
        let auditError: Error?
    }

    var summary: String {
        guard loaded else { return "" }
        if people.isEmpty && invites.isEmpty {
            return failures.contains { $0.machine.alias == nil } ? "Unavailable" : "Nobody yet"
        }
        var parts: [String] = []
        if !people.isEmpty {
            let agents = Set(people.map { "\($0.machine.alias ?? "")|\($0.guest.grant?.terminalID ?? $0.guest.grant?.agentName ?? "")" })
            parts.append("\(people.count) \(people.count == 1 ? "person" : "people")")
            parts.append("\(agents.count) agent\(agents.count == 1 ? "" : "s")")
        }
        if !invites.isEmpty {
            parts.append("\(invites.count) invite\(invites.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    /// Bumped per load, so a slower earlier load (say, before `machine.status` answered and
    /// named more machines) cannot overwrite a newer one.
    private var generation = 0

    func load(client: HerdrClient, machines: [GuestMachine]) async {
        generation += 1
        let mine = generation
        let results = await withTaskGroup(of: (Int, MachineResult).self) { group in
            for (index, machine) in machines.enumerated() {
                group.addTask {
                    do {
                        let listing = try await client.guestList(machine: machine.alias)
                        do {
                            let entries = try await client.guestAudit(limit: 100, machine: machine.alias)
                            return (index, MachineResult(machine: machine, listing: listing, entries: entries,
                                                         error: nil, auditError: nil))
                        } catch {
                            return (index, MachineResult(machine: machine, listing: listing, entries: [],
                                                         error: nil, auditError: error))
                        }
                    } catch {
                        return (index, MachineResult(machine: machine, listing: nil, entries: [],
                                                     error: error, auditError: nil))
                    }
                }
            }
            var out: [(Int, MachineResult)] = []
            for await result in group { out.append(result) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        guard mine == generation else { return }
        apply(results)
    }

    private func apply(_ results: [MachineResult]) {
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        var people: [Person] = []
        var invites: [Invite] = []
        var log: [LogLine] = []
        var failures: [Failure] = []
        var logFailures: [Failure] = []
        var links: [TroubledLink] = []
        for result in results {
            if let error = result.error {
                // A peer without guest support (or an old daemon) simply has nobody to list.
                if !Self.isMissingFeature(error) || result.machine.alias == nil {
                    failures.append(Failure(machine: result.machine, message: GuestAdminError.message(error)))
                }
                continue
            }
            guard let listing = result.listing else { continue }
            if let auditError = result.auditError {
                logFailures.append(Failure(machine: result.machine, message: GuestAdminError.message(auditError)))
            }
            people += listing.activeGuests.map { Person(guest: $0, machine: result.machine) }
            invites += listing.pendingInvites(nowMs: nowMs).map { Invite(invite: $0, machine: result.machine) }
            if let link = listing.link, link.state == .retrying {
                links.append(TroubledLink(machine: result.machine, status: link))
            }
            let byID = Dictionary(listing.guests.map { ($0.guestID, $0) }, uniquingKeysWith: { first, _ in first })
            for (index, entry) in result.entries.enumerated() {
                let guest = entry.guestID.flatMap { byID[$0] }
                log.append(LogLine(
                    id: "\(result.machine.alias ?? "")|\(entry.tsMs)|\(index)",
                    entry: entry,
                    agentName: guest?.grant?.agentName ?? entry.pane,
                    device: guest?.device.flatMap { $0.isEmpty ? nil : $0 }))
            }
        }
        self.people = people.sorted { ($0.guest.lastSeenMs ?? 0) > ($1.guest.lastSeenMs ?? 0) }
        self.invites = invites.sorted { ($0.invite.createdMs ?? 0) > ($1.invite.createdMs ?? 0) }
        self.log = log.sorted { $0.entry.tsMs > $1.entry.tsMs }
        self.failures = failures
        self.logFailures = logFailures
        self.troubledLinks = links
        loaded = true
    }

    private static func isMissingFeature(_ error: Error) -> Bool {
        guard let api = error as? APIError else { return false }
        return api.code == "unsupported"
            || (api.code == "invalid_request" && api.message.contains("unknown variant"))
    }
}

/// The Shared access detail body.
struct GuestAccessSection: View {
    let client: HerdrClient
    @ObservedObject var model: GuestAccessModel
    let reload: () async -> Void

    @AppStorage(GuestOwnerName.storageKey) private var ownerName = ""
    @State private var revoking: GuestAccessModel.Person?
    @State private var actionError: String?
    /// Share Gram flipped here and not yet confirmed by a reload, by person id, so the switch
    /// shows the owner's latest choice while `guest.update` is in flight.
    @State private var shareGramPending: [String: Bool] = [:]
    /// One `guest.update` per guest at a time; quick flips collapse into the last choice.
    @State private var shareGramSender = LatestValueSender<String, Bool>()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GuestStyle.sectionLabel("PEOPLE", top: 6)
            peopleCard
            ForEach(model.troubledLinks) { link in
                note("Relay link on \(link.machine.label) is retrying"
                     + (link.status.lastError.map { ": \($0)" } ?? ""), tint: Palette.waiting)
            }
            ForEach(model.failures) { failure in
                note("\(failure.machine.label): \(failure.message)", tint: Palette.waiting)
            }
            if !model.invites.isEmpty {
                GuestStyle.sectionLabel("PENDING INVITES")
                invitesCard
            }
            GuestStyle.sectionLabel("ACTIVITY LOG")
            logCard
            GuestStyle.sectionLabel("YOUR NAME")
            ownerNameField
        }
        .confirmationDialog(
            revoking.map { "Revoke \($0.guest.name)?" } ?? "",
            isPresented: $revoking.isPresent(),
            titleVisibility: .visible,
            presenting: revoking
        ) { person in
            Button("Revoke", role: .destructive) {
                Task { await revoke(.guest(person.guest.guestID), on: person.machine) }
            }
        } message: { person in
            Text("\(person.guest.name) loses access to \(person.guest.grant?.agentName ?? "the agent") right away, and any open session closes.")
        }
        .alert("Shared access", isPresented: $actionError.isPresent()) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: People

    @ViewBuilder private var peopleCard: some View {
        if model.people.isEmpty {
            GuestStyle.card {
                Text(model.loaded ? "Nobody has access. Share an agent from its ••• menu."
                                  : "Loading…")
                    .font(Typography.app(14)).foregroundStyle(Palette.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 14)
            }
        } else {
            GuestStyle.card {
                ForEach(Array(model.people.enumerated()), id: \.element.id) { index, person in
                    if index > 0 { GuestStyle.divider }
                    personRow(person)
                }
            }
        }
    }

    private func personRow(_ person: GuestAccessModel.Person) -> some View {
        let guest = person.guest
        let state = GuestPresence(lastSeenMs: guest.lastSeenMs)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text(String(guest.name.prefix(1)).uppercased())
                    .font(Typography.app(16, .bold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 9).fill(GuestStyle.avatar))
                VStack(alignment: .leading, spacing: 2) {
                    Text(guest.name).font(Typography.app(16, .semibold)).foregroundStyle(Palette.text)
                    Text("\(guest.grant?.agentName ?? "An agent") on \(person.machine.label)"
                         + (sharesGram(person) ? " · Gram shared" : ""))
                        .font(Typography.app(13)).foregroundStyle(Palette.textFaint).lineLimit(1)
                    HStack(spacing: 6) {
                        Circle().fill(state.color).frame(width: 8, height: 8)
                        Text(state.text).font(Typography.machine(12)).foregroundStyle(Palette.textFaint)
                    }
                    .padding(.top, 4)
                    if let fingerprint = guest.fingerprint {
                        Text([fingerprint, guest.device.flatMap { $0.isEmpty ? nil : $0 }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(Typography.machine(11.5)).foregroundStyle(Palette.textFaint)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                Button("Revoke") { revoking = person }
                    .buttonStyle(.capsule(.destructive))
                    .accessibilityLabel("Revoke \(guest.name)")
                    .accessibilityIdentifier("guest-revoke-\(guest.name)")
            }
            Toggle(isOn: Binding(
                get: { sharesGram(person) },
                set: { on in Task { await setShareGram(on, for: person) } }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Share Gram").font(Typography.app(14, .semibold)).foregroundStyle(Palette.text)
                    Text("\(guest.name) sees what \(guest.grant?.agentName ?? "the agent") sends you, and is notified")
                        .font(Typography.app(12)).foregroundStyle(Palette.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Palette.brand)
            .padding(.leading, 48)
            .accessibilityIdentifier("guest-share-gram-\(guest.name)")
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private func sharesGram(_ person: GuestAccessModel.Person) -> Bool {
        shareGramPending[person.id] ?? person.guest.shareGram
    }

    /// `guest.update` for one guest, on the machine that holds them. Flips made while one is in
    /// flight are sent after it, as the latest choice only, so the daemon ends on the owner's
    /// last choice; the run that sends them reloads and reports once, at the end.
    private func setShareGram(_ on: Bool, for person: GuestAccessModel.Person) async {
        shareGramPending[person.id] = on
        var failure: String?
        let outcome = await shareGramSender.submit(on, for: person.id) { value in
            do {
                try await client.guestUpdate(guestID: person.guest.guestID, shareGram: value,
                                             machine: person.machine.alias)
                failure = nil
            } catch let api as APIError where api.code == "invalid_request" && api.message.contains("unknown variant") {
                failure = "Update Herdr on \(person.machine.label) to share Gram."
                throw api
            } catch {
                failure = GuestAdminError.message(error)
                throw error
            }
        }
        guard case .finished(let failed) = outcome else { return }
        await reload()
        shareGramPending[person.id] = nil
        if failed, let failure { actionError = failure }
    }

    // MARK: Invites

    private var invitesCard: some View {
        GuestStyle.card {
            ForEach(Array(model.invites.enumerated()), id: \.element.id) { index, item in
                if index > 0 { GuestStyle.divider }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.invite.name).font(Typography.app(16, .semibold)).foregroundStyle(Palette.text)
                        Text(inviteDetail(item))
                            .font(Typography.app(13)).foregroundStyle(Palette.textFaint).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    Button("Cancel") {
                        Task { await revoke(.invite(item.invite.inviteID), on: item.machine) }
                    }
                    .buttonStyle(.capsule(.secondary))
                    .accessibilityLabel("Cancel invite for \(item.invite.name)")
                    .accessibilityIdentifier("guest-cancel-\(item.invite.name)")
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
            }
        }
    }

    private func inviteDetail(_ item: GuestAccessModel.Invite) -> String {
        let agent = item.invite.grant?.agentName ?? "An agent"
        var text = "\(agent) on \(item.machine.label)" + (item.invite.shareGram ? " · Gram shared" : "")
        if let expires = item.invite.expiresMs {
            let remaining = Double(expires) / 1000 - Date().timeIntervalSince1970
            text += " · " + GuestPresence.remaining(remaining)
        }
        return text
    }

    // MARK: Log

    /// A failed `guest.audit` is a row of its own, never the empty state: "nothing yet" would
    /// claim a guest did nothing when the log simply could not be read.
    @ViewBuilder private var logCard: some View {
        if model.log.isEmpty && model.logFailures.isEmpty {
            GuestStyle.card {
                Text(model.loaded ? "Nothing yet. Every message and file a guest sends is recorded here."
                                  : "Loading…")
                    .font(Typography.app(14)).foregroundStyle(Palette.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 14)
            }
        } else {
            GuestStyle.card {
                ForEach(Array(model.logFailures.enumerated()), id: \.element.id) { index, failure in
                    if index > 0 { GuestStyle.divider }
                    logFailureRow(failure)
                }
                ForEach(Array(model.log.enumerated()), id: \.element.id) { index, line in
                    if index > 0 || !model.logFailures.isEmpty { GuestStyle.divider }
                    GuestLogRow(line: line)
                }
            }
        }
    }

    private func logFailureRow(_ failure: GuestAccessModel.Failure) -> some View {
        let source = failure.machine.alias == nil ? "" : " from \(failure.machine.label)"
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(Palette.waiting)
            Text("Couldn't load the activity log\(source): \(failure.message)")
                .font(Typography.app(13.5)).foregroundStyle(Palette.textDim)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("guest-log-failure")
    }

    // MARK: Your name

    private var ownerNameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("", text: $ownerName, prompt: Text("Your name").foregroundStyle(Palette.textFaint))
                .font(Typography.app(16)).foregroundStyle(Palette.text)
                .textInputAutocapitalization(.words).autocorrectionDisabled()
                .padding(.horizontal, 14).frame(height: 50)
                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.surface))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.hairline, lineWidth: 1))
                .accessibilityIdentifier("guest-settings-owner-name")
            Text("People you share with see “Shared by \(GuestOwnerName.normalized(ownerName) ?? "you")”. New invites use it.")
                .font(Typography.app(12.5)).foregroundStyle(Palette.textFaint)
                .padding(.horizontal, 2)
        }
        .padding(.horizontal, 16)
    }

    private func note(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(Typography.app(12.5)).foregroundStyle(tint)
            .padding(.horizontal, 18).padding(.top, 8)
    }

    private func revoke(_ target: GuestRevokeTarget, on machine: GuestMachine) async {
        do {
            try await client.guestRevoke(target, machine: machine.alias)
        } catch {
            actionError = GuestAdminError.message(error)
        }
        await reload()
    }
}

/// One activity-log entry: who did what to which agent, when, and from which key.
struct GuestLogRow: View {
    let line: GuestAccessModel.LogLine

    private var entry: GuestAuditEntry { line.entry }
    private var who: String { entry.name ?? "A guest" }
    private var agent: String { line.agentName ?? "the agent" }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                headline.lineLimit(1)
                Spacer(minLength: 8)
                Text(GuestPresence.clock(entry.tsMs))
            }
            .font(Typography.machine(12, .medium)).foregroundStyle(Palette.textFaint)
            bodyText
            if let fingerprint = entry.fingerprint {
                Text("key " + ([fingerprint, line.device].compactMap { $0 }.joined(separator: " · ")))
                    .font(Typography.machine(11.5)).foregroundStyle(Palette.textFaint)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("guest-log-entry")
    }

    private var name: Text {
        Text(who).foregroundStyle(GuestStyle.label).fontWeight(.semibold)
    }

    private var headline: Text {
        switch entry.event {
        case .prompt, .upload: return Text("\(name) → \(agent)")
        case .accepted: return Text("\(name) joined")
        case .connected: return Text("\(name) connected")
        case .denied: return Text("\(name) was refused")
        case .paused: return Text("\(name) paused")
        case .revoked: return Text("\(name) revoked")
        case .other(let raw): return Text("\(name) \(raw)")
        }
    }

    @ViewBuilder private var bodyText: some View {
        switch entry.event {
        case .prompt:
            Text(entry.text ?? "").font(Typography.app(13.5)).foregroundStyle(Palette.text)
                .lineSpacing(2).lineLimit(6)
        case .upload:
            let size = entry.file?.size.map {
                Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .memory))
                    .font(Typography.machine(12)).foregroundStyle(Palette.textFaint)
            }
            HStack(spacing: 6) {
                Text("📎 \(entry.file?.name ?? "a file")").font(Typography.app(13.5)).foregroundStyle(Palette.text)
                if let size { size }
            }
        default:
            if let detail {
                Text(detail).font(Typography.app(13.5)).foregroundStyle(Palette.textDim)
            }
        }
    }

    private var detail: String? {
        switch entry.event {
        case .accepted: return "Accepted your invite"
        case .connected: return "Opened \(agent)"
        case .denied: return "Blocked \(entry.method ?? "a request")"
        case .paused: return "\(agent) left the foreground, so the stream paused"
        case .revoked: return "Access revoked"
        case .prompt, .upload, .other: return nil
        }
    }
}

/// Plain-language presence and times for the Shared access screen.
enum GuestPresence {
    /// Seen within this window reads as "active".
    static let activeWindowMs: UInt64 = 5 * 60 * 1000

    case active(ago: String), idle(ago: String), neverConnected

    init(lastSeenMs: UInt64?, now: Date = Date()) {
        guard let lastSeenMs else {
            self = .neverConnected
            return
        }
        let nowMs = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        let age = nowMs > lastSeenMs ? nowMs - lastSeenMs : 0
        let ago = Self.ago(seconds: Double(age) / 1000)
        self = age <= Self.activeWindowMs ? .active(ago: ago) : .idle(ago: ago)
    }

    var text: String {
        switch self {
        case .active(let ago): return "active · \(ago)"
        case .idle(let ago): return "last active \(ago)"
        case .neverConnected: return "accepted · not connected yet"
        }
    }

    var color: Color {
        switch self {
        case .active: return Palette.done
        case .idle, .neverConnected: return Palette.textFaint
        }
    }

    static func ago(seconds: Double) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86_400 { return "\(s / 3600) h ago" }
        return "\(s / 86_400) d ago"
    }

    static func remaining(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        if s < 3600 { return "expires in \(max(1, s / 60)) min" }
        return "expires in \(s / 3600) h"
    }

    /// "11:42" today, "Sep 27 11:42" before that.
    static func clock(_ ms: UInt64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "MMM d HH:mm"
        return formatter.string(from: date)
    }
}
