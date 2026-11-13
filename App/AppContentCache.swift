import Foundation
import HerdrKit

/// The app's one `ContentCache` (slow-network fix 4): what the agent list, each chat,
/// Gram and each terminal last showed, so a cold start paints it at once and refreshes
/// behind it.
///
/// In Caches: never backed up, never synced to iCloud, and iOS may purge it under storage
/// pressure, which only costs the head start. A forgotten machine and a left share are
/// wiped (`SavedHostsStore.delete`, `SharedMachinesStore.remove`).
enum AppContentCache {
    static let shared: ContentCache = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return ContentCache(root: caches.appendingPathComponent("ContentCache", isDirectory: true))
    }()

    /// The scope a connection to `creds` reads and records: the machine (`user@host:port`,
    /// as `SessionChoice` keys it) and its herdr session.
    static func scope(for creds: SSHCredentials) -> ContentCacheScope {
        shared.scope(machine: SessionChoice.machineKey(creds), session: creds.session)
    }

    /// The scope a guest share reads and records: that share, and only its one agent.
    static func scope(for access: GuestAccess) -> ContentCacheScope {
        shared.scope(share: access.id, sharedTarget: access.agentTarget, sharedName: access.agentName)
    }

    /// Forgets everything kept for a saved machine, every session of it.
    static func wipe(machine saved: SavedHost) {
        guard let endpoint = HostEndpoint.parse(saved.host) else { return }
        shared.wipe(.machine(SessionChoice.machineKey(username: saved.username,
                                                       host: endpoint.host, port: endpoint.port)))
    }

    /// Forgets everything kept for a share the guest left.
    static func wipe(share access: GuestAccess) {
        shared.wipe(.share(access.id))
    }
}
