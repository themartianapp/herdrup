import Crypto
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH
import XCTest
@testable import HerdrKit

/// A machine this device got by pairing is pinned to the host key the approver checked, and
/// HerdrUp Desktop checks the ECDSA one. Stock OpenSSH has ECDSA and ed25519 host keys and
/// would show this app ed25519 first, so the pin would refuse the very host it was made for
/// unless the app asks for that key's algorithm alone. This runs the real connect path
/// (`SSHConnectionCore` with the pinning validator `CitadelTransport` builds) against an
/// in-process SSH server holding both keys.
final class PairedHostKeyAlgorithmTests: XCTestCase {
    /// Accepts any password: the test is about the host key, not the user.
    private final class AnyPassword: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
        let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .password
        func requestReceived(request: NIOSSHUserAuthenticationRequest,
                             responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
            responsePromise.succeed(.success)
        }
    }

    func testAPairedMachineIsShownTheKeyItsPinWasMadeFrom() async throws {
        let ed25519 = NIOSSHPrivateKey(ed25519Key: .init())
        let ecdsa = NIOSSHPrivateKey(p256Key: .init())
        let auth = AnyPassword()
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                        role: .server(SSHServerConfiguration(hostKeys: [ed25519, ecdsa], userAuthDelegate: auth)),
                        allocator: channel.allocator, inboundChildChannelInitializer: nil))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let port = try XCTUnwrap(server.localAddress?.port.flatMap { UInt16(exactly: $0) })

        // What the approver sent: the ECDSA key, as an OpenSSH line.
        let sent = String(openSSHPublicKey: ecdsa.publicKey)
        let algorithm = try XCTUnwrap(HostKeyRecorder.algorithm(ofOpenSSHKey: sent))
        XCTAssertEqual(algorithm, "ecdsa-sha2-nistp256")
        let pin = try XCTUnwrap(HostKeyRecorder.fingerprint(ofOpenSSHKey: sent))

        /// Connects as a paired device that pinned `pin`, offering `hostKeyAlgorithm` alone or
        /// (nil) every algorithm; returns the key the host showed and the pin accepted.
        func connect(hostKeyAlgorithm: String?) async throws -> String? {
            let pins = PinningHostKeyPolicy.PinStore()
            pins.pin(host: "127.0.0.1", port: port, fingerprint: pin)
            let recorder = HostKeyRecorder(PinningHostKeyPolicy(store: pins))
            var credentials = SSHCredentials(host: "127.0.0.1", port: port, username: "pair",
                                             password: "pair", remoteSocketPath: "")
            credentials.hostKeyAlgorithm = hostKeyAlgorithm
            let core = SSHConnectionCore(
                credentials: credentials,
                hostKeyValidator: .custom(PinningHostKeyValidator(host: "127.0.0.1", port: port, policy: recorder)),
                connectTimeoutNanoseconds: 10_000_000_000)
            do {
                _ = try await core.connectedClient()
            } catch {
                await core.close()
                throw error
            }
            await core.close()
            return recorder.trustedKey
        }

        // Asked for ECDSA alone, the host shows the key the pin was made from.
        let shown = try await connect(hostKeyAlgorithm: algorithm)
        XCTAssertEqual(shown, sent)

        // Offering every algorithm, the host shows ed25519, which the ECDSA pin refuses.
        do {
            _ = try await connect(hostKeyAlgorithm: nil)
            XCTFail("an unrestricted client connected through the ECDSA pin")
        } catch TransportError.hostKeyRejected(_, let fingerprint) {
            XCTAssertEqual(fingerprint, sshHostKeyFingerprintSHA256(ed25519.publicKey))
        }

        try await server.close()
    }
}
