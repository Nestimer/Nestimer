import Foundation

@MainActor
final class ChildDetailViewModel: ObservableObject {
    @Published var child: Child?
    @Published var policy: Policy?
    @Published var activities: [Activity] = []
    @Published var devices: [Device] = []
    @Published var usage: [UsageEntry] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    /// True when the child has no devices, so no policy row exists. The API returns 404
    /// rather than creating one -- a Policy with device_id NULL would leave a device that
    /// attaches later without one. The view shows guidance instead of an editor.
    @Published var hasNoDevices = false

    /// Not in the brief's verbatim listing, but bonusSection (moved verbatim from
    /// DeviceDetailView) reads vm.isGrantingBonus and vm.bonusRemainingSeconds. Mirrors
    /// DeviceDetailViewModel's bonus tracking, sourced from Child.bonusUntil instead of
    /// Device.bonusUntil.
    @Published var isGrantingBonus = false

    let childId: String
    private let api = APIClient.shared

    init(childId: String) {
        self.childId = childId
    }

    var todayMinutes: Double {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        return usage.first(where: { $0.date == today })?.totalMinutes ?? 0
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let children = try await api.listChildren()
            child = children.first(where: { $0.id == childId })

            let allDevices = try await api.listDevices()
            devices = allDevices.filter { $0.childId == childId }
            hasNoDevices = devices.isEmpty

            usage = (try? await api.getChildUsage(childId: childId)) ?? []
            activities = (try? await api.listChildActivities(childId: childId)) ?? []

            do {
                policy = try await api.getChildPolicy(childId: childId)
            } catch APIError.notFound {
                policy = nil          // expected for a child with no devices
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func updatePolicy(_ update: PolicyUpdate) async {
        do {
            policy = try await api.updateChildPolicy(childId: childId, update: update)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func grantBonus(minutes: Int) async {
        isGrantingBonus = true
        do {
            try await api.grantChildBonus(childId: childId, minutes: minutes)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
        isGrantingBonus = false
    }

    private func parseISODate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }

    var bonusRemainingSeconds: Int? {
        guard let until = parseISODate(child?.bonusUntil) else { return nil }
        let s = Int(until.timeIntervalSinceNow)
        return s > 0 ? s : nil
    }

    func addActivity(_ activity: ActivityCreate) async {
        do {
            _ = try await api.createChildActivity(childId: childId, activity: activity)
            activities = (try? await api.listChildActivities(childId: childId)) ?? activities
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteActivity(_ activityId: String) async {
        do {
            try await api.deleteChildActivity(childId: childId, activityId: activityId)
            activities.removeAll { $0.id == activityId }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Not in the brief's verbatim ChildDetailViewModel listing, but activityRow (moved
    /// verbatim from DeviceDetailView) calls vm.toggleActivity(activity) -- without this the
    /// moved code does not compile. Mirrors DeviceDetailViewModel.toggleActivity, scoped to
    /// the child's activities via APIClient.updateChildActivity.
    func toggleActivity(_ activity: Activity) async {
        do {
            let updated = try await api.updateChildActivity(
                childId: childId, activityId: activity.id,
                update: ActivityUpdate(enabled: !activity.enabled)
            )
            if let idx = activities.firstIndex(where: { $0.id == activity.id }) {
                activities[idx] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
