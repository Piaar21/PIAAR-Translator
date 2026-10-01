import Foundation
import Combine

@MainActor
final class TodoViewModel: ObservableObject {
    @Published private(set) var filter: TodoFilter = .today
    @Published private(set) var items: [TodoSnapshot] = []
    @Published private(set) var todayItems: [TodoSnapshot] = []
    @Published private(set) var todayDate: Date = Date()
    @Published private(set) var groups: [TodoGroupSnapshot] = []
    @Published private(set) var selectedID: UUID?
    @Published var draft = TodoDraft()
    @Published var errorMessage: String?
    @Published private(set) var groupQuickEntry: TodoGroupQuickEntry?
    @Published private(set) var groupQuickFocusRequest = 0
    @Published var quickTitle = ""
    @Published private(set) var quickFocusRequest = 0
    @Published private(set) var quickWantsFocus = false
    @Published private(set) var fullDate: Date = Date()
    @Published private(set) var fullItems: [TodoSnapshot] = []
    @Published private(set) var overdueDays: Set<Date> = []
    @Published private(set) var calendarOptions: [TodoCalendarOption] = []
    @Published private(set) var calendarBusy = false
    @Published var calendarError: String?
    @Published var fullEditor: TodoEditorSession?
    @Published var editorError: String?
    private var followsToday = true
    private let calendarService: TodoCalendarService
    private var pendingCalendarIDs: [UUID: String] = [:]
    private var savedDraft: TodoDraft?
    private let repository: TodoRepository
    private let clock: () -> Date
    var calendar: Calendar

    init(repository: TodoRepository, calendar: Calendar = .autoupdatingCurrent,
         clock: @escaping () -> Date = Date.init,
         calendarService: TodoCalendarService? = nil) throws {
        self.repository = repository
        self.calendar = calendar
        self.clock = clock
        self.calendarService = calendarService ?? AppleTodoCalendarService()
        fullDate = calendar.startOfDay(for: clock())
        try reload()
    }

    var selectedItem: TodoSnapshot? { items.first { $0.id == selectedID } }
    var hasUnsavedChanges: Bool { selectedID != nil && savedDraft != draft }
    var selectedDate: Date {
        if case .day(let date) = filter { return calendar.startOfDay(for: date) }
        return calendar.startOfDay(for: clock())
    }
    var defaultGroupID: UUID? {
        if case .group(let id) = filter { return id }
        return nil
    }
    var title: String {
        switch filter {
        case .today: return "오늘"
        case .day: return "할 일"
        case .upcoming: return "예정"
        case .completed: return "완료"
        case .ungrouped: return "그룹 없음"
        case .group(let id): return groups.first { $0.id == id }?.name ?? "그룹"
        }
    }

    // Window requests are observable so focus also works after lazy store loading.
    func prepareForQuickEntry(windowWasActive: Bool) {
        guard !hasUnsavedChanges,
              !(windowWasActive && selectedID != nil) else { return }
        if !quickTitle.isEmpty {
            requestQuickFocus()
            return
        }
        selectFilter(.today)
        selectTodo(nil)
        requestQuickFocus()
    }

    func requestQuickFocus() {
        quickWantsFocus = true
        quickFocusRequest += 1
    }

    @discardableResult
    func submitQuickEntry() -> Bool {
        guard !quickTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard create(TodoDraft(title: quickTitle, date: selectedDate, groupID: defaultGroupID)) else { return false }
        quickTitle = ""
        selectTodo(nil)
        requestQuickFocus()
        return true
    }

    // The minimal UI always creates today, independently of legacy filters.
    @discardableResult
    func submitTodayQuickEntry() -> Bool {
        guard !quickTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        do {
            _ = try repository.create(TodoDraft(title: quickTitle, date: clock()), calendar: calendar)
            quickTitle = ""
            try reload()
            errorMessage = nil
            requestQuickFocus()
            return true
        } catch { report(error); return false }
    }

    func cancelQuickEntry() {
        quickTitle = ""
        quickWantsFocus = false
        quickFocusRequest += 1
    }

