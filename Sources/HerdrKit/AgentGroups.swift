import Foundation

// Agent folders and stars (herdrup#552), synced through the herdr server's owner store
// (`agent.groups.get` / `agent.groups.set`, capability `agent_groups`). Membership follows
// the agent NAME (the raw `AgentInfo.name`): it survives restarts, and the server moves it
// along when an agent is renamed.

/// One folder: a named, ordered set of agents.
public struct AgentFolder: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var order: Int
    public var members: [String]

    public init(id: String, name: String, order: Int, members: [String]) {
        self.id = id
        self.name = name
        self.order = order
        self.members = members
    }
}

/// The whole owner document. `set` replaces it whole; `revision` is the optimistic-concurrency
/// token (0 before the first set): a set from a stale revision is refused with
/// `groups_conflict`, carrying the current document.
public struct AgentGroupsDocument: Codable, Equatable, Sendable {
    public var revision: UInt64
    public var folders: [AgentFolder]
    public var stars: [String]

    public init(revision: UInt64 = 0, folders: [AgentFolder] = [], stars: [String] = []) {
        self.revision = revision
        self.folders = folders
        self.stars = stars
    }

    /// The server's limit on ids, folder names and agent names, in Unicode characters.
    public static let maxNameLength = 64

    /// A folder name as the server accepts it: trimmed and at most 64 characters. Nil when
    /// nothing is left.
    public static func folderName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxNameLength))
    }

    public func isStarred(_ name: String) -> Bool { stars.contains(name) }

    /// The folder `name` is in, if any. An agent is in at most one folder.
    public func folder(containing name: String) -> AgentFolder? {
        folders.first { $0.members.contains(name) }
    }

    /// Folders in display order.
    public var orderedFolders: [AgentFolder] {
        folders.enumerated()
            .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
            .map(\.element)
    }

    // MARK: edits (pure, so a conflict can replay them onto the server's current document)

    /// Stars or unstars `name`. Idempotent (not a toggle), so replaying it onto a document
    /// another device changed meanwhile keeps what this device asked for.
    public mutating func setStar(_ name: String, _ starred: Bool) {
        stars.removeAll { $0 == name }
        if starred { stars.append(name) }
    }

    /// Puts `name` in the folder `folderID`, taking it out of any other. A missing folder
    /// (deleted on another device meanwhile) leaves the agent where it was.
    public mutating func move(_ name: String, toFolder folderID: String) {
        guard folders.contains(where: { $0.id == folderID }) else { return }
        removeFromFolders(name)
        if let index = folders.firstIndex(where: { $0.id == folderID }) {
            folders[index].members.append(name)
        }
    }

    public mutating func removeFromFolders(_ name: String) {
        for index in folders.indices {
            folders[index].members.removeAll { $0 == name }
        }
    }

    /// A new folder after the others, holding `member` (moved out of any other folder).
    public mutating func addFolder(id: String, name: String, member: String?) {
        let order = (folders.map(\.order).max() ?? -1) + 1
        folders.append(AgentFolder(id: id, name: name, order: order, members: []))
        if let member { move(member, toFolder: id) }
    }

    public mutating func renameFolder(_ folderID: String, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[index].name = name
    }

    /// Deletes the folder; its agents go back to the list.
    public mutating func deleteFolder(_ folderID: String) {
        folders.removeAll { $0.id == folderID }
    }

    /// Moves a folder one place up (`by: -1`) or down (`by: 1`) in the display order and
    /// renumbers every folder 0, 1, 2…
    public mutating func moveFolder(_ folderID: String, by delta: Int) {
        var ordered = orderedFolders
        guard let index = ordered.firstIndex(where: { $0.id == folderID }) else { return }
        let target = index + delta
        guard ordered.indices.contains(target) else { return }
        ordered.swapAt(index, target)
        for position in ordered.indices { ordered[position].order = position }
        folders = ordered
    }

    /// A short random folder id.
    public static func newFolderID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }
}

/// One change the owner makes on this device. Applied to the document the list shows at once,
/// then sent; on `groups_conflict` it is applied again to the server's current document.
public enum AgentGroupsEdit: Equatable, Sendable {
    case setStar(String, Bool)
    case move(String, toFolder: String)
    case removeFromFolder(String)
    case addFolder(id: String, name: String, member: String?)
    case renameFolder(String, to: String)
    case deleteFolder(String)
    case moveFolder(String, by: Int)

