#if DEBUG
import Foundation
import HerdrKit
import SwiftUI

/// The owner's guest-access screens over canned daemon answers (`HERDR_SCREENSHOT_MOCK=share`
/// for the pane and its share sheet, `sharedaccess` for Settings). The guest store is stateful
/// for the whole process, so a UI test sees its own invite, revoke or cancel land.
///
/// Launch environment:
/// - `HERDR_MOCK_OWNER_NAME`: preset "Your name"; `-` clears it to exercise the first-share ask.
/// - `HERDR_MOCK_GUEST_INVITE=1`: start with one pending invite (for "sam").
/// - `HERDR_MOCK_SAVED_PEER_GUEST=1`: the agent-less saved machine mcb-air holds guest `sam`.
/// - `HERDR_MOCK_AUDIT_FAIL=1`: the connected machine's `guest.audit` fails.
/// - `HERDR_MOCK_STILL=1`: llm-opt reads idle instead of working. The WORKING pill pulses
///   forever, which holds XCUITest's wait-for-idle for a minute per action; only the
///   screenshot capture keeps the design's WORKING state.
enum GuestShareMock {
    static let machineLabel = "Jerry's Mac Studio"
    static let peerAlias = "2cc0ffe3a0753cafcf28f46a7bb29351"
    /// A saved machine that is federated but runs no agents right now, so nothing in
    /// `agent.list` names it; only `machine.status` does.
    static let savedPeerAlias = "5b7e1d20c4a94f3e8d6b0a1c2e3f4a5b"

    static let agentStatus = ProcessInfo.processInfo.environment["HERDR_MOCK_STILL"] == "1" ? "idle" : "working"

