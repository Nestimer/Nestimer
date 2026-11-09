import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
import NesTimerCore
import UserNotifications

/// The pairing-time picker results: what to count, and what is always allowed.
struct Selections: Codable {
    /// "All Apps & Categories" from the picker — the usage that counts.
    var counted = FamilyActivitySelection()
    /// Messages — never shielded. (iOS never shields Phone; it can't even be picked.)
    var exempt = FamilyActivitySelection()

    static func load() -> Selections { AppGroup.read(Selections.self, from: AppGroup.selectionURL) ?? Selections() }
    func save() { AppGroup.write(self, to: AppGroup.selectionURL) }
}

struct FileStateStore: StateStore {
    func load() -> AgentState { AppGroup.read(AgentState.self, from: AppGroup.stateURL) ?? AgentState() }
    func save(_ s: AgentState) { AppGroup.write(s, to: AppGroup.stateURL) }

    /// The app and the monitor extension are separate processes: hold an exclusive flock on
    /// a lock file in the App Group for each read-modify-write.
    ///
    /// The wait is bounded: iOS can suspend the monitor extension at any moment, and a
    /// suspended process keeps its flock. After 2 s we go ahead unlocked — the merge rules
    /// (max of counters, union of attempts) make a rare lost race cheap; a hung app is not.
    func update<T>(_ body: (inout AgentState) -> T) -> T {
        let path = AppGroup.container.appendingPathComponent("state.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        let started = Date()
        var locked = false
        if fd >= 0 {
            while true {
                locked = flock(fd, LOCK_EX | LOCK_NB) == 0
                if locked || Date().timeIntervalSince(started) >= 2 { break }
                usleep(20_000)
            }
        }
        let waited = Date().timeIntervalSince(started)
        if waited > 0.2 || !locked { DebugLog.write(String(format: "state lock: waited %.2fs, locked=%@", waited, locked ? "yes" : "NO")) }
        defer { if fd >= 0 { if locked { flock(fd, LOCK_UN) }; close(fd) } }
        var s = load()
        let r = body(&s)
        save(s)
        return r
    }
}

struct ManagedShield: Shield {
    private let store = ManagedSettingsStore()

    func apply(_ reason: ShieldReason) {
        AppGroup.write(reason, to: AppGroup.shieldReasonURL)
        let exempt = Selections.load().exempt.applicationTokens
        store.shield.applicationCategories = .all(except: exempt)
        store.shield.webDomainCategories = .all()
    }

    func remove() {
        store.shield.applicationCategories = nil
        store.shield.webDomainCategories = nil
    }
}

/// Re-arms only what changed. Restarting an activity whose interval is in progress makes
/// iOS call intervalDidStart again, which would wake us, which would re-arm... — a loop.
struct DeviceActivityScheduler: MonitorScheduler {
    static let daily = DeviceActivityName("daily")
    private let center = DeviceActivityCenter()
    private var armedURL: URL { AppGroup.container.appendingPathComponent("armed-events.json") }

