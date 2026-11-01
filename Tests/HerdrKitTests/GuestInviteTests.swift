import Crypto
import Foundation
import XCTest
@testable import HerdrKit

final class GuestInviteTests: XCTestCase {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func fields(overriding changes: [String: Any] = [:]) -> [String: Any] {
        var fields: [String: Any] = [
            "v": 1,
            "relay": "https://guest.herdrup.themartian.app",
            "host_id": Base64URL.encode(Data(repeating: 0x11, count: 16)),
            "host_pub": Base64URL.encode(Data(repeating: 0x22, count: 32)),
            "invite_id": Base64URL.encode(Data(repeating: 0x33, count: 16)),
            "secret": Base64URL.encode(Data(repeating: 0x44, count: 32)),
            "machine_label": "Jerry's Mac Studio",
            "owner_name": "Jerry",
            "agent_name": "llm-opt",
            "guest_name": "plotarmordev",
            "expires_unix": Int(now.timeIntervalSince1970) + 86_400,
        ]
        for (key, value) in changes { fields[key] = value }
        return fields
    }

    static func payload(_ fields: [String: Any]) -> String {
        Base64URL.encode(try! JSONSerialization.data(withJSONObject: fields))
    }

    func testAllLinkFormsParseAndRoundTrip() throws {
        let payload = Self.payload(Self.fields())
        let app = try GuestInvite.parse("herdrup://guest-invite#\(payload)", now: Self.now)
        let path = try GuestInvite.parse("https://guest.herdrup.themartian.app/i/\(payload)", now: Self.now)
        let fragment = try GuestInvite.parse("https://guest.herdrup.themartian.app/i#\(payload)", now: Self.now)
        XCTAssertEqual(app, path)
        XCTAssertEqual(app, fragment)
        XCTAssertEqual(app.guestName, "plotarmordev")
        XCTAssertEqual(app.machineLabel, "Jerry's Mac Studio")
        XCTAssertEqual(app.hostPublicKey, Data(repeating: 0x22, count: 32))
        XCTAssertEqual(app.expires, Self.now.addingTimeInterval(86_400))

        XCTAssertEqual(try GuestInvite.parse(app.appLink.absoluteString, now: Self.now), app)
        XCTAssertEqual(try GuestInvite.parse(app.webLink.absoluteString, now: Self.now), app)
        XCTAssertEqual(app.webLink.absoluteString, "https://guest.herdrup.themartian.app/i/\(app.payload)")
    }

    /// A relay mounted below the root serves its links below that path, and only there.
    func testWebLinkOnARelayWithAPath() throws {
        let payload = Self.payload(Self.fields(overriding: ["relay": "https://example.org/herdr/"]))
        for link in ["https://example.org/herdr/i/\(payload)", "https://example.org/herdr/i#\(payload)",
                     "https://EXAMPLE.org/herdr/i/\(payload)"] {
            XCTAssertEqual(try GuestInvite.parse(link, now: Self.now).relay.absoluteString,
                           "https://example.org/herdr/", link)
        }
        for link in ["https://example.org/i/\(payload)", "https://example.org/other/i/\(payload)",
                     "https://example.org/herdr/x/i/\(payload)"] {
            XCTAssertThrowsError(try GuestInvite.parse(link, now: Self.now), link) {
                XCTAssertEqual($0 as? GuestInvite.Failure, .notAnInvite, link)
            }
        }
    }

    /// A web link is only an invite on its own relay: a valid payload lifted onto another
    /// host, path or port, or with anything around `/i/<payload>`, is rejected.
    func testRejectsWebLinksOffTheExactRelayPath() {
        let payload = Self.payload(Self.fields())
        let links = [
            "https://evil.example/i/\(payload)",
            "https://evil.example/i#\(payload)",
            "https://guest.herdrup.themartian.app.evil.example/i/\(payload)",
            "https://guest.herdrup.themartian.app:8443/i/\(payload)",
            "https://user@guest.herdrup.themartian.app/i/\(payload)",
            "http://guest.herdrup.themartian.app/i/\(payload)",
            "https://guest.herdrup.themartian.app/x/i/\(payload)",
            "https://guest.herdrup.themartian.app/i/i/\(payload)",
            "https://guest.herdrup.themartian.app/i/\(payload)/",
            "https://guest.herdrup.themartian.app/i/\(payload)/extra",
            "https://guest.herdrup.themartian.app/i/\(payload)?x=1",
            "https://guest.herdrup.themartian.app/i/\(payload)#\(payload)",
            "https://guest.herdrup.themartian.app/i?x=1#\(payload)",
            "https://guest.herdrup.themartian.app/in#\(payload)",
            "https://guest.herdrup.themartian.app/i/",
            "https://guest.herdrup.themartian.app/i#",
            "herdrup://guest-invite#",
        ]
        for link in links {
            XCTAssertThrowsError(try GuestInvite.parse(link, now: Self.now), link) {
                XCTAssertEqual($0 as? GuestInvite.Failure, .notAnInvite, link)
            }
        }
    }

