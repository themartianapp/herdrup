import HerdrKit
import SwiftUI
import UIKit

/// The tabs of a guest's agent screen: Chat only for an omp agent on a host that serves
/// guests its transcript (#482). Gram is the guest shell's own tab (#697).
enum GuestPaneTab: Hashable { case chat, terminal }

/// The guest shell's Gram tab (herdrup#697, design 3B): an inbox list with an "All agents"
/// row, the combined feed of every shared agent, above one row per shared agent, grouped
/// by owner when shares come from more than one owner or host. On a phone the list opens a
/// feed full screen; in a regular-width window the list stays beside the open feed.
struct GuestGramTab: View {
    @ObservedObject var inbox: GuestGramInbox
    /// The tab is the one on screen: only then does an open feed mark what it shows read.
    let active: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let _ = inbox.revision
        ZStack {
            Palette.ground.ignoresSafeArea()
            if sizeClass == .regular {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        SectionTopBar(title: "Gram") { EmptyView() }
                        list
                    }
                    .frame(width: 340)
                    Rectangle().fill(Palette.hairline).frame(width: 1 / displayScale).ignoresSafeArea()
                    conversation(inbox.selection ?? .all, back: nil)
                }
            } else if let selection = inbox.selection {
                conversation(selection) { inbox.selection = nil }
            } else {
                VStack(spacing: 0) {
                    SectionTopBar(title: "Gram") { EmptyView() }
                    list
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guest-gram-tab")
    }

    private func conversation(_ selection: GuestGramSelectionKey, back: (() -> Void)?) -> some View {
        GuestGramConversation(inbox: inbox, selection: selection, active: active, onBack: back)
            .id(selection)
    }

    private var list: some View {
        let groups = inbox.groups
        let regular = sizeClass == .regular
        let selected = regular ? (inbox.selection ?? .all) : nil
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                row(.all, identifier: "guest-gram-all", selected: selected == .all) {
                    let merge = inbox.merge(.all)
                    let newest = merge.items.last
                    return GramConversationRow(
                        title: "All agents",
                        avatarNames: inbox.shares.map(\.agentName),
                        systemImage: inbox.shares.isEmpty ? "bubble.left.and.bubble.right.fill" : nil,
                        preview: newest.map { preview($0.message, agent: inbox.agentName($0.grant)) }
                            ?? AttributedString("\(inbox.shares.count) shared agents"),
                        time: newest?.message.createdAt,
                        unread: merge.unreadCount > 0,
                        selected: selected == .all,
                        unreadCount: merge.unreadCount)
                }
                ForEach(groups) { group in
                    if groups.count > 1 {
                        Text(group.ownerName.uppercased())
                            .font(Typography.app(12, .semibold)).tracking(0.6)
                            .foregroundStyle(Palette.textFaint)
                            .padding(.leading, 22).padding(.top, 16).padding(.bottom, 4)
                            .accessibilityIdentifier("guest-gram-group-\(group.ownerName)")
                    }
                    ForEach(group.shares) { share in
                        let key = GuestGramSelectionKey.grant(share.id)
                        row(key, identifier: "guest-gram-agent-\(share.agentTarget)", selected: selected == key) {
                            let newest = inbox.merge(key).items.last
                            let unread = inbox.unread(share.id)
                            return GramConversationRow(
                                title: inbox.label(share.id),
                                avatarNames: [share.agentName],
                                systemImage: nil,
                                preview: newest.map { preview($0.message, agent: share.agentName) }
                                    ?? AttributedString("No Grams yet"),
                                time: newest?.message.createdAt,
                                unread: unread > 0,
                                selected: selected == key,
                                unreadCount: unread)
                        }
                    }
                }
            }
            .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 24)
        }
        .refreshable { await inbox.refresh() }
        .accessibilityIdentifier("guest-gram-inbox")
    }

    private func row(_ key: GuestGramSelectionKey, identifier: String, selected: Bool,
                     label: () -> GramConversationRow) -> some View {
        let content = label()
        return Button { inbox.selection = key } label: { content }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The row's preview: the agent's words, or "You: " before the guest's own.
    private func preview(_ message: GuestGramMessage, agent: String) -> AttributedString {
        let text = message.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let body = text.isEmpty ? (message.file?.name ?? message.expiredFile?.name ?? "") : text
        return AttributedString(message.isFromAgent ? body : "You: \(body)")
    }
}

