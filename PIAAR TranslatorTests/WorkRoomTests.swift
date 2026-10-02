import XCTest
import SwiftData
@testable import PIAAR_Translator

final class WorkRoomTests: XCTestCase {
    @MainActor private func fixture() async throws -> (MockCollaborationEnvironment, WorkUserSummary, [FriendEntry], WorkRoom) {
        let env = MockCollaborationEnvironment(seedReceivedTasks: false)
        let profile = try await env.friends.currentProfile()
        let a = try await env.friends.addFriend(code: FriendCode("B3821K7M"))
        let b = try await env.friends.addFriend(code: FriendCode("C1057P2Q"))
        let room = try await env.rooms.createRoom(name: "방", creator: profile, invitedUserIDs: [a.user.id, b.user.id])
        return (env, profile, [a, b], room)
    }
    @MainActor private func makeTask(_ env: MockCollaborationEnvironment, _ room: WorkRoom,
                                    _ sender: WorkUserSummary, _ receiver: WorkUserSummary,
                                    groupID: UUID? = nil) async throws -> SharedTask {
        try await env.tasks.sendRoomTask(SharedTaskDraft(title: "업무", date: Date()), roomID: room.id,
                                        groupID: groupID, sender: sender, receiver: receiver)
    }

    @MainActor func testInitialRoomListEmptyAndCreatorAutomaticallyJoins() async throws {
        let env = MockCollaborationEnvironment(seedReceivedTasks: false)
        let profile = try await env.friends.currentProfile()
        let before = try await env.rooms.rooms(for: profile.id)
        XCTAssertTrue(before.isEmpty)
        let room = try await env.rooms.createRoom(name: "  양말  ", creator: profile, invitedUserIDs: [])
        let members = try await env.rooms.members(roomID: room.id, actorUserID: profile.id)
        XCTAssertEqual(room.name, "양말"); XCTAssertEqual(room.creatorUserID, profile.id)
        XCTAssertEqual(members.map(\.userID), [profile.id]); XCTAssertNil(members.first?.removedAt)
        let list = try await env.rooms.rooms(for: profile.id)
        XCTAssertEqual(list, [room])
    }

    @MainActor func testFriendsInvitedOnceAndUnknownInviteFailsWithoutPartialRoom() async throws {
        let (env, profile, friends, room) = try await fixture()
        let members = try await env.rooms.members(roomID: room.id, actorUserID: profile.id)
        XCTAssertEqual(Set(members.map(\.userID)), Set([profile.id] + friends.map { $0.user.id }))
        try await env.rooms.addMember(roomID: room.id, userID: friends[0].user.id, actorUserID: profile.id)
        let unchanged = try await env.rooms.members(roomID: room.id, actorUserID: profile.id)
        XCTAssertEqual(unchanged.count, 3)
        do {
            _ = try await env.rooms.createRoom(name: "bad", creator: profile, invitedUserIDs: [UUID()])
            XCTFail("non-friend room")
        } catch { XCTAssertEqual(error as? WorkRoomError, .notFriend) }
        do {
            try await env.rooms.addMember(roomID: room.id, userID: UUID(), actorUserID: profile.id)
            XCTFail("non-friend member")
        } catch { XCTAssertEqual(error as? WorkRoomError, .notFriend) }
        let rooms = try await env.rooms.rooms(for: profile.id)
        XCTAssertEqual(rooms.count, 1)
    }

    @MainActor func testEmptyNamesAndCreatorRemovalAreRejected() async throws {
        let (env, profile, _, room) = try await fixture()
        do { _ = try await env.rooms.createRoom(name: " \n", creator: profile, invitedUserIDs: []); XCTFail("empty") }
        catch { XCTAssertEqual(error as? WorkRoomError, .emptyName) }
        do { try await env.rooms.removeMember(roomID: room.id, userID: profile.id, actorUserID: profile.id); XCTFail("creator removed") }
        catch { XCTAssertEqual(error as? WorkRoomError, .creatorRemoval) }
    }

