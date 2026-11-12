import XCTest
@testable import HerdrKit

/// `GramRecipients.build`: who Gram's "@" list and agents sheet offer. Recent senders first,
/// then every other agent `gram.post` would accept, so an agent that never wrote can be picked.
final class GramRecipientsTests: XCTestCase {

    private func agent(_ name: String?, pane: String, machineID: String? = nil,
                       machineLabel: String? = nil, reachability: String? = nil,
                       archived: Bool = false) throws -> AgentInfo {
        var obj: [String: Any] = ["pane_id": pane]
        if let name { obj["name"] = name }
        if let machineID { obj["machine_id"] = machineID }
        if let machineLabel { obj["machine_label"] = machineLabel }
        if let reachability { obj["reachability"] = reachability }
        if archived { obj["archived"] = ["at": "2026-11-01T00:00:00Z"] }
        let data = try JSONSerialization.data(withJSONObject: obj)
        return try JSONDecoder().decode(AgentInfo.self, from: data)
    }

    private func gram(_ id: String, from: String, at ms: UInt64, machineLabel: String? = nil) -> GramMessage {
        GramMessage(id: id, direction: .agentToOwner, from: from, text: "hi", createdUnixMs: ms,
                    readByOwner: true, machineLabel: machineLabel)
    }

    private func owner(_ id: String, to: String, at ms: UInt64) -> GramMessage {
        GramMessage(id: id, direction: .ownerToAgent, from: "owner", to: to, text: "go", createdUnixMs: ms,
                    readByOwner: true)
    }

    func testARosterAgentThatNeverWroteIsListed() throws {
        let list = GramRecipients.build(messages: [], roster: [try agent("jarvis", pane: "w1:p1")],
                                        localMachine: "mac-studio")
        XCTAssertEqual(list, [GramRecipient(from: "jarvis", name: "jarvis", machine: "mac-studio")])
    }

    func testRecentSendersComeFirstThenTheRestAlphabetically() throws {
        let messages = [gram("g1", from: "vetrina", at: 3), owner("g2", to: "zed", at: 2),
                        gram("g3", from: "clientloop", at: 1)]
        let roster = try [agent("zed", pane: "w1:p1"), agent("Bravo", pane: "w1:p2"),
                          agent("vetrina", pane: "w1:p3"), agent("alfa", pane: "w1:p4"),
                          agent("clientloop", pane: "w1:p5")]
        let list = GramRecipients.build(messages: messages, roster: roster, localMachine: "")
        XCTAssertEqual(list.map(\.from), ["vetrina", "clientloop", "alfa", "Bravo", "zed"],
                       "senders newest first, then the others A to Z; an owner post makes no sender")
    }

    func testOneEntryPerRoutingName() throws {
        let messages = [gram("g1", from: "vetrina", at: 2), gram("g2", from: "vetrina", at: 1)]
        let list = GramRecipients.build(messages: messages, roster: [try agent("vetrina", pane: "w1:p1")],
                                        localMachine: "")
        XCTAssertEqual(list.map(\.from), ["vetrina"])
    }

    /// The same bare name on this machine and on a peer stays two recipients, each with its
    /// own routing name (`<alias>/<name>` for the peer) and machine label.
    func testTheSameNameOnTwoMachinesStaysApart() throws {
        let roster = try [
            agent("clientloop", pane: "w1:p1"),
            agent("4b1e/clientloop", pane: "4b1e/w1:p1", machineID: "4b1e", machineLabel: "hetzner-1",
                  reachability: "reachable"),
            agent("mcb-air/clientloop", pane: "mcb-air/w1:p2", machineID: "mcb-air", reachability: "reachable"),
        ]
        let list = GramRecipients.build(messages: [gram("g1", from: "4b1e/clientloop", at: 1, machineLabel: "hetzner-1")],
                                        roster: roster, localMachine: "mac-studio")
        XCTAssertEqual(list, [
            GramRecipient(from: "4b1e/clientloop", name: "clientloop", machine: "hetzner-1"),
            GramRecipient(from: "clientloop", name: "clientloop", machine: "mac-studio"),
            GramRecipient(from: "mcb-air/clientloop", name: "clientloop", machine: "mcb-air"),
        ])
    }

    /// Only agents `gram.post` accepts: no archived or unnamed agent, and a peer's agent only
    /// while that peer is reachable.
    func testAgentsTheDaemonWouldRefuseAreLeftOut() throws {
        let roster = try [
            agent("huurjacht", pane: "", archived: true),
            agent(nil, pane: "w1:p2"),
            agent("mcb-air/scout", pane: "mcb-air/w1:p1", machineID: "mcb-air", reachability: "degraded"),
            agent("box/scout", pane: "box/w1:p1", machineID: "box", reachability: "unreachable"),
            agent("ok", pane: "w1:p3"),
        ]
        let list = GramRecipients.build(messages: [], roster: roster, localMachine: "")
        XCTAssertEqual(list, [GramRecipient(from: "ok", name: "ok", machine: nil)])
    }
}
