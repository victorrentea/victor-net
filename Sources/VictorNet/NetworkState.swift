import CoreWLAN
import Foundation

/// What the menu bar icon shows: **the phone's bars, always** (Victor, 2026-11-12). The Wi-Fi
/// is macOS's own icon again; this one says how the phone is doing, on its hotspot or not.
enum NetworkLook: Equatable {
    /// On the phone's hotspot: the data SIM's bars, 0…4, read every 5 s; nil = no fresh word from it.
    case hotspot(level: Int?, alert: RoamingAlert? = nil)
    /// On anything else, or on nothing: the bars of the phone's last answer, drawn faded;
    /// nil = none in the last 15 minutes.
    case away(level: Int?, alert: RoamingAlert? = nil)
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

    /// Why the badge is up, in words (Victor, 2026-11-12: *"I can't tell why"*): the
    /// menu bar's tooltip, and the head of the data SIM's row in the menu.
    static func reason(_ a: RoamingAlert, left: Int64, sim: String?) -> String {
        let on = sim.map { " on \($0)" } ?? ""
        switch a {
        case .low:
            return String(format: "Only %.1f GB of roaming left%@ (warns under %.0f GB)", Double(left) / 1e9, on, Double(lowBytes) / 1e9)
        case .capped:
            return left <= 0 ? "Roaming allowance used up\(on)"
                : String(format: "%.1f GB of roaming left%@, under the phone's reserve: it keeps the hotspot off", Double(left) / 1e9, on)
        }
    }

    /// The emoji that stands in for ✈️ on the data SIM's row while the badge is up.
    static func emoji(_ a: RoamingAlert) -> String { a == .low ? "⚠️" : "❌" }
}

enum NetworkLookPolicy {
    /// Off the hotspot the phone is asked every 10 min over the home Wi-Fi, every 20 over Bluetooth.
    static let awayFreshFor: TimeInterval = 900

    static func look(onHotspot: Bool, live: PhoneSignal?, away: PhoneSignal?, now: Date) -> NetworkLook {
        if onHotspot { return .hotspot(level: live?.level) }
        let last = [live, away].compactMap { $0 }
            .filter { now.timeIntervalSince($0.readAt) < awayFreshFor }
            .max { $0.readAt < $1.readAt }
        return .away(level: last?.level)
    }

    /// RSSI → the 0…1 of an SF Symbol's variable value: −50 dBm and better is
    /// full, −90 empty; the system item's three arcs land about where its own do.
    static func strength(rssi: Int) -> Double {
        max(0, min(1, Double(rssi + 90) / 40))
    }
}

/// The live reads behind the policy.
final class NetworkState {
    static let unnamedKey = "wifi:?"
    private(set) var wired: WiredLinkState = .disconnected
    var ssid: String? { snapshot.ssid }
    var rssi: Int? { snapshot.rssi }
    var phoneSignal: PhoneSignal?
    /// The phone's `/status` off the hotspot: over the home Wi-Fi (`PhoneLan`) or Bluetooth.
    var offHotspotSignal: PhoneSignal?

    /// Everything read from CoreWLAN, as of the last background read.
    ///
    /// **Never on the main thread** (2026-10-21): every CoreWLAN call is an XPC
    /// round trip to `airportd`, and twice that evening `airportd` stopped
    /// answering for minutes (even `networksetup -getairportnetwork` hung). The
    /// menu, the icon and `RoamingDataWatch` all froze behind one `ssid()`. Now
    /// a read happens on `readQueue` and the main thread only ever sees the last
    /// snapshot; a hung read just leaves it stale.
    struct WifiSnapshot {
        var ssid: String?
        var rssi: Int?
        var scan: [(ssid: String, rssi: Int, secure: Bool)] = []
        var at: Date?
    }

    private let lock = NSLock()
    private var _snapshot = WifiSnapshot()
    private var readInFlight = false
    private let readQueue = DispatchQueue(label: "ro.victorrentea.victor-net.wifi-read", qos: .userInitiated)

    var snapshot: WifiSnapshot { lock.lock(); defer { lock.unlock() }; return _snapshot }

    init() {
        // The first read is waited for (1 s at most), so the icon starts right.
        let first = DispatchSemaphore(value: 0)
        readWifi { first.signal() }
        _ = first.wait(timeout: .now() + 1)
    }

