import Foundation

// Immutable values read from the backup; never retain live SwiftData models.
struct LegacyRecurrenceSnapshot {
    let id: UUID
    let title: String
    let notes: String?
    let groupID: UUID?
    let weekdayMask: Int
    let beginsOn: Date
    let deadlineDayOffset: Int?
    let startMinutes: Int?
    let deadlineMinutes: Int?
    @available(macOS 14.0, *)
    init(_ model: TodoRepeatSchedule) {
        id = model.id; title = model.title; notes = model.notes; groupID = model.groupID
        weekdayMask = model.weekdayMask; beginsOn = model.beginsOn
        deadlineDayOffset = model.deadlineDayOffset; startMinutes = model.startMinutes; deadlineMinutes = model.deadlineMinutes
    }
    func template(userID: UUID, groupID: UUID?, calendar: Calendar) throws -> TaskDraft {
        guard (0...127).contains(weekdayMask), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TaskServiceError.unsupportedLegacy }
        let day = TaskDay(beginsOn, calendar: calendar)
        let deadline = deadlineDayOffset.map { TaskDay(calendar.date(byAdding: .day, value: $0, to: day.date(calendar: calendar))!, calendar: calendar) }
        func time(_ minutes: Int?) throws -> Date? {
            guard let minutes else { return nil }
            guard (0..<1440).contains(minutes), let deadline else { throw TaskServiceError.unsupportedLegacy }
            guard let value = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: deadline.date(calendar: calendar)) else { throw TaskServiceError.unsupportedLegacy }
            return value
        }
        let draft = try TaskDraft(title: title, scheduledDate: day, groupID: groupID, deadlineDate: deadline,
            startAt: time(startMinutes), deadlineAt: time(deadlineMinutes), id: MigrationIdentity.id(kind: "repeat-template", userID: userID, sourceID: id), notes: notes, isRecurrenceTemplate: true)
        try draft.validate(); return draft
    }
    func rule(userID: UUID, calendar: Calendar) throws -> TaskRecurrence {
        let value = TaskRecurrence(id: MigrationIdentity.id(kind: "recurrence", userID: userID, sourceID: id),
            templateTaskID: MigrationIdentity.id(kind: "repeat-template", userID: userID, sourceID: id), weekdays: weekdayMask,
            startDate: TaskDay(beginsOn, calendar: calendar), endDate: nil, timezone: calendar.timeZone.identifier, isActive: weekdayMask != 0)
        try value.validate(); return value
    }
}
