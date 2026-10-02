import Foundation
import Combine

struct RoomTaskSection: Identifiable {
    let group: RoomGroup?
    let tasks: [SharedTask]
    var id: UUID? { group?.id }
}

@MainActor final class WorkRoomsViewModel: ObservableObject {
    @Published private(set) var rooms: [WorkRoom] = []
    @Published private(set) var selectedRoom: WorkRoom?
    @Published private(set) var members: [WorkRoomMember] = []
    @Published private(set) var groups: [RoomGroup] = []
    @Published private(set) var tasks: [SharedTask] = []
    @Published private(set) var friends: [FriendEntry] = []
    @Published private(set) var memberUsers: [WorkUserSummary] = []
    @Published private(set) var profile: WorkUserSummary?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isBusy = false
    let sharedTasks: SharedTasksViewModel
    private let friendRepository: any FriendRepository
    private let roomRepository: any WorkRoomRepository
    private let taskRepository: any SharedTaskRepository
    private let clock: () -> Date
    private let calendar: Calendar
    private var pendingRoomID: UUID?
    private var taskUpdates: AnyCancellable?

    init(friends: any FriendRepository, rooms: any WorkRoomRepository, tasks: any SharedTaskRepository,
         sharedTasks: SharedTasksViewModel, clock: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        friendRepository = friends; roomRepository = rooms; taskRepository = tasks
        self.sharedTasks = sharedTasks; self.clock = clock; self.calendar = calendar
        taskUpdates = sharedTasks.$assigned.combineLatest(sharedTasks.$sent).sink { [weak self] received, sent in
            guard let self else { return }
            var updates: [UUID: SharedTask] = [:]
            for task in received + sent { updates[task.id] = task }
            self.tasks = self.tasks.map { updates[$0.id] ?? $0 }
        }
    }
    var canManageMembers: Bool { selectedRoom?.creatorUserID == profile?.id }
    var sections: [RoomTaskSection] {
        groups.map { group in RoomTaskSection(group: group, tasks: sharedTasks.sorted(tasks.filter { $0.roomGroupID == group.id })) }
        + [RoomTaskSection(group: nil, tasks: sharedTasks.sorted(tasks.filter { $0.roomGroupID == nil }))]
    }
    var taskRecipients: [WorkUserSummary] {
        memberUsers.filter { user in members.contains { $0.userID == user.id && $0.removedAt == nil } }
    }
    var availableFriends: [FriendEntry] { friends.filter { friend in !members.contains { $0.userID == friend.user.id } } }

    func loadSidebar() async {
        do {
            profile = try await friendRepository.currentProfile()
            friends = try await friendRepository.friends()
            rooms = try await roomRepository.rooms(for: profile!.id)
        } catch { errorMessage = error.localizedDescription }
    }
    func loadRoom(_ id: UUID) async {
        pendingRoomID = id
        await drainPendingRooms()
    }
    private func drainPendingRooms() async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        // A sidebar selection made during a mutation/load must not be dropped.
        while let id = pendingRoomID {
            pendingRoomID = nil
            selectedRoom = nil; tasks = []; groups = []; members = []; memberUsers = []
            do { try await refreshRoom(id); errorMessage = nil }
            catch { errorMessage = error.localizedDescription }
        }
    }
    private func finishMutation() {
        isBusy = false
        if pendingRoomID != nil { Task { await self.drainPendingRooms() } }
    }
    private func refreshRoom(_ id: UUID) async throws {
        let profile = try await friendRepository.currentProfile(); self.profile = profile
        friends = try await friendRepository.friends()
        selectedRoom = try await roomRepository.room(id: id, for: profile.id)
        members = try await roomRepository.members(roomID: id, actorUserID: profile.id).filter { $0.removedAt == nil }
        groups = try await roomRepository.groups(roomID: id, actorUserID: profile.id)
        tasks = try await taskRepository.roomTasks(roomID: id, for: profile.id)
        var users: [WorkUserSummary] = []
        for member in members { users.append(try await roomRepository.memberUser(roomID: id, userID: member.userID, actorUserID: profile.id)) }
        memberUsers = users
        rooms = try await roomRepository.rooms(for: profile.id)
    }
    func createRoom(name: String, invited: Set<UUID>) async -> UUID? {
        guard !isBusy else { return nil }
        isBusy = true; defer { finishMutation() }
        do {
            let profile = try await friendRepository.currentProfile()
            let room = try await roomRepository.createRoom(name: name, creator: profile, invitedUserIDs: Array(invited))
            try await refreshRoom(room.id); errorMessage = nil
            return room.id
        } catch { errorMessage = error.localizedDescription; return nil }
    }
    private func mutate(_ operation: (UUID, UUID) async throws -> Void) async -> Bool {
        guard !isBusy, let room = selectedRoom, let profile else { return false }
        isBusy = true; defer { finishMutation() }
        do {
            try await operation(room.id, profile.id)
            try await refreshRoom(room.id)
            await sharedTasks.load()
            errorMessage = nil; return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func addMember(_ userID: UUID) async {
        _ = await mutate { try await self.roomRepository.addMember(roomID: $0, userID: userID, actorUserID: $1) }
    }
    func removeMember(_ userID: UUID) async {
        _ = await mutate { try await self.roomRepository.removeMember(roomID: $0, userID: userID, actorUserID: $1) }
    }
    func addGroup(name: String, color: String?) async -> Bool {
        await mutate { _ = try await self.roomRepository.createGroup(roomID: $0, name: name, color: color, actorUserID: $1) }
    }
    func renameGroup(_ group: RoomGroup, name: String) async -> Bool {
        await mutate { try await self.roomRepository.renameGroup(roomID: $0, groupID: group.id, name: name, actorUserID: $1) }
    }
    func deleteGroup(_ group: RoomGroup) async {
        _ = await mutate { try await self.roomRepository.deleteGroup(roomID: $0, groupID: group.id, actorUserID: $1) }
    }
    func addTask(title: String, groupID: UUID?, receiverID: UUID, requestID: UUID) async -> Bool {
        await mutate { roomID, _ in
            guard let sender = self.profile, let receiver = self.taskRecipients.first(where: { $0.id == receiverID }) else {
                throw WorkRoomError.forbidden
            }
            _ = try await self.taskRepository.sendRoomTask(SharedTaskDraft(id: requestID, title: title,
                date: self.calendar.startOfDay(for: self.clock())), roomID: roomID, groupID: groupID,
                sender: sender, receiver: receiver)
        }
    }
    func toggle(_ task: SharedTask) async {
        _ = await mutate { _, actor in
            let current = try await self.taskRepository.task(id: task.id, actorUserID: actor)
            _ = try await (current.isCompleted ? self.taskRepository.reopen(taskID: task.id, actorUserID: actor)
                          : self.taskRepository.complete(taskID: task.id, actorUserID: actor))
        }
    }
    func archive() async -> Bool {
        await mutate { try await self.roomRepository.archiveRoom(id: $0, actorUserID: $1) }
    }
}
