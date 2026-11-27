import Combine
import Foundation
import HerdrKit
import UIKit

/// What this device remembers about the signed-in account, besides the refresh token in the
/// Keychain: which provider signed in (deletion asks the same one again, DESIGN #698 §6.1) and
/// Apple's user id (the launch credential check, §2.5). Nothing secret. Google's email
/// (`display_hint`) lives beside the session in the Keychain (`AccountHintStore`), not here.
struct AccountProfile: Codable, Equatable {
    var provider: AccountProvider
    var appleUserID: String?
}

/// Something the account screens tell the person: a refusal from the service, a sync that left
/// something behind, or what deletion did.
struct AccountNotice: Identifiable, Equatable {
    enum Action: Equatable {
        /// `device_in_other_account`: sign out here, then sign in to the other account.
        case signOut
    }

    let id = UUID()
    let title: String
    let message: String
    var action: Action?
}

/// The HerdrUp account on this device (DESIGN #698 §2, §3.2, §5, §6.1): sign-in with Apple or
/// Google, this install's guest key enrolled as a device, machine and prompt sync, sign-out and
/// deletion. Built on HerdrKit's `AccountSession`, `DeviceEnroller`, `StatementCache` and
/// `SyncEngine`; the app's own copies (`SavedHostsStore`, `SavedPromptsStore`) stay the source of
/// what the app shows, and HerdrKit's `AccountLocalSync` keeps them and the account in step.
@MainActor
final class HerdrUpAccount: ObservableObject {
    static let shared = HerdrUpAccount()

    enum Busy: Equatable {
        case signingIn(AccountProvider)
        case syncing
        case signingOut
        case deleting
    }

    enum Enrolment: Equatable {
        case unknown
        case enrolling
        case enrolled(AccountDevice)
        /// The service's refusal code (`too_many_devices`, `device_in_other_account`, …), or
        /// `unreachable`.
        case failed(String)
    }

    /// The service's features, read at launch and whenever a sign-in screen shows. Nil until
    /// the first answer; `healthFailed` when it couldn't be read.
    @Published private(set) var health: AccountHealth?
    @Published private(set) var healthFailed = false
    @Published private(set) var signedIn: Bool
    @Published private(set) var profile: AccountProfile?
    @Published private(set) var displayHint: String?
    @Published private(set) var devices: [AccountDevice] = []
    @Published private(set) var enrolment: Enrolment = .unknown
    @Published private(set) var busy: Busy?
    @Published private(set) var lastSync: AccountSyncSummary?
    @Published private(set) var syncing = false
    /// The last sync failed (or the account is full); a later successful sync clears it.
    @Published private(set) var syncFailed = false
    /// How many machines and prompts the account holds, as of the last sync.
    @Published private(set) var syncedCounts = (hosts: 0, prompts: 0)
    /// The account page is on screen and shows `notice` itself; the root shows it otherwise.
    @Published var screenVisible = false
    @Published var notice: AccountNotice?
    /// The first-launch sign-in screen (1B) was answered: signed in, or "Set up without an
    /// account".
    @Published private(set) var onboardingDone: Bool

    let session: AccountSession
    let statements: StatementCache
    let sync: SyncEngine
    private let providers: AccountProviderSignIn
    private let defaults: UserDefaults
    /// One sync at a time; one asked for during a sync runs once more after it (#776 F2).
    private var syncLoop: AccountSyncLoop!
    /// The next sync's failure is shown even when the service is unreachable (the first sync
    /// after sign-in, or one the person asked for).
    private var reportNextSyncFailure = false
    private var lastAutoSync = Date.distantPast
    private var started = false
    private var cancellables: Set<AnyCancellable> = []
    /// True while a sync applies the account's copy to the local stores, so those changes
    /// don't count as local edits to push.
    private var applying = false
    /// The signed-in account's id, known from the first sync of this process on. Shares added
    /// here are claimed for it (`AccountShareLedger`).
    private var accountID: String?
    /// The file the sync state lives in, so a sign-out that couldn't delete it can retry.
    private let syncStore: SyncStateStore
    /// Where the session's display hint lives: the Keychain item beside the refresh token.
    private let hints: AccountHintStore

