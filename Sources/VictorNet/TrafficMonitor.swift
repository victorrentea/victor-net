import AppKit
import Darwin
import Foundation
import Network

/// 📈 What this connection is doing, and how it compares with the others —
/// the question behind it (Victor, 2026-10-20): *"I sometimes have a hard time
/// telling if the hotel Wi-Fi has a larger bandwidth and a lower latency than
/// my hotspot."*
///
/// - **↓ / ↑** — the `en*` interfaces' kernel byte counters, read once a second
///   all the time (a `getifaddrs` call, nothing measurable), so the window is
///   already full when the menu opens. Shown as the **5 s average** and the
///   **highest 5 s average in the last 10 minutes on this network**; no
///   instantaneous number, which jumped too much to read.
/// - **Latency** — `LatencyProbe`, a TCP handshake to 1.1.1.1:443 every 5 s,
///   also always on: comparing two networks needs numbers taken the same way on
///   both, whatever was open at the time.
/// - **⚡ Speed test** — what a link *can* do, which "max seen" only says if
///   something happened to use it: one download of a fixed size, on demand.
///
/// Every network's figures are kept in `NetworkBook` (`~/.victor-net/networks.json`)
/// for the *Other networks* submenu.

/// Per-second rates, kept for 10 minutes.
struct RateHistory {
    static let keep: TimeInterval = 600
    static let window = 5

    private(set) var samples: [(at: Date, value: Double)] = []

    mutating func add(_ value: Double, at now: Date) {
        samples.append((now, value))
        samples.removeAll { now.timeIntervalSince($0.at) > Self.keep }
    }

    mutating func reset() { samples = [] }

    /// Mean of the last `window` samples (fewer right after a network change).
    var average: Double? {
        let last = samples.suffix(Self.window)
        return last.isEmpty ? nil : last.map(\.value).reduce(0, +) / Double(last.count)
    }

    /// The highest `window`-sample mean held — a sustained rate, not one spike.
    var maxAverage: Double? {
        guard !samples.isEmpty else { return nil }
        let v = samples.map(\.value)
        guard v.count > Self.window else { return v.reduce(0, +) / Double(v.count) }
        var sum = v[0..<Self.window].reduce(0, +)
        var best = sum
        for i in Self.window..<v.count {
            sum += v[i] - v[i - Self.window]
            best = max(best, sum)
        }
        return best / Double(Self.window)
    }

    /// The last `count` values, oldest first, for the bars.
    func recent(_ count: Int) -> [Double] { samples.suffix(count).map(\.value) }
}

/// What this Mac remembers about one network.
struct NetworkRecord: Codable, Equatable {
    var name: String
    var kind: String
    var maxDown: Double = 0
    var maxUp: Double = 0
    var latencyMs: Double?
    var speedDown: Double?
    var speedAt: Date?
    var lastSeen: Date
}

enum NetworkBookPolicy {
    /// `name — ↓ max 8.4 MB/s · ⚡ 21 MB/s · 38 ms · 2 h ago`
    static func line(_ r: NetworkRecord, now: Date) -> String {
        var parts = ["↓ max \(TrafficPolicy.rate(r.maxDown))", "↑ max \(TrafficPolicy.rate(r.maxUp))"]
        if let s = r.speedDown { parts.append("⚡ \(TrafficPolicy.rate(s))") }
        if let l = r.latencyMs { parts.append(String(format: "%.0f ms", l)) }
        parts.append(ago(r.lastSeen, now: now))
        return "\(r.name) — " + parts.joined(separator: " · ")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) h \(s % 3600 / 60) min"
    }

    /// "now", "35 min", "3 h", "2 days" — the **last seen** column.
    static func since(_ date: Date, now: Date) -> String {
        let a = ago(date, now: now)
        return a.hasSuffix(" ago") ? String(a.dropLast(4)) : a
    }

    static func ago(_ date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 120 { return "now" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 2 * 86_400 { return "\(s / 3600) h ago" }
        return "\(s / 86_400) days ago"
    }
}

final class NetworkBook {
    static let path = Config.directory.appendingPathComponent("networks.json")
    private(set) var records: [String: NetworkRecord] = [:]

