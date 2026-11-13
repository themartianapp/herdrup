import Foundation
import HerdrKit
import Security

/// Which credential a saved host authenticates with.
enum SavedAuthKind: String, Codable {
    case key
    case password
}

/// The secret half of a saved host, routed to the matching Keychain store by the
/// store's add/update. Keeps one code path for both auth kinds.
enum HostSecret {
    case key(String)
    case password(String)
}

/// A saved connection target for one-tap reconnect. Holds ONLY the non-secret
/// fields (host — which may include ":port" — and username). The private key or
/// password is NEVER stored here; it lives in the Keychain (`KeychainCredentialStore`),
/// keyed by `id`. So the on-disk (UserDefaults) list can be read without exposing a secret.
struct SavedHost: Codable, Identifiable, Hashable {
    let id: UUID
    var host: String
    var username: String
    /// Optional friendly label ("My Mac"). Legacy saved hosts predate this field, so it
    /// is OPTIONAL — old JSON without the key decodes to `nil` (no migration needed).
    var nickname: String?
    /// Which credential this host uses. OPTIONAL for migration exactly like `nickname`:
    /// JSON written before password auth has no `authKind`, decodes to nil, and resolves
    /// to `.key` via `auth` — so every legacy host stays key-based.
    var authKind: SavedAuthKind?

    /// The resolved auth kind for callers — a legacy (nil) host is key-based.
    var auth: SavedAuthKind { authKind ?? .key }

    /// The primary display label: the nickname if set, else the host itself.
    var label: String {
        if let n = nickname?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
        return host
    }
}

/// Persists saved hosts: the host+username list in UserDefaults, each host's
/// private key in the Keychain (device-local, unlock-gated). The two are kept in
/// lockstep — `save` only records a host once its key persists, and `delete`
/// removes both — so a listed host is always one-tap reconnectable.
final class SavedHostsStore: ObservableObject {
    static let shared = SavedHostsStore()

    private let defaultsKey = ShareStorage.hostsKey
    private let keychain = KeychainCredentialStore(service: "dev.herdr.credentials")
    /// A host's password lives in its own Keychain service so a host's key and
    /// password never collide on the same account id. Same device-only discipline.
    private let passwordKeychain = KeychainCredentialStore(service: "dev.herdr.credentials.password")

    /// Published to SwiftUI, which forbids that from a background thread: in a Debug build a
    /// write off the main thread stops here rather than as a runtime warning (#664).
    @Published private(set) var hosts: [SavedHost] {
        willSet { assert(Thread.isMainThread, "SavedHostsStore.hosts is published; change it on the main thread") }
    }

    init() {
        if let data = ShareStorage.defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([SavedHost].self, from: data) {
            hosts = decoded
        } else {
            hosts = []
        }
    }

    /// Adds a NEW saved host (its own id) and stores its secret (key or password) in
    /// the Keychain. Returns false — WITHOUT recording the host — if a required field
    /// is missing or the secret could not be persisted, so the UI never offers a
    /// one-tap host it cannot open.
    @discardableResult
    func add(nickname: String, host: String, username: String, secret: HostSecret) -> Bool {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !u.isEmpty else { return false }
        let id = UUID()
        // Persist the secret FIRST; only record the host if it actually stuck.
        let kind: SavedAuthKind
        switch secret {
        case .key(let pem):
            let key = pem.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, keychain.save(account: id.uuidString, secret: key) else { return false }
            kind = .key
        case .password(let password):
            // A password is NOT trimmed — leading/trailing spaces can be significant.
            guard !password.isEmpty,
                  passwordKeychain.save(account: id.uuidString, secret: password) else { return false }
            kind = .password
        }
        hosts.insert(
            SavedHost(id: id, host: h, username: u, nickname: n.isEmpty ? nil : n, authKind: kind),
            at: 0)
        persist()
        return true
    }

    /// Updates an existing saved host IN PLACE (by id): host / username / nickname, and
    /// the secret only when `secret` is non-nil (nil = keep the current one, so an edit
    /// never forces re-entering it). Switching auth kind drops the now-stale other
    /// secret. Returns false without changing anything if a required field is missing
    /// or a provided secret fails to persist.
    @discardableResult
    func update(_ existing: SavedHost, nickname: String, host: String, username: String, secret: HostSecret?) -> Bool {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !u.isEmpty else { return false }
        guard let i = hosts.firstIndex(where: { $0.id == existing.id }) else { return false }
        var newKind = existing.auth
        // Replace the secret only if a new one was entered; a failed persist aborts the
        // whole update so the record never drifts out of lockstep with the Keychain.
        if let secret {
            switch secret {
            case .key(let pem):
                let key = pem.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty,
                      keychain.save(account: existing.id.uuidString, secret: key) else { return false }
                newKind = .key
            case .password(let password):
                guard !password.isEmpty,
                      passwordKeychain.save(account: existing.id.uuidString, secret: password) else { return false }
                newKind = .password
            }
            // Auth kind changed → best-effort drop the stale secret from the other store.
            if newKind != existing.auth {
                switch existing.auth {
                case .key: _ = keychain.delete(account: existing.id.uuidString)
                case .password: _ = passwordKeychain.delete(account: existing.id.uuidString)
                }
            }
        }
        hosts[i].host = h
        hosts[i].username = u
        hosts[i].nickname = n.isEmpty ? nil : n
        hosts[i].authKind = newKind
        persist()
        // Pointed at another machine (or account): what the old one showed is not this one's.
        if h != existing.host || u != existing.username { Self.wipeContentCache(existing) }
        return true
    }

