import SwiftUI

struct WorkMainView: View {
    @ObservedObject var navigation: WorkNavigationState
    @ObservedObject var todoStore: TodoWorkspaceStore
    let openTranslator: () -> Void
    let openSettings: () -> Void
    @ObservedObject private var friendsModel: FriendsViewModel
    @ObservedObject private var sharedTasks: SharedTasksViewModel
    @ObservedObject private var workRooms: WorkRoomsViewModel
    @State private var taskToSend: TodoSnapshot?
    @State private var roomCreationNotice = false

    init(navigation: WorkNavigationState, todoStore: TodoWorkspaceStore,
         openTranslator: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.navigation = navigation; self.todoStore = todoStore
        self.openTranslator = openTranslator; self.openSettings = openSettings
        let workspace = todoStore.collaboration
        _friendsModel = ObservedObject(wrappedValue: workspace.friends)
        _sharedTasks = ObservedObject(wrappedValue: workspace.sharedTasks)
        _workRooms = ObservedObject(wrappedValue: workspace.rooms)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 190)
            selectedContent.frame(maxWidth: WorkDesign.readingWidth, maxHeight: .infinity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(WorkDesign.contentBackground)
        }
        .environment(\.workFullRows, true)
        .task { todoStore.load(); await sharedTasks.load(); await workRooms.loadSidebar() }
        .frame(minWidth: 680, minHeight: 420)
        .sheet(item: $taskToSend) { todo in
            SendTaskView(model: sharedTasks, todo: todo) { navigation.selectSidebar(.friends) }
        }
        .sheet(isPresented: $roomCreationNotice) {
            CreateWorkRoomView(model: workRooms) { navigation.selectSidebar(.room($0)) }
        }
    }

    private var sidebar: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 8) {
                Text("PIAAR Work").font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 12).padding(.top, 18).padding(.bottom, 10)
                sidebarRow("내 할 일", symbol: "checkmark", selection: .myTodos)
                sidebarRow("받은 업무", symbol: "arrow.down", selection: .receivedTasks,
                           badge: sharedTasks.receivedIncompleteCount)
                sidebarRow("보낸 업무", symbol: "arrow.up", selection: .sentTasks)
                Text("업무방").font(WorkDesign.secondary).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.top, 14)
                if !workRooms.rooms.isEmpty {
                    ScrollView(.vertical) {
                        VStack(spacing: 2) {
                            ForEach(workRooms.rooms) { room in
                                sidebarRow(room.name, selection: .room(room.id))
                            }
                        }
                    }.frame(height: min(200, max(0, geometry.size.height - 390), CGFloat(workRooms.rooms.count) * 36))
                }
                Button { roomCreationNotice = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").foregroundStyle(Color.accentColor)
                        Text("업무방 만들기")
                    }.font(.system(size: 13)).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                        .padding(.horizontal, 12).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Spacer(minLength: 6)
                sidebarRow("친구", selection: .friends)
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
            SharedTasksView(model: sharedTasks, received: true)
        case .sentTasks:
            SharedTasksView(model: sharedTasks, received: false)
        case .room(let id):
            WorkRoomView(model: workRooms, roomID: id) { navigation.selectSidebar(.myTodos) }
        case .profile:
            ProfileView(model: friendsModel)
        case .friends:
            FriendsView(model: friendsModel, sharedTasks: sharedTasks)
        }
    }

    @ViewBuilder private var todoContent: some View {
        if let model = todoStore.model {
            FullTodoView(model: model, sharedTasks: sharedTasks, sendTask: { taskToSend = $0 })
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
