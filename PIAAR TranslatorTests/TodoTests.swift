import XCTest
import SwiftData
import CoreData
import AppKit
import SwiftUI
@testable import PIAAR_Translator

final class TodoTests: XCTestCase {
    private func calendar(_ zone: String = "Asia/Seoul") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ year: Int = 2026, _ month: Int = 10, _ day: Int = 1,
                      hour: Int = 12, calendar: Calendar? = nil) -> Date {
        let calendar = calendar ?? self.calendar()
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @MainActor private func repository(now: Date? = nil) throws -> SwiftDataTodoRepository {
        let now = now ?? date()
        return SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true), clock: { now })
    }

    @MainActor
    func testCreateTrimsTitleAndNotesAndPersistsDay() throws {
        let repository = try repository()
        let item = try repository.create(TodoDraft(title: "  발주 확인 \n", notes: " 메모 ", date: date()), calendar: calendar())
        XCTAssertEqual(item.title, "발주 확인")
        XCTAssertEqual(item.notes, "메모")
        XCTAssertEqual(item.date, calendar().startOfDay(for: date()))
        XCTAssertFalse(item.isCompleted)
        XCTAssertNil(item.completedAt)
        XCTAssertNil(item.groupID)
        XCTAssertEqual(item.createdAt, date())
        XCTAssertEqual(item.updatedAt, date())
        XCTAssertEqual(try repository.todos(matching: .today, now: date(), calendar: calendar()).map(\.id), [item.id])
    }

    @MainActor
    func testEmptyTitleRejectedWithoutInsertion() throws {
        let repository = try repository()
        XCTAssertThrowsError(try repository.create(TodoDraft(title: " \n", date: date()), calendar: calendar()))
        XCTAssertTrue(try repository.todos(matching: .today, now: date(), calendar: calendar()).isEmpty)
    }

    @MainActor
    func testUpdateAllEditableFieldsPreservesIdentityAndCreation() throws {
        var now = date()
        let repository = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true), clock: { now })
        let item = try repository.create(TodoDraft(title: "old", date: date()), calendar: calendar())
        let group = try repository.createGroup(name: "업무")
        now = date(2026, 10, 2)
        try repository.update(todoID: item.id, draft: TodoDraft(title: "new", notes: "note", date: now, groupID: group.id), calendar: calendar())
        let changed = try XCTUnwrap(repository.todos(matching: .day(now), now: now, calendar: calendar()).first)
        XCTAssertEqual(changed.id, item.id)
        XCTAssertEqual(changed.title, "new")
        XCTAssertEqual(changed.notes, "note")
        XCTAssertEqual(changed.groupID, group.id)
        XCTAssertEqual(changed.createdAt, item.createdAt)
        XCTAssertEqual(changed.updatedAt, now)
    }

    @MainActor
    func testInvalidUpdateDoesNotChangeSavedTodo() throws {
        let repository = try repository()
        let item = try repository.create(TodoDraft(title: "keep", date: date()), calendar: calendar())
        XCTAssertThrowsError(try repository.update(todoID: item.id, draft: TodoDraft(title: "", date: date()), calendar: calendar()))
        XCTAssertEqual(try repository.todos(matching: .today, now: date(), calendar: calendar()).first?.title, "keep")
        XCTAssertThrowsError(try repository.changeGroup(todoID: item.id, groupID: UUID()))
        XCTAssertNil(try repository.todos(matching: .today, now: date(), calendar: calendar()).first?.groupID)
    }

    @MainActor
    func testDeleteTodoKeepsItsGroupAndOtherItems() throws {
        let repository = try repository()
        let group = try repository.createGroup(name: "업무")
        let a = try repository.create(TodoDraft(title: "delete", date: date(), groupID: group.id), calendar: calendar())
        let b = try repository.create(TodoDraft(title: "keep", date: date(), groupID: group.id), calendar: calendar())
        try repository.delete(todoID: a.id)
        XCTAssertEqual(try repository.todos(matching: .today, now: date(), calendar: calendar()).map(\.id), [b.id])
        XCTAssertEqual(try repository.groups().map(\.id), [group.id])
    }

    @MainActor
    func testCompleteAndUncompleteAreExplicitAndIdempotent() throws {
        var now = date()
        let repository = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true), clock: { now })
        let item = try repository.create(TodoDraft(title: "task", date: date()), calendar: calendar())
        now = date().addingTimeInterval(60)
        try repository.complete(todoID: item.id)
        let completionTime = now
        now = now.addingTimeInterval(60)
        try repository.complete(todoID: item.id)
        let done = try XCTUnwrap(repository.todos(matching: .completed, now: now, calendar: calendar()).first)
        XCTAssertTrue(done.isCompleted)
        XCTAssertEqual(done.completedAt, completionTime)
        XCTAssertEqual(done.updatedAt, completionTime)
        XCTAssertTrue(try repository.todos(matching: .today, now: now, calendar: calendar()).isEmpty)
        try repository.uncomplete(todoID: item.id)
        let uncompletedTime = now
        now = now.addingTimeInterval(60)
        try repository.uncomplete(todoID: item.id)
        let active = try XCTUnwrap(repository.todos(matching: .today, now: now, calendar: calendar()).first)
        XCTAssertFalse(active.isCompleted)
        XCTAssertNil(active.completedAt)
        XCTAssertEqual(active.updatedAt, uncompletedTime)
    }

    @MainActor
    func testSpecificDayHasExclusiveUpperBoundary() throws {
        let repository = try repository()
        let yesterday = try repository.create(TodoDraft(title: "yesterday", date: date(2026, 9, 30)), calendar: calendar())
        let today = try repository.create(TodoDraft(title: "today", date: date()), calendar: calendar())
        let tomorrow = try repository.create(TodoDraft(title: "tomorrow", date: date(2026, 10, 2, hour: 0)), calendar: calendar())
        let result = try repository.todos(matching: .day(date()), now: date(), calendar: calendar())
        XCTAssertEqual(result.map(\.id), [today.id])
        XCTAssertFalse(result.contains { $0.id == yesterday.id || $0.id == tomorrow.id })
    }

    @MainActor
    func testUpcomingExcludesTodayPastAndCompleted() throws {
        let repository = try repository()
        for day in [1, 2, 3] {
            _ = try repository.create(TodoDraft(title: "day \(day)", date: date(2026, 10, day)), calendar: calendar())
        }
        let done = try repository.create(TodoDraft(title: "done", date: date(2026, 10, 4)), calendar: calendar())
        try repository.complete(todoID: done.id)
        let result = try repository.todos(matching: .upcoming, now: date(), calendar: calendar())
        XCTAssertEqual(Set(result.map(\.title)), Set(["day 2", "day 3"]))
    }

    @MainActor
    func testCompletedIsNewestCompletionFirst() throws {
        var now = date()
        let repository = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true), clock: { now })
        let a = try repository.create(TodoDraft(title: "a", date: date()), calendar: calendar())
        let b = try repository.create(TodoDraft(title: "b", date: date()), calendar: calendar())
        try repository.complete(todoID: b.id)
        now = now.addingTimeInterval(60)
        try repository.complete(todoID: a.id)
        XCTAssertEqual(try repository.todos(matching: .completed, now: now, calendar: calendar()).map(\.id), [a.id, b.id])
    }

    @MainActor
    func testDayQueriesAcrossDSTAndTimeZones() throws {
        let la = calendar("America/Los_Angeles")
        for (month, day, hours) in [(3, 8, 23), (11, 1, 25)] {
            let now = date(2026, month, day, calendar: la)
            let range = TodoDates.interval(for: now, calendar: la)
            XCTAssertEqual(range.duration, Double(hours * 3600))
            let repository = try repository(now: now)
            let item = try repository.create(TodoDraft(title: "DST", date: now), calendar: la)
            _ = try repository.create(TodoDraft(title: "next", date: range.end), calendar: la)
            XCTAssertEqual(try repository.todos(matching: .day(now), now: now, calendar: la).map(\.id), [item.id])
        }
        for zone in ["Asia/Seoul", "Pacific/Honolulu", "Pacific/Kiritimati"] {
            let cal = calendar(zone)
            let now = date(calendar: cal)
            let repository = try repository(now: now)
            let item = try repository.create(TodoDraft(title: zone, date: now), calendar: cal)
            XCTAssertEqual(try repository.todos(matching: .today, now: now, calendar: cal).map(\.id), [item.id])
        }
    }

    @MainActor
    func testChangeDateAndGroupIncludingNilGroup() throws {
        let repository = try repository()
        let item = try repository.create(TodoDraft(title: "task", date: date()), calendar: calendar())
        let group = try repository.createGroup(name: "work")
        try repository.changeGroup(todoID: item.id, groupID: group.id)
        XCTAssertEqual(try repository.todos(matching: .group(group.id), now: date(), calendar: calendar()).map(\.id), [item.id])
        try repository.changeDate(todoID: item.id, date: date(2026, 10, 2), calendar: calendar())
        XCTAssertTrue(try repository.todos(matching: .today, now: date(), calendar: calendar()).isEmpty)
        try repository.changeGroup(todoID: item.id, groupID: nil)
        XCTAssertEqual(try repository.todos(matching: .ungrouped, now: date(), calendar: calendar()).map(\.id), [item.id])
        XCTAssertEqual(try repository.groups().count, 1) // No synthetic "그룹 없음" record.
    }

    @MainActor
    func testCreateRenameAndSortGroups() throws {
        let repository = try repository()
        let a = try repository.createGroup(name: "  first ")
        let b = try repository.createGroup(name: "second")
        XCTAssertEqual(a.name, "first")
        XCTAssertThrowsError(try repository.createGroup(name: " \n"))
        try repository.renameGroup(groupID: b.id, name: "changed")
        try repository.setGroupSortOrder(groupID: a.id, sortOrder: 10)
        let groups = try repository.groups()
        XCTAssertEqual(groups.map(\.id), [b.id, a.id])
        XCTAssertEqual(groups.first?.name, "changed")
    }

    @MainActor
    func testDeletingGroupKeepsBothActiveAndCompletedTodos() throws {
        let container = try TodoPersistence.makeContainer(inMemory: true)
        let repository = SwiftDataTodoRepository(container: container)
        let group = try repository.createGroup(name: "remove")
        let a = try repository.create(TodoDraft(title: "active", date: date(), groupID: group.id), calendar: calendar())
        let b = try repository.create(TodoDraft(title: "done", date: date(), groupID: group.id), calendar: calendar())
        try repository.complete(todoID: b.id)
        try repository.deleteGroup(groupID: group.id)
        // Read with a fresh context to verify persisted nullification, not just cached UI state.
        let reloaded = SwiftDataTodoRepository(container: container)
        XCTAssertTrue(try reloaded.groups().isEmpty)
        let active = try reloaded.todos(matching: .ungrouped, now: date(), calendar: calendar())
        let done = try reloaded.todos(matching: .completed, now: date(), calendar: calendar())
        XCTAssertEqual(active.map(\.id), [a.id])
        XCTAssertEqual(done.map(\.id), [b.id])
        XCTAssertNil(active.first?.groupID)
        XCTAssertNil(done.first?.groupID)
    }

    @MainActor
    func testSortOrderThenCreatedAt() throws {
        var now = date()
        let repository = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true), clock: { now })
        let a = try repository.create(TodoDraft(title: "a", date: date()), calendar: calendar())
        now = now.addingTimeInterval(1)
        let b = try repository.create(TodoDraft(title: "b", date: date()), calendar: calendar())
        now = now.addingTimeInterval(1)
        let c = try repository.create(TodoDraft(title: "c", date: date()), calendar: calendar())
        try repository.setSortOrder(todoID: a.id, sortOrder: 2)
        try repository.setSortOrder(todoID: b.id, sortOrder: 0)
        try repository.setSortOrder(todoID: c.id, sortOrder: 0)
        XCTAssertEqual(try repository.todos(matching: .today, now: date(), calendar: calendar()).map(\.id), [b.id, c.id, a.id])
        XCTAssertThrowsError(try repository.setSortOrder(todoID: a.id, sortOrder: -1))
    }

    @MainActor
    func testPersistenceAcrossContainerRecreation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PIAAR-Todo-Test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Todo.store")
        let ids: (UUID, UUID) = try autoreleasepool {
            let container = try TodoPersistence.makeContainer(storeURL: url)
            let repository = SwiftDataTodoRepository(container: container)
            let group = try repository.createGroup(name: "persisted group")
            let item = try repository.create(TodoDraft(title: "persisted todo", notes: "notes", date: date(), groupID: group.id), calendar: calendar())
            try repository.complete(todoID: item.id)
            return (item.id, group.id)
        }
        let reopened = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(storeURL: url))
        let item = try XCTUnwrap(reopened.todos(matching: .completed, now: date(), calendar: calendar()).first)
        XCTAssertEqual(item.id, ids.0)
        XCTAssertEqual(item.groupID, ids.1)
        XCTAssertEqual(item.title, "persisted todo")
        XCTAssertEqual(item.notes, "notes")
        XCTAssertNotNil(item.completedAt)
        XCTAssertEqual(try reopened.groups().first?.name, "persisted group")
    }

    @MainActor
    func testFailedSaveRollsBackAndCanRetry() throws {
        enum Failure: Error { case diskFull }
        var fail = false
        let repository = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true), saveContext: {
            if fail { throw Failure.diskFull }
            try $0.save()
        })
        let item = try repository.create(TodoDraft(title: "keep", date: date()), calendar: calendar())
        fail = true
        XCTAssertThrowsError(try repository.update(todoID: item.id, draft: TodoDraft(title: "lost", date: date()), calendar: calendar()))
        XCTAssertEqual(try repository.todos(matching: .today, now: date(), calendar: calendar()).first?.title, "keep")
        XCTAssertThrowsError(try repository.delete(todoID: item.id))
        XCTAssertEqual(try repository.todos(matching: .today, now: date(), calendar: calendar()).count, 1)
        fail = false
        try repository.complete(todoID: item.id)
        XCTAssertEqual(try repository.todos(matching: .completed, now: date(), calendar: calendar()).count, 1)
    }

    @MainActor
    func testGroupDeletionSaveFailureRollsBackLinks() throws {
        enum Failure: Error { case diskFull }
        var fail = false
        let repository = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true), saveContext: {
            if fail { throw Failure.diskFull }
            try $0.save()
        })
        let group = try repository.createGroup(name: "keep group")
        let item = try repository.create(TodoDraft(title: "keep todo", date: date(), groupID: group.id), calendar: calendar())
        fail = true
        XCTAssertThrowsError(try repository.deleteGroup(groupID: group.id))
        XCTAssertEqual(try repository.groups().map(\.id), [group.id])
        XCTAssertEqual(try repository.todos(matching: .group(group.id), now: date(), calendar: calendar()).map(\.id), [item.id])
    }

    @MainActor
    func testStoreOpenFailureDoesNotCrashAndRetryWorks() throws {
        enum Failure: Error { case unavailable }
        var fail = true
        let repository = try repository()
        let store = TodoWorkspaceStore(makeRepository: {
            if fail { throw Failure.unavailable }
            return repository
        })
        store.load()
        XCTAssertNil(store.model)
        XCTAssertNotNil(store.initializationError)
        fail = false
        store.load()
        XCTAssertNotNil(store.model)
        XCTAssertNil(store.initializationError)
    }

    func testStorePathIsIndependentOfDisplayNameAndBundleLocation() throws {
        let url = try TodoPersistence.storeURL()
        XCTAssertTrue(url.path.hasSuffix("/Application Support/com.piaar.PIAAR-Translator/Todo/Todo.store"))
        XCTAssertFalse(url.path.contains(".app/"))
        XCTAssertFalse(url.path.contains("PIAAR Work"))
    }

    @MainActor
    func testViewModelDefaultsAndCreateFromCompletedShowsNewItem() throws {
        let model = try TodoViewModel(repository: repository(), calendar: calendar(), clock: { self.date() })
        model.selectFilter(.day(date(2026, 10, 3)))
        XCTAssertEqual(model.selectedDate, calendar().startOfDay(for: date(2026, 10, 3)))
        XCTAssertTrue(model.saveGroup(id: nil, name: "group"))
        let group = try XCTUnwrap(model.groups.first)
        model.selectFilter(.group(group.id))
        XCTAssertEqual(model.defaultGroupID, group.id)
        model.selectFilter(.completed)
        XCTAssertTrue(model.create(TodoDraft(title: "new", date: date())))
        XCTAssertEqual(model.items.first?.title, "new")
        XCTAssertEqual(model.selectedID, model.items.first?.id)
    }

    @MainActor
    func testViewModelSavesBeforeSelectionAndRejectsInvalidDraft() throws {
        let repository = try repository()
        let a = try repository.create(TodoDraft(title: "a", date: date()), calendar: calendar())
        let b = try repository.create(TodoDraft(title: "b", date: date()), calendar: calendar())
        let model = try TodoViewModel(repository: repository, calendar: calendar(), clock: { self.date() })
        model.selectTodo(a.id)
        model.draft.title = "changed"
        model.selectTodo(b.id)
        XCTAssertEqual(model.selectedID, b.id)
        XCTAssertEqual(try repository.todos(matching: .today, now: date(), calendar: calendar()).first?.title, "changed")
        model.draft.title = ""
        model.selectFilter(.upcoming)
        XCTAssertEqual(model.filter, .today)
        XCTAssertEqual(model.selectedID, b.id)
        XCTAssertNotNil(model.errorMessage)
        model.discardDraft()
        XCTAssertEqual(model.draft.title, "b")
    }

    @MainActor
    func testRefreshDoesNotLoseDraftAcrossMidnight() throws {
        var now = date()
        let repository = try repository()
        let item = try repository.create(TodoDraft(title: "task", date: date()), calendar: calendar())
        let model = try TodoViewModel(repository: repository, calendar: calendar(), clock: { now })
        model.selectTodo(item.id)
        model.draft.notes = "unfinished"
        now = date(2026, 10, 2)
        model.refresh()
        XCTAssertEqual(model.draft.notes, "unfinished")
        XCTAssertEqual(model.selectedID, item.id)
        XCTAssertTrue(model.saveDraftIfNeeded())
        XCTAssertTrue(model.items.isEmpty)
    }

    @MainActor
    func testViewModelDeletionSelectsNextAndGroupDeletionMovesFilter() throws {
        let repository = try repository()
        let group = try repository.createGroup(name: "group")
        let a = try repository.create(TodoDraft(title: "a", date: date(), groupID: group.id), calendar: calendar())
        let b = try repository.create(TodoDraft(title: "b", date: date(), groupID: group.id), calendar: calendar())
        let model = try TodoViewModel(repository: repository, calendar: calendar(), clock: { self.date() })
        model.selectFilter(.group(group.id))
        model.selectTodo(a.id)
        model.delete(a)
        XCTAssertEqual(model.selectedID, b.id)
        model.deleteGroup(group)
        XCTAssertEqual(model.filter, .ungrouped)
        XCTAssertEqual(model.items.map(\.id), [b.id])
        model.delete(model.items[0])
        XCTAssertNil(model.selectedID)
    }

    @MainActor
    func testCommandNMatcherRejectsOtherModifiersAndRepeats() throws {
        func event(_ modifiers: NSEvent.ModifierFlags, repeatKey: Bool = false, key: String = "n") -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: repeatKey, keyCode: 45)!
        }
        XCTAssertTrue(TodoShortcutNSView.isNewTodoShortcut(event(.command)))
        XCTAssertFalse(TodoShortcutNSView.isNewTodoShortcut(event([.command, .shift])))
        XCTAssertFalse(TodoShortcutNSView.isNewTodoShortcut(event(.control)))
        XCTAssertFalse(TodoShortcutNSView.isNewTodoShortcut(event(.command, repeatKey: true)))
        XCTAssertFalse(TodoShortcutNSView.isNewTodoShortcut(event(.command, key: "t")))
    }

    @MainActor
    func testCommandNHandlesNonLatinInputWithoutChangingLatinRemaps() throws {
        func event(_ character: String, keyCode: UInt16 = 45) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: keyCode))
        }
        XCTAssertTrue(TodoShortcutNSView.isNewTodoShortcut(try event("ㅜ")))
        XCTAssertFalse(TodoShortcutNSView.isNewTodoShortcut(try event("ㅜ", keyCode: 17)))
        XCTAssertFalse(TodoShortcutNSView.isNewTodoShortcut(try event("b")))
        XCTAssertFalse(TodoShortcutNSView.isNewTodoShortcut(try event("")))
    }

    @MainActor
    func testQuickEntryCreatesClearsAndRequestsNextFocus() throws {
        let model = try TodoViewModel(repository: repository(), calendar: calendar(), clock: { self.date() })
        model.quickTitle = "  빠른 추가  "
        XCTAssertTrue(model.submitQuickEntry())
        XCTAssertEqual(model.items.map(\.title), ["빠른 추가"])
        XCTAssertEqual(model.quickTitle, "")
        XCTAssertNil(model.selectedID, "Quick entry must not open the inspector")
        XCTAssertEqual(model.quickFocusRequest, 1)
    }

    @MainActor
    func testBlankQuickEntryDoesNotInsertOrOpenInspector() throws {
        let model = try TodoViewModel(repository: repository())
        model.quickTitle = " \n"
        XCTAssertFalse(model.submitQuickEntry())
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.selectedID)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testCancelQuickEntryDoesNotCreateTodo() throws {
        let model = try TodoViewModel(repository: repository())
        model.quickTitle = "cancel"
        model.cancelQuickEntry()
        XCTAssertEqual(model.quickTitle, "")
        XCTAssertTrue(model.items.isEmpty)
    }

    @MainActor
    func testQuickEntryUsesSelectedDate() throws {
        let model = try TodoViewModel(repository: repository(), calendar: calendar(), clock: { self.date() })
        model.selectFilter(.day(date(2026, 10, 3)))
        model.quickTitle = "scheduled"
        XCTAssertTrue(model.submitQuickEntry())
        XCTAssertEqual(model.items.first?.date, calendar().startOfDay(for: date(2026, 10, 3)))
        XCTAssertNil(model.items.first?.groupID)
    }

    @MainActor
    func testQuickEntryUsesSelectedGroup() throws {
        let model = try TodoViewModel(repository: repository(), calendar: calendar(), clock: { self.date() })
        XCTAssertTrue(model.saveGroup(id: nil, name: "업무"))
        let group = try XCTUnwrap(model.groups.first)
        model.selectFilter(.group(group.id))
        model.quickTitle = "group task"
        XCTAssertTrue(model.submitQuickEntry())
        XCTAssertEqual(model.items.first?.groupID, group.id)
        XCTAssertEqual(model.items.first?.date, model.selectedDate)
        XCTAssertEqual(model.filter, .group(group.id))
    }

    @MainActor
    func testHotkeyPreparationSelectsTodayAndRequestsFocus() throws {
        let model = try TodoViewModel(repository: repository(), calendar: calendar(), clock: { self.date() })
        model.selectFilter(.upcoming)
        model.prepareForQuickEntry(windowWasActive: false)
        XCTAssertEqual(model.filter, .today)
        XCTAssertNil(model.selectedID)
        XCTAssertEqual(model.quickFocusRequest, 1)
    }

    @MainActor
    func testHotkeyPreservesUnsavedInspectorEvenInBackground() throws {
        let model = try TodoViewModel(repository: repository(), calendar: calendar(), clock: { self.date() })
        XCTAssertTrue(model.create(TodoDraft(title: "keep", date: date(2026, 10, 2))))
        let id = model.selectedID
        let filter = model.filter
        model.draft.notes = "unfinished"
        model.prepareForQuickEntry(windowWasActive: false)
        XCTAssertEqual(model.selectedID, id)
        XCTAssertEqual(model.filter, filter)
        XCTAssertEqual(model.draft.notes, "unfinished")
        XCTAssertEqual(model.quickFocusRequest, 0)
    }

    @MainActor
    func testHotkeyPreservesActiveInspectorSelection() throws {
        let model = try TodoViewModel(repository: repository(), calendar: calendar(), clock: { self.date() })
        XCTAssertTrue(model.create(TodoDraft(title: "keep", date: date(2026, 10, 2))))
        let id = model.selectedID
        model.prepareForQuickEntry(windowWasActive: true)
        XCTAssertEqual(model.selectedID, id)
        XCTAssertNotEqual(model.filter, .today)
        XCTAssertEqual(model.quickFocusRequest, 0)
    }

    @MainActor
    func testHotkeyPreservesQuickDraftAndCurrentDate() throws {
        let model = try TodoViewModel(repository: repository(), calendar: calendar(), clock: { self.date() })
        model.selectFilter(.day(date(2026, 10, 2)))
        model.quickTitle = "unfinished"
        model.prepareForQuickEntry(windowWasActive: false)
        XCTAssertEqual(model.quickTitle, "unfinished")
        XCTAssertEqual(model.filter, .day(calendar().startOfDay(for: date(2026, 10, 2))))
    }

    @MainActor
    func testNewShortcutFocusRequestDoesNotDiscardInspectorDraft() throws {
        let model = try TodoViewModel(repository: repository(), calendar: calendar(), clock: { self.date() })
        XCTAssertTrue(model.create(TodoDraft(title: "keep", date: date())))
        model.draft.notes = "unfinished"
        let id = model.selectedID
        model.requestQuickFocus()
        XCTAssertEqual(model.quickFocusRequest, 1)
        XCTAssertEqual(model.selectedID, id)
        XCTAssertEqual(model.draft.notes, "unfinished")
    }

    @MainActor
    func testInspectorCloseSavesAndClearsSelection() throws {
        let repo = try repository()
        let model = try TodoViewModel(repository: repo, calendar: calendar(), clock: { self.date() })
        XCTAssertTrue(model.create(TodoDraft(title: "before", date: date())))
        model.draft.title = "after"
        XCTAssertTrue(model.closeInspector())
        XCTAssertNil(model.selectedID)
        XCTAssertEqual(try repo.todos(matching: .today, now: date(), calendar: calendar()).first?.title, "after")
    }

    @MainActor
    func testInspectorCloseRejectsInvalidDraftWithoutDiscarding() throws {
        let model = try TodoViewModel(repository: repository(), calendar: calendar(), clock: { self.date() })
        XCTAssertTrue(model.create(TodoDraft(title: "keep", date: date())))
        let id = model.selectedID
        model.draft.title = ""
        XCTAssertFalse(model.closeInspector())
        XCTAssertEqual(model.selectedID, id)
        XCTAssertEqual(model.draft.title, "")
        XCTAssertNotNil(model.errorMessage)
    }

    @MainActor
    func testQuickEntrySaveFailureKeepsInputForRetry() throws {
        enum Failure: Error { case diskFull }
        var fail = true
        let repo = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true), saveContext: {
            if fail { throw Failure.diskFull }
            try $0.save()
        })
        let model = try TodoViewModel(repository: repo, calendar: calendar(), clock: { self.date() })
        model.quickTitle = "keep input"
        XCTAssertFalse(model.submitQuickEntry())
        XCTAssertEqual(model.quickTitle, "keep input")
        XCTAssertTrue(model.items.isEmpty)
        fail = false
        XCTAssertTrue(model.submitQuickEntry())
        XCTAssertEqual(model.items.map(\.title), ["keep input"])
    }

    @MainActor
    func testCompletionRemovesTodayAndRestorePreservesIdentity() throws {
        let model = try TodoViewModel(repository: repository(), calendar: calendar(), clock: { self.date() })
        model.quickTitle = "task"
        XCTAssertTrue(model.submitQuickEntry())
        let item = try XCTUnwrap(model.items.first)
        model.setCompleted(item, completed: true)
        XCTAssertTrue(model.items.isEmpty)
        model.selectFilter(.completed)
        let done = try XCTUnwrap(model.items.first)
        XCTAssertEqual(done.id, item.id)
        model.setCompleted(done, completed: false)
        XCTAssertTrue(model.items.isEmpty)
        model.selectFilter(.today)
        XCTAssertEqual(model.items.first?.id, item.id)
        XCTAssertNil(model.items.first?.completedAt)
    }

    @MainActor
    func testDayNavigationReturnsToToday() throws {
        let model = try TodoViewModel(repository: repository(), calendar: calendar(), clock: { self.date() })
        model.moveDay(by: 1)
        XCTAssertEqual(model.selectedDate, calendar().startOfDay(for: date(2026, 10, 2)))
        model.moveDay(by: -1)
        XCTAssertEqual(model.filter, .today)
    }


    @MainActor
    func testEscapeClearsInputAndRevokesFocusRequest() throws {
        let model = try TodoViewModel(repository: repository())
        model.requestQuickFocus()
        model.quickTitle = "cancel"
        let revision = model.quickFocusRequest
        model.cancelQuickEntry()
        XCTAssertEqual(model.quickTitle, "")
        XCTAssertFalse(model.quickWantsFocus)
        XCTAssertGreaterThan(model.quickFocusRequest, revision)
    }

    @MainActor
    func testSuccessfulEnterKeepsFocusIntentForNextTodo() throws {
        let model = try TodoViewModel(repository: repository(), calendar: calendar(), clock: { self.date() })
        model.quickTitle = "first"
        XCTAssertTrue(model.submitQuickEntry())
        XCTAssertTrue(model.quickWantsFocus)
        let revision = model.quickFocusRequest
        model.quickTitle = "second"
        XCTAssertTrue(model.submitQuickEntry())
        XCTAssertTrue(model.quickWantsFocus)
        XCTAssertGreaterThan(model.quickFocusRequest, revision)
        XCTAssertEqual(model.items.count, 2)
    }

    @MainActor
    private func activateTestWindow(_ window: NSWindow) async {
        NSApp.setActivationPolicy(.regular)
        identifyTodoTestWindow(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.unhide(nil)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        window.makeKeyAndOrderFront(nil)
        let activation = expectation(description: "Test host activation committed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            window.makeKeyAndOrderFront(nil)
            window.makeKey()
            activation.fulfill()
        }
        await fulfillment(of: [activation], timeout: 3)

    }

    @MainActor
    func testNativeQuickInputReclaimsActualFieldEditorAndEscapeReleasesIt() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let input = TodoQuickInputNSView()
        input.frame = NSRect(x: 20, y: 200, width: 250, height: 25)
        let detail = NSTextField(frame: NSRect(x: 20, y: 100, width: 250, height: 25))
        content.addSubview(input)
        detail.placeholderString = "[Unit Test] alternate focus target"
        content.addSubview(detail)
        window.contentView = content
        defer { input.stopObserving(); input.shortcut.stop(); window.orderOut(nil) }
        // Requests made before window activation must survive until it becomes key.
        input.applyFocusRequest(revision: 1, wantsFocus: true)
        await activateTestWindow(window)
        let first = expectation(description: "Actual quick-entry field editor focused")
        DispatchQueue.main.async { XCTAssertTrue(input.hasKeyboardFocus); first.fulfill() }
        await fulfillment(of: [first], timeout: 2)
        XCTAssertTrue(window.makeFirstResponder(detail))
        XCTAssertFalse(input.hasKeyboardFocus)
        await activateTestWindow(window)
        input.applyFocusRequest(revision: 2, wantsFocus: true)
        let again = expectation(description: "Repeated shortcut reclaims field editor")
        DispatchQueue.main.async { XCTAssertTrue(input.hasKeyboardFocus); again.fulfill() }
        await fulfillment(of: [again], timeout: 2)
        let editor = try XCTUnwrap(input.currentEditor() as? NSTextView)
        input.cancel = {}
        input.setText("cancel")
        XCTAssertTrue(input.control(input, textView: editor,
                                   doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(input.stringValue, "")
        XCTAssertFalse(input.hasKeyboardFocus)
        // A cancelled request must not steal focus on a later window notification.
        input.applyFocusRequest(revision: 3, wantsFocus: false)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        let cancelled = expectation(description: "Focus stays released")
        DispatchQueue.main.async { XCTAssertFalse(input.hasKeyboardFocus); cancelled.fulfill() }
        await fulfillment(of: [cancelled], timeout: 2)
    }

    @MainActor
    func testNativeEnterCreatesAndFocusesNextInput() async throws {
        let model = try TodoViewModel(repository: repository(), calendar: calendar(), clock: { self.date() })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let input = TodoQuickInputNSView()
        input.frame = NSRect(x: 20, y: 100, width: 250, height: 25)
        window.contentView?.addSubview(input)
        defer { input.stopObserving(); input.shortcut.stop(); window.orderOut(nil) }
        await activateTestWindow(window)
        input.applyFocusRequest(revision: 1, wantsFocus: true)
        let focused = expectation(description: "Field editor ready for Enter")
        DispatchQueue.main.async { focused.fulfill() }
        await fulfillment(of: [focused], timeout: 2)
        let editor = try XCTUnwrap(input.currentEditor() as? NSTextView)
        model.quickTitle = "테스트 할 일"
        input.setText(model.quickTitle)
        input.submit = {
            XCTAssertTrue(model.submitQuickEntry())
            input.setText(model.quickTitle)
            input.applyFocusRequest(revision: 2, wantsFocus: model.quickWantsFocus)
        }
        XCTAssertTrue(input.control(input, textView: editor,
                                   doCommandBy: #selector(NSResponder.insertNewline(_:))))
        let saved = expectation(description: "Continuous input after Enter")
        DispatchQueue.main.async {
            XCTAssertEqual(model.items.first?.title, "테스트 할 일")
            XCTAssertEqual(input.stringValue, "")
            XCTAssertEqual(input.currentEditor()?.string, "")
            XCTAssertTrue(input.hasKeyboardFocus)
            saved.fulfill()
        }
        await fulfillment(of: [saved], timeout: 2)
    }


    @MainActor
    func testCommandNEventActuallyFocusesQuickInputFromAnotherField() async throws {
        // Command routing can be tested without making the background test host a foreground app.
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        let input = TodoQuickInputNSView()
        input.frame = NSRect(x: 20, y: 200, width: 250, height: 25)
        let other = NSTextField(frame: NSRect(x: 20, y: 100, width: 250, height: 25))
        window.contentView?.addSubview(input)
        other.placeholderString = "[Unit Test] alternate focus target"
        window.contentView?.addSubview(other)
        defer { input.stopObserving(); input.shortcut.stop(); window.orderOut(nil) }
        await activateTestWindow(window)
        XCTAssertTrue(window.makeFirstResponder(other))
        let focused = expectation(description: "Command-N routed to actual quick-entry focus")
        input.shortcut.action = {
            input.applyFocusRequest(revision: 1, wantsFocus: true)
            DispatchQueue.main.async {
                XCTAssertTrue(input.hasKeyboardFocus)
                focused.fulfill()
            }
        }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45))
        NSApp.postEvent(event, atStart: false)
        await fulfillment(of: [focused], timeout: 3)
    }

    @MainActor
    func testCommandNKeyEquivalentFocusesQuickInputWithoutKeyDownMonitor() async throws {
        // Command routing can be tested without making the background test host a foreground app.
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        let input = TodoQuickInputNSView()
        input.frame = NSRect(x: 20, y: 200, width: 250, height: 25)
        let other = NSTextField(frame: NSRect(x: 20, y: 100, width: 250, height: 25))
        window.contentView?.addSubview(input)
        other.placeholderString = "[Unit Test] alternate focus target"
        window.contentView?.addSubview(other)
        await activateTestWindow(window)
        defer { input.stopObserving(); input.shortcut.stop(); window.orderOut(nil) }
        XCTAssertTrue(window.makeFirstResponder(other))
        window.makeKey()
        input.shortcut.stop()
        let focused = expectation(description: "Cocoa key equivalent focuses native quick entry")
        input.shortcut.action = {
            input.applyFocusRequest(revision: 1, wantsFocus: true)
            DispatchQueue.main.async {
                XCTAssertTrue(input.hasKeyboardFocus)
                focused.fulfill()
            }
        }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45))
        XCTAssertTrue(input.performKeyEquivalent(with: event))
        await fulfillment(of: [focused], timeout: 3)
    }

    @MainActor
    func testFullCompletionAndEditorKeepNativeQuickInputBounds() async throws {
        let model = try TodoViewModel(repository: repository(), calendar: calendar(), clock: { self.date() })
        model.quickTitle = "layout fixture"
        XCTAssertTrue(model.submitQuickEntry())
        let id = try XCTUnwrap(model.items.first?.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 620),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: FullTodoView(model: model))
        window.setContentSize(NSSize(width: 800, height: 620))
        await activateTestWindow(window)
        defer { window.orderOut(nil); window.contentViewController = nil }
        func settle() async {
            let ready = expectation(description: "SwiftUI layout committed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                window.contentView?.layoutSubtreeIfNeeded()
                ready.fulfill()
            }
            await fulfillment(of: [ready], timeout: 2)
        }
        func input(in view: NSView) -> TodoQuickInputNSView? {
            if let field = view as? TodoQuickInputNSView { return field }
            return view.subviews.compactMap { input(in: $0) }.first
        }
        await settle()
        let field = try XCTUnwrap(input(in: try XCTUnwrap(window.contentView)))
        let original = field.convert(field.bounds, to: nil)
        model.toggleCompletion(try XCTUnwrap(model.fullItems.first { $0.id == id }))
        await settle()
        XCTAssertEqual(field.convert(field.bounds, to: nil), original)
        model.beginFullEditing(try XCTUnwrap(model.fullItems.first { $0.id == id }))
        await settle()
        XCTAssertEqual(field.convert(field.bounds, to: nil), original)
        model.fullEditor = nil
        await settle()
        XCTAssertEqual(field.convert(field.bounds, to: nil), original)
        XCTAssertEqual(window.contentView?.bounds.width, 800)
    }


    @MainActor
    func testTodoWindowActivationKeepsUnsavedEditAndDoesNotForceAddSheet() async throws {
        let repo = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true))
        let store = TodoWorkspaceStore { repo }
        store.load()
        let model = try XCTUnwrap(store.model)
        let controller = WorkWindowController(openTranslator: {}, openSettings: {}, todoStore: store)
        defer { controller.window?.orderOut(nil) }
        func settle() async {
            let ready = expectation(description: "Window activation and focus committed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { ready.fulfill() }
            await fulfillment(of: [ready], timeout: 2)
        }
        func input(in view: NSView) -> TodoQuickInputNSView? {
            if let field = view as? TodoQuickInputNSView { return field }
            return view.subviews.compactMap { input(in: $0) }.first
        }
        model.selectFilter(.upcoming)
        controller.showTodo()
        await activateTestWindow(try XCTUnwrap(controller.window))
        await settle()
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        let quickInput = try XCTUnwrap(input(in: content))
        XCTAssertTrue(quickInput.hasKeyboardFocus)
        XCTAssertEqual(model.filter, .today)
        XCTAssertNil(model.fullEditor)
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(model.create(TodoDraft(title: "keep editing", date: Date())))
        model.draft.notes = "unfinished inspector notes"
        let selected = model.selectedID
        let editing = NSTextField(frame: NSRect(x: 500, y: 100, width: 200, height: 25))
        editing.placeholderString = "[Unit Test] alternate focus target"
        content.addSubview(editing)
        XCTAssertTrue(window.makeFirstResponder(editing))
        controller.showTodo()
        await activateTestWindow(try XCTUnwrap(controller.window))
        await settle()
        XCTAssertEqual(model.selectedID, selected)
        XCTAssertEqual(model.draft.notes, "unfinished inspector notes")
        XCTAssertNotNil(editing.currentEditor(), "A repeated Todo hotkey must not steal an unsaved editor's focus")
        model.discardDraft()
        XCTAssertTrue(model.closeInspector())
        controller.showTodo()
        await activateTestWindow(try XCTUnwrap(controller.window))
        await settle()
        XCTAssertNil(model.fullEditor)
        XCTAssertNil(window.attachedSheet)
    }

}

