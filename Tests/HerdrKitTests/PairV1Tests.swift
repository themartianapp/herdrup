import Crypto
import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import XCTest
@testable import HerdrKit

/// pair-v1 against AccountService/test/vectors/pair-v1.json, the vector the account service,
/// HerdrUp Desktop and this app share.
final class PairV1Tests: XCTestCase {
    struct Vector: Decodable {
        let requesterPriv, approverPriv, requesterPub, approverPub, sshPub: String
        let nonceB, nonceT, commit, code, requestID: String
        let seq: UInt64
        let envelopeJSON: String
        let sealed: String

        enum CodingKeys: String, CodingKey {
            case code, seq, sealed, commit
            case requesterPriv = "requester_priv"
            case approverPriv = "approver_priv"
            case requesterPub = "requester_pub"
            case approverPub = "approver_pub"
            case sshPub = "ssh_pub"
            case nonceB = "nonce_b"
            case requestID = "request_id"
            case nonceT = "nonce_t"
            case envelopeJSON = "envelope_json"
        }
    }

    static func vector() throws -> Vector {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AccountService/test/vectors/pair-v1.json")
        return try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
    }

    private func b64(_ text: String) throws -> Data { try XCTUnwrap(Base64URL.decode(text)) }

    private func key(_ text: String) throws -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: b64(text))
    }

    func testMatchesTheSharedVector() throws {
        let v = try Self.vector()
        let requester = try key(v.requesterPriv), approver = try key(v.approverPriv)
        let B = try b64(v.requesterPub), T = try b64(v.approverPub), S = try b64(v.sshPub)
        XCTAssertEqual(requester.publicKey.rawRepresentation, B)
        XCTAssertEqual(approver.publicKey.rawRepresentation, T)

        let commit = try PairV1.commit(requesterPub: B, sshPub: S, nonceB: b64(v.nonceB))
        XCTAssertEqual(Base64URL.encode(commit), v.commit)
        XCTAssertNoThrow(try PairV1.open(requesterPub: B, sshPub: S, commit: b64(v.commit), nonceB: b64(v.nonceB)))
        XCTAssertEqual(try PairV1.code(requesterPub: B, sshPub: S, approverPub: T, nonceB: b64(v.nonceB), nonceT: b64(v.nonceT)),
                       v.code)

        let iv = try XCTUnwrap(Base64URL.decode(v.sealed)).prefix(12)
        let sealed = try PairV1.seal(approver: approver, requesterPub: B, sshPub: S, requestID: v.requestID, seq: v.seq,
                                     plaintext: Data(v.envelopeJSON.utf8), iv: Data(iv))
        XCTAssertEqual(sealed, v.sealed)

        let plain = try PairV1.openEnvelope(requester: requester, approverPub: T, sshPub: S, requestID: v.requestID,
                                            seq: v.seq, sealed: v.sealed)
        XCTAssertEqual(String(decoding: plain, as: UTF8.self), v.envelopeJSON)
        XCTAssertThrowsError(try PairV1.openEnvelope(requester: requester, approverPub: T, sshPub: S, requestID: v.requestID,
                                                     seq: v.seq + 1, sealed: v.sealed))
        // S and the request id are bound: the same sealed list doesn't open for another key or
        // replayed onto another request.
        let otherS = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        XCTAssertThrowsError(try PairV1.openEnvelope(requester: requester, approverPub: T, sshPub: otherS,
                                                     requestID: v.requestID, seq: v.seq, sealed: v.sealed))
        let otherID = String(v.requestID.dropLast()) + (v.requestID.hasSuffix("A") ? "B" : "A")
        XCTAssertThrowsError(try PairV1.openEnvelope(requester: requester, approverPub: T, sshPub: S,
                                                     requestID: otherID, seq: v.seq, sealed: v.sealed))
        // The envelope is pair-v1's: approve-v1's label doesn't open it.
        XCTAssertThrowsError(try ApproveV1.openEnvelope(browser: requester, approverPub: T, seq: v.seq, sealed: v.sealed))
        let machines = try PairEnvelope.parse(plain).machines
        XCTAssertEqual(machines.first?.status, .added)
        XCTAssertEqual(machines.first?.port, 22)
    }

    /// A service that swaps S (or B, or the revealed nonce) is caught by the commit, and the
    /// codes stop matching.
    func testRefusesASwappedSSHKeyOrNonce() throws {
        let v = try Self.vector()
        let B = try b64(v.requesterPub), T = try b64(v.approverPub), S = try b64(v.sshPub)
        let otherS = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        XCTAssertThrowsError(try PairV1.open(requesterPub: B, sshPub: otherS, commit: b64(v.commit), nonceB: b64(v.nonceB))) {
            XCTAssertEqual($0 as? ApproveV1.Failure, .tampered)
        }
        XCTAssertThrowsError(try PairV1.open(requesterPub: B, sshPub: S, commit: b64(v.commit),
                                             nonceB: Data(repeating: 0x12, count: 32)))
        XCTAssertNotEqual(try PairV1.code(requesterPub: B, sshPub: otherS, approverPub: T, nonceB: b64(v.nonceB), nonceT: b64(v.nonceT)),
                          v.code)
    }

    func testTheEnvelopeRoundTripsItsMachines() throws {
        let machine = PairEnvelope.Machine(nickname: "build-box", host: "10.0.0.12", port: 2222, user: "ci",
                                           hostKey: "ssh-ed25519 AAAA", status: .failed, reason: "timed out")
        let json = try PairEnvelope(machines: [machine]).json()
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertTrue(text.contains(#""host_key":"ssh-ed25519 AAAA""#), text)
        XCTAssertTrue(text.contains(#""v":1"#), text)
        XCTAssertEqual(try PairEnvelope.parse(json).machines, [machine])
        XCTAssertThrowsError(try PairEnvelope.parse(Data(#"{"v":2,"machines":[]}"#.utf8)))
    }

    func testTheLabelIsOnePrintableLineOfAtMost80() {
        XCTAssertEqual(PairMachines.label(requester: "MacBook Air", approver: "Jerry's iPhone"),
                       "MacBook Air (approved on Jerry's iPhone)")
        let long = PairMachines.label(requester: String(repeating: "n", count: 120) + "\nx", approver: "iPad\t\u{7}")
        XCTAssertLessThanOrEqual(long.count, 80)
        XCTAssertTrue(long.hasSuffix(" (approved on iPad)"), long)
        XCTAssertFalse(long.contains("\n"))
    }

    func testAPairPushOpensItsRequestAndAGuestPushNeverDoes() {
        let pair: [AnyHashable: Any] = ["aps": ["category": "pair_request", "alert": ["body": "x"]], "request_id": "Req1"]
        XCTAssertEqual(PushTapTarget(userInfo: pair), .pairRequest("Req1"))
        XCTAssertEqual(PushTapTarget(userInfo: ["aps": ["category": "pair_request"]]), PushTapTarget.none)
        var guest = pair
        guest["herdr_guest"] = true
        XCTAssertEqual(PushTapTarget(userInfo: guest), .droppedGuest)
    }

    /// The approver sends the host key its connection trusted, and the new device pins exactly
    /// the fingerprint that connection checked.
    func testTheRecordedHostKeyIsTheOneThePinChecks() throws {
        let loop = EmbeddedEventLoop()
        func decide(_ recorder: HostKeyRecorder, _ key: NIOSSHPublicKey) -> Bool {
            let promise = loop.makePromise(of: Void.self)
            var trusted: Bool?
            promise.futureResult.whenComplete { if case .success = $0 { trusted = true } else { trusted = false } }
            PinningHostKeyValidator(host: "fleet-hel1", port: 22, policy: recorder)
                .validateHostKey(hostKey: key, validationCompletePromise: promise)
            loop.run()
            return trusted ?? false
        }
        let pins = PinningHostKeyPolicy.PinStore()
        let recorder = HostKeyRecorder(PinningHostKeyPolicy(store: pins))
        XCTAssertTrue(decide(recorder, NIOSSHPrivateKey(ed25519Key: .init()).publicKey))

        let line = try XCTUnwrap(recorder.trustedKey)
        XCTAssertTrue(line.hasPrefix("ssh-ed25519 "), line)
        XCTAssertEqual(HostKeyRecorder.fingerprint(ofOpenSSHKey: line), pins.pinned(key: "fleet-hel1:22"))
        XCTAssertNil(HostKeyRecorder.fingerprint(ofOpenSSHKey: "not a key"))

        // A rejected key is not recorded.
        let other = HostKeyRecorder(PinningHostKeyPolicy(store: pins))
        XCTAssertFalse(decide(other, NIOSSHPrivateKey(ed25519Key: .init()).publicKey))
        XCTAssertNil(other.trustedKey)
    }

    /// An approver that saw a host certificate may send it as host_key. This app never
    /// negotiates certificate host-key algorithms, so the host shows it the plain certified
    /// key; the pin must be that key's, or every connect after pairing would be refused.
    func testAHostCertificatePinsTheKeyItCertifies() throws {
        let plain = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPe20jCjHILbi0oia+XTjaYy8WtHOKueMP/ymXXJkIfO"
        let cert = "ssh-ed25519-cert-v01@openssh.com AAAAIHNzaC1lZDI1NTE5LWNlcnQtdjAxQG9wZW5zc2guY29tAAAAIN46Pyh56idR9QvyrRush6rqJB3pwTFhDggryxWMCsIQAAAAIPe20jCjHILbi0oia+XTjaYy8WtHOKueMP/ymXXJkIfOAAAAAAAAAAAAAAACAAAACmZsZWV0LWhlbDEAAAAOAAAACmZsZWV0LWhlbDEAAAAAaVWq8AAAAAB8JFDwAAAAAAAAAAAAAAAAAAAAMwAAAAtzc2gtZWQyNTUxOQAAACCy41EgMLY0ZutF4qiBtWxbAj94qNa1AW3ssqbIn6CUuQAAAFMAAAALc3NoLWVkMjU1MTkAAABAMnP2AtVx44FZRW49/K4MEj7RkDbTJ7lOKA07x7EwomCw3G0GI1Bdq2VSk5WFLAvb8W3DkmIm/0QGgeGDRd6IDw=="
        let presented = try NIOSSHPublicKey(openSSHPublicKey: plain)
        let pin = try XCTUnwrap(HostKeyRecorder.fingerprint(ofOpenSSHKey: cert))
        XCTAssertEqual(pin, sshHostKeyFingerprintSHA256(presented))
    }
}
