import Foundation

@MainActor
final class ChildrenViewModel: ObservableObject {
    @Published var children: [Child] = []
    @Published var devices: [Device] = []
    /// Today's shared minutes per child id. Populated per child after `load()`.
    @Published var todayMinutes: [String: Double] = [:]
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// True only when the /children request itself failed (and so `children` is stale or
    /// empty) -- as opposed to errorMessage being set by a failed /devices request (children
    /// still loaded fine) or by an unrelated create/rename/delete failure. Recomputed by
    /// EVERY load(), including the ones createChild/renameChild/deleteChild trigger directly,
    /// so a view driving its "couldn't load" state off this can't go stale the way a
    /// view-local flag recomputed only by the view's own wrapper could.
    @Published var childrenLoadFailed = false

    private let api = APIClient.shared

    func devices(for child: Child) -> [Device] {
        devices.filter { $0.childId == child.id }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        childrenLoadFailed = false

        // Loaded independently and on purpose. This is the screen a parent opens to check
        // on their child's machines, so a failing /children request must not leave it
        // stuck on "Loading..." -- the same reasoning as DevicesPage.jsx on the web.
        do {
            children = try await api.listChildren()
        } catch {
            errorMessage = "Could not load children."
            childrenLoadFailed = true
        }
        do {
            devices = try await api.listDevices()
        } catch {
            if errorMessage == nil {
                errorMessage = "Could not load devices."
            }
        }

        isLoading = false
        await loadTodayMinutes()
    }

    /// One request per child, fanned out concurrently via TaskGroup so the whole batch
    /// costs one round trip's latency instead of N sequential ones -- load() has already
    /// published `children` and set isLoading = false by the time this runs, so figures
    /// simply pop in as each request completes. Failures here are deliberately silent per
    /// child: the list is still usable without that child's figure, and this is the
    /// screen a parent opens to check on their child's machines.
    private func loadTodayMinutes() async {
        let today = Self.todayString()
        let ids = children.map(\.id)
        let api = self.api // captured by value into the child tasks below, not `self`

        await withTaskGroup(of: (id: String, minutes: Double?).self) { group in
            for id in ids {
                group.addTask {
                    guard let rows = try? await api.getChildUsage(childId: id, days: 1) else {
                        return (id, nil)
                    }
                    return (id, rows.first(where: { $0.date == today })?.totalMinutes ?? 0)
                }
            }
            for await result in group {
                if let minutes = result.minutes {
                    todayMinutes[result.id] = minutes
                }
            }
        }
    }

    private static func todayString() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
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
