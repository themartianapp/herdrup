import XCTest
import Foundation
import Crypto
import Citadel
@testable import HerdrKit

/// The decisions that happen after a scan: what order, and which failures are refused.
///
/// These are exactly the things a device test would be bad at. On a phone, "it worked"
/// hides whether the pin was written before or after the remote machine was changed, and
/// whether an unpinned host was quietly saved anyway — both invisible until someone is
/// attacked. Here they are ordinary assertions.
final class PairingCoordinatorTests: XCTestCase {

    // MARK: - Doubles that RECORD ORDER

    private final class Recorder: @unchecked Sendable {
        var events: [String] = []
        var pinSucceeds = true
        var saveSucceeds = true
        var redeemError: Pairing.Error?
        var pinnedHost: String?
        var pinnedPort: UInt16?
        var pinnedFingerprint: String?
        var savedKeyPEM: String?
        var savedHost: String?
        var savedUser: String?
        var sentPublicKey: String?
        var sentDeviceLabel: String?
        var savedOnMainThread: Bool?
    }

    private struct FakeStore: PairingCoordinator.HostStore {
        let recorder: Recorder
        func addPairedHost(nickname: String, host: String, username: String,
                           privateKeyPEM: String) -> Bool {
            recorder.events.append("save")
            recorder.savedOnMainThread = Thread.isMainThread
            recorder.savedHost = host
            recorder.savedUser = username
            recorder.savedKeyPEM = privateKeyPEM
            return recorder.saveSucceeds
        }
    }

    private struct FakePinner: PairingCoordinator.HostKeyPinner {
        let recorder: Recorder
        func pin(host: String, port: UInt16, fingerprint: String) -> Bool {
            recorder.events.append("pin")
            recorder.pinnedHost = host
            recorder.pinnedPort = port
            recorder.pinnedFingerprint = fingerprint
            return recorder.pinSucceeds
        }
    }

    private func makeCoordinator(_ recorder: Recorder) -> PairingCoordinator {
        PairingCoordinator(
            store: FakeStore(recorder: recorder),
            pinner: FakePinner(recorder: recorder),
            redeem: { _, publicKey, label in
                recorder.events.append("redeem")
                recorder.sentPublicKey = publicKey
                recorder.sentDeviceLabel = label
                if let error = recorder.redeemError { throw error }
            })
    }

    /// `XCTAssertThrowsError` cannot take an async expression, and a bare do/catch that
    /// forgets its `XCTFail` passes when nothing throws — the failure mode this whole file
    /// exists to avoid. This fails loudly on success and returns the error for further
    /// assertions.
    @discardableResult
    private func assertThrows(
        _ expected: PairingCoordinator.Failure,
        file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Void
    ) async -> PairingCoordinator.Failure? {
        do {
            try await body()
            XCTFail("expected \(expected), but nothing was thrown", file: file, line: line)
            return nil
        } catch let failure as PairingCoordinator.Failure {
            XCTAssertEqual(failure, expected, file: file, line: line)
            return failure
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
            return nil
        }
    }

    private func payload(host: String = "100.64.1.2",
                         fp: String = PairingFixture.qrFingerprint) -> Pairing.Payload {
        Pairing.Payload(v: 1, host: host, port: 4021, user: "jerry", token: "tok", fp: fp)
    }

    // MARK: - Order

    /// PIN BEFORE REDEEM. If pinning fails after the key is already on the other machine,
    /// the user is left with an orphaned entry in their authorized_keys for a failure they
    /// did not cause and will not be told about.
    func testPinsBeforeTouchingTheOtherMachine() async throws {
        let recorder = Recorder()
        try await makeCoordinator(recorder).completePairing(payload: payload(), deviceLabel: "iPhone")
        XCTAssertEqual(recorder.events, ["pin", "redeem", "save"])
    }

