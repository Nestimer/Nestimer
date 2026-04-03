import SwiftUI

struct AddDeviceView: View {
    @ObservedObject var vm: DevicesViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var deviceName = ""
    @State private var childName = ""
    @State private var createdDevice: Device?
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            Form {
                if let device = createdDevice {
                    // Success state — show token
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Устройство создано!", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.headline)

                            Text("Используйте этот токен при установке агента на Mac ребёнка:")
                                .font(.callout)

                            if let token = device.apiToken {
                                Text(token)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(8)
                                    .background(Color.gray.opacity(0.1))
                                    .cornerRadius(8)

                                Button {
                                    #if os(iOS)
                                    UIPasteboard.general.string = token
                                    #elseif os(macOS)
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(token, forType: .string)
                                    #endif
                                } label: {
                                    Label("Скопировать токен", systemImage: "doc.on.doc")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    Section {
                        Text("Запустите на Mac ребёнка:")
                            .font(.callout)

                        Text("sudo ./install.sh")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(8)
                    } header: {
                        Text("Установка агента")
                    }
                } else {
                    // Creation form
                    Section {
                        TextField("MacBook Миши", text: $deviceName)

                        TextField("Миша", text: $childName)
                    } header: {
                        Text("Новое устройство")
                    } footer: {
                        Text("Введите название Mac и имя ребёнка")
                    }
                }
            }
            .navigationTitle(createdDevice != nil ? "Готово" : "Новое устройство")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }

                if createdDevice == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task {
                                isCreating = true
                                createdDevice = await vm.createDevice(name: deviceName, childName: childName)
                                isCreating = false
                            }
                        } label: {
                            if isCreating {
                                ProgressView()
                            } else {
                                Text("Создать")
                            }
                        }
                        .disabled(deviceName.isEmpty || childName.isEmpty || isCreating)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 450, height: 400)
        #endif
    }
}