#if DEBUG
/// For the UI tests, over the whole guest shell (any tab), as `GuestPaneView`'s: the Gram and
/// push calls the mock host answered (`guest-host-calls`), and what it refused a guest
/// (`guest-forbidden-calls`). Under `HERDR_MOCK_GUEST_GRAM_ARRIVAL`, a fixture button lands a
/// new Gram from enyo-ui and announces it as a push would.
struct GuestGramProbes: View {
    let hostID: String
    @State private var hostCalls = ""
    @State private var forbidden = ""

    var body: some View {
        ZStack {
            Color.clear.accessibilityElement()
                .accessibilityIdentifier("guest-host-calls").accessibilityLabel(hostCalls)
            Color.clear.accessibilityElement()
                .accessibilityIdentifier("guest-forbidden-calls").accessibilityLabel(forbidden)
        }
        .frame(width: 1, height: 1)
        .overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.environment["HERDR_MOCK_GUEST_GRAM_ARRIVAL"] != nil {
                Button("Gram arrives") {
                    GuestMockTransport.deliverGram()
                    PushCenter.shared.guestGramArrived(hostID: hostID)
                }
                .buttonStyle(.bordered).fixedSize()
                .offset(x: 12, y: 120)
                .accessibilityIdentifier("guest-fixture-gram-arrives")
            }
        }
        .task {
            while !Task.isCancelled {
                hostCalls = GuestMockTransport.hostCalls.joined(separator: ";")
                forbidden = GuestMockTransport.forbiddenCalls.joined(separator: ",")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
#endif

typealias GuestGramSelectionKey = GuestGramInbox.Selection

/// One feed of the Gram tab: the combined feed, or one shared agent's. Oldest at the top and
/// pinned to the bottom on the inbox's `WindowedBottomFeed`, drawn by the owner's `GramRow`
/// as a guest viewer: each agent's Grams under its own avatar and name, the guest's own
/// posts on the right with "Delivered to <agent>". A message's menu offers Reply, which
/// addresses the composer to its agent; a new message goes to the composer's "To" agent,
/// the agent of the newest incoming Gram until the guest picks another.
struct GuestGramConversation: View {
    @ObservedObject var inbox: GuestGramInbox
    let selection: GuestGramSelectionKey
    /// On screen: the Gram tab is selected (and no agent page covers it). Only then is what
    /// the feed shows marked read.
    let active: Bool
    let onBack: (() -> Void)?

    @State private var downloadingID: String?
    @State private var progress: (received: Int, total: Int)?
    @State private var openTask: Task<Void, Never>?
    @State private var preview: GramPreview?
    @State private var fileError: String?
    @State private var visibility = FeedVisibility()
    @State private var appearance = 0
    @State private var landed = false
    @State private var anchorID: String?
    @State private var expanded: [String: Set<Int>] = [:]
    /// The composer's chosen agent; nil follows the merge's default.
    @State private var target: GuestAccess.ID?
    @State private var draft = ""
    @State private var sending = false
    @State private var sendError: String?
    @FocusState private var composerFocused: Bool
    @AppStorage("ui.fontScale") private var uiFontScale: Double = 1.0

    private static let bottomID = "guest-gram-bottom"

    private struct Row: Identifiable {
        let id: String
        let item: GuestGramMergedItem
        let entry: GramFeedEntry
    }

    /// The feed's rows, oldest first, always keyed by grant and message id
    /// (`GuestGramMergedItem.id`): ids are not unique across hosts, and a row must keep its
    /// identity (scroll anchor, unfolded text, download) whatever else pages in.
    private func rows(_ merge: GuestGramMerge) -> [Row] {
        let messages = merge.items.map { $0.message.gramMessage(agent: inbox.agentName($0.grant)) }
        let entries = GramFeedEntry.entries(oldestFirst: messages)
        return zip(merge.items, entries).map { Row(id: $0.id, item: $0, entry: $1) }
    }

    private var title: String {
        switch selection {
        case .all: "All agents"
        case .grant(let id): inbox.label(id)
        }
    }

    var body: some View {
        let _ = inbox.revision
        let merge = inbox.merge(selection)
        let rows = rows(merge)
        VStack(spacing: 0) {
            header
            if let fileError { notice(fileError, id: "guest-gram-file-error") }
            if let failure = inbox.failure(selection) { notice(failure, id: "guest-gram-failure") }
            if rows.isEmpty && merge.hasMore {
                floorPager(merge)
            } else if rows.isEmpty {
                ScrollView { empty.frame(maxWidth: .infinity) }
                    .refreshable { await inbox.refresh(selection) }
                    .frame(maxHeight: .infinity)
            } else {
                feed(rows, merge: merge)
            }
            composer(merge)
        }
        .background(Palette.ground)
        .gramFileViewer($preview)
        // Keyed on visibility: leaving the tab cancels a refresh still out, so it can't mark
        // a hidden feed read when it lands; coming back refreshes and marks what shows.
        .task(id: active) {
            await inbox.refresh(selection)
            guard active, !Task.isCancelled else { return }
            await inbox.markShown(selection)
        }
        // Viewed is read: whatever lands in the feed while it shows is marked read, and what
        // landed while it was hidden once it shows again. Never while another tab is up.
        .onChange(of: merge.items.map(\.id)) { _, _ in
            guard active else { return }
            Task { await inbox.markShown(selection) }
        }
        .onDisappear { openTask?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guest-gram-list")
    }

    /// Back in its capsule, leading; in an iPad window whose controls take the leading corner
    /// Back joins the right-hand capsule instead (`SectionBackSlot`), as the guest home's.
    private var header: some View {
        SectionTopBar(title: title, leading: {
            if onBack != nil { SectionBackSlot(.leading) { backButton } }
        }) {
            if onBack != nil { SectionBackSlot(.trailing) { backButton } }
        }
    }

    private var backButton: some View {
        SectionBarButton(icon: "chevron.left", label: "Gram", identifier: "guest-gram-back") { onBack?() }
    }

    private func feed(_ rows: [Row], merge: GuestGramMerge) -> some View {
        ScrollViewReader { proxy in
            WindowedBottomFeed(
                feed: proxy,
                items: rows,
                spacing: 0,
                showsSentinel: merge.hasMore,
                bottomID: Self.bottomID,
                feedID: "guest-gram-feed",
                messagesID: "guest-gram-messages",
                messagesValue: "\(rows.count) messages",
                column: .capped(GramBubble.columnCap),
                visibleTop: 0,
                search: "",
                visibility: visibility,
                appearance: $appearance,
                landed: $landed,
                anchorID: $anchorID,
                onLanded: { Task { @MainActor in if visibility.sentinelOnScreen { loadOlder(top: rows.first?.id) } } },
                onSentinelArrival: { loadOlder(top: rows.first?.id) },
                sentinel: {
                    Button {
                        // A tap retries the failed page: the feeds' failure clears, then a
                        // fresh, reader-asked fetch.
                        inbox.retryPaging(selection)
                        visibility.pageArmed = true
                        loadOlder(top: rows.first?.id)
                    } label: {
                        HStack(spacing: 8) {
                            if let pageError {
                                GramPageFailureLabel(message: pageError)
                            } else {
                                ProgressView().controlSize(.small)
                                Text("Loading older messages…")
                            }
                        }
                        .font(Typography.app(12))
                        .foregroundStyle(Palette.textFaint)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .disabled(pageError == nil)
                    .accessibilityIdentifier("guest-gram-loading-older")
                },
                row: { index, row in
                    GramFeedRow(index: index, entry: row.entry) {
                        gramRow(row)
                    }
                },
                footer: { EmptyView() }
            )
            // A new Gram follows in while the guest is at the bottom, as the inbox does.
            .onChange(of: rows.last?.id) { _, _ in
                guard landed, visibility.atBottom else { return }
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            .refreshable { await inbox.refresh(selection) }
        }
        .overlay(alignment: .top) {
            GramGroundFade().frame(height: 16)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private func gramRow(_ row: Row) -> some View {
        let message = row.entry.message
        let grant = row.item.grant
        return GramRow(
            message: message,
            isDownloadingFile: downloadingID == row.id,
            downloadProgress: downloadingID == row.id ? progress : nil,
            feedLanded: landed,
            isSaved: false,
            expandedSegments: expanded[row.id] ?? [],
            fontScale: uiFontScale,
            onOpenFile: { open(row.item) },
            onSaveFile: {},
            onPrefetchImage: {},
            onToggleSave: {},
            onDelete: {},
            onSetExpanded: { segment, open in
                if open { expanded[row.id, default: []].insert(segment) } else { expanded[row.id]?.remove(segment) }
            },
            onReply: selection == .all ? {
                target = grant
                composerFocused = true
            } : nil,
            startsGroup: row.entry.startsGroup,
            endsGroup: row.entry.endsGroup,
            viewer: .guest
        )
        .equatable()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guest-gram-row-\(row.item.message.id)")
    }

    /// The failed older page of the selection's feeds, shown by both paging surfaces with
    /// Retry: derived from the feeds (`GuestGramFeed.pageError`), so it clears the moment a
    /// page lands or a refresh replaces a list, wherever that happened.
    private var pageError: String? {
        inbox.pageFailed(selection) ? "Couldn't load older messages." : nil
    }

    private func loadOlder(top: String?) {
        guard landed, visibility.pageArmed, !visibility.anchoring, !visibility.pageRequested,
              pageError == nil, inbox.merge(selection).hasMore else { return }
        visibility.pageArmed = false
        visibility.pageRequested = true
        let before = inbox.merge(selection).items.count
        Task { @MainActor in
            await pageEarlier()
            visibility.pageRequested = false
            if inbox.merge(selection).items.count > before {
                if let top { anchorID = top }
            } else {
                visibility.pageArmed = true
            }
        }
    }

    /// One "Earlier" for the merge's grants at the floor. A failure stays in the feed that
    /// failed (`GuestGramFeed.pageError`), which `pageError` reads.
    private func pageEarlier() async {
        try? await inbox.loadEarlier(selection)
    }

    /// Every held row is at or under the strict floor (a page that ended inside one
    /// millisecond): page on until something shows, with the sentinel's failure and Retry.
    /// Keyed on the floor, the hidden count and whether a feed's page failed: a new floor
    /// pages again, a failure waits, and the failure clearing (Retry, a page landing, or a
    /// refresh replacing the list when the conversation is reopened) pages again.
    private func floorPager(_ merge: GuestGramMerge) -> some View {
        let failure = pageError
        return ScrollView {
            Button {
                inbox.retryPaging(selection)
            } label: {
                HStack(spacing: 8) {
                    if let failure {
                        GramPageFailureLabel(message: failure)
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Loading older messages…")
                    }
                }
                .font(Typography.app(12))
                .foregroundStyle(Palette.textFaint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .disabled(failure == nil)
            .accessibilityIdentifier("guest-gram-loading-older")
            .padding(.top, 60)
        }
        .refreshable { await inbox.refresh(selection) }
        .frame(maxHeight: .infinity)
        .task(id: "\(merge.floorUnixMs ?? 0)/\(merge.hiddenCount)/\(failure != nil)") {
            guard failure == nil else { return }
            await pageEarlier()
        }
    }

    // MARK: Composer

    /// The composer's agent: the reader's pick, else the merge's default (the newest
    /// incoming Gram's agent, else the first share).
    private func resolvedTarget(_ merge: GuestGramMerge) -> GuestAccess.ID? {
        if let target, inbox.access(target) != nil { return target }
        return merge.defaultTarget
    }

    private func composer(_ merge: GuestGramMerge) -> some View {
        let to = resolvedTarget(merge)
        return VStack(alignment: .leading, spacing: 6) {
            if let sendError {
                Text(sendError).font(Typography.app(12.5)).foregroundStyle(Palette.textDim)
                    .accessibilityIdentifier("guest-gram-send-error")
            }
            if selection == .all, inbox.shares.count > 1 {
                Menu {
                    ForEach(inbox.shares) { share in
                        Button(inbox.label(share.id)) { target = share.id }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("To").foregroundStyle(Palette.textDim)
                        if let to { GramAvatar(name: inbox.agentName(to), size: 18) }
                        Text(to.map(inbox.label) ?? "").foregroundStyle(Palette.text)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.textFaint)
                    }
                    .font(Typography.app(13, .semibold))
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(Capsule().fill(Palette.surfaceRaised))
                }
                .accessibilityIdentifier("guest-gram-to")
                .accessibilityValue(to.map(inbox.label) ?? "")
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(to.map { "Message \(inbox.label($0))" } ?? "Message", text: $draft, axis: .vertical)
                    .font(Typography.app(15))
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 20).fill(Palette.surface))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.hairline, lineWidth: 1))
                    .accessibilityIdentifier("guest-gram-composer")
                Button { send(to: to) } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ground)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(canSend(to) ? Palette.text : Palette.textFaint))
                }
                .buttonStyle(.plain)
                .disabled(!canSend(to))
                .accessibilityLabel("Send")
                .accessibilityIdentifier("guest-gram-send")
            }
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 10)
        .background(Palette.ground)
    }

    private func canSend(_ to: GuestAccess.ID?) -> Bool {
        to != nil && !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send(to: GuestAccess.ID?) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let to, !text.isEmpty, !sending else { return }
        sending = true
        sendError = nil
        Task {
            defer { sending = false }
            do {
                try await inbox.send(text, to: to)
                if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
            } catch {
                let agent = inbox.label(to)
                sendError = GuestError.classify(error).map { "Couldn't send to \(agent): \($0.description)" }
                    ?? "Couldn't send to \(agent): \(error.localizedDescription)"
            }
        }
    }

    // MARK: Empty and notices

    @ViewBuilder private var empty: some View {
        if inbox.loaded(selection) && inbox.failure(selection) == nil {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.textDim)
                    .frame(width: 46, height: 46)
                    .background(Palette.surfaceRaised, in: Circle())
                Text("No Grams yet")
                    .font(Typography.app(16, .semibold)).foregroundStyle(Palette.text)
                Text(emptyText)
                    .font(Typography.app(13.5)).foregroundStyle(Palette.textDim)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 60).padding(.horizontal, 20)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("guest-gram-empty")
        } else if !inbox.loaded(selection) {
            ProgressView().tint(Palette.textDim).padding(.top, 60)
        }
    }

