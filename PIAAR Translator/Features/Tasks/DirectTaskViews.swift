import SwiftUI

struct DirectTaskSheet: View {
    @ObservedObject var model: TaskDeliveryModel
    let finished: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: WorkDesign.sectionSpacing) {
            Text(model.fixedReceiver ? "\(model.receiver?.displayName ?? "친구")에게 할 일 보내기" : "친구에게 할 일 보내기").font(WorkDesign.title)
            if !model.fixedReceiver {
                Picker("받는 사람", selection: Binding(get: { model.receiver?.userID }, set: { id in model.receiver = model.friends.first { $0.userID == id } })) {
                    Text("친구 선택").tag(Optional<UUID>.none)
                    ForEach(model.friends) { friend in Text(friend.displayName).tag(Optional(friend.userID)) }
                }
                if !model.isLoading && model.friends.isEmpty { Text("전달할 친구가 없습니다.").font(.caption).foregroundStyle(.secondary) }
            }
            if model.source != nil {
                Text(model.title).font(WorkDesign.todo)
                Text("원본 할 일은 그대로 유지됩니다.").font(.caption).foregroundStyle(.secondary)
            } else {
                TextField("할 일을 입력하세요", text: $model.title).textFieldStyle(.roundedBorder).focused($focused)
            }
            HStack {
                Text("마감일").font(WorkDesign.secondary)
                Spacer()
                if let date = model.deadline {
                    DatePicker("", selection: Binding(get: { date }, set: { model.deadline = $0 }), displayedComponents: .date).labelsHidden()
                    if model.source == nil { Button("해제") { model.deadline = nil }.buttonStyle(.plain) }
                } else if model.source == nil {
                    Button("선택 안 함") { model.deadline = Date() }.buttonStyle(.plain).foregroundStyle(.secondary)
                } else { Text("선택 안 함").foregroundStyle(.secondary) }
            }.disabled(model.source != nil)
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("취소") { model.invalidate(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if model.isSending { ProgressView().controlSize(.small) }
                Button("전달") { Task { if await model.send() { await finished(); dismiss() } } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.receiver == nil || model.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.workSheet().frame(width: 370).disabled(model.isSending).interactiveDismissDisabled(model.isSending)
            .task { if !model.fixedReceiver { await model.loadFriends() }; focused = model.source == nil }
    }
}
struct ServerTaskHistoryView: View {
    @ObservedObject var model: TaskWorkspaceModel
    let task: WorkTask
    @State private var entries: [TaskHistoryEvent] = []
    @State private var error: String?
    @State private var loading = true
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(task.title).font(WorkDesign.title)
            if loading { ProgressView().controlSize(.small) }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary); Button("다시 시도") { Task { await load() } } }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !loading && error == nil && entries.isEmpty { Text("활동 기록이 없습니다.").foregroundStyle(.secondary) }
                    ForEach(entries) { event in
                        HStack(alignment: .top) {
                            Text(event.createdAt, format: .dateTime.month().day().hour().minute()).foregroundStyle(.secondary)
                            Text(event.summary)
                        }.font(.callout)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 300)
            HStack { Spacer(); Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.workSheet().frame(width: 420).task { await load() }
    }
    private func load() async {
        loading = true; defer { loading = false }
        do { entries = try await model.loadHistory(taskID: task.id); error = nil }
        catch { self.error = "활동 기록을 불러오지 못했습니다. 다시 시도해주세요." }
    }
}
