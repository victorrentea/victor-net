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

    /// `{"battery":{"pct":63,"charging":false},…}`; nil from a phone older than 29 Oct 2026.
    static func parse(_ data: Data, now: Date) -> PhoneBattery? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let b = o["battery"] as? [String: Any],
              let pct = (b["pct"] as? NSNumber)?.intValue, (0...100).contains(pct) else { return nil }
        return PhoneBattery(pct: pct, charging: (b["charging"] as? NSNumber)?.boolValue ?? false, readAt: now)
    }

    /// `GET /phone/battery`: `{"pct":63,"charging":false,"age_s":120}`, or `{"pct":-1}` when
    /// the phone has not answered since this app started.
    static func json(_ b: PhoneBattery?, now: Date) -> [String: Any] {
        guard let b else { return ["pct": -1] }
        return ["pct": b.pct, "charging": b.charging, "age_s": max(0, Int(now.timeIntervalSince(b.readAt)))]
    }
}

/// The latest `PhoneBattery`, written from the main thread and the Bluetooth
/// poll's queue, read from the HTTP queue.
final class PhoneBatteryBook {
    private let lock = NSLock()
    private var latest: PhoneBattery?

    func accept(_ data: Data) {
        guard let b = PhoneBattery.parse(data, now: Date()) else { return }
        lock.lock(); latest = b; lock.unlock()
    }

    var json: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return PhoneBattery.json(latest, now: Date())
    }
}
