import Foundation

// A civil date, never an implicitly UTC-converted midnight.
struct TaskDay: Codable, Hashable, Comparable {
    let value: String
    init(_ date: Date, calendar: Calendar) {
        var civil = Calendar(identifier: .gregorian); civil.timeZone = calendar.timeZone
        let c = civil.dateComponents([.year, .month, .day], from: date)
        value = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    init(value: String) throws {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!
        guard parts.count == 3, value.count == 10,
              let date = c.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              TaskDay(date, calendar: c).value == value else { throw TaskServiceError.invalidData }
        self.value = value
    }
    func date(calendar: Calendar) -> Date {
        let p = value.split(separator: "-").map { Int($0)! }
        var civil = Calendar(identifier: .gregorian); civil.timeZone = calendar.timeZone
        return civil.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))!
    }
    init(from decoder: Decoder) throws { try self.init(value: decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(value) }
    static func < (a: Self, b: Self) -> Bool { a.value < b.value }
}

enum TaskPriority: String, Codable { case normal, important }
enum TaskDayPeriod: String, Codable { case morning, afternoon, evening }

enum TaskStatus: String, Codable { case open, completed }
// Namespace avoids colliding with Swift concurrency's Task throughout the app.
enum TaskDomain {
    struct Task: Identifiable, Codable, Equatable {
        let id: UUID
        var title: String
        let createdBy: UUID
        let assignedTo: UUID
        let spaceID: UUID?
        var groupID: UUID?
        var scheduledDate: TaskDay?
        var deadlineDate: TaskDay?
        var deadlineAt: Date?
        var startAt: Date?
        var status: TaskStatus
        var completedAt: Date?
        let sourceLocalTodoID: UUID?
        let isArchived: Bool
        let createdAt: Date
        let updatedAt: Date
        var notes: String? = nil
        var sortOrder: Int? = nil
        var recurrenceID: UUID? = nil
        var isRecurrenceTemplate: Bool = false
        var scheduledAt: Date? = nil
        var dayPeriod: TaskDayPeriod? = nil
        var estimatedMinutes: Int? = nil
        var priority: TaskPriority = .normal
        var deferCount: Int = 0
        var lastDeferredAt: Date? = nil
        enum CodingKeys: String, CodingKey {
            case id, title, notes, status, priority
            case scheduledAt = "scheduled_at", dayPeriod = "day_period", estimatedMinutes = "estimated_minutes"
            case deferCount = "defer_count", lastDeferredAt = "last_deferred_at"
            case recurrenceID = "recurrence_id", isRecurrenceTemplate = "is_recurrence_template"
            case createdBy = "created_by", assignedTo = "assigned_to", spaceID = "space_id", groupID = "group_id"
            case scheduledDate = "scheduled_date", deadlineDate = "deadline_date", deadlineAt = "deadline_at", startAt = "start_at"
            case completedAt = "completed_at", sourceLocalTodoID = "source_local_todo_id", isArchived = "is_archived"
            case createdAt = "created_at", updatedAt = "updated_at", sortOrder = "sort_order"
        }
        func permission(userID: UUID) -> TaskPermission {
            if isRecurrenceTemplate || isArchived { return .readOnly }
            if createdBy == userID && assignedTo == userID { return .edit }
            return assignedTo == userID ? .completeOnly : .readOnly
        }
        // Rule management and copying an instance are separate from editing its row.
        func canEditContent(userID: UUID) -> Bool {
            permission(userID: userID) == .edit && recurrenceID == nil && !isRecurrenceTemplate
        }
    }
}
typealias WorkTask = TaskDomain.Task
enum TaskPermission { case edit, completeOnly, readOnly }
struct TaskDraft: Equatable {
    var title: String
    var scheduledDate: TaskDay
    var groupID: UUID? = nil
    var deadlineDate: TaskDay? = nil
    var startAt: Date? = nil
    var deadlineAt: Date? = nil
    var sourceLocalTodoID: UUID? = nil
    var status: TaskStatus = .open
    var completedAt: Date? = nil
    var id: UUID = UUID()
    var notes: String? = nil
    var recurrenceID: UUID? = nil
    var isRecurrenceTemplate: Bool = false
    var scheduledAt: Date? = nil
    var dayPeriod: TaskDayPeriod? = nil
    var estimatedMinutes: Int? = nil
    var priority: TaskPriority = .normal
    var isSomeday: Bool = false
    var expectedSchedule: TaskScheduleExpectation? = nil
    var scheduleDay: TaskDay? { isSomeday ? nil : scheduledDate }
    var normalizedNotes: String? { notes?.isEmpty == true ? nil : notes }
    func validate() throws {
        guard estimatedMinutes == nil || (1...1440).contains(estimatedMinutes!) else { throw TaskServiceError.invalidData }
        guard scheduledAt == nil || dayPeriod == nil else { throw TaskServiceError.invalidData }
        guard !isSomeday || (scheduledAt == nil && dayPeriod == nil && recurrenceID == nil && !isRecurrenceTemplate) else { throw TaskServiceError.invalidData }
        guard !(isRecurrenceTemplate && recurrenceID != nil) else { throw TaskServiceError.invalidData }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TaskServiceError.invalidData }
        if startAt != nil || deadlineAt != nil { guard deadlineDate != nil else { throw TaskServiceError.invalidData } }
        if let startAt, let deadlineAt, deadlineAt <= startAt { throw TaskServiceError.invalidData }
    }
}
enum TaskQuery: Equatable {
    case assigned(from: TaskDay, through: TaskDay)
    case created(from: TaskDay, through: TaskDay)
    case received(from: TaskDay, through: TaskDay)
    case sent(from: TaskDay, through: TaskDay)
    case overdue(from: TaskDay, before: TaskDay)
    case space(UUID, from: TaskDay, through: TaskDay)
    case allInSpace(UUID)
    case someday
    case allOverdue(before: TaskDay)
}
enum TaskEventKind: String, Codable { case created, assigned, completed, reopened, rescheduled, archived }
struct TaskEventRequest: Identifiable, Equatable, Codable {
    let id: UUID
    let taskID: UUID
    let actorID: UUID
    let kind: TaskEventKind
    var actorDisplayNameSnapshot: String? = nil
    var metadata: [String: String] = [:]
    static func creationEvents(task: WorkTask, actorID: UUID, displayName: String?) -> [Self] {
        let kinds: [TaskEventKind] = task.createdBy == task.assignedTo ? [.created] : [.created, .assigned]
        return kinds.map { Self(id: MigrationIdentity.id(kind: "event-" + $0.rawValue, userID: actorID, sourceID: task.id), taskID: task.id, actorID: actorID, kind: $0, actorDisplayNameSnapshot: displayName) }
    }
}
// Exact wire contract; append-only writes have no update/delete API.
struct TaskEventPayload: Encodable {
    let id: UUID
    let task_id: UUID
    let actor_id: UUID
    let actor_display_name_snapshot: String
    let event_type: String
    let metadata: [String: String]
    init(_ event: TaskEventRequest, userID: UUID) throws {
        guard event.actorID == userID, let name = event.actorDisplayNameSnapshot,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TaskServiceError.invalidData }
        id = event.id; task_id = event.taskID; actor_id = event.actorID
        actor_display_name_snapshot = name; event_type = event.kind.rawValue; metadata = event.metadata
    }
}
enum TaskServiceError: LocalizedError, Equatable {
    case invalidData, permission, network, unavailable, limitExceeded, notFound, unsupportedLegacy, scheduleConflict
    var errorDescription: String? {
        switch self {
        case .scheduleConflict: return "일정이 다른 곳에서 변경되었습니다. 최신 일정을 확인해주세요."
        case .invalidData: return "할 일 데이터 형식을 확인해주세요."
        case .permission: return "이 할 일을 변경할 권한이 없습니다."
        case .network: return "서버 연결에 실패했습니다. 기존 목록은 유지됩니다."
        case .unavailable: return "서버 요청에 실패했습니다. 다시 시도해주세요."
        case .limitExceeded: return "조회 범위에 할 일이 너무 많습니다. 날짜 범위를 줄여주세요."
        case .notFound: return "할 일을 찾을 수 없습니다."
        case .unsupportedLegacy: return "이 항목은 정보 보존을 위해 이전 대기로 남깁니다."
        }
    }
}
@MainActor protocol TaskRepository {
    var userID: UUID { get }
    func tasks(_ query: TaskQuery) async throws -> [WorkTask]
    func createTask(_ draft: TaskDraft) async throws -> WorkTask
    func updateTask(id: UUID, draft: TaskDraft) async throws -> WorkTask
    func completeTask(id: UUID) async throws -> WorkTask
    func reopenTask(id: UUID) async throws -> WorkTask
    func fetchTask(id: UUID) async throws -> WorkTask?
    func importedTask(sourceLocalTodoID: UUID) async throws -> WorkTask?
    func recurrenceInstance(id: UUID, day: TaskDay) async throws -> WorkTask?
    func archiveTask(id: UUID) async throws
    func archiveTask(id: UUID, commandID: UUID) async throws
    func rescheduleTask(_ command: TaskScheduleCommand) async throws -> WorkTask
    func createSpaceTask(_ draft: TaskDraft, spaceID: UUID, receiverID: UUID) async throws -> WorkTask
    func createDirectTask(_ draft: TaskDraft, receiverID: UUID) async throws -> WorkTask
    func participantNames(ids: Set<UUID>) async throws -> [UUID: String]
    func history(taskID: UUID) async throws -> [TaskHistoryEvent]
    func receivedIncompleteCount() async throws -> Int
    func recordEvent(_ event: TaskEventRequest) async throws
}
extension TaskRepository {
    func archiveTask(id: UUID, commandID: UUID) async throws { try await archiveTask(id: id) }
    func rescheduleTask(_ command: TaskScheduleCommand) async throws -> WorkTask { throw TaskServiceError.unavailable }
    func createSpaceTask(_ draft: TaskDraft, spaceID: UUID, receiverID: UUID) async throws -> WorkTask { throw TaskServiceError.unavailable }
    func receivedIncompleteCount() async throws -> Int { 0 }
    func createDirectTask(_ draft: TaskDraft, receiverID: UUID) async throws -> WorkTask { throw TaskServiceError.unavailable }
    func participantNames(ids: Set<UUID>) async throws -> [UUID: String] { [:] }
    func history(taskID: UUID) async throws -> [TaskHistoryEvent] { throw TaskServiceError.unavailable }
    func recurrenceInstance(id: UUID, day: TaskDay) async throws -> WorkTask? { throw TaskServiceError.unavailable }
    func tasksAssignedToMe(date: TaskDay) async throws -> [WorkTask] { try await tasks(.assigned(from: date, through: date)) }
    func tasksCreatedByMe(date: TaskDay) async throws -> [WorkTask] { try await tasks(.created(from: date, through: date)) }
}

