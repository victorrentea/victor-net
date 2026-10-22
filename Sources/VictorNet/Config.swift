import Foundation

/// Everything that belongs to *one* Mac and *one* phone, kept out of this public
/// repository: `~/.victor-net/config.env`, `KEY=value` per line, `#` comments.
///
/// ```
/// PHONE_BT_ADDRESS=a1-b2-c3-d4-e5-f6   # the phone, as System Settings › Bluetooth shows it
/// HOTSPOT_SSID=my-phone                # the phone's hotspot network
/// PREFERRED_SSID=my-home               # optional: on the hotspot with this in range, move to it
/// HOME_COUNTRY=RO                      # ISO code; abroad + on the hotspot = roaming data
/// HOME_TIMEZONE=Europe/Bucharest
/// HOME_LAT=…  HOME_LON=…  HOME_RADIUS_M=150   # optional: no hotspot request at home
/// HOTSPOT_PASSWORD=…                   # optional: only if the keychain lacks it
/// INCLUDE=~/.some-other-secrets.env    # optional: merge another env file under these
/// ```
///
/// Without a phone address the phone features stay off; the network icon, the
/// wired/Wi-Fi rows and the traffic readout work on any Mac.
enum Config {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".victor-net")
    static let file = directory.appendingPathComponent("config.env")

    static let values: [String: String] = load()

    static var phoneBluetoothAddress: String { values["PHONE_BT_ADDRESS"] ?? "" }
    static var hasPhone: Bool { !phoneBluetoothAddress.isEmpty }
    static var hotspotSSID: String { values["HOTSPOT_SSID"] ?? "" }
    static var wifiInterface: String { values["WIFI_INTERFACE"] ?? "en0" }
    static var homeCountry: String { values["HOME_COUNTRY"] ?? Locale.current.region?.identifier ?? "" }
    static var homeTimeZone: String { values["HOME_TIMEZONE"] ?? TimeZone.current.identifier }
    /// The phone app's status port on the hotspot's gateway (`StatusServer.kt`).
    static var phoneStatusPort: UInt16 { UInt16(values["PHONE_STATUS_PORT"] ?? "") ?? 55126 }

    private static func load() -> [String: String] {
        guard let own = parse(file.path) else { return [:] }
        guard let include = own["INCLUDE"] else { return own }
        let path = (include as NSString).expandingTildeInPath
        // Our own keys win over the included file's.
        return (parse(path) ?? [:]).merging(own) { _, mine in mine }
    }

    static func parse(_ path: String) -> [String: String]? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return parse(text: content)
    }

    static func parse(text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: "\n") {
            var stripped = line.trimmingCharacters(in: .whitespaces)
            if let hash = stripped.range(of: " #") { stripped = String(stripped[..<hash.lowerBound]) }
            guard !stripped.hasPrefix("#"), let eq = stripped.firstIndex(of: "=") else { continue }
            let key = stripped[..<eq].trimmingCharacters(in: .whitespaces)
            let value = stripped[stripped.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}
