import Foundation

@MainActor
final class ChildrenViewModel: ObservableObject {
    @Published var children: [Child] = []
    @Published var devices: [Device] = []
    /// Today's shared minutes per child id. Populated per child after `load()`.
    @Published var todayMinutes: [String: Double] = [:]
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let api = APIClient.shared

    func devices(for child: Child) -> [Device] {
        devices.filter { $0.childId == child.id }
    }

    func load() async {
        isLoading = true
        errorMessage = nil

        // Loaded independently and on purpose. This is the screen a parent opens to check
        // on their child's machines, so a failing /children request must not leave it
        // stuck on "Loading..." -- the same reasoning as DevicesPage.jsx on the web.
        do {
            children = try await api.listChildren()
        } catch {
            errorMessage = "Could not load children."
        }
        do {
            devices = try await api.listDevices()
        } catch {
            errorMessage = "Could not load devices."
        }

        isLoading = false
        await loadTodayMinutes()
    }

    /// One request per child. Failures here are deliberately silent: the list is still
    /// usable without today's figure, and this is the screen a parent opens to check on
    /// their child's machines.
    private func loadTodayMinutes() async {
        let today = Self.todayString()
        for child in children {
            guard let rows = try? await api.getChildUsage(childId: child.id, days: 1) else {
                continue
            }
            todayMinutes[child.id] = rows.first(where: { $0.date == today })?.totalMinutes ?? 0
        }
    }

    private static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    func createChild(name: String) async {
        do {
            _ = try await api.createChild(name: name)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameChild(_ id: String, name: String) async {
        do {
            try await api.renameChild(id, name: name)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteChild(_ id: String) async {
        do {
            try await api.deleteChild(id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
