import SwiftUI

struct ChildDetailView: View {
    let childId: String
    @StateObject private var vm: ChildDetailViewModel
    @State private var showAddActivity = false

    init(childId: String) {
        self.childId = childId
        _vm = StateObject(wrappedValue: ChildDetailViewModel(childId: childId))
    }

    var body: some View {
        Group {
            if vm.child != nil {
                ScrollView {
                    VStack(spacing: 20) {
                        sharedBudgetSection
                        devicesSection

                        if vm.hasNoDevices {
                            ContentUnavailableView {
                                Label("No Devices", systemImage: "desktopcomputer")
                            } description: {
                                Text("Add a device to this child to set limits")
                            }
                            .padding()
                            .background(.regularMaterial)
                            .cornerRadius(16)
                        } else if vm.policy != nil {
                            // Sections 3-5, moved from DeviceDetailView
                            downtimeSection
                            screenTimeSection
                            activitiesSection
                            bonusSection
                        }
                    }
                    .padding()
                }
            } else if let error = vm.errorMessage {
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
        .navigationTitle(vm.child?.name ?? "Child")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .task { await vm.load() }
        .refreshable { await vm.load() }
        .sheet(isPresented: $showAddActivity) {
            AddActivityView(vm: vm)
        }
    }

    // MARK: - Shared budget

    private var sharedBudgetSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Today")
                .font(.title2)
                .fontWeight(.semibold)

            let limit = vm.policy?.screenTimeLimitMinutes
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(durationText(vm.todayMinutes))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    if let limit {
                        Text("of \(durationText(Double(limit)))")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if let limit, limit > 0 {
                    ProgressView(value: min(vm.todayMinutes / Double(limit), 1.0))
                }
                Text("Shared across every device below")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(.regularMaterial)
            .cornerRadius(16)
        }
    }

    // MARK: - Devices

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Devices")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(spacing: 0) {
                ForEach(vm.devices) { device in
                    NavigationLink {
                        DeviceDetailView(deviceId: device.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                    .foregroundStyle(.primary)
                                Text(device.dailyCapMinutes.map { "cap: \(durationText(Double($0)))" }
                                     ?? "cap: none")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Circle()
                                .fill(device.isOnline ? Color.green : Color.gray.opacity(0.3))
                                .frame(width: 8, height: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if device.id != vm.devices.last?.id {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(.regularMaterial)
            .cornerRadius(16)
        }
    }

    // MARK: - Downtime (moved from DeviceDetailView; reads vm.policy directly since this
    // view calls it with no arguments, and save calls now go through vm.updatePolicy(_:)
    // instead of the per-device convenience wrappers DeviceDetailViewModel had)

    private var downtimeSection: some View {
        Group {
            if let policy = vm.policy {
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
                            Task { await vm.updatePolicy(PolicyUpdate(downtimeEnabled: newValue)) }
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
                                Task { await vm.updatePolicy(PolicyUpdate(downtimeStart: newTime)) }
                            }

                            timePickerRow(
                                label: "End",
                                time: policy.downtimeEnd
                            ) { newTime in
                                Task { await vm.updatePolicy(PolicyUpdate(downtimeEnd: newTime)) }
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
                                        Task {
                                            var update = PolicyUpdate()
                                            update.clearFields = [.downtimeWeekdayStart, .downtimeWeekdayEnd]
                                            await vm.updatePolicy(update)
                                        }
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
                                        Task {
                                            var update = PolicyUpdate()
                                            update.clearFields = [.downtimeWeekendStart, .downtimeWeekendEnd]
                                            await vm.updatePolicy(update)
                                        }
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
        }
    }

    // MARK: - Screen Time

    private var screenTimeSection: some View {
        Group {
            if let policy = vm.policy {
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
                            Task { await vm.updatePolicy(PolicyUpdate(screenTimeEnabled: newValue)) }
                        }

                        if policy.screenTimeEnabled {
                            Divider().padding(.leading, 44)

                            minutesPickerRow(
                                label: "Weekdays",
                                minutes: policy.screenTimeLimitMinutes
                            ) { newMin in
                                Task { await vm.updatePolicy(PolicyUpdate(screenTimeLimitMinutes: newMin)) }
                            }

                            Divider().padding(.leading, 44)

                            HStack(spacing: 0) {
                                minutesPickerRow(
                                    label: "Weekends",
                                    minutes: policy.screenTimeWeekendLimitMinutes ?? policy.screenTimeLimitMinutes,
                                    placeholder: "Same as weekdays"
                                ) { newMin in
                                    Task { await vm.updatePolicy(PolicyUpdate(screenTimeWeekendLimitMinutes: newMin)) }
                                }
                                if policy.screenTimeWeekendLimitMinutes != nil {
                                    Button {
                                        Task {
                                            var update = PolicyUpdate()
                                            update.clearFields = [.screenTimeWeekendLimitMinutes]
                                            await vm.updatePolicy(update)
                                        }
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
                            clearDayLimit(day: day.index)
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
                            set: { newMin in setDayLimit(day: day.index, minutes: newMin) }
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

    /// Not in the brief's verbatim per-day code, but the moved perDayPickerRows body calls
    /// vm.setDayLimit / vm.clearDayLimit, which only exist on DeviceDetailViewModel. Mirrors
    /// those bodies, targeting vm.updatePolicy(_:) since ChildDetailViewModel exposes only
    /// the generic update method.
    private func setDayLimit(day: Int, minutes: Int) {
        var update = PolicyUpdate()
        switch day {
        case 0: update.screenTimeMonMinutes = minutes
        case 1: update.screenTimeTueMinutes = minutes
        case 2: update.screenTimeWedMinutes = minutes
        case 3: update.screenTimeThuMinutes = minutes
        case 4: update.screenTimeFriMinutes = minutes
        case 5: update.screenTimeSatMinutes = minutes
        case 6: update.screenTimeSunMinutes = minutes
        default: return
        }
        Task { await vm.updatePolicy(update) }
    }

    private func clearDayLimit(day: Int) {
        var update = PolicyUpdate()
        let key: PolicyUpdate.CodingKeys
        switch day {
        case 0: key = .screenTimeMonMinutes
        case 1: key = .screenTimeTueMinutes
        case 2: key = .screenTimeWedMinutes
        case 3: key = .screenTimeThuMinutes
        case 4: key = .screenTimeFriMinutes
        case 5: key = .screenTimeSatMinutes
        case 6: key = .screenTimeSunMinutes
        default: return
        }
        update.clearFields = [key]
        Task { await vm.updatePolicy(update) }
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
                Task { await vm.deleteActivity(activity.id) }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
        .onAppear { vm.startBonusCountdown() }
        .onDisappear { vm.stopBonusCountdown() }
    }
}

// MARK: - Add activity sheet

struct AddActivityView: View {
    @ObservedObject var vm: ChildDetailViewModel
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
                            await vm.addActivity(ActivityCreate(
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
