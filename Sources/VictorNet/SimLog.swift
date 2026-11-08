import CoreLocation
import Foundation

/// One SIM in one place: what its hotspot gave this Mac there.
struct SimSpot: Codable, Equatable {
    /// The last `SimLogPolicy.keepSamples` handshakes to 1.1.1.1, in ms.
    var latency: [Double] = []
    /// SINR in dB, read along with each handshake.
    var sinr: [Double] = []
    /// Bytes per second of the last automatic speed test.
    var speed: Double?
    var speedAt: Date?
    var lastSeen: Date = .distantPast
    /// Best 5 s average seen here on this SIM, bytes/s. Optional: older files lack them.
    var maxDown: Double?
    var maxUp: Double?
    /// How the menu names it ("Orange"), kept for when the phone is not around to say.
    var label: String?
}

/// The decisions behind `SimLog`, with no clock, file or network of their own.
enum SimLogPolicy {
    static let keepSamples = 240
    /// Ten minutes on one SIM in one place, before its capacity is worth measuring.
    static let settle: TimeInterval = 600
    /// Faster than this, Victor is using the link: a test would measure his traffic too.
    static let busyBytesPerSecond: Double = 100_000

    /// About a kilometre: a training room and its hotel stay apart, one building does not split.
    static func place(_ c: CLLocationCoordinate2D?) -> String {
        guard let c else { return "?" }
        return String(format: "%.2f,%.2f", c.latitude, c.longitude)
    }

    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Once per SIM per place, ever (Victor, 2026-11-08), and never on roaming data, which is paid by the MB.
    static func shouldTestSpeed(_ spot: SimSpot?, stableFor: TimeInterval, recentDown: Double, roaming: Bool) -> Bool {
        !roaming && stableFor >= settle && recentDown < busyBytesPerSecond && spot?.speedAt == nil
    }

}

/// 📶 Which of the phone's two SIMs serves this Mac better, place by place (Victor, 2026-11-08:
/// *"the goal is just the best traffic and/or latency"*). Docs: docs/victor-net.md.
///
/// Latency costs nothing to collect: `LatencyProbe` already shakes hands every 5 s, so each
/// result on the hotspot is filed under the place and the SIM the phone reports. Capacity
/// cannot be read off traffic, which only shows what happened to be used, so after ten quiet
/// minutes on one SIM in one place the 10 MB ⚡ test runs, once for that SIM there, never in roaming.
/// Kept in `~/.victor-net/sim-places.json`, which stays on this Mac.
final class SimLog {
    static let path = Config.directory.appendingPathComponent("sim-places.json")

    private let traffic: TrafficMonitor
    private(set) var spots: [String: [String: SimSpot]] = [:]
    private var stable: (place: String, sim: String, since: Date)?
    private var unsaved = 0

    var onHotspot: () -> Bool = { false }
    var signal: () -> PhoneSignal? = { nil }
    var location: () -> (CLLocation, Date)? = { nil }
    /// Unknown counts as roaming: a test is not worth a wrong guess abroad.
    var roaming: () -> Bool = { true }

    init(traffic: TrafficMonitor) {
        self.traffic = traffic
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.path),
           let s = try? dec.decode([String: [String: SimSpot]].self, from: data) {
            spots = s
        }
    }

    /// Where this Mac is: a fix older than an hour says nothing about the room it is in now.
    private var place: String {
        guard let (fix, at) = location(), Date().timeIntervalSince(at) < 3600 else { return "?" }
        return SimLogPolicy.place(fix.coordinate)
    }

    /// The SIM the phone uses for data, while its hotspot is this Mac's network.
    var currentSim: String? {
        guard onHotspot(), let s = signal(), Date().timeIntervalSince(s.readAt) < PhoneStatusPolicy.staleAfter else { return nil }
        return s.sim
    }

    /// One `LatencyProbe` result. Main thread.
    func latency(_ ms: Double) {
        guard let sim = currentSim else { stable = nil; return }
        let now = Date(), here = place
        if stable?.place != here || stable?.sim != sim { stable = (here, sim, now) }
        var spot = spots[here, default: [:]][sim] ?? SimSpot()
        spot.latency = Array((spot.latency + [ms]).suffix(SimLogPolicy.keepSamples))
        if let sinr = signal()?.sinr { spot.sinr = Array((spot.sinr + [Double(sinr)]).suffix(SimLogPolicy.keepSamples)) }
        spot.lastSeen = now
        // The traffic window restarts on a SIM switch, so its best belongs to this SIM.
        spot.maxDown = max(spot.maxDown ?? 0, traffic.down.maxAverage ?? 0)
        spot.maxUp = max(spot.maxUp ?? 0, traffic.up.maxAverage ?? 0)
        if let s = signal()?.sims.first(where: { $0.name == sim }) { spot.label = SimSignalPolicy.label(s) }
        spots[here, default: [:]][sim] = spot
        unsaved += 1
        if unsaved >= 12 { save() }

        let stableFor = stable.map { now.timeIntervalSince($0.since) } ?? 0
        if SimLogPolicy.shouldTestSpeed(spot, stableFor: stableFor, recentDown: traffic.down.average ?? 0,
                                        roaming: roaming()) {
            spots[here]?[sim]?.speedAt = now   // claimed now: one test, even if it fails
            netInfo("📶 measuring \(sim)'s capacity here (\(here))")
            traffic.runSpeedTest { [weak self] rate in
                guard let self, let rate else { return }
                self.spots[here]?[sim]?.speed = rate
                self.save()
            }
        }
    }

    /// What each SIM gave this Mac where it is now.
    var here: [String: SimSpot] { spots[place] ?? [:] }

    var stateJSON: [String: Any] {
        ["place": place, "sim": orNull(currentSim),
         "stable_s": orNull(stable.map { Int(Date().timeIntervalSince($0.since)) }),
         "here": (spots[place] ?? [:]).mapValues { s in
             ["latency_ms": orNull(SimLogPolicy.median(s.latency)), "samples": s.latency.count,
              "sinr_db": orNull(SimLogPolicy.median(s.sinr)), "speed": orNull(s.speed)] as [String: Any]
         }]
    }

    func save() {
        unsaved = 0
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(spots).write(to: Self.path, options: .atomic)
    }
}
