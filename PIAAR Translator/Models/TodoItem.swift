import Foundation
import SwiftData

@Model
final class TodoItem {
    // Defaults and optional relationships leave room for a future sync migration.
    // No uniqueness constraint: IDs are assigned by the repository.
    var id: UUID = UUID()
    var title: String = ""
    var notes: String?
    var date: Date = Date()
    var isCompleted: Bool = false
    var completedAt: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var sortOrder: Int = 0
    var repeatRule: String?
    var linkedCalendarEventID: String?
    var deadlineDate: Date?
    var startDateTime: Date?
    var deadlineDateTime: Date?
    var repeatScheduleID: UUID?
    var group: TodoGroup?

    init(title: String, notes: String? = nil, date: Date, sortOrder: Int = 0,
         group: TodoGroup? = nil, now: Date = Date()) {
        self.title = title
        self.notes = notes
        self.date = date
        self.sortOrder = sortOrder
        self.group = group
        self.createdAt = now
        self.updatedAt = now
    }
}
