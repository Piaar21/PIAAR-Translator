import SwiftUI

struct WorkMainView: View {
    @ObservedObject var navigation: WorkNavigationState
    @ObservedObject var todoStore: TodoWorkspaceStore
    let openTranslator: () -> Void
    let openSettings: () -> Void

    var body: some View {
        todoContent
            .task { todoStore.load() }
            .frame(minWidth: 420, minHeight: 360)
    }

    @ViewBuilder private var todoContent: some View {
        if let model = todoStore.model {
            FullTodoView(model: model)
        } else if let error = todoStore.initializationError {
            VStack(alignment: .leading, spacing: 16) {
                Label("Todo 저장소를 열 수 없습니다", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                ScrollView { Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 200)
                Button("다시 시도") { todoStore.load() }
            }
            .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView("할 일 불러오는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

enum WorkFeature: String, CaseIterable, Identifiable {
    case translator = "Translator"
    case todo = "Todo"
    var id: Self { self }
}

// Shared by the window controller and SwiftUI; hotkeys can select a feature
// without reconstructing either the main window or the Todo workspace.
@MainActor
final class WorkNavigationState: ObservableObject {
    @Published private(set) var selection: WorkFeature = .translator

    @discardableResult
    func select(_ feature: WorkFeature, canLeaveTodo: () -> Bool = { true }) -> Bool {
        guard selection != feature else { return true }
        guard selection != .todo || canLeaveTodo() else { return false }
        selection = feature
        return true
    }
}