    public func apply(to document: inout AgentGroupsDocument) {
        switch self {
        case let .setStar(name, starred): document.setStar(name, starred)
        case let .move(name, folderID): document.move(name, toFolder: folderID)
        case let .removeFromFolder(name): document.removeFromFolders(name)
        case let .addFolder(id, name, member): document.addFolder(id: id, name: name, member: member)
        case let .renameFolder(id, name): document.renameFolder(id, to: name)
        case let .deleteFolder(id): document.deleteFolder(id)
        case let .moveFolder(id, delta): document.moveFolder(id, by: delta)
        }
    }

    public func applied(to document: AgentGroupsDocument) -> AgentGroupsDocument {
        var next = document
        apply(to: &next)
        return next
    }
}

extension AgentGroupsDocument {
    /// Saves `edit` made on `base` through `set` (`agent.groups.set`) and returns the server's
    /// new document. When another device saved first (`groups_conflict`), the edit is applied
    /// once more to the server's current document and sent again; a second conflict is thrown
    /// with the newest document. An edit that changes nothing is not sent.
    public static func commit(
        _ edit: AgentGroupsEdit,
        onto base: AgentGroupsDocument,
        set: (AgentGroupsDocument) async throws -> AgentGroupsDocument
    ) async throws -> AgentGroupsDocument {
        let next = edit.applied(to: base)
        guard next != base else { return base }
        do {
            return try await set(next)
        } catch AgentGroupsError.conflict(let current) {
            let replayed = edit.applied(to: current)
            guard replayed != current else { return current }
            return try await set(replayed)
        }
    }
}

public enum AgentGroupsError: Error, Equatable, Sendable {
    /// The set was based on a stale revision; `current` is the server's document now.
    case conflict(current: AgentGroupsDocument)
    /// The server refused the document (`invalid_groups`).
    case invalid(String)
    /// A guest connection: folders are the owner's.
    case forbidden
    /// The daemon predates `agent.groups.*`.
    case unsupported
}

// MARK: - the list with folders

/// A row of the Agents list once folders and stars are applied.
public enum AgentListItem: Equatable, Sendable, Identifiable {
    /// An agent. `folderID` is set for an agent shown indented under its open folder.
    case agent(AgentRow, starred: Bool, folderID: String?)
    case folder(AgentFolderSummary)

    public var id: String {
        switch self {
        case .agent(let row, _, _): row.id
        case .folder(let summary): "folder:\(summary.folder.id)"
        }
    }
}

/// What a folder row shows: its agents, the waiting and stopped counts, and the line that
/// says who needs you.
public struct AgentFolderSummary: Equatable, Sendable {
    public let folder: AgentFolder
    /// The folder's agents present in the list, most urgent first (starred first within a state).
    public let members: [AgentRow]
    public let isOpen: Bool

    public var waitingCount: Int { members.filter { $0.group == .needsYou }.count }
    public var stoppedCount: Int { members.filter { $0.group == .stopped }.count }

    /// "enyo-review needs you · enyo-efm stopped"; "2 working" or "idle" when nothing is
    /// wrong; "empty" for a folder with no agents here.
    public var summaryLine: String {
        guard !members.isEmpty else { return "empty" }
        var parts: [String] = []
        let waiting = members.filter { $0.group == .needsYou }.map(\.title)
        if !waiting.isEmpty { parts.append(Self.phrase(waiting, one: "needs you", many: "need you")) }
        let stopped = members.filter { $0.group == .stopped }.map(\.title)
        if !stopped.isEmpty { parts.append(Self.phrase(stopped, one: "stopped", many: "stopped")) }
        if parts.isEmpty {
            let working = members.filter { $0.group == .working }.count
            return working > 0 ? "\(working) working" : "idle"
        }
        return parts.joined(separator: " · ")
    }

    public var agentCountText: String { members.count == 1 ? "1 agent" : "\(members.count) agents" }

    private static func phrase(_ names: [String], one: String, many: String) -> String {
        switch names.count {
        case 1: "\(names[0]) \(one)"
        case 2: "\(names[0]) and \(names[1]) \(many)"
        default: "\(names.count) \(many)"
        }
    }
}

