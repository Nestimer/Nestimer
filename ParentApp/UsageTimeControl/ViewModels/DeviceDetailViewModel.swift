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
    @Published var currentTOTPCode: String?
    @Published var totpSecondsRemaining: Int = 0
    private var totpTimer: Timer?

    private let api = APIClient.shared

    /// Serializes policy updates so rapid changes don't overwrite each other.
    private var pendingUpdate: PolicyUpdate?
    private var isUpdating = false

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
        // Merge with any pending update to avoid race conditions
        pendingUpdate = mergeUpdates(existing: pendingUpdate, new: update)

        guard !isUpdating else { return } // Already sending — merged update will be sent next
        isUpdating = true
        isSaving = true

        while let update = pendingUpdate {
            pendingUpdate = nil
            do {
                policy = try await api.updatePolicy(deviceId: deviceId, update: update)
            } catch {
                self.error = error.localizedDescription
                break
            }
        }

        isUpdating = false
        isSaving = false
    }

    private func mergeUpdates(existing: PolicyUpdate?, new: PolicyUpdate) -> PolicyUpdate {
        guard let existing else { return new }
        return PolicyUpdate(
            downtimeEnabled: new.downtimeEnabled ?? existing.downtimeEnabled,
            downtimeStart: new.downtimeStart ?? existing.downtimeStart,
            downtimeEnd: new.downtimeEnd ?? existing.downtimeEnd,
            downtimeWeekdayStart: new.downtimeWeekdayStart ?? existing.downtimeWeekdayStart,
            downtimeWeekdayEnd: new.downtimeWeekdayEnd ?? existing.downtimeWeekdayEnd,
            downtimeWeekendStart: new.downtimeWeekendStart ?? existing.downtimeWeekendStart,
            downtimeWeekendEnd: new.downtimeWeekendEnd ?? existing.downtimeWeekendEnd,
            screenTimeEnabled: new.screenTimeEnabled ?? existing.screenTimeEnabled,
            screenTimeLimitMinutes: new.screenTimeLimitMinutes ?? existing.screenTimeLimitMinutes,
            screenTimeWeekendLimitMinutes: new.screenTimeWeekendLimitMinutes ?? existing.screenTimeWeekendLimitMinutes,
            screenTimeMonMinutes: new.screenTimeMonMinutes ?? existing.screenTimeMonMinutes,
            screenTimeTueMinutes: new.screenTimeTueMinutes ?? existing.screenTimeTueMinutes,
            screenTimeWedMinutes: new.screenTimeWedMinutes ?? existing.screenTimeWedMinutes,
            screenTimeThuMinutes: new.screenTimeThuMinutes ?? existing.screenTimeThuMinutes,
            screenTimeFriMinutes: new.screenTimeFriMinutes ?? existing.screenTimeFriMinutes,
            screenTimeSatMinutes: new.screenTimeSatMinutes ?? existing.screenTimeSatMinutes,
            screenTimeSunMinutes: new.screenTimeSunMinutes ?? existing.screenTimeSunMinutes
        )
    }

    func setDayLimit(day: Int, minutes: Int) async {
        // day: 0=Mon, 6=Sun
        var update = PolicyUpdate()
        switch day {
        case 0: update.screenTimeMonMinutes = minutes
        case 1: update.screenTimeTueMinutes = minutes
        case 2: update.screenTimeWedMinutes = minutes
        case 3: update.screenTimeThuMinutes = minutes
        case 4: update.screenTimeFriMinutes = minutes
        case 5: update.screenTimeSatMinutes = minutes
        case 6: update.screenTimeSunMinutes = minutes
        default: return
        }
        await updatePolicy(update)
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

    // MARK: - TOTP code generation

    func startTOTPGeneration() {
        updateTOTPCode()
        totpTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateTOTPCode() }
        }
    }

    func stopTOTPGeneration() {
        totpTimer?.invalidate()
        totpTimer = nil
    }

    private func updateTOTPCode() {
        guard let secret = device?.sharedSecret else {
            currentTOTPCode = nil
            return
        }
        currentTOTPCode = TOTPGenerator.generateCode(secretHex: secret)
        totpSecondsRemaining = TOTPGenerator.secondsRemaining
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
