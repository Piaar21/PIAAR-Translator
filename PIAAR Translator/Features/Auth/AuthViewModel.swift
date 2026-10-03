import Foundation
import Combine

enum CollaborationAuthState: Equatable {
    case checkingSession, signedOut, needsEmailConfirmation, signedIn(CollaborationProfile)
    case error(CollaborationAuthError)
}
@MainActor final class AuthViewModel: ObservableObject {
    @Published private(set) var state: CollaborationAuthState = .checkingSession
    @Published private(set) var isBusy = false
    @Published private(set) var error: CollaborationAuthError?
    private(set) var user: AuthenticatedUser?
    private let auth: AuthRepository
    private let profiles: CollaborationProfileRepository
    private var started = false
    private var monitor: Task<Void, Never>?
    private var generation = 0
    init(auth: AuthRepository, profiles: CollaborationProfileRepository) {
        self.auth = auth; self.profiles = profiles
    }
    deinit { monitor?.cancel() }
    var profile: CollaborationProfile? {
        if case .signedIn(let profile) = state { return profile }
        return nil
    }
    func start() async {
        guard !started else { return }; started = true
        await restore()
        monitor = Task { [weak self, auth] in
            for await user in auth.changes() {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                // Explicit auth actions already reconcile their own result.
                guard !self.isBusy else { continue }
                if user?.id == self.user?.id { continue }
                self.generation += 1
                self.user = user
                self.error = nil
                self.state = .signedOut
                if let user { await self.loadProfile(user) }
            }
        }
    }
    func restore() async {
        guard !isBusy else { return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            let restored = try await auth.restoreSession()
            adopt(restored)
            if let user { await loadProfile(user) } else { state = .signedOut }
        } catch { report(error) }
    }
    func signUp(name: String, email: String, password: String) async {
        guard !isBusy else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 30, email.contains("@"), !password.isEmpty else {
            error = .invalidInput; return
        }
        isBusy = true; error = nil; defer { isBusy = false }
        do {
            switch try await auth.signUp(SignupRequest(displayName: name, email: email, password: password)) {
            case .awaitingConfirmation: user = nil; state = .needsEmailConfirmation
            case .signedIn(let user): adopt(user); await loadProfile(user)
            }
        } catch { report(error) }
    }
    func signIn(email: String, password: String) async {
        guard !isBusy else { return }
        isBusy = true; error = nil; defer { isBusy = false }
        do {
            let user = try await auth.signIn(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            adopt(user); await loadProfile(user)
        } catch { report(error) }
    }
    func rename(_ name: String) async {
        guard !isBusy, let user else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 30 else { error = .invalidInput; return }
        isBusy = true; error = nil; defer { isBusy = false }
        do {
            let profile = try await profiles.updateDisplayName(name, userID: user.id)
            guard profile.id == user.id else { throw CollaborationAuthError.profileUpdate }
            state = .signedIn(profile)
        } catch { self.error = (error as? CollaborationAuthError) ?? .profileUpdate }
    }
    func signOut() async {
        guard !isBusy else { return }
        isBusy = true; error = nil; defer { isBusy = false }
        do { try await auth.signOut(); generation += 1; user = nil; state = .signedOut }
        catch {
            // SDK local sign-out may already have removed its stored session before
            // the server revocation fails. Do not leave an authenticated screen up.
            do {
                if try await auth.restoreSession() == nil { generation += 1; user = nil; state = .signedOut }
            } catch { /* A read error is not evidence that a session is absent. */ }
            report(error)
        }
    }
    private func adopt(_ next: AuthenticatedUser?) {
        if user?.id != next?.id { generation += 1; state = .signedOut }
        user = next
    }
    private func loadProfile(_ user: AuthenticatedUser) async {
        let requestGeneration = generation
        do {
            guard let profile = try await profiles.profile(userID: user.id), profile.id == user.id else {
                throw CollaborationAuthError.profileMissing
            }
            guard generation == requestGeneration, self.user?.id == user.id else { return }
            state = .signedIn(profile)
        } catch {
            guard generation == requestGeneration else { return }
            report(error)
        }
    }
    func requireLogin(_ error: CollaborationAuthError) {
        generation += 1; user = nil; state = .error(error); self.error = error
    }
    private func report(_ error: Error) {
        let value = (error as? CollaborationAuthError) ?? .unavailable
        self.error = value
        if value == .sessionMissing { generation += 1; user = nil; state = .signedOut; return }
        if value == .refreshFailed { requireLogin(value); return }
        if profile == nil { state = value == .sessionMissing ? .signedOut : .error(value) }
    }
}
