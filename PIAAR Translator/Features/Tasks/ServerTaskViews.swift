import SwiftUI
import AppKit

struct ServerTasksView: View {
    enum Page { case mine, received, sent }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: TaskWorkspaceModel
    var page: Page = .mine
    var mini = false
    var closeMini: () -> Void = {}
    var migration: LegacyTaskMigration? = nil
    @State private var historyTask: WorkTask?
    @State private var selectedReceiver: UUID?
    @State private var showMembers = false
    @State private var confirmArchive = false
    var closeSpace: () -> Void = {}
    @State private var groupInput: UUID?
    @State private var addingUngrouped = false
    @State private var groupTitle = ""
    @State private var groupEditing: TaskGroup?
    @State private var creatingGroup = false
    @State private var quickFocused = false
    @State private var showMigration = false
    @State private var showSomeday = false
    @State private var organize = false
    private var rows: [WorkTask] {
        if showSomeday { return model.someday }
        switch page {
        case .mine: return mini ? model.todayTasks : model.assigned
        case .received: return model.received
        case .sent: return mini ? model.todaySent : model.sent
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: mini ? 14 : WorkDesign.sectionSpacing) {
            header
            if page == .mine && !showSomeday { quickInput.disabled(!model.spaceWritable) }
            if let error = model.errorMessage {
                HStack { Text(error).font(.caption).foregroundStyle(.secondary); Button("다시 시도") { Task { await model.refresh() } } }
            }
            if let notice = model.deliveryNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            if let notice = model.historyNotice {
                HStack { Text(notice).font(.caption).foregroundStyle(.secondary); Button("기록 재시도") { Task { await model.retryEvents() } } }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: mini ? 12 : WorkDesign.sectionSpacing) {
                    if mini || page != .mine {
                        if rows.isEmpty, model.loaded { Text(page == .sent ? "보낸 업무가 없습니다." : "할 일이 없습니다.").font(.subheadline).foregroundStyle(.secondary) }
                        ForEach(rows) { row($0) }
                    } else {
                        ForEach(model.groups) { section($0) }
                        section(nil)
                        if !showSomeday, model.spaceID == nil, !model.deferredTasks.isEmpty, model.calendar.isDateInToday(model.selectedDate) {
                            HStack {
                                Text("미룬 일 \(model.deferredTasks.count)").font(WorkDesign.section).foregroundStyle(.secondary)
                                Spacer(); Button("정리하기") { organize = true }.buttonStyle(.plain)
                            }
                            ForEach(model.deferredTasks) { row($0) }
                        }
                    }
                }.padding(.vertical, 4)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: rows.map(\.id))
            }
            .overlay(alignment: .topTrailing) {
                if model.isLoading && !model.loaded { ProgressView().controlSize(.small).frame(width: 16, height: 16).allowsHitTesting(false) }
            }
            if !mini, page == .mine, let migration {
                MigrationSummaryView(model: migration, open: { showMigration = true })
            }
        }.padding(mini ? 18 : WorkDesign.padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(mini ? Color(nsColor: .windowBackgroundColor) : WorkDesign.contentBackground)
            .environment(\.workFullRows, !mini)
            .task { await model.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await model.refresh() } }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in Task { await model.refresh() } }
            .onChange(of: model.selectedDate) { _ in Task { await model.refresh() } }
            .sheet(isPresented: $organize) { DeferredTaskOrganizer(model: model) }
            .sheet(isPresented: $showMembers) { SpaceMembersView(model: model) }
            .alert("업무방 보관", isPresented: $confirmArchive) {
                Button("취소", role: .cancel) {}
                Button("보관") { Task { if await model.archiveSpace() { closeSpace() } } }
            } message: { Text("기존 기록은 보존되며, 보관 후에는 이 업무방을 변경할 수 없습니다.") }
            .sheet(item: $model.delivery) { composer in DirectTaskSheet(model: composer, finished: { await model.deliveryFinished() }) }
            .sheet(item: $historyTask) { task in ServerTaskHistoryView(model: model, task: task) }
            .sheet(item: $model.editor) { task in ServerTaskEditor(model: model, task: task) }
            .sheet(isPresented: $creatingGroup) { ServerGroupEditor(model: model, group: nil) }
            .sheet(item: $groupEditing) { group in ServerGroupEditor(model: model, group: group) }
            .sheet(isPresented: $showMigration) { if let migration { MigrationConsentView(model: migration, refresh: { await model.refresh() }) } }
    }
    @ViewBuilder private var header: some View {
        if model.spaceID != nil {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(model.currentSpace?.name ?? "업무방").font(WorkDesign.title)
                    Spacer()
                    Button { showMembers = true } label: { Label("멤버 \(model.participants.count)명", systemImage: "person.2") }.buttonStyle(.plain)
                    Menu {
                        Button("새 그룹") { creatingGroup = true }.disabled(!model.spaceWritable)
                        Button("새로고침") { Task { await model.refresh(); await model.onSpaceChange?() } }
                        if model.isSpaceCreator { Button("업무방 보관") { confirmArchive = true }.disabled(!model.spaceWritable) }
                    } label: { Image(systemName: "ellipsis").frame(width: 36, height: 36) }.menuStyle(.borderlessButton).fixedSize()
                }
            }
        } else {
        HStack {
            if mini { Text(page == .sent ? "보낸 업무" : "오늘 할 일").font(.headline) }
            else {
                if showSomeday { Text("언젠가").font(WorkDesign.title) } else {
                TaskDatePicker(selection: $model.selectedDate, calendar: model.calendar, today: model.today,
                    overdueDays: model.overdueDays, headline: true, monthChanged: { value in
                        model.calendarMonth = value; Task { await model.refresh() }
                    })
                }
            }
            Spacer()
            if mini || page != .mine {
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise").frame(width: 30, height: 30) }.buttonStyle(.plain).help("새로고침")
            }
            if !mini, page == .mine {
                Menu {
                    Button(showSomeday ? "날짜별 할 일" : "언젠가") { showSomeday.toggle() }
                    Button("그룹 만들기") { creatingGroup = true }
                    Button("새로고침") { Task { await model.refresh() } }
                    if migration != nil { Button("기존 할 일 가져오기") { showMigration = true } }
                } label: { Image(systemName: "ellipsis").frame(width: 36, height: 36).contentShape(Rectangle()) }.menuStyle(.borderlessButton).fixedSize()
            }
        }
        }
    }

    private var quickInput: some View {
        VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
            Image(systemName: "plus").foregroundStyle(mini ? Color.secondary : .accentColor)
            TodoQuickInput(text: $model.quickTitle, focusRevision: model.focusRevision, wantsFocus: model.wantsFocus && groupInput == nil && !addingUngrouped,
                submit: { Task { if await model.add(mini: mini), mini { closeMini() } } }, cancel: {
                    let hadText = !model.quickTitle.isEmpty; model.cancelInput()
                    if mini { if hadText { model.requestFocus() } else { closeMini() } }
                }, newShortcut: model.requestFocus, placeholder: "할 일을 적어보세요", focusChanged: { quickFocused = $0 }, submitContinuously: { Task { await model.add(mini: mini) } })
                .frame(height: mini ? 22 : WorkDesign.inputHeight)
        }.padding(.horizontal, mini ? 0 : 12)
            .contentShape(Rectangle()).onTapGesture { model.requestFocus() }
            .background(!mini ? (quickFocused ? Color.accentColor.opacity(0.065) : WorkDesign.softControl) : Color.clear,
                        in: RoundedRectangle(cornerRadius: WorkDesign.radius))
        QuickAddPreview(result: model.parseQuickAdd(model.quickTitle, mini: mini))
        }
    }
    private func section(_ group: TaskGroup?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Circle().fill(TodoGroupColor.resolve(group?.colorHex)).frame(width: 7, height: 7)
                Text(group?.name ?? "그룹 없음").font(WorkDesign.section)
                if model.spaceID != nil { Text("\(rows.filter { $0.groupID == group?.id }.count)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let group, model.canManageGroup(group) {
                    Menu {
                        Button("그룹 수정") { groupEditing = group }
                        if model.spaceID == nil {
                            Button("위로 이동") { move(group, -1) }
                            Button("아래로 이동") { move(group, 1) }
                        }
                        Button("그룹 삭제", role: .destructive) { Task { await model.deleteGroup(group) } }
                    } label: { Image(systemName: "ellipsis").frame(width: 36, height: 36).contentShape(Rectangle()) }.menuStyle(.borderlessButton).fixedSize()
                }
            }
            ForEach(rows.filter { task in
                if let group { return task.groupID == group.id }
                return task.groupID == nil || !model.groups.contains { $0.id == task.groupID }
            }) { row($0) }
            if (group != nil && groupInput == group?.id) || (group == nil && addingUngrouped) {
                VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    TodoQuickInput(text: $groupTitle, focusRevision: model.focusRevision, wantsFocus: true, submit: {
                        let title = groupTitle, receiver = selectedReceiver ?? model.userID
                        Task { if await model.add(groupID: group?.id, title: title, receiverID: receiver) { groupTitle = ""; selectedReceiver = model.userID; groupInput = nil; addingUngrouped = false; model.requestFocus() } }
                    }, cancel: { groupInput = nil; addingUngrouped = false; groupTitle = "" }, newShortcut: model.requestFocus,
                    placeholder: "할 일을 입력하세요...", submitContinuously: {
                        let title = groupTitle, receiver = selectedReceiver ?? model.userID
                        Task { if await model.add(groupID: group?.id, title: title, receiverID: receiver) { groupTitle = ""; selectedReceiver = model.userID; model.requestFocus() } }
                    }).frame(height: WorkDesign.inputHeight)
                    if model.spaceID != nil {
                        Picker("담당자", selection: Binding(get: { selectedReceiver ?? model.userID }, set: { selectedReceiver = $0 })) {
                            ForEach(model.participants) { Text($0.name).tag($0.id) }
                        }.labelsHidden().frame(width: 110)
                    }
                }
                QuickAddPreview(result: model.parseQuickAdd(groupTitle))
                }.padding(.horizontal, 8).background(WorkDesign.softControl, in: RoundedRectangle(cornerRadius: WorkDesign.radius)).disabled(!model.spaceWritable)
            } else {
                Button { groupInput = group?.id; addingUngrouped = group == nil; groupTitle = ""; selectedReceiver = model.userID; model.requestFocus() } label: {
                    Image(systemName: "plus").frame(width: 36, height: 36).contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.leading, 28).disabled(!model.spaceWritable)
            }
        }
    }
    private func move(_ group: TaskGroup, _ step: Int) {
        var ids = model.groups.map(\.id)
        guard let i = ids.firstIndex(of: group.id), ids.indices.contains(i + step) else { return }
        ids.swapAt(i, i + step); Task { await model.reorderGroups(ids) }
    }
    private var taskMenuLabel: some View {
        Image(systemName: "ellipsis").foregroundStyle(.secondary)
            .frame(width: 36, height: 36).contentShape(Rectangle())
    }
    private func row(_ task: WorkTask) -> some View {
        let permission = model.permission(for: task)
        return HStack(spacing: 8) {
            Button { Task { await model.toggle(task) } } label: {
                VStack(alignment: .leading, spacing: 2) {
                TodoRowContent(presentation: TodoRowPresentation(title: task.title, isCompleted: task.status == .completed,
                    direction: model.spaceID != nil || task.createdBy == task.assignedTo ? .none : (task.assignedTo == model.userID ? .received : .sent),
                    personName: model.spaceID == nil ? model.personName(for: task) : nil, deadlineText: model.deadlineText(task)),
                    color: TodoGroupColor.resolve(model.groups.first { $0.id == task.groupID }?.colorHex),
                    supplementalPerson: model.spaceID != nil ? model.relationshipText(task) : nil)
                if task.priority == .important { Text("중요").font(.caption).foregroundStyle(.secondary).padding(.leading, 28) }
                if let summary = DeferredTaskPresentation.summary(task, userID: model.userID, now: model.today, calendar: model.calendar) {
                    Text(summary).font(.caption).foregroundStyle(.secondary).padding(.leading, 28)
                }
                if model.spaceID == nil, let id = task.spaceID, let name = model.spaceNames[id] { Text(name).font(.caption).foregroundStyle(.secondary).padding(.leading, 28) }
                }
            }.buttonStyle(.plain).disabled(permission == .readOnly || model.isWriting)
            if !mini, permission == .edit {
                Menu {
                    Button("활동 기록") { historyTask = task }
                    if model.canEditContent(task) { Button("수정") { model.openEditor(task) } }
                    if model.canDeliver { Button("업무 전달") { model.beginDelivery(source: task) } }
                    if task.recurrenceID != nil { Button("반복 해제") { Task { await model.stopRepeating(task) } } }
                    if task.recurrenceID == nil && !task.isRecurrenceTemplate { Button("삭제", role: .destructive) { Task { await model.archive(task) } } }
                } label: { taskMenuLabel }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            if !mini, permission != .edit {
                Menu { Button("활동 기록") { historyTask = task } } label: {
                    taskMenuLabel
                }.menuStyle(.borderlessButton).fixedSize()
            }
        }
    }
}

private struct ServerGroupEditor: View {
    @ObservedObject var model: TaskWorkspaceModel
    let group: TaskGroup?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color = TodoGroupColors.palette[0]
    @State private var commandID = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(group == nil ? "그룹 만들기" : "그룹 수정").font(.headline)
            TextField("그룹 이름", text: $name).textFieldStyle(.roundedBorder)
            HStack { ForEach(TodoGroupColors.palette, id: \.self) { hex in
                Button { color = hex } label: { Circle().fill(TodoGroupColor.resolve(hex)).frame(width: 22, height: 22).overlay(Circle().stroke(color == hex ? Color.primary : .clear, lineWidth: 2)) }.buttonStyle(.plain)
            } }
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Button("취소") { dismiss() }; Spacer(); Button("저장") {
                Task { if let group { await model.renameGroup(group, name: name, color: color) }
                       else { await model.createGroup(name: name, color: color, id: commandID) }
                    if model.errorMessage == nil { dismiss() }
                }
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWriting) }
        }.padding(24).frame(width: 340).onAppear { name = group?.name ?? ""; color = group?.colorHex ?? TodoGroupColors.palette[0] }
    }
}
