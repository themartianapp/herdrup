import XCTest
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import NIOSSH
@testable import HerdrKit

/// The phone's half of QR pairing, driven over REAL loopback sockets.
///
/// A mocked transport would prove only that the mock matches my belief about the protocol.
/// The daemon's half is already tested in Rust over a real socket; testing this half the
/// same way means the two suites meet at the wire format instead of at an assumption.
final class PairingTests: XCTestCase {

    // MARK: - Reading a scanned code

    func testParsesAValidPairingCode() throws {
        let payload = try Pairing.parse(qrText: sampleJSON())
        XCTAssertEqual(payload.host, "100.64.1.2")
        XCTAssertEqual(payload.port, 4021)
        XCTAssertEqual(payload.user, "root")
        XCTAssertEqual(payload.hostKeyFingerprint, PairingFixture.verifierFingerprint)
    }

    /// A camera hands us whatever QR is in frame. Every one of these must fail as "not a
    /// pairing code" rather than as a socket error minutes later.
    func testRejectsCodesThatAreNotPairingPayloads() {
        for junk in [
            "",
            "hello",
            "https://example.com",
            "WIFI:S:home;T:WPA;P:hunter2;;",
            "{}",
            #"{"v":1,"host":"","port":4021,"user":"root","token":"t","fp":""}"#,
            #"{"v":1,"host":"h","port":4021,"user":"","token":"t","fp":""}"#,
            #"{"v":1,"host":"h","port":4021,"user":"root","token":"","fp":""}"#,
            #"{"v":1,"host":"h","port":0,"user":"root","token":"t","fp":""}"#,
            #"{"v":1,"host":"h","port":70000,"user":"root","token":"t","fp":""}"#,
            // A fingerprint that is present must be the 32-byte SHA256 digest ssh-keygen prints.
            sampleJSON(fp: "SHA256:abc"),
            sampleJSON(fp: PairingFixture.verifierFingerprint),
            sampleJSON(fp: "MD5:" + PairingFixture.qrFingerprint.dropFirst("SHA256:".count)),
            sampleJSON(fp: PairingFixture.qrFingerprint + "="),
            sampleJSON(fp: String(PairingFixture.qrFingerprint.dropLast())),
        ] {
            XCTAssertThrowsError(try Pairing.parse(qrText: junk), "accepted junk: \(junk)") { error in
                XCTAssertEqual(error as? Pairing.Error, .notAPairingCode, "for \(junk)")
            }
        }
    }

    /// A version mismatch is a DIFFERENT failure from a bad code, because the remedy
    /// differs: update the app, versus scan a real code.
    func testAFutureVersionIsReportedAsAVersionProblem() {
        let future = sampleJSON(v: 4, sshPort: 2222)
        XCTAssertThrowsError(try Pairing.parse(qrText: future)) { error in
            XCTAssertEqual(error as? Pairing.Error, .unsupportedVersion(4))
        }
    }

    /// Versions 2 and 3 (Deimos Forge) carry the SSH port; version 1 never does. A
    /// version-2 or -3 code without a usable port, or a version-1 code with one, is not a
    /// real code.
    func testVersionsTwoAndThreeCarryTheSSHPortAndVersionOneDoesNot() throws {
        XCTAssertEqual(try Pairing.parse(qrText: sampleJSON(v: 2, sshPort: 43341)).sshPort, 43341)
        let v3 = try Pairing.parse(qrText: sampleJSON(v: 3, sshPort: 22220))
        XCTAssertEqual(v3.v, 3)
        XCTAssertEqual(v3.sshPort, 22220)
        XCTAssertNil(try Pairing.parse(qrText: sampleJSON()).sshPort)
        for bad in [sampleJSON(v: 2), sampleJSON(v: 2, sshPort: 0), sampleJSON(v: 2, sshPort: 65536),
                    sampleJSON(v: 3), sampleJSON(v: 3, sshPort: 0), sampleJSON(v: 3, sshPort: 65536),
                    sampleJSON(v: 1, sshPort: 2222)] {
            XCTAssertThrowsError(try Pairing.parse(qrText: bad), "accepted: \(bad)") { error in
                XCTAssertEqual(error as? Pairing.Error, .notAPairingCode)
            }
        }
    }

