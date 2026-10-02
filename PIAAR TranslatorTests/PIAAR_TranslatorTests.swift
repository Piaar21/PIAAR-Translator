import XCTest
import CloudKit
import Combine
import SwiftData
import AppKit
import Carbon.HIToolbox
import Security
@testable import PIAAR_Translator

final class PIAAR_TranslatorTests: XCTestCase {
    @MainActor
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "PIAAR.Stabilization.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @MainActor
    func testExistingStorageIdentifiers() {
        XCTAssertEqual(GlobalHotKeyManager.keyCodeDefaultsKey, "PIAARHotKeyKeyCode")
        XCTAssertEqual(GlobalHotKeyManager.modifiersDefaultsKey, "PIAARHotKeyModifiers")
        XCTAssertEqual(KeychainManager.service, "OPENAI_CLIPBOARD_TRANSLATOR")
        XCTAssertEqual(KeychainManager.account, NSUserName())
        XCTAssertEqual(Bundle(for: TranslatorViewModel.self).bundleIdentifier, "com.piaar.PIAAR-Translator")
    }

    @MainActor
    func testLegacyShortcutLoadsWithoutRewritingDefaults() {
        withDefaults { defaults in
            defaults.set(Int(kVK_ANSI_A), forKey: "PIAARHotKeyKeyCode")
            defaults.set(Int(cmdKey | shiftKey), forKey: "PIAARHotKeyModifiers")
            let before = defaults.dictionaryRepresentation() as NSDictionary
            let manager = GlobalHotKeyManager(defaults: defaults, registration: { _ in nil })
            XCTAssertEqual(manager.shortcut, GlobalHotKeyShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | shiftKey)))
            XCTAssertTrue(manager.register())
            XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
        }
    }

    @MainActor
    func testMissingShortcutUsesDefaultWithoutWriting() {
        withDefaults { defaults in
            let manager = GlobalHotKeyManager(defaults: defaults, registration: { _ in nil })
            XCTAssertEqual(manager.shortcut, .defaultShortcut)
            XCTAssertTrue(manager.register())
            XCTAssertNil(defaults.object(forKey: "PIAARHotKeyKeyCode"))
            XCTAssertNil(defaults.object(forKey: "PIAARHotKeyModifiers"))
        }
    }

    @MainActor
    func testMalformedShortcutValuesNeverOverwriteStoredValues() {
        let cases: [(Any?, Any?)] = [
            (-1, controlKey), (Int64.max, controlKey), (128, controlKey),
            (1.5, controlKey), (true, controlKey), ("17", controlKey),
            ([17], controlKey), (17, nil), (nil, controlKey),
            (17, -1), (17, 0), (17, Int64.max), (17, 1.5),
            (17, true), (17, "4096"), (17, 1), (17, [controlKey])
        ]
        for (key, flags) in cases {
            withDefaults { defaults in
                if let key { defaults.set(key, forKey: "PIAARHotKeyKeyCode") }
                if let flags { defaults.set(flags, forKey: "PIAARHotKeyModifiers") }
                let before = defaults.dictionaryRepresentation() as NSDictionary
                let manager = GlobalHotKeyManager(defaults: defaults, registration: { _ in nil })
                XCTAssertEqual(manager.shortcut, .defaultShortcut)
                XCTAssertTrue(manager.register())
                XCTAssertNotNil(manager.registrationError)
                XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
            }
        }
    }

    @MainActor
    func testNonFiniteShortcutValuesAreRejected() {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(GlobalHotKeyManager.decodeShortcut(keyCode: value, modifiers: controlKey))
            XCTAssertNil(GlobalHotKeyManager.decodeShortcut(keyCode: 17, modifiers: value))
        }
        // A is key code zero and must remain a valid shortcut.
        XCTAssertNotNil(GlobalHotKeyManager.decodeShortcut(keyCode: 0, modifiers: cmdKey))
    }

    @MainActor
    func testFailedShortcutChangeRestoresPreviousAndPreservesError() {
        withDefaults { defaults in
            defaults.set(17, forKey: "PIAARHotKeyKeyCode")
            defaults.set(Int(controlKey), forKey: "PIAARHotKeyModifiers")
            let before = defaults.dictionaryRepresentation() as NSDictionary
            var attempts: [GlobalHotKeyShortcut] = []
            let manager = GlobalHotKeyManager(defaults: defaults, registration: { shortcut in
                attempts.append(shortcut)
                return shortcut.keyCode == 0 ? "conflict -9878" : nil
            })
            XCTAssertFalse(manager.updateShortcut(keyCode: 0, modifiers: UInt32(cmdKey)))
            XCTAssertEqual(attempts.map(\.keyCode), [0, 17])
            XCTAssertEqual(manager.shortcut, .defaultShortcut)
            XCTAssertTrue(manager.registrationError?.contains("conflict -9878") == true)
            XCTAssertTrue(manager.registrationError?.contains("복구했습니다") == true)
            XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
        }
    }

    @MainActor
    func testFailedRollbackReportsBothErrorsAndPreservesSettings() {
        withDefaults { defaults in
            let manager = GlobalHotKeyManager(defaults: defaults, registration: {
                $0.keyCode == 0 ? "new failure" : "restore failure"
            })
            XCTAssertFalse(manager.updateShortcut(keyCode: 0, modifiers: UInt32(cmdKey)))
            XCTAssertTrue(manager.registrationError?.contains("new failure") == true)
            XCTAssertTrue(manager.registrationError?.contains("restore failure") == true)
            XCTAssertEqual(manager.shortcut, .defaultShortcut)
            XCTAssertNil(defaults.object(forKey: "PIAARHotKeyKeyCode"))
        }
    }

    @MainActor
    func testInvalidChangeDoesNotAttemptRegistration() {
        withDefaults { defaults in
            let manager = GlobalHotKeyManager(defaults: defaults, registration: { _ in
                XCTFail("Invalid input must not unregister or register a shortcut")
                return nil
            })
            XCTAssertFalse(manager.updateShortcut(keyCode: .max, modifiers: UInt32(cmdKey)))
            XCTAssertFalse(manager.updateShortcut(keyCode: 17, modifiers: 0))
            XCTAssertNil(defaults.object(forKey: "PIAARHotKeyKeyCode"))
        }
    }

    @MainActor
    func testSuccessfulShortcutChangeUsesLegacyKeys() {
        withDefaults { defaults in
            let manager = GlobalHotKeyManager(defaults: defaults, registration: { _ in nil })
            XCTAssertTrue(manager.updateShortcut(keyCode: 0, modifiers: UInt32(cmdKey)))
            XCTAssertEqual(defaults.integer(forKey: "PIAARHotKeyKeyCode"), 0)
            XCTAssertEqual(defaults.integer(forKey: "PIAARHotKeyModifiers"), Int(cmdKey))
            XCTAssertNil(manager.registrationError)
        }
    }

    @MainActor
    func testKeychainSuccessfulReadUsesLegacyQuery() throws {
        let key = try KeychainManager.loadAPIKey { query, result in
            let query = query as NSDictionary
            XCTAssertEqual(query[kSecClass] as? String, kSecClassGenericPassword as String)
            XCTAssertEqual(query[kSecAttrService] as? String, "OPENAI_CLIPBOARD_TRANSLATOR")
            XCTAssertEqual(query[kSecAttrAccount] as? String, NSUserName())
            XCTAssertNil(query[kSecAttrAccessGroup])
            XCTAssertNil(query[kSecAttrSynchronizable])
            result?.pointee = Data(" fixture-key \n".utf8) as CFData
            return errSecSuccess
        }
        XCTAssertEqual(key, "fixture-key")
    }

    @MainActor
    func testKeychainNotFoundIsDistinctFromAccessFailure() {
        XCTAssertThrowsError(try KeychainManager.loadAPIKey { _, _ in errSecItemNotFound }) {
            guard case TranslatorError.apiKeyNotFound = $0 else {
                return XCTFail("Expected item not found, got \($0)")
            }
        }
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecNotAvailable, errSecUserCanceled] {
            XCTAssertThrowsError(try KeychainManager.loadAPIKey { _, _ in status }) {
                XCTAssertEqual($0 as? KeychainReadError, .access(status))
            }
            XCTAssertEqual(KeychainManager.apiKeyStatus { _, _ in status }, .failure(status))
        }
    }

    @MainActor
    func testInvalidKeychainDataIsNotReportedAsMissing() {
        for data: Data? in [nil, Data(), Data([0xFF]), Data(" \n".utf8)] {
            XCTAssertThrowsError(try KeychainManager.loadAPIKey { _, result in
                result?.pointee = data.map { $0 as CFData }
                return errSecSuccess
            }) {
                XCTAssertEqual($0 as? KeychainReadError, .invalidData)
            }
        }
    }

    @MainActor
    func testKeychainStatusRefreshDistinguishesAccessErrorAndRecovers() {
        var status = errSecSuccess
        let manager = KeychainManager(copyItem: { query, _ in
            let query = query as NSDictionary
            XCTAssertEqual(query[kSecAttrService] as? String, "OPENAI_CLIPBOARD_TRANSLATOR")
            XCTAssertEqual(query[kSecAttrAccount] as? String, NSUserName())
            return status
        })
        XCTAssertEqual(manager.lookupStatus, .found)
        status = errSecInteractionNotAllowed
        manager.refreshStatus()
        XCTAssertEqual(manager.lookupStatus, .failure(status))
        XCTAssertTrue(manager.isError)
        XCTAssertEqual(manager.apiKeyStatusText, "API Key 상태를 확인할 수 없습니다.")
        XCTAssertNotNil(manager.statusMessage)
        status = errSecSuccess
        manager.refreshStatus()
        XCTAssertTrue(manager.hasAPIKey)
        XCTAssertFalse(manager.isError)
        XCTAssertNil(manager.statusMessage)
        status = errSecItemNotFound
        manager.refreshStatus()
        XCTAssertEqual(manager.lookupStatus, .notFound)
        XCTAssertFalse(manager.isError)
    }

    @MainActor
    func testUnchangedClipboardIsNotASelectionAndEmptyClipboardClearsOriginal() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("old clipboard", forType: .string)
        let previous = pasteboard.changeCount
        XCTAssertNil(TranslatorViewModel.copiedSelection(from: pasteboard, after: previous))
        pasteboard.clearContents()
        pasteboard.setString(" new selection \n", forType: .string)
        XCTAssertEqual(TranslatorViewModel.copiedSelection(from: pasteboard, after: previous), "new selection")
        let model = TranslatorViewModel(service: ControlledTranslationService())
        model.originalText = "stale original"
        pasteboard.clearContents()
        model.loadClipboard(from: pasteboard)
        XCTAssertEqual(model.originalText, "")
        pasteboard.setString(" \n", forType: .string)
        XCTAssertNil(TranslatorViewModel.copiedSelection(from: pasteboard, after: previous))
    }

    @MainActor
    func testFailedSelectionDoesNotTranslateStaleOriginal() async {
        let model = TranslatorViewModel(service: ControlledTranslationService())
        model.originalText = "stale original"
        model.translatedText = "stale translation"
        await model.prepareTranslation(text: nil)
        XCTAssertEqual(model.originalText, "")
        XCTAssertEqual(model.translatedText, "")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isTranslating)
    }

    @MainActor
    func testNewIncomingRequestCancelsAndRejectsOlderResponse() async {
        let started = expectation(description: "two requests")
        started.expectedFulfillmentCount = 2
        let service = ControlledTranslationService(incomingStarted: started)
        let model = TranslatorViewModel(service: service)
        model.originalText = "old"
        let old = Task { await model.translateOriginal() }
        await service.waitUntilIncomingExists("old")
        model.originalText = "new"
        let new = Task { await model.translateOriginal() }
        await fulfillment(of: [started], timeout: 3)
        await service.finishIncoming("new", result: .success("new translation"))
        await new.value
        await service.finishIncoming("old", result: .success("old translation"))
        await old.value
        XCTAssertEqual(model.translatedText, "new translation")
        XCTAssertEqual(model.suggestions, ["new suggestion"])
        XCTAssertNil(model.errorMessage)
        let cancelled = await service.cancelledIncoming
        XCTAssertTrue(cancelled.contains("old"))
    }

    @MainActor
    func testNewConversationRejectsLateError() async {
        let service = ControlledTranslationService()
        let model = TranslatorViewModel(service: service)
        model.originalText = "old"
        let task = Task { await model.translateOriginal() }
        await service.waitUntilIncomingExists("old")
        model.clearConversation()
        await service.finishIncoming("old", result: .failure(TranslatorError.apiError("late error")))
        await task.value
        XCTAssertEqual(model.originalText, "")
        XCTAssertEqual(model.translatedText, "")
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isTranslating)
        XCTAssertFalse(model.shouldFocusReply)
    }

    @MainActor
    func testNewConversationRejectsLateSuggestions() async {
        let started = expectation(description: "suggestions started")
        let service = ControlledTranslationService(suggestionsStarted: started)
        let model = TranslatorViewModel(service: service)
        model.originalText = "old"
        let task = Task { await model.translateOriginal() }
        await service.waitUntilIncomingExists("old")
        await service.finishIncoming("old", result: .success("translated"))
        await fulfillment(of: [started], timeout: 3)
        model.clearConversation()
        await service.finishSuggestions()
        await task.value
        XCTAssertTrue(model.suggestions.isEmpty)
        XCTAssertEqual(model.translatedText, "")
        XCTAssertFalse(model.isGeneratingSuggestions)
        XCTAssertFalse(model.shouldFocusReply)
    }

    @MainActor
    func testNewReplyRejectsOlderResponseAndValidatesCurrentNumbers() async {
        let service = ControlledTranslationService()
        let model = TranslatorViewModel(service: service)
        model.replyText = "old 1"
        let old = Task { await model.translateReply() }
        await service.waitUntilReplyExists("old 1")
        model.replyText = "new 2"
        let new = Task { await model.translateReply() }
        await service.waitUntilReplyExists("new 2")
        await service.finishReply("new 2", text: "reply 2")
        await new.value
        await service.finishReply("old 1", text: "reply 1")
        await old.value
        XCTAssertEqual(model.translatedReplyText, "reply 2")
        XCTAssertFalse(model.numberMismatch)
        XCTAssertFalse(model.isReplyTranslating)
        let cancelled = await service.cancelledReplies
        XCTAssertTrue(cancelled.contains("old 1"))
    }

    @MainActor
    func testNewConversationRejectsLateReply() async {
        let service = ControlledTranslationService()
        let model = TranslatorViewModel(service: service)
        model.replyText = "old"
        let task = Task { await model.retranslateReply() }
        await service.waitUntilReplyExists("old")
        model.clearConversation()
        await service.finishReply("old", text: "late reply")
        await task.value
        XCTAssertEqual(model.translatedReplyText, "")
        XCTAssertFalse(model.isReplyTranslating)
        XCTAssertNil(model.errorMessage)
    }
}

