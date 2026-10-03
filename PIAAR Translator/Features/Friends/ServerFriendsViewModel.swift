import Foundation
import Combine

@MainActor final class ServerFriendsViewModel: ObservableObject {
    let userID: UUID
    @Published private(set) var friends: [Friend] = []
    @Published private(set) var incoming: [FriendRequestPresentation] = []
    @Published private(set) var outgoing: [FriendRequestPresentation] = []
    @Published private(set) var candidate: WorkUserSummary?
    @Published private(set) var relationship: FriendRelationship?
    @Published private(set) var errorMessage: String?
    @Published private(set) var searchError: String?
    @Published private(set) var notice: String?
    @Published private(set) var isBusy = false
    @Published private(set) var loaded = false
    @Published var searchQuery = ""
    @Published var codeInput = "" { didSet { if codeInput != oldValue { candidate = nil; relationship = nil; searchError = nil; notice = nil } } }
    @Published var addingFriend = false
    private let repository: FriendshipRepository
    private let sessionFailure: (CollaborationAuthError) -> Void
    private var invalidated = false
    private var revision = 0
    private var refreshPending = false
    init(repository: FriendshipRepository, sessionFailure: @escaping (CollaborationAuthError) -> Void = { _ in }) {
        self.repository = repository; userID = repository.userID; self.sessionFailure = sessionFailure
    }
    var filteredFriends: [Friend] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return friends }
        let code = query.replacingOccurrences(of: "#", with: "").replacingOccurrences(of: "-", with: "").uppercased()
        return friends.filter { $0.displayName.localizedCaseInsensitiveContains(query) || (!code.isEmpty && $0.friendCode.rawValue.contains(code)) }
    }
    func beginAddingFriend() { guard !invalidated else { return }; codeInput = ""; candidate = nil; relationship = nil; searchError = nil; notice = nil; addingFriend = true }
    func cancelAddingFriend() { addingFriend = false; codeInput = ""; candidate = nil; relationship = nil; searchError = nil; notice = nil }
    func invalidate() {
        invalidated = true; revision += 1; refreshPending = false
        friends = []; incoming = []; outgoing = []; candidate = nil; relationship = nil
        codeInput = ""; searchQuery = ""; searchError = nil; errorMessage = nil; notice = nil
        addingFriend = false; isBusy = false; loaded = false
    }
    func refresh() async {
        guard !invalidated else { return }
        if isBusy { refreshPending = true; return }
        isBusy = true; let token = revision
        await reload(token: token)
        finish(token: token)
    }
    private func reload(token: Int) async {
        do {
            let value = try await repository.snapshot()
            guard valid(token) else { return }
            // Publish the complete snapshot only after every query/profile join succeeds.
            friends = value.friends; incoming = value.incoming; outgoing = value.outgoing
            loaded = true; errorMessage = nil
            if let person = candidate {
                if friends.contains(where: { $0.userID == person.id }) { relationship = .friend }
                else if let request = incoming.first(where: { $0.person.id == person.id }) { relationship = .incoming(request.request) }
                else if let request = outgoing.first(where: { $0.person.id == person.id }) { relationship = .outgoing(request.request) }
                else { relationship = .available; notice = nil }
            }
        } catch { if valid(token) { report(error, searching: false) } }
    }
    private func valid(_ token: Int) -> Bool { !invalidated && token == revision }
    private func finish(token: Int) {
        guard valid(token) else { return }; isBusy = false
        if refreshPending { refreshPending = false; Task { await self.refresh() } }
    }
    func findUser() async {
        guard !invalidated, !isBusy else { return }; isBusy = true; let token = revision; let input = codeInput
        candidate = nil; relationship = nil; searchError = nil; notice = nil
        defer { finish(token: token) }
        do {
            let code = try FriendCode(input)
            let user = try await repository.searchUser(friendCode: code)
            guard valid(token), input == codeInput else { return }
            guard user.id != userID else { throw FriendshipError.selfRequest }
            let state = try await repository.relationship(with: user.id)
            guard valid(token), input == codeInput else { return }
            candidate = user; relationship = state
        } catch { if valid(token) { report(error, searching: true) } }
    }
    func sendRequest() async {
        guard !invalidated, !isBusy, let user = candidate, relationship == .available else { return }
        isBusy = true; let token = revision; searchError = nil
        defer { finish(token: token) }
        do {
            let result = try await repository.sendRequest(to: user.id)
            guard valid(token) else { return }
            switch result {
            case .sent(let request):
                relationship = .outgoing(request); notice = "친구 요청을 보냈습니다."
                if !outgoing.contains(where: { $0.id == request.id }) { outgoing.append(FriendRequestPresentation(request: request, person: user)) }
            case .existing(let state): relationship = state; notice = nil
            }
            await reload(token: token)
        } catch { if valid(token) { report(error, searching: true) } }
    }
    func accept(_ id: UUID) async {
        guard !invalidated, !isBusy else { return }
        guard incoming.contains(where: { $0.id == id }) || incomingSearchID == id else { return }
        isBusy = true; let token = revision
        defer { finish(token: token) }
        do {
            _ = try await repository.acceptRequest(id: id)
            guard valid(token) else { return }
            incoming.removeAll { $0.id == id }
            if incomingSearchID == id { relationship = .friend }
            notice = "친구 요청을 수락했습니다."; searchError = nil
            await reload(token: token)
        } catch { if valid(token) { report(error, searching: false) } }
    }
    private var incomingSearchID: UUID? { if case .incoming(let r) = relationship { return r.id }; return nil }
    func reject(_ id: UUID) async {
        guard !invalidated, !isBusy, incoming.contains(where: { $0.id == id }) else { return }
        isBusy = true; let token = revision
        defer { finish(token: token) }
        do {
            try await repository.rejectRequest(id: id)
            guard valid(token) else { return }
            incoming.removeAll { $0.id == id }; if incomingSearchID == id { relationship = .available }
            await reload(token: token)
        } catch { if valid(token) { report(error, searching: false) } }
    }
    func remove(_ friend: Friend) async {
        guard !invalidated, !isBusy else { return }; isBusy = true; let token = revision
        defer { finish(token: token) }
        do {
            try await repository.removeFriend(friendshipID: friend.friendshipID)
            guard valid(token) else { return }
            friends.removeAll { $0.id == friend.id }
            if candidate?.id == friend.userID { relationship = .available }
            await reload(token: token)
        } catch { if valid(token) { report(error, searching: false) } }
    }
    private func report(_ error: Error, searching: Bool) {
        if let auth = error as? CollaborationAuthError, auth == .sessionMissing || auth == .refreshFailed {
            invalidate(); sessionFailure(auth); return
        }
        let message: String
        if let value = error as? FriendshipError { message = value.localizedDescription }
        else if let value = error as? FriendError { message = value.localizedDescription }
        else { message = "친구 정보를 확인하지 못했습니다. 연결을 확인하고 다시 시도해주세요." }
        if searching { searchError = message } else { errorMessage = message }
    }
}
