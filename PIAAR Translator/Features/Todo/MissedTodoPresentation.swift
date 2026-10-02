import Foundation

struct MissedTodoSection: Identifiable {
    let date: Date
    let personal: [TodoSnapshot]
    let shared: [SharedTask]
    var id: Date { date }
    var count: Int { personal.count + shared.count }
}

enum MissedTodoPresentation {
    static func sections(personal: [TodoSnapshot], assigned: [SharedTask], today: Date,
                         selectedDate: Date, calendar: Calendar) -> [MissedTodoSection] {
        guard calendar.isDate(selectedDate, inSameDayAs: today) else { return [] }
        let today = calendar.startOfDay(for: today)
        var seen = Set<UUID>()
        let shared = assigned.filter { !$0.isCompleted && seen.insert($0.id).inserted }
        return (1...3).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let interval = TodoDates.interval(for: day, calendar: calendar)
            let todos = personal.filter { !$0.isCompleted && $0.date >= interval.start && $0.date < interval.end }
            let tasks = shared.filter { $0.date >= interval.start && $0.date < interval.end }
            guard !todos.isEmpty || !tasks.isEmpty else { return nil }
            return MissedTodoSection(date: day, personal: TodoDates.sorted(todos), shared: tasks)
        }
    }
}