    static let agent: AgentInfo = decodeAgent(
        #"{"pane_id":"w1:p1","terminal_id":"t-llm","name":"llm-opt","agent":"omp","agent_status":"\#(agentStatus)","cwd":"/Users/jerry/repos"}"#)

    /// A federated agent, so Settings reads a second guest store through the coordinator.
    static let peerAgent: AgentInfo = decodeAgent(
        #"{"pane_id":"2cc0ffe3a0753cafcf28f46a7bb29351/w1:p2","terminal_id":"2cc0ffe3a0753cafcf28f46a7bb29351/t-voice","name":"2cc0ffe3a0753cafcf28f46a7bb29351/voice","machine_id":"2cc0ffe3a0753cafcf28f46a7bb29351","machine_label":"pi-burj","agent":"claude","agent_status":"idle","cwd":"/home/pi/voice"}"#)

    private static func decodeAgent(_ json: String) -> AgentInfo {
        // The fixture is a literal; a decode failure is a programming error in this file.
        try! JSONDecoder().decode(AgentInfo.self, from: Data(json.utf8))
    }

    /// Applies the launch environment to the app's own storage, once per process.
    @MainActor static func prepare() {
        guard !prepared else { return }
        prepared = true
        let env = ProcessInfo.processInfo.environment
        switch env["HERDR_MOCK_OWNER_NAME"] {
        case "-"?: UserDefaults.standard.removeObject(forKey: GuestOwnerName.storageKey)
        case let name?: UserDefaults.standard.set(name, forKey: GuestOwnerName.storageKey)
        case nil: break
        }
    }
    @MainActor private static var prepared = false

    @MainActor
    static func paneView() -> some View {
        prepare()
        return NavigationStack {
            TerminalPaneContent(client: HerdrClient(transport: GuestShareMockTransport()),
                                paneID: agent.paneID, title: "llm-opt", agent: agent)
        }
        .environment(\.guestMachineLabel, machineLabel)
    }

    @MainActor
    static func settingsView() -> some View {
        prepare()
        return SettingsView(mode: .owner(HerdrClient(transport: GuestShareMockTransport())),
                            agents: [agent, peerAgent], host: "studio.tail-scale.ts.net")
            .environment(\.guestMachineLabel, machineLabel)
    }
}

/// The guest stores the mock daemons keep, one per machine (`""` is the connected machine):
/// the local machine starts with plotarmordev on llm-opt and three log lines; pi-burj (an
/// agent-derived peer) starts empty; mcb-air, a saved machine with NO agents, holds `sam`
/// when `HERDR_MOCK_SAVED_PEER_GUEST=1`.
final class GuestShareMockStore: @unchecked Sendable {
    static let shared = GuestShareMockStore()

    private struct Machine {
        var guests: [[String: Any]] = []
        var invites: [[String: Any]] = []
        var audit: [[String: Any]] = []
    }

    private let lock = NSLock()
    private var machines: [String: Machine] = [:]
    private var inviteSeq = 0
    /// `HERDR_MOCK_AUDIT_FAIL=1`: the connected machine's `guest.audit` fails.
    private let auditFails = ProcessInfo.processInfo.environment["HERDR_MOCK_AUDIT_FAIL"] == "1"

    private static let fingerprint = "SHA256:9f3a·e71c·04bd·c21e"
    private static let grant: [String: Any] = ["terminal_id": "t-llm", "agent_name": "llm-opt",
                                               "agent_session": ["source": "hook", "agent": "omp", "kind": "session_id", "value": "s1"]]

    private init() {
        let env = ProcessInfo.processInfo.environment
        let now = Date()
        let nowMs = Self.ms(now)
        // Today's 11:40 / 11:42 / 11:44, as in the design, so the log reads like it.
        func today(_ hour: Int, _ minute: Int) -> UInt64 {
            let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
            return Self.ms(date)
        }
        var local = Machine()
        local.guests = [[
            "guest_id": "g-plot", "name": "plotarmordev", "fingerprint": Self.fingerprint,
            "device": "iPhone", "grant": Self.grant, "created_ms": today(11, 40),
            "last_seen_ms": nowMs - 2 * 60 * 1000, "revoked": false,
        ]]
        local.audit = [
            Self.entry(today(11, 44), "upload", extra: ["file": ["name": "prompt-set-v2.jsonl", "size": 49_152, "sha256": "5e1f"]]),
            Self.entry(today(11, 42), "prompt", extra: ["text": "can you rerun the TensorFold bench against our Q5 build and send me the table?"]),
            Self.entry(today(11, 40), "accepted"),
        ]
        if env["HERDR_MOCK_GUEST_INVITE"] == "1" {
            local.invites.append(Self.invite(id: "inv-sam", name: "sam", createdMs: nowMs - 60_000))
        }
        machines[""] = local
        machines[GuestShareMock.peerAlias] = Machine()
        var saved = Machine()
        if env["HERDR_MOCK_SAVED_PEER_GUEST"] == "1" {
            saved.guests = [[
                "guest_id": "g-sam", "name": "sam", "fingerprint": "SHA256:51c0·2ab9·7e04·d3f8",
                "device": "iPad", "grant": ["terminal_id": "t-notes", "agent_name": "notes"],
                "created_ms": nowMs - 3_600_000, "last_seen_ms": NSNull(), "revoked": false,
            ]]
        }
        machines[GuestShareMock.savedPeerAlias] = saved
    }

    private static func ms(_ date: Date) -> UInt64 { UInt64(date.timeIntervalSince1970 * 1000) }

    private static func entry(_ ts: UInt64, _ event: String, guestID: String = "g-plot",
                              name: String = "plotarmordev", extra: [String: Any] = [:]) -> [String: Any] {
        var e: [String: Any] = ["ts_ms": ts, "guest_id": guestID, "name": name,
                                "fingerprint": fingerprint, "event": event, "pane": "w1:p1"]
        e.merge(extra) { _, new in new }
        return e
    }

    private static func invite(id: String, name: String, createdMs: UInt64, shareGram: Bool = false) -> [String: Any] {
        ["invite_id": id, "name": name, "grant": grant, "owner_name": "Jerry",
         "machine_label": GuestShareMock.machineLabel, "created_ms": createdMs,
         "expires_ms": createdMs + 24 * 3600 * 1000, "used_by": NSNull(), "share_gram": shareGram]
    }

    func answer(method: String, params: [String: Any]) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let key = params["machine"] as? String ?? ""
        // The coordinator refuses a machine it has no saved profile for.
        guard var machine = machines[key] else {
            return ["error": ["code": "machine_not_found", "message": "no saved machine \(key)"]]
        }
        defer { machines[key] = machine }
        switch method {
        case "guest.list":
            return ["type": "guest_list", "guests": machine.guests, "invites": machine.invites,
                    "link": ["state": key.isEmpty ? "up" : "off", "last_error": NSNull()]]
        case "guest.audit":
            if auditFails && key.isEmpty {
                return ["error": ["code": "internal", "message": "audit.jsonl is unreadable"]]
            }
            return ["type": "guest_audit", "entries": machine.audit]
        case "guest.invite.create":
            let name = params["name"] as? String ?? ""
            guard GuestName.isValid(name) else {
                return ["error": ["code": "guest_invalid_name", "message": "invalid guest name"]]
            }
            inviteSeq += 1
            let invite = Self.invite(id: "inv-\(inviteSeq)", name: name, createdMs: Self.ms(Date()),
                                     shareGram: params["share_gram"] as? Bool ?? false)
            machine.invites.append(invite)
            let payload = Base64URLMock.encode(#"{"v":1,"invite_id":"inv-\#(inviteSeq)","guest_name":"\#(name)","agent_name":"llm-opt"}"#)
            // An older daemon's '#' web link, which the invite sheet shares in the path form.
            return ["type": "guest_invite", "invite": invite,
                    "url": "herdrup://guest-invite#\(payload)",
                    "web_url": "https://guest.herdrup.app/i/\(payload)"]
        case "guest.update":
            guard let id = params["guest_id"] as? String,
                  let index = machine.guests.firstIndex(where: { $0["guest_id"] as? String == id }),
                  let share = params["share_gram"] as? Bool else {
                return ["error": ["code": "guest_not_found", "message": "no such guest"]]
            }
            machine.guests[index]["share_gram"] = share
            return ["type": "ok"]
        case "guest.revoke":
            if let id = params["guest_id"] as? String,
               let index = machine.guests.firstIndex(where: { $0["guest_id"] as? String == id }) {
                machine.guests[index]["revoked"] = true
                let name = machine.guests[index]["name"] as? String ?? ""
                machine.audit.insert(Self.entry(Self.ms(Date()), "revoked", guestID: id, name: name), at: 0)
                return ["type": "guest_revoked", "guest_id": id, "closed_streams": 1]
            }
            if let id = params["invite_id"] as? String,
               let index = machine.invites.firstIndex(where: { $0["invite_id"] as? String == id }) {
                machine.invites.remove(at: index)
                return ["type": "guest_revoked", "invite_id": id, "closed_streams": 0]
            }
            return ["error": ["code": "guest_not_found", "message": "no such guest or invite"]]
        default:
            return [:]
        }
    }
}

/// base64url without padding, for the fixture's fake invite payload.
private enum Base64URLMock {
    static func encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Answers `guest.*` from the store, `agent.list` with the share fixtures, and `pane.stream`
/// with llm-opt's screen; everything else falls through to the shared screenshot mock.
struct GuestShareMockTransport: HerdrTransport {
    private let base = MockTransport()

    func roundTrip(_ requestLine: String) async throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(requestLine.utf8)) as? [String: Any],
              let method = object["method"] as? String else {
            return try await base.roundTrip(requestLine)
        }
        if method == "agent.list" { return Self.agentList }
        if method == "machine.status" { return Self.machineStatus }
        guard method.hasPrefix("guest.") else { return try await base.roundTrip(requestLine) }
        let params = object["params"] as? [String: Any] ?? [:]
        let answer = GuestShareMockStore.shared.answer(method: method, params: params)
        let envelope: [String: Any] = answer["error"] != nil
            ? ["id": "mock", "error": answer["error"]!]
            : ["id": "mock", "result": answer]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        return String(decoding: data, as: UTF8.self)
    }

    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        guard requestLine.contains("pane.stream") else { return base.stream(requestLine) }
        return AsyncThrowingStream { continuation in
            continuation.yield(MockWireFixtures.paneStreamAck)
            continuation.yield(Self.resetFrame)
            // Stay open like a live stream; an ended one reads as a drop and reconnects.
            let pings = Task {
                var seq: UInt64 = 1
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    guard !Task.isCancelled else { break }
                    continuation.yield(MockTransport.paneStreamPing(seq: seq, epoch: 7))
                    seq += 1
                }
            }
            continuation.onTermination = { _ in pings.cancel() }
        }
    }

    /// Both peers are saved machines; only pi-burj runs an agent.
    private static let machineStatus = #"""
    {"id":"mock","result":{"type":"machine_status","machines":{
      "2cc0ffe3a0753cafcf28f46a7bb29351":{"profile_id":"2cc0ffe3a0753cafcf28f46a7bb29351","display_label":"pi-burj","saved_state":"coordinated","federation_configured":true,"stale":false},
      "5b7e1d20c4a94f3e8d6b0a1c2e3f4a5b":{"profile_id":"5b7e1d20c4a94f3e8d6b0a1c2e3f4a5b","display_label":"mcb-air","saved_state":"coordinated","federation_configured":true,"stale":false}
    }}}
    """#

    private static let agentList = #"""
    {"id":"mock","result":{"type":"agent_list","agents":[
      {"pane_id":"w1:p1","terminal_id":"t-llm","name":"llm-opt","agent":"omp","agent_status":"\#(GuestShareMock.agentStatus)","cwd":"/Users/jerry/repos"},
      {"pane_id":"2cc0ffe3a0753cafcf28f46a7bb29351/w1:p2","terminal_id":"2cc0ffe3a0753cafcf28f46a7bb29351/t-voice","name":"2cc0ffe3a0753cafcf28f46a7bb29351/voice","machine_id":"2cc0ffe3a0753cafcf28f46a7bb29351","machine_label":"pi-burj","agent":"claude","agent_status":"idle","cwd":"/home/pi/voice"}
    ]}}
    """#

    /// llm-opt's screen from the design: the guest's labelled prompt, then the agent at work.
    private static var resetFrame: String {
        let dim = "\u{1B}[38;5;60m", violet = "\u{1B}[1;38;2;183;168;255m", blue = "\u{1B}[38;2;91;155;232m"
        let bold = "\u{1B}[1m", green = "\u{1B}[38;2;95;179;127m", reset = "\u{1B}[0m"
        let body = [
            "\(dim)~/repos/llm-opt\(reset)",
            "",
            "\(bold)❯ \(reset)\(violet)plotarmordev (via HerdrUp):\(reset) can you rerun the TensorFold bench",
            "  against our Q5 build and send me the table?",
            "",
            "\(blue)●\(reset) Reading bench/tensorfold.sh",
            "\(blue)●\(reset) Running bench/tensorfold.sh --q5 …",
            "    decode   \(bold)41.2 tok/s\(reset)  \(green)(+36%)\(reset)",
            "    prefill  \(bold)1,180 tok/s\(reset)",
            "\(blue)●\(reset) Writing results/tensorfold-q5.md",
        ].joined(separator: "\r\n")
        // Hide the cursor, as the agent's TUI does while it works. A visible cursor blinks
        // forever (SwiftTerm's caret is a repeating animation), so the app never goes idle and
        // every XCUITest action waits out its 60 s idle timeout, which is what pushed the CI
        // iPhone round past its budget. The `scroll` mock hides it for the same reason.
        let b64 = Data(("\u{1B}[2J\u{1B}[H" + body + "\r\n\u{1B}[?25l").utf8).base64EncodedString()
        return #"{"stream":"pane.bytes","frame":"reset","seq":0,"epoch":7,"cols":80,"rows":24,"data_b64":"\#(b64)"}"#
    }
}
#endif
