import SwiftUI
import AppKit

struct FriendsView: View {
    @ObservedObject var model: FriendsViewModel
    @ObservedObject var sharedTasks: SharedTasksViewModel
    @State private var friendToSend: FriendEntry?
    @State private var sentFeedback = false
    @State private var friendToRemove: FriendEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: WorkDesign.sectionSpacing) {
            HStack {
                Text("친구").font(WorkDesign.title)
                Spacer()
                Button { model.beginAddingFriend() } label: {
                    Image(systemName: "plus").frame(width: 30, height: 30).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(Color.accentColor).help("친구 추가")
            }
            WorkSearchField(text: $model.searchQuery)
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Text("친구 목록").font(WorkDesign.section)
                Spacer()
                if sentFeedback { Text("전달됨").font(.caption).foregroundStyle(.secondary) }
            }
            if model.friends.isEmpty {
                WorkEmptyState(title: "아직 추가한 친구가 없습니다.", detail: "오른쪽 위 +로 동료를 추가해보세요.")
                Spacer()
            } else if model.filteredFriends.isEmpty {
                WorkEmptyState(title: "검색 결과가 없습니다.")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.filteredFriends) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.user.displayName).font(WorkDesign.person)
                            Text(entry.user.friendCode.displayValue).font(WorkDesign.secondary).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button("업무 전달") { sentFeedback = false; friendToSend = entry }
                            Button("친구 삭제", role: .destructive) { friendToRemove = entry }
                        } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 28, height: 28) }
                            .menuStyle(.borderlessButton).fixedSize().disabled(model.isBusy)
                    }.padding(.horizontal, 10).frame(minHeight: 52).modifier(WorkHoverSurface())
                        }
                    }
                }
            }
        }.padding(WorkDesign.padding).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(WorkDesign.contentBackground)
            .task { await model.load() }
            .sheet(isPresented: $model.addingFriend) { AddFriendView(model: model) }
            .sheet(item: $friendToSend) { entry in
                SendFriendTaskView(model: sharedTasks, friend: entry) { sentFeedback = true }
            }
            .alert("친구 삭제", isPresented: Binding(get: { friendToRemove != nil }, set: {
                if !$0 { friendToRemove = nil }
            })) {
                Button("취소", role: .cancel) { friendToRemove = nil }
                Button("삭제", role: .destructive) {
                    if let entry = friendToRemove { Task { await model.removeFriend(entry) } }
                    friendToRemove = nil
                }
            } message: {
                Text("\(friendToRemove?.user.displayName ?? "")님을 친구 목록에서 삭제할까요?")
            }
    }

}

private struct AddFriendView: View {
    @ObservedObject var model: FriendsViewModel
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: WorkDesign.sectionSpacing) {
            Text("친구 추가").font(WorkDesign.title)
            Text("친구 코드").font(WorkDesign.secondary).foregroundStyle(.secondary)
            TextField("친구 코드 입력...", text: $model.codeInput).textFieldStyle(.roundedBorder)
                .focused($focused).onSubmit(add)
            if let error = model.errorMessage { Text(error).font(WorkDesign.secondary).foregroundStyle(.red) }
            HStack {
                Button("취소") { model.cancelAddingFriend() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("추가", action: add).keyboardShortcut(.defaultAction)
                    .disabled(model.codeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.workSheet().frame(width: 330).disabled(model.isBusy)
            .onAppear { focused = true }
    }
    private func add() { Task { await model.addFriend() } }
}
