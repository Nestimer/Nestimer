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
    private let tickInterval: TimeInterval = 30  // Check every 30 seconds

    /// Max idle time before we stop counting (5 minutes).
    /// If the user hasn't touched keyboard/mouse for this long, we don't count it.
    private let maxIdleSeconds: Double = 300

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

        if let lastTick = lastTickTime, isUserActive() {
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

    // MARK: - Activity detection (combines all checks)

    /// Returns true only if the user is actively using the computer:
    /// screen on + not locked + not idle.
    private func isUserActive() -> Bool {
        guard isScreenAwake() else { return false }
        guard !isScreenLocked() else { return false }
        guard !isUserIdle() else { return false }
        return true
    }

    // MARK: - Screen power state (IOKit)

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

    // MARK: - Screen lock detection

    /// Checks if the screen is locked by querying the loginwindow session.
    /// Uses CGSessionCopyCurrentDictionary() which returns session info
    /// including "CGSSessionScreenIsLocked" key.
    private func isScreenLocked() -> Bool {
        // Method 1: CGSessionCopyCurrentDictionary (most reliable)
        // This is a CoreGraphics function available when running as a daemon
        if let sessionDict = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if let isLocked = sessionDict["CGSSessionScreenIsLocked"] as? Bool {
                return isLocked
            }
        }

        // Method 2: Check via ioreg for screen saver / lock state
        // The screenIsLocked property in loginwindow
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            """
            import subprocess, sys
            result = subprocess.run(
                ['/usr/bin/ioreg', '-n', 'Root', '-d1', '-a'],
                capture_output=True, text=True
            )
            sys.exit(0 if 'IOConsoleLocked' not in result.stdout else 1)
            """
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            // Exit code 1 = locked, 0 = not locked
            return process.terminationStatus != 0
        } catch {
            return false // Assume not locked on error
        }
    }

    // MARK: - User idle detection (HID idle time)

    /// Returns true if the user has been idle (no keyboard/mouse input)
    /// for longer than maxIdleSeconds.
    /// Uses IOKit HIDSystem to get idle time.
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

        // HIDIdleTime is in nanoseconds
        if let idleTimeNano = dict["HIDIdleTime"] as? UInt64 {
            let idleSeconds = Double(idleTimeNano) / 1_000_000_000.0
            return idleSeconds > maxIdleSeconds
        }

        // Try as NSNumber (sometimes it comes as this type)
        if let idleTimeNumber = dict["HIDIdleTime"] as? NSNumber {
            let idleSeconds = idleTimeNumber.doubleValue / 1_000_000_000.0
            return idleSeconds > maxIdleSeconds
        }

        return false
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
