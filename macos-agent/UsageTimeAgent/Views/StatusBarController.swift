import AppKit
import SwiftUI

/// Manages the menu bar status item (tray icon).
/// Shows remaining time and basic status info.
class StatusBarController {
    private var statusItem: NSStatusItem
    private weak var usageTracker: UsageTracker?
    private var currentPolicy: ServerPolicy?
    private var menu: NSMenu

    init(usageTracker: UsageTracker?) {
        self.usageTracker = usageTracker
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.menu = NSMenu()

        setupStatusItem()
        buildMenu()
    }

    // MARK: - Public

    func updateDisplay(usedMinutes: Double) {
        guard let button = statusItem.button else { return }

        if let policy = currentPolicy, policy.screenTimeEnabled {
            let remaining = Double(policy.screenTimeLimitMinutes) - usedMinutes
            if remaining > 0 {
                let h = Int(remaining) / 60
                let m = Int(remaining) % 60
                if h > 0 {
                    button.title = " \(h)ч \(m)м"
                } else {
                    button.title = " \(m)м"
                }
            } else {
                button.title = " 0м"
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
        if let image = NSImage(systemSymbolName: "clock.badge.checkmark", accessibilityDescription: "UsageTime") {
            image.size = NSSize(width: 18, height: 18)
            button.image = image
            button.imagePosition = .imageLeading
        }

        statusItem.menu = menu
    }

    private func buildMenu() {
        menu.removeAllItems()

        // Header
        let headerItem = NSMenuItem(title: "UsageTime Agent", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        menu.addItem(NSMenuItem.separator())

        // Usage info
        if let tracker = usageTracker {
            let used = tracker.getUsedMinutesToday()
            let usedText = formatMinutes(Int(used))

            if let policy = currentPolicy {
                if policy.screenTimeEnabled {
                    let remaining = max(0, Double(policy.screenTimeLimitMinutes) - used)
                    let limitText = formatMinutes(policy.screenTimeLimitMinutes)

                    let usageItem = NSMenuItem(
                        title: "Использовано: \(usedText) из \(limitText)",
                        action: nil,
                        keyEquivalent: ""
                    )
                    usageItem.isEnabled = false
                    menu.addItem(usageItem)

                    let remainingItem = NSMenuItem(
                        title: "Осталось: \(formatMinutes(Int(remaining)))",
                        action: nil,
                        keyEquivalent: ""
                    )
                    remainingItem.isEnabled = false
                    menu.addItem(remainingItem)
                } else {
                    let usageItem = NSMenuItem(
                        title: "Использовано: \(usedText)",
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
                        title: "Даунтайм: \(policy.downtimeStart) – \(policy.downtimeEnd)",
                        action: nil,
                        keyEquivalent: ""
                    )
                    dtItem.isEnabled = false
                    menu.addItem(dtItem)
                }
            } else {
                let usageItem = NSMenuItem(
                    title: "Использовано: \(usedText)",
                    action: nil,
                    keyEquivalent: ""
                )
                usageItem.isEnabled = false
                menu.addItem(usageItem)

                let syncItem = NSMenuItem(title: "Синхронизация...", action: nil, keyEquivalent: "")
                syncItem.isEnabled = false
                menu.addItem(syncItem)
            }
        } else {
            let noConfig = NSMenuItem(title: "Не настроено", action: nil, keyEquivalent: "")
            noConfig.isEnabled = false
            menu.addItem(noConfig)
        }

        menu.addItem(NSMenuItem.separator())

        // Version
        let versionItem = NSMenuItem(
            title: "v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")",
            action: nil,
            keyEquivalent: ""
        )
        versionItem.isEnabled = false
        menu.addItem(versionItem)
    }

    private func formatMinutes(_ m: Int) -> String {
        let h = m / 60
        let min = m % 60
        if h > 0 { return "\(h)ч \(min)м" }
        return "\(min)м"
    }
}
