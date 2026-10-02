import SwiftUI

struct SharedTasksView: View {
    @ObservedObject var model: SharedTasksViewModel
    let received: Bool
    @State private var historyTask: SharedTask?
    private var tasks: [SharedTask] { received ? model.received : model.sent }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkDesign.sectionSpacing) {
            Text(received ? "받은 업무" : "보낸 업무").font(WorkDesign.title)
            if let error = model.errorMessage { Text(error).font(.callout).foregroundStyle(.red) }
            if tasks.isEmpty {
                WorkEmptyState(title: received ? "아직 받은 업무가 없습니다." : "아직 보낸 업무가 없습니다.")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: WorkDesign.innerSpacing) {
                        ForEach([false, true], id: \.self) { completed in
                            let section = tasks.filter { $0.isCompleted == completed }
                            if !section.isEmpty {
                                Text(completed ? "완료" : "미완료").font(WorkDesign.section)
                                ForEach(section) { task in row(task) }
                            }
                        }
                    }
                }
            }
        }.padding(WorkDesign.padding).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(WorkDesign.contentBackground)
            .task { await model.load() }
            .sheet(item: $historyTask) { task in TaskHistoryView(model: model, task: task) }
    }

    private func row(_ task: SharedTask) -> some View {
        HStack(spacing: WorkDesign.innerSpacing) {
            if received {
                ReceivedTaskRow(model: model, task: task)
            } else {
                SentTaskRow(model: model, task: task)
                Button("기록") { historyTask = task }.buttonStyle(.plain).font(.caption)
            }
        }
    }


}

struct SendTaskView: View {
    @ObservedObject var model: SharedTasksViewModel
    let todo: TodoSnapshot
    let goToFriends: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var receiverID: UUID?
    @State private var requestID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: WorkDesign.sectionSpacing) {
            Text("업무 전달").font(WorkDesign.title)
            Text(todo.title)
            Text("받는 사람").font(WorkDesign.section)
            if model.recipients.isEmpty {
                Text("업무를 전달하려면 먼저 친구를 추가해주세요.").foregroundStyle(.secondary)
                Button("친구 화면으로 이동") { dismiss(); goToFriends() }
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.recipients) { entry in
                            Button { receiverID = entry.user.id } label: {
                                HStack {
                                    Image(systemName: receiverID == entry.user.id ? "largecircle.fill.circle" : "circle")
                                    Text(entry.user.displayName)
                                    Spacer()
                                    Text(entry.user.friendCode.displayValue).font(.caption).foregroundStyle(.secondary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxHeight: 180)
            }
            if let error = model.errorMessage { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("전달") {
                    guard let receiverID else { return }
                    Task {
                        if await model.send(SharedTaskDraft(todo: todo, id: requestID), receiverID: receiverID) { dismiss() }
                    }
                }.keyboardShortcut(.defaultAction).disabled(receiverID == nil || model.isBusy)
            }.disabled(model.isBusy)
        }.padding(WorkDesign.padding).frame(width: 400)
            .task { await model.load() }
    }
}

private struct TaskHistoryView: View {
    @ObservedObject var model: SharedTasksViewModel
    let task: SharedTask
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [TaskHistoryEntry] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("업무 기록").font(WorkDesign.title)
            Text(task.title)
            if let error { Text(error).foregroundStyle(.red) }
            ScrollView {
                VStack(alignment: .leading, spacing: WorkDesign.innerSpacing) {
                    ForEach(entries) { entry in
                        Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened) + " " + description(entry))
                            .font(.callout)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 260)
            HStack { Spacer(); Button("확인") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(WorkDesign.padding).frame(width: 440)
            .task {
                do { entries = try await model.history(for: task) }
                catch { self.error = error.localizedDescription }
            }
    }

