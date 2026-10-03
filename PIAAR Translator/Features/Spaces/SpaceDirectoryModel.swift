import Foundation
import Combine

@MainActor final class SpaceDirectoryModel: ObservableObject {
    let repository: SpaceRepository
    let friendships: FriendshipRepository
    @Published private(set) var spaces: [Space] = []
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var friends: [Friend] = []
    @Published private(set) var created: Space?
    @Published private(set) var failedInvites: [Friend] = []
    @Published var creating = false
    private var creationID = UUID()
    private var inviteIDs: [UUID: UUID] = [:]
    private var invalidated = false
    private var revision = 0
    private var models: [UUID: TaskWorkspaceModel] = [:]
    private let makeModel: (UUID) -> TaskWorkspaceModel
    private let sessionFailure: (CollaborationAuthError) -> Void
    init(repository: SpaceRepository, friendships: FriendshipRepository, makeModel: @escaping (UUID) -> TaskWorkspaceModel,
         sessionFailure: @escaping (CollaborationAuthError) -> Void = { _ in }) {
        self.repository = repository; self.friendships = friendships; self.makeModel = makeModel; self.sessionFailure = sessionFailure
    }
    func model(id: UUID) -> TaskWorkspaceModel {
        if invalidated { let model = makeModel(id); model.invalidate(); return model }
        if let cached = models[id] { return cached }
        let model = makeModel(id); let refreshRoot = model.onSpaceChange
        model.onSpaceChange = { [weak self] in await refreshRoot?(); await self?.refresh() }
        models[id] = model; return model
    }
    func refresh() async {
        guard !invalidated else { return }; revision += 1; let token = revision
        do {
            let rows = try await repository.spaces()
            guard !invalidated, revision == token else { return }
            spaces = rows.filter { !$0.isArchived }; loaded = true; errorMessage = nil
            for (id, model) in models {
                if rows.contains(where: { $0.id == id }) { model.updateSpaceStates(rows) }
                else { model.clearSpaceAccess() }
            }
        } catch { if !invalidated, revision == token { report(error) } }
    }
    func beginCreating() { guard !invalidated else { return }; creationID = UUID(); inviteIDs = [:]; created = nil; failedInvites = []; errorMessage = nil; friends = []; creating = true }
    func loadFriends() async {
        guard !invalidated else { return }
        do { let snapshot = try await friendships.snapshot(); if !invalidated { friends = snapshot.friends } }
        catch { report(error) }
    }
    func create(name: String, selected: Set<UUID>) async -> Bool {
        guard !invalidated, !busy, repository.userID == friendships.userID else { return false }
        busy = true; defer { busy = false }
        do {
            let targets = created == nil ? friends.filter { selected.contains($0.userID) } : failedInvites
            if created == nil {
                let value = try await repository.createSpace(id: creationID, name: name)
                guard !invalidated else { return false }; created = value
                if !spaces.contains(where: { $0.id == value.id }) { spaces.append(value) }
            }
            guard let space = created else { return false }; var failed: [Friend] = []
            for friend in targets {
                guard !invalidated else { return false }
                let id = inviteIDs[friend.userID] ?? UUID(); inviteIDs[friend.userID] = id
                do { _ = try await repository.addMember(id: id, spaceID: space.id, friend: friend) }
                catch {
                    if error is CollaborationAuthError { report(error); return false }
                    failed.append(friend)
                }
            }
            guard !invalidated else { return false }; failedInvites = failed
            errorMessage = failed.isEmpty ? nil : "\(failed.count)명의 초대에 실패했습니다. 업무방은 만들어졌습니다."
            // Do not erase a partial result with a refresh error.
            return failed.isEmpty
        } catch { report(error); return false }
    }
    func invalidate() {
        invalidated = true; revision += 1; models.values.forEach { $0.invalidate() }; models = [:]
        spaces = []; friends = []; created = nil; failedInvites = []; inviteIDs = [:]; creating = false; busy = false; loaded = false; errorMessage = nil
    }
    private func report(_ error: Error) {
        guard !invalidated else { return }
        if let auth = error as? CollaborationAuthError, auth == .sessionMissing || auth == .refreshFailed { invalidate(); sessionFailure(auth) }
        else { errorMessage = (error as? SpaceError)?.localizedDescription ?? (error is URLError ? "서버 연결에 실패했습니다. 기존 목록은 유지됩니다." : SpaceError.unavailable.localizedDescription) }
    }
}
