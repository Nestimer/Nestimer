import Foundation
import NesTimerCore

/// Files shared by the app and its extensions. Never holds secrets (those are in the Keychain).
enum AppGroup {
    static let id = "group.com.nestimer.child"

    static var container: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)!
    }
    static var stateURL: URL { container.appendingPathComponent("state.json") }
    static var selectionURL: URL { container.appendingPathComponent("selection.json") }
    static var shieldReasonURL: URL { container.appendingPathComponent("shield-reason.json") }

    static func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
