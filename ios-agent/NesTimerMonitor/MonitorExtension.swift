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

    /// Restarting the daily activity (which we do to re-arm events) makes iOS call
    /// intervalDidEnd/intervalDidStart for it right away. Only the real day boundary
    /// matters; anything else is our own echo and would loop.
    private func isEcho(_ activity: DeviceActivityName) -> Bool {
        guard activity == DeviceActivityScheduler.daily else { return false }
        let cal = AppGroup.homeCalendar
        let minute = cal.component(.hour, from: Date()) * 60 + cal.component(.minute, from: Date())
        return minute > 2 && minute < 24 * 60 - 2
    }

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        if isEcho(activity) { return }
        run { DebugLog.write("intervalDidStart \(activity.rawValue) → \(await $0.onIntervalBoundary())") }
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        if isEcho(activity) { return }
        run { DebugLog.write("intervalDidEnd \(activity.rawValue) → \(await $0.onIntervalBoundary())") }
    }

    /// Callbacks are synchronous and the process may be suspended once they return, so we
    /// wait for the wake to finish — but by spinning the run loop, not blocking the thread:
    /// DeviceActivity/ManagedSettings calls inside the wake need this (main) thread, and a
    /// semaphore wait here stalled every wake until its timeout.
    private func run(_ body: @escaping @Sendable (SyncEngine) async -> Void) {
        let done = Flag(), timedOut = Flag()
        let started = Date()
        let deferred = DeferredScheduler()
        Task.detached {
            await body(Engine.make(scheduler: deferred))
            done.set()
            // Finished after the callback returned: arm what it planned now (best effort;
            // iOS may already have suspended us).
            if timedOut.isSet { DispatchQueue.global(qos: .userInitiated).async { deferred.flush() } }
        }
        let deadline = Date().addingTimeInterval(25)
        while !done.isSet && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if !done.isSet {
            timedOut.set()
            // Nothing planned yet: at least keep the heartbeat so another wake comes.
            DispatchQueue.global(qos: .userInitiated).async { DeviceActivityScheduler().ensureHeartbeat() }
        }
        // Arm after this callback returns (startMonitoring waits for it).
        DispatchQueue.global(qos: .userInitiated).async { deferred.flush() }
        let took = Date().timeIntervalSince(started)
        if timedOut.isSet {
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
