import Foundation
import IOKit.pwr_mgt

/// Tracks actual screen usage time by monitoring user activity.
/// Uses IOKit to detect if the screen is active (not asleep/locked).
class UsageTracker {
    private var usedMinutesToday: Double = 0.0
    private var trackingDate: String = ""
    private var lastTickTime: Date?
    private var isActive: Bool = true
    private let tickInterval: TimeInterval = 30  // Check every 30 seconds

    private let localStoragePath = "/var/lib/usagetime/usage.json"

    init() {
        loadLocalState()
    }

    /// Called on a timer. Returns accumulated minutes for today.
    func tick() -> Double {
        let today = currentDateString()

        // Reset if new day
        if today != trackingDate {
            usedMinutesToday = 0
            trackingDate = today
            lastTickTime = nil
        }

        let now = Date()

        if let lastTick = lastTickTime, isScreenAwake() {
            let elapsed = now.timeIntervalSince(lastTick)
            // Only count if elapsed is reasonable (not after sleep/suspend)
            if elapsed < tickInterval * 3 {
                usedMinutesToday += elapsed / 60.0
            }
        }

        lastTickTime = now
        saveLocalState()
        return usedMinutesToday
    }

    /// Set usage from server (e.g., on startup sync).
    func setUsedMinutes(_ minutes: Double, forDate date: String) {
        if date == currentDateString() {
            // Take the higher value to avoid losing tracked time
            usedMinutesToday = max(usedMinutesToday, minutes)
        }
    }

    func getUsedMinutesToday() -> Double {
        return usedMinutesToday
    }

    func currentDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    // MARK: - Screen state detection

    private func isScreenAwake() -> Bool {
        // Use IOKit to check display power state
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayWrangler"),
            &iterator
        )
        guard result == KERN_SUCCESS else { return true } // assume active on error

        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else { return true }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS, let dict = properties?.takeRetainedValue() as? [String: Any] else {
            return true
        }

        // Check if display is powered on
        if let powerState = dict["DevicePowerState"] as? Int {
            return powerState > 0
        }
        return true
    }

    // MARK: - Local persistence

    private func loadLocalState() {
        guard let data = FileManager.default.contents(atPath: localStoragePath),
              let state = try? JSONDecoder().decode(LocalState.self, from: data) else {
            trackingDate = currentDateString()
            return
        }
        trackingDate = state.date
        if state.date == currentDateString() {
            usedMinutesToday = state.usedMinutes
        } else {
            trackingDate = currentDateString()
        }
    }

    private func saveLocalState() {
        let state = LocalState(date: trackingDate, usedMinutes: usedMinutesToday)
        guard let data = try? JSONEncoder().encode(state) else { return }

        let dir = (localStoragePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: localStoragePath, contents: data)
    }

    struct LocalState: Codable {
        let date: String
        let usedMinutes: Double
    }
}