// Keep existing absolute instants when an edit only changes title/group,
// including after a device timezone change.
enum TaskDeadlineTiming {
    static func timestamp(_ time: Date, day: TaskDay, originalDay: TaskDay?, originalTime: Date?, calendar: Calendar) -> Date {
        if day == originalDay, time == originalTime { return time }
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.date(bySettingHour: parts.hour!, minute: parts.minute!, second: 0, of: day.date(calendar: calendar))!
    }
}

// History uses the recorded actor name, never a current profile lookup.
struct TaskHistoryEvent: Codable, Identifiable, Equatable {
    let id: UUID
    let taskID: UUID
    let actorID: UUID
    let actorDisplayNameSnapshot: String
    let kind: TaskEventKind
    let metadata: [String: String]
    let createdAt: Date
    enum CodingKeys: String, CodingKey {
        case id, taskID = "task_id", actorID = "actor_id", actorDisplayNameSnapshot = "actor_display_name_snapshot"
        case kind = "event_type", metadata, createdAt = "created_at"
    }
    var summary: String {
        switch kind {
        case .created: return actorDisplayNameSnapshot + " 생성"
        case .assigned: return (metadata["receiver_display_name"] ?? "친구") + "에게 전달"
        case .completed: return actorDisplayNameSnapshot + " 완료"
        case .reopened: return actorDisplayNameSnapshot + " 완료 취소"
        case .rescheduled: return actorDisplayNameSnapshot + " 일정 변경"
        case .archived: return actorDisplayNameSnapshot + " 삭제"
        }
    }
}

