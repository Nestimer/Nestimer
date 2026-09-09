import AppKit
import SwiftUI

/// Manages the menu bar status item (tray icon).
/// Shows remaining time and basic status info.
class StatusBarController {
    private var statusItem: NSStatusItem
    private weak var usageTracker: UsageTracker?
    private var currentPolicy: ServerPolicy?
    private var menu: NSMenu
    /// When true, shows DEV badge and Quit menu item.
    var devMode = false
    /// Minutes the child spent on their OTHER devices, from the last server snapshot.
    /// The usage tracker only holds this device's own usage, so the shared budget the
    /// menu bar counts down against is this plus the tracker's value.
    var otherDevicesUsedMinutes: Double = 0
    /// Currently active scheduled activity (e.g. "English") — shown in menu bar title.
    var activeActivityName: String?
    var activeActivityEndsAt: String?

    init(usageTracker: UsageTracker?) {
        self.usageTracker = usageTracker
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.menu = NSMenu()

        setupStatusItem()
        buildMenu()
    }

    // MARK: - Public

    /// `deviceUsedMinutes` is THIS device's own usage; the child's shared total is that
    /// plus `otherDevicesUsedMinutes`.
    func updateDisplay(deviceUsedMinutes: Double) {
        guard let button = statusItem.button else { return }

        // If activity is active, show its name+end time and skip usage display
        if let name = activeActivityName, let endsAt = activeActivityEndsAt {
            button.title = " \(name) until \(endsAt)"
            buildMenu()
            return
        }

        if let policy = currentPolicy, policy.screenTimeEnabled {
            let remaining = RemainingTime.minutes(
                limitMinutes: policy.screenTimeLimitMinutes,
                childUsedMinutes: otherDevicesUsedMinutes + deviceUsedMinutes,
                deviceCapMinutes: policy.deviceCapMinutes,
                deviceUsedMinutes: deviceUsedMinutes
            )
            if remaining > 0 {
                let h = Int(remaining) / 60
                let m = Int(remaining) % 60
                if h > 0 {
                    button.title = " \(h)h \(m)m"
                } else {
                    button.title = " \(m)m"
                }
            } else {
                button.title = " 0m"
            }
        } else {
            button.title = ""
        }

        buildMenu()
    }

    func updatePolicy(policy: ServerPolicy) {
        self.currentPolicy = policy
    }

    // MARK: - Setup

    private func setupStatusItem() {
        guard let button = statusItem.button else { return }

        // Use SF Symbol for the menu bar icon
        if let image = NSImage(systemSymbolName: "clock.badge.checkmark", accessibilityDescription: "NesTimer") {
            image.size = NSSize(width: 18, height: 18)
            button.image = image
            button.imagePosition = .imageLeading
        }

        statusItem.menu = menu
    }

    private func buildMenu() {
        menu.removeAllItems()

        // Header
        let headerItem = NSMenuItem(title: "NesTimer Agent", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        menu.addItem(NSMenuItem.separator())

        // Usage info
        if let tracker = usageTracker {
            let deviceUsed = tracker.getUsedMinutesToday()
            // "Used: X of Y" counts the shared budget — the child's time on their other
            // devices spends the same allowance as time spent here.
            let used = otherDevicesUsedMinutes + deviceUsed
            let usedText = formatMinutes(Int(used))

            if let policy = currentPolicy {
                if policy.screenTimeEnabled {
                    let remaining = RemainingTime.minutes(
                        limitMinutes: policy.screenTimeLimitMinutes,
                        childUsedMinutes: used,
                        deviceCapMinutes: policy.deviceCapMinutes,
                        deviceUsedMinutes: deviceUsed
                    )
                    let limitText = formatMinutes(policy.screenTimeLimitMinutes)

                    let usageItem = NSMenuItem(
                        title: "Used: \(usedText) of \(limitText)",
                        action: nil,
                        keyEquivalent: ""
                    )
                    usageItem.isEnabled = false
                    menu.addItem(usageItem)

                    let remainingItem = NSMenuItem(
                        title: "Remaining: \(formatMinutes(Int(remaining)))",
                        action: nil,
                        keyEquivalent: ""
                    )
                    remainingItem.isEnabled = false
                    menu.addItem(remainingItem)
                } else {
                    let usageItem = NSMenuItem(
                        title: "Used: \(usedText)",
                        action: nil,
                        keyEquivalent: ""
                    )
                    usageItem.isEnabled = false
                    menu.addItem(usageItem)
                }

                menu.addItem(NSMenuItem.separator())

                // Downtime info
                if policy.downtimeEnabled {
                    let dtItem = NSMenuItem(
                        title: "Downtime: \(policy.downtimeStart) – \(policy.downtimeEnd)",
                        action: nil,
                        keyEquivalent: ""
                    )
                    dtItem.isEnabled = false
                    menu.addItem(dtItem)
                }
            } else {
                let usageItem = NSMenuItem(
                    title: "Used: \(usedText)",
                    action: nil,
                    keyEquivalent: ""
                )
                usageItem.isEnabled = false
                menu.addItem(usageItem)

                let syncItem = NSMenuItem(title: "Syncing...", action: nil, keyEquivalent: "")
                syncItem.isEnabled = false
                menu.addItem(syncItem)
            }
        } else {
            let noConfig = NSMenuItem(title: "Not configured", action: nil, keyEquivalent: "")
            noConfig.isEnabled = false
            menu.addItem(noConfig)
        }

        menu.addItem(NSMenuItem.separator())

        // Version
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let versionText = devMode ? "v\(version) — DEV MODE" : "v\(version)"
        let versionItem = NSMenuItem(title: versionText, action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        // Dev mode: add Quit option
        if devMode {
            menu.addItem(NSMenuItem.separator())
            let quitItem = NSMenuItem(
                title: "Quit (Dev Mode)",
                action: #selector(quitApp),
                keyEquivalent: "q"
            )
            quitItem.target = self
            menu.addItem(quitItem)
        }
    }

    @objc private func quitApp() {
        NSLog("[NesTimerAgent] DEV: Quit via menu")
        NSApp.terminate(nil)
    }

    private func formatMinutes(_ m: Int) -> String {
        let h = m / 60
        let min = m % 60
        if h > 0 { return "\(h)h \(min)m" }
        return "\(min)m"
    }
}
