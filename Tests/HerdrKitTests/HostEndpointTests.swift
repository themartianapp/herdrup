import XCTest
@testable import HerdrKit

final class HostEndpointTests: XCTestCase {

    // MARK: - recognising a tailnet destination

    /// AXIS: the /10 BOUNDARIES. Tailscale uses 100.64.0.0/10, not 100.0.0.0/8 —
    /// so 100.63.x.x and 100.128.x.x are ordinary public addresses. Getting this
    /// wrong makes a real internet host stop retrying after three failures, which
    /// is a worse bug than the spinner this fix removes.
    func testCarrierGradeNATRangeBoundaries() {
        for inside in ["100.64.0.0", "100.64.1.2", "100.100.50.7", "100.127.255.255"] {
            XCTAssertEqual(HostEndpoint.parse(inside)?.isTailnetAddress, true, "\(inside) is in 100.64.0.0/10")
        }
        for outside in ["100.63.255.255", "100.128.0.0", "100.0.0.1", "100.255.255.255"] {
            XCTAssertEqual(HostEndpoint.parse(outside)?.isTailnetAddress, false, "\(outside) is outside the /10")
        }
    }

    /// AXIS: ordinary private and public addresses are never tailnet.
    func testOrdinaryAddressesAreNotTailnet() {
        for host in ["10.0.0.1", "192.168.1.10", "172.16.0.1", "8.8.8.8", "127.0.0.1"] {
            XCTAssertEqual(HostEndpoint.parse(host)?.isTailnetAddress, false, host)
        }
    }

    /// AXIS: a port must not change the verdict — the classifier reads the parsed
    /// host, so "100.64.0.1:2222" is the same destination as "100.64.0.1".
    func testPortDoesNotAffectTheVerdict() {
        XCTAssertEqual(HostEndpoint.parse("100.64.0.1:2222")?.isTailnetAddress, true)
        XCTAssertEqual(HostEndpoint.parse("192.168.1.1:2222")?.isTailnetAddress, false)
    }

    /// AXIS: MagicDNS names, and the two near-misses. The leading dot is what
    /// separates "box.ts.net" from "notts.net"; requiring a label before it keeps
    /// a bare "ts.net" out; and a suffix check (not a substring one) is what stops
    /// an attacker-controlled "ts.net.evil.com" from reading as a tailnet host.
    func testMagicDNSNamesAndTheirNearMisses() {
        for name in ["box.ts.net", "mac.tail-scale.ts.net", "BOX.TS.NET"] {
            XCTAssertEqual(HostEndpoint.parse(name)?.isTailnetAddress, true, name)
        }
        for name in ["notts.net", "ts.net", "ts.net.evil.com", "example.com", "tsxnet"] {
            XCTAssertEqual(HostEndpoint.parse(name)?.isTailnetAddress, false, name)
        }
    }

    /// AXIS: a dotted string that is not four numeric octets is a NAME, and must
    /// be judged as one — "100.64.0.0.evil.com" must not pass as an address.
    func testAddressLookalikesAreNotTreatedAsAddresses() {
        XCTAssertEqual(HostEndpoint.parse("100.64.0.0.evil.com")?.isTailnetAddress, false)
        XCTAssertEqual(HostEndpoint.parse("100.64.0")?.isTailnetAddress, false)
        XCTAssertEqual(HostEndpoint.parse("100.999.0.1")?.isTailnetAddress, false)
    }

    // MARK: - the valid shapes

    func testPlainHostDefaultsTo22() {
        XCTAssertEqual(HostEndpoint.parse("mac.tail-scale.ts.net"), HostEndpoint(host: "mac.tail-scale.ts.net", port: 22))
    }

    func testHostColonPort() {
        XCTAssertEqual(HostEndpoint.parse("host:2222"), HostEndpoint(host: "host", port: 2222))
    }

    func testBracketedIPv6WithPort() {
        XCTAssertEqual(HostEndpoint.parse("[::1]:22"), HostEndpoint(host: "::1", port: 22))
    }

    func testBracketedIPv6WithoutPortDefaults() {
        XCTAssertEqual(HostEndpoint.parse("[fe80::1]"), HostEndpoint(host: "fe80::1", port: 22))
    }