    private static let profileKey = "account.profile.v1"
    private static let onboardingKey = "account.onboarding.done"
    /// A sign-out whose synced copy couldn't be deleted: retried at launch and before the next
    /// sign-in.
    private static let cleanupKey = "account.sync.cleanupPending"
    /// The stored display hint couldn't be deleted or replaced: it may name another account (or
    /// an earlier one), so it is never restored, and its delete is retried at each launch.
    private static let hintCleanupKey = "account.hint.cleanupPending"

    private init() {
        let client: AccountClient
        let tokens: AccountTokenStore
        let hints: AccountHintStore
        var syncStore: SyncStateStore
        #if DEBUG
        if ScreenshotMock.mode != nil {
            let mock = MockAccountService.shared
            client = mock.client
            tokens = mock.tokenStore
            hints = mock.hintStore
            syncStore = InMemorySyncStateStore()
            providers = mock
            defaults = mock.defaults
        } else {
            client = AccountClient()
            let keychain = KeychainAccountTokenStore()
            tokens = keychain
            hints = keychain
            syncStore = (try? FileSyncStateStore.standard()) ?? InMemorySyncStateStore()
            providers = NativeProviderSignIn()
            defaults = .standard
        }
        #else
        client = AccountClient()
        let keychain = KeychainAccountTokenStore()
        tokens = keychain
        hints = keychain
        syncStore = (try? FileSyncStateStore.standard()) ?? InMemorySyncStateStore()
        providers = NativeProviderSignIn()
        defaults = .standard
        #endif
        session = AccountSession(client: client, store: tokens) { reason in
            Task { @MainActor in HerdrUpAccount.shared.sessionEnded(reason) }
        }
        statements = StatementCache(session: session)
        var profile = defaults.data(forKey: Self.profileKey).flatMap { try? JSONDecoder().decode(AccountProfile.self, from: $0) }
        // The session is the refresh token, not the profile: `AccountSession` deletes the token
        // first and the rest is cleared after, so a kill in between leaves a profile (and a
        // hint) with no token. That is signed out. A Keychain that can't be read right now
        // (nil here) leaves the decision to `start()`, which asks the session again.
        let tokenStored: Bool?
        do { tokenStored = try tokens.loadRefreshToken() != nil } catch { tokenStored = nil }
        if tokenStored == false, profile != nil {
            profile = nil
            defaults.removeObject(forKey: Self.profileKey)
        }
        // No session, or a sign-out that didn't finish: the synced copy belongs to no one, so
        // it is deleted before anything loads it. If that fails, this launch keeps sync state
        // in memory and the delete is tried again.
        if profile == nil || defaults.bool(forKey: Self.cleanupKey) {
            do {
                try syncStore.deleteSyncState()
                defaults.removeObject(forKey: Self.cleanupKey)
            } catch {
                defaults.set(true, forKey: Self.cleanupKey)
                syncStore = InMemorySyncStateStore()
            }
        }
        self.syncStore = syncStore
        self.hints = hints
        sync = Self.engine(session: session, store: syncStore)
        self.profile = profile
        signedIn = profile != nil
        onboardingDone = defaults.bool(forKey: Self.onboardingKey)
        syncLoop = AccountSyncLoop { [weak self] in await self?.runSync() }
        // The email shown for the session: restored only with a stored token and only when no
        // earlier delete or replace of it failed; otherwise it is deleted (and retried).
        if tokenStored == true, profile != nil, !defaults.bool(forKey: Self.hintCleanupKey) {
            displayHint = try? hints.loadDisplayHint()
        } else if tokenStored != nil || defaults.bool(forKey: Self.hintCleanupKey) {
            deleteStoredHint()
        }
    }