    /// A version-2 (Deimos Forge) payload names SSH on another port: the key must be
    /// pinned at that port and the machine saved with it, or the first connection either
    /// dials 22 or looks up a pin that was never stored.
    func testAVersionTwoPayloadPinsAndSavesItsSSHPort() async throws {
        let recorder = Recorder()
        let forge = Pairing.Payload(v: 2, host: "100.106.218.88", port: 4021, user: "jerry",
                                    token: "tok", fp: PairingFixture.qrFingerprint, sshPort: 43341)
        try await makeCoordinator(recorder).completePairing(payload: forge, deviceLabel: "iPhone")
        XCTAssertEqual(recorder.pinnedHost, "100.106.218.88")
        XCTAssertEqual(recorder.pinnedPort, 43341)
        XCTAssertEqual(recorder.savedHost, "100.106.218.88:43341")
        XCTAssertEqual(HostEndpoint.parse(recorder.savedHost ?? ""),
                       HostEndpoint(host: "100.106.218.88", port: 43341),
                       "the saved destination must connect where the key was pinned")
    }

    // MARK: - Version 3, end to end over a real socket

    /// The real `Pairing.redeem`, so the proof check is exercised exactly as the app runs it.
    private func makeLiveCoordinator(_ recorder: Recorder) -> PairingCoordinator {
        PairingCoordinator(store: FakeStore(recorder: recorder), pinner: FakePinner(recorder: recorder))
    }

