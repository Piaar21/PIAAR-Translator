import AppKit
import SwiftUI

@MainActor
final class WorkWindowController: NSWindowController, NSWindowDelegate {
    private var resetsDateOnNextShow = true
    private let todoStore: TodoWorkspaceStore
    let navigation = WorkNavigationState()

    init(openTranslator: @escaping () -> Void, openSettings: @escaping () -> Void,
         todoStore: TodoWorkspaceStore? = nil) {
        self.todoStore = todoStore ?? TodoWorkspaceStore()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PIAAR Work"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 680, height: 420)
        window.contentViewController = NSHostingController(rootView: WorkMainView(
            navigation: navigation,
            todoStore: self.todoStore,
            openTranslator: openTranslator,
            openSettings: openSettings
        ))
        // Hosting content initially sizes itself to its minimum; establish the
        // intended default before restoring a user's saved frame.
        window.setContentSize(NSSize(width: 780, height: 600))
        window.setFrameAutosaveName("PIAARWorkTodoWindow")
        if !window.setFrameUsingName("PIAARWorkTodoWindow") { window.center() }
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var sharedTodoStore: TodoWorkspaceStore { todoStore }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        todoStore.model?.saveDraftIfNeeded() ?? true
    }

    func windowWillClose(_ notification: Notification) { resetsDateOnNextShow = true }

    func showTodo() {
        navigation.select(.todo)
        // Reopening Full (including Mini → Full) starts at personal Todos.
        // Leave an already visible Full window's current sidebar selection alone.
        if window?.isVisible != true && window?.attachedSheet == nil {
            navigation.selectSidebar(.myTodos)
        }
        todoStore.load()
        if resetsDateOnNextShow { todoStore.model?.openFullToday(); resetsDateOnNextShow = false }
        todoStore.model?.refresh()
        if window?.attachedSheet == nil {
            todoStore.model?.prepareForQuickEntry(windowWasActive: window?.isKeyWindow == true)
        }
        show()
    }

    func show() {
        guard let window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        // Accessory apps need their window visible before requesting activation.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.attachedSheet?.makeKeyAndOrderFront(nil)
    }
}

// A single owner retains the window even after it is closed.
@MainActor
final class WorkWindowCoordinator {
    private(set) var controller: WorkWindowController?
    private let makeController: () -> WorkWindowController
    private let makeMini: @MainActor (TodoWorkspaceStore) -> MiniTodoWindowController
    private(set) var miniController: MiniTodoWindowController?

    init(makeController: @escaping () -> WorkWindowController,
         makeMini: (@MainActor (TodoWorkspaceStore) -> MiniTodoWindowController)? = nil) {
        self.makeController = makeController
        self.makeMini = makeMini ?? { MiniTodoWindowController(todoStore: $0) }
    }

    func showWork() {
        miniController?.window?.orderOut(nil)
        windowController().showTodo()
    }

    // Closing restarts at Mini; hiding for a toggle retains both controllers and drafts.
    func handleTodoHotKey() {
        if miniController?.window?.isVisible == true {
            showWork()
        } else {
            showMini()
        }
    }

    private func showMini() {
        let full = windowController()
        full.window?.orderOut(nil)
        full.window?.attachedSheet?.orderOut(nil)
        if miniController == nil { miniController = makeMini(full.sharedTodoStore) }
        miniController?.showTodo()
        // Activation can reorder an attached sheet's parent. Keep both hidden
        // after activating Mini without ending the sheet or losing its draft.
        full.window?.orderOut(nil)
        full.window?.attachedSheet?.orderOut(nil)
        DispatchQueue.main.async { [weak self, weak full] in
            guard self?.miniController?.window?.isVisible == true else { return }
            full?.window?.orderOut(nil)
            full?.window?.attachedSheet?.orderOut(nil)
        }
    }
    func showTodo() { showWork() }

    private func windowController() -> WorkWindowController {
        if let controller { return controller }
        let newController = makeController()
        controller = newController
        return newController
    }
}
