import Foundation
import Combine

@MainActor final class TaskWorkspaceModel: ObservableObject {
    let spaceID: UUID?
    let spaceRepository: SpaceRepository?
    var onSpaceChange: (() async -> Void)?
    @Published private(set) var currentSpace: Space?
    @Published private(set) var spaceMembers: [SpaceMember] = []
    @Published private(set) var spaceNames: [UUID: String] = [:]
    @Published private(set) var archivedSpaceIDs: Set<UUID> = []
    @Published private(set) var invitationFriends: [Friend] = []
    private var pendingReceiver: UUID?
    let recurrences: TaskRecurrenceService?
    let userID: UUID
    let repository: TaskRepository
    let groupRepository: GroupRepository
    var calendar: Calendar
    var calendarLinks: TaskCalendarLinks?
    var calendarService: TodoCalendarService?
    var calendarMonth: Date?
    @Published var selectedDate: Date
    @Published var quickTitle = ""
    @Published private(set) var focusRevision = 0
    @Published private(set) var wantsFocus = false
    @Published private(set) var assigned: [WorkTask] = []
    @Published private(set) var todayTasks: [WorkTask] = []
    @Published private(set) var receivedIncompleteCount = 0
    @Published private(set) var received: [WorkTask] = []
    @Published private(set) var sent: [WorkTask] = []
    @Published private(set) var todaySent: [WorkTask] = []
    @Published private(set) var overdue: [WorkTask] = []
    @Published private(set) var someday: [WorkTask] = []
    @Published private(set) var groups: [TaskGroup] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isWriting = false
    @Published private(set) var loaded = false
    @Published private(set) var errorMessage: String?
    var historyNotice: String? { eventQueue.notice }
    @Published var editor: WorkTask?
    private var revision = 0
    private var invalidated = false
    private let now: () -> Date
    private let sessionFailure: (CollaborationAuthError) -> Void
    private var pendingCompletion: (id: UUID, status: TaskStatus, completedAt: Date?)?
    private var pendingDraft: TaskDraft?
    private var pendingSchedule: TaskScheduleCommand?
    private var pendingArchives: [UUID: UUID] = [:]
    @Published var delivery: TaskDeliveryModel?
    @Published private(set) var deliveryNotice: String?
    @Published private(set) var participantNames: [UUID: String] = [:]
    private let friendships: FriendshipRepository?
    let eventQueue: TaskEventQueue
    private let actorDisplayName: () -> String?
    private var eventObservation: AnyCancellable?
    private var pendingCreationName: String?
    init(repository: TaskRepository, groups: GroupRepository, calendar: Calendar = .autoupdatingCurrent,
         now: @escaping () -> Date = Date.init, events: TaskEventQueue? = nil, actorDisplayName: @escaping () -> String? = { nil }, sessionFailure: @escaping (CollaborationAuthError) -> Void = { _ in }, recurrences: TaskRecurrenceService? = nil, friendships: FriendshipRepository? = nil, spaceID: UUID? = nil, spaces: SpaceRepository? = nil) {
        self.spaceID = spaceID; spaceRepository = spaces; self.friendships = friendships; self.recurrences = recurrences; self.repository = repository; groupRepository = groups; userID = repository.userID
        eventQueue = events ?? TaskEventQueue(repository: repository); self.actorDisplayName = actorDisplayName
        self.calendar = calendar; self.now = now; self.sessionFailure = sessionFailure
        selectedDate = calendar.startOfDay(for: now())
        eventObservation = eventQueue.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    var today: Date { calendar.startOfDay(for: now()) }
    var overdueDays: Set<Date> { Set(deferredTasks.compactMap { $0.scheduledDate?.date(calendar: calendar) }) }
    var missed: [WorkTask] {
        let from = TaskDay(calendar.date(byAdding: .day, value: -3, to: today)!, calendar: calendar)
        return overdue.filter { ($0.scheduledDate.map { $0 >= from }) == true }
    }
    func parseQuickAdd(_ text: String, mini: Bool = false) -> QuickAddParseResult {
        QuickAddParser.parse(text, referenceDate: now(), calendar: calendar, timeZone: calendar.timeZone,
                             defaultDate: TaskDay(mini || spaceID != nil ? today : selectedDate, calendar: calendar))
    }
    var deferredTasks: [WorkTask] {
        overdue.filter { DeferredTaskPresentation.overdueDays($0, userID: userID, now: now(), calendar: calendar) != nil }
            .sorted { a, b in
                if a.scheduledDate != b.scheduledDate { return a.scheduledDate! < b.scheduledDate! }
                return a.id.uuidString < b.id.uuidString
            }
    }
    func canOrganize(_ task: WorkTask) -> Bool { DeferredTaskPresentation.canOrganize(task, userID: userID) && permission(for: task) == .edit }
    func requestFocus() { wantsFocus = true; focusRevision += 1 }
    func cancelInput() { quickTitle = ""; pendingDraft = nil; wantsFocus = false; focusRevision += 1 }
    func openToday() { selectedDate = today; if editor == nil { requestFocus() } }
    func invalidate() {
        invalidated = true; revision += 1
        currentSpace = nil; spaceMembers = []; spaceNames = [:]; archivedSpaceIDs = []; invitationFriends = []; pendingReceiver = nil
        receivedIncompleteCount = 0
        delivery?.invalidate(); delivery = nil; deliveryNotice = nil; participantNames = [:]
        assigned = []; todayTasks = []; received = []; sent = []; todaySent = []; overdue = []; someday = []; groups = []
        pendingCompletion = nil; pendingSchedule = nil; pendingArchives = [:]; editor = nil; quickTitle = ""; pendingDraft = nil; eventQueue.invalidate(); pendingCreationName = nil
        loaded = false; isLoading = false; isWriting = false; errorMessage = nil
    }
    func refresh() async {
        guard !invalidated else { return }
        if let spaceID { await refreshSpace(spaceID); return }
        revision += 1; let token = revision
        isLoading = true
        defer { if revision == token { isLoading = false } }
        let date = TaskDay(selectedDate, calendar: calendar), day = TaskDay(today, calendar: calendar)
        let month = calendar.dateInterval(of: .month, for: calendarMonth ?? selectedDate)!
        let from = TaskDay(calendar.date(byAdding: .day, value: -7, to: month.start)!, calendar: calendar)
        let before = min(day, TaskDay(calendar.date(byAdding: .day, value: 7, to: month.end)!, calendar: calendar))
        do {
            try await recurrences?.materializeToday(now: now())
            guard !invalidated, revision == token else { return }
            async let a = repository.tasksAssignedToMe(date: date)
            async let t = repository.tasksAssignedToMe(date: day)
            async let r = repository.tasks(.received(from: date, through: date))
            async let s = repository.tasks(.sent(from: date, through: date))
            async let ts = repository.tasks(.sent(from: day, through: day))
            async let o = repository.tasks(.overdue(from: from, before: before))
            async let m = repository.tasks(.allOverdue(before: day))
            async let somedayRows = repository.tasks(.someday)
            async let g = groupRepository.personalGroups()
            async let count = repository.receivedIncompleteCount()
            let result = try await (a, t, r, s, ts, o, g, m, count, somedayRows)
            guard revision == token, !invalidated else { return }
            receivedIncompleteCount = result.8
            if let pending = pendingCompletion,
               let row = (result.0 + result.1 + result.2 + result.5 + result.7).first(where: { $0.id == pending.id }),
               row.assignedTo == userID, row.createdBy != userID {
                receivedIncompleteCount = max(0, result.8 + (pending.status == .open ? 1 : 0) - (row.status == .open ? 1 : 0))
            }
            assigned = completionOverlay(result.0); todayTasks = completionOverlay(result.1); received = completionOverlay(result.2); sent = completionOverlay(result.3)
            todaySent = completionOverlay(result.4); groups = result.6; someday = completionOverlay(result.9)
            overdue = completionOverlay(result.5 + result.7).reduce(into: [WorkTask]()) { list, task in if !list.contains(where: { $0.id == task.id }) { list.append(task) } }
            loaded = true; errorMessage = nil
            // Current profile names remain resolvable after friendship deletion. History uses snapshots.
            let ids = Set((result.0 + result.1 + result.2 + result.3 + result.4).flatMap { [$0.createdBy, $0.assignedTo] }).subtracting([userID])
            do {
                let names = try await repository.participantNames(ids: ids)
                guard revision == token, !invalidated else { return }
                participantNames.merge(names, uniquingKeysWith: { _, new in new })
                if let spaceRepository {
                    let spaces = try await spaceRepository.spaces()
                    guard revision == token, !invalidated else { return }; updateSpaceStates(spaces)
                }
            } catch { if revision == token, !invalidated { report(error) } }
        } catch { if revision == token, !invalidated { report(error) } }
    }
    @discardableResult func add(groupID: UUID? = nil, mini: Bool = false, title: String? = nil, receiverID: UUID? = nil) async -> Bool {
        guard !isWriting, !invalidated, spaceWritable else { return false }
        let receiver = receiverID ?? userID
        let raw = (title ?? quickTitle).trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = parseQuickAdd(raw, mini: mini)
        let value = parsed.title
        guard !value.isEmpty else { return false }
        let day = parsed.scheduledDate
        if pendingDraft?.title != value || pendingDraft?.scheduledDate != day || pendingDraft?.groupID != groupID || pendingReceiver != receiver || pendingDraft?.scheduledAt != parsed.scheduledAt || pendingDraft?.dayPeriod != parsed.dayPeriod || pendingDraft?.estimatedMinutes != parsed.estimatedMinutes || pendingDraft?.priority != parsed.priority {
            pendingDraft = parsed.draft(groupID: groupID)
            pendingReceiver = receiver; pendingCreationName = actorDisplayName()
        }
        guard let draft = pendingDraft else { return false }
        isWriting = true; defer { isWriting = false }
        do {
            let task: WorkTask
            if let spaceID {
                guard let currentSpace, currentSpace.canAssign(userID: receiver, members: spaceMembers) else { throw SpaceError.permission }
                task = try await repository.createSpaceTask(draft, spaceID: spaceID, receiverID: receiver)
            } else { task = try await repository.createTask(draft) }
            guard !invalidated else { return false }
            if title == nil { quickTitle = "" }; pendingDraft = nil; requestFocus()
            var creationEvents = TaskEventRequest.creationEvents(task: task, actorID: userID, displayName: pendingCreationName)
            for i in creationEvents.indices where creationEvents[i].kind == .assigned {
                creationEvents[i].metadata = ["receiver_id": task.assignedTo.uuidString, "receiver_display_name": participantNames[task.assignedTo] ?? spaceMembers.first { $0.userID == task.assignedTo }?.displayNameSnapshot ?? "사용자"]
            }
            await eventQueue.enqueue(creationEvents)
            pendingCreationName = nil; await refreshAfterWrite(); return true
        } catch { if !invalidated { report(error) }; return false }
    }
    // UI cache only. Failed writes restore the previous status; no local persistence.
    private func completionOverlay(_ rows: [WorkTask]) -> [WorkTask] {
        guard let pendingCompletion else { return TaskPresentationSorter.sort(rows) }
        return TaskPresentationSorter.sort(rows.map { row in
            guard row.id == pendingCompletion.id else { return row }
            var copy = row; copy.status = pendingCompletion.status; copy.completedAt = pendingCompletion.completedAt; return copy
        })
    }
    private func showCompletion(id: UUID, status: TaskStatus, completedAt: Date?) {
        pendingCompletion = (id, status, completedAt)
        assigned = completionOverlay(assigned); todayTasks = completionOverlay(todayTasks)
        received = completionOverlay(received); sent = completionOverlay(sent); todaySent = completionOverlay(todaySent)
        overdue = completionOverlay(overdue)
    }
    func toggle(_ task: WorkTask) async {
        guard !isWriting, !invalidated, permission(for: task) != .readOnly else { return }
        isWriting = true; defer { isWriting = false }
        revision += 1; isLoading = false
        let oldCount = receivedIncompleteCount
        if task.createdBy != userID && task.assignedTo == userID {
            receivedIncompleteCount = max(0, receivedIncompleteCount + (task.status == .completed ? 1 : -1))
        }
        showCompletion(id: task.id, status: task.status == .completed ? .open : .completed,
            completedAt: task.status == .completed ? nil : now())
        do {
            let name = actorDisplayName()
            let updated = task.status == .completed ? try await repository.reopenTask(id: task.id) : try await repository.completeTask(id: task.id)
            guard !invalidated else { return }
            revision += 1; isLoading = false
            showCompletion(id: updated.id, status: updated.status, completedAt: updated.completedAt); pendingCompletion = nil
            await event(updated, kind: updated.status == .completed ? .completed : .reopened, name: name); await refreshAfterWrite()
        } catch {
            if !invalidated {
                revision += 1; isLoading = false
                receivedIncompleteCount = oldCount
                showCompletion(id: task.id, status: task.status, completedAt: task.completedAt); pendingCompletion = nil
                report(error)
            }
        }
    }
    func save(_ task: WorkTask, draft: TaskDraft) async -> Bool {
        guard !isWriting, !invalidated, canEditContent(task) else { return false }
        isWriting = true; defer { isWriting = false }
        do { _ = try await repository.updateTask(id: task.id, draft: draft); guard !invalidated else { return false }; await refreshAfterWrite(); return true }
        catch {
            if !invalidated {
                if error as? TaskServiceError == .scheduleConflict {
                    await refreshAfterWrite()
                    if let latest = try? await repository.fetchTask(id: task.id), !invalidated { editor = latest }
                }
                report(error)
            }
            return false
        }
    }
    @discardableResult func reschedule(_ task: WorkTask, date: TaskDay?) async -> Bool {
        guard !isWriting, !invalidated, canOrganize(task) else { return false }
        var at: Date?
        if let date, let originalAt = task.scheduledAt {
            if date == task.scheduledDate { at = originalAt }
            else {
                let components = calendar.dateComponents([.hour, .minute], from: originalAt)
                let day = date.date(calendar: calendar)
                at = calendar.date(bySettingHour: components.hour!, minute: components.minute!, second: 0, of: day, matchingPolicy: .strict, repeatedTimePolicy: .first, direction: .forward)
                guard let at, calendar.isDate(at, inSameDayAs: day) else { report(TaskServiceError.invalidData); return false }
            }
        }
        let period = date == nil ? nil : task.dayPeriod
        if pendingSchedule?.taskID != task.id || pendingSchedule?.matchesTarget(date: date, at: at, period: period) != true {
            pendingSchedule = TaskScheduleCommand(task: task, date: date, at: at, period: period)
        }
        guard let command = pendingSchedule else { return false }
        isWriting = true; defer { isWriting = false }
        do {
            _ = try await repository.rescheduleTask(command)
            guard !invalidated else { return false }; pendingSchedule = nil
            await refreshAfterWrite(); return true
        } catch {
            if !invalidated {
                if error as? TaskServiceError == .scheduleConflict { pendingSchedule = nil; await refreshAfterWrite() }
                report(error)
            }
            return false
        }
    }
    @discardableResult func organizeArchive(_ task: WorkTask) async -> Bool {
        guard !isWriting, !invalidated, canOrganize(task) else { return false }
        let command = pendingArchives[task.id] ?? UUID(); pendingArchives[task.id] = command
        isWriting = true; defer { isWriting = false }
        do {
            try await repository.archiveTask(id: task.id, commandID: command)
            guard !invalidated else { return false }; pendingArchives[task.id] = nil
            await refreshAfterWrite(); return true
        } catch { if !invalidated { report(error) }; return false }
    }
    func archive(_ task: WorkTask) async { _ = await organizeArchive(task) }
    func stopRepeating(_ task: WorkTask) async {
        guard !isWriting, !invalidated, permission(for: task) == .edit,
              let id = task.recurrenceID, let recurrences else { return }
        isWriting = true; defer { isWriting = false }
        do { try await recurrences.deactivate(id: id); if !invalidated { await refreshAfterWrite() } }
        catch { if !invalidated { report(error) } }
    }
    func createGroup(name: String, color: String, id: UUID = UUID()) async {
        guard !isWriting, !invalidated else { return }
        isWriting = true; defer { isWriting = false }
        do {
            if let spaceID { guard spaceWritable else { throw SpaceError.archived }; _ = try await groupRepository.createSpaceGroup(id: id, spaceID: spaceID, name: name, colorHex: color, sortOrder: groups.count) }
            else { _ = try await groupRepository.create(id: id, name: name, colorHex: color, sortOrder: groups.count) }
            if !invalidated { await refreshAfterWrite() }
        }
        catch { if !invalidated { report(error) } }
    }
    func renameGroup(_ group: TaskGroup, name: String, color: String?) async {
        guard !isWriting, !invalidated else { return }; isWriting = true; defer { isWriting = false }
        do {
            if let spaceID { guard canManageGroup(group) else { throw SpaceError.permission }; try await groupRepository.renameSpaceGroup(id: group.id, spaceID: spaceID, name: name, colorHex: color) }
            else { try await groupRepository.rename(id: group.id, name: name, colorHex: color) }
            if !invalidated { await refreshAfterWrite() }
        }
        catch { if !invalidated { report(error) } }
    }
    func deleteGroup(_ group: TaskGroup) async {
        guard !isWriting, !invalidated else { return }; isWriting = true; defer { isWriting = false }
        do {
            if let spaceID { guard canManageGroup(group) else { throw SpaceError.permission }; try await groupRepository.deleteSpaceGroup(id: group.id, spaceID: spaceID) }
            else { try await groupRepository.delete(id: group.id) }
            if !invalidated { await refreshAfterWrite() }
        }
        catch { if !invalidated { report(error) } }
    }
    func reorderGroups(_ ids: [UUID]) async {
        guard spaceID == nil, !isWriting, !invalidated else { return }; isWriting = true; defer { isWriting = false }
        do { try await groupRepository.reorder(ids: ids); if !invalidated { await refreshAfterWrite() } }
        catch { if !invalidated { report(error) } }
    }
    private func event(_ task: WorkTask, kind: TaskEventKind, name: String?) async {
        await eventQueue.enqueue([TaskEventRequest(id: UUID(), taskID: task.id, actorID: userID, kind: kind, actorDisplayNameSnapshot: name)])
    }
    func loadHistory(taskID: UUID) async throws -> [TaskHistoryEvent] {
        guard !invalidated else { throw CollaborationAuthError.sessionMissing }
        let rows: [TaskHistoryEvent]
        do { rows = try await repository.history(taskID: taskID) }
        catch { if !invalidated { report(error) }; throw error }
        guard !invalidated else { throw CollaborationAuthError.sessionMissing }; return rows
    }
    var canDeliver: Bool { friendships != nil }
    func beginDelivery(to friend: Friend? = nil, source: WorkTask? = nil) {
        guard !invalidated, delivery == nil, let friendships else { return }
        if let source { guard source.permission(userID: userID) == .edit, !source.isRecurrenceTemplate else { return } }
        deliveryNotice = nil
        delivery = TaskDeliveryModel(tasks: repository, friendships: friendships, events: eventQueue, receiver: friend, source: source,
            calendar: calendar, today: { [weak self] in self?.today ?? Date() }, name: actorDisplayName, sessionFailure: sessionFailure)
    }
    func deliveryFinished() async {
        guard !invalidated else { return }; delivery = nil; deliveryNotice = "전달됨"; await refresh()
    }
    func personName(for task: WorkTask) -> String? {
        guard task.createdBy != task.assignedTo else { return nil }
        return participantNames[task.assignedTo == userID ? task.createdBy : task.assignedTo] ?? "사용자"
    }
    func retryEvents() async { await eventQueue.retry() }
    func deadlineText(_ task: WorkTask) -> String? {
        TodoDates.dDay(deadline: task.deadlineDate?.date(calendar: calendar) ?? task.deadlineAt, now: now(), calendar: calendar)
    }
    private func report(_ error: Error) {
        if error is CancellationError { return }
        if let auth = error as? CollaborationAuthError {
            if auth == .sessionMissing || auth == .refreshFailed { sessionFailure(auth); return }
            errorMessage = auth.localizedDescription
        } else { errorMessage = (error as? SpaceError)?.localizedDescription ?? (error as? TaskServiceError)?.localizedDescription ?? (error is URLError ? TaskServiceError.network.localizedDescription : TaskServiceError.unavailable.localizedDescription) }
    }
}

extension TaskWorkspaceModel {
    var spaceWritable: Bool {
        guard spaceID != nil else { return true }
        guard let currentSpace, !currentSpace.isArchived else { return false }
        return currentSpace.canAccess(userID: userID, members: spaceMembers)
    }
    var isSpaceCreator: Bool { currentSpace?.createdBy == userID }
    var participants: [SpaceParticipant] {
        guard let space = currentSpace else { return [] }
        var people = [space.createdBy: participantNames[space.createdBy] ?? "업무방 생성자"]
        for member in spaceMembers where member.removedAt == nil { people[member.userID] = participantNames[member.userID] ?? member.displayNameSnapshot }
        return people.map { SpaceParticipant(id: $0.key, name: $0.key == userID ? "나" : $0.value) }.sorted {
            if $0.id == userID { return true }; if $1.id == userID { return false }; return $0.name.localizedCompare($1.name) == .orderedAscending
        }
    }
    func openEditor(_ task: WorkTask) {
        guard !invalidated, canEditContent(task) else { return }
        editor = task
    }
    func canEditContent(_ task: WorkTask) -> Bool {
        permission(for: task) == .edit && task.canEditContent(userID: userID)
    }
    func permission(for task: WorkTask) -> TaskPermission {
        if let id = task.spaceID, archivedSpaceIDs.contains(id) { return .readOnly }
        if spaceID != nil && !spaceWritable { return .readOnly }
        return task.permission(userID: userID)
    }
    func canManageGroup(_ group: TaskGroup) -> Bool {
        guard spaceID != nil else { return group.ownerID == userID }
        return spaceWritable && currentSpace?.canManage(group: group, userID: userID) == true
    }
    func updateSpaceStates(_ spaces: [Space]) {
        guard !invalidated else { return }
        spaceNames.merge(Dictionary(spaces.map { ($0.id, $0.name) }, uniquingKeysWith: { _, value in value }), uniquingKeysWith: { _, value in value })
        archivedSpaceIDs = Set(spaces.filter(\.isArchived).map(\.id))
        if let spaceID, let space = spaces.first(where: { $0.id == spaceID }) { currentSpace = space }
    }
    func clearSpaceAccess() {
        guard spaceID != nil else { return }; revision += 1; isLoading = false
        currentSpace = nil; assigned = []; groups = []; spaceMembers = []; participantNames = [:]; invitationFriends = []
        editor = nil; quickTitle = ""; errorMessage = SpaceError.permission.localizedDescription
    }
    private func refreshSpace(_ id: UUID) async {
        guard let spaceRepository else { return }
        revision += 1; let token = revision; isLoading = true; defer { if revision == token { isLoading = false } }
        do {
            guard let space = try await spaceRepository.space(id: id) else {
                guard !invalidated, revision == token else { return }
                clearSpaceAccess(); loaded = true; return
            }
            async let m = spaceRepository.members(spaceID: id)
            async let g = groupRepository.groups(spaceID: id)
            async let t = repository.tasks(.allInSpace(id))
            let result = try await (m, g, t)
            guard !invalidated, revision == token else { return }
            currentSpace = space; spaceMembers = result.0.filter { $0.removedAt == nil }; groups = result.1
            assigned = completionOverlay(result.2); loaded = true; errorMessage = nil; updateSpaceStates([space])
            let ids = Set(result.2.flatMap { [$0.createdBy, $0.assignedTo] } + result.0.map(\.userID) + [space.createdBy])
            let names = try await repository.participantNames(ids: ids)
            guard !invalidated, revision == token else { return }; participantNames.merge(names, uniquingKeysWith: { _, value in value })
        } catch { if !invalidated, revision == token { report(error) } }
    }
    private func refreshAfterWrite() async { await refresh(); if !invalidated { await onSpaceChange?() } }
    func loadInvitationFriends() async {
        guard !invalidated, isSpaceCreator, let friendships else { return }
        do {
            let result = try await friendships.snapshot()
            guard !invalidated else { return }
            invitationFriends = result.friends.filter { friend in friend.userID != currentSpace?.createdBy && !spaceMembers.contains { $0.userID == friend.userID && $0.removedAt == nil } }
        } catch { if !invalidated { report(error) } }
    }
    func invite(_ friend: Friend) async {
        guard !invalidated, !isWriting, spaceWritable, isSpaceCreator, let spaceID, let spaceRepository else { return }
        isWriting = true; defer { isWriting = false }
        do { _ = try await spaceRepository.addMember(id: UUID(), spaceID: spaceID, friend: friend); if !invalidated { await refreshAfterWrite(); await loadInvitationFriends() } }
        catch { if !invalidated { report(error) } }
    }
    func removeMember(_ member: SpaceMember) async {
        guard !invalidated, !isWriting, spaceWritable, isSpaceCreator, member.userID != currentSpace?.createdBy,
              let spaceID, let spaceRepository, member.spaceID == spaceID else { return }
        isWriting = true; defer { isWriting = false }
        do { try await spaceRepository.removeMember(id: member.id, spaceID: spaceID); if !invalidated { await refreshAfterWrite(); await loadInvitationFriends() } }
        catch { if !invalidated { report(error) } }
    }
    func archiveSpace() async -> Bool {
        guard !invalidated, !isWriting, isSpaceCreator, let spaceID, let spaceRepository else { return false }
        isWriting = true; defer { isWriting = false }
        do { try await spaceRepository.archiveSpace(id: spaceID); guard !invalidated else { return false }; await refreshAfterWrite(); return true }
        catch { if !invalidated { report(error) }; return false }
    }
    func relationshipText(_ task: WorkTask) -> String? {
        let sender = participantNames[task.createdBy] ?? "사용자", receiver = participantNames[task.assignedTo] ?? "사용자"
        if task.createdBy == task.assignedTo { return task.assignedTo == userID ? nil : receiver }
        if task.assignedTo == userID { return "← " + sender }
        if task.createdBy == userID { return "→ " + receiver }
        return sender + " → " + receiver
    }
}
