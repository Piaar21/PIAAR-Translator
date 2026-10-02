import Foundation

struct WorkRoom: Identifiable, Equatable {
    let id: UUID
    var name: String
    let creatorUserID: UUID
    let createdAt: Date
    var updatedAt: Date
    var isArchived: Bool
}
struct WorkRoomMember: Identifiable, Equatable {
    let id: UUID
    let roomID: UUID
    let userID: UUID
    let displayNameSnapshot: String
    let joinedAt: Date
    var removedAt: Date?
}
struct RoomGroup: Identifiable, Equatable {
    let id: UUID
    let roomID: UUID
    var name: String
    var colorHex: String?
    var sortOrder: Int
    let createdAt: Date
    var updatedAt: Date
}

enum WorkRoomError: LocalizedError, Equatable {
    case notFound, forbidden, archived, emptyName, notFriend, creatorRemoval, groupNotFound, invalidOrder
    var errorDescription: String? {
        switch self {
        case .notFound: return "업무방을 찾을 수 없습니다."
        case .forbidden: return "활성 멤버만 업무방을 사용할 수 있습니다."
        case .archived: return "보관된 업무방은 변경할 수 없습니다."
        case .emptyName: return "이름을 입력해주세요."
        case .notFriend: return "현재 친구 목록에서 멤버를 선택해주세요."
        case .creatorRemoval: return "업무방 생성자는 제거할 수 없습니다."
        case .groupNotFound: return "업무방 그룹을 찾을 수 없습니다."
        case .invalidOrder: return "현재 그룹 전체를 올바른 순서로 지정해주세요."
        }
    }
}

@MainActor protocol WorkRoomAccess: AnyObject {
    func validateAccess(roomID: UUID, userID: UUID, writing: Bool) async throws
    func validateTask(roomID: UUID, senderID: UUID, receiverID: UUID, groupID: UUID?) async throws
}
@MainActor protocol RoomTaskGroupMaintenance: AnyObject {
    func detachGroup(roomID: UUID, groupID: UUID) async
}
@MainActor protocol WorkRoomRepository: WorkRoomAccess {
    func rooms(for userID: UUID) async throws -> [WorkRoom]
    func room(id: UUID, for userID: UUID) async throws -> WorkRoom
    func createRoom(name: String, creator: WorkUserSummary, invitedUserIDs: [UUID]) async throws -> WorkRoom
    func archiveRoom(id: UUID, actorUserID: UUID) async throws
    func members(roomID: UUID, actorUserID: UUID) async throws -> [WorkRoomMember]
    func memberUser(roomID: UUID, userID: UUID, actorUserID: UUID) async throws -> WorkUserSummary
    func addMember(roomID: UUID, userID: UUID, actorUserID: UUID) async throws
    func removeMember(roomID: UUID, userID: UUID, actorUserID: UUID) async throws
    func groups(roomID: UUID, actorUserID: UUID) async throws -> [RoomGroup]
    func createGroup(roomID: UUID, name: String, color: String?, actorUserID: UUID) async throws -> RoomGroup
    func renameGroup(roomID: UUID, groupID: UUID, name: String, actorUserID: UUID) async throws
    func deleteGroup(roomID: UUID, groupID: UUID, actorUserID: UUID) async throws
    func reorderGroups(roomID: UUID, ids: [UUID], actorUserID: UUID) async throws
}

@MainActor final class MockWorkRoomRepository: WorkRoomRepository {
    private var roomRecords: [UUID: WorkRoom] = [:]
    private var memberRecords: [UUID: [WorkRoomMember]] = [:]
    private var userSnapshots: [UUID: WorkUserSummary] = [:]
    private var groupRecords: [UUID: [RoomGroup]] = [:]
    private let friends: any FriendRepository
    private let clock: () -> Date
    // Weak back-reference avoids a cycle with SharedTask's room-access dependency.
    weak var taskGroups: (any RoomTaskGroupMaintenance)?

