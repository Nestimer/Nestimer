import SwiftUI

struct AddDeviceView: View {
    @ObservedObject var vm: DevicesViewModel

    /// The existing child to attach the new device to — the path used from
    /// ChildDetailView, where the child is already chosen. id and name are bundled into
    /// one type, rather than two independent optional parameters, because the API
    /// requires a non-empty `child_name` even when `child_id` is set (it uses the
    /// child's own name server-side and ignores this value, but still rejects a blank
    /// one) — "id set, name missing" would otherwise compile and 422 at the moment a
    /// parent tries to register their child's Mac. This type makes that unrepresentable.
    struct AttachTarget {
        let id: String
        let name: String
    }
    var attachTo: AttachTarget? = nil
    /// Fired the moment the device is created (while the success/token screen is showing),
    /// so the caller can refresh without waiting for the sheet to be dismissed.
    var onCreated: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var deviceName = ""
    @State private var childName = ""
    @State private var createdDevice: Device?
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var didCopy = false

    /// What the agent's setup dialog parses: "server|token", split on the single "|".
    /// The bare token alone is rejected there, so showing only the token — as this
    /// screen used to — left the parent with something that could not be pasted.
    private func setupString(token: String) -> String {
        let server = KeychainHelper.getServerURL().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(server)|\(token)"
    }

    private let agentDownloadURL = "https://nestimer.com/download/NesTimer.dmg"

    private func copyToPasteboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    private var isChildLocked: Bool { attachTo != nil }

    var body: some View {
        NavigationStack {
            Form {
                if let device = createdDevice {
                    // Success state — the one line the agent asks for.
                    Section {
                        Label("Device created!", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.headline)

                        if let token = device.apiToken {
                            Text("Paste this single line when the agent asks for the setup string:")
                                .font(.callout)

                            Text(setupString(token: token))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(8)

                            Button {
                                copyToPasteboard(setupString(token: token))
                                didCopy = true
                            } label: {
                                Label(didCopy ? "Copied" : "Copy Setup String",
                                      systemImage: didCopy ? "checkmark" : "doc.on.doc")
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Text("The server did not return a setup token. Open the device and use Regenerate Token to get one.")
                                .font(.callout)
                                .foregroundStyle(.red)
                        }
                    }

                    Section {
                        Link(destination: URL(string: agentDownloadURL)!) {
                            Label("Download NesTimer for Mac", systemImage: "arrow.down.circle")
                        }

                        Text("""
                        1. Download the app on the child's Mac and drag it to Applications.
                        2. Open it — it asks for the setup string. Paste the line above.
                        3. Enter that Mac's admin password once, so the agent installs \
                        itself as a protected service.
                        """)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    } header: {
                        Text("Install the agent")
                    }
                } else {
                    // Creation form
                    Section {
                        // On macOS a TextField's first argument is the *label*, shown
                        // beside the field — not a placeholder. Passing the example name
                        // there printed "Alex's MacBook" as a caption next to an empty
                        // box. The example belongs in `prompt`, which is the placeholder
                        // on both platforms.
                        TextField("Mac name", text: $deviceName, prompt: Text("Alex's MacBook"))

                        if !isChildLocked {
                            TextField("Child's name", text: $childName, prompt: Text("Alex"))
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
            .formStyle(.grouped)
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
                                if let attachTo {
                                    do {
                                        let device = try await APIClient.shared.createDevice(
                                            name: deviceName,
                                            childName: attachTo.name,
                                            childId: attachTo.id
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
        .frame(width: 460, height: createdDevice == nil ? 260 : 520)
        #endif
    }
}
