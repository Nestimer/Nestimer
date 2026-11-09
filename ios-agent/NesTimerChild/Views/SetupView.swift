import FamilyControls
import NesTimerCore
import SwiftUI

/// Pairing: setup string → TOTP secret → Screen Time authorization → pick what counts and
/// what stays allowed.
struct SetupView: View {
    let onDone: () -> Void

    enum Step { case pair, authorize, pickCounted, pickExempt }
    @State private var step: Step = .pair
    @State private var raw = ""
    @State private var error: String?
    @State private var busy = false
    @State private var selections = Selections.load()
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            Form {
                switch step {
                case .pair: pairSection
                case .authorize: authorizeSection
                case .pickCounted: pickSection(
                    title: "What counts",
                    text: "Tap \u{201C}All Apps & Categories\u{201D} at the top, then Done.",
                    summary: "\(selections.counted.categoryTokens.count) categories selected",
                    ready: !selections.counted.categoryTokens.isEmpty,
                    next: { step = .pickExempt })
                case .pickExempt: pickSection(
                    title: "Always allowed",
                    text: "Find and tick Messages \u{2014} it stays available even when time is up. (Phone is never blocked.)",
                    summary: "\(selections.exempt.applicationTokens.count) apps selected",
                    ready: !selections.exempt.applicationTokens.isEmpty,
                    next: finish)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Set up NesTimer")
            .familyActivityPicker(isPresented: $showPicker,
                                  selection: step == .pickCounted ? $selections.counted : $selections.exempt)
            .onChange(of: selections.counted) { _, _ in selections.save() }
            .onChange(of: selections.exempt) { _, _ in selections.save() }
        }
    }

    private var pairSection: some View {
        Section {
            Text("Ask your parent for the setup string from the NesTimer dashboard.")
            TextField("https://my.nestimer.com|…", text: $raw, axis: .vertical)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.system(.footnote, design: .monospaced))
            Button("Paste") { raw = UIPasteboard.general.string ?? raw }
            Button(busy ? "Connecting…" : "Connect") { Task { await connect() } }
                .disabled(busy || raw.isEmpty)
        }
    }

    private var authorizeSection: some View {
        Section {
            Text("NesTimer needs Screen Time access to count and limit screen time.")
            Text("Also turn off Settings \u{2192} Screen Time \u{2192} Share Across Devices, so time on other devices isn't counted here twice.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Allow Screen Time access") { Task { await authorize() } }
        }
    }

    private func pickSection(title: String, text: String, summary: String, ready: Bool,
                             next: @escaping () -> Void) -> some View {
        Section(title) {
            Text(text)
            Button("Choose…") { showPicker = true }
            Text(summary).foregroundStyle(.secondary)
            Button("Continue", action: next).disabled(!ready)
        }
    }

    private func connect() async {
        error = nil
        guard let s = SetupString.parse(raw) else {
            error = "That doesn't look like a NesTimer setup string."
            return
        }
        busy = true
        defer { busy = false }
        Keychain.set(.serverURL, s.serverURL.absoluteString)
        Keychain.set(.apiToken, s.token)
        do {
            guard let secret = try await AgentClient().fetchTOTPSecret() else {
                error = "The server didn't accept this setup string."
                Keychain.delete(.apiToken)
                return
            }
            Keychain.set(.totpSecret, secret)
            AppGroup.write(TimeZone.current.identifier, to: AppGroup.homeTimeZoneURL)
            step = .authorize
        } catch {
            self.error = "Can't reach the server. Check the internet connection."
            Keychain.delete(.apiToken)
        }
    }

    private func authorize() async {
        do {
            #if DEBUG
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            #else
            try await AuthorizationCenter.shared.requestAuthorization(for: .child)
            #endif
            step = .pickCounted
        } catch {
            self.error = "Screen Time access wasn't granted (\(error.localizedDescription))."
        }
    }

    private func finish() {
        selections.save()
        Task {
            _ = await Engine.make().onForeground()
            onDone()
        }
    }
}
