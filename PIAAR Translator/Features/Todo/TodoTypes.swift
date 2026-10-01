import Foundation

// Value snapshots keep SwiftData objects and unsaved changes out of the UI.
struct TodoSnapshot: Identifiable, Equatable {
    let id: UUID
    let title: String
    let notes: String?
    let date: Date
    let isCompleted: Bool
    let completedAt: Date?
    let createdAt: Date
    let updatedAt: Date
    let sortOrder: Int
    let groupID: UUID?
    var deadlineDate: Date? = nil
    var repeatRule: String? = nil
    var linkedCalendarEventID: String? = nil
    var startDateTime: Date? = nil
    var deadlineDateTime: Date? = nil
    var repeatScheduleID: UUID? = nil
}

extension TodoSnapshot {
    // Existing V2 deadlines retain their exact time and remain readable.
    var effectiveDeadlineDate: Date? { deadlineDate ?? deadlineDateTime }
}

struct TodoGroupSnapshot: Identifiable, Equatable {
    let id: UUID
    let name: String
    let colorHex: String?
    let sortOrder: Int
}

struct TodoDraft: Equatable {
    var title: String = ""
    var notes: String = ""
    var date: Date = Date()
    var groupID: UUID?

    init(title: String = "", notes: String = "", date: Date = Date(), groupID: UUID? = nil) {
        self.title = title
        self.notes = notes
        self.date = date
        self.groupID = groupID
    }

    init(_ todo: TodoSnapshot) {
        title = todo.title
        notes = todo.notes ?? ""
        date = todo.date
        groupID = todo.groupID
    }

    var hasTitle: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

enum TodoFilter: Hashable {
    case today
    case day(Date)
    case upcoming
    case completed
    case ungrouped
    case group(UUID)
}

// Use calendar day boundaries, never a fixed 86,400-second offset (DST).
enum TodoDates {
    static func interval(for date: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return DateInterval(start: start, end: end)
    }
}

enum TodoStoreError: LocalizedError {
    case emptyTitle
    case emptyGroupName
    case todoNotFound
    case groupNotFound
    case invalidOrder

    var errorDescription: String? {
        switch self {
        case .emptyTitle: return "할 일 제목을 입력해주세요."
        case .emptyGroupName: return "그룹 이름을 입력해주세요."
        case .todoNotFound: return "할 일을 찾을 수 없습니다. 목록을 새로고침해주세요."
        case .groupNotFound: return "그룹을 찾을 수 없습니다. 그룹을 다시 선택해주세요."
        case .invalidOrder: return "정렬 순서는 0 이상의 값이어야 합니다."
        }
    }
}
