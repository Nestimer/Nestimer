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
            if vm.childrenLoadFailed && vm.children.isEmpty {
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
                ChildListRow(
                    child: child,
                    devices: vm.devices(for: child),
                    usedMinutes: vm.todayMinutes[child.id],
                    onRename: {
                        renameTarget = child
                        renameText = child.name
                    },
                    onDelete: {
                        Task {
                            await vm.deleteChild(child.id)
                            // Otherwise the detail pane's .id() never changes, so it is
                            // never rebuilt and keeps rendering the deleted child's
                            // cached data -- including an "Add Device" path that would
                            // POST a child_id that no longer exists.
                            if selection == child.id { selection = nil }
                        }
                    }
                )
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

/// One sidebar row plus its swipe/context actions. Split out of ChildrenListView's body
/// (rather than inlined in the ForEach) for two reasons: it keeps the platform-conditional
/// navigation-vs-selectable-row split (see `rowContent`) from ballooning the type-checking
/// cost of the enclosing List/ForEach/modifier chain -- inlined, the combination timed out
/// the compiler -- and it gives that split a single, obviously-correct place to live.
private struct ChildListRow: View {
    let child: Child
    let devices: [Device]
    let usedMinutes: Double?
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        rowContent
            .swipeActions(edge: .trailing) {
                // DELETE /children/{id} returns 400 while the child still has devices.
                // Offering a button that can only fail is worse than not offering it, so
                // it appears only once the child is empty. Gated on child.deviceIds (from
                // the same /children response as the row itself), not a separate
                // /devices request that can fail or simply not have landed yet.
                if child.deviceIds.isEmpty {
                    Button("Delete", role: .destructive, action: onDelete)
                }
                Button("Rename", action: onRename)
                    .tint(.blue)
            }
            .contextMenu {
                // Same actions as the swipe gestures, for macOS (right-click) and iOS
                // (long-press) where a swipe isn't the primary or only input.
                Button("Rename", action: onRename)
                if child.deviceIds.isEmpty {
                    Button("Delete", role: .destructive, action: onDelete)
                }
            }
    }

    // Split explicitly by platform rather than relying on tag-vs-link precedence. On
    // macOS the row is a plain selectable List row: no link means nothing can swallow the
    // click and there is no dangling .navigationDestination(for: Child.self) call for a
    // link to fail to find (that modifier is iOS-only). On iOS it stays the push link,
    // whose value type (Child) intentionally no longer matches `selection`'s type
    // (String), so it can no longer be folded into list selection and is unambiguously a
    // push.
    @ViewBuilder
    private var rowContent: some View {
        #if os(macOS)
        ChildRow(child: child, devices: devices, usedMinutes: usedMinutes)
            .tag(child.id)
        #else
        NavigationLink(value: child) {
            ChildRow(child: child, devices: devices, usedMinutes: usedMinutes)
        }
        #endif
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
