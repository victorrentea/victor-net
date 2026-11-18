import Foundation

/// ✈️ A transient pill, shown by Victor Addons, each time another GB of a SIM's roaming
/// allowance is gone (Victor, 2026-11-18: "when another GB of ROAMING data is consumed, also
/// displaying the amount left (GB, %, days left, SIM)"). One counter per SIM, since each has
/// its own plan: `✈️ vdf: 8.4 GB left · 62% · 14 days`.
///
/// It follows the **phone's** count (`cycleTotal`), not the meter's live estimate: the
/// estimate is corrected by every reading, and a pill must not claim a GB the phone then
/// takes back. On the hotspot the phone answers every 5 s, off it every 20 min.
enum RoamingGbNoticePolicy {

    static let step: Int64 = 1_000_000_000

    /// The last whole GB announced for one SIM, in one plan cycle (the cycle is named by
    /// its `nextReset`, in seconds).
    struct Mark: Equatable {
        let cycle: Int64
        let gb: Int64

        var stored: String { "\(cycle):\(gb)" }
        init(cycle: Int64, gb: Int64) { self.cycle = cycle; self.gb = gb }
        init?(stored: String?) {
            guard let parts = stored?.split(separator: ":"), parts.count == 2,
                  let c = Int64(parts[0]), let g = Int64(parts[1]) else { return nil }
            self.init(cycle: c, gb: g)
        }
    }

    /// The mark to keep after this reading, and whether it crossed into a new GB.
    /// The first reading ever, or the first of a new cycle, only takes a baseline: a
    /// changed reset day or a Mac that was off must not announce a GB nobody saw go.
    /// A count that went *down* (Vodafone's `*123#` correction) lowers the mark silently,
    /// so the next GB is announced again.
    static func check(_ r: RoamingWarningPolicy.Reading, mark: Mark?) -> (mark: Mark, announce: Bool) {
        let now = Mark(cycle: Int64(r.nextReset.timeIntervalSince1970), gb: max(0, r.cycleTotal) / step)
        guard let mark, mark.cycle == now.cycle else { return (now, false) }
        return (now, now.gb > mark.gb)
    }

    /// The readings to watch: one per SIM, or the single one from an older phone app.
    static func perSim(_ r: RoamingWarningPolicy.Reading) -> [RoamingWarningPolicy.Reading] {
        r.sims.isEmpty ? [r] : r.sims
    }

    /// `✈️ vdf: 8.4 GB left · 62% · 14 days`. Short: the pill is one line of 38 pt type.
    static func text(_ r: RoamingWarningPolicy.Reading, now: Date) -> String {
        let sim = SimSignalPolicy.tag(sim: r.simName ?? "roaming", key: r.simKey)
        let pct = Int((r.remainingFraction * 100).rounded(.down))
        var line = "✈️ \(sim): \(String(format: "%.1f", Double(r.remaining) / 1e9)) GB left · \(pct)%"
        if let days = daysLeft(until: r.nextReset, now: now) {
            line += " · \(days) \(days == 1 ? "day" : "days")"
        }
        return line
    }

    /// Whole days until the reset, a part-day counting as one; nil when the phone sent none.
    static func daysLeft(until reset: Date, now: Date) -> Int? {
        guard reset.timeIntervalSince1970 > 0 else { return nil }
        return max(0, Int((reset.timeIntervalSince(now) / 86_400).rounded(.up)))
    }
}

/// Keeps one `Mark` per SIM in `UserDefaults` (so a restart does not announce the same GB
/// twice) and hands each new GB to Victor Addons' bottom-left pill.
final class RoamingGbNotice {
    private let defaults: UserDefaults
    private let show: (String) -> Void

    init(defaults: UserDefaults = .standard, show: @escaping (String) -> Void = AddonsBanner.show) {
        self.defaults = defaults
        self.show = show
    }

    /// Main thread, on every real reading (never a simulated one).
    func accept(_ reading: RoamingWarningPolicy.Reading, now: Date = Date()) {
        // One pill for all: Addons' banner is latest-wins, a second would replace the first.
        var texts: [String] = []
        defer { if !texts.isEmpty { show(texts.joined(separator: "   ")) } }
        for r in RoamingGbNoticePolicy.perSim(reading) {
            let key = "roaming.gbNotice.\(r.simKey ?? "data")"
            let (mark, announce) = RoamingGbNoticePolicy.check(
                r, mark: RoamingGbNoticePolicy.Mark(stored: defaults.string(forKey: key)))
            defaults.set(mark.stored, forKey: key)
            guard announce else { continue }
            let text = RoamingGbNoticePolicy.text(r, now: now)
            netInfo("✈️ another roaming GB gone (\(mark.gb) GB used): \(text)")
            texts.append(text)
        }
    }
}

/// The bottom-left pill of Victor Addons (`GET 127.0.0.1:55123/banner`, local only there).
/// Fire and forget: with Addons not running the notice is only in the log.
enum AddonsBanner {
    static func show(_ text: String) {
        var c = URLComponents(string: "http://127.0.0.1:55123/banner")!
        c.queryItems = [URLQueryItem(name: "text", value: text), URLQueryItem(name: "hold", value: "8")]
        guard let url = c.url else { return }
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.httpMethod = "GET"
        URLSession.shared.dataTask(with: req) { _, resp, error in
            let code = (resp as? HTTPURLResponse)?.statusCode
            if code != 200 { netInfo("✈️ Addons did not show the pill: \(error?.localizedDescription ?? "HTTP \(code ?? 0)")") }
        }.resume()
    }
}
