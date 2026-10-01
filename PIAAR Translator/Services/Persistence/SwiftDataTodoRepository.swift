import Foundation
import SwiftData

@MainActor
final class SwiftDataTodoRepository: TodoRepository {
    private let container: ModelContainer
    private var context: ModelContext
    private let clock: () -> Date
    private let saveContext: (ModelContext) throws -> Void

    init(container: ModelContainer, clock: @escaping () -> Date = Date.init,
         saveContext: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.container = container
        context = ModelContext(container)
        context.autosaveEnabled = false
        self.clock = clock
        self.saveContext = saveContext
    }

    func todos(matching filter: TodoFilter, now: Date, calendar: Calendar) throws -> [TodoSnapshot] {
        var predicate: Predicate<TodoItem>?
        switch filter {
        case .today, .day:
            let date: Date
            if case .day(let selected) = filter { date = selected } else { date = now }
            let interval = TodoDates.interval(for: date, calendar: calendar)
            let start = interval.start
            let end = interval.end
            predicate = #Predicate { !$0.isCompleted && $0.date >= start && $0.date < end }
        case .upcoming:
            let tomorrow = TodoDates.interval(for: now, calendar: calendar).end
            predicate = #Predicate { !$0.isCompleted && $0.date >= tomorrow }
        case .completed:
            predicate = #Predicate { $0.isCompleted }
        case .ungrouped:
            predicate = #Predicate { !$0.isCompleted && $0.group == nil }
        case .group(let id):
            predicate = #Predicate { !$0.isCompleted && $0.group?.id == id }
        }
        let sort: [SortDescriptor<TodoItem>]
        if filter == .completed {
            sort = [SortDescriptor(\TodoItem.completedAt, order: .reverse),
                    SortDescriptor(\TodoItem.createdAt, order: .reverse)]
        } else {
            sort = [SortDescriptor(\TodoItem.sortOrder), SortDescriptor(\TodoItem.createdAt)]
        }
        return try context.fetch(FetchDescriptor(predicate: predicate, sortBy: sort)).map(snapshot)
    }

    func groups() throws -> [TodoGroupSnapshot] {
        try context.fetch(FetchDescriptor<TodoGroup>(sortBy: [SortDescriptor(\TodoGroup.sortOrder),
                                                           SortDescriptor(\TodoGroup.createdAt)]))
            .map(groupSnapshot)
    }