    init() {
        if let data = try? Data(contentsOf: Self.path),
           let r = try? JSONDecoder().decode([String: NetworkRecord].self, from: data) {
            records = r
        }
    }

    func update(_ key: String, _ change: (inout NetworkRecord) -> Void, name: String, kind: String) {
        var r = records[key] ?? NetworkRecord(name: name, kind: kind, lastSeen: Date())
        r.name = name
        r.kind = kind
        change(&r)
        records[key] = r
    }

    func save() {
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(records).write(to: Self.path, options: .atomic)
    }
}

/// Time to complete a TCP handshake with 1.1.1.1:443 — one round trip, through
/// whatever route the Mac is using. A few hundred bytes every 5 s.
final class LatencyProbe {
    private let queue = DispatchQueue(label: "ro.victorrentea.victor-net.latency", qos: .utility)
    private var timer: DispatchSourceTimer?
    var onResult: ((Double?) -> Void)?

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 5)
        t.setEventHandler { [weak self] in self?.probe() }
        t.resume()
        timer = t
    }

    private func probe() {
        let began = DispatchTime.now()
        let conn = NWConnection(host: "1.1.1.1", port: 443, using: .tcp)
        var done = false
        let finish: (Double?) -> Void = { [weak self] ms in
            guard !done else { return }
            done = true
            conn.cancel()
            RunLoop.main.perform(inModes: [.common]) { self?.onResult?(ms) }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(Double(DispatchTime.now().uptimeNanoseconds - began.uptimeNanoseconds) / 1e6)
            case .failed, .waiting: finish(nil)
            default: break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { finish(nil) }
    }
}

/// The network the Mac is on now, as the book files it.
struct NetworkID: Equatable {
    let key: String
    let name: String
    /// "wired", "wifi", "hotspot".
    let kind: String
}

final class TrafficMonitor {
    private(set) var down = RateHistory()
    private(set) var up = RateHistory()
    /// Handshake times in the last 10 minutes.
    private(set) var latency: [(at: Date, ms: Double)] = []
    private(set) var network: NetworkID?
    let book = NetworkBook()
    private let probe = LatencyProbe()
    private var timer: Timer?
    private var lastCounters: [String: (UInt32, UInt32)] = [:]
    private var lastCounterTime: TimeInterval = 0
    private var ticks = 0
    private(set) var speedTestRunning = false

    /// Asked every second; `NetworkState` answers.
    var currentNetwork: () -> NetworkID? = { nil }
    /// Main thread, after every sample.
    var onChange: (() -> Void)?

    func start() {
        lastCounters = Self.readCounters()
        lastCounterTime = ProcessInfo.processInfo.systemUptime
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        probe.onResult = { [weak self] ms in
            guard let self else { return }
            guard let ms else {
                if self.offlineSince == nil { self.offlineSince = Date() }
                return
            }
            if let since = self.offlineSince, Date().timeIntervalSince(since) > 10 {
                netInfo("📶 back online after \(Int(Date().timeIntervalSince(since)))s")
            }
            self.offlineSince = nil
            self.latency.append((Date(), ms))
            self.latency.removeAll { Date().timeIntervalSince($0.at) > RateHistory.keep }
        }
        probe.start()
    }

    /// The first failed handshake of the current run of failures; nil while
    /// they succeed. Took over Victor Insomnia's "📵 Offline N min" row on
    /// 2026-10-20, when Insomnia stopped caring about the internet.
    private(set) var offlineSince: Date?

    /// Mean of the last three handshakes (≈ 15 s).
    var latencyRecent: Double? {
        let last = latency.suffix(3).map(\.ms)
        return last.isEmpty ? nil : last.reduce(0, +) / Double(last.count)
    }

    var latencyBest: Double? { latency.map(\.ms).min() }

