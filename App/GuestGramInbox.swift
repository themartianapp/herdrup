import Combine
import HerdrKit
import SwiftUI

/// The guest's one Gram inbox (herdrup#697, design 3B): every share on this phone whose
/// owner shares its Gram, each over its own connection and `GuestGramFeed`, merged on the
/// client by HerdrKit's `GuestGramMerge`. A share whose host doesn't share Gram (or predates
/// the features object) never gets a `gram.list`, and is in neither the feed nor the list.
@MainActor
final class GuestGramInbox: ObservableObject {
    /// What the Gram tab shows: the combined feed, or one share's own.
    enum Selection: Hashable {
        case all
        case grant(GuestAccess.ID)
    }

    /// One group of rows: the shares of one owner on one host.
    struct Group: Identifiable {
        let id: String
        let ownerName: String
        let shares: [GuestAccess]
    }

    private final class Grant {
        var access: GuestAccess
        let connection: GuestConnection
        let feed = GuestGramFeed()
        var gram = false
        var watch: AnyCancellable?

        init(access: GuestAccess, connection: GuestConnection) {
            self.access = access
            self.connection = connection
        }
    }

    /// The shares with Gram, in the phone's share order.
    @Published private(set) var shares: [GuestAccess] = []
    /// The open feed; nil is the inbox list (a phone's first screen).
    @Published var selection: Selection?
    /// Bumped on every feed change, so views re-read the merge.
    @Published private(set) var revision = 0

    private let connect: (GuestAccess) throws -> GuestConnection
    private var grants: [GuestAccess.ID: Grant] = [:]
    private var order: [GuestAccess.ID] = []

    init(connect: @escaping (GuestAccess) throws -> GuestConnection) {
        self.connect = connect
    }

    // MARK: Shares

    /// Follows the phone's shares: a new one connects and asks its host what it shares
    /// (a ping; Gram follows once the hello says so), a left one goes.
    func sync(_ accesses: [GuestAccess]) {
        order = accesses.map(\.id)
        let keep = Set(order)
        for id in grants.keys where !keep.contains(id) { grants[id] = nil }
        for access in accesses {
            if let grant = grants[access.id] {
                grant.access = access
            } else {
                _ = try? connection(for: access)
            }
        }
        publishShares()
    }

    /// The share's one connection, shared with its Agents row and agent page: their polling
    /// (`agent.list` every few seconds) carries the host's hello features, so a host that
    /// comes back online, or an owner who turns Gram on, shows here without a second probe.
    func connection(for access: GuestAccess) throws -> GuestConnection {
        if let grant = grants[access.id] { return grant.connection }
        let connection = try connect(access)
        let grant = Grant(access: access, connection: connection)
        grants[access.id] = grant
        grant.feed.onChange = { [weak self] in self?.revision += 1 }
        // The features model publishes on the main thread (`GuestFeaturesModel.sink`).
        grant.watch = connection.features.$current.sink { [weak self, weak grant] features in
            MainActor.assumeIsolated {
                guard let self, let grant else { return }
                let gram = features?.gram == true
                guard gram != grant.gram else { return }
                grant.gram = gram
                self.publishShares()
                if gram { Task { await grant.feed.refresh(client: grant.connection.client) } }
            }
        }
        // Any call's hello says what the host shares; a ping asks for nothing else.
        Task { _ = try? await connection.client.serverCapabilities() }
        return connection
    }

    /// How often a share without Gram (or whose host didn't answer) is asked again, for the
    /// shares on other machines that no Agents screen polls.
    static let rediscoverInterval: Duration = .seconds(30)

