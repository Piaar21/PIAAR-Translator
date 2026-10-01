import Foundation
import SwiftData

// A persistent template, independent of the completion state of daily instances.
// Scalar defaults and no uniqueness constraints permit a future CloudKit migration.
@Model
final class TodoRepeatSchedule {
    var id: UUID = UUID()
    var title: String = ""
    var notes: String?
    var groupID: UUID?
    var weekdayMask: Int = 0
    var beginsOn: Date = Date()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var deadlineDayOffset: Int?
    var startMinutes: Int?
    var deadlineMinutes: Int?

    init(title: String, beginsOn: Date, now: Date) {
        self.title = title
        self.beginsOn = beginsOn
        self.createdAt = now
        self.updatedAt = now
    }
}
