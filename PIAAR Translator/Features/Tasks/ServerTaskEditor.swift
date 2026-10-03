import SwiftUI

struct ServerTaskEditor: View {
    @ObservedObject var model: TaskWorkspaceModel
    let task: WorkTask
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var day = Date()
    @State private var isSomeday = false
    @State private var group: UUID?
    @State private var timing = TaskDeadlineSelection()
    @State private var error: String?
    @State private var linkCalendar = false
    @State private var availableGroups: [TaskGroup] = []
    @State private var calendars: [TodoCalendarOption] = []
    @State private var calendarID: String?
    private var draft: TaskDraft {
        var value = timing.draft(title: title, day: day, group: group, original: task, calendar: model.calendar)
        value.isSomeday = isSomeday
        if isSomeday { value.scheduledAt = nil; value.dayPeriod = nil }
        else if task.scheduledDate != value.scheduleDay, let original = task.scheduledAt {
            let c = model.calendar.dateComponents([.hour, .minute], from: original)
            value.scheduledAt = model.calendar.date(bySettingHour: c.hour!, minute: c.minute!, second: 0, of: day, matchingPolicy: .strict, repeatedTimePolicy: .first, direction: .forward)
        }
        return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("할 일 수정").font(.headline)
            TextField("할 일", text: $title).textFieldStyle(.roundedBorder)
            Toggle("언젠가", isOn: $isSomeday).disabled(task.recurrenceID != nil || task.isRecurrenceTemplate)
            if !isSomeday { TaskDatePicker(selection: $day, calendar: model.calendar, label: "날짜").disabled(task.recurrenceID != nil || task.isRecurrenceTemplate) }
            Picker("그룹", selection: $group) {
                Text("그룹 없음").tag(UUID?.none)
                if let id = task.groupID, !availableGroups.contains(where: { $0.id == id }) {
                    Text(model.groups.first { $0.id == id }?.name ?? "현재 그룹").tag(Optional(id))
                }
                ForEach(availableGroups) { Text($0.name).tag(Optional($0.id)) }
            }
            Toggle("마감일", isOn: Binding(get: { timing.date != nil }, set: { timing.date = $0 ? day : nil }))
            if timing.date != nil {
                TaskDatePicker(selection: Binding(get: { timing.date ?? day }, set: { timing.date = $0 }), calendar: model.calendar, label: "마감일")
                TaskTimeRow(title: "시작 시간", selection: $timing.start, calendar: model.calendar, date: timing.date ?? day)
                TaskTimeRow(title: "마감 시간", selection: $timing.end, calendar: model.calendar, date: timing.date ?? day)
                Toggle("Calendar 연동", isOn: $linkCalendar).onChange(of: linkCalendar) { _, value in
                    guard value, let service = model.calendarService else { return }
                    Task { do { try await service.requestAccess(); calendars = try service.calendars() }
                           catch { self.error = error.localizedDescription; linkCalendar = false } }
                }
                if linkCalendar {
                    Picker("Calendar", selection: $calendarID) {
                        Text("기본 Calendar").tag(String?.none)
                        ForEach(calendars) { Text($0.title).tag(Optional($0.id)) }
                    }
                }
            }
            if let error = error ?? model.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Button("취소") { dismiss() }; Spacer(); Button("저장") { Task { await save() } }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWriting || !model.canEditContent(task)) }
        }.padding(24).frame(width: 380).task {
            do { availableGroups = if let id = task.spaceID { try await model.groupRepository.groups(spaceID: id) } else { model.groups } }
            catch { self.error = "그룹을 불러오지 못했습니다." }
        }.onChange(of: task) { _, latest in
            isSomeday = latest.scheduledDate == nil
            day = latest.scheduledDate?.date(calendar: model.calendar) ?? model.today
        }.onAppear {
            isSomeday = task.scheduledDate == nil; title = task.title; day = task.scheduledDate?.date(calendar: model.calendar) ?? model.today; group = task.groupID
            timing = TaskDeadlineSelection(date: task.deadlineDate?.date(calendar: model.calendar), start: task.startAt, end: task.deadlineAt)
        }
    }
    private func save() async {
        let value = draft
        if let start = value.startAt, let end = value.deadlineAt, end <= start { error = "마감시간은 시작시간 이후여야 합니다."; return }
        guard await model.save(task, draft: value) else { return }
        if linkCalendar, let links = model.calendarLinks, let service = model.calendarService {
            do {
                guard let updated = try await model.repository.fetchTask(id: task.id) else { throw TaskServiceError.notFound }
                try links.link(updated, calendar: model.calendar, service: service, calendarID: calendarID)
            } catch { self.error = "서버 저장은 완료되었습니다. Calendar 연동 실패: " + error.localizedDescription; return }
        }
        dismiss()
    }
}
