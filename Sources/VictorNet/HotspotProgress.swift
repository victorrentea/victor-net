import Foundation

/// What `HotspotFallback` is doing, as the menu's *Start Hotspot* row
/// shows it. A value: the attempt blocks the fallback's queue for up to 100 s,
/// so the menu reads a copy instead of waiting on it.
struct HotspotProgress: Equatable {
    enum Phase: Equatable {
        case idle
        /// Probing the internet, up to ~9 s while offline.
        case checking
        /// The Bluetooth page, the SDP query and the channel open.
        case askingPhone(deadline: Date)
        /// The signal is delivered: waiting for the hotspot and joining it.
        case joining(deadline: Date)
    }

    var phase: Phase = .idle
    var offline = false
    var nextRetryAt: Date?
    /// Why the last attempt failed; the row's tooltip.
    var lastFailure: String?
}

/// When the next automatic attempt runs, and how the row words all of it.
enum HotspotRowPolicy {
    /// Attempts start at least `cooldown` apart and at least `pause` after the
    /// last one ended: a failed attempt can outlast the cooldown (it takes up to
    /// 100 s), and the phone is not paged again the second it ends.
    static func nextAttempt(lastStart: Date, ended: Date, cooldown: TimeInterval, pause: TimeInterval) -> Date {
        max(lastStart + cooldown, ended + pause)
    }

    /// Whole seconds still to go, rounded up: "1s" until it really is over.
    static func seconds(until date: Date, now: Date) -> Int {
        max(0, Int(date.timeIntervalSince(now).rounded(.up)))
    }

    /// On the hotspot, with internet, there is nothing to start.
    static func visible(_ p: HotspotProgress, onHotspot: Bool) -> Bool {
        !onHotspot || p.offline || p.phase != .idle
    }

    /// The phone's hotspot is on, as far as this Mac can tell: it is on it, or sees it in a
    /// scan. Nothing else says so. A scan keeps the name a few seconds after a stop, so
    /// `stoppedRecently` turns the row back at once.
    static func showsStop(_ p: HotspotProgress, onHotspot: Bool, inScan: Bool, stoppedRecently: Bool) -> Bool {
        p.phase == .idle && !stoppedRecently && (onHotspot || inScan)
    }

    /// Nothing to click while an attempt runs: the row just shows it.
    static func busy(_ p: HotspotProgress) -> Bool { p.phase != .idle }

    static func status(_ p: HotspotProgress, now: Date) -> (text: String, spinning: Bool) {
        switch p.phase {
        case .askingPhone(let deadline):
            return ("asking phone \(seconds(until: deadline, now: now))s", true)
        case .joining(let deadline):
            return ("joining \(seconds(until: deadline, now: now))s", true)
        case .checking where p.offline:
            return ("checking", true)
        case .checking, .idle:
            guard p.offline, let at = p.nextRetryAt else { return ("", false) }
            return ("retrying in \(seconds(until: at, now: now))s", false)
        }
    }
}
