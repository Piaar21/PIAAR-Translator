import SwiftUI
import AppKit

struct ServerFriendsView: View {
    var sendTask: ((Friend) -> Void)? = nil
    var deliveryNotice: String? = nil
    @ObservedObject var model: ServerFriendsViewModel
    @State private var friendToRemove: Friend?
    var body: some View {
        VStack(alignment: .leading, spacing: WorkDesign.sectionSpacing) {
            HStack {
                Text("친구").font(WorkDesign.title)
                Spacer()
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise").frame(width: 30, height: 30) }
                    .buttonStyle(.plain).help("새로고침").disabled(model.isBusy)
                Button { model.beginAddingFriend() } label: { Image(systemName: "plus").frame(width: 30, height: 30).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor).help("친구 추가").disabled(model.isBusy)
            }
            if let deliveryNotice { Text(deliveryNotice).font(.caption).foregroundStyle(.secondary) }
            WorkSearchField(text: $model.searchQuery)
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !model.incoming.isEmpty {
                        HStack { Text("받은 요청"); Spacer(); Text("\(model.incoming.count)").foregroundStyle(.secondary) }.font(WorkDesign.section)
                        ForEach(model.incoming) { entry in
                            HStack {
                                person(entry.person.displayName, entry.person.friendCode)
                                Spacer()
                                Button("거절") { Task { await model.reject(entry.id) } }
                                Button("수락") { Task { await model.accept(entry.id) } }.tint(.accentColor)
                            }.frame(minHeight: 52).disabled(model.isBusy)
                        }
                    }
                    Text("친구 목록").font(WorkDesign.section).padding(.top, 8)
                    if model.loaded, model.friends.isEmpty {
                        WorkEmptyState(title: "아직 친구가 없습니다.", detail: "오른쪽 위 +로 친구를 추가할 수 있습니다.")
                    } else if model.loaded, model.filteredFriends.isEmpty {
                        WorkEmptyState(title: "검색 결과가 없습니다.")
                    }
                    ForEach(model.filteredFriends) { friend in
                        HStack {
                            person(friend.displayName, friend.friendCode); Spacer()
                            Menu {
                                if let sendTask { Button("업무 전달") { sendTask(friend) } }
                                Button("친구 삭제", role: .destructive) { friendToRemove = friend }
                            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                                .menuStyle(.borderlessButton).fixedSize().disabled(model.isBusy)
                        }.padding(.horizontal, 10).frame(minHeight: 52).modifier(WorkHoverSurface())
                    }
                    if !model.outgoing.isEmpty {
                        Text("요청 대기").font(WorkDesign.section).padding(.top, 12)
                        ForEach(model.outgoing) { entry in
                            person(entry.person.displayName, entry.person.friendCode).frame(minHeight: 44)
                        }
                    }
                }.padding(.vertical, 4)
            }
            if model.isBusy && !model.loaded { ProgressView().controlSize(.small) }
        }.padding(WorkDesign.padding).background(WorkDesign.contentBackground)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .task { await model.refresh() }
            .sheet(isPresented: $model.addingFriend) { ServerAddFriendView(model: model) }
            .alert("친구 삭제", isPresented: Binding(get: { friendToRemove != nil }, set: { if !$0 { friendToRemove = nil } })) {
                Button("취소", role: .cancel) { friendToRemove = nil }
                Button("삭제", role: .destructive) { if let friend = friendToRemove { Task { await model.remove(friend) } }; friendToRemove = nil }
            } message: { Text("\(friendToRemove?.displayName ?? "")님을 친구 목록에서 삭제할까요?") }
    }
    private func person(_ name: String, _ code: FriendCode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(WorkDesign.person)
            Text(code.displayValue).font(WorkDesign.secondary).foregroundStyle(.secondary)
        }
    }
}
private struct ServerAddFriendView: View {
    @ObservedObject var model: ServerFriendsViewModel
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: WorkDesign.sectionSpacing) {
            Text("친구 추가").font(WorkDesign.title)
            Text("친구 코드").font(WorkDesign.secondary).foregroundStyle(.secondary)
            TextField("#XXXXXXXX", text: $model.codeInput).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { Task { await model.findUser() } }
            if let user = model.candidate {
                VStack(alignment: .leading, spacing: 4) {
                    Text(user.displayName).font(WorkDesign.person)
                    Text(user.friendCode.displayValue).font(WorkDesign.secondary).foregroundStyle(.secondary)
                }
                switch model.relationship {
                case .available:
                    Button("친구 요청 보내기") { Task { await model.sendRequest() } }
                case .friend: Text("이미 친구입니다.").font(.callout)
                case .outgoing: Text(model.notice ?? "이미 친구 요청을 보냈습니다.").font(.callout)
                case .incoming(let request):
                    Text("\(user.displayName)님이 이미 친구 요청을 보냈습니다.").font(.callout)
                    Button("수락") { Task { await model.accept(request.id) } }
                case nil: EmptyView()
                }
            }
            if let error = model.searchError { Text(error).font(.caption).foregroundStyle(.red) }
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("취소") { model.cancelAddingFriend() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("찾기") { Task { await model.findUser() } }.keyboardShortcut(.defaultAction)
                    .disabled(model.codeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.workSheet().frame(width: 350).disabled(model.isBusy).interactiveDismissDisabled(model.isBusy)
            .onAppear { focused = true }
    }
}
