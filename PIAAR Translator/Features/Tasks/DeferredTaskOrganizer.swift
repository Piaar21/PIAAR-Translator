import SwiftUI

struct DeferredTaskOrganizer: View {
    @ObservedObject var model: TaskWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var skipped: Set<UUID> = []
    @State private var chooseDate = false
    @State private var date = Date()
    @State private var confirmDelete = false
    private var current: WorkTask? { model.deferredTasks.first { !skipped.contains($0.id) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("미룬 일 정리").font(.headline); Spacer(); Button("닫기") { dismiss() }.disabled(model.isWriting) }
            if let task = current {
                Text(task.title).font(.title3)
                if let text = DeferredTaskPresentation.summary(task, userID: model.userID, now: model.today, calendar: model.calendar) {
                    Text(text).font(.caption).foregroundStyle(.secondary)
                }
                if model.canOrganize(task) {
                    HStack {
                        Button("오늘") { move(task, to: model.today) }
                        Button("내일") { if let day = model.calendar.date(byAdding: .day, value: 1, to: model.today) { move(task, to: day) } }
                        Button("날짜 변경") { date = task.scheduledDate?.date(calendar: model.calendar) ?? model.today; chooseDate = true }
                    }
                    HStack {
                        Button("언젠가") { Task { if await model.reschedule(task, date: nil) { skipped.insert(task.id) } } }
                        Button("삭제", role: .destructive) { confirmDelete = true }
                    }
                    if chooseDate {
                        TaskDatePicker(selection: $date, calendar: model.calendar, label: "날짜")
                        Button("날짜 적용") { move(task, to: date) }
                    }
                } else {
                    Text(task.recurrenceID != nil ? "반복 할 일은 완료 상태만 변경할 수 있습니다." : "받은 업무는 완료 상태만 변경할 수 있습니다.").font(.caption).foregroundStyle(.secondary)
                    Button("완료") { Task { await model.toggle(task) } }.disabled(model.permission(for: task) == .readOnly)
                }
                Button("다음") { skipped.insert(task.id); chooseDate = false }
            } else { Text("확인할 미룬 일이 없습니다.").foregroundStyle(.secondary) }
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(24).frame(width: 380).disabled(model.isWriting).interactiveDismissDisabled(model.isWriting)
            .alert("할 일을 삭제할까요?", isPresented: $confirmDelete) {
                Button("취소", role: .cancel) {}
                Button("삭제", role: .destructive) { if let task = current { Task { if await model.organizeArchive(task) { skipped.insert(task.id) } } } }
            }
    }
    private func move(_ task: WorkTask, to date: Date) {
        Task { if await model.reschedule(task, date: TaskDay(date, calendar: model.calendar)) { skipped.insert(task.id); chooseDate = false } }
    }
}