    /// A stub daemon reply over whatever key the coordinator generated and sent: a `pair.ok`
    /// with version `v` and the ok proof keyed by `token`, or no proof when `token` is nil.
    private func okReply(v: Int = 3, token: String? = V3Vector.token) -> (String) -> String? {
        { request in
            guard let object = try? JSONSerialization.jsonObject(with: Data(request.utf8))
                    as? [String: Any],
                  let key = object["public_key"] as? String
            else { return nil }
            guard let token else { return #"{"type":"pair.ok","v":\#(v)}"# }
            let proof = Base64URL.encode(Pairing.okProof(token: token, publicKeyLine: key))
            return #"{"type":"pair.ok","v":\#(v),"proof":"\#(proof)"}"#
        }
    }

    private func v3Payload(_ server: StubDaemon) -> Pairing.Payload {
        server.payload(v: 3, sshPort: 22220, token: V3Vector.token, fp: PairingFixture.qrFingerprint)
    }

    /// A Forge v3 code pairs when the machine proves itself, the token never crosses the
    /// wire, and the host is saved with the SSH port and the key that was actually sent.
    func testAVersionThreePairingWithTheMachinesProofSaves() async throws {
        let recorder = Recorder()
        let server = try StubDaemon(respond: okReply())
        defer { server.stop() }

        try await makeLiveCoordinator(recorder).completePairing(
            payload: v3Payload(server), deviceLabel: V3Vector.device)

        XCTAssertEqual(recorder.events, ["pin", "save"])
        XCTAssertEqual(recorder.pinnedPort, 22220)
        XCTAssertEqual(recorder.savedHost, "127.0.0.1:22220")

        let received = try XCTUnwrap(server.waitForRequest())
        XCTAssertFalse(received.contains(V3Vector.token), "the token must never be sent")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(received.utf8)) as? [String: Any])
        XCTAssertNil(object["token"], "a v3 request has no token key")
        XCTAssertEqual(object["v"] as? Int, 3)
        let sent = try XCTUnwrap(object["public_key"] as? String)
        XCTAssertEqual(object["proof"] as? String, Base64URL.encode(Pairing.requestProof(
            token: V3Vector.token, publicKeyLine: sent, deviceLabel: V3Vector.device)))
        let saved = try XCTUnwrap(recorder.savedKeyPEM)
        XCTAssertEqual(
            try PairingKeyRoundTrip.publicLine(fromPrivatePEM: saved, comment: V3Vector.device),
            sent, "the saved private key must match the key the machine proved it accepted")
    }

    /// A `pair.ok` that does not prove itself — wrong proof, no proof, or not version 3 —
    /// is a failure, and NOTHING is saved: it may be an on-path forgery.
    func testAnUnprovenVersionThreeOkSavesNothing() async throws {
        let cases: [(String, (String) -> String?)] = [
            ("wrong proof", okReply(token: "not-the-qr-token")),
            ("missing proof", okReply(token: nil)),
            ("v mismatch", okReply(v: 2)),
        ]
        for (name, respond) in cases {
            let recorder = Recorder()
            let server = try StubDaemon(respond: respond)
            defer { server.stop() }

            let failure = await assertThrows(.pairing(.unverifiedReply)) {
                try await makeLiveCoordinator(recorder).completePairing(
                    payload: v3Payload(server), deviceLabel: V3Vector.device)
            }
            XCTAssertEqual(recorder.events, ["pin"], "\(name): no save after an unproven ok")
            XCTAssertNil(recorder.savedKeyPEM, name)
            XCTAssertTrue(failure?.userFacingMessage.contains("herdr pair") == true, name)
        }
    }

    func testAFailedPinNeverReachesTheOtherMachine() async {
        let recorder = Recorder()
        recorder.pinSucceeds = false
        await assertThrows(.couldNotPinHostKey) {
            try await makeCoordinator(recorder).completePairing(payload: payload(), deviceLabel: "iPhone")
        }

        XCTAssertEqual(recorder.events, ["pin"], "nothing may run after a failed pin")
        XCTAssertNil(recorder.sentPublicKey, "no key may be sent when the pin failed")
    }

    // MARK: - The unpinnable case

    /// A machine that cannot identify itself must be REFUSED, not saved unpinned.
    ///
    /// This is the one that would otherwise pass silently: saving the host still "works",
    /// and the damage only shows up at first connect, which trusts whatever answers.
    func testAMachineWithNoHostKeyIsRefusedRatherThanSavedUnpinned() async {
        let recorder = Recorder()
        await assertThrows(.noHostKeyToPin) {
            try await makeCoordinator(recorder).completePairing(
                payload: payload(fp: ""), deviceLabel: "iPhone")
        }

        XCTAssertTrue(recorder.events.isEmpty, "nothing at all may happen without a pin target")
    }

    // MARK: - What gets pinned

    /// THE PIN MUST TARGET THE SSH PORT, NOT THE PAIRING PORT.
    ///
    /// The payload's `port` is the short-lived pairing listener; SSH is a different service
    /// on a different port. Pinning against 4021 would file the fingerprint under a key the
    /// SSH connection never looks up — the pin would silently miss and first contact would
    /// trust-on-first-use anyway, which is the exact hole the fingerprint exists to close.
    func testPinsAgainstTheSSHPortNotThePairingPort() async throws {
        let recorder = Recorder()
        try await makeCoordinator(recorder).completePairing(payload: payload(), deviceLabel: "iPhone")
        XCTAssertEqual(recorder.pinnedPort, 22, "4021 is the pairing listener, not sshd")
        XCTAssertEqual(recorder.pinnedHost, "100.64.1.2")
        XCTAssertEqual(recorder.pinnedFingerprint, PairingFixture.verifierFingerprint,
                       "the pin must be in the form the SSH verifier presents, or the first "
                       + "connection to this unchanged host is rejected")
    }

    /// An explicit ":port" in the host is an SSH port and must be honoured, and must not
    /// end up inside the pinned host string — the pin store keys on the bare host.
    func testAnExplicitSSHPortIsHonouredAndStrippedFromTheHost() async throws {
        let recorder = Recorder()
        try await makeCoordinator(recorder).completePairing(
            payload: payload(host: "100.64.1.2:2222"), deviceLabel: "iPhone")
        XCTAssertEqual(recorder.pinnedPort, 2222)
        XCTAssertEqual(recorder.pinnedHost, "100.64.1.2", "the port must not be in the host key")
    }

    // MARK: - What crosses the wire, and what does not

    /// The private half must reach the Keychain and NOTHING else.
    func testOnlyThePublicHalfIsSentAndThePrivateHalfIsSaved() async throws {
        let recorder = Recorder()
        try await makeCoordinator(recorder).completePairing(payload: payload(), deviceLabel: "Jerry's iPhone")

        let sent = try XCTUnwrap(recorder.sentPublicKey)
        let saved = try XCTUnwrap(recorder.savedKeyPEM)
        XCTAssertTrue(sent.hasPrefix("ssh-ed25519 "))
        XCTAssertFalse(sent.contains("PRIVATE KEY"), "a private key must never be sent")
        XCTAssertTrue(saved.contains("OPENSSH PRIVATE KEY"))
        XCTAssertEqual(recorder.sentDeviceLabel, "Jerry's iPhone")

        // The two halves must belong to the same keypair, or the host saves a key the
        // machine will not accept and the user gets a permission error at first connect.
        let parsed = try PairingKeyRoundTrip.publicLine(fromPrivatePEM: saved, comment: "Jerry's iPhone")
        XCTAssertEqual(parsed, sent, "the saved private key must match the key that was sent")
    }

    func testTheHostIsSavedWithTheScannedUserAndAddress() async throws {
        let recorder = Recorder()
        let name = try await makeCoordinator(recorder).completePairing(
            payload: payload(), deviceLabel: "iPhone")
        XCTAssertEqual(recorder.savedHost, "100.64.1.2")
        XCTAssertEqual(recorder.savedUser, "jerry")
        XCTAssertEqual(name, "jerry@100.64.1.2", "a default nickname a person can recognise")
    }

    // MARK: - Threads

    /// The save publishes UI state (`SavedHostsStore.hosts` is `@Published`), so it must run
    /// on the main thread however the caller got there (#664). A nonisolated test method is
    /// the caller that tells them apart: before the fix the save ran on its background thread.
    func testSavesOnTheMainThread() async throws {
        let recorder = Recorder()
        try await makeCoordinator(recorder).completePairing(payload: payload(), deviceLabel: "iPhone")
        XCTAssertEqual(recorder.savedOnMainThread, true, "the store write must run on the main thread")
    }

    // MARK: - Failures downstream of the remote change

    /// A refused redemption must not leave a saved host behind.
    func testARefusedRedemptionSavesNothing() async {
        let recorder = Recorder()
        recorder.redeemError = .refused("pairing refused")
        let failure = await assertThrows(.pairing(.refused("pairing refused"))) {
            try await makeCoordinator(recorder).completePairing(payload: payload(), deviceLabel: "iPhone")
        }
        // The message the user sees must come from the pairing error, which explains that
        // codes are single-use.
        XCTAssertTrue(failure?.userFacingMessage.contains("herdr pair") == true)
        XCTAssertEqual(recorder.events, ["pin", "redeem"], "no save after a refusal")
    }

    /// Failing to save AFTER the machine accepted the key is its own case: the remote side
    /// really did change, so the message has to tell the user to clean it up.
    func testAFailedSaveAfterARemoteChangeSaysSo() async {
        let recorder = Recorder()
        recorder.saveSucceeds = false
        let failure = await assertThrows(.pairedButCouldNotSave) {
            try await makeCoordinator(recorder).completePairing(payload: payload(), deviceLabel: "iPhone")
        }
        let message = failure?.userFacingMessage ?? ""
        XCTAssertTrue(message.contains("authorized_keys"),
                      "the user must be told there is something to remove: \(message)")
    }

    /// Every failure must give a next step, not just restate itself.
    func testEveryFailureHasAnActionableMessage() async {
        let failures: [PairingCoordinator.Failure] = [
            .noHostKeyToPin, .couldNotPinHostKey,
            .pairing(.notAPairingCode), .pairing(.unverifiedReply), .pairedButCouldNotSave,
        ]
        for failure in failures {
            let message = failure.userFacingMessage
            XCTAssertFalse(message.isEmpty)
            XCTAssertTrue(
                message.contains("herdr pair") || message.contains("Try again")
                    || message.contains("authorized_keys"),
                "\(failure) gives no next step: \(message)")
        }
    }
}

/// Re-derives the public line from a stored private key, so a test can prove the saved and
/// sent halves are the SAME keypair rather than merely both well-formed.
enum PairingKeyRoundTrip {
    static func publicLine(fromPrivatePEM pem: String, comment: String) throws -> String {
        let key = try Curve25519.Signing.PrivateKey(sshEd25519: Data(pem.utf8), decryptionKey: nil)
        return PairingKey.authorizedKeysLine(for: key.publicKey, comment: comment)
    }
}
