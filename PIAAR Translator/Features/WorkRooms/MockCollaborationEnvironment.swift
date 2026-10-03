import Foundation

// One memory-only world per Full workspace. No singleton, DB, or network.
@MainActor final class MockCollaborationEnvironment {
    let friends: MockFriendRepository
    let rooms: MockWorkRoomRepository
    let tasks: MockSharedTaskRepository

    init(seedReceivedTasks: Bool = true, clock: @escaping () -> Date = Date.init) {
        let friends = MockFriendRepository(clock: clock)
        let rooms = MockWorkRoomRepository(friends: friends, clock: clock)
        let tasks = MockSharedTaskRepository(seedReceivedFor: seedReceivedTasks ? friends.mockProfile : nil,
            sampleSenders: friends.mockUsers, clock: clock, roomAccess: rooms)
        rooms.taskGroups = tasks
        self.friends = friends; self.rooms = rooms; self.tasks = tasks
    }
}

// Both window hosts retain/observe these same presentation models via TodoWorkspaceStore.
@MainActor final class CollaborationWorkspace {
    let friends: FriendsViewModel
    let sharedTasks: SharedTasksViewModel
    let rooms: WorkRoomsViewModel

    convenience init(environment: MockCollaborationEnvironment? = nil) {
        let environment = environment ?? MockCollaborationEnvironment()
        self.init(friendRepository: environment.friends, taskRepository: environment.tasks,
                  roomRepository: environment.rooms)
    }

    // Future backend adapters can be injected together without changing views or
    // mixing real account IDs into only one part of the Mock collaboration world.
    init(friendRepository: any FriendRepository, taskRepository: any SharedTaskRepository,
         roomRepository: any WorkRoomRepository) {
        friends = FriendsViewModel(repository: friendRepository)
        sharedTasks = SharedTasksViewModel(friends: friendRepository, tasks: taskRepository, rooms: roomRepository)
        rooms = WorkRoomsViewModel(friends: friendRepository, rooms: roomRepository,
                                  tasks: taskRepository, sharedTasks: sharedTasks)
    }
}
