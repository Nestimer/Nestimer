import SwiftUI

@MainActor
class AuthViewModel: ObservableObject {
    @Published var isAuthenticated = false
    @Published var user: User?
    @Published var isLoading = false
    @Published var error: String?
    @Published var serverURL: String

    private let api = APIClient.shared

    init() {
        self.serverURL = KeychainHelper.getServerURL()
        if KeychainHelper.getToken() != nil {
            isAuthenticated = true
            Task { await checkAuth() }
        }
    }

    func checkAuth() async {
        guard KeychainHelper.getToken() != nil else {
            isAuthenticated = false
            return
        }
        do {
            user = try await api.me()
            isAuthenticated = true
        } catch {
            isAuthenticated = false
        }
    }

    func login(email: String, password: String) async {
        isLoading = true
        error = nil
        do {
            _ = try await api.login(email: email, password: password)
            user = try await api.me()
            isAuthenticated = true
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func register(name: String, email: String, password: String) async {
        isLoading = true
        error = nil
        do {
            _ = try await api.register(name: name, email: email, password: password)
            user = try await api.me()
            isAuthenticated = true
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func logout() {
        Task { await api.logout() }
        isAuthenticated = false
        user = nil
    }

    func saveServerURL() {
        KeychainHelper.saveServerURL(serverURL)
    }
}
