import SwiftUI

@main
struct NesTimerAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No visible window — this is a menu bar only app (LSUIElement = true)
        Settings {
            EmptyView()
        }
    }
}
