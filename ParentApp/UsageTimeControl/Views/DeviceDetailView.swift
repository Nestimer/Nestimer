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
                ProgressView("Загрузка...")
            } else if let policy = vm.policy {
                ScrollView {
                    VStack(spacing: 20) {
                        todayCard
                        downtimeSection(policy: policy)
                        screenTimeSection(policy: policy)
                        usageHistorySection
                        deviceInfoSection
                    }
                    .padding()
                }
            } else if let error = vm.error {
                ContentUnavailableView {
                    Label("Ошибка", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            }
        }
        .navigationTitle(vm.device?.name ?? "Устройство")
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
                Text("Сегодня")
                    .font(.headline)
                Spacer()
                if let device = vm.device {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(device.isOnline ? Color.green : Color.gray.opacity(0.3))
                            .frame(width: 8, height: 8)
                        Text(device.isOnline ? "Онлайн" : "Офлайн")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Text(formatMinutes(Int(vm.usedToday)))
                    .font(.system(size: 40, weight: .bold, design: .rounded))

                Text("из \(formatMinutes(vm.limitMinutes))")
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

    // MARK: - Downtime

    private func downtimeSection(policy: Policy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Время отдыха")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(spacing: 0) {
                toggleRow(
                    title: "Даунтайм",
                    subtitle: "Компьютер заблокирован в это время",
                    icon: "moon.fill",
                    iconColor: .indigo,
                    isOn: policy.downtimeEnabled
                ) { newValue in
                    Task { await vm.setDowntimeEnabled(newValue) }
                }

                if policy.downtimeEnabled {
                    Divider().padding(.leading, 44)

                    timePickerRow(
                        label: "Начало",
                        time: policy.downtimeStart
                    ) { newTime in
                        Task { await vm.setDowntimeStart(newTime) }
                    }

                    Divider().padding(.leading, 44)

                    timePickerRow(
                        label: "Конец",
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
            Text("Экранное время")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(spacing: 0) {
                toggleRow(
                    title: "Лимит времени",
                    subtitle: "Максимум за день вне даунтайма",
                    icon: "hourglass",
                    iconColor: .blue,
                    isOn: policy.screenTimeEnabled
                ) { newValue in
                    Task { await vm.setScreenTimeEnabled(newValue) }
                }

                if policy.screenTimeEnabled {
                    Divider().padding(.leading, 44)

                    minutesPickerRow(
                        label: "Будни",
                        minutes: policy.screenTimeLimitMinutes
                    ) { newMin in
                        Task { await vm.setScreenTimeLimit(newMin) }
                    }

                    Divider().padding(.leading, 44)

                    minutesPickerRow(
                        label: "Выходные",
                        minutes: policy.screenTimeWeekendLimitMinutes ?? policy.screenTimeLimitMinutes,
                        placeholder: "Как в будни"
                    ) { newMin in
                        Task { await vm.setWeekendLimit(newMin) }
                    }
                }
            }
            .background(.regularMaterial)
            .cornerRadius(16)
        }
    }

    // MARK: - Usage history

    private var usageHistorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("За неделю")
                .font(.title2)
                .fontWeight(.semibold)

            if vm.usage.isEmpty {
                Text("Нет данных")
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
            Text("Устройство")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(spacing: 0) {
                if let device = vm.device {
                    infoRow(label: "Имя", value: device.name)
                    Divider().padding(.leading, 16)
                    infoRow(label: "Ребёнок", value: device.childName)
                    Divider().padding(.leading, 16)
                    infoRow(label: "Последняя связь", value: device.lastSeenText)

                    if let token = device.apiToken {
                        Divider().padding(.leading, 16)
                        HStack {
                            Text("API токен")
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
                                Label("Копировать", systemImage: "doc.on.doc")
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
