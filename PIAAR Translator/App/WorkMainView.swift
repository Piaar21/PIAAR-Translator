import SwiftUI
import AppKit

struct WorkMainView: View {
    @ObservedObject var navigation: WorkNavigationState
    @ObservedObject var todoStore: TodoWorkspaceStore
    let openTranslator: () -> Void
    let openSettings: () -> Void
    @ObservedObject private var account: AuthViewModel
    @State private var taskToSend: TodoSnapshot?

    init(navigation: WorkNavigationState, todoStore: TodoWorkspaceStore,
         openTranslator: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.navigation = navigation; self.todoStore = todoStore
        self.openTranslator = openTranslator; self.openSettings = openSettings
        _account = ObservedObject(wrappedValue: todoStore.collaborationAccount)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 190)
            selectedContent.frame(maxWidth: WorkDesign.readingWidth, maxHeight: .infinity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(WorkDesign.contentBackground)
        }
        .background {
            if let model = todoStore.serverTasks {
                TodoNewShortcut { navigation.selectSidebar(.myTodos); model.requestFocus() }.frame(width: 0, height: 0)
            }
        }
        .background { if let directory = todoStore.serverSpaces { SpaceCreationPresenter(model: directory, open: { navigation.selectSidebar(.room($0)) }) } }
        .environment(\.workFullRows, true)
        .task { todoStore.load() }
        .task { await account.start() }
        .task { await todoStore.serverFriends?.refresh(); await todoStore.serverSpaces?.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await todoStore.serverFriends?.refresh(); await todoStore.serverSpaces?.refresh(); await todoStore.serverTasks?.refresh() }
        }
        .frame(minWidth: 680, minHeight: 420)
        .sheet(item: $taskToSend) { todo in
            CollaborationFeatureGate(account: account) {
                if todoStore.serverTasks == nil { SendTaskView(model: todoStore.collaboration.sharedTasks, todo: todo) { navigation.selectSidebar(.friends) } }
            }
        }

    }

    private var sidebar: some View {
        GeometryReader { _ in
            VStack(alignment: .leading, spacing: 8) {
                Text("PIAAR Work").font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 12).padding(.top, 18).padding(.bottom, 10)
                sidebarRow("내 할 일", symbol: "checkmark", selection: .myTodos)
                sidebarRow("받은 업무", symbol: "arrow.down", selection: .receivedTasks,
                           badge: todoStore.serverTasks?.receivedIncompleteCount ?? 0)
                sidebarRow("보낸 업무", symbol: "arrow.up", selection: .sentTasks)
                HStack {
                    Text("업무방").font(WorkDesign.secondary).foregroundStyle(.secondary)
                    Spacer()
                    Button { todoStore.serverSpaces?.beginCreating() } label: { Image(systemName: "plus").frame(width: 28, height: 28).contentShape(Rectangle()) }
                        .buttonStyle(.plain).help("업무방 만들기").disabled(todoStore.serverSpaces == nil)
                }.padding(.horizontal, 12).padding(.top, 14)
                if let directory = todoStore.serverSpaces, !directory.spaces.isEmpty {
                    ScrollView(.vertical) {
                        VStack(spacing: 2) {
                            ForEach(directory.spaces) { space in sidebarRow(space.name, selection: .room(space.id)) }
                        }
                    }.frame(minHeight: 0, maxHeight: min(200, CGFloat(directory.spaces.count) * 36)).layoutPriority(-1)
                } else {
                    Text("아직 업무방이 없습니다.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
                }
                if let message = todoStore.serverSpaces?.errorMessage { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(.horizontal, 12) }
                Spacer(minLength: 6)
                sidebarRow("친구", selection: .friends, badge: todoStore.serverFriends?.incoming.count ?? 0)
                sidebarRow("내 프로필", selection: .profile)
            }.padding(.horizontal, 10).padding(.bottom, 14)
        }.background(WorkDesign.sidebarBackground)
    }

    private func sidebarRow(_ title: String, symbol: String? = nil,
                            selection: WorkSidebarSelection, badge: Int = 0) -> some View {
        let selected = navigation.sidebarSelection == selection
        return Button { navigation.selectSidebar(selection) } label: {
            HStack(spacing: 8) {
                Capsule().fill(selected ? Color.accentColor : Color.clear).frame(width: 3, height: 14)
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 14) }
                Text(title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 2)
                if badge > 0 { Text("\(badge)").font(.system(size: 11)).foregroundStyle(.secondary) }
            }.font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .background(selected ? Color.primary.opacity(0.055) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 9)).contentShape(Rectangle())
        }.buttonStyle(.plain).help(title)
    }

    @ViewBuilder private var selectedContent: some View {
        switch navigation.sidebarSelection {
        case .myTodos:
            todoContent
        case .receivedTasks:
            if let model = todoStore.serverTasks { ServerTasksView(model: model, page: .received) }
            else { CollaborationFeatureGate(account: account) { SharedTasksView(model: todoStore.collaboration.sharedTasks, received: true) } }
        case .sentTasks:
            if let model = todoStore.serverTasks { ServerTasksView(model: model, page: .sent) }
            else { CollaborationFeatureGate(account: account) { SharedTasksView(model: todoStore.collaboration.sharedTasks, received: false) } }
        case .room(let id):
            if let directory = todoStore.serverSpaces {
                ServerTasksView(model: directory.model(id: id), closeSpace: { navigation.selectSidebar(.myTodos) }).id(id)
                    .task(id: id) { await directory.refresh() }
            } else { Text("업무방 정보를 사용할 수 없습니다.").foregroundStyle(.secondary) }
        case .profile:
            CollaborationAccountView(model: account)
        case .friends:
            if let friends = todoStore.serverFriends, let tasks = todoStore.serverTasks {
                ServerFriendTasksView(friends: friends, tasks: tasks)
            }
            else if todoStore.serverTasks != nil { Text("친구 정보를 사용할 수 없습니다.").foregroundStyle(.secondary) }
            else { CollaborationFeatureGate(account: account) { FriendsView(model: todoStore.collaboration.friends, sharedTasks: todoStore.collaboration.sharedTasks) } }
        }
    }

    @ViewBuilder private var todoContent: some View {
        if let model = todoStore.serverTasks {
            ServerTasksView(model: model, migration: todoStore.migration)
        } else if let model = todoStore.model {
            FullTodoView(model: model, sharedTasks: todoStore.collaboration.sharedTasks, sendTask: { taskToSend = $0 })
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
    @Published private(set) var sidebarSelection: WorkSidebarSelection = .myTodos

    func selectSidebar(_ selection: WorkSidebarSelection) {
        sidebarSelection = selection
    }

    @discardableResult
    func select(_ feature: WorkFeature, canLeaveTodo: () -> Bool = { true }) -> Bool {
        guard selection != feature else { return true }
        guard selection != .todo || canLeaveTodo() else { return false }
        selection = feature
        return true
    }
}

// Full-only navigation; room IDs come from the collaboration repository.
enum WorkSidebarSelection: Hashable {
    case myTodos
    case receivedTasks
    case sentTasks
    case room(UUID)
    case friends
    case profile
}

// Observe the Task model here as well, so sheet completion and notices update on the friends page.
private struct ServerFriendTasksView: View {
    @ObservedObject var friends: ServerFriendsViewModel
    @ObservedObject var tasks: TaskWorkspaceModel
    var body: some View {
        ServerFriendsView(sendTask: { tasks.beginDelivery(to: $0) }, deliveryNotice: tasks.deliveryNotice, model: friends)
            .sheet(item: $tasks.delivery) { composer in DirectTaskSheet(model: composer, finished: { await tasks.deliveryFinished() }) }
    }
}

private struct SpaceCreationPresenter: View {
    @ObservedObject var model: SpaceDirectoryModel
    let open: (UUID) -> Void
    var body: some View { Color.clear.frame(width: 0, height: 0).sheet(isPresented: $model.creating) { CreateSpaceView(model: model, open: open) } }
}
