import Foundation

/// Passwords of the Wi-Fi networks macOS will not hand to `networksetup`, typed once in the
/// menu. macOS's own menu joins such a network, but `networksetup` gets "Missing password",
/// and storing it with `-addpreferredwirelessnetworkatindex` does not change that (measured
/// 2026-11-06). Its own file, owner-only: a password can hold anything `config.env` trims.
enum WifiPasswords {
    static let file = Config.directory.appendingPathComponent("wifi-passwords.json")

    static func password(for ssid: String, in url: URL = file) -> String? {
        all(in: url)[ssid]
    }

    static func store(_ password: String, for ssid: String, in url: URL = file) {
        var passwords = all(in: url)
        passwords[ssid] = password
        guard let data = try? JSONSerialization.data(withJSONObject: passwords) else { return }
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    private static func all(in url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String] ?? [:]
    }
}
