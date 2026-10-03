import XCTest
import Supabase
@testable import PIAAR_Translator

@MainActor final class RecurrenceTests: XCTestCase {
    let user = UUID()
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Seoul")!; return c }
    func day(_ value: String = "2026-10-04") throws -> TaskDay { try TaskDay(value: value) }
    fileprivate func fixture(mask: Int = 127) throws -> (RecurrenceTaskMemory, RecurrenceMemory, TaskRecurrenceService, TaskDraft, TaskRecurrence) {
        let tasks = RecurrenceTaskMemory(userID: user); let rules = RecurrenceMemory(userID: user)
        let template = TaskDraft(title: "반복", scheduledDate: try day(), notes: "메모", isRecurrenceTemplate: true)
        let rule = TaskRecurrence(id: UUID(), templateTaskID: template.id, weekdays: mask, startDate: try day(), endDate: nil, timezone: "Asia/Seoul", isActive: true)
        return (tasks, rules, TaskRecurrenceService(tasks: tasks, repository: rules), template, rule)
    }
    func testSundayFirstMapping() throws {
        let (_, _, _, _, rule) = try fixture(mask: 1)
        XCTAssertTrue(rule.includes(try day())); XCTAssertFalse(rule.includes(try day("2026-10-05")))
        for i in 0..<7 {
            var value = rule; value.weekdays = 1 << i
            let date = calendar.date(byAdding: .day, value: i, to: try day().date(calendar: calendar))!
            XCTAssertTrue(value.includes(TaskDay(date, calendar: calendar)))
        }
    }
    func testTemplateHasNoRecurrenceAndIsNotInstance() async throws {
        let (tasks, _, service, template, rule) = try fixture()
        _ = try await service.prepare(template: template, rule: rule)
        XCTAssertTrue(tasks.rows[0].isRecurrenceTemplate); XCTAssertNil(tasks.rows[0].recurrenceID)
        let visible = try await tasks.tasks(.assigned(from: day(), through: day()))
        XCTAssertTrue(visible.isEmpty)
    }
    func testRecurrenceCreatedAfterTemplate() async throws {
        let (tasks, rules, service, template, rule) = try fixture()
        rules.onCreate = { XCTAssertEqual(tasks.rows.first?.id, template.id) }
        let saved = try await service.prepare(template: template, rule: rule)
        XCTAssertEqual(saved.templateTaskID, template.id); XCTAssertEqual(rules.rows.count, 1)
    }
    func testTemplateAndRuleRetryAreUnique() async throws {
        let (tasks, rules, service, template, rule) = try fixture()
        _ = try await service.prepare(template: template, rule: rule); _ = try await service.prepare(template: template, rule: rule)
        XCTAssertEqual(tasks.rows.count, 1); XCTAssertEqual(rules.rows.count, 1)
    }
    func testInstanceCarriesRuleAndCivilDate() async throws {
        let (_, _, service, template, rule) = try fixture()
        _ = try await service.prepare(template: template, rule: rule)
        let saved = try await service.instance(rule, day: day("2026-10-05"))
        XCTAssertEqual(saved.recurrenceID, rule.id); XCTAssertEqual(saved.scheduledDate?.value, "2026-10-05")
        XCTAssertFalse(saved.isRecurrenceTemplate); XCTAssertEqual(saved.notes, "메모"); XCTAssertEqual(saved.status, .open)
    }
    func testSameDayReusesInstanceWithoutOverwrite() async throws {
        let (tasks, _, service, template, rule) = try fixture()
        _ = try await service.prepare(template: template, rule: rule)
        let first = try await service.instance(rule, day: day())
        let i = tasks.rows.firstIndex { $0.id == first.id }!; tasks.rows[i].title = "서버 수정"
        let reused = try await service.instance(rule, day: day())
        XCTAssertEqual(reused.id, first.id); XCTAssertEqual(reused.title, "서버 수정"); XCTAssertEqual(tasks.rows.count, 2)
    }
    func testUniqueConflictFetchReuse() async throws {
        let id = UUID(); let result: UUID = try await RecurrenceConflict.reuse(error: PostgrestError(code: "23505", message: "unique")) { id }
        XCTAssertEqual(result, id)
    }
    func testUniqueOtherIdentityDoesNotHideError() async {
        do { let _: UUID = try await RecurrenceConflict.reuse(error: PostgrestError(code: "23505", message: "unrelated")) { nil }; XCTFail() }
        catch { XCTAssertEqual((error as? PostgrestError)?.code, "23505") }
    }
    func testOtherDBErrorDoesNotFetchOrReuse() async {
        var fetched = false
        do { let _: UUID = try await RecurrenceConflict.reuse(error: PostgrestError(code: "42501", message: "RLS")) { fetched = true; return UUID() }; XCTFail() }
        catch { XCTAssertEqual((error as? PostgrestError)?.code, "42501") }; XCTAssertFalse(fetched)
    }
    func testForeignKeyErrorIsNotUnique() { XCTAssertFalse(RecurrenceConflict.isUnique(PostgrestError(code: "23503", message: "FK"))) }
    func testTwoDeviceInsertRaceReusesWinner() async throws {
        let (tasks, rules, a, template, rule) = try fixture()
        _ = try await a.prepare(template: template, rule: rule)
        let b = TaskRecurrenceService(tasks: tasks, repository: rules)
        tasks.race = true
        async let first = a.instance(rule, day: day()); async let second = b.instance(rule, day: day())
        let pair = try await (first, second)
        XCTAssertEqual(pair.0.id, pair.1.id); XCTAssertEqual(tasks.rows.filter { !$0.isRecurrenceTemplate }.count, 1)
        XCTAssertEqual(tasks.raceInserts, 2); XCTAssertEqual(tasks.conflicts, 1)
    }
    func testEachDayCompletionIsIndependent() async throws {
        let (tasks, _, service, template, rule) = try fixture(); _ = try await service.prepare(template: template, rule: rule)
        let a = try await service.instance(rule, day: day()); let b = try await service.instance(rule, day: day("2026-10-05"))
        _ = try await tasks.completeTask(id: a.id)
        XCTAssertEqual(tasks.rows.first { $0.id == a.id }?.status, .completed)
        XCTAssertEqual(tasks.rows.first { $0.id == b.id }?.status, .open)
    }
    func testDeactivatePreservesInstancesAndStopsGeneration() async throws {
        let (tasks, rules, service, template, rule) = try fixture(); _ = try await service.prepare(template: template, rule: rule)
        let a = try await service.instance(rule, day: day()); _ = try await tasks.completeTask(id: a.id)
        try await service.deactivate(id: rule.id)
        try await service.materializeToday(now: day("2026-10-05").date(calendar: calendar))
        XCTAssertFalse(rules.rows[0].isActive); XCTAssertEqual(tasks.rows.count, 2)
        XCTAssertEqual(tasks.rows.first { $0.id == a.id }?.status, .completed)
    }
    func testOnlyTodayIsMaterialized() async throws {
        let (tasks, _, service, template, rule) = try fixture(); _ = try await service.prepare(template: template, rule: rule)
        try await service.materializeToday(now: day("2026-10-07").date(calendar: calendar))
        XCTAssertEqual(tasks.rows.filter { !$0.isRecurrenceTemplate }.compactMap { $0.scheduledDate?.value }, ["2026-10-07"])
    }
    func testServerEditedRuleAndTemplatePreservedOnRetry() async throws {
        let (tasks, rules, service, template, rule) = try fixture(); _ = try await service.prepare(template: template, rule: rule)
        tasks.rows[0].title = "edited"; rules.rows[0].weekdays = 2; rules.rows[0].isActive = false
        let saved = try await service.prepare(template: template, rule: rule)
        XCTAssertEqual(tasks.rows[0].title, "edited"); XCTAssertEqual(saved.weekdays, 2); XCTAssertFalse(saved.isActive)
    }
    func testTemplateCannotHaveRecurrenceID() throws {
        var draft = try fixture().3; draft.recurrenceID = UUID(); XCTAssertThrowsError(try draft.validate())
    }
    func testRuleStartEndAndInactiveChecks() throws {
        var rule = try fixture().4
        XCTAssertFalse(rule.includes(try day("2026-10-03"))); rule.isActive = false; XCTAssertFalse(rule.includes(try day()))
        rule.weekdays = 128; XCTAssertThrowsError(try rule.validate())
    }
    func testDeadlineOffsetAndOptionalTimesPreserved() throws {
        let (tasks, _, _, template, rule) = try fixture(); var draft = template
        draft.deadlineDate = try day("2026-10-06")
        let shifted = try TaskRecurrenceService.draft(template: tasks.row(draft), rule: rule, day: day("2026-10-10"))
        XCTAssertEqual(shifted.deadlineDate?.value, "2026-10-12"); XCTAssertNil(shifted.startAt); XCTAssertNil(shifted.deadlineAt)
    }
    func testLegacyRepeatScheduleGroupingAndRetry() async throws {
        let (tasks, rules, service, _, _) = try fixture()
        let model = TodoRepeatSchedule(title: "legacy", beginsOn: try day().date(calendar: calendar), now: Date()); model.weekdayMask = 127; model.notes = "원본"
        let schedule = LegacyRecurrenceSnapshot(model)
        func todo(_ date: String) throws -> TodoSnapshot {
            TodoSnapshot(id: UUID(), title: "instance", notes: "메모", date: try day(date).date(calendar: calendar), isCompleted: date == "2026-10-04", completedAt: nil, createdAt: Date(), updatedAt: Date(), sortOrder: 0, groupID: nil, repeatScheduleID: model.id)
        }
        let source = RecurrenceLegacySource(archive: LegacyTodoArchive(todos: try [todo("2026-10-04"), todo("2026-10-05"), todo("2026-10-05")], groups: [], schedules: [schedule]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: directory) }
        let migration = LegacyTaskMigration(source: source, tasks: tasks, groups: RecurrenceGroups(userID: user), calendar: calendar, links: TaskCalendarLinks(userID: user, directory: directory), recurrences: service)
        await migration.loadPreview(); XCTAssertEqual(migration.preview?.repeatTemplatesReady, 1); XCTAssertEqual(migration.preview?.pendingRepeats, 0)
        XCTAssertEqual(migration.preview?.importable, 2); XCTAssertEqual(migration.preview?.duplicateRepeatDates, 1)
        await migration.migrate(approvedUserID: user)
        XCTAssertEqual(rules.rows.count, 1); XCTAssertEqual(tasks.rows.count, 3)
        XCTAssertEqual(tasks.rows.filter { !$0.isRecurrenceTemplate && $0.status == .completed }.count, 1)
        tasks.rows[1].title = "서버 편집"
        await migration.migrate(approvedUserID: user)
        XCTAssertEqual(tasks.rows.count, 3); XCTAssertEqual(tasks.rows[1].title, "서버 편집"); XCTAssertEqual(rules.rows.count, 1)
        XCTAssertEqual(source.archive.todos.count, 3)
    }
    func testLegacyInactiveRulePreservesHistoricalInstance() async throws {
        let model = TodoRepeatSchedule(title: "stopped", beginsOn: Date(), now: Date()); model.weekdayMask = 0
        let rule = try LegacyRecurrenceSnapshot(model).rule(userID: user, calendar: calendar)
        XCTAssertFalse(rule.isActive); XCTAssertEqual(rule.weekdays, 0)
    }
    func testOrdinaryEditPayloadDoesNotResetRecurrence() throws {
        let (_, _, _, template, _) = try fixture(); let payload = SupabaseTaskRepository.payload(template)
        XCTAssertNil(payload["recurrence_id"]); XCTAssertNil(payload["is_recurrence_template"])
    }
    func testFailedRuleReportsInstanceFailureAndCanResumeAfterRestart() async throws {
        let (tasks, rules, service, _, _) = try fixture()
        let model = TodoRepeatSchedule(title: "repeat", beginsOn: try day().date(calendar: calendar), now: Date()); model.weekdayMask = 127
        let t = TodoSnapshot(id: UUID(), title: "historical", notes: "memo", date: try day().date(calendar: calendar), isCompleted: true, completedAt: nil, createdAt: Date(), updatedAt: Date(), sortOrder: 0, groupID: nil, repeatScheduleID: model.id)
        let source = RecurrenceLegacySource(archive: LegacyTodoArchive(todos: [t], groups: [], schedules: [LegacyRecurrenceSnapshot(model)]))
        func make() -> LegacyTaskMigration { LegacyTaskMigration(source: source, tasks: tasks, groups: RecurrenceGroups(userID: user), calendar: calendar, links: TaskCalendarLinks(userID: user, inMemory: true), recurrences: service) }
        rules.failure = TaskServiceError.network
        let m = make(); await m.loadPreview(); await m.migrate(approvedUserID: user)
        XCTAssertEqual(m.result?.rulesFailed, 1); XCTAssertEqual(m.result?.todosFailed, 1)
        XCTAssertEqual(tasks.rows.count, 1); XCTAssertTrue(tasks.rows[0].isRecurrenceTemplate)
        rules.failure = nil
        let restart = make(); await restart.loadPreview(); await restart.migrate(approvedUserID: user)
        XCTAssertEqual(tasks.rows.count, 2); XCTAssertEqual(rules.rows.count, 1)
        XCTAssertEqual(tasks.rows[1].status, .completed); XCTAssertNil(tasks.rows[1].completedAt)
        XCTAssertEqual(tasks.rows[1].sourceLocalTodoID, t.id); XCTAssertEqual(tasks.rows[1].notes, "memo")
    }
    func testLegacyImportDoesNotFabricateCreatedEventButNormalInstanceDoes() async throws {
        let (tasks, rules, _, template, rule) = try fixture()
        let queue = TaskEventQueue(repository: tasks, storage: MemoryTaskEventStorage())
        tasks.eventFailure = true
        let service = TaskRecurrenceService(tasks: tasks, repository: rules, events: queue)
        _ = try await service.prepare(template: template, rule: rule)
        var legacy = TaskDraft(title: "historical", scheduledDate: try day(), status: .completed)
        legacy.sourceLocalTodoID = UUID()
        let historical = try await service.instance(rule, day: day(), legacy: legacy)
        XCTAssertTrue(queue.pending.isEmpty); XCTAssertEqual(historical.status, .completed); XCTAssertNil(historical.completedAt)
        _ = try await service.instance(rule, day: day("2026-10-05"))
        XCTAssertEqual(queue.pending.map(\.kind), [.created])
    }
    func testLegacyImportScopeSuspendsTodayGenerationAndRestoresAfterFinish() async throws {
        let (tasks, _, service, template, rule) = try fixture()
        _ = try await service.prepare(template: template, rule: rule)
        try service.beginLegacyImport(); XCTAssertThrowsError(try service.beginLegacyImport())
        try await service.materializeToday(now: day().date(calendar: calendar)); XCTAssertEqual(tasks.rows.count, 1)
        service.endLegacyImport(); try await service.materializeToday(now: day().date(calendar: calendar))
        XCTAssertEqual(tasks.rows.count, 2)
    }
    func testSessionChecksStopBetweenTemplateAndRecurrenceCreation() async throws {
        let (tasks, rules, service, template, rule) = try fixture(); var calls = 0
        do {
            _ = try await service.prepare(template: template, rule: rule, beforeRequest: {
                calls += 1; if calls == 3 { throw CollaborationAuthError.sessionMissing }
            }); XCTFail("The rule must not be created after session invalidation")
        } catch { XCTAssertEqual(error as? CollaborationAuthError, .sessionMissing) }
        XCTAssertEqual(tasks.rows.count, 1); XCTAssertTrue(rules.rows.isEmpty)
        _ = try await service.prepare(template: template, rule: rule)
        XCTAssertEqual(tasks.rows.count, 1); XCTAssertEqual(rules.rows.count, 1)
    }
    func testSessionChecksStopBeforeLegacyInstanceInsert() async throws {
        let (tasks, _, service, template, rule) = try fixture()
        _ = try await service.prepare(template: template, rule: rule); var calls = 0
        do {
            _ = try await service.instance(rule, day: day(), legacy: TaskDraft(title: "legacy", scheduledDate: day()), beforeRequest: {
                calls += 1; if calls == 3 { throw CollaborationAuthError.refreshFailed }
            }); XCTFail("No instance may be inserted")
        } catch { XCTAssertEqual(error as? CollaborationAuthError, .refreshFailed) }
        XCTAssertEqual(tasks.rows.count, 1)
    }

}

