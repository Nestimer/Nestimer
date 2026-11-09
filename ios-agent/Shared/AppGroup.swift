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
    static var homeTimeZoneURL: URL { container.appendingPathComponent("home-timezone.json") }

    /// The time zone recorded at pairing. Day boundaries, downtime and activities follow it,
    /// so switching the phone's time zone can't start a new day early.
    static var homeTimeZone: TimeZone {
        read(String.self, from: homeTimeZoneURL).flatMap(TimeZone.init(identifier:)) ?? .current
    }

    static var homeCalendar: Calendar {
        var c = Calendar.current
        if let id = read(String.self, from: homeTimeZoneURL), let tz = TimeZone(identifier: id) { c.timeZone = tz }
        return c
    }

    static func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}


/// A small rolling debug log in the App Group (who: app or extension). Readable from the
/// app's Debug section; no secrets are written here.
enum DebugLog {
    static var url: URL { AppGroup.container.appendingPathComponent("debug.log") }

    static func write(_ line: String) {
        let who = Bundle.main.bundleIdentifier?.components(separatedBy: ".").last ?? "?"
        let entry = "\(ISO8601DateFormatter().string(from: Date())) [\(who)] \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(entry.utf8)); try? h.close()
        } else {
            try? Data(entry.utf8).write(to: url)
        }
    }

    static func read() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
}
