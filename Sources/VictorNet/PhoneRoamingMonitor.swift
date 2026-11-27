import AppKit
import Foundation
import IOBluetooth

/// Asks the phone, over Bluetooth, how much of the roaming allowance is left.
///
/// The phone (`victor-phone-addons`) already counts roaming traffic for its
/// ROAMING DATA card. We ask on the beacon's own SPP channel: an `R <path>`
/// written within 1.5 s of connecting is a question and gets one line of JSON;
/// silence is what asks for the hotspot, so a question never turns it on.
///
/// **Why Bluetooth and not HTTP.** The phone is only reachable over IP while
/// the Mac is on its hotspot — and a roaming day on hotel Wi-Fi still eats the
/// same allowance. Bluetooth reaches it wherever it is in range, which is
/// wherever Victor is. The cost is a page every poll (the link drops a few
/// seconds after each short connection), ~4 s cold; that is why the poll is
/// every 20 minutes and not more often — the numbers do not move faster than
/// that in any way that matters against a 13.7 GB ceiling.
///
/// The channel opening is `PhoneChannelOpener`, shared with `HotspotFallback`,
/// so it inherits the stale-channel-number and cold-link fixes that one paid for.
final class PhoneRoamingMonitor {

    /// The beacon's own SPP service. Until 14 Oct 2026 the roaming answer had
    /// a second RFCOMM service (UUID `7a1f3c52-…`), and this Mac never once saw
    /// its SDP record: the phone published only one of its two records, and when
    /// both started in the same millisecond the stack mixed them up. Now the
    /// beacon answers both questions on one socket, told apart by the first byte.
    static let sppUUID: UInt16 = 0x1101
    /// Written the moment the channel opens: `R <path>`. The phone waits 1.5 s for
    /// the `R`; a channel that stays silent is a hotspot request, so this must never
    /// be late. The path is one of `StatusServer.kt`'s routes — the same answers the
    /// phone gives over HTTP on its hotspot, here reachable from anywhere in range
    /// (21 Oct 2026: "Ask Vodafone" from the home Wi-Fi went nowhere).
    static func query(_ path: String) -> Data { Data("R \(path)\n".utf8) }
    static let pollInterval: TimeInterval = 20 * 60
    /// Page + SDP + open + the phone's reading. The opener gives up on its own
    /// well inside this; the budget only guards against a callback that never comes.
    private static let pollBudget: TimeInterval = 45
    /// `/clip?c=<ciphertext>&auth=…` is a page of noise in the log: the route is enough.
    static func shortPath(_ path: String) -> String {
        path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
    }

    private let queue = DispatchQueue(label: "ro.victorrentea.phone-roaming", qos: .utility)
    private let bluetooth = RunLoopThread(name: "ro.victorrentea.victor-net.bluetooth-roaming")
    private var timer: DispatchSourceTimer?

    // Touched on `bluetooth` only.
    private var opener: PhoneChannelOpener?
    private var channel: IOBluetoothRFCOMMChannel?
    private var buffer = Data()

    // MARK: The permanent channel (2026-11-27)
    //
    // Victor: *"I'm perfectly fine keeping the connection open at all times between the
    // devices."* The Mac and the phone keep a baseband link up anyway (the phone's log: hours
    // at a time, in sniff mode 11 s after any traffic, and a 60 s idle RFCOMM hold did not wake
    // it). What cost the seconds was a **fresh channel per question**: SDP, open, the phone's
    // 1.5 s query window, and `PhoneSocket.settle` before the next one. So the first question
    // opens with `R /session`; a phone that knows it answers `{"session":true}` and keeps
    // reading `R <path>` lines on that channel for as long as it stays open, and every later
    // question is one line out, one line back. An older phone answers `not found` and hangs
    // up: then it is one channel per question, as before. The hotspot request keeps its own
    // channel: its `take` frees this one, and the next question opens it again.
    static let sessionTag = "question session"
    /// Touched on `bluetooth` only: the open session's channel and its waiting question.
    private var sessionOpener: PhoneChannelOpener?
    private var sessionChannel: IOBluetoothRFCOMMChannel?
    private var sessionBuffer = Data()
    private var sessionPending: ((String?, String?) -> Void)?
    /// Read on `queue`, written on either: whether a session is up, and whether this phone has none.
    private let sessionLock = NSLock()
    private var _sessionOpen = false
    private var sessionUnsupportedUntil = Date.distantPast
    /// A channel that closed before it answered, or died under a question: the next open drops
    /// the link first. Measured 2026-11-27 21:50: after Victor Net was restarted with the
    /// channel up, every open "succeeded" and closed at once, the phone never saw one, until the
    /// link went down and came back (11.5 s); then the phone accepted the next open at once.
    private var dropLinkFirst = false
    /// Longer than a restart, shorter than an evening: an updated phone app is found again soon.
    private static let unsupportedFor: TimeInterval = 30 * 60

