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
    /// Phone + Messages — never shielded.
    var exempt = FamilyActivitySelection()

    static func load() -> Selections { AppGroup.read(Selections.self, from: AppGroup.selectionURL) ?? Selections() }
    func save() { AppGroup.write(self, to: AppGroup.selectionURL) }
}

struct FileStateStore: StateStore {
    func load() -> AgentState { AppGroup.read(AgentState.self, from: AppGroup.stateURL) ?? AgentState() }
    func save(_ s: AgentState) { AppGroup.write(s, to: AppGroup.stateURL) }
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

struct DeviceActivityScheduler: MonitorScheduler {
    static let daily = DeviceActivityName("daily")
    private let center = DeviceActivityCenter()

    func arm(events: [PlannedEvent], windows: [PlannedWindow]) throws {
        let counted = Selections.load().counted
        var deviceEvents: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for e in events {
            deviceEvents[.init(e.name)] = DeviceActivityEvent(
                applications: counted.applicationTokens, categories: counted.categoryTokens,
                webDomains: counted.webDomainTokens, threshold: DateComponents(minute: e.deviceMinutes),
                includesPastActivity: true)
        }
        let allDay = DeviceActivitySchedule(intervalStart: DateComponents(hour: 0, minute: 0),
                                            intervalEnd: DateComponents(hour: 23, minute: 59), repeats: true)
        center.stopMonitoring()
        try center.startMonitoring(Self.daily, during: allDay, events: deviceEvents)

        let cal = Calendar.current
        let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute]
        for w in windows {
            let s = DeviceActivitySchedule(intervalStart: cal.dateComponents(fields, from: w.start),
                                           intervalEnd: cal.dateComponents(fields, from: w.end), repeats: false)
            try? center.startMonitoring(.init(w.name), during: s)
        }
    }
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

enum Engine {
    static func make() -> SyncEngine {
        SyncEngine(api: AgentClient(), store: FileStateStore(), shield: ManagedShield(),
                   scheduler: DeviceActivityScheduler(), notifier: LocalNotifier(), secrets: Keychain())
    }
}
