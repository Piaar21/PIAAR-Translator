import XCTest
import SwiftData
import Supabase
@testable import PIAAR_Translator

@MainActor final class ServerTaskTests: XCTestCase {
    let user = UUID()
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Seoul")!; return c }
    var date: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 10))! }
    var day: TaskDay { TaskDay(date, calendar: calendar) }
    private func fixture() -> (TaskWorkspaceModel, MemoryTaskRepository, MemoryGroupRepository) {
        let repo = MemoryTaskRepository(userID: user); let groups = MemoryGroupRepository(userID: user)
        return (TaskWorkspaceModel(repository: repo, groups: groups, calendar: calendar, now: { self.date }), repo, groups)
    }
    func snapshot(id: UUID = UUID(), title: String = "기존", repeatRule: String? = nil, notes: String? = nil, isCompleted: Bool = false, completedAt: Date? = nil, groupID: UUID? = nil, on: Date? = nil) -> TodoSnapshot {
        TodoSnapshot(id: id, title: title, notes: notes, date: on ?? date, isCompleted: isCompleted, completedAt: completedAt,
                     createdAt: date, updatedAt: date, sortOrder: 0, groupID: groupID, repeatRule: repeatRule)
    }
    private func migration(_ repo: MemoryTaskRepository, _ groups: MemoryGroupRepository, _ todos: [TodoSnapshot]) -> (LegacyTaskMigration, MemoryLegacySource) {
        let source = MemoryLegacySource(archive: LegacyTodoArchive(todos: todos, groups: []))
        return (LegacyTaskMigration(source: source, tasks: repo, groups: groups, calendar: calendar,
            links: TaskCalendarLinks(userID: user, inMemory: true)), source)
    }
    func payload(_ draft: TaskDraft) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(SupabaseTaskRepository.payload(draft))) as! [String: Any]
    }
    private func mutationFixture(recurrence: Bool = false, template: Bool = false, received: Bool = false) -> (TaskWorkspaceModel, MemoryTaskRepository, WorkTask) {
        let (vm, repo, _) = fixture()
        var task = repo.row(TaskDraft(title: "original", scheduledDate: day), createdBy: received ? UUID() : user)
        task.recurrenceID = recurrence ? UUID() : nil
        task.isRecurrenceTemplate = template
        repo.rows = [task]
        return (vm, repo, task)
    }
    func testInstanceHasNoEditorAction() {
        let (vm, _, task) = mutationFixture(recurrence: true)
        XCTAssertFalse(vm.canEditContent(task)); vm.openEditor(task); XCTAssertNil(vm.editor)
    }
    func testInstanceContentSaveIsRejectedByViewModel() async {
        let (vm, repo, task) = mutationFixture(recurrence: true)
        let saved = await vm.save(task, draft: TaskDraft(title: "changed", scheduledDate: day))
        XCTAssertFalse(saved); XCTAssertEqual(repo.rows.first?.title, "original")
    }
    func testInstanceContentPayloadIsRejectedByRepositoryPolicy() {
        let (_, _, task) = mutationFixture(recurrence: true)
        XCTAssertThrowsError(try SupabaseTaskRepository.contentUpdatePayload(task: task, draft: TaskDraft(title: "changed", scheduledDate: day, notes: "changed"), userID: user)) { XCTAssertEqual($0 as? TaskServiceError, .permission) }
    }
    func testInstanceGroupMutationIsRejected() async {
        let (vm, _, task) = mutationFixture(recurrence: true)
        let draft = TaskDraft(title: task.title, scheduledDate: day, groupID: UUID())
        XCTAssertThrowsError(try SupabaseTaskRepository.contentUpdatePayload(task: task, draft: draft, userID: user))
        let saved = await vm.save(task, draft: draft); XCTAssertFalse(saved)
    }
    func testInstanceDeadlineMutationIsRejected() async {
        let (vm, _, task) = mutationFixture(recurrence: true)
        let draft = TaskDraft(title: task.title, scheduledDate: day, deadlineDate: day, startAt: date)
        XCTAssertThrowsError(try SupabaseTaskRepository.contentUpdatePayload(task: task, draft: draft, userID: user))
        let saved = await vm.save(task, draft: draft); XCTAssertFalse(saved)
    }
    func testInstanceCanComplete() async {
        let (vm, repo, task) = mutationFixture(recurrence: true)
        await vm.toggle(task)
        XCTAssertEqual(repo.rows.first?.status, .completed); XCTAssertNotNil(repo.rows.first?.completedAt)
        XCTAssertEqual(repo.events.map(\.kind), [.completed])
    }
    func testInstanceCanReopen() async {
        let (vm, repo, initial) = mutationFixture(recurrence: true)
        var task = initial; task.status = .completed; task.completedAt = date; repo.rows = [task]
        await vm.toggle(task)
        XCTAssertEqual(repo.rows.first?.status, .open); XCTAssertNil(repo.rows.first?.completedAt)
        XCTAssertEqual(repo.events.map(\.kind), [.reopened])
    }
    func testTemplateCannotOpenEditorOrUpdateContent() async {
        let (vm, _, task) = mutationFixture(template: true)
        XCTAssertFalse(vm.canEditContent(task)); XCTAssertEqual(vm.permission(for: task), .readOnly)
        let draft = TaskDraft(title: "changed", scheduledDate: day)
        XCTAssertThrowsError(try SupabaseTaskRepository.contentUpdatePayload(task: task, draft: draft, userID: user))
        let saved = await vm.save(task, draft: draft); XCTAssertFalse(saved)
    }
    func testTemplateCannotCompleteThroughViewModel() async {
        let (vm, repo, task) = mutationFixture(template: true)
        await vm.toggle(task); XCTAssertEqual(repo.rows.first?.status, .open); XCTAssertTrue(repo.events.isEmpty)
    }
    func testReceivedContentUpdateRemainsRejected() async {
        let (vm, repo, task) = mutationFixture(received: true)
        let draft = TaskDraft(title: "changed", scheduledDate: day, notes: "changed")
        XCTAssertFalse(vm.canEditContent(task))
        XCTAssertThrowsError(try SupabaseTaskRepository.contentUpdatePayload(task: task, draft: draft, userID: user))
        let saved = await vm.save(task, draft: draft); XCTAssertFalse(saved); XCTAssertEqual(repo.rows.first?.title, task.title)
    }
    func testReceivedCanCompleteAndReopenWithPersistentEvents() async throws {
        let (vm, repo, task) = mutationFixture(received: true)
        await vm.toggle(task); XCTAssertEqual(repo.rows.first?.status, .completed)
        await vm.toggle(try XCTUnwrap(repo.rows.first)); XCTAssertEqual(repo.rows.first?.status, .open)
        XCTAssertEqual(repo.events.map(\.kind), [.completed, .reopened])
    }
    func testSelfContentSaveStillSucceeds() async {
        let (vm, repo, task) = mutationFixture()
        let saved = await vm.save(task, draft: TaskDraft(title: "changed", scheduledDate: day, notes: "memo", estimatedMinutes: 30, priority: .important))
        XCTAssertTrue(saved); XCTAssertEqual(repo.rows.first?.title, "changed"); XCTAssertEqual(repo.rows.first?.notes, "memo")
        XCTAssertEqual(repo.rows.first?.estimatedMinutes, 30); XCTAssertEqual(repo.rows.first?.priority, .important)
    }
    func testSelfGroupUpdateStillSucceeds() async {
        let (vm, repo, task) = mutationFixture(); let group = UUID()
        let saved = await vm.save(task, draft: TaskDraft(title: task.title, scheduledDate: day, groupID: group))
        XCTAssertTrue(saved); XCTAssertEqual(repo.rows.first?.groupID, group)
    }
    func testSelfDeadlineUpdateStillSucceeds() async {
        let (vm, repo, task) = mutationFixture()
        let saved = await vm.save(task, draft: TaskDraft(title: task.title, scheduledDate: day, deadlineDate: day, startAt: date, deadlineAt: date.addingTimeInterval(3600)))
        XCTAssertTrue(saved); XCTAssertEqual(repo.rows.first?.deadlineDate, day)
        XCTAssertEqual(repo.rows.first?.startAt, date); XCTAssertEqual(repo.rows.first?.deadlineAt, date.addingTimeInterval(3600))
    }
    func testContentUpdatePayloadHasExactWhitelist() throws {
        let (_, _, task) = mutationFixture()
        let draft = TaskDraft(title: " changed ", scheduledDate: day, groupID: UUID(), deadlineDate: day, startAt: date, deadlineAt: date.addingTimeInterval(3600), sourceLocalTodoID: UUID(), notes: "memo", scheduledAt: date, estimatedMinutes: 30, priority: .important)
        let values = try SupabaseTaskRepository.contentUpdatePayload(task: task, draft: draft, userID: user)
        XCTAssertEqual(Set(values.keys), Set(["title", "notes", "group_id", "deadline_date", "start_at", "deadline_at", "estimated_minutes", "priority"]))
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(values)) as! [String: Any]
        XCTAssertEqual(payload["title"] as? String, "changed"); XCTAssertEqual(payload["notes"] as? String, "memo")
        XCTAssertEqual(payload["priority"] as? String, "important"); XCTAssertEqual(payload["estimated_minutes"] as? Int, 30)
    }
    func testContentUpdatePayloadOmitsAllProtectedFields() throws {
        let (_, _, task) = mutationFixture()
        let values = try SupabaseTaskRepository.contentUpdatePayload(task: task, draft: TaskDraft(title: task.title, scheduledDate: day), userID: user)
        for key in ["id", "created_by", "assigned_to", "space_id", "recurrence_id", "is_recurrence_template", "source_local_todo_id", "defer_count", "last_deferred_at", "is_archived", "scheduled_date", "scheduled_at", "day_period", "status", "completed_at"] { XCTAssertNil(values[key], key) }
    }
    func testQuickAddWorkspaceParsesBeforeSavingAndKeepsFocus() async throws {
        let (vm, repo, _) = fixture()
        vm.quickTitle = "내일 오후 3시 쿠팡 발주 확인 30분 중요"
        let saved = await vm.add(); XCTAssertTrue(saved)
        let draft = try XCTUnwrap(repo.attempts.first)
        XCTAssertEqual(draft.title, "쿠팡 발주 확인"); XCTAssertEqual(draft.scheduledDate.value, "2026-10-03")
        XCTAssertEqual(draft.estimatedMinutes, 30); XCTAssertEqual(draft.priority, .important); XCTAssertNotNil(draft.scheduledAt)
        XCTAssertNil(draft.startAt); XCTAssertNil(draft.deadlineDate); XCTAssertTrue(vm.quickTitle.isEmpty); XCTAssertTrue(vm.wantsFocus)
    }
    func testQuickAddFailedSavePreservesInputAndCommandIdentity() async {
        let (vm, repo, _) = fixture(); let input = "내일 공급사 연락 20분"
        vm.quickTitle = input; repo.failure = .network
        let failed = await vm.add(); XCTAssertFalse(failed); XCTAssertEqual(vm.quickTitle, input)
        repo.failure = nil; let saved = await vm.add(); XCTAssertTrue(saved)
        XCTAssertEqual(repo.attempts.count, 2); XCTAssertEqual(repo.attempts[0].id, repo.attempts[1].id)
    }
    func testFullDeferredIncludesOlderThanThreeDaysAndSomedayStaysSeparate() async throws {
        let (vm, repo, _) = fixture()
        let oldDay = try TaskDay(value: "2026-08-01")
        let old = repo.row(TaskDraft(title: "오래된 일", scheduledDate: oldDay))
        var someday = repo.row(TaskDraft(title: "언젠가", scheduledDate: day)); someday.scheduledDate = nil
        repo.rows = [old, someday]; await vm.refresh()
        XCTAssertEqual(vm.deferredTasks.map(\.id), [old.id]); XCTAssertEqual(vm.someday.map(\.id), [someday.id])
        XCTAssertFalse(vm.todayTasks.contains(where: { $0.id == someday.id })); XCTAssertFalse(vm.overdueDays.contains(day.date(calendar: calendar)))
    }
    func testLogoutClearsSomedayAndDeferredState() async {
        let (vm, repo, _) = fixture()
        var someday = repo.row(TaskDraft(title: "언젠가", scheduledDate: day)); someday.scheduledDate = nil
        repo.rows = [someday]; await vm.refresh(); XCTAssertEqual(vm.someday.count, 1)
        vm.invalidate(); XCTAssertTrue(vm.someday.isEmpty); XCTAssertTrue(vm.deferredTasks.isEmpty)
    }
    func testCivilDayDoesNotShiftThroughUTC() throws {
        let midnight = calendar.startOfDay(for: date)
        XCTAssertEqual(TaskDay(midnight, calendar: calendar).value, "2026-10-02")
        XCTAssertEqual(try TaskDay(value: "2026-10-02").date(calendar: calendar), midnight)
    }
    func testCivilDateDecoderRejectsInvalidDates() {
        XCTAssertThrowsError(try JSONDecoder().decode(TaskDay.self, from: Data("\"2026-02-30\"".utf8)))
        XCTAssertThrowsError(try TaskDay(value: "2026-13-01"))
    }
    func testDateOnlyPayloadHasNoInventedTimestamp() throws {
        let p = try payload(TaskDraft(title: "x", scheduledDate: day, deadlineDate: day))
        XCTAssertEqual(p["deadline_date"] as? String, "2026-10-02")
        XCTAssertTrue(p["start_at"] is NSNull); XCTAssertTrue(p["deadline_at"] is NSNull)
        XCTAssertNil(p["created_at"]); XCTAssertNil(p["updated_at"])
    }
    func testStartOnlyPayload() throws {
        let p = try payload(TaskDraft(title: "x", scheduledDate: day, deadlineDate: day, startAt: date))
        XCTAssertEqual(p["start_at"] as? String, SupabaseTaskRepository.timestamp(date)); XCTAssertTrue(p["deadline_at"] is NSNull)
    }
    func testEndOnlyPayload() throws {
        let p = try payload(TaskDraft(title: "x", scheduledDate: day, deadlineDate: day, deadlineAt: date))
        XCTAssertTrue(p["start_at"] is NSNull); XCTAssertEqual(p["deadline_at"] as? String, SupabaseTaskRepository.timestamp(date))
    }
    func testBothTimesPayloadAndValidation() throws {
        let end = date.addingTimeInterval(3600)
        let draft = TaskDraft(title: "x", scheduledDate: day, deadlineDate: day, startAt: date, deadlineAt: end)
        try draft.validate(); let p = try payload(draft)
        XCTAssertEqual(p["start_at"] as? String, SupabaseTaskRepository.timestamp(date))
        XCTAssertEqual(p["deadline_at"] as? String, SupabaseTaskRepository.timestamp(end))
        XCTAssertThrowsError(try TaskDraft(title: "x", scheduledDate: day, startAt: date).validate())
        XCTAssertThrowsError(try TaskDraft(title: "x", scheduledDate: day, deadlineDate: day, startAt: end, deadlineAt: date).validate())
    }
    func testSelfTaskUsesServerRepositoryAndCreatedOnlyHistory() async {
        let (vm, repo, _) = fixture(); vm.quickTitle = "서버 할 일"; await vm.add()
        XCTAssertEqual(repo.rows.count, 1); XCTAssertEqual(repo.rows.first?.createdBy, user); XCTAssertEqual(repo.rows.first?.assignedTo, user)
        XCTAssertNil(repo.rows.first?.spaceID); XCTAssertEqual(repo.events.map(\.kind), [.created]); XCTAssertTrue(vm.quickTitle.isEmpty)
        XCTAssertTrue(vm.wantsFocus); XCTAssertEqual(vm.assigned.count, 1)
    }
    func testWriteFailureKeepsQuickInputAndRetryIdentity() async {
        let (vm, repo, _) = fixture(); vm.quickTitle = "재시도"; repo.failure = .network; await vm.add()
        XCTAssertEqual(vm.quickTitle, "재시도"); XCTAssertNotNil(vm.errorMessage)
        let id = repo.attempts.first?.id; repo.failure = nil; await vm.add()
        XCTAssertEqual(repo.attempts.last?.id, id); XCTAssertEqual(repo.rows.count, 1)
    }
    func testRefreshFailureRetainsVisibleRows() async throws {
        let (vm, repo, _) = fixture(); _ = try await repo.createTask(TaskDraft(title: "보존", scheduledDate: day)); await vm.refresh()
        repo.failure = .network; await vm.refresh(); XCTAssertEqual(vm.assigned.first?.title, "보존"); XCTAssertNotNil(vm.errorMessage)
    }
    func testReceivedSentAndAssignedQueriesDoNotMixAccounts() async {
        let (vm, repo, _) = fixture()
        repo.rows = [repo.row(TaskDraft(title: "self", scheduledDate: day)), repo.row(TaskDraft(title: "received", scheduledDate: day), createdBy: UUID()), repo.row(TaskDraft(title: "sent", scheduledDate: day), assignedTo: UUID()), repo.row(TaskDraft(title: "other", scheduledDate: day), createdBy: UUID(), assignedTo: UUID())]
        await vm.refresh()
        XCTAssertEqual(Set(vm.assigned.map(\.title)), ["self", "received"])
        XCTAssertEqual(vm.received.map(\.title), ["received"]); XCTAssertEqual(vm.sent.map(\.title), ["sent"])
    }
    func testCompletionAndReopenEvents() async throws {
        let (vm, repo, _) = fixture(); let task = try await repo.createTask(TaskDraft(title: "완료", scheduledDate: day))
        await vm.toggle(task); XCTAssertEqual(vm.assigned.first?.status, .completed)
        await vm.toggle(vm.assigned[0]); XCTAssertEqual(vm.assigned.first?.status, .open)
        XCTAssertEqual(repo.events.map(\.kind), [.completed, .reopened])
    }
    func testReadOnlySentTaskCannotBeChanged() async {
        let (vm, repo, _) = fixture(); let sent = repo.row(TaskDraft(title: "sent", scheduledDate: day), assignedTo: UUID())
        repo.rows = [sent]; await vm.toggle(sent); XCTAssertEqual(repo.rows[0].status, .open); XCTAssertTrue(repo.events.isEmpty)
        let saved = await vm.save(sent, draft: TaskDraft(title: "수정", scheduledDate: day)); XCTAssertFalse(saved)
    }
    func testReceivedTaskHasCompletionOnlyPermission() {
        let (_, repo, _) = fixture(); XCTAssertEqual(repo.row(TaskDraft(title: "x", scheduledDate: day), createdBy: UUID()).permission(userID: user), .completeOnly)
    }
    func testHistoryFailureDoesNotRollbackTaskAndCanRetry() async {
        let (vm, repo, _) = fixture(); repo.eventFailure = true; vm.quickTitle = "이벤트 대기"; await vm.add()
        XCTAssertEqual(repo.rows.count, 1); XCTAssertNotNil(vm.historyNotice); XCTAssertTrue(repo.events.isEmpty)
        repo.eventFailure = false; await vm.retryEvents(); XCTAssertEqual(repo.events.count, 1); XCTAssertNil(vm.historyNotice)
    }
    func testInvalidatedWorkspaceIgnoresLateResponse() async throws {
        let (vm, repo, _) = fixture(); _ = try await repo.createTask(TaskDraft(title: "old", scheduledDate: day))
        repo.onRead = { vm.invalidate() }; await vm.refresh(); XCTAssertTrue(vm.assigned.isEmpty); XCTAssertFalse(vm.loaded)
    }
    func testMiniCreatesTodayWhileFullUsesSelectedDate() async {
        let (vm, repo, _) = fixture(); vm.selectedDate = date.addingTimeInterval(86400); vm.quickTitle = "mini"; await vm.add(mini: true)
        vm.quickTitle = "full"; await vm.add(); XCTAssertEqual(repo.rows[0].scheduledDate, day)
        XCTAssertEqual(repo.rows[1].scheduledDate, TaskDay(vm.selectedDate, calendar: calendar))
    }
    func testOverdueIncludesAssignedReceivedAndExcludesCompleted() async {
        let (vm, repo, _) = fixture(); let yesterday = TaskDay(date.addingTimeInterval(-86400), calendar: calendar)
        repo.rows = [repo.row(TaskDraft(title: "missed", scheduledDate: yesterday)), repo.row(TaskDraft(title: "received", scheduledDate: yesterday), createdBy: UUID()), repo.row(TaskDraft(title: "done", scheduledDate: yesterday, status: .completed))]
        await vm.refresh(); XCTAssertEqual(vm.missed.count, 2); XCTAssertEqual(vm.overdueDays, [calendar.startOfDay(for: date.addingTimeInterval(-86400))])
    }
    func testPreviewDoesNotWriteServerAndRequiresApproval() async {
        let (_, repo, groups) = fixture(); let (migration, _) = migration(repo, groups, [snapshot()])
        await migration.loadPreview(); XCTAssertEqual(migration.preview?.importable, 1); XCTAssertTrue(repo.rows.isEmpty)
        await migration.migrate(approvedUserID: UUID()); XCTAssertTrue(repo.rows.isEmpty)
        await migration.migrate(approvedUserID: user); XCTAssertEqual(repo.rows.count, 1)
    }
    func testMigrationRetryDoesNotOverwriteServerChanges() async throws {
        let (_, repo, groups) = fixture(); let local = snapshot(); let (migration, source) = migration(repo, groups, [local])
        await migration.loadPreview(); await migration.migrate(approvedUserID: user)
        let id = repo.rows[0].id; _ = try await repo.updateTask(id: id, draft: TaskDraft(title: "서버에서 수정", scheduledDate: day))
        await migration.loadPreview(); XCTAssertEqual(migration.preview?.alreadyImported, 1)
        await migration.migrate(approvedUserID: user); XCTAssertEqual(repo.rows.count, 1); XCTAssertEqual(repo.rows[0].title, "서버에서 수정")
        XCTAssertEqual(repo.rows[0].sourceLocalTodoID, local.id); XCTAssertNotEqual(id, local.id); XCTAssertEqual(source.archive.todos[0], local)
        XCTAssertTrue(repo.events.isEmpty)
    }
    func testRepeatsRemainPendingWhileNotesAreImportable() async {
        let (_, repo, groups) = fixture(); let (migration, _) = migration(repo, groups, [snapshot(repeatRule: "daily"), snapshot(notes: "메모"), snapshot()])
        await migration.loadPreview(); XCTAssertEqual(migration.preview?.pendingRepeats, 1); XCTAssertEqual(migration.preview?.notesIncluded, 1)
        await migration.migrate(approvedUserID: user); XCTAssertEqual(repo.rows.count, 2)
        XCTAssertEqual(repo.rows.first { $0.notes == "메모" }?.notes, "메모")
    }
    func testMigrationFailureCanRetryWithoutDuplicate() async {
        let (_, repo, groups) = fixture(); let (migration, _) = migration(repo, groups, [snapshot()])
        await migration.loadPreview(); repo.failure = .network; await migration.migrate(approvedUserID: user); XCTAssertEqual(migration.failed, 1)
        repo.failure = nil; await migration.migrate(approvedUserID: user); XCTAssertEqual(repo.rows.count, 1)
    }
    func testStableMigrationIDsAreAccountScoped() {
        let source = UUID(); let a = MigrationIdentity.id(kind: "task", userID: user, sourceID: source)
        XCTAssertEqual(a, MigrationIdentity.id(kind: "task", userID: user, sourceID: source))
        XCTAssertNotEqual(a, MigrationIdentity.id(kind: "task", userID: UUID(), sourceID: source))
        XCTAssertNotEqual(a, MigrationIdentity.id(kind: "group", userID: user, sourceID: source))
    }
    func testLegacyTimingIsPreservedWithoutSyntheticTimes() {
        var local = snapshot(); local.deadlineDate = date; local.startDateTime = date.addingTimeInterval(3600)
        let draft = LegacyTaskMigration.draft(local, groupID: nil, calendar: calendar)
        XCTAssertEqual(draft.deadlineDate, day); XCTAssertEqual(draft.startAt, local.startDateTime); XCTAssertNil(draft.deadlineAt)
    }
    func testDeviceCalendarLinksAreAccountScoped() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = UUID(); let links = TaskCalendarLinks(userID: user, directory: directory)
        try links.set(taskID: task, identifier: "local-event")
        XCTAssertEqual(TaskCalendarLinks(userID: user, directory: directory).identifier(taskID: task), "local-event")
        XCTAssertNil(TaskCalendarLinks(userID: UUID(), directory: directory).identifier(taskID: task))
    }
    func testServerStoreDoesNotOpenLegacyRepository() async {
        let (vm, _, _) = fixture(); var reads = 0
        let store = TodoWorkspaceStore(makeRepository: { reads += 1; throw TaskServiceError.unavailable }, serverTasks: vm)
        store.load(); await Task.yield(); XCTAssertEqual(reads, 0); XCTAssertNil(store.model)
    }
    func testRootAuthRefreshFailureClearsCachedIdentity() async {
        let fake = ServerFakeAccount(); fake.restored = AuthenticatedUser(id: user, email: nil)
        fake.row = CollaborationProfile(id: user, displayName: "me", friendCode: "12345678", isActive: true, createdAt: date, updatedAt: date)
        let auth = AuthViewModel(auth: fake, profiles: fake); await auth.restore(); XCTAssertNotNil(auth.profile)
        auth.requireLogin(.refreshFailed); XCTAssertNil(auth.profile); XCTAssertNil(auth.user)
    }
    func testRootGateCreatesOnlyAuthenticatedScopeAndClearsOnLogout() async {
        let fake = ServerFakeAccount(); let auth = AuthViewModel(auth: fake, profiles: fake)
        var loginRequests = 0; var scopeChanges = 0
        let session = ApplicationSession(account: auth, presentLogin: { loginRequests += 1 }) { id, account in
            let tasks = MemoryTaskRepository(userID: id); let groups = MemoryGroupRepository(userID: id)
            return TodoWorkspaceStore(account: account, serverTasks: TaskWorkspaceModel(repository: tasks, groups: groups))
        }
        session.onAccountChange = { scopeChanges += 1 }; session.start(); await Task.yield()
        XCTAssertFalse(session.allowAccess()); XCTAssertGreaterThan(loginRequests, 0)
        fake.restored = AuthenticatedUser(id: user, email: nil)
        fake.row = CollaborationProfile(id: user, displayName: "me", friendCode: "12345678", isActive: true, createdAt: date, updatedAt: date)
        await auth.signIn(email: "me@example.com", password: "password")
        XCTAssertTrue(session.allowAccess()); XCTAssertEqual(session.store?.serverTasks?.userID, user)
        let previous = session.store?.serverTasks; previous?.quickTitle = "private draft"
        await auth.signOut(); XCTAssertNil(session.store); XCTAssertEqual(previous?.quickTitle, ""); XCTAssertEqual(scopeChanges, 2)
    }
    func testLegacyReadUsesBackupWithoutChangingOriginalStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Todo.store")
        let container = try TodoPersistence.makeContainer(storeURL: url)
        let repo = SwiftDataTodoRepository(container: container)
        _ = try repo.create(TodoDraft(title: "원본 보존", notes: "메모", date: date), calendar: calendar)
        let context = ModelContext(container)
        context.insert(TodoRepeatSchedule(title: "아직 생성되지 않은 반복", beginsOn: date, now: date)); try context.save()
        let before = try Data(contentsOf: url)
        let archive = try LegacySwiftDataTodoSource(storeURL: url).read()
        XCTAssertEqual(archive.todos.first?.title, "원본 보존"); XCTAssertEqual(archive.repeatTemplateCount, 1)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try repo.allTodos().first?.notes, "메모")
    }
    func testBrokenCalendarMappingIsNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(user.uuidString + ".plist"); let original = Data("broken".utf8)
        try original.write(to: url)
        let links = TaskCalendarLinks(userID: user, directory: directory)
        XCTAssertThrowsError(try links.set(taskID: UUID(), identifier: "event")); XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testUnchangedAbsoluteTimeSurvivesTimezoneChange() throws {
        var changedZone = calendar; changedZone.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let result = TaskDeadlineTiming.timestamp(date, day: day, originalDay: day, originalTime: date, calendar: changedZone)
        XCTAssertEqual(result, date)
    }
    func testChangedDeadlineDayKeepsChosenClockTime() {
        let next = TaskDay(date.addingTimeInterval(86400), calendar: calendar)
        let result = TaskDeadlineTiming.timestamp(date, day: next, originalDay: day, originalTime: date, calendar: calendar)
        XCTAssertEqual(TaskDay(result, calendar: calendar), next)
        XCTAssertEqual(calendar.component(.hour, from: result), 10)
    }

    func testCreatedByMeIncludesSelfAndSentButNotReceived() async throws {
        let (_, repo, _) = fixture()
        repo.rows = [repo.row(TaskDraft(title: "self", scheduledDate: day)), repo.row(TaskDraft(title: "sent", scheduledDate: day), assignedTo: UUID()), repo.row(TaskDraft(title: "received", scheduledDate: day), createdBy: UUID())]
        let rows = try await repo.tasksCreatedByMe(date: day)
        XCTAssertEqual(Set(rows.map(\.title)), ["self", "sent"])
    }
    func testTimestampKeepsFractionalSeconds() {
        XCTAssertEqual(SupabaseTaskRepository.timestamp(Date(timeIntervalSince1970: 10.125)), "1970-01-01T00:00:10.125Z")
    }

    func testEventWireContractForAllFourKinds() throws {
        for kind in [TaskEventKind.created, .assigned, .completed, .reopened] {
            let event = TaskEventRequest(id: UUID(), taskID: UUID(), actorID: user, kind: kind, actorDisplayNameSnapshot: "행동 당시 이름")
            let encoded = try JSONEncoder().encode(TaskEventPayload(event, userID: user))
            let values = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            XCTAssertEqual(values["event_type"] as? String, kind.rawValue)
            XCTAssertEqual(values["actor_id"] as? String, user.uuidString)
            XCTAssertEqual(values["actor_display_name_snapshot"] as? String, "행동 당시 이름")
            XCTAssertEqual((values["metadata"] as? [String: Any])?.count, 0)
            XCTAssertNil(values["created_at"]); XCTAssertNil(values["title"]); XCTAssertNil(values["notes"])
        }
    }
    func testEventRejectsDifferentActorAndMissingSnapshot() {
        let wrong = TaskEventRequest(id: UUID(), taskID: UUID(), actorID: UUID(), kind: .created, actorDisplayNameSnapshot: "me")
        XCTAssertThrowsError(try TaskEventPayload(wrong, userID: user))
        XCTAssertThrowsError(try TaskEventPayload(TaskEventRequest(id: UUID(), taskID: UUID(), actorID: user, kind: .created), userID: user))
    }
    func testSelfCreationHasOnlyCreatedAndAssignmentHasBoth() {
        let (_, repo, _) = fixture()
        let selfTask = repo.row(TaskDraft(title: "self", scheduledDate: day))
        XCTAssertEqual(TaskEventRequest.creationEvents(task: selfTask, actorID: user, displayName: "me").map(\.kind), [.created])
        let assigned = repo.row(TaskDraft(title: "assigned", scheduledDate: day), assignedTo: UUID())
        let events = TaskEventRequest.creationEvents(task: assigned, actorID: user, displayName: "me")
        XCTAssertEqual(events.map(\.kind), [.created, .assigned]); XCTAssertEqual(Set(events.map(\.id)).count, 2)
        XCTAssertEqual(events.map(\.id), TaskEventRequest.creationEvents(task: assigned, actorID: user, displayName: "changed").map(\.id))
    }
    func testActorSnapshotCapturedBeforeCreateRequest() async {
        let (_, repo, groups) = fixture(); var name = "before"
        let vm = TaskWorkspaceModel(repository: repo, groups: groups, actorDisplayName: { name })
        repo.onCreate = { name = "after" }; vm.quickTitle = "task"; await vm.add()
        XCTAssertEqual(repo.events.first?.actorDisplayNameSnapshot, "before")
    }
    func testActorSnapshotSurvivesFailedWriteAndUserRetry() async {
        let (_, repo, groups) = fixture(); var name = "first action"
        let vm = TaskWorkspaceModel(repository: repo, groups: groups, actorDisplayName: { name })
        repo.failure = .network; vm.quickTitle = "task"; await vm.add()
        repo.failure = nil; name = "renamed"; await vm.add()
        XCTAssertEqual(repo.events.first?.actorDisplayNameSnapshot, "first action")
    }
    func testCompletedAndReopenedCaptureTheirOwnActorSnapshot() async throws {
        let (_, repo, groups) = fixture(); var name = "complete actor"
        let vm = TaskWorkspaceModel(repository: repo, groups: groups, actorDisplayName: { name })
        let task = try await repo.createTask(TaskDraft(title: "task", scheduledDate: day)); await vm.toggle(task)
        name = "reopen actor"; await vm.toggle(repo.rows[0])
        XCTAssertEqual(repo.events.map(\.actorDisplayNameSnapshot), ["complete actor", "reopen actor"])
    }
    func testNotesNilAndEmptyUseNullPayload() throws {
        XCTAssertTrue(try payload(TaskDraft(title: "x", scheduledDate: day))["notes"] is NSNull)
        XCTAssertTrue(try payload(TaskDraft(title: "x", scheduledDate: day, notes: ""))["notes"] is NSNull)
    }
    func testMultilineMemoIsNotTrimmedOrPutInOtherFields() throws {
        let memo = "  첫 줄\n두 번째 줄\n"
        let p = try payload(TaskDraft(title: "title", scheduledDate: day, notes: memo))
        XCTAssertEqual(p["notes"] as? String, memo); XCTAssertEqual(p["title"] as? String, "title"); XCTAssertNil(p["metadata"])
    }
    func testLegacyMemoMigratesAndServerEditedMemoSurvivesRetry() async throws {
        let (_, repo, groups) = fixture(); let memo = "첫 줄\n두 번째 줄"
        let local = snapshot(notes: memo); let (migration, source) = migration(repo, groups, [local])
        await migration.loadPreview(); XCTAssertEqual(migration.preview?.notesIncluded, 1); XCTAssertEqual(migration.preview?.importable, 1)
        await migration.migrate(approvedUserID: user); XCTAssertEqual(repo.rows[0].notes, memo)
        _ = try await repo.updateTask(id: repo.rows[0].id, draft: TaskDraft(title: "server title", scheduledDate: day, notes: "서버에서 수정"))
        await migration.migrate(approvedUserID: user); XCTAssertEqual(repo.rows[0].notes, "서버에서 수정"); XCTAssertEqual(repo.rows.count, 1)
        XCTAssertEqual(source.archive.todos[0].notes, memo)
    }
    func testNilLegacyMemoMigratesAsNil() async {
        let (_, repo, groups) = fixture(); let (migration, _) = migration(repo, groups, [snapshot()])
        await migration.loadPreview(); await migration.migrate(approvedUserID: user); XCTAssertNil(repo.rows[0].notes)
    }
    func testPendingEventSurvivesRestartWithSameUUIDAndName() async throws {
        let (_, repo, _) = fixture(); let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FileTaskEventStorage(userID: user, directory: directory)
        let event = TaskEventRequest(id: UUID(), taskID: UUID(), actorID: user, kind: .completed, actorDisplayNameSnapshot: "before restart")
        repo.eventFailure = true; let first = TaskEventQueue(repository: repo, storage: storage); await first.enqueue([event])
        XCTAssertEqual(try storage.load(), [event]); first.invalidate()
        repo.eventFailure = false; let restored = TaskEventQueue(repository: repo, storage: storage); await restored.retry()
        XCTAssertEqual(repo.events, [event]); XCTAssertTrue(try storage.load().isEmpty)
    }
    func testEventQueueIsAccountScoped() async throws {
        let (_, repo, _) = fixture(); let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FileTaskEventStorage(userID: user, directory: directory)
        let event = TaskEventRequest(id: UUID(), taskID: UUID(), actorID: user, kind: .created, actorDisplayNameSnapshot: "me")
        repo.eventFailure = true; await TaskEventQueue(repository: repo, storage: storage).enqueue([event])
        XCTAssertTrue(try FileTaskEventStorage(userID: UUID(), directory: directory).load().isEmpty)
        XCTAssertEqual(try storage.load(), [event])
    }
    func testCorruptEventQueueIsPreservedInsteadOfOverwritten() async throws {
        let (_, repo, _) = fixture(); let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storage = FileTaskEventStorage(userID: user, directory: directory); let damaged = Data("invalid".utf8); try damaged.write(to: storage.url)
        let queue = TaskEventQueue(repository: repo, storage: storage)
        await queue.enqueue([TaskEventRequest(id: UUID(), taskID: UUID(), actorID: user, kind: .created, actorDisplayNameSnapshot: "me")])
        XCTAssertEqual(try Data(contentsOf: storage.url), damaged); XCTAssertTrue(repo.events.isEmpty); XCTAssertNotNil(queue.notice)
    }
    func testEventStorageFailureDoesNotRollbackTask() async {
        let (_, repo, groups) = fixture(); let storage = FailingEventStorage(); let queue = TaskEventQueue(repository: repo, storage: storage)
        let vm = TaskWorkspaceModel(repository: repo, groups: groups, events: queue, actorDisplayName: { "me" })
        vm.quickTitle = "saved"; await vm.add(); XCTAssertEqual(repo.rows.count, 1); XCTAssertNotNil(vm.historyNotice)
        storage.fails = false; await vm.retryEvents(); XCTAssertEqual(repo.events.count, 1); XCTAssertNil(vm.historyNotice)
    }
    func testMigrationEventFailureCanRetryWithoutDuplicateTask() async {
        let (_, repo, groups) = fixture()
        let queue = TaskEventQueue(repository: repo, storage: MemoryTaskEventStorage())
        let event = TaskEventRequest(id: UUID(), taskID: UUID(), actorID: user, kind: .completed, actorDisplayNameSnapshot: "me")
        repo.eventFailure = true; await queue.enqueue([event])
        let source = MemoryLegacySource(archive: LegacyTodoArchive(todos: [snapshot(notes: "memo")], groups: []))
        let migration = LegacyTaskMigration(source: source, tasks: repo, groups: groups, links: TaskCalendarLinks(userID: user, inMemory: true), events: queue)
        await migration.loadPreview(); await migration.migrate(approvedUserID: user)
        XCTAssertEqual(migration.succeeded, 1); XCTAssertEqual(migration.failed, 0)
        XCTAssertEqual(queue.pending, [event]); XCTAssertTrue(repo.events.isEmpty)
        await migration.migrate(approvedUserID: user); XCTAssertEqual(repo.rows.count, 1)
        migration.invalidate(); XCTAssertEqual(queue.pending, [event])
        repo.eventFailure = false; await queue.retry()
        XCTAssertEqual(repo.events, [event]); XCTAssertTrue(queue.pending.isEmpty)
    }
    func testWeekdayBitsMatchActualLegacySundayFirstConvention() {
        let values = [1, 2, 4, 8, 16, 32, 64]
        for day in 1...7 { XCTAssertEqual(TodoWeekdayRule([day]).mask, values[day - 1]) }
        XCTAssertEqual(TodoWeekdayRule(Set(1...7)).mask, 127)
        XCTAssertEqual(TodoWeekdayRule([]).mask, 0)
    }
    func testRepeatScheduleInstanceAndUnknownRuleAllRemainPending() {
        var scheduleInstance = snapshot(); scheduleInstance.repeatScheduleID = UUID()
        XCTAssertNotNil(LegacyTaskMigration.pendingReason(scheduleInstance))
        XCTAssertNotNil(LegacyTaskMigration.pendingReason(snapshot(repeatRule: "unrecognized legacy rule")))
        XCTAssertNil(LegacyTaskMigration.pendingReason(snapshot(notes: "memo")))
    }
    func testPreviewCountsRegularRepeatsGroupsAndMemoSeparately() async {
        let (_, repo, groups) = fixture()
        let source = MemoryLegacySource(archive: LegacyTodoArchive(todos: [snapshot(notes: "memo"), snapshot(), snapshot(repeatRule: "daily", notes: "repeat memo")], groups: [], repeatTemplateCount: 1))
        let migration = LegacyTaskMigration(source: source, tasks: repo, groups: groups, links: TaskCalendarLinks(userID: user, inMemory: true))
        await migration.loadPreview()
        XCTAssertEqual(migration.preview?.regularTodos, 2); XCTAssertEqual(migration.preview?.pendingRepeats, 1)
        XCTAssertEqual(migration.preview?.notesIncluded, 2); XCTAssertEqual(migration.preview?.pendingRepeatTemplates, 1)
        XCTAssertTrue(repo.rows.isEmpty); XCTAssertTrue(repo.events.isEmpty)
    }

    func testMigrationRetryDoesNotInventAssignmentAfterServerReassignment() async {
        let (_, repo, groups) = fixture(); let local = snapshot(notes: "local memo"); let (migration, _) = migration(repo, groups, [local])
        await migration.loadPreview(); await migration.migrate(approvedUserID: user)
        let otherUser = UUID(); let id = repo.rows[0].id
        repo.rows = [repo.row(TaskDraft(title: "server title", scheduledDate: day, sourceLocalTodoID: local.id, id: id, notes: "server memo"), assignedTo: otherUser)]
        await migration.migrate(approvedUserID: user)
        XCTAssertEqual(repo.rows[0].assignedTo, otherUser); XCTAssertEqual(repo.rows[0].notes, "server memo")
        XCTAssertTrue(repo.events.isEmpty); XCTAssertEqual(repo.attempts.count, 1)
    }
    func testMigrationGroupAndTaskSuccessCountsAreSeparate() async {
        let (_, repo, groups) = fixture()
        let group = TodoGroupSnapshot(id: UUID(), name: "legacy group", colorHex: "#FF0000", sortOrder: 0)
        let source = MemoryLegacySource(archive: LegacyTodoArchive(todos: [snapshot()], groups: [group]))
        let migration = LegacyTaskMigration(source: source, tasks: repo, groups: groups, links: TaskCalendarLinks(userID: user, inMemory: true))
        await migration.loadPreview(); XCTAssertEqual(migration.preview?.groups, 1)
        await migration.migrate(approvedUserID: user)
        XCTAssertEqual(migration.succeeded, 1); XCTAssertEqual(migration.groupsSucceeded, 1)
        XCTAssertEqual(migration.tasksFailed, 0); XCTAssertEqual(migration.groupsFailed, 0)
        XCTAssertEqual(groups.rows.first?.name, group.name); XCTAssertEqual(groups.rows.first?.colorHex, group.colorHex)
    }

    func testEventOnlyRetryAuthenticationFailureReturnsToAuthGate() async {
        let (_, repo, _) = fixture(); repo.eventAuthFailure = .refreshFailed
        var reported: CollaborationAuthError?
        let storage = MemoryTaskEventStorage()
        let queue = TaskEventQueue(repository: repo, storage: storage, sessionFailure: { reported = $0 })
        let event = TaskEventRequest(id: UUID(), taskID: UUID(), actorID: user, kind: .completed, actorDisplayNameSnapshot: "original name")
        await queue.enqueue([event])
        XCTAssertEqual(reported, .refreshFailed); XCTAssertEqual(queue.pending, [event]); XCTAssertTrue(repo.events.isEmpty)
    }

    func testCalendarSelectionDismissesImmediately() {
        var state = TaskCalendarPresentation(); state.open(selected: date)
        let next = date.addingTimeInterval(86400); state.choose(next)
        XCTAssertFalse(state.isPresented); XCTAssertEqual(state.selected, next)
    }
    func testSelectedDateChangesWithoutWaitingForFetch() {
        let (vm, repo, _) = fixture(); repo.failure = .network
        vm.selectedDate = date.addingTimeInterval(86400)
        XCTAssertEqual(vm.selectedDate, date.addingTimeInterval(86400)); XCTAssertFalse(vm.isLoading)
    }
    func testDeadlineDateSelectionKeepsEditorTimes() {
        var state = TaskCalendarPresentation(); state.open(selected: date)
        var timing = TaskDeadlineSelection(date: date, start: date, end: date.addingTimeInterval(3600))
        state.choose(date.addingTimeInterval(86400)); timing.date = state.selected
        XCTAssertFalse(state.isPresented); XCTAssertNotNil(timing.start); XCTAssertNotNil(timing.end)
    }
    private func editorDraft(_ timing: TaskDeadlineSelection) -> TaskDraft {
        let (_, repo, _) = fixture(); let original = repo.row(TaskDraft(title: "할 일", scheduledDate: day, notes: "메모"))
        return timing.draft(title: "할 일", day: date, group: nil, original: original, calendar: calendar)
    }
    func testEditorBothTimesUnspecifiedHasDateOnly() throws {
        let draft = editorDraft(TaskDeadlineSelection(date: date))
        XCTAssertEqual(draft.deadlineDate, day); XCTAssertNil(draft.startAt); XCTAssertNil(draft.deadlineAt)
        try draft.validate()
    }
    func testEditorOptionalStartOnly() throws {
        let draft = editorDraft(TaskDeadlineSelection(date: date, start: date))
        XCTAssertNotNil(draft.startAt); XCTAssertNil(draft.deadlineAt); try draft.validate()
    }
    func testEditorOptionalEndOnly() throws {
        let draft = editorDraft(TaskDeadlineSelection(date: date, end: date))
        XCTAssertNil(draft.startAt); XCTAssertNotNil(draft.deadlineAt); try draft.validate()
    }
    func testEditorClearingTimesDoesNotInventValues() throws {
        var timing = TaskDeadlineSelection(date: date, start: date, end: date.addingTimeInterval(3600))
        timing.start = nil; timing.end = nil
        let draft = editorDraft(timing); XCTAssertNil(draft.startAt); XCTAssertNil(draft.deadlineAt); try draft.validate()
    }
    func testEditorBothTimesValidateOrder() throws {
        try editorDraft(TaskDeadlineSelection(date: date, start: date, end: date.addingTimeInterval(3600))).validate()
        XCTAssertThrowsError(try editorDraft(TaskDeadlineSelection(date: date, start: date, end: date)).validate())
        XCTAssertThrowsError(try editorDraft(TaskDeadlineSelection(date: date, start: date, end: date.addingTimeInterval(-60))).validate())
    }
    func testEditorRemovingDeadlineClearsPayloadTimes() {
        var timing = TaskDeadlineSelection(date: date, start: date, end: date.addingTimeInterval(3600)); timing.date = nil
        let draft = editorDraft(timing)
        XCTAssertNil(draft.deadlineDate); XCTAssertNil(draft.startAt); XCTAssertNil(draft.deadlineAt)
    }
    func testEditorPreservesExistingMinuteAndAbsoluteTimestamp() {
        let (_, repo, _) = fixture()
        let precise = date.addingTimeInterval(7 * 60)
        let original = repo.row(TaskDraft(title: "할 일", scheduledDate: day, deadlineDate: day, startAt: precise))
        let timing = TaskDeadlineSelection(date: date, start: precise)
        let draft = timing.draft(title: "수정", day: date, group: nil, original: original, calendar: calendar)
        XCTAssertEqual(draft.startAt, precise); XCTAssertEqual(calendar.component(.minute, from: draft.startAt!), 7)
    }
    func testNormalEventDeliveryHasNoTransientStatusText() async {
        let (_, repo, _) = fixture(); let queue = TaskEventQueue(repository: repo)
        repo.onRecordEvent = { XCTAssertNil(queue.notice); XCTAssertEqual(queue.pending.count, 1) }
        await queue.enqueue([TaskEventRequest(id: UUID(), taskID: UUID(), actorID: user, kind: .created, actorDisplayNameSnapshot: "사용자")])
        XCTAssertNil(queue.notice); XCTAssertTrue(queue.pending.isEmpty)
    }
    func testEventDeliveryFailureStillShowsRetryNotice() async {
        let (_, repo, _) = fixture(); let queue = TaskEventQueue(repository: repo); repo.eventFailure = true
        await queue.enqueue([TaskEventRequest(id: UUID(), taskID: UUID(), actorID: user, kind: .created, actorDisplayNameSnapshot: "사용자")])
        XCTAssertNotNil(queue.notice); XCTAssertTrue(queue.deliveryFailed)
        repo.eventFailure = false; await queue.retry(); XCTAssertNil(queue.notice); XCTAssertFalse(queue.deliveryFailed)
    }
    func testCompletionIsOptimisticDuringServerRequestAndRefresh() async throws {
        let (vm, repo, _) = fixture(); let task = try await repo.createTask(TaskDraft(title: "완료", scheduledDate: day)); await vm.refresh()
        repo.beforeCompletion = { _ in
            XCTAssertEqual(vm.assigned.first?.status, .completed); XCTAssertEqual(vm.todayTasks.first?.status, .completed)
            await vm.refresh(); XCTAssertEqual(vm.assigned.first?.status, .completed)
        }
        await vm.toggle(task); XCTAssertEqual(vm.assigned.first?.status, .completed); XCTAssertNil(vm.errorMessage)
    }
    func testFailedOptimisticCompletionRollsBack() async throws {
        let (vm, repo, _) = fixture(); let task = try await repo.createTask(TaskDraft(title: "실패", scheduledDate: day)); await vm.refresh()
        repo.beforeCompletion = { _ in XCTAssertEqual(vm.assigned.first?.status, .completed); throw TaskServiceError.network }
        await vm.toggle(task)
        XCTAssertEqual(vm.assigned.first?.status, .open); XCTAssertEqual(vm.todayTasks.first?.status, .open)
        XCTAssertNotNil(vm.errorMessage); XCTAssertEqual(repo.rows.first?.status, .open); XCTAssertTrue(repo.events.isEmpty)
    }
    func testFailedOptimisticReopenRestoresCompletion() async throws {
        let (vm, repo, _) = fixture(); let task = try await repo.createTask(TaskDraft(title: "완료", scheduledDate: day, status: .completed, completedAt: date)); await vm.refresh()
        repo.beforeCompletion = { _ in XCTAssertEqual(vm.assigned.first?.status, .open); throw TaskServiceError.network }
        await vm.toggle(task)
        XCTAssertEqual(vm.assigned.first?.status, .completed); XCTAssertEqual(vm.assigned.first?.completedAt, date)
    }

    private func displayTask(_ title: String, order: Int, status: TaskStatus = .open, completed: Date? = nil, group: UUID? = nil, creator: UUID? = nil, id: UUID = UUID()) -> WorkTask {
        WorkTask(id: id, title: title, createdBy: creator ?? user, assignedTo: user, spaceID: nil, groupID: group,
            scheduledDate: day, deadlineDate: nil, deadlineAt: nil, startAt: nil, status: status, completedAt: completed,
            sourceLocalTodoID: nil, isArchived: false, createdAt: date.addingTimeInterval(Double(order)), updatedAt: date)
    }
    func testDisplaySortPlacesOpenBeforeCompleted() {
        let a = displayTask("A", order: 0), b = displayTask("B", order: 1), c = displayTask("C", order: 2, status: .completed, completed: date)
        XCTAssertEqual(TaskPresentationSorter.sort([c,b,a]).map(\.title), ["A","B","C"])
    }
    func testDisplaySortCompleteThenReopenRestoresBaseOrder() {
        var a = displayTask("A", order: 0); let b = displayTask("B", order: 1), c = displayTask("C", order: 2, status: .completed, completed: date.addingTimeInterval(-60))
        a.status = .completed; a.completedAt = date
        var sorted = TaskPresentationSorter.sort([a,b,c]); XCTAssertEqual(sorted.map(\.title), ["B","A","C"])
        let i = sorted.firstIndex { $0.id == a.id }!; sorted[i].status = .open; sorted[i].completedAt = nil
        XCTAssertEqual(TaskPresentationSorter.sort(sorted).map(\.title), ["A","B","C"])
    }
    func testDisplayCompletedDateDescendingAndNilLast() {
        let early = displayTask("early", order: 0, status: .completed, completed: date.addingTimeInterval(-60))
        let late = displayTask("late", order: 1, status: .completed, completed: date)
        let missing = displayTask("missing", order: -1, status: .completed)
        XCTAssertEqual(TaskPresentationSorter.sort([missing,early,late]).map(\.title), ["late","early","missing"])
    }
    func testDisplayTiesUseStableCreatedAtAndID() {
        let a = displayTask("A", order: 0, status: .completed, completed: date, id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let b = displayTask("B", order: 0, status: .completed, completed: date, id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        XCTAssertEqual(TaskPresentationSorter.sort([b,a]).map(\.title), ["A","B"])
        XCTAssertEqual(TaskPresentationSorter.sort([a,b]).map(\.title), ["A","B"])
    }
    func testDisplayOpenKeepsExistingCreatedOrderAndIsIdempotent() {
        var a = displayTask("A", order: 0); a.sortOrder = 100
        var b = displayTask("B", order: 1); b.sortOrder = 0
        let sorted = TaskPresentationSorter.sort([b,a])
        XCTAssertEqual(sorted.map(\.title), ["A","B"])
        XCTAssertEqual(TaskPresentationSorter.sort(sorted), sorted)
    }
    func testDisplayGroupsAndUngroupedSortIndependently() {
        let g1 = UUID(), g2 = UUID()
        let rows = [displayTask("done1", order: 0, status: .completed, group: g1), displayTask("done2", order: 1, status: .completed, group: g2), displayTask("noneDone", order: 2, status: .completed),
                    displayTask("open2", order: 3, group: g2), displayTask("open1", order: 4, group: g1), displayTask("noneOpen", order: 5)]
        let sorted = TaskPresentationSorter.sort(rows)
        XCTAssertEqual(sorted.filter { $0.groupID == g1 }.map(\.title), ["open1","done1"])
        XCTAssertEqual(sorted.filter { $0.groupID == g2 }.map(\.title), ["open2","done2"])
        XCTAssertEqual(sorted.filter { $0.groupID == nil }.map(\.title), ["noneOpen","noneDone"])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: rows.map { ($0.id,$0.groupID) }), Dictionary(uniqueKeysWithValues: sorted.map { ($0.id,$0.groupID) }))
    }
    func testOptimisticSortAndRefreshKeepSameOrderFullAndMini() async {
        let (vm, repo, _) = fixture()
        let a = displayTask("A", order: 0), b = displayTask("B", order: 1), c = displayTask("C", order: 2, status: .completed, completed: date.addingTimeInterval(-60))
        repo.rows = [a,b,c]; repo.completionClock = { self.date }; await vm.refresh()
        repo.beforeCompletion = { _ in
            XCTAssertEqual(vm.assigned.map(\.title), ["B","A","C"]); XCTAssertEqual(vm.todayTasks.map(\.title), ["B","A","C"])
            await vm.refresh(); XCTAssertEqual(vm.assigned.map(\.title), ["B","A","C"])
        }
        await vm.toggle(a); await vm.refresh()
        XCTAssertEqual(vm.assigned.map(\.title), ["B","A","C"]); XCTAssertEqual(vm.todayTasks.map(\.title), ["B","A","C"])
        repo.beforeCompletion = { _ in XCTAssertEqual(vm.assigned.map(\.title), ["A","B","C"]) }
        await vm.toggle(vm.assigned.first { $0.id == a.id }!)
        await vm.refresh(); XCTAssertEqual(vm.assigned.map(\.title), ["A","B","C"])
        XCTAssertNil(vm.assigned.first?.completedAt)
    }
    func testReceivedTasksUseSameOptimisticAndRefreshSorter() async {
        let (vm, repo, _) = fixture(); let other = UUID()
        let a = displayTask("received", order: 0, creator: other), b = displayTask("mine", order: 1), c = displayTask("old received", order: 2, status: .completed, completed: date.addingTimeInterval(-60), creator: other)
        repo.rows = [a,b,c]; repo.completionClock = { self.date }; await vm.refresh()
        repo.beforeCompletion = { _ in
            XCTAssertEqual(vm.todayTasks.map(\.title), ["mine","received","old received"])
            XCTAssertEqual(vm.received.map(\.title), ["received","old received"])
        }
        await vm.toggle(a); await vm.refresh()
        XCTAssertEqual(vm.todayTasks.map(\.title), ["mine","received","old received"])
        XCTAssertEqual(vm.received.map(\.title), ["received","old received"])
        repo.beforeCompletion = nil
        await vm.toggle(vm.received.first!)
        XCTAssertEqual(vm.todayTasks.map(\.title), ["received","mine","old received"])
        XCTAssertEqual(vm.received.first?.status, .open)
    }
    func testFailedCompletionRestoresDisplayPosition() async {
        let (vm, repo, _) = fixture(); let a = displayTask("A", order: 0), b = displayTask("B", order: 1)
        repo.rows = [a,b]; await vm.refresh()
        repo.beforeCompletion = { _ in XCTAssertEqual(vm.assigned.map(\.title), ["B","A"]); throw TaskServiceError.network }
        await vm.toggle(a)
        XCTAssertEqual(vm.assigned.map(\.title), ["A","B"]); XCTAssertEqual(vm.todayTasks.map(\.title), ["A","B"])
        XCTAssertNotNil(vm.errorMessage)
    }

    func testAlreadyImportedUnsupportedLegacyIsReusedBySourceIdentity() async {
        let (_, repo, groups) = fixture(); let t = snapshot(title: "unsupported", repeatRule: "unknown")
        var draft = LegacyTaskMigration.draft(t, groupID: nil, calendar: calendar); draft.title = "server modified"
        repo.rows = [repo.row(draft)]
        let (m, _) = migration(repo, groups, [t]); await m.loadPreview()
        XCTAssertEqual(m.preview?.alreadyImported, 1); XCTAssertEqual(m.preview?.pendingTodos, 0)
        XCTAssertEqual(m.preview?.importable, 0); await m.migrate(approvedUserID: user)
        XCTAssertEqual(m.result?.todosSucceeded, 1); XCTAssertTrue(repo.attempts.isEmpty)
        XCTAssertEqual(repo.rows[0].title, "server modified")
    }
    func testMigrationEmptyPreviewAndResult() async {
        let (_, repo, groups) = fixture(); let (m, _) = migration(repo, groups, [])
        await m.loadPreview(); XCTAssertEqual(m.preview?.totalTodos, 0); XCTAssertEqual(m.preview?.importable, 0)
        XCTAssertTrue(repo.attempts.isEmpty); await m.migrate(approvedUserID: user)
        XCTAssertEqual(m.result?.todosSucceeded, 0); XCTAssertEqual(m.result?.todosTotal, 0)
    }
    func testMigrationPreviewSeventyOfOneHundredAlreadyImported() async {
        let (_, repo, groups) = fixture(); let locals = (0..<100).map { snapshot(title: "item \($0)") }
        repo.rows = locals.prefix(70).map { repo.row(LegacyTaskMigration.draft($0, groupID: nil, calendar: calendar)) }
        let (m, _) = migration(repo, groups, locals); await m.loadPreview()
        XCTAssertEqual(m.preview?.totalTodos, 100); XCTAssertEqual(m.preview?.alreadyImported, 70)
        XCTAssertEqual(m.preview?.importable, 30); XCTAssertTrue(repo.attempts.isEmpty)
        await m.migrate(approvedUserID: user)
        XCTAssertEqual(repo.rows.count, 100); XCTAssertEqual(repo.attempts.count, 30)
    }
    func testMigrationPreservesCompletionWithoutInventingTime() async {
        let (_, repo, groups) = fixture()
        let missing = snapshot(title: "unknown completion", isCompleted: true)
        let known = snapshot(title: "known completion", isCompleted: true, completedAt: date.addingTimeInterval(-86400))
        let open = snapshot(title: "open", completedAt: date)
        let (m, _) = migration(repo, groups, [missing, known, open]); await m.loadPreview()
        XCTAssertEqual(m.preview?.missingCompletionTimes, 1); await m.migrate(approvedUserID: user)
        let unknown = repo.rows.first { $0.title == missing.title }; XCTAssertEqual(unknown?.status, .completed); XCTAssertNil(unknown?.completedAt)
        XCTAssertEqual(repo.rows.first { $0.title == known.title }?.completedAt, known.completedAt)
        XCTAssertEqual(repo.rows.first { $0.title == open.title }?.status, .open)
        XCTAssertNil(repo.rows.first { $0.title == open.title }?.completedAt)
    }
    func testMigrationAllFourDeadlineVariantsAndNotes() async {
        let (_, repo, groups) = fixture()
        let locals = (0..<4).map { index -> TodoSnapshot in
            var t = snapshot(title: "variant \(index)", notes: "memo \(index)")
            t.deadlineDate = date
            if index == 1 || index == 3 { t.startDateTime = date.addingTimeInterval(3600) }
            if index == 2 || index == 3 { t.deadlineDateTime = date.addingTimeInterval(7200) }
            return t
        }
        let (m, _) = migration(repo, groups, locals); await m.loadPreview(); await m.migrate(approvedUserID: user)
        for t in locals {
            let saved = repo.rows.first { $0.sourceLocalTodoID == t.id }
            XCTAssertEqual(saved?.deadlineDate, day); XCTAssertEqual(saved?.startAt, t.startDateTime)
            XCTAssertEqual(saved?.deadlineAt, t.deadlineDateTime); XCTAssertEqual(saved?.notes, t.notes)
            XCTAssertEqual(saved?.createdBy, user); XCTAssertEqual(saved?.assignedTo, user); XCTAssertNil(saved?.spaceID)
        }
    }
    func testSameNameLegacyGroupsKeepSeparateIdentityAcrossRestart() async throws {
        let (_, repo, groups) = fixture()
        let a = TodoGroupSnapshot(id: UUID(), name: "same", colorHex: "#FF0000", sortOrder: 1)
        let b = TodoGroupSnapshot(id: UUID(), name: "same", colorHex: "#0000FF", sortOrder: 2)
        let x = snapshot(title: "a", groupID: a.id)
        let y = snapshot(title: "b", groupID: b.id)
        let source = MemoryLegacySource(archive: LegacyTodoArchive(todos: [x,y], groups: [a,b]))
        func make() -> LegacyTaskMigration { LegacyTaskMigration(source: source, tasks: repo, groups: groups, calendar: calendar, links: TaskCalendarLinks(userID: user, inMemory: true)) }
        let first = make(); await first.loadPreview(); await first.migrate(approvedUserID: user)
        XCTAssertEqual(groups.rows.count, 2)
        let aid = MigrationIdentity.id(kind: "group", userID: user, sourceID: a.id)
        let bid = MigrationIdentity.id(kind: "group", userID: user, sourceID: b.id)
        XCTAssertNotEqual(aid, bid); XCTAssertEqual(repo.rows.first { $0.title == "a" }?.groupID, aid)
        XCTAssertEqual(repo.rows.first { $0.title == "b" }?.groupID, bid)
        XCTAssertEqual(groups.rows.first { $0.id == aid }?.sortOrder, 1)
        try await groups.rename(id: aid, name: "server edit", colorHex: "#FFFFFF")
        let retry = make(); await retry.loadPreview(); await retry.migrate(approvedUserID: user)
        XCTAssertEqual(groups.rows.count, 2); XCTAssertEqual(groups.rows.first { $0.id == aid }?.name, "server edit")
        XCTAssertEqual(groups.rows.first { $0.id == aid }?.colorHex, "#FFFFFF"); XCTAssertEqual(repo.attempts.count, 2)
    }
    func testFailedGroupDoesNotCreateOrphanTask() async {
        let (_, repo, groups) = fixture(); groups.failure = .network
        let group = TodoGroupSnapshot(id: UUID(), name: "g", colorHex: nil, sortOrder: 0)
        let t = snapshot(groupID: group.id)
        let source = MemoryLegacySource(archive: LegacyTodoArchive(todos: [t], groups: [group]))
        let m = LegacyTaskMigration(source: source, tasks: repo, groups: groups, calendar: calendar, links: TaskCalendarLinks(userID: user, inMemory: true))
        await m.loadPreview(); await m.migrate(approvedUserID: user)
        XCTAssertTrue(repo.rows.isEmpty); XCTAssertEqual(m.result?.groupsFailed, 1); XCTAssertEqual(m.result?.todosFailed, 1)
        groups.failure = nil; await m.migrate(approvedUserID: user)
        XCTAssertEqual(repo.rows.count, 1); XCTAssertNotNil(repo.rows[0].groupID)
    }
    func testPartialMigrationRestartImportsOnlyMissingRows() async {
        let (_, repo, groups) = fixture(); let locals = [snapshot(title: "a"), snapshot(title: "b"), snapshot(title: "c")]
        repo.createFailure = { $0.title == "b" ? TaskServiceError.network : nil }
        let (first, _) = migration(repo, groups, locals); await first.loadPreview(); await first.migrate(approvedUserID: user)
        XCTAssertEqual(first.result?.todosSucceeded, 2); XCTAssertEqual(first.result?.todosFailed, 1)
        XCTAssertEqual(repo.rows.count, 2); repo.rows[0].title = "server edited"; repo.rows[0].notes = "server memo"
        repo.createFailure = nil; repo.attempts = []
        let (restart, _) = migration(repo, groups, locals); await restart.loadPreview()
        XCTAssertEqual(restart.preview?.alreadyImported, 2); XCTAssertEqual(restart.preview?.importable, 1)
        await restart.migrate(approvedUserID: user)
        XCTAssertEqual(repo.rows.count, 3); XCTAssertEqual(repo.attempts.count, 1)
        XCTAssertEqual(repo.rows[0].title, "server edited"); XCTAssertEqual(repo.rows[0].notes, "server memo")
    }
    func testFailedPreviewClearsEarlierApprovalSource() async {
        let (_, repo, groups) = fixture(); let (m, source) = migration(repo, groups, [snapshot()])
        await m.loadPreview(); XCTAssertNotNil(m.preview)
        source.failure = TaskServiceError.unavailable; await m.loadPreview(); XCTAssertNil(m.preview)
        await m.migrate(approvedUserID: user); XCTAssertTrue(repo.rows.isEmpty); XCTAssertTrue(repo.attempts.isEmpty)
    }
    func testChangedSessionBetweenPreviewAndApprovalBlocksImport() async {
        let (_, repo, groups) = fixture(); var active = user; var stopped = false
        let source = MemoryLegacySource(archive: LegacyTodoArchive(todos: [snapshot()], groups: []))
        let m = LegacyTaskMigration(source: source, tasks: repo, groups: groups, links: TaskCalendarLinks(userID: user, inMemory: true), validateSession: { expected in
            guard active == expected else { throw CollaborationAuthError.sessionMissing }
        }, sessionFailure: { _ in stopped = true })
        await m.loadPreview(); active = UUID(); await m.migrate(approvedUserID: user)
        XCTAssertTrue(stopped); XCTAssertTrue(repo.attempts.isEmpty); XCTAssertEqual(m.result?.stoppedForSession, true)
    }
    func testServerJWTFailureStopsImportWithoutTreatingOtherDBErrorsAsLogout() async {
        for code in ["PGRST301", "PGRST302", "PGRST303"] {
            let (_, repo, groups) = fixture(); var notified = false
            repo.createFailure = { _ in PostgrestError(code: code, message: "authentication failed") }
            let source = MemoryLegacySource(archive: LegacyTodoArchive(todos: [snapshot(), snapshot()], groups: []))
            let m = LegacyTaskMigration(source: source, tasks: repo, groups: groups, links: TaskCalendarLinks(userID: user, inMemory: true), sessionFailure: { _ in notified = true })
            await m.loadPreview(); await m.migrate(approvedUserID: user)
            XCTAssertEqual(repo.attempts.count, 1); XCTAssertTrue(notified); XCTAssertEqual(m.result?.stoppedForSession, true)
        }
        for code in ["23505", "23503", "23514", "42501", "PGRST300"] {
            XCTAssertNil(MigrationDiagnostics.sessionFailure(PostgrestError(code: code, message: "not a user JWT failure")))
        }
    }
    func testSessionLossDuringSourceLookupPreventsFollowingInsert() async {
        let (_, repo, groups) = fixture(); var active = true
        let source = MemoryLegacySource(archive: LegacyTodoArchive(todos: [snapshot()], groups: []))
        let m = LegacyTaskMigration(source: source, tasks: repo, groups: groups, links: TaskCalendarLinks(userID: user, inMemory: true), validateSession: { _ in
            guard active else { throw CollaborationAuthError.sessionMissing }
        })
        await m.loadPreview(); repo.onImportedRead = { active = false }
        await m.migrate(approvedUserID: user)
        XCTAssertTrue(repo.attempts.isEmpty); XCTAssertTrue(repo.rows.isEmpty)
        XCTAssertEqual(m.result?.stoppedForSession, true)
    }
    func testSessionInvalidationMidImportStopsNextRequest() async {
        let (_, repo, groups) = fixture(); var active = true
        repo.onCreate = { active = false }
        let source = MemoryLegacySource(archive: LegacyTodoArchive(todos: [snapshot(title: "a"), snapshot(title: "b")], groups: []))
        let m = LegacyTaskMigration(source: source, tasks: repo, groups: groups, links: TaskCalendarLinks(userID: user, inMemory: true), validateSession: { _ in
            guard active else { throw CollaborationAuthError.refreshFailed }
        })
        await m.loadPreview(); await m.migrate(approvedUserID: user)
        XCTAssertEqual(repo.rows.count, 1); XCTAssertEqual(repo.attempts.count, 1)
        XCTAssertEqual(m.result?.stoppedForSession, true); XCTAssertEqual(source.archive.todos.count, 2)
    }
    func testLocalCalendarLinkRetryPreservesNewerDeviceLink() async throws {
        let (_, repo, groups) = fixture(); var t = snapshot(); t.linkedCalendarEventID = "old-event"
        let links = TaskCalendarLinks(userID: user, inMemory: true)
        let source = MemoryLegacySource(archive: LegacyTodoArchive(todos: [t], groups: []))
        let m = LegacyTaskMigration(source: source, tasks: repo, groups: groups, calendar: calendar, links: links)
        await m.loadPreview(); await m.migrate(approvedUserID: user)
        let id = repo.rows[0].id; XCTAssertEqual(links.identifier(taskID: id), "old-event")
        try links.set(taskID: id, identifier: "new-event"); await m.migrate(approvedUserID: user)
        XCTAssertEqual(links.identifier(taskID: id), "new-event")
        let p = try payload(repo.attempts[0]); XCTAssertNil(p["linked_calendar_event_id"])
    }
    func testMigrationRefreshUsesServerForFullMiniMissedAndCalendar() async {
        let (vm, repo, groups) = fixture()
        let group = TodoGroupSnapshot(id: UUID(), name: "imported", colorHex: nil, sortOrder: 0)
        let today = snapshot(groupID: group.id)
        let yesterday = snapshot(title: "missed", on: date.addingTimeInterval(-86400))
        let source = MemoryLegacySource(archive: LegacyTodoArchive(todos: [today,yesterday], groups: [group]))
        let m = LegacyTaskMigration(source: source, tasks: repo, groups: groups, calendar: calendar, links: TaskCalendarLinks(userID: user, inMemory: true))
        await m.loadPreview(); await m.migrate(approvedUserID: user); await vm.refresh()
        XCTAssertEqual(vm.assigned.count, 1); XCTAssertEqual(vm.todayTasks.count, 1)
        XCTAssertEqual(vm.missed.map(\.title), ["missed"])
        XCTAssertTrue(vm.overdueDays.contains(calendar.startOfDay(for: yesterday.date)))
        XCTAssertEqual(vm.groups.count, 1)
    }

}

