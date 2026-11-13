import Foundation
import HerdrKit

/// The herdr session last picked on each machine (#347), so a relaunch or a reconnect
/// opens the same session. Keyed by `user@host:port`; nil means the default session.
enum SessionChoice {
    private static let defaultsKey = ShareStorage.sessionsKey

    static func machineKey(_ creds: SSHCredentials) -> String {
        machineKey(username: creds.username, host: creds.host, port: creds.port)
    }

    /// The same key from a saved host's parts, for stores wiped when the host is forgotten.
    static func machineKey(username: String, host: String, port: UInt16) -> String {
        "\(username)@\(HostKey.canonical(host: host, port: port))"
    }

    static func remembered(for creds: SSHCredentials) -> String? {
        let all = ShareStorage.defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        guard let name = all[machineKey(creds)], CitadelTransport.isSessionName(name) else { return nil }
        return name
    }

    static func remember(_ session: String?, for creds: SSHCredentials) {
        var all = ShareStorage.defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        all[machineKey(creds)] = session
        ShareStorage.defaults.set(all, forKey: defaultsKey)
    }

    /// The bucket for per-machine stores (saved terminals): pane IDs only mean something
    /// inside one session, so a named session gets its own. The default session keeps the
    /// plain `host:port` key every existing saved terminal already lives under.
    static func storeKey(_ creds: SSHCredentials) -> String {
        let base = HostKey.canonical(host: creds.host, port: creds.port)
        guard let name = creds.session, name != "default" else { return base }
        return base + "#" + name
    }
}
