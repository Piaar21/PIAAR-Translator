import AppKit
import Carbon
import SwiftUI

struct TodoNewShortcut: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> TodoShortcutNSView {
        let view = TodoShortcutNSView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: TodoShortcutNSView, context: Context) { nsView.action = action }

    static func dismantleNSView(_ nsView: TodoShortcutNSView, coordinator: ()) { nsView.stop() }
}

final class TodoShortcutNSView: NSView {
    var action: (() -> Void)?
    private var monitor: Any?
    private weak var monitoredWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        start(in: window)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let window = monitoredWindow, window.isKeyWindow, window.attachedSheet == nil,
              Self.isNewTodoShortcut(event) else { return super.performKeyEquivalent(with: event) }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, window.isKeyWindow, window.attachedSheet == nil else { return }
            self.action?()
        }
        return true
    }

    func start(in window: NSWindow?) {
        stop()
        monitoredWindow = window
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.monitoredWindow,
                  window.isKeyWindow, (event.window == nil || event.window === window),
                  window.attachedSheet == nil,
                  Self.isNewTodoShortcut(event) else { return event }
            // Leave event dispatch before changing the responder/focus state.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.monitoredWindow === window,
                      window.isKeyWindow, window.attachedSheet == nil else { return }
                self.action?()
            }
            return nil
        }
    }

    static func isNewTodoShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !event.isARepeat,
              event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
              let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return false }
        if characters.lowercased() == "n" { return true }
        // Keep Command-N available with non-Latin input sources while honoring
        // remapped Latin layouts rather than treating every physical N as "n".
        return event.keyCode == UInt16(kVK_ANSI_N) && characters.unicodeScalars.contains { !$0.isASCII }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        monitoredWindow = nil
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

// The quick-entry field owns its shortcut monitor and its actual field editor.
// A focus revision is an event, not a persistent Bool that can become stale.
struct TodoQuickInput: NSViewRepresentable {
    @Binding var text: String
    let focusRevision: Int
    let wantsFocus: Bool
    let submit: () -> Void
    let cancel: () -> Void
    let newShortcut: () -> Void
    var placeholder: String = "할 일 추가"
    var focusChanged: ((Bool) -> Void)? = nil
    @Environment(\.workFullRows) private var full

    func makeNSView(context: Context) -> TodoQuickInputNSView {
        TodoQuickInputNSView()
    }

    func updateNSView(_ view: TodoQuickInputNSView, context: Context) {
        view.placeholderString = placeholder
        view.font = full ? .systemFont(ofSize: 15, weight: .medium) : .systemFont(ofSize: NSFont.systemFontSize)
        view.focusChanged = focusChanged
        view.textChanged = { text = $0 }
        view.submit = submit
        view.cancel = cancel
        view.shortcut.action = newShortcut
        view.setText(text)
        view.applyFocusRequest(revision: focusRevision, wantsFocus: wantsFocus)
    }

    static func dismantleNSView(_ view: TodoQuickInputNSView, coordinator: ()) {
        view.stopObserving()
        view.shortcut.stop()
    }
}

final class TodoQuickInputNSView: NSTextField, NSTextFieldDelegate {
    let shortcut = TodoShortcutNSView()
    var textChanged: ((String) -> Void)?
    var focusChanged: ((Bool) -> Void)?
    var submit: (() -> Void)?
    var cancel: (() -> Void)?
    private var focusRevision: Int?
    private var pendingFocusRevision: Int?
    private var keyWindowObserver: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        cell?.isScrollable = true
        font = .systemFont(ofSize: NSFont.systemFontSize)
        placeholderString = "할 일 추가"
        setAccessibilityLabel("할 일 추가")
        delegate = self
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        shortcut.start(in: window)
        guard let window else { return }
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in self?.scheduleFocus() }
        scheduleFocus()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let window, window.isKeyWindow, window.attachedSheet == nil,
              TodoShortcutNSView.isNewTodoShortcut(event) else {
            return super.performKeyEquivalent(with: event)
        }
        // Cocoa can dispatch key equivalents without passing through a local
        // keyDown monitor.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.isKeyWindow == true,
                  self.window?.attachedSheet == nil else { return }
            self.shortcut.action?()
        }
        return true
    }

    func setText(_ text: String) {
        guard stringValue != text else { return }
        stringValue = text
        if let editor = currentEditor(), editor.string != text {
            editor.string = text
            editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
    }

    func applyFocusRequest(revision: Int, wantsFocus: Bool) {
        guard focusRevision != revision else { return }
        focusRevision = revision
        pendingFocusRevision = wantsFocus ? revision : nil
        if wantsFocus { scheduleFocus() }
        else { releaseKeyboardFocus() }
    }

    private func scheduleFocus() {
        guard let revision = pendingFocusRevision else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingFocusRevision == revision,
                  let window = self.window, window.isKeyWindow,
                  window.attachedSheet == nil else { return }
            if window.makeFirstResponder(self) { self.pendingFocusRevision = nil }
        }
    }

    var hasKeyboardFocus: Bool {
        guard let editor = currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    func releaseKeyboardFocus() {
        if hasKeyboardFocus { window?.makeFirstResponder(nil) }
    }

    func controlTextDidBeginEditing(_ notification: Notification) { focusChanged?(true) }
    func controlTextDidEndEditing(_ notification: Notification) { focusChanged?(false) }

    func controlTextDidChange(_ notification: Notification) { textChanged?(stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            submit?()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            pendingFocusRevision = nil
            setText("")
            cancel?()
            releaseKeyboardFocus()
            return true
        default:
            return false
        }
    }

    func stopObserving() {
        if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
        keyWindowObserver = nil
    }

    deinit { if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) } }
}
