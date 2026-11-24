import Crypto
import Foundation
import XCTest
@testable import HerdrKit

/// approve-v1 against AccountService/test/vectors/approve-v1.json, the vector the account
/// service, HerdrUp Desktop and the web share.
final class ApproveV1Tests: XCTestCase {
    struct Vector: Decodable {
        let browserPriv, approverPriv, browserPub, approverPub: String
        let nonceB, nonceT, commit, code: String
        let seq: UInt64
        let envelopeJSON: String
        let sealed: String

        enum CodingKeys: String, CodingKey {
            case code, seq, sealed, commit
            case browserPriv = "browser_priv"
            case approverPriv = "approver_priv"
            case browserPub = "browser_pub"
            case approverPub = "approver_pub"
            case nonceB = "nonce_b"
            case nonceT = "nonce_t"
            case envelopeJSON = "envelope_json"
        }
    }

    static func vector() throws -> Vector {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AccountService/test/vectors/approve-v1.json")
        return try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
    }

    private func b64(_ text: String) throws -> Data { try XCTUnwrap(Base64URL.decode(text)) }

    private func key(_ text: String) throws -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: b64(text))
    }

    func testMatchesTheSharedVector() throws {
        let v = try Self.vector()
        let browser = try key(v.browserPriv), approver = try key(v.approverPriv)
        let B = try b64(v.browserPub), T = try b64(v.approverPub)
        XCTAssertEqual(browser.publicKey.rawRepresentation, B)
        XCTAssertEqual(approver.publicKey.rawRepresentation, T)

        let commit = try ApproveV1.commit(browserPub: B, nonceB: b64(v.nonceB))
        XCTAssertEqual(Base64URL.encode(commit), v.commit)
        XCTAssertNoThrow(try ApproveV1.open(browserPub: B, commit: b64(v.commit), nonceB: b64(v.nonceB)))
        XCTAssertEqual(try ApproveV1.code(browserPub: B, approverPub: T, nonceB: b64(v.nonceB), nonceT: b64(v.nonceT)), v.code)

        // The approver seals exactly what the other implementations seal, given the same IV.
        let iv = try XCTUnwrap(Base64URL.decode(v.sealed)).prefix(12)
        let sealed = try ApproveV1.seal(approver: approver, browserPub: B, seq: v.seq,
                                        plaintext: Data(v.envelopeJSON.utf8), iv: Data(iv))
        XCTAssertEqual(sealed, v.sealed)
        XCTAssertEqual(ApproveV1.sealedLength(v.envelopeJSON.utf8.count), v.sealed.count)

        // And the browser opens it, at that seq only.
        let plain = try ApproveV1.openEnvelope(browser: browser, approverPub: T, seq: v.seq, sealed: v.sealed)
        XCTAssertEqual(String(decoding: plain, as: UTF8.self), v.envelopeJSON)
        XCTAssertThrowsError(try ApproveV1.openEnvelope(browser: browser, approverPub: T, seq: v.seq + 1, sealed: v.sealed))
    }

    /// A compromised service swaps the browser key or the nonce the browser reveals: the
    /// approver refuses the reveal, and the codes differ.
    func testRefusesASwappedKeyOrNonce() throws {
        let v = try Self.vector()
        let B = try b64(v.browserPub), T = try b64(v.approverPub)
        let other = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let wrongNonce = Data(repeating: 0x12, count: 32)
        XCTAssertThrowsError(try ApproveV1.open(browserPub: other, commit: b64(v.commit), nonceB: b64(v.nonceB))) {
            XCTAssertEqual($0 as? ApproveV1.Failure, .tampered)
        }
        XCTAssertThrowsError(try ApproveV1.open(browserPub: B, commit: b64(v.commit), nonceB: wrongNonce)) {
            XCTAssertEqual($0 as? ApproveV1.Failure, .tampered)
        }
        XCTAssertNotEqual(try ApproveV1.code(browserPub: other, approverPub: T, nonceB: b64(v.nonceB), nonceT: b64(v.nonceT)), v.code)
        XCTAssertNotEqual(try ApproveV1.code(browserPub: B, approverPub: other, nonceB: b64(v.nonceB), nonceT: b64(v.nonceT)), v.code)
        XCTAssertThrowsError(try ApproveV1.code(browserPub: B.prefix(31), approverPub: T, nonceB: b64(v.nonceB), nonceT: b64(v.nonceT)))
    }

    /// Sealed to one browser by one approver: another browser key, another approver key or
    /// another seq can't open it.
    func testEnvelopeOpensOnlyForItsBrowserApproverAndSeq() throws {
        let browser = Curve25519.KeyAgreement.PrivateKey(), approver = Curve25519.KeyAgreement.PrivateKey()
        let plain = Data(#"{"v":1}"#.utf8)
        let sealed = try ApproveV1.seal(approver: approver, browserPub: browser.publicKey.rawRepresentation, seq: 3, plaintext: plain)
        XCTAssertFalse(sealed.contains("="))
        XCTAssertEqual(try ApproveV1.openEnvelope(browser: browser, approverPub: approver.publicKey.rawRepresentation, seq: 3, sealed: sealed), plain)
        XCTAssertThrowsError(try ApproveV1.openEnvelope(browser: Curve25519.KeyAgreement.PrivateKey(),
                                                        approverPub: approver.publicKey.rawRepresentation, seq: 3, sealed: sealed))
        XCTAssertThrowsError(try ApproveV1.openEnvelope(browser: browser,
                                                        approverPub: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                                        seq: 3, sealed: sealed))
        XCTAssertThrowsError(try ApproveV1.openEnvelope(browser: browser, approverPub: approver.publicKey.rawRepresentation,
                                                        seq: 3, sealed: sealed + "=="))
    }

    func testCodeMatchesOnlyTheFourDigits() {
        XCTAssertTrue(ApproveV1.codeMatches("0427", "0427"))
        XCTAssertFalse(ApproveV1.codeMatches("427", "0427"))
        XCTAssertFalse(ApproveV1.codeMatches("0428", "0427"))
        XCTAssertFalse(ApproveV1.codeMatches("04270", "0427"))
    }
}
