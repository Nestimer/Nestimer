import SwiftUI
import UserNotifications

@main
struct NesTimerChildApp: App {
    @State private var paired = Keychain.isPaired

    var body: some Scene {
        WindowGroup {
            Group {
                if paired {
                    StatusView(onUnpair: { paired = false })
                } else {
                    SetupView(onDone: { paired = true })
                }
            }
            .onAppear {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        }
    }
}
