import SwiftUI

@MainActor
class DeviceDetailViewModel: ObservableObject {
    let deviceId: String

    @Published var device: Device?
    @Published var policy: Policy?
    @Published var usage: [UsageEntry] = []
    @Published var allChildren: [Child] = []
    @Published var isLoading = false
    @Published var isSaving = false

    /// Failure of the initial load. Rendered by the view's `vm.policy == nil` branch as a
    /// full-screen message with a Retry button.
    @Published var error: String?

    /// Failure of a mutating action (a cap change, a move, a rename, a policy edit).
    /// Deliberately separate from `error`: the load branch is only reachable while `policy`
    /// is nil, so an action failure written there renders nothing at all once the screen
    /// has loaded once -- which is how every mutating control on this screen used to fail
    /// in total silence. This is parental-control software: a control that did not take
    /// effect must never look like one that did. The view surfaces this as an alert
    /// attached OUTSIDE the load gate, so it shows whatever the load state.
    @Published var actionError: String?
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
        // A failing /children request must not block the rest of the device screen --
        // the child picker just becomes unavailable, everything else still works.
        await loadChildren()
        isLoading = false
    }

    func loadChildren() async {
        allChildren = (try? await api.listChildren()) ?? []
    }

    /// Moves the device onto a different child -- this is what merges two devices onto
    /// one shared daily budget. The server re-keys the device's child_id (and its own
    /// activities) and makes sure the destination child has a policy, but it does NOT
    /// touch this device's own daily_cap_minutes column. What DOES change is the
    /// *effective* policy (screen time limit etc.), which /devices/{id}/policy resolves
    /// from the device's current child_id -- so refetch it after the move, or the "Today"
    /// card keeps showing the old child's limit until the next full reload.
    func moveToChild(_ childId: String) async {
        do {
            var update = DeviceUpdateRequest()
            update.childId = childId
            device = try await api.updateDevice(deviceId, update: update)
            if let newPolicy = try? await api.getPolicy(deviceId: deviceId) {
                policy = newPolicy
            }
        } catch {
            self.actionError = error.localizedDescription
        }
    }

    /// Returns whether the rename actually reached the server. The sheet dismisses only
    /// on `true`: dismissing on failure reads to the parent as confirmation.
    @discardableResult
    func updateDeviceName(name: String, childName: String) async -> Bool {
        isSaving = true
        defer { isSaving = false }
        do {
            device = try await api.updateDevice(deviceId, update: DeviceUpdateRequest(name: name, childName: childName))
            return true
        } catch {
            self.actionError = error.localizedDescription
            return false
        }
    }

    // Note: the brief's snippet used `errorMessage`, but this view model's error property
    // (used by every other method here) is named `error` -- matching that instead.
    //
    // Picking "None" must send an explicit JSON null, not omit the field -- DeviceUpdateRequest
    // only encodes dailyCapMinutes when it's non-nil, and the server only clears a column when
    // the key is present in the request body. Route nil through clearFields instead.
    /// Returns whether the cap actually reached the server, so the view can roll back the
    /// value it recorded as sent. Without that rollback its no-op guard swallows a retry of
    /// the same value and the parent cannot set that cap at all.
    @discardableResult
    func updateCap(_ minutes: Int?) async -> Bool {
        do {
            var update = DeviceUpdateRequest()
            if let minutes {
                update.dailyCapMinutes = minutes
            } else {
                update.clearFields = [.dailyCapMinutes]
            }
            device = try await APIClient.shared.updateDevice(deviceId, update: update)
            return true
        } catch {
            self.actionError = error.localizedDescription
            return false
        }
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
                self.actionError = error.localizedDescription
                break
            }
        }

        isUpdating = false
        isSaving = false
    }

    private func mergeUpdates(existing: PolicyUpdate?, new: PolicyUpdate) -> PolicyUpdate {
        guard let existing else { return new }
        var merged = PolicyUpdate(
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
        merged.clearFields = existing.clearFields.union(new.clearFields)
        return merged
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
