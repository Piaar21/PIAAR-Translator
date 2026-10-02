import Foundation

struct SharedTask: Identifiable, Equatable {
    let id: UUID
    let title: String
    let senderUserID: UUID
    let senderDisplayName: String
    let receiverUserID: UUID
    let receiverDisplayName: String
    let sourceTodoID: UUID?
    let roomID: UUID?
    var roomGroupID: UUID? = nil
    let date: Date
    let deadlineDate: Date?
    var isCompleted: Bool
    var completedAt: Date?
    let createdAt: Date
    var updatedAt: Date
}

struct SharedTaskDraft: Equatable {
    let id: UUID
    let title: String
    let date: Date
    let deadlineDate: Date?
    let sourceTodoID: UUID?

    init(todo: TodoSnapshot, id: UUID = UUID()) {
        self.id = id
        title = todo.title
        date = todo.date
        deadlineDate = todo.effectiveDeadlineDate
        sourceTodoID = todo.id
    }

    init(id: UUID = UUID(), title: String, date: Date, deadlineDate: Date? = nil, sourceTodoID: UUID? = nil) {
        self.id = id; self.title = title; self.date = date
        self.deadlineDate = deadlineDate; self.sourceTodoID = sourceTodoID
    }
}

struct TaskHistoryEntry: Identifiable, Equatable {
    enum Action: String { case created, sent, completed, reopened }
    let id: UUID
    let taskID: UUID
    let actorUserID: UUID
    let actorDisplayName: String
    let action: Action
    let timestamp: Date
}

enum SharedTaskError: LocalizedError, Equatable {
    case selfSend, emptyTitle, notFound, forbidden, conflictingRequest, notFriend
    var errorDescription: String? {
        switch self {
        case .selfSend: return "자기 자신에게 업무를 전달할 수 없습니다."
        case .emptyTitle: return "업무 제목을 입력해주세요."
        case .notFound: return "업무를 찾을 수 없습니다."
        case .forbidden: return "받은 사람만 완료 상태를 변경할 수 있습니다."
        case .conflictingRequest: return "이미 처리된 전달 요청입니다."
        case .notFriend: return "현재 친구 목록에서 받는 사람을 선택해주세요."
        }
    }
}

// The only mutation after sending is receiver completion. No content-editing API.
// actorUserID is a Mock policy input, not authentication; a real adapter must verify identity.
@MainActor
protocol SharedTaskRepository {
    func sendTask(_ draft: SharedTaskDraft, sender: WorkUserSummary, receiver: WorkUserSummary) async throws -> SharedTask
    func sentTasks(for userID: UUID) async throws -> [SharedTask]
    func receivedTasks(for userID: UUID) async throws -> [SharedTask]
    func complete(taskID: UUID, actorUserID: UUID) async throws -> SharedTask
    func reopen(taskID: UUID, actorUserID: UUID) async throws -> SharedTask
    func task(id: UUID, actorUserID: UUID?) async throws -> SharedTask
    func history(taskID: UUID, actorUserID: UUID?) async throws -> [TaskHistoryEntry]
    func roomTasks(roomID: UUID, for userID: UUID) async throws -> [SharedTask]
    func sendRoomTask(_ draft: SharedTaskDraft, roomID: UUID, groupID: UUID?,
                      sender: WorkUserSummary, receiver: WorkUserSummary) async throws -> SharedTask
}

extension SharedTaskRepository {
    func task(id: UUID) async throws -> SharedTask { try await task(id: id, actorUserID: nil) }
    func history(taskID: UUID) async throws -> [TaskHistoryEntry] { try await history(taskID: taskID, actorUserID: nil) }
}

@MainActor
final class MockSharedTaskRepository: SharedTaskRepository, RoomTaskGroupMaintenance {
    private var tasks: [UUID: SharedTask] = [:]
    private var records: [UUID: [TaskHistoryEntry]] = [:]
    private let clock: () -> Date
    private let roomAccess: (any WorkRoomAccess)?

    // Optional, explicitly Mock-only received samples. Tests can use an empty repository.
    init(seedReceivedFor profile: WorkUserSummary? = nil, sampleSenders: [WorkUserSummary] = [], clock: @escaping () -> Date = Date.init,
         calendar: Calendar = .current, roomAccess: (any WorkRoomAccess)? = nil) {
        self.clock = clock
        self.roomAccess = roomAccess
        if let profile {
            let now = clock()
            for (index, sender) in sampleSenders.prefix(2).enumerated() {
                let draft = SharedTaskDraft(title: index == 0 ? "상품 등록 확인" : "발주서 확인", date: calendar.startOfDay(for: now),
                    deadlineDate: calendar.date(byAdding: .day, value: index + 1, to: calendar.startOfDay(for: now)))
                _ = try? insert(draft, sender: sender, receiver: profile)
            }
        }
    }

    func sendTask(_ draft: SharedTaskDraft, sender: WorkUserSummary, receiver: WorkUserSummary) async throws -> SharedTask {
        try insert(draft, sender: sender, receiver: receiver)
    }

