import Foundation
import Supabase

// All SDK user/session types stay in this adapter. The SDK owns token refresh.
@MainActor final class SupabaseAccountRepository: AuthRepository, CollaborationProfileRepository {
    let client: SupabaseClient
    init(configuration: SupabaseConfiguration) {
        let transport = URLSessionConfiguration.default
        transport.timeoutIntervalForRequest = 15
        transport.timeoutIntervalForResource = 30
        client = SupabaseClient(supabaseURL: configuration.projectURL, supabaseKey: configuration.publishableKey,
            options: .init(auth: .init(storage: KeychainLocalStorage(service: "com.piaar.PIAAR-Translator.SupabaseAuth"),
                                      storageKey: "piaar-supabase-session", autoRefreshToken: true),
                           global: .init(session: URLSession(configuration: transport))))
    }
    private func user(_ value: User) -> AuthenticatedUser { AuthenticatedUser(id: value.id, email: value.email) }
    func restoreSession() async throws -> AuthenticatedUser? {
        do { return user(try await client.auth.session.user) }
        catch AuthError.sessionMissing { return nil }
        catch { throw translated(error, fallback: .refreshFailed) }
    }
    func signUp(_ request: SignupRequest) async throws -> SignupResult {
        do {
            let result = try await client.auth.signUp(email: request.email, password: request.password,
                data: request.metadata.mapValues { .string($0) })
            guard let session = result.session else { return .awaitingConfirmation }
            return .signedIn(user(session.user))
        } catch { throw translated(error, fallback: .signupFailed) }
    }
    func signIn(email: String, password: String) async throws -> AuthenticatedUser {
        do { return user(try await client.auth.signIn(email: email, password: password).user) }
        catch { throw translated(error, fallback: .unavailable) }
    }
    func signOut() async throws {
        do { try await client.auth.signOut(scope: .local) }
        catch { throw translated(error, fallback: .unavailable) }
    }
    func changes() -> AsyncStream<AuthenticatedUser?> {
        AsyncStream { continuation in
            let task = Task { [client] in
                for await (event, session) in await client.auth.authStateChanges {
                    guard !Task.isCancelled else { break }
                    switch event {
                    case .signedOut: continuation.yield(nil)
                    case .signedIn, .tokenRefreshed:
                        if let session { continuation.yield(AuthenticatedUser(id: session.user.id, email: session.user.email)) }
                    default: break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func requireOwner(_ id: UUID) async throws {
        do { guard try await client.auth.session.user.id == id else { throw CollaborationAuthError.sessionMissing } }
        catch { throw translated(error, fallback: .refreshFailed) }
    }
    func profile(userID: UUID) async throws -> CollaborationProfile? {
        do {
            try await requireOwner(userID)
            let rows: [CollaborationProfile] = try await client.from("profiles")
                .select("id,display_name,friend_code,is_active,created_at,updated_at")
                .eq("id", value: userID.uuidString).limit(1).execute().value
            return rows.first
        } catch { throw translated(error, fallback: .profileFetch) }
    }
    func updateDisplayName(_ name: String, userID: UUID) async throws -> CollaborationProfile {
        struct NameUpdate: Encodable { let display_name: String }
        do {
            try await requireOwner(userID)
            // Only display_name is sent. Never insert profiles or write friend_code.
            let rows: [CollaborationProfile] = try await client.from("profiles")
                .update(NameUpdate(display_name: name)).eq("id", value: userID.uuidString)
                .select("id,display_name,friend_code,is_active,created_at,updated_at").execute().value
            guard let profile = rows.first else { throw CollaborationAuthError.profileMissing }
            return profile
        } catch { throw translated(error, fallback: .profileUpdate) }
    }
    private func translated(_ error: Error, fallback: CollaborationAuthError) -> CollaborationAuthError {
        if let domain = error as? CollaborationAuthError { return domain }
        if error is URLError { return .network }
        if let auth = error as? AuthError {
            switch auth.errorCode.rawValue {
            case "invalid_credentials": return .invalidCredentials
            case "email_not_confirmed": return .emailConfirmation
            case "session_not_found": return .sessionMissing
            default: break
            }
            if case .api(_, _, _, let response) = auth, response.statusCode >= 500 { return .unavailable }
        }
        return fallback
    }
}

// Configuration failure is recoverable UI state, not a fatal startup error.
@MainActor private final class UnconfiguredAccountRepository: AuthRepository, CollaborationProfileRepository {
    func restoreSession() async throws -> AuthenticatedUser? { throw CollaborationAuthError.configuration }
    func signUp(_ request: SignupRequest) async throws -> SignupResult { throw CollaborationAuthError.configuration }
    func signIn(email: String, password: String) async throws -> AuthenticatedUser { throw CollaborationAuthError.configuration }
    func signOut() async throws { throw CollaborationAuthError.configuration }
    func profile(userID: UUID) async throws -> CollaborationProfile? { throw CollaborationAuthError.configuration }
    func updateDisplayName(_ name: String, userID: UUID) async throws -> CollaborationProfile { throw CollaborationAuthError.configuration }
}
@MainActor enum CollaborationAccountComposition {
    static func unconfiguredModel() -> AuthViewModel {
        let repository = UnconfiguredAccountRepository()
        return AuthViewModel(auth: repository, profiles: repository)
    }
    static func makeModel() -> AuthViewModel {
        if let config = try? SupabaseConfiguration.load() {
            let repository = SupabaseAccountRepository(configuration: config)
            return AuthViewModel(auth: repository, profiles: repository)
        }
        let repository = UnconfiguredAccountRepository()
        return AuthViewModel(auth: repository, profiles: repository)
    }
}