    /// Characters outside base64url in the payload mean a damaged link in every form.
    func testRejectsBadPayloadCharacters() {
        let payload = Self.payload(Self.fields())
        let damaged = [String(payload.dropLast(3)) + "!!!", String(payload.dropLast(3)) + "%2F",
                       String(payload.dropLast(4)) + "abc=", "+" + String(payload.dropFirst())]
        for bad in damaged {
            for link in ["herdrup://guest-invite#\(bad)", "https://guest.herdrup.themartian.app/i/\(bad)",
                         "https://guest.herdrup.themartian.app/i#\(bad)"] {
                XCTAssertThrowsError(try GuestInvite.parse(link, now: Self.now), link) {
                    XCTAssertEqual($0 as? GuestInvite.Failure, .malformed("encoding"), link)
                }
            }
        }
    }

    func testRecognisesInviteLinkShapes() {
        XCTAssertTrue(GuestInvite.isInviteLink("herdrup://guest-invite#abc"))
        XCTAssertTrue(GuestInvite.isInviteLink("https://guest.herdrup.themartian.app/i/abc"))
        XCTAssertTrue(GuestInvite.isInviteLink("https://guest.herdrup.themartian.app/i#abc"))
        for text in ["herdrup://agent/w1-3", "https://guest.herdrup.themartian.app/i",
                     "https://guest.herdrup.themartian.app/i/abc/def", "https://example.org/about"] {
            XCTAssertFalse(GuestInvite.isInviteLink(text), text)
        }
    }

    /// An older daemon's `…/i#<payload>` goes out as `…/i/<payload>`, which Messages
    /// keeps whole, and still opens the same invite.
    func testShareableWebURLConvertsTheFragmentForm() throws {
        let payload = Self.payload(Self.fields())
        func created(_ webURL: String) -> GuestInviteCreated {
            GuestInviteCreated(invite: GuestInviteRecord(inviteID: "inv", name: "plotarmordev", grant: nil),
                               url: "herdrup://guest-invite#\(payload)", webURL: webURL)
        }
        let old = created("https://guest.herdrup.themartian.app/i#\(payload)")
        XCTAssertEqual(old.shareableWebURL, "https://guest.herdrup.themartian.app/i/\(payload)")
        XCTAssertFalse(old.shareableWebURL.contains("#"))
        XCTAssertEqual(try GuestInvite.parse(old.shareableWebURL, now: Self.now),
                       try GuestInvite.parse(old.webURL, now: Self.now))

        let mounted = created("https://example.org/herdr/i#\(payload)")
        XCTAssertEqual(mounted.shareableWebURL, "https://example.org/herdr/i/\(payload)")

        let current = created("https://guest.herdrup.themartian.app/i/\(payload)")
        XCTAssertEqual(current.shareableWebURL, current.webURL)
    }

    /// A link pasted with the owner's message around it, as Messages delivers it.
    func testFindsTheLinkInsidePastedText() throws {
        let payload = Self.payload(Self.fields())
        for link in ["https://guest.herdrup.themartian.app/i/\(payload)",
                     "https://guest.herdrup.themartian.app/i#\(payload)"] {
            let text = "hey! here's llm-opt:\n \(link)  \nhave fun"
            XCTAssertEqual(try GuestInvite.parse(text, now: Self.now).agentName, "llm-opt", link)
        }
    }

    func testExpiryBoundary() throws {
        let expires = Int(Self.now.timeIntervalSince1970) + 10
        let link = "herdrup://guest-invite#" + Self.payload(Self.fields(overriding: ["expires_unix": expires]))
        XCTAssertNoThrow(try GuestInvite.parse(link, now: Self.now.addingTimeInterval(9)))
        XCTAssertThrowsError(try GuestInvite.parse(link, now: Self.now.addingTimeInterval(10))) { error in
            XCTAssertEqual(error as? GuestInvite.Failure, .expired)
        }
    }

