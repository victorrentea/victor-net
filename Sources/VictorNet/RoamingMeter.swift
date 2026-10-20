import AppKit
import CoreWLAN
import Darwin
import Foundation

/// The pure half of the 📶 roaming meter: what it says, and when it shows.
///
/// Asked for 14 Oct 2026, after the laptop emptied the roaming allowance through
/// the hotspot with no warning reaching anyone. **The phone decides** whether
/// the hotspot is still allowed (`RoamingGuard.kt` in `victor-phone-addons`
/// keeps the last 1 GB out of its reach), because only the phone knows it is
/// roaming right now. This side only shows the number, and keeps it moving
/// between the phone's 5-minute answers by subtracting what this Mac itself
/// has pulled through the hotspot since the phone's reading.
enum RoamingMeterPolicy {

    /// The phone's reading is only trusted for the 20-minute poll's span and a
    /// bit; after that the estimate is shown as one (`~`).
    static let freshFor: TimeInterval = 30 * 60
    static let orangeUnder: Int64 = 3_000_000_000
    static let redUnder: Int64 = 1_500_000_000

    enum Tint: Equatable { case normal, orange, red }

    struct Display: Equatable {
        let title: String
        let tint: Tint
    }

    /// What is left now: the phone's number minus this Mac's hotspot bytes since.
    static func estimate(_ r: RoamingWarningPolicy.Reading, macBytesSince: Int64) -> Int64 {
        max(0, r.remaining - max(0, macBytesSince))
    }

    /// Shown while on the hotspot — unless a fresh reading says the phone is
    /// on its home network, where the hotspot costs nothing against the plan.
    static func visible(onHotspot: Bool, reading r: RoamingWarningPolicy.Reading?, now: Date) -> Bool {
        guard onHotspot else { return false }
        guard let r, now.timeIntervalSince(r.readAt) < freshFor else { return true }
        return r.roamingNow
    }

    static func display(_ r: RoamingWarningPolicy.Reading?, macBytesSince: Int64, now: Date) -> Display {
        guard let r else { return Display(title: "📶 ?", tint: .orange) }
        let left = estimate(r, macBytesSince: macBytesSince)
        let stale = now.timeIntervalSince(r.readAt) >= freshFor
        let icon = r.hotspotBlocked || left < r.reserve ? "📵" : "📶"
        let tint: Tint = left < redUnder ? .red : left < orangeUnder ? .orange : .normal
        return Display(title: "\(icon) \(stale ? "~" : "")\(String(format: "%.1f", Double(left) / 1e9)) GB", tint: tint)
    }
}

/// Bytes through one interface, summed across samples. `if_data` counters are
/// 32-bit and wrap at 4 GiB — a single afternoon on the hotspot — so this keeps
/// its own 64-bit total from deltas taken every few seconds, far below a wrap.
struct InterfaceByteCounter {
    private(set) var total: Int64 = 0
    private var last: UInt32?
    /// (when, total) — enough to answer "since the phone's reading" for 2 hours.
    private var history: [(Date, Int64)] = []

    mutating func add(sample: UInt32?, at now: Date, counting: Bool) {
        defer { last = sample }
        guard let sample, let last else { return }
        if counting { total += Int64(sample &- last) }   // wraps the right way
        history.append((now, total))
        history.removeAll { now.timeIntervalSince($0.0) > 2 * 3600 }
    }

    /// Counted since `date`; everything we hold when the date is older than that.
    func since(_ date: Date) -> Int64 {
        guard let base = history.first(where: { $0.0 >= date }) else { return 0 }
        return total - base.1
    }

    static func read(_ name: String) -> UInt32? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            guard String(cString: ifa.pointee.ifa_name) == name,
                  ifa.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            return data.pointee.ifi_ibytes &+ data.pointee.ifi_obytes
        }
        return nil
    }
}