    func armEvents(_ events: [PlannedEvent]) throws {
        // Name + relative threshold: the same names re-armed from a new base are a change.
        let names = events.map { "\($0.name)@\($0.armThreshold)" }.sorted()
        // Decide and record under a lock, before starting: concurrent wakes (app + several
        // extension callbacks) must not each see "not armed yet" and restart again.
        let lockPath = AppGroup.container.appendingPathComponent("arm.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        var locked = false
        let t0 = Date()
        while fd >= 0 {
            locked = flock(fd, LOCK_EX | LOCK_NB) == 0
            if locked || Date().timeIntervalSince(t0) > 2 { break }
            usleep(20_000)
        }
        defer { if fd >= 0 { if locked { flock(fd, LOCK_UN) }; close(fd) } }
        if AppGroup.read([String].self, from: armedURL) == names { return }
        AppGroup.write(names, to: armedURL)
        let counted = Selections.load().counted
        guard !counted.categoryTokens.isEmpty || !counted.applicationTokens.isEmpty else {
            throw NoSelection()
        }
        var deviceEvents: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for e in events {
            deviceEvents[.init(e.name)] = DeviceActivityEvent(
                applications: counted.applicationTokens, categories: counted.categoryTokens,
                webDomains: counted.webDomainTokens, threshold: DateComponents(minute: e.armThreshold),
                // Count from now, not from midnight: past usage (including other devices'
                // shared Screen Time) would otherwise fire every threshold at once on restart.
                includesPastActivity: false)
        }
        let allDay = DeviceActivitySchedule(intervalStart: DateComponents(hour: 0, minute: 0),
                                            intervalEnd: DateComponents(hour: 23, minute: 59), repeats: true)
        DebugLog.write("restart daily: \(names.count) events \(names.first ?? "")…\(names.last ?? "")")
        center.stopMonitoring([Self.daily])
        try center.startMonitoring(Self.daily, during: allDay, events: deviceEvents)
        AppGroup.write(names, to: armedURL)
    }

    func armWindows(_ windows: [PlannedWindow]) throws {
        let wanted = Set(windows.map(\.name))
        let current = Set(center.activities.map(\.rawValue)).subtracting([Self.daily.rawValue])
        let stale = current.subtracting(wanted)
        if !stale.isEmpty { center.stopMonitoring(stale.map { DeviceActivityName($0) }) }

        let cal = AppGroup.homeCalendar
        let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute]
        if !stale.isEmpty { DebugLog.write("stop windows: \(stale.sorted())") }
        for w in windows where !current.contains(w.name) {
            try start(w, cal: cal, fields: fields)
        }
    }

    /// Arms the current heartbeat without touching other windows — for a wake that timed
    /// out before it could plan, so the next wake still comes.
    func ensureHeartbeat() {
        let hb = SchedulePlanner.heartbeat(now: Date())
        guard !center.activities.contains(.init(hb.name)) else { return }
        try? start(hb, cal: AppGroup.homeCalendar, fields: [.year, .month, .day, .hour, .minute])
    }

    private func start(_ w: PlannedWindow, cal: Calendar, fields: Set<Calendar.Component>) throws {
        DebugLog.write("start window \(w.name)")
        let s = DeviceActivitySchedule(intervalStart: cal.dateComponents(fields, from: w.start),
                                       intervalEnd: cal.dateComponents(fields, from: w.end), repeats: false)
        try center.startMonitoring(.init(w.name), during: s)
    }

    struct NoSelection: Error {}
}

struct LocalNotifier: Notifier {
    func warn(minutesLeft: Int) {
        post(minutesLeft == 1 ? "1 minute of screen time left" : "\(minutesLeft) minutes of screen time left")
    }
    func expired() { post("Screen time is up for today") }

    private func post(_ text: String) {
        let c = UNMutableNotificationContent()
        c.title = "NesTimer"
        c.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

/// For the monitor extension. DeviceActivityCenter.startMonitoring blocks while *any*
/// monitor callback is running — including the one calling it — so inside a callback the
/// arming is only recorded, and `flush()` performs it once the callback has returned.
final class DeferredScheduler: MonitorScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PlannedEvent]?
    private var windows: [PlannedWindow]?

    func armEvents(_ events: [PlannedEvent]) throws { lock.lock(); self.events = events; lock.unlock() }
    func armWindows(_ windows: [PlannedWindow]) throws { lock.lock(); self.windows = windows; lock.unlock() }

    /// Performs what was recorded, once: a second flush only arms what was recorded since.
    func flush() {
        lock.lock(); let e = events, w = windows; events = nil; windows = nil; lock.unlock()
        let real = DeviceActivityScheduler()
        if let e {
            do { try real.armEvents(e) } catch {
                // No lock event could be armed: don't leave the phone open unmonitored.
                DebugLog.write("deferred armEvents failed: \(error) — shielding")
                ManagedShield().apply(.agentError)
                FileStateStore().update { $0.shielded = true; $0.paused = false }
            }
        }
        if let w { try? real.armWindows(w) }
    }
}

enum Engine {
    static func make(scheduler: MonitorScheduler = DeviceActivityScheduler()) -> SyncEngine {
        SyncEngine(api: AgentClient(), store: FileStateStore(), shield: ManagedShield(),
                   scheduler: scheduler, notifier: LocalNotifier(), secrets: Keychain(),
                   calendar: AppGroup.homeCalendar,
                   trace: { step, s in if s > 0.5 { DebugLog.write(String(format: "%@ took %.1fs", step, s)) } })
    }
}