    func testRejectsLinksThatAreNotInvites() {
        for text in ["", "hello", "https://guest.herdrup.themartian.app/x#abc",
                     "http://guest.herdrup.themartian.app/i#abc", "herdrup://agent/w1-3"] {
            XCTAssertThrowsError(try GuestInvite.parse(text, now: Self.now), text) { error in
                XCTAssertEqual(error as? GuestInvite.Failure, .notAnInvite, text)
            }
        }
    }

    func testRejectsDamagedFields() {
        let cases: [(String, Any, String)] = [
            ("host_pub", Base64URL.encode(Data(count: 31)), "host_pub"),
            ("host_id", "not b64url!", "host_id"),
            ("secret", Base64URL.encode(Data(count: 16)), "secret"),
            ("invite_id", Base64URL.encode(Data(count: 32)), "invite_id"),
            ("guest_name", "-bad", "guest_name"),
            ("guest_name", String(repeating: "a", count: 33), "guest_name"),
            ("machine_label", "  ", "machine_label"),
            ("agent_name", "llm\nopt", "agent_name"),
            ("relay", "ftp://guest.herdrup.themartian.app", "relay"),
            // A cleartext relay is only accepted for a local development relay.
            ("relay", "http://evil.example", "relay"),
            ("expires_unix", "tomorrow", "expires_unix"),
        ]
        for (key, value, field) in cases {
            let link = "herdrup://guest-invite#" + Self.payload(Self.fields(overriding: [key: value]))
            XCTAssertThrowsError(try GuestInvite.parse(link, now: Self.now), "\(key)=\(value)") { error in
                XCTAssertEqual(error as? GuestInvite.Failure, .malformed(field), "\(key)=\(value)")
            }
        }
        var missing = Self.fields()
        missing.removeValue(forKey: "secret")
        XCTAssertThrowsError(try GuestInvite.parse("herdrup://guest-invite#" + Self.payload(missing), now: Self.now)) {
            XCTAssertEqual($0 as? GuestInvite.Failure, .malformed("secret"))
        }
        XCTAssertThrowsError(try GuestInvite.parse("herdrup://guest-invite#!!!", now: Self.now)) {
            XCTAssertEqual($0 as? GuestInvite.Failure, .malformed("encoding"))
        }
    }

    func testLocalDevelopmentRelayIsAllowed() throws {
        let link = "herdrup://guest-invite#" + Self.payload(Self.fields(overriding: ["relay": "http://localhost:8787"]))
        let invite = try GuestInvite.parse(link, now: Self.now)
        let endpoint = RelayEndpoint(relay: invite.relay, hostID: invite.hostID, hostPublicKey: invite.hostPublicKey)
        XCTAssertEqual(endpoint.socketURL.absoluteString, "ws://localhost:8787/v1/guest/\(invite.hostID)")
    }

    func testNewerInviteVersionAsksForAnUpdate() {
        let link = "herdrup://guest-invite#" + Self.payload(Self.fields(overriding: ["v": 2]))
        XCTAssertThrowsError(try GuestInvite.parse(link, now: Self.now)) { error in
            XCTAssertEqual(error as? GuestInvite.Failure, .unsupportedVersion(2))
        }
    }

    func testBase64URLIsStrict() {
        XCTAssertEqual(Base64URL.encode(Data([0xfb, 0xff])), "-_8")
        XCTAssertEqual(Base64URL.decode("-_8"), Data([0xfb, 0xff]))
        XCTAssertNil(Base64URL.decode("-_8="), "padding")
        XCTAssertNil(Base64URL.decode("+/8"), "standard alphabet")
        XCTAssertNil(Base64URL.decode("abcde"), "impossible length")
    }

    func testRelaySocketURL() {
        let endpoint = RelayEndpoint(
            relay: URL(string: "https://guest.herdrup.themartian.app/")!, hostID: "AAAAAAAAAAAAAAAAAAAAAA",
            hostPublicKey: Data(count: 32))
        XCTAssertEqual(endpoint.socketURL.absoluteString,
                       "wss://guest.herdrup.themartian.app/v1/guest/AAAAAAAAAAAAAAAAAAAAAA")
    }

    // MARK: Short links

    static let shortID = "k7Qp2xRmA1bC"
    static let shortKey = Data((1...16).map { UInt8($0) })

