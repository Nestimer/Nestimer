import SwiftUI

@MainActor
class DevicesViewModel: ObservableObject {
    @Published var devices: [Device] = []
    @Published var isLoading = false
    @Published var error: String?

    private let api = APIClient.shared

    func loadDevices() async {
        isLoading = true
        error = nil
        do {
            devices = try await api.listDevices()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func createDevice(name: String, childName: String) async -> Device? {
        do {
            let device = try await api.createDevice(name: name, childName: childName)
            await loadDevices()
            return device
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func deleteDevice(_ id: String) async {
        do {
            try await api.deleteDevice(id)
            devices.removeAll { $0.id == id }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
