import Foundation
import AppKit
import Carbon.HIToolbox

struct GlobalHotKeyShortcut: Equatable {

    var keyCode: UInt32
    var modifiers: UInt32

    static let defaultShortcut =
        GlobalHotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_T),
            modifiers: UInt32(controlKey)
        )

    static let defaultTodoShortcut = GlobalHotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey)
    )

    var displayText: String {

        var text = ""

        if modifiers & UInt32(controlKey) != 0 {
            text += "⌃"
        }

        if modifiers & UInt32(optionKey) != 0 {
            text += "⌥"
        }

        if modifiers & UInt32(shiftKey) != 0 {
            text += "⇧"
        }

        if modifiers & UInt32(cmdKey) != 0 {
            text += "⌘"
        }

        text += Self.keyName(
            for: keyCode
        )

        return text
    }


    static func keyName(
        for keyCode: UInt32
    ) -> String {

        let keys: [UInt32: String] = [

            UInt32(kVK_ANSI_A): "A",
            UInt32(kVK_ANSI_B): "B",
            UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D",
            UInt32(kVK_ANSI_E): "E",
            UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G",
            UInt32(kVK_ANSI_H): "H",
            UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J",
            UInt32(kVK_ANSI_K): "K",
            UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M",
            UInt32(kVK_ANSI_N): "N",
            UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P",
            UInt32(kVK_ANSI_Q): "Q",
            UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S",
            UInt32(kVK_ANSI_T): "T",
            UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V",
            UInt32(kVK_ANSI_W): "W",
            UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y",
            UInt32(kVK_ANSI_Z): "Z",

            UInt32(kVK_ANSI_0): "0",
            UInt32(kVK_ANSI_1): "1",
            UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3",
            UInt32(kVK_ANSI_4): "4",
            UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6",
            UInt32(kVK_ANSI_7): "7",
            UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9"
        ]

        return keys[keyCode]
            ?? "Key \(keyCode)"
    }
}


enum GlobalHotKeyFeature {
    case translator
    case todo

    var defaultShortcut: GlobalHotKeyShortcut {
        self == .translator ? .defaultShortcut : .defaultTodoShortcut
    }

    var keyCodeDefaultsKey: String {
        self == .translator ? GlobalHotKeyManager.keyCodeDefaultsKey : GlobalHotKeyManager.todoKeyCodeDefaultsKey
    }

    var modifiersDefaultsKey: String {
        self == .translator ? GlobalHotKeyManager.modifiersDefaultsKey : GlobalHotKeyManager.todoModifiersDefaultsKey
    }

    var carbonID: UInt32 { self == .translator ? 1 : 2 }
}

