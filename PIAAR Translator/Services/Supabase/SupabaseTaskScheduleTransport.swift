import Foundation
import Supabase

@MainActor final class SupabaseTaskScheduleTransport: TaskScheduleTransport {
    let account: SupabaseAccountRepository
    let userID: UUID
    init(account: SupabaseAccountRepository, userID: UUID) { self.account = account; self.userID = userID }
    func authorize() async throws { try await account.requireOwner(userID) }
    static func payload(_ c: TaskScheduleCommand) -> [String: AnyJSON] {
        ["p_task_id": .string(c.taskID.uuidString), "p_command_id": .string(c.id.uuidString),
         "p_expected_scheduled_date": c.expectedDate.map { .string($0.value) } ?? .null,
         "p_expected_scheduled_at": c.expectedAt.map { .string(SupabaseTaskRepository.timestamp($0)) } ?? .null,
         "p_expected_day_period": c.expectedPeriod.map { .string($0.rawValue) } ?? .null,
         "p_target_scheduled_date": c.targetDate.map { .string($0.value) } ?? .null,
         "p_target_scheduled_at": c.targetAt.map { .string(SupabaseTaskRepository.timestamp($0)) } ?? .null,
         "p_target_day_period": c.targetPeriod.map { .string($0.rawValue) } ?? .null]
    }
    static func archivePayload(taskID: UUID, commandID: UUID) -> [String: AnyJSON] {
        ["p_task_id": .string(taskID.uuidString), "p_command_id": .string(commandID.uuidString)]
    }
    static func mapped(_ error: Error) -> Error {
        if let db = error as? PostgrestError, db.message.localizedCaseInsensitiveContains("schedule conflict") { return TaskServiceError.scheduleConflict }
        return SupabaseFriendTransport.mappedError(error)
    }
    func reschedule(_ command: TaskScheduleCommand) async throws -> WorkTask {
        do { return try await account.client.rpc("reschedule_task", params: Self.payload(command)).single().execute().value }
        catch { throw Self.mapped(error) }
    }
    func archive(taskID: UUID, commandID: UUID) async throws -> WorkTask {
        do { return try await account.client.rpc("archive_task", params: Self.archivePayload(taskID: taskID, commandID: commandID)).single().execute().value }
        catch { throw Self.mapped(error) }
    }
}