    /// What the daemon stores on the relay: nonce || ciphertext || tag, bound to `id`.
    static func seal(_ fields: [String: Any], id: String = shortID, key: Data = shortKey) -> Data {
        let json = try! JSONSerialization.data(withJSONObject: fields)
        return try! AES.GCM.seal(json, using: SymmetricKey(data: key), authenticating: Data(id.utf8)).combined!
    }

    static func shortLink(relay: String = "https://guest.herdrup.themartian.app", id: String = shortID,
                          key: Data = shortKey) -> String {
        "\(relay)/i/\(id)\(Base64URL.encode(key))"
    }

    /// Records each fetched URL and answers with `answer`.
    final class FakeRelay: @unchecked Sendable {
        private let lock = NSLock()
        private var fetched: [URL] = []
        private let answer: @Sendable () throws -> Data

        init(_ answer: @escaping @Sendable () throws -> Data) { self.answer = answer }

        var urls: [URL] { lock.withLock { fetched } }

        var fetch: GuestInvite.SealedInviteFetch {
            { url in
                self.lock.withLock { self.fetched.append(url) }
                return try self.answer()
            }
        }
    }

    func testTellsShortLinksFromLongOnesAndJunk() {
        let key = Base64URL.encode(Self.shortKey)
        XCTAssertEqual(key.count, 22)
        let short = GuestInvite.Link(Self.shortLink())
        XCTAssertEqual(Self.shortLink().count, "https://guest.herdrup.themartian.app/i/".count + 34)
        XCTAssertEqual(short?.content, .sealed(id: Self.shortID, key: key))
        XCTAssertEqual(short?.web?.sealedInviteURL(id: Self.shortID).absoluteString,
                       "https://guest.herdrup.themartian.app/v1/invite/\(Self.shortID)")
        XCTAssertEqual(GuestInvite.Link("https://example.org/herdr/i/\(Self.shortID)\(key)")?
            .web?.sealedInviteURL(id: Self.shortID).absoluteString,
                       "https://example.org/herdr/v1/invite/\(Self.shortID)")
        XCTAssertTrue(GuestInvite.isInviteLink(Self.shortLink()))

        // Anything but exactly 34 base64url characters is the long form.
        let payload = Self.payload(Self.fields())
        let segment = Self.shortID + key
        for long in [payload, String(segment.dropLast()), segment + "A", String(segment.dropLast()) + "!",
                     String(segment.dropLast()) + "="] {
            XCTAssertEqual(GuestInvite.Link("https://guest.herdrup.themartian.app/i/\(long)")?.content,
                           .payload(long), long)
        }

        let base = "https://guest.herdrup.themartian.app/i/"
        for junk in [base + "\(Self.shortID)#\(key)", base + "\(segment)#x", base + "\(segment)?q=1",
                     base + "\(segment)/", base + "\(segment)/x", "http://guest.herdrup.themartian.app/i/\(segment)"] {
            XCTAssertFalse(GuestInvite.isInviteLink(junk), junk)
        }
    }