    @discardableResult
    func closeInspector() -> Bool {
        guard saveDraftIfNeeded() else { return false }
        selectTodo(nil)
        return true
    }

    func moveDay(by offset: Int) {
        guard let date = calendar.date(byAdding: .day, value: offset, to: selectedDate) else { return }
        selectFilter(calendar.isDate(date, inSameDayAs: clock()) ? .today : .day(date))
    }

    func groupName(for item: TodoSnapshot) -> String {
        groups.first { $0.id == item.groupID }?.name ?? "그룹 없음"
    }

    func selectTodo(_ id: UUID?) {
        guard id != selectedID, saveDraftIfNeeded() else { return }
        loadSelection(id)
    }

    func selectFilter(_ requestedFilter: TodoFilter) {
        let filter: TodoFilter
        if case .day(let date) = requestedFilter {
            filter = .day(calendar.startOfDay(for: date))
        } else {
            filter = requestedFilter
        }
        guard filter != self.filter, saveDraftIfNeeded() else { return }
        self.filter = filter
        loadSelection(nil)
        refresh()
    }

    func refresh() {
        // A midnight/time-zone refresh must never discard an unfinished edit.
        guard !hasUnsavedChanges else { return }
        do { try reload(preserveDraft: true) }
        catch { report(error) }
    }

    @discardableResult
    func saveDraftIfNeeded() -> Bool {
        guard hasUnsavedChanges, let id = selectedID else { return true }
        do {
            try repository.update(todoID: id, draft: draft, calendar: calendar)
            savedDraft = draft
            try reload()
            errorMessage = nil
            return true
        } catch { report(error); return false }
    }

    func discardDraft() { loadSelection(selectedID) }

    @discardableResult
    func create(_ newDraft: TodoDraft) -> Bool {
        guard saveDraftIfNeeded() else { return false }
        do {
            let item = try repository.create(newDraft, calendar: calendar)
            // Keep the new item visible even when created from Completed or another day.
            if filter == .completed || filter == .upcoming ||
                !calendar.isDate(item.date, inSameDayAs: selectedDate) {
                filter = .day(item.date)
            } else if case .group(let id) = filter, id != item.groupID {
                filter = .day(item.date)
            } else if filter == .ungrouped, item.groupID != nil {
                filter = .day(item.date)
            }
            try reload()
            loadSelection(item.id)
            errorMessage = nil
            return true
        } catch { report(error); return false }
    }

    func toggleCompletion(_ item: TodoSnapshot) {
        // SwiftUI may still hold the previous snapshot during rapid consecutive clicks.
        let current = fullItems.first { $0.id == item.id } ?? todayItems.first { $0.id == item.id }
            ?? items.first { $0.id == item.id } ?? item
        setCompleted(current, completed: !current.isCompleted)
    }

    func setCompleted(_ item: TodoSnapshot, completed: Bool) {
        guard saveDraftIfNeeded() else { return }
        perform {
            if completed { try repository.complete(todoID: item.id) }
            else { try repository.uncomplete(todoID: item.id) }
        }
    }

    func delete(_ item: TodoSnapshot) {
        // Discard only the confirmed deletion's draft; save unrelated edits first.
        if item.id != selectedID && !saveDraftIfNeeded() { return }
        perform { try repository.delete(todoID: item.id) }
    }

    @discardableResult
    func saveGroup(id: UUID?, name: String) -> Bool {
        guard saveDraftIfNeeded() else { return false }
        do {
            if let id { try repository.renameGroup(groupID: id, name: name) }
            else { _ = try repository.createGroup(name: name) }
            try reload()
            errorMessage = nil
            return true
        } catch { report(error); return false }
    }

    func deleteGroup(_ group: TodoGroupSnapshot) {
        guard saveDraftIfNeeded() else { return }
        do {
            try repository.deleteGroup(groupID: group.id)
            if filter == .group(group.id) { filter = .ungrouped }
            try reload()
        } catch { report(error) }
    }

    func openFullToday() {
        followsToday = true
        fullDate = calendar.startOfDay(for: clock())
        refresh()
    }