    /// AXIS: a bare IPv6 literal (many colons, no brackets) is NOT split into
    /// host:port — the whole thing is the host on the default port.
    func testBareIPv6StaysWhole() {
        XCTAssertEqual(HostEndpoint.parse("::1"), HostEndpoint(host: "::1", port: 22))
        XCTAssertEqual(HostEndpoint.parse("fe80::1"), HostEndpoint(host: "fe80::1", port: 22))
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(HostEndpoint.parse("  host:2222 \n"), HostEndpoint(host: "host", port: 2222))
    }

    // MARK: - the fail-OPEN class the reviewers found

    /// AXIS: an EXPLICIT but invalid port is REJECTED, never silently defaulted
    /// to 22. Before the fix the bracketed branch returned the valid inner host on
    /// port 22 for every one of these, connecting to a port the user never typed
    /// and TOFU-pinning whatever answered there. Each case must now be nil.
    func testBracketedInvalidPortIsRejectedNotDefaulted() {
        for bad in ["[fe80::1]:80222",   // > 65535 (UInt16 overflow)
                    "[fe80::1]:0",        // port 0
                    "[fe80::1]:notaport", // non-numeric
                    "[fe80::1]:",         // empty port
                    "[fe80::1]garbage"] { // junk after the bracket, no colon
            XCTAssertNil(HostEndpoint.parse(bad),
                         "\(bad) should be rejected, not silently connected to :22")
        }
    }

    /// The unbracketed branch must fail the SAME way — an explicit bad port is a
    /// rejection, so the two branches agree (they disagreed before the fix).
    func testUnbracketedInvalidPortIsRejected() {
        for bad in ["host:notaport", "host:80222", "host:0", "host:"] {
            XCTAssertNil(HostEndpoint.parse(bad), "\(bad) should be rejected")
        }
    }

    /// The port must read EXACTLY as a number — no leading sign or spaces that
    /// UInt16(_:) would quietly normalise ("+22" would otherwise parse to 22).
    func testNonDigitPortsAreRejected() {
        for bad in ["host:+22", "host:-1", "host: 22", "[::1]:+1"] {
            XCTAssertNil(HostEndpoint.parse(bad), "\(bad) should be rejected — port is not plain digits")
        }
    }

    func testMalformedBracketsAndEmptyAreRejected() {
        for bad in ["", "   ", "[::1", "[]", "[]:22", "[]:notaport"] {
            XCTAssertNil(HostEndpoint.parse(bad), "\(bad.debugDescription) should be rejected")
        }
    }

    /// Boundary: the largest valid port parses, one past it does not.
    func testPortBoundary() {
        XCTAssertEqual(HostEndpoint.parse("h:65535")?.port, 65535)
        XCTAssertNil(HostEndpoint.parse("h:65536"))
    }

    // MARK: - one host-key pin

    /// A saved machine keeps its paired host-key algorithm across an address edit exactly when
    /// the edit keeps its pin (`SavedHostsStore` asks `samePin`; `KeychainHostKeyPolicy` keys the
    /// pin by `pinKey`). Another spelling of the same host keeps both; a real change drops both.
    func testOtherSpellingsShareOnePinAndAnotherHostDoesNot() {
        XCTAssertTrue(HostEndpoint.samePin("mac.local", "mac.local."))
        XCTAssertTrue(HostEndpoint.samePin("Mac.Local:22", "mac.local"))
        XCTAssertTrue(HostEndpoint.samePin("[::1]", "[0:0::1]"))
        XCTAssertTrue(HostEndpoint.samePin("[fe80::1%EN0]:2222", "[fe80:0::1%en0]:2222"))
        XCTAssertEqual(HostEndpoint.parse("[0:0::1]")?.pinKey, "::1:22")

        XCTAssertFalse(HostEndpoint.samePin("mac.local", "mini.local"))
        XCTAssertFalse(HostEndpoint.samePin("mac.local", "mac.local:2222"))
        XCTAssertFalse(HostEndpoint.samePin("[::1]", "[::2]"))
    }
}
