import Foundation
import Supabase

@MainActor final class SupabaseSpaceRepository: SpaceRepository {
    let userID: UUID
    private let account: SupabaseAccountRepository
    private var client: SupabaseClient { account.client }
    init(account: SupabaseAccountRepository, userID: UUID) { self.account = account; self.userID = userID }
    private func read<T: Decodable>(_ request: PostgrestBuilder) async throws -> T {
        try await account.requireOwner(userID)
        do { let value: T = try await request.execute().value; try await account.requireOwner(userID); return value }
        catch { if (error as? PostgrestError)?.code == "42501" { throw SpaceError.permission }; throw SupabaseFriendTransport.mappedError(error) }
    }
    func spaces() async throws -> [Space] {
        var result: [Space] = []
        for offset in stride(from: 0, to: 4000, by: 200) {
            let rows: [Space] = try await read(client.from("spaces").select().order("created_at").order("id").range(from: offset, to: offset + 199))
            result += rows; if rows.count < 200 { return result }
        }
        throw TaskServiceError.limitExceeded
    }
    func space(id: UUID) async throws -> Space? {
        let rows: [Space] = try await read(client.from("spaces").select().eq("id", value: id.uuidString).limit(1)); return rows.first
    }
    func createSpace(id: UUID, name: String) async throws -> Space {
        let name = try Space.validatedName(name)
        if let saved = try await space(id: id) { guard saved.createdBy == userID else { throw SpaceError.permission }; return saved }
        let values: [String: AnyJSON] = ["id": .string(id.uuidString), "name": .string(name), "created_by": .string(userID.uuidString), "is_archived": .bool(false)]
        do { return try await read(client.from("spaces").insert(values).select().single()) }
        catch {
            if RecurrenceConflict.isUnique(error) || error is URLError, let saved = try await space(id: id), saved.createdBy == userID { return saved }; throw error
        }
    }
    func members(spaceID: UUID) async throws -> [SpaceMember] {
        guard try await space(id: spaceID) != nil else { throw SpaceError.permission }
        var result: [SpaceMember] = []
        for offset in stride(from: 0, to: 4000, by: 200) {
            let rows: [SpaceMember] = try await read(client.from("space_members").select().eq("space_id", value: spaceID.uuidString)
                .is("removed_at", value: nil).order("joined_at").order("id").range(from: offset, to: offset + 199))
            result += rows; if rows.count < 200 { return result }
        }
        throw TaskServiceError.limitExceeded
    }
    private func creator(_ id: UUID) async throws -> Space {
        guard let space = try await space(id: id), space.createdBy == userID else { throw SpaceError.permission }
        guard !space.isArchived else { throw SpaceError.archived }; return space
    }
    func addMember(id: UUID, spaceID: UUID, friend: Friend) async throws -> SpaceMember {
        let space = try await creator(spaceID)
        guard friend.userID != space.createdBy else { throw SpaceError.permission }
        if let existing = try await members(spaceID: spaceID).first(where: { $0.userID == friend.userID }) { return existing }
        let friends = SupabaseFriendRepository(account: account, userID: userID)
        guard try await friends.relationship(with: friend.userID) == .friend else { throw SpaceError.notFriend }
        guard let profile = try await SupabaseFriendTransport(account: account, userID: userID).profile(id: friend.userID), profile.isActive else { throw SpaceError.notFriend }
        // New row on re-invite. No deleted history and no reactivation of past memberships.
        let values: [String: AnyJSON] = ["id": .string(id.uuidString), "space_id": .string(spaceID.uuidString), "user_id": .string(friend.userID.uuidString),
            "display_name_snapshot": .string(profile.displayName), "removed_at": .null]
        _ = try await creator(spaceID)
        do { return try await read(client.from("space_members").insert(values).select().single()) }
        catch {
            if RecurrenceConflict.isUnique(error) || error is URLError,
               let existing = try await members(spaceID: spaceID).first(where: { $0.userID == friend.userID }) { return existing }; throw error
        }
    }
    func removeMember(id: UUID, spaceID: UUID) async throws {
        let space = try await creator(spaceID)
        guard let member = try await members(spaceID: spaceID).first(where: { $0.id == id }), member.userID != space.createdBy else { throw SpaceError.permission }
        let rows: [SpaceMember] = try await read(client.from("space_members").update(["removed_at": SupabaseTaskRepository.timestamp(Date())])
            .eq("id", value: id.uuidString).eq("space_id", value: spaceID.uuidString).is("removed_at", value: nil).select())
        guard rows.count == 1 else { throw SpaceError.permission }
    }
    func archiveSpace(id: UUID) async throws {
        guard let existing = try await space(id: id), existing.createdBy == userID else { throw SpaceError.permission }
        if existing.isArchived { return }
        let rows: [Space] = try await read(client.from("spaces").update(["is_archived": true]).eq("id", value: id.uuidString).eq("created_by", value: userID.uuidString).select())
        guard rows.count == 1 else { throw SpaceError.permission }
    }
    func writable(_ id: UUID) async throws -> Space {
        guard let value = try await space(id: id) else { throw SpaceError.permission }
        guard !value.isArchived else { throw SpaceError.archived }
        // SELECT RLS already restricts this to creator or an active member.
        return value
    }
}