    /// Reads CoreWLAN on `readQueue`; skipped while the previous read hangs.
    private func readWifi(done: (() -> Void)? = nil) {
        lock.lock()
        guard !readInFlight else { lock.unlock(); return }
        readInFlight = true
        lock.unlock()
        readQueue.async { [weak self] in
            var s = WifiSnapshot()
            let iface = CWWiFiClient.shared().interface(withName: Config.wifiInterface)
            // `rssiValue` is 0 while not associated; `ssid` is nil without
            // Location Services even while associated.
            let r = iface?.rssiValue() ?? 0
            s.rssi = r == 0 ? nil : r
            s.ssid = s.rssi == nil ? nil : iface?.ssid()
            var best: [String: (Int, Bool)] = [:]
            for n in iface?.cachedScanResults() ?? [] {
                guard let ssid = n.ssid, !ssid.isEmpty else { continue }
                let secure = !n.supportsSecurity(.none)
                if best[ssid].map({ n.rssiValue > $0.0 }) ?? true { best[ssid] = (n.rssiValue, secure) }
            }
            s.scan = best.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.1 > $1.1 }
            s.at = Date()
            guard let self else { return }
            self.lock.lock()
            self._snapshot = s
            self.readInFlight = false
            self.lock.unlock()
            done?()
        }
    }

    var onHotspot: Bool {
        guard let ssid, !Config.hotspotSSID.isEmpty else { return false }
        return ssid == Config.hotspotSSID && rssi != nil
    }

    var look: NetworkLook {
        NetworkLookPolicy.look(onHotspot: onHotspot, live: phoneSignal, away: offHotspotSignal, now: Date())
    }

    /// For `TrafficMonitor` and the book: the wire wins, as it does for routing.
    var network: NetworkID? {
        if case .connected = wired { return NetworkID(key: "wired", name: "Ethernet", kind: "wired") }
        guard rssi != nil else { return nil }
        guard let name = ssid else { return NetworkID(key: Self.unnamedKey, name: "🛜 Wi-Fi", kind: "wifi") }
        if onHotspot { return NetworkID(key: "wifi:\(name)", name: "📱 \(name)", kind: "hotspot") }
        return NetworkID(key: "wifi:\(name)", name: "🛜 \(name)", kind: "wifi")
    }

    /// Every network in range from the last scan, one per SSID (the strongest),
    /// strongest first: is the hotspot up (`StatusMenu`), is home in range (`PreferredWifi`).
    func scanResults() -> [(ssid: String, rssi: Int, secure: Bool)] { snapshot.scan }

    private let scanQueue = DispatchQueue(label: "ro.victorrentea.victor-net.scan", qos: .utility)
    /// A scan is in flight now.
    private(set) var scanning = false
    /// The last scan that finished: when, how long it took, how many SSIDs it saw.
    private(set) var lastScan: (at: Date, took: TimeInterval, found: Int, error: String?)?
    private(set) var lastScanStarted: Date?

    func scanInBackground() {
        guard !scanning else { return }
        scanning = true
        let began = Date()
        lastScanStarted = began
        scanQueue.async { [weak self] in
            var found = 0
            var error: String?
            do {
                // Asked by name too: a hotspot just switched on took ~20 s to show in a
                // plain scan, with the row still saying "Start Hotspot".
                if !Config.hotspotSSID.isEmpty {
                    _ = try? CWWiFiClient.shared().interface(withName: Config.wifiInterface)?
                        .scanForNetworks(withName: Config.hotspotSSID)
                }
                let seen = try CWWiFiClient.shared().interface(withName: Config.wifiInterface)?.scanForNetworks(withName: nil) ?? []
                found = Set(seen.compactMap { $0.ssid }.filter { !$0.isEmpty }).count
            } catch let e {
                error = e.localizedDescription
            }
            self?.readWifi()
            // Through the run loop, not `DispatchQueue.main`: nothing reaches that
            // while a menu tracks, so the scan would stay "running" for as long as it is open.
            RunLoop.main.perform(inModes: [.common]) {
                guard let self else { return }
                self.scanning = false
                self.lastScan = (Date(), Date().timeIntervalSince(began), found, error)
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
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

    /// Joins a network this Mac knows, with the password the keychain holds or the one in
    /// `WifiPasswords` — `PreferredWifi` moving between the hotspot and home — via `networksetup`.
    func join(_ ssid: String, password: String? = nil, done: @escaping (String?) -> Void) {
        let password = password ?? WifiPasswords.password(for: ssid)
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

    /// Never blocks: one dynamic-store read here, the CoreWLAN read started in the
    /// background (its result shows from the next call on).
    func refresh() {
        wired = WiredLink.current()
        readWifi()
    }

    var stateJSON: [String: Any] {
        let lookName: String
        switch look {
        case .hotspot(let l, let a):
            lookName = "hotspot(level:\(l.map(String.init) ?? "?"),alert:\(a.map { "\($0)" } ?? "none"))"
        case .away(let l, _): lookName = "away(level:\(l.map(String.init) ?? "?"))"
        }
        return ["look": lookName, "ssid": orNull(ssid), "rssi": orNull(rssi),
                "wired": WiredLinkPolicy.title(wired), "on_hotspot": onHotspot, "scan": scanJSON,
                "wifi_read_age_s": orNull(snapshot.at.map { Int(Date().timeIntervalSince($0)) })]
    }
}