final class MinimalTodoTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return value
    }
    private var today: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12))! }

    @MainActor
    func testTodayIncludesCompletedButPreservesPastAndFuture() throws {
        let repo = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true))
        let past = try repo.create(TodoDraft(title: "past", date: today.addingTimeInterval(-86400)), calendar: calendar)
        let future = try repo.create(TodoDraft(title: "future", date: today.addingTimeInterval(86400)), calendar: calendar)
        let done = try repo.create(TodoDraft(title: "done", date: today), calendar: calendar)
        let open = try repo.create(TodoDraft(title: "open", date: today), calendar: calendar)
        try repo.complete(todoID: done.id)
        let model = try TodoViewModel(repository: repo, calendar: calendar, clock: { self.today })
        XCTAssertEqual(model.todayItems.map(\.id), [open.id, done.id])
        XCTAssertEqual(try repo.todos(matching: .day(past.date), now: today, calendar: calendar).map(\.id), [past.id])
        XCTAssertEqual(try repo.todos(matching: .day(future.date), now: today, calendar: calendar).map(\.id), [future.id])
    }

    @MainActor
    func testMidnightRefreshDoesNotCarryOverAndNewInputUsesCurrentDay() throws {
        var now = today
        let repo = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true))
        let model = try TodoViewModel(repository: repo, calendar: calendar, clock: { now })
        model.quickTitle = "yesterday"
        XCTAssertTrue(model.submitTodayQuickEntry())
        let old = try XCTUnwrap(model.todayItems.first)
        model.quickTitle = "typed before midnight"
        now = calendar.date(byAdding: .day, value: 1, to: now)!
        model.refresh()
        XCTAssertTrue(model.todayItems.isEmpty)
        XCTAssertTrue(model.submitTodayQuickEntry())
        XCTAssertEqual(model.todayItems.first?.date, calendar.startOfDay(for: now))
        XCTAssertEqual(try repo.todos(matching: .day(old.date), now: now, calendar: calendar).first?.id, old.id)
    }

    @MainActor
    func testQuickEntryIgnoresLegacyFilterAndKeepsFocusAfterCreation() throws {
        let repo = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true))
        let model = try TodoViewModel(repository: repo, calendar: calendar, clock: { self.today })
        model.selectFilter(.upcoming)
        model.quickTitle = "  today  "
        let revision = model.quickFocusRequest
        XCTAssertTrue(model.submitTodayQuickEntry())
        XCTAssertEqual(model.todayItems.first?.title, "today")
        XCTAssertEqual(model.todayItems.first?.date, calendar.startOfDay(for: today))
        XCTAssertEqual(model.quickTitle, "")
        XCTAssertTrue(model.quickWantsFocus)
        XCTAssertGreaterThan(model.quickFocusRequest, revision)
        XCTAssertNil(model.selectedID)
        model.quickTitle = "cancel"
        model.cancelQuickEntry()
        XCTAssertEqual(model.quickTitle, "")
        XCTAssertFalse(model.quickWantsFocus)
        XCTAssertEqual(model.todayItems.count, 1)
    }

    @MainActor
    func testCompleteUncompleteRestoresStableOrderAndPreservesMetadata() throws {
        let repo = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true))
        let group = try repo.createGroup(name: "legacy")
        let first = try repo.create(TodoDraft(title: "first", notes: "keep", date: today, groupID: group.id), calendar: calendar)
        let second = try repo.create(TodoDraft(title: "second", date: today), calendar: calendar)
        let model = try TodoViewModel(repository: repo, calendar: calendar, clock: { self.today })
        model.setCompleted(first, completed: true)
        XCTAssertEqual(model.todayItems.map(\.id), [second.id, first.id])
        XCTAssertNotNil(model.todayItems.last?.completedAt)
        model.setCompleted(first, completed: false)
        XCTAssertEqual(model.todayItems.map(\.id), [first.id, second.id])
        let restored = try XCTUnwrap(model.todayItems.first)
        XCTAssertNil(restored.completedAt)
        XCTAssertEqual(restored.notes, first.notes)
        XCTAssertEqual(restored.groupID, first.groupID)
        XCTAssertEqual(restored.date, first.date)
        XCTAssertEqual(restored.sortOrder, first.sortOrder)
    }

    @MainActor
    func testHotKeyMiniFullReuseCloseAndSharedData() throws {
        let repo = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true))
        let store = TodoWorkspaceStore { repo }
        var fullCount = 0
        var miniCount = 0
        let coordinator = WorkWindowCoordinator(makeController: {
            fullCount += 1
            return self.identifyTodoTestController(WorkWindowController(openTranslator: {}, openSettings: {}, todoStore: store))
        }, makeMini: {
            miniCount += 1
            return self.identifyTodoTestController(MiniTodoWindowController(todoStore: $0))
        })
        defer { coordinator.controller?.window?.orderOut(nil); coordinator.miniController?.window?.orderOut(nil) }
        coordinator.handleTodoHotKey()
        let full = try XCTUnwrap(coordinator.controller)
        let mini = try XCTUnwrap(coordinator.miniController)
        let model = try XCTUnwrap(store.model)
        XCTAssertTrue(mini.window?.isVisible == true)
        XCTAssertFalse(full.window?.isVisible == true)
        XCTAssertTrue(mini.todoStore === full.sharedTodoStore)
        XCTAssertTrue(model.quickWantsFocus)
        model.quickTitle = "shared"
        XCTAssertTrue(model.submitTodayQuickEntry())
        coordinator.handleTodoHotKey()
        XCTAssertTrue(full.window?.isVisible == true)
        XCTAssertFalse(mini.window?.isVisible == true)
        XCTAssertTrue(full.sharedTodoStore.model === model)
        XCTAssertEqual(full.sharedTodoStore.model?.todayItems.first?.title, "shared")
        let revision = model.quickFocusRequest
        coordinator.handleTodoHotKey()
        XCTAssertTrue(coordinator.controller === full)
        XCTAssertGreaterThan(model.quickFocusRequest, revision)
        XCTAssertTrue(mini.window?.isVisible == true)
        XCTAssertFalse(full.window?.isVisible == true)
        mini.window?.close()
        coordinator.handleTodoHotKey()
        XCTAssertTrue(coordinator.miniController === mini)
        XCTAssertTrue(mini.window?.isVisible == true)
        mini.window?.close()
        coordinator.handleTodoHotKey()
        XCTAssertTrue(mini.window?.isVisible == true)
        coordinator.showWork()
        XCTAssertFalse(mini.window?.isVisible == true)
        XCTAssertTrue(full.window?.isVisible == true)
        XCTAssertEqual(fullCount, 1)
        XCTAssertEqual(miniCount, 1)
    }

    @MainActor
    func testRowToggleUsesLatestStateAndImmediatelyResortsBothLists() throws {
        let repo = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true))
        let first = try repo.create(TodoDraft(title: "first", date: today), calendar: calendar)
        let second = try repo.create(TodoDraft(title: "second", date: today), calendar: calendar)
        let model = try TodoViewModel(repository: repo, calendar: calendar, clock: { self.today })
        model.toggleCompletion(first)
        XCTAssertTrue(try XCTUnwrap(repo.allTodos().first { $0.id == first.id }).isCompleted)
        XCTAssertEqual(model.fullSections.last?.items.map(\.id), [second.id, first.id])
        XCTAssertEqual(model.todayItems.map(\.id), [second.id, first.id])
        XCTAssertNil(model.fullEditor, "Normal row action must not open the editor")
        // A second click may arrive before SwiftUI replaces the captured snapshot.
        model.toggleCompletion(first)
        XCTAssertFalse(try XCTUnwrap(repo.allTodos().first { $0.id == first.id }).isCompleted)
        XCTAssertEqual(model.fullItems.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.todayItems.map(\.id), [first.id, second.id])
    }

    @MainActor
    func testMoreOpensExistingTodoWithoutChangingCompletionOrMetadata() throws {
        let repo = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true))
        let item = try repo.create(TodoDraft(title: "edit", notes: "keep", date: today), calendar: calendar)
        try repo.complete(todoID: item.id)
        let model = try TodoViewModel(repository: repo, calendar: calendar, clock: { self.today })
        let before = try XCTUnwrap(model.fullItems.first)
        model.beginFullEditing(before)
        XCTAssertEqual(model.fullEditor?.todoID, item.id)
        XCTAssertEqual(model.fullEditor?.draft.notes, "keep")
        XCTAssertEqual(try repo.allTodos().first, before)
        XCTAssertTrue(model.fullItems.first?.isCompleted == true)
    }

    @MainActor
    func testFullQuickEntrySelectedDateDefaultsAndFocusCancellation() throws {
        let repo = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true))
        let model = try TodoViewModel(repository: repo, calendar: calendar, clock: { self.today })
        let selected = calendar.startOfDay(for: today.addingTimeInterval(86400 * 3))
        model.selectFullDate(selected)
        model.quickTitle = "quick"
        let revision = model.quickFocusRequest
        XCTAssertTrue(model.submitFullQuickEntry())
        let item = try XCTUnwrap(repo.allTodos().first)
        XCTAssertEqual(item.date, selected)
        XCTAssertNil(item.groupID)
        XCTAssertNil(item.repeatScheduleID)
        XCTAssertNil(item.effectiveDeadlineDate)
        XCTAssertNil(item.linkedCalendarEventID)
        XCTAssertEqual(model.quickTitle, "")
        XCTAssertTrue(model.quickWantsFocus)
        XCTAssertGreaterThan(model.quickFocusRequest, revision)
        XCTAssertNil(model.fullEditor)
        model.quickTitle = "cancel"
        model.cancelQuickEntry()
        XCTAssertEqual(model.quickTitle, "")
        XCTAssertFalse(model.quickWantsFocus)
        model.requestQuickFocus()
        XCTAssertTrue(model.quickWantsFocus)
        XCTAssertEqual(try repo.allTodos().count, 1)
    }

    @MainActor
    func testTogglePreservesFullSelectedDateAndEditorDraft() async throws {
        let repo = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true))
        let store = TodoWorkspaceStore { repo }
        let coordinator = WorkWindowCoordinator {
            self.identifyTodoTestController(WorkWindowController(openTranslator: {}, openSettings: {}, todoStore: store))
        }
        defer { coordinator.controller?.window?.orderOut(nil); coordinator.miniController?.window?.orderOut(nil) }
        coordinator.handleTodoHotKey()
        coordinator.handleTodoHotKey()
        let model = try XCTUnwrap(store.model)
        let selected = model.calendar.startOfDay(for: Date().addingTimeInterval(86400 * 4))
        model.selectFullDate(selected)
        model.quickTitle = "preserve"
        XCTAssertTrue(model.submitFullQuickEntry())
        model.beginFullEditing(try XCTUnwrap(model.fullItems.first))
        let session = try XCTUnwrap(model.fullEditor)
        func settle() async {
            let ready = expectation(description: "Editor sheet committed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { ready.fulfill() }
            await fulfillment(of: [ready], timeout: 3)
        }
        await settle()
        let full = try XCTUnwrap(coordinator.controller?.window)
        let sheet = try XCTUnwrap(full.attachedSheet)
        func input(in view: NSView) -> TodoQuickInputNSView? {
            if let field = view as? TodoQuickInputNSView { return field }
            return view.subviews.compactMap { input(in: $0) }.first
        }
        let field = try XCTUnwrap(input(in: try XCTUnwrap(sheet.contentView)))
        field.setText("unsaved editor title")
        field.textChanged?("unsaved editor title")
        coordinator.handleTodoHotKey()
        await settle()
        XCTAssertTrue(coordinator.miniController?.window?.isVisible == true)
        XCTAssertFalse(full.isVisible)
        XCTAssertFalse(sheet.isVisible)
        coordinator.handleTodoHotKey()
        await settle()
        XCTAssertTrue(full.isVisible)
        XCTAssertTrue(full.attachedSheet === sheet)
        XCTAssertTrue(sheet.isVisible)
        XCTAssertEqual(field.stringValue, "unsaved editor title")
        XCTAssertFalse(coordinator.miniController?.window?.isVisible == true)
        XCTAssertEqual(model.fullDate, selected)
        XCTAssertEqual(model.fullEditor?.id, session.id)
        XCTAssertEqual(model.fullItems.first?.title, "preserve", "Toggling must not save or discard the editor draft")
        model.fullEditor = nil
        await settle()

    }

    @MainActor
    func testMiniNativeEnterEscapeAndFullCommandNFocus() async throws {
        let repo = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true))
        let store = TodoWorkspaceStore { repo }
        let coordinator = WorkWindowCoordinator {
            self.identifyTodoTestController(WorkWindowController(openTranslator: {}, openSettings: {}, todoStore: store))
        }
        defer { coordinator.controller?.window?.orderOut(nil); coordinator.miniController?.window?.orderOut(nil) }
        func settle(_ window: NSWindow) async {
            NSApp.setActivationPolicy(.regular)
            identifyTodoTestWindow(window)
            window.makeKeyAndOrderFront(nil)
            NSApp.unhide(nil)
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            let ready = expectation(description: "Native field editor settled")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                window.makeKeyAndOrderFront(nil)
                window.makeKey()
                ready.fulfill()
            }
            await fulfillment(of: [ready], timeout: 3)
            let focused = expectation(description: "Pending focus request applied")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused.fulfill() }
            await fulfillment(of: [focused], timeout: 3)
        }
        func input(in view: NSView) -> TodoQuickInputNSView? {
            if let field = view as? TodoQuickInputNSView { return field }
            return view.subviews.compactMap { input(in: $0) }.first
        }
        coordinator.handleTodoHotKey()
        let mini = try XCTUnwrap(coordinator.miniController?.window)
        await settle(mini)
        let field = try XCTUnwrap(input(in: try XCTUnwrap(mini.contentView)))
        let model = try XCTUnwrap(store.model)
        XCTAssertTrue(field.hasKeyboardFocus)
        for title in ["first", "second"] {
            model.quickTitle = title
            field.setText(title)
            XCTAssertTrue(field.control(field, textView: try XCTUnwrap(field.currentEditor() as? NSTextView),
                                        doCommandBy: #selector(NSResponder.insertNewline(_:))))
            await settle(mini)
            XCTAssertEqual(model.quickTitle, "")
            XCTAssertTrue(field.hasKeyboardFocus)
        }
        XCTAssertEqual(model.todayItems.map(\.title), ["first", "second"])
        model.quickTitle = "discard"
        field.setText("discard")
        XCTAssertTrue(field.control(field, textView: try XCTUnwrap(field.currentEditor() as? NSTextView),
                                    doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        await settle(mini)
        XCTAssertEqual(model.quickTitle, "")
        XCTAssertTrue(mini.isVisible)
        XCTAssertTrue(field.hasKeyboardFocus)
        XCTAssertTrue(field.control(field, textView: try XCTUnwrap(field.currentEditor() as? NSTextView),
                                    doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertFalse(mini.isVisible)
        coordinator.showWork()
        let full = try XCTUnwrap(coordinator.controller?.window)
        await settle(full)
        let fullField = try XCTUnwrap(input(in: try XCTUnwrap(full.contentView)))
        fullField.shortcut.stop()
        let other = NSTextField(frame: NSRect(x: 10, y: 10, width: 100, height: 24))
        other.placeholderString = "[Unit Test] alternate focus target"
        full.contentView?.addSubview(other)
        XCTAssertTrue(full.makeFirstResponder(other))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: full.windowNumber,
            context: nil, characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45))
        XCTAssertTrue(fullField.performKeyEquivalent(with: event))
        await settle(full)
        XCTAssertNil(model.fullEditor)
        XCTAssertNil(full.attachedSheet)
        XCTAssertTrue(fullField.hasKeyboardFocus)
        fullField.setText("inline created")
        fullField.textChanged?("inline created")
        XCTAssertTrue(fullField.control(fullField, textView: try XCTUnwrap(fullField.currentEditor() as? NSTextView),
                                       doCommandBy: #selector(NSResponder.insertNewline(_:))))
        await settle(full)
        XCTAssertEqual(model.quickTitle, "")
        XCTAssertTrue(fullField.hasKeyboardFocus)
        XCTAssertNil(model.fullEditor)
        XCTAssertTrue(model.fullItems.contains { $0.title == "inline created" })
        fullField.setText("cancel")
        fullField.textChanged?("cancel")
        XCTAssertTrue(fullField.control(fullField, textView: try XCTUnwrap(fullField.currentEditor() as? NSTextView),
                                       doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(model.quickTitle, "")
        XCTAssertFalse(model.quickWantsFocus)

    }

}

@MainActor
private final class FakeTodoCalendarService: TodoCalendarService {
    struct Event { var title: String; var start: Date; var end: Date; var isAllDay: Bool }
    var events: [String: Event] = [:]
    var denied = false
    var requestCount = 0
    var createdCount = 0
    var updatedCount = 0
    var removes = 0
    var failRemoval = false
    func requestAccess() async throws {
        requestCount += 1
        if denied { throw TodoManagementError.calendarDenied }
    }
    func calendars() throws -> [TodoCalendarOption] { [TodoCalendarOption(id: "calendar", title: "Work")] }
    func upsert(identifier: String?, calendarID: String?, title: String, start: Date, end: Date, isAllDay: Bool) throws -> TodoCalendarLink {
        let existing = identifier.flatMap { events[$0] }
        let id = existing == nil ? UUID().uuidString : identifier!
        if existing == nil { createdCount += 1 } else { updatedCount += 1 }
        events[id] = Event(title: title, start: start, end: end, isAllDay: isAllDay)
        return TodoCalendarLink(identifier: id, created: existing == nil)
    }
    func removeCreatedEvent(identifier: String) throws {
        if failRemoval { throw TodoManagementError.calendarUnavailable }
        events[identifier] = nil; removes += 1
    }
}

final class TodoManagementTests: XCTestCase {
    private func calendar(_ zone: String = "Asia/Seoul") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }
    private func date(_ day: Int = 1, hour: Int = 12, calendar: Calendar? = nil) -> Date {
        (calendar ?? self.calendar()).date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }
    @MainActor private func repo(clock: @escaping () -> Date = Date.init) throws -> SwiftDataTodoRepository {
        SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true), clock: clock)
    }

    @MainActor func testFullInitiallyTodayAndSelectingDateIncludesCompleted() throws {
        let repo = try repo()
        let past = try repo.create(TodoDraft(title: "past", date: date(1)), calendar: calendar())
        try repo.complete(todoID: past.id)
        let today = try repo.create(TodoDraft(title: "today", date: date(3)), calendar: calendar())
        let model = try TodoViewModel(repository: repo, calendar: calendar(), clock: { self.date(3) })
        XCTAssertEqual(model.fullDate, calendar().startOfDay(for: date(3)))
        XCTAssertEqual(model.fullItems.map(\.id), [today.id])
        model.selectFullDate(date(1))
        XCTAssertEqual(model.fullItems.map(\.id), [past.id])
        XCTAssertTrue(model.fullItems[0].isCompleted)
        model.openFullToday()
        XCTAssertEqual(model.fullItems.map(\.id), [today.id])
    }

    @MainActor func testPastRedDotsAreDeduplicatedAndClearImmediatelyOnCompletion() throws {
        let repo = try repo()
        let a = try repo.create(TodoDraft(title: "a", date: date(1)), calendar: calendar())
        let b = try repo.create(TodoDraft(title: "b", date: date(1)), calendar: calendar())
        _ = try repo.create(TodoDraft(title: "today", date: date(3)), calendar: calendar())
        _ = try repo.create(TodoDraft(title: "future", date: date(4)), calendar: calendar())
        let model = try TodoViewModel(repository: repo, calendar: calendar(), clock: { self.date(3) })
        XCTAssertEqual(model.overdueDays, [calendar().startOfDay(for: date(1))])
        model.selectFullDate(date(1))
        model.setCompleted(a, completed: true)
        XCTAssertEqual(model.fullItems.map(\.id), [b.id, a.id])
        XCTAssertEqual(model.overdueDays.count, 1)
        model.setCompleted(b, completed: true)
        XCTAssertTrue(model.overdueDays.isEmpty)
        model.setCompleted(a, completed: false)
        XCTAssertEqual(model.overdueDays.count, 1)
    }

    @MainActor func testMiniDateAndCreationStayTodayWhileFullUsesSelectedDate() throws {
        let repo = try repo()
        let model = try TodoViewModel(repository: repo, calendar: calendar(), clock: { self.date(3) })
        model.selectFullDate(date(1))
        model.quickTitle = "full past"
        XCTAssertTrue(model.submitFullQuickEntry())
        XCTAssertEqual(model.fullItems.first?.date, calendar().startOfDay(for: date(1)))
        XCTAssertTrue(model.todayItems.isEmpty)
        model.quickTitle = "mini today"
        XCTAssertTrue(model.submitTodayQuickEntry())
        XCTAssertEqual(model.todayItems.first?.title, "mini today")
        XCTAssertEqual(model.fullItems.first?.title, "full past")
        XCTAssertTrue(model.quickWantsFocus)
    }

    @MainActor func testGroupAssignChangeAndClearPreserveNotes() throws {
        let repo = try repo()
        let a = try repo.createGroup(name: "A"), b = try repo.createGroup(name: "B")
        let item = try repo.create(TodoDraft(title: "task", notes: "keep", date: date()), calendar: calendar())
        let model = try TodoViewModel(repository: repo, calendar: calendar(), clock: { self.date() })
        model.changeFullGroup(item, groupID: a.id)
        XCTAssertEqual(model.fullItems.first?.groupID, a.id)
        model.changeFullGroup(item, groupID: b.id)
        XCTAssertEqual(model.fullItems.first?.groupID, b.id)
        model.changeFullGroup(item, groupID: nil)
        XCTAssertNil(model.fullItems.first?.groupID)
        XCTAssertEqual(model.fullItems.first?.notes, "keep")
    }

    func testWeekdayRuleRoundTripValidationAndMatching() {
        let rule = TodoWeekdayRule([2,4,6])
        XCTAssertEqual(TodoWeekdayRule.decode(rule.encoded), rule)
        XCTAssertTrue(rule.matches(date(2), calendar: calendar())) // Friday
        XCTAssertFalse(rule.matches(date(3), calendar: calendar()))
        XCTAssertNil(TodoWeekdayRule.decode("legacy opaque rule"))
        XCTAssertNil(TodoWeekdayRule.decode("{\"version\":2,\"weekdays\":[2]}"))
        XCTAssertNil(TodoWeekdayRule.decode("{\"version\":1,\"weekdays\":[8]}"))
    }

    @MainActor func testRepeatPersistsRuleAndDoesNotGenerateFutureOrNonMatchingDay() throws {
        var now = date(1)
        let repo = try repo(clock: { now })
        let item = try repo.create(TodoDraft(title: "repeat", date: now), calendar: calendar())
        try repo.setRepeat(todoID: item.id, weekdays: [6], calendar: calendar()) // Friday
        let saved = try XCTUnwrap(repo.allTodos().first)
        XCTAssertEqual(TodoWeekdayRule.decode(saved.repeatRule)?.weekdays, [6])
        XCTAssertNotNil(saved.repeatScheduleID)
        try repo.materializeRepeats(on: date(2), calendar: calendar())
        XCTAssertEqual(try repo.allTodos().count, 1)
        now = date(3) // Saturday
        try repo.materializeRepeats(on: now, calendar: calendar())
        XCTAssertEqual(try repo.allTodos().count, 1)
    }

    @MainActor func testRepeatTodayInstanceIsIdempotentAndCompletionIndependent() throws {
        var now = date(1)
        let repo = try repo(clock: { now })
        let item = try repo.create(TodoDraft(title: "repeat", date: now), calendar: calendar())
        try repo.setRepeat(todoID: item.id, weekdays: [5,6], calendar: calendar())
        try repo.materializeRepeats(on: now, calendar: calendar())
        XCTAssertEqual(try repo.allTodos().count, 1)
        try repo.complete(todoID: item.id)
        now = date(2)
        try repo.materializeRepeats(on: now, calendar: calendar())
        try repo.materializeRepeats(on: now, calendar: calendar())
        let all = try repo.allTodos()
        XCTAssertEqual(all.count, 2)
        let next = try XCTUnwrap(all.first { $0.id != item.id })
        XCTAssertFalse(next.isCompleted)
        XCTAssertNil(next.completedAt)
        XCTAssertEqual(next.repeatScheduleID, all.first { $0.id == item.id }?.repeatScheduleID)
        try repo.complete(todoID: next.id)
        try repo.materializeRepeats(on: now, calendar: calendar())
        XCTAssertEqual(try repo.allTodos().count, 2)
    }

    @MainActor func testRepeatDisableKeepsInstancesAndStopsNextOccurrence() throws {
        var now = date(1)
        let repo = try repo(clock: { now })
        let item = try repo.create(TodoDraft(title: "repeat", date: now), calendar: calendar())
        try repo.setRepeat(todoID: item.id, weekdays: [5,6,7], calendar: calendar())
        now = date(2)
        try repo.materializeRepeats(on: now, calendar: calendar())
        let next = try XCTUnwrap(repo.allTodos().first { $0.id != item.id })
        try repo.setRepeat(todoID: next.id, weekdays: [], calendar: calendar())
        now = date(3)
        try repo.materializeRepeats(on: now, calendar: calendar())
        XCTAssertEqual(try repo.allTodos().count, 2)
        XCTAssertTrue(try repo.allTodos().allSatisfy { $0.repeatRule == nil })
    }

    @MainActor func testRepeatInstancesPreserveGroupNotesAndRelativeDeadlineButNotCalendarID() throws {
        var now = date(1)
        let repo = try repo(clock: { now })
        let group = try repo.createGroup(name: "group")
        let item = try repo.create(TodoDraft(title: "repeat", notes: "note", date: now, groupID: group.id), calendar: calendar())
        try repo.setDeadline(todoID: item.id, start: date(3, hour: 9), deadline: date(3, hour: 18), calendar: calendar())
        try repo.setCalendarEventID(todoID: item.id, identifier: "original event")
        try repo.setRepeat(todoID: item.id, weekdays: [6], calendar: calendar())
        now = date(2)
        try repo.materializeRepeats(on: now, calendar: calendar())
        let next = try XCTUnwrap(repo.allTodos().first { $0.id != item.id })
        XCTAssertEqual(next.notes, "note")
        XCTAssertEqual(next.groupID, group.id)
        XCTAssertEqual(next.startDateTime, date(4, hour: 9))
        XCTAssertEqual(next.deadlineDateTime, date(4, hour: 18))
        XCTAssertNil(next.linkedCalendarEventID)
    }

    @MainActor func testDeadlineSaveRemoveAndDateMeaningRemainIndependent() throws {
        let repo = try repo()
        let item = try repo.create(TodoDraft(title: "task", date: date(1)), calendar: calendar())
        try repo.setDeadline(todoID: item.id, start: date(5, hour: 9), deadline: date(5, hour: 18), calendar: calendar())
        let saved = try XCTUnwrap(repo.allTodos().first)
        XCTAssertEqual(saved.date, item.date)
        XCTAssertEqual(saved.startDateTime, date(5, hour: 9))
        XCTAssertEqual(saved.deadlineDateTime, date(5, hour: 18))
        try repo.setDeadline(todoID: item.id, start: nil, deadline: nil, calendar: calendar())
        let removed = try XCTUnwrap(repo.allTodos().first)
        XCTAssertNil(removed.startDateTime)
        XCTAssertNil(removed.deadlineDateTime)
        XCTAssertEqual(removed.date, item.date)
    }

    @MainActor func testInvalidDeadlineRangeDoesNotChangePersistedValue() throws {
        let repo = try repo()
        let item = try repo.create(TodoDraft(title: "task", date: date()), calendar: calendar())
        try repo.setDeadline(todoID: item.id, start: nil, deadline: date(5, hour: 18), calendar: calendar())
        XCTAssertThrowsError(try repo.setDeadline(todoID: item.id, start: date(5, hour: 19), deadline: date(5, hour: 18), calendar: calendar()))
        XCTAssertThrowsError(try repo.setDeadline(todoID: item.id, start: date(4, hour: 9), deadline: date(5, hour: 18), calendar: calendar()))
        XCTAssertEqual(try repo.allTodos().first?.deadlineDateTime, date(5, hour: 18))
    }

    func testDDayFutureTodayAndPast() {
        XCTAssertEqual(TodoDates.dDay(deadline: date(4), now: date(1), calendar: calendar()), "D-3")
        XCTAssertEqual(TodoDates.dDay(deadline: date(1, hour: 18), now: date(1), calendar: calendar()), "D-DAY")
        XCTAssertEqual(TodoDates.dDay(deadline: date(1), now: date(2), calendar: calendar()), "D+1")
        XCTAssertNil(TodoDates.dDay(deadline: nil, now: date(), calendar: calendar()))
    }

    func testDDayUsesLocalDaysAcrossDSTInsteadOfHours() {
        let calendar = calendar("America/New_York")
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23, minute: 30))!
        let due = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 0, minute: 15))!
        XCTAssertLessThan(due.timeIntervalSince(now), 25 * 3600)
        XCTAssertEqual(TodoDates.dDay(deadline: due, now: now, calendar: calendar), "D-2")
    }

    @MainActor func testCalendarCreatesStoresIDAndUpdatesSameEvent() async throws {
        let repo = try repo()
        let fake = FakeTodoCalendarService()
        let item = try repo.create(TodoDraft(title: "task", date: date()), calendar: calendar())
        try repo.setDeadline(todoID: item.id, start: date(5, hour: 9), deadline: date(5, hour: 18), calendar: calendar())
        let model = try TodoViewModel(repository: repo, calendar: calendar(), clock: { self.date() }, calendarService: fake)
        let first = try XCTUnwrap(model.fullItems.first)
        let result1 = await model.loadCalendarOptions(for: first)
        XCTAssertTrue(result1)
        XCTAssertEqual(model.calendarOptions.first?.id, "calendar")
        let result2 = await model.linkCalendar(first, calendarID: "calendar")
        XCTAssertTrue(result2)
        let id = try XCTUnwrap(model.fullItems.first?.linkedCalendarEventID)
        try repo.update(todoID: item.id, draft: TodoDraft(title: "changed", date: date()), calendar: calendar())
        try repo.setDeadline(todoID: item.id, start: date(6, hour: 10), deadline: date(6, hour: 19), calendar: calendar())
        model.refresh()
        let result3 = await model.linkCalendar(try XCTUnwrap(model.fullItems.first))
        XCTAssertTrue(result3)
        XCTAssertEqual(model.fullItems.first?.linkedCalendarEventID, id)
        XCTAssertEqual(fake.createdCount, 1)
        XCTAssertEqual(fake.updatedCount, 1)
        XCTAssertEqual(fake.events[id]?.title, "changed")
        XCTAssertEqual(fake.events[id]?.start, date(6, hour: 10))
        XCTAssertEqual(fake.events[id]?.end, date(6, hour: 19))
    }

    @MainActor func testCalendarDeletedExternalEventIsRecreated() async throws {
        let repo = try repo()
        let fake = FakeTodoCalendarService()
        let item = try repo.create(TodoDraft(title: "task", date: date()), calendar: calendar())
        try repo.setDeadline(todoID: item.id, start: nil, deadline: date(5, hour: 18), calendar: calendar())
        try repo.setCalendarEventID(todoID: item.id, identifier: "deleted")
        let model = try TodoViewModel(repository: repo, calendar: calendar(), clock: { self.date() }, calendarService: fake)
        let result4 = await model.linkCalendar(try XCTUnwrap(model.fullItems.first))
        XCTAssertTrue(result4)
        XCTAssertNotEqual(model.fullItems.first?.linkedCalendarEventID, "deleted")
        XCTAssertEqual(fake.createdCount, 1)
        XCTAssertEqual(fake.events.count, 1)
    }

    @MainActor func testCalendarPermissionDeniedLeavesTodoUntouched() async throws {
        let repo = try repo()
        let fake = FakeTodoCalendarService(); fake.denied = true
        let item = try repo.create(TodoDraft(title: "task", date: date()), calendar: calendar())
        try repo.setDeadline(todoID: item.id, start: nil, deadline: date(5), calendar: calendar())
        let model = try TodoViewModel(repository: repo, calendar: calendar(), clock: { self.date() }, calendarService: fake)
        let result5 = await model.linkCalendar(try XCTUnwrap(model.fullItems.first))
        XCTAssertFalse(result5)
        XCTAssertTrue(model.calendarError?.contains("캘린더 권한") == true)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(fake.createdCount, 0)
        XCTAssertNil(model.fullItems.first?.linkedCalendarEventID)
        XCTAssertFalse(model.calendarBusy)
    }

    @MainActor func testCalendarWithoutDeadlineDoesNotEvenRequestAccess() async throws {
        let repo = try repo()
        let fake = FakeTodoCalendarService()
        _ = try repo.create(TodoDraft(title: "task", date: date()), calendar: calendar())
        let model = try TodoViewModel(repository: repo, calendar: calendar(), clock: { self.date() }, calendarService: fake)
        let result6 = await model.linkCalendar(try XCTUnwrap(model.fullItems.first))
        XCTAssertFalse(result6)
        XCTAssertEqual(fake.requestCount, 0)
        XCTAssertEqual(fake.createdCount, 0)
        XCTAssertTrue(model.calendarError?.contains("마감일을 먼저") == true)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor func testFailedCalendarIDSaveRemovesNewEventSoRetryDoesNotDuplicate() async throws {
        var failSave = false
        let repo = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true), saveContext: {
            if failSave { throw TodoManagementError.unsupported }; try $0.save()
        })
        let fake = FakeTodoCalendarService()
        let item = try repo.create(TodoDraft(title: "task", date: date()), calendar: calendar())
        try repo.setDeadline(todoID: item.id, start: nil, deadline: date(5), calendar: calendar())
        let model = try TodoViewModel(repository: repo, calendar: calendar(), clock: { self.date() }, calendarService: fake)
        failSave = true
        let result7 = await model.linkCalendar(try XCTUnwrap(model.fullItems.first))
        XCTAssertFalse(result7)
        XCTAssertEqual(fake.removes, 1)
        XCTAssertTrue(fake.events.isEmpty)
        failSave = false
        let result8 = await model.linkCalendar(try XCTUnwrap(model.fullItems.first))
        XCTAssertTrue(result8)
        XCTAssertEqual(fake.events.count, 1)
        XCTAssertNotNil(model.fullItems.first?.linkedCalendarEventID)
    }

    @MainActor func testV1DiskStoreMigratesToV2WithoutLosingLegacyFields() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PIAAR-Migration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Todo.store")
        let id: UUID = try autoreleasepool {
            let schema = Schema(versionedSchema: TodoSchemaV1.self)
            let config = ModelConfiguration("Todo", schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)
            let group = TodoSchemaV1.TodoGroup(name: "old group", now: date())
            let item = TodoSchemaV1.TodoItem(title: "old todo", notes: "old notes", date: calendar().startOfDay(for: date()), group: group, now: date())
            item.repeatRule = "legacy opaque rule"
            item.linkedCalendarEventID = "existing-calendar-id"
            item.isCompleted = true; item.completedAt = date(); item.sortOrder = 17
            context.insert(group); context.insert(item); try context.save()
            return item.id
        }
        // Checksums captured from the actual pre-change build with top-level models.
        // This catches accidental changes to frozen V1, including relationship metadata.
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url, options: nil)
        let hashes = try XCTUnwrap(metadata[NSStoreModelVersionHashesKey] as? [String: Data])
        XCTAssertEqual(hashes["TodoItem"]?.map { String(format: "%02x", $0) }.joined(),
                       "1fd7642282eb2815f24ed4ed291ad1dd2e65c7313735bfcd545bd7dd57f786a4")
        XCTAssertEqual(hashes["TodoGroup"]?.map { String(format: "%02x", $0) }.joined(),
                       "e52bf258b9c5ddb9c8bc1603ca65709623c0d18d65897f32c0832d025cb0ec73")
        let repo = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(storeURL: url))
        let migrated = try XCTUnwrap(repo.allTodos().first)
        XCTAssertEqual(migrated.id, id)
        XCTAssertEqual(migrated.notes, "old notes")
        XCTAssertEqual(migrated.repeatRule, "legacy opaque rule")
        XCTAssertEqual(migrated.linkedCalendarEventID, "existing-calendar-id")
        XCTAssertEqual(migrated.sortOrder, 17)
        XCTAssertEqual(migrated.date, calendar().startOfDay(for: date()))
        XCTAssertEqual(migrated.createdAt, date())
        XCTAssertEqual(migrated.updatedAt, date())
        XCTAssertEqual(migrated.completedAt, date())
        XCTAssertTrue(migrated.isCompleted)
        XCTAssertEqual(try repo.groups().first?.name, "old group")
        XCTAssertEqual(migrated.groupID, try repo.groups().first?.id)
        XCTAssertNil(migrated.deadlineDateTime)
        XCTAssertNil(migrated.repeatScheduleID)
        try repo.setDeadline(todoID: id, start: date(5, hour: 9), deadline: date(5, hour: 18), calendar: calendar())
        let reloaded = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(storeURL: url))
        XCTAssertEqual(try reloaded.allTodos().first?.deadlineDateTime, date(5, hour: 18))
        XCTAssertEqual(try reloaded.allTodos().first?.linkedCalendarEventID, "existing-calendar-id")
    }
    @MainActor func testRecurrenceScheduleSurvivesDiskReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PIAAR-Repeat-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Todo.store")
        let id: UUID = try autoreleasepool {
            let repo = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(storeURL: url), clock: { self.date(1) })
            let item = try repo.create(TodoDraft(title: "saved rule", date: date(1)), calendar: calendar())
            try repo.setRepeat(todoID: item.id, weekdays: [6], calendar: calendar())
            try repo.complete(todoID: item.id)
            return item.id
        }
        let repo = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(storeURL: url), clock: { self.date(2) })
        try repo.materializeRepeats(on: date(2), calendar: calendar())
        let all = try repo.allTodos()
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(try XCTUnwrap(all.first { $0.id == id }).isCompleted)
        XCTAssertFalse(try XCTUnwrap(all.first { $0.id != id }).isCompleted)
        XCTAssertEqual(TodoWeekdayRule.decode(all.first { $0.id != id }?.repeatRule)?.weekdays, [6])
    }

    func testCalendarPermissionDescriptionsExistInAppBundle() {
        XCTAssertFalse((Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") as? String ?? "").isEmpty)
        XCTAssertFalse((Bundle.main.object(forInfoDictionaryKey: "NSCalendarsUsageDescription") as? String ?? "").isEmpty)
    }

}

final class TodoSectionsTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Asia/Seoul")!; return value
    }
    private func date(_ day: Int = 1, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }
    @MainActor private func repository() throws -> SwiftDataTodoRepository {
        SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true), clock: { self.date() })
    }
    @MainActor func testSectionsUseGroupOrderUngroupedLastAndCompletionOrder() throws {
        let repo = try repository()
        let a = try repo.createColoredGroup(name: "A", colorHex: "#E05252")
        let b = try repo.createColoredGroup(name: "B", colorHex: "#9469BB")
        try repo.setGroupSortOrder(groupID: a.id, sortOrder: 5)
        let done = try repo.create(TodoDraft(title: "done", date: date(), groupID: b.id), calendar: calendar)
        let open = try repo.create(TodoDraft(title: "open", date: date(), groupID: b.id), calendar: calendar)
        let plain = try repo.create(TodoDraft(title: "plain", date: date()), calendar: calendar)
        try repo.complete(todoID: done.id)
        let model = try TodoViewModel(repository: repo, calendar: calendar, clock: { self.date() })
        XCTAssertEqual(model.fullSections.map { $0.group?.id }, [b.id, a.id, nil])
        XCTAssertEqual(model.fullSections[0].items.map(\.id), [open.id, done.id])
        XCTAssertEqual(model.fullSections.last?.items.map(\.id), [plain.id])
        XCTAssertEqual(model.colorHex(for: done), "#9469BB")
        XCTAssertNil(model.colorHex(for: plain))
    }
    @MainActor func testNewColoredGroupIsPersistedAndCanBeAssignedToNewTodo() throws {
        let repo = try repository()
        let model = try TodoViewModel(repository: repo, calendar: calendar, clock: { self.date() })
        let group = try XCTUnwrap(model.createFullGroup(name: " red ", colorHex: "#E05252"))
        XCTAssertEqual(group.name, "red")
        XCTAssertEqual(try repo.groups().first?.colorHex, "#E05252")
        model.quickTitle = "group task"
        XCTAssertTrue(model.submitFullQuickEntry())
        model.beginFullEditing(try XCTUnwrap(model.fullItems.first))
        var session = try XCTUnwrap(model.fullEditor)
        XCTAssertNil(session.draft.groupID)
        XCTAssertFalse(session.linkCalendar)
        session.draft.groupID = group.id
        let item = try XCTUnwrap(model.saveFullEditor(session))
        XCTAssertEqual(item.groupID, group.id)
        XCTAssertNil(item.startDateTime)
        XCTAssertNil(item.deadlineDateTime)
        XCTAssertNil(item.deadlineDate)
    }
    @MainActor func testQuickAdditionDefaultsToNoGroupAndEditingReusesSession() throws {
        let model = try TodoViewModel(repository: repository(), calendar: calendar, clock: { self.date() })
        model.quickTitle = "plain"
        XCTAssertTrue(model.submitFullQuickEntry())
        XCTAssertNil(model.fullEditor)
        let item = try XCTUnwrap(model.fullItems.first)
        XCTAssertNil(item.groupID)
        model.beginFullEditing(item)
        let first = try XCTUnwrap(model.fullEditor)
        model.beginFullEditing(item)
        XCTAssertEqual(model.fullEditor?.id, first.id)
        XCTAssertNil(model.fullEditor?.draft.groupID)
    }
    func testHexResolutionSupportsExistingShortAndAlphaValuesAndInvalidFallback() {
        XCTAssertEqual(TodoGroupColors.rgb("#f00"), TodoGroupColors.rgb("#FF0000"))
        XCTAssertEqual(TodoGroupColors.rgb("#FF000080")?.alpha, Double(128) / 255)
        XCTAssertNil(TodoGroupColors.rgb(nil))
        XCTAssertNil(TodoGroupColors.rgb("bad hex"))
        XCTAssertEqual(TodoGroupColors.palette.count, 7)
    }
    @MainActor func testDateOnlyDeadlineStoresBothTimesNilAndDDayUsesDate() throws {
        let repo = try repository()
        let saved = try repo.saveManagedTodo(id: nil, draft: TodoDraft(title: "date only", date: date()),
            deadlineDay: date(4), start: nil, end: nil, weekdays: [], calendar: calendar)
        XCTAssertEqual(saved.deadlineDate, calendar.startOfDay(for: date(4)))
        XCTAssertNil(saved.startDateTime)
        XCTAssertNil(saved.deadlineDateTime)
        let model = try TodoViewModel(repository: repo, calendar: calendar, clock: { self.date() })
        XCTAssertEqual(model.dDay(saved), "D-3")
    }
    @MainActor func testStartOnlyDeadlineIsAllowedWithoutStoringEnd() throws {
        let repo = try repository()
        let saved = try repo.saveManagedTodo(id: nil, draft: TodoDraft(title: "start only", date: date()),
            deadlineDay: date(4), start: date(4, hour: 9), end: nil, weekdays: [], calendar: calendar)
        XCTAssertEqual(saved.startDateTime, date(4, hour: 9))
        XCTAssertNil(saved.deadlineDateTime)
        XCTAssertNotNil(saved.deadlineDate)
    }
    @MainActor func testEndOnlyDeadlineIsAllowedWithoutStoringStart() throws {
        let saved = try repository().saveManagedTodo(id: nil, draft: TodoDraft(title: "end only", date: date()),
            deadlineDay: date(4), start: nil, end: date(4, hour: 18), weekdays: [], calendar: calendar)
        XCTAssertNil(saved.startDateTime)
        XCTAssertEqual(saved.deadlineDateTime, date(4, hour: 18))
    }
    @MainActor func testInvalidBothTimesRejectsWithoutCreatingPartialTodo() throws {
        let repo = try repository()
        XCTAssertThrowsError(try repo.saveManagedTodo(id: nil, draft: TodoDraft(title: "invalid", date: date()),
            deadlineDay: date(4), start: date(4, hour: 19), end: date(4, hour: 18), weekdays: [], calendar: calendar))
        XCTAssertTrue(try repo.allTodos().isEmpty)
    }
    @MainActor func testEditorUpdatesPreserveIdentityNotesCompletionAndCalendarLink() throws {
        let repo = try repository()
        let item = try repo.create(TodoDraft(title: "old", notes: "keep", date: date()), calendar: calendar)
        try repo.complete(todoID: item.id); try repo.setCalendarEventID(todoID: item.id, identifier: "linked")
        let model = try TodoViewModel(repository: repo, calendar: calendar, clock: { self.date() })
        model.beginFullEditing(try XCTUnwrap(model.fullItems.first))
        var session = try XCTUnwrap(model.fullEditor)
        session.draft.title = "edited"
        session.deadlineDay = date(4)
        let saved = try XCTUnwrap(model.saveFullEditor(session))
        XCTAssertEqual(saved.id, item.id); XCTAssertEqual(saved.notes, "keep")
        XCTAssertTrue(saved.isCompleted); XCTAssertEqual(saved.linkedCalendarEventID, "linked")
        XCTAssertEqual(saved.createdAt, item.createdAt); XCTAssertEqual(saved.date, item.date)
        XCTAssertNil(saved.startDateTime); XCTAssertNil(saved.deadlineDateTime)
    }
    @MainActor func testFailedManagedSaveRollsBackWholeCreationIncludingRepeatTemplate() throws {
        let container = try TodoPersistence.makeContainer(inMemory: true)
        let repo = SwiftDataTodoRepository(container: container, saveContext: { _ in throw TodoManagementError.unsupported })
        XCTAssertThrowsError(try repo.saveManagedTodo(id: nil, draft: TodoDraft(title: "failed", date: date()),
            deadlineDay: date(4), start: nil, end: nil, weekdays: [2,4], calendar: calendar))
        XCTAssertTrue(try repo.allTodos().isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<TodoRepeatSchedule>()).isEmpty)
    }
    func testCalendarAllDayUsesCalendarBoundariesIncludingDST() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let timing = try TodoCalendarTiming.make(day: day, start: nil, end: nil, calendar: calendar)
        XCTAssertTrue(timing.isAllDay)
        XCTAssertEqual(timing.end.timeIntervalSince(timing.start), 23 * 3600)
    }
    func testCalendarOneSidedTimesUseThirtyMinutesOnlyDuringConversion() throws {
        let start = date(4, hour: 9), end = date(4, hour: 18)
        let a = try TodoCalendarTiming.make(day: date(4), start: start, end: nil, calendar: calendar)
        XCTAssertEqual(a.start, start); XCTAssertEqual(a.end, start.addingTimeInterval(1800)); XCTAssertFalse(a.isAllDay)
        let b = try TodoCalendarTiming.make(day: date(4), start: nil, end: end, calendar: calendar)
        XCTAssertEqual(b.end, end); XCTAssertEqual(b.start, end.addingTimeInterval(-1800)); XCTAssertFalse(b.isAllDay)
        let c = try TodoCalendarTiming.make(day: date(4), start: start, end: end, calendar: calendar)
        XCTAssertEqual(c.start, start); XCTAssertEqual(c.end, end)
    }
    @MainActor func testAllDayCalendarLinkDoesNotPopulateTodoTimesAndErrorStaysSeparate() async throws {
        let repo = try repository(); let fake = FakeTodoCalendarService()
        let item = try repo.saveManagedTodo(id: nil, draft: TodoDraft(title: "all day", date: date()),
            deadlineDay: date(4), start: nil, end: nil, weekdays: [], calendar: calendar)
        let model = try TodoViewModel(repository: repo, calendar: calendar, clock: { self.date() }, calendarService: fake)
        let linked = await model.linkCalendar(item)
        XCTAssertTrue(linked)
        XCTAssertTrue(try XCTUnwrap(fake.events.values.first).isAllDay)
        XCTAssertNil(model.fullItems.first?.startDateTime); XCTAssertNil(model.fullItems.first?.deadlineDateTime)
        fake.denied = true
        let failed = await model.linkCalendar(item)
        XCTAssertFalse(failed); XCTAssertNotNil(model.calendarError); XCTAssertNil(model.errorMessage)
        model.refresh()
        XCTAssertEqual(model.fullItems.count, 1)
    }
    @MainActor func testDateOnlyRepeatsKeepTimesUnspecifiedInNextInstance() throws {
        var now = date(1)
        let repo = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true), clock: { now })
        let item = try repo.saveManagedTodo(id: nil, draft: TodoDraft(title: "repeat", date: now),
            deadlineDay: date(4), start: nil, end: nil, weekdays: [6], calendar: calendar)
        now = date(2); try repo.materializeRepeats(on: now, calendar: calendar)
        let next = try XCTUnwrap(repo.allTodos().first { $0.id != item.id })
        XCTAssertEqual(next.deadlineDate, calendar.startOfDay(for: date(5)))
        XCTAssertNil(next.startDateTime); XCTAssertNil(next.deadlineDateTime)
    }
    @MainActor func testV2MigrationPreservesExactDeadlineTimesAndRepeatSchedule() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PIAAR-V2-V3-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Todo.store")
        let id: UUID = try autoreleasepool {
            let schema = Schema(versionedSchema: TodoSchemaV2.self)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration("Todo", schema: schema, url: url, cloudKitDatabase: .none)])
            let context = ModelContext(container)
            let group = TodoSchemaV2.TodoGroup(name: "V2 group", colorHex: "#9469BB", now: date())
            let item = TodoSchemaV2.TodoItem(title: "V2 todo", notes: "notes", date: calendar.startOfDay(for: date()), group: group, now: date())
            let rule = TodoSchemaV2.TodoRepeatSchedule(title: "repeat", beginsOn: item.date, now: date())
            rule.weekdayMask = 1 << 5
            item.repeatScheduleID = rule.id; item.repeatRule = TodoWeekdayRule([6]).encoded
            item.startDateTime = date(4, hour: 9); item.deadlineDateTime = date(4, hour: 18)
            item.linkedCalendarEventID = "existing"
            context.insert(group); context.insert(item); context.insert(rule); try context.save()
            return item.id
        }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url, options: nil)
        let hashes = try XCTUnwrap(metadata[NSStoreModelVersionHashesKey] as? [String: Data])
        // Captured from the actual V2 source build before this UI change.
        XCTAssertEqual(hashes["TodoItem"]?.map { String(format: "%02x", $0) }.joined(),
                       "590ce337b18dcf881f63348790ba04862ad472ce6eb0ddde07e8e539e4e3b933")
        XCTAssertEqual(hashes["TodoRepeatSchedule"]?.map { String(format: "%02x", $0) }.joined(),
                       "ff0a7ded17b4f488c91aab054c15a89f877a8efb7355d3536cbd5eaf367c7caf")
        let container = try TodoPersistence.makeContainer(storeURL: url)
        let repo = SwiftDataTodoRepository(container: container, clock: { self.date(2) })
        let old = try XCTUnwrap(repo.allTodos().first)
        XCTAssertEqual(old.id, id); XCTAssertEqual(old.startDateTime, date(4, hour: 9))
        XCTAssertEqual(old.deadlineDateTime, date(4, hour: 18)); XCTAssertEqual(old.effectiveDeadlineDate, date(4, hour: 18))
        XCTAssertEqual(old.linkedCalendarEventID, "existing"); XCTAssertEqual(try repo.groups().first?.colorHex, "#9469BB")
        try repo.materializeRepeats(on: date(2), calendar: calendar)
        XCTAssertEqual(try repo.allTodos().count, 2)
        let session = TodoEditorSession(item: old)
        var changed = session; changed.start = nil; changed.end = nil
        _ = try repo.saveManagedTodo(id: id, draft: changed.draft, deadlineDay: changed.deadlineDay,
            start: nil, end: nil, weekdays: changed.weekdays, calendar: calendar)
        let saved = try XCTUnwrap(repo.allTodos().first { $0.id == id })
        XCTAssertNil(saved.startDateTime); XCTAssertNil(saved.deadlineDateTime); XCTAssertNotNil(saved.deadlineDate)
        XCTAssertEqual(saved.linkedCalendarEventID, "existing")
    }
    @MainActor func testHiddenNotesAndOriginalDateAreNotNormalizedByTitleEditing() throws {
        let container = try TodoPersistence.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let exactDate = date(hour: 8)
        let original = TodoItem(title: "legacy", notes: "  original notes  ", date: exactDate)
        context.insert(original); try context.save()
        let repo = SwiftDataTodoRepository(container: container)
        let saved = try repo.saveManagedTodo(id: original.id,
            draft: TodoDraft(title: "changed", notes: original.notes ?? "", date: original.date),
            deadlineDay: nil, start: nil, end: nil, weekdays: [], calendar: calendar)
        XCTAssertEqual(saved.notes, "  original notes  ")
        XCTAssertEqual(saved.date, exactDate)
        XCTAssertEqual(saved.title, "changed")
    }

}