    /// The vector the daemon, the relay page and this app all check (made independently with
    /// Python `cryptography` AESGCM; synthetic identifiers), so the three cannot drift.
    func testShortLinkKnownAnswer() async throws {
        let link = "https://guest.herdrup.themartian.app/i/AQIDBAUGBwgJEBESExQVFhcYGRobHB0eHw"
        let short = GuestInvite.Link.shortForm(path: "/i/AQIDBAUGBwgJEBESExQVFhcYGRobHB0eHw", fragment: nil)
        XCTAssertEqual(short?.basePath, "")
        XCTAssertEqual(short?.id, "AQIDBAUGBwgJ")
        XCTAssertEqual(short?.key, "EBESExQVFhcYGRobHB0eHw")
        XCTAssertEqual(GuestInvite.Link(link)?.content, .sealed(id: "AQIDBAUGBwgJ", key: "EBESExQVFhcYGRobHB0eHw"))

        let blob = Data(base64Encoded:
            "MDEyMzQ1Njc4OTo76HmMcTjDzE3OdSaDaK9beuTqzPLVVEUBKIa8OWJbqs8XDxQL0uQJSTWFeZvgkikIe1wxOA3sk7Hb4x6wjfHjOvVi"
            + "3zfizc3/SM6+90bB9XIi6BXSmuiq8Z6OGZXR7UrLkh6Inxwh/qbAALuB4Rutr24iIC1sU1lG5r7/RWTqMxLRqqDKR32zUCL9iDYu8gaE"
            + "rdUgZeTfpeik9cwTC2mS9pAAakSI/hIczZymbpBb/IrgIv1W3sHDAfC08BLtejXbbxeRGf9jCWTISaVmJu0US2YeF36Re83O9PTtHSl9"
            + "52NNjZtz9hsOMylQomFWeNSDDtRe9oRVNidH/AW4KZnvLpFPC8I0/kZw6IIj18rkR0tEUuZ6ftnsFbrAvQs7hsQn4o6LtYtbJsZ6qhrg"
            + "lLQsb2yiyz5ilcqpXIOl+XaAEjfijL7c8KyX2hbUvWFDH6GS2VWqnlXnKt0SW0rQEaZ4ZBTtBAhU9uehul9N9CJXoQq1")!
        let plaintext = #"{"agent_name":"demo","expires_unix":4102444800,"guest_name":"guest","host_id":"QUFBQUFBQUFBQUFBQUFBQQ","host_pub":"QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI","invite_id":"Q0NDQ0NDQ0NDQ0NDQ0NDQw","machine_label":"test-box","owner_name":"Owner","relay":"https://guest.herdrup.themartian.app","secret":"REREREREREREREREREREREREREREREREREREREREREQ","v":1}"#
        XCTAssertEqual(try GuestInvite.open(sealed: blob, id: "AQIDBAUGBwgJ", key: "EBESExQVFhcYGRobHB0eHw"),
                       Data(plaintext.utf8))

        let relay = FakeRelay { blob }
        let invite = try await GuestInvite.resolve(link, now: Self.now, fetch: relay.fetch)
        XCTAssertEqual(relay.urls.map(\.absoluteString), ["https://guest.herdrup.themartian.app/v1/invite/AQIDBAUGBwgJ"])
        XCTAssertEqual(invite, GuestInvite(
            relay: URL(string: "https://guest.herdrup.themartian.app")!,
            hostID: "QUFBQUFBQUFBQUFBQUFBQQ", hostPublicKey: Data(repeating: UInt8(ascii: "B"), count: 32),
            inviteID: "Q0NDQ0NDQ0NDQ0NDQ0NDQw", secret: "REREREREREREREREREREREREREREREREREREREREREQ",
            machineLabel: "test-box", ownerName: "Owner", agentName: "demo", guestName: "guest",
            expires: Date(timeIntervalSince1970: 4_102_444_800)))
    }

    func testResolvesAShortLinkFromItsOwnRelay() async throws {
        let relay = FakeRelay { Self.seal(Self.fields()) }
        let invite = try await GuestInvite.resolve(
            "here you go: \(Self.shortLink()) enjoy", now: Self.now, fetch: relay.fetch)
        XCTAssertEqual(invite, try GuestInvite.parse("herdrup://guest-invite#\(Self.payload(Self.fields()))", now: Self.now))
        XCTAssertEqual(relay.urls.map(\.absoluteString),
                       ["https://guest.herdrup.themartian.app/v1/invite/\(Self.shortID)"])

        // The sync parser cannot open a short link.
        XCTAssertThrowsError(try GuestInvite.parse(Self.shortLink(), now: Self.now)) {
            XCTAssertEqual($0 as? GuestInvite.Failure, .notAnInvite)
        }
    }

    func testResolveReadsLongLinksWithoutFetching() async throws {
        let relay = FakeRelay { XCTFail("fetched"); return Data() }
        let link = "https://guest.herdrup.themartian.app/i/\(Self.payload(Self.fields()))"
        let invite = try await GuestInvite.resolve(link, now: Self.now, fetch: relay.fetch)
        XCTAssertEqual(invite.agentName, "llm-opt")
        XCTAssertTrue(relay.urls.isEmpty)
    }

    func testShortLinkSealMustMatchKeyAndID() async {
        let cases: [(String, Data)] = [
            ("wrong key", Self.seal(Self.fields(), key: Data(repeating: 9, count: 16))),
            ("wrong aad", Self.seal(Self.fields(), id: "AAAAAAAAAAAA")),
            ("tampered", { var blob = Self.seal(Self.fields()); blob[blob.count - 20] ^= 1; return blob }()),
            ("truncated", Data(Self.seal(Self.fields()).prefix(28))),
            ("too big", Data(count: GuestInvite.maxSealedInviteSize + 1)),
        ]
        for (name, blob) in cases {
            await assertResolveFails(Self.shortLink(), blob: blob, .malformed("seal"), name)
        }
    }

