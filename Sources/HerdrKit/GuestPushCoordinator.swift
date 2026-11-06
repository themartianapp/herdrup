import Foundation

/// The system around a guest's push: iOS permission and token, the push relay, and a
/// connection to a share. The app supplies the live one; tests and UI-test mocks script it.
public struct GuestPushSystem: Sendable {
    public var authorization: @Sendable () async -> PushAuthorization
    public var requestAuthorization: @Sendable () async -> Bool
    /// Asks iOS for an APNs token; it arrives later, through `deviceTokenChanged`, or iOS
    /// refuses, through `tokenFailed`.
    public var registerForRemoteNotifications: @Sendable () async -> Void
    public var deviceToken: @Sendable () async -> String?
    public var relayCapability: @Sendable (String) async -> String?
    /// A client for a share, for calls made away from its screens (a token change, the
    /// Settings control before the home connected, leaving the share).
    public var connect: @Sendable (GuestAccess) async throws -> HerdrClient

    public init(authorization: @escaping @Sendable () async -> PushAuthorization,
                requestAuthorization: @escaping @Sendable () async -> Bool,
                registerForRemoteNotifications: @escaping @Sendable () async -> Void,
                deviceToken: @escaping @Sendable () async -> String?,
                relayCapability: @escaping @Sendable (String) async -> String?,
                connect: @escaping @Sendable (GuestAccess) async throws -> HerdrClient) {
        self.authorization = authorization
        self.requestAuthorization = requestAuthorization
        self.registerForRemoteNotifications = registerForRemoteNotifications
        self.deviceToken = deviceToken
        self.relayCapability = relayCapability
        self.connect = connect
    }
}

/// A guest push attempt that failed, and what Try again repeats.
public struct GuestPushFailure: Sendable, Equatable {
    public enum Operation: Sendable, Equatable {
        /// Registering this phone (Turn on, a connection, a new token).
        case register
        /// Turn off's unregistration: retrying it must never turn notifications back on.
        case unregister
    }

    public let operation: Operation
    public let message: String

    public init(_ operation: Operation, _ message: String) {
        self.operation = operation
        self.message = message
    }
}

/// What the guest's screens show about push, per share by `GuestAccess.id`.
public struct GuestPushState: Sendable, Equatable {
    /// iOS's notification permission, as last read.
    public var authorization: PushAuthorization = .undetermined
    /// The guest's choice per share.
    public var choices: [String: GuestPushChoice] = [:]
    /// What each share's host last advertised.
    public var hostFeatures: [String: GuestFeatures] = [:]
    /// The last attempt for a share that failed, until one succeeds or the guest acts.
    public var failures: [String: GuestPushFailure] = [:]
    /// The share whose "turn on notifications" explanation is showing.
    public var asking: String?

    public init() {}

    public func status(for access: GuestAccess) -> GuestPushPolicy.Status {
        GuestPushPolicy.status(hostTakesPush: hostFeatures[access.id]?.push, choice: choices[access.id],
                               authorization: authorization, failure: failures[access.id]?.message)
    }
}

