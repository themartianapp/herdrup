import HerdrKit
import SwiftUI

/// A guest's view of the one agent shared with them: the live terminal, view only, and a
/// composer whose messages and files reach the agent under the guest's name. While the
/// agent waits on a menu or question the guest answers it as the owner would: the chat's
/// answer buttons, or the owner's menu keys under the terminal. When the owner shares the
/// agent's Gram, a second tab lists it.
struct GuestPaneView: View {
    let client: HerdrClient
    let access: GuestAccess
    @ObservedObject var features: GuestFeaturesModel
    @Binding var tab: GuestPaneTab
    let onClose: () -> Void

    init(client: HerdrClient, access: GuestAccess, features: GuestFeaturesModel,
         tab: Binding<GuestPaneTab>, onClose: @escaping () -> Void) {
        self.client = client
        self.access = access
        self.features = features
        _chatModel = StateObject(wrappedValue: ChatModel(target: access.agentTarget))
        _tab = tab
        self.onClose = onClose
    }

    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The shared agent's conversation for the Chat tab (#482).
    @StateObject private var chatModel: ChatModel
    /// The host serves `agent.transcript` to guests (its pong's `agent_transcript`).
    @State private var transcriptCapable = false
    /// The Chat tab has been made the default once; after that the guest's own pick stands.
    @State private var chatDefaulted = false

    /// Whether the shared agent can be reached right now.
    private enum Availability: Equatable {
        case connecting
        case running
        /// The agent isn't the pane's foreground program; the host refuses guests until it is.
        case paused
        case offline
        /// Revoked or otherwise gone for good.
        case lost
    }

    /// The host caps a prompt at 32 KiB (`invalid_params` beyond it).
    static let maxPromptBytes = 32 * 1024
    private static let pollNanoseconds: UInt64 = 5_000_000_000

    @State private var agent: AgentInfo?
    @State private var availability: Availability = .connecting
    @State private var streamGen = 0
    @State private var reply = ""
    @State private var replyFocused = false
    @State private var dictating = false
    @State private var sending = false
    @State private var note: String?
    /// Menu keys go out one after another, in the order they were tapped.
    @State private var menuKeyTask: Task<Void, Never>?
    /// The host has taken at least one of this guest's menu keys. An older host that keeps
    /// answers for the owner takes none, so after this a refusal is only the pause after a
    /// committing key (the old menu can still show) and proves nothing about the host.
    @State private var hostTookAMenuKey = false
    /// Why the last status poll failed, when it wasn't a change of availability.
    @State private var connectionNote: String?
    @State private var attachments: [ComposerAttachment] = []
    @State private var sendingAttachmentID: UUID?
    @State private var failedAttachmentID: UUID?
    /// Uploads each staged file as it is added, so Send only posts and prompts. Released
    /// with the pane, which abandons the draft (cancels and discards its uploads).
    @State private var uploader = ComposerUploader()
    @State private var loadingAttachment = false
    @State private var showAttachSheet = false
    /// A FILE drag is hovering the terminal (#575), which drops into this composer.
    @State private var terminalDropTargeted = false
    @State private var findOpen = false
    @State private var findTerm = ""
    @State private var findGeneration = 0
    @State private var findDirection: FindRequest.Direction = .forward
    @State private var findMatches: (Int, Int, Bool) = (0, 0, false)
    @FocusState private var findFocused: Bool
    @StateObject private var composerKeyboard = ComposerKeyboard()
    /// The guest's own terminal text size (A− / A+), separate from the owner's setting.
    @AppStorage(GuestTerminalSize.storageKey) private var terminalFontSize = GuestTerminalSize.defaultPoints
    @AppStorage(ChatTextSize.storageKey) private var chatFontSize = ChatTextSize.defaultPoints
    /// The host refused guest resizing (an older host): for the rest of this session the
    /// terminal fits the agent's grid to the width and the size controls are gone.
    @State private var resizeRefused = false
    /// False while the guest has scrolled the terminal away from its newest output: the
    /// owner's jump button shows (`JumpToLatestButton`), and its tap bumps the token.
    @State private var terminalAtTail = true
    @State private var jumpToTailToken = 0
    /// What the terminal's top history capsule shows: loading, the load-earlier offer, or nothing.
    @State private var terminalHistoryPaging = TerminalHistoryPaging.hidden
    /// Bumped by the capsule's "Load earlier output" tap; the terminal pages once per bump.
    @State private var loadEarlierHistoryToken = 0
    /// The note row's height over the composer, and the terminal's: the composer floats over
    /// the terminal (as the owner's does), so only its resting row takes layout height.
    @State private var bottomChromeHeight: CGFloat = 0
    @State private var terminalHeight: CGFloat = 0
    @StateObject private var gram = GuestGramModel()
    @ObservedObject private var guestPush = GuestPushCenter.shared
    #if DEBUG
    @State private var forbiddenProbe = ""
    @State private var hostCallsProbe = ""
    @State private var streamOpensProbe = ""
    @State private var delayedDropCompletion: ((Data?, Error?) -> Void)?
    #endif

    /// The owner shares this agent's Gram with the guest (the host's hello says so).
    private var showsGram: Bool { features.current?.gram == true }
    private var showingGram: Bool { showsGram && tab == .gram }
    /// The Chat tab: a shared omp agent on a host that serves guests its transcript, until
    /// the host says it cannot.
    private var showsChat: Bool {
        transcriptCapable && ChatPreference.isOmp(agent?.agent) && !chatModel.unsupported
    }
    private var showingChat: Bool { showsChat && tab == .chat }
    /// Neither Gram nor Chat covers the terminal.
    private var showingTerminal: Bool { !showingGram && !showingChat }

