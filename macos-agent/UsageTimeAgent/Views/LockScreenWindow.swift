import AppKit
import SwiftUI

/// Full-screen overlay window that blocks all interaction when time is up.
/// Sits above everything including the Dock and menu bar.
class LockScreenWindow {
    private var windows: [NSWindow] = []
    private var isShowing = false
    private var currentReason: LockReason?

    enum LockReason: Equatable {
        case downtime(until: String)
        case timeExpired

        var title: String {
            switch self {
            case .downtime: return "Время отдыха"
            case .timeExpired: return "Время вышло"
            }
        }

        var message: String {
            switch self {
            case .downtime(let until): return "Компьютер доступен с \(until)"
            case .timeExpired: return "Экранное время на сегодня закончилось"
            }
        }

        var icon: String {
            switch self {
            case .downtime: return "moon.zzz.fill"
            case .timeExpired: return "hourglass.bottomhalf.filled"
            }
        }
    }

    func show(reason: LockReason) {
        // Update text if already showing with different reason
        if isShowing && currentReason == reason { return }

        hide() // clear old windows first
        currentReason = reason
        isShowing = true

        // Create a blocking window on every screen
        for screen in NSScreen.screens {
            let window = createBlockingWindow(for: screen, reason: reason)
            windows.append(window)
            window.makeKeyAndOrderFront(nil)
        }

        // Also hide the Dock and steal focus
        NSApp.activate(ignoringOtherApps: true)

        // Disable Force Quit (Cmd+Opt+Esc) by setting window level extremely high
        // and preventing app switching
        NSLog("[UsageTimeAgent] Lock screen shown: \(reason.title)")
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false
        currentReason = nil

        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()

        NSLog("[UsageTimeAgent] Lock screen hidden")
    }

    // MARK: - Window creation

    private func createBlockingWindow(for screen: NSScreen, reason: LockReason) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )

        // Critical window level settings:
        // .screenSaver level is above everything except the actual screen saver
        // Adding +1 puts us above even that
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        window.isOpaque = true
        window.backgroundColor = .black
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = false
        window.canHide = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [
            .canJoinAllSpaces,       // Show on all Spaces/desktops
            .fullScreenAuxiliary,    // Show over full-screen apps
            .stationary,             // Don't move with spaces
            .ignoresCycle,           // Can't be cycled to via Cmd+Tab
        ]

        // SwiftUI content
        let lockView = LockScreenView(reason: reason)
        window.contentView = NSHostingView(rootView: lockView)

        return window
    }
}

// MARK: - Lock Screen SwiftUI View

struct LockScreenView: View {
    let reason: LockScreenWindow.LockReason

    @State private var opacity: Double = 0

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    Color(nsColor: .init(red: 0.05, green: 0.05, blue: 0.15, alpha: 1)),
                    Color(nsColor: .init(red: 0.1, green: 0.05, blue: 0.2, alpha: 1)),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Icon
                Image(systemName: reason.icon)
                    .font(.system(size: 80))
                    .foregroundStyle(.white.opacity(0.7))
                    .symbolEffect(.pulse, options: .repeating)

                // Title
                Text(reason.title)
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                // Message
                Text(reason.message)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))

                // Current time display
                TimeDisplayView()
                    .padding(.top, 20)

                Spacer()
                Spacer()
            }
        }
        .opacity(opacity)
        .onAppear {
            withAnimation(.easeIn(duration: 0.5)) {
                opacity = 1
            }
        }
    }
}

/// Live clock on the lock screen
struct TimeDisplayView: View {
    @State private var currentTime = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(currentTime, style: .time)
            .font(.system(size: 64, weight: .light, design: .rounded))
            .foregroundStyle(.white.opacity(0.4))
            .monospacedDigit()
            .onReceive(timer) { time in
                currentTime = time
            }
    }
}