    private let lock = NSLock()
    private var _reading: RoamingWarningPolicy.Reading?
    private var _simulated: RoamingWarningPolicy.Reading?
    private var _lastPollAt: Date?
    private var _lastError: String?
    private var _lastLine: String?
    private var pollInFlight = false

    /// Fired on the main thread after every poll, with the current reading
    /// (nil when there has never been one).
    var onReading: ((RoamingWarningPolicy.Reading?) -> Void)?
    /// Vodafone's last balance SMS, carried by every `/status` (main thread).
    var onVodafone: ((VodafoneBalance) -> Void)?
    /// Every `/status` body the Bluetooth poll got (`PhoneBatteryBook`). On the poll's queue.
    var onStatus: ((Data) -> Void)?

    var reading: RoamingWarningPolicy.Reading? {
        lock.lock(); defer { lock.unlock() }
        return _simulated ?? _reading
    }

    /// A `/test/roaming/simulate` reading is shadowing the phone's (`RoamingGbNotice` skips it).
    var isSimulating: Bool { lock.withLock { _simulated != nil } }

    /// The last reading, kept on disk (Victor, 2026-10-21: "should be cached on the
    /// Mac even if the phone is unavailable"): after a restart the menu shows it at
    /// once instead of "the phone has not answered yet", with its age.
    static let cachePath = Config.directory.appendingPathComponent("roaming-last.json")

    init() {
        if let line = try? String(contentsOf: Self.cachePath, encoding: .utf8) {
            _reading = RoamingWarningPolicy.parse(line)
        }
    }

    /// Under `lock`.
    private func keep(_ r: RoamingWarningPolicy.Reading) {
        _reading = r
        let line = RoamingWarningPolicy.line(r)
        DispatchQueue.global(qos: .utility).async { try? line.write(to: Self.cachePath, atomically: true, encoding: .utf8) }
    }

