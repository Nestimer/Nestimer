import SwiftUI

struct AddDeviceView: View {
    @ObservedObject var vm: DevicesViewModel

    /// When set, this sheet attaches the new device to an EXISTING child instead of
    /// creating one from a typed name — the path used from ChildDetailView, where the
    /// child is already chosen. `lockedChildName` is the child's real name; the API still
    /// requires a non-empty `child_name` even when `child_id` is set (it uses the child's
    /// own name server-side and ignores this value), so it must not be blank.
    var childId: String? = nil
    var lockedChildName: String? = nil
    /// Fired the moment the device is created (while the success/token screen is showing),
    /// so the caller can refresh without waiting for the sheet to be dismissed.
    var onCreated: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var deviceName = ""
    @State private var childName = ""
    @State private var createdDevice: Device?
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var isChildLocked: Bool { childId != nil }

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
                        TextField("Alex's MacBook", text: $deviceName)

                        if !isChildLocked {
                            TextField("Alex", text: $childName)
                        }
                    } header: {
                        Text("New Device")
                    } footer: {
                        Text(isChildLocked
                             ? "Enter the Mac's name"
                             : "Enter the Mac name and child's name")
                    }

                    if let errorMessage {
                        Section {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
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
                                errorMessage = nil
                                if let childId {
                                    do {
                                        let device = try await APIClient.shared.createDevice(
                                            name: deviceName,
                                            childName: lockedChildName ?? "",
                                            childId: childId
                                        )
                                        createdDevice = device
                                        onCreated?()
                                    } catch {
                                        errorMessage = error.localizedDescription
                                    }
                                } else {
                                    createdDevice = await vm.createDevice(name: deviceName, childName: childName)
                                }
                                isCreating = false
                            }
                        } label: {
                            if isCreating {
                                ProgressView()
                            } else {
                                Text("Create")
                            }
                        }
                        .disabled(deviceName.isEmpty || (!isChildLocked && childName.isEmpty) || isCreating)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 450, height: 400)
        #endif
    }
}
