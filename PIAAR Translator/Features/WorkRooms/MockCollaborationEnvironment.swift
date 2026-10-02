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

    init(environment: MockCollaborationEnvironment? = nil) {
        let environment = environment ?? MockCollaborationEnvironment()
        friends = FriendsViewModel(repository: environment.friends)
        sharedTasks = SharedTasksViewModel(friends: environment.friends, tasks: environment.tasks, rooms: environment.rooms)
        rooms = WorkRoomsViewModel(friends: environment.friends, rooms: environment.rooms,
                                  tasks: environment.tasks, sharedTasks: sharedTasks)
    }
}
