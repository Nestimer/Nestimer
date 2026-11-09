import NesTimerCore
import SwiftUI

/// What the child sees: time left, state, and where to type the parent's code.
struct StatusView: View {
    let onUnpair: () -> Void

    @Environment(\.scenePhase) private var phase
    @State private var decision: Decision?
    @State private var code = ""
    @State private var codeMessage: String?
    @State private var lastSync: Date?
    @State private var refreshing = false
    @FocusState private var codeFocused: Bool
    @State private var tzCode = ""
    @State private var tzMessage: String?
    @State private var homeTZ = AppGroup.homeTimeZone

    /// The phone's own time zone differs from the one NesTimer follows (travel).
    private var travelling: Bool { TimeZone.current.identifier != homeTZ.identifier }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    hero
                } footer: {
                    if let lastSync {
                        Text("Updated \(lastSync.formatted(date: .omitted, time: .shortened)) \u{00B7} pull down to refresh")
                            .frame(maxWidth: .infinity)
                    }
                }
                if travelling {
                    Section {
                        Text("Your time zone changed to \(TimeZone.current.identifier). NesTimer still uses \(homeTZ.identifier) time until a parent confirms.")
                            .font(.callout)
                        TextField("Parent's code to switch", text: $tzCode)
                            .keyboardType(.numberPad)
                            .font(.system(.title3, design: .monospaced))
                            .onChange(of: tzCode) { _, v in
                                tzCode = String(v.filter(\.isNumber).prefix(6))
                                if tzCode.count == 6 { Task { await confirmTimeZone() } }
                            }
                        if let tzMessage { Text(tzMessage).font(.footnote) }
                    } header: {
                        Text("Travelling?")
                    }
                }
                Section {
                    TextField("6-digit code", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .multilineTextAlignment(.center)
                        .font(.system(.title, design: .rounded).monospacedDigit().weight(.semibold))
                        .padding(.vertical, 4)
                        .focused($codeFocused)
                        .onChange(of: code) { _, v in
                            code = String(v.filter(\.isNumber).prefix(6))
                            if code.count == 6 { Task { await submit() } }
                        }
                    if let codeMessage {
                        Text(codeMessage).font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                } header: {
                    Label("Code from your parent", systemImage: "key.fill")
                } footer: {
                    Text("Your parent can open it from the NesTimer app or dashboard.")
                }
                #if DEBUG
                Section("Debug") {
                    Button("Refresh") { Task { await refresh() } }
                    Button("Copy debug log") { UIPasteboard.general.string = DebugLog.read() }
                    Button("Reset today's count") {
                        // Back to what the server holds for this device today.
                        FileStateStore().update { s in
                            let floor = s.snapshot?.deviceUsedMinutes ?? 0
                            s.observedMinutes = floor
                            s.pausedMinutes = 0
                            s.serverFloorMinutes = floor
                            s.reportedMinutes = floor
                            s.lastObservedAt = Date()
                            s.armedEvents = nil   // re-arm from the new base
                        }
                        try? FileManager.default.removeItem(at: DebugLog.url)
                        Task { await refresh() }
                    }
                    Button("Reset pairing", role: .destructive) {
                        Keychain.delete(.apiToken); Keychain.delete(.serverURL); Keychain.delete(.totpSecret)
                        onUnpair()
                    }
                }
                #endif
            }
            .navigationTitle("NesTimer")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await refresh() }
        }
        .task { await autoRefresh() }
        .onChange(of: phase) { _, p in if p == .active { Task { await autoRefresh() } } }
    }

    private var hero: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.15)).frame(width: 84, height: 84)
                Image(systemName: symbol)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(headline)
                .font(.system(.largeTitle, design: .rounded).weight(.bold).monospacedDigit())
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
                .lineLimit(2)
            if let caption {
                Text(caption).font(.headline).foregroundStyle(tint)
            }
            if !detail.isEmpty {
                Text(detail)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var symbol: String {
        switch decision {
        case .none: return "hourglass"
        case .shield(.downtime): return "moon.zzz.fill"
        case .shield(.clockChanged): return "clock.badge.exclamationmark.fill"
        case .shield(.agentError): return "exclamationmark.triangle.fill"
        case .shield: return "lock.fill"
        case .open(_, .activity): return "figure.run"
        case .open(_, .temporaryUnlock): return "lock.open.fill"
        case .open(_, .bonus): return "gift.fill"
        case .open(nil, _): return "infinity"
        case .open: return "hourglass"
        }
    }

    private var tint: Color {
        switch decision {
        case .none: return .secondary
        case .shield(.downtime): return .indigo
        case .shield(.clockChanged), .shield(.agentError): return .orange
        case .shield: return .red
        case .open(_, .activity), .open(_, .temporaryUnlock), .open(_, .bonus): return .blue
        case .open(let r?, _) where r <= 15: return .orange
        case .open: return .green
        }
    }

    /// Small line under the big time ("left today").
    private var caption: String? {
        if case .open(_?, _) = decision { return "left today" }
        return nil
    }

    private var headline: String {
        switch decision {
        case .none: return "Checking…"
        case .shield(.downtime): return "Downtime"
        case .shield(.deviceCapReached): return "Limit reached"
        case .shield(.timeExpired): return "Time's up"
        case .shield(.clockChanged): return "Clock changed"
        case .shield(.agentError): return "Needs attention"
        case .open(let r, _):
            guard let r else { return "No limit today" }
            let m = Int(r)
            return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
        }
    }

    private var detail: String {
        switch decision {
        case .open(_, .activity(let endsAt)): return "Scheduled activity until \(endsAt)"
        case .open(_, .temporaryUnlock): return "Unlocked with a code for 5 minutes"
        case .open(_, .bonus): return "Bonus time from your parent"
        case .open: return "Phone and Messages always work."
        case .shield(.clockChanged): return "Turn on Settings \u{2192} General \u{2192} Date & Time \u{2192} Set Automatically. Phone and Messages still work."
        case .shield(.agentError): return "Screen Time monitoring couldn't start. Ask your parent to check the app. Phone and Messages still work."
        case .shield(.downtime(let until)): return "Until \(until). Phone and Messages still work."
        case .shield(.deviceCapReached): return "This iPhone's daily limit is used up. Phone and Messages still work."
        case .shield: return "Today's screen time is used up. Phone and Messages still work."
        case .none: return ""
        }
    }

    /// Opening the app fires both `.task` and the scene-phase change (and the phase can
    /// flicker); one refresh is enough. Manual refreshes always run.
    private func autoRefresh() async {
        if refreshing { return }
        if let lastSync, Date().timeIntervalSince(lastSync) < 3 { return }
        await refresh()
    }

    private func refresh() async {
        refreshing = true
        defer { refreshing = false }
        let started = Date()
        decision = await Engine.make().onForeground()
        DebugLog.write("app refresh → \(String(describing: decision))")
        lastSync = Date()
        let took = Date().timeIntervalSince(started)
        if took > 3 { DebugLog.write(String(format: "app refresh took %.1fs", took)) }
    }

    private func confirmTimeZone() async {
        let ok = await Engine.make().verifyParentCode(tzCode)
        tzCode = ""
        if ok {
            AppGroup.write(TimeZone.current.identifier, to: AppGroup.homeTimeZoneURL)
            homeTZ = AppGroup.homeTimeZone
            tzMessage = "NesTimer now uses local time."
            await refresh()
        } else {
            tzMessage = "That code didn't work."
        }
    }

    private func submit() async {
        let ok = await Engine.make().submitCode(code)
        code = ""
        codeFocused = false
        codeMessage = ok ? "Unlocked for 5 minutes." : "That code didn't work, or it was already used. A new code comes every 5 minutes."
        await refresh()
    }
}
