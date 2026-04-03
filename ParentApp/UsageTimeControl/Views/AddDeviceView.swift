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
                            Label("Device created!", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.headline)

                            Text("Use this token when installing the agent on the child's Mac:")
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
                                    Label("Copy Token", systemImage: "doc.on.doc")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    Section {
                        Text("Run on the child's Mac:")
                            .font(.callout)

                        Text("sudo ./install.sh")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(8)
                    } header: {
                        Text("Agent Installation")
                    }
                } else {
                    // Creation form
                    Section {
                        TextField("Misha's MacBook", text: $deviceName)

                        TextField("Misha", text: $childName)
                    } header: {
                        Text("New Device")
                    } footer: {
                        Text("Enter the Mac name and child's name")
                    }
                }
            }
            .navigationTitle(createdDevice != nil ? "Done" : "New Device")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
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
                                Text("Create")
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
