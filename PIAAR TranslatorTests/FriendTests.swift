import XCTest
import SwiftData
@testable import PIAAR_Translator

final class FriendTests: XCTestCase {
    func testCodeNormalizationAndDisplay() throws {
        for input in ["A3K8R21P", "#a3k8r21p", "A3K8-R21P", "  #a3k8-r21p\n"] {
            let code = try FriendCode(input)
            XCTAssertEqual(code.rawValue, "A3K8R21P")
            XCTAssertEqual(code.displayValue, "#A3K8R21P")
        }
    }

    func testInvalidCodeRejected() {
        for input in ["", "#A3821", "123456789", "ABCDEFG!", "##A3K8R21P", "A3K8 R21P", "가나다라마바사아"] {
            XCTAssertThrowsError(try FriendCode(input)) { XCTAssertEqual($0 as? FriendError, .invalidCode) }
        }
        XCTAssertNoThrow(try FriendCode("D8842L1X"))
    }

    @MainActor func testInitialProfileAndEmptyFriendsAreMemoryOnly() async throws {
        let repo = MockFriendRepository()
        let profile = try await repo.currentProfile()
        XCTAssertEqual(profile.displayName, "양태호")
        XCTAssertEqual(profile.friendCode.rawValue, "A3K8R21P")
        let friends = try await repo.friends()
        XCTAssertTrue(friends.isEmpty)
    }

    @MainActor func testAddFriendPreservesUserAndTimestamp() async throws {
        let now = Date(timeIntervalSince1970: 1234)
        let repo = MockFriendRepository(clock: { now })
        let entry = try await repo.addFriend(code: FriendCode("#b3821-k7m"))
        XCTAssertEqual(entry.user.displayName, "김대리")
        XCTAssertEqual(entry.user.friendCode.displayValue, "#B3821K7M")
        XCTAssertEqual(entry.addedAt, now)
        let friends = try await repo.friends()
        XCTAssertEqual(friends, [entry])
    }

    @MainActor func testUnknownCodeIsNotFound() async throws {
        let repo = MockFriendRepository()
        do {
            _ = try await repo.addFriend(code: FriendCode("ZZZZZZZZ"))
            XCTFail("Unknown user accepted")
        } catch { XCTAssertEqual(error as? FriendError, .notFound) }
        let friends = try await repo.friends()
        XCTAssertTrue(friends.isEmpty)
    }

    @MainActor func testSelfAdditionRejected() async throws {
        let repo = MockFriendRepository()
        do {
            _ = try await repo.addFriend(code: FriendCode("A3K8R21P"))
            XCTFail("Self accepted")
        } catch { XCTAssertEqual(error as? FriendError, .selfAddition) }
    }

    @MainActor func testDuplicateDoesNotInsertAnotherEntry() async throws {
        let repo = MockFriendRepository()
        let entry = try await repo.addFriend(code: FriendCode("B3821K7M"))
        do {
            _ = try await repo.addFriend(code: FriendCode("#b3821-k7m"))
            XCTFail("Duplicate accepted")
        } catch { XCTAssertEqual(error as? FriendError, .duplicate) }
        let friends = try await repo.friends()
        XCTAssertEqual(friends, [entry])
    }

    @MainActor func testRemovalOnlyChangesFriendListAndDirectoryCanBeReused() async throws {
        let repo = MockFriendRepository()
        let profile = try await repo.currentProfile()
        let first = try await repo.addFriend(code: FriendCode("B3821K7M"))
        let other = try await repo.addFriend(code: FriendCode("C1057P2Q"))
        try await repo.removeFriend(id: first.id)
        let remaining = try await repo.friends()
        let unchangedProfile = try await repo.currentProfile()
        XCTAssertEqual(remaining, [other])
        XCTAssertEqual(unchangedProfile, profile)
        let readded = try await repo.addFriend(code: FriendCode("B3821K7M"))
        XCTAssertEqual(readded.user, first.user)
        XCTAssertNotEqual(readded.id, first.id)
        try await repo.removeFriend(id: UUID())
        let friends = try await repo.friends()
        XCTAssertEqual(friends.count, 2)
    }

    @MainActor func testDisplayNameUpdateKeepsIdentityAndCodeImmutable() async throws {
        let repo = MockFriendRepository()
        let before = try await repo.currentProfile()
        let updated = try await repo.updateDisplayName(" 새 이름 \n")
        XCTAssertEqual(updated.displayName, "새 이름")
        XCTAssertEqual(updated.id, before.id)
        XCTAssertEqual(updated.friendCode, before.friendCode)
        do {
            _ = try await repo.updateDisplayName(" \n")
            XCTFail("Empty name accepted")
        } catch { XCTAssertEqual(error as? FriendError, .emptyName) }
        let after = try await repo.currentProfile()
        XCTAssertEqual(after, updated)
    }