    @MainActor func testOnlyCreatorManagesMembersAndArchive() async throws {
        let (env, profile, friends, room) = try await fixture()
        let actor = friends[0].user.id
        do { try await env.rooms.removeMember(roomID: room.id, userID: friends[1].user.id, actorUserID: actor); XCTFail("unauthorized") }
        catch { XCTAssertEqual(error as? WorkRoomError, .forbidden) }
        do { try await env.rooms.archiveRoom(id: room.id, actorUserID: actor); XCTFail("unauthorized archive") }
        catch { XCTAssertEqual(error as? WorkRoomError, .forbidden) }
        let members = try await env.rooms.members(roomID: room.id, actorUserID: profile.id)
        XCTAssertEqual(members.filter { $0.removedAt == nil }.count, 3)
    }

    @MainActor func testRemovedMemberIsSoftDeletedAndExcludedFromRoomList() async throws {
        let (env, profile, friends, room) = try await fixture()
        try await env.rooms.removeMember(roomID: room.id, userID: friends[0].user.id, actorUserID: profile.id)
        let members = try await env.rooms.members(roomID: room.id, actorUserID: profile.id)
        let removed = try XCTUnwrap(members.first { $0.userID == friends[0].user.id })
        XCTAssertNotNil(removed.removedAt); XCTAssertEqual(removed.displayNameSnapshot, "김대리")
        let rooms = try await env.rooms.rooms(for: friends[0].user.id)
        XCTAssertTrue(rooms.isEmpty)
        try await env.rooms.addMember(roomID: room.id, userID: friends[0].user.id, actorUserID: profile.id)
        let rejoined = try await env.rooms.members(roomID: room.id, actorUserID: profile.id)
        XCTAssertEqual(rejoined.filter { $0.userID == friends[0].user.id }.count, 2)
        XCTAssertEqual(rejoined.filter { $0.userID == friends[0].user.id && $0.removedAt == nil }.count, 1)
    }

    @MainActor func testArchiveHidesSidebarWithoutDeletingTasksOrHistory() async throws {
        let (env, profile, friends, room) = try await fixture()
        let task = try await makeTask(env, room, profile, friends[0].user)
        let before = try await env.tasks.history(taskID: task.id, actorUserID: profile.id)
        try await env.rooms.archiveRoom(id: room.id, actorUserID: profile.id)
        let list = try await env.rooms.rooms(for: profile.id)
        let archived = try await env.rooms.room(id: room.id, for: profile.id)
        let tasks = try await env.tasks.roomTasks(roomID: room.id, for: profile.id)
        let after = try await env.tasks.history(taskID: task.id, actorUserID: profile.id)
        XCTAssertTrue(list.isEmpty); XCTAssertTrue(archived.isArchived); XCTAssertEqual(tasks, [task]); XCTAssertEqual(after, before)
        do { _ = try await makeTask(env, room, profile, friends[0].user); XCTFail("archived write") }
        catch { XCTAssertEqual(error as? WorkRoomError, .archived) }
    }

    @MainActor func testGroupsCreateRenameAndReorderIndependentOfPersonalGroups() async throws {
        let (env, profile, _, room) = try await fixture()
        let a = try await env.rooms.createGroup(roomID: room.id, name: "상세페이지", color: "#E05252", actorUserID: profile.id)
        let b = try await env.rooms.createGroup(roomID: room.id, name: "발주", color: nil, actorUserID: profile.id)
        XCTAssertEqual(a.sortOrder, 0); XCTAssertEqual(b.sortOrder, 1); XCTAssertEqual(a.roomID, room.id)
        try await env.rooms.renameGroup(roomID: room.id, groupID: a.id, name: " new ", actorUserID: profile.id)
        try await env.rooms.reorderGroups(roomID: room.id, ids: [b.id, a.id], actorUserID: profile.id)
        let groups = try await env.rooms.groups(roomID: room.id, actorUserID: profile.id)
        XCTAssertEqual(groups.map(\.id), [b.id, a.id]); XCTAssertEqual(groups.map(\.sortOrder), [0, 1])
        XCTAssertEqual(groups.last?.name, "new"); XCTAssertEqual(groups.last?.colorHex, a.colorHex)
        do { try await env.rooms.reorderGroups(roomID: room.id, ids: [b.id, b.id], actorUserID: profile.id); XCTFail("duplicate") }
        catch { XCTAssertEqual(error as? WorkRoomError, .invalidOrder) }
    }

