import XCTest
@testable import PIAAR_Translator

@MainActor final class SpaceTests: XCTestCase {
    let a = UUID(), b = UUID(), c = UUID()
    let day = try! TaskDay(value: "2026-10-03")
    private func setup() async throws -> (SpaceMemory, SpaceFake, SpaceFake, Space) {
        let db = SpaceMemory(); db.names[a] = "A"; db.names[b] = "B"; db.names[c] = "C"; db.befriend(a, b)
        let ra = SpaceFake(userID: a, db: db), rb = SpaceFake(userID: b, db: db)
        let space = try await ra.createSpace(id: UUID(), name: " 업무방 "); return (db, ra, rb, space)
    }
    private func scoped(_ repo: SpaceFake, _ space: Space) -> TaskWorkspaceModel {
        TaskWorkspaceModel(repository: repo, groups: repo, now: { self.day.date(calendar: .current) }, actorDisplayName: { repo.db.names[repo.userID] }, friendships: repo, spaceID: space.id, spaces: repo)
    }
    private func directory(_ repo: SpaceFake) -> SpaceDirectoryModel {
        SpaceDirectoryModel(repository: repo, friendships: repo, makeModel: { id in
            TaskWorkspaceModel(repository: repo, groups: repo, actorDisplayName: { "A" }, friendships: repo, spaceID: id, spaces: repo)
        })
    }
    func testSpaceNameTrimAndLimits() throws {
        XCTAssertEqual(try Space.validatedName("  방 \n"), "방"); XCTAssertThrowsError(try Space.validatedName("   "))
        XCTAssertEqual(try Space.validatedName(String(repeating: "가", count: 60)).count, 60)
        XCTAssertThrowsError(try Space.validatedName(String(repeating: "가", count: 61)))
    }
    func testCreatorAutoAccessWithoutMembership() async throws {
        let (db, ra, _, space) = try await setup(); XCTAssertTrue(db.membersRows.isEmpty)
        let spaces = try await ra.spaces(); XCTAssertEqual(spaces, [space]); XCTAssertTrue(space.canAccess(userID: a, members: []))
        let vm = scoped(ra, space); await vm.refresh(); XCTAssertTrue(vm.spaceWritable); XCTAssertEqual(vm.participants.map(\.id), [a])
    }
    func testNonmemberCannotSeeSpaceOrGroupsOrUnrelatedTasks() async throws {
        let (db, ra, rb, space) = try await setup(); _ = try await ra.createSpaceGroup(id: UUID(), spaceID: space.id, name: "g", colorHex: nil, sortOrder: 0)
        _ = try await ra.createSpaceTask(TaskDraft(title: "self", scheduledDate: day), spaceID: space.id, receiverID: a)
        let spaces = try await rb.spaces(), value = try await rb.space(id: space.id); XCTAssertTrue(spaces.isEmpty); XCTAssertNil(value)
        do { _ = try await rb.groups(spaceID: space.id); XCTFail() } catch {}
        let tasks = try await rb.tasks(.space(space.id, from: day, through: day)); XCTAssertTrue(tasks.isEmpty); XCTAssertEqual(db.tasksRows.count, 1)
    }
    func testFriendInviteDuplicateAndReinvitePreservePastRow() async throws {
        let (_, ra, rb, space) = try await setup(); let friend = ra.friend(b)
        let first = try await ra.addMember(id: UUID(), spaceID: space.id, friend: friend)
        let duplicate = try await ra.addMember(id: UUID(), spaceID: space.id, friend: friend); XCTAssertEqual(first.id, duplicate.id)
        try await ra.removeMember(id: first.id, spaceID: space.id)
        let hidden = try await rb.spaces(); XCTAssertTrue(hidden.isEmpty)
        let again = try await ra.addMember(id: UUID(), spaceID: space.id, friend: friend); XCTAssertNotEqual(first.id, again.id)
        XCTAssertEqual(ra.db.membersRows.count, 2); XCTAssertNotNil(ra.db.membersRows[0].removedAt); XCTAssertNil(ra.db.membersRows[1].removedAt)
    }
    func testNonfriendInviteAndNoncreatorManagementDenied() async throws {
        let (_, ra, rb, space) = try await setup()
        do { _ = try await ra.addMember(id: UUID(), spaceID: space.id, friend: ra.friend(c)); XCTFail() } catch {}
        _ = try await ra.addMember(id: UUID(), spaceID: space.id, friend: ra.friend(b))
        do { _ = try await rb.addMember(id: UUID(), spaceID: space.id, friend: rb.friend(c)); XCTFail() } catch {}
        do { try await rb.archiveSpace(id: space.id); XCTFail() } catch {}
    }
    func testCreatorCannotBeInvitedOrRemoved() async throws {
        let (_, ra, _, space) = try await setup()
        do { _ = try await ra.addMember(id: UUID(), spaceID: space.id, friend: ra.friend(a)); XCTFail() } catch {}
        let vm = scoped(ra, space); await vm.refresh()
        let row = SpaceMember(id: UUID(), spaceID: space.id, userID: a, displayNameSnapshot: "A", joinedAt: Date(), removedAt: nil)
        await vm.removeMember(row); XCTAssertEqual(ra.removeCalls, 0)
    }
    func testFriendDeletionDoesNotEndMembershipOrAssignment() async throws {
        let (db, ra, rb, space) = try await setup(); _ = try await ra.addMember(id: UUID(), spaceID: space.id, friend: ra.friend(b)); db.friends = []
        let task = try await rb.createSpaceTask(TaskDraft(title: "member remains", scheduledDate: day), spaceID: space.id, receiverID: a)
        XCTAssertEqual(task.spaceID, space.id); let members = try await ra.members(spaceID: space.id); XCTAssertEqual(members.count, 1)
    }
    func testDirectoryCreateSoloAndSidebar() async throws {
        let (_, ra, _, _) = try await setup(); let vm = directory(ra); vm.beginCreating(); await vm.loadFriends()
        let ok = await vm.create(name: "solo", selected: []); XCTAssertTrue(ok); XCTAssertEqual(vm.created?.name, "solo")
        await vm.refresh(); XCTAssertEqual(vm.spaces.count, 2)
    }
    func testCreatePartialInviteFailureAndRetryOnlyFailed() async throws {
        let (db, ra, _, _) = try await setup(); db.befriend(a, c); ra.failedInvite = c
        let vm = directory(ra); vm.beginCreating(); await vm.loadFriends()
        let first = await vm.create(name: "partial", selected: [b, c]); XCTAssertFalse(first); XCTAssertNotNil(vm.created); XCTAssertEqual(vm.failedInvites.map(\.userID), [c])
        let id = vm.created?.id; XCTAssertEqual(db.spacesRows.count, 2); XCTAssertEqual(db.membersRows.filter { $0.spaceID == id }.count, 1)
        ra.failedInvite = nil; let second = await vm.create(name: "must not rename", selected: []); XCTAssertTrue(second)
        XCTAssertEqual(vm.created?.id, id); XCTAssertEqual(vm.created?.name, "partial"); XCTAssertEqual(ra.inviteCalls[b], 1); XCTAssertEqual(ra.inviteCalls[c], 2)
    }
    func testDirectoryRefreshFailureRetainsList() async throws {
        let (_, ra, _, _) = try await setup(); let vm = directory(ra); await vm.refresh(); let old = vm.spaces
        ra.failRead = true; await vm.refresh(); XCTAssertEqual(vm.spaces, old); XCTAssertNotNil(vm.errorMessage)
    }
    func testSpaceRefreshFailureRetainsTasksAndMembers() async throws {
        let (_, ra, _, space) = try await setup(); let vm = scoped(ra, space); await vm.refresh(); _ = await vm.add(title: "keep"); let old = vm.assigned
        ra.failRead = true; await vm.refresh(); XCTAssertEqual(vm.assigned, old); XCTAssertEqual(vm.currentSpace, space)
    }
    func testActiveMemberCreatesGroupOwnerOrCreatorCanEdit() async throws {
        let (_, ra, rb, space) = try await setup(); _ = try await ra.addMember(id: UUID(), spaceID: space.id, friend: ra.friend(b))
        let group = try await rb.createSpaceGroup(id: UUID(), spaceID: space.id, name: "g", colorHex: "#112233", sortOrder: 0)
        XCTAssertEqual(group.ownerID, b); XCTAssertEqual(group.spaceID, space.id)
        try await ra.renameSpaceGroup(id: group.id, spaceID: space.id, name: "creator edit", colorHex: nil)
        XCTAssertEqual(ra.db.groupsRows[0].name, "creator edit")
        let personal = try await ra.personalGroups(); XCTAssertTrue(personal.isEmpty)
    }
    func testGroupNonOwnerMemberCannotEdit() async throws {
        let (_, ra, rb, space) = try await setup(); _ = try await ra.addMember(id: UUID(), spaceID: space.id, friend: ra.friend(b))
        let group = try await ra.createSpaceGroup(id: UUID(), spaceID: space.id, name: "owner", colorHex: nil, sortOrder: 0)
        let vm = scoped(rb, space); await vm.refresh(); XCTAssertFalse(vm.canManageGroup(group))
        await vm.renameGroup(group, name: "no", color: nil); await vm.deleteGroup(group); XCTAssertEqual(ra.db.groupsRows[0], group)
    }
    func testDeleteGroupPreservesAllTasksAndClearsGroup() async throws {
        let (_, ra, _, space) = try await setup(); let vm = scoped(ra, space); await vm.refresh(); await vm.createGroup(name: "g", color: "#ffffff")
        let group = vm.groups[0]; _ = await vm.add(groupID: group.id, title: "x"); await vm.deleteGroup(group)
        XCTAssertTrue(vm.groups.isEmpty); XCTAssertEqual(vm.assigned.count, 1); XCTAssertNil(vm.assigned[0].groupID)
    }
    func testSelfTaskAndMemberAssignmentUseSameTaskTableAndEvents() async throws {
        let (_, ra, _, space) = try await setup(); _ = try await ra.addMember(id: UUID(), spaceID: space.id, friend: ra.friend(b))
        let vm = scoped(ra, space); await vm.refresh()
        let selfOK = await vm.add(title: "self"), memberOK = await vm.add(title: "member", receiverID: b)
        XCTAssertTrue(selfOK); XCTAssertTrue(memberOK); XCTAssertEqual(vm.assigned.count, 2)
        XCTAssertEqual(Set(ra.db.tasksRows.map(\.assignedTo)), [a, b]); XCTAssertTrue(ra.db.tasksRows.allSatisfy { $0.spaceID == space.id })
        XCTAssertEqual(ra.db.events.map(\.kind), [.created, .created, .assigned]); XCTAssertEqual(ra.db.events.last?.metadata["receiver_display_name"], "B")
    }
    func testNonmemberAndRemovedReceiverCannotBeAssigned() async throws {
        let (_, ra, _, space) = try await setup(); let vm = scoped(ra, space); await vm.refresh()
        let ok = await vm.add(title: "no", receiverID: c); XCTAssertFalse(ok); XCTAssertTrue(ra.db.tasksRows.isEmpty)
        let member = try await ra.addMember(id: UUID(), spaceID: space.id, friend: ra.friend(b)); await vm.refresh(); try await ra.removeMember(id: member.id, spaceID: space.id)
        let staleOK = await vm.add(title: "removed", receiverID: b); XCTAssertFalse(staleOK); XCTAssertTrue(ra.db.tasksRows.isEmpty)
    }
    func testReceiverCompletionAndOthersReadOnlyInSpace() async throws {
        let (_, ra, rb, space) = try await setup(); _ = try await ra.addMember(id: UUID(), spaceID: space.id, friend: ra.friend(b))
        let task = try await ra.createSpaceTask(TaskDraft(title: "to b", scheduledDate: day), spaceID: space.id, receiverID: b)
        let sender = scoped(ra, space), receiver = scoped(rb, space); await sender.refresh(); await receiver.refresh()
        await sender.toggle(task); XCTAssertEqual(ra.db.tasksRows[0].status, .open)
        await receiver.toggle(task); XCTAssertEqual(rb.db.tasksRows[0].status, .completed); XCTAssertEqual(rb.db.events.last?.kind, .completed)
        await receiver.toggle(rb.db.tasksRows[0]); XCTAssertEqual(rb.db.tasksRows[0].status, .open); XCTAssertEqual(rb.db.events.last?.kind, .reopened)
    }
    func testSpaceTaskIntegratedIntoMineReceivedSentAndMiniSameID() async throws {
        let (_, ra, rb, space) = try await setup(); _ = try await ra.addMember(id: UUID(), spaceID: space.id, friend: ra.friend(b))
        let task = try await ra.createSpaceTask(TaskDraft(title: "to b", scheduledDate: day), spaceID: space.id, receiverID: b)
        let mine = TaskWorkspaceModel(repository: rb, groups: rb, now: { self.day.date(calendar: .current) }, spaces: rb)
        let sent = TaskWorkspaceModel(repository: ra, groups: ra, now: { self.day.date(calendar: .current) }, spaces: ra)
        await mine.refresh(); await sent.refresh()
        XCTAssertEqual(mine.assigned.map(\.id), [task.id]); XCTAssertEqual(mine.received.map(\.id), [task.id]); XCTAssertEqual(mine.todayTasks.map(\.id), [task.id]); XCTAssertEqual(sent.sent.map(\.id), [task.id]); XCTAssertEqual(sent.todaySent.map(\.id), [task.id]); XCTAssertEqual(mine.spaceNames[space.id], space.name)
    }
    func testRelationshipLabelsAllDirections() async throws {
        let (_, ra, _, space) = try await setup(); _ = try await ra.addMember(id: UUID(), spaceID: space.id, friend: ra.friend(b))
        let vm = scoped(ra, space); await vm.refresh()
        let task = try await ra.createSpaceTask(TaskDraft(title: "sent", scheduledDate: day), spaceID: space.id, receiverID: b); await vm.refresh(); XCTAssertEqual(vm.relationshipText(task), "→ B")
        var selfRow = task; selfRow = ra.row(TaskDraft(title: "self", scheduledDate: day), receiver: a, spaceID: space.id); XCTAssertNil(vm.relationshipText(selfRow))
    }
    func testArchiveHidesSidebarAndBlocksAllWritesPreservingHistory() async throws {
        let (_, ra, _, space) = try await setup(); let vm = scoped(ra, space); await vm.refresh(); _ = await vm.add(title: "keep"); await vm.createGroup(name: "g", color: "#000000")
        let directory = directory(ra); await directory.refresh(); let task = vm.assigned[0], history = ra.db.events
        let ok = await vm.archiveSpace(); XCTAssertTrue(ok); await directory.refresh(); XCTAssertTrue(directory.spaces.isEmpty)
        let added = await vm.add(title: "blocked"); XCTAssertFalse(added); await vm.toggle(task); await vm.createGroup(name: "no", color: "#ffffff")
        XCTAssertEqual(ra.db.tasksRows.count, 1); XCTAssertEqual(ra.db.tasksRows[0].status, .open); XCTAssertEqual(ra.db.groupsRows.count, 1); XCTAssertEqual(ra.db.events, history)
        let main = TaskWorkspaceModel(repository: ra, groups: ra, now: { self.day.date(calendar: .current) }, spaces: ra); await main.refresh(); XCTAssertEqual(main.permission(for: task), .readOnly)
    }
    func testArchiveBlocksInvitesRemovalsAndGroupChanges() async throws {
        let (_, ra, _, space) = try await setup(); let member = try await ra.addMember(id: UUID(), spaceID: space.id, friend: ra.friend(b))
        let group = try await ra.createSpaceGroup(id: UUID(), spaceID: space.id, name: "g", colorHex: nil, sortOrder: 0); try await ra.archiveSpace(id: space.id)
        do { try await ra.removeMember(id: member.id, spaceID: space.id); XCTFail() } catch {}
        do { try await ra.deleteSpaceGroup(id: group.id, spaceID: space.id); XCTFail() } catch {}
        do { _ = try await ra.addMember(id: UUID(), spaceID: space.id, friend: ra.friend(c)); XCTFail() } catch {}
        XCTAssertNil(ra.db.membersRows[0].removedAt); XCTAssertEqual(ra.db.groupsRows.count, 1)
    }
    func testRemovedUserRefreshClearsScopeDataNotJustSidebar() async throws {
        let (_, ra, rb, space) = try await setup(); let member = try await ra.addMember(id: UUID(), spaceID: space.id, friend: ra.friend(b))
        _ = try await ra.createSpaceTask(TaskDraft(title: "visible", scheduledDate: day), spaceID: space.id, receiverID: a)
        let vm = scoped(rb, space); await vm.refresh(); XCTAssertEqual(vm.assigned.count, 1)
        try await ra.removeMember(id: member.id, spaceID: space.id); await vm.refresh(); XCTAssertTrue(vm.assigned.isEmpty); XCTAssertNil(vm.currentSpace); XCTAssertTrue(vm.spaceMembers.isEmpty)
    }
    func testInvitationListExcludesCurrentMembersAndCreator() async throws {
        let (db, ra, _, space) = try await setup(); db.befriend(a, c); let member = try await ra.addMember(id: UUID(), spaceID: space.id, friend: ra.friend(b))
        let vm = scoped(ra, space); await vm.refresh(); await vm.loadInvitationFriends(); XCTAssertEqual(vm.invitationFriends.map(\.userID), [c])
        await vm.removeMember(member); XCTAssertEqual(Set(vm.invitationFriends.map(\.userID)), [b, c])
    }
    func testAccountInvalidationClearsDirectoryAndCachedScope() async throws {
        let (_, ra, _, space) = try await setup(); let dir = directory(ra); await dir.refresh(); let scope = dir.model(id: space.id); await scope.refresh(); dir.beginCreating(); await dir.loadFriends()
        dir.invalidate(); XCTAssertTrue(dir.spaces.isEmpty); XCTAssertTrue(dir.friends.isEmpty); XCTAssertFalse(dir.creating); XCTAssertNil(scope.currentSpace); XCTAssertTrue(scope.assigned.isEmpty)
        let ok = await scope.add(title: "late"); XCTAssertFalse(ok)
    }
    func testAccountADataIsNotShownInAccountBDirectory() async throws {
        let (_, ra, rb, _) = try await setup(); let first = directory(ra), second = directory(rb); await first.refresh(); first.invalidate(); await second.refresh(); XCTAssertTrue(second.spaces.isEmpty)
    }
    func testSpaceCreateTimeoutRetryReusesSpaceID() async throws {
        let (_, ra, _, _) = try await setup(); let vm = directory(ra); vm.beginCreating(); ra.createTimeout = true
        let first = await vm.create(name: "retry", selected: []); XCTAssertFalse(first); ra.createTimeout = false
        let second = await vm.create(name: "retry", selected: []); XCTAssertTrue(second); XCTAssertEqual(ra.db.spacesRows.filter { $0.name == "retry" }.count, 1)
    }
    func testScopedMutationRefreshesMainModel() async throws {
        let (_, ra, _, space) = try await setup(); let main = TaskWorkspaceModel(repository: ra, groups: ra, now: { self.day.date(calendar: .current) }, spaces: ra)
        let scoped = scoped(ra, space); scoped.onSpaceChange = { await main.refresh() }; await scoped.refresh(); _ = await scoped.add(title: "new")
        XCTAssertEqual(main.todayTasks.map(\.id), scoped.assigned.map(\.id))
    }
    func testSpaceTaskSelfEditAndForeignGroupRejected() async throws {
        let (_, ra, _, space) = try await setup(); let vm = scoped(ra, space); await vm.refresh(); _ = await vm.add(title: "old"); let task = vm.assigned[0]
        let ok = await vm.save(task, draft: TaskDraft(title: "new", scheduledDate: day)); XCTAssertTrue(ok); XCTAssertEqual(vm.assigned[0].title, "new")
        let other = try await ra.createSpace(id: UUID(), name: "other"), wrongGroup = try await ra.createSpaceGroup(id: UUID(), spaceID: other.id, name: "wrong", colorHex: nil, sortOrder: 0)
        let no = await vm.save(vm.assigned[0], draft: TaskDraft(title: "no", scheduledDate: day, groupID: wrongGroup.id)); XCTAssertFalse(no); XCTAssertEqual(ra.db.tasksRows[0].title, "new")
    }
    func testSpaceDisplaysAllDatesNotOnlyToday() async throws {
        let (_, ra, _, space) = try await setup()
        let yesterday = try TaskDay(value: "2026-10-02"), tomorrow = try TaskDay(value: "2026-10-04")
        _ = try await ra.createSpaceTask(TaskDraft(title: "past", scheduledDate: yesterday), spaceID: space.id, receiverID: a)
        _ = try await ra.createSpaceTask(TaskDraft(title: "future", scheduledDate: tomorrow), spaceID: space.id, receiverID: a)
        let vm = scoped(ra, space); await vm.refresh(); XCTAssertEqual(Set(vm.assigned.map(\.title)), ["past", "future"])
    }
    func testDefaultReceiverReturnsToSelfOnNextCreation() async throws {
        let (_, ra, _, space) = try await setup(); _ = try await ra.addMember(id: UUID(), spaceID: space.id, friend: ra.friend(b))
        let vm = scoped(ra, space); await vm.refresh(); XCTAssertEqual(vm.participants.first?.id, a)
        _ = await vm.add(title: "member", receiverID: b); _ = await vm.add(title: "default self")
        XCTAssertEqual(ra.db.tasksRows.map(\.assignedTo), [b, a])
    }
    func testDirectoryConfirmedLossOfAccessClearsCachedScope() async throws {
        let (_, ra, rb, space) = try await setup(); let member = try await ra.addMember(id: UUID(), spaceID: space.id, friend: ra.friend(b))
        let dir = directory(rb); await dir.refresh(); let scope = dir.model(id: space.id); await scope.refresh(); XCTAssertNotNil(scope.currentSpace)
        try await ra.removeMember(id: member.id, spaceID: space.id); await dir.refresh(); XCTAssertNil(scope.currentSpace); XCTAssertTrue(scope.spaceMembers.isEmpty)
    }
    func testInvalidatedDirectoryCannotRecreateActiveScope() async throws {
        let (_, ra, _, space) = try await setup(); let dir = directory(ra); dir.invalidate(); let scope = dir.model(id: space.id)
        await scope.refresh(); let ok = await scope.add(title: "no"); XCTAssertFalse(ok); XCTAssertNil(scope.currentSpace); XCTAssertTrue(ra.db.tasksRows.isEmpty)
    }
    func testSpaceHistoryUsesOriginalActorSnapshots() async throws {
        let (db, ra, rb, space) = try await setup(); _ = try await ra.addMember(id: UUID(), spaceID: space.id, friend: ra.friend(b))
        let sender = scoped(ra, space); await sender.refresh(); _ = await sender.add(title: "send", receiverID: b)
        let receiver = scoped(rb, space); await receiver.refresh(); await receiver.toggle(receiver.assigned[0])
        db.names[a] = "Renamed A"; db.names[b] = "Renamed B"
        let history = try await sender.loadHistory(taskID: sender.assigned[0].id)
        XCTAssertEqual(history.map(\.kind), [.created, .assigned, .completed]); XCTAssertEqual(history.map(\.actorDisplayNameSnapshot), ["A", "A", "B"])
    }
    func testThirdPartyRelationshipAndMemberToMemberAssignment() async throws {
        let (db, ra, rb, space) = try await setup(); db.befriend(a, c)
        _ = try await ra.addMember(id: UUID(), spaceID: space.id, friend: ra.friend(b)); _ = try await ra.addMember(id: UUID(), spaceID: space.id, friend: ra.friend(c))
        let task = try await rb.createSpaceTask(TaskDraft(title: "B to C", scheduledDate: day), spaceID: space.id, receiverID: c)
        let viewer = scoped(ra, space); await viewer.refresh(); XCTAssertEqual(viewer.relationshipText(task), "B → C"); XCTAssertEqual(viewer.permission(for: task), .readOnly)
        let relationship = try await rb.relationship(with: c); XCTAssertEqual(relationship, .available)
    }
    func testDeleteSpaceGroupDoesNotDeleteOtherAssigneesTasks() async throws {
        let (_, ra, _, space) = try await setup(); _ = try await ra.addMember(id: UUID(), spaceID: space.id, friend: ra.friend(b))
        let group = try await ra.createSpaceGroup(id: UUID(), spaceID: space.id, name: "g", colorHex: nil, sortOrder: 0)
        _ = try await ra.createSpaceTask(TaskDraft(title: "self", scheduledDate: day, groupID: group.id), spaceID: space.id, receiverID: a)
        _ = try await ra.createSpaceTask(TaskDraft(title: "other", scheduledDate: day, groupID: group.id), spaceID: space.id, receiverID: b)
        let vm = scoped(ra, space); await vm.refresh(); await vm.deleteGroup(group)
        XCTAssertEqual(vm.assigned.count, 2); XCTAssertTrue(vm.assigned.allSatisfy { $0.groupID == nil })
    }
    func testSpaceRequestRetryKeepsCommandAndSnapshot() async throws {
        let (db, ra, _, space) = try await setup(); let vm = scoped(ra, space); await vm.refresh(); ra.taskTimeout = true
        let first = await vm.add(title: "retry"); XCTAssertFalse(first); XCTAssertEqual(db.tasksRows.count, 1); let id = db.tasksRows[0].id
        db.names[a] = "Renamed"; ra.taskTimeout = false
        let second = await vm.add(title: "retry"); XCTAssertTrue(second); XCTAssertEqual(db.tasksRows.count, 1); XCTAssertEqual(db.tasksRows[0].id, id); XCTAssertEqual(db.events.first?.actorDisplayNameSnapshot, "A")
    }
    func testSpaceAuthFailureClearsAllCachedScopes() async throws {
        let (_, ra, _, space) = try await setup(); var requestedLogin = false
        let dir = SpaceDirectoryModel(repository: ra, friendships: ra, makeModel: { id in self.scoped(ra, space) }, sessionFailure: { _ in requestedLogin = true })
        await dir.refresh(); let scope = dir.model(id: space.id); await scope.refresh(); ra.failAuth = true; await dir.refresh()
        XCTAssertTrue(requestedLogin); XCTAssertTrue(dir.spaces.isEmpty); XCTAssertNil(scope.currentSpace)
    }
    func testRemovedReceiverKeepsTaskCompletionRightOutsideSpace() async throws {
        let (_, ra, rb, space) = try await setup(); let member = try await ra.addMember(id: UUID(), spaceID: space.id, friend: ra.friend(b))
        let task = try await ra.createSpaceTask(TaskDraft(title: "historical assignment", scheduledDate: day), spaceID: space.id, receiverID: b)
        try await ra.removeMember(id: member.id, spaceID: space.id)
        let main = TaskWorkspaceModel(repository: rb, groups: rb, now: { self.day.date(calendar: .current) }, actorDisplayName: { "B" }, spaces: rb)
        await main.refresh(); XCTAssertEqual(main.received.map(\.id), [task.id]); await main.toggle(task)
        XCTAssertEqual(rb.db.tasksRows[0].status, .completed); XCTAssertEqual(rb.db.events.last?.actorID, b)
        let hiddenSpace = try await rb.space(id: space.id); XCTAssertNil(hiddenSpace)
    }
    func testRemovedReceiverStillCannotUpdateArchivedTask() async throws {
        let (_, ra, rb, space) = try await setup(); let member = try await ra.addMember(id: UUID(), spaceID: space.id, friend: ra.friend(b))
        let task = try await ra.createSpaceTask(TaskDraft(title: "archived", scheduledDate: day), spaceID: space.id, receiverID: b)
        try await ra.removeMember(id: member.id, spaceID: space.id); try await ra.archiveSpace(id: space.id)
        let main = TaskWorkspaceModel(repository: rb, groups: rb, now: { self.day.date(calendar: .current) }, spaces: rb)
        await main.refresh(); await main.toggle(task); XCTAssertEqual(rb.db.tasksRows[0].status, .open); XCTAssertTrue(rb.db.events.isEmpty)
    }
    func testScopeNamesAndMembersWireKeys() throws {
        let space = Space(id: UUID(), name: "name", createdBy: a, isArchived: false, createdAt: Date(), updatedAt: Date())
        let member = SpaceMember(id: UUID(), spaceID: space.id, userID: b, displayNameSnapshot: "B", joinedAt: Date(), removedAt: nil)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(member)) as! [String: Any]
        XCTAssertNotNil(encoded["space_id"]); XCTAssertNotNil(encoded["display_name_snapshot"]); XCTAssertNil(encoded["room_id"])
        XCTAssertEqual(try JSONDecoder().decode(Space.self, from: JSONEncoder().encode(space)), space)
    }
}

