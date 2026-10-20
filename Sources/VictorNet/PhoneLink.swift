import Foundation
import SystemConfiguration

/// The phone's signal, and a fresh roaming reading, every 5 s — **only while the
/// Mac is on the phone's hotspot**, and over that hotspot's own network:
/// `GET http://<default gateway>:55126/status`, answered by `StatusServer.kt`
/// in the phone app.
///
/// Why HTTP here and Bluetooth elsewhere: off the hotspot the phone has no IP
/// route to this Mac, so the 20-minute roaming poll stays on Bluetooth
/// (`PhoneRoamingMonitor`). On the hotspot the gateway *is* the phone, a
/// request costs a few milliseconds and no paging, and 5 s is what a signal
/// icon needs — a Bluetooth page every 5 s would cost ~4 s each.
struct PhoneSignal: Equatable {
    /// 0…4, Android's `SignalStrength.level` for the data SIM.
    let level: Int
    let dbm: Int?
    /// "5G", "LTE", "3G"… — nil without READ_PHONE_STATE on the phone.
    let network: String?
    let operatorName: String?
    let readAt: Date
}

enum PhoneStatusPolicy {
    /// `{"signal":{"level":3,"dbm":-97,"network":"LTE","operator":"Vodafone RO"},"roaming":{…}}`
    static func parse(_ data: Data, now: Date) -> (PhoneSignal?, RoamingWarningPolicy.Reading?) {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (nil, nil) }
        var signal: PhoneSignal?
        if let s = o["signal"] as? [String: Any], let level = (s["level"] as? NSNumber)?.intValue {
            signal = PhoneSignal(level: max(0, min(4, level)), dbm: (s["dbm"] as? NSNumber)?.intValue,
                                 network: s["network"] as? String, operatorName: s["operator"] as? String,
                                 readAt: now)
        }
        var reading: RoamingWarningPolicy.Reading?
        if let r = o["roaming"] as? [String: Any],
           let json = try? JSONSerialization.data(withJSONObject: r),
           let line = String(data: json, encoding: .utf8) {
            reading = RoamingWarningPolicy.parse(line)
        }
        return (signal, reading)
    }

    /// A signal older than this is not drawn: three missed polls.
    static let staleAfter: TimeInterval = 16
}

final class PhoneLink {
    private static let every: TimeInterval = 5

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 2
        c.timeoutIntervalForResource = 3
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
    private var timer: Timer?
    private var inFlight = false
    private var lastError: String?

    /// The hotspot check, asked on every tick (from `NetworkState`).
    var onHotspot: () -> Bool = { false }
    /// Main thread.
    var onSignal: ((PhoneSignal?) -> Void)?
    var onReading: ((RoamingWarningPolicy.Reading) -> Void)?

    private(set) var signal: PhoneSignal?

    func start() {
        let t = Timer(timeInterval: Self.every, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    var stateJSON: [String: Any] {
        var o: [String: Any] = ["gateway": orNull(Self.gateway()), "last_error": orNull(lastError)]
        if let s = signal {
            o["signal"] = ["level": s.level, "dbm": orNull(s.dbm), "network": orNull(s.network),
                           "operator": orNull(s.operatorName),
                           "age_s": Int(Date().timeIntervalSince(s.readAt))]
        }
        return o
    }

    private func tick() {
        if let s = signal, Date().timeIntervalSince(s.readAt) > PhoneStatusPolicy.staleAfter {
            signal = nil
            onSignal?(nil)
        }
        guard onHotspot(), !inFlight, let gw = Self.gateway(),
              let url = URL(string: "http://\(gw):\(Config.phoneStatusPort)/status") else { return }
        inFlight = true
        session.dataTask(with: url) { [weak self] data, _, error in
            RunLoop.main.perform(inModes: [.common]) {
                guard let self else { return }
                self.inFlight = false
                guard let data, error == nil else {
                    let why = error?.localizedDescription ?? "no answer"
                    if why != self.lastError { netInfo("📱 phone status: \(why)") }
                    self.lastError = why
                    return
                }
                if self.lastError != nil { netInfo("📱 phone status answering again") }
                self.lastError = nil
                let (signal, reading) = PhoneStatusPolicy.parse(data, now: Date())
                if let signal {
                    self.signal = signal
                    self.onSignal?(signal)
                }
                if let reading { self.onReading?(reading) }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }.resume()
    }

    /// The IPv4 default router — on the hotspot, the phone itself.
    static func gateway() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "VictorNet.PhoneLink" as CFString, nil, nil),
              let v = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return v["Router"] as? String
    }
}
