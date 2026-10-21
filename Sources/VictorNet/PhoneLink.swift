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
/// "La 20oct26 h09:43, mai aveti: … 22.86GB din Trafic rmg optiune …" — what
/// Vodafone said, when its data was taken, and how much the phone had counted in
/// the cycle at that moment.
struct VodafoneBalance: Equatable {
    let remainingMb: Int64
    let at: Date
    let usedAtBytes: Int64?
    let received: Date
    let validUntil: Date?
}

enum VodafonePolicy {
    /// Two pots (My Vodafone, 2026-10-21): the **monthly** EU roaming allowance
    /// (`planMb`, "Date roaming SEE … din 13702.98") and the **bought option**,
    /// whose remainder is the SMS's "N GB din Trafic rmg optiune". At Vodafone's
    /// timestamp, left = option + what the monthly allowance still had then
    /// (by the phone's count). Then remaining = plan + adjust − used ⇒
    /// adjust = left − plan + used-then; what is used after that comes off.
    static func adjustMb(_ v: VodafoneBalance, planMb: Int64, usedNowBytes: Int64) -> Int64 {
        let usedThenMb = (v.usedAtBytes ?? usedNowBytes) / 1_000_000
        let monthlyLeftThen = max(0, planMb - usedThenMb)
        return v.remainingMb + monthlyLeftThen - planMb + usedThenMb
    }
}

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
            let dbm = (s["dbm"] as? NSNumber)?.intValue
            signal = PhoneSignal(level: dbm.map(bars(dbm:)) ?? max(0, min(4, level)), dbm: dbm,
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

    /// Vodafone's last balance SMS, as the phone caught it (`VodafoneSms.kt`).
    static func vodafone(_ data: Data) -> VodafoneBalance? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let v = o["vodafone"] as? [String: Any],
              let mb = (v["remainingMb"] as? NSNumber)?.int64Value,
              let at = (v["at"] as? NSNumber)?.doubleValue,
              let received = (v["received"] as? NSNumber)?.doubleValue else { return nil }
        let used = (v["usedAt"] as? NSNumber)?.int64Value ?? -1
        return VodafoneBalance(remainingMb: mb, at: Date(timeIntervalSince1970: at / 1000),
                               usedAtBytes: used >= 0 ? used : nil,
                               received: Date(timeIntervalSince1970: received / 1000),
                               validUntil: (v["validUntil"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) })
    }

    /// Bars from dBm on the scale the phone's own status bar uses, not Android's:
    /// at −102 dBm the S24 showed 2/4 while `SignalStrength.level` said 3
    /// (AOSP's LTE thresholds are −98/−108/−118; Samsung's are stricter).
    static func bars(dbm: Int) -> Int {
        switch dbm {
        case (-90)...: return 4
        case (-100)...: return 3
        case (-110)...: return 2
        case (-120)...: return 1
        default: return 0
        }
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
    var onVodafone: ((VodafoneBalance) -> Void)?
    /// Off the hotspot, `/config` and `/ussd` go over Bluetooth instead
    /// (`PhoneRoamingMonitor.request`): path, timeout, main-thread answer.
    var viaBluetooth: ((String, TimeInterval, @escaping (Data?, String?) -> Void) -> Void)?

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
                if let v = PhoneStatusPolicy.vodafone(data) { self.onVodafone?(v) }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }.resume()
    }

    /// Settings go to the phone, which keeps them because it is the one that
    /// counts and refuses the hotspot (`/config` in `StatusServer.kt`); only on
    /// its hotspot. Main thread: the fresh reading, or why not.
    func configure(_ params: [String: String], done: @escaping (RoamingWarningPolicy.Reading?, String?) -> Void) {
        let q = params.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        get("/config?\(q)", timeout: 4) { [weak self] data, error in
            guard let data else { return done(nil, error) }
            let (_, reading) = PhoneStatusPolicy.parse(data, now: Date())
            if let reading { self?.onReading?(reading) }
            done(reading, reading == nil ? "the phone answered without a reading" : nil)
        }
    }

    /// `*123#` dialled by the phone on its data SIM; Vodafone's answer as text.
    func askVodafone(done: @escaping (String?, String?) -> Void) {
        get("/ussd", timeout: 25) { data, error in
            guard let data, let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return done(nil, error ?? "unreadable answer")
            }
            done(o["answer"] as? String, o["error"] as? String)
        }
    }

    private func get(_ path: String, timeout: TimeInterval, done: @escaping (Data?, String?) -> Void) {
        guard onHotspot(), let gw = Self.gateway(),
              let url = URL(string: "http://\(gw):\(Config.phoneStatusPort)\(path)") else {
            guard let viaBluetooth else { return done(nil, "only while this Mac is on the phone's hotspot") }
            return viaBluetooth(path, timeout + 20, done)   // + the page, SDP and channel open
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        URLSession.shared.dataTask(with: request) { data, _, error in
            RunLoop.main.perform(inModes: [.common]) { done(data, error?.localizedDescription) }
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
