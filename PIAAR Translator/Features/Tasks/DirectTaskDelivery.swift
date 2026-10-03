import Foundation
import Combine

// One command = one new public.tasks row. The UUID stays unchanged on retry.
// No local Task persistence and no reassignment of the source Task.
enum DirectTaskPolicy {
    static func draft(title: String, today: TaskDay, deadline: TaskDay?, source: WorkTask?, userID: UUID, id: UUID) throws -> TaskDraft {
        if let source {
            guard source.permission(userID: userID) == .edit, !source.isRecurrenceTemplate else { throw TaskServiceError.permission }
            return TaskDraft(title: source.title, scheduledDate: today, deadlineDate: source.deadlineDate,
                             startAt: source.startAt, deadlineAt: source.deadlineAt, id: id, notes: source.notes)
        }
        return TaskDraft(title: title, scheduledDate: today, deadlineDate: deadline, id: id)
    }
    static func validate(_ draft: TaskDraft, receiver: UUID, sender: UUID) throws {
        try draft.validate()
        guard receiver != sender, draft.groupID == nil, draft.sourceLocalTodoID == nil,
              draft.recurrenceID == nil, !draft.isRecurrenceTemplate, draft.status == .open,
              draft.completedAt == nil else { throw TaskServiceError.invalidData }
    }
    static func matches(_ task: WorkTask, id: UUID, sender: UUID, receiver: UUID) -> Bool {
        task.id == id && task.createdBy == sender && task.assignedTo == receiver && task.spaceID == nil && !task.isRecurrenceTemplate
    }
}
enum DirectTaskError: LocalizedError {
    case notFriend
    var errorDescription: String? { "더 이상 친구가 아닙니다." }
}

@MainActor final class TaskDeliveryModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title: String
    @Published var deadline: Date?
    @Published var receiver: Friend?
    @Published private(set) var friends: [Friend] = []
    @Published private(set) var isSending = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var delivered = false
    let source: WorkTask?
    let fixedReceiver: Bool
    private let tasks: TaskRepository
    private let friendships: FriendshipRepository
    private let events: TaskEventQueue
    private let calendar: Calendar
    private let today: () -> Date
    private let name: () -> String?
    private let sessionFailure: (CollaborationAuthError) -> Void
    private var pending: (draft: TaskDraft, receiver: UUID, name: String?, receiverName: String)?
    private var invalidated = false
    init(tasks: TaskRepository, friendships: FriendshipRepository, events: TaskEventQueue, receiver: Friend?, source: WorkTask?,
         calendar: Calendar, today: @escaping () -> Date, name: @escaping () -> String?, sessionFailure: @escaping (CollaborationAuthError) -> Void) {
        self.tasks = tasks; self.friendships = friendships; self.events = events; self.receiver = receiver; self.source = source
        fixedReceiver = receiver != nil; title = source?.title ?? ""; deadline = source?.deadlineDate?.date(calendar: calendar)
        self.calendar = calendar; self.today = today; self.name = name; self.sessionFailure = sessionFailure
    }
    func invalidate() { invalidated = true; pending = nil; receiver = nil; friends = []; title = ""; deadline = nil; errorMessage = nil }
    func loadFriends() async {
        guard !invalidated else { return }; isLoading = true; defer { isLoading = false }
        do { let rows = try await friendships.snapshot(); guard !invalidated else { return }; friends = rows.friends }
        catch { report(error) }
    }
    func send() async -> Bool {
        guard !isSending, !delivered, !invalidated, let receiver else { return false }
        isSending = true; defer { isSending = false }
        do {
            guard tasks.userID == friendships.userID else { throw CollaborationAuthError.sessionMissing }
            let draft = try DirectTaskPolicy.draft(title: title, today: TaskDay(today(), calendar: calendar),
                deadline: deadline.map { TaskDay($0, calendar: calendar) }, source: source, userID: tasks.userID, id: pending?.draft.id ?? UUID())
            // After an ambiguous timeout, first reconcile the previous command. Do not create
            // another row just because the form was changed or the friendship has since ended.
            if let pending, let saved = try await tasks.fetchTask(id: pending.draft.id) {
                guard DirectTaskPolicy.matches(saved, id: pending.draft.id, sender: tasks.userID, receiver: pending.receiver) else { throw TaskServiceError.permission }
                guard !invalidated else { return false }
                await finish(saved, senderName: pending.name, receiverName: pending.receiverName); return !invalidated
            }
            try DirectTaskPolicy.validate(draft, receiver: receiver.userID, sender: tasks.userID)
            guard try await friendships.relationship(with: receiver.userID) == .friend else { throw DirectTaskError.notFriend }
            guard !invalidated else { return false }
            pending = (draft, receiver.userID, pending?.name ?? name(), receiver.displayName)
            let saved = try await tasks.createDirectTask(draft, receiverID: receiver.userID)
            guard !invalidated else { return false }
            await finish(saved, senderName: pending?.name, receiverName: receiver.displayName)
            return !invalidated
        } catch { report(error); return false }
    }
    private func finish(_ task: WorkTask, senderName: String?, receiverName: String) async {
        var requests = TaskEventRequest.creationEvents(task: task, actorID: tasks.userID, displayName: senderName)
        for i in requests.indices where requests[i].kind == .assigned {
            requests[i].metadata = ["receiver_id": task.assignedTo.uuidString, "receiver_display_name": receiverName]
        }
        await events.enqueue(requests)
        guard !invalidated else { return }; delivered = true; pending = nil; errorMessage = nil
    }
    private func report(_ error: Error) {
        guard !invalidated else { return }
        if let auth = error as? CollaborationAuthError {
            if auth == .sessionMissing || auth == .refreshFailed { invalidate(); sessionFailure(auth) }
            else { errorMessage = auth.localizedDescription }
        } else if error is DirectTaskError { errorMessage = error.localizedDescription }
        else if error is URLError { errorMessage = TaskServiceError.network.localizedDescription }
        else { errorMessage = (error as? TaskServiceError)?.localizedDescription ?? "전달하지 못했습니다. 다시 시도해주세요." }
    }
}
