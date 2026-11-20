import Foundation
import HerdrKit

/// The app's saved machines and prompts as HerdrKit's `AccountLocalSync` sees them
/// (DESIGN #698 §5). The merge itself (host identity rule, auth kind following the secret,
/// edits made during a sync left alone) lives in HerdrKit, where it is tested; this only maps
/// `SavedHostsStore` and `SavedPromptsStore` onto it. Secrets never move to the account: the
/// sync only asks whether one is here, and a machine's secret moves with it when it takes the
/// account's id.
@MainActor
final class SavedStoresAccountLocal: AccountLocalStore {
    private let hosts: SavedHostsStore
    private let promptStore: SavedPromptsStore
    private let defaults: UserDefaults

    private static let hostIDsKey = "account.sync.hostIDs"
    private static let promptIDsKey = "account.sync.promptIDs"

    init(hosts: SavedHostsStore, prompts: SavedPromptsStore, defaults: UserDefaults) {
        self.hosts = hosts
        self.promptStore = prompts
        self.defaults = defaults
    }

    static func forget(_ defaults: UserDefaults) {
        defaults.removeObject(forKey: hostIDsKey)
        defaults.removeObject(forKey: promptIDsKey)
    }

    var machines: [LocalMachine] {
        hosts.hosts.map { saved in
            LocalMachine(id: saved.id, address: saved.host, username: saved.username, nickname: saved.nickname,
                         authKind: saved.auth == .password ? .password : .key)
        }
    }

    var prompts: [LocalPrompt] {
        promptStore.prompts.map { LocalPrompt(id: $0.id, title: $0.nickname, text: $0.text) }
    }

    func hasSecret(_ id: UUID, kind: SyncHost.AuthKind) -> Bool {
        hosts.hasSecret(id: id, kind: kind == .password ? .password : .key)
    }

    func putMachine(_ machine: LocalMachine) {
        hosts.applySynced(id: machine.id, host: machine.address, username: machine.username,
                          nickname: machine.nickname, authKind: machine.authKind == .password ? .password : .key)
    }

    func moveMachine(_ id: UUID, to newID: UUID) -> Bool {
        guard let saved = hosts.hosts.first(where: { $0.id == id }) else { return false }
        return hosts.adoptSyncID(saved, id: newID)
    }

    func mergeMachine(_ duplicate: UUID, into kept: UUID) -> Bool {
        guard let copy = hosts.hosts.first(where: { $0.id == duplicate }),
              let keeper = hosts.hosts.first(where: { $0.id == kept }) else { return false }
        return hosts.mergeDuplicate(copy, into: keeper)
    }

    func removeMachine(_ id: UUID) -> Bool {
        guard let saved = hosts.hosts.first(where: { $0.id == id }) else { return true }
        return hosts.delete(saved)
    }

    func setPrompts(_ prompts: [LocalPrompt]) {
        promptStore.applySynced(prompts.map { SavedPrompt(id: $0.id, nickname: $0.title, text: $0.text) })
    }

    var heldMachineIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.hostIDsKey) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Self.hostIDsKey) }
    }

    var heldPromptIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.promptIDsKey) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Self.promptIDsKey) }
    }
}
