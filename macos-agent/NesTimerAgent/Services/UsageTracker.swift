import Foundation
import IOKit.pwr_mgt
import ApplicationServices

/// Tracks actual screen usage time by monitoring user activity.
/// Only counts time when:
///   1. Screen is powered on (not sleeping)
///   2. Screen is NOT locked (user is logged in at desktop)
///   3. User is not idle for too long (keyboard/mouse activity within threshold)
class UsageTracker {
    private var usedMinutesToday: Double = 0.0
    private var trackingDate: String = ""
    private var lastTickTime: Date?
    private let tickInterval: TimeInterval = 30

    /// Max idle time before we stop counting (5 minutes).
    private let maxIdleSeconds: Double = 300

    /// The clock. Injected so the day rollover can be tested without waiting for midnight.
    private let now: () -> Date

    private let localStoragePath: String

    private static let defaultStoragePath: String = {
        // Try locations in order: /Library app support (root), user app support, /tmp
        let candidates: [URL] = [
            FileManager.default.urls(for: .applicationSupportDirectory, in: .localDomainMask).first,
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            URL(fileURLWithPath: "/tmp"),
        ].compactMap { $0 }

        for base in candidates {
            let dir = base.appendingPathComponent("NesTimerAgent")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                return dir.appendingPathComponent("usage.json").path
            } catch {
                continue
            }
        }
        // Last resort
        return "/tmp/NesTimerAgent-usage.json"
    }()

    init(now: @escaping () -> Date = Date.init, storagePath: String? = nil) {
        self.now = now
        self.localStoragePath = storagePath ?? Self.defaultStoragePath
        loadLocalState()
    }

    /// Starts a fresh counter when the local date has moved on. Returns true if it did.
    @discardableResult
    private func rollOverIfNeeded() -> Bool {
        let today = currentDateString()
        guard today != trackingDate else { return false }
        usedMinutesToday = 0
        trackingDate = today
        lastTickTime = nil
        return true
    }

    /// The date and its total, read together. A usage report must take both from here:
    /// reading the total and then asking for the date separately lets midnight fall in
    /// between, which posts yesterday's minutes under today's date. Also rolls the day
    /// over, so a new date never carries the old total even if no tick has run yet
    /// (ticks pause during activities, bonus time and before the first sync).
    func snapshot() -> (date: String, minutes: Double) {
        if rollOverIfNeeded() { saveLocalState() }
        return (trackingDate, usedMinutesToday)
    }

    /// Called on a timer. Returns accumulated minutes for today.
    func tick() -> Double {
        rollOverIfNeeded()

        let now = self.now()

        if let lastTick = lastTickTime, isUserActive() {
            let elapsed = now.timeIntervalSince(lastTick)
            if elapsed < tickInterval * 3 {
                usedMinutesToday += elapsed / 60.0
            }
        }

        lastTickTime = now
        saveLocalState()
        return usedMinutesToday
    }

    /// Force-set usage to server value (used on first sync to clear stale cache).
    func forceSetUsedMinutes(_ minutes: Double, forDate date: String) {
        if date == currentDateString() {
            usedMinutesToday = minutes
            trackingDate = date
            saveLocalState()
        }
    }

    func setUsedMinutes(_ minutes: Double, forDate date: String) {
        if date == currentDateString() {
            // Server is the source of truth — accept its value.
            // Local could be higher (counted between syncs) or lower (parent reset).
            // Use server value if local was reset, otherwise keep local (more recent ticks).
            if minutes > usedMinutesToday {
                usedMinutesToday = minutes
            }
            // If server reports LESS than local (parent manually reset),
            // respect the reset on next sync.
            if minutes < usedMinutesToday - 5 {
                NSLog("[NesTimerAgent] Server reset detected: server=\(String(format: "%.1f", minutes))m, local=\(String(format: "%.1f", usedMinutesToday))m — accepting server value")
                usedMinutesToday = minutes
            }
        }
    }

    func getUsedMinutesToday() -> Double {
        usedMinutesToday
    }

    func currentDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter.string(from: now())
    }

    // MARK: - Activity detection

    private func isUserActive() -> Bool {
        guard isScreenAwake() else { return false }
        guard !isScreenLocked() else { return false }
        guard !isUserIdle() else { return false }
        return true
    }

    // MARK: - Screen power (IOKit)

    private func isScreenAwake() -> Bool {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayWrangler"),
            &iterator
        )
        guard result == KERN_SUCCESS else { return true }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else { return true }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS, let dict = properties?.takeRetainedValue() as? [String: Any] else {
            return true
        }

        if let powerState = dict["DevicePowerState"] as? Int {
            return powerState > 0
        }
        return true
    }

    // MARK: - Lock screen detection

    private func isScreenLocked() -> Bool {
        // CGSessionCopyCurrentDictionary returns session info including lock state
        if let sessionDict = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if let isLocked = sessionDict["CGSSessionScreenIsLocked"] as? Bool {
                return isLocked
            }
        }
        return false
    }

    // MARK: - Idle detection (HIDSystem)

    private func isUserIdle() -> Bool {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOHIDSystem"),
            &iterator
        )
        guard result == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }

        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return false }
        defer { IOObjectRelease(entry) }

        var unmanagedDict: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(entry, &unmanagedDict, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS,
              let dict = unmanagedDict?.takeRetainedValue() as? [String: Any] else {
            return false
        }

        if let idleNano = dict["HIDIdleTime"] as? UInt64 {
            return Double(idleNano) / 1_000_000_000.0 > maxIdleSeconds
        }
        if let idleNumber = dict["HIDIdleTime"] as? NSNumber {
            return idleNumber.doubleValue / 1_000_000_000.0 > maxIdleSeconds
        }
        return false
    }

    // MARK: - Persistence

    private func loadLocalState() {
        guard let data = FileManager.default.contents(atPath: localStoragePath),
              let state = try? JSONDecoder().decode(LocalState.self, from: data) else {
            trackingDate = currentDateString()
            return
        }
        if state.date == currentDateString() {
            trackingDate = state.date
            usedMinutesToday = state.usedMinutes
        } else {
            trackingDate = currentDateString()
            usedMinutesToday = 0
        }
    }

    private func saveLocalState() {
        let state = LocalState(date: trackingDate, usedMinutes: usedMinutesToday)
        guard let data = try? JSONEncoder().encode(state) else {
            NSLog("[NesTimerAgent] Failed to encode usage state")
            return
        }
        // Atomic write: write to temp file, then rename
        let tempPath = localStoragePath + ".tmp"
        let url = URL(fileURLWithPath: tempPath)
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.moveItem(atPath: tempPath, toPath: localStoragePath)
        } catch {
            // Fallback: direct write
            FileManager.default.createFile(atPath: localStoragePath, contents: data)
        }
    }

    struct LocalState: Codable {
        let date: String
        let usedMinutes: Double
    }
}
