import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct DeviceDetailView: View {
    let deviceId: String
    @StateObject private var vm: DeviceDetailViewModel
    @State private var showAddActivity = false
    @State private var showEditName = false

    init(deviceId: String) {
        self.deviceId = deviceId
        _vm = StateObject(wrappedValue: DeviceDetailViewModel(deviceId: deviceId))
    }

    var body: some View {
        Group {
            if let policy = vm.policy {
                ScrollView {
                    VStack(spacing: 20) {
                        todayCard
                        unlockCodeSection
                        bonusSection
                        downtimeSection(policy: policy)
                        screenTimeSection(policy: policy)
                        activitiesSection
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
        }
        .task {
            await vm.load()
        }
        .sheet(isPresented: $showAddActivity) {
            AddActivityView(vm: vm)
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

    // MARK: - Bonus

    private var bonusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Give Bonus Time")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(spacing: 12) {
                Text("Temporarily unlock without changing the daily limit. The bonus does not count toward used time.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    ForEach([5, 10, 15], id: \.self) { mins in
                        Button {
                            Task { await vm.grantBonus(minutes: mins) }
                        } label: {
                            Text("+\(mins) min")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.isGrantingBonus)
                    }
                }

                if let remaining = vm.bonusRemainingSeconds {
                    let m = remaining / 60
                    let s = remaining % 60
                    HStack {
                        Image(systemName: "clock.badge.checkmark")
                            .foregroundStyle(.green)
                        Text("Bonus active — \(m):\(String(format: "%02d", s)) remaining")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .padding()
            .background(.regularMaterial)
            .cornerRadius(16)
        }
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

                    HStack {
                        Text("Default")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 44)
                        Spacer()
                    }
                    .padding(.top, 4)

                    timePickerRow(
                        label: "Start",
                        time: policy.downtimeStart
                    ) { newTime in
                        Task { await vm.setDowntimeStart(newTime) }
                    }

                    timePickerRow(
                        label: "End",
                        time: policy.downtimeEnd
                    ) { newTime in
                        Task { await vm.setDowntimeEnd(newTime) }
                    }

                    Divider().padding(.leading, 44)

                    HStack {
                        Text("Weekdays (Mon–Fri)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 44)
                        Spacer()
                        if policy.downtimeWeekdayStart != nil || policy.downtimeWeekdayEnd != nil {
                            Button("Reset") {
                                Task { await vm.clearDowntimeWeekdayOverride() }
                            }
                            .font(.caption)
                            .padding(.trailing, 16)
                        }
                    }
                    .padding(.top, 4)

                    timePickerRow(
                        label: "Start",
                        time: policy.downtimeWeekdayStart ?? policy.downtimeStart
                    ) { newTime in
                        Task { await vm.updatePolicy(PolicyUpdate(downtimeWeekdayStart: newTime)) }
                    }

                    timePickerRow(
                        label: "End",
                        time: policy.downtimeWeekdayEnd ?? policy.downtimeEnd
                    ) { newTime in
                        Task { await vm.updatePolicy(PolicyUpdate(downtimeWeekdayEnd: newTime)) }
                    }

                    Divider().padding(.leading, 44)

                    HStack {
                        Text("Weekends (Sat–Sun)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 44)
                        Spacer()
                        if policy.downtimeWeekendStart != nil || policy.downtimeWeekendEnd != nil {
                            Button("Reset") {
                                Task { await vm.clearDowntimeWeekendOverride() }
                            }
                            .font(.caption)
                            .padding(.trailing, 16)
                        }
                    }
                    .padding(.top, 4)

                    timePickerRow(
                        label: "Start",
                        time: policy.downtimeWeekendStart ?? policy.downtimeStart
                    ) { newTime in
                        Task { await vm.updatePolicy(PolicyUpdate(downtimeWeekendStart: newTime)) }
                    }

                    timePickerRow(
                        label: "End",
                        time: policy.downtimeWeekendEnd ?? policy.downtimeEnd
                    ) { newTime in
                        Task { await vm.updatePolicy(PolicyUpdate(downtimeWeekendEnd: newTime)) }
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

                    HStack(spacing: 0) {
                        minutesPickerRow(
                            label: "Weekends",
                            minutes: policy.screenTimeWeekendLimitMinutes ?? policy.screenTimeLimitMinutes,
                            placeholder: "Same as weekdays"
                        ) { newMin in
                            Task { await vm.setWeekendLimit(newMin) }
                        }
                        if policy.screenTimeWeekendLimitMinutes != nil {
                            Button {
                                Task { await vm.clearWeekendLimit() }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 16)
                        }
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
                    if day.value != nil {
                        Button {
                            Task { await vm.clearDayLimit(day: day.index) }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
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

    // MARK: - Scheduled activities

    private var activitiesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Scheduled Activities")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button { showAddActivity = true } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 0) {
                if vm.activities.isEmpty {
                    Text("No activities yet")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding()
                } else {
                    ForEach(vm.activities) { activity in
                        activityRow(activity)
                        if activity.id != vm.activities.last?.id {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
            .background(.regularMaterial)
            .cornerRadius(16)
        }
    }

    private func activityRow(_ activity: Activity) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.name)
                    .font(.body)
                    .foregroundStyle(activity.enabled ? .primary : .secondary)
                Text("\(activity.dayLabel) \(activity.startTime)–\(activity.endTime)  ±\(activity.bufferBeforeMinutes)m")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { activity.enabled },
                set: { _ in Task { await vm.toggleActivity(activity) } }
            ))
            .labelsHidden()
            Button(role: .destructive) {
                Task { await vm.deleteActivity(activity) }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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

// MARK: - Add activity sheet

struct AddActivityView: View {
    @ObservedObject var vm: DeviceDetailViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var dayOfWeek = 0
    @State private var startDate = Calendar.current.date(bySettingHour: 16, minute: 0, second: 0, of: Date())!
    @State private var endDate = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: Date())!
    @State private var bufferBefore = 5
    @State private var bufferAfter = 5
    @State private var isSaving = false

    private let days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("English", text: $name)
                }
                Section("Day") {
                    Picker("Day", selection: $dayOfWeek) {
                        ForEach(0..<7) { i in Text(days[i]).tag(i) }
                    }
                    #if os(iOS)
                    .pickerStyle(.menu)
                    #endif
                }
                Section("Time") {
                    DatePicker("Start", selection: $startDate, displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: $endDate, displayedComponents: .hourAndMinute)
                }
                Section("Buffer (minutes)") {
                    Stepper("Before: \(bufferBefore) min", value: $bufferBefore, in: 0...60)
                    Stepper("After: \(bufferAfter) min", value: $bufferAfter, in: 0...60)
                }
            }
            .navigationTitle("New Activity")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            isSaving = true
                            await vm.createActivity(ActivityCreate(
                                name: name.isEmpty ? "Activity" : name,
                                dayOfWeek: dayOfWeek,
                                startTime: formatTime(startDate),
                                endTime: formatTime(endDate),
                                bufferBeforeMinutes: bufferBefore,
                                bufferAfterMinutes: bufferAfter,
                                enabled: true
                            ))
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(name.isEmpty || isSaving)
                }
            }
        }
        #if os(macOS)
        .frame(width: 450, height: 500)
        #endif
    }

    private func formatTime(_ date: Date) -> String {
        let h = Calendar.current.component(.hour, from: date)
        let m = Calendar.current.component(.minute, from: date)
        return String(format: "%02d:%02d", h, m)
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
