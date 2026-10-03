import Foundation

struct TaskScheduleExpectation: Equatable {
    let date: TaskDay?
    let at: Date?
    let period: TaskDayPeriod?
    init(_ task: WorkTask) { date = task.scheduledDate; at = task.scheduledAt; period = task.dayPeriod }
    func matches(date: TaskDay?, at: Date?, period: TaskDayPeriod?) -> Bool { self.date == date && self.at == at && self.period == period }
}

struct TaskScheduleCommand: Equatable {
    let id: UUID
    let taskID: UUID
    let expectedDate: TaskDay?
    let expectedAt: Date?
    let expectedPeriod: TaskDayPeriod?
    let targetDate: TaskDay?
    let targetAt: Date?
    let targetPeriod: TaskDayPeriod?
    init(task: WorkTask, date: TaskDay?, at: Date? = nil, period: TaskDayPeriod? = nil, id: UUID = UUID(), expectation: TaskScheduleExpectation? = nil) {
        self.id = id; taskID = task.id
        let expected = expectation ?? TaskScheduleExpectation(task)
        expectedDate = expected.date; expectedAt = expected.at; expectedPeriod = expected.period
        targetDate = date; targetAt = at; targetPeriod = period
    }
    func matchesTarget(date: TaskDay?, at: Date?, period: TaskDayPeriod?) -> Bool {
        targetDate == date && targetAt == at && targetPeriod == period
    }
    func validate() throws {
        guard targetDate != nil || (targetAt == nil && targetPeriod == nil), targetAt == nil || targetPeriod == nil else { throw TaskServiceError.invalidData }
    }
}

@MainActor protocol TaskScheduleTransport {
    func authorize() async throws
    func reschedule(_ command: TaskScheduleCommand) async throws -> WorkTask
    func archive(taskID: UUID, commandID: UUID) async throws -> WorkTask
}

// Server mutations are atomic; they never enqueue a second client Event.
@MainActor enum TaskScheduleMutation {
    static func reschedule(_ command: TaskScheduleCommand, transport: TaskScheduleTransport) async throws -> WorkTask {
        try command.validate(); try await transport.authorize()
        let row = try await transport.reschedule(command)
        try await transport.authorize()
        guard row.id == command.taskID else { throw TaskServiceError.invalidData }
        return row
    }
    static func archive(taskID: UUID, commandID: UUID, transport: TaskScheduleTransport) async throws -> WorkTask {
        try await transport.authorize()
        let row = try await transport.archive(taskID: taskID, commandID: commandID)
        try await transport.authorize()
        guard row.id == taskID else { throw TaskServiceError.invalidData }
        return row
    }
}
