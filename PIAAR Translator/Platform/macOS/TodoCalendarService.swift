import Foundation
import EventKit

struct TodoCalendarOption: Identifiable, Equatable {
    let id: String
    let title: String
}
struct TodoCalendarLink {
    let identifier: String
    let created: Bool
}

@MainActor
protocol TodoCalendarService {
    func requestAccess() async throws
    func calendars() throws -> [TodoCalendarOption]
    func upsert(identifier: String?, calendarID: String?, title: String, start: Date, end: Date, isAllDay: Bool) throws -> TodoCalendarLink
    func removeCreatedEvent(identifier: String) throws
}

@MainActor
final class AppleTodoCalendarService: TodoCalendarService {
    private let store = EKEventStore()

    func requestAccess() async throws {
        if #available(macOS 14.0, *) {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return
            case .notDetermined, .writeOnly:
                guard try await store.requestFullAccessToEvents() else { throw TodoManagementError.calendarDenied }
            default: throw TodoManagementError.calendarDenied
            }
        } else {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .authorized: return
            case .notDetermined:
                guard try await store.requestAccess(to: .event) else { throw TodoManagementError.calendarDenied }
            default: throw TodoManagementError.calendarDenied
            }
        }
    }

    private var hasCalendarAccess: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) { return status == .fullAccess }
        return status == .authorized
    }

    func calendars() throws -> [TodoCalendarOption] {
        guard hasCalendarAccess else { throw TodoManagementError.calendarDenied }
        return store.calendars(for: .event).filter(\.allowsContentModifications)
            .map { TodoCalendarOption(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func upsert(identifier: String?, calendarID: String?, title: String, start: Date, end: Date, isAllDay: Bool) throws -> TodoCalendarLink {
        guard hasCalendarAccess else { throw TodoManagementError.calendarDenied }
        guard end > start else { throw TodoManagementError.invalidTimeRange }
        let existing = identifier.flatMap { store.event(withIdentifier: $0) }
        let event = existing ?? EKEvent(eventStore: store)
        if let calendarID {
            guard let calendar = store.calendar(withIdentifier: calendarID), calendar.allowsContentModifications else {
                throw TodoManagementError.calendarUnavailable
            }
            event.calendar = calendar
        } else if existing == nil {
            event.calendar = store.defaultCalendarForNewEvents
        }
        guard let calendar = event.calendar, calendar.allowsContentModifications else { throw TodoManagementError.calendarUnavailable }
        event.title = title
        event.isAllDay = isAllDay
        event.timeZone = isAllDay ? nil : .autoupdatingCurrent
        event.startDate = start
        event.endDate = end
        try store.save(event, span: .thisEvent, commit: true)
        guard let id = event.eventIdentifier else { throw TodoManagementError.calendarUnavailable }
        return TodoCalendarLink(identifier: id, created: existing == nil)
    }

    func removeCreatedEvent(identifier: String) throws {
        if let event = store.event(withIdentifier: identifier) {
            try store.remove(event, span: .thisEvent, commit: true)
        }
    }
}
