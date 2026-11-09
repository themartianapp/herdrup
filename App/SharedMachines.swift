import Foundation
import HerdrKit

struct SharedMachineGroup: Identifiable {
    struct Identity: Hashable {
        let hostID: String
        let publicKey: Data

        init(_ access: GuestAccess) {
            hostID = access.endpoint.hostID
            publicKey = access.endpoint.hostPublicKey
        }
    }
    let id: Identity
    var accesses: [GuestAccess]
}

/// Machines someone else shared with this phone ("Shared with you"). Each entry is a
/// grant for one agent on one machine; it holds no secret (the device key lives in
/// the Keychain), so the list is plain JSON in UserDefaults.
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
            return SharedMachinesStore(defaults: nil, machines: seeded)
        }
        #endif
        return SharedMachinesStore(defaults: ShareStorage.defaults)
    }()

    static let defaultsKey = ShareStorage.guestsKey

    /// Nil keeps the list in memory only (screenshot mocks and UI tests).
    private let defaults: UserDefaults?

    @Published private(set) var machines: [GuestAccess]

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
        return groups
    }

    init(defaults: UserDefaults?, machines: [GuestAccess] = []) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([GuestAccess].self, from: data) {
            self.machines = decoded
        } else {
            self.machines = machines
        }
    }

    /// Adds a grant, replacing any earlier one with the same id (accepting a fresh
    /// invite from the same host as the same guest refreshes it in place).
    func add(_ access: GuestAccess) {
        if let index = machines.firstIndex(where: { $0.id == access.id }) {
            machines[index] = access
        } else {
            machines.append(access)
        }
        persist()
    }

    /// Saves what the host reports about a grant now (the owner renamed its agent). A grant
    /// this phone already left stays gone.
    func update(_ access: GuestAccess) {
        guard let index = machines.firstIndex(where: { $0.id == access.id }),
              machines[index] != access else { return }
        machines[index] = access
        persist()
    }

    /// Removes a grant; its host stops pushing to this phone for it.
    func remove(_ access: GuestAccess) {
        GuestPushCenter.shared.leaving(access)
        machines.removeAll { $0.id == access.id }
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
