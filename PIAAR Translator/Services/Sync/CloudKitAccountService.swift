import CloudKit
import Combine
import Foundation

enum CloudKitConfiguration {
    static let containerIdentifier = "iCloud.com.piaar.PIAAR-Work"
}

enum CloudAccountState: Equatable {
    case notChecked, available, noAccount, restricted, couldNotDetermine, temporarilyUnavailable, unknown
    case error(message: String)

    var label: String {
        switch self {
        case .notChecked: return "확인 전"
        case .available: return "연결됨"
        case .noAccount: return "로그인 필요"
        case .restricted: return "접근 제한됨"
        case .temporarilyUnavailable: return "일시적으로 사용할 수 없음"
        case .couldNotDetermine, .unknown, .error: return "상태 확인 실패"
        }
    }
    // This is an account prerequisite, not a verified database read/write.
    var permitsPrivateDatabaseAccount: Bool { self == .available }
    var detail: String? {
        switch self {
        case .available: return "Private Cloud Database를 사용할 수 있는 계정 상태입니다. 개인 Todo와 협업 데이터 동기화는 아직 수행하지 않습니다."
        case .couldNotDetermine: return "iCloud 계정 상태를 확인할 수 없습니다."
        case .unknown: return "지원하지 않는 계정 상태를 반환했습니다."
        case .error(let message): return message
        default: return nil
        }
    }
}

@MainActor protocol CloudKitAccountChecking {
    func accountState() async throws -> CloudAccountState
}

@MainActor final class CloudKitAccountService: CloudKitAccountChecking {
    // Creating or constructing a Profile view does not trigger CloudKit calls.
    private lazy var container = CKContainer(identifier: CloudKitConfiguration.containerIdentifier)
    func accountState() async throws -> CloudAccountState {
        Self.map(try await container.accountStatus())
    }
    static func map(_ status: CKAccountStatus) -> CloudAccountState {
        switch status {
        case .available: return .available
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .couldNotDetermine: return .couldNotDetermine
        case .temporarilyUnavailable: return .temporarilyUnavailable
        @unknown default: return .unknown
        }
    }
}

@MainActor final class CloudAccountDiagnostics: ObservableObject {
    @Published private(set) var state: CloudAccountState = .notChecked
    @Published private(set) var isChecking = false
    private let service: any CloudKitAccountChecking
    private var accountChanges: AnyCancellable?
    @Published private(set) var accountChangeRevision = 0
    private var revision = 0

    init(service: (any CloudKitAccountChecking)? = nil) {
        self.service = service ?? CloudKitAccountService()
    }
    func startMonitoring(center: NotificationCenter = .default) {
        guard accountChanges == nil else { return }
        accountChanges = center.publisher(for: .CKAccountChanged).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor [weak self] in
                guard let self else { return }
                self.accountChangeRevision += 1
                await self.refresh()
            } }
    }
    func stopMonitoring() { accountChanges = nil }
    func refresh() async {
        revision += 1
        let request = revision
        isChecking = true
        do {
            let value = try await service.accountState()
            guard request == revision else { return }
            state = value
        } catch {
            guard request == revision else { return }
            state = .error(message: error.localizedDescription)
        }
        if request == revision { isChecking = false }
    }
}
