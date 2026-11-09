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
            let d: Decision
            if let minutes = PlannedEvent.observedMinutes(fromName: name) {
                d = await engine.onThreshold(eventName: name, observedMinutes: minutes)
            } else {
                d = await engine.onIntervalBoundary()
            }
            DebugLog.write("event \(name) [\(activity.rawValue)] → \(d)")
        }
    }

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        run { DebugLog.write("intervalDidStart \(activity.rawValue) → \(await $0.onIntervalBoundary())") }
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        run { DebugLog.write("intervalDidEnd \(activity.rawValue) → \(await $0.onIntervalBoundary())") }
    }

    /// Callbacks are synchronous and the process may be suspended once they return, so we
    /// wait for the wake to finish — but by spinning the run loop, not blocking the thread:
    /// DeviceActivity/ManagedSettings calls inside the wake need this (main) thread, and a
    /// semaphore wait here stalled every wake until its timeout.
    private func run(_ body: @escaping @Sendable (SyncEngine) async -> Void) {
        let done = Flag()
        let started = Date()
        let deferred = DeferredScheduler()
        Task.detached {
            await body(Engine.make(scheduler: deferred))
            done.set()
        }
        let deadline = Date().addingTimeInterval(25)
        while !done.isSet && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        // Arm after this callback returns (startMonitoring waits for it).
        DispatchQueue.global(qos: .userInitiated).async { deferred.flush() }
        let took = Date().timeIntervalSince(started)
        if !done.isSet {
            DebugLog.write("wake timed out after 25s — returning to iOS with work in flight")
        } else if took > 3 {
            DebugLog.write(String(format: "wake took %.1fs", took))
        }
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
