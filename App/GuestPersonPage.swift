import HerdrKit
import SwiftUI

// Settings → Shared access → a person (design 4B, owner pick 2026-11-16; frames o2 and o3 of
// the account-shares mockup): the agents they hold on one machine, the devices that may use
// them, and removing either or the whole person.

/// The value a PEOPLE row pushes: `GuestAccessModel.Person.id`.
struct GuestPersonRoute: Hashable {
    let id: String
}

/// A person's initial on the neutral tile the Shared access rows use.
struct GuestInitialTile: View {
    let name: String
    let size: CGFloat

    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(Typography.app((size * 0.44).rounded(), .bold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: (size / 4).rounded()).fill(GuestStyle.avatar))
            .accessibilityHidden(true)
    }
}

/// How a person reads in the PEOPLE row and on their page.
enum GuestPeopleText {
    /// Each agent once, in the order the person got them.
    static func agentNames(_ person: GuestPerson) -> [String] {
        var names: [String] = []
        for grant in person.grants {
            let name = grant.grant?.agentName ?? "an agent"
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// "enyo, orgstudio on hetzner".
    static func agents(_ person: GuestPerson, on machine: GuestMachine) -> String {
        "\(agentNames(person).joined(separator: ", ")) on \(machine.label)"
    }

    /// "enyo and orgstudio", for sentences.
    static func agentList(_ person: GuestPerson) -> String {
        sentence(agentNames(person))
    }

    /// "HerdrUp account · iPhone, MacBook" or, for a plain share, "Only this device · iPhone".
    static func devices(_ person: GuestPerson) -> String {
        let names = person.devices.map(deviceName)
        if person.accountBound {
            return names.isEmpty ? "HerdrUp account" : "HerdrUp account · " + names.joined(separator: ", ")
        }
        return (["Only this device"] + names.prefix(1)).joined(separator: " · ")
    }

    static func deviceName(_ device: GuestDevice) -> String {
        device.device ?? "Unnamed device"
    }

    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    /// "a", "a and b", "a, b and c".
    static func sentence(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }
}

/// One person's page. It reads the person live from the model, so a removal shows as soon as
/// the reload lands, and it closes itself once the person is gone.
struct GuestPersonPage: View {
    let client: HerdrClient
    @ObservedObject var model: GuestAccessModel
    let personID: String
    let reload: () async -> Void

    private enum Confirmation: Equatable {
        case person
        case grant(GuestRecord)
    }

    @Environment(\.dismiss) private var dismiss
    /// The person as last loaded, so the page keeps its content while it closes after a
    /// removal instead of going blank under the pop.
    @State private var shown: GuestAccessModel.Person?
    @State private var confirming: Confirmation?
    @State private var working = false
    @State private var actionError: String?

    private var current: GuestAccessModel.Person? { model.person(id: personID) ?? shown }

    private var confirmTitle: String {
        guard let item = current, let confirming else { return "" }
        return title(confirming, item: item)
    }

    var body: some View {
        let item = current
        ZStack {
            Palette.ground.ignoresSafeArea()
            VStack(spacing: 0) {
                SectionTopBar(title: item?.person.name ?? "", leading: {
                    SectionBackSlot(.leading) { backButton }
                }) {
                    SectionBackSlot(.trailing) { backButton }
                }
                ScrollView {
                    if let item { content(item) }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .alert(confirmTitle,
               isPresented: $confirming.isPresent(), presenting: confirming) { confirm in
            if let item {
                Button(action(confirm, item: item), role: .destructive) {
                    Task { await perform(confirm, item: item) }
                }
                .accessibilityIdentifier("guest-confirm-remove")
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirm in
            if let item { Text(message(confirm, item: item)) }
        }
        .alert("Shared access", isPresented: $actionError.isPresent()) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .task(id: model.person(id: personID)?.person) {
            if let live = model.person(id: personID) {
                shown = live
            } else if model.loaded, shown != nil {
                dismiss()
            }
        }
    }

    private var backButton: some View {
        SectionBarButton(icon: "chevron.left", label: "Back", identifier: "guest-person-back") { dismiss() }
    }

    private func content(_ item: GuestAccessModel.Person) -> some View {
        let person = item.person
        return VStack(alignment: .leading, spacing: 0) {
            header(item)
            GuestStyle.sectionLabel("AGENTS", top: 22)
            GuestStyle.card {
                ForEach(Array(person.grants.enumerated()), id: \.element.guestID) { index, grant in
                    if index > 0 { GuestStyle.divider }
                    agentRow(grant, item: item)
                }
            }
            GuestStyle.sectionLabel("DEVICES")
            GuestStyle.card {
                ForEach(Array(person.devices.enumerated()), id: \.element.fingerprint) { index, device in
                    if index > 0 { GuestStyle.divider }
                    deviceRow(device, item: item)
                }
            }
            footnote(person.accountBound
                     ? "A device is added when \(person.name) signs in to HerdrUp there and opens a share. It shows here and in the activity log."
                     : "\(person.name) accepted on this device only. Another device needs a new invite.")
            Button("Remove \(person.name)") { confirming = .person }
                .buttonStyle(.capsule(.destructive, .large, fullWidth: true))
                .disabled(working)
                .padding(.horizontal, 16).padding(.top, 24)
                .accessibilityIdentifier("guest-person-remove")
            Text(removalLine(person))
                .font(Typography.app(13)).foregroundStyle(Palette.textFaint)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                .padding(.horizontal, 24).padding(.top, 10)
        }
        .padding(.bottom, 24)
    }

    // MARK: Header

    private func header(_ item: GuestAccessModel.Person) -> some View {
        let person = item.person
        let state = GuestPresence(lastSeenMs: person.lastSeenMs)
        // Name the device only when it is the one behind the person's latest use.
        let device = person.lastSeenDevice.flatMap { $0.lastSeenMs == person.lastSeenMs ? $0.device : nil }
        return VStack(spacing: 6) {
            GuestInitialTile(name: person.name, size: 72)
            Text(person.name).font(Typography.app(24, .bold)).foregroundStyle(Palette.text)
                .padding(.top, 8)
            HStack(spacing: 6) {
                Circle().fill(state.color).frame(width: 8, height: 8)
                Text(state.headline(on: device))
            }
            Text(person.accountBound
                 ? "HerdrUp account · " + GuestPeopleText.count(person.devices.count, "device")
                 : GuestPeopleText.devices(person))
        }
        .font(Typography.app(14)).foregroundStyle(Palette.textDim)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16).padding(.top, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("guest-person-header")
    }

    // MARK: Agents

    private func agentRow(_ grant: GuestRecord, item: GuestAccessModel.Person) -> some View {
        let agent = grant.grant?.agentName ?? "An agent"
        var detail = "on \(item.machine.label)"
        if let created = grant.createdMs { detail += " · since \(GuestPresence.day(created))" }
        if sharesGram(grant, on: item.machine) { detail += " · Gram shared" }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                GramAvatar(name: agent, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent).font(Typography.app(16, .semibold)).foregroundStyle(Palette.text)
                    Text(detail).font(Typography.app(13)).foregroundStyle(Palette.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("guest-agent-\(agent)")
                Button("Remove") { confirming = .grant(grant) }
                    .buttonStyle(.capsule(.secondary, .compact))
                    .disabled(working)
                    .accessibilityLabel("Remove \(agent)")
                    .accessibilityIdentifier("guest-agent-remove-\(agent)")
            }
            Toggle(isOn: Binding(
                get: { sharesGram(grant, on: item.machine) },
                set: { on in Task { await setShareGram(on, for: grant, on: item.machine) } }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Share Gram").font(Typography.app(14, .semibold)).foregroundStyle(Palette.text)
                    Text("\(item.person.name) sees what \(agent) sends you, and is notified")
                        .font(Typography.app(12)).foregroundStyle(Palette.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Palette.brand)
            .padding(.leading, 42)
            .accessibilityIdentifier("guest-share-gram-\(agent)")
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private func sharesGram(_ grant: GuestRecord, on machine: GuestMachine) -> Bool {
        model.shareGramPending[GuestAccessModel.shareKey(grant, on: machine)] ?? grant.shareGram
    }

    /// `guest.update` for one share, on the machine that holds it. Flips made while one is in
    /// flight are sent after it, as the latest choice only, so the daemon ends on the owner's
    /// last choice; the run that sends them reloads and reports once, at the end.
    private func setShareGram(_ on: Bool, for grant: GuestRecord, on machine: GuestMachine) async {
        let key = GuestAccessModel.shareKey(grant, on: machine)
        model.shareGramPending[key] = on
        var failure: String?
        let outcome = await model.shareGramSender.submit(on, for: key) { value in
            do {
                try await client.guestUpdate(guestID: grant.guestID, shareGram: value, machine: machine.alias)
                failure = nil
            } catch let api as APIError where api.code == "invalid_request" && api.message.contains("unknown variant") {
                failure = "Update Herdr on \(machine.label) to share Gram."
                throw api
            } catch {
                failure = GuestAdminError.message(error)
                throw error
            }
        }
        guard case .finished(let failed) = outcome else { return }
        await reload()
        model.shareGramPending[key] = nil
        if failed, let failure { actionError = failure }
    }

    // MARK: Devices

    private func deviceRow(_ device: GuestDevice, item: GuestAccessModel.Person) -> some View {
        let name = GuestPeopleText.deviceName(device)
        var status: [String] = []
        if let seen = device.lastSeenMs { status.append(GuestPresence(lastSeenMs: seen).deviceText) }
        if let added = device.addedMs { status.append("added \(GuestPresence.day(added))") }
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: Self.icon(for: name))
                .font(.system(size: 16)).foregroundStyle(Palette.textDim)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(Typography.app(16)).foregroundStyle(Palette.text)
                HStack(spacing: 6) {
                    if let seen = device.lastSeenMs {
                        Circle().fill(GuestPresence(lastSeenMs: seen).color).frame(width: 7, height: 7)
                    }
                    Text(status.joined(separator: " · "))
                }
                .font(Typography.machine(12)).foregroundStyle(Palette.textFaint)
                // The key ties the device to its activity-log lines.
                Text(device.fingerprint)
                    .font(Typography.machine(11.5)).foregroundStyle(Palette.textFaint)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("guest-device-\(name)")
            // A plain share is one device: removing it is removing the person, below.
            if item.person.accountBound {
                Menu {
                    Button(role: .destructive) {
                        Task { await removeDevice(device, item: item) }
                    } label: {
                        Label("Remove device", systemImage: "minus.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.circle(diameter: 30))
                .disabled(working)
                .accessibilityLabel("\(name) actions")
                .accessibilityIdentifier("guest-device-menu-\(name)")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// The device's kind from the name it gave herdr ("iPhone", "MacBook", "Browser (…)").
    private static func icon(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("iphone") { return "iphone" }
        if lower.contains("ipad") { return "ipad" }
        if lower.contains("browser") || lower.contains("chrome") || lower.contains("safari") { return "globe" }
        if lower.contains("macbook") { return "laptopcomputer" }
        return "desktopcomputer"
    }

    /// herdr keeps each share's devices separately, so a device goes from every share of the
    /// person that it may use.
    private func removeDevice(_ device: GuestDevice, item: GuestAccessModel.Person) async {
        working = true
        for grant in item.person.grantsHolding(fingerprint: device.fingerprint) {
            do {
                try await client.guestRemoveDevice(guestID: grant.guestID, fingerprint: device.fingerprint,
                                                   machine: item.machine.alias)
            } catch let api as APIError where api.code == "invalid_request" && api.message.contains("unknown variant") {
                actionError = "Update Herdr on \(item.machine.label) to remove a device."
                break
            } catch {
                actionError = GuestAdminError.message(error)
                break
            }
        }
        await reload()
        working = false
    }

    // MARK: Removing the person or one agent

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(Typography.app(12.5)).foregroundStyle(Palette.textFaint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18).padding(.top, 8)
    }

    /// What "Remove <name>" takes away, under the button.
    private func removalLine(_ person: GuestPerson) -> String {
        let agents = GuestPeopleText.agentList(person)
        if person.accountBound, person.devices.count > 1 {
            return "Removes \(agents) from all \(person.devices.count) devices at once."
        }
        let device = person.devices.first.map(GuestPeopleText.deviceName) ?? "device"
        return "Removes \(agents) from \(person.name)'s \(device)."
    }

    private func title(_ confirm: Confirmation, item: GuestAccessModel.Person) -> String {
        "\(action(confirm, item: item))?"
    }

    private func action(_ confirm: Confirmation, item: GuestAccessModel.Person) -> String {
        switch confirm {
        case .person: return "Remove \(item.person.name)"
        case .grant(let grant): return "Remove \(grant.grant?.agentName ?? "this agent")"
        }
    }

    /// Names what goes: the agents, the machine, and every device that loses them.
    private func message(_ confirm: Confirmation, item: GuestAccessModel.Person) -> String {
        let person = item.person
        let devices = person.devices.map(GuestPeopleText.deviceName)
        let reach = devices.count > 1
            ? "on all \(devices.count) devices (\(devices.joined(separator: ", ")))"
            : "on their \(devices.first ?? "device")"
        switch confirm {
        case .person:
            return "\(person.name) loses \(GuestPeopleText.agentList(person)) on \(item.machine.label) \(reach) right away, "
                + "and open sessions close. To come back, \(person.name) needs a new invite."
        case .grant(let grant):
            return "\(person.name) loses \(grant.grant?.agentName ?? "this agent") on \(item.machine.label) \(reach) "
                + "right away, and open sessions close."
        }
    }

    private func perform(_ confirm: Confirmation, item: GuestAccessModel.Person) async {
        switch confirm {
        case .person: await revoke(item.person.revokeTargets, on: item.machine)
        case .grant(let grant): await revoke([.guest(grant.guestID)], on: item.machine)
        }
    }

    private func revoke(_ targets: [GuestRevokeTarget], on machine: GuestMachine) async {
        working = true
        for target in targets {
            do {
                try await client.guestRevoke(target, machine: machine.alias)
            } catch {
                actionError = GuestAdminError.message(error)
                break
            }
        }
        await reload()
        working = false
    }
}
