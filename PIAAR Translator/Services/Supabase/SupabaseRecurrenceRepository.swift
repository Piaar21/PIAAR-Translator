import Foundation
import Supabase

@MainActor final class SupabaseRecurrenceRepository: RecurrenceRepository {
    let userID: UUID
    private let account: SupabaseAccountRepository
    private var client: SupabaseClient { account.client }
    init(account: SupabaseAccountRepository, userID: UUID) { self.account = account; self.userID = userID }
    private func authorize() async throws { try await account.requireOwner(userID) }
    func rules() async throws -> [TaskRecurrence] {
        try await authorize()
        // Ownership comes from the template, not from an assumed recurrence owner column.
        var result: [TaskRecurrence] = []
        for offset in stride(from: 0, to: 4000, by: 200) {
            let rows: [WorkTask] = try await client.from("tasks").select().eq("created_by", value: userID.uuidString)
                .eq("assigned_to", value: userID.uuidString).eq("is_recurrence_template", value: true).eq("is_archived", value: false)
                .order("id").range(from: offset, to: offset + 199).execute().value
            for template in rows { if let rule = try await rule(templateID: template.id) { result.append(rule) } }
            if rows.count < 200 { try await authorize(); return result }
        }
        throw TaskServiceError.limitExceeded
    }
    func rule(templateID: UUID) async throws -> TaskRecurrence? {
        try await authorize()
        let template = try await SupabaseTaskRepository(account: account, userID: userID).fetchTask(id: templateID)
        guard template?.createdBy == userID, template?.isRecurrenceTemplate == true else { throw TaskServiceError.permission }
        let rows: [TaskRecurrence] = try await client.from("task_recurrences").select().eq("template_task_id", value: templateID.uuidString).limit(1).execute().value
        try await authorize(); return rows.first
    }
    func create(_ value: TaskRecurrence) async throws -> TaskRecurrence {
        try await authorize(); try value.validate()
        if let existing = try await rule(templateID: value.templateTaskID) { return existing }
        try await authorize()
        do {
            let saved: TaskRecurrence = try await client.from("task_recurrences").insert(value).select().single().execute().value
            try await authorize(); return saved
        } catch { return try await RecurrenceConflict.reuse(error: error) { try await self.rule(templateID: value.templateTaskID) } }
    }
    func deactivate(id: UUID) async throws {
        try await authorize()
        let rows: [TaskRecurrence] = try await client.from("task_recurrences").select().eq("id", value: id.uuidString).limit(1).execute().value
        guard let value = rows.first, try await rule(templateID: value.templateTaskID)?.id == id else { throw TaskServiceError.permission }
        try await client.from("task_recurrences").update(["is_active": false]).eq("id", value: id.uuidString).execute()
        try await authorize()
    }
}
