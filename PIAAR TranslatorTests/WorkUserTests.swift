import XCTest
@testable import PIAAR_Translator

@MainActor private final class FakeWorkUserGateway: WorkUserGateway {
    var identity = "account-a"
    var unavailable = false
    var records: [String: StoredWorkUser] = [:]
    var publicProfiles: [String: PublicWorkUser] = [:]
    var saveFailures: Set<Int> = []
    var publicFailure: WorkUserError?
    var replacementAfterPublish: StoredWorkUser?
    var collisionCodes = Set<String>()
    var concurrentWinner: WorkUser?
    var switchAccountAfterPrivate = false
    var privateSaves = 0
    var publicSaves = 0
    var fetchError: WorkUserError?
    func currentIdentity() async throws -> String {
        if unavailable { throw WorkUserError.unavailable }; return identity
    }
    func fetchPrivate(identity: String) async throws -> StoredWorkUser? {
        if let fetchError { throw fetchError }; return records[identity]
    }
    func savePrivate(identity: String, user: WorkUser, pending: Bool, expectedRevision: String?) async throws -> StoredWorkUser {
        privateSaves += 1
        if saveFailures.contains(privateSaves) { throw WorkUserError.privateSaveFailure("injected") }
        if expectedRevision == nil, let winner = concurrentWinner {
            concurrentWinner = nil
            records[identity] = StoredWorkUser(user: winner, publicationPending: true, revision: "winner")
            throw WorkUserError.concurrentChange
        }
        guard records[identity]?.revision == expectedRevision else { throw WorkUserError.concurrentChange }
        let stored = StoredWorkUser(user: user, publicationPending: pending, revision: String(privateSaves),
            friendCodeEstablished: records[identity]?.friendCodeEstablished == true || !pending)
        records[identity] = stored
        if switchAccountAfterPrivate { self.identity = "account-b"; switchAccountAfterPrivate = false }
        return stored
    }
    func publish(_ profile: PublicWorkUser, identity: String) async throws -> Bool {
        guard identity == self.identity else { throw WorkUserError.accountChanged }
        publicSaves += 1
        if let publicFailure { throw publicFailure }
        if collisionCodes.contains(profile.friendCode) { return false }
        if let existing = publicProfiles[profile.friendCode], existing.workUserID != profile.workUserID { return false }
        publicProfiles[profile.friendCode] = profile
        if let replacementAfterPublish { records[identity] = replacementAfterPublish; self.replacementAfterPublish = nil }
        return true
    }
}

