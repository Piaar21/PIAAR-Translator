import Foundation

struct FriendCode: Hashable {
    let rawValue: String
    var displayValue: String { "#" + rawValue }

    init(_ input: String) throws {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        value = value.replacingOccurrences(of: "-", with: "").uppercased()
        guard value.utf8.count == 8,
              value.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else {
            throw FriendError.invalidCode
        }
        rawValue = value
    }
}

struct WorkUserSummary: Identifiable, Equatable {
    let id: UUID
    let displayName: String
    let friendCode: FriendCode
}

struct FriendEntry: Identifiable, Equatable {
    let id: UUID
    let user: WorkUserSummary
    let addedAt: Date
}

enum FriendError: LocalizedError, Equatable {
    case invalidCode, notFound, selfAddition, duplicate, emptyName
    var errorDescription: String? {
        switch self {
        case .invalidCode: return "친구 코드는 영문과 숫자 8자리로 입력해주세요."
        case .notFound: return "사용자를 찾을 수 없습니다."
        case .selfAddition: return "자기 자신은 친구로 추가할 수 없습니다."
        case .duplicate: return "이미 추가된 친구입니다."
        case .emptyName: return "이름을 입력해주세요."
        }
    }
}

// Async boundary for a future account-backed implementation; no storage or network here.
@MainActor
protocol FriendRepository {
    func currentProfile() async throws -> WorkUserSummary
    func friends() async throws -> [FriendEntry]
    func addFriend(code: FriendCode) async throws -> FriendEntry
    func removeFriend(id: UUID) async throws
    func updateDisplayName(_ name: String) async throws -> WorkUserSummary
}

@MainActor
final class MockFriendRepository: FriendRepository {
    private var profile: WorkUserSummary
    private let directory: [WorkUserSummary]
    private var entries: [FriendEntry] = []
    private let clock: () -> Date

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
        profile = WorkUserSummary(id: UUID(), displayName: "양태호", friendCode: try! FriendCode("A3K8R21P"))
        directory = [
            WorkUserSummary(id: UUID(), displayName: "김대리", friendCode: try! FriendCode("B3821K7M")),
            WorkUserSummary(id: UUID(), displayName: "박대리", friendCode: try! FriendCode("C1057P2Q")),
            WorkUserSummary(id: UUID(), displayName: "이대리", friendCode: try! FriendCode("D8842L1X"))
        ]
    }

    // Composition-only access for seeding another memory-only Mock repository.
    var mockProfile: WorkUserSummary { profile }
    var mockUsers: [WorkUserSummary] { directory }

    func currentProfile() async throws -> WorkUserSummary { profile }
    func friends() async throws -> [FriendEntry] { entries }

    func addFriend(code: FriendCode) async throws -> FriendEntry {
        guard code != profile.friendCode else { throw FriendError.selfAddition }
        guard let user = directory.first(where: { $0.friendCode == code }) else { throw FriendError.notFound }
        guard !entries.contains(where: { $0.user.id == user.id }) else { throw FriendError.duplicate }
        let entry = FriendEntry(id: UUID(), user: user, addedAt: clock())
        entries.append(entry)
        return entry
    }

    // Removes the friendship only; user directory and unrelated records stay intact.
    func removeFriend(id: UUID) async throws { entries.removeAll { $0.id == id } }

    func updateDisplayName(_ name: String) async throws -> WorkUserSummary {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FriendError.emptyName }
        profile = WorkUserSummary(id: profile.id, displayName: name, friendCode: profile.friendCode)
        return profile
    }
}
