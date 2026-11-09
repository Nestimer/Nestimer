import DeviceActivity
import Foundation
import NesTimerCore

/// Woken by iOS at usage thresholds and schedule boundaries. Each callback runs one
/// SyncEngine wake and must finish before returning — the process can be suspended after.
final class MonitorExtension: DeviceActivityMonitor {
    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        let name = event.rawValue
        run { engine in
            if let minutes = PlannedEvent.observedMinutes(fromName: name) {
                _ = await engine.onThreshold(eventName: name, observedMinutes: minutes)
            } else {
                _ = await engine.onIntervalBoundary()
            }
        }
    }

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        run { _ = await $0.onIntervalBoundary() }
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        run { _ = await $0.onIntervalBoundary() }
    }

    private func run(_ body: @escaping @Sendable (SyncEngine) async -> Void) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await body(Engine.make())
            done.signal()
        }
        _ = done.wait(timeout: .now() + 25)
    }
}
