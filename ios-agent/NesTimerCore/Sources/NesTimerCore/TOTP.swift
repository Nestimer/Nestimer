import CryptoKit
import Foundation

/// 6-digit codes, HMAC-SHA1, 300 s step. Must match api/app/totp.py,
/// web-dashboard/src/utils/totp.js and macos-agent's TOTPGenerator.swift.
public enum TOTP {
    public static let step: TimeInterval = 300

    public static func code(secretHex: String, counter: UInt64) -> String? {
        guard let key = Data(hex: secretHex), !key.isEmpty else { return nil }
        var be = counter.bigEndian
        let msg = Data(bytes: &be, count: 8)
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: msg, using: SymmetricKey(data: key)))
        let offset = Int(mac[19] & 0x0F)
        let value = (UInt32(mac[offset]) & 0x7F) << 24 | UInt32(mac[offset + 1]) << 16
            | UInt32(mac[offset + 2]) << 8 | UInt32(mac[offset + 3])
        return String(format: "%06d", value % 1_000_000)
    }

    /// The step (counter) the code matches within ± `window` steps of `now`, if any.
    public static func matchingStep(secretHex: String, code: String, now: Date, window: Int = 1) -> Int64? {
        let t = Int64(now.timeIntervalSince1970 / step)
        for offset in -window...window where t + Int64(offset) >= 0 {
            if Self.code(secretHex: secretHex, counter: UInt64(t + Int64(offset))) == code { return t + Int64(offset) }
        }
        return nil
    }

    /// Accepts the current step ± `window` steps.
    public static func verify(secretHex: String, code: String, now: Date, window: Int = 1) -> Bool {
        let t = Int64(now.timeIntervalSince1970 / step)
        for offset in -window...window where t + Int64(offset) >= 0 {
            if let c = Self.code(secretHex: secretHex, counter: UInt64(t + Int64(offset))), c == code { return true }
        }
        return false
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i..<j], radix: 16) else { return nil }
            data.append(byte)
            i = j
        }
        self = data
    }
}
