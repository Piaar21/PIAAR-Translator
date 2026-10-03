import SwiftUI
import AppKit
import Combine

// Only the application composition root creates SDK-backed repositories.
@MainActor final class ApplicationSession {
    let account: AuthViewModel
    private let presentLogin: (() -> Void)?
    private let makeStore: (UUID, AuthViewModel) -> TodoWorkspaceStore
    private(set) var store: TodoWorkspaceStore?
    private var subscription: AnyCancellable?
    private var loginWindow: NSWindow?
    var onAccountChange: () -> Void = {}
    var onLogin: () -> Void = {}
    init(account: AuthViewModel, presentLogin: (() -> Void)? = nil, makeStore: @escaping (UUID, AuthViewModel) -> TodoWorkspaceStore) {
        self.account = account; self.presentLogin = presentLogin; self.makeStore = makeStore
    }
    static func production() -> ApplicationSession {
        guard let config = try? SupabaseConfiguration.load() else {
            return ApplicationSession(account: CollaborationAccountComposition.unconfiguredModel(), makeStore: { _, account in TodoWorkspaceStore(account: account) })
        }
        let repository = SupabaseAccountRepository(configuration: config)
        let account = AuthViewModel(auth: repository, profiles: repository)
        return ApplicationSession(account: account) { id, auth in
            let tasks = SupabaseTaskRepository(account: repository, userID: id)
            let groups = SupabaseGroupRepository(account: repository, userID: id)
            let links = TaskCalendarLinks(userID: id)
            let events = TaskEventQueue(repository: tasks, storage: FileTaskEventStorage(userID: id), sessionFailure: { [weak auth] in auth?.requireLogin($0) })
            let rules = SupabaseRecurrenceRepository(account: repository, userID: id)
            let recurrences = TaskRecurrenceService(tasks: tasks, repository: rules, events: events, actorName: { [weak auth] in auth?.profile?.displayName })
            let friendRepository = SupabaseFriendRepository(account: repository, userID: id)
            let spaces = SupabaseSpaceRepository(account: repository, userID: id)
            let model = TaskWorkspaceModel(repository: tasks, groups: groups, events: events, actorDisplayName: { [weak auth] in auth?.profile?.displayName }, sessionFailure: { [weak auth] in auth?.requireLogin($0) }, recurrences: recurrences, friendships: friendRepository, spaces: spaces)
            model.calendarLinks = links
            model.calendarService = AppleTodoCalendarService()
            let migration = LegacyTaskMigration(source: LegacySwiftDataTodoSource(), tasks: tasks, groups: groups, links: links, events: events, actorDisplayName: { [weak auth] in auth?.profile?.displayName }, recurrences: recurrences, validateSession: { [weak auth] expected in
                guard auth?.profile?.id == expected else { throw CollaborationAuthError.sessionMissing }
                try await repository.requireOwner(expected)
                guard auth?.profile?.id == expected else { throw CollaborationAuthError.sessionMissing }
            }, sessionFailure: { [weak auth] in auth?.requireLogin($0) })
            let friends = ServerFriendsViewModel(repository: friendRepository, sessionFailure: { [weak auth] in auth?.requireLogin($0) })
            let directory = SpaceDirectoryModel(repository: spaces, friendships: friendRepository, makeModel: { [weak model, weak auth] spaceID in
                let scoped = TaskWorkspaceModel(repository: tasks, groups: groups, events: events,
                    actorDisplayName: { [weak auth] in auth?.profile?.displayName }, sessionFailure: { [weak auth] in auth?.requireLogin($0) },
                    friendships: friendRepository, spaceID: spaceID, spaces: spaces)
                scoped.calendarLinks = links; scoped.calendarService = model?.calendarService
                scoped.onSpaceChange = { [weak model] in await model?.refresh() }; return scoped
            }, sessionFailure: { [weak auth] in auth?.requireLogin($0) })
            return TodoWorkspaceStore(account: auth, serverTasks: model, migration: migration, serverFriends: friends, serverSpaces: directory)
        }
    }
    func start() {
        subscription = account.$state.sink { [weak self] state in
            guard let self else { return }
            // Published state emits before storage changes; use the emitted state.
            let id: UUID? = { if case .signedIn(let profile) = state { return profile.id }; return nil }()
            if id != self.store?.serverTasks?.userID {
                self.store?.serverSpaces?.invalidate()
                self.store?.serverFriends?.invalidate()
                self.store?.serverTasks?.invalidate(); self.store?.migration?.invalidate()
                self.store = nil; self.onAccountChange()
                if let id { self.store = self.makeStore(id, self.account); self.loginWindow?.orderOut(nil); self.onLogin() }
            }
            if id == nil { self.showLogin() }
        }
        Task { await account.start() }
    }
    @discardableResult func allowAccess() -> Bool {
        guard store?.serverTasks != nil else { showLogin(); return false }; return true
    }
    func showLogin() {
        if let presentLogin { presentLogin(); return }
        if loginWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.contentMinSize = NSSize(width: 440, height: 560)
            window.title = "PIAAR Work 로그인"; window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: CollaborationAccountView(model: account))
            window.center(); loginWindow = window
        }
        loginWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
