import DeviceActivity
import SwiftUI
import UserNotifications

@main
struct NesTimerChildApp: App {
    @State private var paired = Keychain.isPaired

    #if DEBUG
    /// Before the first refresh touches anything: record what iOS is really monitoring and
    /// copy the App Group files to Documents, where `devicectl device copy from` can read them.
    init() {
        let center = DeviceActivityCenter()
        let acts = center.activities.map(\.rawValue).sorted()
        let events = center.events(for: DeviceActivityScheduler.daily).keys.map(\.rawValue).sorted()
        DebugLog.write("DIAG launch: activities=\(acts) dailyEvents=\(events)")
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for name in ["debug.log", "state.json", "armed-events.json"] {
            let dst = docs.appendingPathComponent(name)
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: AppGroup.container.appendingPathComponent(name), to: dst)
        }
    }
    #endif

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