    /// Keeps the email the service passed at sign-in (Google's `display_hint`) beside the
    /// session, so the account shows it after a relaunch; nil deletes it (sign-out, an ended
    /// session, deletion, an Apple sign-in without one). Best effort: a Keychain that refuses
    /// costs only the initial on the next launch.
    private func rememberDisplayHint(_ hint: String?) {
        displayHint = hint
        guard let hint, !hint.isEmpty else { return deleteStoredHint() }
        do {
            try hints.saveDisplayHint(hint)
            defaults.removeObject(forKey: Self.hintCleanupKey)
        } catch {
            // The previous account's hint may still be stored: never restore it, delete it.
            deleteStoredHint()
        }
    }

    /// Deletes the stored hint. A failed delete is remembered (`hintCleanupKey`): the stored
    /// hint is then never restored, and the delete is tried again at the next launch.
    private func deleteStoredHint() {
        do {
            try hints.deleteDisplayHint()
            defaults.removeObject(forKey: Self.hintCleanupKey)
        } catch {
            defaults.set(true, forKey: Self.hintCleanupKey)
        }
    }

    /// The sync engine over `store`. An unreadable state file is deleted, and the next sync
    /// is a full pull, which rebuilds it.
    private static func engine(session: AccountSession, store: SyncStateStore) -> SyncEngine {
        if let engine = try? SyncEngine(session: session, store: store) { return engine }
        try? store.deleteSyncState()
        if let engine = try? SyncEngine(session: session, store: store) { return engine }
        // A store that can't even read "nothing": keep this launch's state in memory.
        do {
            return try SyncEngine(session: session, store: InMemorySyncStateStore())
        } catch {
            preconditionFailure("an empty in-memory sync state always loads")
        }
    }

    // MARK: Launch

    /// Called once from the root view: reads the service's features, confirms the session the
    /// profile claims, checks Apple's credential state, and syncs. Also starts watching local
    /// edits so they reach the account.
    func start() {
        guard !started else { return }
        started = true
        observeLocalEdits()
        NotificationCenter.default.addObserver(forName: AppleCredentialWatch.revokedNotification, object: nil,
                                               queue: .main) { _ in
            Task { @MainActor in await HerdrUpAccount.shared.appleCredentialRevoked() }
        }
        Task {
            // The session first (a Keychain read), so a stale profile never shows as signed in
            // while the network answers.
            let stored = (try? await session.isSignedIn()) ?? signedIn
            if !stored {
                if profile != nil { forgetProfile() }
                deleteStoredHint()
                displayHint = nil
            } else if displayHint == nil, !defaults.bool(forKey: Self.hintCleanupKey) {
                // The Keychain couldn't be read at init: restore the hint now the session is known.
                displayHint = try? hints.loadDisplayHint()
            }
            if stored, profile == nil {
                // A session without a profile (an older build's): ask which provider at deletion.
                profile = AccountProfile(provider: .apple, appleUserID: nil)
            }
            signedIn = stored
            await loadHealth()
            guard stored else { return }
            if let user = profile?.appleUserID, profile?.provider == .apple,
               await AppleCredentialWatch.isRevoked(userID: user) {
                await appleCredentialRevoked()
                return
            }
            await refreshDevices()
            foregrounded()
        }
    }

    /// Back in the foreground: sync, at most once a minute.
    func foregrounded() {
        guard signedIn, Date().timeIntervalSince(lastAutoSync) > 60 else { return }
        lastAutoSync = Date()
        localEditSync()
    }

    func loadHealth() async {
        do {
            health = try await session.client.health()
            healthFailed = false
        } catch {
            if health == nil { healthFailed = true }
        }
    }

    /// Apple sign-in is offered when the service takes native ID tokens (§2.1).
    var offersApple: Bool { health?.offers(AccountHealth.nativeSignIn) == true }

