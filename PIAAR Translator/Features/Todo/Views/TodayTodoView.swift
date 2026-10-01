import SwiftUI
import AppKit

// Both windows observe the same model; no separate Mini storage or draft.
struct TodayTodoView: View {
    @ObservedObject var model: TodoViewModel
    let isMini: Bool
    var closeMini: () -> Void = {}
    @Environment(\.scenePhase) private var scenePhase
    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("오늘 할 일").font(.headline)
                if !isMini {
                    Text(model.todayDate.formatted(.dateTime.year().month().day()))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "plus").foregroundStyle(.secondary)
                TodoQuickInput(text: $model.quickTitle,
                               focusRevision: model.quickFocusRequest,
                               wantsFocus: model.quickWantsFocus,
                               submit: { _ = model.submitTodayQuickEntry() },
                               cancel: cancelInput,
                               newShortcut: model.requestQuickFocus)
                    .frame(height: 22)
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if model.todayItems.isEmpty {
                Text("오늘 할 일이 없습니다.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.top, 10)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.todayItems) { item in
                            TodoRowView(model: model, item: item, showMoreButton: false)
                        }
                    }.padding(.vertical, 4)
                }
            }
        }
        .padding(isMini ? 18 : 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.refresh() }
        .onReceive(refreshTimer) { _ in model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in model.refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refresh() } }
    }

    private func cancelInput() {
        let hadText = !model.quickTitle.isEmpty
        model.cancelQuickEntry()
        if isMini {
            if hadText { model.requestQuickFocus() }
            else { closeMini() }
        }
    }
}
