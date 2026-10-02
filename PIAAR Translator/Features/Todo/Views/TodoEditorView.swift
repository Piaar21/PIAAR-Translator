import SwiftUI

struct TodoEditorView: View {
    @ObservedObject var model: TodoViewModel
    @State private var session: TodoEditorSession
    @State private var focusRevision = 1
    @State private var repeatOpen = false
    @State private var deadlineOpen = false
    @State private var groupOpen = false
    @State private var calendarOpen = false
    @State private var deleteConfirm = false
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    init(model: TodoViewModel, initial: TodoEditorSession) {
        self.model = model; _session = State(initialValue: initial)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: WorkDesign.sectionSpacing) {
            Text("할 일 수정").font(WorkDesign.title)
            TodoQuickInput(text: $session.draft.title, focusRevision: focusRevision, wantsFocus: true,
                           submit: save, cancel: { if !saving { dismiss() } },
                           newShortcut: { focusRevision += 1 }, placeholder: "할 일을 적어보세요").frame(height: WorkDesign.inputHeight)
            HStack(spacing: 6) {
                Menu("그룹") {
                    Button("그룹 없음") { session.draft.groupID = nil }
                    ForEach(model.groups) { group in
                        Button(group.name + (session.draft.groupID == group.id ? " ✓" : "")) { session.draft.groupID = group.id }
                    }
                    Divider()
                    Button("+ 새 그룹") { groupOpen = true }
                }.fixedSize().popover(isPresented: $groupOpen) {
                    TodoNewGroupView(model: model) { group in session.draft.groupID = group.id; groupOpen = false }
                }
                Button("반복") { repeatOpen = true }.popover(isPresented: $repeatOpen) {
                    TodoWeekdayPicker(weekdays: $session.weekdays)
                }
                Button("마감일") { deadlineOpen = true }.popover(isPresented: $deadlineOpen) {
                    TodoOptionalDeadlineView(session: $session, calendar: model.calendar)
                }
                Button(session.linkCalendar ? "✓ 캘린더" : "캘린더 연동") {
                    guard session.deadlineDay != nil else {
                        model.calendarError = TodoManagementError.deadlineRequired.localizedDescription
                        return
                    }
                    if session.linkCalendar { session.linkCalendar = false; return }
                    let preview = TodoSnapshot(id: session.todoID ?? session.id, title: session.draft.title,
                        notes: session.draft.notes, date: session.draft.date, isCompleted: false,
                        completedAt: nil, createdAt: Date(), updatedAt: Date(), sortOrder: 0,
                        groupID: session.draft.groupID, deadlineDate: session.deadlineDay,
                        startDateTime: session.start, deadlineDateTime: session.end)
                    Task {
                        if await model.loadCalendarOptions(for: preview) { calendarOpen = true }
                    }
                }.disabled(model.calendarBusy)
                    .popover(isPresented: $calendarOpen) {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("캘린더", selection: Binding(get: { session.calendarID ?? "" }, set: { session.calendarID = $0.isEmpty ? nil : $0 })) {
                                Text("기존 / 기본 캘린더").tag("")
                                ForEach(model.calendarOptions) { Text($0.title).tag($0.id) }
                            }
                            Text("할 일을 저장할 때 연동합니다.").font(.caption).foregroundStyle(.secondary)
                            Button("선택") { session.linkCalendar = true; calendarOpen = false }
                        }.padding(WorkDesign.padding).frame(width: 260)
                    }
            }.controlSize(.small)
            if let name = model.groups.first(where: { $0.id == session.draft.groupID })?.name {
                Text(name).font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.editorError { Text(error).font(.caption).foregroundStyle(.secondary) }
            HStack {
                if session.todoID != nil {
                    Button("삭제", role: .destructive) { deleteConfirm = true }.buttonStyle(.plain)
                }
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("저장", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!session.draft.hasTitle || saving)
            }
        }.padding(WorkDesign.padding).frame(width: 380)
            .onAppear { DispatchQueue.main.async { focusRevision += 1 } }
            .interactiveDismissDisabled(saving)
            .alert("캘린더 연동", isPresented: Binding(get: { model.calendarError != nil }, set: { if !$0 { model.calendarError = nil } })) {
                Button("확인") {
                    model.calendarError = nil
                    if session.deadlineDay == nil { DispatchQueue.main.async { deadlineOpen = true } }
                }
            } message: { Text(model.calendarError ?? "") }
            .alert("할 일을 삭제할까요?", isPresented: $deleteConfirm) {
                Button("취소", role: .cancel) {}
                Button("삭제", role: .destructive) {
                    if let id = session.todoID, model.deleteFullEditor(id) { dismiss() }
                }
            }
    }
    private func save() {
        guard !saving, session.draft.hasTitle, let item = model.saveFullEditor(session) else { return }
        // Preserve the saved identity if Calendar linking fails, so retry never inserts another Todo.
        session.todoID = item.id
        if session.linkCalendar {
            saving = true
            Task {
                let linked = await model.linkCalendar(item, calendarID: session.calendarID)
                saving = false
                if linked { dismiss() }
                else { model.calendarError = "할 일은 저장되었습니다.\n" + (model.calendarError ?? "캘린더 연동을 다시 시도해주세요.") }
            }
        } else { dismiss() }
    }
}

