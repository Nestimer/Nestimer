import Foundation
import CommonCrypto

/// Generates and verifies TOTP-like 6-digit codes with a 5-minute step.
/// Algorithm matches the Python (api/app/totp.py) and JavaScript (web-dashboard/src/utils/totp.js) implementations.
struct TOTPGenerator {
    static let step: UInt64 = 300  // 5 minutes

    /// Generate the current 6-digit code.
    static func generateCode(secretHex: String) -> String? {
        let t = UInt64(Date().timeIntervalSince1970) / step
        return codeForCounter(secretHex: secretHex, counter: t)
    }

    /// Verify a code, accepting current step +/- window (default 1 = 15 min tolerance).
    static func verifyCode(secretHex: String, code: String, window: Int = 1) -> Bool {
        let t = Int64(Date().timeIntervalSince1970) / Int64(step)
        for offset in -window...window {
            if let candidate = codeForCounter(secretHex: secretHex, counter: UInt64(t + Int64(offset))),
               candidate == code {
                return true
            }
        }
        return false
    }

    /// Seconds remaining until the current code expires.
    static var secondsRemaining: Int {
        Int(step) - (Int(Date().timeIntervalSince1970) % Int(step))
    }

    // MARK: - Private

    private static func codeForCounter(secretHex: String, counter: UInt64) -> String? {
        guard let key = Data(hexString: secretHex) else { return nil }
        var bigEndianCounter = counter.bigEndian
        let msg = Data(bytes: &bigEndianCounter, count: 8)

        var hmac = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        key.withUnsafeBytes { keyPtr in
            msg.withUnsafeBytes { msgPtr in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1),
                        keyPtr.baseAddress, key.count,
                        msgPtr.baseAddress, msg.count,
                        &hmac)
            }
        }

        let offset = Int(hmac[19] & 0x0F)
        let code = (UInt32(hmac[offset]) & 0x7F) << 24
                 | UInt32(hmac[offset + 1]) << 16
                 | UInt32(hmac[offset + 2]) << 8
                 | UInt32(hmac[offset + 3])
        let otp = code % 1_000_000
        return String(format: "%06d", otp)
    }
}

// MARK: - Data hex helper

extension Data {
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var index = hexString.startIndex
        for _ in 0..<len {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
