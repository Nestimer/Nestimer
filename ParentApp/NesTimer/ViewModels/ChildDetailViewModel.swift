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

    /// Serializes policy updates so rapid changes (e.g. stepper auto-repeat) don't overwrite
    /// each other. Mirrors DeviceDetailViewModel.updatePolicy's merge-and-serialize queue.
    private var pendingUpdate: PolicyUpdate?
    private var isUpdatingPolicy = false

    init(childId: String) {
        self.childId = childId
    }

    var todayMinutes: Double {
        let f = DateFormatter()
        // Pinned like ChildrenViewModel.todayString(): an unpinned formatter picks up the
        // device's calendar/locale, so on a non-Gregorian calendar "yyyy-MM-dd" doesn't match
        // the API's date strings and today's usage silently reads as zero.
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
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
            guard child != nil else {
                // Not thrown, so without this the view's gate (vm.child != nil) falls through
                // to an endless spinner -- e.g. the child was deleted elsewhere and this screen
                // still holds its stale id.
                errorMessage = "Child not found"
                isLoading = false
                return
            }

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
        // Merge with any pending update to avoid race conditions -- rows like the per-day
        // stepper fire several updates in quick succession (SwiftUI auto-repeat), and letting
        // them race would let an in-flight request overwrite a later one on the server.
        pendingUpdate = mergeUpdates(existing: pendingUpdate, new: update)

        guard !isUpdatingPolicy else { return } // Already sending — merged update will be sent next
        isUpdatingPolicy = true

        while let next = pendingUpdate {
            pendingUpdate = nil
            do {
                policy = try await api.updateChildPolicy(childId: childId, update: next)
            } catch {
                errorMessage = error.localizedDescription
                break
            }
        }

        isUpdatingPolicy = false
    }

    /// Mirrors DeviceDetailViewModel.mergeUpdates -- kept in sync with it field-for-field.
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

    private var bonusTickTimer: Timer?

    /// Ticks once a second so bonusSection's countdown actually counts down. bonusRemainingSeconds
    /// is computed fresh from Date() on every read, but nothing was re-invoking that read --
    /// DeviceDetailView got this for free from its TOTP timer republishing every second; this
    /// screen has no TOTP display, so it needs its own tick. Call start from bonusSection's
    /// onAppear and stop from onDisappear, mirroring DeviceDetailViewModel's TOTP timer.
    ///
    /// Idempotent (stops any existing timer first) since bonusSection's onAppear can fire more
    /// than once without a matching onDisappear -- an unbalanced call would otherwise leak a
    /// second 1 Hz timer for the app's lifetime. The timer itself runs the whole time the
    /// section is visible (so it's ready the moment a bonus is granted), but only republishes
    /// the view model on ticks where a bonus is actually counting down, so it doesn't wake the
    /// view every second for nothing.
    func startBonusCountdown() {
        stopBonusCountdown()
        bonusTickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.bonusRemainingSeconds != nil else { return }
                self.objectWillChange.send()
            }
        }
    }

    func stopBonusCountdown() {
        bonusTickTimer?.invalidate()
        bonusTickTimer = nil
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
