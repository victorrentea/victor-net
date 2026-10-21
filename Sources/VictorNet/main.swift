import AppKit
import Darwin
import Foundation

// --- Logs: /tmp/victor-net.log however we were launched ---
// Under `open` (Login Items, Finder, start.sh) stdout goes to the unified log;
// redirect it so every launch writes the same file.
func redirectLogsIfNeeded() {
    var st = stat()
    let isRegular = fstat(fileno(stderr), &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    if isRegular { return }
    let fd = open("/tmp/victor-net.log", O_WRONLY | O_APPEND | O_CREAT, 0o644)
    if fd < 0 { return }
    setvbuf(stdout, nil, _IOLBF, 0)
    setvbuf(stderr, nil, _IONBF, 0)
    dup2(fd, fileno(stdout))
    dup2(fd, fileno(stderr))
    close(fd)
}
redirectLogsIfNeeded()

// --- One instance: a new launch replaces the old one ---
let pidFilePath = "/tmp/VictorNet.pid"
let myPid = getpid()

func pidIsVictorNet(_ pid: Int32) -> Bool {
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
    return String(cString: buf).contains("Victor Net")
}

if let old = (try? String(contentsOfFile: pidFilePath, encoding: .utf8))
        .flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
   old != myPid, pidIsVictorNet(old) {
    netInfo("Stopping previous instance (pid \(old))")
    kill(old, SIGTERM)
    for _ in 0..<20 where kill(old, 0) == 0 { usleep(100_000) }
    if kill(old, 0) == 0 { kill(old, SIGKILL) }
}
try? "\(myPid)".write(toFile: pidFilePath, atomically: true, encoding: .utf8)

// --- The app ---
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let net = NetworkState()
    private let traffic = TrafficMonitor()
    private let phone = PhoneLink()
    private let roaming = PhoneRoamingMonitor()
    private let hotspot = HotspotFallback()
    private var roamingData: RoamingDataWatch?
    private var menu: StatusMenu?
    private var http: HttpServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        netInfo("Victor Net starting (built \(BuildInfo.time)); config \(Config.file.path)\(Config.hasPhone ? "" : " — no phone configured")")
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)

        net.refresh()
        let menu = StatusMenu(net: net, traffic: traffic, phone: phone, roaming: roaming)
        self.menu = menu

        traffic.currentNetwork = { [weak self] in self?.net.network }
        traffic.onChange = { [weak self] in
            self?.net.refresh()
            self?.menu?.tick()
        }
        traffic.start()

        phone.onHotspot = { [weak self] in self?.net.onHotspot ?? false }
        phone.onSignal = { [weak self] s in
            self?.net.phoneSignal = s
            self?.menu?.refreshIcon()
        }
        phone.onReading = { [weak self] r in self?.roaming.accept(r) }
        phone.onVodafone = { [weak self] v in self?.menu?.vodafoneArrived(v) }
        phone.viaBluetooth = { [weak self] path, budget, done in self?.roaming.request(path, budget: budget, done: done) }
        phone.start()

        // No pill on screen for a low allowance (Victor, 2026-10-20: "I don't
        // need that"): the ⚠ / ✕ beside the bars is the whole warning.
        roaming.onReading = { [weak self] _ in self?.menu?.refreshIcon() }
        roaming.onVodafone = { [weak self] v in self?.menu?.vodafoneArrived(v) }
        roaming.start()
        hotspot.start()

        let watch = RoamingDataWatch(phone: roaming, location: { [weak self] in self?.hotspot.lastLocationFix() })
        watch.start()
        roamingData = watch
        menu.onRoamingSuspendToggled = { [weak watch] in watch?.refresh() }

        let server = HttpServer { [weak self] path, query in self?.route(path, query) ?? (503, "{}") }
        server.start()
        http = server
    }

    /// On the HTTP queue. Reads of main-thread state go through the main run
    /// loop in common modes, so a hook still answers while the menu is open.
    private func route(_ path: String, _ query: [String: String]) -> (Int, String) {
        switch path {
        case "/ping":
            return (200, HttpServer.json(["ok": true, "app": "victor-net", "built": BuildInfo.time]))
        case "/test/state":
            var o: [String: Any] = [:]
            onMain {
                o["network"] = self.net.stateJSON
                o["traffic"] = self.traffic.stateJSON
                o["phone"] = self.phone.stateJSON
                o["roaming"] = self.roaming.diagnosticsJSON
            }
            return (200, HttpServer.json(o))
        case "/test/hotspot":
            return (200, hotspot.forceAttemptJSON())
        case "/test/roaming":
            roaming.pollNow()
            return (200, roaming.diagnosticsJSON)
        case let p where p.hasPrefix("/test/roaming/simulate/"):
            let arg = String(p.dropFirst("/test/roaming/simulate/".count))
            onMain { self.roaming.simulate(remainingPct: Int(arg) ?? -1) }
            return (200, roaming.diagnosticsJSON)
        case "/test/vodafone/ask":
            // The menu's "Ask Vodafone for What Is Left", as a click would; read the
            // outcome in the log (`📶 *123# →`, then `📶 Vodafone says`).
            DispatchQueue.main.async { self.menu?.askVodafoneNow() }
            return (200, "{\"ok\":true}")
        case "/test/more-row":
            var path = ""
            onMain { path = self.menu?.renderMoreRowForTest() ?? "" }
            return (200, HttpServer.json(["png": path]))
        case "/test/icon":
            // The current icon, 8× on a light and a dark bar, to look at.
            var path = ""
            onMain { path = self.menu?.renderIconForTest(wired: query["wired"] == "1") ?? "" }
            return (200, HttpServer.json(["png": path]))
        case "/test/menu/open":
            let secs = min(max(Double(query["close"] ?? "") ?? 3, 0.5), 10)
            DispatchQueue.main.async { self.menu?.openForTest(closeAfter: secs, unfoldMore: query["more"] == "1") }
            return (200, "{\"ok\":true}")
        default:
            return (404, "{\"error\":\"not found\"}")
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        let done = DispatchSemaphore(value: 0)
        RunLoop.main.perform(inModes: [.common]) { work(); done.signal() }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        _ = done.wait(timeout: .now() + 2)
    }

    func applicationWillTerminate(_ notification: Notification) {
        traffic.book.save()
        if (try? String(contentsOfFile: pidFilePath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "\(myPid)" {
            try? FileManager.default.removeItem(atPath: pidFilePath)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
