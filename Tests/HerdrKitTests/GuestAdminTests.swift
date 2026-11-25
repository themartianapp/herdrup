import XCTest
@testable import HerdrKit

/// The owner-side guest RPCs: what goes on the wire (including routing a federated agent to
/// the daemon that runs it) and how leniently the answers decode.
final class GuestAdminTests: XCTestCase {

    private static let inviteReply = #"""
    {"id":"x","result":{"type":"guest_invite","invite":{"invite_id":"inv1","name":"plotarmordev",
    "grant":{"terminal_id":"t7","agent_name":"llm-opt","agent_session":{"source":"hook","agent":"omp","kind":"session_id","value":"s1"}},"owner_name":"Jerry",
    "machine_label":"Jerry's Mac Studio","created_ms":1000,"expires_ms":86401000,"used_by":null,
    "secret_sha256":"ignored"},"url":"herdrup://guest-invite#eyJ2IjoxfQ",
    "web_url":"https://guest.herdrup.themartian.app/i#eyJ2IjoxfQ"}}
    """#

    private func federatedAgent() throws -> AgentInfo {
        try JSONDecoder().decode(AgentInfo.self, from: Data(#"""
        {"pane_id":"2cc0ffe3/w1:p3","name":"2cc0ffe3/llm-opt","terminal_id":"2cc0ffe3/t7",
         "machine_id":"2cc0ffe3","machine_label":"Jerry's Mac Studio","agent":"omp"}
        """#.utf8))
    }

    // MARK: guest.invite.create

    func testInviteCreateForALocalAgentSendsNoMachine() async throws {
        let t = RecordingTransport(reply: Self.inviteReply)
        let created = try await HerdrClient(transport: t).guestInviteCreate(
            target: "w1:p1", name: "plotarmordev", ownerName: "Jerry", machineLabel: "Jerry's Mac Studio")

        let (method, params) = try t.last()
        XCTAssertEqual(method, "guest.invite.create")
        XCTAssertEqual(params["target"] as? String, "w1:p1")
        XCTAssertEqual(params["name"] as? String, "plotarmordev")
        XCTAssertEqual(params["owner_name"] as? String, "Jerry")
        XCTAssertEqual(params["machine_label"] as? String, "Jerry's Mac Studio")
        // A local call must not carry a machine (not even null): the coordinator would try to
        // route it to a peer.
        XCTAssertNil(params["machine"], "local invite must not name a machine")
        XCTAssertNil(params["ttl_secs"], "no ttl means the daemon's 24 h default")

        XCTAssertEqual(created.url, "herdrup://guest-invite#eyJ2IjoxfQ")
        XCTAssertEqual(created.webURL, "https://guest.herdrup.themartian.app/i#eyJ2IjoxfQ")
        XCTAssertEqual(created.invite.inviteID, "inv1")
        XCTAssertEqual(created.invite.grant, GuestGrant(terminalID: "t7", agentName: "llm-opt"))
        XCTAssertEqual(created.invite.expiresMs, 86_401_000)
        XCTAssertNil(created.invite.usedBy)
    }

    /// A federated agent is shared by the daemon that runs it: the coordinator gets the peer
    /// alias as `machine` and the pane id that peer knows, never the prefixed id.
    func testInviteCreateForAFederatedAgentRoutesToItsMachineWithTheLocalPane() async throws {
        let route = GuestRoute(agent: try federatedAgent())
        XCTAssertEqual(route.target, "w1:p3")
        XCTAssertEqual(route.machine, "2cc0ffe3")
        XCTAssertEqual(route.local("2cc0ffe3/t7"), "t7", "the grant is matched by the peer's own terminal id")

        let t = RecordingTransport(reply: Self.inviteReply)
        _ = try await HerdrClient(transport: t).guestInviteCreate(
            target: route.target, name: "plotarmordev", ownerName: "Jerry",
            machineLabel: "Jerry's Mac Studio", ttlSecs: 3600, machine: route.machine)

        let (_, params) = try t.last()
        XCTAssertEqual(params["machine"] as? String, "2cc0ffe3")
        XCTAssertEqual(params["target"] as? String, "w1:p3")
        XCTAssertEqual(params["ttl_secs"] as? Int, 3600)
    }

    func testRouteStripsOnlyTheExactMachinePrefix() {
        // The local remainder may itself contain slashes.
        let nested = GuestRoute(paneID: "peer/a/b:p1", machineID: "peer")
        XCTAssertEqual(nested.target, "a/b:p1")
        XCTAssertEqual(nested.machine, "peer")
        // A pane that does not carry its machine's prefix is not rewritten or routed.
        let mismatch = GuestRoute(paneID: "other/w1:p1", machineID: "peer")
        XCTAssertEqual(mismatch.target, "other/w1:p1")
        XCTAssertNil(mismatch.machine)
        // A local agent with a slash in its id stays local.
        let local = GuestRoute(paneID: "w1/p1", machineID: nil)
        XCTAssertEqual(local.target, "w1/p1")
        XCTAssertNil(local.machine)
        XCTAssertEqual(nested.local("peer/t9"), "t9")
        XCTAssertEqual(local.local("peer/t9"), "peer/t9")
    }

    // MARK: guest.list

    func testListDecodesLenientlyAndSeparatesActiveFromRevokedAndSpentInvites() async throws {
        let reply = #"""
        {"id":"x","result":{"type":"guest_list","future_field":{"a":1},
         "guests":[
          {"guest_id":"g1","name":"plotarmordev","fingerprint":"SHA256:9f3a·e71c·04bd·c21e","device":"iPhone",
           "grant":{"terminal_id":"t7","agent_name":"llm-opt"},"created_ms":10,"last_seen_ms":20,"revoked":false,"extra":true},
          {"guest_id":"g2","name":"old","grant":{"terminal_id":"t7","agent_name":"llm-opt"},"revoked":true},
          {"guest_id":"g3","name":"other","grant":{"terminal_id":"t8","agent_name":"voice"}}],
         "invites":[
          {"invite_id":"i1","name":"fresh","grant":{"terminal_id":"t7"},"expires_ms":5000},
          {"invite_id":"i2","name":"used","grant":{"terminal_id":"t7"},"expires_ms":5000,"used_by":"g1"},
          {"invite_id":"i3","name":"stale","grant":{"terminal_id":"t7"},"expires_ms":1000}],
         "link":{"state":"hibernating","last_error":"dns"}}}
        """#
        let t = RecordingTransport(reply: reply)
        let listing = try await HerdrClient(transport: t).guestList()

        let (method, params) = try t.last()
        XCTAssertEqual(method, "guest.list")
        XCTAssertTrue(params.isEmpty, "a local list sends no params, got \(params)")

        XCTAssertEqual(listing.guests.count, 3)
        XCTAssertFalse(listing.guests[2].revoked, "an absent revoked flag means not revoked")
        XCTAssertEqual(listing.activeGuests.map(\.guestID), ["g1", "g3"])
        XCTAssertEqual(listing.activeGuests(terminalID: "t7", agentName: "llm-opt").map(\.guestID), ["g1"],
                       "the chip must name neither a revoked guest nor another agent's guest")
        XCTAssertEqual(listing.pendingInvites(nowMs: 2000).map(\.inviteID), ["i1"],
                       "used and expired invites are not pending")
        XCTAssertEqual(listing.pendingInvites(nowMs: 5000).map(\.inviteID), [],
                       "an invite expires at expires_ms")
        XCTAssertEqual(listing.link, GuestLinkStatus(state: .other("hibernating"), lastError: "dns"),
                       "an unknown link state must not fail the whole list")
    }

    func testListOnAPeerCarriesTheMachineAndToleratesMissingArrays() async throws {
        let t = RecordingTransport(reply: #"{"id":"x","result":{"type":"guest_list","link":{"state":"up"}}}"#)
        let listing = try await HerdrClient(transport: t).guestList(machine: "2cc0ffe3")
        XCTAssertEqual(try t.last().params["machine"] as? String, "2cc0ffe3")
        XCTAssertEqual(listing, GuestListing(link: GuestLinkStatus(state: .up)))
    }

    // MARK: share_gram (herdrup#338)

    func testInviteCreateSendsShareGramAndAnOrdinaryInviteSendsItOff() async throws {
        let t = RecordingTransport(reply: Self.inviteReply)
        let client = HerdrClient(transport: t)
        _ = try await client.guestInviteCreate(
            target: "w1:p1", name: "plotarmordev", ownerName: "Jerry", machineLabel: "Mac", shareGram: true)
        XCTAssertEqual(try t.last().params["share_gram"] as? Bool, true)
        _ = try await client.guestInviteCreate(
            target: "w1:p1", name: "sam", ownerName: "Jerry", machineLabel: "Mac")
        XCTAssertEqual(try t.last().params["share_gram"] as? Bool, false, "Gram is shared only when asked")
    }

    func testGuestUpdateTogglesShareGramForOneGuestOnItsMachine() async throws {
        let t = RecordingTransport(reply: #"{"id":"x","result":{"type":"ok"}}"#)
        try await HerdrClient(transport: t).guestUpdate(guestID: "g1", shareGram: true, machine: "2cc0ffe3")
        var (method, params) = try t.last()
        XCTAssertEqual(method, "guest.update")
        XCTAssertEqual(params["guest_id"] as? String, "g1")
        XCTAssertEqual(params["share_gram"] as? Bool, true)
        XCTAssertEqual(params["machine"] as? String, "2cc0ffe3")

        try await HerdrClient(transport: t).guestUpdate(guestID: "g1", shareGram: false)
        (method, params) = try t.last()
        XCTAssertEqual(params["share_gram"] as? Bool, false)
        XCTAssertNil(params["machine"], "a local guest must not name a machine")
    }

    func testListReadsShareGramPerGuestAndInviteAndAnOlderDaemonMeansOff() async throws {
        let reply = #"""
        {"id":"x","result":{"type":"guest_list","guests":[
          {"guest_id":"g1","name":"plotarmordev","share_gram":true},
          {"guest_id":"g2","name":"sam"}],
         "invites":[{"invite_id":"i1","name":"ana","share_gram":true},{"invite_id":"i2","name":"bo"}]}}
        """#
        let listing = try await HerdrClient(transport: RecordingTransport(reply: reply)).guestList()
        XCTAssertEqual(listing.guests.map(\.shareGram), [true, false])
        XCTAssertEqual(listing.invites.map(\.shareGram), [true, false])
    }

    func testGrantMatchPrefersTerminalIDAndFallsBackToName() {
        let grant = GuestGrant(terminalID: "t7", agentName: "llm-opt")
        XCTAssertTrue(grant.matches(terminalID: "t7", agentName: "renamed"))
        XCTAssertFalse(grant.matches(terminalID: "t8", agentName: "llm-opt"),
                       "a different terminal with the same name is a different agent")
        XCTAssertTrue(GuestGrant(terminalID: nil, agentName: "llm-opt").matches(terminalID: "t7", agentName: "llm-opt"))
        XCTAssertFalse(GuestGrant(terminalID: nil, agentName: nil).matches(terminalID: nil, agentName: nil))
    }

    // MARK: guest.revoke

    func testRevokeNamesExactlyOneKind() async throws {
        let t = RecordingTransport(reply: #"{"id":"x","result":{"type":"guest_revoked","guest_id":"g1","closed_streams":1}}"#)
        let client = HerdrClient(transport: t)

        try await client.guestRevoke(.guest("g1"))
        var params = try t.last().params
        XCTAssertEqual(try t.last().method, "guest.revoke")
        XCTAssertEqual(params["guest_id"] as? String, "g1")
        XCTAssertNil(params["invite_id"])
        XCTAssertNil(params["machine"])

        try await client.guestRevoke(.invite("i1"), machine: "peer")
        params = try t.last().params
        XCTAssertEqual(params["invite_id"] as? String, "i1")
        XCTAssertNil(params["guest_id"])
        XCTAssertEqual(params["machine"] as? String, "peer")
    }

    func testRevokeFailureSurfacesTheDaemonError() async throws {
        let t = RecordingTransport.error(code: "unsupported", message: "guest access is unix only")
        do {
            try await HerdrClient(transport: t).guestRevoke(.guest("g1"))
            XCTFail("an error envelope must throw")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "unsupported")
        }
    }

    func testRevokeByPersonSendsOnlyThePerson() async throws {
        let t = RecordingTransport(reply: #"{"id":"x","result":{"type":"guest_revoked","person":"acct-nike","closed_streams":2}}"#)
        try await HerdrClient(transport: t).guestRevoke(.person("acct-nike"), machine: "peer")
        let (method, params) = try t.last()
        XCTAssertEqual(method, "guest.revoke")
        XCTAssertEqual(params["person"] as? String, "acct-nike")
        XCTAssertNil(params["guest_id"], "herdr takes exactly one of guest_id, invite_id and person")
        XCTAssertNil(params["invite_id"])
        XCTAssertEqual(params["machine"] as? String, "peer")
    }

    // MARK: guest.remove_device

    func testRemoveDeviceNamesTheShareAndTheDeviceAndReadsTheShareBack() async throws {
        let reply = #"""
        {"id":"x","result":{"type":"guest_device_removed","closed_streams":1,"guest":{"guest_id":"g-n1","name":"Nike",
         "fingerprint":"SHA256:aaaa","device":"iPhone","grant":{"terminal_id":"t7","agent_name":"enyo"},"created_ms":100,
         "last_seen_ms":900,"revoked":false,"share_gram":false,"account_bound":true,"person":"acct-nike",
         "devices":[{"fingerprint":"SHA256:bbbb","device":"MacBook","added_ms":200,"last_seen_ms":500,"removed":true}]}}}
        """#
        let t = RecordingTransport(reply: reply)
        let guest = try await HerdrClient(transport: t).guestRemoveDevice(guestID: "g-n1", fingerprint: "SHA256:bbbb")
        let (method, params) = try t.last()
        XCTAssertEqual(method, "guest.remove_device")
        XCTAssertEqual(params["guest_id"] as? String, "g-n1")
        XCTAssertEqual(params["fingerprint"] as? String, "SHA256:bbbb")
        XCTAssertNil(params["machine"], "a local share must not name a machine")
        XCTAssertEqual(guest.usableDevices.map(\.fingerprint), ["SHA256:aaaa"], "the removed device is gone")

        _ = try await HerdrClient(transport: t).guestRemoveDevice(guestID: "g-n1", fingerprint: "SHA256:bbbb",
                                                                  machine: "peer")
        XCTAssertEqual(try t.last().params["machine"] as? String, "peer")
    }

    func testRemoveDeviceFromAPlainShareSurfacesTheDaemonError() async throws {
        let t = RecordingTransport.error(code: "guest_not_account_bound", message: "revoke the guest instead")
        do {
            try await HerdrClient(transport: t).guestRemoveDevice(guestID: "g-sam", fingerprint: "SHA256:dddd")
            XCTFail("an error envelope must throw")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "guest_not_account_bound")
        }
    }

    // MARK: People (account-linked shares)

    /// `guest.list` as herdr emits it with accounts: Nike accepted enyo on her iPhone and
    /// orgstudio on her MacBook, and each share learned the other device; she also opened enyo
    /// in a browser the owner removed since. sam has a plain share; `old` comes from a daemon
    /// from before accounts.
    private static let peopleReply = #"""
    {"id":"x","result":{"type":"guest_list","guests":[
     {"guest_id":"g-old","name":"old","fingerprint":"SHA256:eeee","device":"iPad",
      "grant":{"terminal_id":"t9","agent_name":"notes"},"created_ms":10,"revoked":false},
     {"guest_id":"g-n2","name":"Nike","fingerprint":"SHA256:bbbb","device":"MacBook",
      "grant":{"terminal_id":"t8","agent_name":"orgstudio"},"created_ms":150,"last_seen_ms":400,"revoked":false,
      "share_gram":false,"account_bound":true,"person":"acct-nike",
      "devices":[{"fingerprint":"SHA256:aaaa","device":"iPhone","added_ms":160,"last_seen_ms":300,"removed":false}]},
     {"guest_id":"g-sam","name":"sam","fingerprint":"SHA256:dddd","device":"iPhone",
      "grant":{"terminal_id":"t7","agent_name":"enyo"},"created_ms":120,"last_seen_ms":50,"revoked":false,
      "share_gram":false,"account_bound":false,"person":"SHA256:dddd","devices":[]},
     {"guest_id":"g-n1","name":"Nike","fingerprint":"SHA256:aaaa","device":"iPhone",
      "grant":{"terminal_id":"t7","agent_name":"enyo"},"created_ms":100,"last_seen_ms":900,"revoked":false,
      "share_gram":true,"account_bound":true,"person":"acct-nike","devices":[
       {"fingerprint":"SHA256:bbbb","device":"MacBook","added_ms":200,"last_seen_ms":500,"removed":false},
       {"fingerprint":"SHA256:cccc","device":"Browser (Chrome on macOS)","added_ms":300,"last_seen_ms":null,"removed":true}]},
     {"guest_id":"g-gone","name":"Nike","fingerprint":"SHA256:aaaa","grant":{"terminal_id":"t6"},
      "revoked":true,"account_bound":true,"person":"acct-nike"}]}}
    """#

    func testListDecodesTheAccountFieldsAndAnOlderDaemonMeansAPlainShare() async throws {
        let listing = try await HerdrClient(transport: RecordingTransport(reply: Self.peopleReply)).guestList()
        let nike = try XCTUnwrap(listing.guests.first { $0.guestID == "g-n1" })
        XCTAssertTrue(nike.accountBound)
        XCTAssertEqual(nike.person, "acct-nike")
        XCTAssertEqual(nike.devices, [
            GuestDevice(fingerprint: "SHA256:bbbb", device: "MacBook", addedMs: 200, lastSeenMs: 500),
            GuestDevice(fingerprint: "SHA256:cccc", device: "Browser (Chrome on macOS)", addedMs: 300, removed: true),
        ])
        XCTAssertEqual(nike.usableDevices.map(\.fingerprint), ["SHA256:aaaa", "SHA256:bbbb"],
                       "the accepting device first, and never a removed one")
        XCTAssertEqual(nike.usableDevices.first?.lastSeenMs, 900,
                       "the share was used after every added device, so by the accepting one")

        let old = try XCTUnwrap(listing.guests.first { $0.guestID == "g-old" })
        XCTAssertFalse(old.accountBound)
        XCTAssertNil(old.person)
        XCTAssertEqual(old.devices, [])
        XCTAssertEqual(old.usableDevices, [GuestDevice(fingerprint: "SHA256:eeee", device: "iPad", addedMs: 10)])
    }

    func testAnAddedDevicesUseIsNotTheAcceptingDevices() {
        let share = GuestRecord(
            guestID: "g1", name: "Nike", fingerprint: "SHA256:aaaa", device: "iPhone", grant: nil,
            createdMs: 100, lastSeenMs: 500, accountBound: true, person: "acct",
            devices: [GuestDevice(fingerprint: "SHA256:bbbb", device: "MacBook", addedMs: 200, lastSeenMs: 500)])
        XCTAssertNil(share.usableDevices[0].lastSeenMs,
                     "the MacBook stamped the share's last use, so the iPhone's is unknown")
        XCTAssertEqual(share.usableDevices[1].lastSeenMs, 500)
    }

    func testARemovedAcceptingDeviceLeavesOnlyTheOthers() {
        let share = GuestRecord(
            guestID: "g1", name: "Nike", fingerprint: "SHA256:aaaa", device: "iPhone", grant: nil,
            createdMs: 100, lastSeenMs: 500, accountBound: true, person: "acct",
            devices: [GuestDevice(fingerprint: "SHA256:bbbb", device: "MacBook", addedMs: 200),
                      GuestDevice(fingerprint: "SHA256:aaaa", device: "iPhone", addedMs: 100, removed: true)])
        XCTAssertEqual(share.usableDevices.map(\.fingerprint), ["SHA256:bbbb"])
    }

    func testPeopleGroupEveryShareOfOnePersonAndMergeTheirDevices() async throws {
        let listing = try await HerdrClient(transport: RecordingTransport(reply: Self.peopleReply)).guestList()
        let people = listing.people
        XCTAssertEqual(people.map(\.name), ["Nike", "sam", "old"], "most recently seen first; revoked shares drop out")

        let nike = people[0]
        XCTAssertTrue(nike.accountBound)
        XCTAssertEqual(nike.grants.map(\.guestID), ["g-n1", "g-n2"], "oldest share first")
        XCTAssertEqual(nike.devices, [
            GuestDevice(fingerprint: "SHA256:aaaa", device: "iPhone", addedMs: 100, lastSeenMs: 900),
            GuestDevice(fingerprint: "SHA256:bbbb", device: "MacBook", addedMs: 150, lastSeenMs: 500),
        ], "one entry per device across both shares; the removed browser is not listed")
        XCTAssertEqual(nike.lastSeenMs, 900)
        XCTAssertEqual(nike.lastSeenDevice?.device, "iPhone")
        XCTAssertEqual(nike.revokeTargets, [.person("acct-nike")], "Remove Nike is one guest.revoke {person}")
        XCTAssertEqual(nike.grantsHolding(fingerprint: "SHA256:bbbb").map(\.guestID), ["g-n1", "g-n2"],
                       "a device goes from every share it may use")
        XCTAssertEqual(nike.grantsHolding(fingerprint: "SHA256:cccc").map(\.guestID), [])

        let sam = people[1]
        XCTAssertFalse(sam.accountBound)
        XCTAssertEqual(sam.devices.map(\.device), ["iPhone"])
        XCTAssertEqual(sam.revokeTargets, [.guest("g-sam")], "a plain guest is revoked by its guest id")
        XCTAssertEqual(sam.grantsHolding(fingerprint: "SHA256:dddd").map(\.guestID), [],
                       "a plain share has no device to remove")

        XCTAssertEqual(people[2].id, "SHA256:eeee", "an older daemon's share groups by its device key")
        XCTAssertEqual(people[2].revokeTargets, [.guest("g-old")])
    }

    // MARK: guest.audit

    func testAuditClampsTheLimitAndOmitsUnsetFilters() async throws {
        let t = RecordingTransport(reply: #"{"id":"x","result":{"type":"guest_audit","entries":[]}}"#)
        let client = HerdrClient(transport: t)

        _ = try await client.guestAudit(limit: 10_000)
        var params = try t.last().params
        XCTAssertEqual(try t.last().method, "guest.audit")
        XCTAssertEqual(params["limit"] as? Int, 500, "the daemon rejects a page above 500")
        XCTAssertNil(params["guest_id"])
        XCTAssertNil(params["before_ms"])
        XCTAssertNil(params["machine"])

        _ = try await client.guestAudit(guestID: "g1", limit: 0, beforeMs: 1234, machine: "peer")
        params = try t.last().params
        XCTAssertEqual(params["limit"] as? Int, 1)
        XCTAssertEqual(params["guest_id"] as? String, "g1")
        XCTAssertEqual(params["before_ms"] as? Int, 1234)
        XCTAssertEqual(params["machine"] as? String, "peer")
    }

    func testAuditDecodesEveryEventShapeAndKeepsUnknownEvents() async throws {
        let reply = #"""
        {"id":"x","result":{"type":"guest_audit","entries":[
         {"ts_ms":5,"guest_id":"g-n1","name":"Nike","fingerprint":"SHA256:cccc","event":"device_added",
          "pane":"t7","text":"Browser (Chrome on macOS)"},
         {"ts_ms":4,"guest_id":"g-n1","name":"Nike","fingerprint":"SHA256:cccc","event":"device_removed","pane":"t7"},
         {"ts_ms":3,"guest_id":"g1","name":"plotarmordev","fingerprint":"SHA256:9f3a·e71c·04bd·c21e","event":"upload",
          "pane":"w1:p1","file":{"name":"prompt-set-v2.jsonl","size":49152,"sha256":"ab"}},
         {"ts_ms":2,"guest_id":"g1","name":"plotarmordev","event":"prompt","pane":"w1:p1","text":"rerun the bench"},
         {"ts_ms":1,"guest_id":"g1","name":"plotarmordev","event":"denied","method":"pane.send_keys"},
         {"ts_ms":0,"event":"quarantined","new":1}]}}
        """#
        let entries = try await HerdrClient(transport: RecordingTransport(reply: reply)).guestAudit()
        XCTAssertEqual(entries.map(\.event),
                       [.deviceAdded, .deviceRemoved, .upload, .prompt, .denied, .other("quarantined")])
        XCTAssertEqual(entries[0].text, "Browser (Chrome on macOS)", "a device_added entry names the device")
        XCTAssertEqual(entries[0].fingerprint, "SHA256:cccc")
        XCTAssertEqual(entries[2].file, GuestAuditFile(name: "prompt-set-v2.jsonl", size: 49152, sha256: "ab"))
        XCTAssertEqual(entries[3].text, "rerun the bench")
        XCTAssertEqual(entries[4].method, "pane.send_keys")
        XCTAssertNil(entries[5].guestID)
    }

    // MARK: Which machines Settings reads

    private func saved(_ json: String) throws -> [SavedMachineStatus] {
        let wrapped = try JSONDecoder().decode([String: SavedMachineStatus].self, from: Data(json.utf8))
        return Array(wrapped.values)
    }

    /// A saved machine running no agents still holds guests: it must be read (and so be
    /// revocable) even though no agent names it. And a peer only known from its agents (an
    /// older daemon without `machine.status`) must not drop out either.
    func testDirectoryIsTheUnionOfSavedMachinesAndAgentPeers() throws {
        let savedMachines = try saved(#"""
        {"aa":{"profile_id":"aa","display_label":"mcb-air","saved_state":"coordinated","stale":false},
         "bb":{"profile_id":"bb","display_label":"pi-burj","saved_state":"coordinated","stale":false}}
        """#)
        let peers = [
            PeerSummary(alias: "bb", label: "stale-label", agentCount: 2, reachability: .reachable),
            PeerSummary(alias: "cc", label: nil, agentCount: 1, reachability: .degraded),
        ]
        let directory = GuestMachine.directory(localLabel: "Jerry's Mac Studio",
                                               savedMachines: savedMachines, agentPeers: peers)
        XCTAssertEqual(directory, [
            GuestMachine(alias: nil, label: "Jerry's Mac Studio"),
            GuestMachine(alias: "cc", label: "cc"),
            GuestMachine(alias: "aa", label: "mcb-air"),
            GuestMachine(alias: "bb", label: "pi-burj"),
        ], "every machine exactly once, the connected one first, saved labels over agent-derived ones")
    }

    /// A saved profile that has not opted into federation is not a peer: asking it for guests
    /// would only surface a routing failure in Settings. It still keeps its saved label if its
    /// agents already name it.
    func testDirectorySkipsSavedMachinesThatAreNotFederated() throws {
        let savedMachines = try saved(#"""
        {"aa":{"profile_id":"aa","display_label":"mcb-air","saved_state":"coordinated","stale":false},
         "dd":{"profile_id":"dd","display_label":"pi-tv","saved_state":"saved","federation_configured":false,"stale":false},
         "ee":{"profile_id":"ee","display_label":"joltra","saved_state":"saved","federation_configured":false,"stale":false}}
        """#)
        let peers = [PeerSummary(alias: "ee", label: "old", agentCount: 1, reachability: .reachable)]
        let directory = GuestMachine.directory(localLabel: "box", savedMachines: savedMachines,
                                               agentPeers: peers)
        XCTAssertEqual(directory, [
            GuestMachine(alias: nil, label: "box"),
            GuestMachine(alias: "ee", label: "joltra"),
            GuestMachine(alias: "aa", label: "mcb-air"),
        ], "an unfederated saved profile is read only when its agents already name it")
    }

    func testDirectoryWithoutPeersIsJustTheConnectedMachine() {
        XCTAssertEqual(GuestMachine.directory(localLabel: "box", savedMachines: [], agentPeers: []),
                       [GuestMachine(alias: nil, label: "box")])
    }
}
