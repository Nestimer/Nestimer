import SwiftUI

struct DevicesListView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @StateObject private var vm = DevicesViewModel()
    @State private var showAddDevice = false

    var body: some View {
        List {
            if vm.devices.isEmpty && !vm.isLoading {
                ContentUnavailableView {
                    Label("Нет устройств", systemImage: "desktopcomputer")
                } description: {
                    Text("Добавьте Mac ребёнка, чтобы начать контроль")
                } actions: {
                    Button("Добавить устройство") {
                        showAddDevice = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            ForEach(vm.devices) { device in
                NavigationLink(value: device.id) {
                    DeviceRow(device: device)
                }
            }
            .onDelete { indexSet in
                for i in indexSet {
                    let device = vm.devices[i]
                    Task { await vm.deleteDevice(device.id) }
                }
            }
        }
        .navigationTitle("Устройства")
        .navigationDestination(for: String.self) { deviceId in
            DeviceDetailView(deviceId: deviceId)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddDevice = true
                } label: {
                    Image(systemName: "plus")
                }
            }

            ToolbarItem(placement: .cancellationAction) {
                Menu {
                    if let user = authVM.user {
                        Text(user.name)
                        Text(user.email)
                        Divider()
                    }
                    Button("Выйти", role: .destructive) {
                        authVM.logout()
                    }
                } label: {
                    Image(systemName: "person.circle")
                }
            }
        }
        .refreshable {
            await vm.loadDevices()
        }
        .task {
            await vm.loadDevices()
        }
        .sheet(isPresented: $showAddDevice) {
            AddDeviceView(vm: vm)
        }
    }
}

struct DeviceRow: View {
    let device: Device

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.headline)

                Text(device.childName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(device.isOnline ? Color.green : Color.gray.opacity(0.3))
                    .frame(width: 8, height: 8)

                Text(device.isOnline ? "Онлайн" : device.lastSeenText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
