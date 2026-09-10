import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct DeviceDetailView: View {
    let deviceId: String
    @StateObject private var vm: DeviceDetailViewModel
    @State private var showEditName = false
    @State private var capMinutes: Int?
    /// The cap value we last told the server about (either via a seed from .task/.refreshable
    /// or a dispatched PATCH). onChange compares against this, not against vm.device, because
    /// vm.device is stale while a PATCH is in flight -- comparing against it would let a
    /// revert typed during that window be silently swallowed as a no-op.
    @State private var lastSentCap: Int?
    /// The child the picker's confirmation dialog is asking about -- set as soon as a new
    /// selection is tapped, cleared on confirm or cancel. Nothing is sent to the server until
    /// the parent confirms; on cancel the Picker's binding just re-reads vm.device?.childId,
    /// which hasn't changed, so it reverts on its own.
    @State private var pendingChildId: String?
    @State private var showMoveConfirmation = false

    init(deviceId: String) {
        self.deviceId = deviceId
        _vm = StateObject(wrappedValue: DeviceDetailViewModel(deviceId: deviceId))
    }

    var body: some View {
        Group {
            if vm.policy != nil {
                ScrollView {
                    VStack(spacing: 20) {
                        todayCard
                        unlockCodeSection
                        usageHistorySection
                        deviceInfoSection
                    }
                    .padding()
                }
            } else if let error = vm.error {
                ContentUnavailableView {
                    Label("Error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                    Button("Retry") { Task { await vm.load() } }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 8)
                }
            } else {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 600)
        #endif
        .navigationTitle(vm.device?.name ?? "Device")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .refreshable {
            await vm.load()
            capMinutes = vm.device?.dailyCapMinutes
            lastSentCap = capMinutes
        }
        .task {
            await vm.load()
            capMinutes = vm.device?.dailyCapMinutes
            lastSentCap = capMinutes
        }
        .sheet(isPresented: $showEditName) {
            EditDeviceNameView(vm: vm)
        }
        .confirmationDialog(
            "Move device?",
            isPresented: $showMoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move", role: .destructive) {
                if let pendingChildId {
                    Task { await vm.moveToChild(pendingChildId) }
                }
                pendingChildId = nil
            }
            Button("Cancel", role: .cancel) {
                pendingChildId = nil
            }
        } message: {
            if let pendingChildId,
               let target = vm.allChildren.first(where: { $0.id == pendingChildId }) {
                Text("Moving this device merges it onto \(target.name)'s shared daily limit and usage.")
            }
        }
    }

    // MARK: - Today's usage card

    private var todayCard: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Today")
                    .font(.headline)
                Spacer()
                if let device = vm.device {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(device.isOnline ? Color.green : Color.gray.opacity(0.3))
                            .frame(width: 8, height: 8)
                        Text(device.isOnline ? "Online" : "Offline")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Text(formatMinutes(Int(vm.usedToday)))
                    .font(.system(size: 40, weight: .bold, design: .rounded))

                Text("of \(formatMinutes(vm.limitMinutes))")
                    .foregroundStyle(.secondary)

                Spacer()
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(0.15))

                    RoundedRectangle(cornerRadius: 6)
                        .fill(progressColor)
                        .frame(width: geo.size.width * vm.usagePercent)
                        .animation(.spring, value: vm.usagePercent)
                }
            }
            .frame(height: 12)
        }
        .padding()
        .background(.regularMaterial)
        .cornerRadius(16)
    }

    private var progressColor: Color {
        if vm.usagePercent > 0.9 { return .red }
        if vm.usagePercent > 0.7 { return .orange }
        return .green
    }

    // MARK: - Unlock code (TOTP)

    private var unlockCodeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Unlock Code")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(spacing: 16) {
                Text("Tell this code to your child — unlocks for 5 minutes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let code = vm.currentTOTPCode {
                    Button {
                        #if os(iOS)
                        UIPasteboard.general.string = code
                        #elseif os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        #endif
                    } label: {
                        Text(code)
                            .font(.system(size: 48, weight: .bold, design: .monospaced))
                            .tracking(8)
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .help("Click to copy")

                    let remaining = vm.totpSecondsRemaining
                    let minutes = remaining / 60
                    let seconds = remaining % 60
                    Text("Valid for \(minutes):\(String(format: "%02d", seconds))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.blue.opacity(0.15))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.blue)
                                .frame(width: geo.size.width * CGFloat(remaining) / 300.0)
                        }
                    }
                    .frame(height: 4)
                } else {
                    Text("Secret not configured")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding()
            .background(.regularMaterial)
            .cornerRadius(16)
        }
        .onAppear { vm.startTOTPGeneration() }
        .onDisappear { vm.stopTOTPGeneration() }
    }

    // MARK: - Usage history

    private var usageHistorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This Week")
                .font(.title2)
                .fontWeight(.semibold)

            if vm.usage.isEmpty {
                Text("No data")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.regularMaterial)
                    .cornerRadius(16)
            } else {
                UsageChartView(usage: vm.usage, limitMinutes: vm.limitMinutes)
                    .padding()
                    .background(.regularMaterial)
                    .cornerRadius(16)
            }
        }
    }

    // MARK: - Device info

    private var deviceInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Device")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(spacing: 0) {
                if let device = vm.device {
                    HStack {
                        Text("Name")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(device.name)
                        Button {
                            showEditName = true
                        } label: {
                            Image(systemName: "pencil")
                                .font(.callout)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    Divider().padding(.leading, 16)
                    if vm.allChildren.isEmpty {
                        // Couldn't load the children list -- fall back to a plain, read-only
                        // row rather than blocking the rest of the device screen.
                        infoRow(label: "Child", value: device.childName)
                    } else {
                        // A device backfilled lazily server-side (or whose child was deleted)
                        // can have a childId that's nil or absent from allChildren. A menu
                        // Picker can't represent "no selection" -- it renders the first row as
                        // checked -- so without this, tapping that apparently-selected row would
                        // silently move the device onto a child the parent never chose. Make
                        // the "unknown child" state an explicit, disabled placeholder instead.
                        let hasKnownChild = device.childId.map { id in
                            vm.allChildren.contains { $0.id == id }
                        } ?? false
                        HStack {
                            Text("Child")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("Child", selection: Binding(
                                get: { hasKnownChild ? device.childId! : "" },
                                set: { newId in
                                    pendingChildId = newId
                                    showMoveConfirmation = true
                                }
                            )) {
                                if !hasKnownChild {
                                    Text("Not assigned").tag("")
                                }
                                ForEach(vm.allChildren) { child in
                                    Text(child.name).tag(child.id)
                                }
                            }
                            .labelsHidden()
                            .disabled(!hasKnownChild)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        Text("Moving this device merges it onto that child's shared daily limit and usage.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }
                    Divider().padding(.leading, 16)
                    HStack {
                        Text("Daily cap")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("Daily cap", selection: $capMinutes) {
                            Text("None").tag(Optional<Int>.none)
                            ForEach([30, 60, 90, 120, 180, 240], id: \.self) { m in
                                Text(formatMinutes(m)).tag(Optional(m))
                            }
                        }
                        .labelsHidden()
                        .onChange(of: capMinutes) { _, newValue in
                            // .task/.refreshable seed capMinutes from the server (and
                            // lastSentCap along with it), which fires this same onChange --
                            // skip it when the value already matches what we last sent so a
                            // load doesn't echo a no-op PATCH. Comparing against lastSentCap
                            // rather than vm.device?.dailyCapMinutes matters because vm.device
                            // is stale while a PATCH is in flight: a revert typed during that
                            // window (e.g. 60 -> 90 -> 60 before the first PATCH lands) must
                            // still be recognized as a new value to send, not swallowed as a
                            // no-op against the not-yet-updated server value.
                            guard newValue != lastSentCap else { return }
                            lastSentCap = newValue
                            Task { await vm.updateCap(newValue) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    Divider().padding(.leading, 16)
                    infoRow(label: "Last Seen", value: device.lastSeenText)
                    if let version = device.agentVersion {
                        Divider().padding(.leading, 16)
                        infoRow(label: "Agent Version", value: "v\(version)")
                    }

                    if let token = device.apiToken {
                        Divider().padding(.leading, 16)
                        let setupString = "\(KeychainHelper.getServerURL())|\(token)"
                        HStack {
                            Text("Setup String")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                #if os(iOS)
                                UIPasteboard.general.string = setupString
                                #elseif os(macOS)
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(setupString, forType: .string)
                                #endif
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                                    .font(.callout)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }
            }
            .background(.regularMaterial)
            .cornerRadius(16)
        }
    }
}

// MARK: - Edit device name sheet

struct EditDeviceNameView: View {
    @ObservedObject var vm: DeviceDetailViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var childName: String = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Device Name") {
                    TextField("Device name", text: $name)
                }
                Section("Child Name") {
                    TextField("Child name", text: $childName)
                }
            }
            .navigationTitle("Edit Device")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            isSaving = true
                            await vm.updateDeviceName(name: name, childName: childName)
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(name.isEmpty || childName.isEmpty || isSaving)
                }
            }
            .onAppear {
                name = vm.device?.name ?? ""
                childName = vm.device?.childName ?? ""
            }
        }
        #if os(macOS)
        .frame(width: 400, height: 250)
        #endif
    }
}