    /// An absent fingerprint must read as "unknown", never as a pinnable empty string.
    func testAnEmptyFingerprintIsNilNotEmpty() throws {
        let payload = try Pairing.parse(qrText: sampleJSON(fp: ""))
        XCTAssertNil(payload.hostKeyFingerprint,
                     "an empty fp must not flow into a pin call as a valid fingerprint")
        XCTAssertNil(try Pairing.parse(qrText: sampleJSON(fp: "   ")).hostKeyFingerprint)
    }

    /// THE QR AND THE SSH VERIFIER MUST NAME A HOST KEY THE SAME WAY.
    ///
    /// The daemon prints `ssh-keygen -lf` output (`SHA256:` + base64); the verifier presents
    /// lowercase hex. Both are the SHA-256 of the same wire-form key. If the pinned value is
    /// in one spelling and the presented value in the other, the exact comparison rejects
    /// the first connection to a freshly paired, unchanged host.
    func testTheScannedFingerprintMatchesWhatTheSSHVerifierPresents() throws {
        let key = try NIOSSHPublicKey(openSSHPublicKey: PairingFixture.publicKeyLine)
        XCTAssertEqual(sshHostKeyFingerprintSHA256(key), PairingFixture.verifierFingerprint,
                       "the fixture's digest must be what the verifier computes for its key")
        let payload = try Pairing.parse(qrText: sampleJSON(fp: PairingFixture.qrFingerprint))
        XCTAssertEqual(payload.hostKeyFingerprint, sshHostKeyFingerprintSHA256(key))
    }

    // MARK: - The wire contract with the Rust daemon

