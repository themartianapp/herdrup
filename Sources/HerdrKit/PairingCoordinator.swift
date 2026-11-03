import Foundation

/// Everything that happens AFTER a pairing QR is scanned, in one testable place.
///
/// The camera and the SwiftUI screens have to live in the app target, which does not build
/// on Linux — so the decisions live here instead, behind two small protocols the app
/// conforms to. What is decided here is the part that can be silently wrong: the ORDER of
/// the steps, and which failures are allowed to be partial.
///
/// THE ORDER IS THE POINT.
///
///  1. PIN the host key first. If pinning fails, nothing has touched the other machine —
///     no key has been added, nothing needs revoking. Pinning after redeeming would leave
///     an orphaned key in someone's `authorized_keys` on a failure they did not cause.
///  2. REDEEM, which hands over the public key.
///  3. SAVE the host and its private key.
///
/// A host saved without a pin is the failure worth refusing outright: `HostEditor` hosts
/// trust-on-first-use, so an unpinned entry connects to whatever answers, once, silently.
/// The whole reason the payload carries a fingerprint is to close that window.
public struct PairingCoordinator {

    /// Where a paired host gets recorded. `SavedHostsStore` in the app conforms to this.
    public protocol HostStore {
        /// Returns false WITHOUT recording the host if the secret could not be persisted,
        /// which is the contract `SavedHostsStore.add` already has.
        func addPairedHost(nickname: String, host: String, username: String,
                           privateKeyPEM: String) -> Bool
    }

    /// Where a host-key fingerprint gets pinned. `KeychainHostKeyPolicy` conforms.
    public protocol HostKeyPinner {
        /// Returns whether the pin actually persisted. A `false` here must not be ignored.
        func pin(host: String, port: UInt16, fingerprint: String) -> Bool
    }

    public enum Failure: Swift.Error, Equatable {
        /// The machine could not tell us its host key, so there is nothing to pin and the
        /// first connection would trust whatever answers.
        case noHostKeyToPin
        /// We had a fingerprint but could not store it.
        case couldNotPinHostKey
        /// Pairing itself failed. Carries the underlying reason so the UI can show its
        /// actionable message.
        case pairing(Pairing.Error)
        /// The machine accepted our key, but the host could not be saved on this device.
        /// Deliberately distinct: the remote side DID change, so the message differs.
        case pairedButCouldNotSave

        public var userFacingMessage: String {
            switch self {
            case .noHostKeyToPin:
                return "That computer couldn't identify itself, so connecting to it "
                    + "wouldn't be safe. Make sure SSH is enabled on it, then run "
                    + "`herdr pair` again."
            case .couldNotPinHostKey:
                return "Couldn't save that computer's identity on this device. Try again."
            case .pairing(let error):
                return error.userFacingMessage
            case .pairedButCouldNotSave:
                return "Your key was added to that computer, but this device couldn't save "
                    + "the connection. Remove the line marked herdr-pair from its "
                    + "~/.ssh/authorized_keys and pair again."
            }
        }
    }

    private let store: HostStore
    private let pinner: HostKeyPinner
    /// Injectable so tests drive the real socket protocol against a stub daemon.
    private let redeem: (Pairing.Payload, String, String) async throws -> Void

    public init(
        store: HostStore,
        pinner: HostKeyPinner,
        redeem: @escaping (Pairing.Payload, String, String) async throws -> Void = {
            try await Pairing.redeem(payload: $0, publicKeyLine: $1, deviceLabel: $2)
        }
    ) {
        self.store = store
        self.pinner = pinner
        self.redeem = redeem
    }

    /// Pair with the machine described by a scanned payload.
    ///
    /// - Parameter deviceLabel: shown in the machine's `authorized_keys` so a person can
    ///   recognise and revoke this device later. A device name, not a secret.
    /// - Returns: the nickname the host was saved under.
    /// ASYNC, and the reason is not style. The redemption is a blocking socket round
    /// trip, so it must leave the caller's actor — but the store and the pinner must NOT.
    /// `store.addPairedHost` mutates an `@Published` property, and SwiftUI forbids that
    /// off the main actor. Awaiting only the socket keeps steps 1 and 3 on the caller's
    /// actor while step 2 goes wide, instead of detaching the whole thing and mutating
    /// observable state from a background thread.
    @discardableResult
    public func completePairing(
        payload: Pairing.Payload,
        deviceLabel: String,
        nickname: String? = nil
    ) async throws -> String {
        // 1. Pin BEFORE touching the other machine.
        guard let fingerprint = payload.hostKeyFingerprint else {
            throw Failure.noHostKeyToPin
        }
        // Version 2 names the SSH port; the host is then a bare address, used as is (no
        // ":port" stripping, which would misread the last group of an IPv6 literal).
        let pinHost = payload.sshPort == nil ? bareHost(payload.host) : payload.host
        let port = payload.sshPort.flatMap(UInt16.init(exactly:)) ?? sshPort(for: payload.host)
        guard pinner.pin(host: pinHost, port: port, fingerprint: fingerprint) else {
            throw Failure.couldNotPinHostKey
        }

        // 2. Hand over the PUBLIC half. The private key stays in `key` and goes to the
        //    Keychain below; it is never sent and never written anywhere else.
        let key = PairingKey(comment: deviceLabel)
        do {
            try await redeem(payload, key.authorizedKeysLine, deviceLabel)
        } catch let error as Pairing.Error {
            throw Failure.pairing(error)
        }

        // 3. Record the host. The store persists the secret first and returns false
        //    without recording anything if that fails, so a false here means nothing was
        //    half-written locally — but the remote machine HAS our key, hence its own case.
        let name = nickname ?? defaultNickname(for: payload)
        guard store.addPairedHost(
            nickname: name,
            host: savedHost(payload),
            username: payload.user,
            privateKeyPEM: key.privateKeyPEM)
        else { throw Failure.pairedButCouldNotSave }

        return name
    }

    /// The SSH port to pin against — NOT the pairing port.
    ///
    /// The payload's `port` is the short-lived pairing listener, which is gone seconds
    /// later; SSH is a different service on a different port. Pinning against the pairing
    /// port would store the fingerprint under a key the SSH connection never looks up, so
    /// the pin would silently miss and first contact would trust-on-first-use anyway —
    /// the exact hole this is meant to close.
    private func sshPort(for host: String) -> UInt16 {
        guard let colon = host.lastIndex(of: ":"),
              let explicit = UInt16(host[host.index(after: colon)...])
        else { return 22 }
        return explicit
    }

    /// The host without any ":port" suffix, matching how the pin store keys entries.
    private func bareHost(_ host: String) -> String {
        guard let colon = host.lastIndex(of: ":"),
              UInt16(host[host.index(after: colon)...]) != nil
        else { return host }
        return String(host[host.startIndex..<colon])
    }

    /// The destination to save: the payload's host, plus ":<ssh_port>" when a version-2
    /// payload names an SSH port other than 22, in the "host:port" form `HostEndpoint`
    /// parses (bracketed for an IPv6 literal).
    private func savedHost(_ payload: Pairing.Payload) -> String {
        guard let sshPort = payload.sshPort, sshPort != 22 else { return payload.host }
        let host = payload.host
        return host.contains(":") ? "[\(host)]:\(sshPort)" : "\(host):\(sshPort)"
    }

    private func defaultNickname(for payload: Pairing.Payload) -> String {
        "\(payload.user)@\(bareHost(payload.host))"
    }
}
