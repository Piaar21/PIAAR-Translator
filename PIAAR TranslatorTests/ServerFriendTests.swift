import XCTest
import Supabase
@testable import PIAAR_Translator

@MainActor final class ServerFriendTests: XCTestCase {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    private func fixture() -> (FriendMemoryDatabase, SupabaseFriendRepository, FriendMemoryTransport, ServerFriendsViewModel) {
        let db = FriendMemoryDatabase()
        for (id, name, code) in [(a,"A","AAAA0001"),(b,"Beta","BBBB0002"),(c,"alpha","CCCC0003"),(d,"D","DDDD0004")] {
            db.people[id] = CollaborationProfile(id: id, displayName: name, friendCode: code, isActive: true, createdAt: db.now, updatedAt: db.now)
        }
        let transport = FriendMemoryTransport(userID: a, db: db)
        let repo = SupabaseFriendRepository(userID: a, transport: transport)
        return (db, repo, transport, ServerFriendsViewModel(repository: repo))
    }
    private func request(_ db: FriendMemoryDatabase, from: UUID, to: UUID, status: FriendRequest.Status = .pending) -> FriendRequest {
        let r = FriendRequest(id: UUID(), senderID: from, receiverID: to, status: status, createdAt: db.now, updatedAt: db.now, respondedAt: status == .pending ? nil : db.now)
        db.requests.append(r); return r
    }
    private func pair(_ db: FriendMemoryDatabase, _ one: UUID, _ two: UUID, ended: Bool = false) -> FriendshipRecord {
        let ids = [one,two].sorted { $0.uuidString < $1.uuidString }
        let p = FriendshipRecord(id: UUID(), userAID: ids[0], userBID: ids[1], createdAt: db.now, endedAt: ended ? db.now : nil)
        db.pairs.append(p); return p
    }
    func testNormalizeAllSupportedFriendCodes() throws {
        for code in ["#AB12CD34", "ab12cd34", "AB12-CD34", " AB12CD34 \n"] {
            XCTAssertEqual(try FriendCode(code).rawValue, "AB12CD34")
            XCTAssertEqual(try FriendCode(code).displayValue, "#AB12CD34")
        }
    }
    func testFindUserRequiresSeparateSendConfirmation() async {
        let (db, _, _, vm) = fixture(); vm.beginAddingFriend(); vm.codeInput = "#bbbb-0002"
        await vm.findUser(); XCTAssertEqual(vm.candidate?.id, b); XCTAssertEqual(vm.relationship, .available)
        XCTAssertTrue(vm.addingFriend); XCTAssertTrue(db.requests.isEmpty); XCTAssertEqual(db.insertCount, 0)
    }
    func testMissingUserKeepsSheetOpen() async {
        let (_, _, _, vm) = fixture(); vm.beginAddingFriend(); vm.codeInput = "ZZZZ9999"; await vm.findUser()
        XCTAssertNil(vm.candidate); XCTAssertEqual(vm.searchError, "사용자를 찾을 수 없습니다."); XCTAssertTrue(vm.addingFriend)
    }
    func testSelfRequestIsRejectedBeforeInsert() async {
        let (db, repo, _, vm) = fixture(); vm.codeInput = "AAAA0001"; await vm.findUser()
        XCTAssertEqual(vm.searchError, "자기 자신에게 친구 요청을 보낼 수 없습니다.")
        do { _ = try await repo.sendRequest(to: a); XCTFail() } catch { XCTAssertEqual(error as? FriendshipError, .selfRequest) }
        XCTAssertEqual(db.insertCount, 0)
    }
    func testInactiveProfileCannotBeFoundOrRequested() async {
        let (db, repo, _, _) = fixture(); db.people[b] = CollaborationProfile(id: b, displayName: "inactive", friendCode: "BBBB0002", isActive: false, createdAt: db.now, updatedAt: db.now)
        do { _ = try await repo.searchUser(friendCode: FriendCode("BBBB0002")); XCTFail() } catch { XCTAssertEqual(error as? FriendshipError, .notFound) }
        do { _ = try await repo.sendRequest(to: b); XCTFail() } catch { XCTAssertEqual(error as? FriendshipError, .notFound) }
        XCTAssertEqual(db.insertCount, 0)
    }
    func testSendingCreatesPendingRequestNotFriendship() async {
        let (db, _, _, vm) = fixture(); vm.codeInput = "BBBB0002"; await vm.findUser(); await vm.sendRequest()
        XCTAssertEqual(db.requests.count, 1); XCTAssertEqual(db.requests[0].senderID, a); XCTAssertEqual(db.requests[0].receiverID, b)
        XCTAssertEqual(db.requests[0].status, .pending); XCTAssertNil(db.requests[0].respondedAt)
        XCTAssertTrue(db.pairs.isEmpty); XCTAssertTrue(vm.friends.isEmpty); XCTAssertEqual(vm.outgoing.count, 1)
        XCTAssertEqual(vm.notice, "친구 요청을 보냈습니다.")
    }
    func testExistingOutgoingDoesNotInsertAgain() async throws {
        let (db, repo, _, vm) = fixture(); let r = request(db, from: a, to: b)
        vm.codeInput = "BBBB0002"; await vm.findUser(); XCTAssertEqual(vm.relationship, .outgoing(r))
        let delivery = try await repo.sendRequest(to: b); XCTAssertEqual(delivery, .existing(.outgoing(r)))
        await vm.sendRequest(); XCTAssertEqual(db.insertCount, 0); XCTAssertEqual(db.requests.count, 1)
    }
    func testExistingIncomingOffersAcceptanceWithoutReverseInsert() async throws {
        let (db, repo, _, vm) = fixture(); let r = request(db, from: b, to: a)
        vm.codeInput = "BBBB0002"; await vm.findUser(); XCTAssertEqual(vm.relationship, .incoming(r))
        let delivery = try await repo.sendRequest(to: b); XCTAssertEqual(delivery, .existing(.incoming(r)))
        await vm.accept(r.id); XCTAssertEqual(vm.relationship, .friend); XCTAssertEqual(vm.friends.count, 1)
        XCTAssertEqual(db.insertCount, 0); XCTAssertEqual(db.acceptCount, 1)
    }
    func testActiveFriendshipBlocksNewRequest() async throws {
        let (db, repo, _, vm) = fixture(); _ = pair(db, a, b)
        vm.codeInput = "BBBB0002"; await vm.findUser(); XCTAssertEqual(vm.relationship, .friend)
        let delivery = try await repo.sendRequest(to: b); XCTAssertEqual(delivery, .existing(.friend)); XCTAssertEqual(db.insertCount, 0)
    }
    func testOppositePendingPairRaceRecoversIncomingWinner() async throws {
        let (db, repo, _, _) = fixture()
        var winner: FriendRequest?
        db.beforeInsert = { winner = self.request(db, from: self.b, to: self.a) }
        let result = try await repo.sendRequest(to: b)
        XCTAssertEqual(result, .existing(.incoming(try XCTUnwrap(winner))))
        XCTAssertEqual(db.requests.count, 1); XCTAssertEqual(db.insertCount, 1); XCTAssertEqual(db.pairReads, 2)
    }
    func testSameDirectionPendingPairRaceRecoversOutgoingWinner() async throws {
        let (db, repo, _, _) = fixture(); var winner: FriendRequest?
        db.beforeInsert = { winner = self.request(db, from: self.a, to: self.b) }
        let delivery = try await repo.sendRequest(to: b); XCTAssertEqual(delivery, .existing(.outgoing(try XCTUnwrap(winner))))
        XCTAssertEqual(db.requests.count, 1)
    }
    func testUnrelatedUniqueConflictIsNotReportedAsSuccess() async {
        let (db, repo, _, _) = fixture(); db.insertFailure = FriendshipError.uniqueConflict
        do { _ = try await repo.sendRequest(to: b); XCTFail() } catch { XCTAssertEqual(error as? FriendshipError, .uniqueConflict) }
        XCTAssertTrue(db.requests.isEmpty); XCTAssertTrue(db.pairs.isEmpty)
    }
    func testOtherServerErrorsDoNotEnterPairConflictRecovery() async {
        let (db, repo, _, _) = fixture(); db.insertFailure = FriendshipError.unavailable
        do { _ = try await repo.sendRequest(to: b); XCTFail() } catch { XCTAssertEqual(error as? FriendshipError, .unavailable) }
        XCTAssertEqual(db.pairReads, 1)
    }
    func testIncomingIsReceiverOwnedAndPendingOnly() async throws {
        let (db, repo, _, _) = fixture(); let expected = request(db, from: b, to: a)
        _ = request(db, from: a, to: c); _ = request(db, from: c, to: d); _ = request(db, from: d, to: a, status: .rejected)
        db.returnUnscopedRows = true
        let value = try await repo.snapshot()
        XCTAssertEqual(value.incoming.map(\.id), [expected.id]); XCTAssertEqual(value.incoming[0].person.id, b)
        XCTAssertEqual(value.outgoing.count, 1); XCTAssertEqual(value.outgoing[0].person.id, c)
    }
    func testAcceptMakesBothUsersFriendsAndClearsPending() async throws {
        let (db, repo, _, vm) = fixture(); let r = request(db, from: b, to: a)
        await vm.refresh(); await vm.accept(r.id)
        let other = SupabaseFriendRepository(userID: b, transport: FriendMemoryTransport(userID: b, db: db))
        let mine = try await repo.snapshot(), theirs = try await other.snapshot()
        XCTAssertEqual(mine.friends.map(\.userID), [b]); XCTAssertEqual(theirs.friends.map(\.userID), [a])
        XCTAssertEqual(vm.friends.map(\.userID), [b]); XCTAssertTrue(vm.incoming.isEmpty)
        XCTAssertTrue(theirs.outgoing.isEmpty); XCTAssertEqual(db.acceptCount, 1); XCTAssertEqual(db.pairs.count, 1)
        XCTAssertEqual(db.requests[0].status, .accepted); XCTAssertEqual(db.requests[0].respondedAt, db.now)
    }
    func testAcceptanceReusesExistingActiveFriendship() async throws {
        let (db, repo, _, _) = fixture(); let p = pair(db, a, b); let r = request(db, from: b, to: a)
        let id = try await repo.acceptRequest(id: r.id); XCTAssertEqual(id, p.id); XCTAssertEqual(db.pairs.count, 1)
    }
    func testSenderAndThirdUserCannotAcceptRejectOrRemoveOthers() async {
        let (db, repo, _, _) = fixture(); let r = request(db, from: a, to: b)
        do { _ = try await repo.acceptRequest(id: r.id); XCTFail() } catch {}
        do { try await repo.rejectRequest(id: r.id); XCTFail() } catch {}
        let p = pair(db, a, b)
        let third = SupabaseFriendRepository(userID: c, transport: FriendMemoryTransport(userID: c, db: db))
        do { try await third.removeFriend(friendshipID: p.id); XCTFail() } catch {}
        XCTAssertNil(db.pairs[0].endedAt); XCTAssertEqual(db.requests[0].status, .pending)
    }
    func testRejectRemovesIncomingAndCreatesNoFriendship() async {
        let (db, _, _, vm) = fixture(); let r = request(db, from: b, to: a)
        await vm.refresh(); await vm.reject(r.id)
        XCTAssertTrue(vm.incoming.isEmpty); XCTAssertTrue(db.pairs.isEmpty)
        XCTAssertEqual(db.requests[0].status, .rejected); XCTAssertEqual(db.requests[0].respondedAt, db.now)
        XCTAssertEqual(db.rejectCount, 1)
    }
    func testRejectedPairCanRequestAgain() async throws {
        let (db, repo, _, _) = fixture(); let old = request(db, from: b, to: a, status: .rejected)
        _ = try await repo.sendRequest(to: b)
        XCTAssertEqual(db.requests.count, 2); XCTAssertEqual(db.requests[0].id, old.id)
        XCTAssertEqual(db.requests[1].status, .pending)
    }
    func testRemoveEndsRowAndDisappearsFromBothUsers() async throws {
        let (db, _, _, vm) = fixture(); let p = pair(db, a, b)
        await vm.refresh(); let friend = try XCTUnwrap(vm.friends.first); await vm.remove(friend)
        XCTAssertTrue(vm.friends.isEmpty); XCTAssertEqual(db.pairs.count, 1); XCTAssertEqual(db.pairs[0].id, p.id)
        XCTAssertEqual(db.pairs[0].endedAt, db.now); XCTAssertEqual(db.removeCount, 1)
        let other = SupabaseFriendRepository(userID: b, transport: FriendMemoryTransport(userID: b, db: db))
        let snapshot = try await other.snapshot(); XCTAssertTrue(snapshot.friends.isEmpty)
    }
    func testEndedFriendshipCanRequestAgain() async throws {
        let (db, repo, _, _) = fixture(); _ = pair(db, a, b, ended: true)
        let relationship = try await repo.relationship(with: b); XCTAssertEqual(relationship, .available); _ = try await repo.sendRequest(to: b)
        XCTAssertEqual(db.requests.count, 1)
    }
    func testFriendMappingWorksFromBothOrderedPairSidesAndSortsByName() async throws {
        let (db, repo, _, _) = fixture(); _ = pair(db, a, b); _ = pair(db, a, c)
        let list = try await repo.snapshot().friends
        XCTAssertEqual(list.map(\.displayName), ["alpha", "Beta"])
        let other = SupabaseFriendRepository(userID: b, transport: FriendMemoryTransport(userID: b, db: db))
        let otherSnapshot = try await other.snapshot(); XCTAssertEqual(otherSnapshot.friends.first?.userID, a)
    }
    func testLocalFriendSearchDoesNotSearchDirectoryOrCallServer() async {
        let (db, _, _, vm) = fixture(); _ = pair(db, a, b); await vm.refresh(); let reads = db.profileReads
        vm.searchQuery = "bEt"; XCTAssertEqual(vm.filteredFriends.map(\.userID), [b])
        vm.searchQuery = "#bb-bb"; XCTAssertEqual(vm.filteredFriends.map(\.userID), [b])
        vm.searchQuery = "CCCC0003"; XCTAssertTrue(vm.filteredFriends.isEmpty)
        XCTAssertEqual(db.profileReads, reads)
    }
    func testRefreshFailurePreservesWholeSuccessfulSnapshot() async {
        let (db, _, _, vm) = fixture(); _ = pair(db, a, b); _ = request(db, from: c, to: a); _ = request(db, from: a, to: d)
        await vm.refresh(); let friends = vm.friends, incoming = vm.incoming, outgoing = vm.outgoing
        db.readFailure = FriendshipError.unavailable; await vm.refresh()
        XCTAssertEqual(vm.friends, friends); XCTAssertEqual(vm.incoming, incoming); XCTAssertEqual(vm.outgoing, outgoing)
        XCTAssertTrue(vm.loaded); XCTAssertNotNil(vm.errorMessage)
    }
    func testLogoutClearsAllAccountStateImmediatelyAndIgnoresLateRefresh() async {
        let (db, _, _, vm) = fixture(); _ = pair(db, a, b); _ = request(db, from: c, to: a); _ = request(db, from: a, to: d)
        await vm.refresh(); vm.beginAddingFriend(); vm.codeInput = "BBBB0002"; await vm.findUser(); vm.searchQuery = "Beta"
        db.onRead = { vm.invalidate() }; await vm.refresh()
        XCTAssertTrue(vm.friends.isEmpty); XCTAssertTrue(vm.incoming.isEmpty); XCTAssertTrue(vm.outgoing.isEmpty)
        XCTAssertNil(vm.candidate); XCTAssertNil(vm.relationship); XCTAssertFalse(vm.addingFriend)
        XCTAssertTrue(vm.codeInput.isEmpty); XCTAssertTrue(vm.searchQuery.isEmpty); XCTAssertFalse(vm.loaded)
    }
    func testNewAccountGetsItsOwnWorkspaceNotPreviousUsersRows() async {
        let (db, _, _, old) = fixture(); _ = pair(db, a, c); _ = pair(db, b, d)
        await old.refresh(); old.invalidate()
        let fresh = ServerFriendsViewModel(repository: SupabaseFriendRepository(userID: b, transport: FriendMemoryTransport(userID: b, db: db)))
        XCTAssertTrue(fresh.friends.isEmpty); await fresh.refresh()
        XCTAssertEqual(fresh.friends.map(\.userID), [d]); XCTAssertTrue(old.friends.isEmpty)
    }
    func testSessionFailureClearsStateAndNotifiesAuthGate() async {
        let (db, repo, transport, _) = fixture(); _ = pair(db, a, b); var notified = false
        let vm = ServerFriendsViewModel(repository: repo, sessionFailure: { _ in notified = true })
        await vm.refresh(); transport.sessionValid = false; await vm.refresh()
        XCTAssertTrue(notified); XCTAssertTrue(vm.friends.isEmpty); XCTAssertFalse(vm.loaded)
    }
    func testLateSearchResultAfterLogoutIsIgnored() async {
        let (db, _, _, vm) = fixture(); vm.codeInput = "BBBB0002"; db.onProfile = { vm.invalidate() }
        await vm.findUser(); XCTAssertNil(vm.candidate); XCTAssertNil(vm.relationship); XCTAssertFalse(vm.isBusy)
    }
    func testChangingSearchCodeInvalidatesPreviouslyConfirmedRecipient() async {
        let (db, _, _, vm) = fixture(); vm.codeInput = "BBBB0002"; await vm.findUser()
        vm.codeInput = "CCCC0003"; await vm.sendRequest()
        XCTAssertNil(vm.candidate); XCTAssertEqual(db.insertCount, 0)
    }
    func testFailedAcceptOrDeleteKeepsExistingUIRows() async throws {
        let (db, _, _, vm) = fixture(); let r = request(db, from: c, to: a); _ = pair(db, a, b)
        await vm.refresh(); db.rpcFailure = FriendshipError.unavailable
        await vm.accept(r.id); XCTAssertEqual(vm.incoming.map(\.id), [r.id])
        let friend = try XCTUnwrap(vm.friends.first); await vm.remove(friend); XCTAssertEqual(vm.friends, [friend])
        XCTAssertNotNil(vm.errorMessage)
    }
    func testThirdUserSnapshotCannotSeePairOrRequests() async throws {
        let (db, _, _, _) = fixture(); _ = pair(db, a, b); _ = request(db, from: a, to: b)
        let third = SupabaseFriendRepository(userID: c, transport: FriendMemoryTransport(userID: c, db: db))
        let snapshot = try await third.snapshot()
        XCTAssertTrue(snapshot.friends.isEmpty); XCTAssertTrue(snapshot.incoming.isEmpty); XCTAssertTrue(snapshot.outgoing.isEmpty)
    }
    func testSDKJWTFailuresMapToAuthWithoutMisclassifyingSQLConstraints() {
        for code in ["PGRST301", "PGRST302", "PGRST303"] {
            let error = SupabaseFriendTransport.mappedError(PostgrestError(code: code, message: "JWT"))
            XCTAssertEqual(error as? CollaborationAuthError, .sessionMissing)
        }
        for code in ["23505", "23503", "42501"] {
            let error = SupabaseFriendTransport.mappedError(PostgrestError(code: code, message: "DB"))
            XCTAssertEqual((error as? PostgrestError)?.code, code)
        }
    }
    func testRequestCodingUsesExactContractWithoutProfileSnapshots() throws {
        let db = FriendMemoryDatabase(); let r = request(db, from: a, to: b)
        let data = try JSONEncoder().encode(r)
        let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(value["sender_id"] as? String, a.uuidString); XCTAssertEqual(value["receiver_id"] as? String, b.uuidString)
        XCTAssertNotNil(value["created_at"]); XCTAssertNotNil(value["updated_at"])
        XCTAssertNil(value["sender_display_name"]); XCTAssertNil(value["email"]); XCTAssertNil(value["metadata"])
        XCTAssertEqual(try JSONDecoder().decode(FriendRequest.self, from: data), r)
    }
}