    init(friends: any FriendRepository, clock: @escaping () -> Date = Date.init) {
        self.friends = friends; self.clock = clock
    }
    func validateAccess(roomID: UUID, userID: UUID, writing: Bool = false) async throws {
        guard let room = roomRecords[roomID] else { throw WorkRoomError.notFound }
        guard memberRecords[roomID, default: []].contains(where: { $0.userID == userID && $0.removedAt == nil }) else {
            throw WorkRoomError.forbidden
        }
        if writing && room.isArchived { throw WorkRoomError.archived }
    }
    func validateTask(roomID: UUID, senderID: UUID, receiverID: UUID, groupID: UUID?) async throws {
        try await validateAccess(roomID: roomID, userID: senderID, writing: true)
        try await validateAccess(roomID: roomID, userID: receiverID, writing: true)
        if let groupID, !groupRecords[roomID, default: []].contains(where: { $0.id == groupID }) {
            throw WorkRoomError.groupNotFound
        }
    }
    func rooms(for userID: UUID) async throws -> [WorkRoom] {
        roomRecords.values.filter { room in
            !room.isArchived && memberRecords[room.id, default: []].contains { $0.userID == userID && $0.removedAt == nil }
        }.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }
    func room(id: UUID, for userID: UUID) async throws -> WorkRoom {
        try await validateAccess(roomID: id, userID: userID, writing: false)
        return roomRecords[id]!
    }
    func createRoom(name: String, creator: WorkUserSummary, invitedUserIDs: [UUID]) async throws -> WorkRoom {
        let name = try validName(name)
        let current = try await friends.currentProfile()
        guard current.id == creator.id else { throw WorkRoomError.forbidden }
        let list = try await friends.friends()
        let ids = Set(invitedUserIDs).subtracting([creator.id])
        guard ids.allSatisfy({ id in list.contains { $0.user.id == id } }) else { throw WorkRoomError.notFriend }
        let now = clock()
        let room = WorkRoom(id: UUID(), name: name, creatorUserID: current.id,
                            createdAt: now, updatedAt: now, isArchived: false)
        let users = [current] + list.filter { ids.contains($0.user.id) }.map(\.user)
        for user in users { userSnapshots[user.id] = user }
        roomRecords[room.id] = room
        memberRecords[room.id] = users.map {
            WorkRoomMember(id: UUID(), roomID: room.id, userID: $0.id, displayNameSnapshot: $0.displayName,
                           joinedAt: now, removedAt: nil)
        }
        return room
    }
    private func requireCreator(_ roomID: UUID, _ actor: UUID) async throws {
        try await validateAccess(roomID: roomID, userID: actor, writing: true)
        guard roomRecords[roomID]?.creatorUserID == actor else { throw WorkRoomError.forbidden }
    }
    func archiveRoom(id: UUID, actorUserID: UUID) async throws {
        try await requireCreator(id, actorUserID)
        roomRecords[id]?.isArchived = true; roomRecords[id]?.updatedAt = clock()
    }
    func members(roomID: UUID, actorUserID: UUID) async throws -> [WorkRoomMember] {
        try await validateAccess(roomID: roomID, userID: actorUserID, writing: false)
        return memberRecords[roomID] ?? []
    }
    func memberUser(roomID: UUID, userID: UUID, actorUserID: UUID) async throws -> WorkUserSummary {
        try await validateAccess(roomID: roomID, userID: actorUserID, writing: false)
        try await validateAccess(roomID: roomID, userID: userID, writing: false)
        guard let user = userSnapshots[userID] else { throw WorkRoomError.forbidden }
        return user
    }
    func addMember(roomID: UUID, userID: UUID, actorUserID: UUID) async throws {
        try await requireCreator(roomID, actorUserID)
        let current = try await friends.currentProfile()
        guard current.id == actorUserID else { throw WorkRoomError.forbidden }
        let list = try await friends.friends()
        guard let user = list.first(where: { $0.user.id == userID })?.user else { throw WorkRoomError.notFriend }
        if memberRecords[roomID, default: []].contains(where: { $0.userID == userID && $0.removedAt == nil }) { return }
        userSnapshots[user.id] = user
        // Rejoining makes a new membership interval; old removed snapshots remain.
        memberRecords[roomID, default: []].append(WorkRoomMember(id: UUID(), roomID: roomID, userID: user.id,
            displayNameSnapshot: user.displayName, joinedAt: clock(), removedAt: nil))
        roomRecords[roomID]?.updatedAt = clock()
    }
    func removeMember(roomID: UUID, userID: UUID, actorUserID: UUID) async throws {
        try await requireCreator(roomID, actorUserID)
        guard roomRecords[roomID]?.creatorUserID != userID else { throw WorkRoomError.creatorRemoval }
        if let index = memberRecords[roomID]?.firstIndex(where: { $0.userID == userID && $0.removedAt == nil }) {
            memberRecords[roomID]?[index].removedAt = clock(); roomRecords[roomID]?.updatedAt = clock()
        }
    }
    func groups(roomID: UUID, actorUserID: UUID) async throws -> [RoomGroup] {
        try await validateAccess(roomID: roomID, userID: actorUserID, writing: false)
        return groupRecords[roomID, default: []].sorted { $0.sortOrder < $1.sortOrder }
    }
    func createGroup(roomID: UUID, name: String, color: String?, actorUserID: UUID) async throws -> RoomGroup {
        try await validateAccess(roomID: roomID, userID: actorUserID, writing: true)
        let name = try validName(name), now = clock()
        let group = RoomGroup(id: UUID(), roomID: roomID, name: name, colorHex: color,
            sortOrder: groupRecords[roomID, default: []].count, createdAt: now, updatedAt: now)
        groupRecords[roomID, default: []].append(group)
        return group
    }
    func renameGroup(roomID: UUID, groupID: UUID, name: String, actorUserID: UUID) async throws {
        try await validateAccess(roomID: roomID, userID: actorUserID, writing: true)
        let name = try validName(name)
        guard let index = groupRecords[roomID]?.firstIndex(where: { $0.id == groupID }) else { throw WorkRoomError.groupNotFound }
        groupRecords[roomID]?[index].name = name; groupRecords[roomID]?[index].updatedAt = clock()
    }
    func deleteGroup(roomID: UUID, groupID: UUID, actorUserID: UUID) async throws {
        try await validateAccess(roomID: roomID, userID: actorUserID, writing: true)
        guard groupRecords[roomID, default: []].contains(where: { $0.id == groupID }) else { throw WorkRoomError.groupNotFound }
        await taskGroups?.detachGroup(roomID: roomID, groupID: groupID)
        groupRecords[roomID]?.removeAll { $0.id == groupID }
        normalizeOrder(roomID)
    }
    func reorderGroups(roomID: UUID, ids: [UUID], actorUserID: UUID) async throws {
        try await validateAccess(roomID: roomID, userID: actorUserID, writing: true)
        let current = groupRecords[roomID, default: []]
        guard ids.count == current.count, Set(ids).count == ids.count, Set(ids) == Set(current.map(\.id)) else {
            throw WorkRoomError.invalidOrder
        }
        groupRecords[roomID] = ids.compactMap { id in current.first { $0.id == id } }
        normalizeOrder(roomID)
    }
    private func normalizeOrder(_ roomID: UUID) {
        for index in groupRecords[roomID, default: []].indices {
            groupRecords[roomID]?[index].sortOrder = index; groupRecords[roomID]?[index].updatedAt = clock()
        }
    }
    private func validName(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw WorkRoomError.emptyName }; return value
    }
}
