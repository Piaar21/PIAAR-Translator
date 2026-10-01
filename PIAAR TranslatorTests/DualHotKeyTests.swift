import XCTest
import AppKit
import Carbon.HIToolbox
@testable import PIAAR_Translator

final class DualHotKeyTests: XCTestCase {
    @MainActor
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "PIAAR.DualHotKey.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @MainActor
    private func makePair(_ defaults: UserDefaults) -> GlobalHotKeyPair {
        GlobalHotKeyPair(defaults: defaults, translatorRegistration: { _ in nil },
                         todoRegistration: { _ in nil })
    }

    @MainActor
    private func makeWorkCoordinator(_ created: @escaping () -> Void = {}) -> WorkWindowCoordinator {
        WorkWindowCoordinator {
            created()
            let store = TodoWorkspaceStore {
                SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true))
            }
            store.load()
            return self.identifyTodoTestController(WorkWindowController(openTranslator: {}, openSettings: {}, todoStore: store))
        }
    }

    @MainActor
    func testTodoDefaultIsControlRWithoutWritingDefaults() {
        withDefaults { defaults in
            let before = defaults.dictionaryRepresentation() as NSDictionary
            let pair = makePair(defaults)
            XCTAssertEqual(pair.todo.shortcut.keyCode, UInt32(kVK_ANSI_R))
            XCTAssertEqual(pair.todo.shortcut.modifiers, UInt32(controlKey))
            XCTAssertEqual(pair.todo.shortcut.displayText, "⌃R")
            XCTAssertEqual(pair.translator.shortcut, .defaultShortcut)
            XCTAssertTrue(pair.register().todo)
            XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
        }
    }

    @MainActor
    func testStorageKeysAndCarbonIDsAreSeparate() {
        withDefaults { defaults in
            let pair = makePair(defaults)
            XCTAssertEqual(GlobalHotKeyManager.todoKeyCodeDefaultsKey, "PIAARTodoHotKeyKeyCode")
            XCTAssertEqual(GlobalHotKeyManager.todoModifiersDefaultsKey, "PIAARTodoHotKeyModifiers")
            XCTAssertEqual(pair.translator.carbonID, 1)
            XCTAssertEqual(pair.todo.carbonID, 2)
            XCTAssertEqual(GlobalHotKeyManager.carbonSignature, 0x50494152)
            XCTAssertNotEqual(pair.translator.carbonID, pair.todo.carbonID)
        }
    }

    @MainActor
    func testSavedTodoLoadsWithoutChangingTranslatorOrDefaults() {
        withDefaults { defaults in
            defaults.set(Int(kVK_ANSI_A), forKey: "PIAARHotKeyKeyCode")
            defaults.set(Int(cmdKey | shiftKey), forKey: "PIAARHotKeyModifiers")
            defaults.set(Int(kVK_ANSI_B), forKey: "PIAARTodoHotKeyKeyCode")
            defaults.set(Int(optionKey | controlKey), forKey: "PIAARTodoHotKeyModifiers")
            let before = defaults.dictionaryRepresentation() as NSDictionary
            let pair = makePair(defaults)
            XCTAssertEqual(pair.translator.shortcut.keyCode, UInt32(kVK_ANSI_A))
            XCTAssertEqual(pair.todo.shortcut, GlobalHotKeyShortcut(keyCode: UInt32(kVK_ANSI_B),
                                                                  modifiers: UInt32(optionKey | controlKey)))
            XCTAssertTrue(pair.register().todo)
            XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
        }
    }

    @MainActor
    func testTodoSaveReloadAndRestoreControlR() {
        withDefaults { defaults in
            let pair = makePair(defaults)
            XCTAssertTrue(pair.todo.updateShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey)))
            XCTAssertEqual(defaults.integer(forKey: "PIAARTodoHotKeyKeyCode"), Int(kVK_ANSI_A))
            XCTAssertEqual(defaults.integer(forKey: "PIAARTodoHotKeyModifiers"), Int(cmdKey))
            let reloaded = makePair(defaults)
            XCTAssertEqual(reloaded.todo.shortcut, pair.todo.shortcut)
            XCTAssertTrue(reloaded.todo.restoreDefault())
            XCTAssertEqual(reloaded.todo.shortcut, .defaultTodoShortcut)
            XCTAssertEqual(makePair(defaults).todo.shortcut.displayText, "⌃R")
            XCTAssertNil(defaults.object(forKey: "PIAARHotKeyKeyCode"))
            XCTAssertNil(defaults.object(forKey: "PIAARHotKeyModifiers"))
        }
    }

    @MainActor
    func testUpdatingEachShortcutPreservesTheOther() {
        withDefaults { defaults in
            let pair = makePair(defaults)
            XCTAssertTrue(pair.translator.updateShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey)))
            let translator = pair.translator.shortcut
            XCTAssertTrue(pair.todo.updateShortcut(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(optionKey)))
            XCTAssertEqual(pair.translator.shortcut, translator)
            let todo = pair.todo.shortcut
            XCTAssertTrue(pair.translator.restoreDefault())
            XCTAssertEqual(pair.todo.shortcut, todo)
            XCTAssertEqual(defaults.integer(forKey: "PIAARTodoHotKeyKeyCode"), Int(kVK_ANSI_B))
            XCTAssertEqual(defaults.integer(forKey: "PIAARHotKeyKeyCode"), Int(kVK_ANSI_T))
        }
    }

    @MainActor
    func testSameShortcutRejectedInBothDirectionsBeforeRegistration() {
        withDefaults { defaults in
            var translatorAttempts = 0
            var todoAttempts = 0
            let pair = GlobalHotKeyPair(defaults: defaults, translatorRegistration: { _ in
                translatorAttempts += 1; return nil
            }, todoRegistration: { _ in todoAttempts += 1; return nil })
            _ = pair.register()
            let before = defaults.dictionaryRepresentation() as NSDictionary
            XCTAssertFalse(pair.todo.updateShortcut(keyCode: pair.translator.shortcut.keyCode,
                                                    modifiers: pair.translator.shortcut.modifiers))
            XCTAssertFalse(pair.translator.updateShortcut(keyCode: pair.todo.shortcut.keyCode,
                                                          modifiers: pair.todo.shortcut.modifiers))
            XCTAssertEqual(translatorAttempts, 1)
            XCTAssertEqual(todoAttempts, 1)
            XCTAssertTrue(pair.translator.isRegistered)
            XCTAssertTrue(pair.todo.isRegistered)
            XCTAssertEqual(pair.todo.registrationError, GlobalHotKeyManager.conflictMessage)
            XCTAssertEqual(pair.translator.registrationError, GlobalHotKeyManager.conflictMessage)
            XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
        }
    }

    @MainActor
    func testLegacyTranslatorControlRTakesPriorityAtStartup() {
        withDefaults { defaults in
            defaults.set(Int(kVK_ANSI_R), forKey: "PIAARHotKeyKeyCode")
            defaults.set(Int(controlKey), forKey: "PIAARHotKeyModifiers")
            let before = defaults.dictionaryRepresentation() as NSDictionary
            let pair = makePair(defaults)
            let result = pair.register()
            XCTAssertTrue(result.translator)
            XCTAssertFalse(result.todo)
            XCTAssertEqual(pair.translator.shortcut.displayText, "⌃R")
            XCTAssertEqual(pair.todo.registrationError, GlobalHotKeyManager.conflictMessage)
            XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
            XCTAssertTrue(pair.todo.updateShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey)))
            XCTAssertTrue(pair.translator.isRegistered)
            XCTAssertTrue(pair.todo.isRegistered)
        }
    }

    @MainActor
    func testRestoreDefaultConflictPreservesCustomTodo() {
        withDefaults { defaults in
            let pair = makePair(defaults)
            XCTAssertTrue(pair.todo.updateShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey)))
            XCTAssertTrue(pair.translator.updateShortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey)))
            let before = defaults.dictionaryRepresentation() as NSDictionary
            XCTAssertFalse(pair.todo.restoreDefault())
            XCTAssertEqual(pair.todo.shortcut.keyCode, UInt32(kVK_ANSI_A))
            XCTAssertTrue(pair.todo.isRegistered)
            XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
        }
    }

    @MainActor
    func testMalformedTodoDefaultsArePreserved() {
        let values: [(Any?, Any?)] = [
            (-1, controlKey), (128, controlKey), (true, controlKey), ("15", controlKey),
            (1.5, controlKey), (15, nil), (nil, controlKey), (15, 0), (15, -1),
            (15, 1.5), (15, true), (15, "4096"), (15, Int64.max), (15, [controlKey])
        ]
        for (key, flags) in values {
            withDefaults { defaults in
                if let key { defaults.set(key, forKey: "PIAARTodoHotKeyKeyCode") }
                if let flags { defaults.set(flags, forKey: "PIAARTodoHotKeyModifiers") }
                let before = defaults.dictionaryRepresentation() as NSDictionary
                let pair = makePair(defaults)
                XCTAssertEqual(pair.todo.shortcut, .defaultTodoShortcut)
                XCTAssertTrue(pair.register().todo)
                XCTAssertNotNil(pair.todo.registrationError)
                XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
            }
        }
    }

    @MainActor
    func testInvalidTodoChangeDoesNotUnregisterOrSave() {
        withDefaults { defaults in
            var attempts = 0
            let pair = GlobalHotKeyPair(defaults: defaults, translatorRegistration: { _ in nil },
                                       todoRegistration: { _ in attempts += 1; return nil })
            _ = pair.register()
            XCTAssertFalse(pair.todo.updateShortcut(keyCode: .max, modifiers: UInt32(cmdKey)))
            XCTAssertFalse(pair.todo.updateShortcut(keyCode: 15, modifiers: 0))
            XCTAssertTrue(pair.todo.isRegistered)
            XCTAssertEqual(attempts, 1)
            XCTAssertNil(defaults.object(forKey: "PIAARTodoHotKeyKeyCode"))
        }
    }

    @MainActor
    func testTodoRegistrationFailureRestoresPreviousAndPreservesDefaults() {
        withDefaults { defaults in
            defaults.set(Int(kVK_ANSI_B), forKey: "PIAARTodoHotKeyKeyCode")
            defaults.set(Int(optionKey), forKey: "PIAARTodoHotKeyModifiers")
            var attempts: [UInt32] = []
            let pair = GlobalHotKeyPair(defaults: defaults, translatorRegistration: { _ in nil },
                                       todoRegistration: { shortcut in
                attempts.append(shortcut.keyCode)
                return shortcut.keyCode == UInt32(kVK_ANSI_A) ? "new conflict -9878" : nil
            })
            _ = pair.register()
            let before = defaults.dictionaryRepresentation() as NSDictionary
            XCTAssertFalse(pair.todo.updateShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey)))
            XCTAssertEqual(attempts, [UInt32(kVK_ANSI_B), UInt32(kVK_ANSI_A), UInt32(kVK_ANSI_B)])
            XCTAssertTrue(pair.todo.isRegistered)
            XCTAssertTrue(pair.translator.isRegistered)
            XCTAssertEqual(pair.todo.shortcut.keyCode, UInt32(kVK_ANSI_B))
            XCTAssertTrue(pair.todo.registrationError?.contains("new conflict -9878") == true)
            XCTAssertTrue(pair.todo.registrationError?.contains("복구했습니다") == true)
            XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
        }
    }

    @MainActor
    func testTodoRollbackFailureReportsBothErrors() {
        withDefaults { defaults in
            let pair = GlobalHotKeyPair(defaults: defaults, translatorRegistration: { _ in nil },
                                       todoRegistration: {
                $0.keyCode == UInt32(kVK_ANSI_A) ? "new failure" : "restore failure"
            })
            XCTAssertFalse(pair.todo.updateShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey)))
            XCTAssertEqual(pair.todo.shortcut, .defaultTodoShortcut)
            XCTAssertFalse(pair.todo.isRegistered)
            XCTAssertTrue(pair.todo.registrationError?.contains("new failure") == true)
            XCTAssertTrue(pair.todo.registrationError?.contains("restore failure") == true)
            XCTAssertNil(defaults.object(forKey: "PIAARTodoHotKeyKeyCode"))
        }
    }

    @MainActor
    func testTodoRegistrationFailureDoesNotDisableTranslator() {
        withDefaults { defaults in
            let pair = GlobalHotKeyPair(defaults: defaults, translatorRegistration: { _ in nil },
                                       todoRegistration: { _ in "OS conflict" })
            let results = pair.register()
            XCTAssertTrue(results.translator)
            XCTAssertFalse(results.todo)
            var translations = 0
            pair.translator.onHotKeyPressed = { translations += 1 }
            XCTAssertTrue(pair.translator.receiveHotKey(signature: GlobalHotKeyManager.carbonSignature, id: 1))
            XCTAssertEqual(translations, 1)
        }
    }

    @MainActor
    func testCarbonEventsRouteOnlyToTheirOwnCallback() {
        withDefaults { defaults in
            let pair = makePair(defaults)
            _ = pair.register()
            var translations = 0
            var todos = 0
            pair.translator.onHotKeyPressed = { translations += 1 }
            pair.todo.onHotKeyPressed = { todos += 1 }
            XCTAssertFalse(pair.translator.receiveHotKey(signature: GlobalHotKeyManager.carbonSignature, id: 2))
            XCTAssertTrue(pair.todo.receiveHotKey(signature: GlobalHotKeyManager.carbonSignature, id: 2))
            XCTAssertEqual(translations, 0)
            XCTAssertEqual(todos, 1)
            XCTAssertFalse(pair.todo.receiveHotKey(signature: GlobalHotKeyManager.carbonSignature, id: 1))
            XCTAssertTrue(pair.translator.receiveHotKey(signature: GlobalHotKeyManager.carbonSignature, id: 1))
            XCTAssertEqual(translations, 1)
            XCTAssertEqual(todos, 1)
            XCTAssertFalse(pair.todo.receiveHotKey(signature: 0, id: 2))
            pair.unregister()
            XCTAssertFalse(pair.todo.receiveHotKey(signature: GlobalHotKeyManager.carbonSignature, id: 2))
            XCTAssertEqual(todos, 1)
        }
    }

    @MainActor
    func testRealCarbonHandlersDispatchBothIndependentIDs() async throws {
        let name = "PIAAR.Carbon.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        // Avoid taking the user's actual Translator/Todo shortcuts.
        let modifiers = Int(controlKey | optionKey | shiftKey | cmdKey)
        defaults.set(Int(kVK_F17), forKey: "PIAARHotKeyKeyCode")
        defaults.set(modifiers, forKey: "PIAARHotKeyModifiers")
        defaults.set(Int(kVK_F18), forKey: "PIAARTodoHotKeyKeyCode")
        defaults.set(modifiers, forKey: "PIAARTodoHotKeyModifiers")
        let pair = GlobalHotKeyPair(defaults: defaults)
        defer { pair.unregister() }
        let fired = expectation(description: "Both Carbon handlers dispatch")
        fired.expectedFulfillmentCount = 2
        var received: [UInt32] = []
        pair.translator.onHotKeyPressed = { received.append(1); fired.fulfill() }
        pair.todo.onHotKeyPressed = { received.append(2); fired.fulfill() }
        let registration = pair.register()
        XCTAssertTrue(registration.translator, pair.translator.registrationError ?? "")
        XCTAssertTrue(registration.todo, pair.todo.registrationError ?? "")
        guard registration.translator && registration.todo else { return }
        for id: UInt32 in [1, 2] {
            var event: EventRef?
            XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                       GetCurrentEventTime(), 0, &event), noErr)
            let created = try XCTUnwrap(event)
            defer { ReleaseEvent(created) }
            var hotKeyID = EventHotKeyID(signature: GlobalHotKeyManager.carbonSignature, id: id)
            XCTAssertEqual(SetEventParameter(created, EventParamName(kEventParamDirectObject),
                                              EventParamType(typeEventHotKeyID),
                                              MemoryLayout<EventHotKeyID>.size, &hotKeyID), noErr)
            XCTAssertEqual(SendEventToEventTarget(created, GetApplicationEventTarget()), noErr)
        }
        await fulfillment(of: [fired], timeout: 3)
        XCTAssertEqual(received, [1, 2])
    }

    @MainActor
    func testTodoHotKeySelectsTodoAndReusesWindowWithoutTranslatorCallback() {
        withDefaults { defaults in
            let pair = makePair(defaults)
            var created = 0
            var translations = 0
            let work = makeWorkCoordinator { created += 1 }
            defer { work.controller?.window?.close() }
            pair.todo.onHotKeyPressed = { work.showTodo() }
            pair.translator.onHotKeyPressed = { translations += 1 }
            _ = pair.register()
            XCTAssertNil(work.controller)
            XCTAssertTrue(pair.todo.receiveHotKey(signature: GlobalHotKeyManager.carbonSignature, id: 2))
            let first = work.controller
            XCTAssertEqual(first?.navigation.selection, .todo)
            XCTAssertTrue(first?.window?.isVisible == true)
            XCTAssertTrue(pair.todo.receiveHotKey(signature: GlobalHotKeyManager.carbonSignature, id: 2))
            XCTAssertTrue(work.controller === first)
            XCTAssertEqual(created, 1)
            XCTAssertEqual(translations, 0)
        }
    }

    @MainActor
    func testExistingAndClosedWorkWindowIsReusedForTodo() {
        var created = 0
        let work = makeWorkCoordinator { created += 1 }
        defer { work.controller?.window?.close() }
        work.showWork()
        let first = work.controller
        let window = first?.window
        XCTAssertEqual(first?.navigation.selection, .todo)
        work.showTodo()
        XCTAssertTrue(work.controller === first)
        XCTAssertTrue(work.controller?.window === window)
        XCTAssertEqual(first?.navigation.selection, .todo)
        window?.performClose(nil)
        XCTAssertFalse(window?.isVisible == true)
        work.showTodo()
        XCTAssertTrue(work.controller?.window === window)
        XCTAssertTrue(window?.isVisible == true)
        XCTAssertEqual(created, 1)
    }

    @MainActor
    func testNavigationPreservesTodoDraftValidation() {
        let navigation = WorkNavigationState()
        XCTAssertTrue(navigation.select(.todo))
        XCTAssertFalse(navigation.select(.translator, canLeaveTodo: { false }))
        XCTAssertEqual(navigation.selection, .todo)
        XCTAssertTrue(navigation.select(.todo, canLeaveTodo: { XCTFail("No exit validation on same feature"); return false }))
        XCTAssertTrue(navigation.select(.translator, canLeaveTodo: { true }))
    }

    @MainActor
    func testRecordingResumePreservesConflictAndRestoresBothRegistrations() {
        withDefaults { defaults in
            let pair = makePair(defaults)
            _ = pair.register()
            pair.unregister()
            XCTAssertFalse(pair.todo.isRegistered)
            XCTAssertFalse(pair.translator.isRegistered)
            XCTAssertFalse(pair.todo.updateShortcut(keyCode: pair.translator.shortcut.keyCode,
                                                    modifiers: pair.translator.shortcut.modifiers))
            pair.resumeAfterRecording()
            XCTAssertTrue(pair.todo.isRegistered)
            XCTAssertTrue(pair.translator.isRegistered)
            XCTAssertEqual(pair.todo.registrationError, GlobalHotKeyManager.conflictMessage)
        }
    }

    @MainActor
    func testRecordingResumeKeepsOriginalRegistrationFailure() {
        withDefaults { defaults in
            let pair = GlobalHotKeyPair(defaults: defaults, translatorRegistration: { _ in nil },
                                       todoRegistration: {
                $0.keyCode == UInt32(kVK_ANSI_A) ? "new failure -9878" : nil
            })
            _ = pair.register()
            pair.unregister()
            XCTAssertFalse(pair.todo.updateShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey)))
            let error = pair.todo.registrationError
            pair.resumeAfterRecording()
            XCTAssertEqual(pair.todo.registrationError, error)
            XCTAssertTrue(pair.todo.isRegistered)
            XCTAssertTrue(pair.translator.isRegistered)
        }
    }

    @MainActor
    func testResolvedStartupConflictClearsWhenTranslatorChanges() {
        withDefaults { defaults in
            defaults.set(Int(kVK_ANSI_R), forKey: "PIAARHotKeyKeyCode")
            defaults.set(Int(controlKey), forKey: "PIAARHotKeyModifiers")
            let pair = makePair(defaults)
            XCTAssertFalse(pair.register().todo)
            XCTAssertEqual(pair.todo.registrationError, GlobalHotKeyManager.conflictMessage)
            pair.unregister()
            XCTAssertTrue(pair.translator.restoreDefault())
            pair.resumeAfterRecording()
            XCTAssertTrue(pair.todo.isRegistered)
            XCTAssertNil(pair.todo.registrationError)
            XCTAssertEqual(pair.todo.shortcut.displayText, "⌃R")
        }
    }

    @MainActor
    func testTodoHotkeyRoutesToTodayQuickFocusAndKeepsPendingInput() throws {
        try withDefaults { defaults in
            let repo = SwiftDataTodoRepository(container: try TodoPersistence.makeContainer(inMemory: true))
            let store = TodoWorkspaceStore { repo }
            store.load()
            let model = try XCTUnwrap(store.model)
            let work = WorkWindowCoordinator {
                self.identifyTodoTestController(WorkWindowController(openTranslator: { XCTFail("Todo must not invoke Translator") },
                                     openSettings: {}, todoStore: store))
            }
            defer { work.controller?.window?.close() }
            let pair = makePair(defaults)
            pair.todo.onHotKeyPressed = { work.showTodo() }
            _ = pair.register()
            model.selectFilter(.upcoming)
            XCTAssertTrue(pair.todo.receiveHotKey(signature: GlobalHotKeyManager.carbonSignature, id: 2))
            XCTAssertEqual(model.filter, .today)
            XCTAssertEqual(model.quickFocusRequest, 1)
            let window = work.controller?.window
            model.quickTitle = "unfinished quick entry"
            XCTAssertTrue(pair.todo.receiveHotKey(signature: GlobalHotKeyManager.carbonSignature, id: 2))
            XCTAssertTrue(work.controller?.window === window)
            XCTAssertEqual(model.quickTitle, "unfinished quick entry")
            XCTAssertEqual(model.quickFocusRequest, 2)
        }
    }

}