extension TaskHistoryEvent {
    // metadata is JSONB. Only string presentation fields are consumed; unrelated
    // structured keys or NULL from other clients must not make history unreadable.
    private struct MetadataKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var strings: [String: String] = [:]
        if let metadata = try? c.nestedContainer(keyedBy: MetadataKey.self, forKey: .metadata) {
            for key in metadata.allKeys {
                if let value = try? metadata.decode(String.self, forKey: key) { strings[key.stringValue] = value }
            }
        }
        self.init(id: try c.decode(UUID.self, forKey: .id), taskID: try c.decode(UUID.self, forKey: .taskID),
                  actorID: try c.decode(UUID.self, forKey: .actorID),
                  actorDisplayNameSnapshot: try c.decodeIfPresent(String.self, forKey: .actorDisplayNameSnapshot) ?? "알 수 없는 사용자",
                  kind: try c.decode(TaskEventKind.self, forKey: .kind), metadata: strings,
                  createdAt: try c.decode(Date.self, forKey: .createdAt))
    }
}

extension TaskDomain.Task {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        createdBy = try c.decode(UUID.self, forKey: .createdBy); assignedTo = try c.decode(UUID.self, forKey: .assignedTo)
        spaceID = try c.decodeIfPresent(UUID.self, forKey: .spaceID); groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        scheduledDate = try c.decodeIfPresent(TaskDay.self, forKey: .scheduledDate)
        deadlineDate = try c.decodeIfPresent(TaskDay.self, forKey: .deadlineDate)
        deadlineAt = try c.decodeIfPresent(Date.self, forKey: .deadlineAt); startAt = try c.decodeIfPresent(Date.self, forKey: .startAt)
        status = try c.decode(TaskStatus.self, forKey: .status); completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        sourceLocalTodoID = try c.decodeIfPresent(UUID.self, forKey: .sourceLocalTodoID)
        isArchived = try c.decode(Bool.self, forKey: .isArchived)
        createdAt = try c.decode(Date.self, forKey: .createdAt); updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        notes = try c.decodeIfPresent(String.self, forKey: .notes); sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder)
        recurrenceID = try c.decodeIfPresent(UUID.self, forKey: .recurrenceID)
        isRecurrenceTemplate = try c.decodeIfPresent(Bool.self, forKey: .isRecurrenceTemplate) ?? false
        scheduledAt = try c.decodeIfPresent(Date.self, forKey: .scheduledAt)
        dayPeriod = try c.decodeIfPresent(TaskDayPeriod.self, forKey: .dayPeriod)
        estimatedMinutes = try c.decodeIfPresent(Int.self, forKey: .estimatedMinutes)
        priority = try c.decodeIfPresent(TaskPriority.self, forKey: .priority) ?? .normal
        deferCount = try c.decodeIfPresent(Int.self, forKey: .deferCount) ?? 0
        lastDeferredAt = try c.decodeIfPresent(Date.self, forKey: .lastDeferredAt)
        guard estimatedMinutes == nil || (1...1440).contains(estimatedMinutes!), deferCount >= 0 else { throw TaskServiceError.invalidData }
    }
}

enum DeferredTaskPresentation {
    static func overdueDays(_ task: WorkTask, userID: UUID, now: Date, calendar: Calendar) -> Int? {
        guard task.assignedTo == userID, task.status == .open, !task.isArchived, !task.isRecurrenceTemplate,
              let day = task.scheduledDate else { return nil }
        let days = calendar.dateComponents([.day], from: day.date(calendar: calendar), to: calendar.startOfDay(for: now)).day ?? 0
        return days > 0 ? days : nil
    }
    static func canOrganize(_ task: WorkTask, userID: UUID) -> Bool {
        task.permission(userID: userID) == .edit && !task.isArchived && !task.isRecurrenceTemplate && task.recurrenceID == nil
    }
    static func summary(_ task: WorkTask, userID: UUID, now: Date, calendar: Calendar) -> String? {
        guard let days = overdueDays(task, userID: userID, now: now, calendar: calendar) else { return nil }
        return "\(days)일째 미완료" + (task.deferCount > 0 ? " · \(task.deferCount)번 미룸" : "")
    }
}