    /// THE FIELD NAMES ARE A CROSS-LANGUAGE CONTRACT.
    ///
    /// `PairRedeem` in src/pairing.rs deserialises `type`, `token`, `public_key`, `device`.
    /// Swift's default encoding would emit `kind` and `publicKey`, which the daemon would
    /// reject as unparseable — and the failure would appear as an opaque refusal on a
    /// user's phone, with the real reason only in a terminal they are not looking at.
    func testTheRedeemLineMatchesTheDaemonsFieldNames() throws {
        let line = try Pairing.redeemLine(
            token: "tok", publicKeyLine: "ssh-ed25519 AAAA test", deviceLabel: "iPhone")

        XCTAssertEqual(line.last, 0x0A, "the daemon reads exactly one line")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["type", "token", "public_key", "device"])
        XCTAssertEqual(object["type"] as? String, "pair.redeem")
        XCTAssertEqual(object["token"] as? String, "tok")
        XCTAssertEqual(object["public_key"] as? String, "ssh-ed25519 AAAA test")
        XCTAssertEqual(object["device"] as? String, "iPhone")
    }

    /// The one thing that must never appear on this wire.
    func testTheRedeemLineCarriesOnlyThePublicHalf() throws {
        let key = PairingKey(comment: "iPhone")
        let line = try Pairing.redeemLine(
            token: "tok", publicKeyLine: key.authorizedKeysLine, deviceLabel: "iPhone")
        let text = String(decoding: line, as: UTF8.self)

        XCTAssertFalse(text.contains("PRIVATE KEY"))
        XCTAssertFalse(text.contains(key.privateKeyPEM))

        // Compared after DECODING, not by substring. JSONEncoder escapes "/" as "\\/",
        // and ed25519 base64 contains "/" about half the time — so a substring check here
        // fails on a correct line, roughly one run in two. (serde_json unescapes it on the
        // daemon's side, which the live cross-language run confirms.)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(object["public_key"] as? String, key.authorizedKeysLine)
    }

    // MARK: - Redeeming over a real socket

    func testASuccessfulRedemptionOverARealSocket() throws {
        let server = try StubDaemon(reply: #"{"type":"pair.ok"}"#)
        defer { server.stop() }

        let key = PairingKey(comment: "iPhone")
        XCTAssertNoThrow(try Pairing.redeem(
            payload: server.payload(),
            publicKeyLine: key.authorizedKeysLine,
            deviceLabel: "Jerry's iPhone",
            timeout: 5))

        // The daemon must have received exactly what the contract test pins.
        let received = try XCTUnwrap(server.waitForRequest())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(received.utf8)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "pair.redeem")
        XCTAssertEqual(object["device"] as? String, "Jerry's iPhone")
        XCTAssertEqual(object["public_key"] as? String, key.authorizedKeysLine)
    }

    /// The daemon's refusal is opaque by design; the app must surface its OWN sentence.
    func testARefusalIsReportedWithAnActionableMessage() throws {
        let server = try StubDaemon(reply: #"{"type":"pair.error","message":"pairing refused"}"#)
        defer { server.stop() }

        XCTAssertThrowsError(try Pairing.redeem(
            payload: server.payload(), publicKeyLine: "ssh-ed25519 AAAA x",
            deviceLabel: "iPhone", timeout: 5)
        ) { error in
            XCTAssertEqual(error as? Pairing.Error, .refused("pairing refused"))
            // A person needs to know codes are single-use and expire; "pairing refused"
            // does not say that.
            XCTAssertTrue(
                (error as? Pairing.Error)?.userFacingMessage.contains("herdr pair") == true)
        }
    }

    func testAClosedConnectionIsNotMistakenForSuccess() throws {
        let server = try StubDaemon(reply: nil)  // accept, then close
        defer { server.stop() }

        XCTAssertThrowsError(try Pairing.redeem(
            payload: server.payload(), publicKeyLine: "ssh-ed25519 AAAA x",
            deviceLabel: "iPhone", timeout: 5)
        ) { error in
            guard case .badResponse = error as? Pairing.Error else {
                return XCTFail("expected badResponse, got \(error)")
            }
        }
    }

    func testGarbageFromTheServerIsNotMistakenForSuccess() throws {
        let server = try StubDaemon(reply: "<html>login page</html>")
        defer { server.stop() }

        XCTAssertThrowsError(try Pairing.redeem(
            payload: server.payload(), publicKeyLine: "ssh-ed25519 AAAA x",
            deviceLabel: "iPhone", timeout: 5)
        ) { error in
            guard case .badResponse = error as? Pairing.Error else {
                return XCTFail("expected badResponse, got \(error)")
            }
        }
    }

    func testAnUnreachableMachineFailsQuicklyAndSaysSo() throws {
        // A stopped stub must refuse connections. The pause lets the stub's worker reach
        // accept() first: the schedule under which a close() alone left the port
        // listening on Linux (CI 39225257578), so this case always covers it.
        let server = try StubDaemon(reply: nil)
        let payload = server.payload()
        Thread.sleep(forTimeInterval: 0.2)
        server.stop()

        XCTAssertThrowsError(try Pairing.redeem(
            payload: payload, publicKeyLine: "ssh-ed25519 AAAA x",
            deviceLabel: "iPhone", timeout: 2)
        ) { error in
            guard case .unreachable = error as? Pairing.Error else {
                return XCTFail("expected unreachable, got \(error)")
            }
        }
    }

    /// A hostname in a scanned QR is a way to point the phone at a machine the daemon did
    /// not name. `herdr pair` only ever emits a literal tailnet address.
    func testAHostnameInTheCodeIsRefusedRatherThanResolved() {
        let payload = Pairing.Payload(
            v: 1, host: "example.com", port: 4021, user: "root", token: "t", fp: "")
        XCTAssertThrowsError(try Pairing.redeem(
            payload: payload, publicKeyLine: "ssh-ed25519 AAAA x", deviceLabel: "x", timeout: 2)
        ) { error in
            guard case .unreachable(let why) = error as? Pairing.Error else {
                return XCTFail("expected unreachable, got \(error)")
            }
            XCTAssertTrue(why.contains("IPv4"), "should name the reason, got \(why)")
        }
    }

    // MARK: - Version 3: proofs instead of the token

    /// The known-answer vectors from deimos-forge `docs/pairing-v3.md`. The server computes
    /// the same values from the same inputs; a mismatch here is a pairing that always fails.
    func testV3ProofsMatchTheSpecVectors() throws {
        // The label's apostrophe is U+2019; an editor "fixing" it would change every proof.
        XCTAssertEqual(Array(V3Vector.device.utf8),
                       [0x4a, 0x65, 0x72, 0x72, 0x79, 0xe2, 0x80, 0x99, 0x73, 0x20, 0x69, 0x50,
                        0x68, 0x6f, 0x6e, 0x65])

        let request = Pairing.requestProof(
            token: V3Vector.token, publicKeyLine: V3Vector.publicKey, deviceLabel: V3Vector.device)
        XCTAssertEqual(request, try XCTUnwrap(Base64URL.decode(V3Vector.requestProof)))
        XCTAssertEqual(Base64URL.encode(request), V3Vector.requestProof)

        let ok = Pairing.okProof(token: V3Vector.token, publicKeyLine: V3Vector.publicKey)
        XCTAssertEqual(ok, try XCTUnwrap(Base64URL.decode(V3Vector.okProof)))
        XCTAssertTrue(Pairing.okReplyIsGenuine(
            ["type": "pair.ok", "v": 3, "proof": V3Vector.okProof],
            token: V3Vector.token, publicKeyLine: V3Vector.publicKey))
    }

    /// THE TOKEN MUST NOT BE ON THIS WIRE. The server refuses a v3 request with a `token`
    /// field, and an on-path reader who saw it could redeem the code with its own key.
    func testTheV3RedeemLineCarriesAProofAndNoToken() throws {
        let line = try Pairing.redeemLineV3(
            token: V3Vector.token, publicKeyLine: V3Vector.publicKey, deviceLabel: V3Vector.device)
        let text = String(decoding: line, as: UTF8.self)

        XCTAssertEqual(line.last, 0x0A, "the daemon reads exactly one line")
        XCTAssertFalse(text.contains(V3Vector.token))
        XCTAssertTrue(text.contains(#""v":3"#), "v must be the JSON integer 3: \(text)")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["type", "v", "public_key", "device", "proof"])
        XCTAssertEqual(object["type"] as? String, "pair.redeem")
        XCTAssertEqual(object["public_key"] as? String, V3Vector.publicKey)
        XCTAssertEqual(object["device"] as? String, V3Vector.device)
        XCTAssertEqual(object["proof"] as? String, V3Vector.requestProof)
    }

    func testAV3RedemptionWithTheMachinesProofSucceedsOverARealSocket() throws {
        let server = try StubDaemon(
            reply: #"{"type":"pair.ok","v":3,"proof":"\#(V3Vector.okProof)"}"#)
        defer { server.stop() }

        XCTAssertNoThrow(try Pairing.redeem(
            payload: server.payload(v: 3, sshPort: 22220, token: V3Vector.token),
            publicKeyLine: V3Vector.publicKey,
            deviceLabel: V3Vector.device,
            timeout: 5))

        let received = try XCTUnwrap(server.waitForRequest())
        XCTAssertFalse(received.contains(V3Vector.token))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(received.utf8)) as? [String: Any])
        XCTAssertNil(object["token"], "a v3 request must not carry the token")
        XCTAssertEqual(object["v"] as? Int, 3)
        XCTAssertEqual(object["proof"] as? String, V3Vector.requestProof)
    }

    /// A v3 `pair.ok` is success ONLY with the machine's proof over this key. Over the
    /// internet an unproven "ok" could come from anyone on the path.
    func testAV3OkWithoutTheMachinesProofIsAFailure() throws {
        let otherToken = Base64URL.encode(
            Pairing.okProof(token: "some-other-token", publicKeyLine: V3Vector.publicKey))
        let otherKey = Base64URL.encode(
            Pairing.okProof(token: V3Vector.token, publicKeyLine: "ssh-ed25519 AAAA attacker"))
        let replies = [
            #"{"type":"pair.ok","v":3,"proof":"\#(otherToken)"}"#,          // wrong token
            #"{"type":"pair.ok","v":3,"proof":"\#(otherKey)"}"#,            // substituted key
            #"{"type":"pair.ok","v":3,"proof":"\#(V3Vector.requestProof)"}"#,  // our proof echoed
            #"{"type":"pair.ok","v":3}"#,                                   // missing proof
            #"{"type":"pair.ok","v":3,"proof":null}"#,                      // null proof
            #"{"type":"pair.ok","v":3,"proof":"\#(V3Vector.okProof)="}"#,   // padded
            #"{"type":"pair.ok","v":3,"proof":"not a proof!"}"#,            // malformed
            #"{"type":"pair.ok"}"#,                                         // a v2 success
            #"{"type":"pair.ok","v":2,"proof":"\#(V3Vector.okProof)"}"#,    // v mismatch
            #"{"type":"pair.ok","proof":"\#(V3Vector.okProof)"}"#,          // v missing
            #"{"type":"pair.ok","v":"3","proof":"\#(V3Vector.okProof)"}"#,  // v not an integer
        ]
        for reply in replies {
            let server = try StubDaemon(reply: reply)
            defer { server.stop() }

            XCTAssertThrowsError(try Pairing.redeem(
                payload: server.payload(v: 3, sshPort: 22220, token: V3Vector.token),
                publicKeyLine: V3Vector.publicKey, deviceLabel: V3Vector.device, timeout: 5),
                "accepted: \(reply)"
            ) { error in
                XCTAssertEqual(error as? Pairing.Error, .unverifiedReply, "for \(reply)")
            }
        }
    }

    /// Version 3 changes nothing for version 2: the token is still sent, there is no proof,
    /// and a bare `pair.ok` is success.
    func testAV2RedemptionStillSendsTheTokenAndAcceptsAPlainOk() throws {
        let server = try StubDaemon(reply: #"{"type":"pair.ok"}"#)
        defer { server.stop() }

        XCTAssertNoThrow(try Pairing.redeem(
            payload: server.payload(v: 2, sshPort: 43341), publicKeyLine: "ssh-ed25519 AAAA x",
            deviceLabel: "iPhone", timeout: 5))

        let received = try XCTUnwrap(server.waitForRequest())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(received.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["type", "token", "public_key", "device"])
        XCTAssertEqual(object["token"] as? String, "test-token")
    }

    /// Every error must produce a sentence that tells a person what to DO. An error whose
    /// message only restates the failure sends them back to the screen that blocked them.
    func testEveryErrorHasAnActionableMessage() {
        let errors: [Pairing.Error] = [
            .notAPairingCode, .unsupportedVersion(2), .unreachable("x"),
            .refused("pairing refused"), .badResponse("x"), .unverifiedReply,
        ]
        for error in errors {
            let message = error.userFacingMessage
            XCTAssertFalse(message.isEmpty)
            XCTAssertTrue(
                message.contains("herdr pair") || message.contains("Update the app"),
                "\(error) gives no next step: \(message)")
        }
    }

    // MARK: - Helpers

    private func sampleJSON(v: Int = 1, fp: String = PairingFixture.qrFingerprint,
                            sshPort: Int? = nil) -> String {
        let payload = Pairing.Payload(
            v: v, host: "100.64.1.2", port: 4021, user: "root", token: "tok", fp: fp,
            sshPort: sshPort)
        return String(decoding: try! JSONEncoder().encode(payload), as: UTF8.self)
    }
}

/// One real host key and its two spellings. `publicKeyLine` and `qrFingerprint` came
/// from `ssh-keygen -t ed25519` and `ssh-keygen -lf` on that key; `verifierFingerprint` is
/// the same 32 bytes as hex, which the agreement test checks against the SSH verifier.
enum PairingFixture {
    static let publicKeyLine =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOghQ4P9xzhQk7cVQkuP07258+uGtw6lKieEGilwdrEZ fixture"
    static let qrFingerprint = "SHA256:Ngt93tunTdupZrmZMz3HbnXnwF/wXCHFPz/+zkz9dr4"
    static let verifierFingerprint =
        "360b7ddedba74ddba966b999333dc76e75e7c05ff05c21c53f3ffece4cfd76be"
}

/// The pairing-v3 test vectors from deimos-forge `docs/pairing-v3.md`, verbatim. The token is
/// base64url of bytes 0x00...0x1f, but the proofs key on its UTF-8 text, not those bytes.
enum V3Vector {
    static let token = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
    static let publicKey =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBw"
    static let device = "Jerry\u{2019}s iPhone"
    static let requestProof = "PuR15vzOIbxGh1CUYsPhARz4Ng8mthBo0_l84U3votU"
    static let okProof = "tovCz8GMEp1nj2sCCdjMW0Q7VaNUQ7jhPXamxCMvcM8"
}

/// A minimal stand-in for `serve_one_pairing`: accept one connection, read one line, send
/// the reply computed from that line (or none), close.
///
/// This is a stand-in for the DAEMON, not for the code under test — the client's socket
/// path, encoding and parsing are all real. Internal, not private, so the coordinator tests
/// can run a version-3 pairing end to end against it.
final class StubDaemon {
    private let listenFD: Int32
    let port: Int
    private let received: Box
    private let lock: NSLock
    private let arrived: DispatchSemaphore
    private var stopped = false

    convenience init(reply: String?) throws {
        try self.init(respond: { _ in reply })
    }

    /// - Parameter respond: given the request line (without its newline), the reply to
    ///   send, or nil to close without replying.
    init(respond: @escaping (String) -> String?) throws {
        // Everything the worker thread touches is built as a LOCAL first. Capturing a
        // stored property in a closure's capture list captures `self`, which the compiler
        // rejects during init — and the fix is not `[weak self]`, it is not needing self.
        let fd = socket(AF_INET, sockStream, 0)
        guard fd >= 0 else { throw TestError.socket }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // let the OS choose a free port
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                platformBind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            platformClose(fd)
            throw TestError.socket
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { platformClose(fd); throw TestError.socket }

        let box = Box()
        let lock = NSLock()
        let arrived = DispatchSemaphore(value: 0)

        self.listenFD = fd
        self.port = Int(UInt16(bigEndian: actual.sin_port))
        self.received = box
        self.lock = lock
        self.arrived = arrived

        let thread = Thread {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var line = [UInt8]()
            var byte: UInt8 = 0
            while line.count < 16 * 1024 {
                let n = recv(client, &byte, 1, 0)
                if n != 1 || byte == 0x0A { break }
                line.append(byte)
            }
            let request = String(decoding: line, as: UTF8.self)
            lock.lock()
            box.value = request
            lock.unlock()
            arrived.signal()
            if let reply = respond(request) {
                let out = reply + "\n"
                _ = out.withCString { send(client, $0, strlen($0), 0) }
            }
            platformClose(client)
        }
        thread.start()
    }

    func payload(v: Int = 1, sshPort: Int? = nil, token: String = "test-token",
                 fp: String = "SHA256:stub") -> Pairing.Payload {
        Pairing.Payload(
            v: v, host: "127.0.0.1", port: port, user: "tester",
            token: token, fp: fp, sshPort: sshPort)
    }

    func waitForRequest(timeout: TimeInterval = 5) -> String? {
        guard arrived.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return received.value
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        // shutdown() first: on Linux, close() alone does not wake the worker blocked in
        // accept(), and the socket keeps listening, so a "refused" connect is accepted
        // and then dropped.
        _ = shutdown(listenFD, Int32(SHUT_RDWR))
        platformClose(listenFD)
    }

    enum TestError: Swift.Error { case socket }

    /// A shared mutable String the worker thread can fill in.
    ///
    /// Not `NSMutableString`: swift-corelibs-foundation has no no-argument initialiser for
    /// it, so the same line compiles on Darwin and fails on Linux.
    final class Box: @unchecked Sendable { var value = "" }
}
