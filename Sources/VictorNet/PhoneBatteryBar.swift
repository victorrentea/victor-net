import AppKit

/// When the phone needs a charger, and what the bar then says. No AppKit, so a test can pin it.
enum PhoneLowBattery {
    static let threshold = 30
    /// A phone that went quiet this long ago may have been charged since.
    static let maxAge: TimeInterval = 2 * 60 * 60

    static func showing(_ b: PhoneBattery?, now: Date) -> Int? {
        guard let b, b.pct <= threshold, !b.charging, now.timeIntervalSince(b.readAt) < maxAge else { return nil }
        return b.pct
    }
}

/// 🔋 The phone's battery in the menu bar, there only while it runs low, blinking slowly in red
/// (Victor, 2026-11-06). It replaces the battery warning that was Soduto's last job. Drawn by
/// `StatusMenu` in its own item, left of the bars (2026-11-12; a separate item until then).
final class PhoneBatteryBar {
    private var simulated: Int?

    var reading: () -> PhoneBattery? = { nil }

    /// `GET /test/phone-battery/simulate/<pct>`; nil goes back to the real reading.
    func simulate(_ pct: Int?) { simulated = pct }

    /// The percentage to show now, or nil while there is nothing to warn about.
    var showing: Int? { simulated ?? PhoneLowBattery.showing(reading(), now: Date()) }

    var stateJSON: [String: Any] {
        ["showing": showing != nil, "simulated": orNull(simulated)]
    }
}
