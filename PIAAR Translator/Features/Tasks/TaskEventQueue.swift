import Foundation
import Combine

@MainActor protocol TaskEventStorage {
    func load() throws -> [TaskEventRequest]
    func save(_ events: [TaskEventRequest]) throws
}
@MainActor final class MemoryTaskEventStorage: TaskEventStorage {
    private var events: [TaskEventRequest] = []
    func load() throws -> [TaskEventRequest] { events }
    func save(_ events: [TaskEventRequest]) throws { self.events = events }
}
@MainActor final class FileTaskEventStorage: TaskEventStorage {
    let url: URL
    init(userID: UUID, directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.piaar.PIAAR-Translator/PendingTaskEvents")
        url = base.appendingPathComponent(userID.uuidString + ".json")
    }
    func load() throws -> [TaskEventRequest] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([TaskEventRequest].self, from: Data(contentsOf: url))
    }
    func save(_ events: [TaskEventRequest]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(events).write(to: url, options: .atomic)
    }
}

// Only audit requests are stored locally. Tasks themselves remain Supabase-only.
@MainActor final class TaskEventQueue: ObservableObject {
    @Published private(set) var pending: [TaskEventRequest] = []
    @Published private(set) var storageError: String?
    private let repository: TaskRepository
    private let storage: TaskEventStorage
    private let sessionFailure: (CollaborationAuthError) -> Void
    @Published private(set) var deliveryFailed = false
    private var loadFailed = false
    private var draining = false
    private var invalidated = false
    init(repository: TaskRepository, storage: TaskEventStorage? = nil, sessionFailure: @escaping (CollaborationAuthError) -> Void = { _ in }) {
        self.repository = repository; self.storage = storage ?? MemoryTaskEventStorage(); self.sessionFailure = sessionFailure
        do {
            let events = try self.storage.load()
            guard events.allSatisfy({ $0.actorID == repository.userID }), Set(events.map(\.id)).count == events.count else { throw TaskServiceError.invalidData }
            pending = events; deliveryFailed = !events.isEmpty
        } catch { loadFailed = true; storageError = "활동 기록 대기 파일을 읽을 수 없습니다. 원본 파일은 보존됩니다." }
    }
    var notice: String? {
        if let storageError { return storageError + " · 새 대기 기록 \(pending.count)건" }
        return pending.isEmpty || !deliveryFailed ? nil : "할 일은 저장되었습니다. 활동 기록 \(pending.count)건은 저장 대기 중입니다."
    }
    func invalidate() { invalidated = true; pending = []; storageError = nil; deliveryFailed = false }
    func enqueue(_ events: [TaskEventRequest]) async {
        guard !invalidated else { return }
        for event in events where event.actorID == repository.userID && !pending.contains(where: { $0.id == event.id }) { pending.append(event) }
        await retry()
    }
    func retry() async {
        guard !invalidated, !draining else { return }; draining = true; defer { draining = false }
        if loadFailed {
            do {
                let recovered = try storage.load()
                guard recovered.allSatisfy({ $0.actorID == repository.userID }), Set(recovered.map(\.id)).count == recovered.count else { throw TaskServiceError.invalidData }
                pending = recovered + pending.filter { new in !recovered.contains { $0.id == new.id } }
                loadFailed = false
            } catch { return }
        }
        while !invalidated {
            // Persist the original UUID/name snapshot before every HTTP attempt.
            do { try storage.save(pending); storageError = nil }
            catch { storageError = "할 일은 저장되었습니다. 활동 기록 대기 파일 저장에 실패했습니다."; return }
            guard let event = pending.first else { deliveryFailed = false; return }
            do { try await repository.recordEvent(event) }
            catch {
                deliveryFailed = true
                if let auth = error as? CollaborationAuthError, auth == .sessionMissing || auth == .refreshFailed { sessionFailure(auth) }
                return
            }
            guard !invalidated else { return }
            pending.removeAll { $0.id == event.id }
        }
    }
}
