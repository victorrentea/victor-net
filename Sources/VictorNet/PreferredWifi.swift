import CoreWLAN
import Foundation
import Network

/// The menu switch (default on): "Prefer <home Wi-Fi> over <hotspot>".
enum PreferredWifiSettings {
    static let enabledKey = "PreferredWifi.enabled"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}

/// The decision, without a radio.
enum PreferredWifiPolicy {
    /// Weaker than this and the home AP is the edge of its range — walking up to
    /// the building, or the far end of the flat: the hotspot in the pocket is
    /// the better link, and a join there would drop it for nothing.
    static let minRSSI = -75

    /// The preferred network's RSSI when it is time to move to it, else nil.
    static func switchTo(enabled: Bool, preferred: String, hotspot: String, current: String?,
                         scan: [(ssid: String, rssi: Int)], now: Date, backoffUntil: Date) -> Int? {
        guard enabled, !preferred.isEmpty, !hotspot.isEmpty, preferred != hotspot,
              current == hotspot, now >= backoffUntil else { return nil }
        guard let rssi = scan.filter({ $0.ssid == preferred }).map(\.rssi).max(), rssi >= minRSSI else { return nil }
        return rssi
    }
}

/// **On the phone's hotspot while the home Wi-Fi is in range, move to the home
/// Wi-Fi** (Victor, 2026-10-22: *"prefer [home] over [phone]"*). The hotspot is
/// roaming data and ~1 MB/s; at home the Wi-Fi is ~15 MB/s and free.
///
/// macOS will not do it on its own: it stays on a network that works, whatever
/// the preferred list says — and the hotspot sits on top of that list anyway,
/// because macOS promotes the network last joined (see `HotspotFallback`). Seen
/// 22 Oct 2026: the fallback joined the hotspot just outside the home geofence,
/// and the Mac was still on it at home, with the home Wi-Fi in range.
///
/// The SSID is `PREFERRED_SSID` in `~/.victor-net/config.env`: this repo is public.
final class PreferredWifi {
    /// How often the situation is looked at.
    private static let tick: TimeInterval = 30
    /// A scan takes ~5 s and stalls the link while it runs, so while on the
    /// hotspot one is asked for at most this often (the menu's scans count too).
    private static let scanEvery: TimeInterval = 90
    /// Associate + DHCP, with room, before the move is judged.
    private static let settle: TimeInterval = 15
    /// After a join that did not take (out of range by now, wrong password).
    private static let backoffAfterFailedJoin: TimeInterval = 5 * 60
    /// After the home Wi-Fi joined but carried nothing — the router is down;
    /// back to the hotspot, and leave it alone for a while.
    private static let backoffAfterDeadNetwork: TimeInterval = 15 * 60

    private let net: NetworkState
    private let hotspot: HotspotFallback
    private var timer: Timer?
    private var backoffUntil = Date.distantPast
    private var switching = false
    private let queue = DispatchQueue(label: "ro.victorrentea.victor-net.preferred-wifi", qos: .utility)

    private var preferred: String { Config.values["PREFERRED_SSID"] ?? "" }

    init(net: NetworkState, hotspot: HotspotFallback) {
        self.net = net
        self.hotspot = hotspot
    }

    func start() {
        guard !preferred.isEmpty, !Config.hotspotSSID.isEmpty else { return }
        let t = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in self?.evaluate() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        netInfo("🛜 Preferring '\(preferred)' over '\(Config.hotspotSSID)'\(PreferredWifiSettings.isEnabled ? "" : " — switched off in the menu")")
    }

    /// Main thread.
    private func evaluate() {
        guard !switching, PreferredWifiSettings.isEnabled, net.onHotspot else { return }
        let scan = net.scanResults().map { (ssid: $0.ssid, rssi: $0.rssi) }
        guard let rssi = PreferredWifiPolicy.switchTo(
            enabled: true, preferred: preferred, hotspot: Config.hotspotSSID, current: net.ssid,
            scan: scan, now: Date(), backoffUntil: backoffUntil)
        else {
            if Date() >= backoffUntil, Date().timeIntervalSince(net.lastScanStarted ?? .distantPast) >= Self.scanEvery {
                net.scanInBackground()
            }
            return
        }
        move(rssi: rssi)
    }

    private func move(rssi: Int) {
        let from = Config.hotspotSSID, to = preferred
        switching = true
        // The gap between leaving the hotspot and DHCP on the home Wi-Fi is not
        // "offline": the fallback must not answer it by joining the hotspot back.
        hotspot.hold(for: Self.settle + 15)
        netInfo("🛜 '\(to)' in range (\(rssi) dBm) while on '\(from)' — moving to it")
        net.join(to) { [weak self] error in
            guard let self else { return }
            if let error { netInfo("🛜 networksetup on '\(to)': \(error) — the interface decides") }
            self.queue.asyncAfter(deadline: .now() + Self.settle) { self.judge(from: from, to: to) }
        }
    }

    /// On `queue`: what the interface is on now, and whether it carries anything.
    private func judge(from: String, to: String) {
        let ssid = CWWiFiClient.shared().interface(withName: Config.wifiInterface)?.ssid()
        let verdict: (backoff: TimeInterval, rejoin: Bool)
        if ssid != to {
            netInfo("🛜 Move to '\(to)' did not take (on '\(ssid ?? "nothing")') — retrying in \(Int(Self.backoffAfterFailedJoin / 60)) min")
            verdict = (Self.backoffAfterFailedJoin, false)
        } else if Self.wifiHasInternet() {
            netInfo("🛜 Moved from '\(from)' to '\(to)'")
            verdict = (0, false)
        } else {
            netInfo("🛜 '\(to)' joined but carries nothing — back to '\(from)', not again for \(Int(Self.backoffAfterDeadNetwork / 60)) min")
            verdict = (Self.backoffAfterDeadNetwork, true)
        }
        DispatchQueue.main.async {
            self.backoffUntil = Date() + verdict.backoff
            guard verdict.rejoin else { self.switching = false; self.net.refresh(); return }
            self.hotspot.hold(for: Self.settle + 15)
            self.net.join(from) { _ in self.switching = false; self.net.refresh() }
        }
    }

    /// A TCP handshake **over Wi-Fi**: with a cable in, the default route would
    /// answer for the cable.
    private static func wifiHasInternet() -> Bool {
        for _ in 1...2 {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .wifi
            let conn = NWConnection(host: "1.1.1.1", port: 443, using: params)
            let sem = DispatchSemaphore(value: 0)
            var ok = false
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: ok = true; sem.signal()
                case .failed, .cancelled: sem.signal()
                default: break
                }
            }
            conn.start(queue: DispatchQueue.global(qos: .utility))
            _ = sem.wait(timeout: .now() + 4)
            conn.cancel()
            if ok { return true }
            Thread.sleep(forTimeInterval: 2)
        }
        return false
    }

    var stateJSON: [String: Any] {
        ["preferred": preferred, "enabled": PreferredWifiSettings.isEnabled, "switching": switching,
         "backoff_s": max(0, Int(backoffUntil.timeIntervalSinceNow))]
    }
}
