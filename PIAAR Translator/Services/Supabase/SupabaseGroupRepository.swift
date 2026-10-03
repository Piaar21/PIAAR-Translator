import Foundation
import Supabase

@MainActor final class SupabaseGroupRepository: GroupRepository {
    let userID: UUID
    private let account: SupabaseAccountRepository
    private var client: SupabaseClient { account.client }
    init(account: SupabaseAccountRepository, userID: UUID) { self.account = account; self.userID = userID }
    func personalGroups() async throws -> [TaskGroup] {
        try await account.requireOwner(userID)
        let rows: [TaskGroup] = try await client.from("groups").select().eq("owner_id", value: userID.uuidString)
            .is("space_id", value: nil).order("sort_order").order("id").limit(1000).execute().value
        try await account.requireOwner(userID)
        guard rows.count < 1000 else { throw TaskServiceError.limitExceeded }; return rows
    }
    func groups(spaceID: UUID) async throws -> [TaskGroup] {
        try await account.requireOwner(userID)
        let rows: [TaskGroup] = try await client.from("groups").select().eq("space_id", value: spaceID.uuidString)
            .order("sort_order").limit(1000).execute().value
        guard rows.count < 1000 else { throw TaskServiceError.limitExceeded }; return rows
    }
    func fetchGroup(id: UUID) async throws -> TaskGroup? {
        try await account.requireOwner(userID)
        let rows: [TaskGroup] = try await client.from("groups").select().eq("id", value: id.uuidString).limit(1).execute().value
        try await account.requireOwner(userID); return rows.first
    }
    func create(id: UUID, name: String, colorHex: String?, sortOrder: Int) async throws -> TaskGroup {
        try await account.requireOwner(userID)
        if let existing = try await fetchGroup(id: id) {
            guard existing.ownerID == userID, existing.spaceID == nil else { throw TaskServiceError.permission }; return existing
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TaskServiceError.invalidData }
        let values: [String: AnyJSON] = ["id": .string(id.uuidString), "name": .string(name),
            "color_hex": colorHex.map { .string($0) } ?? .null, "owner_id": .string(userID.uuidString),
            "space_id": .null, "sort_order": .integer(sortOrder)]
        try await account.requireOwner(userID)
        do {
            let saved: TaskGroup = try await client.from("groups").insert(values).select().single().execute().value
            try await account.requireOwner(userID); return saved
        }
        catch { if let existing = try await fetchGroup(id: id), existing.ownerID == userID, existing.spaceID == nil { return existing }; throw error }
    }
    func rename(id: UUID, name: String, colorHex: String?) async throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TaskServiceError.invalidData }
        try await account.requireOwner(userID)
        let values: [String: AnyJSON] = ["name": .string(name), "color_hex": colorHex.map { .string($0) } ?? .null]
        try await client.from("groups").update(values).eq("id", value: id.uuidString)
            .eq("owner_id", value: userID.uuidString).is("space_id", value: nil).execute()
    }
    func delete(id: UUID) async throws {
        try await account.requireOwner(userID)
        // The existing ON DELETE SET NULL FK preserves tasks.
        try await client.from("groups").delete().eq("id", value: id.uuidString)
            .eq("owner_id", value: userID.uuidString).is("space_id", value: nil).execute()
    }
    private func writableSpace(_ id: UUID) async throws -> Space {
        try await SupabaseSpaceRepository(account: account, userID: userID).writable(id)
    }
    func createSpaceGroup(id: UUID, spaceID: UUID, name: String, colorHex: String?, sortOrder: Int) async throws -> TaskGroup {
        _ = try await writableSpace(spaceID)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TaskServiceError.invalidData }
        if let existing = try await fetchGroup(id: id) { guard existing.spaceID == spaceID, existing.ownerID == userID else { throw TaskServiceError.permission }; return existing }
        let values: [String: AnyJSON] = ["id": .string(id.uuidString), "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)),
            "color_hex": colorHex.map { .string($0) } ?? .null, "owner_id": .string(userID.uuidString),
            "space_id": .string(spaceID.uuidString), "sort_order": .integer(sortOrder)]
        do {
            let row: TaskGroup = try await client.from("groups").insert(values).select().single().execute().value
            try await account.requireOwner(userID); return row
        } catch {
            if RecurrenceConflict.isUnique(error) || error is URLError, let saved = try await fetchGroup(id: id), saved.spaceID == spaceID, saved.ownerID == userID { return saved }; throw SupabaseFriendTransport.mappedError(error)
        }
    }
    private func editableGroup(_ id: UUID, spaceID: UUID) async throws {
        let space = try await writableSpace(spaceID)
        guard let group = try await fetchGroup(id: id), space.canManage(group: group, userID: userID) else { throw TaskServiceError.permission }
    }
    func renameSpaceGroup(id: UUID, spaceID: UUID, name: String, colorHex: String?) async throws {
        try await editableGroup(id, spaceID: spaceID)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TaskServiceError.invalidData }
        let values: [String: AnyJSON] = ["name": .string(name), "color_hex": colorHex.map { .string($0) } ?? .null]
        let rows: [TaskGroup] = try await client.from("groups").update(values).eq("id", value: id.uuidString).eq("space_id", value: spaceID.uuidString).select().execute().value
        try await account.requireOwner(userID); guard rows.count == 1 else { throw TaskServiceError.permission }
    }
    func deleteSpaceGroup(id: UUID, spaceID: UUID) async throws {
        try await editableGroup(id, spaceID: spaceID)
        let rows: [TaskGroup] = try await client.from("groups").delete().eq("id", value: id.uuidString).eq("space_id", value: spaceID.uuidString).select().execute().value
        try await account.requireOwner(userID); guard rows.count == 1 else { throw TaskServiceError.permission }
        // Server ON DELETE SET NULL preserves all Tasks, including other members' Tasks.
    }
    func reorder(ids: [UUID]) async throws {
        try await account.requireOwner(userID)
        let owned = Set(try await personalGroups().map(\.id))
        guard Set(ids).count == ids.count, Set(ids) == owned else { throw TaskServiceError.permission }
        for (index, id) in ids.enumerated() {
            try await account.requireOwner(userID)
            try await client.from("groups").update(["sort_order": index]).eq("id", value: id.uuidString)
                .eq("owner_id", value: userID.uuidString).is("space_id", value: nil).execute()
        }
    }
}
