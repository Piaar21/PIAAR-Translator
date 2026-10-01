import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginManager:
    ObservableObject {

    static let shared =
        LaunchAtLoginManager()

    @Published private(set)
    var isEnabled: Bool = false

    @Published private(set)
    var errorMessage: String?

    private init() {
        refreshStatus()
    }


    // MARK: - Status

    func refreshStatus() {

        switch SMAppService.mainApp.status {

        case .enabled:
            isEnabled = true

        case .notRegistered,
             .requiresApproval,
             .notFound:

            isEnabled = false

        @unknown default:
            isEnabled = false
        }
    }


    // MARK: - Enable / Disable

    func setEnabled(
        _ enabled: Bool
    ) {

        errorMessage = nil

        do {

            if enabled {

                if SMAppService.mainApp.status != .enabled {

                    try SMAppService
                        .mainApp
                        .register()
                }

            } else {

                if SMAppService.mainApp.status != .notRegistered {

                    try SMAppService
                        .mainApp
                        .unregister()
                }
            }

            refreshStatus()

        } catch {

            refreshStatus()

            errorMessage =
                "로그인 시 자동 실행 설정을 변경하지 못했습니다.\n\(error.localizedDescription)"
        }
    }
}