// Fake server honors pending unordered-pair uniqueness and receiver/participant RPC permissions.
// There is no SupabaseClient, credential, network, or real user row in this test boundary.
@MainActor private final class FriendMemoryDatabase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var people: [UUID: CollaborationProfile] = [:]
    var requests: [FriendRequest] = []
    var pairs: [FriendshipRecord] = []
    var insertCount = 0, acceptCount = 0, rejectCount = 0, removeCount = 0, pairReads = 0, profileReads = 0
    var insertFailure: Error?, readFailure: Error?, rpcFailure: Error?
    var beforeInsert: (() -> Void)?, onRead: (() -> Void)?, onProfile: (() -> Void)?
    var returnUnscopedRows = false
}
@MainActor private final class FriendMemoryTransport: FriendTransport {
    let userID: UUID; let db: FriendMemoryDatabase; var sessionValid = true
    init(userID: UUID, db: FriendMemoryDatabase) { self.userID = userID; self.db = db }
    func authorize() async throws { guard sessionValid else { throw CollaborationAuthError.sessionMissing } }
    func profile(code: FriendCode) async throws -> CollaborationProfile? { db.onProfile?(); db.profileReads += 1; return db.people.values.first { $0.friendCode == code.rawValue } }
    func profile(id: UUID) async throws -> CollaborationProfile? { db.profileReads += 1; return db.people[id] }
    func profiles(ids: Set<UUID>) async throws -> [CollaborationProfile] { db.profileReads += 1; return ids.compactMap { db.people[$0] } }
    func requests(incoming: Bool) async throws -> [FriendRequest] {
        if let error = db.readFailure { throw error }; db.onRead?()
        if db.returnUnscopedRows { return db.requests }
        return db.requests.filter { $0.status == .pending && (incoming ? $0.receiverID == userID : $0.senderID == userID) }
    }
    func pendingPair(with user: UUID) async throws -> FriendRequest? {
        db.pairReads += 1
        return db.requests.first { $0.status == .pending && Set([$0.senderID,$0.receiverID]) == Set([userID,user]) }
    }
    func activeFriendships() async throws -> [FriendshipRecord] {
        if let error = db.readFailure { throw error }
        return db.returnUnscopedRows ? db.pairs : db.pairs.filter { $0.otherUser(than: userID) != nil }
    }
    func activePair(with user: UUID) async throws -> FriendshipRecord? { db.pairs.first { $0.otherUser(than: userID) == user } }
    func insertRequest(receiver: UUID) async throws -> FriendRequest {
        try await authorize(); db.insertCount += 1; db.beforeInsert?(); db.beforeInsert = nil
        if let error = db.insertFailure { throw error }
        guard receiver != userID else { throw FriendshipError.selfRequest }
        guard !db.requests.contains(where: { $0.status == .pending && Set([$0.senderID,$0.receiverID]) == Set([userID,receiver]) }) else { throw FriendshipError.uniqueConflict }
        let r = FriendRequest(id: UUID(), senderID: userID, receiverID: receiver, status: .pending, createdAt: db.now, updatedAt: db.now, respondedAt: nil)
        db.requests.append(r); return r
    }
    func accept(id: UUID) async throws -> UUID {
        try await authorize(); if let error = db.rpcFailure { throw error }
        guard let i = db.requests.firstIndex(where: { $0.id == id && $0.receiverID == userID && $0.status == .pending }) else { throw FriendshipError.unavailable }
        let old = db.requests[i]; db.acceptCount += 1
        db.requests[i] = FriendRequest(id: old.id, senderID: old.senderID, receiverID: old.receiverID, status: .accepted, createdAt: old.createdAt, updatedAt: db.now, respondedAt: db.now)
        if let pair = db.pairs.first(where: { $0.otherUser(than: userID) == old.senderID }) { return pair.id }
        let users = [userID, old.senderID].sorted { $0.uuidString < $1.uuidString }
        let pair = FriendshipRecord(id: UUID(), userAID: users[0], userBID: users[1], createdAt: db.now, endedAt: nil)
        db.pairs.append(pair); return pair.id
    }
    func reject(id: UUID) async throws {
        try await authorize(); if let error = db.rpcFailure { throw error }
        guard let i = db.requests.firstIndex(where: { $0.id == id && $0.receiverID == userID && $0.status == .pending }) else { throw FriendshipError.unavailable }
        let old = db.requests[i]; db.rejectCount += 1
        db.requests[i] = FriendRequest(id: old.id, senderID: old.senderID, receiverID: old.receiverID, status: .rejected, createdAt: old.createdAt, updatedAt: db.now, respondedAt: db.now)
    }
    func remove(id: UUID) async throws {
        try await authorize(); if let error = db.rpcFailure { throw error }
        guard let i = db.pairs.firstIndex(where: { $0.id == id && ($0.userAID == userID || $0.userBID == userID) }) else { throw FriendshipError.unavailable }
        let old = db.pairs[i]; db.removeCount += 1
        db.pairs[i] = FriendshipRecord(id: old.id, userAID: old.userAID, userBID: old.userBID, createdAt: old.createdAt, endedAt: db.now)
    }
}
