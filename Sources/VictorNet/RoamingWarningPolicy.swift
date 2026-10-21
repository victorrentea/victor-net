import Foundation

/// Pure decisions behind the 📶 roaming-allowance warning (`RoamingWarning`).
///
/// The phone owns the numbers — the plan's ceiling, the reset day, the 15%
/// threshold — and sends them with every reading (see `PhoneRoamingMonitor`
/// and `RoamingStatusChannel.kt` in `victor-phone-addons`). This side only
/// decides *whether to show it now*: once a day, on a day the phone has been
/// roaming, until Victor dismisses it.
enum RoamingWarningPolicy {

    struct Reading: Equatable {
        /// Roaming bytes since the plan's last reset day, the whole phone.
        let cycleTotal: Int64
        /// The part of `cycleTotal` that went through the hotspot.
        let cycleHotspot: Int64
        /// Roaming bytes since the phone's midnight.
        let today: Int64
        let roamingNow: Bool
        let limit: Int64
        let lowFraction: Double
        let nextReset: Date
        /// When the phone took the reading.
        let readAt: Date
        /// The phone's own verdict (`RoamingGuard`, since 14 Oct 2026): roaming
        /// right now and under its reserve, so it no longer turns the hotspot on.
        var hotspotBlocked: Bool = false
        /// The reserve the phone keeps out of the hotspot's reach.
        var reserve: Int64 = 1_000_000_000
        /// Victor switched the phone's protection off until the next reset
        /// (2026-10-20: an extra package was bought, the reserve is not wanted).
        var guardOff: Bool = false
        /// The settings the phone holds, as the Mac shows and edits them.
        var planMb: Int64?
        var adjust: Int64 = 0
        var resetDay: Int?

        var remaining: Int64 { max(0, limit - cycleTotal) }
        var remainingFraction: Double { limit > 0 ? Double(remaining) / Double(limit) : 0 }
        /// Same rule as the phone's `Reading.roamingToday`: traffic in roaming
        /// since midnight, or on a roaming network right now (the morning,
        /// before anything has been counted).
        var roamingToday: Bool { roamingNow || today > 0 }
        /// Roaming **now**, not today (14 Oct 2026): back home in the morning, the
        /// day already held GBs of roaming and the red pill fired on the home network.
        var low: Bool { roamingNow && remainingFraction < lowFraction }
    }

    /// A reading this old says nothing about *now*: the phone may have gone
    /// home, or out of Bluetooth range for the day. Three missed polls.
    static let staleAfter: TimeInterval = 60 * 60

    /// One line of JSON from the phone. Nil for anything that is not a
    /// complete reading — including the phone's own `{"error": …}` answer when
    /// it has lost Usage access, which must not read as "nothing used".
    static func parse(_ line: String) -> Reading? {
        guard let data = line.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              o["error"] == nil,
              let total = (o["cycleTotal"] as? NSNumber)?.int64Value,
              let today = (o["today"] as? NSNumber)?.int64Value,
              let limit = (o["limit"] as? NSNumber)?.int64Value, limit > 0,
              let readAt = (o["readAt"] as? NSNumber)?.doubleValue
        else { return nil }
        return Reading(
            cycleTotal: total,
            cycleHotspot: (o["cycleHotspot"] as? NSNumber)?.int64Value ?? 0,
            today: today,
            roamingNow: (o["roamingNow"] as? Bool) ?? false,
            limit: limit,
            lowFraction: (o["lowFraction"] as? NSNumber)?.doubleValue ?? 0.15,
            nextReset: Date(timeIntervalSince1970: ((o["nextReset"] as? NSNumber)?.doubleValue ?? 0) / 1000),
            readAt: Date(timeIntervalSince1970: readAt / 1000),
            hotspotBlocked: (o["hotspotBlocked"] as? Bool) ?? false,
            reserve: (o["reserve"] as? NSNumber)?.int64Value ?? 1_000_000_000,
            guardOff: (o["guardOff"] as? Bool) ?? false,
            planMb: (o["planMb"] as? NSNumber)?.int64Value,
            adjust: (o["adjust"] as? NSNumber)?.int64Value ?? 0,
            resetDay: (o["resetDay"] as? NSNumber)?.intValue)
    }

    /// The inverse of `parse`, for the copy kept on disk (`PhoneRoamingMonitor`).
    static func line(_ r: Reading) -> String {
        var o: [String: Any] = [
            "v": 1, "cycleTotal": r.cycleTotal, "cycleHotspot": r.cycleHotspot, "today": r.today,
            "roamingNow": r.roamingNow, "limit": r.limit, "lowFraction": r.lowFraction,
            "nextReset": Int64(r.nextReset.timeIntervalSince1970 * 1000),
            "readAt": Int64(r.readAt.timeIntervalSince1970 * 1000),
            "hotspotBlocked": r.hotspotBlocked, "reserve": r.reserve, "guardOff": r.guardOff, "adjust": r.adjust,
        ]
        if let p = r.planMb { o["planMb"] = p }
        if let d = r.resetDay { o["resetDay"] = d }
        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Show the warning now? Only for a fresh reading taken *today* (its
    /// `today` counter is the phone's day, so yesterday's reading would claim
    /// yesterday's roaming), and not once it has been dismissed today — the
    /// dismissal is per day, so the next roaming day asks again.
    static func shouldWarn(_ r: Reading?, now: Date, dismissedDay: String?, calendar: Calendar) -> Bool {
        // Protection switched off on the phone (an extra package bought): it knows.
        guard let r, r.low, !r.guardOff else { return false }
        guard now.timeIntervalSince(r.readAt) < staleAfter,
              calendar.isDate(r.readAt, inSameDayAs: now) else { return false }
        return dismissedDay != dayKey(now, calendar: calendar)
    }

    static func text(_ r: Reading) -> String {
        let pct = Int((r.remainingFraction * 100).rounded(.down))
        return "📶 Roaming: \(gb(r.remaining)) left (\(pct)%)"
    }

    static func gb(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1e9)
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
