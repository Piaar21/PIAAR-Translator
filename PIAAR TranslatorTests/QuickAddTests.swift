import XCTest
@testable import PIAAR_Translator

final class QuickAddTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Seoul")!; return c
    }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 12))! }
    private func parse(_ text: String) -> QuickAddParseResult { QuickAddParser.parse(text, referenceDate: now, calendar: calendar, timeZone: calendar.timeZone) }
    func testTodayTomorrowAndAfterTomorrow() {
        for (input, date, title) in [("오늘 세금계산서 확인", "2026-10-02", "세금계산서 확인"), ("내일 공급사 연락", "2026-10-03", "공급사 연락"), ("모레 상세페이지 수정", "2026-10-04", "상세페이지 수정")] {
            let r = parse(input); XCTAssertEqual(r.scheduledDate.value, date); XCTAssertEqual(r.title, title)
        }
    }
    func testClosestWeekdayIncludesToday() { XCTAssertEqual(parse("금요일 재고 확인").scheduledDate.value, "2026-10-02"); XCTAssertEqual(parse("월요일 촬영").scheduledDate.value, "2026-10-05") }
    func testCalendarWeekStartsMonday() {
        XCTAssertEqual(parse("이번주 금요일 재고 확인").scheduledDate.value, "2026-10-02")
        XCTAssertEqual(parse("다음주 월요일 양말 촬영").scheduledDate.value, "2026-10-05")
        XCTAssertEqual(parse("다음주 화요일 미팅").scheduledDate.value, "2026-10-06")
    }
    func testExplicitDateFormats() { for text in ["10월 15일 상품 등록", "10/15 상품 등록", "10.15 상품 등록"] { XCTAssertEqual(parse(text).scheduledDate.value, "2026-10-15"); XCTAssertEqual(parse(text).title, "상품 등록") } }
    func testRelativeCalendarDates() { for (text, day) in [("3일 뒤 샘플 확인", "2026-10-05"), ("일주일 뒤 확인", "2026-10-09"), ("2주 뒤 확인", "2026-10-16")] { XCTAssertEqual(parse(text).scheduledDate.value, day) } }
    func testDayPeriodHasNoFabricatedTime() { for (text, period) in [("내일 오전에 공급사 연락", TaskDayPeriod.morning), ("오후에 확인", .afternoon), ("저녁에 확인", .evening)] { let r = parse(text); XCTAssertEqual(r.dayPeriod, period); XCTAssertNil(r.scheduledAt) } }
    func testStandaloneMorning() { XCTAssertEqual(parse("금요일 오전 왕총한테 요청 20분").dayPeriod, .morning) }
    func testExplicitMeridiemHours() { for (text, h) in [("오전 10시 연락", 10), ("오후 3시 연락", 15), ("저녁 7시 연락", 19)] { let r = parse(text); XCTAssertEqual(r.scheduledAt.map { calendar.component(.hour, from: $0) }, h); XCTAssertNil(r.dayPeriod); XCTAssertEqual(r.title, "연락") } }
    func testTwentyFourHourClock() { let r = parse("15:30 확인"); XCTAssertEqual(r.scheduledAt.map { calendar.component(.minute, from: $0) }, 30); XCTAssertEqual(r.title, "확인") }
    func testAmbiguousTimeRemainsInTitle() { let r = parse("오늘 4시 택배 확인"); XCTAssertEqual(r.title, "4시 택배 확인"); XCTAssertNil(r.scheduledAt); XCTAssertNil(parse("3시 연락").scheduledAt) }
    func testDurationUnitsAndCombinedToken() { for (text, m) in [("발주 20분",20), ("발주 30분",30), ("수정 1시간",60), ("등록 1시간 30분",90), ("수정 2시간",120)] { XCTAssertEqual(parse(text).estimatedMinutes,m) } }
    func testDurationMaximumAndOverflowDoNotCrashOrConsume() { for t in ["수정 25시간", "수정 1441분", "수정 999999999999999999999999999시간", "9999999999999999999999999주 뒤 확인"] { XCTAssertNil(parse(t).estimatedMinutes); XCTAssertEqual(parse(t).title,t) } }
    func testPriorityTokensOnly() { for t in ["중요 발주", "발주 중요", "급함 발주", "긴급 발주"] { XCTAssertEqual(parse(t).priority,.important); XCTAssertEqual(parse(t).title,"발주") }; XCTAssertEqual(parse("중요한 회의").priority,.normal) }
    func testCombinedExampleAndDeadlineIsolation() { let r = parse("내일 오후 3시 쿠팡 발주 확인 30분 중요"); XCTAssertEqual(r.title,"쿠팡 발주 확인"); XCTAssertEqual(r.estimatedMinutes,30); XCTAssertEqual(r.priority,.important); let d = r.draft(); XCTAssertNil(d.deadlineDate); XCTAssertNil(d.startAt); XCTAssertNil(d.deadlineAt); XCTAssertNotNil(d.scheduledAt) }
    func testUnsupportedRecurrenceProtected() { let r = parse("매주 월요일 업체 연락"); XCTAssertEqual(r.title,"매주 월요일 업체 연락"); XCTAssertTrue(r.recognizedTokens.isEmpty) }
    func testDateDurationRangesDoNotOverlap() { let r = parse("3일 뒤 업체 연락 1시간 30분"); XCTAssertEqual(r.title,"업체 연락"); XCTAssertEqual(r.estimatedMinutes,90); XCTAssertEqual(r.recognizedTokens.count,2) }
    func testFallbackAndUnknownPhrase() { XCTAssertEqual(parse("왕총이랑 그거 다시 확인").title,"왕총이랑 그거 다시 확인"); XCTAssertEqual(parse("오늘 퇴근 전에 택배 발송 확인").title,"퇴근 전에 택배 발송 확인") }
    func testConflictingDatesRemainUnconsumed() { XCTAssertEqual(parse("오늘 내일 확인").title,"오늘 내일 확인") }
    func testInvalidClockPreserved() { let r = parse("오후 13시 연락"); XCTAssertNil(r.scheduledAt); XCTAssertNil(r.dayPeriod); XCTAssertEqual(r.title,"오후 13시 연락") }
    func testNoTitleAfterParsingUsesOriginal() { XCTAssertEqual(parse("내일 중요").title,"내일 중요") }
    func testDefaultSelectedDatePreserved() { let selected = try! TaskDay(value:"2026-11-01"); let r = QuickAddParser.parse("상품 등록", referenceDate:now, calendar:calendar, timeZone:calendar.timeZone, defaultDate:selected); XCTAssertEqual(r.scheduledDate,selected) }
    func testDSTTomorrowIsCalendarDay() {
        var c = calendar; c.timeZone = TimeZone(identifier:"America/Los_Angeles")!
        let reference = c.date(from:DateComponents(year:2026,month:3,day:7,hour:12))!
        let r = QuickAddParser.parse("내일 연락",referenceDate:reference,calendar:c,timeZone:c.timeZone)
        XCTAssertEqual(r.scheduledDate.value,"2026-03-08")
    }
}
