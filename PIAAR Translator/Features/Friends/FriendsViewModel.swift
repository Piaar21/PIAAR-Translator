import Foundation
import Combine

@MainActor
final class FriendsViewModel: ObservableObject {
    @Published private(set) var profile: WorkUserSummary?
    @Published private(set) var friends: [FriendEntry] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isBusy = false
    @Published var codeInput = ""
    @Published var searchQuery = ""
    @Published var addingFriend = false

    func beginAddingFriend() { codeInput = ""; errorMessage = nil; addingFriend = true }
    func cancelAddingFriend() { codeInput = ""; addingFriend = false }

    var filteredFriends: [FriendEntry] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return friends }
        let code = query.replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "-", with: "").uppercased()
        return friends.filter {
            $0.user.displayName.localizedCaseInsensitiveContains(query)
                || (!code.isEmpty && $0.user.friendCode.rawValue.contains(code))
        }
    }
    private let repository: any FriendRepository

    init(repository: any FriendRepository) { self.repository = repository }

    func load() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            profile = try await repository.currentProfile()
            friends = try await repository.friends()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func addFriend() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let code = try FriendCode(codeInput)
            let entry = try await repository.addFriend(code: code)
            friends.append(entry)
            codeInput = ""
            addingFriend = false
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func removeFriend(_ entry: FriendEntry) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await repository.removeFriend(id: entry.id)
            friends.removeAll { $0.id == entry.id }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func saveDisplayName(_ name: String) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            profile = try await repository.updateDisplayName(name)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
