import Foundation

/// The phone's music stops while Victor dictates on this Mac (asked 2026-10-29).
///
/// **Where "dictating" comes from.** Victor Mac's `ChromeBridge` pushes
/// `{"type":"dictation","active":true|false}` on `ws://127.0.0.1:8766` for the
/// Victor Addons Chrome extension, which pauses audible tabs with it. Its window
/// is "Wispr Flow or Walkie Talkie holds the microphone" (`CoreAudioManager`), so
/// it covers a Walkie dictation through either engine. This is one more client on
/// that socket; it says `hello` with only `dictation`, so Victor Mac never sends
/// it a Chrome command. With Victor Mac not running, the connect fails and is
/// retried.
///
/// Until 2026-11-24 this listened on Walkie Talkie's own `MusicBridge`
/// (`:8920`), deleted on 2026-11-20 with Walkie's Chrome extension: from then on
/// nobody told the phone, until this moved to Victor Mac's bridge.
///
/// **How the phone is told.** `GET /media?hold=1&ttl=…` / `hold=0`, a
/// `StatusServer.kt` route on the phone, through `PhoneLink` — over HTTP while on
/// the hotspot (milliseconds), otherwise `R /media…` over Bluetooth (a page, a
/// few seconds). The phone takes a transient audio focus, so the player pauses
/// and resumes by itself when it is given back.
///
/// **Why a ttl, refreshed.** A `hold=0` that never arrives (Victor Mac quit, this
/// Mac asleep, out of Bluetooth range) must not leave the music off for good, so
/// the phone lets go on its own after `ttl` and the hold is renewed every
/// `refresh` while the dictation lasts.
final class PhoneMediaPause {

    static let bridgeURL = URL(string: "ws://127.0.0.1:8766")!
    private static let ttl = 90
    private static let refresh: TimeInterval = 30
    private static let reconnectAfter: TimeInterval = 5

    private let phone: PhoneLink
    private let session = URLSession(configuration: .ephemeral)

    // Main thread only.
    private var task: URLSessionWebSocketTask?
    private var connected = false
    private var dictating = false
    /// What the phone was last told and whether a request is out: only one at a
    /// time, so a quick pause–resume cannot arrive in the wrong order.
    private var sent: Bool?
    private var inFlight = false
    private var lastSentAt = Date.distantPast
    private var lastError: String?
    private var refreshTimer: Timer?

    init(phone: PhoneLink) { self.phone = phone }

    func start() {
        guard Config.hasPhone else { return }
        connect()
        let t = Timer(timeInterval: Self.refresh, repeats: true) { [weak self] _ in self?.renew() }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    var stateJSON: [String: Any] {
        ["bridge_connected": connected, "dictating": dictating,
         "phone_told": sent.map { $0 ? "pause" : "resume" } ?? NSNull(),
         "last_error": lastError ?? NSNull()]
    }

    // MARK: - Victor Mac's dictation bridge

    private func connect() {
        let t = session.webSocketTask(with: Self.bridgeURL)
        task = t
        t.resume()
        // Listed as a client that handles `dictation` only, so the bridge's
        // feature-gated commands (focus-or-open, reload) are never meant for us.
        t.send(.string(#"{"type":"hello","client":"victor-net","features":["dictation"]}"#)) { _ in }
        receive(t)
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.task === t else { return }
                switch result {
                case .success(let message):
                    if !self.connected {
                        self.connected = true
                        netInfo("🎵 listening to Victor Mac's dictation bridge — the phone's music pauses with it")
                    }
                    if case .string(let text) = message { self.handle(text) }
                    self.receive(t)
                case .failure:
                    if self.connected { netInfo("🎵 Victor Mac's dictation bridge closed — retrying every \(Int(Self.reconnectAfter))s") }
                    self.connected = false
                    self.task = nil
                    // A socket gone mid-dictation is Victor Mac gone: let the music go.
                    self.setDictating(false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.reconnectAfter) { [weak self] in self?.connect() }
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              o["type"] as? String == "dictation", let active = o["active"] as? Bool else { return }
        setDictating(active)
    }

    // MARK: - The phone

    private func setDictating(_ value: Bool) {
        guard value != dictating else { return }
        dictating = value
        push()
    }

    private func renew() {
        if dictating, Date().timeIntervalSince(lastSentAt) >= Self.refresh - 1 { sent = nil; push() }
    }

    private func push() {
        guard !inFlight, sent != dictating else { return }
        let hold = dictating
        // Nothing to undo if the phone was never told to pause.
        if !hold && sent == nil { return }
        inFlight = true
        lastSentAt = Date()
        phone.media(hold: hold, ttl: Self.ttl) { [weak self] _, error in
            guard let self else { return }
            self.inFlight = false
            if let error {
                if error != self.lastError { netInfo("🎵 phone \(hold ? "pause" : "resume") failed: \(error)") }
                self.lastError = error
                // A pause that never landed needs no resume; a resume that failed
                // is covered by the phone's ttl.
                self.sent = hold ? nil : false
            } else {
                if self.sent != hold { netInfo(hold ? "🎵 phone music paused for the dictation" : "🎵 phone music resumed") }
                self.lastError = nil
                self.sent = hold
            }
            // Only if the dictation moved on while we were asking; a failed pause
            // is retried by `renew`, not in a tight loop.
            if self.dictating != hold { self.push() }
        }
    }
}