final class WorkUserTests: XCTestCase {
    @MainActor func testMissingUserDoesNotCreateAnything() async throws {
        let g = FakeWorkUserGateway(), r = ReconciledWorkUserRepository(gateway: FakeWorkUserGateway())
        let empty = try await r.currentUser(); XCTAssertNil(empty)
        let model = WorkUserProfileViewModel(repository: ReconciledWorkUserRepository(gateway: g))
        await model.load(); XCTAssertNil(model.user); XCTAssertTrue(model.loaded)
        XCTAssertEqual(g.privateSaves, 0); XCTAssertEqual(g.publicSaves, 0)
    }
    @MainActor func testCreateAndNewRepositoryReloadSameUUIDCode() async throws {
        let g = FakeWorkUserGateway()
        let first = try await ReconciledWorkUserRepository(gateway: g, code: { "ZX123456" }).create(displayName: " 새 사용자 ")
        let second = try await ReconciledWorkUserRepository(gateway: g).currentUser()
        XCTAssertEqual(first, second); XCTAssertEqual(first.displayName, "새 사용자")
        XCTAssertEqual(first.friendCode, "ZX123456"); XCTAssertEqual(first.displayedFriendCode, "#ZX123456")
        let repeated = try await ReconciledWorkUserRepository(gateway: g).create(displayName: "다른 입력")
        XCTAssertEqual(first, repeated); XCTAssertEqual(g.records.count, 1); XCTAssertEqual(g.publicProfiles.count, 1)
    }
    func testNameAndCodeValidation() throws {
        XCTAssertThrowsError(try WorkUser.validName(" \n"))
        XCTAssertThrowsError(try WorkUser.validName(String(repeating: "가", count: 31)))
        XCTAssertEqual(try WorkUser.validName(" 이름 "), "이름")
        XCTAssertEqual(try WorkUser.validName(String(repeating: "가", count: 30)).count, 30)
        for _ in 0..<100 { let code = WorkUser.randomFriendCode(); XCTAssertTrue(WorkUser.validCode(code)); XCTAssertEqual(try FriendCode(code).rawValue, code) }
        XCTAssertFalse(WorkUser.validCode("abcd1234")); XCTAssertFalse(WorkUser.validCode("ABCDE1234"))
    }
    @MainActor func testCollisionRetriesAndPreservesInternalUUID() async throws {
        let g = FakeWorkUserGateway(); g.collisionCodes = ["AAAA0000", "BBBB0000"]
        var codes = ["AAAA0000", "BBBB0000", "CCCC0000"]
        let user = try await ReconciledWorkUserRepository(gateway: g, code: { codes.removeFirst() }).create(displayName: "name")
        XCTAssertEqual(user.friendCode, "CCCC0000"); XCTAssertEqual(g.publicSaves, 3)
        XCTAssertEqual(g.records[g.identity]?.user.id, user.id); XCTAssertEqual(g.records.count, 1)
    }
    @MainActor func testCollisionAttemptsAreBoundedAndPendingUserRetained() async {
        let g = FakeWorkUserGateway(); g.collisionCodes = ["AAAA0000"]
        do { _ = try await ReconciledWorkUserRepository(gateway: g, maxAttempts: 3, code: { "AAAA0000" }).create(displayName: "name"); XCTFail() }
        catch { XCTAssertEqual(error as? WorkUserError, .collisionLimit) }
        XCTAssertEqual(g.publicSaves, 3); XCTAssertEqual(g.records.count, 1)
        XCTAssertTrue(g.records[g.identity]?.publicationPending == true)
    }
    @MainActor func testPrivateInitialFailureDoesNotPublishOrInventSuccessfulUser() async {
        let g = FakeWorkUserGateway(); g.saveFailures = [1]
        do { _ = try await ReconciledWorkUserRepository(gateway: g).create(displayName: "name"); XCTFail() }
        catch { XCTAssertEqual(error as? WorkUserError, .privateSaveFailure("injected")) }
        XCTAssertTrue(g.records.isEmpty); XCTAssertTrue(g.publicProfiles.isEmpty)
    }
    @MainActor func testPrivateSuccessPublicFailureReconcilesOnRelaunch() async throws {
        let g = FakeWorkUserGateway(); g.publicFailure = .publicSaveFailure("offline")
        do { _ = try await ReconciledWorkUserRepository(gateway: g).create(displayName: "name"); XCTFail() }
        catch { guard case .partialPublication = error as? WorkUserError else { return XCTFail("wrong error") } }
        let pending = try XCTUnwrap(g.records[g.identity])
        XCTAssertTrue(pending.publicationPending); XCTAssertTrue(g.publicProfiles.isEmpty)
        g.publicFailure = nil
        let recovered = try await ReconciledWorkUserRepository(gateway: g).currentUser()
        XCTAssertEqual(recovered, pending.user); XCTAssertFalse(g.records[g.identity]!.publicationPending)
        XCTAssertEqual(g.publicProfiles.count, 1)
    }
    @MainActor func testPublicSuccessPrivateFinalizationFailureReconcilesWithoutDuplicate() async throws {
        let g = FakeWorkUserGateway(); g.saveFailures = [2]
        do { _ = try await ReconciledWorkUserRepository(gateway: g).create(displayName: "name"); XCTFail() }
        catch { guard case .partialPublication = error as? WorkUserError else { return XCTFail("wrong error") } }
        let before = try XCTUnwrap(g.records[g.identity]?.user)
        XCTAssertEqual(g.publicProfiles.count, 1)
        let recovered = try await ReconciledWorkUserRepository(gateway: g).currentUser()
        XCTAssertEqual(recovered, before); XCTAssertEqual(g.publicProfiles.count, 1)
    }
    @MainActor func testConcurrentFirstCreateUsesWinnerWithoutDuplicateUUID() async throws {
        let g = FakeWorkUserGateway()
        let winner = WorkUser(id: UUID(), displayName: "winner", friendCode: "ZZ123456", createdAt: Date(), updatedAt: Date(), isActive: true)
        g.concurrentWinner = winner
        let actual = try await ReconciledWorkUserRepository(gateway: g).create(displayName: "loser")
        XCTAssertEqual(actual, winner); XCTAssertEqual(g.records.count, 1)
    }
    @MainActor func testPublicContainsOnlyFourAllowedValuesAndLinksUUID() async throws {
        let g = FakeWorkUserGateway()
        let user = try await ReconciledWorkUserRepository(gateway: g).create(displayName: "name")
        let publicUser = try XCTUnwrap(g.publicProfiles[user.friendCode])
        XCTAssertEqual(publicUser.workUserID, user.id)
        XCTAssertEqual(Set(Mirror(reflecting: publicUser).children.compactMap(\.label)), ["workUserID", "friendCode", "displayName", "isActive"])
    }
    @MainActor func testRenameUpdatesBothAndNeverChangesCodeOrUUID() async throws {
        let g = FakeWorkUserGateway(), now = Date()
        let r = ReconciledWorkUserRepository(gateway: g, clock: { now })
        let original = try await r.create(displayName: "old")
        let updated = try await r.updateDisplayName(" new ")
        XCTAssertEqual(updated.id, original.id); XCTAssertEqual(updated.friendCode, original.friendCode)
        XCTAssertEqual(updated.createdAt, original.createdAt); XCTAssertEqual(updated.displayName, "new")
        XCTAssertEqual(g.publicProfiles[updated.friendCode]?.displayName, "new")
    }
    @MainActor func testRenamePartialFailureRecoversOriginalIdentityAndNewName() async throws {
        let g = FakeWorkUserGateway()
        let repo = ReconciledWorkUserRepository(gateway: g)
        let original = try await repo.create(displayName: "old")
        g.publicFailure = .network
        do { _ = try await repo.updateDisplayName("new"); XCTFail() } catch {}
        XCTAssertEqual(g.publicProfiles[original.friendCode]?.displayName, "old")
        XCTAssertEqual(g.records[g.identity]?.user.displayName, "new")
        g.publicFailure = nil
        let repaired = try await ReconciledWorkUserRepository(gateway: g).currentUser()
        XCTAssertEqual(repaired?.id, original.id); XCTAssertEqual(repaired?.displayName, "new")
        XCTAssertEqual(repaired?.friendCode, original.friendCode)
    }
    @MainActor func testEstablishedCodeCannotBeReissuedDuringReconciliation() async throws {
        let g = FakeWorkUserGateway()
        let r = ReconciledWorkUserRepository(gateway: g)
        let user = try await r.create(displayName: "name")
        g.collisionCodes = [user.friendCode]
        do { _ = try await r.updateDisplayName("new"); XCTFail() } catch {}
        do { _ = try await r.currentUser(); XCTFail() } catch {}
        XCTAssertEqual(g.records[g.identity]?.user.friendCode, user.friendCode)
    }
    @MainActor func testAccountIsolationAndUnavailableBlocksWrites() async throws {
        let g = FakeWorkUserGateway()
        let repository = ReconciledWorkUserRepository(gateway: g)
        let a = try await repository.create(displayName: "a")
        g.identity = "account-b"
        let empty = try await repository.currentUser(); XCTAssertNil(empty)
        let b = try await repository.create(displayName: "b")
        XCTAssertNotEqual(a.id, b.id)
        g.unavailable = true
        let saves = g.privateSaves
        do { _ = try await repository.updateDisplayName("blocked"); XCTFail() } catch { XCTAssertEqual(error as? WorkUserError, .unavailable) }
        XCTAssertEqual(g.privateSaves, saves)
    }
    @MainActor func testOfflineViewModelKeepsLoadedRealUserAndStopsLoading() async throws {
        let g = FakeWorkUserGateway()
        let vm = WorkUserProfileViewModel(repository: ReconciledWorkUserRepository(gateway: g))
        let created = await vm.create("real"); XCTAssertTrue(created)
        let id = vm.user?.id
        g.fetchError = .network
        await vm.load()
        XCTAssertEqual(vm.user?.id, id); XCTAssertNotNil(vm.errorMessage); XCTAssertFalse(vm.isBusy)
        vm.accountChanged(); XCTAssertNil(vm.user)
    }
    @MainActor func testPrivateRenameFailureDoesNotChangePublicOrOriginal() async throws {
        let g = FakeWorkUserGateway()
        let repo = ReconciledWorkUserRepository(gateway: g)
        let user = try await repo.create(displayName: "old")
        g.saveFailures = [g.privateSaves + 1]
        do { _ = try await repo.updateDisplayName("new"); XCTFail() } catch {}
        XCTAssertEqual(g.records[g.identity]?.user, user)
        XCTAssertEqual(g.publicProfiles[user.friendCode]?.displayName, "old")
    }
    @MainActor func testLoadRepairsStalePublicNameWithoutChangingPrivateIdentity() async throws {
        let g = FakeWorkUserGateway()
        let repo = ReconciledWorkUserRepository(gateway: g)
        let original = try await repo.create(displayName: "old")
        let stale = try XCTUnwrap(g.publicProfiles[original.friendCode])
        let updated = try await repo.updateDisplayName("new")
        g.publicProfiles[original.friendCode] = stale
        let saves = g.privateSaves
        let repaired = try await ReconciledWorkUserRepository(gateway: g).currentUser()
        XCTAssertEqual(repaired, updated); XCTAssertEqual(g.privateSaves, saves)
        XCTAssertEqual(g.publicProfiles[original.friendCode]?.displayName, "new")
    }
    @MainActor func testRetryAfterDoesNotImmediatelyRepeatPublicPublication() async {
        let g = FakeWorkUserGateway(); g.publicFailure = .retryLater(seconds: 30)
        do { _ = try await ReconciledWorkUserRepository(gateway: g).create(displayName: "name"); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("30초")) }
        XCTAssertEqual(g.publicSaves, 1); XCTAssertEqual(g.records.count, 1)
    }
    @MainActor func testAccountSwitchDuringCreationCannotPublishUnderDifferentAccount() async {
        let g = FakeWorkUserGateway(); g.switchAccountAfterPrivate = true
        do { _ = try await ReconciledWorkUserRepository(gateway: g).create(displayName: "name"); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("계정이 변경")) }
        XCTAssertTrue(g.publicProfiles.isEmpty); XCTAssertNil(g.records["account-b"])
        XCTAssertNotNil(g.records["account-a"])
    }

    @MainActor func testConcurrentRenameDuringCleanLoadRepublishesLatestCanonicalName() async throws {
        let g = FakeWorkUserGateway()
        let old = try await ReconciledWorkUserRepository(gateway: g).create(displayName: "old")
        let latest = WorkUser(id: old.id, displayName: "latest", friendCode: old.friendCode,
            createdAt: old.createdAt, updatedAt: Date(), isActive: true)
        g.replacementAfterPublish = StoredWorkUser(user: latest, publicationPending: false,
                                                   revision: "newer", friendCodeEstablished: true)
        let actual = try await ReconciledWorkUserRepository(gateway: g).currentUser()
        XCTAssertEqual(actual, latest)
        XCTAssertEqual(g.publicProfiles[old.friendCode]?.displayName, "latest")
        XCTAssertEqual(g.records.count, 1)
    }

}
