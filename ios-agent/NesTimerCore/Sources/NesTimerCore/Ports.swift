import Foundation

/// The outside world, as the SyncEngine sees it. iOS adapters implement these in
/// ios-agent/Shared; tests use in-memory fakes.
public protocol AgentAPI: Sendable {
    func fetchConfig(localDate: String) async throws -> ServerPolicy
    func reportUsage(date: String, totalMinutes: Double) async throws
    /// Returns false for any server answer that isn't "valid" (including 429).
    /// Throws only when the server can't be reached; only then may the engine fall back
    /// to the Keychain secret.
    func verifyTOTP(code: String) async throws -> Bool
}

public protocol StateStore: Sendable {
    func load() -> AgentState
    func save(_ state: AgentState)
}

public protocol Shield: Sendable {
    func apply(_ reason: ShieldReason)
    func remove()
}

public protocol MonitorScheduler: Sendable {
    func arm(events: [PlannedEvent], windows: [PlannedWindow]) throws
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

    public init() {}

    /// What counts against the budget.
    public var countedMinutes: Double { max(0, observedMinutes - pausedMinutes, serverFloorMinutes) }
}
