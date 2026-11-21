import Foundation
import Security
import HerdrKit

/// The guest device key in the Keychain: one generic-password item, readable after
/// the first unlock (so a share can refresh from the background) and never synced,
/// because the key is this install's identity to every host that shared with it.
/// Mirrors `KeychainCredentialStore`'s discipline (checked statuses, update in
/// place), but stores raw bytes and throws, so a locked or failing Keychain is never
/// mistaken for "no key yet", which would mint a new identity and sever every share.
struct KeychainGuestKeyStore: GuestKeyStore {
    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { "the Keychain refused this device's guest key (\(status))" }
    }

    var service = "dev.herdr.guest"
    var account = "device-key"

    private var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    func loadGuestKey() throws -> Data? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw Failure(status: status) }
        return data
    }

    func saveGuestKey(_ rawKey: Data) throws {
        let updated = SecItemUpdate(base as CFDictionary, [kSecValueData as String: rawKey] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw Failure(status: updated) }
        var add = base
        add[kSecValueData as String] = rawKey
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure(status: added) }
    }
}

/// This install's guest identity, created on first use and kept for the life of the
/// install: leaving a share removes the grant, not the key.
enum GuestDevice {
    static func identity() throws -> GuestIdentity {
        try GuestIdentity.loadOrCreate(store: keyStore)
    }

    /// Where this install's guest key lives. The device the HerdrUp account enrols
    /// (`DeviceEnroller`) is this same key.
    static var keyStore: GuestKeyStore {
        #if DEBUG && !HERDR_SHARE_EXTENSION
        if ScreenshotMock.mode != nil { return mockKeyStore }
        #endif
        return KeychainGuestKeyStore()
    }

    #if DEBUG && !HERDR_SHARE_EXTENSION
    /// A fixed key, so mock screens never touch the Keychain and show a stable fingerprint.
    private static let mockKeyStore = InMemoryGuestKeyStore(key: Data((1...32).map { UInt8($0) }))
    #endif

    /// A readable sentence for anything accepting or connecting as a guest can throw.
    static func describe(_ error: Error, machine: String) -> String {
        let text: String
        if let guest = GuestError.classify(error) {
            text = guest == .hostOffline ? "\(machine) is offline" : guest.description
        } else if let failure = error as? GuestInvite.Failure {
            text = failure.description
        } else if let failure = error as? GuestIdentity.Failure, failure == .corruptKey {
            text = "this phone's guest key is unreadable"
        } else if let keychain = error as? KeychainGuestKeyStore.Failure {
            text = keychain.description
        } else {
            text = error.localizedDescription
        }
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