    @MainActor func testNewRepositoryResetsMockState() async throws {
        let first = MockFriendRepository()
        _ = try await first.addFriend(code: FriendCode("D8842L1X"))
        _ = try await first.updateDisplayName("changed")
        let fresh = MockFriendRepository()
        let friends = try await fresh.friends()
        let profile = try await fresh.currentProfile()
        XCTAssertTrue(friends.isEmpty)
        XCTAssertEqual(profile.displayName, "양태호")
    }

    @MainActor func testFriendOperationsLeavePersonalTodoStoreUnchanged() async throws {
        let container = try TodoPersistence.makeContainer(inMemory: true)
        let todoRepo = SwiftDataTodoRepository(container: container)
        let todo = try todoRepo.create(TodoDraft(title: "keep", date: Date()), calendar: .current)
        let repo = MockFriendRepository()
        let entry = try await repo.addFriend(code: FriendCode("B3821K7M"))
        _ = try await repo.updateDisplayName("name")
        try await repo.removeFriend(id: entry.id)
        XCTAssertEqual(try todoRepo.allTodos().map(\.id), [todo.id])
        XCTAssertEqual(try todoRepo.allTodos().first?.title, "keep")
        XCTAssertEqual(Set(container.schema.entities.map(\.name)), Set(["TodoItem", "TodoGroup", "TodoRepeatSchedule"]))
    }

    @MainActor func testViewModelNormalizesAddAndRetainsInputOnError() async throws {
        let model = FriendsViewModel(repository: MockFriendRepository())
        await model.load()
        model.codeInput = "#b3821-k7m"
        await model.addFriend()
        XCTAssertEqual(model.friends.count, 1)
        XCTAssertEqual(model.codeInput, "")
        XCTAssertNil(model.errorMessage)
        model.codeInput = "ZZZZZZZZ"
        await model.addFriend()
        XCTAssertEqual(model.errorMessage, FriendError.notFound.localizedDescription)
        XCTAssertEqual(model.codeInput, "ZZZZZZZZ")
        XCTAssertEqual(model.friends.count, 1)
        await model.removeFriend(try XCTUnwrap(model.friends.first))
        XCTAssertTrue(model.friends.isEmpty)
        XCTAssertNil(model.errorMessage)
        let saved = await model.saveDisplayName("new")
        XCTAssertTrue(saved)
        XCTAssertEqual(model.profile?.displayName, "new")
    }

