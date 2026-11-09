import Foundation

/// The outside world, as the SyncEngine sees it. iOS adapters implement these in
/// ios-agent/Shared; tests use in-memory fakes.
/// A config response plus the server's clock (from the HTTP Date header), the only time
/// source the child can't change.
public struct ConfigResponse: Sendable {
    public let policy: ServerPolicy
    public let serverTime: Date?
    public init(policy: ServerPolicy, serverTime: Date?) { self.policy = policy; self.serverTime = serverTime }
}

public protocol AgentAPI: Sendable {
    func fetchConfig(localDate: String) async throws -> ConfigResponse
    func reportUsage(date: String, totalMinutes: Double) async throws
    /// Returns false for any server answer that isn't "valid" (including 429).
    /// Throws only when the server can't be reached; only then may the engine fall back
    /// to the Keychain secret.
    func verifyTOTP(code: String) async throws -> Bool
}

public protocol StateStore: Sendable {
    func load() -> AgentState
    func save(_ state: AgentState)
    /// Read-modify-write without another process (app vs. monitor extension) writing in
    /// between. The file-backed store holds an flock while the closure runs.
    func update<T>(_ body: (inout AgentState) -> T) -> T
}

public extension StateStore {
    func update<T>(_ body: (inout AgentState) -> T) -> T {
        var s = load(); let r = body(&s); save(s); return r
    }
}

public protocol Shield: Sendable {
    func apply(_ reason: ShieldReason)
    func remove()
}

public protocol MonitorScheduler: Sendable {
    /// Usage events on the daily activity. A throw means no lock will fire: the engine shields.
    func armEvents(_ events: [PlannedEvent]) throws
    /// Downtime/activity/bonus windows. Best effort; usage events still bound any miss.
    func armWindows(_ windows: [PlannedWindow]) throws
}

public protocol Notifier: Sendable {
    func warn(minutesLeft: Int)
    func expired()
}

public protocol SecretStore: Sendable {
    func totpSecret() -> String?
}

/// Everything the engine remembers between wakes (App Group JSON).
public struct AgentState: Codable, Equatable, Sendable {
    /// Local date (yyyy-MM-dd) the counters belong to.
    public var date: String = ""
    /// Today's usage as iOS measures it (all non-exempt apps), from threshold events.
    public var observedMinutes: Double = 0
    /// Part of `observedMinutes` spent during an activity or a TOTP unlock — not counted,
    /// matching the Mac, where those states pause counting.
    public var pausedMinutes: Double = 0
    /// Last total the server acknowledged.
    public var reportedMinutes: Double = 0
    public var snapshot: ServerPolicy?
    /// The local date `snapshot`'s usage numbers belong to.
    public var snapshotDate: String?
    public var snapshotAt: Date?
    public var unlockUntil: Date?
    /// `observedMinutes` value at which a TOTP unlock ends (5 minutes of use).
    public var unlockEndsAtObserved: Int?
    public var warned: Set<Int> = []
    /// Whether counting was paused at the last wake (activity / TOTP unlock).
    public var paused: Bool = false
    public var shielded: Bool = false
    /// Device usage the server already holds for today (e.g. after a reinstall).
    public var serverFloorMinutes: Double = 0
    /// Recent code attempts, for the local rate limit.
    public var codeAttempts: [Date] = []
    /// Highest TOTP step ever accepted; a code at or below it is spent.
    public var lastCodeStep: Int64 = -1

    // Trusted time: the last server time seen, and the monotonic uptime at that moment.
    // trusted now = anchorTime + (uptime - anchorUptime), unless the phone rebooted.
    public var anchorTime: Date?
    public var anchorUptime: TimeInterval?
    /// The latest trusted time ever established; the clock may never go back past it.
    public var latestTrusted: Date?

    // For splitting a usage delta between paused and counted time.
    public var lastWakeAt: Date?
    /// When `observedMinutes` last grew; it may grow by at most the time elapsed since.
    public var lastObservedAt: Date?
    /// Last time a wake went to the network; bursts within seconds re-use the snapshot.
    public var lastNetworkAt: Date?
    /// The usage events currently armed on iOS (absolute deviceMinutes, relative thresholds)
    /// and the day they were armed for. Nil = must (re-)arm.
    public var armedEvents: [PlannedEvent]?
    public var armedDate: String?
    public var secondsSinceObservation: TimeInterval = 0
    public var pausedSecondsSinceObservation: TimeInterval = 0

    public init() {}

    /// What counts against the budget.
    public var countedMinutes: Double { max(0, observedMinutes - pausedMinutes, serverFloorMinutes) }
}