/// Folders and stars applied to the list's state sections.
///
/// - A starred agent goes first within its state, so a starred agent that needs you is the
///   very first row.
/// - A folder's agents leave their sections. The folder row sits in the section of its most
///   urgent agent, after that section's starred agents, and among the other agents by
///   recency: a folder counts as recent as its most recently active agent, the same
///   last-completed-turn time the list sorts agents by. On a tie the folder goes first, then
///   folders by their order. When open, its agents follow it, most urgent first.
/// - A folder with none of its agents in the list is kept in `emptyFolders`, so it can still
///   be renamed or deleted.
public struct AgentFolderLayout: Equatable, Sendable {
    public struct Section: Equatable, Sendable {
        public let group: AgentGroup
        public let items: [AgentListItem]
        /// The agents in this section, those inside its folders included.
        public let agentCount: Int
    }

    public let sections: [Section]
    public let emptyFolders: [AgentFolderSummary]

    public init(sections: [(group: AgentGroup, rows: [AgentRow])],
                groups: AgentGroupsDocument?, openFolders: Set<String>) {
        let groups = groups ?? AgentGroupsDocument()
        let stars = Set(groups.stars)
        func starred(_ row: AgentRow) -> Bool { row.info.name.map(stars.contains) ?? false }
        func starredFirst(_ rows: [AgentRow]) -> [AgentRow] {
            rows.filter(starred) + rows.filter { !starred($0) }
        }

        // Each agent name belongs to the first folder that lists it.
        var folderOf: [String: String] = [:]
        for folder in groups.orderedFolders {
            for member in folder.members where folderOf[member] == nil { folderOf[member] = folder.id }
        }
        func folderID(_ row: AgentRow) -> String? { row.info.name.flatMap { folderOf[$0] } }

        // Folder members, most urgent first: the sections are already in state order.
        var membersByFolder: [String: [AgentRow]] = [:]
        for section in sections {
            for row in starredFirst(section.rows) {
                if let id = folderID(row) { membersByFolder[id, default: []].append(row) }
            }
        }

        var summaries: [AgentGroup: [AgentFolderSummary]] = [:]
        var empty: [AgentFolderSummary] = []
        for folder in groups.orderedFolders {
            let members = membersByFolder[folder.id] ?? []
            let summary = AgentFolderSummary(folder: folder, members: members,
                                             isOpen: openFolders.contains(folder.id))
            if let urgent = members.first?.group {
                summaries[urgent, default: []].append(summary)
            } else {
                empty.append(summary)
            }
        }

        // A folder is as recent as its most recently active agent: the same clock
        // `AgentList` sorts agents by within a state.
        func recency(_ row: AgentRow) -> Int64 { row.info.lastCompletedTurn?.completedUnixMs ?? Int64.min }
        func recency(_ summary: AgentFolderSummary) -> Int64 { summary.members.map(recency).max() ?? Int64.min }

        var built: [Section] = []
        for section in sections {
            let loose = section.rows.filter { folderID($0) == nil }
            var items: [AgentListItem] = loose.filter(starred)
                .map { .agent($0, starred: true, folderID: nil) }
            var count = loose.count
            // Both lists are newest first (`loose` from `AgentList`; folders stably sorted
            // here), so one merge interleaves them.
            let folders = (summaries[section.group] ?? []).enumerated()
                .sorted { (recency($1.element), $0.offset) < (recency($0.element), $1.offset) }
                .map(\.element)
            var others = loose.filter { !starred($0) }[...]
            for summary in folders {
                while let next = others.first, recency(next) > recency(summary) {
                    items.append(.agent(next, starred: false, folderID: nil))
                    others.removeFirst()
                }
                items.append(.folder(summary))
                count += summary.members.count
                if summary.isOpen {
                    items += summary.members.map { .agent($0, starred: starred($0), folderID: summary.folder.id) }
                }
            }
            items += others.map { .agent($0, starred: false, folderID: nil) }
            if !items.isEmpty { built.append(Section(group: section.group, items: items, agentCount: count)) }
        }
        // A folder whose most urgent agent's state has no section of its own here cannot
        // happen: that agent came from one of `sections`.
        self.sections = built
        self.emptyFolders = empty
    }
}
