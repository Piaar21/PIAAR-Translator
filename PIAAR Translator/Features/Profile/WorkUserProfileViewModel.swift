import Combine
import Foundation

@MainActor final class WorkUserProfileViewModel: ObservableObject {
    @Published private(set) var user: WorkUser?
    @Published private(set) var isBusy = false
    @Published private(set) var loaded = false
    @Published private(set) var errorMessage: String?
    private let repository: any WorkUserRepository
    private var generation = 0
    private var pendingLoad = false

    init(repository: any WorkUserRepository) { self.repository = repository }
    func accountChanged() {
        pendingLoad = false
        generation += 1; user = nil; loaded = false; errorMessage = nil
    }
    func load() async {
        if isBusy { pendingLoad = true; return }
        await run { try await self.repository.currentUser() }
    }
    @discardableResult func create(_ name: String) async -> Bool {
        await run { try await self.repository.create(displayName: name) }
    }
    @discardableResult func rename(_ name: String) async -> Bool {
        await run { try await self.repository.updateDisplayName(name) }
    }
    @discardableResult private func run(_ action: () async throws -> WorkUser?) async -> Bool {
        guard !isBusy else { return false }
        let request = generation
        isBusy = true
        defer {
            isBusy = false
            if pendingLoad { pendingLoad = false; Task { await self.load() } }
        }
        do {
            let value = try await action()
            guard request == generation else { return false }
            user = value; loaded = true; errorMessage = nil
            return true
        } catch {
            guard request == generation else { return false }
            loaded = true; errorMessage = error.localizedDescription
            // Keep a previously fetched profile offline; never substitute the Mock profile.
            return false
        }
    }
}
