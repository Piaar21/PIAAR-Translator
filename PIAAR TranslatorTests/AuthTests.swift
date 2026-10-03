import XCTest
@testable import PIAAR_Translator

@MainActor final class AuthTests: XCTestCase {
    private let id = UUID()
    private func profile(_ id: UUID, name: String = "김대리") -> CollaborationProfile {
        CollaborationProfile(id: id, displayName: name, friendCode: "B3821K7M", isActive: true,
                             createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2))
    }
    private func fixture() -> (AuthViewModel, FakeAccount) {
        let fake = FakeAccount(); fake.row = profile(id)
        return (AuthViewModel(auth: fake, profiles: fake), fake)
    }
    func testSignedOut() async {
        let (vm, _) = fixture(); await vm.start()
        XCTAssertEqual(vm.state, .signedOut); XCTAssertFalse(vm.isBusy)
    }
    func testSignupRequestAndDisplayNameMetadata() async {
        let (vm, fake) = fixture(); await vm.signUp(name: " 김대리 ", email: " a@piaar.co.kr ", password: "password")
        XCTAssertEqual(fake.request, SignupRequest(displayName: "김대리", email: "a@piaar.co.kr", password: "password"))
        XCTAssertEqual(fake.request?.metadata, ["display_name": "김대리"])
    }
    func testSignupWithSessionLoadsTriggerProfile() async {
        let (vm, fake) = fixture(); fake.signup = .signedIn(AuthenticatedUser(id: id, email: nil))
        await vm.signUp(name: "김대리", email: "a@piaar.co.kr", password: "password")
        XCTAssertEqual(vm.profile, fake.row); XCTAssertEqual(fake.fetchIDs, [id])
    }
    func testSignupAwaitingConfirmationIsSuccessWithoutProfileFetch() async {
        let (vm, fake) = fixture(); await vm.signUp(name: "김대리", email: "a@piaar.co.kr", password: "password")
        XCTAssertEqual(vm.state, .needsEmailConfirmation); XCTAssertNil(vm.error); XCTAssertTrue(fake.fetchIDs.isEmpty)
    }
    func testLoginSuccess() async {
        let (vm, fake) = fixture(); fake.restored = AuthenticatedUser(id: id, email: "a@piaar.co.kr")
        await vm.signIn(email: "a@piaar.co.kr", password: "password")
        XCTAssertEqual(vm.profile?.id, id); XCTAssertEqual(vm.profile?.friendCode, "B3821K7M")
    }
    func testInvalidCredentials() async {
        let (vm, fake) = fixture(); fake.authFailure = .invalidCredentials
        await vm.signIn(email: "a@piaar.co.kr", password: "bad")
        XCTAssertEqual(vm.error, .invalidCredentials); XCTAssertFalse(vm.isBusy)
    }
    func testEmailConfirmationRequired() async {
        let (vm, fake) = fixture(); fake.authFailure = .emailConfirmation
        await vm.signIn(email: "a@piaar.co.kr", password: "password")
        XCTAssertEqual(vm.error, .emailConfirmation)
    }
    func testSessionRestore() async {
        let (vm, fake) = fixture(); fake.restored = AuthenticatedUser(id: id, email: nil)
        await vm.start(); XCTAssertEqual(vm.profile?.id, id)
    }
    func testSessionMissing() async {
        let (vm, _) = fixture(); await vm.restore()
        XCTAssertNil(vm.user); XCTAssertEqual(vm.state, .signedOut)
    }
    func testRefreshFailureIsNotSignedOutOrInfiniteSpinner() async {
        let (vm, fake) = fixture(); fake.authFailure = .refreshFailed
        await vm.restore(); XCTAssertEqual(vm.state, .error(.refreshFailed)); XCTAssertFalse(vm.isBusy)
    }
    func testSessionMissingAfterLoginClearsCachedIdentity() async {
        let (vm, fake) = fixture(); fake.restored = AuthenticatedUser(id: id, email: nil)
        await vm.restore(); fake.authFailure = .sessionMissing
        await vm.restore(); XCTAssertNil(vm.profile); XCTAssertNil(vm.user); XCTAssertEqual(vm.state, .signedOut)
    }
    func testProfileMissingSeparateFromLoginFailure() async {
        let (vm, fake) = fixture(); fake.row = nil; fake.restored = AuthenticatedUser(id: id, email: nil)
        await vm.restore(); XCTAssertEqual(vm.error, .profileMissing); XCTAssertEqual(vm.user?.id, id)
    }
    func testProfileFetchFailure() async {
        let (vm, fake) = fixture(); fake.restored = AuthenticatedUser(id: id, email: nil); fake.profileFailure = .profileFetch
        await vm.restore(); XCTAssertEqual(vm.error, .profileFetch)
    }
    func testProfileCannotBelongToDifferentAccount() async {
        let (vm, fake) = fixture(); fake.row = profile(UUID()); fake.restored = AuthenticatedUser(id: id, email: nil)
        await vm.restore(); XCTAssertNil(vm.profile); XCTAssertEqual(vm.error, .profileMissing)
    }
    func testNameUpdatePreservesIdentityAndFriendCode() async {
        let (vm, fake) = fixture(); fake.restored = AuthenticatedUser(id: id, email: nil)
        await vm.restore(); await vm.rename(" 박대리 ")
        XCTAssertEqual(vm.profile?.displayName, "박대리"); XCTAssertEqual(vm.profile?.id, id)
        XCTAssertEqual(vm.profile?.friendCode, "B3821K7M"); XCTAssertEqual(fake.updatedID, id)
    }
    func testNameUpdateFailureKeepsProfile() async {
        let (vm, fake) = fixture(); fake.restored = AuthenticatedUser(id: id, email: nil)
        await vm.restore(); let before = vm.profile; fake.profileFailure = .profileUpdate
        await vm.rename("새 이름"); XCTAssertEqual(vm.profile, before); XCTAssertEqual(vm.error, .profileUpdate)
    }
    func testOfflineRetainsLoadedProfile() async {
        let (vm, fake) = fixture(); fake.restored = AuthenticatedUser(id: id, email: nil)
        await vm.restore(); let before = vm.profile; fake.authFailure = .network
        await vm.restore(); XCTAssertEqual(vm.profile, before); XCTAssertEqual(vm.error, .network)
    }
    func testLogoutClearsCollaborationOnlyAndPreservesLocalTodo() async throws {
        let (vm, fake) = fixture(); fake.restored = AuthenticatedUser(id: id, email: nil)
        let container = try TodoPersistence.makeContainer(inMemory: true)
        let repository = SwiftDataTodoRepository(container: container)
        let todo = try TodoViewModel(repository: repository)
        todo.quickTitle = "보존할 개인 할 일"
        // Keep the real local repository populated across an unrelated auth logout.
        todo.submitQuickEntry()
        let before = todo.items
        await vm.restore(); await vm.signOut()
        XCTAssertEqual(vm.state, .signedOut); XCTAssertNil(vm.user); XCTAssertEqual(fake.logoutCount, 1)
        XCTAssertEqual(todo.items, before)
    }
    func testDifferentAccountProfileFailureDoesNotExposePreviousProfile() async {
        let (vm, fake) = fixture(); fake.restored = AuthenticatedUser(id: id, email: nil)
        await vm.restore(); XCTAssertNotNil(vm.profile)
        fake.restored = AuthenticatedUser(id: UUID(), email: nil); fake.profileFailure = .profileFetch
        await vm.restore(); XCTAssertNil(vm.profile); XCTAssertEqual(vm.error, .profileFetch)
    }
    func testRealAuthIdentityDoesNotChangeMockIdentity() async throws {
        let (vm, fake) = fixture(); fake.restored = AuthenticatedUser(id: id, email: nil)
        let mock = MockFriendRepository(); let before = try await mock.currentProfile()
        await vm.restore(); await vm.rename("실제 이름"); await vm.signOut()
        let after = try await mock.currentProfile()
        XCTAssertEqual(before, after); XCTAssertNotEqual(before.id, id)
    }
    func testLogoutNetworkFailureAfterLocalSessionRemovalClearsProfile() async {
        let (vm, fake) = fixture(); fake.restored = AuthenticatedUser(id: id, email: nil)
        await vm.restore(); fake.logoutFailureAfterRemoval = true
        await vm.signOut(); XCTAssertNil(vm.profile); XCTAssertNil(vm.user); XCTAssertEqual(vm.error, .network)
    }
    func testInvalidSignupDoesNotCallRepository() async {
        let (vm, fake) = fixture(); await vm.signUp(name: " ", email: "a@piaar.co.kr", password: "password")
        XCTAssertEqual(vm.error, .invalidInput); XCTAssertNil(fake.request)
    }
    func testConfigurationRejectsPrivilegedAndLegacyKeys() {
        for key in ["", "sb_secret_example", "service_role", "eyJhbGciOiJIUzI1NiJ9.example"] {
            XCTAssertThrowsError(try SupabaseConfiguration(projectURL: "https://example.supabase.co", publishableKey: key))
        }
    }
    func testConfigurationAcceptsOnlyPublishableKeyAndHTTPS() throws {
        let config = try SupabaseConfiguration(projectURL: "https://example.supabase.co", publishableKey: " sb_publishable_example ")
        XCTAssertEqual(config.publishableKey, "sb_publishable_example")
        XCTAssertThrowsError(try SupabaseConfiguration(projectURL: "http://example.supabase.co", publishableKey: "sb_publishable_example"))
    }
    func testProfileDecodesServerColumnNames() throws {
        let json = """
        {"id":"\(id)","display_name":"김대리","friend_code":"B3821K7M","is_active":true,"created_at":"2026-10-01T00:00:00Z","updated_at":"2026-10-02T00:00:00Z"}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let row = try decoder.decode(CollaborationProfile.self, from: Data(json.utf8))
        XCTAssertEqual(row.id, id); XCTAssertEqual(row.friendCode, "B3821K7M")
    }
}

@MainActor private final class FakeAccount: AuthRepository, CollaborationProfileRepository {
    var restored: AuthenticatedUser?
    var signup: SignupResult = .awaitingConfirmation
    var row: CollaborationProfile?
    var authFailure: CollaborationAuthError?
    var profileFailure: CollaborationAuthError?
    var request: SignupRequest?
    var fetchIDs: [UUID] = []
    var updatedID: UUID?
    var logoutCount = 0
    var logoutFailureAfterRemoval = false
    func restoreSession() async throws -> AuthenticatedUser? {
        if let authFailure { throw authFailure }; return restored
    }
    func signUp(_ request: SignupRequest) async throws -> SignupResult {
        if let authFailure { throw authFailure }; self.request = request; return signup
    }
    func signIn(email: String, password: String) async throws -> AuthenticatedUser {
        if let authFailure { throw authFailure }
        guard let restored else { throw CollaborationAuthError.invalidCredentials }; return restored
    }
    func signOut() async throws {
        if let authFailure { throw authFailure }; logoutCount += 1; restored = nil
        if logoutFailureAfterRemoval { throw CollaborationAuthError.network }
    }
    func profile(userID: UUID) async throws -> CollaborationProfile? {
        fetchIDs.append(userID); if let profileFailure { throw profileFailure }; return row
    }
    func updateDisplayName(_ name: String, userID: UUID) async throws -> CollaborationProfile {
        if let profileFailure { throw profileFailure }; updatedID = userID
        guard let row else { throw CollaborationAuthError.profileMissing }
        let updated = CollaborationProfile(id: row.id, displayName: name, friendCode: row.friendCode,
                                           isActive: row.isActive, createdAt: row.createdAt, updatedAt: Date())
        self.row = updated; return updated
    }
}
