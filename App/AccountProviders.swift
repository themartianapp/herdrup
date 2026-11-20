import AuthenticationServices
import CryptoKit
import Foundation
import HerdrKit
import UIKit

/// What a provider's sign-in gives the app (DESIGN #698 §2.1, §6.1): the ID token carrying the
/// service's nonce, Apple's one-use authorization code (the service revokes the Apple grant with
/// it at deletion), and Apple's stable user id, kept to check the credential state at launch.
struct ProviderCredential: Sendable {
    let idToken: String
    let authorizationCode: String?
    let appleUserID: String?
}

enum ProviderSignInError: Error, Equatable {
    /// The person closed the sheet. Not an error to show.
    case cancelled
    /// The provider answered without what the service needs, or refused.
    case failed(String)
}

/// A sign-in with Apple or Google that yields an ID token for `nonce`. The app uses
/// `NativeProviderSignIn`; screenshot mocks and UI tests use `MockAccountService`'s, since
/// neither Apple's sheet nor Google's page can run there.
protocol AccountProviderSignIn {
    @MainActor func signIn(_ provider: AccountProvider, nonce: String) async throws -> ProviderCredential
}

/// The native flows of DESIGN #698 §2.1 for the iOS app and the same app on Mac.
struct NativeProviderSignIn: AccountProviderSignIn {
    @MainActor func signIn(_ provider: AccountProvider, nonce: String) async throws -> ProviderCredential {
        switch provider {
        case .apple: return try await AppleSignIn().run(nonce: nonce)
        case .google: return try await GoogleSignIn().run(nonce: nonce)
        }
    }
}

/// The window a provider's sheet or page presents over.
@MainActor private func presentationWindow() -> ASPresentationAnchor {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    if let window = active?.windows.first(where: \.isKeyWindow) ?? active?.windows.first { return window }
    return ASPresentationAnchor()
}

/// Sign in with Apple: `ASAuthorizationAppleIDProvider`, no scopes (we never receive a name or
/// an email), and the service's nonce passed unchanged (§2.1, §2.2).
@MainActor
private final class AppleSignIn: NSObject, ASAuthorizationControllerDelegate,
                                 ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<ProviderCredential, Error>?
    /// Kept for the length of the request: the controller holds its delegate weakly.
    private var retained: AppleSignIn?

    func run(nonce: String) async throws -> ProviderCredential {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = []
        request.nonce = nonce
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        retained = self
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<ProviderCredential, Error>) {
        continuation?.resume(with: result)
        continuation = nil
        retained = nil
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated { presentationWindow() }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController,
                                             didCompleteWithAuthorization authorization: ASAuthorization) {
        MainActor.assumeIsolated {
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8)
            else { return finish(.failure(ProviderSignInError.failed("Apple didn't return a sign-in token."))) }
            let code = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
            finish(.success(ProviderCredential(idToken: idToken, authorizationCode: code, appleUserID: credential.user)))
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        MainActor.assumeIsolated {
            if let auth = error as? ASAuthorizationError, auth.code == .canceled {
                finish(.failure(ProviderSignInError.cancelled))
            } else {
                finish(.failure(ProviderSignInError.failed(error.localizedDescription)))
            }
        }
    }
}

/// Sign in with Google through the Google **iOS client**: `ASWebAuthenticationSession` with
/// PKCE, then the code is exchanged at Google, since an iOS client has no secret (§2.1). Scopes
/// `openid email`; the ID token's `aud` is the iOS client id. No Google SDK.
@MainActor
private final class GoogleSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    static var clientID: String? {
        Bundle.main.object(forInfoDictionaryKey: "HerdrGoogleIOSClientID") as? String
    }

    /// `com.googleusercontent.apps.<id>`: the client id reversed, its own URL scheme.
    static func callbackScheme(for clientID: String) -> String {
        "com.googleusercontent.apps." + clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }

    func run(nonce: String) async throws -> ProviderCredential {
        guard let clientID = Self.clientID, !clientID.isEmpty else {
            throw ProviderSignInError.failed("Google sign-in isn't set up in this build.")
        }
        let scheme = Self.callbackScheme(for: clientID)
        let redirect = scheme + ":/oauth2redirect"
        let verifier = Self.randomB64URL(32)
        let challenge = Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomB64URL(16)
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        let callback = try await authenticate(url: components.url!, scheme: scheme)
        let answer = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard answer.first(where: { $0.name == "state" })?.value == state else {
            throw ProviderSignInError.failed("Google's answer didn't match this sign-in.")
        }
        guard let code = answer.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            if answer.first(where: { $0.name == "error" })?.value == "access_denied" { throw ProviderSignInError.cancelled }
            throw ProviderSignInError.failed("Google didn't sign you in.")
        }
        let idToken = try await exchange(code: code, verifier: verifier, clientID: clientID, redirect: redirect)
        return ProviderCredential(idToken: idToken, authorizationCode: nil, appleUserID: nil)
    }

    private func authenticate(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: ProviderSignInError.cancelled)
                } else {
                    continuation.resume(throwing: ProviderSignInError.failed(error?.localizedDescription ?? "Google didn't sign you in."))
                }
            }
            session.presentationContextProvider = self
            if !session.start() {
                continuation.resume(throwing: ProviderSignInError.failed("Couldn't open Google's sign-in page."))
            }
        }
    }

    /// `POST https://oauth2.googleapis.com/token` with the PKCE verifier; keeps only the ID token.
    private func exchange(code: String, verifier: String, clientID: String, redirect: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code_verifier", value: verifier),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
        ]
        // `+` is a space in a form body; URLComponents leaves it as is.
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        let (data, response) = try await URLSession(configuration: config).data(for: request)
        struct TokenAnswer: Decodable { let id_token: String? }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let idToken = (try? JSONDecoder().decode(TokenAnswer.self, from: data))?.id_token, !idToken.isEmpty
        else { throw ProviderSignInError.failed("Google didn't finish the sign-in.") }
        return idToken
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { presentationWindow() }
    }

    private static func randomB64URL(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Base64URL.encode(Data(bytes))
    }
}

/// Apple's side of a session (§2.5): at launch the app asks whether the Apple ID that signed in
/// still allows HerdrUp, and watches for the revocation notice. Revoked → signed out here.
enum AppleCredentialWatch {
    static func isRevoked(userID: String) async -> Bool {
        await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, _ in
                continuation.resume(returning: state == .revoked)
            }
        }
    }

    static var revokedNotification: Notification.Name { ASAuthorizationAppleIDProvider.credentialRevokedNotification }
}
