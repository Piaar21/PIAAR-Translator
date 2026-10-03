import XCTest
import Supabase
@testable import PIAAR_Translator

@MainActor final class TaskScheduleTests: XCTestCase {
    let me = UUID()
    private func row() throws -> WorkTask {
        WorkTask(id:UUID(),title:"원본",createdBy:me,assignedTo:me,spaceID:nil,groupID:nil,scheduledDate:try TaskDay(value:"2026-10-01"),deadlineDate:try TaskDay(value:"2026-11-01"),deadlineAt:nil,startAt:nil,status:.open,completedAt:nil,sourceLocalTodoID:nil,isArchived:false,createdAt:Date(),updatedAt:Date(),notes:"메모")
    }
    func testExactRPCPayloadAndSomedayNulls() throws {
        let t = try row(), command = TaskScheduleCommand(task:try row(),date:nil)
        let p = SupabaseTaskScheduleTransport.payload(command)
        XCTAssertEqual(Set(p.keys),Set(["p_task_id","p_command_id","p_expected_scheduled_date","p_expected_scheduled_at","p_expected_day_period","p_target_scheduled_date","p_target_scheduled_at","p_target_day_period"]))
        XCTAssertEqual(p["p_target_scheduled_date"],.null); XCTAssertEqual(p["p_target_scheduled_at"],.null); XCTAssertEqual(p["p_target_day_period"],.null)
        XCTAssertNil(p["defer_count"]); XCTAssertNil(p["last_deferred_at"])
        let archive = SupabaseTaskScheduleTransport.archivePayload(taskID:t.id,commandID:UUID())
        XCTAssertEqual(Set(archive.keys),Set(["p_task_id","p_command_id"]))
    }
    func testScheduleRPCAndServerCount() async throws {
        let fake = FakeScheduleTransport(try row()); let target = try TaskDay(value:"2026-10-05")
        let command = TaskScheduleCommand(task:fake.row,date:target)
        let saved = try await TaskScheduleMutation.reschedule(command,transport:fake)
        XCTAssertEqual(saved.scheduledDate,target); XCTAssertEqual(saved.deferCount,1); XCTAssertEqual(fake.events.count,1)
        XCTAssertEqual(saved.notes,"메모"); XCTAssertEqual(saved.deadlineDate,try TaskDay(value:"2026-11-01"))
    }
    func testSameCommandRetryDoesNotIncrementTwice() async throws {
        let fake = FakeScheduleTransport(try row()); let command = TaskScheduleCommand(task:fake.row,date:try TaskDay(value:"2026-10-05"))
        _ = try await TaskScheduleMutation.reschedule(command,transport:fake)
        _ = try await TaskScheduleMutation.reschedule(command,transport:fake)
        XCTAssertEqual(fake.row.deferCount,1); XCTAssertEqual(fake.events.count,1)
    }
    func testCommittedTimeoutRetryReusesCommand() async throws {
        let fake = FakeScheduleTransport(try row()); fake.timeoutAfterCommit = true
        let command = TaskScheduleCommand(task:fake.row,date:try TaskDay(value:"2026-10-05"))
        do { _ = try await TaskScheduleMutation.reschedule(command,transport:fake); XCTFail() } catch { XCTAssertTrue(error is URLError) }
        _ = try await TaskScheduleMutation.reschedule(command,transport:fake)
        XCTAssertEqual(fake.row.deferCount,1); XCTAssertEqual(fake.events.count,1)
    }
    func testScheduleConflictPreservesLatestServerState() async throws {
        let fake = FakeScheduleTransport(try row()); let command = TaskScheduleCommand(task:fake.row,date:try TaskDay(value:"2026-10-05"))
        fake.row.scheduledDate = try TaskDay(value:"2026-10-08")
        do { _ = try await TaskScheduleMutation.reschedule(command,transport:fake); XCTFail() } catch { XCTAssertEqual(error as? TaskServiceError,.scheduleConflict) }
        XCTAssertEqual(fake.row.scheduledDate,try TaskDay(value:"2026-10-08")); XCTAssertTrue(fake.events.isEmpty)
    }
    func testEditorExpectedScheduleIsOriginalNotFreshFetch() throws {
        let original = try row(); var latest = original; latest.scheduledDate = try TaskDay(value:"2026-10-09")
        let c = TaskScheduleCommand(task:latest,date:try TaskDay(value:"2026-10-10"),expectation:TaskScheduleExpectation(original))
        XCTAssertEqual(c.expectedDate,original.scheduledDate); XCTAssertNotEqual(c.expectedDate,latest.scheduledDate)
    }
    func testSomedayAndReturnToDateDoNotIncreaseCount() async throws {
        let fake = FakeScheduleTransport(try row())
        _ = try await TaskScheduleMutation.reschedule(TaskScheduleCommand(task:fake.row,date:nil),transport:fake)
        XCTAssertNil(fake.row.scheduledDate); XCTAssertEqual(fake.row.deferCount,0)
        _ = try await TaskScheduleMutation.reschedule(TaskScheduleCommand(task:fake.row,date:try TaskDay(value:"2026-10-20")),transport:fake)
        XCTAssertEqual(fake.row.deferCount,0)
    }
    func testEarlierOrSameDateDoesNotIncreaseCount() async throws {
        let fake = FakeScheduleTransport(try row())
        for day in ["2026-09-30","2026-09-30"] {
            _ = try await TaskScheduleMutation.reschedule(TaskScheduleCommand(task:fake.row,date:try TaskDay(value:day)),transport:fake)
        }
        XCTAssertEqual(fake.row.deferCount,0)
    }
    func testEventFailureRollsBackServerMutation() async throws {
        let fake = FakeScheduleTransport(try row()); let original = fake.row; fake.failEvent = true
        do { _ = try await TaskScheduleMutation.reschedule(TaskScheduleCommand(task:fake.row,date:nil),transport:fake); XCTFail() } catch {}
        XCTAssertEqual(fake.row,original); XCTAssertTrue(fake.events.isEmpty)
    }
    func testArchiveRetryUsesOneServerEvent() async throws {
        let fake = FakeScheduleTransport(try row()); let id = UUID()
        _ = try await TaskScheduleMutation.archive(taskID:fake.row.id,commandID:id,transport:fake)
        _ = try await TaskScheduleMutation.archive(taskID:fake.row.id,commandID:id,transport:fake)
        XCTAssertTrue(fake.row.isArchived); XCTAssertEqual(fake.events.count,1)
    }
    func testAccountSwitchRejectsLateResult() async throws {
        let fake = FakeScheduleTransport(try row()); fake.logoutAfterWrite = true
        do { _ = try await TaskScheduleMutation.reschedule(TaskScheduleCommand(task:fake.row,date:nil),transport:fake); XCTFail() } catch { XCTAssertEqual(error as? CollaborationAuthError,.sessionMissing) }
    }
    func testOtherDatabaseErrorsRemainErrors() {
        let permission = PostgrestError(code:"42501",message:"permission denied")
        XCTAssertEqual((SupabaseTaskScheduleTransport.mapped(permission) as? PostgrestError)?.code,"42501")
        XCTAssertEqual(SupabaseTaskScheduleTransport.mapped(PostgrestError(code:"P0001",message:"schedule conflict")) as? TaskServiceError,.scheduleConflict)
    }
}

