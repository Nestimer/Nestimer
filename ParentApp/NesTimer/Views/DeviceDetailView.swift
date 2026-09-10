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
        }
        .task {
            await vm.load()
            capMinutes = vm.device?.dailyCapMinutes
        }
        .sheet(isPresented: $showEditName) {
            EditDeviceNameView(vm: vm)
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
                    infoRow(label: "Child", value: device.childName)
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
