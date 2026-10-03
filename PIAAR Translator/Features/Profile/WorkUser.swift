import Foundation

struct WorkUser: Identifiable, Equatable, Codable {
    let id: UUID
    let displayName: String
    let friendCode: String
    let createdAt: Date
    let updatedAt: Date
    let isActive: Bool

    var displayedFriendCode: String { "#" + friendCode }
    static func validName(_ input: String) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 30 else { throw WorkUserError.invalidName }
        return name
    }
    static func validCode(_ code: String) -> Bool {
        code.utf8.count == 8 && code.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
    }
    static func randomFriendCode() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }
}

// Only these four values are published. No Apple identity or private metadata.
struct PublicWorkUser: Equatable {
    let workUserID: UUID
    let friendCode: String
    let displayName: String
    let isActive: Bool
    init(_ user: WorkUser) {
        workUserID = user.id; friendCode = user.friendCode
        displayName = user.displayName; isActive = user.isActive
    }
}

enum WorkUserError: LocalizedError, Equatable {
    case invalidName, unavailable, network, permission, collisionLimit, concurrentChange, invalidRecord
    case fetchFailure(String), privateSaveFailure(String), publicSaveFailure(String)
    case partialPublication(String), retryLater(seconds: Double), accountChanged
    var errorDescription: String? {
        switch self {
        case .invalidName: return "이름은 공백을 제외하고 1~30자로 입력해주세요."
        case .unavailable: return "iCloud를 사용할 수 없습니다. 계정 상태를 확인해주세요."
        case .network: return "네트워크에 연결할 수 없습니다. 연결 후 다시 확인해주세요."
        case .permission: return "CloudKit 접근 권한이 없습니다. Development 설정을 확인해주세요."
        case .collisionLimit: return "친구코드를 확보하지 못했습니다. 나중에 다시 시도해주세요."
        case .concurrentChange: return "다른 요청에서 프로필이 변경되었습니다. 다시 확인해주세요."
        case .invalidRecord: return "저장된 프로필 형식이 올바르지 않습니다. 기존 데이터는 유지됩니다."
        case .fetchFailure(let message): return "프로필 조회 실패: " + message
        case .privateSaveFailure(let message): return "Private 프로필 저장 실패: " + message
        case .publicSaveFailure(let message): return "공개 프로필 저장 실패: " + message
        case .partialPublication(let message): return "원본은 저장되었지만 공개 프로필 반영은 아직 완료되지 않았습니다. 다시 확인하면 복구합니다. " + message
        case .retryLater(let seconds): return "CloudKit이 재시도 대기를 요청했습니다. 약 \(Int(seconds.rounded(.up)))초 후 다시 확인해주세요."
        case .accountChanged: return "iCloud 계정이 변경되었습니다. 다시 확인해주세요."
        }
    }
}

@MainActor protocol WorkUserRepository {
    func currentUser() async throws -> WorkUser?
    func create(displayName: String) async throws -> WorkUser
    func updateDisplayName(_ name: String) async throws -> WorkUser
}

// Backend-neutral concurrency token; no CloudKit types cross this boundary.
struct StoredWorkUser: Equatable {
    let user: WorkUser
    let publicationPending: Bool
    let revision: String?
    let friendCodeEstablished: Bool
    init(user: WorkUser, publicationPending: Bool, revision: String?, friendCodeEstablished: Bool = false) {
        self.user = user; self.publicationPending = publicationPending; self.revision = revision
        self.friendCodeEstablished = friendCodeEstablished
    }
}
@MainActor protocol WorkUserGateway {
    func currentIdentity() async throws -> String
    func fetchPrivate(identity: String) async throws -> StoredWorkUser?
    func savePrivate(identity: String, user: WorkUser, pending: Bool, expectedRevision: String?) async throws -> StoredWorkUser
    func publish(_ profile: PublicWorkUser, identity: String) async throws -> Bool // false = code belongs to another UUID
}