    /// Google needs the service to know the Google iOS client, and this build to carry it.
    var offersGoogle: Bool {
        guard health?.offers(AccountHealth.nativeSignIn) == true,
              health?.offers(AccountHealth.nativeSignInGoogle) == true else { return false }
        #if DEBUG
        if ScreenshotMock.mode != nil { return true }
        #endif
        return (Bundle.main.object(forInfoDictionaryKey: "HerdrGoogleIOSClientID") as? String)?.isEmpty == false
    }

    /// The first-launch screen (1B) shows until it is answered, and only while this device has
    /// no account, no saved machine and no share: anyone already set up keeps today's list. A
    /// sign-in started there stays there until its first sync has brought the machines.
    func shouldOnboard(hasMachines: Bool, hasShares: Bool) -> Bool {
        !onboardingDone && !hasMachines && !hasShares && (!signedIn || busy != nil)
    }

    /// "Set up without an account": today's machine list, exactly as before.
    func skipOnboarding() {
        setOnboardingDone()
    }

    private func setOnboardingDone() {
        onboardingDone = true
        defaults.set(true, forKey: Self.onboardingKey)
    }

    // MARK: Sign-in

    /// Signs in with `provider`, enrols this device, then runs the first sync (pull first,
    /// adopt matching machines, push the rest; DESIGN §5.5).
    func signIn(_ provider: AccountProvider) async {
        guard busy == nil, !signedIn else { return }
        // A sign-out that couldn't delete the last account's synced copy finishes first, so
        // that copy can never be pushed into this account.
        guard finishPendingCleanup() else {
            notice = AccountNotice(title: "Couldn't sign in",
                                   message: "The last sign-out couldn't delete its synced copy on this \(Self.deviceKind). Restart herdrup and try again.")
            return
        }
        busy = .signingIn(provider)
        defer { if busy == .signingIn(provider) { busy = nil } }
        do {
            let nonce = try await session.nonce()
            let credential = try await providers.signIn(provider, nonce: nonce.nonce)
            let answer = try await session.signIn(provider: provider, idToken: credential.idToken,
                                                  nonce: nonce.nonce, platform: Self.platform)
            saveProfile(AccountProfile(provider: provider, appleUserID: credential.appleUserID))
            rememberDisplayHint(answer.displayHint)
            signedIn = true
        } catch ProviderSignInError.cancelled {
            return
        } catch {
            notice = AccountNotice(title: "Couldn't sign in", message: Self.describe(error))
            return
        }
        await enrolThisDevice()
        busy = .syncing
        reportNextSyncFailure = true
        syncLoop.request()
        await syncLoop.waitUntilIdle()
        await refreshDevices()
        setOnboardingDone()
        busy = nil
    }

    // MARK: Devices (DESIGN §3.2)

    /// Enrols this install's guest key (the one every share already knows) as a device.
    func enrolThisDevice() async {
        guard signedIn else { return }
        enrolment = .enrolling
        do {
            let device = try await DeviceEnroller(session: session, keyStore: GuestDevice.keyStore)
                .enrol(name: Self.deviceName, platform: Self.platform)
            enrolment = .enrolled(device)
        } catch AccountError.signedOut {
            enrolment = .unknown
        } catch let error as AccountError {
            let code = error.code ?? "unreachable"
            enrolment = .failed(code)
            switch code {
            case "device_in_other_account":
                notice = AccountNotice(
                    title: "This \(Self.deviceKind) belongs to another account",
                    message: "Its device key is already part of another HerdrUp account, and a key belongs to one account at a time. Sign out here, sign in to that account and remove this \(Self.deviceKind) from its devices, then sign in again.",
                    action: .signOut)
            case "too_many_devices":
                notice = AccountNotice(
                    title: "Too many devices",
                    message: "This account already has 20 devices. Remove one in Settings › HerdrUp account, then try again. Sync still works without it.")
            default:
                break
            }
        } catch {
            enrolment = .failed("unreachable")
        }
    }