    @MainActor func testDeleteGroupMovesTasksToUngroupedWithoutLosingHistory() async throws {
        let (env, profile, friends, room) = try await fixture()
        let group = try await env.rooms.createGroup(roomID: room.id, name: "g", color: nil, actorUserID: profile.id)
        let task = try await makeTask(env, room, profile, friends[0].user, groupID: group.id)
        let before = try await env.tasks.history(taskID: task.id, actorUserID: profile.id)
        try await env.rooms.deleteGroup(roomID: room.id, groupID: group.id, actorUserID: profile.id)
        let saved = try await env.tasks.task(id: task.id, actorUserID: profile.id)
        let history = try await env.tasks.history(taskID: task.id, actorUserID: profile.id)
        let groups = try await env.rooms.groups(roomID: room.id, actorUserID: profile.id)
        XCTAssertNil(saved.roomGroupID); XCTAssertEqual(saved.id, task.id); XCTAssertEqual(history, before); XCTAssertTrue(groups.isEmpty)
    }

    @MainActor func testSelfTaskHasCreatedOnlyAndNoSentReceivedDuplication() async throws {
        let (env, profile, _, room) = try await fixture()
        let task = try await makeTask(env, room, profile, profile)
        XCTAssertEqual(task.senderUserID, profile.id); XCTAssertEqual(task.receiverUserID, profile.id)
        XCTAssertEqual(task.roomID, room.id); XCTAssertNil(task.roomGroupID)
        let history = try await env.tasks.history(taskID: task.id, actorUserID: profile.id)
        XCTAssertEqual(history.map(\.action), [.created])
        let sent = try await env.tasks.sentTasks(for: profile.id), received = try await env.tasks.receivedTasks(for: profile.id)
        XCTAssertTrue(sent.isEmpty); XCTAssertTrue(received.isEmpty)
        _ = try await env.tasks.complete(taskID: task.id, actorUserID: profile.id)
    }

    @MainActor func testRoomDeliveryAppearsAsSameIDInAllThreeProjections() async throws {
        let (env, profile, friends, room) = try await fixture()
        let group = try await env.rooms.createGroup(roomID: room.id, name: "g", color: nil, actorUserID: profile.id)
        let task = try await makeTask(env, room, profile, friends[0].user, groupID: group.id)
        let sent = try await env.tasks.sentTasks(for: profile.id)
        let received = try await env.tasks.receivedTasks(for: friends[0].user.id)
        let roomTasks = try await env.tasks.roomTasks(roomID: room.id, for: friends[1].user.id)
        XCTAssertEqual(sent.map(\.id), [task.id]); XCTAssertEqual(received.map(\.id), [task.id]); XCTAssertEqual(roomTasks.map(\.id), [task.id])
        XCTAssertEqual(task.roomGroupID, group.id); XCTAssertEqual(task.receiverUserID, friends[0].user.id)
    }

    @MainActor func testNonMemberAndRemovedMemberCannotReadRoomOrHistoryOrWrite() async throws {
        let (env, profile, friends, room) = try await fixture()
        let task = try await makeTask(env, room, profile, friends[0].user)
        try await env.rooms.removeMember(roomID: room.id, userID: friends[0].user.id, actorUserID: profile.id)
        for actor in [UUID(), friends[0].user.id] {
            do { _ = try await env.tasks.roomTasks(roomID: room.id, for: actor); XCTFail("read") }
            catch { XCTAssertEqual(error as? WorkRoomError, .forbidden) }
            do { _ = try await env.tasks.history(taskID: task.id, actorUserID: actor); XCTFail("history") }
            catch { XCTAssertEqual(error as? WorkRoomError, .forbidden) }
            do { _ = try await env.tasks.task(id: task.id, actorUserID: actor); XCTFail("task read") }
            catch { XCTAssertEqual(error as? WorkRoomError, .forbidden) }
        }
        do { _ = try await env.tasks.task(id: task.id); XCTFail("anonymous room read") }
        catch { XCTAssertEqual(error as? WorkRoomError, .forbidden) }
        do { _ = try await env.tasks.complete(taskID: task.id, actorUserID: friends[0].user.id); XCTFail("removed completion") }
        catch { XCTAssertEqual(error as? WorkRoomError, .forbidden) }
        let hidden = try await env.tasks.receivedTasks(for: friends[0].user.id)
        XCTAssertTrue(hidden.isEmpty)
        let preserved = try await env.tasks.history(taskID: task.id, actorUserID: profile.id)
        XCTAssertEqual(preserved.map(\.action), [.created, .sent])
    }