    func selectFullDate(_ date: Date) {
        fullDate = calendar.startOfDay(for: date)
        followsToday = calendar.isDate(fullDate, inSameDayAs: clock())
        refresh()
    }

    func beginGroupQuickEntry(groupID: UUID?) {
        groupQuickEntry = TodoGroupQuickEntry(groupID: groupID)
        groupQuickFocusRequest += 1
    }

    func updateGroupQuickTitle(_ title: String) { groupQuickEntry?.title = title }
    func cancelGroupQuickEntry() { groupQuickEntry = nil }
    func focusFullQuickEntry() {
        cancelGroupQuickEntry()
        requestQuickFocus()
    }

    @discardableResult
    func submitGroupQuickEntry() -> Bool {
        guard let entry = groupQuickEntry,
              !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        do {
            _ = try repository.create(TodoDraft(title: entry.title, date: fullDate, groupID: entry.groupID), calendar: calendar)
            try reload()
            groupQuickEntry = nil
            errorMessage = nil
            requestQuickFocus()
            return true
        } catch { report(error); return false }
    }

    func submitFullQuickEntry() -> Bool {
        guard !quickTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        do {
            _ = try repository.create(TodoDraft(title: quickTitle, date: fullDate), calendar: calendar)
            quickTitle = ""
            try reload()
            errorMessage = nil
            requestQuickFocus()
            return true
        } catch { report(error); return false }
    }

    func changeFullGroup(_ item: TodoSnapshot, groupID: UUID?) {
        perform { try repository.changeGroup(todoID: item.id, groupID: groupID) }
    }
    func changeRepeat(_ item: TodoSnapshot, weekdays: Set<Int>) {
        perform { try repository.setRepeat(todoID: item.id, weekdays: weekdays, calendar: calendar) }
    }
    @discardableResult
    func changeDeadline(_ item: TodoSnapshot, start: Date?, deadline: Date?) -> Bool {
        do {
            try repository.setDeadline(todoID: item.id, start: start, deadline: deadline, calendar: calendar)
            try reload(); errorMessage = nil
            return true
        } catch { report(error); return false }
    }
    func dDay(_ item: TodoSnapshot) -> String? {
        TodoDates.dDay(deadline: item.effectiveDeadlineDate, now: clock(), calendar: calendar)
    }

