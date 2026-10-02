import Foundation
import Combine

@MainActor
final class SharedTasksViewModel: ObservableObject {
    @Published private(set) var received: [SharedTask] = []
    @Published private(set) var assigned: [SharedTask] = []
    @Published private(set) var sent: [SharedTask] = []
    @Published private(set) var recipients: [FriendEntry] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isBusy = false
    private let friendRepository: any FriendRepository
    private let repository: any SharedTaskRepository
    private let rooms: (any WorkRoomRepository)?
    @Published private(set) var roomNames: [UUID: String] = [:]
    private let clock: () -> Date
    private let calendar: Calendar

    var receivedIncompleteCount: Int { received.filter { !$0.isCompleted }.count }

    init(friends: any FriendRepository, tasks: any SharedTaskRepository,
         clock: @escaping () -> Date = Date.init, calendar: Calendar = .current,
         rooms: (any WorkRoomRepository)? = nil) {
        friendRepository = friends; repository = tasks; self.clock = clock; self.calendar = calendar; self.rooms = rooms
    }

    func load() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await refresh()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func refresh() async throws {
        let profile = try await friendRepository.currentProfile()
        recipients = try await friendRepository.friends()
        received = sorted(try await repository.receivedTasks(for: profile.id))
        sent = sorted(try await repository.sentTasks(for: profile.id))
        var roomTasks: [SharedTask] = []
        var names: [UUID: String] = [:]
        if let rooms {
            for room in try await rooms.rooms(for: profile.id) {
                names[room.id] = room.name
                roomTasks += try await repository.roomTasks(roomID: room.id, for: profile.id)
            }
            for id in Set((received + sent).compactMap(\.roomID)) where names[id] == nil {
                names[id] = try await rooms.room(id: id, for: profile.id).name
            }
        }
        roomNames = names
        assigned = sorted(MyTaskPresentation.assigned(received: received, roomTasks: roomTasks, userID: profile.id))
    }

    @discardableResult
    func send(_ draft: SharedTaskDraft, receiverID: UUID) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let profile = try await friendRepository.currentProfile()
            let friends = try await friendRepository.friends() // Revalidate after a sheet was opened.
            guard let receiver = friends.first(where: { $0.user.id == receiverID })?.user else {
                throw SharedTaskError.notFriend
            }
            let task = try await repository.sendTask(draft, sender: profile, receiver: receiver)
            sent.removeAll { $0.id == task.id }; sent.append(task); sent = sorted(sent)
            errorMessage = nil
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    // A second UI entry point into the existing send/revalidation path.
    func sendNewTask(title: String, deadline: Date?, receiverID: UUID, requestID: UUID) async -> Bool {
        let draft = SharedTaskDraft(id: requestID, title: title, date: calendar.startOfDay(for: clock()),
                                   deadlineDate: deadline.map { calendar.startOfDay(for: $0) })
        return await send(draft, receiverID: receiverID)
    }

    func toggle(_ task: SharedTask) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let profile = try await friendRepository.currentProfile()
            let current = try await repository.task(id: task.id, actorUserID: profile.id)
            let updated = try await (current.isCompleted
                ? repository.reopen(taskID: task.id, actorUserID: profile.id)
                : repository.complete(taskID: task.id, actorUserID: profile.id))
            received = sorted(received.map { $0.id == updated.id ? updated : $0 })
            sent = sorted(sent.map { $0.id == updated.id ? updated : $0 })
            assigned = sorted(assigned.map { $0.id == updated.id ? updated : $0 })
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func history(for task: SharedTask) async throws -> [TaskHistoryEntry] {
        let profile = try await friendRepository.currentProfile()
        return try await repository.history(taskID: task.id, actorUserID: profile.id)
    }

    func received(on date: Date, calendar: Calendar) -> [SharedTask] {
        let interval = TodoDates.interval(for: date, calendar: calendar)
        return received.filter { $0.date >= interval.start && $0.date < interval.end }
    }

    func assigned(on date: Date, calendar: Calendar) -> [SharedTask] {
        let interval = TodoDates.interval(for: date, calendar: calendar)
        return assigned.filter { $0.date >= interval.start && $0.date < interval.end }
    }

    func sent(on date: Date, calendar: Calendar) -> [SharedTask] {
        let interval = TodoDates.interval(for: date, calendar: calendar)
        return sent.filter { $0.date >= interval.start && $0.date < interval.end }
    }

    func dDay(_ task: SharedTask) -> String? {
        TodoDates.dDay(deadline: task.deadlineDate, now: clock(), calendar: calendar)
    }

    func sorted(_ tasks: [SharedTask]) -> [SharedTask] {
        let today = clock()
        return tasks.sorted {
            if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
            let aToday = calendar.isDate($0.date, inSameDayAs: today)
            let bToday = calendar.isDate($1.date, inSameDayAs: today)
            if aToday != bToday { return aToday }
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

// Presentation only: never converts SharedTask into a persisted TodoItem.
enum TodayListItem: Identifiable {
    enum ID: Hashable { case personal(UUID), received(UUID) }
    case personalTodo(TodoSnapshot)
    case receivedTask(SharedTask)
    var id: ID {
        switch self {
        case .personalTodo(let todo): return .personal(todo.id)
        case .receivedTask(let task): return .received(task.id)
        }
    }
    var isCompleted: Bool {
        switch self {
        case .personalTodo(let todo): return todo.isCompleted
        case .receivedTask(let task): return task.isCompleted
        }
    }
    static func combined(personal: [TodoSnapshot], received: [SharedTask]) -> [TodayListItem] {
        let items = personal.map(Self.personalTodo) + received.map(Self.receivedTask)
        return items.filter { !$0.isCompleted } + items.filter(\.isCompleted)
    }
}

// One projection for Full, Mini, and calendar indicators. Nothing is persisted.
enum MyTaskPresentation {
    static func assigned(received: [SharedTask], roomTasks: [SharedTask], userID: UUID) -> [SharedTask] {
        var seen = Set<UUID>()
        return (received + roomTasks).filter { $0.receiverUserID == userID && seen.insert($0.id).inserted }
    }
    static func overdueDays(personal: Set<Date>, assigned: [SharedTask], today: Date, calendar: Calendar) -> Set<Date> {
        let today = calendar.startOfDay(for: today)
        return personal.union(assigned.filter { !$0.isCompleted && $0.date < today }
            .map { calendar.startOfDay(for: $0.date) })
    }
}