    func start() {
        guard timer == nil, Config.hasPhone else { return }
        bluetooth.start()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 20, repeating: Self.pollInterval)
        t.setEventHandler { [weak self] in self?.poll(reason: "timer") }
        t.resume()
        timer = t
        // Sleeping drops the link and may have crossed midnight or a border.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.asyncAfter(deadline: .now() + 30) { self?.poll(reason: "wake") }
        }
    }

    /// A reading that came another way — over the hotspot, from `PhoneLink`,
    /// every 5 s — replaces the Bluetooth one: it is the same JSON, fresher.
    func accept(_ r: RoamingWarningPolicy.Reading) {
        lock.lock()
        keep(r)
        _lastPollAt = Date()
        _lastError = nil
        let current = _simulated ?? r
        lock.unlock()
        onReading?(current)
    }

    /// The phone just answered over Bluetooth (a hotspot request): a reading older than `age`
    /// is refreshed now rather than at the 20-minute timer, so the menu does not say
    /// "19 min ago · BT" while the phone is right there (Victor, 2026-11-12, on a plane).
    func pollIfOlder(than age: TimeInterval, reason: String) {
        guard Config.hasPhone else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let last = self.lock.withLock { self._lastPollAt }
            guard last.map({ Date().timeIntervalSince($0) > age }) ?? true else { return }
            self.poll(reason: reason)
        }
    }

    /// `GET /test/roaming` — poll now (async), answer with the previous state.
    func pollNow(reason: String = "test") {
        guard Config.hasPhone else { return }
        queue.async { [weak self] in self?.poll(reason: reason) }
    }

    /// Any `StatusServer.kt` route over Bluetooth (`/config?…`, `/ussd`), for when
    /// the Mac is not on the hotspot. Main thread: the JSON line, or why not.
    func request(_ path: String, budget: TimeInterval, done: @escaping (Data?, String?) -> Void) {
        guard Config.hasPhone else { return done(nil, "no phone configured") }
        queue.async { [weak self] in
            guard let self else { return }
            let (line, error) = self.exchange(path, budget: budget)
            DispatchQueue.main.async { done(line.map { Data($0.utf8) }, error) }
        }
    }

    /// `GET /test/roaming/simulate/<pct>` — pretend the phone roams today with
    /// `pct`% left; `pct` < 0 clears the simulation. Shadows the real reading.
    func simulate(remainingPct: Int) {
        lock.lock()
        if remainingPct < 0 {
            _simulated = nil
        } else {
            let limit: Int64 = 13_703_000_000
            _simulated = RoamingWarningPolicy.Reading(
                cycleTotal: limit - limit * Int64(remainingPct) / 100, cycleHotspot: 0, today: 1,
                roamingNow: true, limit: limit, lowFraction: 0.15,
                nextReset: Date().addingTimeInterval(86_400), readAt: Date())
        }
        let r = _simulated ?? _reading
        lock.unlock()
        netInfo("📶 roaming: simulating \(remainingPct)% left")
        DispatchQueue.main.async { self.onReading?(r) }
    }

    var diagnosticsJSON: String {
        lock.lock(); defer { lock.unlock() }
        let r = _simulated ?? _reading
        var o: [String: Any] = [
            "simulated": _simulated != nil,
            "last_poll_at": _lastPollAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
            "last_error": _lastError ?? NSNull(),
            "last_line": _lastLine ?? NSNull(),
        ]
        if let r {
            o["cycle_total"] = r.cycleTotal
            o["today"] = r.today
            o["roaming_now"] = r.roamingNow
            o["limit"] = r.limit
            o["remaining_pct"] = Int(r.remainingFraction * 100)
            o["low"] = r.low
            o["read_at"] = ISO8601DateFormatter().string(from: r.readAt)
        }
        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Polling (on `queue`)

    private func poll(reason: String) {
        guard !pollInFlight else { return }
        pollInFlight = true
        defer { pollInFlight = false }

        let (line, why) = exchange(PhoneAuth.statusPath, budget: Self.pollBudget)
        var error = why
        // `/status` = {"signal":…,"roaming":{…},"vodafone":{…}}; a phone older than
        // 21 Oct 2026 ignores the path and answers the bare reading.
        let data = line.map { Data($0.utf8) }
        let parsed = data.flatMap { PhoneStatusPolicy.parse($0, now: Date()).1 } ?? line.flatMap(RoamingWarningPolicy.parse)
        let vodafone = data.flatMap(PhoneStatusPolicy.vodafone)
        if let data { onStatus?(data) }
        if line != nil, parsed == nil { error = "unreadable answer from the phone" }
        lock.lock()
        _lastPollAt = Date()
        _lastLine = line
        _lastError = error
        if let parsed { keep(parsed) }
        let current = _simulated ?? _reading
        lock.unlock()

        if let parsed {
            netInfo("📶 roaming (\(reason)): \(RoamingWarningPolicy.gb(parsed.cycleTotal)) of " +
                        "\(RoamingWarningPolicy.gb(parsed.limit)), today \(RoamingWarningPolicy.gb(parsed.today))" +
                        "\(parsed.roamingNow ? ", roaming now" : "")\(parsed.low ? " — LOW" : "")")
        } else {
            netInfo("📵 roaming poll (\(reason)) failed: \(error ?? "?")")
        }
        DispatchQueue.main.async {
            self.onReading?(current)
            if let vodafone { self.onVodafone?(vodafone) }
        }
    }

    /// One question, one line — over the permanent channel when the phone has one, else on a
    /// channel of its own. On `queue` (blocks it — one exchange at a time).
    private func exchange(_ path: String, budget: TimeInterval) -> (String?, String?) {
        guard Date() >= sessionLock.withLock({ sessionUnsupportedUntil }) else {
            return singleExchange(path, budget: budget)
        }
        guard PhoneSocket.shared.take("beacon (\(Self.shortPath(path)))", timeout: max(budget, 45),
                                      keeping: Self.sessionTag) else {
            return (nil, "the phone's channel stayed busy")
        }
        var reused = sessionLock.withLock { _sessionOpen }
        for attempt in 0..<2 {
            if !sessionLock.withLock({ _sessionOpen }) {
                // A fast `take(keeping:)` may have found the session already dead: the phone needs
                // its re-listen before the next open (the 28 Aug stale-SDP race).
                PhoneSocket.shared.settleBeforeOpen()
                let started = Date()
                switch openSession(budget: budget) {
                case .open:
                    netInfo(String(format: "📶 permanent channel to the phone open in %.1f s", Date().timeIntervalSince(started)))
                case .unsupported:
                    sessionLock.withLock { sessionUnsupportedUntil = Date() + Self.unsupportedFor }
                    netInfo("📶 the phone has no permanent channel (an older app) — one channel per question for \(Int(Self.unsupportedFor / 60)) min")
                    PhoneSocket.shared.done()
                    return singleExchange(path, budget: budget)
                case .failed(let why):
                    // Closed before it answered: a stale channel, which only a fresh link clears.
                    // Once more, now, rather than losing this question too.
                    if attempt == 0, sessionLock.withLock({ dropLinkFirst }) {
                        netInfo("📵 the permanent channel closed before answering (\(why)) — dropping the link and opening again")
                        PhoneSocket.shared.noteHangUp()
                        continue
                    }
                    PhoneSocket.shared.done()
                    return (nil, why)
                }
                reused = false
            }
            let (line, why, unreached) = ask(path, budget: budget)
            if let line {
                PhoneSocket.shared.done(holding: { [weak self] in self?.closeSession() }, by: Self.sessionTag)
                if line.hasPrefix("#") { return (nil, "the phone took the question for a hotspot request (\(line))") }
                return (line, nil)
            }
            closeSession()
            PhoneSocket.shared.noteHangUp()   // now, not when the Bluetooth thread gets to it
            if reused { sessionLock.withLock { dropLinkFirst = true } }
            // A channel that died without telling us (a sleep, a dropped link, the phone's service
            // restarted): once more on a fresh one — when the question cannot have reached the
            // phone, or is safe to repeat (review, 2026-11-27).
            guard attempt == 0, reused, unreached || Self.repeatable(path) else {
                PhoneSocket.shared.done()
                return (nil, why)
            }
            netInfo("📶 the permanent channel was dead (\(why ?? "?")) — reopening it")
        }
        PhoneSocket.shared.done()
        return (nil, "the phone never answered")
    }

    /// Reads and settings: asked twice, they do no harm. Not `/ussd`, `/clip`, `/chime`, `/hotspot/off`.
    static func repeatable(_ path: String) -> Bool {
        ["", "/status", "/config", "/media"].contains(shortPath(path))
    }

    enum SessionOpen: Equatable { case open, unsupported, failed(String) }

    /// Opens the channel and asks `R /session`. On `queue`, inside a `PhoneSocket` turn.
    private func openSession(budget: TimeInterval) -> SessionOpen {
        var result = SessionOpen.failed("the phone never answered")
        let done = DispatchSemaphore(value: 0)
        var signalled = false
        let finish: (SessionOpen) -> Void = { r in
            guard !signalled else { return }
            signalled = true
            result = r
            done.signal()
        }
        bluetooth.async { [weak self] in
            guard let self else { return finish(.failed("shutting down")) }
            guard let dev = IOBluetoothDevice(addressString: HotspotFallback.phoneBluetoothAddress) else {
                return finish(.failed("phone not in the Bluetooth pairing list"))
            }
            self.sessionBuffer = Data()
            if self.sessionLock.withLock({ () -> Bool in let d = self.dropLinkFirst; self.dropLinkFirst = false; return d }) {
                dev.closeConnection()   // the opener pages it back up and reads the SDP record afresh
            }
            self.sessionPending = { line, why in
                guard let line else { return finish(.failed(why ?? "the phone never answered")) }
                finish(Self.handshake(line))
            }
            let opener = PhoneChannelOpener(device: dev, service: IOBluetoothSDPUUID(uuid16: Self.sppUUID),
                                            serviceName: "beacon (session)") { outcome in
                switch outcome {
                case .opened(let ch, _):
                    self.sessionChannel = ch
                    // Signed, so no other paired device can hold the phone's only socket with it.
                    var bytes = [UInt8](Self.query(PhoneAuth.sign("/session", key: PhoneAuth.key)))
                    let written = ch.writeSync(&bytes, length: UInt16(bytes.count))
                    if written != kIOReturnSuccess { self.answer(nil, "could not open the session (\(written))") }
                case .failed(let why):
                    self.answer(nil, why)
                }
            }
            opener.onData = { [weak self] data in self?.sessionReceived(data) }
            opener.onClosed = { [weak self] in
                guard let self else { return }
                let handshaking = !self.sessionLock.withLock { self._sessionOpen }
                if handshaking { self.sessionLock.withLock { self.dropLinkFirst = true } }
                self.sessionLock.withLock { self._sessionOpen = false }
                self.sessionChannel = nil
                self.sessionOpener = nil
                self.answer(nil, "the phone closed the channel")
                PhoneSocket.shared.hungUp(by: Self.sessionTag)
            }
            self.sessionOpener = opener
            opener.start()
        }
        if done.wait(timeout: .now() + budget) == .timedOut { finish(.failed("the phone never answered")) }
        switch result {
        case .open:
            sessionLock.withLock { _sessionOpen = true }
        case .unsupported, .failed:
            // An older phone answers `not found` and waits for us to hang up.
            closeSession()
        }
        return result
    }

    /// The answer to `R /session`: `{"session":true}` = a session; any other JSON (an older phone:
    /// `{"error":"not found"}` / `"unsigned"`) = none; `#go`… (the `R` came too late and it took
    /// the channel for a hotspot request) or a cut line = a failed open, tried again next time.
    static func handshake(_ line: String) -> SessionOpen {
        if line.contains("\"session\":true") { return .open }
        if line.hasPrefix("{"), line.hasSuffix("}") { return .unsupported }
        return .failed("the phone did not open a session (\(line.prefix(20)))")
    }

    /// One `R <path>` line on the open session, one line back. On `queue`. `unreached`: the
    /// question was never written (no channel, a failed write), so asking again is safe.
    private func ask(_ path: String, budget: TimeInterval) -> (String?, String?, Bool) {
        var line: String?
        var error: String? = "the phone never answered"
        var unreached = false
        let done = DispatchSemaphore(value: 0)
        var signalled = false
        let finish: (String?, String?, Bool) -> Void = { l, why, never in
            guard !signalled else { return }
            signalled = true
            line = l
            error = why
            unreached = never
            done.signal()
        }
        bluetooth.async { [weak self] in
            guard let self, let ch = self.sessionChannel, ch.isOpen() else {
                return finish(nil, "the permanent channel is gone", true)
            }
            self.sessionPending = { l, why in finish(l, why, false) }
            var bytes = [UInt8](Self.query(path))
            let written = ch.writeSync(&bytes, length: UInt16(bytes.count))
            if written != kIOReturnSuccess {
                self.sessionPending = nil
                finish(nil, "could not ask the phone (\(written))", true)
            }
        }
        // Over an open channel an answer takes a link wake-up (≤ 0.75 s) and the phone's work; a
        // channel dead without a close callback must not hold the question for the whole budget.
        // `/ussd` is the exception: Vodafone may take 20 s, and the phone is busy until then.
        let wait = Self.shortPath(path) == "/ussd" ? budget : min(budget, 12)
        if done.wait(timeout: .now() + wait) == .timedOut {
            finish(nil, "no answer on the permanent channel", false)
        }
        bluetooth.async { [weak self] in self?.sessionPending = nil }
        return (line, error, unreached)
    }

    /// On `bluetooth`: a line completes the waiting question.
    private func sessionReceived(_ data: Data) {
        sessionBuffer.append(data)
        while let nl = sessionBuffer.firstIndex(of: 0x0A) {
            let line = String(data: sessionBuffer[sessionBuffer.startIndex..<nl], encoding: .utf8)
            sessionBuffer.removeSubrange(sessionBuffer.startIndex...nl)
            answer(line, nil)
        }
        if sessionBuffer.count > 1 << 20 { sessionBuffer = Data() }
    }

    /// On `bluetooth`.
    private func answer(_ line: String?, _ why: String?) {
        let pending = sessionPending
        sessionPending = nil
        pending?(line, why)
    }

    /// Any thread.
    private func closeSession() {
        sessionLock.withLock { _sessionOpen = false }
        bluetooth.async { [weak self] in
            guard let self else { return }
            let had = self.sessionChannel != nil || self.sessionOpener != nil
            self.sessionOpener?.onClosed = nil
            self.sessionChannel?.close()
            self.sessionChannel = nil
            self.sessionOpener = nil
            self.answer(nil, "the permanent channel was closed")
            if had { PhoneSocket.shared.hungUp(by: Self.sessionTag) }
        }
    }

    /// One question on a channel of its own: open, write `R <path>`, read up to the newline,
    /// hang up — the only way before 2026-11-27, and still the way to a phone without sessions.
    private func singleExchange(_ path: String, budget: TimeInterval) -> (String?, String?) {
        // One socket on the phone, shared with the hotspot request: wait for our turn, which
        // frees the channel that request may be holding and waits out the phone's re-listen
        // (21 Oct 2026: a `/config` sent right after a poll never reached the phone).
        // At least a slow hotspot turn (stale channel, re-page, verdict, settle): a clip that times
        // out here is not sent again.
        guard PhoneSocket.shared.take("beacon (\(Self.shortPath(path)))", timeout: max(budget, 45)) else {
            return (nil, "the phone's channel stayed busy")
        }
        defer { PhoneSocket.shared.done() }
        var line: String?
        var error: String? = "the phone never answered"
        let done = DispatchSemaphore(value: 0)
        var signalled = false
        let finish: (String?, String?) -> Void = { l, why in
            guard !signalled else { return }
            signalled = true
            line = l
            error = why
            done.signal()
        }

        bluetooth.async { [weak self] in
            guard let self else { return finish(nil, "shutting down") }
            guard let dev = IOBluetoothDevice(addressString: HotspotFallback.phoneBluetoothAddress) else {
                return finish(nil, "phone not in the Bluetooth pairing list")
            }
            self.buffer = Data()
            let opener = PhoneChannelOpener(device: dev, service: IOBluetoothSDPUUID(uuid16: Self.sppUUID),
                                            serviceName: "beacon (\(Self.shortPath(path)))") { outcome in
                switch outcome {
                case .opened(let ch, _):
                    self.channel = ch
                    var bytes = [UInt8](Self.query(path))
                    let written = ch.writeSync(&bytes, length: UInt16(bytes.count))
                    if written != kIOReturnSuccess { finish(nil, "could not ask the phone (\(written))") }
                case .failed(let why):
                    finish(nil, why)
                }
            }
            opener.onData = { [weak self] data in
                guard let self else { return }
                self.buffer.append(data)
                if let nl = self.buffer.firstIndex(of: 0x0A) {
                    let line = String(data: self.buffer[..<nl], encoding: .utf8)
                    // `#go`/`#airplane`: the phone missed the `R` and took this for a hotspot
                    // request. Not an answer — and `/clip` must not report "sent".
                    if line?.hasPrefix("#") == true {
                        return finish(nil, "the phone took the question for a hotspot request (\(line ?? ""))")
                    }
                    finish(line, nil)
                }
            }
            opener.onClosed = { finish(nil, "the phone closed the channel without an answer") }
            self.opener = opener
            opener.start()
        }

        _ = done.wait(timeout: .now() + budget)
        // Hang up on the Bluetooth thread, where the channel lives; the phone
        // is waiting for exactly this to free its socket for the next caller.
        bluetooth.async { [weak self] in
            self?.opener?.onClosed = nil
            self?.channel?.close()
            self?.channel = nil
            self?.opener = nil
        }
        return (line, error)
    }
}
