import Foundation

public struct PlannedEvent: Equatable, Sendable, Codable {
    public enum Kind: Equatable, Sendable, Codable {
        case chunk
        case warning(minutesLeft: Int)
        case lock
        case unlockEnd
    }

    public let name: String
    /// Cumulative device usage today (minutes) at which the event fires.
    public let deviceMinutes: Int
    public let kind: Kind
    /// What iOS is given: usage *since the events were armed* (includesPastActivity off),
    /// i.e. deviceMinutes minus the observed usage at arming time. Set by the engine.
    public var armThreshold: Int

    public init(name: String, deviceMinutes: Int, kind: Kind, armThreshold: Int? = nil) {
        self.name = name; self.deviceMinutes = deviceMinutes; self.kind = kind
        self.armThreshold = armThreshold ?? deviceMinutes
    }

    /// Every name ends in "-<deviceMinutes>", so the monitor extension can recover the
    /// observed usage from the event alone: "chunk-85", "warn5-117", "lock-122", "unlockend-65".
    public static func observedMinutes(fromName name: String) -> Int? {
        guard let last = name.split(separator: "-").last else { return nil }
        return Int(last)
    }
}

/// Which DeviceActivity usage events to arm for the rest of today.
public enum ThresholdPlanner {
    public static let chunk = 5
    /// iOS accepted 120 events per activity in the spike; 20 keeps re-arming cheap.
    public static let maxEvents = 20
    public static let warningMinutes = [15, 10, 5, 1]

    public static func plan(deviceUsedMinutes: Double, remainingMinutes: Double?,
                            unlockEndsAfterMinutes: Int?) -> [PlannedEvent] {
        var fixed: [PlannedEvent] = []
        var lockPoint: Int?

        if let unlock = unlockEndsAfterMinutes {
            fixed.append(PlannedEvent(name: "unlockend-\(Int(deviceUsedMinutes.rounded(.up)) + unlock)", deviceMinutes: Int(deviceUsedMinutes.rounded(.up)) + unlock, kind: .unlockEnd))
        }
        if let remaining = remainingMinutes {
            guard remaining > 0 else { return fixed }  // already spent: the caller shields
            let lock = Int((deviceUsedMinutes + remaining).rounded(.up))
            lockPoint = lock
            fixed.append(PlannedEvent(name: "lock-\(lock)", deviceMinutes: lock, kind: .lock))
            for n in warningMinutes {
                let at = Int((deviceUsedMinutes + remaining - Double(n)).rounded(.up))
                if Double(at) > deviceUsedMinutes, at < lock {
                    fixed.append(PlannedEvent(name: "warn\(n)-\(at)", deviceMinutes: at, kind: .warning(minutesLeft: n)))
                }
            }
        }
        if remainingMinutes != nil && lockPoint == nil { return fixed }

        let taken = Set(fixed.map(\.deviceMinutes))
        var chunks: [PlannedEvent] = []
        var m = (Int(deviceUsedMinutes) / chunk + 1) * chunk
        while chunks.count + fixed.count < maxEvents {
            if let lock = lockPoint, m >= lock { break }
            if !taken.contains(m) {
                chunks.append(PlannedEvent(name: "chunk-\(m)", deviceMinutes: m, kind: .chunk))
            }
            m += chunk
            if m > 24 * 60 { break }
        }
        return (fixed + chunks).sorted { $0.deviceMinutes < $1.deviceMinutes }
    }
}
