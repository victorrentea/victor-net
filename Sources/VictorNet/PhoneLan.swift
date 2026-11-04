import Darwin
import Foundation

/// When to ask, and whom. No sockets, so a test can pin it.
enum PhoneLanPolicy {
    /// The battery is not worth more than this (Victor, 2026-11-04).
    static let every: TimeInterval = 10 * 60
    /// Arriving on the network asks sooner, but never more than once a minute.
    static let minGap: TimeInterval = 60

    static func due(now: Date, lastAttempt: Date?, networkChanged: Bool) -> Bool {
        guard let lastAttempt else { return true }
        let gap = now.timeIntervalSince(lastAttempt)
        return gap >= every || (networkChanged && gap >= minGap)
    }

    /// Every other host of a /24 or smaller; nothing on anything wider.
    static func hosts(ip: String, mask: String) -> [String] {
        guard let me = v4(ip), let m = v4(mask), m >= 0xFFFF_FF00, ~m & (~m &+ 1) == 0, ~m >= 2 else { return [] }
        let net = me & m
        return (1..<(~m)).map { net + $0 }.filter { $0 != me }.map {
            "\($0 >> 24).\(($0 >> 16) & 255).\(($0 >> 8) & 255).\($0 & 255)"
        }
    }

    private static func v4(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 < 256 }) else { return nil }
        return parts.reduce(0) { $0 << 8 | $1 }
    }
}

/// 🔋 The phone's `/status` over the home Wi-Fi, for its battery: off the hotspot
/// the only other way is a Bluetooth page, which fails whenever the phone's radio
/// is out of reach (4 Nov 2026: 17 hours without a reading, the phone on the same
/// Wi-Fi as this Mac).
///
/// Only on `PREFERRED_SSID`, because the phone's address has to be found by asking
/// the whole subnet: on a client's network that is a port scan. Between sweeps it
/// keeps the address that answered and asks only that one.
final class PhoneLan {
    private static let tick: TimeInterval = 30

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 1.5
        c.timeoutIntervalForResource = 2
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
    private var timer: Timer?
    private var busy = false
    private var ip: String?
    private var lastAttempt: Date?
    private var lastAnswer: Date?
    private var lastSSID: String?
    private var networkChanged = false

    /// Asked on every tick (from `NetworkState`).
    var onHotspot: () -> Bool = { false }
    var ssid: () -> String? = { nil }
    /// Every `/status` body that carried a battery (`PhoneBatteryBook`). Main thread.
    var onStatus: ((Data) -> Void)?

    func start() {
        guard Config.hasPhone, !Config.preferredSSID.isEmpty else { return }
        let t = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    var stateJSON: [String: Any] {
        let now = Date()
        return ["ip": orNull(ip),
                "last_attempt_ago_s": orNull(lastAttempt.map { Int(now.timeIntervalSince($0)) }),
                "last_answer_ago_s": orNull(lastAnswer.map { Int(now.timeIntervalSince($0)) })]
    }

    private func check() {
        let current = ssid()
        if current != lastSSID {
            lastSSID = current
            networkChanged = true
        }
        guard !busy, current == Config.preferredSSID, !onHotspot(),
              PhoneLanPolicy.due(now: Date(), lastAttempt: lastAttempt, networkChanged: networkChanged)
        else { return }
        busy = true
        lastAttempt = Date()
        networkChanged = false
        guard let ip else { return sweep() }
        ask([ip]) { [weak self] found in
            if found != nil { self?.busy = false } else { self?.sweep() }
        }
    }

    private func sweep() {
        let hosts = Self.wifiAddress().map { PhoneLanPolicy.hosts(ip: $0.ip, mask: $0.mask) } ?? []
        guard !hosts.isEmpty else { busy = false; return }
        ask(hosts) { [weak self] found in
            guard let self else { return }
            self.busy = false
            if let found, found != self.ip { netInfo("🔋 phone found on the Wi-Fi at \(found)") }
            self.ip = found
        }
    }

    /// `done` runs once on the main thread: who answered with a battery, or nil.
    private func ask(_ hosts: [String], done: @escaping (String?) -> Void) {
        var left = hosts.count
        var answered = false
        var tasks: [URLSessionDataTask] = []
        for host in hosts {
            guard let url = URL(string: "http://\(host):\(Config.phoneStatusPort)/status") else {
                left -= 1
                continue
            }
            let task = session.dataTask(with: url) { [weak self] data, _, _ in
                RunLoop.main.perform(inModes: [.common]) {
                    left -= 1
                    guard !answered else { return }
                    if let data, PhoneBattery.parse(data, now: Date()) != nil {
                        answered = true
                        tasks.forEach { $0.cancel() }
                        self?.lastAnswer = Date()
                        self?.onStatus?(data)
                        done(host)
                    } else if left == 0 {
                        done(nil)
                    }
                }
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }
            tasks.append(task)
        }
        guard !tasks.isEmpty else { return done(nil) }
        tasks.forEach { $0.resume() }
    }

    private static func wifiAddress() -> (ip: String, mask: String)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        func text(_ a: UnsafeMutablePointer<sockaddr>) -> String {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            return String(cString: host)
        }
        var p = head
        while let i = p {
            defer { p = i.pointee.ifa_next }
            guard String(cString: i.pointee.ifa_name) == Config.wifiInterface,
                  let a = i.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET),
                  let m = i.pointee.ifa_netmask else { continue }
            return (text(a), text(m))
        }
        return nil
    }
}
