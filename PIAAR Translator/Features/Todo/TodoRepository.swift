import Foundation

@MainActor
protocol TodoRepository {
    func todos(matching filter: TodoFilter, now: Date, calendar: Calendar) throws -> [TodoSnapshot]
    func saveManagedTodo(id: UUID?, draft: TodoDraft, deadlineDay: Date?, start: Date?, end: Date?, weekdays: Set<Int>, calendar: Calendar) throws -> TodoSnapshot
    func createColoredGroup(name: String, colorHex: String) throws -> TodoGroupSnapshot
    func allTodos() throws -> [TodoSnapshot]
    func setDeadline(todoID: UUID, start: Date?, deadline: Date?, calendar: Calendar) throws
    func setRepeat(todoID: UUID, weekdays: Set<Int>, calendar: Calendar) throws
    func materializeRepeats(on date: Date, calendar: Calendar) throws
    func setCalendarEventID(todoID: UUID, identifier: String?) throws
    func groups() throws -> [TodoGroupSnapshot]
    func create(_ draft: TodoDraft, calendar: Calendar) throws -> TodoSnapshot
    func update(todoID: UUID, draft: TodoDraft, calendar: Calendar) throws
    func delete(todoID: UUID) throws
    func complete(todoID: UUID) throws
    func uncomplete(todoID: UUID) throws
    func changeDate(todoID: UUID, date: Date, calendar: Calendar) throws
    func changeGroup(todoID: UUID, groupID: UUID?) throws
    func setSortOrder(todoID: UUID, sortOrder: Int) throws
    func createGroup(name: String) throws -> TodoGroupSnapshot
    func renameGroup(groupID: UUID, name: String) throws
    func deleteGroup(groupID: UUID) throws
    func setGroupSortOrder(groupID: UUID, sortOrder: Int) throws
}

// Keep existing alternative repositories source compatible; unsupported management
// operations fail explicitly rather than silently discarding changes.
extension TodoRepository {
    func saveManagedTodo(id: UUID?, draft: TodoDraft, deadlineDay: Date?, start: Date?, end: Date?, weekdays: Set<Int>, calendar: Calendar) throws -> TodoSnapshot { throw TodoManagementError.unsupported }
    func createColoredGroup(name: String, colorHex: String) throws -> TodoGroupSnapshot { throw TodoManagementError.unsupported }
    func allTodos() throws -> [TodoSnapshot] { throw TodoManagementError.unsupported }
    func setDeadline(todoID: UUID, start: Date?, deadline: Date?, calendar: Calendar) throws { throw TodoManagementError.unsupported }
    func setRepeat(todoID: UUID, weekdays: Set<Int>, calendar: Calendar) throws { throw TodoManagementError.unsupported }
    func materializeRepeats(on date: Date, calendar: Calendar) throws {}
    func setCalendarEventID(todoID: UUID, identifier: String?) throws { throw TodoManagementError.unsupported }
}
