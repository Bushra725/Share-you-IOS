import Foundation
import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseCore
import GoogleSignIn

/// Optional account (the app works fully without one, like Android).
/// Sign in with Apple + Google, both through Firebase Authentication.
/// Signing in syncs the profile and transfer stats to Firestore.
@MainActor
final class AuthService: NSObject, ObservableObject {
    static let shared = AuthService()

    struct Account: Equatable {
        let uid: String
        let name: String?
        let email: String?
        let providers: [String]
    }

    @Published private(set) var account: Account?
    @Published private(set) var busy = false
    @Published var error: String?

    private var listener: AuthStateDidChangeListenerHandle?
    /// Raw nonce for the Sign in with Apple request in flight.
    private var currentNonce: String?

    func start() {
        guard listener == nil else { return }
        listener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in self?.update(user) }
        }
    }

    private func update(_ user: User?) {
        if let user {
            account = Account(uid: user.uid, name: user.displayName, email: user.email,
                              providers: user.providerData.map(\.providerID))
            CrashReporter.setUser(user.uid)
            Task { await FirestoreService.shared.upsertProfile() }
        } else {
            account = nil
            CrashReporter.setUser(nil)
        }
    }

    // MARK: - Google

    func signInWithGoogle() async {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            error = String(localized: "Google Sign-In is not configured.")
            return
        }
        guard let presenter = UIHelpers.topViewController() else { return }
        busy = true
        defer { busy = false }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let idToken = result.user.idToken?.tokenString else {
                error = String(localized: "Google did not return an ID token.")
                return
            }
            let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: result.user.accessToken.tokenString)
            _ = try await Auth.auth().signIn(with: credential)
            AnalyticsService.log(.signIn, ["method": "google"])
        } catch let e as NSError where e.domain == kGIDSignInErrorDomain && e.code == GIDSignInError.canceled.rawValue {
            // user closed the sheet
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Apple (used with SwiftUI's SignInWithAppleButton)

    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonce()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
    }

    func handleApple(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .failure(let e):
            if (e as? ASAuthorizationError)?.code != .canceled { error = e.localizedDescription }
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = cred.identityToken, let token = String(data: tokenData, encoding: .utf8),
                  let nonce = currentNonce else {
                error = String(localized: "Apple did not return a sign-in token.")
                return
            }
            busy = true
            defer { busy = false }
            let credential = OAuthProvider.appleCredential(withIDToken: token, rawNonce: nonce, fullName: cred.fullName)
            do {
                let res = try await Auth.auth().signIn(with: credential)
                // Apple sends the name only on the first sign-in: store it.
                if let name = cred.fullName, res.user.displayName == nil {
                    let formatted = PersonNameComponentsFormatter().string(from: name)
                    if !formatted.isEmpty {
                        let change = res.user.createProfileChangeRequest()
                        change.displayName = formatted
                        try? await change.commitChanges()
                        update(Auth.auth().currentUser)
                    }
                }
                AnalyticsService.log(.signIn, ["method": "apple"])
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Sign out / delete (App Store guideline 5.1.1(v): in-app account deletion)

    func signOut() {
        do {
            try Auth.auth().signOut()
            GIDSignIn.sharedInstance.signOut()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Deletes the Firestore data and the Firebase account. Apple accounts also revoke the Apple token.
    func deleteAccount() async -> Bool {
        guard let user = Auth.auth().currentUser else { return false }
        busy = true
        defer { busy = false }
        do {
            if user.providerData.contains(where: { $0.providerID == "apple.com" }) {
                let auth = try await AppleReauth.run()
                if let codeData = auth.authorizationCode, let code = String(data: codeData, encoding: .utf8) {
                    try await Auth.auth().revokeToken(withAuthorizationCode: code)
                }
                if let tokenData = auth.identityToken, let token = String(data: tokenData, encoding: .utf8), let nonce = AppleReauth.lastNonce {
                    let cred = OAuthProvider.appleCredential(withIDToken: token, rawNonce: nonce, fullName: nil)
                    try await user.reauthenticate(with: cred)
                }
            } else if user.providerData.contains(where: { $0.providerID == "google.com" }),
                      let presenter = UIHelpers.topViewController() {
                let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
                if let idToken = result.user.idToken?.tokenString {
                    let cred = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: result.user.accessToken.tokenString)
                    try await user.reauthenticate(with: cred)
                }
            }
            await FirestoreService.shared.deleteUserData(uid: user.uid)
            try await user.delete()
            GIDSignIn.sharedInstance.signOut()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: - Nonce helpers

    static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var generator = SystemRandomNumberGenerator()
        while result.count < length {
            result.append(charset[Int(generator.next() % UInt64(charset.count))])
        }
        return result
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Runs a fresh Sign in with Apple request (needed to revoke the token before deleting the account).
@MainActor
final class AppleReauth: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    static var lastNonce: String?
    private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?
    private static var current: AppleReauth?

    static func run() async throws -> ASAuthorizationAppleIDCredential {
        let helper = AppleReauth()
        current = helper
        defer { current = nil }
        return try await withCheckedThrowingContinuation { c in
            helper.continuation = c
            let nonce = AuthService.randomNonce()
            lastNonce = nonce
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = []
            request.nonce = AuthService.sha256(nonce)
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = helper
            controller.presentationContextProvider = helper
            controller.performRequests()
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        Task { @MainActor in
            if let cred = authorization.credential as? ASAuthorizationAppleIDCredential {
                continuation?.resume(returning: cred)
            } else {
                continuation?.resume(throwing: ASAuthorizationError(.failed))
            }
            continuation = nil
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        Task { @MainActor in
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIHelpers.topViewController()?.view.window ?? ASPresentationAnchor()
        }
    }
}
