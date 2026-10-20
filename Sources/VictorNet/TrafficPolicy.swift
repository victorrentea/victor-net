import AppKit
import Darwin
import Foundation

/// 📈 Traffic — the pure half: reading `nettop`'s CSV, folding helper processes
/// into their app, and formatting rates. The live half is `TrafficMonitor`.
///
/// Moved from Victor Addons on 2026-10-20 with the rest of the network rows.
/// Latency from `nettop`'s `rtt_avg` (`latency(of:)`) is kept for the test
/// hook, but the menu's latency is `LatencyProbe` now: it has to run while the
/// menu is closed, so two networks can be compared at all.
enum TrafficPolicy {

    struct Row: Equatable {
        /// `Google Chrome H.45972` for a process; nil for a connection.
        let process: String?
        let pid: pid_t?
        /// Remote address of a connection (`17.57.146.24`), nil for a process.
        let remote: String?
        let isTCP: Bool
        let bytesIn: Int
        let bytesOut: Int
        let rttMs: Double?
    }

    /// One line of `nettop -x -n -J bytes_in,bytes_out,rtt_avg`, or nil for the
    /// header / anything unexpected. Connection lines carry `<->`; nettop
    /// truncates the RTT column to its width (`1247.78 m`, `16787.62`), so only
    /// the leading number is read and the unit is always milliseconds.
    static func parse(line: String) -> Row? {
        // The name may itself contain commas only in theory; the three numeric
        // columns are always the last three (plus nettop's trailing comma).
        var cols = line.components(separatedBy: ",")
        if cols.last == "" { cols.removeLast() }
        guard cols.count >= 4, !cols[0].isEmpty else { return nil }
        let rttText = cols[cols.count - 1]
        guard let bytesOut = Int(cols[cols.count - 2]), let bytesIn = Int(cols[cols.count - 3]) else { return nil }
        let name = cols[0..<(cols.count - 3)].joined(separator: ",")
        let rtt = Double(rttText.prefix { $0.isNumber || $0 == "." })

        if let arrow = name.range(of: "<->") {
            let remoteEndpoint = String(name[arrow.upperBound...])
            return Row(process: nil, pid: nil, remote: host(of: remoteEndpoint),
                       isTCP: name.hasPrefix("tcp"), bytesIn: bytesIn, bytesOut: bytesOut,
                       rttMs: (rtt ?? 0) > 0 ? rtt : nil)
        }
        let dot = name.lastIndex(of: ".")
        let pid = dot.flatMap { pid_t(name[name.index(after: $0)...]) }
        return Row(process: pid == nil ? name : String(name[..<dot!]), pid: pid, remote: nil,
                   isTCP: false, bytesIn: bytesIn, bytesOut: bytesOut, rttMs: nil)
    }

    /// `17.57.146.24:5223` → `17.57.146.24`; IPv6 puts the port after a dot
    /// (`2a00:1450::1.443`).
    static func host(of endpoint: String) -> String {
        let separator: Character = endpoint.contains(".") && endpoint.filter({ $0 == ":" }).count > 1 ? "." : ":"
        guard let i = endpoint.lastIndex(of: separator) else { return endpoint }
        return String(endpoint[..<i])
    }

    /// LAN, loopback and link-local peers say nothing about the internet's
    /// latency — the tablet on 10.x answers in 0 ms, an AirPlay socket in 2.7 s.
    static func isPublic(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "*" || h.isEmpty { return false }
        if h.contains(":") {
            return !(h == "::1" || h.hasPrefix("fe80") || h.hasPrefix("fc") || h.hasPrefix("fd"))
        }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (169, 254), (192, 168): return false
        case (172, 16...31): return false
        case (100, 64...127): return false   // CGNAT / Tailscale
        default: return true
        }
    }

    /// Median RTT of the public TCP connections, preferring those that moved
    /// bytes in this sample: an idle socket's smoothed RTT is whatever it was
    /// when it last spoke.
    static func latency(of rows: [Row]) -> (ms: Double, connections: Int)? {
        let tcp = rows.filter { $0.isTCP && $0.rttMs != nil && $0.remote.map(isPublic) == true }
        let active = tcp.filter { $0.bytesIn + $0.bytesOut > 0 }
        let pool = (active.isEmpty ? tcp : active).compactMap(\.rttMs).sorted()
        guard !pool.isEmpty else { return nil }
        let mid = pool.count / 2
        let median = pool.count % 2 == 1 ? pool[mid] : (pool[mid - 1] + pool[mid]) / 2
        return (median, pool.count)
    }

    struct App: Equatable {
        let name: String
        let bytesIn: Int
        let bytesOut: Int
    }

    /// The `count` busiest apps of one delta block, by bytes in + out. `appName`
    /// folds a pid into the app that owns it (helpers into their `.app`).
    static func topApps(of rows: [Row], count: Int = 3, appName: (Row) -> String) -> [App] {
        var totals: [String: (Int, Int)] = [:]
        for row in rows where row.process != nil && row.bytesIn + row.bytesOut > 0 {
            let name = appName(row)
            let t = totals[name] ?? (0, 0)
            totals[name] = (t.0 + row.bytesIn, t.1 + row.bytesOut)
        }
        return totals.map { App(name: $0.key, bytesIn: $0.value.0, bytesOut: $0.value.1) }
            .sorted { ($0.bytesIn + $0.bytesOut, $1.name) > ($1.bytesIn + $1.bytesOut, $0.name) }
            .prefix(count).map { $0 }
    }

    /// `/Applications/Google Chrome.app/Contents/Frameworks/…/Google Chrome
    /// Helper.app/Contents/MacOS/Google Chrome Helper` → `Google Chrome`: the
    /// **outermost** bundle, which is the app Victor would recognise.
    static func appName(executablePath: String) -> String? {
        if let r = executablePath.range(of: ".app/") {
            return executablePath[..<r.lowerBound].split(separator: "/").last.map(String.init)
        }
        // A binary named after its version (`~/.local/share/claude/versions/2.1.304`
        // is Claude Code): the folder above `versions` is the program.
        let parts = executablePath.split(separator: "/").map(String.init)
        if let last = parts.last, last.range(of: #"^\d+(\.\d+)+$"#, options: .regularExpression) != nil {
            let up = parts.dropLast().filter { $0 != "versions" }
            return up.last
        }
        return nil
    }

    /// Always MB/s, two decimals — for tables, where a column that mixes KB/s and
    /// MB/s cannot be compared at a glance (Victor, 2026-10-20).
    static func mbps(_ bytesPerSecond: Double) -> String {
        String(format: "%.2f MB/s", max(0, bytesPerSecond) / 1_000_000)
    }

    /// Bytes per second, decimal units like Activity Monitor's network tab.
    static func rate(_ bytesPerSecond: Double) -> String {
        let b = max(0, bytesPerSecond)
        if b < 1_000 { return "\(Int(b)) B/s" }
        if b < 1_000_000 { return String(format: "%.0f KB/s", b / 1_000) }
        return String(format: "%.1f MB/s", b / 1_000_000)
    }

    /// Wrap-aware difference of two 32-bit interface counters (`if_data` is
    /// 32-bit and wraps every 4 GB — once every half hour at 2 MB/s).
    static func delta(_ now: UInt32, _ before: UInt32) -> UInt64 {
        UInt64(now &- before)
    }
}