// These windows belong to the hosted unit-test process, never to normal app
// navigation. Keep real focus tests visible but unmistakable and release their UI.
extension XCTestCase {
    @MainActor
    func identifyTodoTestController<T: NSWindowController>(_ controller: T) -> T {
        if let window = controller.window { identifyTodoTestWindow(window) }
        return controller
    }

    @MainActor
    func identifyTodoTestWindow(_ window: NSWindow) {
        guard !window.title.hasPrefix("[Unit Test]") else { return }
        window.title = "[Unit Test] " + name
        window.setFrameAutosaveName("")
        addTeardownBlock { await MainActor.run {
            window.orderOut(nil)
            window.contentViewController = nil
            window.contentView = nil
        } }
    }
}

final class FullTodoInputAndDeadlineTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return value
    }
    private func date(_ day: Int = 5, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }
    @MainActor private func repository() throws -> SwiftDataTodoRepository {
        SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true))
    }

    @MainActor func testGroupInlineEnterUsesGroupAndFullSelectedDate() throws {
        let repo = try repository()
        let group = try repo.createGroup(name: "업무")
        let model = try TodoViewModel(repository: repo, calendar: calendar, clock: { self.date(1) })
        model.selectFullDate(date(5))
        model.beginGroupQuickEntry(groupID: group.id)
        XCTAssertGreaterThan(model.groupQuickFocusRequest, 0)
        model.updateGroupQuickTitle("  공장 확인  ")
        XCTAssertTrue(model.submitGroupQuickEntry())
        let item = try XCTUnwrap(repo.allTodos().first)
        XCTAssertEqual(item.title, "공장 확인")
        XCTAssertEqual(item.groupID, group.id)
        XCTAssertEqual(item.date, calendar.startOfDay(for: date(5)))
        XCTAssertNil(item.repeatScheduleID)
        XCTAssertNil(item.effectiveDeadlineDate)
        XCTAssertNil(item.linkedCalendarEventID)
        XCTAssertNil(model.groupQuickEntry)
        XCTAssertNil(model.fullEditor)
    }

    @MainActor func testUngroupedInlineEnterStoresNilGroup() throws {
        let repo = try repository()
        let model = try TodoViewModel(repository: repo, calendar: calendar, clock: { self.date() })
        model.beginGroupQuickEntry(groupID: nil)
        XCTAssertNotNil(model.groupQuickEntry)
        model.updateGroupQuickTitle("기타")
        XCTAssertTrue(model.submitGroupQuickEntry())
        XCTAssertNil(try XCTUnwrap(repo.allTodos().first).groupID)
    }

    @MainActor func testInlineEscapeCancelsWithoutCreatingTodo() throws {
        let repo = try repository()
        let model = try TodoViewModel(repository: repo, calendar: calendar, clock: { self.date() })
        model.beginGroupQuickEntry(groupID: nil)
        model.updateGroupQuickTitle("취소")
        model.cancelGroupQuickEntry()
        XCTAssertNil(model.groupQuickEntry)
        XCTAssertFalse(model.submitGroupQuickEntry())
        XCTAssertTrue(try repo.allTodos().isEmpty)
    }

    @MainActor func testOnlyOneGroupInlineInputIsActive() throws {
        let model = try TodoViewModel(repository: repository(), calendar: calendar, clock: { self.date() })
        let first = UUID(), second = UUID()
        model.beginGroupQuickEntry(groupID: first)
        model.updateGroupQuickTitle("old")
        let revision = model.groupQuickFocusRequest
        model.beginGroupQuickEntry(groupID: second)
        XCTAssertEqual(model.groupQuickEntry?.groupID, second)
        XCTAssertEqual(model.groupQuickEntry?.title, "")
        XCTAssertGreaterThan(model.groupQuickFocusRequest, revision)
    }

    @MainActor func testCommandNClosesGroupEntryAndFocusesTopInputWithoutSheet() throws {
        let model = try TodoViewModel(repository: repository(), calendar: calendar, clock: { self.date() })
        model.beginGroupQuickEntry(groupID: UUID())
        model.updateGroupQuickTitle("draft")
        model.focusFullQuickEntry()
        XCTAssertNil(model.groupQuickEntry)
        XCTAssertTrue(model.quickWantsFocus)
        XCTAssertNil(model.fullEditor)
        model.quickTitle = "top"
        XCTAssertTrue(model.submitFullQuickEntry())
        XCTAssertNil(model.fullItems.first?.groupID)
        XCTAssertTrue(model.quickWantsFocus)
    }

    @MainActor func testEmptyGroupInputDoesNotCreateOrCloseEntry() throws {
        let repo = try repository()
        let model = try TodoViewModel(repository: repo, calendar: calendar, clock: { self.date() })
        model.beginGroupQuickEntry(groupID: nil)
        model.updateGroupQuickTitle("   ")
        XCTAssertFalse(model.submitGroupQuickEntry())
        XCTAssertNotNil(model.groupQuickEntry)
        XCTAssertTrue(try repo.allTodos().isEmpty)
    }

    func testDeadlineDraftStartsUnspecifiedAndSaveKeepsTimesNil() throws {
        var session = TodoEditorSession(date: date())
        let draft = TodoDeadlineDraft(session: session)
        XCTAssertNil(draft.start)
        XCTAssertNil(draft.end)
        try draft.apply(to: &session, calendar: calendar)
        XCTAssertEqual(session.deadlineDay, calendar.startOfDay(for: date()))
        XCTAssertNil(session.start)
        XCTAssertNil(session.end)
    }

    func testDeadlineDraftStartOnlyIsAllowed() throws {
        var session = TodoEditorSession(date: date())
        var draft = TodoDeadlineDraft(session: session)
        draft.start = date(1, hour: 9)
        try draft.apply(to: &session, calendar: calendar)
        XCTAssertEqual(session.start, date(5, hour: 9))
        XCTAssertNil(session.end)
    }

    func testDeadlineDraftEndOnlyIsAllowed() throws {
        var session = TodoEditorSession(date: date())
        var draft = TodoDeadlineDraft(session: session)
        draft.end = date(1, hour: 18)
        try draft.apply(to: &session, calendar: calendar)
        XCTAssertNil(session.start)
        XCTAssertEqual(session.end, date(5, hour: 18))
    }

    func testDeadlineDraftBothTimesAndUnspecifiedRestoration() throws {
        var session = TodoEditorSession(date: date())
        var draft = TodoDeadlineDraft(session: session)
        draft.start = date(hour: 9); draft.end = date(hour: 18)
        try draft.apply(to: &session, calendar: calendar)
        XCTAssertEqual(session.start, date(hour: 9))
        XCTAssertEqual(session.end, date(hour: 18))
        draft.start = nil; draft.end = nil
        try draft.apply(to: &session, calendar: calendar)
        XCTAssertNil(session.start)
        XCTAssertNil(session.end)
    }

    func testInvalidBothTimesDoNotChangeEditorSession() throws {
        var session = TodoEditorSession(date: date())
        var draft = TodoDeadlineDraft(session: session)
        draft.start = date(hour: 18); draft.end = date(hour: 9)
        XCTAssertThrowsError(try draft.apply(to: &session, calendar: calendar))
        XCTAssertNil(session.deadlineDay)
        XCTAssertNil(session.start)
        XCTAssertNil(session.end)
        draft.end = draft.start
        XCTAssertThrowsError(try draft.apply(to: &session, calendar: calendar))
    }

    func testUnconfirmedTimeDraftDoesNotModifySession() {
        let session = TodoEditorSession(date: date())
        var draft = TodoDeadlineDraft(session: session)
        draft.start = date(hour: 9)
        draft.end = date(hour: 18)
        XCTAssertNil(session.start)
        XCTAssertNil(session.end)
        XCTAssertNil(session.deadlineDay)
    }
}
