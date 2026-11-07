import CryptoKit
import Foundation

/// Signs what this Mac asks the phone to change: `…&auth=<ts>.<hmac-sha256(key, "ts|path")>`,
/// keyed with `CLIP_KEY`. The phone (`RequestAuth.kt`) takes a signature once, within two minutes;
/// without it anyone on a shared Wi-Fi could stop the hotspot or dial `*123#`.
enum PhoneAuth {
    static func sign(_ path: String, key: SymmetricKey?, now: Date = Date()) -> String {
        guard let key else { return path }
        let ts = Int(now.timeIntervalSince1970)
        let code = HMAC<SHA256>.authenticationCode(for: Data("\(ts)|\(path)".utf8), using: key)
        let hex = code.map { String(format: "%02x", $0) }.joined()
        return path + (path.contains("?") ? "&" : "?") + "auth=\(ts).\(hex)"
    }
}
