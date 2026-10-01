import AppKit

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let openWork: () -> Void
    private let openTranslator: () -> Void
    private let openSettings: () -> Void

    init(openWork: @escaping () -> Void,
         openTranslator: @escaping () -> Void,
         openSettings: @escaping () -> Void) {
        self.openWork = openWork
        self.openTranslator = openTranslator
        self.openSettings = openSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "PIAAR Work")
        statusItem.button?.toolTip = "PIAAR Work"
        let menu = NSMenu(title: "PIAAR Work")
        addItem("PIAAR Work 열기", action: #selector(showWork), to: menu)
        addItem("번역 팝업 열기", action: #selector(showTranslator), to: menu)
        menu.addItem(.separator())
        addItem("설정…", action: #selector(showSettings), to: menu)
        menu.addItem(.separator())
        addItem("PIAAR Work 종료", action: #selector(quit), to: menu)
        statusItem.menu = menu
    }

    private func addItem(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func showWork() { openWork() }
    @objc private func showTranslator() { openTranslator() }
    @objc private func showSettings() { openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}
