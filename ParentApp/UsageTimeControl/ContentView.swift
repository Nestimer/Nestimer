import SwiftUI

struct ContentView: View {
    @EnvironmentObject var authVM: AuthViewModel

    var body: some View {
        Group {
            if authVM.isAuthenticated {
                NavigationStack {
                    DevicesListView()
                }
            } else {
                LoginView()
            }
        }
        .animation(.default, value: authVM.isAuthenticated)
    }
}
