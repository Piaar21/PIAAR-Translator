import Foundation

// Calendar weekday values (Sunday=1). JSON is explicitly versioned; unknown
// legacy repeatRule strings remain untouched until the user changes the rule.
struct TodoWeekdayRule: Codable, Equatable {
    var version = 1
    let weekdays: [Int]
    init(_ days: Set<Int>) { weekdays = days.filter { (1...7).contains($0) }.sorted() }
    var mask: Int { weekdays.reduce(0) { $0 | (1 << ($1 - 1)) } }
    func matches(_ date: Date, calendar: Calendar) -> Bool {
        weekdays.contains(calendar.component(.weekday, from: date))
    }
    var encoded: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func decode(_ value: String?) -> TodoWeekdayRule? {
        guard let value, let data = value.data(using: .utf8),
              let rule = try? JSONDecoder().decode(Self.self, from: data), rule.version == 1,
              Set(rule.weekdays).count == rule.weekdays.count,
              rule.weekdays.allSatisfy({ (1...7).contains($0) }) else { return nil }
        return rule
    }
}

enum TodoManagementError: LocalizedError {
    case invalidTimeRange, deadlineRequired, calendarDenied, calendarUnavailable, unsupported
    var errorDescription: String? {
        switch self {
        case .invalidTimeRange: return "마감 시간은 시작 시간보다 뒤여야 합니다."
        case .deadlineRequired: return "마감일을 먼저 설정해주세요."
        case .calendarDenied: return "캘린더 권한이 필요합니다. 시스템 설정의 개인정보 보호 및 보안에서 캘린더 접근을 허용해주세요."
        case .calendarUnavailable: return "사용 가능한 캘린더를 찾을 수 없습니다."
        case .unsupported: return "이 저장소에서는 해당 기능을 사용할 수 없습니다."
        }
    }
}

extension TodoDates {
    static func dDay(deadline: Date?, now: Date, calendar: Calendar) -> String? {
        guard let deadline else { return nil }
        let difference = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                                  to: calendar.startOfDay(for: deadline)).day ?? 0
        if difference == 0 { return "D-DAY" }
        return difference > 0 ? "D-\(difference)" : "D+\(-difference)"
    }
    static func sorted(_ values: [TodoSnapshot]) -> [TodoSnapshot] {
        values.sorted {
            if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

struct TodoGroupRGB: Equatable { let red: Double; let green: Double; let blue: Double; let alpha: Double }
enum TodoGroupColors {
    static let palette = ["#E05252", "#E78B35", "#C9AA32", "#4B9C69", "#4A78C2", "#9469BB", "#85858B"]
    static func rgb(_ hex: String?) -> TodoGroupRGB? {
        guard var text = hex?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6 || text.count == 8, let value = UInt32(text, radix: 16) else { return nil }
        let hasAlpha = text.count == 8
        let color = hasAlpha ? value >> 8 : value
        return TodoGroupRGB(red: Double((color >> 16) & 255) / 255, green: Double((color >> 8) & 255) / 255,
                            blue: Double(color & 255) / 255, alpha: hasAlpha ? Double(value & 255) / 255 : 1)
    }
}
struct TodoGroupSection: Identifiable {
    let group: TodoGroupSnapshot?
    let items: [TodoSnapshot]
    var id: UUID? { group?.id }
}

struct TodoEditorSession: Identifiable {
    let id = UUID()
    var todoID: UUID?
    var draft: TodoDraft
    var weekdays: Set<Int> = []
    var deadlineDay: Date?
    var start: Date?
    var end: Date?
    var linkCalendar = false
    var calendarID: String?
    init(date: Date, groupID: UUID? = nil) { draft = TodoDraft(date: date, groupID: groupID) }
    init(item: TodoSnapshot) {
        todoID = item.id; draft = TodoDraft(item)
        weekdays = Set(TodoWeekdayRule.decode(item.repeatRule)?.weekdays ?? [])
        deadlineDay = item.effectiveDeadlineDate
        start = item.startDateTime; end = item.deadlineDateTime
    }
}

struct TodoCalendarTiming: Equatable {
    let start: Date
    let end: Date
    let isAllDay: Bool
    static func make(day: Date?, start: Date?, end: Date?, calendar: Calendar) throws -> Self {
        guard let day else { throw TodoManagementError.deadlineRequired }
        if let start, let end {
            guard end > start else { throw TodoManagementError.invalidTimeRange }
            return Self(start: start, end: end, isAllDay: false)
        }
        if let start { return Self(start: start, end: start.addingTimeInterval(1800), isAllDay: false) }
        if let end { return Self(start: end.addingTimeInterval(-1800), end: end, isAllDay: false) }
        let interval = TodoDates.interval(for: day, calendar: calendar)
        return Self(start: interval.start, end: interval.end, isAllDay: true)
    }
}

// Transient input state only; these are not persisted SwiftData models.
struct TodoGroupQuickEntry {
    let groupID: UUID?
    var title = ""
}

struct TodoDeadlineDraft {
    var day: Date
    var start: Date?
    var end: Date?

    init(session: TodoEditorSession) {
        day = session.deadlineDay ?? session.draft.date
        start = session.start
        end = session.end
    }

    func apply(to session: inout TodoEditorSession, calendar: Calendar) throws {
        let startValue = combine(start, calendar: calendar)
        let endValue = combine(end, calendar: calendar)
        if let startValue, let endValue, endValue <= startValue {
            throw TodoManagementError.invalidTimeRange
        }
        session.deadlineDay = calendar.startOfDay(for: day)
        session.start = startValue
        session.end = endValue
    }

    private func combine(_ time: Date?, calendar: Calendar) -> Date? {
        guard let time else { return nil }
        return calendar.date(bySettingHour: calendar.component(.hour, from: time),
            minute: calendar.component(.minute, from: time), second: 0, of: day)
    }
}
