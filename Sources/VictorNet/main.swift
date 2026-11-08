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
    private let phoneBattery = PhoneBatteryBook()
    private let phoneBatteryBar = PhoneBatteryBar()
    private let phoneLan = PhoneLan()
    private let phoneCloud = PhoneCloud()
    private lazy var mediaPause = PhoneMediaPause(phone: phone)
    private lazy var clipSync = ClipSync(phone: phone)
    private lazy var simLog = SimLog(traffic: traffic)
    private let hotspot = HotspotFallback()
    private lazy var preferredWifi = PreferredWifi(net: net, hotspot: hotspot)
    private var roamingData: RoamingDataWatch?
    private var menu: StatusMenu?
    private var http: HttpServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        netInfo("Victor Net starting (built \(BuildInfo.time)); config \(Config.file.path)\(Config.hasPhone ? "" : " — no phone configured")")
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)

        net.refresh()
        let menu = StatusMenu(net: net, traffic: traffic, phone: phone, roaming: roaming, hotspot: hotspot)
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
        phone.onStatus = { [weak self] data in
            self?.phoneBattery.accept(data)
            self?.clipSync.status(data)
        }
        phone.viaBluetooth = { [weak self] path, budget, done in self?.roaming.request(path, budget: budget, done: done) }
        phone.start()
        mediaPause.start()

        // No pill on screen for a low allowance (Victor, 2026-10-20: "I don't
        // need that"): the ⚠ / ✕ beside the bars is the whole warning.
        roaming.onReading = { [weak self] _ in self?.menu?.refreshIcon() }
        roaming.onVodafone = { [weak self] v in self?.menu?.vodafoneArrived(v) }
        roaming.onStatus = { [weak self] data in
            self?.phoneBattery.accept(data)
            self?.clipSync.status(data)
        }
        roaming.start()
        phoneLan.onHotspot = { [weak self] in self?.net.onHotspot ?? false }
        phoneLan.ssid = { [weak self] in self?.net.ssid }
        phoneLan.onStatus = { [weak self] data in
            self?.phoneBattery.accept(data)
            self?.clipSync.status(data)
        }
        phoneLan.start()
        phoneCloud.onHotspot = { [weak self] in self?.net.onHotspot ?? false }
        phoneCloud.onReading = { [weak self] b in self?.phoneBattery.accept(b) }
        phoneCloud.start()
        phoneBatteryBar.reading = { [weak self] in self?.phoneBattery.current }
        menu.phoneBattery = { [weak self] in self?.phoneBattery.current }
        phoneBatteryBar.start()
        simLog.onHotspot = { [weak self] in self?.net.onHotspot ?? false }
        simLog.signal = { [weak self] in self?.net.phoneSignal }
        simLog.location = { [weak self] in self?.hotspot.lastLocationFix() }
        simLog.roaming = { [weak self] in self?.roaming.reading?.roamingNow ?? true }
        traffic.onLatency = { [weak self] ms in self?.simLog.latency(ms) }
        menu.simHere = { [weak self] in self?.simLog.here ?? [:] }
        clipSync.onHotspot = { [weak self] in self?.net.onHotspot ?? false }
        clipSync.start()
        hotspot.start()
        menu.onOpen = { [weak self] in self?.hotspot.menuOpened() }
        preferredWifi.start()

        let watch = RoamingDataWatch(phone: roaming, net: net, location: { [weak self] in self?.hotspot.lastLocationFix() })
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
        case "/phone/battery":
            // Read by Victor Addons for the tablet's top bar (`PhoneBattery`).
            return (200, HttpServer.json(phoneBattery.json))
        case "/test/state":
            var o: [String: Any] = [:]
            onMain {
                o["network"] = self.net.stateJSON
                o["traffic"] = self.traffic.stateJSON
                o["phone"] = self.phone.stateJSON
                o["phone_lan"] = self.phoneLan.stateJSON
                o["phone_cloud"] = self.phoneCloud.stateJSON
                o["roaming"] = self.roaming.diagnosticsJSON
                o["preferred_wifi"] = self.preferredWifi.stateJSON
                o["hotspot"] = self.hotspot.stateJSON
                o["media_pause"] = self.mediaPause.stateJSON
                o["clip"] = self.clipSync.stateJSON
                o["sim_log"] = self.simLog.stateJSON
                o["phone_battery_bar"] = self.phoneBatteryBar.stateJSON
            }
            return (200, HttpServer.json(o))
        case "/test/hotspot":
            return (200, hotspot.forceAttemptJSON())
        case "/test/hotspot/start":
            // The menu's "Start Hotspot", as a click would.
            hotspot.startNow()
            return (200, HttpServer.json(hotspot.stateJSON))
        case "/test/files/ignore":
            let secs = min(max(Double(query["s"] ?? "") ?? 60, 0), 900)
            onMain { self.clipSync.inbox.ignore(onlyDirect: query["direct"] == "1", for: secs) }
            return (200, HttpServer.json(clipSync.inbox.stateJSON))
        case "/test/hotspot/row":
            var row: [String: Any] = [:]
            onMain { row = self.menu?.hotspotRowForTest() ?? [:] }
            return (200, HttpServer.json(row))
        case "/test/hotspot/stop":
            // The menu's "Stop Hotspot", as a click would.
            onMain { self.menu?.stopHotspot() }
            return (200, "{\"ok\":true}")
        case "/test/hotspot/offline":
            hotspot.simulateOffline(seconds: min(max(Double(query["s"] ?? "") ?? 80, 1), 300))
            return (200, "{\"ok\":true}")
        case "/test/roaming":
            roaming.pollNow()
            return (200, roaming.diagnosticsJSON)
        case let p where p.hasPrefix("/test/roaming/stale/"):
            guard let ch = UInt8(p.dropFirst("/test/roaming/stale/".count)) else { return (400, "channel number") }
            PhoneChannelOpener.useStaleChannelOnce(ch)
            roaming.pollNow()
            return (200, roaming.diagnosticsJSON)
        case let p where p.hasPrefix("/test/phone-battery/simulate/"):
            let pct = Int(p.dropFirst("/test/phone-battery/simulate/".count))
            onMain { self.phoneBatteryBar.simulate(pct) }
            return (200, HttpServer.json(["simulated": orNull(pct)]))
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
        case "/test/menu/rows":
            var rows: [String] = []
            onMain { rows = self.menu?.rowsForTest() ?? [] }
            return (200, HttpServer.json(["rows": rows]))
        case "/test/menu/open":
            let secs = min(max(Double(query["close"] ?? "") ?? 3, 0.5), 30)
            DispatchQueue.main.async { self.menu?.openForTest(closeAfter: secs) }
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
