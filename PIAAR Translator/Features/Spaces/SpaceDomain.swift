import Foundation

struct Space: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let createdBy: UUID
    let isArchived: Bool
    let createdAt: Date
    let updatedAt: Date
    enum CodingKeys: String, CodingKey {
        case id, name, createdBy = "created_by", isArchived = "is_archived", createdAt = "created_at", updatedAt = "updated_at"
    }
    static func validatedName(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...60).contains(value.count) else { throw SpaceError.invalidName }; return value
    }
    func canAccess(userID: UUID, members: [SpaceMember]) -> Bool {
        createdBy == userID || members.contains { $0.userID == userID && $0.spaceID == id && $0.removedAt == nil }
    }
    func canAssign(userID: UUID, members: [SpaceMember]) -> Bool { canAccess(userID: userID, members: members) }
    func canManage(group: TaskGroup, userID: UUID) -> Bool {
        !isArchived && group.spaceID == id && (group.ownerID == userID || createdBy == userID)
    }
}
struct SpaceMember: Identifiable, Codable, Equatable {
    let id: UUID
    let spaceID: UUID
    let userID: UUID
    let displayNameSnapshot: String
    let joinedAt: Date
    let removedAt: Date?
    enum CodingKeys: String, CodingKey {
        case id, spaceID = "space_id", userID = "user_id", displayNameSnapshot = "display_name_snapshot", joinedAt = "joined_at", removedAt = "removed_at"
    }
}
struct SpaceParticipant: Identifiable, Equatable {
    let id: UUID
    let name: String
}
enum SpaceError: LocalizedError, Equatable {
    case invalidName, unavailable, archived, permission, notFriend
    var errorDescription: String? {
        switch self {
        case .invalidName: return "업무방 이름은 1~60자로 입력해주세요."
        case .unavailable: return "업무방 정보를 불러오지 못했습니다. 다시 시도해주세요."
        case .archived: return "보관된 업무방은 변경할 수 없습니다."
        case .permission: return "이 업무방에 접근하거나 변경할 권한이 없습니다."
        case .notFriend: return "현재 친구인 사용자만 초대할 수 있습니다."
        }
    }
}
@MainActor protocol SpaceRepository {
    var userID: UUID { get }
    func spaces() async throws -> [Space]
    func space(id: UUID) async throws -> Space?
    func createSpace(id: UUID, name: String) async throws -> Space
    func members(spaceID: UUID) async throws -> [SpaceMember]
    func addMember(id: UUID, spaceID: UUID, friend: Friend) async throws -> SpaceMember
    func removeMember(id: UUID, spaceID: UUID) async throws
    func archiveSpace(id: UUID) async throws
}
extension GroupRepository {
    func createSpaceGroup(id: UUID, spaceID: UUID, name: String, colorHex: String?, sortOrder: Int) async throws -> TaskGroup { throw TaskServiceError.unavailable }
    func renameSpaceGroup(id: UUID, spaceID: UUID, name: String, colorHex: String?) async throws { throw TaskServiceError.unavailable }
    func deleteSpaceGroup(id: UUID, spaceID: UUID) async throws { throw TaskServiceError.unavailable }
}