// Deliberately ignores cancellation while suspended, like a late network callback.
private actor ControlledTranslationService: TranslationService {
    let incomingStarted: XCTestExpectation?
    let suggestionsStarted: XCTestExpectation?
    private var incoming: [String: CheckedContinuation<String, Error>] = [:]
    private var replies: [String: CheckedContinuation<String, Error>] = [:]
    private var suggestions: CheckedContinuation<[String], Error>?
    private(set) var cancelledIncoming: [String] = []
    private(set) var cancelledReplies: [String] = []

    init(incomingStarted: XCTestExpectation? = nil, suggestionsStarted: XCTestExpectation? = nil) {
        self.incomingStarted = incomingStarted
        self.suggestionsStarted = suggestionsStarted
    }

    func translateReceivedMessage(_ text: String, history: [ConversationMessage]) async throws -> String {
        defer { if Task.isCancelled { cancelledIncoming.append(text) } }
        return try await withCheckedThrowingContinuation {
            incoming[text] = $0
            incomingStarted?.fulfill()
        }
    }

    func generateReplySuggestions(originalMessage: String, translatedMessage: String,
                                  history: [ConversationMessage]) async throws -> [String] {
        if let suggestionsStarted {
            return try await withCheckedThrowingContinuation {
                suggestions = $0
                suggestionsStarted.fulfill()
            }
        }
        return ["\(originalMessage) suggestion"]
    }

    func translateReply(reply: String, originalMessage: String, translatedMessage: String,
                        history: [ConversationMessage], alternativeTo: String?) async throws -> String {
        defer { if Task.isCancelled { cancelledReplies.append(reply) } }
        return try await withCheckedThrowingContinuation { replies[reply] = $0 }
    }

    func waitUntilIncomingExists(_ text: String) async {
        for _ in 0..<300 {
            if incoming[text] != nil { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Incoming request did not start: \(text)")
    }

    func waitUntilReplyExists(_ text: String) async {
        for _ in 0..<300 {
            if replies[text] != nil { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Reply request did not start: \(text)")
    }

    func finishIncoming(_ text: String, result: Result<String, Error>) {
        incoming.removeValue(forKey: text)?.resume(with: result)
    }

    func finishReply(_ reply: String, text: String) {
        replies.removeValue(forKey: reply)?.resume(returning: text)
    }

    func finishSuggestions() {
        suggestions?.resume(returning: ["late suggestion"])
        suggestions = nil
    }
}

@MainActor private final class FakeCloudAccountService: CloudKitAccountChecking {
    var response: Result<CloudAccountState, Error>
    private(set) var calls = 0
    init(_ response: Result<CloudAccountState, Error>) { self.response = response }
    func accountState() async throws -> CloudAccountState { calls += 1; return try response.get() }
}

final class CloudAccountDiagnosticsTests: XCTestCase {
    @MainActor func testAvailableMappingIsOnlyAccountPrerequisite() {
        XCTAssertEqual(CloudKitAccountService.map(.available), .available)
        XCTAssertTrue(CloudKitAccountService.map(.available).permitsPrivateDatabaseAccount)
    }
    @MainActor func testNoAccountMapping() { XCTAssertEqual(CloudKitAccountService.map(.noAccount), .noAccount) }
    @MainActor func testRestrictedMapping() { XCTAssertEqual(CloudKitAccountService.map(.restricted), .restricted) }
    @MainActor func testCouldNotDetermineMapping() { XCTAssertEqual(CloudKitAccountService.map(.couldNotDetermine), .couldNotDetermine) }
    @MainActor func testTemporarilyUnavailableMapping() { XCTAssertEqual(CloudKitAccountService.map(.temporarilyUnavailable), .temporarilyUnavailable) }
    @MainActor func testFutureStatusMapsSafely() throws {
        let status = try XCTUnwrap(CKAccountStatus(rawValue: 999))
        XCTAssertEqual(CloudKitAccountService.map(status), .unknown)
        XCTAssertFalse(CloudAccountState.unknown.permitsPrivateDatabaseAccount)
    }
    @MainActor func testErrorPreservedAndRefreshRecovers() async {
        let fake = FakeCloudAccountService(.failure(NSError(domain: "diagnostic", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "offline diagnostic"])))
        let model = CloudAccountDiagnostics(service: fake)
        XCTAssertEqual(fake.calls, 0); XCTAssertEqual(model.state, .notChecked)
        await model.refresh()
        XCTAssertEqual(model.state, .error(message: "offline diagnostic"))
        XCTAssertFalse(model.isChecking)
        fake.response = .success(.available)
        await model.refresh()
        XCTAssertEqual(model.state.label, "연결됨"); XCTAssertEqual(fake.calls, 2)
    }
    @MainActor func testAccountChangedNotificationRefreshesFakeOnly() async {
        let fake = FakeCloudAccountService(.success(.noAccount))
        let model = CloudAccountDiagnostics(service: fake)
        let center = NotificationCenter()
        await model.refresh()
        model.startMonitoring(center: center)
        model.startMonitoring(center: center)
        fake.response = .success(.available)
        let changed = expectation(description: "account state refreshed")
        let observation = model.$state.dropFirst().sink { if $0 == .available { changed.fulfill() } }
        center.post(name: .CKAccountChanged, object: nil)
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(fake.calls, 2)
        observation.cancel(); model.stopMonitoring()
    }
    @MainActor func testCloudFailureDoesNotPreventTodoOrMockCollaboration() async throws {
        let fake = FakeCloudAccountService(.failure(NSError(domain: "offline", code: 1)))
        let diagnostics = CloudAccountDiagnostics(service: fake)
        await diagnostics.refresh()
        let repo = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true))
        let todo = try TodoViewModel(repository: repo)
        todo.quickTitle = "local still works"
        XCTAssertTrue(todo.submitTodayQuickEntry())
        XCTAssertEqual(try repo.allTodos().count, 1)
        let env = MockCollaborationEnvironment(seedReceivedTasks: false)
        let workspace = CollaborationWorkspace(environment: env)
        await workspace.friends.load()
        workspace.friends.codeInput = "B3821K7M"
        await workspace.friends.addFriend()
        let friend = try XCTUnwrap(workspace.friends.friends.first)
        let sent = await workspace.sharedTasks.sendNewTask(title: "mock still works", deadline: nil,
            receiverID: friend.user.id, requestID: UUID())
        XCTAssertTrue(sent); XCTAssertEqual(workspace.sharedTasks.sent.count, 1)
        let room = await workspace.rooms.createRoom(name: "mock room", invited: [friend.user.id])
        XCTAssertNotNil(room)
        XCTAssertEqual(fake.calls, 1)
    }
}
