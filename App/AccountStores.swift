import Foundation
import Security
import HerdrKit

/// What the account screens show about who is signed in, kept beside the session so it survives a
/// relaunch: Google's `display_hint` (the account email). Device-local, never synced, never sent
/// anywhere; deleted whenever the session ends.
protocol AccountHintStore {
    func loadDisplayHint() throws -> String?
    func saveDisplayHint(_ hint: String) throws
    /// Succeeds when the hint is gone, including when there was none.
    func deleteDisplayHint() throws
}

/// The HerdrUp account's refresh token in the Keychain (DESIGN #698 §2.5): service
/// `dev.herdr.account`, account `refresh`, readable after the first unlock on this device only,
/// never synchronizable, in the access group `$(AppIdentifierPrefix)com.jerryfane.herdr`. The
/// access token stays in memory (`AccountSession`). Same checked-status discipline as
/// `KeychainCredentialStore` and `KeychainGuestKeyStore`: every OSStatus is checked, the value
/// is updated in place, and a locked or failing Keychain throws rather than reading as "signed
/// out", which would drop a session that still exists.
///
/// The display hint (`AccountHintStore`) is a second item in the same service with the same
/// attributes, account `display-hint`.
struct KeychainAccountTokenStore: AccountTokenStore, AccountHintStore {
    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { "the Keychain refused the HerdrUp account's sign-in (\(status))" }
    }

    var service = "dev.herdr.account"
    var account = "refresh"
    var hintAccount = "display-hint"
    /// `HerdrKeychainAccessGroup` in Info.plist, which xcodegen fills with
    /// `$(AppIdentifierPrefix)com.jerryfane.herdr` (project.yml). An unsigned simulator build
    /// has no prefix; there the group is left out, and the item lands in the app's default
    /// group, which on a signed build is this same group (the first of keychain-access-groups).
    var accessGroup: String? = KeychainAccountTokenStore.bundleAccessGroup

    static var bundleAccessGroup: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "HerdrKeychainAccessGroup") as? String,
              !group.hasPrefix("com."), !group.hasPrefix("$(") else { return nil }
        return group
    }

    private func base(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    func loadRefreshToken() throws -> String? { try load(account) }
    func saveRefreshToken(_ token: String) throws { try save(token, account) }
    func deleteRefreshToken() throws { try delete(account) }

    func loadDisplayHint() throws -> String? { try load(hintAccount) }
    func saveDisplayHint(_ hint: String) throws { try save(hint, hintAccount) }
    func deleteDisplayHint() throws { try delete(hintAccount) }

    private func load(_ account: String) throws -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw Failure(status: status) }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    private func save(_ text: String, _ account: String) throws {
        let value = Data(text.utf8)
        let updated = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw Failure(status: updated) }
        var add = base(account)
        add[kSecValueData as String] = value
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure(status: added) }
    }

    private func delete(_ account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}

#if DEBUG
/// The display hint in memory, for screenshot mocks and UI tests (no Keychain there).
final class InMemoryAccountHintStore: AccountHintStore {
    private var hint: String?
    init(hint: String?) { self.hint = hint }
    func loadDisplayHint() throws -> String? { hint }
    func saveDisplayHint(_ hint: String) throws { self.hint = hint }
    func deleteDisplayHint() throws { hint = nil }
}
#endif

/// `SyncEngine`'s state as one JSON file in Application Support (`HerdrUp Account/sync-state.json`):
/// the pull revision, this device's copy of the account's items and the changes not yet pushed.
/// Nothing in it is secret (the sync bodies are allowlisted fields only, DESIGN §5.4). Written
/// atomically, excluded from backups (another device restored from it would push a stale queue),
/// and protected until first unlock so a background sync can read it.
struct FileSyncStateStore: SyncStateStore {
    let url: URL

    static func standard() throws -> FileSyncStateStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return FileSyncStateStore(url: support.appendingPathComponent("HerdrUp Account", isDirectory: true)
            .appendingPathComponent("sync-state.json"))
    }

    func loadSyncState() throws -> SyncState? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        return try JSONDecoder().decode(SyncState.self, from: data)
    }

    func saveSyncState(_ state: SyncState) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = url
        try excluded.setResourceValues(values)
    }

    func deleteSyncState() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }
}
