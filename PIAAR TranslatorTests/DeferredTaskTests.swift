import XCTest
@testable import PIAAR_Translator

final class DeferredTaskTests: XCTestCase {
    private let me = UUID()
    private var calendar: Calendar { var c = Calendar(identifier:.gregorian); c.timeZone = TimeZone(identifier:"Asia/Seoul")!; return c }
    private var now: Date { calendar.date(from:DateComponents(year:2026,month:10,day:5))! }
    private func row(_ days: Int = -1) -> WorkTask {
        let date = calendar.date(byAdding:.day,value:days,to:now)!
        return WorkTask(id:UUID(),title:"확인",createdBy:me,assignedTo:me,spaceID:nil,groupID:nil,scheduledDate:TaskDay(date,calendar:calendar),deadlineDate:nil,deadlineAt:nil,startAt:nil,status:.open,completedAt:nil,sourceLocalTodoID:nil,isArchived:false,createdAt:now,updatedAt:now)
    }
    private func overdue(_ t: WorkTask) -> Int? { DeferredTaskPresentation.overdueDays(t,userID:me,now:now,calendar:calendar) }
    func testCalendarOverdueDays() { XCTAssertEqual(overdue(row()),1); XCTAssertEqual(overdue(row(-5)),5); XCTAssertNil(overdue(row(0))); XCTAssertNil(overdue(row(1))) }
    func testCountDoesNotIncreaseJustBecauseDatePassed() { let t = row(-5); XCTAssertEqual(overdue(t),5); XCTAssertEqual(t.deferCount,0); XCTAssertEqual(DeferredTaskPresentation.summary(t,userID:me,now:now,calendar:calendar),"5일째 미완료") }
    func testDeferredCountPresentation() { var t = row(-4); t.deferCount = 2; XCTAssertEqual(DeferredTaskPresentation.summary(t,userID:me,now:now,calendar:calendar),"4일째 미완료 · 2번 미룸") }
    func testSomedayIsNotOverdue() { var t = row(); t.scheduledDate = nil; XCTAssertNil(overdue(t)) }
    func testCompletedExcluded() { var t = row(); t.status = .completed; XCTAssertNil(overdue(t)) }
    func testArchivedExcluded() {
        let t = row(); let archived = WorkTask(id:t.id,title:t.title,createdBy:me,assignedTo:me,spaceID:nil,groupID:nil,scheduledDate:t.scheduledDate,deadlineDate:nil,deadlineAt:nil,startAt:nil,status:.open,completedAt:nil,sourceLocalTodoID:nil,isArchived:true,createdAt:now,updatedAt:now)
        XCTAssertNil(overdue(archived)); XCTAssertFalse(DeferredTaskPresentation.canOrganize(archived,userID:me))
    }
    func testReceivedShowsAgeButCannotOrganize() {
        let t = row(); let received = WorkTask(id:t.id,title:t.title,createdBy:UUID(),assignedTo:me,spaceID:UUID(),groupID:nil,scheduledDate:t.scheduledDate,deadlineDate:nil,deadlineAt:nil,startAt:nil,status:.open,completedAt:nil,sourceLocalTodoID:nil,isArchived:false,createdAt:now,updatedAt:now)
        XCTAssertEqual(overdue(received),1); XCTAssertFalse(DeferredTaskPresentation.canOrganize(received,userID:me)); XCTAssertEqual(received.permission(userID:me),.completeOnly)
    }
    func testSentNotOverdueForSender() {
        let t = row(); let sent = WorkTask(id:t.id,title:t.title,createdBy:me,assignedTo:UUID(),spaceID:nil,groupID:nil,scheduledDate:t.scheduledDate,deadlineDate:nil,deadlineAt:nil,startAt:nil,status:.open,completedAt:nil,sourceLocalTodoID:nil,isArchived:false,createdAt:now,updatedAt:now)
        XCTAssertNil(overdue(sent)); XCTAssertFalse(DeferredTaskPresentation.canOrganize(sent,userID:me))
    }
    func testRecurrenceInstanceCannotOrganizeButCanComplete() { var t = row(); t.recurrenceID = UUID(); XCTAssertFalse(DeferredTaskPresentation.canOrganize(t,userID:me)); XCTAssertEqual(t.permission(userID:me),.edit); XCTAssertEqual(overdue(t),1) }
    func testTemplateExcluded() { var t = row(); t.isRecurrenceTemplate = true; XCTAssertNil(overdue(t)); XCTAssertFalse(DeferredTaskPresentation.canOrganize(t,userID:me)) }
    func testNewWireFieldsRoundTripAndNilDate() throws {
        var t = row(); t.scheduledDate = nil; t.estimatedMinutes = 90; t.priority = .important; t.deferCount = 2; t.lastDeferredAt = now
        let data = try JSONEncoder().encode(t); let decoded = try JSONDecoder().decode(WorkTask.self,from:data)
        XCTAssertEqual(decoded,t); XCTAssertNil(decoded.scheduledDate)
        let json = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        XCTAssertEqual(json["estimated_minutes"] as? Int,90); XCTAssertEqual(json["priority"] as? String,"important"); XCTAssertEqual(json["defer_count"] as? Int,2)
    }
    func testOldWireFieldsGetSafeDefaults() throws {
        var json = try JSONSerialization.jsonObject(with:JSONEncoder().encode(row())) as! [String:Any]
        for key in ["scheduled_at","day_period","estimated_minutes","priority","defer_count","last_deferred_at"] { json.removeValue(forKey:key) }
        let t = try JSONDecoder().decode(WorkTask.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertNil(t.scheduledAt); XCTAssertNil(t.dayPeriod); XCTAssertNil(t.estimatedMinutes); XCTAssertEqual(t.priority,.normal); XCTAssertEqual(t.deferCount,0); XCTAssertNil(t.lastDeferredAt)
    }
    func testRescheduleAndArchiveHistoryDecode() throws {
        for kind in [TaskEventKind.rescheduled,.archived] {
            let event = TaskHistoryEvent(id:UUID(),taskID:UUID(),actorID:me,actorDisplayNameSnapshot:"사용자",kind:kind,metadata:[:],createdAt:now)
            let decoded = try JSONDecoder().decode(TaskHistoryEvent.self,from:JSONEncoder().encode(event))
            XCTAssertEqual(decoded.kind,kind); XCTAssertTrue(decoded.summary.contains("사용자"))
        }
    }
}
