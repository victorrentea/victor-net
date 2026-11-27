import Foundation

/// **The phone has one Bluetooth socket, and this Mac has two users of it.** `HotspotFallback`
/// opens a channel and holds it; `PhoneRoamingMonitor` opens one, asks one question (`/status`,
/// `/clip`, `/hotspot/off`…) and hangs up. Both go to the same SPP channel, and RFCOMM gives two
/// devices one connection per server channel: a second open while the first is held never
/// answers at all.
///
/// 12 Nov 2026, on a plane: offline for 1 h 25 min, the fallback held the channel ~73 s out of
/// every ~110. Each clip copied on the Mac (4 of them) and every `/status` poll opened a second
/// channel, waited 8 s for an answer that could not come, then dropped the whole link to re-read
/// the SDP record. That killed the held channel too ("bt socket closed" on the phone) and the
/// question was still lost. Not one Bluetooth clip in the log had ever gone through.
///
/// So the two take turns here: one open or question at a time, a question first frees the
/// channel the fallback holds (it has done its job: the phone fires the routine on accepting it,
/// the hold signals nothing), and nobody opens within `settle` of the last hang-up, while the
/// phone is still standing its next socket up.
final class PhoneSocket {
    static let shared = PhoneSocket()

    /// The phone re-listens ~2 s after a hang-up; asked sooner, this Mac's SDP cache hands back
    /// the dead channel. It was 2 s, exactly the phone's own retry sleep, and on 28 Aug 2026 the
    /// Mac lost that race by 60 ms: the query read the dead socket's channel from macOS's cache
    /// and the open never came back, burning a 40 s budget. 21 Oct 2026: a `/config` sent right
    /// after a poll never reached the phone. Longer than the phone's retry, not equal to it.
    static let settle: TimeInterval = 5
    private let settle: TimeInterval

    init(settle: TimeInterval = PhoneSocket.settle) { self.settle = settle }

    private let cond = NSCondition()
    /// An open or a question is in flight.
    private var busy = false
    /// Closes the channel the hotspot fallback holds, while it holds one.
    private var held: (() -> Void)?
    /// Who holds it: `PhoneRoamingMonitor.sessionTag` for the permanent question channel, which
    /// its own questions keep instead of freeing (2026-11-27).
    private var heldBy: String?
    private var lastHangUp = Date.distantPast

    /// Blocks until it is this caller's turn (false: not within `timeout`), frees a held channel
    /// and waits out the settle. Every `true` must be followed by `done`.
    func take(_ who: String, timeout: TimeInterval, keeping keep: String? = nil) -> Bool {
        cond.lock()
        // Uptime, like the holder's semaphores: a wall-clock deadline expires during sleep and
        // a wake would give up at once on a turn whose holder resumes its own budget.
        let until = ProcessInfo.processInfo.systemUptime + timeout
        while busy {
            let left = until - ProcessInfo.processInfo.systemUptime
            if left <= 0 {
                cond.unlock()
                netInfo("📵 \(who): the phone's channel stayed busy for \(Int(timeout))s")
                return false
            }
            _ = cond.wait(until: Date() + min(left, 1))
        }
        busy = true
        if let keep, heldBy == keep, held != nil {
            // Our own permanent channel: still open, nothing to free, nothing to settle.
            cond.unlock()
            return true
        }
        let release = held
        let releasedFrom = heldBy
        held = nil
        heldBy = nil
        cond.unlock()

        if let release {
            netInfo("📶 \(who): freeing the channel \(releasedFrom.map { "the \($0)" } ?? "the hotspot request") holds")
            release()
            hungUp()
        }
        let wait = settle - Date().timeIntervalSince(cond.withLock { lastHangUp })
        if wait > 0 { Thread.sleep(forTimeInterval: min(wait, settle)) }   // a clock stepped back
        return true
    }

    /// A channel this side closed just now, whoever held the socket: starts the settle clock.
    func noteHangUp() { cond.withLock { lastHangUp = Date() } }

    /// Sleeps out what is left of the settle since the last hang-up — for a holder that found
    /// its own channel dead after a fast `take(keeping:)` and is about to open a new one.
    func settleBeforeOpen() {
        let wait = settle - Date().timeIntervalSince(cond.withLock { lastHangUp })
        if wait > 0 { Thread.sleep(forTimeInterval: min(wait, settle)) }
    }

    /// The turn is over. `holding`: the channel stays open, and this closes it when a question
    /// needs the socket. Nil: it was hung up just now.
    func done(holding release: (() -> Void)? = nil, by holder: String? = nil) {
        cond.lock()
        busy = false
        held = release
        heldBy = release == nil ? nil : holder
        if release == nil { lastHangUp = Date() }
        cond.broadcast()
        cond.unlock()
    }

    /// The held channel went away by itself (the fallback closed it, or the phone did). `holder`
    /// is whose channel it was: a late close of the fallback's old channel must not forget the
    /// permanent one that has taken its place.
    func hungUp(by holder: String? = nil) {
        cond.withLock {
            if heldBy == holder {
                held = nil
                heldBy = nil
            }
            lastHangUp = Date()
        }
    }
}
