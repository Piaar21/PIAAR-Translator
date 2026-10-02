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

@MainActor
struct ProfileView: View {
    @ObservedObject var model: FriendsViewModel
    @StateObject private var cloud = CloudAccountDiagnostics()
    @State private var editingName = false
    @State private var nameDraft = ""
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: WorkDesign.sectionSpacing) {
            profileContent
            HStack(spacing: 10) {
                Text("iCloud").font(WorkDesign.secondary).foregroundStyle(.secondary)
                Text(cloud.isChecking ? "확인 중…" : cloud.state.label).font(WorkDesign.secondary)
                    .help(cloud.state.detail ?? cloud.state.label)
                Spacer()
                Button("다시 확인") { Task { await cloud.refresh() } }
                    .buttonStyle(.plain).font(WorkDesign.secondary).foregroundStyle(.secondary)
                    .disabled(cloud.isChecking)
            }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            Spacer()
        }.padding(WorkDesign.padding).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(WorkDesign.contentBackground)
            .task {
                cloud.startMonitoring()
                async let accountCheck: Void = cloud.refresh()
                await model.load()
                await accountCheck
            }
            .onDisappear { cloud.stopMonitoring() }
    }
    @ViewBuilder private var profileContent: some View {
        if let profile = model.profile {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("내 프로필").font(WorkDesign.title)
                    Spacer()
                }
                if editingName {
                    HStack {
                        TextField("이름", text: $nameDraft).textFieldStyle(.roundedBorder)
                        Button("취소") { editingName = false }
                        Button("저장") {
                            Task { if await model.saveDisplayName(nameDraft) { editingName = false } }
                        }
                    }.disabled(model.isBusy)
                } else {
                    HStack {
                        Text(profile.displayName).font(WorkDesign.todo)
                        Spacer()
                        Button("이름 수정") { nameDraft = profile.displayName; editingName = true }
                            .disabled(model.isBusy)
                    }
                }
                HStack(spacing: 12) {
                    Text(profile.friendCode.displayValue).font(.callout).textSelection(.enabled)
                    Button("코드 복사") {
                        NSPasteboard.general.clearContents()
                        copied = NSPasteboard.general.setString(profile.friendCode.displayValue, forType: .string)
                    }
                    if copied { Text("복사됨").font(.caption).foregroundStyle(.secondary) }
                }
            }
        } else { ProgressView("프로필 불러오는 중…") }
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
