import Foundation
import XCTest
@testable import HerdrKit

/// herdrup#552: folders and stars. The list's grouping and sorting rules, the document edits,
/// and the `agent.groups.*` client calls.
final class AgentGroupsTests: XCTestCase {
    private func agent(_ name: String, _ status: String) throws -> AgentInfo {
        let object: [String: Any] = ["pane_id": "p-\(name)", "name": name, "agent_status": status]
        return try JSONDecoder().decode(AgentInfo.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// The list for `agents` (name → wire status); names in `stopped` are panes that are gone.
    private func list(_ agents: [(String, String)], stopped: Set<String> = []) throws -> AgentList {
        let infos = try agents.map { try agent($0.0, $0.1) }
        let live = Set(infos.filter { !stopped.contains($0.name ?? "") }.map(\.paneID))
        return AgentList(agents: infos, livePaneIDs: live)
    }

    private func names(_ section: AgentFolderLayout.Section) -> [String] {
        section.items.map { item in
            switch item {
            case .agent(let row, let starred, let folderID):
                (folderID == nil ? "" : "  ") + (row.info.name ?? "") + (starred ? "*" : "")
            case .folder(let summary):
                "[\(summary.folder.name)]"
            }
        }
    }

    /// Within a state the list orders by pane id here (no turn times), so alphabetically.
    private let roster: [(String, String)] = [
        ("jarvis", "blocked"), ("vetrina", "blocked"), ("enyo-review", "blocked"),
        ("enyo-efm", "idle"), ("enyo", "working"), ("enyo-scout", "idle"),
        ("trend-scout", "idle"), ("herdr-app", "working"), ("herdr-ios", "working"),
    ]

    private var enyo: AgentFolder {
        AgentFolder(id: "f-enyo", name: "Enyo", order: 0,
                    members: ["enyo-review", "enyo-efm", "enyo", "enyo-scout"])
    }

    // MARK: layout

    func testStarredAgentGoesFirstWithinItsState() throws {
        let list = try list(roster)
        let doc = AgentGroupsDocument(stars: ["vetrina", "herdr-ios"])
        let layout = AgentFolderLayout(sections: list.sections, groups: doc, openFolders: [])
        XCTAssertEqual(layout.sections.map(\.group), [.needsYou, .working, .idle])
        XCTAssertEqual(names(layout.sections[0]), ["vetrina*", "enyo-review", "jarvis"],
                       "a starred agent that needs you is the very first row")
        XCTAssertEqual(names(layout.sections[1]), ["herdr-ios*", "enyo", "herdr-app"])
        XCTAssertEqual(names(layout.sections[2]), ["enyo-efm", "enyo-scout", "trend-scout"],
                       "stars sort within a state, not above everything")
    }

    func testClosedFolderSitsInItsMostUrgentStateAndCountsItsAgents() throws {
        let list = try list(roster, stopped: ["enyo-efm"])
        let doc = AgentGroupsDocument(folders: [enyo])
        let layout = AgentFolderLayout(sections: list.sections, groups: doc, openFolders: [])
        XCTAssertEqual(names(layout.sections[0]), ["[Enyo]", "jarvis", "vetrina"],
                       "the folder comes before the loose waiting rows; its agents leave their sections")
        XCTAssertFalse(layout.sections.flatMap(names).contains { $0.contains("enyo-") },
                       "a closed folder shows no agents")
        XCTAssertEqual(layout.sections[0].agentCount, 6)
        guard case .folder(let summary) = try XCTUnwrap(layout.sections[0].items.first) else {
            return XCTFail("expected the folder row first")
        }
        XCTAssertEqual(summary.waitingCount, 1, "a closed folder still shows who waits")
        XCTAssertEqual(summary.stoppedCount, 1)
        XCTAssertEqual(summary.agentCountText, "4 agents")
        XCTAssertEqual(summary.summaryLine, "enyo-review needs you · enyo-efm stopped")
        XCTAssertEqual(summary.members.map(\.title), ["enyo-review", "enyo-efm", "enyo", "enyo-scout"],
                       "members most urgent first")
    }

    func testOpenFolderListsItsAgentsIndentedUnderIt() throws {
        let list = try list(roster)
        let doc = AgentGroupsDocument(folders: [enyo], stars: ["enyo-scout"])
        let layout = AgentFolderLayout(sections: list.sections, groups: doc, openFolders: ["f-enyo"])
        XCTAssertEqual(names(layout.sections[0]),
                       ["[Enyo]", "  enyo-review", "  enyo", "  enyo-scout*", "  enyo-efm", "jarvis", "vetrina"])
    }

    func testFolderOfIdleAgentsSitsInIdleAndFoldersFollowTheirOrder() throws {
        let list = try list(roster)
        let quiet = AgentFolder(id: "f-quiet", name: "Quiet", order: 1, members: ["trend-scout"])
        let herdr = AgentFolder(id: "f-herdr", name: "Herdr", order: 0, members: ["herdr-app", "herdr-ios"])
        let docks = AgentFolder(id: "f-docks", name: "Docks", order: 2, members: ["enyo"])
        let doc = AgentGroupsDocument(folders: [quiet, docks, herdr])
        let layout = AgentFolderLayout(sections: list.sections, groups: doc, openFolders: [])
        XCTAssertEqual(layout.sections.map(\.group), [.needsYou, .working, .idle])
        XCTAssertEqual(names(layout.sections[1]), ["[Herdr]", "[Docks]"],
                       "a state section of only folders, in folder order")
        XCTAssertEqual(names(layout.sections[2]), ["[Quiet]", "enyo-efm", "enyo-scout"],
                       "a folder sits above the idle agents, not at the bottom of the section")
    }

    /// Owner report 2026-10-28: a folder of idle agents sank below every idle agent. With no
    /// turn times (all tied), a folder still goes before the other agents of its section.
    func testOnATieAFolderSortsAfterStarredAgentsAndBeforeTheRestOfItsSection() throws {
        let list = try list(roster)
        let review = AgentFolder(id: "f-review", name: "Review", order: 0, members: ["enyo-review"])
        let quiet = AgentFolder(id: "f-quiet", name: "Quiet", order: 1, members: ["trend-scout"])
        let doc = AgentGroupsDocument(folders: [quiet, review], stars: ["vetrina", "enyo-scout"])
        let layout = AgentFolderLayout(sections: list.sections, groups: doc, openFolders: ["f-quiet"])
        XCTAssertEqual(layout.sections.map(\.group), [.needsYou, .working, .idle])
        XCTAssertEqual(names(layout.sections[0]), ["vetrina*", "[Review]", "jarvis"],
                       "starred agents, then the folder, then the other agents")
        XCTAssertEqual(names(layout.sections[2]), ["enyo-scout*", "[Quiet]", "  trend-scout", "enyo-efm"],
                       "an open folder's agents follow it, before the unstarred agents")
        XCTAssertEqual(layout.sections.map(\.agentCount), [3, 3, 3])
    }

    /// Owner report 2026-11-01: folders sat pinned at the top of their state. A folder now
    /// sorts among its section's other agents by its most recently active agent.
    func testFolderSortsByItsMostRecentAgentAmongTheOtherAgents() throws {
        func idle(_ name: String, _ completedMs: Int64) throws -> AgentInfo {
            let object: [String: Any] = ["pane_id": "p-\(name)", "name": name, "agent_status": "idle",
                                         "last_completed_turn": ["completed_unix_ms": completedMs]]
            return try JSONDecoder().decode(AgentInfo.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let infos = try [idle("fresh", 900), idle("mid", 500), idle("old", 100),
                         idle("docs-a", 300), idle("docs-b", 600), idle("ops-a", 50),
                         idle("pinned", 10)]
        let list = AgentList(agents: infos, livePaneIDs: Set(infos.map(\.paneID)))
        let docs = AgentFolder(id: "f-docs", name: "Docs", order: 0, members: ["docs-a", "docs-b"])
        let ops = AgentFolder(id: "f-ops", name: "Ops", order: 1, members: ["ops-a"])
        let doc = AgentGroupsDocument(folders: [docs, ops], stars: ["pinned"])
        let layout = AgentFolderLayout(sections: list.sections, groups: doc, openFolders: ["f-docs"])
        XCTAssertEqual(names(layout.sections[0]),
                       ["pinned*", "fresh", "[Docs]", "  docs-b", "  docs-a", "mid", "old", "[Ops]"],
                       "starred first; then newest first, a folder at its newest agent (docs-b, 600)")
        XCTAssertEqual(layout.sections[0].agentCount, 7)
    }

    func testFolderWithNoAgentHereIsKeptAsEmpty() throws {
        let list = try list(roster)
        let gone = AgentFolder(id: "f-gone", name: "Old", order: 0, members: ["retired"])
        let layout = AgentFolderLayout(sections: list.sections, groups: AgentGroupsDocument(folders: [gone]),
                                       openFolders: ["f-gone"])
        XCTAssertEqual(layout.emptyFolders.map(\.folder.id), ["f-gone"])
        XCTAssertEqual(layout.emptyFolders.first?.summaryLine, "empty")
        XCTAssertEqual(layout.sections.flatMap(\.items).count, roster.count)
    }

    func testNoDocumentLeavesTheListAsItWas() throws {
        let list = try list(roster)
        let layout = AgentFolderLayout(sections: list.sections, groups: nil, openFolders: [])
        XCTAssertEqual(layout.sections.map { $0.items.map(\.id) }, list.sections.map { $0.rows.map(\.id) })
    }

    func testSummaryLineWordsSeveralAgents() throws {
        let list = try list([("a", "blocked"), ("b", "blocked"), ("c", "blocked"), ("d", "working")])
        let rows = list.rows
        func line(_ names: Set<String>) -> String {
            AgentFolderSummary(folder: AgentFolder(id: "f", name: "F", order: 0, members: []),
                               members: rows.filter { names.contains($0.title) }, isOpen: false).summaryLine
        }
        XCTAssertEqual(line(["a", "b"]), "a and b need you")
        XCTAssertEqual(line(["a", "b", "c"]), "3 need you")
        XCTAssertEqual(line(["d"]), "1 working")
    }

    // MARK: document edits

    func testEditsKeepAnAgentInOneFolderAndRenumberOnReorder() {
        var doc = AgentGroupsDocument(folders: [enyo])
        doc.addFolder(id: "f-new", name: "Scouts", member: "enyo-scout")
        XCTAssertEqual(doc.folder(containing: "enyo-scout")?.id, "f-new", "moved out of Enyo")
        XCTAssertFalse(doc.folders[0].members.contains("enyo-scout"))
        XCTAssertEqual(doc.folders[1].order, 1)

        doc.move("enyo-scout", toFolder: "f-missing")
        XCTAssertEqual(doc.folder(containing: "enyo-scout")?.id, "f-new", "a vanished folder moves nothing")

        doc.moveFolder("f-new", by: -1)
        XCTAssertEqual(doc.orderedFolders.map(\.id), ["f-new", "f-enyo"])
        XCTAssertEqual(doc.orderedFolders.map(\.order), [0, 1])

        doc.setStar("jarvis", true)
        doc.setStar("jarvis", true)
        XCTAssertEqual(doc.stars, ["jarvis"], "starring twice stars once")
        doc.setStar("jarvis", false)
        XCTAssertFalse(doc.isStarred("jarvis"))

        doc.deleteFolder("f-enyo")
        XCTAssertNil(doc.folder(containing: "enyo"), "a deleted folder's agents go back to the list")
        XCTAssertEqual(AgentGroupsDocument.folderName("  "), nil)
        XCTAssertEqual(AgentGroupsDocument.folderName(String(repeating: "x", count: 80))?.count, 64)
    }

    // MARK: saving an edit

    /// A stand-in for `agent.groups.set`: refuses a stale revision with the current document,
    /// otherwise stores the document under the next revision.
    private actor FakeGroupsServer {
        var current: AgentGroupsDocument
        private(set) var sets: [AgentGroupsDocument] = []
        /// Every set is refused as stale (another device always saved first).
        private var alwaysConflict = false

        init(_ current: AgentGroupsDocument) { self.current = current }

        func setAlwaysConflict() { alwaysConflict = true }

        func set(_ document: AgentGroupsDocument) throws -> AgentGroupsDocument {
            sets.append(document)
            if alwaysConflict {
                current.revision += 1
                throw AgentGroupsError.conflict(current: current)
            }
            guard document.revision == current.revision else {
                throw AgentGroupsError.conflict(current: current)
            }
            current = document
            current.revision += 1
            return current
        }
    }

    func testEditIsSavedOnTheDocumentItWasMadeOn() async throws {
        let base = AgentGroupsDocument(revision: 4, folders: [enyo])
        let server = FakeGroupsServer(base)
        let saved = try await AgentGroupsDocument.commit(.setStar("jarvis", true), onto: base) {
            try await server.set($0)
        }
        XCTAssertEqual(saved.revision, 5)
        XCTAssertEqual(saved.stars, ["jarvis"])
        let sets = await server.sets
        XCTAssertEqual(sets.count, 1)
    }

    func testConflictReappliesTheEditOntoTheCurrentDocumentOnce() async throws {
        // This device saw revision 4; another device has since starred herdr-app and renamed
        // the folder (revision 5). This device takes enyo-scout out of the folder.
        let seen = AgentGroupsDocument(revision: 4, folders: [enyo], stars: ["vetrina"])
        var theirs = seen
        theirs.revision = 5
        theirs.setStar("herdr-app", true)
        theirs.renameFolder("f-enyo", to: "Enyo team")
        let server = FakeGroupsServer(theirs)

        let saved = try await AgentGroupsDocument.commit(.removeFromFolder("enyo-scout"), onto: seen) {
            try await server.set($0)
        }
        let sets = await server.sets
        XCTAssertEqual(sets.map(\.revision), [4, 5], "the stale set, then one replay on the current revision")
        XCTAssertEqual(saved.revision, 6)
        XCTAssertEqual(saved.folders.map(\.members), [["enyo-review", "enyo-efm", "enyo"]], "this device's edit")
        XCTAssertEqual(saved.folders.map(\.name), ["Enyo team"], "the other device's rename is kept")
        XCTAssertEqual(saved.stars, ["vetrina", "herdr-app"], "and so is its star")
    }

    func testConflictReplayKeepsAStarIdempotent() async throws {
        // Both devices starred jarvis: replaying the star must not unstar it.
        let seen = AgentGroupsDocument(revision: 1)
        let server = FakeGroupsServer(AgentGroupsDocument(revision: 2, stars: ["jarvis"]))
        let saved = try await AgentGroupsDocument.commit(.setStar("jarvis", true), onto: seen) {
            try await server.set($0)
        }
        XCTAssertEqual(saved.stars, ["jarvis"])
        XCTAssertEqual(saved.revision, 2, "nothing left to change: the current document is the answer")
        let sets = await server.sets
        XCTAssertEqual(sets.count, 1, "no second set for an edit the current document already has")
    }

    func testSecondConflictIsThrownWithTheNewestDocument() async throws {
        let seen = AgentGroupsDocument(revision: 1)
        let server = FakeGroupsServer(AgentGroupsDocument(revision: 1))
        await server.setAlwaysConflict()
        do {
            _ = try await AgentGroupsDocument.commit(.addFolder(id: "f", name: "F", member: nil), onto: seen) {
                try await server.set($0)
            }
            XCTFail("expected the second conflict to be thrown")
        } catch AgentGroupsError.conflict(let current) {
            XCTAssertEqual(current.revision, 3)
        }
        let sets = await server.sets
        XCTAssertEqual(sets.count, 2, "re-applied once, not retried forever")
    }

    func testEditToAFolderDeletedElsewhereChangesNothing() async throws {
        let seen = AgentGroupsDocument(revision: 1, folders: [enyo])
        let server = FakeGroupsServer(AgentGroupsDocument(revision: 2))
        let saved = try await AgentGroupsDocument.commit(.renameFolder("f-enyo", to: "Enyo 2"), onto: seen) {
            try await server.set($0)
        }
        XCTAssertEqual(saved, AgentGroupsDocument(revision: 2), "the folder is gone; the server's document stands")
    }

    // MARK: client

    private let documentJSON = #"{"type":"agent_groups","revision":7,"folders":[{"id":"f1","name":"Enyo","order":0,"members":["enyo"]}],"stars":["jarvis"]}"#

    func testGetAndSetRoundTripTheDocument() async throws {
        let transport = RecordingTransport(reply: #"{"id":"x","result":\#(documentJSON)}"#)
        let client = HerdrClient(transport: transport)
        let doc = try await client.agentGroupsGet()
        XCTAssertEqual(doc, AgentGroupsDocument(
            revision: 7, folders: [AgentFolder(id: "f1", name: "Enyo", order: 0, members: ["enyo"])], stars: ["jarvis"]))
        XCTAssertEqual(try transport.last().method, "agent.groups.get")

        _ = try await client.agentGroupsSet(doc)
        let sent = try transport.last()
        XCTAssertEqual(sent.method, "agent.groups.set")
        XCTAssertEqual(sent.params["revision"] as? Int, 7)
        XCTAssertEqual(sent.params["stars"] as? [String], ["jarvis"])
        let folders = try XCTUnwrap(sent.params["folders"] as? [[String: Any]])
        XCTAssertEqual(folders.first?["members"] as? [String], ["enyo"])
    }

    func testConflictCarriesTheCurrentDocument() async throws {
        let reply = #"{"id":"x","error":{"code":"groups_conflict","message":"stale revision","current":\#(documentJSON)}}"#
        let client = HerdrClient(transport: RecordingTransport(reply: reply))
        do {
            _ = try await client.agentGroupsSet(AgentGroupsDocument(revision: 3))
            XCTFail("expected a conflict")
        } catch AgentGroupsError.conflict(let current) {
            XCTAssertEqual(current.revision, 7)
            XCTAssertEqual(current.stars, ["jarvis"])
        }
    }

    func testRefusalsMapToTheirErrors() async throws {
        let cases: [(String, AgentGroupsError)] = [
            ("invalid_groups", .invalid("name too long")),
            ("guest_forbidden", .forbidden),
            ("unknown_method", .unsupported),
        ]
        for (code, expected) in cases {
            let client = HerdrClient(transport: RecordingTransport.error(code: code, message: "name too long"))
            do {
                _ = try await client.agentGroupsGet()
                XCTFail("expected \(code) to throw")
            } catch let error as AgentGroupsError {
                XCTAssertEqual(error, expected)
            }
        }
    }

    func testCapabilityIsReadFromPing() throws {
        let caps = try JSONDecoder().decode(ServerCapabilities.self, from: Data(#"{"agent_groups":true}"#.utf8))
        XCTAssertTrue(caps.agentGroups)
        let old = try JSONDecoder().decode(ServerCapabilities.self, from: Data("{}".utf8))
        XCTAssertFalse(old.agentGroups, "an older daemon hides folders")
    }
}
