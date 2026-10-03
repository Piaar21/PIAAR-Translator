import Foundation

// Pure relationship orchestration. Unit Tests inject FriendTransport without constructing an SDK client.
@MainActor final class SupabaseFriendRepository: FriendshipRepository {
    let userID: UUID
    private let transport: FriendTransport
    init(userID: UUID, transport: FriendTransport) { self.userID = userID; self.transport = transport }
    convenience init(account: SupabaseAccountRepository, userID: UUID) {
        self.init(userID: userID, transport: SupabaseFriendTransport(account: account, userID: userID))
    }
    static func summary(_ p: CollaborationProfile) throws -> WorkUserSummary {
        WorkUserSummary(id: p.id, displayName: p.displayName, friendCode: try FriendCode(p.friendCode))
    }
    func searchUser(friendCode: FriendCode) async throws -> WorkUserSummary {
        try await transport.authorize()
        guard let p = try await transport.profile(code: friendCode), p.isActive else { throw FriendshipError.notFound }
        try await transport.authorize()
        guard p.id != userID else { throw FriendshipError.selfRequest }
        return try Self.summary(p)
    }
    func relationship(with user: UUID) async throws -> FriendRelationship {
        guard user != userID else { throw FriendshipError.selfRequest }
        try await transport.authorize()
        if let pair = try await transport.activePair(with: user), pair.otherUser(than: userID) == user { try await transport.authorize(); return .friend }
        try await transport.authorize()
        if let r = try await transport.pendingPair(with: user) {
            try await transport.authorize()
            guard r.status == .pending else { throw FriendshipError.invalidData }
            if r.senderID == userID, r.receiverID == user { return .outgoing(r) }
            if r.receiverID == userID, r.senderID == user { return .incoming(r) }
            throw FriendshipError.invalidData
        }
        try await transport.authorize(); return .available
    }
    func sendRequest(to user: UUID) async throws -> FriendRequestDelivery {
        guard user != userID else { throw FriendshipError.selfRequest }
        let existing = try await relationship(with: user)
        guard existing == .available else { return .existing(existing) }
        guard let p = try await transport.profile(id: user), p.isActive else { throw FriendshipError.notFound }
        try await transport.authorize()
        do {
            let request = try await transport.insertRequest(receiver: user)
            try await transport.authorize()
            guard request.senderID == userID, request.receiverID == user, request.status == .pending else { throw FriendshipError.invalidData }
            return .sent(request)
        } catch FriendshipError.uniqueConflict {
            // SQLSTATE 23505 is not success on its own. Reconcile only an exact existing pair.
            let current = try await relationship(with: user)
            guard current != .available else { throw FriendshipError.uniqueConflict }
            return .existing(current)
        }
    }
    func snapshot() async throws -> FriendshipSnapshot {
        try await transport.authorize()
        async let pairs = transport.activeFriendships()
        async let inbox = transport.requests(incoming: true)
        async let outbox = transport.requests(incoming: false)
        let rows = try await (pairs, inbox, outbox)
        try await transport.authorize()
        let friends = rows.0.filter { $0.otherUser(than: userID) != nil }
        let incoming = rows.1.filter { $0.receiverID == userID && $0.senderID != userID && $0.status == .pending }
        let outgoing = rows.2.filter { $0.senderID == userID && $0.receiverID != userID && $0.status == .pending }
        let ids = Set(friends.compactMap { $0.otherUser(than: userID) } + incoming.map(\.senderID) + outgoing.map(\.receiverID))
        let profiles = try await transport.profiles(ids: ids)
        try await transport.authorize()
        var people: [UUID: WorkUserSummary] = [:]
        for p in profiles { people[p.id] = try Self.summary(p) }
        func person(_ id: UUID) throws -> WorkUserSummary {
            guard let value = people[id] else { throw FriendshipError.invalidData }; return value
        }
        let list = try friends.map { pair -> Friend in
            let other = try person(pair.otherUser(than: userID)!)
            return Friend(friendshipID: pair.id, userID: other.id, displayName: other.displayName, friendCode: other.friendCode, createdAt: pair.createdAt)
        }.sorted {
            let order = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return order == .orderedSame ? $0.userID.uuidString < $1.userID.uuidString : order == .orderedAscending
        }
        return try FriendshipSnapshot(friends: list,
            incoming: incoming.map { FriendRequestPresentation(request: $0, person: try person($0.senderID)) },
            outgoing: outgoing.map { FriendRequestPresentation(request: $0, person: try person($0.receiverID)) })
    }
    func acceptRequest(id: UUID) async throws -> UUID {
        try await transport.authorize()
        let saved = try await transport.accept(id: id)
        try await transport.authorize(); return saved
    }
    func rejectRequest(id: UUID) async throws {
        try await transport.authorize(); try await transport.reject(id: id); try await transport.authorize()
    }
    func removeFriend(friendshipID: UUID) async throws {
        try await transport.authorize(); try await transport.remove(id: friendshipID); try await transport.authorize()
    }
}
