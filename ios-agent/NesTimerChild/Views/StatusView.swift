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
                    VStack(alignment: .leading, spacing: 6) {
                        Text(headline).font(.title2.bold())
                        Text(detail).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    if let lastSync {
                        Text("Updated \(lastSync.formatted(date: .omitted, time: .shortened))")
                            .font(.footnote).foregroundStyle(.secondary)
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
                Section("Have a code from your parent?") {
                    TextField("6-digit code", text: $code)
                        .keyboardType(.numberPad)
                        .font(.system(.title3, design: .monospaced))
                        .focused($codeFocused)
                        .onChange(of: code) { _, v in
                            code = String(v.filter(\.isNumber).prefix(6))
                            if code.count == 6 { Task { await submit() } }
                        }
                    if let codeMessage { Text(codeMessage).font(.footnote) }
                }
                #if DEBUG
                Section("Debug") {
                    Button("Refresh") { Task { await refresh() } }
                    Button("Copy debug log") { UIPasteboard.general.string = DebugLog.read() }
                    Button("Reset pairing", role: .destructive) {
                        Keychain.delete(.apiToken); Keychain.delete(.serverURL); Keychain.delete(.totpSecret)
                        onUnpair()
                    }
                }
                #endif
            }
            .navigationTitle("NesTimer")
            .refreshable { await refresh() }
        }
        .task { await refresh() }
        .onChange(of: phase) { _, p in if p == .active { Task { await refresh() } } }
    }

    private var headline: String {
        switch decision {
        case .none: return "Checking…"
        case .shield(.downtime(let until)): return "Downtime until \(until)"
        case .shield(.deviceCapReached): return "This iPhone's limit is reached"
        case .shield(.timeExpired): return "Time's up for today"
        case .shield(.clockChanged): return "Date & time changed"
        case .shield(.agentError): return "NesTimer needs attention"
        case .open(let r, _):
            guard let r else { return "No limit today" }
            let m = Int(r)
            return m >= 60 ? "\(m / 60) h \(m % 60) m left today" : "\(m) m left today"
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
        case .shield: return "Phone and Messages still work."
        case .none: return ""
        }
    }

    private func refresh() async {
        let started = Date()
        decision = await Engine.make().onForeground()
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
        codeMessage = ok ? "Unlocked for 5 minutes." : "That code didn't work."
        await refresh()
    }
}
