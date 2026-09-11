import SwiftUI

struct ContentView: View {
    @EnvironmentObject var authVM: AuthViewModel
    // Only meaningful on macOS: the sidebar's List(selection:) drives which child the
    // detail column's own NavigationStack shows. navigationDestination(for:) alone (in
    // the sidebar) does not do this -- it requires an enclosing NavigationStack, which
    // the sidebar column of a NavigationSplitView does not provide.
    //
    // Keyed by id (String), not by Child: selecting A then B keeps this branch of the
    // `if let` in the SAME structural position, so without an explicit .id() below,
    // ChildDetailView's @StateObject box is reused rather than replaced -- its init runs
    // again, but StateObject(wrappedValue:) discards the new autoclosure once the box is
    // already populated, so `vm` would silently stay wired to child A forever (including
    // in the Add Device sheet, which reads the child to attach to from vm.child).
    @State private var selectedChildID: String?

    var body: some View {
        Group {
            if authVM.isAuthenticated {
                #if os(macOS)
                NavigationSplitView {
                    ChildrenListView(selection: $selectedChildID)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
                } detail: {
                    NavigationStack {
                        if let selectedChildID {
                            ChildDetailView(childId: selectedChildID)
                                .id(selectedChildID)
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
