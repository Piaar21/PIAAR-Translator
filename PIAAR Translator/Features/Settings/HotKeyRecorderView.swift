import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - HotKey Recorder

struct HotKeyRecorderView:
    NSViewRepresentable {

    @Binding var isRecording:
        Bool

    let shortcutText:
        String

    let onShortcut:
        (
            UInt32,
            UInt32
        ) -> Void


    func makeCoordinator()
        -> Coordinator {

        Coordinator(
            isRecording:
                $isRecording,

            onShortcut:
                onShortcut
        )
    }


    func makeNSView(
        context: Context
    ) -> HotKeyRecorderNSView {

        let view =
            HotKeyRecorderNSView()


        view.coordinator =
            context.coordinator


        view.displayText =
            shortcutText


        return view
    }


    func updateNSView(
        _ nsView:
            HotKeyRecorderNSView,

        context: Context
    ) {

        nsView.coordinator =
            context.coordinator


        nsView.displayText =
            isRecording
            ? "새 단축키를 누르세요"
            : shortcutText


        nsView.needsDisplay =
            true
    }


    final class Coordinator {

        @Binding var isRecording:
            Bool

        let onShortcut:
            (
                UInt32,
                UInt32
            ) -> Void


        init(
            isRecording:
                Binding<Bool>,

            onShortcut:
                @escaping (
                    UInt32,
                    UInt32
                ) -> Void
        ) {

            _isRecording =
                isRecording

            self.onShortcut =
                onShortcut
        }
    }
}


// MARK: - Recorder NSView

final class HotKeyRecorderNSView:
    NSView {

    weak var coordinator:
        HotKeyRecorderView
            .Coordinator?


    var displayText =
        "⌃T"


    override var acceptsFirstResponder:
        Bool {
        true
    }


    override func mouseDown(
        with event: NSEvent
    ) {

        coordinator?
            .isRecording =
            true


        window?
            .makeFirstResponder(
                self
            )


        displayText =
            "새 단축키를 누르세요"


        needsDisplay =
            true
    }


    override func keyDown(
        with event: NSEvent
    ) {

        guard
            coordinator?
                .isRecording == true
        else {

            super.keyDown(
                with: event
            )

            return
        }


        // ESC → 녹화 취소
        if event.keyCode == 53 {

            coordinator?
                .isRecording =
                false

            needsDisplay =
                true

            return
        }


        let flags =
            event.modifierFlags
                .intersection(
                    .deviceIndependentFlagsMask
                )


        var carbonModifiers:
            UInt32 = 0


        if flags.contains(
            .control
        ) {

            carbonModifiers |=
                UInt32(controlKey)
        }


        if flags.contains(
            .option
        ) {

            carbonModifiers |=
                UInt32(optionKey)
        }


        if flags.contains(
            .shift
        ) {

            carbonModifiers |=
                UInt32(shiftKey)
        }


        if flags.contains(
            .command
        ) {

            carbonModifiers |=
                UInt32(cmdKey)
        }


        // modifier 없는 단축키는 허용하지 않음
        guard carbonModifiers != 0
        else {

            NSSound.beep()

            return
        }


        coordinator?
            .onShortcut(
                UInt32(
                    event.keyCode
                ),
                carbonModifiers
            )
    }


    override func draw(
        _ dirtyRect: NSRect
    ) {

        super.draw(
            dirtyRect
        )


        let bounds =
            self.bounds


        let path =
            NSBezierPath(
                roundedRect:
                    bounds.insetBy(
                        dx: 0.5,
                        dy: 0.5
                    ),

                xRadius: 9,
                yRadius: 9
            )


        NSColor.controlBackgroundColor
            .setFill()

        path.fill()


        NSColor.separatorColor
            .setStroke()

        path.lineWidth =
            1

        path.stroke()


        let paragraph =
            NSMutableParagraphStyle()

        paragraph.alignment =
            .center


        let attributes:
            [NSAttributedString.Key: Any] = [

                .font:
                    NSFont.systemFont(
                        ofSize: 17,
                        weight: .medium
                    ),

                .foregroundColor:
                    NSColor.labelColor,

                .paragraphStyle:
                    paragraph
            ]


        let text =
            NSAttributedString(
                string:
                    displayText,

                attributes:
                    attributes
            )


        let textSize =
            text.size()


        let rect =
            NSRect(
                x: 0,
                y:
                    (
                        bounds.height
                        - textSize.height
                    ) / 2,

                width:
                    bounds.width,

                height:
                    textSize.height
            )


        text.draw(
            in: rect
        )
    }
}
