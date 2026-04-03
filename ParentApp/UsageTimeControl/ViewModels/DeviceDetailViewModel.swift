import SwiftUI

@MainActor
class DeviceDetailViewModel: ObservableObject {
    let deviceId: String

    @Published var device: Device?
    @Published var policy: Policy?
    @Published var usage: [UsageEntry] = []
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var error: String?

    private let api = APIClient.shared

    init(deviceId: String) {
        self.deviceId = deviceId
    }

    func load() async {
        isLoading = true
        error = nil
        do {
            async let dev = api.getDevice(deviceId)
            async let pol = api.getPolicy(deviceId: deviceId)
            async let usg = api.getUsage(deviceId: deviceId, days: 7)
            let (d, p, u) = try await (dev, pol, usg)
            device = d
            policy = p
            usage = u
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func updatePolicy(_ update: PolicyUpdate) async {
        isSaving = true
        do {
            policy = try await api.updatePolicy(deviceId: deviceId, update: update)
        } catch {
            self.error = error.localizedDescription
        }
        isSaving = false
    }

    // Convenience helpers for toggling
    func setDowntimeEnabled(_ enabled: Bool) async {
        await updatePolicy(PolicyUpdate(downtimeEnabled: enabled))
    }

    func setDowntimeStart(_ time: String) async {
        await updatePolicy(PolicyUpdate(downtimeStart: time))
    }

    func setDowntimeEnd(_ time: String) async {
        await updatePolicy(PolicyUpdate(downtimeEnd: time))
    }

    func setScreenTimeEnabled(_ enabled: Bool) async {
        await updatePolicy(PolicyUpdate(screenTimeEnabled: enabled))
    }

    func setScreenTimeLimit(_ minutes: Int) async {
        await updatePolicy(PolicyUpdate(screenTimeLimitMinutes: minutes))
    }

    func setWeekendLimit(_ minutes: Int?) async {
        await updatePolicy(PolicyUpdate(screenTimeWeekendLimitMinutes: minutes))
    }

    // Computed helpers
    var usedToday: Double {
        usage.first?.totalMinutes ?? 0
    }

    var limitMinutes: Int {
        policy?.screenTimeLimitMinutes ?? 120
    }

    var usagePercent: Double {
        guard limitMinutes > 0 else { return 0 }
        return min(1.0, usedToday / Double(limitMinutes))
    }
}
