import AppKit
import SwiftUI

@MainActor
final class MiniTodoWindowController: NSWindowController {
    let todoStore: TodoWorkspaceStore
    let navigation = MiniTodoNavigation()
    private var tabMonitor: Any?

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
            store: todoStore, navigation: navigation, close: { [weak self] in self?.window?.orderOut(nil) }
        ))
        panel.setContentSize(NSSize(width: 350, height: 380))
        panel.center()
        tabMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, window.isKeyWindow,
                  event.window === window, window.attachedSheet == nil,
                  MiniTodoNavigation.handlesTab(event, composing: (window.firstResponder as? NSTextView)?.hasMarkedText() == true)
            else { return event }
            // Commit the field editor before hiding quick input, preserving its draft.
            window.makeFirstResponder(nil)
            self.navigation.toggle()
            window.title = self.navigation.page == .today ? "오늘 할 일" : "보낸 업무"
            if self.navigation.page == .today { self.todoStore.model?.requestQuickFocus(); self.todoStore.serverTasks?.requestFocus() }
            return nil
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { if let tabMonitor { NSEvent.removeMonitor(tabMonitor) } }

    func showTodo() {
        navigation.reset()
        window?.title = "오늘 할 일"
        todoStore.load()
        todoStore.model?.refresh()
        todoStore.model?.requestQuickFocus()
        todoStore.serverTasks?.openToday()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct MiniTodoRootView: View {
    @ObservedObject var store: TodoWorkspaceStore
    @ObservedObject var navigation: MiniTodoNavigation
    let close: () -> Void

    var body: some View {
        Group {
            if let model = store.serverTasks {
                ServerTasksView(model: model, page: navigation.page == .today ? .mine : .sent, mini: true, closeMini: close)
            } else if let model = store.model {
                if navigation.page == .today {
                    TodayTodoView(model: model, sharedTasks: store.collaboration.sharedTasks, isMini: true, closeMini: close)
                } else {
                    MiniSentTasksView(model: model, sharedTasks: store.collaboration.sharedTasks)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(store.initializationError ?? "할 일 불러오는 중…")
                    Button("다시 시도") { store.load(); store.model?.requestQuickFocus() }
                }.padding(18)
            }
        }.frame(minWidth: 350, minHeight: 380)
    }
}

@MainActor
final class MiniTodoNavigation: ObservableObject {
    enum Page { case today, sent }
    @Published private(set) var page: Page = .today
    func toggle() { page = page == .today ? .sent : .today }
    func reset() { page = .today }
    static func handlesTab(_ event: NSEvent, composing: Bool) -> Bool {
        event.type == .keyDown && event.keyCode == 48 && !event.isARepeat && !composing &&
            event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    }
}

private struct MiniSentTasksView: View {
    @ObservedObject var model: TodoViewModel
    @ObservedObject var sharedTasks: SharedTasksViewModel
    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    var body: some View {
        let tasks = sharedTasks.sent(on: model.todayDate, calendar: model.calendar)
        VStack(alignment: .leading, spacing: 14) {
            Text("보낸 업무").font(.headline)
            if tasks.isEmpty {
                Text("오늘 보낸 업무가 없습니다.").font(.subheadline).foregroundStyle(.secondary).padding(.top, 10)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(tasks) { SentTaskRow(model: sharedTasks, task: $0, compact: true) }
                    }.padding(.vertical, 4)
                }
            }
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .task { await sharedTasks.load() }
            .onAppear { model.refresh() }
            .onReceive(refreshTimer) { _ in model.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in model.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }
}
