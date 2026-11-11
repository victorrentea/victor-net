import Foundation

/// The phone's own charge, as its last `/status` said it — for the tablet's
/// soundboard, which shows it in its top bar instead of the tablet's own
/// (Victor, 2026-10-29). Victor Addons reads it from `GET /phone/battery` and
/// passes it on in the `/ping` the tablet already polls.
///
/// No traffic of its own: it rides on the answers this app already gets — every
/// 5 s over the hotspot (`PhoneLink`), every 20 min over Bluetooth off it
/// (`PhoneRoamingMonitor`). So off the hotspot the number can be that old, and
/// `age_s` says so; the tablet draws an old one dimmed.
struct PhoneBattery: Equatable {
    let pct: Int
    let charging: Bool
    let readAt: Date
    /// How it reached this Mac; shown beside its age (Victor, 2026-11-11).
    var via: Channel? = nil

    enum Channel: String {
        case bluetooth = "BT", hotspot = "Hotspot", wifi = "Wi-Fi", internet = "Internet"
    }

    /// `{"battery":{"pct":63,"charging":false},…}`; nil from a phone older than 29 Oct 2026.
    static func parse(_ data: Data, now: Date, via: Channel? = nil) -> PhoneBattery? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let b = o["battery"] as? [String: Any],
              let pct = (b["pct"] as? NSNumber)?.intValue, (0...100).contains(pct) else { return nil }
        return PhoneBattery(pct: pct, charging: (b["charging"] as? NSNumber)?.boolValue ?? false, readAt: now, via: via)
    }

    /// The menu's row: "🔋 Phone: 63% ⚡ · 12s ago · Wi-Fi" — always how old the reading is and
    /// how it came (Victor, 2026-11-11), redrawn every second while the menu is open.
    func menuTitle(now: Date) -> String {
        "🔋 Phone: \(pct)%\(charging ? " ⚡" : "") · \(Self.age(readAt, now: now))\(via.map { " · \($0.rawValue)" } ?? "")"
    }

    /// Seconds while it is fresh — the hotspot answers every 5 s — then minutes, hours, days.
    static func age(_ date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 2 * 86_400 { return "\(s / 3600) h ago" }
        return "\(s / 86_400) days ago"
    }

    /// Railway's `{"pct":63,"charging":false,"age_s":120}`; nil from `{"pct":-1}` (never reported).
    static func parseCloud(_ data: Data, now: Date) -> PhoneBattery? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pct = (o["pct"] as? NSNumber)?.intValue, (0...100).contains(pct),
              let age = (o["age_s"] as? NSNumber)?.doubleValue else { return nil }
        return PhoneBattery(pct: pct, charging: (o["charging"] as? NSNumber)?.boolValue ?? false,
                            readAt: now.addingTimeInterval(-age), via: .internet)
    }

    /// `GET /phone/battery`: `{"pct":63,"charging":false,"age_s":120}`, or `{"pct":-1}` when
    /// the phone has not answered since this app started.
    static func json(_ b: PhoneBattery?, now: Date) -> [String: Any] {
        guard let b else { return ["pct": -1] }
        var o: [String: Any] = ["pct": b.pct, "charging": b.charging, "age_s": max(0, Int(now.timeIntervalSince(b.readAt)))]
        if let via = b.via { o["via"] = via.rawValue }
        return o
    }
}

/// The latest `PhoneBattery`, written from the main thread and the Bluetooth
/// poll's queue, read from the HTTP queue.
final class PhoneBatteryBook {
    private let lock = NSLock()
    private var latest: PhoneBattery?

    func accept(_ data: Data, via: PhoneBattery.Channel) {
        guard let b = PhoneBattery.parse(data, now: Date(), via: via) else { return }
        accept(b)
    }

    /// The freshest wins: Railway's answer can be older than what just came over Wi-Fi.
    func accept(_ b: PhoneBattery) {
        lock.lock(); defer { lock.unlock() }
        if latest.map({ b.readAt >= $0.readAt }) ?? true { latest = b }
    }

    var current: PhoneBattery? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    var json: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return PhoneBattery.json(latest, now: Date())
    }
}
