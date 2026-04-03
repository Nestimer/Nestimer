import SwiftUI

@main
struct UsageTimeControlApp: App {
    @StateObject private var authVM = AuthViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authVM)
        }
        #if os(macOS)
        .defaultSize(width: 500, height: 700)
        #endif
    }
}