    /// Asks every share without Gram what its host shares now, until cancelled.
    func rediscover() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.rediscoverInterval)
            await discover(hostID: nil)
        }
    }

    /// Pings the shares without Gram (on `hostID`, or all): their hello updates the features.
    private func discover(hostID: String?) async {
        for grant in order.compactMap({ grants[$0] }) where !grant.gram {
            guard hostID == nil || grant.access.endpoint.hostID == hostID else { continue }
            _ = try? await grant.connection.client.serverCapabilities()
        }
    }

    private func publishShares() {
        let next = order.compactMap { id in grants[id].flatMap { $0.gram ? $0.access : nil } }
        if next != shares { shares = next }
        labels = GuestAccess.recipientLabels(next)
        if case .grant(let id)? = selection, !next.contains(where: { $0.id == id }) { selection = nil }
        revision += 1
    }

    /// Each share's agent as the Gram tab names it: unique where two agents share a name.
    private(set) var labels: [GuestAccess.ID: String] = [:]
    func label(_ id: GuestAccess.ID) -> String { labels[id] ?? agentName(id) }

    /// Rows grouped by owner and host, in share order. One group needs no label.
    var groups: [Group] {
        var groups: [Group] = []
        for share in shares {
            let key = "\(share.ownerName)\u{1F}\(share.endpoint.hostID)"
            if let index = groups.firstIndex(where: { $0.id == key }) {
                groups[index] = Group(id: key, ownerName: share.ownerName, shares: groups[index].shares + [share])
            } else {
                groups.append(Group(id: key, ownerName: share.ownerName, shares: [share]))
            }
        }
        return groups
    }

    func access(_ id: GuestAccess.ID) -> GuestAccess? { grants[id]?.access }
    func client(_ id: GuestAccess.ID) -> HerdrClient? { grants[id]?.connection.client }

    /// The share's agent as its host names it now.
    func agentName(_ id: GuestAccess.ID) -> String { grants[id]?.access.agentName ?? "" }

    // MARK: Feeds

    private func ids(_ selection: Selection) -> [GuestAccess.ID] {
        switch selection {
        case .all: shares.map(\.id)
        case .grant(let id): shares.contains { $0.id == id } ? [id] : []
        }
    }

    /// The merged feed for `selection`; one share's own feed is the merge of its one lane.
    func merge(_ selection: Selection) -> GuestGramMerge {
        GuestGramMerge(lanes: ids(selection).compactMap { id in grants[id]?.feed.lane(grant: id) })
    }

    /// Every share's first answer (or failure) has landed.
    func loaded(_ selection: Selection) -> Bool {
        ids(selection).allSatisfy { grants[$0]?.feed.loaded ?? true }
    }

    /// The newest refresh failure of the selection's shares, by agent.
    func failure(_ selection: Selection) -> String? {
        let failures = ids(selection).compactMap { id -> String? in
            guard let grant = grants[id], let error = grant.feed.lastError else { return nil }
            return describe(error, access: grant.access)
        }
        return failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    /// The All agents count and the tab's badge: the sum of every share's unread, read off
    /// each feed (the counts don't depend on the merged order or the floor).
    var unreadTotal: Int { shares.reduce(0) { $0 + unread($1.id) } }
    func unread(_ id: GuestAccess.ID) -> Int {
        guard let grant = grants[id], grant.gram else { return 0 }
        return grant.feed.unreadCount
    }

    /// Reloads the newest page of every share with Gram, or those on `hostID` (a push). The
    /// shares there without Gram are asked again too: a Gram push means their host shares it.
    func refresh(hostID: String? = nil) async {
        for grant in order.compactMap({ grants[$0] }) where grant.gram {
            guard hostID == nil || grant.access.endpoint.hostID == hostID else { continue }
            await grant.feed.refresh(client: grant.connection.client)
        }
        await discover(hostID: hostID)
    }

    func refresh(_ selection: Selection) async {
        for id in ids(selection) {
            guard let grant = grants[id] else { continue }
            await grant.feed.refresh(client: grant.connection.client)
        }
    }

    /// An older page of the selection's shares failed and none has landed since.
    func pageFailed(_ selection: Selection) -> Bool {
        ids(selection).contains { grants[$0]?.feed.pageError != nil }
    }

    /// "Earlier": the next page of each share the merge names (those at its safe floor).
    func loadEarlier(_ selection: Selection) async throws {
        for id in merge(selection).grantsToPage {
            guard let grant = grants[id] else { continue }
            try await grant.feed.loadMore(client: grant.connection.client)
        }
    }

    /// The reader saw the feed: each share's shown unread Grams are read, for this guest only.
    func markShown(_ selection: Selection) async {
        for (id, shown) in merge(selection).shownUnreadByGrant {
            // The reader left (the caller's task was cancelled): mark nothing more.
            guard !Task.isCancelled, let grant = grants[id] else { return }
            await grant.feed.markRead(shown, client: grant.connection.client)
        }
    }

    /// Posts `text` to the share's agent under the name its host lists now (the guest posting
    /// contract; the share's saved name can lag a rename on a machine whose Agents screen
    /// isn't open), saving the rename, then reloads that share.
    func send(_ text: String, to id: GuestAccess.ID) async throws {
        guard let grant = grants[id] else { return }
        let client = grant.connection.client
        let agents = try await client.agentList()
        let listed = agents.first(where: grant.access.isSharedAgent)
        if let renamed = grant.access.renamed(listing: agents) {
            grant.access = renamed
            SharedMachinesStore.shared.update(renamed)
            publishShares()
        }
        try await client.guestGramPost(text: text, to: grant.access.liveAgentName(listed: listed))
        await grant.feed.refresh(client: client)
    }

    func describe(_ error: Error, access: GuestAccess) -> String {
        switch GuestError.classify(error) {
        case .forbidden?: return "\(access.ownerName) doesn't share \(access.agentName)'s Gram with you."
        case let guest?: return "\(access.agentName): \(guest.description)"
        case nil: return "Couldn't load \(access.agentName)'s Gram: \(error.localizedDescription)"
        }
    }
}