    /// The page's ground: the terminal's on the Terminal and Chat tabs, as the owner's
    /// pages, and the app's on Gram, as the owner's Gram.
    private var pageGround: Color { showingGram ? Palette.ground : Palette.groundMachine }

    var body: some View {
        VStack(spacing: 0) {
            header
            statusRow
            if showsGram || showsChat { tabStrip }
            ZStack(alignment: .bottom) {
                // The terminal stays mounted under the Gram and Chat tabs, so its stream and
                // scrollback survive a look at them.
                terminalArea
                    .opacity(showingTerminal ? 1 : 0)
                    .allowsHitTesting(showingTerminal)
                    .accessibilityHidden(!showingTerminal)
                if showingChat {
                    ChatView(client: client, model: chatModel,
                             viewer: .guest(name: access.guestName, ownerName: access.ownerName),
                             eventsPaneID: nil, isActive: true, live: availability == .running,
                             agentStatus: agent?.agentStatus, ground: Palette.groundMachine,
                             onOpenTerminal: { tab = .terminal },
                             findRequest: findRequest,
                             onFindResult: { index, total, capped in findMatches = (index, total, capped) })
                    // Typing redraws this page; the chat skips it (`ChatView ==`).
                    .equatable()
                }
                if showingGram {
                    GuestGramList(client: client, access: access, model: gram)
                        .background(Palette.ground)
                }
                if guestPush.asking == access.id, let current = features.current {
                    GuestPushPrompt(
                        agentName: access.agentName, ownerName: access.ownerName, gram: current.gram,
                        onEnable: {
                            Task { await guestPush.turnOn(access, client: client) }
                        },
                        onDecline: { guestPush.decline(access) })
                    .padding(.horizontal, 12).padding(.bottom, 10)
                    .transition(.opacity)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { terminalHeight = $0 }
            bottomBlock
        }
        .background(pageGround.ignoresSafeArea())
        .overlay { EdgeSwipeBack { onClose() } }
        .task { await pollLoop() }
        // Once the host's features are known: register for push (or explain it, when iOS
        // hasn't asked yet) and load Gram, so the unread count shows before the guest opens
        // the tab.
        .task(id: features.current) {
            guard let current = features.current else { return }
            await guestPush.connected(access, client: client, features: current)
            if current.gram { await gram.refresh(client: client, access: access) }
        }
        // The Chat tab exists only where the host serves guests `agent.transcript`.
        .task(id: access.id) {
            transcriptCapable = (try? await client.serverCapabilities())?.agentTranscript ?? false
        }
        // A shared omp agent opens in Chat, once; afterwards the guest's own pick stands.
        .onChange(of: showsChat, initial: true) { _, available in
            if available, !chatDefaulted {
                chatDefaulted = true
                if tab == .terminal { tab = .chat }
            } else if !available, tab == .chat {
                tab = .terminal
            }
        }
        .onChange(of: tab) { _, _ in
            if findOpen { toggleFind() }
            guard showingGram else { return }
            Task {
                await gram.refresh(client: client, access: access)
                await gram.markAllRead(client: client)
            }
        }
        // Viewed is read: whatever lands in the list while it shows is marked read.
        .onChange(of: gram.messages) { _, _ in
            guard showingGram else { return }
            Task { await gram.markAllRead(client: client) }
        }
        // A Gram push from this share's host: reload.
        .onReceive(PushCenter.shared.$guestGramArrival) { arrival in
            guard let arrival, arrival.hostID == access.endpoint.hostID, showsGram else { return }
            Task { await gram.refresh(client: client, access: access) }
        }
        .composerAttachPicker(
            isPresented: $showAttachSheet, loading: $loadingAttachment,
            room: { ComposerStaging.maxAttachments - attachments.count }
        ) { outcome in addPicked(outcome) }
        // Leaving the pane stops its uploads (a send waiting on one keeps it); closing it
        // for good releases the uploader, which cancels and discards them.
        .onDisappear { uploader.pause() }
        .onAppear { uploader.resume() }
        #if DEBUG
        .overlay(alignment: .topLeading) { debugProbes }
        #endif
    }

    // MARK: - Tabs

    /// Chat · Terminal · Gram, as many as this share offers. On iPad (regular width) a
    /// compact centred capsule with fixed-width tabs, not a strip across the whole page.
    private var tabStrip: some View {
        let compact = sizeClass == .regular
        return HStack(spacing: 4) {
            if showsChat {
                tabButton("Chat", systemImage: "bubble.left", tab: .chat, id: "guest-tab-chat", compact: compact)
            }
            tabButton("Terminal", systemImage: "terminal", tab: .terminal, id: "guest-tab-terminal", compact: compact)
            if showsGram {
                tabButton("Gram", systemImage: "paperplane", tab: .gram, id: "guest-tab-gram",
                          badge: gram.unreadCount, compact: compact)
            }
        }
        .padding(3)
        .background(Capsule().fill(Palette.surface))
        .overlay(Capsule().stroke(Palette.hairlineQuiet, lineWidth: 1))
        .fixedSize(horizontal: compact, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guest-tab-strip")
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    /// One tab of the compact (iPad) strip: three of them fill the mockup's 450 pt capsule.
    private static let compactTabWidth: CGFloat = 145

    private func tabButton(_ title: String, systemImage: String, tab value: GuestPaneTab, id: String,
                           badge: Int = 0, compact: Bool = false) -> some View {
        let selected = tab == value
        return Button {
            tab = value
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
                Text(title).font(Typography.app(14, .semibold))
                if badge > 0 {
                    Text("\(badge)")
                        .font(Typography.machine(11, .bold)).foregroundStyle(Palette.ground)
                        .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(Palette.waiting))
                        .accessibilityIdentifier("guest-gram-unread")
                }
            }
            .foregroundStyle(selected ? Palette.text : Palette.textDim)
            .frame(maxWidth: compact ? nil : .infinity, minHeight: 34)
            .frame(width: compact ? Self.compactTabWidth : nil)
            .background(Capsule().fill(selected ? Palette.surfaceRaised : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge > 0 ? "\(title), \(badge) unread" : title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    // MARK: - Header

    private var heading: String {
        var parts = [agent?.name ?? access.agentName]
        if let kind = agent?.agent, !kind.isEmpty, !parts.contains(kind) { parts.append(kind) }
        if let folder = agent?.guestFolder { parts.append(folder) }
        return parts.joined(separator: " · ")
    }

    /// The owner's agent header (#358): the round back button, the title (or the find
    /// field), and one capsule holding Find, Reconnect and ⋯ on the Terminal tab, ⋯ alone
    /// on Gram. No Share or Close: only the owner can invite people or close the agent.
    private var header: some View {
        HStack(spacing: 10) {
            PaneHeaderBackButton(identifier: "guest-back") { onClose() }
            if findOpen {
                InlineSearchField(
                    placeholder: "Find", text: $findTerm, focus: $findFocused,
                    matches: (index: findMatches.0, total: findMatches.1, capped: findMatches.2),
                    onNext: { stepFind(.forward) }, onPrevious: { stepFind(.backward) },
                    identifierPrefix: "guest-find")
            } else {
                Text(heading).font(Typography.app(16, .semibold))
                    .foregroundStyle(Palette.text).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            PaneHeaderCapsule {
                if !showingGram {
                    InlineSearchToggle(isOpen: findOpen, identifier: "guest-find",
                                       target: CGSize(width: 40, height: 44)) { toggleFind() }
                    PaneHeaderRefreshButton(identifier: "guest-refresh",
                                            refreshing: showingChat && chatModel.manualRefreshing) {
                        if showingChat {
                            Task { await chatModel.manualRefresh(client: client) }
                        } else {
                            streamGen += 1
                            Task { await refresh() }
                        }
                    }
                }
                actionsMenu
            }
        }
        .frame(height: max(44, (44 * Typography.scale).rounded()))
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 8)
    }

    /// This share's push is off (or iOS refuses it): the ⋯ shows the owner's amber struck bell.
    private var notificationsOff: Bool {
        switch guestPush.status(for: access) {
        case .off, .denied: return true
        case .on, .unavailable, .failed: return false
        }
    }

    /// The owner's ⋯, trimmed to what a guest may do: copy the screen or the recent output
    /// (`agent.read`) and the guest's own text size on the Terminal tab, and this share's
    /// notifications (GuestPushCenter, as in Guest Settings) on every tab.
    private var actionsMenu: some View {
        Menu {
            if showingTerminal {
                TerminalCopyMenuSection(client: client, paneID: access.agentTarget)
            }
            // Chat size remains available even when the host cannot resize the terminal.
            if showingChat || (showingTerminal && !resizeRefused &&
                               (availability == .running || availability == .connecting)) {
                TerminalTextSizeMenuSection(
                    increaseID: "guest-font-increase", decreaseID: "guest-font-decrease",
                    onIncrease: {
                        if showingChat { chatFontSize = ChatTextSize.stepped(chatFontSize, by: 1) }
                        else { terminalFontSize = GuestTerminalSize.stepped(terminalFontSize, by: 1) }
                    },
                    onDecrease: {
                        if showingChat { chatFontSize = ChatTextSize.stepped(chatFontSize, by: -1) }
                        else { terminalFontSize = GuestTerminalSize.stepped(terminalFontSize, by: -1) }
                    },
                    onReset: {
                        if showingChat { chatFontSize = ChatTextSize.defaultPoints }
                        else { terminalFontSize = GuestTerminalSize.defaultPoints }
                    })
            }
            if let action = guestPush.status(for: access).action {
                Button { runPushAction(action) } label: {
                    switch action {
                    case .turnOff: Label("Turn off notifications", systemImage: "bell.slash")
                    case .turnOn: Label("Turn on notifications", systemImage: "bell")
                    case .openSettings: Label("Allow notifications in Settings", systemImage: "gear")
                    case .retry: Label("Retry notifications", systemImage: "arrow.clockwise")
                    }
                }
                .accessibilityIdentifier("guest-notifications")
            }
        } label: {
            PaneActionsMenuLabel(notificationsOff: notificationsOff)
        }
        .accessibilityIdentifier("guest-actions")
        .accessibilityValue(notificationsOff ? "Notifications off" : "Notifications on")
    }

    private func runPushAction(_ action: GuestPushAction) {
        guard action != .openSettings else {
            guestPush.openSettings()
            return
        }
        Task { await guestPush.perform(action, access, client: client) }
    }

    /// The agent's status and "Shared by <owner>" under the header: the pill also carries
    /// CONNECTING / NOT RUNNING / OFFLINE / NEEDS <OWNER>, which the owner's title line has
    /// no room for beside the capsule.
    private var statusRow: some View {
        HStack(spacing: 8) {
            statusPill
            SharedByChip(owner: access.ownerName)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var statusPill: some View {
        switch availability {
        case .connecting:
            GuestStatusPill(label: "CONNECTING", color: Palette.textDim, dot: Palette.textFaint,
                            fill: Palette.surfaceRaised, pulsing: false)
        case .paused, .offline, .lost:
            GuestStatusPill(label: availability == .offline ? "OFFLINE" : availability == .lost ? "ACCESS REMOVED" : "NOT RUNNING",
                            color: Palette.textDim, dot: Palette.textFaint, fill: Palette.surfaceRaised,
                            pulsing: false)
        case .running:
            if waitingForOwner {
                GuestStatusPill(label: "NEEDS \(access.ownerName.uppercased())", color: Palette.waiting,
                                dot: Palette.waiting, fill: Palette.waiting.opacity(0.14), pulsing: false)
            } else {
                let group = agent.map { AgentRow(info: $0).group } ?? .working
                GuestStatusPill(label: group.sectionTitle, color: group.color, dot: group.color,
                                fill: group.color.opacity(0.13), pulsing: group == .working)
            }
        }
    }

    /// The agent waits on a menu or question: the state in which the host lets a guest
    /// press the menu keys (`agent_status` blocked or `input_pending`).
    private var isBlocked: Bool {
        availability == .running && agent?.isAwaitingMenuInput == true
    }

    /// Blocked, and this guest's host keeps answers for the owner (an older host refused one).
    private var waitingForOwner: Bool { isBlocked && chatModel.answersRefused }

    /// The owner's menu keys, under the terminal, while the guest may answer.
    private var showsMenuKeys: Bool { isBlocked && !chatModel.answersRefused && showingTerminal }

    // MARK: - Terminal

    private var findRequest: FindRequest? {
        guard findOpen else { return nil }
        return FindRequest(term: findTerm, generation: findGeneration, direction: findDirection)
    }

    private var terminalArea: some View {
        ZStack(alignment: .top) {
            Palette.groundMachine
            // Unmounted while the host refuses the stream, and remounted fresh on recovery.
            if availability == .connecting || availability == .running {
                LiveTerminalView(
                    client: client, paneID: access.agentTarget, viewOnly: true,
                    fitsStreamWidth: resizeRefused,
                    onResizeRefused: { resizeRefused = true },
                    onStreamEnded: streamEnded,
                    jumpToTailToken: jumpToTailToken,
                    onTailStateChange: { terminalAtTail = $0 },
                    onHistoryPagingChange: { terminalHistoryPaging = $0 },
                    loadEarlierHistoryToken: loadEarlierHistoryToken,
                    isAtTail: terminalAtTail,
                    fontSize: CGFloat(GuestTerminalSize.clamped(terminalFontSize)),
                    controlArmed: .constant(false),
                    findRequest: showingChat ? nil : findRequest,
                    onFindResult: { index, total in
                        if !showingChat { findMatches = (index, total, false) }
                    },
                    // A file dropped anywhere on the terminal joins the composer, under the
                    // paperclip's own rule: only while the guest may attach (#575).
                    fileDrop: showingTerminal && canAttach ? TerminalFileDrop(
                        onTargetChange: { terminalDropTargeted = $0 },
                        onDrop: { acceptDroppedFiles($0) }) : nil)
                    .id(streamGen)
                    .accessibilityIdentifier("guest-terminal")
                    // The owner's terminal inset.
                    .padding(.horizontal, 8)
                    // The composer's drop highlight, around the whole terminal while a file
                    // drag hovers it; never hit-tests.
                    .overlay {
                        if terminalDropTargeted && showingTerminal {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Palette.brand, lineWidth: 2)
                                .allowsHitTesting(false)
                                .accessibilityIdentifier("guest-terminal-drop-highlight")
                        }
                    }
                    // The owner's jump button while the guest reads history; a local scroll
                    // (view-only sends nothing).
                    .overlay(alignment: .bottom) {
                        ZStack {
                            if !terminalAtTail {
                                JumpToLatestButton(label: "Jump to latest output", identifier: "guest-latest",
                                                   regularGlass: true) { jumpToTailToken += 1 }
                                    .padding(.bottom, 16)
                            }
                        }
                        .animation(.easeInOut(duration: 0.15), value: terminalAtTail)
                    }
                    .overlay(alignment: .top) {
                        ZStack {
                            TerminalHistoryCapsule(state: terminalHistoryPaging, identifierPrefix: "guest") {
                                loadEarlierHistoryToken += 1
                            }
                        }
                        .animation(.easeInOut(duration: 0.15), value: terminalHistoryPaging)
                    }
            }
            if let message = centerMessage {
                GuestCenterMessage(icon: message.icon, title: message.title, detail: message.detail)
                    .padding(.horizontal, 24)
                    .padding(.top, 204)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var centerMessage: (icon: String, title: String, detail: String)? {
        switch availability {
        case .paused:
            return ("pause.fill", "\(access.agentName) isn't running",
                    "The shared agent isn't available in this terminal. Your messages and files so far are still in the transcript.")
        case .offline:
            return ("wifi.slash", "\(access.machineLabel) is offline",
                    "HerdrUp will reconnect when \(access.ownerName)'s machine is back online.")
        case .lost:
            return ("lock.fill", "Your access to \(access.agentName) has ended",
                    "\(access.ownerName) removed your access. Ask \(access.ownerName) for a new invite to talk to \(access.agentName) again.")
        case .connecting, .running:
            return nil
        }
    }

    // MARK: - Composer

    private var canCompose: Bool { availability == .running }
    /// When the composer takes an attachment: the paperclip's own enabled state, which a
    /// terminal drop shares.
    private var canAttach: Bool { canCompose && !sending && !loadingAttachment }

    private var hasContent: Bool {
        !attachments.isEmpty || !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The composer floats over the terminal, as the owner's does: only the note row and the
    /// composer's resting row take layout height, so a growing composer never resizes the
    /// agent's terminal.
    private var bottomBlock: some View {
        Color.clear
            .frame(height: bottomChromeHeight + ComposerStyle.restingHeight + 8)
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    Group {
                        if !showingTerminal && note == nil && connectionNote == nil && !isBlocked {
                            Color.clear.frame(height: 4)
                        } else {
                            VStack(spacing: 0) {
                                noteRow.padding(.top, 2).padding(.bottom, showsMenuKeys ? 4 : 10)
                                if showsMenuKeys {
                                    GuestMenuKeyBar(enabled: canCompose, send: sendMenuKey)
                                        .padding(.bottom, 6)
                                }
                            }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomChromeHeight = $0 }
                    composer
                        .environment(\.composerEditorRoom, terminalHeight)
                        // In Chat on iPad and Mac, the conversation column's width, centred under it.
                        .conversationColumn(showingChat)
                        .padding(.bottom, 8)
                }
                .fixedSize(horizontal: false, vertical: true)
                .background(pageGround)
            }
    }

    /// The single line above the composer: an error note when there is one, else the
    /// question banner, else the view-only reminder.
    @ViewBuilder
    private var noteRow: some View {
        HStack(spacing: 7) {
            if let text = note ?? connectionNote {
                Text(text).foregroundStyle(Palette.textDim)
                    .accessibilityIdentifier("guest-note")
            } else if waitingForOwner {
                Image(systemName: "clock").font(.system(size: 12, weight: .semibold))
                Text("\(access.agentName) is asking a question only \(access.ownerName) can answer")
                    .accessibilityIdentifier("guest-blocked-banner")
            } else if isBlocked {
                Image(systemName: "questionmark.circle").font(.system(size: 12, weight: .semibold))
                Text(showingTerminal ? "\(access.agentName) is asking a question · answer with the keys below"
                                     : "\(access.agentName) is asking a question")
                    .accessibilityIdentifier("guest-question-banner")
            } else if availability == .running || availability == .connecting {
                Image(systemName: "eye").font(.system(size: 12, weight: .semibold))
                Text(resizeRefused ? "View-only · this host doesn't support guest resizing"
                                   : "Terminal is view-only · send messages below")
                    .accessibilityIdentifier("guest-view-only-note")
            }
        }
        .font(Typography.app(12, .medium))
        .foregroundStyle(isBlocked && note == nil && connectionNote == nil ? Palette.waiting : Palette.textFaint)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 26)
        .padding(.horizontal, 16)
    }

    private var placeholder: Text {
        switch availability {
        case .connecting: return Text("Connecting…")
        case .paused: return Text("Agent unavailable")
        case .offline: return Text("Machine offline")
        case .lost: return Text("Access removed")
        case .running: break
        }
        let full = access.composerPlaceholder
        guard full.hasSuffix(access.guestName) else { return Text(full) }
        let lead = String(full.dropLast(access.guestName.count))
        return Text(lead) + Text(access.guestName).font(Typography.app(16, .medium)).foregroundColor(Palette.textDim)
    }

    private var composer: some View {
        AdaptiveComposer(
            text: reply,
            isFocused: replyFocused,
            hasAccessory: !attachments.isEmpty,
            // The standard reply bar's collapse button, while a software keyboard covers
            // the pane: the view-only terminal has nothing else to tap it away with.
            showsLeading: composerKeyboard.isVisible && !findFocused && replyFocused,
            isRecording: dictating
        ) { editorHeight in
            ComposerTextField(
                text: $reply,
                isEnabled: canCompose && !dictating,
                isFocused: replyFocused,
                onFocusChange: { replyFocused = $0 },
                placeholder: "",
                accessibilityIdentifier: "guest-composer-input",
                capitalization: .sentences,
                autocorrection: .default,
                onChange: { _, _ in note = nil },
                onCommandReturn: { send() },
                fixedHeight: editorHeight
            )
            .frame(minWidth: 0, maxWidth: .infinity)
            .overlay(alignment: .leading) {
                if reply.isEmpty && !dictating {
                    placeholder
                        .font(Typography.app(16))
                        .foregroundStyle(Palette.textDim)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
            }
        } accessory: {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachmentChip($0) }
                    }
                    .padding(.horizontal, 7)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        } leading: {
            Button { replyFocused = false } label: {
                ComposerActionIcon(image: Image("ComposerKeyboard"))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Collapse keyboard")
            .accessibilityIdentifier("guest-keyboard-button")
        } actions: {
            HStack(spacing: 4) {
                ComposerAttachButton(busy: loadingAttachment) { showAttachSheet = true }
                    .disabled(!canAttach)
                    .accessibilityIdentifier("guest-attach-button")
                MicButton(text: $reply, recording: $dictating)
                    .fixedSize()
                    .disabled(!canCompose || sending)
                    .accessibilityIdentifier("guest-mic-button")
                if hasContent {
                    Button { send() } label: {
                        ComposerActionIcon(image: Image("ComposerSend"), primary: true, busy: sending,
                                           progress: uploader.sendProgress(attachments, sending: sending))
                    }
                    .disabled(!canCompose || sending || dictating || loadingAttachment)
                    .fixedSize()
                    .accessibilityLabel("Send message")
                    .accessibilityIdentifier("guest-send-button")
                } else {
                    // The owner's saved prompts: a pick fills the composer and sends it as a
                    // message (`agent.prompt`), like a typed one.
                    SavedPromptsMenu { prompt in
                        reply = prompt.text
                        send()
                    }
                    .disabled(!canCompose || sending || dictating || loadingAttachment)
                    .accessibilityIdentifier("guest-saved-prompts")
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .opacity(canCompose ? 1 : 0.45)
        .disabled(!canCompose)
    }

    /// Staged picks or drops join the draft and start uploading at once, so Send only has
    /// to post them and prompt.
    private func addPicked(_ outcome: ComposerPickOutcome) {
        let picked = outcome.files.map {
            ComposerAttachment(name: $0.name, mime: $0.mime,
                               isImage: $0.mime.hasPrefix("image/"), staged: $0.staged)
        }
        attachments += picked
        uploader.start(picked, client: client, into: $attachments)
        note = outcome.note
    }

    /// Files dropped on the terminal (#575), staged by the composer's paste and drop rule
    /// (`PastedFile`) within the attachment cap, then added exactly as a paperclip pick.
    private func acceptDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        let files = TerminalFileDrop.files(in: providers)
        guard canAttach, !files.isEmpty else { return false }
        let room = ComposerStaging.maxAttachments - attachments.count
        loadingAttachment = true
        Task { @MainActor in
            let outcome = await PastedFile.stageAll(files, room: room)
            loadingAttachment = false
            addPicked(outcome)
        }
        return true
    }

    private func attachmentChip(_ file: ComposerAttachment) -> some View {
        let state = ComposerAttachmentState.for(
            file, upload: uploader.phase(of: file.id), sending: sending,
            sendingID: sendingAttachmentID, failedID: failedAttachmentID)
        // A file still uploading can go: removing it cancels its upload. Only a send in
        // flight holds the strip, so the batch it is delivering stays whole.
        return ComposerAttachmentChip(
            name: file.name, size: file.staged.size, isImage: file.isImage, state: state,
            canRemove: !sending,
            onRemove: { removeAttachment(file.id) },
            onRetry: { uploader.retry(file.id) }
        )
    }

    private func removeAttachment(_ id: UUID) {
        guard let current = attachments.first(where: { $0.id == id }) else { return }
        attachments.removeAll { $0.id == id }
        // Cancels a running upload, deletes the staged bytes, and discards a finished upload.
        uploader.remove(current)
    }

    // MARK: - Find

    private func toggleFind() {
        if findOpen {
            findOpen = false
            findTerm = ""
            findMatches = (0, 0, false)
            findFocused = false
        } else {
            findOpen = true
            findFocused = true
        }
    }

    private func stepFind(_ direction: FindRequest.Direction) {
        guard !findTerm.isEmpty else { return }
        findDirection = direction
        findGeneration += 1
    }

    // MARK: - Status

    private func pollLoop() async {
        while !Task.isCancelled, availability != .lost {
            await refresh()
            try? await Task.sleep(nanoseconds: Self.pollNanoseconds)
        }
    }

    private func refresh() async {
        do {
            let agents = try await client.agentList()
            // The grant's terminal or pane id first; name may be null in a guest's projection.
            let shared = agents.first(where: access.isSharedAgent)
                ?? agents.first { $0.name == access.agentName }
            agent = shared ?? agent
            connectionNote = nil
            // No agent, or one the host says isn't in the foreground: paused.
            if let shared, shared.guestRunning != false {
                setAvailability(.running)
            } else {
                setAvailability(.paused)
            }
        } catch {
            // Anything but a change of availability (host busy, a dropped or refused
            // connection) is worth retrying: say so and keep polling.
            connectionNote = apply(error) ? nil
                : "Can't reach \(access.machineLabel) (\(GuestError.classify(error)?.description ?? error.localizedDescription)). Trying again…"
        }
    }

    private func setAvailability(_ next: Availability) {
        guard availability != .lost, next != availability else { return }
        let resuming = next == .running && availability != .connecting
        availability = next
        if resuming { streamGen += 1 }
    }

    /// Maps a failed call or stream onto the screen; returns true when it was handled as a
    /// change of availability rather than a one-off failure.
    @discardableResult
    private func apply(_ error: Error) -> Bool {
        guard let guest = GuestError.classify(error) else { return false }
        if guest.isAccessLost || guest == .revoked {
            setAvailability(.lost)
        } else if guest == .paused {
            setAvailability(.paused)
        } else if guest == .hostOffline {
            setAvailability(.offline)
        } else {
            return false
        }
        return true
    }

    private func streamEnded(_ error: Error?) {
        guard let error, apply(error) else { return }
        Task { await refresh() }
    }

    // MARK: - Menu keys

    /// Presses one of the owner's menu keys in the shared agent's pane (`pane.send_keys`).
    /// The host takes these from a guest only while the agent waits on a menu, and only
    /// `GuestMenuKeyBar.keys`. A refusal while the agent still waits, from a host that has
    /// never taken one of this guest's keys, means an older host that keeps answers for the
    /// owner: back to waiting for them. Any other refusal is a race (the menu closed, or the
    /// pause after a committing key), and the next poll settles the screen.
    private func sendMenuKey(_ key: String) {
        guard GuestMenuKeyBar.keys.contains(key), let pane = agent?.paneID else { return }
        let previous = menuKeyTask
        menuKeyTask = Task {
            await previous?.value
            guard !Task.isCancelled, !chatModel.answersRefused else { return }
            do {
                try await client.sendPaneKeys(pane: pane, keys: [key])
                hostTookAMenuKey = true
                note = nil
            } catch is CancellationError {
                return
            } catch let error where GuestError.classify(error) == .forbidden {
                await refresh()
                if isBlocked, !hostTookAMenuKey { chatModel.noteAnswersRefused() }
            } catch {
                note = failureNote(error)
            }
        }
    }

    // MARK: - Send

    private func send() {
        guard canCompose, !sending, !dictating, !loadingAttachment, hasContent else { return }
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= Self.maxPromptBytes else {
            note = "Messages are limited to 32 KB. Send it in parts, or attach it as a file."
            return
        }
        sending = true
        note = nil
        let batch = attachments
        let outgoingID = showingChat ? chatModel.stageOutgoing(
            text: text, author: .guest(name: access.guestName), files: batch) : nil
        let clearedReply = reply
        reply = ""
        // Leaving the app or locking the phone mid-upload suspends it, which drops the
        // relay connection and fails the send; this keeps it running for iOS's grace period.
        let background = BackgroundAssertion(name: "herdr.guest.send")
        Task {
            defer { sending = false; sendingAttachmentID = nil; background.end() }
            failedAttachmentID = nil
            var promptAttempted = false
            if let outgoingID, !(await chatModel.prepareOutgoing(outgoingID, client: client)) {
                if reply.isEmpty { reply = clearedReply }
                return
            }
            do {
                var prompt = text
                if !batch.isEmpty {
                    let delivered = try await deliver(batch)
                    prompt = GramAttachmentPrompt.text(text, delivered: delivered)
                }
                chatModel.updateOutgoing(outgoingID, state: .sending, wireText: prompt)
                promptAttempted = true
                let receipt = try await client.prompt(
                    pane: access.agentTarget, text: prompt,
                    waitUntil: HerdrClient.anyAgentStatus, timeoutMs: 6000)
                chatModel.updateOutgoing(outgoingID, state: receipt == .submitted ? .submitted : .unconfirmed)
                // Each file's staged bytes went when its gram posted (the sender), and each
                // post consumed its upload: nothing left on the host to discard.
                let sentIDs = Set(batch.map(\.id))
                attachments.removeAll { sentIDs.contains($0.id) }
                uploader.forget(sentIDs)
                if reply.trimmingCharacters(in: .whitespacesAndNewlines) == text { reply = "" }
                // Attachments are the guest's own Grams: show them in the Gram tab.
                if !batch.isEmpty, showsGram { await gram.refresh(client: client, access: access) }
            } catch {
                note = failureNote(error)
                let state: TranscriptSendState
                if !promptAttempted {
                    state = .notDelivered("Attachment upload did not complete.")
                } else if let api = error as? APIError {
                    state = TranscriptSendState(rejection: api)
                } else {
                    state = .unconfirmed
                }
                chatModel.updateOutgoing(outgoingID, state: state)
                if case .notDelivered = state {
                    if reply.isEmpty { reply = clearedReply }
                } else {
                    // An uncertain response must not leave a one-tap duplicate send.
                    let sentIDs = Set(batch.map(\.id))
                    attachments.removeAll { sentIDs.contains($0.id) }
                    uploader.forget(sentIDs)
                }
            }
            // The request returned: look for the prompt in the transcript now rather than
            // at the next poll (guests have no event stream).
            if outgoingID != nil, promptAttempted {
                Task { await chatModel.refresh(client: client) }
            }
        }
    }

    /// Posts each staged file as a gram to the shared agent (`GramAttachmentSender`),
    /// remembering each step so a retry after a failure resumes rather than re-sends. Each
    /// file has been uploading since it was added (`uploader`): the ones that landed post at
    /// once, the rest are awaited, and only one whose upload failed or the host lost
    /// uploads here.
    private func deliver(_ batch: [ComposerAttachment]) async throws -> [GramAttachmentPrompt.Delivered] {
        let target = access.liveAgentName(listed: agent)
        let sender = uploader.sender(client: client, into: $attachments, post: { _, attachment in
            try await client.guestGramPost(
                text: "Attachment from \(access.guestName).", to: target,
                attachment: attachment
            ).id
        })
        let result = await sender.send(batch, sending: { sendingAttachmentID = $0.id }) { file in
            guard let index = attachments.firstIndex(where: { $0.id == file.id }) else { return }
            attachments[index] = file
        }
        switch result {
        case .success(let delivered):
            return delivered
        case .failure(let failure):
            failedAttachmentID = failure.attachment.id
            throw failure.error
        }
    }

    private func failureNote(_ error: Error) -> String {
        if let guest = GuestError.classify(error) {
            apply(error)
            switch guest {
            case .paused: return "\(access.agentName) isn't running, so it wasn't sent."
            case .revoked: return "\(access.ownerName) revoked your access."
            case .forbidden: return "\(access.ownerName)'s machine doesn't allow that."
            default: return guest.description
            }
        }
        if let api = error as? APIError, api.code == "invalid_params" {
            return "\(access.ownerName)'s machine refused the message: \(api.message)"
        }
        return "Couldn't send: \(error.localizedDescription)"
    }

    // MARK: - Debug probes

    #if DEBUG
    /// For the UI tests: methods the mock host refused as not allowed for guests
    /// (`guest-forbidden-calls`), and the Gram and push calls it answered, with their
    /// arguments (`guest-host-calls`).
    private var debugProbes: some View {
        ZStack {
            Color.clear
                .accessibilityElement()
                .accessibilityIdentifier("guest-forbidden-calls")
                .accessibilityLabel(forbiddenProbe)
            Color.clear
                .accessibilityElement()
                .accessibilityIdentifier("guest-host-calls")
                .accessibilityLabel(hostCallsProbe)
            Color.clear
                .accessibilityElement()
                .accessibilityIdentifier("guest-stream-opens")
                .accessibilityLabel(streamOpensProbe)
        }
        .frame(width: 1, height: 1)
        .overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.environment["HERDR_MOCK_DELAYED_DROP"] == "1" {
                HStack {
                    Button("Drop file") {
                        let provider = NSItemProvider()
                        provider.suggestedName = "delayed-report.pdf"
                        provider.registerDataRepresentation(
                            forTypeIdentifier: "com.adobe.pdf", visibility: .all
                        ) { completion in
                            Task { @MainActor in delayedDropCompletion = completion }
                            return nil
                        }
                        acceptDroppedFiles([provider])
                    }
                    .accessibilityIdentifier("guest-fixture-drop-file")
                    Button("Finish staging") {
                        let completion = delayedDropCompletion
                        delayedDropCompletion = nil
                        completion?(Data("%PDF-1.4 delayed drop\n".utf8), nil)
                    }
                    .disabled(delayedDropCompletion == nil)
                    .accessibilityIdentifier("guest-fixture-finish-staging")
                    Button("Send shortcut") { send() }
                        .accessibilityIdentifier("guest-fixture-send-shortcut")
                }
                .buttonStyle(.bordered)
                .fixedSize()
                .offset(x: 12, y: 80)
            }
        }
        .task {
            while !Task.isCancelled {
                forbiddenProbe = GuestMockTransport.forbiddenCalls.joined(separator: ",")
                hostCallsProbe = GuestMockTransport.hostCalls.joined(separator: ";")
                streamOpensProbe = "\(GuestMockTransport.streamOpens)"
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
    #endif
}

extension AgentInfo {
    /// The folder a guest sees for this agent: the nearest cwd component that isn't just the
    /// agent's own name or kind ("~/repos/llm-opt" for llm-opt → "repos").
    var guestFolder: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let skip = Set([name, agent].compactMap { $0 })
        return URL(fileURLWithPath: cwd).pathComponents.reversed()
            .first { $0 != "/" && $0 != "." && !skip.contains($0) }
    }
}

/// The status pill of the guest pane's status row.
private struct GuestStatusPill: View {
    let label: String
    let color: Color
    let dot: Color
    let fill: Color
    let pulsing: Bool

    var body: some View {
        HStack(spacing: 7) {
            PulsingDot(color: dot, active: pulsing)
            Text(label).font(Typography.machine(12, .semibold)).tracking(1.2)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 11)
        .frame(height: 26)
        .background(Capsule().fill(fill))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("guest-status-pill")
    }
}

/// "Shared by <owner>": whose agent the guest is looking at.
struct SharedByChip: View {
    let owner: String

    var body: some View {
        Text("Shared by \(owner)")
            .font(Typography.app(12, .medium))
            .foregroundStyle(Palette.textDim)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

/// The card over the terminal when the agent can't be reached.
private struct GuestCenterMessage: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.textDim)
                .frame(width: 46, height: 46)
                .background(Circle().fill(Palette.surfaceRaised))
                .padding(.bottom, 12)
            Text(title)
                .font(Typography.app(17, .semibold)).foregroundStyle(Palette.text)
                .padding(.bottom, 6)
            Text(detail)
                .font(Typography.app(14)).foregroundStyle(Palette.textDim)
                .lineSpacing(5)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22).padding(.horizontal, 20)
        .background(RoundedRectangle(cornerRadius: 20).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Palette.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("guest-center-message")
    }
}

/// The owner's menu keys (the terminal's quick-key row: esc, space, arrows, tab and the
/// pinned Return), for a guest answering a plan approval, a permission prompt or a
/// multi-part question. Only keys a guest's host accepts, and nothing that types text.
struct GuestMenuKeyBar: View {
    /// Every key this bar sends; the host's guest gate allows exactly these and digits, y, n.
    static let keys: Set<String> = ["Escape", "Space", "Left", "Up", "Down", "Right", "Tab", "Enter"]

    let enabled: Bool
    let send: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    keyCap(label: "esc", key: "Escape")
                    keyCap(label: "space", key: "Space", minWidth: 84)
                    ComposerKeyGroup {
                        keyCap(image: "ComposerKeyLeft", key: "Left", grouped: true)
                        ComposerKeyDivider()
                        keyCap(image: "ComposerKeyUp", key: "Up", grouped: true)
                        ComposerKeyDivider()
                        keyCap(image: "ComposerKeyDown", key: "Down", grouped: true)
                        ComposerKeyDivider()
                        keyCap(image: "ComposerKeyRight", key: "Right", grouped: true)
                    }
                    keyCap(label: "tab", key: "Tab")
                }
                .padding(.leading, 16).padding(.trailing, 12).padding(.vertical, 4)
            }
            // Keys fade out just before the pinned Return instead of sliding under it.
            .mask(
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 16)
                }
            )
            keyCap(image: "ComposerKeyEnter", key: "Enter", primary: true)
                .padding(.trailing, 16)
        }
        .disabled(!enabled)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guest-menu-keys")
    }

    private func keyCap(label: String? = nil, image: String? = nil, key: String, primary: Bool = false,
                        grouped: Bool = false, minWidth: CGFloat = 44) -> some View {
        Button { send(key) } label: {
            ComposerQuickKeyLabel(text: label ?? key, imageName: image, primary: primary,
                                  grouped: grouped, minWidth: minWidth)
        }
        .accessibilityLabel(Text(key))
    }
}
