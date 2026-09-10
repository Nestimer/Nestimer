import SwiftUI

struct ChildrenListView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @StateObject private var vm = ChildrenViewModel()
    @State private var showAddChild = false
    @State private var newChildName = ""
    @State private var renameTarget: Child?
    @State private var renameText = ""

    /// Drives the macOS NavigationSplitView's detail column. Unused on iOS, where
    /// ChildrenListView() is constructed with no selection and navigation is push-based
    /// via .navigationDestination inside the caller's NavigationStack.
    @Binding var selection: Child?

    /// True only when the most recent load() call itself failed and left the list
    /// empty -- as opposed to vm.errorMessage being set (and later cleared by dismissing
    /// the alert below) by an unrelated create/rename/delete failure. Tracked locally
    /// because ChildrenViewModel has one shared errorMessage for all of those, and this
    /// screen needs the load failure to keep showing a retry state even after the alert
    /// for it has been dismissed.
    @State private var loadFailed = false

    init(selection: Binding<Child?> = .constant(nil)) {
        self._selection = selection
    }

    var body: some View {
        List(selection: $selection) {
            if loadFailed {
                ContentUnavailableView {
                    Label("Couldn't Load Children", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(vm.errorMessage ?? "Something went wrong.")
                } actions: {
                    Button("Retry") { Task { await loadChildren() } }
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
        .navigationDestination(for: Child.self) { child in
            ChildDetailView(childId: child.id)
        }
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
        .refreshable { await loadChildren() }
        .task { await loadChildren() }
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

    private func loadChildren() async {
        await vm.load()
        loadFailed = vm.errorMessage != nil && vm.children.isEmpty
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
                // nothing, and a parent can't tell the two apart.
                if !devices.isEmpty {
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