    func refreshDevices() async {
        guard signedIn else { return }
        guard let list = try? await session.devices() else { return }
        devices = list.sorted { ($0.current ? 0 : 1, $0.createdMs) < ($1.current ? 0 : 1, $1.createdMs) }
        if let current = list.first(where: \.current) {
            enrolment = .enrolled(current)
        } else if enrolment == .unknown {
            await enrolThisDevice()
        }
    }

    func renameDevice(_ device: AccountDevice, to name: String) async {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        guard !trimmed.isEmpty, trimmed != device.name else { return }
        do {
            _ = try await session.renameDevice(id: device.id, name: trimmed)
            await refreshDevices()
        } catch {
            notice = AccountNotice(title: "Couldn't rename \(device.name)", message: Self.describe(error))
        }
    }

    /// Removing this device ends this session too (the service drops its sessions).
    func removeDevice(_ device: AccountDevice) async {
        do {
            try await session.removeDevice(device)
            if !device.current { await refreshDevices() }
        } catch {
            notice = AccountNotice(title: "Couldn't remove \(device.name)", message: Self.describe(error))
        }
    }

    // MARK: Sign-out and deletion

    /// Ends the session (on the service when it can be reached). Machines and prompts stay.
    func signOut() async {
        guard signedIn, busy != .signingOut else { return }
        busy = .signingOut
        defer { busy = nil }
        await session.signOut()
        // `onSignOut` clears the rest; make sure it ran even when the session was already gone.
        await clearAfterSignOut()
    }

    /// DESIGN §6.1: a fresh sign-in with the same provider confirms, then the service deletes
    /// everything. Apple's grant is revoked with the fresh authorization code; when Apple didn't
    /// confirm, the person gets Apple's manual steps.
    func deleteAccount() async {
        guard signedIn, busy == nil else { return }
        let provider = profile?.provider ?? .apple
        busy = .deleting
        defer { busy = nil }
        do {
            let nonce = try await session.nonce()
            let credential = try await providers.signIn(provider, nonce: nonce.nonce)
            let result = try await session.deleteAccount(provider: provider, idToken: credential.idToken,
                                                         nonce: nonce.nonce,
                                                         authorizationCode: provider == .apple ? credential.authorizationCode : nil)
            await clearAfterSignOut()
            if result.manualRevoke && provider == .apple {
                notice = AccountNotice(
                    title: "Account deleted",
                    message: "Your HerdrUp account is gone. Apple didn't confirm that HerdrUp stopped using your Apple ID, so finish it there: Settings › Apple Account › Sign in with Apple › HerdrUp › Stop Using. Your machines and prompts stay on this \(Self.deviceKind).")
            } else {
                notice = AccountNotice(
                    title: "Account deleted",
                    message: "Your HerdrUp account and everything synced to it are gone. Your machines and prompts stay on this \(Self.deviceKind).")
            }
        } catch ProviderSignInError.cancelled {
            return
        } catch AccountError.refused(_, "wrong_account", _, _, _) {
            notice = AccountNotice(title: "That's another account",
                                   message: "Sign in with the \(provider == .apple ? "Apple ID" : "Google account") this HerdrUp account uses to delete it.")
        } catch {
            notice = AccountNotice(title: "Couldn't delete the account", message: Self.describe(error))
        }
    }

    /// `AccountSession.onSignOut`, on the main actor (HerdrKit's guidance): statements and the
    /// sync state go; the app's machines and prompts stay.
    private func sessionEnded(_ reason: AccountSession.SignOutReason) {
        let wasSignedIn = signedIn
        Task { await clearAfterSignOut() }
        if wasSignedIn, reason == .sessionEnded || reason == .sessionRevoked {
            notice = AccountNotice(title: "Signed out of your HerdrUp account",
                                   message: "The account ended this session. Your machines and prompts stay on this \(Self.deviceKind); sign in again to sync.")
        }
    }