    @MainActor func testOnlyReceiverCanCompleteAndRoomHistoryReusesExistingActions() async throws {
        let (env, profile, friends, room) = try await fixture()
        let task = try await makeTask(env, room, profile, friends[0].user)
        for actor in [profile.id, friends[1].user.id] {
            do { _ = try await env.tasks.complete(taskID: task.id, actorUserID: actor); XCTFail("wrong actor") }
            catch { XCTAssertEqual(error as? SharedTaskError, .forbidden) }
        }
        _ = try await env.tasks.complete(taskID: task.id, actorUserID: friends[0].user.id)
        _ = try await env.tasks.reopen(taskID: task.id, actorUserID: friends[0].user.id)
        let history = try await env.tasks.history(taskID: task.id, actorUserID: friends[1].user.id)
        XCTAssertEqual(history.map(\.action), [.created, .sent, .completed, .reopened])
        XCTAssertEqual(history.last?.actorDisplayName, "김대리")
    }

    @MainActor func testNonMemberReceiverAndGroupFromAnotherRoomAreRejected() async throws {
        let (env, profile, friends, room) = try await fixture()
        let outsider = try await env.friends.addFriend(code: FriendCode("D8842L1X"))
        do { _ = try await makeTask(env, room, profile, outsider.user); XCTFail("nonmember recipient") }
        catch { XCTAssertEqual(error as? WorkRoomError, .forbidden) }
        let other = try await env.rooms.createRoom(name: "other", creator: profile, invitedUserIDs: [])
        let group = try await env.rooms.createGroup(roomID: other.id, name: "g", color: nil, actorUserID: profile.id)
        do { _ = try await makeTask(env, room, profile, friends[0].user, groupID: group.id); XCTFail("cross-room group") }
        catch { XCTAssertEqual(error as? WorkRoomError, .groupNotFound) }
    }

    @MainActor func testFriendRemovalDoesNotRemoveMembershipSnapshotsOrTasks() async throws {
        let (env, profile, friends, room) = try await fixture()
        let task = try await makeTask(env, room, profile, friends[0].user)
        try await env.friends.removeFriend(id: friends[0].id)
        let members = try await env.rooms.members(roomID: room.id, actorUserID: profile.id)
        XCTAssertTrue(members.contains { $0.userID == friends[0].user.id && $0.removedAt == nil })
        let taskRead = try await env.tasks.task(id: task.id, actorUserID: profile.id)
        XCTAssertEqual(taskRead.receiverDisplayName, "김대리")
        let user = try await env.rooms.memberUser(roomID: room.id, userID: friends[0].user.id, actorUserID: profile.id)
        XCTAssertEqual(user.id, friends[0].user.id); XCTAssertEqual(user.friendCode, friends[0].user.friendCode)
    }

    @MainActor func testEnvironmentUsesSameUserIDsAcrossFriendRoomAndSharedTask() async throws {
        let (env, profile, friends, room) = try await fixture()
        let directory = try XCTUnwrap(env.friends.mockUsers.first { $0.friendCode == friends[0].user.friendCode })
        let members = try await env.rooms.members(roomID: room.id, actorUserID: profile.id)
        let task = try await makeTask(env, room, profile, friends[0].user)
        XCTAssertEqual(directory.id, friends[0].user.id)
        XCTAssertTrue(members.contains { $0.userID == directory.id })
        XCTAssertEqual(task.senderUserID, env.friends.mockProfile.id); XCTAssertEqual(task.receiverUserID, directory.id)
        let newEnvironment = MockCollaborationEnvironment(seedReceivedTasks: false)
        let fresh = try await newEnvironment.rooms.rooms(for: newEnvironment.friends.mockProfile.id)
        XCTAssertTrue(fresh.isEmpty)
    }

