import Foundation

// The state machine is backend-independent; CloudKit supplies only the gateway.
@MainActor final class ReconciledWorkUserRepository: WorkUserRepository {
    private let gateway: any WorkUserGateway
    private let code: () -> String
    private let clock: () -> Date
    private let maxAttempts: Int
    init(gateway: any WorkUserGateway, maxAttempts: Int = 8,
         code: @escaping () -> String = WorkUser.randomFriendCode, clock: @escaping () -> Date = Date.init) {
        self.gateway = gateway; self.maxAttempts = max(1, maxAttempts); self.code = code; self.clock = clock
    }
    func currentUser() async throws -> WorkUser? {
        let identity = try await gateway.currentIdentity()
        guard let stored = try await gateway.fetchPrivate(identity: identity) else { return nil }
        return try await reconcile(stored, identity: identity)
    }
    func create(displayName: String) async throws -> WorkUser {
        let name = try WorkUser.validName(displayName)
        let identity = try await gateway.currentIdentity()
        if let existing = try await gateway.fetchPrivate(identity: identity) {
            return try await reconcile(existing, identity: identity)
        }
        let now = clock(), candidate = code()
        guard WorkUser.validCode(candidate) else { throw WorkUserError.invalidRecord }
        let user = WorkUser(id: UUID(), displayName: name, friendCode: candidate,
                            createdAt: now, updatedAt: now, isActive: true)
        let stored: StoredWorkUser
        do { stored = try await gateway.savePrivate(identity: identity, user: user, pending: true, expectedRevision: nil) }
        catch WorkUserError.concurrentChange {
            guard let winner = try await gateway.fetchPrivate(identity: identity) else { throw WorkUserError.concurrentChange }
            return try await reconcile(winner, identity: identity)
        }
        return try await reconcile(stored, identity: identity)
    }
    func updateDisplayName(_ name: String) async throws -> WorkUser {
        let name = try WorkUser.validName(name)
        let identity = try await gateway.currentIdentity()
        guard let old = try await gateway.fetchPrivate(identity: identity) else { throw WorkUserError.invalidRecord }
        let user = WorkUser(id: old.user.id, displayName: name, friendCode: old.user.friendCode,
            createdAt: old.user.createdAt, updatedAt: max(clock(), old.user.updatedAt), isActive: old.user.isActive)
        let updated = try await gateway.savePrivate(identity: identity, user: user, pending: true, expectedRevision: old.revision)
        return try await reconcile(updated, identity: identity, mayChangeCode: false)
    }
    private func reconcile(_ initial: StoredWorkUser, identity: String, mayChangeCode: Bool = true) async throws -> WorkUser {
        var stored = initial
        for _ in 0..<maxAttempts {
            let published: Bool
            do { published = try await gateway.publish(PublicWorkUser(stored.user), identity: identity) }
            catch { throw WorkUserError.partialPublication(error.localizedDescription) }
            if published {
                if !stored.publicationPending {
                    guard let latest = try await gateway.fetchPrivate(identity: identity) else { throw WorkUserError.concurrentChange }
                    if latest.revision == stored.revision { return stored.user }
                    stored = latest; continue
                }
                do {
                    return try await gateway.savePrivate(identity: identity, user: stored.user, pending: false,
                                                         expectedRevision: stored.revision).user
                } catch WorkUserError.concurrentChange {
                    guard let latest = try await gateway.fetchPrivate(identity: identity) else { throw WorkUserError.concurrentChange }
                    // A concurrent rename must not be overwritten by the previous name.
                    stored = latest; continue
                } catch { throw WorkUserError.partialPublication(error.localizedDescription) }
            }
            guard mayChangeCode && !stored.friendCodeEstablished else { throw WorkUserError.partialPublication("친구코드 소유권 충돌") }
            let candidate = code()
            guard WorkUser.validCode(candidate) else { throw WorkUserError.invalidRecord }
            let user = WorkUser(id: stored.user.id, displayName: stored.user.displayName, friendCode: candidate,
                createdAt: stored.user.createdAt, updatedAt: max(clock(), stored.user.updatedAt), isActive: stored.user.isActive)
            do { stored = try await gateway.savePrivate(identity: identity, user: user, pending: true, expectedRevision: stored.revision) }
            catch WorkUserError.concurrentChange {
                guard let latest = try await gateway.fetchPrivate(identity: identity) else { throw WorkUserError.concurrentChange }
                stored = latest
            }
        }
        throw WorkUserError.collisionLimit
    }
}
