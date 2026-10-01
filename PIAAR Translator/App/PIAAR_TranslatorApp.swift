import SwiftUI

@main
struct PIAAR_TranslatorApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self)
    var appDelegate

    var body: some Scene {

        Settings {
            EmptyView()
        }
    }
}
