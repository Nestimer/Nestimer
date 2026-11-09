import Foundation

/// The `server|token` pairing string from the parent dashboard, as the Mac agent accepts it.
public struct SetupString: Equatable, Sendable {
    public let serverURL: URL
    public let token: String

    public static func parse(_ raw: String) -> SetupString? {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
        guard parts.count == 2 else { return nil }
        var server = parts[0].trimmingCharacters(in: .whitespaces)
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        guard !server.isEmpty, !token.isEmpty else { return nil }
        // Same migration as AgentConfig.migrateServerURL on the Mac.
        if server.contains("134.209.8.62") { server = "https://my.nestimer.com" }
        while server.hasSuffix("/") { server.removeLast() }
        guard let url = URL(string: server), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return SetupString(serverURL: url, token: token)
    }
}
