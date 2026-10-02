import XCTest
import SwiftData
import AppKit
@testable import PIAAR_Translator

final class SharedTaskTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_816_400)
    private func user(_ name: String, _ code: String) throws -> WorkUserSummary {
        WorkUserSummary(id: UUID(), displayName: name, friendCode: try FriendCode(code))
    }
    @MainActor private func sent(_ repo: any SharedTaskRepository) async throws -> SharedTask {
        try await repo.sendTask(SharedTaskDraft(title: "업무", date: now),
            sender: user("sender", "A3K8R21P"), receiver: user("receiver", "B3821K7M"))
    }

    @MainActor func testSendAndSenderReceiverProjectionsShareOneID() async throws {
        let repo = MockSharedTaskRepository(clock: { self.now })
        let task = try await sent(repo)
        let sender = try await repo.sentTasks(for: task.senderUserID)
        let receiver = try await repo.receivedTasks(for: task.receiverUserID)
        let unrelated = try await repo.receivedTasks(for: UUID())
        XCTAssertEqual(sender, [task]); XCTAssertEqual(receiver, [task]); XCTAssertTrue(unrelated.isEmpty)
        XCTAssertNil(task.roomID); XCTAssertFalse(task.isCompleted); XCTAssertNil(task.completedAt)
        XCTAssertEqual(task.createdAt, now); XCTAssertEqual(task.updatedAt, now)
    }

    @MainActor func testTodoDraftCopiesOnlyTaskFieldsAndLeavesSourceUnchanged() async throws {
        let container = try TodoPersistence.makeContainer(inMemory: true)
        let personal = SwiftDataTodoRepository(container: container)
        let original = try personal.create(TodoDraft(title: "original", notes: "private note", date: now), calendar: .current)
        var todo = original
        todo.deadlineDate = now.addingTimeInterval(86400)
        todo.repeatRule = "daily"; todo.linkedCalendarEventID = "local-calendar"; todo.repeatScheduleID = UUID()
        let draft = SharedTaskDraft(todo: todo)
        let repo = MockSharedTaskRepository()
        let task = try await repo.sendTask(draft, sender: user("s", "A3K8R21P"), receiver: user("r", "B3821K7M"))
        XCTAssertEqual(task.sourceTodoID, original.id); XCTAssertEqual(task.title, original.title)
        XCTAssertEqual(task.date, original.date); XCTAssertEqual(task.deadlineDate, todo.deadlineDate)
        XCTAssertEqual(try personal.allTodos(), [original])
        XCTAssertEqual(Set(container.schema.entities.map(\.name)), Set(["TodoItem", "TodoGroup", "TodoRepeatSchedule"]))
    }

    func testLegacyEffectiveDeadlineCopiedWithoutOtherMetadata() throws {
        let todo = TodoSnapshot(id: UUID(), title: "legacy", notes: nil, date: now, isCompleted: false,
            completedAt: nil, createdAt: now, updatedAt: now, sortOrder: 0, groupID: UUID(),
            deadlineDateTime: now)
        XCTAssertEqual(SharedTaskDraft(todo: todo).deadlineDate, now)
    }

    @MainActor func testSelfSendAndEmptyTitleRejected() async throws {
        let repo = MockSharedTaskRepository()
        let sender = try user("s", "A3K8R21P")
        do {
            _ = try await repo.sendTask(SharedTaskDraft(title: "t", date: now), sender: sender, receiver: sender)
            XCTFail("self send")
        } catch { XCTAssertEqual(error as? SharedTaskError, .selfSend) }
        do {
            _ = try await repo.sendTask(SharedTaskDraft(title: " \n", date: now), sender: sender, receiver: user("r", "B3821K7M"))
            XCTFail("empty title")
        } catch { XCTAssertEqual(error as? SharedTaskError, .emptyTitle) }
        let tasks = try await repo.sentTasks(for: sender.id)
        XCTAssertTrue(tasks.isEmpty)
    }

    @MainActor func testSameSendRequestIsIdempotentAndReceiverCannotBeChanged() async throws {
        let repo = MockSharedTaskRepository()
        let draft = SharedTaskDraft(title: "task", date: now)
        let sender = try user("s", "A3K8R21P"), receiver = try user("r", "B3821K7M")
        let first = try await repo.sendTask(draft, sender: sender, receiver: receiver)
        let retry = try await repo.sendTask(draft, sender: sender, receiver: receiver)
        XCTAssertEqual(first, retry)
        let history = try await repo.history(taskID: first.id)
        XCTAssertEqual(history.count, 2)
        do {
            _ = try await repo.sendTask(draft, sender: sender, receiver: user("other", "C1057P2Q"))
            XCTFail("receiver changed")
        } catch { XCTAssertEqual(error as? SharedTaskError, .conflictingRequest) }
        let all = try await repo.sentTasks(for: sender.id)
        XCTAssertEqual(all.count, 1)
    }

    @MainActor func testReceiverCanCompleteAndReopenWithImmutableContent() async throws {
        var clock = now
        let repo = MockSharedTaskRepository(clock: { clock })
        let task = try await sent(repo)
        clock = now.addingTimeInterval(60)
        let done = try await repo.complete(taskID: task.id, actorUserID: task.receiverUserID)
        XCTAssertTrue(done.isCompleted); XCTAssertEqual(done.completedAt, clock)
        clock = clock.addingTimeInterval(60)
        let reopened = try await repo.reopen(taskID: task.id, actorUserID: task.receiverUserID)
        XCTAssertFalse(reopened.isCompleted); XCTAssertNil(reopened.completedAt)
        XCTAssertEqual(reopened.updatedAt, clock)
        XCTAssertEqual(reopened.title, task.title); XCTAssertEqual(reopened.senderUserID, task.senderUserID)
        XCTAssertEqual(reopened.receiverUserID, task.receiverUserID); XCTAssertEqual(reopened.date, task.date)
        XCTAssertEqual(reopened.deadlineDate, task.deadlineDate)
        let senderView = try await repo.sentTasks(for: task.senderUserID)
        XCTAssertEqual(senderView, [reopened])
    }

    @MainActor func testSenderAndUnrelatedUsersCannotChangeCompletion() async throws {
        let repo = MockSharedTaskRepository()
        let task = try await sent(repo)
        for actor in [task.senderUserID, UUID()] {
            do { _ = try await repo.complete(taskID: task.id, actorUserID: actor); XCTFail("forbidden completion") }
            catch { XCTAssertEqual(error as? SharedTaskError, .forbidden) }
            do { _ = try await repo.reopen(taskID: task.id, actorUserID: actor); XCTFail("forbidden reopen") }
            catch { XCTAssertEqual(error as? SharedTaskError, .forbidden) }
        }
        let unchanged = try await repo.task(id: task.id)
        XCTAssertEqual(unchanged, task)
    }

    @MainActor func testRepeatedCompletionDoesNotDuplicateHistory() async throws {
        let repo = MockSharedTaskRepository()
        let task = try await sent(repo)
        _ = try await repo.reopen(taskID: task.id, actorUserID: task.receiverUserID)
        let done = try await repo.complete(taskID: task.id, actorUserID: task.receiverUserID)
        let retry = try await repo.complete(taskID: task.id, actorUserID: task.receiverUserID)
        XCTAssertEqual(done, retry)
        let history = try await repo.history(taskID: task.id)
        XCTAssertEqual(history.map(\.action), [.created, .sent, .completed])
    }

    @MainActor func testHistoryActorsAndTimestampOrderIncludingClockRollback() async throws {
        var clock = now
        let repo = MockSharedTaskRepository(clock: { clock })
        let task = try await sent(repo)
        clock = now.addingTimeInterval(100)
        _ = try await repo.complete(taskID: task.id, actorUserID: task.receiverUserID)
        clock = now.addingTimeInterval(-100)
        _ = try await repo.reopen(taskID: task.id, actorUserID: task.receiverUserID)
        let history = try await repo.history(taskID: task.id)
        XCTAssertEqual(history.map(\.action), [.created, .sent, .completed, .reopened])
        XCTAssertEqual(history.map(\.actorUserID), [task.senderUserID, task.senderUserID, task.receiverUserID, task.receiverUserID])
        XCTAssertEqual(history.map(\.actorDisplayName), ["sender", "sender", "receiver", "receiver"])
        XCTAssertEqual(history.map(\.timestamp), history.map(\.timestamp).sorted())
        XCTAssertEqual(Set(history.map(\.id)).count, 4)
    }

    @MainActor func testFriendDeletionDoesNotDeleteTaskHistory() async throws {
        let friends = MockFriendRepository()
        let sender = try await friends.currentProfile()
        let friend = try await friends.addFriend(code: FriendCode("B3821K7M"))
        let repo = MockSharedTaskRepository()
        let task = try await repo.sendTask(SharedTaskDraft(title: "keep", date: now), sender: sender, receiver: friend.user)
        let before = try await repo.history(taskID: task.id)
        try await friends.removeFriend(id: friend.id)
        _ = try await friends.updateDisplayName("new name")
        let after = try await repo.history(taskID: task.id)
        let saved = try await repo.task(id: task.id)
        XCTAssertEqual(after, before); XCTAssertEqual(saved.senderDisplayName, sender.displayName)
        _ = try await repo.complete(taskID: task.id, actorUserID: friend.user.id)
    }

    @MainActor func testUnknownTaskOperationsFail() async {
        let repo = MockSharedTaskRepository()
        do { _ = try await repo.task(id: UUID()); XCTFail("unknown") }
        catch { XCTAssertEqual(error as? SharedTaskError, .notFound) }
        do { _ = try await repo.history(taskID: UUID()); XCTFail("unknown") }
        catch { XCTAssertEqual(error as? SharedTaskError, .notFound) }
        do { _ = try await repo.complete(taskID: UUID(), actorUserID: UUID()); XCTFail("unknown") }
        catch { XCTAssertEqual(error as? SharedTaskError, .notFound) }
    }

    @MainActor func testMockSeedsAreReceivedOnlyAndResetWithNewRepository() async throws {
        let friends = MockFriendRepository()
        let profile = try await friends.currentProfile()
        let repo = MockSharedTaskRepository(seedReceivedFor: profile, sampleSenders: friends.mockUsers)
        let incoming = try await repo.receivedTasks(for: profile.id)
        let outgoing = try await repo.sentTasks(for: profile.id)
        XCTAssertEqual(incoming.count, 2); XCTAssertTrue(outgoing.isEmpty)
        XCTAssertTrue(incoming.allSatisfy { $0.sourceTodoID == nil && $0.roomID == nil && !$0.isCompleted })
        let empty = MockSharedTaskRepository()
        let reset = try await empty.receivedTasks(for: profile.id)
        XCTAssertTrue(reset.isEmpty)
    }

    @MainActor func testBadgeDecreasesOnCompleteAndIncreasesOnReopen() async throws {
        let friends = MockFriendRepository()
        let profile = try await friends.currentProfile()
        let repo = MockSharedTaskRepository(seedReceivedFor: profile, sampleSenders: friends.mockUsers)
        let model = SharedTasksViewModel(friends: friends, tasks: repo)
        await model.load()
        XCTAssertEqual(model.receivedIncompleteCount, 2)
        let task = try XCTUnwrap(model.received.first)
        await model.toggle(task)
        XCTAssertEqual(model.receivedIncompleteCount, 1)
        XCTAssertTrue(model.received.last?.isCompleted == true)
        await model.toggle(try XCTUnwrap(model.received.last))
        XCTAssertEqual(model.receivedIncompleteCount, 2)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor func testRecipientsAreFriendsOnlyAndRemovedFriendCannotReceive() async throws {
        let friends = MockFriendRepository()
        let repo = MockSharedTaskRepository()
        let model = SharedTasksViewModel(friends: friends, tasks: repo)
        await model.load()
        XCTAssertTrue(model.recipients.isEmpty)
        let friend = try await friends.addFriend(code: FriendCode("B3821K7M"))
        await model.load()
        XCTAssertEqual(model.recipients.map(\.user.id), [friend.user.id])
        let draft = SharedTaskDraft(title: "task", date: now)
        let unrelated = await model.send(draft, receiverID: UUID())
        XCTAssertFalse(unrelated)
        let sent = await model.send(draft, receiverID: friend.user.id)
        XCTAssertTrue(sent); XCTAssertEqual(model.sent.count, 1)
        try await friends.removeFriend(id: friend.id)
        let blocked = await model.send(SharedTaskDraft(title: "new", date: now), receiverID: friend.user.id)
        XCTAssertFalse(blocked); XCTAssertEqual(model.errorMessage, SharedTaskError.notFriend.localizedDescription)
        XCTAssertEqual(model.sent.count, 1)
    }

    @MainActor func testViewModelSentStateReflectsReceiverChangesAfterReload() async throws {
        let friends = MockFriendRepository()
        let friend = try await friends.addFriend(code: FriendCode("B3821K7M"))
        let repo = MockSharedTaskRepository()
        let model = SharedTasksViewModel(friends: friends, tasks: repo)
        let success = await model.send(SharedTaskDraft(title: "task", date: now), receiverID: friend.user.id)
        XCTAssertTrue(success)
        let task = try XCTUnwrap(model.sent.first)
        let receiverTasks = try await repo.receivedTasks(for: friend.user.id)
        XCTAssertEqual(receiverTasks, [task])
        _ = try await repo.complete(taskID: task.id, actorUserID: friend.user.id)
        await model.load()
        XCTAssertTrue(model.sent.first?.isCompleted == true)
        _ = try await repo.reopen(taskID: task.id, actorUserID: friend.user.id)
        await model.load()
        XCTAssertFalse(model.sent.first?.isCompleted == true)
    }

    @MainActor func testTodayPriorityAndStableCompletionSectionsAndDDay() async throws {
        let friends = MockFriendRepository()
        let profile = try await friends.currentProfile()
        let sender = try user("s", "B3821K7M")
        let repo = MockSharedTaskRepository()
        let yesterday = try await repo.sendTask(SharedTaskDraft(title: "past", date: now.addingTimeInterval(-86400)), sender: sender, receiver: profile)
        let today = try await repo.sendTask(SharedTaskDraft(title: "today", date: now, deadlineDate: now), sender: sender, receiver: profile)
        _ = try await repo.sendTask(SharedTaskDraft(title: "future", date: now.addingTimeInterval(86400)), sender: sender, receiver: profile)
        let model = SharedTasksViewModel(friends: friends, tasks: repo, clock: { self.now })
        await model.load()
        XCTAssertEqual(model.received.map(\.title), ["today", "past", "future"])
        XCTAssertEqual(model.dDay(today), "D-DAY")
        XCTAssertNil(model.dDay(yesterday))
        await model.toggle(today)
        XCTAssertEqual(model.received.last?.id, today.id)
    }
    @MainActor func testFriendNewTaskUsesSameSendRouteWithoutSourceOrRoom() async throws {
        let friends = MockFriendRepository()
        let receiver = try await friends.addFriend(code: FriendCode("C1057P2Q"))
        let repo = MockSharedTaskRepository()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let model = SharedTasksViewModel(friends: friends, tasks: repo, clock: { self.now }, calendar: calendar)
        let id = UUID(), deadline = now.addingTimeInterval(100000)
        let success = await model.sendNewTask(title: "  새 업무  ", deadline: deadline,
                                             receiverID: receiver.user.id, requestID: id)
        XCTAssertTrue(success)
        let sent = try XCTUnwrap(model.sent.first)
        XCTAssertEqual(sent.id, id); XCTAssertEqual(sent.title, "새 업무")
        XCTAssertEqual(sent.receiverUserID, receiver.user.id)
        XCTAssertNil(sent.sourceTodoID); XCTAssertNil(sent.roomID); XCTAssertNil(sent.roomGroupID)
        XCTAssertEqual(sent.date, calendar.startOfDay(for: now))
        XCTAssertEqual(sent.deadlineDate, calendar.startOfDay(for: deadline))
        let stored = try await repo.task(id: id)
        XCTAssertEqual(stored, sent)
        let history = try await repo.history(taskID: id)
        XCTAssertEqual(history.map(\.action), [.created, .sent])
        let repeated = await model.sendNewTask(title: "새 업무", deadline: deadline,
                                              receiverID: receiver.user.id, requestID: id)
        XCTAssertTrue(repeated); XCTAssertEqual(model.sent.count, 1)
    }

    @MainActor func testFriendNewTaskRequiresTitleAndCurrentFriend() async throws {
        let friends = MockFriendRepository()
        let receiver = try await friends.addFriend(code: FriendCode("B3821K7M"))
        let model = SharedTasksViewModel(friends: friends, tasks: MockSharedTaskRepository())
        let empty = await model.sendNewTask(title: "   ", deadline: nil, receiverID: receiver.user.id, requestID: UUID())
        XCTAssertFalse(empty); XCTAssertTrue(model.sent.isEmpty)
        try await friends.removeFriend(id: receiver.id)
        let removed = await model.sendNewTask(title: "task", deadline: nil, receiverID: receiver.user.id, requestID: UUID())
        XCTAssertFalse(removed); XCTAssertTrue(model.sent.isEmpty)
        XCTAssertEqual(model.errorMessage, SharedTaskError.notFriend.localizedDescription)
    }

    @MainActor func testSelectedDateIncludesDirectAndRoomReceivedTasksOnly() async throws {
        let env = MockCollaborationEnvironment(seedReceivedTasks: false)
        let profile = try await env.friends.currentProfile()
        let friend = try await env.friends.addFriend(code: FriendCode("B3821K7M"))
        let room = try await env.rooms.createRoom(name: "양말", creator: profile, invitedUserIDs: [friend.user.id])
        let day = Calendar.current.startOfDay(for: now)
        let direct = try await env.tasks.sendTask(SharedTaskDraft(title: "direct", date: day), sender: friend.user, receiver: profile)
        let roomTask = try await env.tasks.sendRoomTask(SharedTaskDraft(title: "room", date: day), roomID: room.id,
            groupID: nil, sender: friend.user, receiver: profile)
        _ = try await env.tasks.sendTask(SharedTaskDraft(title: "other day", date: day.addingTimeInterval(172800)), sender: friend.user, receiver: profile)
        let workspace = CollaborationWorkspace(environment: env)
        await workspace.sharedTasks.load()
        let filtered = workspace.sharedTasks.received(on: day, calendar: .current)
        XCTAssertEqual(Set(filtered.map(\.id)), Set([direct.id, roomTask.id]))
        XCTAssertTrue(filtered.allSatisfy { $0.senderDisplayName == "김대리" })
        XCTAssertEqual(workspace.sharedTasks.roomNames[room.id], "양말")
        XCTAssertEqual(workspace.sharedTasks.receivedIncompleteCount, 3)
    }

    @MainActor func testReceivedDateFilterUsesCalendarDSTAndExclusiveEnd() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        let interval = TodoDates.interval(for: date, calendar: calendar)
        XCTAssertEqual(interval.duration, 23 * 3600)
        let env = MockCollaborationEnvironment(seedReceivedTasks: false)
        let profile = try await env.friends.currentProfile(), sender = env.friends.mockUsers[0]
        let inside = try await env.tasks.sendTask(SharedTaskDraft(title: "inside", date: interval.end.addingTimeInterval(-1)), sender: sender, receiver: profile)
        _ = try await env.tasks.sendTask(SharedTaskDraft(title: "before", date: interval.start.addingTimeInterval(-1)), sender: sender, receiver: profile)
        _ = try await env.tasks.sendTask(SharedTaskDraft(title: "next", date: interval.end), sender: sender, receiver: profile)
        let model = CollaborationWorkspace(environment: env).sharedTasks
        await model.load()
        XCTAssertEqual(model.received(on: date, calendar: calendar).map(\.id), [inside.id])
    }

    @MainActor func testMiniAndFullHostsShareWorkspaceAndCompletionWithoutReload() async throws {
        let env = MockCollaborationEnvironment()
        let workspace = CollaborationWorkspace(environment: env)
        let repo = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true))
        let store = TodoWorkspaceStore(makeRepository: { repo }, collaboration: workspace)
        let full = WorkWindowController(openTranslator: {}, openSettings: {}, todoStore: store)
        let mini = MiniTodoWindowController(todoStore: store)
        defer { full.window?.close(); mini.window?.close() }
        XCTAssertTrue(full.sharedTodoStore.collaboration.sharedTasks === mini.todoStore.collaboration.sharedTasks)
        await workspace.sharedTasks.load()
        let task = try XCTUnwrap(workspace.sharedTasks.received.first)
        await mini.todoStore.collaboration.sharedTasks.toggle(task)
        XCTAssertTrue(full.sharedTodoStore.collaboration.sharedTasks.received.first { $0.id == task.id }?.isCompleted == true)
        XCTAssertEqual(workspace.sharedTasks.receivedIncompleteCount, 1)
        await full.sharedTodoStore.collaboration.sharedTasks.toggle(task)
        XCTAssertFalse(mini.todoStore.collaboration.sharedTasks.received.first { $0.id == task.id }?.isCompleted == true)
        XCTAssertEqual(workspace.sharedTasks.receivedIncompleteCount, 2)
    }

    @MainActor func testInboxCompletionImmediatelyUpdatesLoadedRoom() async throws {
        let env = MockCollaborationEnvironment(seedReceivedTasks: false)
        let profile = try await env.friends.currentProfile()
        let friend = try await env.friends.addFriend(code: FriendCode("B3821K7M"))
        let room = try await env.rooms.createRoom(name: "room", creator: profile, invitedUserIDs: [friend.user.id])
        let task = try await env.tasks.sendRoomTask(SharedTaskDraft(title: "incoming", date: Date()), roomID: room.id,
            groupID: nil, sender: friend.user, receiver: profile)
        let workspace = CollaborationWorkspace(environment: env)
        await workspace.rooms.loadRoom(room.id)
        await workspace.sharedTasks.load()
        await workspace.sharedTasks.toggle(task)
        XCTAssertTrue(workspace.rooms.tasks.first?.isCompleted == true)
        await workspace.sharedTasks.toggle(task)
        XCTAssertFalse(workspace.rooms.tasks.first?.isCompleted == true)
        let history = try await workspace.sharedTasks.history(for: task)
        XCTAssertEqual(history.map(\.action), [.created, .sent, .completed, .reopened])
    }

    @MainActor func testMiniCombinesPersonalAndReceivedWithIncompleteFirst() async throws {
        let env = MockCollaborationEnvironment(seedReceivedTasks: false)
        let profile = try await env.friends.currentProfile(), sender = env.friends.mockUsers[0]
        let repo = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true))
        let personal = try repo.create(TodoDraft(title: "personal", date: Date()), calendar: .current)
        let donePersonal = try repo.create(TodoDraft(title: "done personal", date: Date()), calendar: .current)
        try repo.complete(todoID: donePersonal.id)
        let incoming = try await env.tasks.sendTask(SharedTaskDraft(title: "incoming", date: Date()), sender: sender, receiver: profile)
        let doneIncoming = try await env.tasks.sendTask(SharedTaskDraft(title: "done received", date: Date()), sender: sender, receiver: profile)
        _ = try await env.tasks.complete(taskID: doneIncoming.id, actorUserID: profile.id)
        let personalModel = try TodoViewModel(repository: repo)
        let shared = CollaborationWorkspace(environment: env).sharedTasks
        await shared.load()
        let today = shared.received(on: personalModel.todayDate, calendar: personalModel.calendar)
        let rows = TodayListItem.combined(personal: personalModel.todayItems, received: today)
        XCTAssertEqual(rows.map(\.isCompleted), [false, false, true, true])
        XCTAssertEqual(rows.map(\.id), [.personal(personal.id), .received(incoming.id), .personal(donePersonal.id), .received(doneIncoming.id)])
        XCTAssertEqual(try repo.allTodos().count, 2)
    }

    @MainActor func testMiniInputStillCreatesOnlyPersonalTodoAndSeedIsToday() async throws {
        let env = MockCollaborationEnvironment()
        let workspace = CollaborationWorkspace(environment: env)
        let repo = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true))
        let personal = try TodoViewModel(repository: repo)
        await workspace.sharedTasks.load()
        let ids = workspace.sharedTasks.received.map(\.id)
        XCTAssertEqual(workspace.sharedTasks.received(on: personal.todayDate, calendar: personal.calendar).count, 2)
        personal.quickTitle = "quick entry"
        XCTAssertTrue(personal.submitTodayQuickEntry())
        XCTAssertEqual(try repo.allTodos().map(\.title), ["quick entry"])
        await workspace.sharedTasks.load()
        XCTAssertEqual(workspace.sharedTasks.received.map(\.id), ids)
        XCTAssertTrue(workspace.sharedTasks.sent.isEmpty)
    }

    @MainActor func testMiniTabRoundTripAndNewPresentationReset() {
        let navigation = MiniTodoNavigation()
        XCTAssertEqual(navigation.page, .today)
        navigation.toggle(); XCTAssertEqual(navigation.page, .sent)
        navigation.toggle(); XCTAssertEqual(navigation.page, .today)
        navigation.toggle(); navigation.reset(); XCTAssertEqual(navigation.page, .today)
    }

    @MainActor func testMiniTabPreservesCompositionAndModifiedKeys() throws {
        func event(_ flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false, code: UInt16 = 48) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: "\t",
                charactersIgnoringModifiers: "\t", isARepeat: repeatKey, keyCode: code))
        }
        XCTAssertTrue(MiniTodoNavigation.handlesTab(try event(), composing: false))
        XCTAssertFalse(MiniTodoNavigation.handlesTab(try event(), composing: true))
        for flags: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
            XCTAssertFalse(MiniTodoNavigation.handlesTab(try event(flags), composing: false))
        }
        XCTAssertFalse(MiniTodoNavigation.handlesTab(try event(repeatKey: true), composing: false))
        XCTAssertFalse(MiniTodoNavigation.handlesTab(try event(code: 36), composing: false))
    }

    @MainActor func testSharedRowPresentationMapsDirectionPersonAndDeadline() async throws {
        let repo = MockSharedTaskRepository()
        let task = try await sent(repo)
        let received = TodoRowPresentation.shared(task, received: true, deadlineText: "D-2")
        XCTAssertEqual(received.direction.arrow, "←")
        XCTAssertEqual(received.personName, task.senderDisplayName)
        XCTAssertEqual(received.personLabel, "← sender")
        XCTAssertEqual(received.deadlineText, "D-2")
        XCTAssertTrue(received.isInteractive)
        let sent = TodoRowPresentation.shared(task, received: false, deadlineText: nil)
        XCTAssertEqual(sent.direction.arrow, "→")
        XCTAssertEqual(sent.personName, task.receiverDisplayName)
        XCTAssertEqual(sent.personLabel, "→ receiver")
        XCTAssertNil(sent.deadlineText)
        XCTAssertFalse(sent.isInteractive)
        let completed = try await repo.complete(taskID: task.id, actorUserID: task.receiverUserID)
        XCTAssertTrue(TodoRowPresentation.shared(completed, received: false, deadlineText: nil).isCompleted)
    }

    @MainActor func testPersonalPresentationHasNoDirectionAndRetainsDeadline() throws {
        let repo = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true))
        let todo = try repo.create(TodoDraft(title: "personal", date: now), calendar: .current)
        let row = TodoRowPresentation.personal(todo, deadlineText: "D-DAY")
        XCTAssertEqual(row.title, todo.title)
        XCTAssertNil(row.direction.arrow); XCTAssertNil(row.personLabel); XCTAssertNil(row.personName)
        XCTAssertEqual(row.deadlineText, "D-DAY"); XCTAssertTrue(row.isInteractive)
    }

    @MainActor func testMiniSentDateAndTodayPersonalReceivedRemainSeparate() async throws {
        let env = MockCollaborationEnvironment(seedReceivedTasks: false)
        let profile = try await env.friends.currentProfile(), other = env.friends.mockUsers[0]
        let day = Calendar.current.startOfDay(for: now)
        let outgoing = try await env.tasks.sendTask(SharedTaskDraft(title: "sent today", date: day), sender: profile, receiver: other)
        _ = try await env.tasks.sendTask(SharedTaskDraft(title: "sent tomorrow", date: Calendar.current.date(byAdding: .day, value: 1, to: day)!), sender: profile, receiver: other)
        let incoming = try await env.tasks.sendTask(SharedTaskDraft(title: "received", date: day), sender: other, receiver: profile)
        let shared = CollaborationWorkspace(environment: env).sharedTasks
        await shared.load()
        XCTAssertEqual(shared.sent(on: day, calendar: .current).map(\.id), [outgoing.id])
        let repo = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true))
        let personal = try repo.create(TodoDraft(title: "personal", date: day), calendar: .current)
        let todayRows = TodayListItem.combined(personal: [personal], received: shared.received(on: day, calendar: .current))
        XCTAssertEqual(todayRows.map(\.id), [.personal(personal.id), .received(incoming.id)])
        await shared.toggle(outgoing)
        XCTAssertNotNil(shared.errorMessage)
        let stored = try await env.tasks.task(id: outgoing.id)
        XCTAssertFalse(stored.isCompleted)
        _ = try await env.tasks.complete(taskID: outgoing.id, actorUserID: other.id)
        await shared.load()
        XCTAssertTrue(shared.sent(on: day, calendar: .current).first?.isCompleted == true)
    }

    @MainActor func testAssignedIncludesSelfAndReceivedRoomsDeduplicatesAndExcludesOthers() async throws {
        let env = MockCollaborationEnvironment(seedReceivedTasks: false)
        let me = try await env.friends.currentProfile()
        let friend = try await env.friends.addFriend(code: FriendCode("B3821K7M"))
        let room = try await env.rooms.createRoom(name: "양말", creator: me, invitedUserIDs: [friend.user.id])
        let direct = try await env.tasks.sendTask(SharedTaskDraft(title: "direct", date: now), sender: friend.user, receiver: me)
        let own = try await env.tasks.sendRoomTask(SharedTaskDraft(title: "self", date: now), roomID: room.id, groupID: nil, sender: me, receiver: me)
        let incoming = try await env.tasks.sendRoomTask(SharedTaskDraft(title: "incoming", date: now), roomID: room.id, groupID: nil, sender: friend.user, receiver: me)
        _ = try await env.tasks.sendRoomTask(SharedTaskDraft(title: "other", date: now), roomID: room.id, groupID: nil, sender: me, receiver: friend.user)
        let model = CollaborationWorkspace(environment: env).sharedTasks
        await model.load()
        XCTAssertEqual(Set(model.assigned.map(\.id)), Set([direct.id, own.id, incoming.id]))
        XCTAssertEqual(model.assigned.count, 3)
        XCTAssertEqual(model.roomNames[room.id], "양말")
        XCTAssertEqual(Set(model.assigned(on: now, calendar: .current).map(\.id)), Set([direct.id, own.id, incoming.id]))
        XCTAssertTrue(model.assigned(on: now.addingTimeInterval(86400), calendar: .current).isEmpty)
        let rows = TodayListItem.combined(personal: [], received: model.assigned(on: now, calendar: .current))
        XCTAssertEqual(rows.count, 3)
        XCTAssertNil(TodoRowPresentation.shared(own, received: true, deadlineText: nil).personLabel)
        XCTAssertEqual(TodoRowPresentation.shared(incoming, received: true, deadlineText: nil).direction, .received)
        XCTAssertEqual(model.received.count, 2)
        XCTAssertEqual(model.sent.count, 1)
    }

    @MainActor func testOverdueDatesIncludeAllOwnSourcesExcludeCompletedTodayFutureAndSent() async throws {
        let env = MockCollaborationEnvironment(seedReceivedTasks: false)
        let me = try await env.friends.currentProfile()
        let friend = try await env.friends.addFriend(code: FriendCode("B3821K7M"))
        let room = try await env.rooms.createRoom(name: "room", creator: me, invitedUserIDs: [friend.user.id])
        let calendar = Calendar.current, today = Calendar.current.startOfDay(for: now)
        func day(_ value: Int) -> Date { calendar.date(byAdding: .day, value: value, to: today)! }
        _ = try await env.tasks.sendTask(SharedTaskDraft(title: "past direct", date: day(-1)), sender: friend.user, receiver: me)
        _ = try await env.tasks.sendRoomTask(SharedTaskDraft(title: "past received", date: day(-2)), roomID: room.id, groupID: nil, sender: friend.user, receiver: me)
        _ = try await env.tasks.sendRoomTask(SharedTaskDraft(title: "past self", date: day(-3)), roomID: room.id, groupID: nil, sender: me, receiver: me)
        _ = try await env.tasks.sendRoomTask(SharedTaskDraft(title: "other", date: day(-4)), roomID: room.id, groupID: nil, sender: me, receiver: friend.user)
        _ = try await env.tasks.sendTask(SharedTaskDraft(title: "sent", date: day(-5)), sender: me, receiver: friend.user)
        let done = try await env.tasks.sendTask(SharedTaskDraft(title: "done", date: day(-6)), sender: friend.user, receiver: me)
        _ = try await env.tasks.complete(taskID: done.id, actorUserID: me.id)
        _ = try await env.tasks.sendTask(SharedTaskDraft(title: "today", date: day(0)), sender: friend.user, receiver: me)
        _ = try await env.tasks.sendTask(SharedTaskDraft(title: "future", date: day(1)), sender: friend.user, receiver: me)
        let repo = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true))
        _ = try repo.create(TodoDraft(title: "personal past", date: day(-7)), calendar: calendar)
        let completed = try repo.create(TodoDraft(title: "done personal", date: day(-8)), calendar: calendar)
        try repo.complete(todoID: completed.id)
        _ = try repo.create(TodoDraft(title: "personal today", date: today), calendar: calendar)
        let personal = try TodoViewModel(repository: repo, calendar: calendar, clock: { self.now })
        let shared = CollaborationWorkspace(environment: env).sharedTasks
        await shared.load()
        let result = MyTaskPresentation.overdueDays(personal: personal.overdueDays, assigned: shared.assigned, today: today, calendar: calendar)
        XCTAssertEqual(result, Set([-1, -2, -3, -7].map(day)))
    }

    @MainActor func testLastIncompleteRoomCompletionRemovesDotAndReopenRestoresAcrossHosts() async throws {
        let env = MockCollaborationEnvironment(seedReceivedTasks: false)
        let me = try await env.friends.currentProfile()
        let room = try await env.rooms.createRoom(name: "room", creator: me, invitedUserIDs: [])
        let past = Calendar.current.startOfDay(for: now).addingTimeInterval(-86400)
        let first = try await env.tasks.sendRoomTask(SharedTaskDraft(title: "one", date: past), roomID: room.id, groupID: nil, sender: me, receiver: me)
        let second = try await env.tasks.sendRoomTask(SharedTaskDraft(title: "two", date: past), roomID: room.id, groupID: nil, sender: me, receiver: me)
        let workspace = CollaborationWorkspace(environment: env)
        await workspace.rooms.loadRoom(room.id); await workspace.sharedTasks.load()
        func days() -> Set<Date> { MyTaskPresentation.overdueDays(personal: [], assigned: workspace.sharedTasks.assigned, today: now, calendar: .current) }
        XCTAssertEqual(days(), [past])
        await workspace.sharedTasks.toggle(first)
        XCTAssertEqual(days(), [past])
        XCTAssertTrue(workspace.rooms.tasks.first { $0.id == first.id }?.isCompleted == true)
        await workspace.sharedTasks.toggle(second)
        XCTAssertTrue(days().isEmpty)
        await workspace.rooms.toggle(second)
        XCTAssertEqual(days(), [past])
        XCTAssertFalse(workspace.sharedTasks.assigned.first { $0.id == second.id }?.isCompleted == true)
    }

    @MainActor func testRoomInlineSelfTaskImmediatelyAppearsInMiniProjection() async throws {
        let env = MockCollaborationEnvironment(seedReceivedTasks: false)
        let me = try await env.friends.currentProfile()
        let room = try await env.rooms.createRoom(name: "room", creator: me, invitedUserIDs: [])
        let workspace = CollaborationWorkspace(environment: env)
        await workspace.rooms.loadRoom(room.id)
        let created = await workspace.rooms.addTask(title: "self", groupID: nil, receiverID: me.id, requestID: UUID())
        XCTAssertTrue(created)
        let today = workspace.sharedTasks.assigned(on: Date(), calendar: .current)
        XCTAssertEqual(today.map(\.title), ["self"])
        XCTAssertTrue(workspace.sharedTasks.sent.isEmpty)
        let navigation = MiniTodoNavigation(); navigation.toggle()
        XCTAssertEqual(navigation.page, .sent)
    }

    @MainActor func testMissedThreeCalendarDaysAllSourcesAndNoDuplicates() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12))!
        let start = calendar.startOfDay(for: today)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: start)! }
        let env = MockCollaborationEnvironment(seedReceivedTasks: false)
        let me = try await env.friends.currentProfile()
        let friend = try await env.friends.addFriend(code: FriendCode("B3821K7M"))
        let room = try await env.rooms.createRoom(name: "room", creator: me, invitedUserIDs: [friend.user.id])
        let repo = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true))
        for offset in [-4, -3, -2, -1, 0, 1] {
            _ = try repo.create(TodoDraft(title: "personal", date: day(offset)), calendar: calendar)
        }
        let done = try repo.create(TodoDraft(title: "done", date: day(-1)), calendar: calendar)
        try repo.complete(todoID: done.id)
        let direct = try await env.tasks.sendTask(SharedTaskDraft(title: "direct", date: day(-1)), sender: friend.user, receiver: me)
        let selfTask = try await env.tasks.sendRoomTask(SharedTaskDraft(title: "self", date: day(-2)), roomID: room.id, groupID: nil, sender: me, receiver: me)
        let received = try await env.tasks.sendRoomTask(SharedTaskDraft(title: "received", date: day(-3)), roomID: room.id, groupID: nil, sender: friend.user, receiver: me)
        let sent = try await env.tasks.sendTask(SharedTaskDraft(title: "sent", date: day(-1)), sender: me, receiver: friend.user)
        let other = try await env.tasks.sendRoomTask(SharedTaskDraft(title: "other", date: day(-1)), roomID: room.id, groupID: nil, sender: me, receiver: friend.user)
        let finished = try await env.tasks.sendTask(SharedTaskDraft(title: "done shared", date: day(-1)), sender: friend.user, receiver: me)
        _ = try await env.tasks.complete(taskID: finished.id, actorUserID: me.id)
        let shared = CollaborationWorkspace(environment: env).sharedTasks
        await shared.load()
        let sections = MissedTodoPresentation.sections(personal: try repo.allTodos(), assigned: shared.assigned + shared.assigned,
            today: today, selectedDate: today, calendar: calendar)
        XCTAssertEqual(sections.map(\.date), [-1, -2, -3].map(day))
        XCTAssertEqual(sections.map(\.count), [2, 2, 2])
        XCTAssertEqual(Set(sections.flatMap(\.shared).map(\.id)), Set([direct.id, selfTask.id, received.id]))
        XCTAssertFalse(sections.flatMap(\.shared).contains { $0.id == sent.id || $0.id == other.id || $0.id == finished.id })
        XCTAssertTrue(MissedTodoPresentation.sections(personal: try repo.allTodos(), assigned: shared.assigned,
            today: today, selectedDate: day(-1), calendar: calendar).isEmpty)
    }

    @MainActor func testMissedCompletionRemovesDateAndReopenRestoresPersonalAndShared() async throws {
        let calendar = Calendar.current, today = Calendar.current.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let repo = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true))
        let todo = try repo.create(TodoDraft(title: "personal", date: yesterday), calendar: calendar)
        let personal = try TodoViewModel(repository: repo, calendar: calendar, clock: { self.now })
        let env = MockCollaborationEnvironment(seedReceivedTasks: false)
        let me = try await env.friends.currentProfile()
        let task = try await env.tasks.sendTask(SharedTaskDraft(title: "received", date: yesterday), sender: env.friends.mockUsers[0], receiver: me)
        let shared = CollaborationWorkspace(environment: env).sharedTasks
        await shared.load()
        func sections() -> [MissedTodoSection] { MissedTodoPresentation.sections(personal: personal.pastIncomplete,
            assigned: shared.assigned, today: today, selectedDate: today, calendar: calendar) }
        XCTAssertEqual(sections().first?.count, 2)
        personal.toggleCompletion(todo)
        XCTAssertEqual(sections().first?.count, 1)
        await shared.toggle(task)
        XCTAssertTrue(sections().isEmpty)
        XCTAssertTrue(MyTaskPresentation.overdueDays(personal: personal.overdueDays, assigned: shared.assigned, today: today, calendar: calendar).isEmpty)
        personal.setCompleted(todo, completed: false)
        await shared.toggle(task)
        XCTAssertEqual(sections().first?.count, 2)
    }

    @MainActor func testMissedDateBoundaryIncludesWholeThirdDayAndExcludesTodayMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10))!
        let third = calendar.date(byAdding: .day, value: -3, to: today)!
        let repo = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true))
        _ = try repo.create(TodoDraft(title: "inside", date: third), calendar: calendar)
        _ = try repo.create(TodoDraft(title: "before", date: third.addingTimeInterval(-1)), calendar: calendar)
        _ = try repo.create(TodoDraft(title: "today", date: today), calendar: calendar)
        let result = MissedTodoPresentation.sections(personal: try repo.allTodos(), assigned: [], today: today,
            selectedDate: today.addingTimeInterval(300), calendar: calendar)
        XCTAssertEqual(result.flatMap(\.personal).map(\.title), ["inside"])
    }

}