    private func clearAfterSignOut() async {
        syncLoop.cancel()
        await statements.clear()
        do {
            try await sync.clear()
        } catch {
            // The synced copy is still on disk: the sign-out isn't finished. It is deleted at
            // the next launch (before anything loads it) or the next sign-in, whichever is first.
            defaults.set(true, forKey: Self.cleanupKey)
            notice = AccountNotice(title: "Sign-out didn't finish",
                                   message: "Your machines and prompts stay on this \(Self.deviceKind), but the account's synced copy couldn't be deleted. herdrup tries again when it next opens.")
        }
        SavedStoresAccountLocal.forget(defaults)
        // The ledger stays with the shares: which account each belongs to, and leaves still
        // to write (#849 review F1).
        SharedMachinesStore.shared.setAccountShares([])
        accountID = nil
        forgetProfile()
        signedIn = false
        rememberDisplayHint(nil)
        devices = []
        enrolment = .unknown
        lastSync = nil
        syncFailed = false
        syncedCounts = (0, 0)
    }

    private func appleCredentialRevoked() async {
        guard signedIn, profile?.provider == .apple else { return }
        await session.signOut()
        await clearAfterSignOut()
        notice = AccountNotice(title: "Signed out of your HerdrUp account",
                               message: "Sign in with Apple was turned off for HerdrUp. Your machines and prompts stay on this \(Self.deviceKind).")
    }

    private func saveProfile(_ profile: AccountProfile) {
        self.profile = profile
        defaults.set(try? JSONEncoder().encode(profile), forKey: Self.profileKey)
    }

    private func forgetProfile() {
        profile = nil
        defaults.removeObject(forKey: Self.profileKey)
    }

    // MARK: Sync (DESIGN §5)

    /// Syncs now. A sync asked for while one runs makes it run once more when it ends, so an
    /// edit made meanwhile is pushed (#776 F2).
    func syncNow() {
        guard signedIn else { return }
        reportNextSyncFailure = true
        syncLoop.request()
    }

    /// A local edit: sync, quietly when the service can't be reached.
    private func localEditSync() {
        guard signedIn else { return }
        syncLoop.request()
    }

    /// Deletes a synced copy a sign-out left behind. True when there is none (any more).
    private func finishPendingCleanup() -> Bool {
        guard defaults.bool(forKey: Self.cleanupKey) else { return true }
        do {
            try syncStore.deleteSyncState()
            defaults.removeObject(forKey: Self.cleanupKey)
            return true
        } catch {
            return false
        }
    }

    private func runSync() async {
        let report = reportNextSyncFailure
        reportNextSyncFailure = false
        syncing = true
        defer { syncing = false }
        let local = SavedStoresAccountLocal(hosts: .shared, prompts: .shared, defaults: defaults)
        let run = AccountLocalSync(engine: sync, store: local) { [weak self] active in
            self?.applying = active
        }
        do {
            var summary = try await run.run()
            // The shares after the machines and prompts, on the mirror that run just pulled.
            let account = try await session.requireAccountID()
            accountID = account
            summary.absorb(try await AccountShareSync(engine: sync, store: SharedMachinesStore.shared, account: account).run())
            lastSync = summary
            syncFailed = summary.overQuota
            let hosts = await sync.items(in: .hosts).count
            let prompts = await sync.items(in: .prompts).count
            syncedCounts = (hosts, prompts)
            lastAutoSync = Date()
            if let message = summary.problems {
                notice = AccountNotice(title: "Some things didn't sync", message: message)
            }
        } catch is CancellationError {
            return
        } catch AccountError.signedOut {
            return
        } catch {
            syncFailed = true
            // A background sync that can't reach the service tries again later, quietly.
            if report || (error as? AccountError) != .unreachable {
                notice = AccountNotice(title: "Couldn't sync", message: Self.describe(error))
            }
        }
    }

