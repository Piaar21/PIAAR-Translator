import Foundation
import Supabase

@MainActor final class SupabaseTaskRepository: TaskRepository {
    let userID: UUID
    private let account: SupabaseAccountRepository
    private var scheduleCommands: [UUID: TaskScheduleCommand] = [:]
    private var archiveCommands: [UUID: UUID] = [:]
    private var client: SupabaseClient { account.client }
    init(account: SupabaseAccountRepository, userID: UUID) { self.account = account; self.userID = userID }
    private func authorize() async throws { try await account.requireOwner(userID) }
    func tasks(_ query: TaskQuery) async throws -> [WorkTask] {
        try await authorize()
        var result: [WorkTask] = []
        for offset in stride(from: 0, to: 4000, by: 200) {
            var request = client.from("tasks").select().eq("is_archived", value: false).eq("is_recurrence_template", value: false)
            switch query {
            case .assigned(let from, let through):
                request = request.eq("assigned_to", value: userID.uuidString).gte("scheduled_date", value: from.value).lte("scheduled_date", value: through.value)
            case .created(let from, let through):
                request = request.eq("created_by", value: userID.uuidString).gte("scheduled_date", value: from.value).lte("scheduled_date", value: through.value)
            case .received(let from, let through):
                request = request.eq("assigned_to", value: userID.uuidString).neq("created_by", value: userID.uuidString).gte("scheduled_date", value: from.value).lte("scheduled_date", value: through.value)
            case .sent(let from, let through):
                request = request.eq("created_by", value: userID.uuidString).neq("assigned_to", value: userID.uuidString).gte("scheduled_date", value: from.value).lte("scheduled_date", value: through.value)
            case .overdue(let from, let before):
                request = request.eq("assigned_to", value: userID.uuidString).eq("status", value: "open").gte("scheduled_date", value: from.value).lt("scheduled_date", value: before.value)
            case .someday:
                request = request.eq("assigned_to", value: userID.uuidString).is("scheduled_date", value: nil)
            case .allOverdue(let before):
                request = request.eq("assigned_to", value: userID.uuidString).eq("status", value: "open").lt("scheduled_date", value: before.value)
            case .allInSpace(let id):
                request = request.eq("space_id", value: id.uuidString)
            case .space(let id, let from, let through):
                request = request.eq("space_id", value: id.uuidString).gte("scheduled_date", value: from.value).lte("scheduled_date", value: through.value)
            }
            let rows: [WorkTask] = try await request.order("created_at").order("id").range(from: offset, to: offset + 199).execute().value
            try await authorize()
            result += rows
            if rows.count < 200 { return result }
        }
        throw TaskServiceError.limitExceeded
    }
    func fetchTask(id: UUID) async throws -> WorkTask? {
        try await authorize()
        let rows: [WorkTask] = try await client.from("tasks").select().eq("id", value: id.uuidString).limit(1).execute().value
        try await authorize(); return rows.first
    }
    func importedTask(sourceLocalTodoID: UUID) async throws -> WorkTask? {
        try await authorize()
        let rows: [WorkTask] = try await client.from("tasks").select()
            .eq("created_by", value: userID.uuidString).eq("source_local_todo_id", value: sourceLocalTodoID.uuidString).limit(1).execute().value
        try await authorize(); return rows.first
    }
    func recurrenceInstance(id: UUID, day: TaskDay) async throws -> WorkTask? {
        try await authorize()
        let rows: [WorkTask] = try await client.from("tasks").select().eq("recurrence_id", value: id.uuidString)
            .eq("scheduled_date", value: day.value).eq("is_recurrence_template", value: false).limit(1).execute().value
        try await authorize(); return rows.first
    }
    func createTask(_ draft: TaskDraft) async throws -> WorkTask {
        try await authorize()
        try draft.validate()
        if let source = draft.sourceLocalTodoID, let existing = try await importedTask(sourceLocalTodoID: source) { return existing }
        if let rule = draft.recurrenceID, let existing = try await recurrenceInstance(id: rule, day: draft.scheduledDate) { return existing }
        try await validateGroup(draft.groupID)
        var values = Self.payload(draft)
        values["recurrence_id"] = draft.recurrenceID.map { .string($0.uuidString) } ?? .null
        values["is_recurrence_template"] = .bool(draft.isRecurrenceTemplate)
        values["id"] = .string(draft.id.uuidString)
        values["created_by"] = .string(userID.uuidString)
        values["assigned_to"] = .string(userID.uuidString)
        values["space_id"] = .null
        values["status"] = .string(draft.status.rawValue)
        values["is_archived"] = .bool(false)
        values["source_local_todo_id"] = draft.sourceLocalTodoID.map { .string($0.uuidString) } ?? .null
        values["completed_at"] = draft.completedAt.map { .string(Self.timestamp($0)) } ?? .null
        try await authorize() // Ownership may change during the preceding group/source reads.
        do {
            let row: WorkTask = try await client.from("tasks").insert(values).select().single().execute().value
            try await authorize(); return row
        } catch {
            guard RecurrenceConflict.isUnique(error) || error is URLError else { throw error }
            if let rule = draft.recurrenceID {
                return try await RecurrenceConflict.reuse(error: error) { try await self.recurrenceInstance(id: rule, day: draft.scheduledDate) }
            }
            if let source = draft.sourceLocalTodoID, let existing = try await importedTask(sourceLocalTodoID: source) { return existing }
            if let existing = try await fetchTask(id: draft.id), existing.createdBy == userID { return existing }
            throw error
        }
    }
    func createSpaceTask(_ draft: TaskDraft, spaceID: UUID, receiverID: UUID) async throws -> WorkTask {
        try await authorize(); try draft.validate()
        guard draft.sourceLocalTodoID == nil, draft.recurrenceID == nil, !draft.isRecurrenceTemplate,
              draft.status == .open, draft.completedAt == nil else { throw TaskServiceError.invalidData }
        if let saved = try await fetchTask(id: draft.id) {
            guard saved.spaceID == spaceID, saved.createdBy == userID, saved.assignedTo == receiverID else { throw TaskServiceError.permission }; return saved
        }
        let spaces = SupabaseSpaceRepository(account: account, userID: userID)
        let space = try await spaces.writable(spaceID)
        let members = try await spaces.members(spaceID: spaceID)
        guard space.canAssign(userID: receiverID, members: members) else { throw SpaceError.permission }
        try await validateGroup(draft.groupID, spaceID: spaceID)
        try await authorize()
        var values = Self.directPayload(draft, sender: userID, receiver: receiverID)
        values["space_id"] = .string(spaceID.uuidString); values["group_id"] = draft.groupID.map { .string($0.uuidString) } ?? .null
        do {
            let row: WorkTask = try await client.from("tasks").insert(values).select().single().execute().value
            try await authorize(); return row
        } catch {
            if RecurrenceConflict.isUnique(error) || error is URLError, let saved = try await fetchTask(id: draft.id),
               saved.spaceID == spaceID, saved.createdBy == userID, saved.assignedTo == receiverID { return saved }
            if (error as? PostgrestError)?.code == "42501" { throw SpaceError.permission }; throw SupabaseFriendTransport.mappedError(error)
        }
    }
    private func writableTaskSpace(_ task: WorkTask) async throws {
        if let spaceID = task.spaceID,
           let space = try await SupabaseSpaceRepository(account: account, userID: userID).space(id: spaceID), space.isArchived { throw SpaceError.archived }
        // A removed member may still own an existing Task without Space SELECT access.
        // UPDATE RLS (assignee + non-archived Space) is the final guard in that case.
    }
    func createDirectTask(_ draft: TaskDraft, receiverID: UUID) async throws -> WorkTask {
        try await authorize()
        try DirectTaskPolicy.validate(draft, receiver: receiverID, sender: userID)
        if let existing = try await fetchTask(id: draft.id) {
            guard DirectTaskPolicy.matches(existing, id: draft.id, sender: userID, receiver: receiverID) else { throw TaskServiceError.permission }
            return existing
        }
        // UI rechecks friendship; the INSERT RLS remains the final race/security guard.
        let friends = SupabaseFriendRepository(account: account, userID: userID)
        guard try await friends.relationship(with: receiverID) == .friend else { throw DirectTaskError.notFriend }
        try await authorize()
        do {
            let row: WorkTask = try await client.from("tasks").insert(Self.directPayload(draft, sender: userID, receiver: receiverID)).select().single().execute().value
            try await authorize(); return row
        } catch {
            // Only the exact command can be reused, never another Task with the same title.
            if RecurrenceConflict.isUnique(error) || error is URLError,
               let saved = try await fetchTask(id: draft.id),
               DirectTaskPolicy.matches(saved, id: draft.id, sender: userID, receiver: receiverID) { return saved }
            if (error as? PostgrestError)?.code == "42501" {
                if try await friends.relationship(with: receiverID) != .friend { throw DirectTaskError.notFriend }
                throw TaskServiceError.permission
            }
            throw SupabaseFriendTransport.mappedError(error)
        }
    }
    static func directPayload(_ draft: TaskDraft, sender: UUID, receiver: UUID) -> [String: AnyJSON] {
        var values = payload(draft)
        values["id"] = .string(draft.id.uuidString)
        values["created_by"] = .string(sender.uuidString); values["assigned_to"] = .string(receiver.uuidString)
        values["space_id"] = .null; values["group_id"] = .null; values["recurrence_id"] = .null
        values["source_local_todo_id"] = .null; values["is_recurrence_template"] = .bool(false)
        values["is_archived"] = .bool(false); values["status"] = .string("open"); values["completed_at"] = .null
        return values
    }
    func participantNames(ids: Set<UUID>) async throws -> [UUID: String] {
        let transport = SupabaseFriendTransport(account: account, userID: userID)
        let profiles = try await transport.profiles(ids: ids)
        return Dictionary(profiles.map { ($0.id, $0.displayName) }, uniquingKeysWith: { _, latest in latest })
    }
    func receivedIncompleteCount() async throws -> Int {
        try await authorize()
        let response = try await client.from("tasks").select("id", head: true, count: .exact)
            .eq("assigned_to", value: userID.uuidString).neq("created_by", value: userID.uuidString)
            .eq("status", value: "open").eq("is_archived", value: false).eq("is_recurrence_template", value: false).execute()
        try await authorize()
        guard let count = response.count else { throw TaskServiceError.invalidData }; return count
    }
    func history(taskID: UUID) async throws -> [TaskHistoryEvent] {
        try await authorize()
        var result: [TaskHistoryEvent] = []
        for offset in stride(from: 0, to: 4000, by: 200) {
            let rows: [TaskHistoryEvent] = try await client.from("task_events")
                .select("id,task_id,actor_id,actor_display_name_snapshot,event_type,metadata,created_at")
                .eq("task_id", value: taskID.uuidString).order("created_at").order("id")
                .range(from: offset, to: offset + 199).execute().value
            try await authorize(); result += rows
            if rows.count < 200 { return result }
        }
        throw TaskServiceError.limitExceeded
    }
    func updateTask(id: UUID, draft: TaskDraft) async throws -> WorkTask {
        try draft.validate()
        try await authorize()
        guard let existing = try await fetchTask(id: id), existing.canEditContent(userID: userID) else { throw TaskServiceError.permission }
        try await writableTaskSpace(existing)
        if draft.groupID != existing.groupID || existing.spaceID == nil {
            try await validateGroup(draft.groupID, spaceID: existing.spaceID)
        }
        let target = draft.scheduleDay
        let expected = draft.expectedSchedule ?? TaskScheduleExpectation(existing)
        if !expected.matches(date: target, at: draft.scheduledAt, period: draft.dayPeriod) || scheduleCommands[id] != nil {
            guard DeferredTaskPresentation.canOrganize(existing, userID: userID) else { throw TaskServiceError.permission }
            let command: TaskScheduleCommand
            if let previous = scheduleCommands[id], previous.matchesTarget(date: target, at: draft.scheduledAt, period: draft.dayPeriod) {
                command = previous
            } else {
                command = TaskScheduleCommand(task: existing, date: target, at: draft.scheduledAt, period: draft.dayPeriod, expectation: expected)
            }
            scheduleCommands[id] = command
            do { _ = try await rescheduleTask(command) }
            catch { if error as? TaskServiceError == .scheduleConflict { scheduleCommands[id] = nil }; throw error }
        }
        let values = try Self.contentUpdatePayload(task: existing, draft: draft, userID: userID)
        let row: WorkTask = try await client.from("tasks").update(values).eq("id", value: id.uuidString)
            .eq("created_by", value: userID.uuidString).eq("assigned_to", value: userID.uuidString).select().single().execute().value
        try await authorize(); scheduleCommands[id] = nil; return row
    }
    func completeTask(id: UUID) async throws -> WorkTask { try await completion(id, completed: true) }
    func reopenTask(id: UUID) async throws -> WorkTask { try await completion(id, completed: false) }
    private func completion(_ id: UUID, completed: Bool) async throws -> WorkTask {
        try await authorize()
        guard let existing = try await fetchTask(id: id), existing.permission(userID: userID) != .readOnly else { throw TaskServiceError.permission }
        try await writableTaskSpace(existing)
        let status: TaskStatus = completed ? .completed : .open
        if existing.status == status { return existing }
        let values: [String: AnyJSON] = ["status": .string(status.rawValue),
            "completed_at": completed ? .string(Self.timestamp(Date())) : .null]
        let row: WorkTask = try await client.from("tasks").update(values).eq("id", value: id.uuidString)
            .eq("assigned_to", value: userID.uuidString).select().single().execute().value
        try await authorize(); return row
    }
    func rescheduleTask(_ command: TaskScheduleCommand) async throws -> WorkTask {
        try await authorize()
        guard let task = try await fetchTask(id: command.taskID), DeferredTaskPresentation.canOrganize(task, userID: userID) else { throw TaskServiceError.permission }
        try await writableTaskSpace(task)
        return try await TaskScheduleMutation.reschedule(command, transport: SupabaseTaskScheduleTransport(account: account, userID: userID))
    }
    func archiveTask(id: UUID) async throws {
        let command = archiveCommands[id] ?? UUID(); archiveCommands[id] = command
        try await archiveTask(id: id, commandID: command); archiveCommands[id] = nil
    }
    func archiveTask(id: UUID, commandID: UUID) async throws {
        try await authorize()
        guard let task = try await fetchTask(id: id), task.permission(userID: userID) == .edit, !task.isRecurrenceTemplate, task.recurrenceID == nil else { throw TaskServiceError.permission }
        try await writableTaskSpace(task)
        _ = try await TaskScheduleMutation.archive(taskID: id, commandID: commandID, transport: SupabaseTaskScheduleTransport(account: account, userID: userID))
    }
    func recordEvent(_ event: TaskEventRequest) async throws {
        try await authorize()
        let values = try TaskEventPayload(event, userID: userID)
        do { try await client.from("task_events").insert(values).execute() }
        catch {
            let rows: [[String: AnyJSON]] = try await client.from("task_events").select("id")
                .eq("id", value: event.id.uuidString).eq("actor_id", value: userID.uuidString).eq("task_id", value: event.taskID.uuidString).limit(1).execute().value
            if rows.isEmpty { throw error }
        }
    }
    private func validateGroup(_ id: UUID?, spaceID: UUID? = nil) async throws {
        guard let id else { return }
        let repo = SupabaseGroupRepository(account: account, userID: userID)
        guard let group = try await repo.fetchGroup(id: id) else { throw TaskServiceError.permission }
        if let spaceID { guard group.spaceID == spaceID else { throw TaskServiceError.permission } }
        else { guard group.ownerID == userID, group.spaceID == nil else { throw TaskServiceError.permission } }
    }
    // A content mutation cannot carry schedule, identity, completion or archive fields.
    // INSERT keeps its separate payload, including the initial schedule.
    static func contentUpdatePayload(task: WorkTask, draft: TaskDraft, userID: UUID) throws -> [String: AnyJSON] {
        guard task.canEditContent(userID: userID) else { throw TaskServiceError.permission }
        try draft.validate()
        return ["title": .string(draft.title.trimmingCharacters(in: .whitespacesAndNewlines)),
                "notes": draft.normalizedNotes.map { .string($0) } ?? .null,
                "group_id": draft.groupID.map { .string($0.uuidString) } ?? .null,
                "deadline_date": draft.deadlineDate.map { .string($0.value) } ?? .null,
                "start_at": draft.startAt.map { .string(Self.timestamp($0)) } ?? .null,
                "deadline_at": draft.deadlineAt.map { .string(Self.timestamp($0)) } ?? .null,
                "estimated_minutes": draft.estimatedMinutes.map { .integer($0) } ?? .null,
                "priority": .string(draft.priority.rawValue)]
    }
    static func payload(_ draft: TaskDraft) -> [String: AnyJSON] {
        ["title": .string(draft.title.trimmingCharacters(in: .whitespacesAndNewlines)),
         "scheduled_date": draft.scheduleDay.map { .string($0.value) } ?? .null,
         "scheduled_at": draft.scheduledAt.map { .string(Self.timestamp($0)) } ?? .null,
         "day_period": draft.dayPeriod.map { .string($0.rawValue) } ?? .null,
         "estimated_minutes": draft.estimatedMinutes.map { .integer($0) } ?? .null,
         "priority": .string(draft.priority.rawValue),
         "notes": draft.normalizedNotes.map { .string($0) } ?? .null,
         "group_id": draft.groupID.map { .string($0.uuidString) } ?? .null,
         "deadline_date": draft.deadlineDate.map { .string($0.value) } ?? .null,
         "start_at": draft.startAt.map { .string(Self.timestamp($0)) } ?? .null,
         "deadline_at": draft.deadlineAt.map { .string(Self.timestamp($0)) } ?? .null]
    }
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