@MainActor private final class RecurrenceTaskMemory: TaskRepository {
    let userID: UUID; var rows: [WorkTask] = []; var race = false; var raceInserts = 0; var conflicts = 0
    var eventFailure = false
    var barrier: CheckedContinuation<Void, Never>?
    init(userID: UUID) { self.userID = userID }
    func row(_ d: TaskDraft) -> WorkTask {
        WorkTask(id: d.id, title: d.title, createdBy: userID, assignedTo: userID, spaceID: nil, groupID: d.groupID, scheduledDate: d.scheduledDate, deadlineDate: d.deadlineDate, deadlineAt: d.deadlineAt, startAt: d.startAt, status: d.status, completedAt: d.completedAt, sourceLocalTodoID: d.sourceLocalTodoID, isArchived: false, createdAt: Date(), updatedAt: Date(), notes: d.notes, recurrenceID: d.recurrenceID, isRecurrenceTemplate: d.isRecurrenceTemplate)
    }
    func tasks(_ query: TaskQuery) async throws -> [WorkTask] { rows.filter { !$0.isRecurrenceTemplate && !$0.isArchived } }
    func fetchTask(id: UUID) async throws -> WorkTask? { rows.first { $0.id == id } }
    func importedTask(sourceLocalTodoID: UUID) async throws -> WorkTask? { rows.first { $0.sourceLocalTodoID == sourceLocalTodoID } }
    func recurrenceInstance(id: UUID, day: TaskDay) async throws -> WorkTask? { rows.first { $0.recurrenceID == id && $0.scheduledDate == day } }
    func createTask(_ d: TaskDraft) async throws -> WorkTask {
        if d.recurrenceID != nil && race {
            raceInserts += 1
            if raceInserts == 1 { await withCheckedContinuation { barrier = $0 } }
            else { barrier?.resume(); barrier = nil }
        }
        if let id = d.recurrenceID, rows.contains(where: { $0.recurrenceID == id && $0.scheduledDate == d.scheduledDate }) {
            conflicts += 1
            return try await RecurrenceConflict.reuse(error: PostgrestError(code: "23505", message: "unique")) { try await self.recurrenceInstance(id: id, day: d.scheduledDate) }
        }
        if let existing = rows.first(where: { $0.id == d.id }) { return existing }
        let value = row(d); rows.append(value); return value
    }
    func updateTask(id: UUID, draft: TaskDraft) async throws -> WorkTask { let i = rows.firstIndex { $0.id == id }!; rows[i].title = draft.title; return rows[i] }
    func completeTask(id: UUID) async throws -> WorkTask { let i = rows.firstIndex { $0.id == id }!; rows[i].status = .completed; return rows[i] }
    func reopenTask(id: UUID) async throws -> WorkTask { let i = rows.firstIndex { $0.id == id }!; rows[i].status = .open; return rows[i] }
    func archiveTask(id: UUID) async throws {}
    func recordEvent(_ event: TaskEventRequest) async throws { if eventFailure { throw TaskServiceError.network } }
}
@MainActor private final class RecurrenceMemory: RecurrenceRepository {
    let userID: UUID; var rows: [TaskRecurrence] = []; var onCreate: (() -> Void)?; var failure: Error?
    init(userID: UUID) { self.userID = userID }
    func rules() async throws -> [TaskRecurrence] { rows }
    func rule(templateID: UUID) async throws -> TaskRecurrence? { rows.first { $0.templateTaskID == templateID } }
    func create(_ rule: TaskRecurrence) async throws -> TaskRecurrence { if let failure { throw failure }; onCreate?(); if let old = rows.first(where: { $0.templateTaskID == rule.templateTaskID }) { return old }; rows.append(rule); return rule }
    func deactivate(id: UUID) async throws { let i = rows.firstIndex { $0.id == id }!; rows[i].isActive = false }
}
@MainActor private final class RecurrenceLegacySource: LegacyTodoSource {
    let archive: LegacyTodoArchive
    init(archive: LegacyTodoArchive) { self.archive = archive }
    func read() throws -> LegacyTodoArchive { archive }
}
@MainActor private final class RecurrenceGroups: GroupRepository {
    let userID: UUID
    init(userID: UUID) { self.userID = userID }
    func personalGroups() async throws -> [TaskGroup] { [] }
    func groups(spaceID: UUID) async throws -> [TaskGroup] { [] }
    func fetchGroup(id: UUID) async throws -> TaskGroup? { nil }
    func create(id: UUID, name: String, colorHex: String?, sortOrder: Int) async throws -> TaskGroup { throw TaskServiceError.unavailable }
    func rename(id: UUID, name: String, colorHex: String?) async throws {}
    func delete(id: UUID) async throws {}
    func reorder(ids: [UUID]) async throws {}
}
