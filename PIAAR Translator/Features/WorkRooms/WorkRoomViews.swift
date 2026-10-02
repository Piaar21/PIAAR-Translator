import SwiftUI

struct CreateWorkRoomView: View {
    @ObservedObject var model: WorkRoomsViewModel
    let created: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var invited: Set<UUID> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("업무방 만들기").font(WorkDesign.title)
            TextField("업무방 이름", text: $name).textFieldStyle(.roundedBorder)
            Text("멤버").font(WorkDesign.section)
            Text("나는 자동으로 참여합니다.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.friends) { friend in
                        Toggle(friend.user.displayName, isOn: Binding(get: { invited.contains(friend.user.id) }, set: {
                            if $0 { invited.insert(friend.user.id) } else { invited.remove(friend.user.id) }
                        }))
                    }
                    if model.friends.isEmpty { Text("친구를 추가하면 멤버로 초대할 수 있습니다.").foregroundStyle(.secondary) }
                }
            }.frame(maxHeight: 180)
            if let error = model.errorMessage { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("만들기") {
                    Task { if let id = await model.createRoom(name: name, invited: invited) { dismiss(); created(id) } }
                }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(WorkDesign.padding).frame(width: 380).disabled(model.isBusy)
            .task { await model.loadSidebar() }
    }
}

struct WorkRoomView: View {
    @ObservedObject var model: WorkRoomsViewModel
    let roomID: UUID
    let archived: () -> Void
    @State private var membersOpen = false
    @State private var addGroupOpen = false
    @State private var editingGroup: RoomGroup?
    @State private var archiveConfirmation = false
    var body: some View {
        VStack(alignment: .leading, spacing: WorkDesign.sectionSpacing) {
            if let room = model.selectedRoom, room.id == roomID {
                HStack {
                    Text(room.name).font(WorkDesign.title)
                    Spacer()
                    if model.canManageMembers {
                        Menu {
                            Button("업무방 보관") { archiveConfirmation = true }
                        } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 28, height: 28) }.menuStyle(.borderlessButton).fixedSize()
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.members.map(\.displayNameSnapshot).joined(separator: " · ")).font(.callout)
                    }
                    Spacer()
                    if model.canManageMembers { Button("멤버 관리") { membersOpen = true }.buttonStyle(.plain).font(WorkDesign.secondary).foregroundStyle(.secondary) }
                }
                if let error = model.errorMessage { Text(error).font(.callout).foregroundStyle(.red) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: WorkDesign.sectionSpacing) {
                        ForEach(model.sections) { section in
                            RoomTaskSectionView(model: model, section: section, editGroup: { editingGroup = $0 })
                        }
                        Button { addGroupOpen = true } label: { Label("그룹 추가", systemImage: "plus") }
                            .buttonStyle(.plain)
                    }.padding(.vertical, 4)
                }
            } else {
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
                else { ProgressView("업무방 불러오는 중…") }
                Spacer()
            }
        }.padding(WorkDesign.padding).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(WorkDesign.contentBackground)
            .task(id: roomID) { await model.loadRoom(roomID) }
            .sheet(isPresented: $membersOpen) { RoomMembersView(model: model) }
            .sheet(isPresented: $addGroupOpen) { RoomGroupEditorView(model: model, group: nil) }
            .sheet(item: $editingGroup) { RoomGroupEditorView(model: model, group: $0) }
            .alert("업무방을 보관할까요?", isPresented: $archiveConfirmation) {
                Button("취소", role: .cancel) {}
                Button("보관") { Task { if await model.archive() { archived() } } }
            } message: { Text("Sidebar에서 숨겨지며 기존 업무와 기록은 유지됩니다.") }
    }
}

