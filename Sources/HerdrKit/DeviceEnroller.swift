import Crypto
import Foundation

/// Enrols this install's guest key as a device of the signed-in account (DESIGN §3.2).
///
/// The device is the existing `GuestIdentity`: the X25519 key a guest proves in every Noise
/// handshake, generated once and kept in a `GuestKeyStore` (the Keychain in the app, this
/// device only). It is never synced and never replaced, since replacing it would sever every
/// share. An X25519 key can't sign, so possession is proved with a key agreement against the
/// challenge's ephemeral server key, exactly as AccountService/src/devices.ts checks it:
///
///     k   = X25519(d, E)                      (all zero → refused)
///     mk  = HKDF-SHA256(ikm = k, salt, info = "herdrup account enrol v1", 32 bytes)
///     mac = HMAC-SHA256(mk, "herdrup-enrol-v1|" account_id "|" device_pub "|" challenge_id)
///
/// with keys, salt and mac in unpadded base64url. AccountService/test/vectors/enrol-v1.json
/// pins it for every client.
public struct DeviceEnroller: Sendable {
    public static let info = "herdrup account enrol v1"
    public static let messagePrefix = "herdrup-enrol-v1|"

    public enum Failure: Error, Equatable, Sendable {
        /// The challenge's server key or salt isn't 32 bytes of base64url.
        case malformedChallenge
        /// The server key is a low-order point: the shared secret would be all zero.
        case invalidServerKey
    }

    /// What `POST /v1/devices` carries besides the challenge id.
    public struct Proof: Equatable, Sendable {
        public let devicePub: String
        public let mac: String
    }

    private let session: AccountSession
    private let keyStore: GuestKeyStore

    public init(session: AccountSession, keyStore: GuestKeyStore) {
        self.session = session
        self.keyStore = keyStore
    }

    /// Enrols this install's guest key (creating it on first use) under `name`. Idempotent:
    /// a key already in the account binds this session to that device (200).
    ///
    /// The service's refusals surface as `AccountError.refused` with its code:
    /// `device_in_other_account` (409: offer to sign out of that account first),
    /// `session_has_device` (409), `too_many_devices` (403).
    public func enrol(name: String, platform: AccountPlatform) async throws -> AccountDevice {
        let identity = try GuestIdentity.loadOrCreate(store: keyStore)
        let client = session.client
        // Challenge and enrolment run together, so a retry after a refresh starts from a new
        // challenge: a challenge is one use and lives 60 seconds.
        return try await session.authorized { token in
            let challenge = try await client.deviceChallenge(accessToken: token)
            let proof = try Self.proof(privateKey: identity.privateKey, challenge: challenge)
            return try await client.enrolDevice(challengeID: challenge.challengeID, devicePub: proof.devicePub,
                                                mac: proof.mac, name: name, platform: platform, accessToken: token)
        }
    }

    /// The device's side of the proof: `k = X25519(d, E)`, then the MAC.
    public static func proof(privateKey: Curve25519.KeyAgreement.PrivateKey, challenge: DeviceChallenge) throws -> Proof {
        guard let serverPub = Base64URL.decode(challenge.serverPub), serverPub.count == 32,
              let salt = Base64URL.decode(challenge.salt), salt.count == 32
        else { throw Failure.malformedChallenge }
        let shared = try sharedSecret(privateKey: privateKey, publicKey: serverPub)
        let devicePub = Base64URL.encode(privateKey.publicKey.rawRepresentation)
        return Proof(devicePub: devicePub,
                     mac: mac(sharedSecret: shared, salt: salt, accountID: challenge.accountID,
                              devicePub: devicePub, challengeID: challenge.challengeID))
    }

    /// X25519 of `privateKey` and `publicKey`, refusing a low-order public key (an all-zero
    /// result; BoringSSL refuses it itself, CryptoKit returns the zeros).
    public static func sharedSecret(privateKey: Curve25519.KeyAgreement.PrivateKey, publicKey: Data) throws -> Data {
        let shared: Data
        do {
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
            shared = try privateKey.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
        } catch {
            throw Failure.invalidServerKey
        }
        guard shared.contains(where: { $0 != 0 }) else { throw Failure.invalidServerKey }
        return shared
    }

    /// The enrolment MAC (unpadded base64url) over a shared secret, as the Worker computes it.
    public static func mac(sharedSecret: Data, salt: Data, accountID: String, devicePub: String,
                           challengeID: String) -> String {
        let mk = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: sharedSecret), salt: salt,
                                        info: Data(info.utf8), outputByteCount: 32)
        let message = messagePrefix + accountID + "|" + devicePub + "|" + challengeID
        return Base64URL.encode(Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: mk)))
    }
}
