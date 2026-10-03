import SwiftUI

// Presentation state only; selecting a date never waits for a repository request.
struct TaskCalendarPresentation {
    var month = Date()
    var selected = Date()
    var isPresented = false
    mutating func open(selected: Date) { self.selected = selected; month = selected; isPresented = true }
    mutating func choose(_ date: Date) { selected = date; isPresented = false }
}
struct TaskDeadlineSelection {
    var date: Date?
    var start: Date?
    var end: Date?
    func draft(title: String, day: Date, group: UUID?, original: WorkTask, calendar: Calendar) -> TaskDraft {
        let deadline = date.map { TaskDay($0, calendar: calendar) }
        func time(_ value: Date?, originalTime: Date?) -> Date? {
            guard let value, let deadline else { return nil }
            return TaskDeadlineTiming.timestamp(value, day: deadline, originalDay: original.deadlineDate, originalTime: originalTime, calendar: calendar)
        }
        return TaskDraft(title: title, scheduledDate: TaskDay(day, calendar: calendar), groupID: group,
            deadlineDate: deadline, startAt: time(start, originalTime: original.startAt),
            deadlineAt: time(end, originalTime: original.deadlineAt), notes: original.notes,
            scheduledAt: original.scheduledAt, dayPeriod: original.dayPeriod, estimatedMinutes: original.estimatedMinutes, priority: original.priority, isSomeday: original.scheduledDate == nil, expectedSchedule: TaskScheduleExpectation(original))
    }
}

struct TaskDatePicker: View {
    @Binding var selection: Date
    let calendar: Calendar
    var today = Date()
    var overdueDays: Set<Date> = []
    var headline = false
    var label: String? = nil
    var monthChanged: (Date) -> Void = { _ in }
    @State private var presentation = TaskCalendarPresentation()
    var body: some View {
        Button { presentation.open(selected: selection) } label: {
            HStack(spacing: 8) {
                if let label { Text(label); Spacer() }
                Text(selection.formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "ko_KR"))))
                    .font(headline ? .system(size: 21, weight: .semibold) : .body)
                if !overdueDays.isEmpty { Circle().fill(Color.red).frame(width: 6, height: 6) }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 8).frame(minHeight: 44).contentShape(Rectangle())
                .modifier(WorkHoverSurface())
        }.buttonStyle(.plain).popover(isPresented: $presentation.isPresented) {
            VStack(spacing: 12) {
                TodoMonthView(month: $presentation.month, selected: selection, today: today,
                    overdueDays: overdueDays, calendar: calendar) { choose($0) }
                Button("오늘") { choose(calendar.startOfDay(for: today)) }
            }.padding(16).frame(width: 330)
                .environment(\.calendar, calendar).environment(\.timeZone, calendar.timeZone)
        }.onChange(of: presentation.month) { _, value in monthChanged(value) }
    }
    private func choose(_ date: Date) {
        presentation.choose(date)
        selection = presentation.selected
    }
}

struct TaskTimeRow: View {
    let title: String
    @Binding var selection: Date?
    let calendar: Calendar
    let date: Date
    @State private var open = false
    @State private var editing = Date()
    var body: some View {
        Button { editing = selection ?? Date(); open = true } label: {
            HStack {
                Text(title); Spacer()
                Text(selection.map { timeText($0) } ?? "미정").foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 8).frame(height: 44).contentShape(Rectangle())
                .modifier(WorkHoverSurface())
        }.buttonStyle(.plain).popover(isPresented: $open) {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.headline)
                DatePicker("시간", selection: $editing, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.stepperField).controlSize(.large)
                HStack(spacing: 6) {
                    Button("지금") { apply(Date()) }
                    ForEach([9, 12, 15, 18], id: \.self) { hour in
                        Button(String(format: "%02d:00", hour)) {
                            if let value = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) { apply(value) }
                        }
                    }
                }.controlSize(.small)
                Button("미정으로 설정") { selection = nil; open = false }
                Button { apply(editing) } label: { Text("적용").frame(maxWidth: .infinity, minHeight: 44) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(20).frame(width: 320)
                .environment(\.calendar, calendar).environment(\.timeZone, calendar.timeZone)
        }
    }
    private func apply(_ value: Date) { selection = value; open = false }
    private func timeText(_ value: Date) -> String {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "HH:mm"
        return f.string(from: value)
    }
}