    @MainActor func testRoomNameLookupAndViewModelCrossScreenRefresh() async throws {
        let (env, profile, friends, room) = try await fixture()
        let shared = SharedTasksViewModel(friends: env.friends, tasks: env.tasks, rooms: env.rooms)
        let model = WorkRoomsViewModel(friends: env.friends, rooms: env.rooms, tasks: env.tasks, sharedTasks: shared)
        await model.loadRoom(room.id)
        let created = await model.addTask(title: "shared", groupID: nil, receiverID: friends[0].user.id, requestID: UUID())
        XCTAssertTrue(created); XCTAssertEqual(model.tasks.count, 1); XCTAssertEqual(shared.sent.count, 1)
        XCTAssertEqual(model.tasks.first?.id, shared.sent.first?.id)
        XCTAssertEqual(shared.roomNames[room.id], room.name)
        let groupCreated = await model.addGroup(name: "g", color: nil)
        XCTAssertTrue(groupCreated)
        let group = try XCTUnwrap(model.groups.first)
        let selfCreated = await model.addTask(title: "mine", groupID: group.id, receiverID: profile.id, requestID: UUID())
        XCTAssertTrue(selfCreated)
        let mine = try XCTUnwrap(model.tasks.first { $0.receiverUserID == profile.id })
        await model.toggle(mine)
        XCTAssertTrue(model.tasks.first { $0.id == mine.id }?.isCompleted == true)
        XCTAssertEqual(model.sections.last?.group, nil)
        await model.deleteGroup(group)
        XCTAssertTrue(model.tasks.allSatisfy { $0.roomGroupID == nil })
    }

    @MainActor func testCreateRoomViewModelReturnsIDAndUpdatesSidebar() async throws {
        let env = MockCollaborationEnvironment(seedReceivedTasks: false)
        let shared = SharedTasksViewModel(friends: env.friends, tasks: env.tasks, rooms: env.rooms)
        let model = WorkRoomsViewModel(friends: env.friends, rooms: env.rooms, tasks: env.tasks, sharedTasks: shared)
        let friend = try await env.friends.addFriend(code: FriendCode("B3821K7M"))
        let id = await model.createRoom(name: "new", invited: [friend.user.id])
        XCTAssertNotNil(id); XCTAssertEqual(model.rooms.first?.id, id); XCTAssertEqual(model.members.count, 2)
        let archived = await model.archive()
        XCTAssertTrue(archived); XCTAssertTrue(model.rooms.isEmpty)
    }

    @MainActor func testRoomOperationsDoNotModifyPersonalTodoSchemaOrRecords() async throws {
        let container = try TodoPersistence.makeContainer(inMemory: true)
        let repo = SwiftDataTodoRepository(container: container)
        let group = try repo.createGroup(name: "personal")
        let todo = try repo.create(TodoDraft(title: "keep", date: Date(), groupID: group.id), calendar: .current)
        let (env, profile, _, room) = try await fixture()
        _ = try await env.rooms.createGroup(roomID: room.id, name: "room-only", color: nil, actorUserID: profile.id)
        _ = try await makeTask(env, room, profile, profile)
        XCTAssertEqual(try repo.allTodos(), [todo]); XCTAssertEqual(try repo.groups().map(\.id), [group.id])
        XCTAssertEqual(Set(container.schema.entities.map(\.name)), Set(["TodoItem", "TodoGroup", "TodoRepeatSchedule"]))
    }
    @MainActor func testNewFriendCanJoinAndRemovedReceiverCannotReceiveNewTasks() async throws {
        let (env, profile, friends, room) = try await fixture()
        let added = try await env.friends.addFriend(code: FriendCode("D8842L1X"))
        try await env.rooms.addMember(roomID: room.id, userID: added.user.id, actorUserID: profile.id)
        let members = try await env.rooms.members(roomID: room.id, actorUserID: profile.id)
        XCTAssertTrue(members.contains { $0.userID == added.user.id && $0.removedAt == nil })
        try await env.rooms.removeMember(roomID: room.id, userID: friends[0].user.id, actorUserID: profile.id)
        do { _ = try await makeTask(env, room, profile, friends[0].user); XCTFail("removed recipient") }
        catch { XCTAssertEqual(error as? WorkRoomError, .forbidden) }
    }

