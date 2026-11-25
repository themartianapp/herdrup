import HerdrKit
import SwiftUI
import UIKit
import UserNotifications

/// What a share's host offers this guest (`features` in each hello), as the relay reports
/// it. Nil until the first call of this connection answers. Published on the main thread.
final class GuestFeaturesModel: ObservableObject, @unchecked Sendable {
    @Published private(set) var current: GuestFeatures?

    init(_ initial: GuestFeatures? = nil) {
        current = initial
    }

    /// Hands the transport a sink that publishes on the main thread.
    func sink() -> @Sendable (GuestFeatures) -> Void {
        { [weak self] features in
            DispatchQueue.main.async { self?.update(features) }
        }
    }

    func update(_ features: GuestFeatures) {
        if current != features { current = features }
    }
}

/// The app's side of guest push (herdrup#338, #343): `GuestPushCoordinator` (HerdrKit)
/// decides and registers; this publishes its state to the guest's screens on the main
/// thread and supplies the live iOS system, or a scripted one under the screenshot mocks
/// so UI tests never show the system alert or reach APNs and the push relay.
@MainActor
final class GuestPushCenter: ObservableObject {
    static let shared = GuestPushCenter()

    @Published private(set) var state: GuestPushState
    private let coordinator: GuestPushCoordinator
    private let openSystemSettings: () -> Void

    /// The share whose "turn on notifications" explanation is showing, by `GuestAccess.id`.
    var asking: String? { state.asking }
    var hostFeatures: [String: GuestFeatures] { state.hostFeatures }
    func status(for access: GuestAccess) -> GuestPushPolicy.Status { state.status(for: access) }

    init(system: GuestPushSystem, openSettings: @escaping () -> Void, defaults: UserDefaults = .standard) {
        let relay = StateRelay()
        state = GuestPushCoordinator.storedState(defaults)
        coordinator = GuestPushCoordinator(system: system, defaults: defaults) { state in
            DispatchQueue.main.async { MainActor.assumeIsolated { relay.center?.state = state } }
        }
        openSystemSettings = openSettings
        relay.center = self
    }

    private final class StateRelay: @unchecked Sendable {
        weak var center: GuestPushCenter?
    }

    private convenience init() {
        #if DEBUG
        if ScreenshotMock.mode != nil {
            let defaults = UserDefaults.standard
            // Each UI test launch starts undecided, like a fresh install.
            defaults.removeObject(forKey: GuestPushCoordinator.consentKey)
            defaults.removeObject(forKey: GuestPushCoordinator.featuresKey)
            self.init(system: .mock, openSettings: {}, defaults: defaults)
            return
        }
        #endif
        self.init(system: .live, openSettings: {
            guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
            UIApplication.shared.open(url)
        })
    }

    func connected(_ access: GuestAccess, client: HerdrClient, features: GuestFeatures) async {
        await coordinator.connected(access, client: client, features: features)
    }

    func refresh(_ access: GuestAccess, client: HerdrClient?) async {
        await coordinator.refresh(access, client: client)
    }

    func turnOn(_ access: GuestAccess, client: HerdrClient?) async {
        await coordinator.turnOn(access, client: client)
    }

    /// The Notifications control's button, other than Open Settings.
    func perform(_ action: GuestPushAction, _ access: GuestAccess, client: HerdrClient?) async {
        await coordinator.perform(action, access, client: client)
    }

    func decline(_ access: GuestAccess) {
        Task { await coordinator.decline(access) }
    }

    func deviceTokenChanged(shares: [GuestAccess]) {
        Task { await coordinator.deviceTokenChanged(shares: shares) }
    }

    /// iOS refused a token: shares waiting for one show why.
    func tokenFailed(_ reason: String) {
        Task { await coordinator.tokenFailed(reason) }
    }

    func leaving(_ access: GuestAccess) {
        Task { await coordinator.leaving(access) }
    }

    func openSettings() { openSystemSettings() }
}

extension GuestPushSystem {
    static let live = GuestPushSystem(
        authorization: {
            switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
            case .authorized, .provisional, .ephemeral: return .granted
            case .denied: return .denied
            case .notDetermined: return .undetermined
            @unknown default: return .undetermined
            }
        },
        requestAuthorization: {
            (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        },
        registerForRemoteNotifications: {
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
        },
        deviceToken: { await MainActor.run { PushCenter.shared.deviceToken } },
        relayCapability: { await PushCenter.relay.capability(kind: .device, token: $0) },
        connect: { access in try await MainActor.run { try GuestConnection.open(access).client } })

    #if DEBUG
    /// `HERDR_MOCK_PUSH_AUTH` sets iOS's answer before any question: `granted`, `denied`,
    /// or (by default) undecided, which turns granted once asked. A granted phone has a
    /// fixed token; the relay is never contacted (its capability is canned); calls go to
    /// the mock host.
    static var mock: GuestPushSystem {
        let authorization = MockAuthorization(ProcessInfo.processInfo.environment["HERDR_MOCK_PUSH_AUTH"])
        return GuestPushSystem(
            authorization: { authorization.value },
            requestAuthorization: {
                if authorization.value == .undetermined { authorization.value = .granted }
                return authorization.value == .granted
            },
            registerForRemoteNotifications: {},
            deviceToken: { authorization.value == .granted ? GuestMockTransport.deviceToken : nil },
            relayCapability: { _ in "hpr1.mock" },
            connect: { _ in HerdrClient(transport: GuestMockTransport(scenario: .running)) })
    }

    private final class MockAuthorization: @unchecked Sendable {
        var value: PushAuthorization
        init(_ raw: String?) {
            switch raw {
            case "granted": value = .granted
            case "denied": value = .denied
            default: value = .undetermined
            }
        }
    }
    #endif
}

/// The one-time explanation before iOS asks for notification permission.
struct GuestPushPrompt: View {
    let agentName: String
    let ownerName: String
    let gram: Bool
    let onEnable: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.text)
                    .frame(width: 32, height: 32)
                    .background(Palette.surfaceRaised, in: Circle())
                Text("Get notified about \(agentName)")
                    .font(Typography.app(16, .semibold)).foregroundStyle(Palette.text)
            }
            Text(detail)
                .font(Typography.app(13.5)).foregroundStyle(Palette.textDim)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Not now", action: onDecline)
                    .buttonStyle(.capsule(.secondary, .large, fullWidth: true))
                    .accessibilityIdentifier("guest-push-not-now")
                Button("Turn on", action: onEnable)
                    .buttonStyle(.capsule(.filled, .large, fullWidth: true))
                    .accessibilityIdentifier("guest-push-enable")
            }
            .padding(.top, 2)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guest-push-prompt")
    }

    private var detail: String {
        let kinds = gram ? "needs \(ownerName), finishes or stops, and when it sends a Gram"
                         : "needs \(ownerName), finishes or stops"
        return "HerdrUp can tell you when \(agentName) \(kinds), even while the app is closed. "
            + "You can change this any time in Settings."
    }
}
