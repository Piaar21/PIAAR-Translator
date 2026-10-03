import Foundation

// Device-local mapping, separate from both Supabase and the legacy Todo archive.
@MainActor final class TaskCalendarLinks {
    private let url: URL?
    private var values: [String: String]
    private var readError: Error?
    init(userID: UUID, directory: URL? = nil, inMemory: Bool = false) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.piaar.PIAAR-Translator/TaskCalendarLinks")
        url = inMemory ? nil : base.appendingPathComponent(userID.uuidString + ".plist")
        values = [:]
        if let url, FileManager.default.fileExists(atPath: url.path) {
            do { values = try PropertyListDecoder().decode([String: String].self, from: Data(contentsOf: url)) }
            catch { readError = error }
        }
    }
    func identifier(taskID: UUID) -> String? { values[taskID.uuidString] }
    func set(taskID: UUID, identifier: String) throws {
        if let readError { throw readError }
        var next = values; next[taskID.uuidString] = identifier
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListEncoder().encode(next).write(to: url, options: .atomic)
        }
        values = next
    }
    func link(_ task: WorkTask, calendar: Calendar, service: TodoCalendarService, calendarID: String? = nil) throws {
        if let readError { throw readError }
        let timing = try TodoCalendarTiming.make(day: task.deadlineDate?.date(calendar: calendar), start: task.startAt, end: task.deadlineAt, calendar: calendar)
        let link = try service.upsert(identifier: identifier(taskID: task.id), calendarID: calendarID,
            title: task.title, start: timing.start, end: timing.end, isAllDay: timing.isAllDay)
        do { try set(taskID: task.id, identifier: link.identifier) }
        catch { if link.created { try? service.removeCreatedEvent(identifier: link.identifier) }; throw error }
    }
}