private struct TodoNewGroupView: View {
    @ObservedObject var model: TodoViewModel
    let created: (TodoGroupSnapshot) -> Void
    @State private var name = ""
    @State private var color = TodoGroupColors.palette[0]
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("새 그룹").font(.headline)
            TextField("그룹 이름", text: $name).focused($focused).onSubmit(add)
            Text("색상").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 9) {
                ForEach(TodoGroupColors.palette, id: \.self) { value in
                    Button { color = value } label: {
                        Circle().fill(TodoGroupColor.resolve(value)).frame(width: 22, height: 22)
                            .overlay(Circle().stroke(color == value ? Color.primary : Color.clear, lineWidth: 2).padding(-3))
                    }.buttonStyle(.plain).accessibilityLabel("그룹 색상 \(value)")
                }
            }
            if let error = model.editorError { Text(error).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("취소") { dismiss() }
                Spacer()
                Button("추가", action: add).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(WorkDesign.padding).frame(width: 260).onAppear { focused = true }
    }
    private func add() { if let group = model.createFullGroup(name: name, colorHex: color) { created(group) } }
}

private struct TodoWeekdayPicker: View {
    @Binding var weekdays: Set<Int>
    @Environment(\.dismiss) private var dismiss
    private let days: [(Int, String)] = [(2,"월"),(3,"화"),(4,"수"),(5,"목"),(6,"금"),(7,"토"),(1,"일")]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("반복 요일").font(.headline)
            HStack(spacing: 4) {
                ForEach(days, id: \.0) { day in
                    Toggle(day.1, isOn: Binding(get: { weekdays.contains(day.0) }, set: {
                        if $0 { weekdays.insert(day.0) } else { weekdays.remove(day.0) }
                    })).toggleStyle(.button)
                }
            }
            HStack {
                Button("반복 없음") { weekdays = []; dismiss() }
                Spacer()
                Button("확인") { dismiss() }
            }
        }.padding(WorkDesign.padding).frame(width: 290)
    }
}

private struct TodoOptionalDeadlineView: View {
    @Binding var session: TodoEditorSession
    let calendar: Calendar
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TodoDeadlineDraft
    @State private var error: String?

    init(session: Binding<TodoEditorSession>, calendar: Calendar) {
        _session = session
        self.calendar = calendar
        _draft = State(initialValue: TodoDeadlineDraft(session: session.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("마감일").font(.headline)
            DatePicker("마감 날짜", selection: $draft.day, displayedComponents: .date).datePickerStyle(.graphical)
            TodoOptionalTimeRow(title: "시작 시간", selection: $draft.start, day: draft.day, defaultHour: 9, calendar: calendar)
            TodoOptionalTimeRow(title: "마감 시간", selection: $draft.end, day: draft.day, defaultHour: 18, calendar: calendar)
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("지우기") {
                    session.deadlineDay = nil; session.start = nil; session.end = nil
                    session.linkCalendar = false
                    dismiss()
                }
                Spacer()
                Button("저장") {
                    do { try draft.apply(to: &session, calendar: calendar); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
        }.padding(WorkDesign.padding).frame(width: 280)
    }
}

private struct TodoOptionalTimeRow: View {
    let title: String
    @Binding var selection: Date?
    let day: Date
    let defaultHour: Int
    let calendar: Calendar
    @State private var isOpen = false

    var body: some View {
        Button { isOpen = true } label: {
            HStack {
                Text(title)
                Spacer()
                Text(selection.map { $0.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) } ?? "미정")
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: 28).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .popover(isPresented: $isOpen) {
                TodoTimePicker(title: title, selection: $selection,
                    initial: selection ?? calendar.date(bySettingHour: defaultHour, minute: 0, second: 0, of: day) ?? day)
            }
    }
}

private struct TodoTimePicker: View {
    let title: String
    @Binding var selection: Date?
    @State private var time: Date
    @Environment(\.dismiss) private var dismiss

    init(title: String, selection: Binding<Date?>, initial: Date) {
        self.title = title; _selection = selection
        _time = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            DatePicker("시간", selection: $time, displayedComponents: .hourAndMinute)
                .datePickerStyle(.field).labelsHidden()
            HStack {
                Button("미정으로 설정") { selection = nil; dismiss() }
                Spacer()
                Button("선택") { selection = time; dismiss() }
            }
        }.padding(WorkDesign.padding).frame(width: 240)
    }
}
