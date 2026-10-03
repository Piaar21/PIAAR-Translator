import Foundation

struct AuthenticatedUser: Equatable { let id: UUID; let email: String? }
struct CollaborationProfile: Codable, Equatable {
    let id: UUID
    let displayName: String
    let friendCode: String
    let isActive: Bool
    let createdAt: Date
    let updatedAt: Date
    enum CodingKeys: String, CodingKey {
        case id, displayName = "display_name", friendCode = "friend_code"
        case isActive = "is_active", createdAt = "created_at", updatedAt = "updated_at"
    }
}
struct SignupRequest: Equatable {
    let displayName: String
    let email: String
    let password: String
    var metadata: [String: String] { ["display_name": displayName] }
}
enum SignupResult: Equatable { case signedIn(AuthenticatedUser), awaitingConfirmation }
enum CollaborationAuthError: LocalizedError, Equatable {
    case configuration, network, invalidCredentials, emailConfirmation, sessionMissing
    case refreshFailed, profileMissing, profileFetch, profileUpdate, unavailable, invalidInput
    case signupFailed
    var errorDescription: String? {
        switch self {
        case .configuration: return "Supabase publishable key 설정이 필요합니다."
        case .network: return "네트워크 연결을 확인하고 다시 시도해주세요."
        case .invalidCredentials: return "이메일 또는 비밀번호가 올바르지 않습니다."
        case .emailConfirmation: return "인증 메일을 확인해주세요."
        case .sessionMissing: return "로그인이 필요합니다."
        case .refreshFailed: return "세션 갱신에 실패했습니다. 다시 시도하거나 로그인해주세요."
        case .profileMissing: return "계정의 프로필이 없습니다. 서버의 profiles 생성 설정을 확인해주세요."
        case .profileFetch: return "프로필을 불러오지 못했습니다. 다시 시도해주세요."
        case .profileUpdate: return "이름 변경에 실패했습니다. 기존 프로필은 유지됩니다."
        case .unavailable: return "Supabase를 사용할 수 없습니다. 잠시 후 다시 시도해주세요."
        case .invalidInput: return "이름(1~30자), 이메일, 비밀번호를 확인해주세요."
        case .signupFailed: return "회원가입에 실패했습니다. 입력값과 서버의 가입 정책을 확인해주세요."
        }
    }
}
@MainActor protocol AuthRepository {
    func restoreSession() async throws -> AuthenticatedUser?
    func signUp(_ request: SignupRequest) async throws -> SignupResult
    func signIn(email: String, password: String) async throws -> AuthenticatedUser
    func signOut() async throws
    func changes() -> AsyncStream<AuthenticatedUser?>
}
extension AuthRepository {
    func changes() -> AsyncStream<AuthenticatedUser?> { AsyncStream { $0.finish() } }
}
@MainActor protocol CollaborationProfileRepository {
    func profile(userID: UUID) async throws -> CollaborationProfile?
    func updateDisplayName(_ name: String, userID: UUID) async throws -> CollaborationProfile
}