private struct RoomTaskSectionView: View {
    @ObservedObject var model: WorkRoomsViewModel
    let section: RoomTaskSection
    let editGroup: (RoomGroup) -> Void
    @State private var entering = false
    @State private var title = ""
    @State private var receiverID: UUID?
    @State private var requestID = UUID()
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: WorkDesign.innerSpacing) {
            HStack(spacing: 7) {
                Circle().fill(TodoGroupColor.resolve(section.group?.colorHex)).frame(width: 7, height: 7)
                Text(section.group?.name ?? "그룹 없음").font(WorkDesign.section)
                Text("\(section.tasks.count)개").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let group = section.group {
                    Menu {
                        Button("그룹 이름 변경") { editGroup(group) }
                        Button("그룹 삭제", role: .destructive) { Task { await model.deleteGroup(group) } }
                    } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 28, height: 28) }.menuStyle(.borderlessButton).fixedSize()
                }
            }
            ForEach(section.tasks) { task in
                if task.receiverUserID == model.profile?.id {
                    Button { Task { await model.toggle(task) } } label: { taskRow(task) }
                        .buttonStyle(.plain).disabled(model.isBusy)
                } else { taskRow(task).help("\(task.receiverDisplayName)님의 할 일입니다.") }
            }
            if entering {
                HStack(spacing: 8) {
                    TextField("할 일을 입력하세요...", text: $title).textFieldStyle(.plain).focused($focused)
                        .frame(minWidth: 150, maxWidth: 290)
                        .onSubmit { submit() }
                        .onExitCommand { title = ""; focused = false; entering = false }
                    Menu {
                        ForEach(model.taskRecipients) { user in
                            Button(user.id == model.profile?.id ? "나" : user.displayName) { receiverID = user.id }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(receiverID == model.profile?.id ? "나" : model.taskRecipients.first { $0.id == receiverID }?.displayName ?? "나")
                            Image(systemName: "chevron.down").font(.system(size: 9))
                        }.font(WorkDesign.secondary).foregroundStyle(.secondary).padding(.horizontal, 8).frame(height: 28)
                    }.menuStyle(.borderlessButton).fixedSize()

                }.padding(.horizontal, 12).frame(height: WorkDesign.inputHeight).frame(maxWidth: 420, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: WorkDesign.radius))
                    .disabled(model.isBusy)
                    .onAppear { DispatchQueue.main.async { focused = true } }
            } else {
                HStack {
                    Button {
                        receiverID = model.profile?.id; title = ""; requestID = UUID(); entering = true
                    } label: { Image(systemName: "plus").frame(width: 28, height: 24) }.buttonStyle(.plain)
                    Spacer()
                }.padding(.leading, 28)
            }
        }
    }
    private func submit() {
        guard let receiverID, !model.isBusy else { return }
        Task {
            if await model.addTask(title: title, groupID: section.id, receiverID: receiverID, requestID: requestID) {
                title = ""; requestID = UUID(); self.receiverID = model.profile?.id
                DispatchQueue.main.async { focused = true }
            }
        }
    }
    private func taskRow(_ task: SharedTask) -> some View {
        TodoRowContent(presentation: TodoRowPresentation(title: task.title, isCompleted: task.isCompleted,
            direction: .none, personName: nil, deadlineText: model.sharedTasks.dDay(task)),
            color: TodoGroupColor.resolve(section.group?.colorHex),
            supplementalPerson: task.receiverUserID == model.profile?.id ? "나" : task.receiverDisplayName,
            allowsHover: task.receiverUserID == model.profile?.id)
    }

}

private struct RoomMembersView: View {
    @ObservedObject var model: WorkRoomsViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("멤버 관리").font(WorkDesign.title)
            ScrollView {
                VStack(alignment: .leading, spacing: WorkDesign.innerSpacing) {
                    Text("현재 멤버").font(WorkDesign.section)
                    ForEach(model.members) { member in
                        HStack {
                            Text(member.displayNameSnapshot); Spacer()
                            if member.userID != model.selectedRoom?.creatorUserID {
                                Button("제거") { Task { await model.removeMember(member.userID) } }
                            } else { Text("생성자").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    Divider()
                    Text("친구 추가").font(WorkDesign.section)
                    ForEach(model.availableFriends) { friend in
                        HStack {
                            Text(friend.user.displayName); Spacer()
                            Button("추가") { Task { await model.addMember(friend.user.id) } }
                        }
                    }
                    if model.availableFriends.isEmpty { Text("추가할 친구가 없습니다.").foregroundStyle(.secondary) }
                }
            }.frame(maxHeight: 300)
            if let error = model.errorMessage { Text(error).foregroundStyle(.red).font(.callout) }
            HStack { Spacer(); Button("확인") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(WorkDesign.padding).frame(width: 380).disabled(model.isBusy)
    }
}

private struct RoomGroupEditorView: View {
    @ObservedObject var model: WorkRoomsViewModel
    let group: RoomGroup?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var color = TodoGroupColors.palette[0]
    init(model: WorkRoomsViewModel, group: RoomGroup?) {
        self.model = model; self.group = group; _name = State(initialValue: group?.name ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(group == nil ? "그룹 추가" : "그룹 이름 변경").font(WorkDesign.title)
            TextField("그룹 이름", text: $name).textFieldStyle(.roundedBorder)
            if group == nil {
                HStack {
                    ForEach(TodoGroupColors.palette, id: \.self) { value in
                        Button { color = value } label: {
                            Circle().fill(TodoGroupColor.resolve(value)).frame(width: 22, height: 22)
                                .overlay(Circle().stroke(color == value ? Color.primary : Color.clear, lineWidth: 2))
                        }.buttonStyle(.plain).accessibilityLabel(value)
                    }
                }
            }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction); Spacer()
                Button("저장") {
                    Task {
                        let success: Bool
                        if let group { success = await model.renameGroup(group, name: name) }
                        else { success = await model.addGroup(name: name, color: color) }
                        if success { dismiss() }
                    }
                }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(WorkDesign.padding).frame(width: 340).disabled(model.isBusy)
    }
}
