import SwiftUI
import AppKit
import ApplicationServices

// MARK: - App Delegate

@MainActor
final class AppDelegate:
    NSObject,
    NSApplicationDelegate {

    private var popupController:
        PopupWindowController?

    private var applicationSession: ApplicationSession?

    private lazy var workWindows = WorkWindowCoordinator { [weak self] in
        WorkWindowController(
            openTranslator: { [weak self] in self?.showClipboardTranslator() },
            openSettings: { HotKeySettingsWindowController.shared.show() },
            todoStore: self?.applicationSession?.store
        )
    }
    private var statusBarController: StatusBarController?

    private var isHandlingHotKey =
        false


    func applicationDidFinishLaunching(
        _ notification: Notification
    ) {

        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        NSApp.setActivationPolicy(
            .accessory
        )


        GlobalHotKeyManager
            .shared
            .onHotKeyPressed = {
                [weak self] in

                self?
                    .globalHotKeyPressed()
            }


        GlobalHotKeyManager.todoShared.onHotKeyPressed = { [weak self] in
            guard self?.applicationSession?.allowAccess() == true else { return }
            self?.workWindows.handleTodoHotKey()
        }
        _ = GlobalHotKeyPair.shared.register()


        statusBarController = StatusBarController(
            openWork: { [weak self] in self?.showWork() },
            openTranslator: { [weak self] in self?.showClipboardTranslator() },
            openSettings: { HotKeySettingsWindowController.shared.show() }
        )

        let session = ApplicationSession.production()
        applicationSession = session
        session.onAccountChange = { [weak self] in
            self?.workWindows.closeAll()
            self?.popupController?.cancelPendingTranslation()
            self?.popupController?.window?.orderOut(nil)
            self?.popupController = nil
        }
        session.onLogin = { [weak self] in self?.showWork() }
        session.start()
        requestAccessibilityPermissionIfNeeded()
    }


    func applicationWillTerminate(
        _ notification: Notification
    ) {

        GlobalHotKeyPair.shared.unregister()
    }


    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {

        showTranslator(text: NSPasteboard.general.string(forType: .string))

        return true
    }


    // MARK: - Work Window

    private func showWork() {
        guard applicationSession?.allowAccess() == true else { return }
        workWindows.showWork()
    }

    private func showClipboardTranslator() {
        showTranslator(text: NSPasteboard.general.string(forType: .string))
    }


    // MARK: - Global HotKey

    private func globalHotKeyPressed() {

        guard applicationSession?.allowAccess() == true, !isHandlingHotKey else {
            return
        }


        isHandlingHotKey =
            true


        let requestScope = applicationSession?.store?.serverTasks
        Task { @MainActor in
            guard applicationSession?.store?.serverTasks === requestScope else { isHandlingHotKey = false; return }
            defer {
                isHandlingHotKey =
                    false
            }


            guard AXIsProcessTrusted()
            else {

                requestAccessibilityPermissionIfNeeded()

                showAccessibilityAlert()

                return
            }


            popupController?.cancelPendingTranslation()

            let pasteboard =
                NSPasteboard.general


            let oldChangeCount =
                pasteboard.changeCount


            guard sendCommandC() else {
                showTranslator(text: nil)
                return
            }


            // 대상 앱이 복사를 완료할 때까지
            // 최대 약 0.6초 기다린다.
            for _ in 0..<12 {

                try? await Task.sleep(
                    nanoseconds:
                        50_000_000
                )


                if pasteboard.changeCount !=
                    oldChangeCount {

                    break
                }
            }


            guard applicationSession?.store?.serverTasks === requestScope else { return }
            let selection = TranslatorViewModel.copiedSelection(from: pasteboard, after: oldChangeCount)
            showTranslator(text: selection)
        }
    }


    // MARK: - Copy Selected Text

    private func sendCommandC() -> Bool {

        guard
            let source =
                CGEventSource(
                    stateID:
                        .hidSystemState
                )
        else {
            return false
        }


        let keyCode =
            CGKeyCode(
                8
            )


        guard
            let keyDown =
                CGEvent(
                    keyboardEventSource:
                        source,
                    virtualKey:
                        keyCode,
                    keyDown:
                        true
                ),

            let keyUp =
                CGEvent(
                    keyboardEventSource:
                        source,
                    virtualKey:
                        keyCode,
                    keyDown:
                        false
                )
        else {
            return false
        }


        keyDown.flags = [
            .maskCommand
        ]

        keyUp.flags = [
            .maskCommand
        ]


        keyDown.post(
            tap:
                .cghidEventTap
        )

        keyUp.post(
            tap:
                .cghidEventTap
        )
        return true
    }


    // MARK: - Translator Window

    private func showTranslator(text: String?) {

        guard applicationSession?.allowAccess() == true else { return }
        if popupController == nil {

            popupController =
                PopupWindowController()
        }


        popupController?
            .show(text: text)
    }


    // MARK: - Accessibility

    private func requestAccessibilityPermissionIfNeeded() {

        guard !AXIsProcessTrusted()
        else {
            return
        }


        let options = [
            kAXTrustedCheckOptionPrompt
                .takeUnretainedValue()
                as String: true
        ] as CFDictionary


        AXIsProcessTrustedWithOptions(
            options
        )
    }


    private func showAccessibilityAlert() {

        let alert =
            NSAlert()


        alert.alertStyle =
            .informational


        alert.messageText =
            "손쉬운 사용 권한이 필요합니다"


        alert.informativeText =
            """
            선택한 텍스트를 자동 복사하려면 PIAAR Work의 손쉬운 사용 권한이 필요합니다.

            시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 PIAAR Work(기존 PIAAR Translator)를 허용해주세요.

            권한을 켠 뒤 단축키를 다시 누르면 됩니다.
            """


        alert.addButton(
            withTitle:
                "시스템 설정 열기"
        )


        alert.addButton(
            withTitle:
                "나중에"
        )


        let response =
            alert.runModal()


        if response ==
            .alertFirstButtonReturn {

            openAccessibilitySettings()
        }
    }


    private func openAccessibilitySettings() {

        guard
            let url =
                URL(
                    string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                )
        else {
            return
        }


        NSWorkspace.shared.open(
            url
        )
    }
}