    private var emptyText: String {
        switch selection {
        case .all:
            return "What the agents shared with you send from now on shows here, with its files."
        case .grant(let id):
            let access = inbox.access(id)
            return "What \(access?.agentName ?? "this agent") sends \(access?.ownerName ?? "its owner") from now on shows here, with its files."
        }
    }

    private func notice(_ text: String, id: String) -> some View {
        Text(text)
            .font(Typography.app(13)).foregroundStyle(Palette.textDim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surface))
            .accessibilityIdentifier(id)
            .padding(.horizontal, 16).padding(.top, 8)
    }

    // MARK: Files

    /// Downloads the file in bounded pieces from its own share's host and opens it:
    /// markdown rendered, HTML and SVG in the in-app viewer, anything else in QuickLook.
    private func open(_ item: GuestGramMergedItem) {
        guard downloadingID == nil, let file = item.message.file,
              let client = inbox.client(item.grant) else { return }
        let owner = inbox.access(item.grant)?.ownerName ?? "The owner"
        downloadingID = item.id
        progress = nil
        fileError = nil
        openTask = Task {
            defer { downloadingID = nil; progress = nil }
            do {
                let (name, mime, data) = try await client.gramGetFileChunked(
                    id: item.message.id, expectedSize: file.size) { received, total in
                    Task { @MainActor in progress = (received, total) }
                }
                if Task.isCancelled { return }
                preview = try GramPreviewRouter.preview(data: data, name: name, mime: mime, cachedAt: nil)
                #if DEBUG
                GuestMockTransport.noteOpened(name)
                #endif
            } catch is CancellationError {
            } catch {
                if GuestError.classify(error) == .forbidden {
                    fileError = "\(owner) doesn't share this file with you."
                } else {
                    fileError = "Couldn't open the file: \((error as? APIError)?.message ?? error.localizedDescription)"
                }
            }
        }
    }
}