@MainActor private final class MemoryTaskRepository: TaskRepository {
    let userID: UUID
    var rows: [WorkTask] = []
    var events: [TaskEventRequest] = []
    var attempts: [TaskDraft] = []
    var failure: TaskServiceError?
    var names: [UUID: String] = [:]
    var directFailure: Error?
    var directAfterInsertFailure = false
    var beforeDirect: (() async -> Void)?
    var eventFailure = false
    var eventAuthFailure: CollaborationAuthError?
    var completionClock: () -> Date = Date.init
    var beforeCompletion: ((TaskStatus) async throws -> Void)?
    var onRecordEvent: (() -> Void)?
    var onRead: (() -> Void)?
    var onImportedRead: (() -> Void)?
    var onCreate: (() -> Void)?
    var createFailure: ((TaskDraft) -> Error?)?
    init(userID: UUID) { self.userID = userID }
    func row(_ d: TaskDraft, createdBy: UUID? = nil, assignedTo: UUID? = nil) -> WorkTask {
        WorkTask(id: d.id, title: d.title, createdBy: createdBy ?? userID, assignedTo: assignedTo ?? userID, spaceID: nil, groupID: d.groupID, scheduledDate: d.scheduledDate, deadlineDate: d.deadlineDate, deadlineAt: d.deadlineAt, startAt: d.startAt, status: d.status, completedAt: d.completedAt, sourceLocalTodoID: d.sourceLocalTodoID, isArchived: false, createdAt: Date(), updatedAt: Date(), notes: d.normalizedNotes)
    }
    func tasks(_ query: TaskQuery) async throws -> [WorkTask] {
        if let failure { throw failure }; onRead?()
        return rows.filter { t in
            guard !t.isArchived else { return false }
            switch query {
            case .assigned(let from, let to): return t.assignedTo == userID && (t.scheduledDate.map { $0 >= from } == true) && (t.scheduledDate.map { $0 <= to } == true)
            case .created(let from, let to): return t.createdBy == userID && (t.scheduledDate.map { $0 >= from } == true) && (t.scheduledDate.map { $0 <= to } == true)
            case .received(let from, let to): return t.assignedTo == userID && t.createdBy != userID && (t.scheduledDate.map { $0 >= from } == true) && (t.scheduledDate.map { $0 <= to } == true)
            case .sent(let from, let to): return t.createdBy == userID && t.assignedTo != userID && (t.scheduledDate.map { $0 >= from } == true) && (t.scheduledDate.map { $0 <= to } == true)
            case .overdue(let from, let before): return t.assignedTo == userID && t.status == .open && (t.scheduledDate.map { $0 >= from } == true) && (t.scheduledDate.map { $0 < before } == true)
            case .someday: return t.assignedTo == userID && t.scheduledDate == nil
            case .allOverdue(let before): return t.assignedTo == userID && t.status == .open && (t.scheduledDate.map { $0 < before } == true)
            case .allInSpace(let id): return t.spaceID == id
            case .space(let id, let from, let to): return t.spaceID == id && (t.scheduledDate.map { $0 >= from } == true) && (t.scheduledDate.map { $0 <= to } == true)
            }
        }
    }
    func createTask(_ draft: TaskDraft) async throws -> WorkTask {
        attempts.append(draft); if let error = createFailure?(draft) { throw error }; if let failure { throw failure }; try draft.validate()
        if let source = draft.sourceLocalTodoID, let existing = rows.first(where: { $0.sourceLocalTodoID == source }) { return existing }
        if let existing = rows.first(where: { $0.id == draft.id }) { return existing }
        let t = row(draft); rows.append(t); onCreate?(); return t
    }
    func createDirectTask(_ draft: TaskDraft, receiverID: UUID) async throws -> WorkTask {
        attempts.append(draft); await beforeDirect?()
        if let directFailure { throw directFailure }
        try DirectTaskPolicy.validate(draft, receiver: receiverID, sender: userID)
        if let row = rows.first(where: { $0.id == draft.id }) { return row }
        let saved = row(draft, assignedTo: receiverID); rows.append(saved)
        if directAfterInsertFailure { throw URLError(.timedOut) }; return saved
    }
    func receivedIncompleteCount() async throws -> Int {
        if let failure { throw failure }
        return rows.filter { $0.assignedTo == userID && $0.createdBy != userID && $0.status == .open && !$0.isArchived && !$0.isRecurrenceTemplate }.count
    }
    func participantNames(ids: Set<UUID>) async throws -> [UUID: String] { names.filter { ids.contains($0.key) } }
    func updateTask(id: UUID, draft: TaskDraft) async throws -> WorkTask {
        if let failure { throw failure }; guard let index = rows.firstIndex(where: { $0.id == id }) else { throw TaskServiceError.notFound }
        _ = try SupabaseTaskRepository.contentUpdatePayload(task: rows[index], draft: draft, userID: userID)
        rows[index].title = draft.title; rows[index].notes = draft.normalizedNotes
        rows[index].groupID = draft.groupID; rows[index].deadlineDate = draft.deadlineDate
        rows[index].startAt = draft.startAt; rows[index].deadlineAt = draft.deadlineAt
        rows[index].estimatedMinutes = draft.estimatedMinutes; rows[index].priority = draft.priority
        return rows[index]
    }
    func completeTask(id: UUID) async throws -> WorkTask { try await beforeCompletion?(.completed); return try status(id, .completed) }
    func reopenTask(id: UUID) async throws -> WorkTask { try await beforeCompletion?(.open); return try status(id, .open) }
    private func status(_ id: UUID, _ status: TaskStatus) throws -> WorkTask {
        if let failure { throw failure }; let index = rows.firstIndex { $0.id == id }!
        guard rows[index].permission(userID: userID) != .readOnly else { throw TaskServiceError.permission }
        rows[index].status = status; rows[index].completedAt = status == .completed ? completionClock() : nil; return rows[index]
    }
    func fetchTask(id: UUID) async throws -> WorkTask? { if let failure { throw failure }; return rows.first { $0.id == id } }
    func importedTask(sourceLocalTodoID: UUID) async throws -> WorkTask? { if let failure { throw failure }; onImportedRead?(); return rows.first { $0.sourceLocalTodoID == sourceLocalTodoID } }
    func archiveTask(id: UUID) async throws { rows.removeAll { $0.id == id } }
    func recordEvent(_ event: TaskEventRequest) async throws { onRecordEvent?(); if let eventAuthFailure { throw eventAuthFailure }; if eventFailure { throw TaskServiceError.network }; if !events.contains(where: { $0.id == event.id }) { events.append(event) } }
}
@MainActor private final class MemoryGroupRepository: GroupRepository {
    let userID: UUID
    var rows: [TaskGroup] = []
    var failure: TaskServiceError?
    init(userID: UUID) { self.userID = userID }
    func personalGroups() async throws -> [TaskGroup] { rows }
    func groups(spaceID: UUID) async throws -> [TaskGroup] { rows.filter { $0.spaceID == spaceID } }
    func create(id: UUID, name: String, colorHex: String?, sortOrder: Int) async throws -> TaskGroup {
        if let failure { throw failure }
        if let existing = rows.first(where: { $0.id == id }) { return existing }
        let row = TaskGroup(id: id, name: name, colorHex: colorHex, ownerID: userID, spaceID: nil, sortOrder: sortOrder, createdAt: Date(), updatedAt: Date()); rows.append(row); return row
    }
    func rename(id: UUID, name: String, colorHex: String?) async throws { let i = rows.firstIndex { $0.id == id }!; rows[i].name = name; rows[i].colorHex = colorHex }
    func delete(id: UUID) async throws { rows.removeAll { $0.id == id } }
    func reorder(ids: [UUID]) async throws { for (i, id) in ids.enumerated() { let index = rows.firstIndex { $0.id == id }!; rows[index].sortOrder = i } }
    func fetchGroup(id: UUID) async throws -> TaskGroup? { rows.first { $0.id == id } }
}
@MainActor private final class MemoryLegacySource: LegacyTodoSource {
    let archive: LegacyTodoArchive
    init(archive: LegacyTodoArchive) { self.archive = archive }
    var failure: Error?
    func read() throws -> LegacyTodoArchive { if let failure { throw failure }; return archive }
}