/// Push for the agents shared with this phone (herdrup#338, #343). A guest's device
/// registers its APNs token with each share's host over the guest relay; the host then
/// pushes the shared agent's status changes and, when the owner shares Gram, its Grams.
/// `GuestPushPolicy` decides when; this carries it out and keeps `state` for the screens,
/// reporting every change through `onChange`.
public actor GuestPushCoordinator {
    public private(set) var state: GuestPushState {
        didSet { if state != oldValue { onChange(state) } }
    }

    /// Per share: the registration last sent, so one connection registers once and a new
    /// connection, token or Gram preference registers again.
    private var sent: [String: Registration] = [:]
    private struct Registration: Equatable {
        /// Held, not just its address: a released client's address can come back as the
        /// next connection's, which would then never register.
        let client: HerdrClient
        let token: String
        let gram: Bool

        static func == (lhs: Registration, rhs: Registration) -> Bool {
            lhs.client === rhs.client && lhs.token == rhs.token && lhs.gram == rhs.gram
        }
    }
    /// Per share: the guest's latest intent (Turn on, Turn off, Not now, leaving). An
    /// operation started under an older one stops before it reaches the host.
    private var intents: [String: UInt64] = [:]
    /// Per share: the operation queued last. Each waits for the one before, so a share
    /// never has a registration and an unregistration in flight together.
    private var operations: [String: Task<Void, Never>] = [:]
    /// Per share: the intent under which it asked iOS for a token and is waiting for one.
    private var awaitingToken: [String: UInt64] = [:]

    private let system: GuestPushSystem
    private let defaults: UserDefaults
    private let onChange: @Sendable (GuestPushState) -> Void
    /// Per share: true once the guest turned push on, false after "Not now" or Turn off.
    public static let consentKey = "guest.push.consent.v1"
    /// Per share: the features its host last advertised, so a token change can re-register
    /// with the right `notify_gram` while the share isn't open.
    public static let featuresKey = "guest.push.features.v1"

    public init(system: GuestPushSystem, defaults: UserDefaults = .standard,
                onChange: @escaping @Sendable (GuestPushState) -> Void = { _ in }) {
        self.system = system
        self.defaults = defaults
        self.onChange = onChange
        state = Self.storedState(defaults)
    }

    /// The choices and features saved in `defaults`, before anything is read from iOS.
    public static func storedState(_ defaults: UserDefaults) -> GuestPushState {
        var state = GuestPushState()
        state.choices = ((defaults.dictionary(forKey: consentKey) as? [String: Bool]) ?? [:])
            .mapValues { $0 ? .on : .off }
        state.hostFeatures = ((defaults.dictionary(forKey: featuresKey) as? [String: [Bool]]) ?? [:])
            .compactMapValues { $0.count == 2 ? GuestFeatures(gram: $0[0], push: $0[1]) : nil }
        return state
    }

    // MARK: State

    private func setChoice(_ value: GuestPushChoice?, for access: GuestAccess) {
        state.choices[access.id] = value
        defaults.set(state.choices.mapValues { $0 == .on }, forKey: Self.consentKey)
    }

    private func remember(_ features: GuestFeatures?, for access: GuestAccess) {
        guard state.hostFeatures[access.id] != features else { return }
        state.hostFeatures[access.id] = features
        defaults.set(state.hostFeatures.mapValues { [$0.gram, $0.push] }, forKey: Self.featuresKey)
    }

    private func setFailure(_ failure: GuestPushFailure?, for access: GuestAccess) {
        state.failures[access.id] = failure
    }

    private func setAsking(_ id: String?) {
        state.asking = id
    }

    /// Re-reads iOS's permission, which the guest can change in Settings at any time.
    @discardableResult
    public func refreshAuthorization() async -> PushAuthorization {
        let current = await system.authorization()
        state.authorization = current
        return current
    }

    /// The guest's Settings came into view, or the app came back to the foreground (the
    /// guest may have changed iOS's permission meanwhile): re-read it, and register over
    /// the share's open connection if that is now due.
    public func refresh(_ access: GuestAccess, client: HerdrClient?) async {
        guard let client, let features = state.hostFeatures[access.id] else {
            await refreshAuthorization()
            return
        }
        await connected(access, client: client, features: features)
    }

    // MARK: Flow

    /// A connection to the share learned (or re-learned) its host's features: register when
    /// the policy says so, so the host always holds the current token and `notify_gram`, or
    /// explain when iOS hasn't asked yet. Safe to call repeatedly: a connection registers once.
    public func connected(_ access: GuestAccess, client: HerdrClient, features: GuestFeatures) async {
        remember(features, for: access)
        let authorization = await refreshAuthorization()
        switch GuestPushPolicy.onConnect(hostTakesPush: features.push, choice: state.choices[access.id],
                                         authorization: authorization) {
        case .register:
            if state.asking == access.id { setAsking(nil) }
            let intent = currentIntent(access)
            await serially(access) {
                await self.register(access, client: client, features: features, intent: intent)
            }
        case .explain:
            setAsking(access.id)
        case .none:
            if state.asking == access.id { setAsking(nil) }
        }
    }

    /// The Notifications control's button. `openSettings` is the app's to carry out. Try
    /// again repeats what failed: a refused Turn off is retried as Turn off, so the share
    /// stays off.
    public func perform(_ action: GuestPushAction, _ access: GuestAccess, client: HerdrClient?) async {
        switch action {
        case .turnOn: await turnOn(access, client: client)
        case .turnOff: await turnOff(access, client: client)
        case .retry:
            if state.failures[access.id]?.operation == .unregister {
                await turnOff(access, client: client)
            } else {
                await turnOn(access, client: client)
            }
        case .openSettings: break
        }
    }

    /// Turn on, from the explanation or the Settings control (also Try again after a failed
    /// registration): ask iOS when it hasn't asked yet, then register. When the token
    /// arrives later (the first registration with APNs), `deviceTokenChanged` registers it.
    public func turnOn(_ access: GuestAccess, client: HerdrClient?) async {
        let intent = newIntent(access)
        setAsking(nil)
        setChoice(.on, for: access)
        setFailure(nil, for: access)
        if await refreshAuthorization() == .undetermined {
            _ = await system.requestAuthorization()
            await refreshAuthorization()
        }
        guard state.authorization == .granted, let features = state.hostFeatures[access.id], features.push
        else { return }
        await serially(access) {
            guard let client = await self.resolve(client, for: access, .register) else { return }
            await self.register(access, client: client, features: features, again: true, intent: intent)
        }
    }

    /// "Not now" on the explanation: this share stays off until the guest turns it on.
    public func decline(_ access: GuestAccess) {
        _ = newIntent(access)
        setAsking(nil)
        setChoice(.off, for: access)
    }

    /// Turn off, from the Settings control: the host stops pushing to this phone. Runs after
    /// any registration already in flight, so Off is always the host's last word.
    public func turnOff(_ access: GuestAccess, client: HerdrClient?) async {
        let intent = newIntent(access)
        setChoice(.off, for: access)
        setFailure(nil, for: access)
        await serially(access) {
            await self.unregister(access, client: client, intent: intent)
        }
    }

    /// The APNs token changed: register it with every share the policy says should have it.
    public func deviceTokenChanged(shares: [GuestAccess]) async {
        let authorization = await refreshAuthorization()
        for access in shares {
            guard let features = state.hostFeatures[access.id],
                  GuestPushPolicy.registersOnTokenChange(hostTakesPush: features.push,
                                                         choice: state.choices[access.id],
                                                         authorization: authorization) else { continue }
            let intent = currentIntent(access)
            await serially(access) {
                guard let client = await self.resolve(nil, for: access, .register) else { return }
                await self.register(access, client: client, features: features, intent: intent)
            }
        }
    }

    /// The guest removed the share from this phone: the host stops pushing to it.
    public func leaving(_ access: GuestAccess) async {
        _ = newIntent(access)
        let wasRegistered = sent[access.id] != nil || state.choices[access.id] == .on
        awaitingToken[access.id] = nil
        setChoice(nil, for: access)
        remember(nil, for: access)
        setFailure(nil, for: access)
        if state.asking == access.id { setAsking(nil) }
        guard wasRegistered || state.authorization == .granted else { return }
        await serially(access) {
            await self.forget(access)
        }
    }

    /// iOS refused this app an APNs token (`didFailToRegisterForRemoteNotifications…`): every
    /// share still waiting for one shows why, until a token arrives or the guest retries.
    public func tokenFailed(_ reason: String) {
        for (id, intent) in awaitingToken where intents[id] ?? 0 == intent && state.choices[id] != .off {
            state.failures[id] = GuestPushFailure(.register, "iOS couldn't set up notifications: \(reason)")
        }
    }

    // MARK: Operations

    private func currentIntent(_ access: GuestAccess) -> UInt64 { intents[access.id] ?? 0 }

    private func newIntent(_ access: GuestAccess) -> UInt64 {
        let next = currentIntent(access) &+ 1
        intents[access.id] = next
        return next
    }

    /// Whether the guest has changed their mind since `intent`.
    private func superseded(_ intent: UInt64, _ access: GuestAccess) -> Bool {
        currentIntent(access) != intent
    }

    /// Runs `operation` once every earlier operation for the share has finished. Not the
    /// caller's task: leaving a screen mid-registration must not cancel it.
    private func serially(_ access: GuestAccess, _ operation: @escaping @Sendable () async -> Void) async {
        let previous = operations[access.id]
        let task = Task {
            await previous?.value
            await operation()
        }
        operations[access.id] = task
        await task.value
    }

    /// The share's open connection, else a new one. A share that can't be reached fails
    /// `operation`, so Try again repeats it.
    private func resolve(_ client: HerdrClient?, for access: GuestAccess,
                         _ operation: GuestPushFailure.Operation) async -> HerdrClient? {
        if let client { return client }
        do {
            return try await system.connect(access)
        } catch {
            setFailure(GuestPushFailure(operation, "Couldn't reach \(access.machineLabel): \(Self.describe(error))"),
                       for: access)
            return nil
        }
    }

    /// Every status kind on; Gram pushes only where the owner shares Gram. Without a token
    /// yet, asks iOS for one; `deviceTokenChanged` registers it when it lands. `again`
    /// re-sends what this connection already sent (Turn on, Retry). Stops wherever the
    /// guest has since changed their mind, so a later Turn off always wins.
    private func register(_ access: GuestAccess, client: HerdrClient, features: GuestFeatures,
                          again: Bool = false, intent: UInt64) async {
        guard !superseded(intent, access), state.choices[access.id] != .off else { return }
        guard let token = await system.deviceToken() else {
            awaitingToken[access.id] = intent
            await system.registerForRemoteNotifications()
            return
        }
        awaitingToken[access.id] = nil
        let registration = Registration(client: client, token: token, gram: features.gram)
        guard again || sent[access.id] != registration else { return }
        let capability = await system.relayCapability(token)
        guard !superseded(intent, access), state.choices[access.id] != .off else { return }
        sent[access.id] = registration
        do {
            // A guest's share pushes every finished turn of the shared agent, as before:
            // "Only my requests" is the owner's choice (a guest never starts a "mine" turn).
            try await client.registerDevice(token: token, needsInput: true, dies: true, finishes: .always,
                                            gram: features.gram, mutedPanes: [], relayCapability: capability)
        } catch {
            // The next connection, token or Retry tries again.
            sent[access.id] = nil
            guard !superseded(intent, access) else { return }
            setFailure(GuestPushFailure(.register, "Couldn't register with \(access.machineLabel): \(Self.describe(error))"),
                       for: access)
            return
        }
        guard !superseded(intent, access) else { return }
        // Without the push service's capability the host can push only with an APNs key of
        // its own, which most don't have.
        setFailure(capability == nil
                   ? GuestPushFailure(.register, "\(access.machineLabel) has this phone, but the push service couldn't be reached, so notifications may not arrive.")
                   : nil, for: access)
    }

    /// Turn off's host side: drop this phone's registration.
    private func unregister(_ access: GuestAccess, client: HerdrClient?, intent: UInt64) async {
        sent[access.id] = nil
        guard let token = await system.deviceToken(),
              let client = await resolve(client, for: access, .unregister) else { return }
        do {
            try await client.unregisterDevice(token: token)
        } catch {
            guard !superseded(intent, access) else { return }
            setFailure(GuestPushFailure(.unregister, "Couldn't turn them off on \(access.machineLabel): \(Self.describe(error))"),
                       for: access)
        }
    }

    /// Leaving's host side: best effort, since the share is gone from the phone.
    private func forget(_ access: GuestAccess) async {
        sent[access.id] = nil
        guard let token = await system.deviceToken(),
              let client = try? await system.connect(access) else { return }
        try? await client.unregisterDevice(token: token)
    }

    private static func describe(_ error: Error) -> String {
        GuestError.classify(error)?.description ?? error.localizedDescription
    }
}
