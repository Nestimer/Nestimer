import Foundation
import IOKit.pwr_mgt

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

    private let localStoragePath: String = {
        // Try locations in order: /Library app support (root), user app support, /tmp
        let candidates: [URL] = [
            FileManager.default.urls(for: .applicationSupportDirectory, in: .localDomainMask).first,
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            URL(fileURLWithPath: "/tmp"),
        ].compactMap { $0 }

        for base in candidates {
            let dir = base.appendingPathComponent("UsageTimeAgent")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                return dir.appendingPathComponent("usage.json").path
            } catch {
                continue
            }
        }
        // Last resort
        return "/tmp/UsageTimeAgent-usage.json"
    }()

    init() {
        loadLocalState()
    }

    /// Called on a timer. Returns accumulated minutes for today.
    func tick() -> Double {
        let today = currentDateString()

        if today != trackingDate {
            usedMinutesToday = 0
            trackingDate = today
            lastTickTime = nil
        }

        let now = Date()

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

    func setUsedMinutes(_ minutes: Double, forDate date: String) {
        if date == currentDateString() {
            usedMinutesToday = max(usedMinutesToday, minutes)
        }
    }

    func getUsedMinutesToday() -> Double {
        usedMinutesToday
    }

    func currentDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
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
            NSLog("[UsageTimeAgent] Failed to encode usage state")
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
