import Foundation
import CryptoKit
import SQLite3
import SwiftData
import Combine

struct LegacyTodoArchive {
    let todos: [TodoSnapshot]
    let groups: [TodoGroupSnapshot]
    let schedules: [LegacyRecurrenceSnapshot]
    let repeatTemplateCount: Int
    init(todos: [TodoSnapshot], groups: [TodoGroupSnapshot], repeatTemplateCount: Int = 0, schedules: [LegacyRecurrenceSnapshot] = []) {
        self.todos = todos; self.groups = groups; self.repeatTemplateCount = max(repeatTemplateCount, schedules.count); self.schedules = schedules
    }
}
@MainActor protocol LegacyTodoSource { func read() throws -> LegacyTodoArchive }
// SwiftData opens and migrates only a SQLite backup, never the user's live archive.
@MainActor final class LegacySwiftDataTodoSource: LegacyTodoSource {
    private let overrideURL: URL?
    init(storeURL: URL? = nil) { overrideURL = storeURL }
    func read() throws -> LegacyTodoArchive {
        let sourceURL = try overrideURL ?? TodoPersistence.storeURL()
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return LegacyTodoArchive(todos: [], groups: []) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PIAAR-LegacyRead-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("Todo.store")
        var source: OpaquePointer?, destination: OpaquePointer?
        guard sqlite3_open_v2(sourceURL.path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(source); throw TaskServiceError.unavailable
        }
        defer { sqlite3_close(source) }
        guard sqlite3_open_v2(copy.path, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            sqlite3_close(destination); throw TaskServiceError.unavailable
        }
        defer { sqlite3_close(destination) }
        sqlite3_busy_timeout(source, 5000)
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else { throw TaskServiceError.unavailable }
        let result = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finish == SQLITE_OK else { throw TaskServiceError.unavailable }
        let container = try TodoPersistence.makeContainer(storeURL: copy)
        let repository = SwiftDataTodoRepository(container: container)
        let schedules = try ModelContext(container).fetch(FetchDescriptor<TodoRepeatSchedule>()).map(LegacyRecurrenceSnapshot.init)
        return try LegacyTodoArchive(todos: repository.allTodos(), groups: repository.groups(), schedules: schedules)
    }
}
enum MigrationIdentity {
    static func id(kind: String, userID: UUID, sourceID: UUID) -> UUID {
        var bytes = Array(SHA256.hash(data: Data((kind + ":" + userID.uuidString + ":" + sourceID.uuidString).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
}
struct LegacyMigrationPreview: Equatable {
    let totalTodos: Int
    let groups: Int
    let importable: Int
    let alreadyImported: Int
    let pendingRepeats: Int
    let notesIncluded: Int
    var regularTodos: Int { totalTodos - repeatedTodos }
    let pendingRepeatTemplates: Int
    var repeatTemplatesReady: Int = 0
    var repeatInstancesReady: Int = 0
    var duplicateRepeatDates: Int = 0
    var pendingTodos: Int = 0
    var missingCompletionTimes: Int = 0
    var repeatedTodos: Int = 0
}
struct LegacyMigrationResult: Equatable {
    var todosTotal = 0
    var todosSucceeded = 0
    var todosFailed = 0
    var groupsTotal = 0
    var groupsSucceeded = 0
    var groupsFailed = 0
    var rulesTotal = 0
    var rulesSucceeded = 0
    var rulesFailed = 0
    var pending = 0
    var calendarFailures = 0
    var stoppedForSession = false
    var completionConstraintFailure = false
}
@MainActor final class LegacyTaskMigration: ObservableObject {
    let userID: UUID
    @Published private(set) var preview: LegacyMigrationPreview?
    @Published private(set) var busy = false
    @Published private(set) var succeeded = 0
    @Published private(set) var failed = 0
    @Published private(set) var groupsSucceeded = 0
    @Published private(set) var groupsFailed = 0
    @Published private(set) var tasksFailed = 0
    @Published private(set) var calendarFailures = 0
    @Published private(set) var result: LegacyMigrationResult?
    // Kept for consumers inspecting the existing queue. Import never mutates it.
    var pendingHistory: Int { eventQueue.pending.count }
    let eventQueue: TaskEventQueue
    @Published private(set) var message: String?
    private let recurrences: TaskRecurrenceService?
    private let source: LegacyTodoSource
    private let tasks: TaskRepository
    private let groups: GroupRepository
    private let calendar: Calendar
    private let links: TaskCalendarLinks
    private let validateSession: (UUID) async throws -> Void
    private let sessionFailure: (CollaborationAuthError) -> Void
    private var archive: LegacyTodoArchive?
    private var previewCalendar: Calendar?
    private var invalidated = false
    init(source: LegacyTodoSource, tasks: TaskRepository, groups: GroupRepository,
         calendar: Calendar = .autoupdatingCurrent, links: TaskCalendarLinks, events: TaskEventQueue? = nil,
         actorDisplayName: @escaping () -> String? = { nil }, recurrences: TaskRecurrenceService? = nil,
         validateSession: @escaping (UUID) async throws -> Void = { _ in },
         sessionFailure: @escaping (CollaborationAuthError) -> Void = { _ in }) {
        self.recurrences = recurrences; self.source = source; self.tasks = tasks; self.groups = groups; self.calendar = calendar
        self.links = links; userID = tasks.userID
        eventQueue = events ?? TaskEventQueue(repository: tasks)
        self.validateSession = validateSession; self.sessionFailure = sessionFailure
    }
    func invalidate() { invalidated = true; archive = nil; preview = nil; previewCalendar = nil; message = nil; busy = false }
    static func pendingReason(_ item: TodoSnapshot) -> String? {
        if item.repeatScheduleID != nil || item.repeatRule != nil { return "반복 규칙 이전 대기" }
        return nil
    }
    private var migrationCalendar: Calendar { previewCalendar ?? calendar }
    private func ensureSession() async throws {
        guard !invalidated else { throw CancellationError() }
        guard tasks.userID == userID, groups.userID == userID,
              recurrences == nil || recurrences?.repository.userID == userID else { throw CollaborationAuthError.sessionMissing }
        try await validateSession(userID)
        guard !invalidated else { throw CancellationError() }
    }
    private func supportedSchedules(_ data: LegacyTodoArchive) -> [LegacyRecurrenceSnapshot] {
        guard recurrences != nil else { return [] }
        let counts = Dictionary(grouping: data.schedules, by: \.id)
        let groupCounts = Dictionary(grouping: data.groups, by: \.id)
        return data.schedules.filter {
            counts[$0.id]?.count == 1 && ($0.groupID == nil || groupCounts[$0.groupID!]?.count == 1) &&
            (try? $0.template(userID: userID, groupID: nil, calendar: migrationCalendar)) != nil
        }
    }
    private func canImport(_ todo: TodoSnapshot, schedules: Set<UUID>, data: LegacyTodoArchive) -> Bool {
        if let id = todo.groupID, data.groups.filter({ $0.id == id }).count != 1 { return false }
        guard (try? Self.draft(todo, groupID: nil, calendar: migrationCalendar).validate()) != nil else { return false }
        if let id = todo.repeatScheduleID { return schedules.contains(id) }
        return Self.pendingReason(todo) == nil
    }
    func loadPreview() async {
        guard !busy, !invalidated else { return }
        busy = true; archive = nil; preview = nil; previewCalendar = nil; result = nil; message = nil
        defer { busy = false }
        do {
            try await ensureSession()
            var frozen = calendar; frozen.timeZone = calendar.timeZone; previewCalendar = frozen
            let data = try source.read()
            let ready = supportedSchedules(data), ids = Set(ready.map(\.id))
            var imported = 0
            var importedIDs = Set<UUID>()
            for todo in data.todos {
                try await ensureSession()
                if try await tasks.importedTask(sourceLocalTodoID: todo.id) != nil { imported += 1; importedIDs.insert(todo.id) }
                else if let schedule = todo.repeatScheduleID, ids.contains(schedule), let service = recurrences,
                        let rule = try await service.repository.ruleIfTemplateExists(scheduleID: schedule, tasks: tasks),
                        try await tasks.recurrenceInstance(id: rule.id, day: TaskDay(todo.date, calendar: frozen)) != nil { imported += 1; importedIDs.insert(todo.id) }
            }
            try await ensureSession()
            let pending = data.todos.filter { !importedIDs.contains($0.id) && !canImport($0, schedules: ids, data: data) }
            let paired = data.todos.compactMap { todo -> String? in
                guard let id = todo.repeatScheduleID, ids.contains(id) else { return nil }
                return id.uuidString + ":" + TaskDay(todo.date, calendar: frozen).value
            }
            let newRepeatDates = data.todos.compactMap { todo -> String? in
                guard !importedIDs.contains(todo.id), canImport(todo, schedules: ids, data: data),
                      let id = todo.repeatScheduleID else { return nil }
                return id.uuidString + ":" + TaskDay(todo.date, calendar: frozen).value
            }
            let coalesced = newRepeatDates.count - Set(newRepeatDates).count
            archive = data
            preview = LegacyMigrationPreview(totalTodos: data.todos.count, groups: data.groups.count,
                importable: data.todos.count - pending.count - imported - coalesced, alreadyImported: imported,
                pendingRepeats: pending.filter { Self.pendingReason($0) != nil }.count,
                notesIncluded: data.todos.filter { !($0.notes ?? "").isEmpty }.count,
                pendingRepeatTemplates: data.repeatTemplateCount - ready.count, repeatTemplatesReady: ready.count,
                repeatInstancesReady: data.todos.filter { $0.repeatScheduleID.map(ids.contains) == true }.count,
                duplicateRepeatDates: paired.count - Set(paired).count, pendingTodos: pending.count,
                missingCompletionTimes: data.todos.filter { $0.isCompleted && $0.completedAt == nil }.count,
                repeatedTodos: data.todos.filter { Self.pendingReason($0) != nil }.count)
            MigrationDiagnostics.summary(phase: "preview", todos: data.todos.count, groups: data.groups.count, rules: data.repeatTemplateCount, failed: pending.count)
        } catch {
            archive = nil; preview = nil; previewCalendar = nil
            MigrationDiagnostics.failure(error, phase: "preview", id: nil)
            if !invalidated { message = "기존 할 일을 확인하지 못했습니다. 다시 검토해주세요. 원본은 유지됩니다." }
            notifySession(error)
        }
    }
    static var isEnabled: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
    private func notifySession(_ error: Error) {
        if let auth = MigrationDiagnostics.sessionFailure(error) { sessionFailure(auth) }
    }
    private func isSessionStop(_ error: Error) -> Bool {
        error is CancellationError || MigrationDiagnostics.sessionFailure(error) != nil
    }
    func migrate(approvedUserID: UUID) async {
        guard Self.isEnabled else { message = "가져오기는 Debug 앱에서만 실행할 수 있습니다."; return }
        guard approvedUserID == userID, !invalidated, !busy, let archive, preview != nil else { return }
        busy = true; message = nil
        var ownsImportScope = false
        var summary = LegacyMigrationResult()
        let ready = supportedSchedules(archive), ids = Set(ready.map(\.id))
        summary.todosTotal = archive.todos.count; summary.groupsTotal = archive.groups.count
        summary.rulesTotal = archive.repeatTemplateCount
        summary.pending = (preview?.pendingTodos ?? 0) + archive.repeatTemplateCount - ready.count
        defer {
            if ownsImportScope { recurrences?.endLegacyImport() }; busy = false
            if !invalidated {
                succeeded = summary.todosSucceeded; failed = summary.todosFailed + summary.groupsFailed + summary.rulesFailed
                tasksFailed = summary.todosFailed; groupsSucceeded = summary.groupsSucceeded; groupsFailed = summary.groupsFailed
                calendarFailures = summary.calendarFailures; result = summary
                MigrationDiagnostics.summary(phase: "import-finished", todos: summary.todosSucceeded, groups: summary.groupsSucceeded, rules: summary.rulesSucceeded, failed: failed)
            }
        }
        do {
            try await ensureSession() // Revalidate the live user, not just the approval's UUID.
            try recurrences?.beginLegacyImport(); ownsImportScope = recurrences != nil
            var mapping: [UUID: UUID] = [:]
            let groupCounts = Dictionary(grouping: archive.groups, by: \.id)
            for group in archive.groups {
                try await ensureSession()
                do {
                    guard groupCounts[group.id]?.count == 1 else { throw TaskServiceError.unsupportedLegacy }
                    let id = MigrationIdentity.id(kind: "group", userID: userID, sourceID: group.id)
                    let saved = try await groups.create(id: id, name: group.name, colorHex: group.colorHex, sortOrder: group.sortOrder)
                    try await ensureSession()
                    guard saved.ownerID == userID, saved.spaceID == nil else { throw TaskServiceError.permission }
                    mapping[group.id] = saved.id; summary.groupsSucceeded += 1
                } catch {
                    MigrationDiagnostics.failure(error, phase: "group", id: group.id)
                    if isSessionStop(error) { throw error }; summary.groupsFailed += 1
                }
            }
            var rules: [UUID: TaskRecurrence] = [:]
            if let service = recurrences {
                for schedule in ready {
                    try await ensureSession()
                    do {
                        if let id = schedule.groupID, mapping[id] == nil { throw TaskServiceError.unsupportedLegacy }
                        let template = try schedule.template(userID: userID, groupID: schedule.groupID.flatMap { mapping[$0] }, calendar: migrationCalendar)
                        rules[schedule.id] = try await service.prepare(template: template, rule: schedule.rule(userID: userID, calendar: migrationCalendar), beforeRequest: { try await self.ensureSession() })
                        summary.rulesSucceeded += 1
                    } catch {
                        MigrationDiagnostics.failure(error, phase: "rule", id: schedule.id)
                        if isSessionStop(error) { throw error }; summary.rulesFailed += 1
                    }
                }
            }
            for todo in archive.todos.sorted(by: { $0.sortOrder == $1.sortOrder ? $0.createdAt < $1.createdAt : $0.sortOrder < $1.sortOrder }) {
                try await ensureSession()
                do {
                    let saved: WorkTask
                    if let existing = try await tasks.importedTask(sourceLocalTodoID: todo.id) { saved = existing }
                    else {
                        guard canImport(todo, schedules: ids, data: archive) else { continue }
                        if let group = todo.groupID, mapping[group] == nil { throw TaskServiceError.unsupportedLegacy }
                        var draft = Self.draft(todo, groupID: todo.groupID.flatMap { mapping[$0] }, calendar: migrationCalendar)
                        draft.id = MigrationIdentity.id(kind: "task", userID: userID, sourceID: todo.id)
                        if let scheduleID = todo.repeatScheduleID {
                            guard let rule = rules[scheduleID], let service = recurrences else { throw TaskServiceError.unsupportedLegacy }
                            saved = try await service.instance(rule, day: draft.scheduledDate, legacy: draft, beforeRequest: { try await self.ensureSession() })
                        } else { try await ensureSession(); saved = try await tasks.createTask(draft) }
                    }
                    // No created/assigned events for an import of historical data.
                    summary.todosSucceeded += 1
                    try await ensureSession()
                    if let identifier = todo.linkedCalendarEventID, links.identifier(taskID: saved.id) == nil {
                        do { try links.set(taskID: saved.id, identifier: identifier) }
                        catch { summary.calendarFailures += 1; MigrationDiagnostics.failure(error, phase: "calendar-link", id: todo.id) }
                    }
                } catch {
                    MigrationDiagnostics.failure(error, phase: "task", id: todo.id)
                    if isSessionStop(error) { throw error }
                    if todo.isCompleted, todo.completedAt == nil, MigrationDiagnostics.isCheckViolation(error) { summary.completionConstraintFailure = true }
                    summary.todosFailed += 1
                }
            }
            try await ensureSession()
        } catch {
            MigrationDiagnostics.failure(error, phase: "session", id: nil)
            if isSessionStop(error) { summary.stoppedForSession = true; message = "로그인이 변경되어 가져오기를 중단했습니다. 이미 가져온 항목과 원본은 보존됩니다."; notifySession(error) }
            else { message = "가져오기를 시작하지 못했습니다. 다시 검토해주세요." }
        }
    }
    static func draft(_ todo: TodoSnapshot, groupID: UUID?, calendar: Calendar) -> TaskDraft {
        TaskDraft(title: todo.title, scheduledDate: TaskDay(todo.date, calendar: calendar), groupID: groupID,
            deadlineDate: (todo.effectiveDeadlineDate ?? todo.startDateTime).map { TaskDay($0, calendar: calendar) },
            startAt: todo.startDateTime, deadlineAt: todo.deadlineDateTime,
            sourceLocalTodoID: todo.id, status: todo.isCompleted ? .completed : .open,
            completedAt: todo.isCompleted ? todo.completedAt : nil, notes: todo.notes)
    }
}
