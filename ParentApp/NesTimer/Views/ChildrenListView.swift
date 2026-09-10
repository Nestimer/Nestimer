import SwiftUI

struct ChildrenListView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @StateObject private var vm = ChildrenViewModel()
    @State private var showAddChild = false
    @State private var newChildName = ""
    @State private var renameTarget: Child?
    @State private var renameText = ""

    var body: some View {
        List {
            if vm.children.isEmpty && !vm.isLoading {
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
                    // offering it, so it appears only once the child is empty.
                    if vm.devices(for: child).isEmpty {
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
                    Text(durationText(usedMinutes))
                        .font(.headline)
                        .monospacedDigit()
                }
                if onlineCount > 0 {
                    HStack(spacing: 6) {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
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
