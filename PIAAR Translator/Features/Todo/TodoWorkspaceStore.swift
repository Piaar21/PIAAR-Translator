import Foundation
import Combine
import OSLog

// Owned by the main window. Opening/using the Translator never creates a Todo DB.
@MainActor
final class TodoWorkspaceStore: ObservableObject {
    @Published private(set) var model: TodoViewModel?
    @Published private(set) var initializationError: String?
    lazy var collaboration = CollaborationWorkspace()
    let collaborationAccount: AuthViewModel
    let serverTasks: TaskWorkspaceModel?
    let migration: LegacyTaskMigration?
    let serverSpaces: SpaceDirectoryModel?
    private var spacesObservation: AnyCancellable?
    let serverFriends: ServerFriendsViewModel?
    private var friendsObservation: AnyCancellable?
    private var serverObservation: AnyCancellable?
    private let makeRepository: @MainActor () throws -> TodoRepository
    private let logger = Logger(subsystem: "com.piaar.PIAAR-Translator", category: "TodoPersistence")

    init(makeRepository: (@MainActor () throws -> TodoRepository)? = nil,
         collaboration: CollaborationWorkspace? = nil,
         account: AuthViewModel? = nil, serverTasks: TaskWorkspaceModel? = nil, migration: LegacyTaskMigration? = nil, serverFriends: ServerFriendsViewModel? = nil, serverSpaces: SpaceDirectoryModel? = nil) {
        collaborationAccount = account ?? CollaborationAccountComposition.unconfiguredModel()
        self.serverSpaces = serverSpaces; self.serverTasks = serverTasks; self.migration = migration; self.serverFriends = serverFriends
        self.makeRepository = makeRepository ?? {
            SwiftDataTodoRepository(container: try TodoPersistence.makeContainer())
        }
        if let collaboration { self.collaboration = collaboration }
        spacesObservation = serverSpaces?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        friendsObservation = serverFriends?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        serverObservation = serverTasks?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func load() {
        if let serverTasks { Task { await serverTasks.refresh() }; return }
        guard model == nil else { return }
        do {
            model = try TodoViewModel(repository: makeRepository())
            initializationError = nil
        } catch {
            let diagnostic = String(describing: error as NSError)
            logger.error("Todo store initialization failed: \(diagnostic, privacy: .public)")
            initializationError = "할 일 저장소를 열 수 없습니다. 기존 데이터는 삭제하지 않았습니다.\n\(diagnostic)"
        }
    }
}
