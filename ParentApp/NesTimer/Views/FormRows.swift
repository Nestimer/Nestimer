import SwiftUI

// Row helpers shared by ChildDetailView and DeviceDetailView. These were private members
// of DeviceDetailView until the child-level sections moved out; both screens need them.

func toggleRow(
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

func timePickerRow(
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

func minutesPickerRow(
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

func infoRow(label: String, value: String) -> some View {
    HStack {
        Text(label)
            .foregroundStyle(.secondary)
        Spacer()
        Text(value)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
}

/// "2h 4m" / "45m". Lives here rather than on a view so ChildrenListView and
/// ChildDetailView can both use it without depending on each other.
func durationText(_ minutes: Double) -> String {
    let total = Int(minutes.rounded())
    return total < 60 ? "\(total)m" : "\(total / 60)h \(total % 60)m"
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
