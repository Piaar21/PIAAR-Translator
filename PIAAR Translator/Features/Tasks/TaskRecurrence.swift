import Foundation
import Supabase

struct TaskRecurrence: Codable, Equatable, Identifiable {
    let id: UUID
    let templateTaskID: UUID
    var weekdays: Int
    let startDate: TaskDay
    let endDate: TaskDay?
    let timezone: String
    var isActive: Bool
    enum CodingKeys: String, CodingKey {
        case id, weekdays, timezone
        case templateTaskID = "template_task_id", startDate = "start_date", endDate = "end_date", isActive = "is_active"
    }
    func validate() throws {
        guard (0...127).contains(weekdays), TimeZone(identifier: timezone) != nil,
              endDate == nil || endDate! >= startDate else { throw TaskServiceError.invalidData }
    }
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: timezone)!; return c
    }
    func includes(_ day: TaskDay) -> Bool {
        isActive && day >= startDate && (endDate == nil || day <= endDate!) &&
        weekdays & (1 << (calendar.component(.weekday, from: day.date(calendar: calendar)) - 1)) != 0
    }
}
// Only SQL unique violations can reconcile a competing insert. RLS/FK/network errors propagate.
enum RecurrenceConflict {
    static func isUnique(_ error: Error) -> Bool { (error as? PostgrestError)?.code == "23505" }
    @MainActor static func reuse<T>(error: Error, fetch: () async throws -> T?) async throws -> T {
        guard isUnique(error), let existing = try await fetch() else { throw error }; return existing
    }
}
@MainActor protocol RecurrenceRepository {
    var userID: UUID { get }
    func rules() async throws -> [TaskRecurrence]
    func rule(templateID: UUID) async throws -> TaskRecurrence?
    func create(_ rule: TaskRecurrence) async throws -> TaskRecurrence
    func deactivate(id: UUID) async throws
}
@MainActor final class TaskRecurrenceService {
    let tasks: TaskRepository
    let repository: RecurrenceRepository
    private var importingLegacy = false
    func beginLegacyImport() throws { guard !importingLegacy else { throw TaskServiceError.unavailable }; importingLegacy = true }
    func endLegacyImport() { importingLegacy = false }
    private let events: TaskEventQueue?
    private let actorName: () -> String?
    init(tasks: TaskRepository, repository: RecurrenceRepository, events: TaskEventQueue? = nil, actorName: @escaping () -> String? = { nil }) {
        self.tasks = tasks; self.repository = repository; self.events = events; self.actorName = actorName
    }
    func prepare(template: TaskDraft, rule: TaskRecurrence, beforeRequest: () async throws -> Void = {}) async throws -> TaskRecurrence {
        guard tasks.userID == repository.userID, template.id == rule.templateTaskID,
              template.isRecurrenceTemplate, template.recurrenceID == nil else { throw TaskServiceError.invalidData }
        try rule.validate()
        try await beforeRequest()
        if let existing = try await tasks.fetchTask(id: template.id) {
            guard existing.createdBy == tasks.userID, existing.isRecurrenceTemplate else { throw TaskServiceError.permission }
        } else { try await beforeRequest(); _ = try await tasks.createTask(template) }
        try await beforeRequest()
        if let existing = try await repository.rule(templateID: template.id) { return existing }
        try await beforeRequest()
        return try await repository.create(rule)
    }
    func instance(_ rule: TaskRecurrence, day: TaskDay, legacy: TaskDraft? = nil, beforeRequest: () async throws -> Void = {}) async throws -> WorkTask {
        try rule.validate()
        try await beforeRequest()
        guard let template = try await tasks.fetchTask(id: rule.templateTaskID), template.isRecurrenceTemplate,
              template.createdBy == tasks.userID, template.assignedTo == tasks.userID else { throw TaskServiceError.permission }
        try await beforeRequest()
        if let existing = try await tasks.recurrenceInstance(id: rule.id, day: day) { return existing }
        var draft = try legacy ?? Self.draft(template: template, rule: rule, day: day)
        draft.recurrenceID = rule.id; draft.isRecurrenceTemplate = false; draft.scheduledDate = day
        let name = actorName()
        try await beforeRequest()
        let saved = try await tasks.createTask(draft)
        if legacy == nil, let events { await events.enqueue(TaskEventRequest.creationEvents(task: saved, actorID: tasks.userID, displayName: name)) }
        return saved
    }
    func materializeToday(now: Date) async throws {
        guard !importingLegacy else { return }
        for rule in try await repository.rules() {
            guard !importingLegacy else { return }
            try rule.validate()
            let day = TaskDay(now, calendar: rule.calendar)
            if rule.includes(day) {
                do {
                    _ = try await instance(rule, day: day, beforeRequest: {
                        guard !self.importingLegacy else { throw CancellationError() }
                    })
                } catch is CancellationError { return }
            }
        }
    }
    func deactivate(id: UUID) async throws { try await repository.deactivate(id: id) }
    static func draft(template: WorkTask, rule: TaskRecurrence, day: TaskDay) throws -> TaskDraft {
        let c = rule.calendar
        guard let templateDay = template.scheduledDate else { throw TaskServiceError.invalidData }
        let deadline = template.deadlineDate.map { old in
            let offset = c.dateComponents([.day], from: templateDay.date(calendar: c), to: old.date(calendar: c)).day!
            return TaskDay(c.date(byAdding: .day, value: offset, to: day.date(calendar: c))!, calendar: c)
        }
        func time(_ old: Date?) throws -> Date? {
            guard let old else { return nil }
            guard let deadline else { throw TaskServiceError.invalidData }
            let parts = c.dateComponents([.hour, .minute, .second], from: old)
            guard let result = c.date(bySettingHour: parts.hour!, minute: parts.minute!, second: parts.second!, of: deadline.date(calendar: c)) else { throw TaskServiceError.invalidData }
            return result
        }
        let draft = try TaskDraft(title: template.title, scheduledDate: day, groupID: template.groupID,
            deadlineDate: deadline, startAt: time(template.startAt), deadlineAt: time(template.deadlineAt), notes: template.notes, recurrenceID: rule.id)
        try draft.validate(); return draft
    }
}

extension RecurrenceRepository {
    func ruleIfTemplateExists(scheduleID: UUID, tasks: TaskRepository) async throws -> TaskRecurrence? {
        let id = MigrationIdentity.id(kind: "repeat-template", userID: userID, sourceID: scheduleID)
        guard try await tasks.fetchTask(id: id) != nil else { return nil }
        return try await rule(templateID: id)
    }
}
