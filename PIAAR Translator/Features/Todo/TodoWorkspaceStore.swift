import Foundation
import Combine
import OSLog

// Owned by the main window. Opening/using the Translator never creates a Todo DB.
@MainActor
final class TodoWorkspaceStore: ObservableObject {
    @Published private(set) var model: TodoViewModel?
    @Published private(set) var initializationError: String?
    lazy var collaboration = CollaborationWorkspace()
    private let makeRepository: @MainActor () throws -> TodoRepository
    private let logger = Logger(subsystem: "com.piaar.PIAAR-Translator", category: "TodoPersistence")

    init(makeRepository: (@MainActor () throws -> TodoRepository)? = nil,
         collaboration: CollaborationWorkspace? = nil) {
        self.makeRepository = makeRepository ?? {
            SwiftDataTodoRepository(container: try TodoPersistence.makeContainer())
        }
        if let collaboration { self.collaboration = collaboration }
    }

    func load() {
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