// An account-scoped, in-memory simulation of the confirmed contract. No SDK client.
@MainActor private final class SpaceMemory {
    var spacesRows: [Space] = [], membersRows: [SpaceMember] = [], groupsRows: [TaskGroup] = [], tasksRows: [WorkTask] = [], events: [TaskEventRequest] = []
    var names: [UUID: String] = [:]
    var friends: Set<String> = []
    func pair(_ a: UUID, _ b: UUID) -> String { [a.uuidString, b.uuidString].sorted().joined(separator: "/") }
    func befriend(_ a: UUID, _ b: UUID) { friends.insert(pair(a, b)) }
}
@MainActor private final class SpaceFake: SpaceRepository, GroupRepository, TaskRepository, FriendshipRepository {
    let userID: UUID, db: SpaceMemory
    var failRead = false, createTimeout = false, taskTimeout = false, failAuth = false
    var failedInvite: UUID?
    var inviteCalls: [UUID: Int] = [:]
    var removeCalls = 0
    init(userID: UUID, db: SpaceMemory) { self.userID = userID; self.db = db }
    func checkRead() throws { if failAuth { throw CollaborationAuthError.sessionMissing }; if failRead { throw URLError(.notConnectedToInternet) } }
    func active(_ space: Space, user: UUID) -> Bool { space.canAccess(userID: user, members: db.membersRows) }
    func writable(_ id: UUID) throws -> Space {
        guard let s = db.spacesRows.first(where: { $0.id == id }), active(s, user: userID) else { throw SpaceError.permission }
        guard !s.isArchived else { throw SpaceError.archived }; return s
    }
    func spaces() async throws -> [Space] { try checkRead(); return db.spacesRows.filter { active($0, user: userID) } }
    func space(id: UUID) async throws -> Space? { try checkRead(); return db.spacesRows.first { $0.id == id && active($0, user: userID) } }
    func createSpace(id: UUID, name: String) async throws -> Space {
        let name = try Space.validatedName(name)
        if let s = db.spacesRows.first(where: { $0.id == id }) { return s }
        let space = Space(id: id, name: name, createdBy: userID, isArchived: false, createdAt: Date(), updatedAt: Date()); db.spacesRows.append(space)
        if createTimeout { throw URLError(.timedOut) }; return space
    }
    func members(spaceID: UUID) async throws -> [SpaceMember] {
        try checkRead(); guard let s = db.spacesRows.first(where: { $0.id == spaceID }), active(s, user: userID) else { throw SpaceError.permission }
        return db.membersRows.filter { $0.spaceID == spaceID && $0.removedAt == nil }
    }
    func friend(_ id: UUID) -> Friend { Friend(friendshipID: UUID(), userID: id, displayName: db.names[id] ?? "Friend", friendCode: try! FriendCode("AB12CD34"), createdAt: Date()) }
    func addMember(id: UUID, spaceID: UUID, friend: Friend) async throws -> SpaceMember {
        inviteCalls[friend.userID, default: 0] += 1
        let s = try writable(spaceID); guard s.createdBy == userID, friend.userID != s.createdBy else { throw SpaceError.permission }
        if let row = db.membersRows.first(where: { $0.spaceID == spaceID && $0.userID == friend.userID && $0.removedAt == nil }) { return row }
        guard db.friends.contains(db.pair(userID, friend.userID)) else { throw SpaceError.notFriend }
        if failedInvite == friend.userID { throw URLError(.notConnectedToInternet) }
        let row = SpaceMember(id: id, spaceID: spaceID, userID: friend.userID, displayNameSnapshot: friend.displayName, joinedAt: Date(), removedAt: nil); db.membersRows.append(row); return row
    }
    func removeMember(id: UUID, spaceID: UUID) async throws {
        removeCalls += 1; let s = try writable(spaceID); guard s.createdBy == userID,
            let index = db.membersRows.firstIndex(where: { $0.id == id && $0.spaceID == spaceID }), db.membersRows[index].userID != s.createdBy else { throw SpaceError.permission }
        let old = db.membersRows[index]; db.membersRows[index] = SpaceMember(id: old.id, spaceID: old.spaceID, userID: old.userID, displayNameSnapshot: old.displayNameSnapshot, joinedAt: old.joinedAt, removedAt: Date())
    }
    func archiveSpace(id: UUID) async throws {
        guard let index = db.spacesRows.firstIndex(where: { $0.id == id }), db.spacesRows[index].createdBy == userID else { throw SpaceError.permission }
        let s = db.spacesRows[index]; db.spacesRows[index] = Space(id: s.id, name: s.name, createdBy: s.createdBy, isArchived: true, createdAt: s.createdAt, updatedAt: Date())
    }
    func personalGroups() async throws -> [TaskGroup] { try checkRead(); return db.groupsRows.filter { $0.ownerID == userID && $0.spaceID == nil } }
    func groups(spaceID: UUID) async throws -> [TaskGroup] { guard try await space(id: spaceID) != nil else { throw SpaceError.permission }; return db.groupsRows.filter { $0.spaceID == spaceID } }
    func fetchGroup(id: UUID) async throws -> TaskGroup? { db.groupsRows.first { $0.id == id } }
    func create(id: UUID, name: String, colorHex: String?, sortOrder: Int) async throws -> TaskGroup {
        let group = TaskGroup(id: id, name: name, colorHex: colorHex, ownerID: userID, spaceID: nil, sortOrder: sortOrder, createdAt: Date(), updatedAt: Date()); db.groupsRows.append(group); return group
    }
    func createSpaceGroup(id: UUID, spaceID: UUID, name: String, colorHex: String?, sortOrder: Int) async throws -> TaskGroup {
        _ = try writable(spaceID)
        if let saved = db.groupsRows.first(where: { $0.id == id }) { return saved }
        let group = TaskGroup(id: id, name: name, colorHex: colorHex, ownerID: userID, spaceID: spaceID, sortOrder: sortOrder, createdAt: Date(), updatedAt: Date()); db.groupsRows.append(group); return group
    }
    func managedGroup(_ id: UUID, _ spaceID: UUID) throws -> Int {
        let space = try writable(spaceID)
        guard let index = db.groupsRows.firstIndex(where: { $0.id == id }), space.canManage(group: db.groupsRows[index], userID: userID) else { throw SpaceError.permission }; return index
    }
    func renameSpaceGroup(id: UUID, spaceID: UUID, name: String, colorHex: String?) async throws { let index = try managedGroup(id, spaceID); db.groupsRows[index].name = name; db.groupsRows[index].colorHex = colorHex }
    func deleteSpaceGroup(id: UUID, spaceID: UUID) async throws {
        let index = try managedGroup(id, spaceID); db.groupsRows.remove(at: index)
        for i in db.tasksRows.indices where db.tasksRows[i].groupID == id { db.tasksRows[i].groupID = nil }
    }
    func rename(id: UUID, name: String, colorHex: String?) async throws { guard let i = db.groupsRows.firstIndex(where: { $0.id == id && $0.ownerID == userID && $0.spaceID == nil }) else { throw SpaceError.permission }; db.groupsRows[i].name = name }
    func delete(id: UUID) async throws { db.groupsRows.removeAll { $0.id == id && $0.ownerID == userID && $0.spaceID == nil } }
    func reorder(ids: [UUID]) async throws {}
    func row(_ d: TaskDraft, receiver: UUID, spaceID: UUID?) -> WorkTask {
        WorkTask(id: d.id, title: d.title, createdBy: userID, assignedTo: receiver, spaceID: spaceID, groupID: d.groupID, scheduledDate: d.scheduledDate, deadlineDate: d.deadlineDate, deadlineAt: d.deadlineAt, startAt: d.startAt, status: d.status, completedAt: d.completedAt, sourceLocalTodoID: d.sourceLocalTodoID, isArchived: false, createdAt: Date(), updatedAt: Date(), notes: d.notes)
    }
    func canRead(_ task: WorkTask) -> Bool {
        if task.createdBy == userID || task.assignedTo == userID { return true }
        return db.spacesRows.contains { $0.id == task.spaceID && active($0, user: userID) }
    }
    func tasks(_ query: TaskQuery) async throws -> [WorkTask] {
        try checkRead(); return db.tasksRows.filter { task in
            guard canRead(task), !task.isArchived, !task.isRecurrenceTemplate else { return false }
            switch query {
            case .assigned(let f, let t): return task.assignedTo == userID && (task.scheduledDate.map { $0 >= f } == true) && (task.scheduledDate.map { $0 <= t } == true)
            case .created(let f, let t): return task.createdBy == userID && (task.scheduledDate.map { $0 >= f } == true) && (task.scheduledDate.map { $0 <= t } == true)
            case .received(let f, let t): return task.assignedTo == userID && task.createdBy != userID && (task.scheduledDate.map { $0 >= f } == true) && (task.scheduledDate.map { $0 <= t } == true)
            case .sent(let f, let t): return task.createdBy == userID && task.assignedTo != userID && (task.scheduledDate.map { $0 >= f } == true) && (task.scheduledDate.map { $0 <= t } == true)
            case .someday: return task.assignedTo == userID && task.scheduledDate == nil
            case .allOverdue(let before): return task.assignedTo == userID && task.status == .open && (task.scheduledDate.map { $0 < before } == true)
            case .allInSpace(let id): return task.spaceID == id
            case .space(let id, let f, let t): return task.spaceID == id && (task.scheduledDate.map { $0 >= f } == true) && (task.scheduledDate.map { $0 <= t } == true)
            case .overdue(let f, let t): return task.assignedTo == userID && task.status == .open && (task.scheduledDate.map { $0 >= f } == true) && (task.scheduledDate.map { $0 < t } == true)
            }
        }
    }
    func createTask(_ d: TaskDraft) async throws -> WorkTask { let row = row(d, receiver: userID, spaceID: nil); db.tasksRows.append(row); return row }
    func createSpaceTask(_ d: TaskDraft, spaceID: UUID, receiverID: UUID) async throws -> WorkTask {
        let space = try writable(spaceID); guard space.canAssign(userID: receiverID, members: db.membersRows) else { throw SpaceError.permission }
        if let id = d.groupID { guard db.groupsRows.contains(where: { $0.id == id && $0.spaceID == spaceID }) else { throw SpaceError.permission } }
        if let saved = db.tasksRows.first(where: { $0.id == d.id }) { return saved }
        let row = row(d, receiver: receiverID, spaceID: spaceID); db.tasksRows.append(row); if taskTimeout { throw URLError(.timedOut) }; return row
    }
    func mutationIndex(_ id: UUID) throws -> Int {
        guard let index = db.tasksRows.firstIndex(where: { $0.id == id }), db.tasksRows[index].assignedTo == userID else { throw TaskServiceError.permission }
        if let id = db.tasksRows[index].spaceID, db.spacesRows.first(where: { $0.id == id })?.isArchived == true { throw SpaceError.archived }; return index
    }
    func updateTask(id: UUID, draft: TaskDraft) async throws -> WorkTask {
        let i = try mutationIndex(id); guard db.tasksRows[i].createdBy == userID else { throw TaskServiceError.permission }
        if let group = draft.groupID { guard db.groupsRows.contains(where: { $0.id == group && $0.spaceID == db.tasksRows[i].spaceID }) else { throw SpaceError.permission } }
        db.tasksRows[i].title = draft.title; db.tasksRows[i].groupID = draft.groupID; return db.tasksRows[i]
    }
    func completeTask(id: UUID) async throws -> WorkTask { let i = try mutationIndex(id); db.tasksRows[i].status = .completed; db.tasksRows[i].completedAt = Date(); return db.tasksRows[i] }
    func reopenTask(id: UUID) async throws -> WorkTask { let i = try mutationIndex(id); db.tasksRows[i].status = .open; db.tasksRows[i].completedAt = nil; return db.tasksRows[i] }
    func archiveTask(id: UUID) async throws { let i = try mutationIndex(id); guard db.tasksRows[i].createdBy == userID else { throw TaskServiceError.permission }; db.tasksRows.remove(at: i) }
    func fetchTask(id: UUID) async throws -> WorkTask? { db.tasksRows.first { $0.id == id && canRead($0) } }
    func importedTask(sourceLocalTodoID: UUID) async throws -> WorkTask? { nil }
    func history(taskID: UUID) async throws -> [TaskHistoryEvent] {
        db.events.filter { $0.taskID == taskID }.map { TaskHistoryEvent(id: $0.id, taskID: $0.taskID, actorID: $0.actorID, actorDisplayNameSnapshot: $0.actorDisplayNameSnapshot ?? "", kind: $0.kind, metadata: $0.metadata, createdAt: Date()) }
    }
    func recordEvent(_ event: TaskEventRequest) async throws { guard event.actorID == userID else { throw TaskServiceError.permission }; if !db.events.contains(where: { $0.id == event.id }) { db.events.append(event) } }
    func receivedIncompleteCount() async throws -> Int { db.tasksRows.filter { $0.assignedTo == userID && $0.createdBy != userID && $0.status == .open }.count }
    func participantNames(ids: Set<UUID>) async throws -> [UUID: String] { db.names.filter { ids.contains($0.key) } }
    func relationship(with user: UUID) async throws -> FriendRelationship { db.friends.contains(db.pair(userID, user)) ? .friend : .available }
    func snapshot() async throws -> FriendshipSnapshot { FriendshipSnapshot(friends: db.names.keys.filter { $0 != userID && db.friends.contains(db.pair(userID, $0)) }.map(friend), incoming: [], outgoing: []) }
    func searchUser(friendCode: FriendCode) async throws -> WorkUserSummary { throw FriendshipError.notFound }
    func sendRequest(to user: UUID) async throws -> FriendRequestDelivery { throw FriendshipError.unavailable }
    func acceptRequest(id: UUID) async throws -> UUID { throw FriendshipError.unavailable }
    func rejectRequest(id: UUID) async throws { throw FriendshipError.unavailable }
    func removeFriend(friendshipID: UUID) async throws {}
}
