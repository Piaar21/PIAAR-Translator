import SwiftUI

struct CreateSpaceView: View {
    @ObservedObject var model: SpaceDirectoryModel
    let open: (UUID) -> Void
    @State private var name = ""
    @State private var selected: Set<UUID> = []
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: WorkDesign.sectionSpacing) {
            Text("업무방 만들기").font(WorkDesign.title)
            TextField("업무방 이름", text: $name).textFieldStyle(.roundedBorder).focused($focused).disabled(model.created != nil)
            Text("멤버 · 선택 사항").font(WorkDesign.secondary).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.friends.isEmpty { Text("혼자 업무방을 만들 수 있습니다.").foregroundStyle(.secondary) }
                    ForEach(model.friends) { friend in
                        Toggle(friend.displayName, isOn: Binding(get: { selected.contains(friend.userID) }, set: { if $0 { selected.insert(friend.userID) } else { selected.remove(friend.userID) } }))
                            .disabled(model.created != nil)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 180)
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("닫기") { model.creating = false; dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                if let space = model.created, !model.failedInvites.isEmpty {
                    Button("업무방 열기") { model.creating = false; open(space.id); dismiss() }
                    Button("초대 다시 시도") { Task { await create() } }
                } else {
                    Button("만들기") { Task { await create() } }.keyboardShortcut(.defaultAction)
                        .disabled((try? Space.validatedName(name)) == nil)
                }
            }
        }.workSheet().frame(width: 390).disabled(model.busy).interactiveDismissDisabled(model.busy)
            .task { await model.loadFriends(); focused = true }
    }
    private func create() async {
        if await model.create(name: name, selected: selected), let space = model.created {
            model.creating = false; open(space.id); dismiss()
        }
    }
}
struct SpaceMembersView: View {
    @ObservedObject var model: TaskWorkspaceModel
    @State private var removing: SpaceMember?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: WorkDesign.sectionSpacing) {
            Text("멤버").font(WorkDesign.title)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(model.participants) { person in
                        HStack {
                            Text(model.participantNames[person.id] ?? person.name)
                            Spacer()
                            if person.id == model.currentSpace?.createdBy { Text("생성자").font(.caption).foregroundStyle(.secondary) }
                            else if model.isSpaceCreator && model.spaceWritable,
                                    let member = model.spaceMembers.first(where: { $0.userID == person.id }) {
                                Menu { Button("내보내기", role: .destructive) { removing = member } }
                                label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }.menuStyle(.borderlessButton).fixedSize()
                            }
                        }
                    }
                }
            }.frame(maxHeight: 240)
            if model.isSpaceCreator && model.spaceWritable {
                Menu("친구 초대") {
                    if model.invitationFriends.isEmpty { Text("초대할 수 있는 친구가 없습니다.") }
                    ForEach(model.invitationFriends) { friend in Button(friend.displayName) { Task { await model.invite(friend) } } }
                }.disabled(model.isWriting)
            }
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.workSheet().frame(width: 360).interactiveDismissDisabled(model.isWriting)
            .task { await model.refresh(); await model.loadInvitationFriends() }
            .alert("멤버 내보내기", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button("취소", role: .cancel) { removing = nil }
                Button("내보내기", role: .destructive) { if let member = removing { Task { await model.removeMember(member) } }; removing = nil }
            } message: { Text("\(removing?.displayNameSnapshot ?? "")님을 업무방에서 내보낼까요? 기존 업무 기록은 보존됩니다.") }
    }
}
