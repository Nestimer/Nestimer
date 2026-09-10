import SwiftUI

struct ContentView: View {
    @EnvironmentObject var authVM: AuthViewModel

    var body: some View {
        Group {
            if authVM.isAuthenticated {
                #if os(macOS)
                NavigationSplitView {
                    ChildrenListView()
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
                } detail: {
                    Text("Select a child")
                        .foregroundStyle(.secondary)
                }
                #else
                NavigationStack {
                    ChildrenListView()
                }
                #endif
            } else {
                LoginView()
            }
        }
        .animation(.default, value: authVM.isAuthenticated)
    }
}
