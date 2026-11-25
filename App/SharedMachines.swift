import Foundation
import UIKit
import HerdrKit

/// One machine in SHARED WITH YOU: the grants on it this device holds, and the ones the
/// HerdrUp account holds that this device hasn't opened yet (`synced`, #700). One row per
/// machine, however many agents.
struct SharedMachineGroup: Identifiable {
    struct Identity: Hashable {
        let hostID: String
        let publicKey: Data

        init(_ endpoint: RelayEndpoint) {
            hostID = endpoint.hostID
            publicKey = endpoint.hostPublicKey
        }

        init(_ access: GuestAccess) { self.init(access.endpoint) }
    }
    let id: Identity
    var accesses: [GuestAccess]
    var synced: [AccountShare] = []

    var machineLabel: String { accesses.first?.machineLabel ?? synced.first?.machineLabel ?? "" }
    var ownerName: String { accesses.first?.ownerName ?? synced.first?.ownerName ?? "" }
    var agentNames: [String] { accesses.map(\.agentName) + synced.map(\.agentName) }
}

/// Machines someone else shared with this phone ("Shared with you"). Each entry is a
/// grant for one agent on one machine; it holds no secret (the device key lives in
/// the Keychain), so the list is plain JSON in UserDefaults.
///
/// Shares added to the HerdrUp account (#700) also live in the account's `shares`
/// collection: accepting or leaving one here asks the account to sync (`AccountShareSync`
/// pushes or deletes it), and the account's shares this device hasn't opened are listed as
/// `accountShares` until they are.
@MainActor
final class SharedMachinesStore: ObservableObject {
    static let shared: SharedMachinesStore = {
        #if DEBUG
        // Screenshot mocks and UI tests never read or write the real list; the guest
        // home mocks start with their mock shares, which Leave then removes.
        if let mode = ScreenshotMock.mode {
            let seeded: [GuestAccess] = switch mode {
            case .guest: [GuestMockTransport.access]
            case .guestMachine: GuestMockTransport.machineAccesses
            default: []
            }
            return SharedMachinesStore(defaults: nil, machines: seeded, firstOpen: GuestMockTransport.firstOpen)
        }
        #endif
        return SharedMachinesStore(defaults: ShareStorage.defaults)
    }()

    static let defaultsKey = ShareStorage.guestsKey

    /// Nil keeps the list in memory only (screenshot mocks and UI tests).
    private let defaults: UserDefaults?
    /// Opens an account share on this device for the first time; the relay unless a mock
    /// stands in.
    private let firstOpen: @MainActor (AccountShare) async throws -> GuestAccess

    @Published private(set) var machines: [GuestAccess]
    /// The HerdrUp account's shares that this device hasn't opened (set by each sync;
    /// empty when signed out).
    @Published private(set) var accountShares: [AccountShare] = []

    /// Nothing shared with this device, here or through the account.
    var isEmpty: Bool { machines.isEmpty && accountShares.isEmpty }

    /// Display names are not identity: two hosts can use the same label.
    var groups: [SharedMachineGroup] {
        var groups: [SharedMachineGroup] = []
        var indexes: [SharedMachineGroup.Identity: Int] = [:]
        for access in machines {
            let identity = SharedMachineGroup.Identity(access)
            if let index = indexes[identity] {
                groups[index].accesses.append(access)
            } else {
                indexes[identity] = groups.count
                groups.append(SharedMachineGroup(id: identity, accesses: [access]))
            }
        }
        for share in accountShares {
            let identity = SharedMachineGroup.Identity(share.endpoint)
            if let index = indexes[identity] {
                groups[index].synced.append(share)
            } else {
                indexes[identity] = groups.count
                groups.append(SharedMachineGroup(id: identity, accesses: [], synced: [share]))
            }
        }
        return groups
    }

    init(defaults: UserDefaults?, machines: [GuestAccess] = [],
         firstOpen: @escaping @MainActor (AccountShare) async throws -> GuestAccess = SharedMachinesStore.openOverRelay) {
        self.defaults = defaults
        self.firstOpen = firstOpen
        if let data = defaults?.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([GuestAccess].self, from: data) {
            self.machines = decoded
        } else {
            self.machines = machines
        }
    }