@MainActor
final class GlobalHotKeyManager:
    ObservableObject {

    static let shared = GlobalHotKeyPair.shared.translator
    static let todoShared = GlobalHotKeyPair.shared.todo

    @Published private(set)
    var shortcut:
        GlobalHotKeyShortcut

    @Published private(set)
    var registrationError:
        String?

    var onHotKeyPressed:
        (() -> Void)?

    private var hotKeyRef:
        EventHotKeyRef?

    private var hotKeyHandler:
        EventHandlerRef?

    nonisolated static let keyCodeDefaultsKey = "PIAARHotKeyKeyCode"
    nonisolated static let modifiersDefaultsKey = "PIAARHotKeyModifiers"

    nonisolated static let todoKeyCodeDefaultsKey = "PIAARTodoHotKeyKeyCode"
    nonisolated static let todoModifiersDefaultsKey = "PIAARTodoHotKeyModifiers"
    static let conflictMessage = "번역기와 Todo는 서로 다른 단축키를 사용해야 합니다."
    nonisolated static let carbonSignature: OSType = 0x50494152 // PIAR, unchanged
    nonisolated let carbonID: UInt32
    let feature: GlobalHotKeyFeature
    private(set) var isRegistered = false
    fileprivate weak var otherManager: GlobalHotKeyManager?

    private let defaults: UserDefaults
    // Allows registration failures to be tested without taking a real global shortcut.
    private let registration: ((GlobalHotKeyShortcut) -> String?)?
    private var loadWarning: String?
    private var lastChangeError: String?

    init(defaults: UserDefaults = .standard,
         feature: GlobalHotKeyFeature = .translator,
         registration: ((GlobalHotKeyShortcut) -> String?)? = nil) {
        self.defaults = defaults
        self.feature = feature
        self.carbonID = feature.carbonID
        self.registration = registration
        let key = defaults.object(forKey: feature.keyCodeDefaultsKey)
        let modifiers = defaults.object(forKey: feature.modifiersDefaultsKey)
        if let saved = Self.decodeShortcut(keyCode: key, modifiers: modifiers) {
            shortcut = saved
        } else {
            shortcut = feature.defaultShortcut
            if key != nil || modifiers != nil {
                loadWarning = "저장된 단축키를 읽을 수 없어 이번 실행에서는 기본값을 사용합니다. 기존 설정은 변경하지 않았습니다."
            }
        }
        registrationError = loadWarning
    }

    static func decodeShortcut(keyCode: Any?, modifiers: Any?) -> GlobalHotKeyShortcut? {
        func integer(_ value: Any?) -> UInt32? {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let result = UInt32(exactly: number.doubleValue) else { return nil }
            return result
        }
        guard let key = integer(keyCode), let flags = integer(modifiers),
              isValid(keyCode: key, modifiers: flags) else { return nil }
        return GlobalHotKeyShortcut(keyCode: key, modifiers: flags)
    }

    static func isValid(keyCode: UInt32, modifiers: UInt32) -> Bool {
        let allowed = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        return keyCode <= 0x7F && modifiers != 0 && modifiers & ~allowed == 0
    }


    deinit {

        if let hotKeyRef {
            UnregisterEventHotKey(
                hotKeyRef
            )
        }

        if let hotKeyHandler {
            RemoveEventHandler(
                hotKeyHandler
            )
        }
    }


    // MARK: - Registration

    @discardableResult
    func register() -> Bool {

        // Existing Translator preferences take priority at startup, including a
        // legacy Translator shortcut that happens to equal the new Todo default.
        if let otherManager, shortcut == otherManager.shortcut,
           otherManager.isRegistered || feature == .todo {
            registrationError = Self.conflictMessage
            return false
        }

        unregister()

        registrationError = loadWarning

        if let registration {
            if let error = registration(shortcut) {
                registrationError = error
                return false
            }
            isRegistered = true
            return true
        }

        let hotKeyID =
            EventHotKeyID(
                signature:
                    Self.carbonSignature,
                id: carbonID
            )


        let status =
            RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )


        guard status == noErr else {

            registrationError =
                """
                \(shortcut.displayText) 단축키를 등록할 수 없습니다.
                다른 앱 또는 macOS에서 사용 중인 단축키일 수 있습니다.
                오류 코드: \(status)
                """

            return false
        }


        var eventType =
            EventTypeSpec(
                eventClass:
                    OSType(
                        kEventClassKeyboard
                    ),
                eventKind:
                    UInt32(
                        kEventHotKeyPressed
                    )
            )


        let managerPointer =
            UnsafeMutableRawPointer(
                Unmanaged
                    .passUnretained(self)
                    .toOpaque()
            )


        let handlerStatus =
            InstallEventHandler(
                GetApplicationEventTarget(),

                { _, event, userData -> OSStatus in

                    guard
                        let event,
                        let userData
                    else {
                        return OSStatus(eventNotHandledErr)
                    }


                    var receivedID =
                        EventHotKeyID()


                    let result =
                        GetEventParameter(
                            event,
                            EventParamName(
                                kEventParamDirectObject
                            ),
                            EventParamType(
                                typeEventHotKeyID
                            ),
                            nil,
                            MemoryLayout<
                                EventHotKeyID
                            >.size,
                            nil,
                            &receivedID
                        )


                    guard result == noErr else { return OSStatus(eventNotHandledErr) }
                    let manager = Unmanaged<GlobalHotKeyManager>
                        .fromOpaque(userData).takeUnretainedValue()
                    guard manager.matches(signature: receivedID.signature, id: receivedID.id) else {
                        // Let the other hotkey handler receive its own event.
                        return OSStatus(eventNotHandledErr)
                    }
                    let signature = receivedID.signature
                    let id = receivedID.id
                    DispatchQueue.main.async {
                        _ = manager.receiveHotKey(signature: signature, id: id)
                    }

                    return noErr
                },

                1,
                &eventType,
                managerPointer,
                &hotKeyHandler
            )


        guard handlerStatus == noErr else {

            if let hotKeyRef {
                UnregisterEventHotKey(
                    hotKeyRef
                )
            }

            hotKeyRef = nil

            registrationError =
                """
                글로벌 단축키 이벤트를 등록할 수 없습니다.
                오류 코드: \(handlerStatus)
                """

            return false
        }


        isRegistered = true
        return true
    }

    nonisolated func matches(signature: OSType, id: UInt32) -> Bool {
        signature == Self.carbonSignature && id == carbonID
    }

    @discardableResult
    func receiveHotKey(signature: OSType, id: UInt32) -> Bool {
        guard isRegistered, matches(signature: signature, id: id) else { return false }
        onHotKeyPressed?()
        return true
    }

    // Recording temporarily releases Carbon shortcuts so existing shortcuts can
    // reach the recorder. Resuming must not erase an update/rollback error.
    fileprivate func resumeRegistration() -> Bool {
        let previousError = lastChangeError
        let registered = register()
        if let previousError {
            if registered || registrationError == previousError {
                registrationError = previousError
            } else if let newError = registrationError {
                registrationError = previousError + "\n" + newError
            }
        }
        return registered
    }

    func unregister() {
        isRegistered = false

        if let hotKeyRef {

            UnregisterEventHotKey(
                hotKeyRef
            )

            self.hotKeyRef = nil
        }


        if let hotKeyHandler {

            RemoveEventHandler(
                hotKeyHandler
            )

            self.hotKeyHandler = nil
        }
    }


    // MARK: - Change Shortcut

    @discardableResult
    func updateShortcut(
        keyCode: UInt32,
        modifiers: UInt32
    ) -> Bool {

        guard Self.isValid(keyCode: keyCode, modifiers: modifiers) else {
            return rejectChange("사용할 수 없는 단축키입니다. 기존 단축키는 유지됩니다.")
        }

        let previousShortcut =
            shortcut


        let newShortcut =
            GlobalHotKeyShortcut(
                keyCode: keyCode,
                modifiers: modifiers
            )


        guard newShortcut != otherManager?.shortcut else {
            return rejectChange(Self.conflictMessage)
        }

        shortcut =
            newShortcut


        if register() {

            saveShortcut(
                newShortcut
            )
            loadWarning = nil
            lastChangeError = nil
            registrationError = nil

            return true
        }


        let changeError = registrationError ?? "새 단축키를 등록하지 못했습니다."

        // 새 단축키 등록 실패 시 기존 단축키로 복구하며 최초 오류도 보존합니다.
        shortcut =
            previousShortcut

        let restored = register()
        let recoveryError = registrationError
        registrationError = restored
            ? changeError + "\n기존 단축키로 복구했습니다."
            : changeError + "\n기존 단축키 복구에도 실패했습니다: " + (recoveryError ?? "알 수 없는 오류")
        lastChangeError = registrationError

        return false
    }


    private func rejectChange(_ message: String) -> Bool {
        registrationError = message
        lastChangeError = message
        return false
    }

    func restoreDefault() -> Bool {
        let value = feature.defaultShortcut
        return updateShortcut(keyCode: value.keyCode, modifiers: value.modifiers)
    }


    private func saveShortcut(
        _ shortcut:
            GlobalHotKeyShortcut
    ) {

        defaults.set(
            Int(shortcut.keyCode),
            forKey:
                feature.keyCodeDefaultsKey
        )

        defaults.set(
            Int(shortcut.modifiers),
            forKey:
                feature.modifiersDefaultsKey
        )
    }

}

// Owns the two independent registrations and supplies cross-shortcut validation.
@MainActor
final class GlobalHotKeyPair {
    static let shared = GlobalHotKeyPair()
    let translator: GlobalHotKeyManager
    let todo: GlobalHotKeyManager

    init(defaults: UserDefaults = .standard,
         translatorRegistration: ((GlobalHotKeyShortcut) -> String?)? = nil,
         todoRegistration: ((GlobalHotKeyShortcut) -> String?)? = nil) {
        translator = GlobalHotKeyManager(defaults: defaults, registration: translatorRegistration)
        todo = GlobalHotKeyManager(defaults: defaults, feature: .todo, registration: todoRegistration)
        translator.otherManager = todo
        todo.otherManager = translator
    }

    @discardableResult
    func register() -> (translator: Bool, todo: Bool) {
        let translatorResult = translator.register()
        let todoResult = todo.register()
        return (translatorResult, todoResult)
    }

    func unregister() {
        translator.unregister()
        todo.unregister()
    }

    func resumeAfterRecording() {
        _ = translator.resumeRegistration()
        _ = todo.resumeRegistration()
    }
}
