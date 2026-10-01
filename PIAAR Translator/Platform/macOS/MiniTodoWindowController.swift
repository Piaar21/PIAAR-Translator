import AppKit
import SwiftUI

@MainActor
final class MiniTodoWindowController: NSWindowController {
    let todoStore: TodoWorkspaceStore

    init(todoStore: TodoWorkspaceStore) {
        self.todoStore = todoStore
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 350, height: 380),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "오늘 할 일"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        super.init(window: panel)
        panel.contentViewController = NSHostingController(rootView: MiniTodoRootView(
            store: todoStore, close: { [weak self] in self?.window?.orderOut(nil) }
        ))
        panel.setContentSize(NSSize(width: 350, height: 380))
        panel.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showTodo() {
        todoStore.load()
        todoStore.model?.refresh()
        todoStore.model?.requestQuickFocus()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct MiniTodoRootView: View {
    @ObservedObject var store: TodoWorkspaceStore
    let close: () -> Void

    var body: some View {
        Group {
            if let model = store.model {
                TodayTodoView(model: model, isMini: true, closeMini: close)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(store.initializationError ?? "할 일 불러오는 중…")
                    Button("다시 시도") { store.load(); store.model?.requestQuickFocus() }
                }.padding(18)
            }
        }.frame(minWidth: 350, minHeight: 380)
    }
}