    /// A first open over the relay: the account's statement for this device and the share's
    /// `guest_id`, no invite.
    static func openOverRelay(_ share: AccountShare) async throws -> GuestAccess {
        try await GuestSession.open(share, identity: try GuestDevice.identity(), device: UIDevice.current.model,
                                    statements: AccountGuestStatements())
    }

    /// Adds a grant, replacing any earlier one with the same id (accepting a fresh
    /// invite from the same host as the same guest refreshes it in place). One added to the
    /// account is pushed to it.
    func add(_ access: GuestAccess) {
        if let index = machines.firstIndex(where: { $0.id == access.id }) {
            machines[index] = access
        } else {
            machines.append(access)
        }
        accountShares.removeAll { $0.id == access.id }
        persist()
        if access.accountBound { HerdrUpAccount.shared.sharesChanged() }
    }

    /// Opens a machine from SHARED WITH YOU. The account's shares on it that this device
    /// hasn't opened are opened first, with nothing to accept; the result is the grant its
    /// home starts from. A share that couldn't be opened stays listed, and throws only when
    /// nothing on the machine could be.
    func open(_ group: SharedMachineGroup) async throws -> GuestAccess {
        var failure: Error?
        for share in group.synced {
            do {
                add(try await firstOpen(share))
            } catch {
                failure = failure ?? error
            }
        }
        if let access = machines.first(where: { SharedMachineGroup.Identity($0) == group.id }) { return access }
        throw failure ?? GuestError.revoked
    }

    /// Saves what the host reports about a grant now (the owner renamed its agent). A grant
    /// this phone already left stays gone.
    func update(_ access: GuestAccess) {
        guard let index = machines.firstIndex(where: { $0.id == access.id }),
              machines[index] != access else { return }
        machines[index] = access
        persist()
    }

    /// Removes a grant; its host stops pushing to this phone for it, and nothing it showed
    /// stays on this phone. One in the account leaves the account too, so it leaves every
    /// device.
    func remove(_ access: GuestAccess) {
        drop([access])
        if access.accountBound { HerdrUpAccount.shared.sharesChanged() }
    }

    /// Removes grants left on another device of the account: nothing more to tell it.
    func removeLeftElsewhere(_ ids: Set<String>) {
        drop(machines.filter { ids.contains($0.id) })
    }

    func setAccountShares(_ shares: [AccountShare]) {
        if accountShares != shares { accountShares = shares }
    }

    private func drop(_ accesses: [GuestAccess]) {
        guard !accesses.isEmpty else { return }
        for access in accesses {
            GuestPushCenter.shared.leaving(access)
            AppContentCache.wipe(share: access)
        }
        let ids = Set(accesses.map(\.id))
        machines.removeAll { ids.contains($0.id) }
        persist()
    }

    private func persist() {
        guard let defaults, let data = try? JSONEncoder().encode(machines) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// An invite waiting on the Accept screen. Identifiable so a second link opened while
/// one is showing replaces it rather than being ignored.
struct PendingGuestInvite: Identifiable {
    let id = UUID()
    let invite: GuestInvite
}

/// Where every invite enters the app (a tapped link, a paste, a scan). RootView
/// presents whatever lands here.
@MainActor
final class GuestInviteRouter: ObservableObject {
    static let shared = GuestInviteRouter()

    @Published var pending: PendingGuestInvite?
    /// Why the last link could not be read, shown as an alert.
    @Published var failure: String?
    /// The link to try again from that alert, when it failed only for want of the network.
    @Published private(set) var retryText: String?
    private var resolving: Task<Void, Never>?

    /// Reads `text` as an invite (fetching a short link's sealed invite from its relay) and
    /// presents it, or records why it isn't one. A newer link replaces one still resolving.
    func open(_ text: String) {
        resolving?.cancel()
        failure = nil
        retryText = nil
        resolving = Task { [weak self] in
            do {
                let invite = try await GuestInvite.resolve(text)
                guard !Task.isCancelled else { return }
                self?.pending = PendingGuestInvite(invite: invite)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.retryText = (error as? GuestInvite.Failure) == .unreachable ? text : nil
                self.failure = GuestDevice.describe(error, machine: "")
            }
        }
    }

    /// Opens the link whose fetch failed again.
    func retry() {
        guard let text = retryText else { return }
        open(text)
    }

    /// Whether a URL is an invite link in any form.
    static func isInviteLink(_ url: URL) -> Bool {
        GuestInvite.isInviteLink(url.absoluteString)
    }
}