    @MainActor func testLatestRoomSelectionIsNotDroppedDuringLoad() async throws {
        let (env, profile, _, room) = try await fixture()
        let second = try await env.rooms.createRoom(name: "second", creator: profile, invitedUserIDs: [])
        let started = expectation(description: "profile request suspended")
        let gated = SuspendedProfileRepository(base: env.friends, started: started)
        let shared = SharedTasksViewModel(friends: env.friends, tasks: env.tasks, rooms: env.rooms)
        let model = WorkRoomsViewModel(friends: gated, rooms: env.rooms, tasks: env.tasks, sharedTasks: shared)
        let firstLoad = Task { await model.loadRoom(room.id) }
        await fulfillment(of: [started], timeout: 3)
        await model.loadRoom(second.id)
        gated.resume()
        await firstLoad.value
        XCTAssertEqual(model.selectedRoom?.id, second.id)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor func testRoomReceiverSelectorDefaultsToCurrentUserAndExcludesRemovedMember() async throws {
        let (env, profile, friends, room) = try await fixture()
        let shared = SharedTasksViewModel(friends: env.friends, tasks: env.tasks, rooms: env.rooms)
        let model = WorkRoomsViewModel(friends: env.friends, rooms: env.rooms, tasks: env.tasks, sharedTasks: shared)
        await model.loadRoom(room.id)
        XCTAssertTrue(model.taskRecipients.contains { $0.id == profile.id })
        XCTAssertEqual(Set(model.taskRecipients.map(\.id)), Set([profile.id] + friends.map { $0.user.id }))
        await model.removeMember(friends[0].user.id)
        XCTAssertFalse(model.taskRecipients.contains { $0.id == friends[0].user.id })
        let blocked = await model.addTask(title: "removed", groupID: nil,
            receiverID: friends[0].user.id, requestID: UUID())
        XCTAssertFalse(blocked); XCTAssertTrue(model.tasks.isEmpty)
        let mine = await model.addTask(title: "mine", groupID: nil, receiverID: profile.id, requestID: UUID())
        XCTAssertTrue(mine); XCTAssertEqual(model.tasks.first?.receiverUserID, profile.id)
    }

}

@MainActor private final class SuspendedProfileRepository: FriendRepository {
    let base: any FriendRepository
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var firstRequest = true
    init(base: any FriendRepository, started: XCTestExpectation) { self.base = base; self.started = started }
    func currentProfile() async throws -> WorkUserSummary {
        if firstRequest {
            firstRequest = false
            await withCheckedContinuation { continuation = $0; started.fulfill() }
        }
        return try await base.currentProfile()
    }
    func resume() { continuation?.resume(); continuation = nil }
    func friends() async throws -> [FriendEntry] { try await base.friends() }
    func addFriend(code: FriendCode) async throws -> FriendEntry { try await base.addFriend(code: code) }
    func removeFriend(id: UUID) async throws { try await base.removeFriend(id: id) }
    func updateDisplayName(_ name: String) async throws -> WorkUserSummary { try await base.updateDisplayName(name) }
}

final class FullSidebarNavigationTests: XCTestCase {
    @MainActor private func verifyRoomNavigation(count: Int) async throws {
        let env = MockCollaborationEnvironment(seedReceivedTasks: false)
        let me = try await env.friends.currentProfile()
        var ids: [UUID] = []
        for index in 0..<count {
            let room = try await env.rooms.createRoom(name: "업무방 \(index)", creator: me, invitedUserIDs: [])
            ids.append(room.id)
        }
        let workspace = CollaborationWorkspace(environment: env)
        await workspace.rooms.loadSidebar()
        XCTAssertEqual(Set(workspace.rooms.rooms.map(\.id)), Set(ids))
        let navigation = WorkNavigationState()
        for room in workspace.rooms.rooms {
            navigation.selectSidebar(.room(room.id))
            XCTAssertEqual(navigation.sidebarSelection, .room(room.id))
        }
        navigation.selectSidebar(.friends)
        XCTAssertEqual(navigation.sidebarSelection, .friends)
        navigation.selectSidebar(.profile)
        XCTAssertEqual(navigation.sidebarSelection, .profile)
        XCTAssertEqual(Set(workspace.rooms.rooms.map(\.id)), Set(ids))
        navigation.selectSidebar(.myTodos)
        XCTAssertEqual(navigation.sidebarSelection, .myTodos)
    }
    @MainActor func testNoRoomsKeepsFriendsAndProfileNavigation() async throws { try await verifyRoomNavigation(count: 0) }
    @MainActor func testFewRoomsKeepEveryRoomDestination() async throws { try await verifyRoomNavigation(count: 3) }
    @MainActor func testManyRoomsKeepAllDestinationsAndBottomNavigation() async throws { try await verifyRoomNavigation(count: 25) }
}