    private func insert(_ draft: SharedTaskDraft, sender: WorkUserSummary, receiver: WorkUserSummary,
                        roomID: UUID? = nil, groupID: UUID? = nil) throws -> SharedTask {
        guard sender.id != receiver.id || roomID != nil else { throw SharedTaskError.selfSend }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw SharedTaskError.emptyTitle }
        if let existing = tasks[draft.id] {
            guard existing.senderUserID == sender.id, existing.receiverUserID == receiver.id,
                  existing.title == title, existing.sourceTodoID == draft.sourceTodoID,
                  existing.date == draft.date, existing.deadlineDate == draft.deadlineDate,
                  existing.roomID == roomID, existing.roomGroupID == groupID else {
                throw SharedTaskError.conflictingRequest
            }
            return existing
        }
        let now = clock()
        let task = SharedTask(id: draft.id, title: title, senderUserID: sender.id,
            senderDisplayName: sender.displayName, receiverUserID: receiver.id,
            receiverDisplayName: receiver.displayName, sourceTodoID: draft.sourceTodoID,
            roomID: roomID, roomGroupID: groupID, date: draft.date, deadlineDate: draft.deadlineDate,
            isCompleted: false, completedAt: nil, createdAt: now, updatedAt: now)
        tasks[task.id] = task
        let actions: [TaskHistoryEntry.Action] = sender.id == receiver.id ? [.created] : [.created, .sent]
        records[task.id] = actions.map {
            TaskHistoryEntry(id: UUID(), taskID: task.id, actorUserID: sender.id,
                             actorDisplayName: sender.displayName, action: $0, timestamp: now)
        }
        return task
    }

    func sentTasks(for userID: UUID) async throws -> [SharedTask] {
        try await visibleTasks(for: userID, sent: true)
    }
    func receivedTasks(for userID: UUID) async throws -> [SharedTask] {
        try await visibleTasks(for: userID, sent: false)
    }
    private func visibleTasks(for userID: UUID, sent: Bool) async throws -> [SharedTask] {
        var result: [SharedTask] = []
        for task in tasks.values where task.senderUserID != task.receiverUserID &&
            (sent ? task.senderUserID == userID : task.receiverUserID == userID) {
            if let roomID = task.roomID {
                guard let roomAccess else { continue }
                do { try await roomAccess.validateAccess(roomID: roomID, userID: userID, writing: false) }
                catch WorkRoomError.forbidden { continue }
            }
            result.append(task)
        }
        return result
    }
    func task(id: UUID, actorUserID: UUID?) async throws -> SharedTask {
        guard let task = tasks[id] else { throw SharedTaskError.notFound }
        if let roomID = task.roomID {
            guard let roomAccess, let actorUserID else { throw WorkRoomError.forbidden }
            try await roomAccess.validateAccess(roomID: roomID, userID: actorUserID, writing: false)
        }
        return task
    }
    func history(taskID: UUID, actorUserID: UUID?) async throws -> [TaskHistoryEntry] {
        _ = try await task(id: taskID, actorUserID: actorUserID)
        return records[taskID] ?? []
    }
    func roomTasks(roomID: UUID, for userID: UUID) async throws -> [SharedTask] {
        guard let roomAccess else { throw WorkRoomError.forbidden }
        try await roomAccess.validateAccess(roomID: roomID, userID: userID, writing: false)
        return tasks.values.filter { $0.roomID == roomID }
    }
    func sendRoomTask(_ draft: SharedTaskDraft, roomID: UUID, groupID: UUID?,
                      sender: WorkUserSummary, receiver: WorkUserSummary) async throws -> SharedTask {
        guard let roomAccess else { throw WorkRoomError.forbidden }
        try await roomAccess.validateTask(roomID: roomID, senderID: sender.id, receiverID: receiver.id, groupID: groupID)
        return try insert(draft, sender: sender, receiver: receiver, roomID: roomID, groupID: groupID)
    }
    func detachGroup(roomID: UUID, groupID: UUID) async {
        for id in Array(tasks.keys) where tasks[id]?.roomID == roomID && tasks[id]?.roomGroupID == groupID {
            tasks[id]?.roomGroupID = nil
            if let updatedAt = tasks[id]?.updatedAt { tasks[id]?.updatedAt = max(clock(), updatedAt) }
        }
    }
    func complete(taskID: UUID, actorUserID: UUID) async throws -> SharedTask {
        try await setCompletion(true, taskID: taskID, actorUserID: actorUserID)
    }
    func reopen(taskID: UUID, actorUserID: UUID) async throws -> SharedTask {
        try await setCompletion(false, taskID: taskID, actorUserID: actorUserID)
    }
    private func setCompletion(_ completed: Bool, taskID: UUID, actorUserID: UUID) async throws -> SharedTask {
        guard var task = tasks[taskID] else { throw SharedTaskError.notFound }
        guard actorUserID == task.receiverUserID else { throw SharedTaskError.forbidden }
        if let roomID = task.roomID {
            guard let roomAccess else { throw WorkRoomError.forbidden }
            try await roomAccess.validateAccess(roomID: roomID, userID: actorUserID, writing: true)
        }
        guard task.isCompleted != completed else { return task }
        let now = max(clock(), task.updatedAt)
        task.isCompleted = completed; task.completedAt = completed ? now : nil; task.updatedAt = now
        tasks[taskID] = task
        records[taskID, default: []].append(TaskHistoryEntry(id: UUID(), taskID: taskID,
            actorUserID: actorUserID, actorDisplayName: task.receiverDisplayName,
            action: completed ? .completed : .reopened, timestamp: now))
        return task
    }
}
