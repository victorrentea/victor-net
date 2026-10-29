import AppKit
import Foundation
import IOBluetooth

/// Asks the phone, over Bluetooth, how much of the roaming allowance is left.
///
/// The phone (`victor-phone-addons`) already counts roaming traffic for its
/// ROAMING DATA card; it publishes a second RFCOMM service beside the hotspot
/// beacon, `RoamingStatusChannel`, which answers every connection with one
/// line of JSON and waits for us to hang up.
///
/// **Why a service of its own.** On the beacon's SPP channel the *connection*
/// is the signal: accepting it brings the phone's activity to the front, and
/// the Samsung routine turns the hotspot on at "App opened". Asking about
/// roaming on that channel would switch the hotspot on every 20 minutes.
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
    /// (21 Oct 2026: "Ask Vodafone" from home on tzutze went nowhere).
    static func query(_ path: String) -> Data { Data("R \(path)\n".utf8) }
    static let pollInterval: TimeInterval = 20 * 60
    /// Page + SDP + open + the phone's reading. The opener gives up on its own
    /// well inside this; the budget only guards against a callback that never comes.
    private static let pollBudget: TimeInterval = 45
    private static let reopenSettle: TimeInterval = 5
    /// On `queue`: when the last exchange hung up.
    private var lastHangUp: Date?

    private let queue = DispatchQueue(label: "ro.victorrentea.phone-roaming", qos: .utility)
    private let bluetooth = RunLoopThread(name: "ro.victorrentea.victor-net.bluetooth-roaming")
    private var timer: DispatchSourceTimer?

    // Touched on `bluetooth` only.
    private var opener: PhoneChannelOpener?
    private var channel: IOBluetoothRFCOMMChannel?
    private var buffer = Data()

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

        let (line, why) = exchange("/status", budget: Self.pollBudget)
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

    /// One question, one line: open the beacon's channel, write `R <path>`, read up
    /// to the newline, hang up. On `queue` (blocks it — one exchange at a time).
    private func exchange(_ path: String, budget: TimeInterval) -> (String?, String?) {
        // The phone re-publishes its socket ~2 s after a hang-up; asked sooner, this
        // Mac's SDP cache hands back the dead channel (21 Oct 2026: a `/config` sent
        // right after a poll never reached the phone). Same as HotspotFallback's settle.
        if let last = lastHangUp {
            let wait = Self.reopenSettle - Date().timeIntervalSince(last)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }
        defer { lastHangUp = Date() }
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
                                            serviceName: "beacon (\(path))") { outcome in
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
                    finish(String(data: self.buffer[..<nl], encoding: .utf8), nil)
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
