import SwiftUI
import AppKit

// MARK: - HotKey Settings Window

@MainActor
final class HotKeySettingsWindowController:
    NSWindowController {

    static let shared =
        HotKeySettingsWindowController()

    private init() {

        let rootView =
            HotKeySettingsView()

        let hostingController =
            NSHostingController(
                rootView: rootView
            )

        let window =
            NSWindow(
                contentRect:
                    NSRect(
                        x: 0,
                        y: 0,
                        width: 420,
                        height: 600
                    ),

                styleMask: [
                    .titled,
                    .closable
                ],

                backing:
                    .buffered,

                defer:
                    false
            )

        window.title =
            "PIAAR Work 설정"

        window.setContentSize(
            NSSize(
                width: 420,
                height: 600
            )
        )

        window.contentMinSize =
            NSSize(
                width: 420,
                height: 600
            )

        window.contentMaxSize =
            NSSize(
                width: 420,
                height: 600
            )

        window.contentViewController =
            hostingController

        window.isReleasedWhenClosed =
            false

        window.level =
            .floating

        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary
        ]

        super.init(
            window: window
        )
    }


    required init?(
        coder: NSCoder
    ) {

        fatalError(
            "init(coder:) has not been implemented"
        )
    }


    func show() {

        guard let window
        else {
            return
        }

        NSApp.activate(
            ignoringOtherApps: true
        )

        window.center()

        window.makeKeyAndOrderFront(
            nil
        )

        window.orderFrontRegardless()
    }
}
