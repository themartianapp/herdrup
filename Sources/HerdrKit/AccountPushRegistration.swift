import Foundation

/// Hands this iOS device's push relay capability (`PushRelayEnroller`) to the account service
/// (`PUT /v1/devices/self/push`), so a pair request from another device of the account reaches
/// it as a push (pair-v1, DESIGN §13). It is sent once per enrolled device and capability: a
/// relaunch with the same ones sends nothing, a rotated token (a new capability) or a new
/// enrolment sends again. A failed send is tried again on the next call.
public actor AccountPushRegistration {
    private let session: AccountSession
    private let defaults: UserDefaults
    private let key: String

    public init(session: AccountSession, defaults: UserDefaults = .standard, key: String = "account.push.registered.v1") {
        self.session = session
        self.defaults = defaults
        self.key = key
    }

    /// Registers `capability` for the enrolled device `deviceID` unless that pair is the one
    /// last registered. True when the service has it.
    @discardableResult
    public func register(capability: String, deviceID: String) async -> Bool {
        let mark = "\(deviceID)|\(capability)"
        if defaults.string(forKey: key) == mark { return true }
        let client = session.client
        do {
            try await session.authorized { try await client.setPushCapability(capability, accessToken: $0) }
        } catch {
            return false
        }
        defaults.set(mark, forKey: key)
        return true
    }

    /// Forgets what was registered (sign-out): the next device registers afresh.
    public func forget() {
        defaults.removeObject(forKey: key)
    }
}