    func create(_ draft: TodoDraft, calendar: Calendar) throws -> TodoSnapshot {
        let title = try validTitle(draft.title)
        let group = try findGroup(draft.groupID)
        let day = calendar.startOfDay(for: draft.date)
        let interval = TodoDates.interval(for: day, calendar: calendar)
        let start = interval.start
        let end = interval.end
        let siblings = try context.fetch(FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.date >= start && $0.date < end }))
            .filter { $0.group?.id == draft.groupID }
        let order = nextOrder(siblings.map(\.sortOrder))
        return try transaction {
            let item = TodoItem(title: title, notes: cleanNotes(draft.notes), date: day,
                                sortOrder: order, group: group, now: clock())
            context.insert(item)
            return snapshot(item)
        }
    }

    func update(todoID: UUID, draft: TodoDraft, calendar: Calendar) throws {
        let title = try validTitle(draft.title)
        let item = try findTodo(todoID)
        let group = try findGroup(draft.groupID)
        try transaction {
            item.title = title
            item.notes = cleanNotes(draft.notes)
            item.date = calendar.startOfDay(for: draft.date)
            item.group = group
            item.updatedAt = clock()
            if let schedule = try repeatSchedule(item.repeatScheduleID) {
                schedule.title = item.title
                schedule.notes = item.notes
                schedule.groupID = group?.id
                schedule.updatedAt = clock()
            }
        }
    }

    func delete(todoID: UUID) throws {
        let item = try findTodo(todoID)
        try transaction { context.delete(item) }
    }

    func complete(todoID: UUID) throws {
        let item = try findTodo(todoID)
        guard !item.isCompleted else { return }
        try transaction {
            let now = clock()
            item.isCompleted = true
            item.completedAt = now
            item.updatedAt = now
        }
    }

    func uncomplete(todoID: UUID) throws {
        let item = try findTodo(todoID)
        guard item.isCompleted else { return }
        try transaction {
            item.isCompleted = false
            item.completedAt = nil
            item.updatedAt = clock()
        }
    }

    func changeDate(todoID: UUID, date: Date, calendar: Calendar) throws {
        let item = try findTodo(todoID)
        try transaction {
            item.date = calendar.startOfDay(for: date)
            item.updatedAt = clock()
        }
    }

    func changeGroup(todoID: UUID, groupID: UUID?) throws {
        let item = try findTodo(todoID)
        let group = try findGroup(groupID)
        try transaction {
            item.group = group
            item.updatedAt = clock()
            if let schedule = try repeatSchedule(item.repeatScheduleID) {
                schedule.title = item.title
                schedule.notes = item.notes
                schedule.groupID = group?.id
                schedule.updatedAt = clock()
            }
        }
    }

    func setSortOrder(todoID: UUID, sortOrder: Int) throws {
        guard sortOrder >= 0 else { throw TodoStoreError.invalidOrder }
        let item = try findTodo(todoID)
        try transaction {
            item.sortOrder = sortOrder
            item.updatedAt = clock()
        }
    }

    func createGroup(name: String) throws -> TodoGroupSnapshot {
        let name = try validGroupName(name)
        let order = nextOrder(try groups().map(\.sortOrder))
        return try transaction {
            let group = TodoGroup(name: name, colorHex: "#4A78C2", sortOrder: order, now: clock())
            context.insert(group)
            return groupSnapshot(group)
        }
    }

    func renameGroup(groupID: UUID, name: String) throws {
        let name = try validGroupName(name)
        guard let group = try findGroup(groupID) else { throw TodoStoreError.groupNotFound }
        try transaction {
            group.name = name
            group.updatedAt = clock()
        }
    }

    func deleteGroup(groupID: UUID) throws {
        guard let group = try findGroup(groupID) else { throw TodoStoreError.groupNotFound }
        let id = groupID
        let items = try context.fetch(FetchDescriptor<TodoItem>(predicate: #Predicate { $0.group?.id == id }))
        try transaction {
            let now = clock()
            // Explicitly detach even completed items; nullify is also the model's delete rule.
            for item in items {
                item.group = nil
                item.updatedAt = now
            }
            context.delete(group)
        }
    }

    func setGroupSortOrder(groupID: UUID, sortOrder: Int) throws {
        guard sortOrder >= 0 else { throw TodoStoreError.invalidOrder }
        guard let group = try findGroup(groupID) else { throw TodoStoreError.groupNotFound }
        try transaction {
            group.sortOrder = sortOrder
            group.updatedAt = clock()
        }
    }

    func createColoredGroup(name: String, colorHex: String) throws -> TodoGroupSnapshot {
        guard TodoGroupColors.rgb(colorHex) != nil else { throw TodoManagementError.unsupported }
        return try transaction {
            let group = try createGroup(name: name)
            let model = try findGroup(group.id)!
            model.colorHex = colorHex
            return groupSnapshot(model)
        }
    }

    func saveManagedTodo(id: UUID?, draft: TodoDraft, deadlineDay: Date?, start: Date?, end: Date?,
                         weekdays: Set<Int>, calendar: Calendar) throws -> TodoSnapshot {
        if let start, let end, end <= start { throw TodoManagementError.invalidTimeRange }
        if start != nil || end != nil {
            guard let day = deadlineDay,
                  start.map({ calendar.isDate($0, inSameDayAs: day) }) ?? true,
                  end.map({ calendar.isDate($0, inSameDayAs: day) }) ?? true else {
                throw TodoManagementError.invalidTimeRange
            }
        }
        return try transaction {
            let savedID: UUID
            if let id {
                let existing = try findTodo(id)
                let preservedNotes = existing.notes
                let preservedDate = existing.date
                try update(todoID: id, draft: draft, calendar: calendar)
                existing.notes = preservedNotes
                existing.date = preservedDate
                savedID = id
            }
            else { savedID = try create(draft, calendar: calendar).id }
            let item = try findTodo(savedID)
            item.deadlineDate = deadlineDay.map { calendar.startOfDay(for: $0) }
            item.startDateTime = deadlineDay == nil ? nil : start
            item.deadlineDateTime = deadlineDay == nil ? nil : end
            item.updatedAt = clock()
            // Preserve unknown historical rules when no rule was explicitly changed.
            if TodoWeekdayRule.decode(item.repeatRule)?.weekdays != TodoWeekdayRule(weekdays).weekdays,
               !(weekdays.isEmpty && item.repeatRule != nil && TodoWeekdayRule.decode(item.repeatRule) == nil) {
                try setRepeat(todoID: savedID, weekdays: weekdays, calendar: calendar)
            }
            if let schedule = try repeatSchedule(item.repeatScheduleID) {
                schedule.notes = item.notes
                updateDeadlineTemplate(schedule, from: item, calendar: calendar)
            }
            return snapshot(item)
        }
    }

    func allTodos() throws -> [TodoSnapshot] {
        try context.fetch(FetchDescriptor<TodoItem>()).map(snapshot)
    }

    func setDeadline(todoID: UUID, start: Date?, deadline: Date?, calendar: Calendar) throws {
        if let start {
            guard let deadline, deadline > start, calendar.isDate(start, inSameDayAs: deadline) else {
                throw TodoManagementError.invalidTimeRange
            }
        }
        let item = try findTodo(todoID)
        try transaction {
            item.startDateTime = deadline == nil ? nil : start
            item.deadlineDateTime = deadline
            item.deadlineDate = deadline.map { calendar.startOfDay(for: $0) }
            item.updatedAt = clock()
            if let schedule = try repeatSchedule(item.repeatScheduleID) {
                updateDeadlineTemplate(schedule, from: item, calendar: calendar)
                schedule.updatedAt = clock()
            }
        }
    }

    func setCalendarEventID(todoID: UUID, identifier: String?) throws {
        let item = try findTodo(todoID)
        try transaction { item.linkedCalendarEventID = identifier; item.updatedAt = clock() }
    }

    func setRepeat(todoID: UUID, weekdays: Set<Int>, calendar: Calendar) throws {
        let item = try findTodo(todoID)
        let rule = TodoWeekdayRule(weekdays)
        try transaction {
            let existing = try repeatSchedule(item.repeatScheduleID)
            if rule.weekdays.isEmpty {
                existing?.weekdayMask = 0
                existing?.updatedAt = clock()
                // Existing instances and their completion records remain intact.
                if let id = item.repeatScheduleID {
                    let siblings = try context.fetch(FetchDescriptor<TodoItem>(predicate: #Predicate { $0.repeatScheduleID == id }))
                    for sibling in siblings { sibling.repeatRule = nil; sibling.updatedAt = clock() }
                } else { item.repeatRule = nil }
                return
            }
            let schedule = existing ?? TodoRepeatSchedule(title: item.title, beginsOn: item.date, now: clock())
            if existing == nil { context.insert(schedule) }
            schedule.title = item.title
            schedule.notes = item.notes
            schedule.groupID = item.group?.id
            schedule.weekdayMask = rule.mask
            schedule.updatedAt = clock()
            updateDeadlineTemplate(schedule, from: item, calendar: calendar)
            item.repeatScheduleID = schedule.id
            item.repeatRule = rule.encoded
            item.updatedAt = clock()
            let id = schedule.id
            let siblings = try context.fetch(FetchDescriptor<TodoItem>(predicate: #Predicate { $0.repeatScheduleID == id }))
            for sibling in siblings { sibling.repeatRule = rule.encoded; sibling.updatedAt = clock() }
        }
    }

    // Generate only the requested current day, never an unbounded future series.
    // The shared main-actor repository serializes checks and saves atomically.
    func materializeRepeats(on date: Date, calendar: Calendar) throws {
        let day = calendar.startOfDay(for: date)
        guard day == calendar.startOfDay(for: clock()) else { return }
        let weekday = calendar.component(.weekday, from: day)
        let schedules = try context.fetch(FetchDescriptor<TodoRepeatSchedule>())
            .filter { $0.beginsOn <= day && ($0.weekdayMask & (1 << (weekday - 1))) != 0 }
        let interval = TodoDates.interval(for: day, calendar: calendar)
        let start = interval.start
        let end = interval.end
        let existing = try context.fetch(FetchDescriptor<TodoItem>(predicate: #Predicate { $0.date >= start && $0.date < end }))
        let generated = Set(existing.compactMap(\.repeatScheduleID))
        let missing = schedules.filter { !generated.contains($0.id) }
        guard !missing.isEmpty else { return }
        try transaction {
            var order = nextOrder(existing.map(\.sortOrder))
            for schedule in missing.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                // A deleted group must not prevent the daily instance from appearing.
                let group = try? findGroup(schedule.groupID)
                let item = TodoItem(title: schedule.title, notes: schedule.notes, date: day,
                                    sortOrder: order, group: group ?? nil, now: clock())
                item.repeatScheduleID = schedule.id
                let days = Set((1...7).filter { (schedule.weekdayMask & (1 << ($0 - 1))) != 0 })
                item.repeatRule = TodoWeekdayRule(days).encoded
                if let offset = schedule.deadlineDayOffset,
                   let dueDay = calendar.date(byAdding: .day, value: offset, to: day) {
                    item.deadlineDate = calendar.startOfDay(for: dueDay)
                    if let minutes = schedule.deadlineMinutes {
                        item.deadlineDateTime = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: dueDay)
                    }
                    if let minutes = schedule.startMinutes {
                        item.startDateTime = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: dueDay)
                    }
                }
                context.insert(item)
                if order < Int.max { order += 1 }
            }
        }
    }

    private func repeatSchedule(_ id: UUID?) throws -> TodoRepeatSchedule? {
        guard let id else { return nil }
        return try context.fetch(FetchDescriptor<TodoRepeatSchedule>(predicate: #Predicate { $0.id == id })).first
    }

    private func updateDeadlineTemplate(_ schedule: TodoRepeatSchedule, from item: TodoItem, calendar: Calendar) {
        guard let deadline = item.deadlineDate ?? item.deadlineDateTime else {
            schedule.deadlineDayOffset = nil; schedule.deadlineMinutes = nil; schedule.startMinutes = nil
            return
        }
        schedule.deadlineDayOffset = calendar.dateComponents([.day], from: calendar.startOfDay(for: item.date),
                                                              to: calendar.startOfDay(for: deadline)).day
        schedule.deadlineMinutes = item.deadlineDateTime.map { calendar.component(.hour, from: $0) * 60 + calendar.component(.minute, from: $0) }
        schedule.startMinutes = item.startDateTime.map { calendar.component(.hour, from: $0) * 60 + calendar.component(.minute, from: $0) }
    }

    private var transactionDepth = 0

    private func transaction<T>(_ operation: () throws -> T) throws -> T {
        if transactionDepth > 0 { return try operation() }
        transactionDepth += 1
        defer { transactionDepth -= 1 }
        do {
            let result = try operation()
            try saveContext(context)
            return result
        } catch {
            context.rollback()
            // SwiftData can retain stale registered model values after rollback.
            // UI receives snapshots, so discard this context and read saved data afresh.
            context = ModelContext(container)
            context.autosaveEnabled = false
            throw error
        }
    }

    private func findTodo(_ id: UUID) throws -> TodoItem {
        var descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let item = try context.fetch(descriptor).first else { throw TodoStoreError.todoNotFound }
        return item
    }

    private func findGroup(_ id: UUID?) throws -> TodoGroup? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<TodoGroup>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let group = try context.fetch(descriptor).first else { throw TodoStoreError.groupNotFound }
        return group
    }

    private func validTitle(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw TodoStoreError.emptyTitle }
        return value
    }

    private func validGroupName(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw TodoStoreError.emptyGroupName }
        return value
    }

    private func cleanNotes(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func nextOrder(_ values: [Int]) -> Int {
        guard let last = values.max() else { return 0 }
        return last < Int.max ? last + 1 : last
    }

    private func snapshot(_ item: TodoItem) -> TodoSnapshot {
        TodoSnapshot(id: item.id, title: item.title, notes: item.notes, date: item.date,
                     isCompleted: item.isCompleted, completedAt: item.completedAt,
                     createdAt: item.createdAt, updatedAt: item.updatedAt,
                     sortOrder: item.sortOrder, groupID: item.group?.id,
                     deadlineDate: item.deadlineDate, repeatRule: item.repeatRule, linkedCalendarEventID: item.linkedCalendarEventID,
                     startDateTime: item.startDateTime, deadlineDateTime: item.deadlineDateTime,
                     repeatScheduleID: item.repeatScheduleID)
    }

    private func groupSnapshot(_ group: TodoGroup) -> TodoGroupSnapshot {
        TodoGroupSnapshot(id: group.id, name: group.name, colorHex: group.colorHex, sortOrder: group.sortOrder)
    }
}
