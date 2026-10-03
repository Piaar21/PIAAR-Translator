import CloudKit
import CryptoKit
import Foundation

@MainActor final class CloudKitWorkUserRepository: WorkUserRepository {
    private let repository: ReconciledWorkUserRepository
    init() { repository = ReconciledWorkUserRepository(gateway: CloudKitWorkUserGateway()) }
    func currentUser() async throws -> WorkUser? { try await repository.currentUser() }
    func create(displayName: String) async throws -> WorkUser { try await repository.create(displayName: displayName) }
    func updateDisplayName(_ name: String) async throws -> WorkUser { try await repository.updateDisplayName(name) }
}

// CK identity, records, databases and version tags are confined to this adapter.
@MainActor final class CloudKitWorkUserGateway: WorkUserGateway {
    private lazy var container = CKContainer(identifier: CloudKitConfiguration.containerIdentifier)
    private var retryNotBefore: Date?
    private enum Stage { case fetch, privateSave, publicSave }

    func currentIdentity() async throws -> String {
        try checkRetryDelay()
        do {
            guard try await container.accountStatus() == .available else { throw WorkUserError.unavailable }
            return try await container.userRecordID().recordName
        } catch { throw translated(error, stage: .fetch) }
    }
    private func validateIdentity(_ expected: String) async throws {
        guard try await currentIdentity() == expected else { throw WorkUserError.accountChanged }
    }
    private func privateID(_ identity: String) -> CKRecord.ID {
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return CKRecord.ID(recordName: "work-user-" + hash)
    }
    private func fetch(_ id: CKRecord.ID, database: CKDatabase) async throws -> CKRecord? {
        do { return try await database.record(for: id) }
        catch let error as CKError where error.code == .unknownItem { return nil }
    }
    func fetchPrivate(identity: String) async throws -> StoredWorkUser? {
        try await validateIdentity(identity)
        do {
            guard let record = try await fetch(privateID(identity), database: container.privateCloudDatabase) else { return nil }
            return try decode(record)
        } catch { throw translated(error, stage: .fetch) }
    }
    func savePrivate(identity: String, user: WorkUser, pending: Bool, expectedRevision: String?) async throws -> StoredWorkUser {
        try await validateIdentity(identity)
        do {
            let id = privateID(identity)
            let record: CKRecord
            if let expectedRevision {
                guard let existing = try await fetch(id, database: container.privateCloudDatabase),
                      existing.recordChangeTag == expectedRevision else { throw WorkUserError.concurrentChange }
                record = existing
            } else { record = CKRecord(recordType: "WorkUser", recordID: id) }
            // Do not delete/reinsert records; conditional saves retain their system metadata.
            record["workUserID"] = user.id.uuidString
            record["displayName"] = user.displayName
            record["friendCode"] = user.friendCode
            record["createdAt"] = user.createdAt
            record["updatedAt"] = user.updatedAt
            record["isActive"] = NSNumber(value: user.isActive)
            record["publicationPending"] = NSNumber(value: pending)
            let established = (record["friendCodeEstablished"] as? NSNumber)?.boolValue == true || !pending
            record["friendCodeEstablished"] = NSNumber(value: established)
            try await validateIdentity(identity)
            let saved = try await save(record, database: container.privateCloudDatabase)
            return try decode(saved)
        } catch { throw translated(error, stage: .privateSave) }
    }
    func publish(_ profile: PublicWorkUser, identity: String) async throws -> Bool {
        try await validateIdentity(identity) // Every write belongs to the originally selected account.
        let id = CKRecord.ID(recordName: "friend-" + profile.friendCode)
        do {
            for _ in 0..<3 {
                let existing = try await fetch(id, database: container.publicCloudDatabase)
                if let existing {
                    guard existing.recordType == "PublicWorkUser", let owner = existing["workUserID"] as? String else {
                        throw WorkUserError.invalidRecord
                    }
                    guard owner == profile.workUserID.uuidString else { return false }
                    if existing["displayName"] as? String == profile.displayName,
                       existing["friendCode"] as? String == profile.friendCode,
                       (existing["isActive"] as? NSNumber)?.boolValue == profile.isActive { return true }
                }
                let record = existing ?? CKRecord(recordType: "PublicWorkUser", recordID: id)
                record["workUserID"] = profile.workUserID.uuidString
                record["friendCode"] = profile.friendCode
                record["displayName"] = profile.displayName
                record["isActive"] = NSNumber(value: profile.isActive)
                do {
                    try await validateIdentity(identity)
                    _ = try await save(record, database: container.publicCloudDatabase); return true
                }
                catch let error as CKError where error.code == .serverRecordChanged {
                    // New record ID collision or competing update: re-read the owner, never overwrite blindly.
                    continue
                }
            }
            throw WorkUserError.concurrentChange
        } catch { throw translated(error, stage: .publicSave) }
    }
    private func save(_ record: CKRecord, database: CKDatabase) async throws -> CKRecord {
        let results = try await database.modifyRecords(saving: [record], deleting: [],
            savePolicy: .ifServerRecordUnchanged, atomically: false)
        guard let result = results.saveResults[record.recordID] else { throw WorkUserError.invalidRecord }
        return try result.get()
    }
    private func decode(_ record: CKRecord) throws -> StoredWorkUser {
        guard record.recordType == "WorkUser", let rawID = record["workUserID"] as? String,
              let id = UUID(uuidString: rawID), let name = record["displayName"] as? String,
              let code = record["friendCode"] as? String, WorkUser.validCode(code),
              let created = record["createdAt"] as? Date, let updated = record["updatedAt"] as? Date,
              let active = record["isActive"] as? NSNumber,
              let pending = record["publicationPending"] as? NSNumber else { throw WorkUserError.invalidRecord }
        _ = try WorkUser.validName(name)
        return StoredWorkUser(user: WorkUser(id: id, displayName: name, friendCode: code,
            createdAt: created, updatedAt: updated, isActive: active.boolValue),
            publicationPending: pending.boolValue, revision: record.recordChangeTag,
            friendCodeEstablished: (record["friendCodeEstablished"] as? NSNumber)?.boolValue == true)
    }
    private func checkRetryDelay() throws {
        if let deadline = retryNotBefore, deadline > Date() {
            throw WorkUserError.retryLater(seconds: deadline.timeIntervalSinceNow)
        }
    }
    private func translated(_ error: Error, stage: Stage) -> WorkUserError {
        if let error = error as? WorkUserError { return error }
        if let error = error as? CKError {
            if let seconds = error.retryAfterSeconds {
                retryNotBefore = Date().addingTimeInterval(max(0, seconds))
                return .retryLater(seconds: max(0, seconds))
            }
            switch error.code {
            case .serverRecordChanged: return .concurrentChange
            case .networkUnavailable, .networkFailure: return .network
            case .permissionFailure, .missingEntitlement: return .permission
            case .notAuthenticated: return .unavailable
            default: break
            }
        }
        switch stage {
        case .fetch: return .fetchFailure(error.localizedDescription)
        case .privateSave: return .privateSaveFailure(error.localizedDescription)
        case .publicSave: return .publicSaveFailure(error.localizedDescription)
        }
    }
}