    /// A sealed invite opens only on the relay it names, so a relay cannot hand out an
    /// invite that steers the guest somewhere else.
    func testShortLinkRejectsAnInviteForAnotherRelay() async {
        for relay in ["https://evil.example", "https://guest.herdrup.themartian.app/herdr",
                      "https://guest.herdrup.themartian.app:8443"] {
            await assertResolveFails(Self.shortLink(), blob: Self.seal(Self.fields(overriding: ["relay": relay])),
                                     .malformed("relay"), relay)
        }
    }

    func testShortLinkRunsTheUsualValidation() async {
        await assertResolveFails(Self.shortLink(), blob: Self.seal(Self.fields(overriding: ["secret": "short"])),
                                 .malformed("secret"), "secret")
        await assertResolveFails(
            Self.shortLink(),
            blob: Self.seal(Self.fields(overriding: ["expires_unix": Int(Self.now.timeIntervalSince1970)])),
            .expired, "expired")
    }

    func testShortLinkFetchFailures() async {
        XCTAssertEqual(try GuestInvite.sealedInvite(status: 200, body: Data([1, 2])), Data([1, 2]))
        for (status, expected) in [(404, GuestInvite.Failure.revoked), (500, .unreachable), (429, .unreachable)] {
            XCTAssertThrowsError(try GuestInvite.sealedInvite(status: status, body: Data()), "\(status)") {
                XCTAssertEqual($0 as? GuestInvite.Failure, expected, "\(status)")
            }
        }
        XCTAssertEqual(GuestInvite.Failure.revoked.description, "this invite has expired or was revoked.")

        let gone = FakeRelay { try GuestInvite.sealedInvite(status: 404, body: Data()) }
        await assertResolveFails(Self.shortLink(), fetch: gone.fetch, .revoked, "404")
        let offline = FakeRelay { throw URLError(.notConnectedToInternet) }
        await assertResolveFails(Self.shortLink(), fetch: offline.fetch, .unreachable, "offline")
    }

    private func assertResolveFails(_ link: String, blob: Data, _ expected: GuestInvite.Failure, _ name: String,
                                    line: UInt = #line) async {
        await assertResolveFails(link, fetch: FakeRelay { blob }.fetch, expected, name, line: line)
    }

    private func assertResolveFails(_ link: String, fetch: @escaping GuestInvite.SealedInviteFetch,
                                    _ expected: GuestInvite.Failure, _ name: String, line: UInt = #line) async {
        do {
            _ = try await GuestInvite.resolve(link, now: Self.now, fetch: fetch)
            XCTFail("\(name): resolved", line: line)
        } catch {
            XCTAssertEqual(error as? GuestInvite.Failure, expected, name, line: line)
        }
    }
}

final class GuestNameTests: XCTestCase {
    func testNameRule() {
        for valid in ["plotarmordev", "a", "A.b_c-9", String(repeating: "x", count: 32)] {
            XCTAssertTrue(GuestName.isValid(valid), valid)
        }
        for invalid in ["", ".a", "_a", "-a", "a b", "é", "a/b", String(repeating: "x", count: 33)] {
            XCTAssertFalse(GuestName.isValid(invalid), invalid)
        }
    }
}

final class GuestIdentityTests: XCTestCase {
    func testFingerprintFormat() {
        XCTAssertEqual(GuestIdentity.fingerprint(of: Data(0..<32)), "SHA256:630d·cd29·66c4·3366")
    }

    func testKeyIsCreatedOnceAndReused() throws {
        let store = InMemoryGuestKeyStore()
        let first = try GuestIdentity.loadOrCreate(store: store)
        XCTAssertEqual(try store.loadGuestKey()?.count, 32)
        let second = try GuestIdentity.loadOrCreate(store: store)
        XCTAssertEqual(first.publicKey, second.publicKey)
        XCTAssertEqual(first.fingerprint, second.fingerprint)
    }

    /// Losing the key severs every share; a store that returns garbage must be
    /// surfaced, never silently replaced with a fresh key.
    func testCorruptStoredKeyIsNotOverwritten() {
        let store = InMemoryGuestKeyStore(key: Data(count: 7))
        XCTAssertThrowsError(try GuestIdentity.loadOrCreate(store: store)) { error in
            XCTAssertEqual(error as? GuestIdentity.Failure, .corruptKey)
        }
        XCTAssertEqual(try store.loadGuestKey(), Data(count: 7))
    }
}
