import SwiftUI

struct ChildrenListView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @StateObject private var vm = ChildrenViewModel()
    @State private var showAddChild = false
    @State private var newChildName = ""
    @State private var renameTarget: Child?
    @State private var renameText = ""

    /// Drives the macOS NavigationSplitView's detail column, by child id rather than by
    /// Child itself. An id is stable identity: keying selection (and the detail pane's
    /// .id()) on it survives a rename (Child is Hashable over ALL stored properties, so a
    /// renamed Child no longer == the previously-selected value) and, on delete, leaves
    /// the detail pane able to detect "this id no longer exists" instead of silently
    /// keeping the stale object alive. Unused on iOS, where ChildrenListView() is
    /// constructed with no selection and navigation is push-based via
    /// .navigationDestination inside the caller's NavigationStack.
    @Binding var selection: String?

    init(selection: Binding<String?> = .constant(nil)) {
        self._selection = selection
    }

    var body: some View {
        List(selection: $selection) {
            if vm.childrenLoadFailed {
                ContentUnavailableView {
                    Label("Couldn't Load Children", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(vm.errorMessage ?? "Something went wrong.")
                } actions: {
                    Button("Retry") { Task { await vm.load() } }
                        .buttonStyle(.borderedProminent)
                }
            } else if vm.children.isEmpty && vm.isLoading {
                HStack {
                    Spacer()
                    ProgressView("Loading...")
                    Spacer()
                }
            } else if vm.children.isEmpty {
                ContentUnavailableView {
                    Label("No Children", systemImage: "person.2")
                } description: {
                    Text("Add a child, then attach their Macs")
                } actions: {
                    Button("Add Child") { showAddChild = true }
                        .buttonStyle(.borderedProminent)
                }
            }

            ForEach(vm.children) { child in
                NavigationLink(value: child) {
                    ChildRow(child: child,
                             devices: vm.devices(for: child),
                             usedMinutes: vm.todayMinutes[child.id])
                }
                // NavigationLink(value:) carries a Child (for .navigationDestination(for:
                // Child.self) below), but `selection` is keyed by id -- List needs an
                // explicit tag matching the selection's type to associate this row with it.
                .tag(child.id)
                .swipeActions(edge: .trailing) {
                    // DELETE /children/{id} returns 400 while the child still has
                    // devices. Offering a button that can only fail is worse than not
                    // offering it, so it appears only once the child is empty. Gated on
                    // child.deviceIds (from the same /children response as the row
                    // itself), not vm.devices(for:) -- that comes from a separate
                    // /devices request that can fail or simply not have landed yet,
                    // which would wrongly offer Delete for every child in the meantime.
                    if child.deviceIds.isEmpty {
                        Button("Delete", role: .destructive) {
                            Task { await vm.deleteChild(child.id) }
                        }
                    }
                    Button("Rename") {
                        renameTarget = child
                        renameText = child.name
                    }
                    .tint(.blue)
                }
                .contextMenu {
                    // Same actions as the swipe gestures, for macOS (right-click) and
                    // iOS (long-press) where a swipe isn't the primary or only input.
                    Button("Rename") {
                        renameTarget = child
                        renameText = child.name
                    }
                    if child.deviceIds.isEmpty {
                        Button("Delete", role: .destructive) {
                            Task { await vm.deleteChild(child.id) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Children")
        #if !os(macOS)
        // Push-based navigation for the iOS NavigationStack path. On macOS this sidebar
        // is not inside a NavigationStack (the detail column has its own), so this
        // modifier would never fire a push there -- guarded out rather than left as dead
        // code that could warn at runtime.
        .navigationDestination(for: Child.self) { child in
            ChildDetailView(childId: child.id)
        }
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddChild = true } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .cancellationAction) {
                Menu {
                    if let user = authVM.user {
                        Text(user.name)
                        Text(user.email)
                        Divider()
                    }
                    Button("Sign Out", role: .destructive) { authVM.logout() }
                } label: {
                    Image(systemName: "person.circle")
                }
            }
        }
        .refreshable { await vm.load() }
        .task { await vm.load() }
        .alert("New Child", isPresented: $showAddChild) {
            TextField("Name", text: $newChildName)
            Button("Cancel", role: .cancel) { newChildName = "" }
            Button("Add") {
                let name = newChildName.trimmingCharacters(in: .whitespaces)
                newChildName = ""
                guard !name.isEmpty else { return }
                Task { await vm.createChild(name: name) }
            }
        }
        .alert("Rename Child", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                let name = renameText.trimmingCharacters(in: .whitespaces)
                let target = renameTarget
                renameTarget = nil
                guard !name.isEmpty, let target else { return }
                Task { await vm.renameChild(target.id, name: name) }
            }
        }
        .alert("Error", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }
}

struct ChildRow: View {
    let child: Child
    let devices: [Device]
    let usedMinutes: Double?

    private var onlineCount: Int {
        devices.filter(\.isOnline).count
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(child.name)
                    .font(.headline)
                Text(child.deviceCountText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if let usedMinutes {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(durationText(usedMinutes))
                            .font(.headline)
                            .monospacedDigit()
                        Text("used today")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                // Shown whenever the child has at least one device, even when none are
                // online -- otherwise "all offline" and "no data yet" both render as
                // nothing, and a parent can't tell the two apart. Gated on
                // child.deviceIds (same /children response as deviceCountText above), not
                // the `devices` array here -- that comes from a separate /devices request
                // that can fail or lag, which would show "2 devices" with no dot at all.
                if !child.deviceIds.isEmpty {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(onlineCount > 0 ? Color.green : Color.gray.opacity(0.4))
                            .frame(width: 8, height: 8)
                        Text("\(onlineCount) online")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
