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

/// The menu's hotspot button: one row at the top, above the Wi-Fi switch and apart from the
/// list of networks, so it never moves under the cursor (Victor, 2026-11-11: offline, the list
/// was one grey "Offline" row with no Start in it; when the hotspot came up the list grew under
/// his cursor and his click landed on "Stop Hotspot").
enum HotspotButton: String, Equatable {
    case start, asking, starting, stop, stopping

    var title: String {
        switch self {
        case .start: return "Start Hotspot"
        case .asking: return "Asking the phone…"
        // The phone's app accepted the channel: the routine is turning the hotspot on.
        case .starting: return "Starting Hotspot…"
        case .stop: return "Stop Hotspot"
        case .stopping: return "Stopping Hotspot…"
        }
    }

    static let allStates: [HotspotButton] = [.start, .asking, .starting, .stop, .stopping]

    /// Only the two verbs act; the -ing states just show how far it got.
    var clickable: Bool { self == .start || self == .stop }
}

extension HotspotRowPolicy {
    static func button(_ p: HotspotProgress, onHotspot: Bool, inScan: Bool, stoppedRecently: Bool) -> HotspotButton {
        switch p.phase {
        case .askingPhone: return .asking
        case .joining: return .starting
        case .idle, .checking: break
        }
        // A scan keeps a stopped hotspot's name for 40–50 s: right after a stop only being on it counts.
        if stoppedRecently { return onHotspot ? .stopping : .start }
        return onHotspot || inScan ? .stop : .start
    }

    /// A click does what the button said for at least a second before it: one on a label that
    /// just changed under the cursor is dropped, not turned into the opposite verb.
    static func takesClick(shown: HotspotButton, now: HotspotButton, shownSince: Date, at: Date) -> Bool {
        shown == now && now.clickable && at.timeIntervalSince(shownSince) >= 1
    }
}