    @MainActor func testViewModelAcceptsDifferentRepositoryImplementation() async {
        let model = FriendsViewModel(repository: UnavailableFriendRepository())
        await model.load()
        XCTAssertEqual(model.errorMessage, FriendError.notFound.localizedDescription)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.profile)
        XCTAssertTrue(model.friends.isEmpty)
    }
    @MainActor func testSearchByNameAndNormalizedPartialCode() async throws {
        let repo = MockFriendRepository()
        _ = try await repo.addFriend(code: FriendCode("B3821K7M"))
        _ = try await repo.addFriend(code: FriendCode("C1057P2Q"))
        let model = FriendsViewModel(repository: repo)
        await model.load()
        model.searchQuery = "김"
        XCTAssertEqual(model.filteredFriends.map { $0.user.displayName }, ["김대리"])
        model.searchQuery = " #c1057-p2q "
        XCTAssertEqual(model.filteredFriends.map { $0.user.displayName }, ["박대리"])
        model.searchQuery = "b3821-k"
        XCTAssertEqual(model.filteredFriends.map { $0.user.displayName }, ["김대리"])
    }

    @MainActor func testSearchOnlyFiltersAddedFriendsAndKeepsAddInputSeparate() async throws {
        let repo = MockFriendRepository()
        _ = try await repo.addFriend(code: FriendCode("B3821K7M"))
        let model = FriendsViewModel(repository: repo)
        await model.load()
        model.codeInput = "C1057P2Q"
        model.searchQuery = "D8842L1X"
        XCTAssertTrue(model.filteredFriends.isEmpty)
        XCTAssertEqual(model.friends.count, 1)
        XCTAssertEqual(model.codeInput, "C1057P2Q")
        model.searchQuery = " \n"
        XCTAssertEqual(model.filteredFriends, model.friends)
        model.searchQuery = "#"
        XCTAssertTrue(model.filteredFriends.isEmpty)
    }

    @MainActor func testNameSearchIgnoresCase() async throws {
        let user = WorkUserSummary(id: UUID(), displayName: "Alex Park", friendCode: try FriendCode("B3821K7M"))
        let model = FriendsViewModel(repository: SearchFriendRepository(user: user))
        await model.load()
        model.searchQuery = "aLEX p"
        XCTAssertEqual(model.filteredFriends.map(\.user.id), [user.id])
        model.searchQuery = "nobody"
        XCTAssertTrue(model.filteredFriends.isEmpty)
    }

    @MainActor func testProfileSidebarIsDistinctAndSharesCurrentProfileModel() async throws {
        let env = MockCollaborationEnvironment(seedReceivedTasks: false)
        let workspace = CollaborationWorkspace(environment: env)
        let navigation = WorkNavigationState()
        navigation.selectSidebar(.profile)
        XCTAssertEqual(navigation.sidebarSelection, .profile)
        XCTAssertNotEqual(navigation.sidebarSelection, .friends)
        await workspace.friends.load()
        let profileScreen = ProfileView(model: workspace.friends)
        let friendScreen = FriendsView(model: workspace.friends, sharedTasks: workspace.sharedTasks)
        XCTAssertTrue(profileScreen.model === friendScreen.model)
        let original = try XCTUnwrap(workspace.friends.profile)
        let saved = await profileScreen.model.saveDisplayName("새 이름")
        XCTAssertTrue(saved)
        let stored = try await env.friends.currentProfile()
        XCTAssertEqual(stored.displayName, "새 이름")
        XCTAssertEqual(friendScreen.model.profile, stored)
        XCTAssertEqual(stored.id, original.id)
        XCTAssertEqual(stored.friendCode, original.friendCode)
        XCTAssertEqual(stored.friendCode.displayValue, "#A3K8R21P")
    }

    @MainActor func testFriendPlusFlowClosesAfterNormalizedAdditionAndKeepsSearch() async throws {
        let model = FriendsViewModel(repository: MockFriendRepository())
        await model.load()
        XCTAssertFalse(model.addingFriend)
        model.beginAddingFriend(); XCTAssertTrue(model.addingFriend)
        model.codeInput = "  #b3821-k7m "
        await model.addFriend()
        XCTAssertFalse(model.addingFriend)
        XCTAssertEqual(model.friends.count, 1)
        XCTAssertTrue(model.codeInput.isEmpty)
        model.searchQuery = "김"
        XCTAssertEqual(model.filteredFriends.count, 1)
        model.beginAddingFriend(); model.codeInput = "C1057P2Q"
        model.cancelAddingFriend()
        XCTAssertFalse(model.addingFriend); XCTAssertTrue(model.codeInput.isEmpty)
        XCTAssertEqual(model.friends.count, 1)
    }

    @MainActor func testFriendAddSheetStaysOpenForSelfDuplicateAndMissingCodes() async throws {
        let model = FriendsViewModel(repository: MockFriendRepository())
        await model.load()
        for code in ["A3K8R21P", "ZZZZZZZZ"] {
            model.beginAddingFriend(); model.codeInput = code
            await model.addFriend()
            XCTAssertTrue(model.addingFriend); XCTAssertNotNil(model.errorMessage)
            XCTAssertTrue(model.friends.isEmpty)
        }
        model.codeInput = "B3821K7M"; await model.addFriend()
        model.beginAddingFriend(); model.codeInput = "#b3821-k7m"; await model.addFriend()
        XCTAssertTrue(model.addingFriend); XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.friends.count, 1)
    }

}

@MainActor private final class UnavailableFriendRepository: FriendRepository {
    func currentProfile() async throws -> WorkUserSummary { throw FriendError.notFound }
    func friends() async throws -> [FriendEntry] { [] }
    func addFriend(code: FriendCode) async throws -> FriendEntry { throw FriendError.notFound }
    func removeFriend(id: UUID) async throws { throw FriendError.notFound }
    func updateDisplayName(_ name: String) async throws -> WorkUserSummary { throw FriendError.notFound }
}

@MainActor private final class SearchFriendRepository: FriendRepository {
    let user: WorkUserSummary
    init(user: WorkUserSummary) { self.user = user }
    func currentProfile() async throws -> WorkUserSummary { user }
    func friends() async throws -> [FriendEntry] { [.init(id: user.id, user: user, addedAt: Date())] }
    func addFriend(code: FriendCode) async throws -> FriendEntry { throw FriendError.notFound }
    func removeFriend(id: UUID) async throws {}
    func updateDisplayName(_ name: String) async throws -> WorkUserSummary { user }
}
