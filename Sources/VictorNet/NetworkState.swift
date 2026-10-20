import CoreWLAN
import Foundation

/// Which way this Mac reaches the internet right now, and how well — the one
/// question the menu bar icon answers (2026-10-20, Victor: replaces the system
/// Wi-Fi item, which he takes out of the menu bar).
///
/// | on…              | icon                                   |
/// |------------------|----------------------------------------|
/// | a cable          | dashed ⇄                               |
/// | the phone's hotspot | the phone's cellular bars (the phone says, every 5 s) — plus a Wi-Fi glyph **only when the Mac↔phone Wi-Fi is weak**: the phone is usually next to the laptop, and a second icon that always says "fine" is clutter |
/// | any other Wi-Fi  | Wi-Fi with its strength                |
/// | nothing          | Wi-Fi slashed                          |
enum NetworkLook: Equatable {
    case wired
    /// `level` 0…4 from the phone; nil = no fresh word from it. `weakWifi`
    /// carries the Mac↔phone Wi-Fi strength (0…1) when it is worth showing.
    case hotspot(level: Int?, weakWifi: Double?, alert: RoamingAlert? = nil)
    case wifi(strength: Double)
    case offline
}

/// The badge next to the phone's bars (Victor, 2026-10-20): the GB stay in the
/// menu; the menu bar only says whether to worry.
enum RoamingAlert: Equatable {
    /// Under `RoamingAlertPolicy.lowBytes` left, while roaming.
    case low
    /// Nothing left, or under the phone's reserve so it refuses the hotspot.
    case capped
}

enum RoamingAlertPolicy {
    static let lowBytes: Int64 = 5_000_000_000

    /// Only while the phone says it roams *now*, on a reading young enough to
    /// trust: at home the same numbers cost nothing.
    static func alert(_ r: RoamingWarningPolicy.Reading?, left: Int64, now: Date) -> RoamingAlert? {
        guard let r, r.roamingNow, now.timeIntervalSince(r.readAt) < RoamingMeterPolicy.freshFor else { return nil }
        if left <= 0 || r.hotspotBlocked { return .capped }
        return left < lowBytes ? .low : nil
    }
}

enum NetworkLookPolicy {
    /// Below this the Mac↔phone link itself is the bottleneck: the phone has
    /// been left in another room, or in a bag across the hall.
    static let weakHotspotRSSI = -70

    static func look(wired: WiredLinkState, ssid: String?, rssi: Int?, hotspotSSID: String,
                     phoneLevel: Int?) -> NetworkLook {
        if case .connected = wired { return .wired }
        guard let rssi, rssi != 0 else { return .offline }
        if let ssid, !hotspotSSID.isEmpty, ssid == hotspotSSID {
            return .hotspot(level: phoneLevel, weakWifi: rssi < weakHotspotRSSI ? strength(rssi: rssi) : nil, alert: nil)
        }
        return .wifi(strength: strength(rssi: rssi))
    }

    /// RSSI → the 0…1 of an SF Symbol's variable value: −50 dBm and better is
    /// full, −90 empty; the system item's three arcs land about where its own do.
    static func strength(rssi: Int) -> Double {
        max(0, min(1, Double(rssi + 90) / 40))
    }

    static func wifiRow(ssid: String?, rssi: Int?) -> String {
        guard let rssi, rssi != 0 else { return "🛜 Wi-Fi: not connected" }
        let name = ssid ?? "connected (allow Location to see its name)"
        return "🛜 Wi-Fi: \(name) · \(rssi) dBm"
    }

    static func phoneRow(_ s: PhoneSignal?, onHotspot: Bool) -> String {
        guard onHotspot else { return "📱 Phone: not on its hotspot" }
        guard let s else { return "📱 Phone: on its hotspot, no signal report (is the phone app up to date?)" }
        var parts = ["\(s.level)/4"]
        if let n = s.network { parts.insert(n, at: 0) }
        if let d = s.dbm { parts.append("\(d) dBm") }
        if let o = s.operatorName, !o.isEmpty { parts.append(o) }
        return "📱 Phone: " + parts.joined(separator: " · ")
    }
}

/// The live reads behind the policy.
final class NetworkState {
    static let unnamedKey = "wifi:?"
    private(set) var wired: WiredLinkState = .disconnected
    private(set) var ssid: String?
    private(set) var rssi: Int?
    var phoneSignal: PhoneSignal?

    var onHotspot: Bool {
        guard let ssid, !Config.hotspotSSID.isEmpty else { return false }
        return ssid == Config.hotspotSSID && rssi != nil
    }

    var look: NetworkLook {
        NetworkLookPolicy.look(wired: wired, ssid: ssid, rssi: rssi, hotspotSSID: Config.hotspotSSID,
                               phoneLevel: phoneSignal?.level)
    }

    /// For `TrafficMonitor` and the book: the wire wins, as it does for routing.
    var network: NetworkID? {
        if case .connected = wired { return NetworkID(key: "wired", name: "🔌 Ethernet", kind: "wired") }
        guard rssi != nil else { return nil }
        guard let name = ssid else { return NetworkID(key: Self.unnamedKey, name: "🛜 Wi-Fi", kind: "wifi") }
        if onHotspot { return NetworkID(key: "wifi:\(name)", name: "📱 \(name)", kind: "hotspot") }
        return NetworkID(key: "wifi:\(name)", name: "🛜 \(name)", kind: "wifi")
    }

    /// Cheap: CoreWLAN's cached values and one dynamic-store read.
    func refresh() {
        wired = WiredLink.current()
        let iface = CWWiFiClient.shared().interface(withName: Config.wifiInterface)
        // `rssiValue` is 0 while not associated; `ssid` is nil without
        // Location Services even while associated.
        let r = iface?.rssiValue() ?? 0
        rssi = r == 0 ? nil : r
        ssid = rssi == nil ? nil : iface?.ssid()
    }

    var stateJSON: [String: Any] {
        let lookName: String
        switch look {
        case .wired: lookName = "wired"
        case .hotspot(let l, let w, let a):
            lookName = "hotspot(level:\(l.map(String.init) ?? "?"),weakWifi:\(w != nil),alert:\(a.map { "\($0)" } ?? "none"))"
        case .wifi(let s): lookName = String(format: "wifi(%.2f)", s)
        case .offline: lookName = "offline"
        }
        return ["look": lookName, "ssid": orNull(ssid), "rssi": orNull(rssi),
                "wired": WiredLinkPolicy.title(wired), "on_hotspot": onHotspot]
    }
}
