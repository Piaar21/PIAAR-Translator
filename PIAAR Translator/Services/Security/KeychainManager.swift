import Foundation
import Security
import Combine

enum KeychainReadError: LocalizedError, Equatable {
    case access(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .access(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "오류 코드: \(status)"
            return "Keychain에 접근할 수 없습니다. 저장된 API Key는 삭제되지 않았습니다.\n\(detail)"
        case .invalidData:
            return "저장된 API Key 데이터를 읽을 수 없습니다. Keychain의 기존 항목은 유지됩니다."
        }
    }
}

@MainActor
final class KeychainManager: ObservableObject {

    static let shared =
        KeychainManager()


    // MARK: - Keychain Constants

    nonisolated static let service =
        "OPENAI_CLIPBOARD_TRANSLATOR"

    nonisolated static var account: String {
        NSUserName()
    }


    // MARK: - Published

    enum LookupStatus: Equatable {
        case found
        case notFound
        case failure(OSStatus)
    }

    typealias CopyItem = (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    private let copyItem: CopyItem

    @Published private(set) var lookupStatus: LookupStatus = .notFound

    var hasAPIKey: Bool { lookupStatus == .found }

    var apiKeyStatusText: String {
        switch lookupStatus {
        case .found: return "API Key 등록됨"
        case .notFound: return "API Key가 등록되지 않았습니다."
        case .failure: return "API Key 상태를 확인할 수 없습니다."
        }
    }

    @Published private(set)
    var statusMessage: String?

    @Published private(set)
    var isError: Bool = false


    // MARK: - Init

    init(copyItem: @escaping CopyItem = SecItemCopyMatching) {
        self.copyItem = copyItem
        refreshStatus()
    }


    // MARK: - Status

    func refreshStatus() {
        refreshExistenceOnly()
        if case .failure(let status) = lookupStatus {
            statusMessage = KeychainReadError.access(status).localizedDescription
            isError = true
        } else {
            statusMessage = nil
            isError = false
        }
    }


    // MARK: - Save

    @discardableResult
    func saveAPIKey(
        _ rawKey: String
    ) -> Bool {

        let key =
            rawKey.trimmingCharacters(
                in: .whitespacesAndNewlines
            )


        guard !key.isEmpty else {

            statusMessage =
                "API Key를 입력해주세요."

            isError =
                true

            return false
        }


        guard let data =
                key.data(
                    using: .utf8
                )
        else {

            statusMessage =
                "API Key를 저장할 수 없습니다."

            isError =
                true

            return false
        }


        let query: [String: Any] = [

            kSecClass as String:
                kSecClassGenericPassword,

            kSecAttrService as String:
                Self.service,

            kSecAttrAccount as String:
                Self.account
        ]


        let attributes: [String: Any] = [

            kSecValueData as String:
                data
        ]


        // 기존 API Key가 있는 경우 업데이트
        let updateStatus =
            SecItemUpdate(
                query as CFDictionary,
                attributes as CFDictionary
            )


        if updateStatus ==
            errSecSuccess {

            lookupStatus = .found

            isError =
                false

            statusMessage =
                "API Key가 저장되었습니다."

            return true
        }


        // 기존 API Key가 없는 경우 새로 추가
        if updateStatus ==
            errSecItemNotFound {

            var addQuery =
                query


            addQuery[
                kSecValueData as String
            ] = data


            let addStatus =
                SecItemAdd(
                    addQuery as CFDictionary,
                    nil
                )


            guard addStatus ==
                    errSecSuccess
            else {

                refreshExistenceOnly()

                isError =
                    true

                statusMessage =
                    Self.errorMessage(
                        for: addStatus
                    )

                return false
            }


            lookupStatus = .found

            isError =
                false

            statusMessage =
                "API Key가 저장되었습니다."

            return true
        }


        isError =
            true

        statusMessage =
            Self.errorMessage(
                for: updateStatus
            )


        refreshExistenceOnly()

        return false
    }


    // MARK: - Delete

    @discardableResult
    func deleteAPIKey() -> Bool {

        let query: [String: Any] = [

            kSecClass as String:
                kSecClassGenericPassword,

            kSecAttrService as String:
                Self.service,

            kSecAttrAccount as String:
                Self.account
        ]


        let status =
            SecItemDelete(
                query as CFDictionary
            )


        if status ==
            errSecSuccess ||
            status ==
            errSecItemNotFound {

            lookupStatus = .notFound

            isError =
                false

            statusMessage =
                "API Key가 삭제되었습니다."

            return true
        }


        isError =
            true

        statusMessage =
            Self.errorMessage(
                for: status
            )


        refreshExistenceOnly()

        return false
    }


    // MARK: - Load

    nonisolated static func loadAPIKey(
        copyItem: CopyItem = SecItemCopyMatching
    ) throws -> String {

        let query: [String: Any] = [

            kSecClass as String:
                kSecClassGenericPassword,

            kSecAttrService as String:
                service,

            kSecAttrAccount as String:
                account,

            kSecReturnData as String:
                true,

            kSecMatchLimit as String:
                kSecMatchLimitOne
        ]


        var result:
            CFTypeRef?


        let status =
            copyItem(query as CFDictionary, &result)


        switch classifyLookupStatus(status) {
        case .found: break
        case .notFound: throw TranslatorError.apiKeyNotFound
        case .failure(let status): throw KeychainReadError.access(status)
        }

        guard
            let data =
                result as? Data,

            let key =
                String(
                    data: data,
                    encoding: .utf8
                )?
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),

            !key.isEmpty

        else {

            throw KeychainReadError.invalidData
        }


        return key
    }


    // MARK: - Exists

    nonisolated static func apiKeyStatus(
        copyItem: CopyItem = SecItemCopyMatching
    ) -> LookupStatus {

        let query: [String: Any] = [

            kSecClass as String:
                kSecClassGenericPassword,

            kSecAttrService as String:
                service,

            kSecAttrAccount as String:
                account,

            kSecReturnData as String:
                false,

            kSecMatchLimit as String:
                kSecMatchLimitOne
        ]


        let status =
            copyItem(query as CFDictionary, nil)


        return classifyLookupStatus(status)
    }


    // MARK: - Helpers

    private func refreshExistenceOnly() {

        lookupStatus = Self.apiKeyStatus(copyItem: copyItem)
    }


    nonisolated static func classifyLookupStatus(_ status: OSStatus) -> LookupStatus {
        switch status {
        case errSecSuccess: return .found
        case errSecItemNotFound: return .notFound
        default: return .failure(status)
        }
    }

    nonisolated private static func errorMessage(
        for status: OSStatus
    ) -> String {

        if let message =
            SecCopyErrorMessageString(
                status,
                nil
            ) as String? {

            return "Keychain 오류: \(message)"
        }


        return """
        Keychain 오류 코드: \(status)
        """
    }
}
