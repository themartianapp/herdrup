import Crypto
import XCTest
@testable import HerdrKit

/// The enrolment proof of possession against AccountService/test/vectors/enrol-v1.json, the
/// vector file the Worker's own tests and every other client use (DESIGN §3.2, §9 row 2).
final class DeviceEnrollerTests: XCTestCase {
    struct Vectors: Decodable {
        struct Case: Decodable {
            let name: String
            let device_private: String
            let device_pub: String
            let server_private: String
            let server_pub: String
            let salt: String
            let account_id: String
            let challenge_id: String
            let shared_secret: String
            let mk: String
            let message: String
            let mac: String
        }

        let info: String
        let message_prefix: String
        let cases: [Case]
        let low_order_device_pubs: [String]
    }

    private func vectors() throws -> Vectors {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AccountService/test/vectors/enrol-v1.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    private func bytes(_ b64: String) throws -> Data { try XCTUnwrap(Base64URL.decode(b64)) }

    override func setUp() {
        super.setUp()
        AccountServiceStub.reset()
    }

    override func tearDown() {
        AccountServiceStub.reset()
        super.tearDown()
    }

    func testConstantsMatchTheVectorFile() throws {
        let file = try vectors()
        XCTAssertEqual(DeviceEnroller.info, file.info)
        XCTAssertEqual(DeviceEnroller.messagePrefix, file.message_prefix)
        XCTAssertEqual(file.cases.count, 2)
    }

    /// The device's side: from its private key and the challenge, the exact `device_pub` and `mac`.
    func testDeviceSideReproducesEveryVector() throws {
        for vector in try vectors().cases {
            let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes(vector.device_private))
            let challenge = DeviceChallenge(challengeID: vector.challenge_id, serverPub: vector.server_pub,
                                            salt: vector.salt, accountID: vector.account_id, expiresIn: 60)

            let proof = try DeviceEnroller.proof(privateKey: key, challenge: challenge)

            XCTAssertEqual(proof.devicePub, vector.device_pub, vector.name)
            XCTAssertEqual(proof.mac, vector.mac, vector.name)
            // The intermediate values, so a mismatch says where it starts.
            let shared = try DeviceEnroller.sharedSecret(privateKey: key, publicKey: bytes(vector.server_pub))
            XCTAssertEqual(Base64URL.encode(shared), vector.shared_secret, vector.name)
            let mk = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: shared), salt: try bytes(vector.salt),
                                            info: Data(DeviceEnroller.info.utf8), outputByteCount: 32)
            XCTAssertEqual(mk.withUnsafeBytes { Base64URL.encode(Data($0)) }, vector.mk, vector.name)
            XCTAssertEqual(DeviceEnroller.messagePrefix + vector.account_id + "|" + vector.device_pub + "|" + vector.challenge_id,
                           vector.message, vector.name)
        }
    }

    /// The Worker's side, as devices.ts checks it: X25519(e, D), then the same MAC.
    func testServerSideReproducesEveryVector() throws {
        for vector in try vectors().cases {
            let serverKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes(vector.server_private))
            XCTAssertEqual(Base64URL.encode(serverKey.publicKey.rawRepresentation), vector.server_pub, vector.name)

            let shared = try DeviceEnroller.sharedSecret(privateKey: serverKey, publicKey: bytes(vector.device_pub))

            XCTAssertEqual(Base64URL.encode(shared), vector.shared_secret, vector.name)
            XCTAssertEqual(DeviceEnroller.mac(sharedSecret: shared, salt: try bytes(vector.salt),
                                              accountID: vector.account_id, devicePub: vector.device_pub,
                                              challengeID: vector.challenge_id),
                           vector.mac, vector.name)
        }
    }

    func testAnyOtherInputChangesTheMac() throws {
        let vector = try XCTUnwrap(vectors().cases.first)
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes(vector.device_private))
        func mac(account: String = vector.account_id, challenge: String = vector.challenge_id,
                 salt: String = vector.salt) throws -> String {
            try DeviceEnroller.proof(privateKey: key, challenge: DeviceChallenge(
                challengeID: challenge, serverPub: vector.server_pub, salt: salt, accountID: account, expiresIn: 60)).mac
        }
        XCTAssertEqual(try mac(), vector.mac)
        XCTAssertNotEqual(try mac(account: "CCCCCCCCCCCCCCCCCCCCCC"), vector.mac)
        XCTAssertNotEqual(try mac(challenge: "CCCCCCCCCCCCCCCCCCCCCC"), vector.mac)
        XCTAssertNotEqual(try mac(salt: Base64URL.encode(Data(repeating: 0x22, count: 32))), vector.mac)
    }

    func testLowOrderPointsAreRefusedOnBothSides() throws {
        let file = try vectors()
        XCTAssertEqual(file.low_order_device_pubs.count, 7)
        let key = Curve25519.KeyAgreement.PrivateKey()
        for point in file.low_order_device_pubs {
            // As a server key in a challenge: the device refuses to prove anything with it.
            let challenge = DeviceChallenge(challengeID: "BBBBBBBBBBBBBBBBBBBBBB", serverPub: point,
                                            salt: file.cases[0].salt, accountID: "AAAAAAAAAAAAAAAAAAAAAA", expiresIn: 60)
            XCTAssertThrowsError(try DeviceEnroller.proof(privateKey: key, challenge: challenge), point) { error in
                XCTAssertEqual(error as? DeviceEnroller.Failure, .invalidServerKey)
            }
            // As a device key at the server: no shared secret, so no MAC can match.
            XCTAssertThrowsError(try DeviceEnroller.sharedSecret(privateKey: key, publicKey: bytes(point)), point)
        }
    }

    func testMalformedChallengeIsRefused() {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let bad = DeviceChallenge(challengeID: "BBBBBBBBBBBBBBBBBBBBBB", serverPub: "short", salt: "ERER",
                                  accountID: "AAAAAAAAAAAAAAAAAAAAAA", expiresIn: 60)
        XCTAssertThrowsError(try DeviceEnroller.proof(privateKey: key, challenge: bad)) { error in
            XCTAssertEqual(error as? DeviceEnroller.Failure, .malformedChallenge)
        }
    }

    // MARK: Enrolment against a stub that checks the proof like the Worker

    func testEnrolProvesTheGuestKeyAndKeepsIt() async throws {
        let authority = StubAuthority()
        let serverKey = Curve25519.KeyAgreement.PrivateKey()
        let salt = Data((0..<32).map { UInt8($0) })
        AccountServiceStub.handler = { request in
            if let refused = authority.handle(request) { return refused }
            switch request.path {
            case "/v1/devices/challenge":
                return .json(200, ["challenge_id": "ChallengeAAAAAAAAAAAAA",
                                   "server_pub": Base64URL.encode(serverKey.publicKey.rawRepresentation),
                                   "salt": Base64URL.encode(salt), "account_id": "AccountAAAAAAAAAAAAAAA", "expires_in": 60])
            case "/v1/devices":
                let body = request.json
                guard let devicePub = body["device_pub"] as? String, let mac = body["mac"] as? String,
                      let pub = Base64URL.decode(devicePub),
                      let shared = try? DeviceEnroller.sharedSecret(privateKey: serverKey, publicKey: pub),
                      DeviceEnroller.mac(sharedSecret: shared, salt: salt, accountID: "AccountAAAAAAAAAAAAAAA",
                                         devicePub: devicePub, challengeID: "ChallengeAAAAAAAAAAAAA") == mac
                else { return .error(400, "proof_invalid") }
                let device: [String: Any] = ["id": "DeviceAAAAAAAAAAAAAAAA", "name": body["name"] as? String ?? "",
                                             "platform": body["platform"] as? String ?? "", "device_pub": devicePub,
                                             "created_ms": 1, "current": true]
                return .json(201, ["device": device])
            default:
                return .error(404, "not_found")
            }
        }
        let keyStore = InMemoryGuestKeyStore()
        let enroller = DeviceEnroller(session: makeStubSession(), keyStore: keyStore)

        let device = try await enroller.enrol(name: "Jerry's iPhone", platform: .ios)

        let stored = try XCTUnwrap(try keyStore.loadGuestKey(), "the guest key is created and stored")
        let identity = try GuestIdentity.loadOrCreate(store: keyStore)
        XCTAssertEqual(identity.privateKey.rawRepresentation, stored)
        XCTAssertEqual(device.devicePub, Base64URL.encode(identity.publicKey))
        XCTAssertTrue(device.current)
        let enrol = try XCTUnwrap(AccountServiceStub.requests(to: "/v1/devices").first)
        XCTAssertEqual(Set(enrol.json.keys), ["challenge_id", "device_pub", "mac", "name", "platform"])
        XCTAssertEqual(enrol.json["platform"] as? String, "ios")
        XCTAssertNil(enrol.json["device_private"], "the private key never leaves")

        // Enrolling again uses the same key: a device is never replaced.
        _ = try await enroller.enrol(name: "Jerry's iPhone", platform: .ios)
        XCTAssertEqual(AccountServiceStub.requests(to: "/v1/devices").map { $0.json["device_pub"] as? String },
                       [device.devicePub, device.devicePub])
    }

    func testDeviceInAnotherAccountSurfacesItsCode() async throws {
        let authority = StubAuthority()
        AccountServiceStub.handler = { request in
            if let refused = authority.handle(request) { return refused }
            if request.path == "/v1/devices/challenge" {
                return .json(200, ["challenge_id": "ChallengeAAAAAAAAAAAAA",
                                   "server_pub": Base64URL.encode(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation),
                                   "salt": Base64URL.encode(Data(repeating: 1, count: 32)),
                                   "account_id": "AccountAAAAAAAAAAAAAAA", "expires_in": 60])
            }
            return .error(409, "device_in_other_account")
        }
        let enroller = DeviceEnroller(session: makeStubSession(), keyStore: InMemoryGuestKeyStore())
        do {
            _ = try await enroller.enrol(name: "iPad", platform: .ipados)
            XCTFail("expected the refusal")
        } catch {
            XCTAssertEqual(error as? AccountError, .refused(status: 409, code: "device_in_other_account"))
        }
    }
}