    private func tick() {
        let now = Date()
        let net = currentNetwork()
        if net != network {
            if let old = network { netInfo("📈 \(old.name) → \(net?.name ?? "offline"): new window") }
            network = net
            down.reset()
            up.reset()
            latency = []
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        let counters = Self.readCounters()
        let seconds = max(0.001, uptime - lastCounterTime)
        var bytesIn: UInt64 = 0, bytesOut: UInt64 = 0
        for (name, c) in counters {
            guard let before = lastCounters[name] else { continue }
            bytesIn += TrafficPolicy.delta(c.0, before.0)
            bytesOut += TrafficPolicy.delta(c.1, before.1)
        }
        lastCounters = counters
        lastCounterTime = uptime
        down.add(Double(bytesIn) / seconds, at: now)
        up.add(Double(bytesOut) / seconds, at: now)

        ticks += 1
        // An unnamed Wi-Fi (no Location grant yet) is not filed: every network
        // would land on the same row of the book.
        if let net, net.key != NetworkState.unnamedKey, ticks % 10 == 0 { record(net, now: now) }
        onChange?()
    }

    /// Into the book every 10 s; to disk every minute.
    private func record(_ net: NetworkID, now: Date) {
        let maxDown = down.maxAverage ?? 0, maxUp = up.maxAverage ?? 0
        let median = latency.isEmpty ? nil : latency.map(\.ms).sorted()[latency.count / 2]
        book.update(net.key, { r in
            // The book keeps the best of the day: a network seen yesterday may
            // be a different room's load, or a different hotel with the same SSID.
            let sameDay = now.timeIntervalSince(r.lastSeen) < 86_400
            r.maxDown = max(maxDown, sameDay ? r.maxDown : 0)
            r.maxUp = max(maxUp, sameDay ? r.maxUp : 0)
            if let median { r.latencyMs = median }
            r.lastSeen = now
        }, name: net.name, kind: net.kind)
        if ticks % 60 == 0 { book.save() }
    }

    /// ⚡ One download of a fixed size; the rate goes to this network's record.
    /// Smaller on the hotspot, where every byte comes out of the phone's plan.
    func runSpeedTest(onDone: @escaping (Double?) -> Void) {
        guard !speedTestRunning, let net = network else { return onDone(nil) }
        speedTestRunning = true
        let bytes = net.kind == "hotspot" ? 10_000_000 : 25_000_000
        let url = URL(string: "https://speed.cloudflare.com/__down?bytes=\(bytes)")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 30
        let began = Date()
        URLSession(configuration: config).dataTask(with: url) { [weak self] data, _, error in
            let elapsed = Date().timeIntervalSince(began)
            let rate = (data?.count ?? 0) > bytes / 2 && error == nil ? Double(data!.count) / elapsed : nil
            RunLoop.main.perform(inModes: [.common]) {
                guard let self else { return }
                self.speedTestRunning = false
                if let rate {
                    netInfo("⚡ speed test on \(net.name): \(TrafficPolicy.rate(rate))")
                    self.book.update(net.key, { $0.speedDown = rate; $0.speedAt = Date(); $0.lastSeen = Date() },
                                     name: net.name, kind: net.kind)
                    self.book.save()
                } else {
                    netInfo("⚡ speed test on \(net.name) failed: \(error?.localizedDescription ?? "short read")")
                }
                onDone(rate)
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }.resume()
    }

    var stateJSON: [String: Any] {
        var o: [String: Any] = [
            "network": orNull(network?.name),
            "down_avg": orNull(down.average), "down_max": orNull(down.maxAverage),
            "up_avg": orNull(up.average), "up_max": orNull(up.maxAverage),
            "latency_recent_ms": orNull(latencyRecent), "latency_best_ms": orNull(latencyBest),
            "offline_s": orNull(offlineSince.map { Int(Date().timeIntervalSince($0)) }),
        ]
        return o
    }

    /// Byte counters of the `en*` interfaces that are up. `utun*` is skipped: a
    /// VPN's bytes also cross `en0`, and counting both would double them.
    static func readCounters() -> [String: (UInt32, UInt32)] {
        var result: [String: (UInt32, UInt32)] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return result }
        defer { freeifaddrs(head) }
        var cursor = head
        while let ifa = cursor?.pointee {
            defer { cursor = ifa.ifa_next }
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0,
                  let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self).pointee else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            result[name] = (data.ifi_ibytes, data.ifi_obytes)
        }
        return result
    }
}