    /// The private key for a saved host, from the Keychain. Nil if missing/unreadable
    /// — the caller must treat that as "cannot reconnect", not "empty key".
    func key(for host: SavedHost) -> String? { keychain.load(account: host.id.uuidString) }

    /// The password for a saved host, from the Keychain. Nil if missing/unreadable.
    func password(for host: SavedHost) -> String? { passwordKeychain.load(account: host.id.uuidString) }

    /// The host's secret from this phone's Keychain, or nil when it is not here (the host
    /// list came from another phone, or the secret was deleted). A key is trimmed; a
    /// password is not, since its leading/trailing spaces can be significant.
    func secret(for saved: SavedHost) -> HostSecret? {
        switch saved.auth {
        case .key:
            guard let key = key(for: saved)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty else { return nil }
            return .key(key)
        case .password:
            guard let password = password(for: saved), !password.isEmpty else { return nil }
            return .password(password)
        }
    }

    /// What connecting to a saved host takes: its credentials, or why there are none.
    enum Connection {
        case ready(SSHCredentials)
        /// The saved address does not parse; the editor fixes it.
        case unparseableHost
        /// The secret is not on this phone; the editor asks for it.
        case missingSecret
    }

    /// The one conversion from a saved host to connection credentials, for a tapped row
    /// and for a machine just paired alike.
    func connection(for saved: SavedHost) -> Connection {
        guard let ep = HostEndpoint.parse(saved.host) else { return .unparseableHost }
        switch secret(for: saved) {
        case nil:
            return .missingSecret
        case .key(let key):
            return .ready(SSHCredentials(host: ep.host, port: ep.port, username: saved.username,
                                         privateKeyPEM: key, remoteSocketPath: ""))
        case .password(let password):
            return .ready(SSHCredentials(host: ep.host, port: ep.port, username: saved.username,
                                         password: password, remoteSocketPath: ""))
        }
    }

    /// Removes a saved host. Deletes the secret from BOTH stores first and drops the
    /// host record ONLY if both confirm it is gone — a failed Keychain delete must not
    /// leave a secret orphaned while the host vanishes from the UI. Each delete returns
    /// true on errSecItemNotFound, so a host with only one secret still deletes cleanly.
    /// Returns whether it removed; on false the row stays put so the user can retry.
    @discardableResult
    func delete(_ host: SavedHost) -> Bool {
        guard keychain.delete(account: host.id.uuidString),
              passwordKeychain.delete(account: host.id.uuidString) else { return false }
        hosts.removeAll { $0.id == host.id }
        persist()
        // A forgotten machine leaves nothing it showed behind (agents, chats, Gram, screens).
        Self.wipeContentCache(host)
        return true
    }

    private static func wipeContentCache(_ host: SavedHost) {
        #if !HERDR_SHARE_EXTENSION
        AppContentCache.wipe(machine: host)
        #endif
    }

    private func persist() {
        #if DEBUG && !HERDR_SHARE_EXTENSION
        // Mock runs never write the saved list: a launch-argument list stays as seeded, and
        // a host added in one UI test does not show up in the next.
        if ScreenshotMock.mode != nil { return }
        #endif
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        ShareStorage.defaults.set(data, forKey: defaultsKey)
    }
}

/// A Keychain store for per-host secrets (the private SSH key). Mirrors
/// `KeychainHostKeyPolicy`'s storage discipline — checked statuses, update-in-place
/// rather than delete-then-add — but is its own service and uses
/// `WhenUnlockedThisDeviceOnly`: a private key is more sensitive than a host-key
/// pin, so it is reachable only while the device is unlocked and NEVER syncs to
/// iCloud or another device. The secret is only ever returned by `load`; it is
/// never logged or surfaced elsewhere.
struct KeychainCredentialStore {
    let service: String

    @discardableResult
    func save(account: String, secret: String) -> Bool {
        #if DEBUG && !HERDR_SHARE_EXTENSION
        if ScreenshotMock.mode != nil { MockSecrets.shared.set(secret, service: service, account: account); return true }
        #endif
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Update the value IN PLACE if the item exists (no window where the key is
        // absent); only add when there is nothing to update. Every status checked.
        let updated = SecItemUpdate(base as CFDictionary,
                                    [kSecValueData as String: Data(secret.utf8)] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var add = base
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func load(account: String) -> String? {
        #if DEBUG && !HERDR_SHARE_EXTENSION
        if ScreenshotMock.mode != nil { return MockSecrets.shared.get(service: service, account: account) }
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let secret = String(data: data, encoding: .utf8) else { return nil }
        return secret
    }

    /// Deletes the secret. Returns true only when it is actually GONE — errSecSuccess
    /// (deleted) or errSecItemNotFound (already absent). Any other OSStatus (e.g. the
    /// Keychain temporarily unavailable) returns false, so the caller does not drop the
    /// host record while the key still lives here.
    @discardableResult
    func delete(account: String) -> Bool {
        #if DEBUG && !HERDR_SHARE_EXTENSION
        if ScreenshotMock.mode != nil { MockSecrets.shared.set(nil, service: service, account: account); return true }
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

#if DEBUG && !HERDR_SHARE_EXTENSION
/// Saved-host secrets in screenshot mocks and UI tests: in memory, because an unsigned
/// simulator build cannot write the Keychain and a mock run must leave nothing behind.
private final class MockSecrets: @unchecked Sendable {
    static let shared = MockSecrets()
    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    func get(service: String, account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return secrets["\(service)/\(account)"]
    }

    func set(_ secret: String?, service: String, account: String) {
        lock.lock(); defer { lock.unlock() }
        secrets["\(service)/\(account)"] = secret
    }
}
#endif
