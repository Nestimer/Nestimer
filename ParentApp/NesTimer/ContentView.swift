import SwiftUI

struct ContentView: View {
    @EnvironmentObject var authVM: AuthViewModel
    // Only meaningful on macOS: the sidebar's List(selection:) drives which child the
    // detail column's own NavigationStack shows. navigationDestination(for:) alone (in
    // the sidebar) does not do this -- it requires an enclosing NavigationStack, which
    // the sidebar column of a NavigationSplitView does not provide.
    @State private var selectedChild: Child?

    var body: some View {
        Group {
            if authVM.isAuthenticated {
                #if os(macOS)
                NavigationSplitView {
                    ChildrenListView(selection: $selectedChild)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
                } detail: {
                    NavigationStack {
                        if let selectedChild {
                            ChildDetailView(childId: selectedChild.id)
                        } else {
                            Text("Select a child")
                                .foregroundStyle(.secondary)
                        }
                    }
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
