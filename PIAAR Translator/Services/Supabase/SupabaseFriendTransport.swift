import Foundation
import Supabase

@MainActor final class SupabaseFriendTransport: FriendTransport {
    private let account: SupabaseAccountRepository
    private let userID: UUID
    private var client: SupabaseClient { account.client }
    private static let profileColumns = "id,display_name,friend_code,is_active,created_at,updated_at"
    init(account: SupabaseAccountRepository, userID: UUID) { self.account = account; self.userID = userID }
    static func mappedError(_ error: Error) -> Error {
        if let code = (error as? PostgrestError)?.code, ["PGRST301", "PGRST302", "PGRST303"].contains(code) {
            return CollaborationAuthError.sessionMissing
        }
        return error
    }
    private func readValue<T: Decodable>(_ request: PostgrestBuilder) async throws -> T {
        do { return try await request.execute().value }
        catch { throw Self.mappedError(error) }
    }
    private func invoke(_ request: PostgrestBuilder) async throws {
        do { try await request.execute() }
        catch { throw Self.mappedError(error) }
    }
    func authorize() async throws { try await account.requireOwner(userID) }
    func profile(code: FriendCode) async throws -> CollaborationProfile? {
        try await authorize()
        let rows: [CollaborationProfile] = try await readValue(client.from("profiles").select(Self.profileColumns)
            .eq("friend_code", value: code.rawValue).eq("is_active", value: true).limit(1))
        try await authorize(); return rows.first
    }
    func profile(id: UUID) async throws -> CollaborationProfile? {
        try await authorize()
        let rows: [CollaborationProfile] = try await readValue(client.from("profiles").select(Self.profileColumns)
            .eq("id", value: id.uuidString).limit(1))
        try await authorize(); return rows.first
    }
    func profiles(ids: Set<UUID>) async throws -> [CollaborationProfile] {
        let ids = ids.map(\.uuidString).sorted(); var result: [CollaborationProfile] = []
        for offset in stride(from: 0, to: ids.count, by: 200) {
            try await authorize()
            let rows: [CollaborationProfile] = try await readValue(client.from("profiles").select(Self.profileColumns)
                .in("id", values: Array(ids[offset..<min(offset + 200, ids.count)])).limit(200))
            try await authorize(); result += rows
        }
        return result
    }
    func requests(incoming: Bool) async throws -> [FriendRequest] {
        var result: [FriendRequest] = []
        for offset in stride(from: 0, to: 4000, by: 200) {
            try await authorize()
            let rows: [FriendRequest] = try await readValue(client.from("friend_requests").select()
                .eq(incoming ? "receiver_id" : "sender_id", value: userID.uuidString).eq("status", value: "pending")
                .order("created_at").order("id").range(from: offset, to: offset + 199))
            try await authorize(); result += rows
            if rows.count < 200 { return result }
        }
        throw FriendshipError.limitExceeded
    }
    func pendingPair(with user: UUID) async throws -> FriendRequest? {
        try await authorize()
        let rows: [FriendRequest] = try await readValue(client.from("friend_requests").select().eq("status", value: "pending")
            .or("and(sender_id.eq.\(userID.uuidString),receiver_id.eq.\(user.uuidString)),and(sender_id.eq.\(user.uuidString),receiver_id.eq.\(userID.uuidString))")
            .limit(1))
        try await authorize(); return rows.first
    }
    func activeFriendships() async throws -> [FriendshipRecord] {
        var result: [FriendshipRecord] = []
        for offset in stride(from: 0, to: 4000, by: 200) {
            try await authorize()
            let rows: [FriendshipRecord] = try await readValue(client.from("friendships").select().is("ended_at", value: nil)
                .or("user_a_id.eq.\(userID.uuidString),user_b_id.eq.\(userID.uuidString)")
                .order("created_at").order("id").range(from: offset, to: offset + 199))
            try await authorize(); result += rows
            if rows.count < 200 { return result }
        }
        throw FriendshipError.limitExceeded
    }
    func activePair(with user: UUID) async throws -> FriendshipRecord? {
        let pair = [userID.uuidString.lowercased(), user.uuidString.lowercased()].sorted()
        try await authorize()
        let rows: [FriendshipRecord] = try await readValue(client.from("friendships").select().is("ended_at", value: nil)
            .eq("user_a_id", value: pair[0]).eq("user_b_id", value: pair[1]).limit(1))
        try await authorize(); return rows.first
    }
    func insertRequest(receiver: UUID) async throws -> FriendRequest {
        guard receiver != userID else { throw FriendshipError.selfRequest }
        try await authorize()
        let values: [String: AnyJSON] = ["sender_id": .string(userID.uuidString), "receiver_id": .string(receiver.uuidString), "status": .string("pending")]
        do {
            let saved: FriendRequest = try await readValue(client.from("friend_requests").insert(values).select().single())
            try await authorize(); return saved
        } catch {
            if (error as? PostgrestError)?.code == "23505" { throw FriendshipError.uniqueConflict }
            throw error
        }
    }
    func accept(id: UUID) async throws -> UUID {
        try await authorize()
        let saved: UUID = try await readValue(client.rpc("accept_friend_request", params: ["p_request_id": id.uuidString]))
        try await authorize(); return saved
    }
    func reject(id: UUID) async throws {
        try await authorize()
        try await invoke(client.rpc("reject_friend_request", params: ["p_request_id": id.uuidString]))
        try await authorize()
    }
    func remove(id: UUID) async throws {
        try await authorize()
        try await invoke(client.rpc("remove_friend", params: ["p_friend_id": id.uuidString]))
        try await authorize()
    }
}
