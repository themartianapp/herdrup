import Combine
import Foundation
import HerdrKit
import UIKit

/// What this device remembers about the signed-in account, besides the refresh token in the
/// Keychain: which provider signed in (deletion asks the same one again, DESIGN #698 §6.1) and
/// Apple's user id (the launch credential check, §2.5). Nothing secret. Google's email
/// (`display_hint`) is shown, never kept, so it lives only in `HerdrUpAccount.displayHint`.
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
/// what the app shows, and `AccountSyncRun` keeps them and the account in step.
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
    private var syncTask: Task<Void, Never>?
    private var lastAutoSync = Date.distantPast
    private var started = false
    private var cancellables: Set<AnyCancellable> = []
    /// True while a sync applies the account's copy to the local stores, so those changes
    /// don't count as local edits to push.
    private var applying = false

    private static let profileKey = "account.profile.v1"
    private static let onboardingKey = "account.onboarding.done"

    private init() {
        let client: AccountClient
        let tokens: AccountTokenStore
        let syncStore: SyncStateStore
        #if DEBUG
        if ScreenshotMock.mode != nil {
            let mock = MockAccountService.shared
            client = mock.client
            tokens = mock.tokenStore
            syncStore = InMemorySyncStateStore()
            providers = mock
            defaults = mock.defaults
        } else {
            client = AccountClient()
            tokens = KeychainAccountTokenStore()
            syncStore = (try? FileSyncStateStore.standard()) ?? InMemorySyncStateStore()
            providers = NativeProviderSignIn()
            defaults = .standard
        }
        #else
        client = AccountClient()
        tokens = KeychainAccountTokenStore()
        syncStore = (try? FileSyncStateStore.standard()) ?? InMemorySyncStateStore()
        providers = NativeProviderSignIn()
        defaults = .standard
        #endif
        session = AccountSession(client: client, store: tokens) { reason in
            Task { @MainActor in HerdrUpAccount.shared.sessionEnded(reason) }
        }
        statements = StatementCache(session: session)
        sync = Self.engine(session: session, store: syncStore)
        let profile = defaults.data(forKey: Self.profileKey).flatMap { try? JSONDecoder().decode(AccountProfile.self, from: $0) }
        self.profile = profile
        signedIn = profile != nil
        onboardingDone = defaults.bool(forKey: Self.onboardingKey)
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
            await loadHealth()
            let stored = (try? await session.isSignedIn()) ?? signedIn
            if !stored, profile != nil { forgetProfile() }
            if stored, profile == nil {
                // A session without a profile (an older build's): ask which provider at deletion.
                profile = AccountProfile(provider: .apple, appleUserID: nil)
            }
            signedIn = stored
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
        syncNow()
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
        busy = .signingIn(provider)
        defer { if busy == .signingIn(provider) { busy = nil } }
        do {
            let nonce = try await session.nonce()
            let credential = try await providers.signIn(provider, nonce: nonce.nonce)
            let answer = try await session.signIn(provider: provider, idToken: credential.idToken,
                                                  nonce: nonce.nonce, platform: Self.platform)
            saveProfile(AccountProfile(provider: provider, appleUserID: credential.appleUserID))
            displayHint = answer.displayHint
            signedIn = true
        } catch ProviderSignInError.cancelled {
            return
        } catch {
            notice = AccountNotice(title: "Couldn't sign in", message: Self.describe(error))
            return
        }
        await enrolThisDevice()
        busy = .syncing
        await startSync(first: true).value
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
        } catch AccountError.refused(_, "wrong_account", _, _) {
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
        syncTask?.cancel()
        syncTask = nil
        await statements.clear()
        try? await sync.clear()
        AccountSyncRun.forgetLocalState(defaults)
        forgetProfile()
        signedIn = false
        displayHint = nil
        devices = []
        enrolment = .unknown
        lastSync = nil
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

    /// Syncs now unless a sync is running.
    func syncNow() {
        guard signedIn else { return }
        startSync(first: false)
    }

    /// One sync at a time: a sync asked for while one runs shares it.
    @discardableResult
    private func startSync(first: Bool) -> Task<Void, Never> {
        if let syncTask { return syncTask }
        let task = Task {
            syncing = true
            await runSync(first: first)
            syncing = false
            syncTask = nil
        }
        syncTask = task
        return task
    }

    private func runSync(first: Bool) async {
        let run = AccountSyncRun(engine: sync, hosts: .shared, prompts: .shared, defaults: defaults) { [weak self] active in
            self?.applying = active
        }
        do {
            let summary = try await run.run()
            lastSync = summary
            syncedCounts = (await sync.items(in: .hosts).count, await sync.items(in: .prompts).count)
            lastAutoSync = Date()
            if let message = summary.problems {
                notice = AccountNotice(title: "Some things didn't sync", message: message)
            }
        } catch is CancellationError {
            return
        } catch AccountError.signedOut {
            return
        } catch {
            // A background sync that can't reach the service tries again later, quietly.
            if first || (error as? AccountError) != .unreachable {
                notice = AccountNotice(title: "Couldn't sync", message: Self.describe(error))
            }
        }
    }

    /// A machine or prompt added, edited or removed here reaches the account a few seconds later.
    private func observeLocalEdits() {
        let hosts = SavedHostsStore.shared.$hosts.map { _ in () }
        let prompts = SavedPromptsStore.shared.$prompts.map { _ in () }
        hosts.merge(with: prompts)
            .dropFirst(2)
            .filter { [weak self] in self?.applying == false && self?.signedIn == true }
            .debounce(for: .seconds(3), scheduler: RunLoop.main)
            .sink { [weak self] in self?.syncNow() }
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

    static func describe(_ error: Error) -> String {
        switch error {
        case ProviderSignInError.failed(let text):
            return text
        case AccountError.unreachable:
            return "HerdrUp accounts can't be reached. Check the connection and try again."
        case AccountError.signedOut:
            return "You're signed out. Sign in again."
        case AccountError.malformedResponse:
            return "The account service answered in a way this version doesn't understand. Update herdrup and try again."
        case AccountError.refused(let status, let code, _, _):
            switch code {
            case "nonce_used", "nonce_mismatch", "nonce_invalid": return "The sign-in took too long. Try again."
            case "token_invalid", "token_expired": return "The sign-in wasn't accepted. Try again."
            case "rate_limited": return "Too many tries. Wait a minute and try again."
            case "provider_not_configured": return "This sign-in isn't available yet."
            default: return code.isEmpty ? "The account service refused (\(status))." : "The account service refused (\(code))."
            }
        default:
            return error.localizedDescription
        }
    }
}
