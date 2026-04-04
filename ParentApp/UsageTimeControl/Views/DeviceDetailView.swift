import SwiftUI

struct DeviceDetailView: View {
    let deviceId: String
    @StateObject private var vm: DeviceDetailViewModel

    init(deviceId: String) {
        self.deviceId = deviceId
        _vm = StateObject(wrappedValue: DeviceDetailViewModel(deviceId: deviceId))
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.device == nil {
                ProgressView("Loading...")
            } else if let policy = vm.policy {
                ScrollView {
                    VStack(spacing: 20) {
                        todayCard
                        unlockCodeSection
                        downtimeSection(policy: policy)
                        screenTimeSection(policy: policy)
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
                }
            }
        }
        .navigationTitle(vm.device?.name ?? "Device")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .refreshable {
            await vm.load()
        }
        .task {
            await vm.load()
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
                Text("Tell this code to your child — unlocks for 30 minutes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let code = vm.currentTOTPCode {
                    Text(code)
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .tracking(8)
                        .frame(maxWidth: .infinity)

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

    // MARK: - Downtime

    private func downtimeSection(policy: Policy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Downtime")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(spacing: 0) {
                toggleRow(
                    title: "Downtime",
                    subtitle: "Computer is locked during this time",
                    icon: "moon.fill",
                    iconColor: .indigo,
                    isOn: policy.downtimeEnabled
                ) { newValue in
                    Task { await vm.setDowntimeEnabled(newValue) }
                }

                if policy.downtimeEnabled {
                    Divider().padding(.leading, 44)

                    timePickerRow(
                        label: "Start",
                        time: policy.downtimeStart
                    ) { newTime in
                        Task { await vm.setDowntimeStart(newTime) }
                    }

                    Divider().padding(.leading, 44)

                    timePickerRow(
                        label: "End",
                        time: policy.downtimeEnd
                    ) { newTime in
                        Task { await vm.setDowntimeEnd(newTime) }
                    }
                }
            }
            .background(.regularMaterial)
            .cornerRadius(16)
        }
    }

    // MARK: - Screen Time

    private func screenTimeSection(policy: Policy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Screen Time")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(spacing: 0) {
                toggleRow(
                    title: "Time Limit",
                    subtitle: "Max per day outside downtime",
                    icon: "hourglass",
                    iconColor: .blue,
                    isOn: policy.screenTimeEnabled
                ) { newValue in
                    Task { await vm.setScreenTimeEnabled(newValue) }
                }

                if policy.screenTimeEnabled {
                    Divider().padding(.leading, 44)

                    minutesPickerRow(
                        label: "Weekdays",
                        minutes: policy.screenTimeLimitMinutes
                    ) { newMin in
                        Task { await vm.setScreenTimeLimit(newMin) }
                    }

                    Divider().padding(.leading, 44)

                    minutesPickerRow(
                        label: "Weekends",
                        minutes: policy.screenTimeWeekendLimitMinutes ?? policy.screenTimeLimitMinutes,
                        placeholder: "Same as weekdays"
                    ) { newMin in
                        Task { await vm.setWeekendLimit(newMin) }
                    }

                    Divider().padding(.leading, 44)
                    perDayPickerRows(policy: policy)
                }
            }
            .background(.regularMaterial)
            .cornerRadius(16)
        }
    }

    // MARK: - Per-day limits

    private func perDayPickerRows(policy: Policy) -> some View {
        let days: [(label: String, index: Int, value: Int?)] = [
            ("Mon", 0, policy.screenTimeMonMinutes),
            ("Tue", 1, policy.screenTimeTueMinutes),
            ("Wed", 2, policy.screenTimeWedMinutes),
            ("Thu", 3, policy.screenTimeThuMinutes),
            ("Fri", 4, policy.screenTimeFriMinutes),
            ("Sat", 5, policy.screenTimeSatMinutes),
            ("Sun", 6, policy.screenTimeSunMinutes),
        ]
        return VStack(spacing: 0) {
            HStack {
                Text("Per day overrides")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 44)
                Spacer()
            }
            .padding(.top, 8)
            .padding(.bottom, 4)
            ForEach(days, id: \.index) { day in
                let fallback = (day.index >= 5 ? policy.screenTimeWeekendLimitMinutes : nil) ?? policy.screenTimeLimitMinutes
                let current = day.value ?? fallback
                HStack {
                    Text(day.label)
                        .foregroundStyle(day.value != nil ? .primary : .secondary)
                        .font(.system(.body, design: .rounded))
                        .frame(width: 40, alignment: .leading)
                        .padding(.leading, 44)
                    Spacer()
                    Stepper(
                        value: Binding(
                            get: { current },
                            set: { newMin in Task { await vm.setDayLimit(day: day.index, minutes: newMin) } }
                        ),
                        in: 15...720,
                        step: 15
                    ) {
                        Text(formatMinutes(current))
                            .font(.system(.body, design: .rounded))
                            .fontWeight(day.value != nil ? .medium : .regular)
                            .foregroundStyle(day.value != nil ? .primary : .secondary)
                            .monospacedDigit()
                    }
                    .padding(.trailing, 16)
                }
                .padding(.vertical, 6)
            }
        }
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
                    infoRow(label: "Name", value: device.name)
                    Divider().padding(.leading, 16)
                    infoRow(label: "Child", value: device.childName)
                    Divider().padding(.leading, 16)
                    infoRow(label: "Last Seen", value: device.lastSeenText)

                    if let token = device.apiToken {
                        Divider().padding(.leading, 16)
                        HStack {
                            Text("API Token")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                #if os(iOS)
                                UIPasteboard.general.string = token
                                #elseif os(macOS)
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(token, forType: .string)
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

    // MARK: - Reusable rows

    private func toggleRow(
        title: String,
        subtitle: String,
        icon: String,
        iconColor: Color,
        isOn: Bool,
        onChange: @escaping (Bool) -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { isOn },
                set: { onChange($0) }
            ))
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func timePickerRow(
        label: String,
        time: String,
        onChange: @escaping (String) -> Void
    ) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .padding(.leading, 44)

            Spacer()

            TimePickerCompact(time: time, onChange: onChange)
                .padding(.trailing, 16)
        }
        .padding(.vertical, 8)
    }

    private func minutesPickerRow(
        label: String,
        minutes: Int,
        placeholder: String? = nil,
        onChange: @escaping (Int) -> Void
    ) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .padding(.leading, 44)

            Spacer()

            HStack(spacing: 4) {
                Stepper(
                    value: Binding(
                        get: { minutes },
                        set: { onChange($0) }
                    ),
                    in: 15...720,
                    step: 15
                ) {
                    Text(formatMinutes(minutes))
                        .font(.system(.body, design: .rounded))
                        .fontWeight(.medium)
                        .monospacedDigit()
                }
            }
            .padding(.trailing, 16)
        }
        .padding(.vertical, 8)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Time picker helper

struct TimePickerCompact: View {
    let time: String
    let onChange: (String) -> Void

    @State private var date: Date

    init(time: String, onChange: @escaping (String) -> Void) {
        self.time = time
        self.onChange = onChange

        let parts = time.split(separator: ":").compactMap { Int($0) }
        var components = DateComponents()
        components.hour = parts.count > 0 ? parts[0] : 0
        components.minute = parts.count > 1 ? parts[1] : 0
        _date = State(initialValue: Calendar.current.date(from: components) ?? Date())
    }

    var body: some View {
        DatePicker(
            "",
            selection: $date,
            displayedComponents: .hourAndMinute
        )
        .labelsHidden()
        .onChange(of: date) { _, newDate in
            let h = Calendar.current.component(.hour, from: newDate)
            let m = Calendar.current.component(.minute, from: newDate)
            onChange(String(format: "%02d:%02d", h, m))
        }
    }
}
