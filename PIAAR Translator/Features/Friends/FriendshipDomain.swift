import Foundation

struct Friend: Identifiable, Equatable {
    let friendshipID: UUID
    let userID: UUID
    let displayName: String
    let friendCode: FriendCode
    let createdAt: Date
    var id: UUID { friendshipID }
}
struct FriendRequest: Codable, Equatable, Identifiable {
    enum Status: String, Codable { case pending, accepted, rejected }
    let id: UUID
    let senderID: UUID
    let receiverID: UUID
    let status: Status
    let createdAt: Date
    let updatedAt: Date
    let respondedAt: Date?
    enum CodingKeys: String, CodingKey {
        case id, status, senderID = "sender_id", receiverID = "receiver_id"
        case createdAt = "created_at", updatedAt = "updated_at", respondedAt = "responded_at"
    }
}
struct FriendRequestPresentation: Identifiable, Equatable {
    let request: FriendRequest
    let person: WorkUserSummary
    var id: UUID { request.id }
}
struct FriendshipSnapshot {
    let friends: [Friend]
    let incoming: [FriendRequestPresentation]
    let outgoing: [FriendRequestPresentation]
}
enum FriendRelationship: Equatable {
    case available, friend
    case incoming(FriendRequest), outgoing(FriendRequest)
}
enum FriendRequestDelivery: Equatable {
    case sent(FriendRequest), existing(FriendRelationship)
}
enum FriendshipError: LocalizedError, Equatable {
    case selfRequest, notFound, unavailable, invalidData, limitExceeded, uniqueConflict
    var errorDescription: String? {
        switch self {
        case .selfRequest: return "자기 자신에게 친구 요청을 보낼 수 없습니다."
        case .notFound: return "사용자를 찾을 수 없습니다."
        case .unavailable: return "친구 정보를 확인하지 못했습니다. 잠시 후 다시 시도해주세요."
        case .invalidData: return "친구 정보가 올바르지 않습니다. 새로고침해주세요."
        case .limitExceeded: return "친구 정보가 많아 모두 불러오지 못했습니다."
        case .uniqueConflict: return "요청 상태가 변경되었습니다. 다시 확인해주세요."
        }
    }
}
// The existing FriendRepository remains the isolated Mock contact/room boundary.
// Production uses this mutual friendship boundary; accepting requires a server RPC.
@MainActor protocol FriendshipRepository {
    var userID: UUID { get }
    func searchUser(friendCode: FriendCode) async throws -> WorkUserSummary
    func relationship(with user: UUID) async throws -> FriendRelationship
    func sendRequest(to user: UUID) async throws -> FriendRequestDelivery
    func snapshot() async throws -> FriendshipSnapshot
    func acceptRequest(id: UUID) async throws -> UUID
    func rejectRequest(id: UUID) async throws
    func removeFriend(friendshipID: UUID) async throws
}
// Server rows never reach the View. These Codable values also permit an SDK-free fake transport.
struct FriendshipRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let userAID: UUID
    let userBID: UUID
    let createdAt: Date
    let endedAt: Date?
    enum CodingKeys: String, CodingKey {
        case id, userAID = "user_a_id", userBID = "user_b_id", createdAt = "created_at", endedAt = "ended_at"
    }
    func otherUser(than me: UUID) -> UUID? {
        guard endedAt == nil, userAID != userBID else { return nil }
        if userAID == me { return userBID }; if userBID == me { return userAID }; return nil
    }
}
@MainActor protocol FriendTransport {
    func authorize() async throws
    func profile(code: FriendCode) async throws -> CollaborationProfile?
    func profile(id: UUID) async throws -> CollaborationProfile?
    func profiles(ids: Set<UUID>) async throws -> [CollaborationProfile]
    func requests(incoming: Bool) async throws -> [FriendRequest]
    func pendingPair(with user: UUID) async throws -> FriendRequest?
    func activeFriendships() async throws -> [FriendshipRecord]
    func activePair(with user: UUID) async throws -> FriendshipRecord?
    func insertRequest(receiver: UUID) async throws -> FriendRequest
    func accept(id: UUID) async throws -> UUID
    func reject(id: UUID) async throws
    func remove(id: UUID) async throws
}