    /// A machine or prompt added, edited or removed here reaches the account a few seconds later.
    private func observeLocalEdits() {
        // Each store's current value is published at once on subscribing: drop each one's own
        // first value, not the first two of the merged stream (#776 F3).
        let hosts = SavedHostsStore.shared.$hosts.dropFirst().map { _ in () }
        let prompts = SavedPromptsStore.shared.$prompts.dropFirst().map { _ in () }
        hosts.merge(with: prompts)
            .filter { [weak self] in self?.applying == false && self?.signedIn == true }
            .debounce(for: .seconds(3), scheduler: RunLoop.main)
            .sink { [weak self] in self?.localEditSync() }
            .store(in: &cancellables)

        // A share added to or left from the account here (#700) is claimed for this account at
        // once, then pushed, or deleted on every device, by a sync that starts now.
        SharedMachinesStore.shared.$machines.dropFirst()
            .map { Set($0.filter(\.accountBound).map(\.id)) }
            .removeDuplicates()
            .sink { [weak self] bound in
                guard let self, signedIn else { return }
                if let accountID { SharedMachinesStore.shared.ledger.claim(bound, account: accountID) }
                localEditSync()
            }
            .store(in: &cancellables)
    }

    // MARK: Words

    static var platform: AccountPlatform {
        if ProcessInfo.processInfo.isiOSAppOnMac { return .macos }
        return UIDevice.current.userInterfaceIdiom == .pad ? .ipados : .ios
    }

    /// "iPhone", "iPad" or "Mac", for sentences.
    static var deviceKind: String {
        switch platform {
        case .macos: return "Mac"
        case .ipados: return "iPad"
        default: return "iPhone"
        }
    }

    /// The device's name as the account lists it.
    static var deviceName: String {
        #if DEBUG
        if let name = mockDeviceName { return name }
        #endif
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((name.isEmpty ? deviceKind : name).prefix(64))
    }

    /// The signed-in line: Google's email when the service passed it this session, else the
    /// provider.
    var identityLine: String {
        if let displayHint, !displayHint.isEmpty { return displayHint }
        switch profile?.provider {
        case .google?: return "Signed in with Google"
        default: return "Signed in with Apple"
        }
    }

    /// The account email, when this session knows a real one: Google's `display_hint`. Apple's
    /// private-relay addresses say nothing about the person, so they count as none.
    var email: String? {
        guard let hint = displayHint?.trimmingCharacters(in: .whitespacesAndNewlines),
              hint.contains("@"), !hint.lowercased().hasSuffix("@privaterelay.appleid.com") else { return nil }
        return hint
    }

    /// The account at a glance, for the avatar on the machine list.
    enum Glance: Equatable {
        case signedOut
        case signedIn(email: String?)
        /// Signed in, but the last sync or this device's enrolment failed.
        case needsAttention(email: String?)
    }

    var glance: Glance {
        guard signedIn else { return .signedOut }
        if case .failed = enrolment { return .needsAttention(email: email) }
        return syncFailed ? .needsAttention(email: email) : .signedIn(email: email)
    }

    static func describe(_ error: Error) -> String {
        if case ProviderSignInError.failed(let text)? = error as? ProviderSignInError { return text }
        guard let account = error as? AccountError else { return error.localizedDescription }
        switch account {
        case .unreachable:
            return "HerdrUp accounts can't be reached. Check the connection and try again."
        case .signedOut:
            return "You're signed out. Sign in again."
        case .malformedResponse:
            return "The account service answered in a way this version doesn't understand. Update herdrup and try again."
        case .refused(let status, let code, _, _, _):
            switch code {
            case "nonce_used", "nonce_mismatch", "nonce_invalid": return "The sign-in took too long. Try again."
            case "token_invalid", "token_expired": return "The sign-in wasn't accepted. Try again."
            case "rate_limited": return "Too many tries. Wait a minute and try again."
            case "provider_not_configured": return "This sign-in isn't available yet."
            default: return code.isEmpty ? "The account service refused (\(status))." : "The account service refused (\(code))."
            }
        }
    }
}
