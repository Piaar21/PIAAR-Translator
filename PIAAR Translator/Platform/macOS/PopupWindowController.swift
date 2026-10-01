import AppKit
import SwiftUI

@MainActor
final class PopupWindowController:
    NSWindowController {

    private let viewModel =
        TranslatorViewModel()


    private var preparationTask: Task<Void, Never>?

    func cancelPendingTranslation() {
        preparationTask?.cancel()
        preparationTask = nil
        viewModel.cancelTranslationRequests()
    }

    init() {

        let rootView =
            ContentView(
                viewModel:
                    viewModel
            )


        let hostingController =
            NSHostingController(
                rootView:
                    rootView
            )


        let panel =
            TranslatorPanel(
                contentViewController:
                    hostingController
            )


        panel.setContentSize(
            NSSize(
                width: 500,
                height: 720
            )
        )


        panel.isReleasedWhenClosed =
            false


        super.init(
            window: panel
        )
    }


    required init?(
        coder: NSCoder
    ) {

        fatalError(
            "init(coder:) has not been implemented"
        )
    }


    func show(text: String?) {
        cancelPendingTranslation()

        guard let window else {
            return
        }


        positionNearMouse(
            window
        )


        NSApp.activate(
            ignoringOtherApps: true
        )


        window.makeKeyAndOrderFront(
            nil
        )


        preparationTask = Task {
            await viewModel.prepareTranslation(text: text)
        }
    }


    private func positionNearMouse(
        _ window: NSWindow
    ) {

        let mouse =
            NSEvent.mouseLocation


        guard
            let screen =
                NSScreen.screens.first(
                    where: {
                        NSMouseInRect(
                            mouse,
                            $0.frame,
                            false
                        )
                    }
                )
                ?? NSScreen.main
        else {
            return
        }


        let visible =
            screen.visibleFrame

        let size =
            window.frame.size

        let gap:
            CGFloat = 14


        var x =
            mouse.x + gap

        var y =
            mouse.y
            - size.height
            + 40


        if x + size.width >
            visible.maxX {

            x =
                mouse.x
                - size.width
                - gap
        }


        if x <
            visible.minX {

            x =
                visible.minX
                + gap
        }


        if y <
            visible.minY {

            y =
                visible.minY
                + gap
        }


        if y + size.height >
            visible.maxY {

            y =
                visible.maxY
                - size.height
                - gap
        }


        window.setFrameOrigin(
            NSPoint(
                x: x,
                y: y
            )
        )
    }
}


// MARK: - Translator Panel

final class TranslatorPanel:
    NSPanel {

    override var canBecomeKey:
        Bool {
        true
    }


    override var canBecomeMain:
        Bool {
        false
    }


    convenience init(
        contentViewController:
            NSViewController
    ) {

        self.init(
            contentRect:
                NSRect(
                    x: 0,
                    y: 0,
                    width: 500,
                    height: 720
                ),

            styleMask: [
                .borderless,
                .nonactivatingPanel,
                .fullSizeContentView
            ],

            backing:
                .buffered,

            defer:
                false
        )


        self.contentViewController =
            contentViewController


        self.isMovableByWindowBackground =
            false

        self.isMovable =
            true


        isFloatingPanel =
            true

        level =
            .floating


        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary
        ]


        backgroundColor =
            .clear

        isOpaque =
            false

        hasShadow =
            true

        hidesOnDeactivate =
            false

        animationBehavior =
            .utilityWindow
    }
}