@MainActor private final class ServerFakeAccount: AuthRepository, CollaborationProfileRepository {
    var restored: AuthenticatedUser?
    var row: CollaborationProfile?
    func restoreSession() async throws -> AuthenticatedUser? { restored }
    func signUp(_ request: SignupRequest) async throws -> SignupResult { .awaitingConfirmation }
    func signIn(email: String, password: String) async throws -> AuthenticatedUser { guard let restored else { throw CollaborationAuthError.invalidCredentials }; return restored }
    func signOut() async throws { restored = nil }
    func profile(userID: UUID) async throws -> CollaborationProfile? { row }
    func updateDisplayName(_ name: String, userID: UUID) async throws -> CollaborationProfile { guard let row else { throw CollaborationAuthError.profileMissing }; return row }
}

@MainActor private final class FailingEventStorage: TaskEventStorage {
    var fails = true
    func load() throws -> [TaskEventRequest] { [] }
    func save(_ events: [TaskEventRequest]) throws { if fails { throw TaskServiceError.unavailable } }
}

extension ServerTaskTests {
    private func deliveryFixture(source: WorkTask? = nil) -> (TaskDeliveryModel, MemoryTaskRepository, DeliveryFriends) {
        let repo = MemoryTaskRepository(userID: user), friends = DeliveryFriends(userID: user)
        let composer = TaskDeliveryModel(tasks: repo, friendships: friends, events: TaskEventQueue(repository: repo), receiver: friends.friend,
            source: source, calendar: calendar, today: { self.date }, name: { "Sender Snapshot" }, sessionFailure: { _ in })
        composer.title = source?.title ?? "전달"; return (composer, repo, friends)
    }
    func testDirectFriendDeliveryCreatesOneRowAndTwoEvents() async {
        let (vm, repo, friends) = deliveryFixture(); let ok = await vm.send(); XCTAssertTrue(ok)
        XCTAssertEqual(repo.rows.count, 1); XCTAssertEqual(repo.rows[0].createdBy, user); XCTAssertEqual(repo.rows[0].assignedTo, friends.friend.userID)
        XCTAssertEqual(repo.rows[0].scheduledDate, day); XCTAssertNil(repo.rows[0].groupID); XCTAssertNil(repo.rows[0].spaceID)
        XCTAssertEqual(repo.rows[0].status, .open); XCTAssertNil(repo.rows[0].completedAt)
        XCTAssertEqual(repo.events.map(\.kind), [.created, .assigned]); XCTAssertEqual(Set(repo.events.compactMap(\.actorDisplayNameSnapshot)), ["Sender Snapshot"])
        XCTAssertEqual(repo.events[1].metadata["receiver_display_name"], friends.friend.displayName)
    }
    func testDirectNonFriendBlocked() async {
        let (vm, repo, friends) = deliveryFixture(); friends.state = .available
        let ok = await vm.send(); XCTAssertFalse(ok); XCTAssertTrue(repo.rows.isEmpty); XCTAssertEqual(vm.errorMessage, "더 이상 친구가 아닙니다.")
    }
    func testDirectFriendshipDeletedAfterSheetLoadBlocked() async {
        let (vm, repo, friends) = deliveryFixture(); await vm.loadFriends(); friends.state = .available
        let ok = await vm.send(); XCTAssertFalse(ok); XCTAssertTrue(repo.rows.isEmpty); XCTAssertEqual(friends.relationshipReads, 1)
    }
    func testDirectPendingRequestDoesNotGrantDeliveryPermission() async {
        let (vm, repo, friends) = deliveryFixture()
        friends.state = .outgoing(FriendRequest(id: UUID(), senderID: user, receiverID: friends.friend.userID, status: .pending, createdAt: date, updatedAt: date, respondedAt: nil))
        let ok = await vm.send(); XCTAssertFalse(ok); XCTAssertTrue(repo.rows.isEmpty)
    }
    func testDirectBlankTitleBlocked() async {
        let (vm, repo, _) = deliveryFixture(); vm.title = "  "
        let ok = await vm.send(); XCTAssertFalse(ok); XCTAssertTrue(repo.rows.isEmpty)
    }
    func testDirectSelfAssignmentIsNotDelivery() throws {
        XCTAssertThrowsError(try DirectTaskPolicy.validate(TaskDraft(title: "x", scheduledDate: day), receiver: user, sender: user))
    }
    func testDirectPayloadUsesExistingTasksContract() throws {
        let receiver = UUID(), draft = TaskDraft(title: "x", scheduledDate: day, deadlineDate: day)
        let p = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SupabaseTaskRepository.directPayload(draft, sender: user, receiver: receiver))) as! [String: Any]
        XCTAssertEqual(p["created_by"] as? String, user.uuidString); XCTAssertEqual(p["assigned_to"] as? String, receiver.uuidString)
        for key in ["space_id", "group_id", "recurrence_id", "source_local_todo_id", "completed_at", "start_at", "deadline_at"] { XCTAssertTrue(p[key] is NSNull, key) }
        XCTAssertEqual(p["is_recurrence_template"] as? Bool, false); XCTAssertEqual(p["status"] as? String, "open")
        XCTAssertEqual(p["deadline_date"] as? String, day.value)
    }
    func testDirectCopyPreservesNotesAndAllDeadlineFields() throws {
        let repo = MemoryTaskRepository(userID: user)
        var source = repo.row(TaskDraft(title: "原本", scheduledDate: day, groupID: UUID(), deadlineDate: day, startAt: date, deadlineAt: date.addingTimeInterval(3600), notes: "memo"))
        source.recurrenceID = UUID()
        let copy = try DirectTaskPolicy.draft(title: "ignored", today: day, deadline: nil, source: source, userID: user, id: UUID())
        XCTAssertEqual(copy.title, source.title); XCTAssertEqual(copy.notes, source.notes); XCTAssertEqual(copy.startAt, source.startAt); XCTAssertEqual(copy.deadlineAt, source.deadlineAt); XCTAssertEqual(copy.deadlineDate, source.deadlineDate)
        XCTAssertNil(copy.groupID); XCTAssertNil(copy.recurrenceID); XCTAssertNil(copy.sourceLocalTodoID); XCTAssertFalse(copy.isRecurrenceTemplate); XCTAssertNotEqual(copy.id, source.id)
    }
    func testDirectCopyPreservesOriginalPersonalTask() async {
        let originalRepo = MemoryTaskRepository(userID: user), original = originalRepo.row(TaskDraft(title: "original", scheduledDate: day, groupID: UUID()))
        let (vm, repo, _) = deliveryFixture(source: original); repo.rows = [original]
        let ok = await vm.send(); XCTAssertTrue(ok); XCTAssertEqual(repo.rows.count, 2); XCTAssertEqual(repo.rows.first, original)
        XCTAssertNil(repo.rows.last?.groupID); XCTAssertEqual(repo.rows.first?.status, .open)
    }
    func testDirectTemplateCannotBeCopiedButInstanceCan() throws {
        let repo = MemoryTaskRepository(userID: user); var source = repo.row(TaskDraft(title: "x", scheduledDate: day))
        source.isRecurrenceTemplate = true
        XCTAssertThrowsError(try DirectTaskPolicy.draft(title: "x", today: day, deadline: nil, source: source, userID: user, id: UUID()))
        source.isRecurrenceTemplate = false; source.recurrenceID = UUID()
        let copy = try DirectTaskPolicy.draft(title: "x", today: day, deadline: nil, source: source, userID: user, id: UUID()); XCTAssertNil(copy.recurrenceID)
    }
    func testDirectCannotCopyReceivedOrSentTask() throws {
        let repo = MemoryTaskRepository(userID: user)
        for source in [repo.row(TaskDraft(title: "x", scheduledDate: day), createdBy: UUID()), repo.row(TaskDraft(title: "x", scheduledDate: day), assignedTo: UUID())] {
            XCTAssertThrowsError(try DirectTaskPolicy.draft(title: "x", today: day, deadline: nil, source: source, userID: user, id: UUID()))
        }
    }
    func testDirectRetryUsesSameCommandUUID() async {
        let (vm, repo, _) = deliveryFixture(); repo.directFailure = TaskServiceError.network
        let first = await vm.send(); XCTAssertFalse(first); let id = repo.attempts.last?.id
        repo.directFailure = nil; let second = await vm.send(); XCTAssertTrue(second); XCTAssertEqual(repo.rows.first?.id, id); XCTAssertEqual(repo.rows.count, 1)
    }
    func testDirectTimeoutCommittedRowReusedEvenAfterFriendDeletion() async {
        let (vm, repo, friends) = deliveryFixture(); repo.directAfterInsertFailure = true
        let first = await vm.send(); XCTAssertFalse(first); XCTAssertEqual(repo.rows.count, 1)
        friends.state = .available; vm.title = "changed after timeout"; repo.directAfterInsertFailure = false
        let second = await vm.send(); XCTAssertTrue(second); XCTAssertEqual(repo.rows.count, 1); XCTAssertEqual(repo.rows[0].title, "전달")
    }
    func testDirectMultipleClicksWhileRequestSuspendedCreateOnce() async {
        let (vm, repo, _) = deliveryFixture(); var secondResult = true
        repo.beforeDirect = { secondResult = await vm.send() }
        let first = await vm.send(); XCTAssertTrue(first); XCTAssertFalse(secondResult); XCTAssertEqual(repo.rows.count, 1)
        let again = await vm.send(); XCTAssertFalse(again); XCTAssertEqual(repo.rows.count, 1)
    }
    func testDirectEventFailureDoesNotUndoDeliveredTask() async {
        let (vm, repo, _) = deliveryFixture(); repo.eventFailure = true
        let ok = await vm.send(); XCTAssertTrue(ok); XCTAssertEqual(repo.rows.count, 1); XCTAssertTrue(vm.delivered)
        XCTAssertTrue(repo.events.isEmpty)
    }
    func testDirectEventsPersistAndRetryWithoutTaskDuplication() async {
        let repo = MemoryTaskRepository(userID: user), friends = DeliveryFriends(userID: user), storage = MemoryTaskEventStorage()
        repo.eventFailure = true; let queue = TaskEventQueue(repository: repo, storage: storage)
        let vm = TaskDeliveryModel(tasks: repo, friendships: friends, events: queue, receiver: friends.friend, source: nil, calendar: calendar, today: { self.date }, name: { "Original" }, sessionFailure: { _ in })
        vm.title = "x"; let ok = await vm.send(); XCTAssertTrue(ok); XCTAssertEqual(queue.pending.count, 2)
        let ids = queue.pending.map(\.id); repo.eventFailure = false
        let restored = TaskEventQueue(repository: repo, storage: storage); await restored.retry()
        XCTAssertEqual(repo.events.map(\.id), ids); XCTAssertEqual(repo.events.map(\.kind), [.created, .assigned]); XCTAssertEqual(repo.rows.count, 1)
        XCTAssertEqual(repo.events[0].actorDisplayNameSnapshot, "Original")
    }
    func testDirectAuthFailureDoesNotWrite() async {
        let (vm, repo, friends) = deliveryFixture(); friends.failure = CollaborationAuthError.sessionMissing
        let ok = await vm.send(); XCTAssertFalse(ok); XCTAssertTrue(repo.rows.isEmpty)
    }
    func testDirectInvalidateDuringFriendCheckPreventsWrite() async {
        let (vm, repo, friends) = deliveryFixture(); friends.onRelationship = { vm.invalidate() }
        let ok = await vm.send(); XCTAssertFalse(ok); XCTAssertTrue(repo.rows.isEmpty); XCTAssertNil(vm.receiver)
    }
    func testDirectServerPermissionFailureNotReportedAsSuccess() async {
        let (vm, repo, _) = deliveryFixture(); repo.directFailure = TaskServiceError.permission
        let ok = await vm.send(); XCTAssertFalse(ok); XCTAssertFalse(vm.delivered); XCTAssertNotNil(vm.errorMessage)
    }
    func testReceivedUsesSameRowInMineAndMiniAndCompletionHistory() async {
        let repo = MemoryTaskRepository(userID: user), groups = MemoryGroupRepository(userID: user), sender = UUID()
        repo.names[sender] = "Sender"; repo.rows = [repo.row(TaskDraft(title: "received", scheduledDate: day), createdBy: sender)]
        let vm = TaskWorkspaceModel(repository: repo, groups: groups, calendar: calendar, now: { self.date }, actorDisplayName: { "Receiver" })
        await vm.refresh(); XCTAssertEqual(vm.assigned, vm.received); XCTAssertEqual(vm.todayTasks, vm.received)
        XCTAssertEqual(vm.personName(for: repo.rows[0]), "Sender")
        await vm.toggle(repo.rows[0]); XCTAssertEqual(vm.received[0].status, .completed); XCTAssertEqual(repo.events.last?.kind, .completed); XCTAssertEqual(repo.events.last?.actorID, user)
        await vm.toggle(repo.rows[0]); XCTAssertEqual(vm.todayTasks[0].status, .open); XCTAssertNil(vm.todayTasks[0].completedAt); XCTAssertEqual(repo.events.last?.kind, .reopened)
    }
    func testReceivedCannotEditOrDelete() async {
        let (vm, repo, _) = fixture(); let received = repo.row(TaskDraft(title: "keep", scheduledDate: day), createdBy: UUID()); repo.rows = [received]
        let ok = await vm.save(received, draft: TaskDraft(title: "overwrite", scheduledDate: day)); XCTAssertFalse(ok)
        await vm.archive(received); XCTAssertEqual(repo.rows[0], received)
    }
    func testSentCannotToggleAndRefreshShowsReceiverStatus() async {
        let (vm, repo, _) = fixture(); let receiver = UUID(); repo.names[receiver] = "Receiver"
        repo.rows = [repo.row(TaskDraft(title: "sent", scheduledDate: day), assignedTo: receiver)]; await vm.refresh()
        await vm.toggle(repo.rows[0]); XCTAssertEqual(repo.rows[0].status, .open); XCTAssertTrue(repo.events.isEmpty); XCTAssertEqual(vm.personName(for: vm.sent[0]), "Receiver")
        repo.rows[0].status = .completed; repo.rows[0].completedAt = date; await vm.refresh()
        XCTAssertEqual(vm.sent[0].status, .completed); XCTAssertEqual(vm.todaySent[0].status, .completed); XCTAssertTrue(vm.assigned.isEmpty)
    }
    func testEndedFriendshipDoesNotRemoveExistingTasks() async {
        let (vm, repo, friends) = deliveryFixture(); let ok = await vm.send(); XCTAssertTrue(ok); friends.state = .available
        let rows = try? await repo.tasks(.sent(from: day, through: day)); XCTAssertEqual(rows?.count, 1)
    }
    func testHistoryUsesStoredSnapshotAndAssignmentReceiver() throws {
        let id = UUID(), task = UUID(), actor = UUID()
        let data = """
        {"id":"\(id)","task_id":"\(task)","actor_id":"\(actor)","actor_display_name_snapshot":"Past Name","event_type":"assigned","metadata":{"receiver_display_name":"Past Receiver"},"created_at":0}
        """.data(using: .utf8)!
        let row = try JSONDecoder().decode(TaskHistoryEvent.self, from: data)
        XCTAssertEqual(row.actorDisplayNameSnapshot, "Past Name"); XCTAssertEqual(row.summary, "Past Receiver에게 전달")
        let complete = TaskHistoryEvent(id: UUID(), taskID: task, actorID: actor, actorDisplayNameSnapshot: "Past Name", kind: .completed, metadata: [:], createdAt: date)
        XCTAssertEqual(complete.summary, "Past Name 완료")
    }
    func testDeliveryAndParticipantStateClearedOnAccountInvalidation() async {
        let repo = MemoryTaskRepository(userID: user), groups = MemoryGroupRepository(userID: user), friends = DeliveryFriends(userID: user)
        let vm = TaskWorkspaceModel(repository: repo, groups: groups, calendar: calendar, now: { self.date }, friendships: friends)
        vm.beginDelivery(to: friends.friend); let sheet = vm.delivery; XCTAssertNotNil(sheet)
        vm.invalidate(); XCTAssertNil(vm.delivery); XCTAssertNil(sheet?.receiver); XCTAssertTrue(vm.participantNames.isEmpty); XCTAssertTrue(vm.received.isEmpty); XCTAssertTrue(vm.sent.isEmpty)
        let ok = await sheet?.send(); XCTAssertEqual(ok, false)
    }
    func testReceivedBadgeCountsOtherDatesAndExcludesSelfAndTemplates() async {
        let (vm, repo, _) = fixture(); let oldDay = try! TaskDay(value: "2026-09-29")
        var template = repo.row(TaskDraft(title: "template", scheduledDate: day), createdBy: UUID()); template.isRecurrenceTemplate = true
        repo.rows = [repo.row(TaskDraft(title: "past received", scheduledDate: oldDay), createdBy: UUID()), repo.row(TaskDraft(title: "self", scheduledDate: day)), template]
        await vm.refresh(); XCTAssertEqual(vm.receivedIncompleteCount, 1)
    }
    func testFriendRemovedBetweenCheckAndInsertServerRejectionKeepsSheet() async {
        let (vm, repo, friends) = deliveryFixture()
        repo.beforeDirect = { friends.state = .available; repo.directFailure = TaskServiceError.permission }
        let ok = await vm.send(); XCTAssertFalse(ok); XCTAssertTrue(repo.rows.isEmpty); XCTAssertFalse(vm.delivered)
    }
    func testSentCannotEditOrArchive() async {
        let (vm, repo, _) = fixture(); let sent = repo.row(TaskDraft(title: "sent", scheduledDate: day), assignedTo: UUID()); repo.rows = [sent]
        let ok = await vm.save(sent, draft: TaskDraft(title: "no", scheduledDate: day)); XCTAssertFalse(ok)
        await vm.archive(sent); XCTAssertEqual(repo.rows, [sent])
    }
    func testRetryDoesNotOverwriteReceiverChanges() async {
        let (vm, repo, _) = deliveryFixture(); repo.directAfterInsertFailure = true
        _ = await vm.send(); repo.rows[0].title = "server changed"; repo.rows[0].notes = "new notes"; repo.rows[0].status = .completed
        let ok = await vm.send(); XCTAssertTrue(ok); XCTAssertEqual(repo.rows[0].title, "server changed"); XCTAssertEqual(repo.rows[0].notes, "new notes"); XCTAssertEqual(repo.rows[0].status, .completed)
    }
    func testHistoryAllowsStructuredJSONMetadataWithoutLosingReceiverName() throws {
        let data = """
        {"id":"\(UUID())","task_id":"\(UUID())","actor_id":"\(UUID())","actor_display_name_snapshot":"Past","event_type":"assigned","metadata":{"receiver_display_name":"Receiver","extra":{"old":true}},"created_at":0}
        """.data(using: .utf8)!
        let row = try JSONDecoder().decode(TaskHistoryEvent.self, from: data); XCTAssertEqual(row.summary, "Receiver에게 전달")
    }
    func testOptimisticReceivedBadgeDoesNotRevertDuringRefresh() async {
        let (vm, repo, _) = fixture(); repo.rows = [repo.row(TaskDraft(title: "received", scheduledDate: day), createdBy: UUID())]
        await vm.refresh(); XCTAssertEqual(vm.receivedIncompleteCount, 1)
        repo.beforeCompletion = { _ in
            XCTAssertEqual(vm.receivedIncompleteCount, 0); await vm.refresh(); XCTAssertEqual(vm.receivedIncompleteCount, 0)
        }
        await vm.toggle(repo.rows[0]); XCTAssertEqual(vm.receivedIncompleteCount, 0)
    }
    func testLateDeliveryResponseAfterInvalidationCannotPublishOrRecordEvents() async {
        let (vm, repo, _) = deliveryFixture(); repo.beforeDirect = { vm.invalidate() }
        let ok = await vm.send(); XCTAssertFalse(ok); XCTAssertFalse(vm.delivered); XCTAssertTrue(repo.events.isEmpty)
    }
    func testMismatchedAccountRepositoriesCannotDeliver() async {
        let repo = MemoryTaskRepository(userID: user), other = DeliveryFriends(userID: UUID())
        let vm = TaskDeliveryModel(tasks: repo, friendships: other, events: TaskEventQueue(repository: repo), receiver: other.friend, source: nil, calendar: calendar, today: { self.date }, name: { "me" }, sessionFailure: { _ in })
        vm.title = "x"; let ok = await vm.send(); XCTAssertFalse(ok); XCTAssertTrue(repo.rows.isEmpty)
    }
    func testDeliveryFinishingRefreshesSentWithoutNavigationChange() async {
        let repo = MemoryTaskRepository(userID: user), groups = MemoryGroupRepository(userID: user), friends = DeliveryFriends(userID: user)
        let vm = TaskWorkspaceModel(repository: repo, groups: groups, calendar: calendar, now: { self.date }, actorDisplayName: { "me" }, friendships: friends)
        vm.beginDelivery(to: friends.friend); vm.delivery?.title = "x"; let ok = await vm.delivery?.send(); XCTAssertEqual(ok, true)
        await vm.deliveryFinished(); XCTAssertNil(vm.delivery); XCTAssertEqual(vm.sent.count, 1); XCTAssertEqual(vm.deliveryNotice, "전달됨")
    }
}
@MainActor private final class DeliveryFriends: FriendshipRepository {
    let userID: UUID
    let friend: Friend
    var state: FriendRelationship = .friend
    var failure: Error?
    var relationshipReads = 0
    var onRelationship: (() -> Void)?
    init(userID: UUID) { self.userID = userID; friend = Friend(friendshipID: UUID(), userID: UUID(), displayName: "Friend", friendCode: try! FriendCode("AB12CD34"), createdAt: Date()) }
    func relationship(with user: UUID) async throws -> FriendRelationship { relationshipReads += 1; if let failure { throw failure }; onRelationship?(); return state }
    func snapshot() async throws -> FriendshipSnapshot { if let failure { throw failure }; return FriendshipSnapshot(friends: state == .friend ? [friend] : [], incoming: [], outgoing: []) }
    func searchUser(friendCode: FriendCode) async throws -> WorkUserSummary { throw FriendshipError.notFound }
    func sendRequest(to user: UUID) async throws -> FriendRequestDelivery { throw FriendshipError.unavailable }
    func acceptRequest(id: UUID) async throws -> UUID { throw FriendshipError.unavailable }
    func rejectRequest(id: UUID) async throws { throw FriendshipError.unavailable }
    func removeFriend(friendshipID: UUID) async throws { state = .available }
}
