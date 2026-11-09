import Foundation

/// Which limit is currently binding — decides what the lock screen tells the child.
public enum LimitSource: Equatable, Sendable {
    case sharedBudget
    case deviceCap
}

/// Remaining screen time, in minutes.
///
/// Two limits apply at once: the child's shared daily budget across all their
/// devices, and an optional ceiling on this device. The tighter one wins.
public enum RemainingTime {

    public static func minutes(
        limitMinutes: Int,
        childUsedMinutes: Double,
        deviceCapMinutes: Int?,
        deviceUsedMinutes: Double
    ) -> Double {
        let fromBudget = Double(limitMinutes) - childUsedMinutes
        guard let cap = deviceCapMinutes else {
            return max(0, fromBudget)
        }
        let fromCap = Double(cap) - deviceUsedMinutes
        return max(0, min(fromBudget, fromCap))
    }

    public static func binding(
        limitMinutes: Int,
        childUsedMinutes: Double,
        deviceCapMinutes: Int?,
        deviceUsedMinutes: Double
    ) -> LimitSource {
        guard let cap = deviceCapMinutes else { return .sharedBudget }
        let fromBudget = Double(limitMinutes) - childUsedMinutes
        let fromCap = Double(cap) - deviceUsedMinutes
        return fromCap < fromBudget ? .deviceCap : .sharedBudget
    }
}