    var fullSections: [TodoGroupSection] {
        let ordered = groups.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.id.uuidString < $1.id.uuidString
        }
        let known = Set(ordered.map(\.id))
        return ordered.map { group in TodoGroupSection(group: group, items: TodoDates.sorted(fullItems.filter { $0.groupID == group.id })) }
            + [TodoGroupSection(group: nil, items: TodoDates.sorted(fullItems.filter { $0.groupID == nil || !known.contains($0.groupID!) }))]
    }
    func colorHex(for item: TodoSnapshot) -> String? { groups.first { $0.id == item.groupID }?.colorHex }
    func beginFullEditing(_ item: TodoSnapshot) {
        guard fullEditor == nil else { return }
        editorError = nil
        calendarError = nil
        fullEditor = TodoEditorSession(item: item)
    }
    func createFullGroup(name: String, colorHex: String) -> TodoGroupSnapshot? {
        do {
            let group = try repository.createColoredGroup(name: name, colorHex: colorHex)
            try reload(); editorError = nil
            return group
        } catch { editorError = error.localizedDescription; return nil }
    }
    func saveFullEditor(_ session: TodoEditorSession) -> TodoSnapshot? {
        do {
            let item = try repository.saveManagedTodo(id: session.todoID, draft: session.draft,
                deadlineDay: session.deadlineDay, start: session.start, end: session.end,
                weekdays: session.weekdays, calendar: calendar)
            try reload(); editorError = nil
            return item
        } catch { editorError = error.localizedDescription; return nil }
    }
    func deleteFullEditor(_ id: UUID) -> Bool {
        do { try repository.delete(todoID: id); try reload(); editorError = nil; return true }
        catch { editorError = error.localizedDescription; return false }
    }

    func loadCalendarOptions(for item: TodoSnapshot) async -> Bool {
        guard item.effectiveDeadlineDate != nil else { calendarError = TodoManagementError.deadlineRequired.localizedDescription; return false }
        guard !calendarBusy else { return false }
        calendarBusy = true
        defer { calendarBusy = false }
        do {
            try await calendarService.requestAccess()
            calendarOptions = try calendarService.calendars()
            guard !calendarOptions.isEmpty else { throw TodoManagementError.calendarUnavailable }
            calendarError = nil
            return true
        } catch { calendarError = error.localizedDescription; return false }
    }

    @discardableResult
    func linkCalendar(_ item: TodoSnapshot, calendarID: String? = nil) async -> Bool {
        guard !calendarBusy else { return false }
        guard item.effectiveDeadlineDate != nil else { calendarError = TodoManagementError.deadlineRequired.localizedDescription; return false }
        calendarBusy = true
        defer { calendarBusy = false }
        do {
            try await calendarService.requestAccess()
            // Authorization can suspend: reload the current title/deadline before saving.
            guard let current = try repository.allTodos().first(where: { $0.id == item.id }) else { throw TodoStoreError.todoNotFound }
            let timing = try TodoCalendarTiming.make(day: current.effectiveDeadlineDate, start: current.startDateTime,
                                                     end: current.deadlineDateTime, calendar: calendar)
            let link = try calendarService.upsert(identifier: pendingCalendarIDs[item.id] ?? current.linkedCalendarEventID,
                                                   calendarID: calendarID, title: current.title, start: timing.start, end: timing.end, isAllDay: timing.isAllDay)
            do {
                try repository.setCalendarEventID(todoID: item.id, identifier: link.identifier)
                pendingCalendarIDs[item.id] = nil
            } catch {
                if link.created {
                    do { try calendarService.removeCreatedEvent(identifier: link.identifier) }
                    catch { pendingCalendarIDs[item.id] = link.identifier }
                }
                throw error
            }
            try reload(); calendarError = nil
            return true
        } catch { calendarError = error.localizedDescription; return false }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation(); try reload(); errorMessage = nil }
        catch { report(error) }
    }

    private func reload(preserveDraft: Bool = false) throws {
        let now = clock()
        try repository.materializeRepeats(on: now, calendar: calendar)
        let newGroups = try repository.groups()
        let newItems = try repository.todos(matching: filter, now: now, calendar: calendar)
        let interval = TodoDates.interval(for: now, calendar: calendar)
        let unfinished = try repository.todos(matching: .today, now: now, calendar: calendar)
        let completed = try repository.todos(matching: .completed, now: now, calendar: calendar)
            .filter { $0.date >= interval.start && $0.date < interval.end }
        todayDate = interval.start
        todayItems = (unfinished + completed).sorted {
            if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let all = try repository.allTodos()
        if followsToday { fullDate = interval.start }
        let fullInterval = TodoDates.interval(for: fullDate, calendar: calendar)
        fullItems = TodoDates.sorted(all.filter { $0.date >= fullInterval.start && $0.date < fullInterval.end })
        overdueDays = Set(all.filter { !$0.isCompleted && $0.date < interval.start }
            .map { calendar.startOfDay(for: $0.date) })
        let oldIndex = items.firstIndex { $0.id == selectedID } ?? 0
        groups = newGroups
        items = newItems
        if let id = selectedID, newItems.contains(where: { $0.id == id }) {
            if !preserveDraft || !hasUnsavedChanges { loadSelection(id) }
        } else if selectedID != nil {
            loadSelection(newItems.isEmpty ? nil : newItems[min(oldIndex, newItems.count - 1)].id)
        }
    }

    private func loadSelection(_ id: UUID?) {
        selectedID = id
        if let item = items.first(where: { $0.id == id }) {
            draft = TodoDraft(item)
            savedDraft = draft
        } else {
            selectedID = nil
            draft = TodoDraft()
            savedDraft = nil
        }
    }

    private func report(_ error: Error) {
        errorMessage = "변경 사항을 저장하거나 불러오지 못했습니다.\n\(error.localizedDescription)"
    }
}
