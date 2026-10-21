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
        if case .connected = wired { return NetworkID(key: "wired", name: "Ethernet", kind: "wired") }
        guard rssi != nil else { return nil }
        guard let name = ssid else { return NetworkID(key: Self.unnamedKey, name: "🛜 Wi-Fi", kind: "wifi") }
        if onHotspot { return NetworkID(key: "wifi:\(name)", name: "📱 \(name)", kind: "hotspot") }
        return NetworkID(key: "wifi:\(name)", name: "🛜 \(name)", kind: "wifi")
    }

    /// SSIDs in range, from the **last** scan (`cachedScanResults`, instant). A
    /// fresh scan is asked for in the background when the menu opens, so the next
    /// opening is current; scanning on the spot would block the menu for seconds
    /// and briefly stall the link.
    func reachableSSIDs() -> Set<String> {
        let iface = CWWiFiClient.shared().interface(withName: Config.wifiInterface)
        return Set((iface?.cachedScanResults() ?? []).compactMap { $0.ssid })
    }

    /// Every network in range from the last scan, one per SSID (the strongest),
    /// strongest first — for *Other networks*.
    func scanResults() -> [(ssid: String, rssi: Int, secure: Bool)] {
        let iface = CWWiFiClient.shared().interface(withName: Config.wifiInterface)
        var best: [String: (Int, Bool)] = [:]
        for n in iface?.cachedScanResults() ?? [] {
            guard let ssid = n.ssid, !ssid.isEmpty else { continue }
            let secure = !n.supportsSecurity(.none)
            if best[ssid].map({ n.rssiValue > $0.0 }) ?? true { best[ssid] = (n.rssiValue, secure) }
        }
        return best.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.1 > $1.1 }
    }

    var wifiPower: Bool { CWWiFiClient.shared().interface(withName: Config.wifiInterface)?.powerOn() ?? false }

    /// `networksetup -setairportpower`, which needs no admin, unlike CoreWLAN's `setPower`.
    func setWifiPower(_ on: Bool, done: @escaping (String?) -> Void) {
        run(["-setairportpower", Config.wifiInterface, on ? "on" : "off"], done: done)
    }

    /// The networks this Mac remembers (System Settings › Wi-Fi › Known networks).
    func knownSSIDs() -> Set<String> {
        let iface = CWWiFiClient.shared().interface(withName: Config.wifiInterface)
        return Set((iface?.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []).compactMap { $0.ssid })
    }

    private let scanQueue = DispatchQueue(label: "ro.victorrentea.victor-net.scan", qos: .utility)
    /// A scan is in flight now — the menu's spinner (Victor, 2026-10-21: "prove
    /// me that you're searching").
    private(set) var scanning = false
    /// The last scan that finished: when, how long it took, how many SSIDs it saw.
    private(set) var lastScan: (at: Date, took: TimeInterval, found: Int, error: String?)?
    private(set) var lastScanStarted: Date?
    /// Main thread, when a scan starts and when it ends.
    var onScan: (() -> Void)?

    func scanInBackground() {
        guard !scanning else { return }
        scanning = true
        let began = Date()
        lastScanStarted = began
        onScan?()
        scanQueue.async { [weak self] in
            var found = 0
            var error: String?
            do {
                let seen = try CWWiFiClient.shared().interface(withName: Config.wifiInterface)?.scanForNetworks(withName: nil) ?? []
                found = Set(seen.compactMap { $0.ssid }.filter { !$0.isEmpty }).count
            } catch let e {
                error = e.localizedDescription
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                self.lastScan = (Date(), Date().timeIntervalSince(began), found, error)
                self.onScan?()
            }
        }
    }

    var scanJSON: [String: Any] {
        var o: [String: Any] = ["scanning": scanning]
        if let l = lastScan {
            o["last_scan_ago_s"] = Int(Date().timeIntervalSince(l.at))
            o["last_scan_took_s"] = (l.took * 10).rounded() / 10
            o["last_scan_found"] = l.found
            o["last_scan_error"] = orNull(l.error)
        }
        return o
    }

    /// Joins a network — a known one with the password the keychain already
    /// holds (`password` nil), as the hotspot fallback does — via `networksetup`.
    func join(_ ssid: String, password: String? = nil, done: @escaping (String?) -> Void) {
        run(["-setairportnetwork", Config.wifiInterface, ssid] + (password.map { [$0] } ?? []), done: done)
    }

    private func run(_ args: [String], done: @escaping (String?) -> Void) {
        scanQueue.async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            var failure: String?
            do {
                try p.run()
                p.waitUntilExit()
                let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // networksetup exits 0 even when it fails; it says so in words.
                if p.terminationStatus != 0 || text.localizedCaseInsensitiveContains("error")
                    || text.localizedCaseInsensitiveContains("could not") {
                    failure = text.isEmpty ? "exit \(p.terminationStatus)" : text
                }
            } catch {
                failure = "\(error)"
            }
            DispatchQueue.main.async { done(failure) }
        }
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
                "wired": WiredLinkPolicy.title(wired), "on_hotspot": onHotspot, "scan": scanJSON]
    }
}