@MainActor private final class FakeScheduleTransport: TaskScheduleTransport {
    var row: WorkTask
    var events: [UUID: TaskEventKind] = [:]
    var valid = true, logoutAfterWrite = false, failEvent = false, timeoutAfterCommit = false
    init(_ row: WorkTask) { self.row = row }
    func authorize() async throws { if !valid { throw CollaborationAuthError.sessionMissing } }
    func reschedule(_ command: TaskScheduleCommand) async throws -> WorkTask {
        if events[command.id] == .rescheduled { return row }
        guard command.taskID == row.id, row.scheduledDate == command.expectedDate, row.scheduledAt == command.expectedAt, row.dayPeriod == command.expectedPeriod else { throw TaskServiceError.scheduleConflict }
        if failEvent { throw TaskServiceError.unavailable }
        if let old = row.scheduledDate, let new = command.targetDate, new > old { row.deferCount += 1; row.lastDeferredAt = Date() }
        row.scheduledDate = command.targetDate; row.scheduledAt = command.targetAt; row.dayPeriod = command.targetPeriod
        events[command.id] = .rescheduled
        if logoutAfterWrite { valid = false }
        if timeoutAfterCommit { timeoutAfterCommit = false; throw URLError(.timedOut) }
        return row
    }
    func archive(taskID: UUID, commandID: UUID) async throws -> WorkTask {
        if events[commandID] == .archived { return row }
        if failEvent { throw TaskServiceError.unavailable }
        row = WorkTask(id:row.id,title:row.title,createdBy:row.createdBy,assignedTo:row.assignedTo,spaceID:row.spaceID,groupID:row.groupID,scheduledDate:row.scheduledDate,deadlineDate:row.deadlineDate,deadlineAt:row.deadlineAt,startAt:row.startAt,status:row.status,completedAt:row.completedAt,sourceLocalTodoID:row.sourceLocalTodoID,isArchived:true,createdAt:row.createdAt,updatedAt:row.updatedAt,notes:row.notes)
        events[commandID] = .archived; return row
    }
}