    private func description(_ entry: TaskHistoryEntry) -> String {
        switch entry.action {
        case .created: return entry.actorDisplayName + " 생성"
        case .sent: return entry.actorDisplayName + " → " + task.receiverDisplayName + " 전달"
        case .completed: return entry.actorDisplayName + " 완료"
        case .reopened: return entry.actorDisplayName + " 미완료"
        }
    }
}

// Friend-fixed receiver, no source Todo, grouping, repeat, or Calendar metadata.
struct SendFriendTaskView: View {
    @ObservedObject var model: SharedTasksViewModel
    let friend: FriendEntry
    let sent: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var deadline: Date?
    @State private var choosingDeadline = false
    @State private var chosenDate = Date()
    @State private var requestID = UUID()
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: WorkDesign.sectionSpacing) {
            Text("\(friend.user.displayName)에게 업무 전달").font(WorkDesign.title)
            Text("할 일").font(WorkDesign.section)
            TextField("할 일을 입력하세요...", text: $title).textFieldStyle(.roundedBorder).focused($titleFocused)
            HStack {
                Text("마감일")
                Spacer()
                Button {
                    chosenDate = deadline ?? Date(); choosingDeadline = true
                } label: {
                    HStack {
                        Text(deadline?.formatted(date: .abbreviated, time: .omitted) ?? "없음")
                        Image(systemName: "chevron.right").font(.caption)
                    }
                }.popover(isPresented: $choosingDeadline) {
                    VStack(spacing: WorkDesign.innerSpacing) {
                        DatePicker("마감일", selection: $chosenDate, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                        HStack {
                            Button("없음") { deadline = nil; choosingDeadline = false }
                            Spacer()
                            Button("확인") { deadline = chosenDate; choosingDeadline = false }
                        }
                    }.padding(16)
                }
            }
            if let error = model.errorMessage { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("전달") {
                    Task {
                        if await model.sendNewTask(title: title, deadline: deadline,
                            receiverID: friend.user.id, requestID: requestID) {
                            sent(); dismiss()
                        }
                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(WorkDesign.padding).frame(width: 400).disabled(model.isBusy)
            .task { await model.load(); titleFocused = true }
    }
}

// The same completion-only interaction is used by inbox, Full, and Mini.
struct ReceivedTaskRow: View {
    @ObservedObject var model: SharedTasksViewModel
    let task: SharedTask
    var compact = false

    var body: some View {
        Button { Task { await model.toggle(task) } } label: {
            SharedTaskRowContent(model: model, task: task, received: true, compact: compact)

        }.buttonStyle(.plain).disabled(model.isBusy)
            .accessibilityLabel("\(task.title), 받은 업무, 보낸 사람 \(task.senderDisplayName)")
            .accessibilityValue(task.isCompleted ? "완료" : "미완료")
    }
}

struct ReceivedTasksDateSection: View {
    @ObservedObject var model: SharedTasksViewModel
    let date: Date
    let calendar: Calendar
    var body: some View {
        let tasks = model.assigned(on: date, calendar: calendar)
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: WorkDesign.innerSpacing) {
                HStack(spacing: 7) {
                    Text("받은 업무 · 업무방").font(WorkDesign.section)
                    Text("\(tasks.count)개").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(tasks) { task in ReceivedTaskRow(model: model, task: task) }
            }
        }
        if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
    }
}

struct SentTaskRow: View {
    @ObservedObject var model: SharedTasksViewModel
    let task: SharedTask
    var compact = false
    var body: some View {
        // Deliberately no Button or completion gesture for the sender.
        SharedTaskRowContent(model: model, task: task, received: false, compact: compact)
    }
}

private struct SharedTaskRowContent: View {
    @ObservedObject var model: SharedTasksViewModel
    let task: SharedTask
    let received: Bool
    let compact: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TodoRowContent(presentation: .shared(task, received: received, deadlineText: model.dDay(task)),
                           color: received ? .accentColor : .secondary)
            if let id = task.roomID, let name = model.roomNames[id] {
                Text(name).font(.caption).foregroundStyle(.secondary).padding(.leading, 28)
            }
        }
    }
}
