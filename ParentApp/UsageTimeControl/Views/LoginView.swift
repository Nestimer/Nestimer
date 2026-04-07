import SwiftUI

struct LoginView: View {
    @EnvironmentObject var authVM: AuthViewModel

    @State private var isRegister = false
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var showServerSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer().frame(height: 40)

                // Logo area
                VStack(spacing: 8) {
                    Image(systemName: "clock.badge.checkmark")
                        .font(.system(size: 56))
                        .foregroundStyle(.blue)

                    Text("NesTimer")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("Parental controls for macOS")
                        .foregroundStyle(.secondary)
                }

                // Tab picker
                Picker("", selection: $isRegister) {
                    Text("Sign In").tag(false)
                    Text("Sign Up").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                // Form
                VStack(spacing: 16) {
                    if isRegister {
                        TextField("Name", text: $name)
                            .textFieldStyle(.roundedBorder)
                            #if os(iOS)
                            .textContentType(.name)
                            #endif
                    }

                    TextField("Email", text: $email)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        #endif

                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .textContentType(isRegister ? .newPassword : .password)
                        #endif
                }
                .padding(.horizontal)

                if let error = authVM.error {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .padding(.horizontal)
                }

                Button {
                    Task {
                        if isRegister {
                            await authVM.register(name: name, email: email, password: password)
                        } else {
                            await authVM.login(email: email, password: password)
                        }
                    }
                } label: {
                    if authVM.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(isRegister ? "Create Account" : "Sign In")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(authVM.isLoading || email.isEmpty || password.isEmpty)
                .padding(.horizontal)

                // Server URL button
                Button {
                    showServerSettings.toggle()
                } label: {
                    Label("Server Settings", systemImage: "server.rack")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                if showServerSettings {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Server URL")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            TextField("http://localhost:8000", text: $authVM.serverURL)
                                .textFieldStyle(.roundedBorder)
                                #if os(iOS)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                #endif

                            Button("OK") {
                                authVM.saveServerURL()
                                showServerSettings = false
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal)
                }

                Spacer()
            }
        }
        .frame(maxWidth: 400)
        #if os(macOS)
        .frame(minHeight: 500)
        #endif
    }
}
