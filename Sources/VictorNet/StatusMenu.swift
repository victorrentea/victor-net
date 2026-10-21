import AppKit

/// The menu bar switches: state in the title (a trailing ✓), not the item's
/// native tick — one ticked row makes AppKit reserve a check column for the
/// whole menu and nudges every row's emoji to the right.
enum HotspotMenu {
    static func title(enabled: Bool) -> String { "🛜 Auto-start Mobile Hotspot" + (enabled ? "  ✓" : "") }
}

enum RoamingSuspendMenu {
    static func title(enabled: Bool) -> String { "⏸️ Pause Claude on roaming data" + (enabled ? "  ✓" : "") }
}

/// The one status item. **The menu bar shows the route and whether to worry,
/// nothing else** (Victor, 2026-10-20): the phone's bars on its hotspot, with
/// ⚠ under 5 GB of roaming left or a red ✕ once it is gone; the GB themselves
/// are in the menu.
///
/// **The menu is a snapshot**, taken when it opens: no number moves while it is
/// read (*"I don't really care about seeing live data. It distracts me."*).
///
/// **The Mac decides; nothing is typed in** (Victor, 2026-10-20: *"the brain
/// should be on the Mac"*, *"that input text dialog doesn't have any value"*): the
/// remaining GB come from Vodafone — the phone dials `*123#`, catches the SMS and
/// reports it; this side applies it (`vodafoneArrived`). Only when asked —
/// *"I don't want to bombard Vodafone with SMS"* — and the last answer stands
/// until the next one. Protection off until the reset is the one switch.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let net: NetworkState
    private let traffic: TrafficMonitor
    private let phone: PhoneLink
    private let roaming: PhoneRoamingMonitor
    private var hotspotCounter = InterfaceByteCounter()
    private var lastAskedAt = Date.distantPast

    var onRoamingSuspendToggled: (() -> Void)?

    init(net: NetworkState, traffic: TrafficMonitor, phone: PhoneLink, roaming: PhoneRoamingMonitor) {
        self.net = net
        self.traffic = traffic
        self.phone = phone
        self.roaming = roaming
        super.init()
        statusItem.autosaveName = "victorNet"
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        refreshIcon()
    }

    /// Every second, after `TrafficMonitor` sampled.
    func tick() {
        let now = Date()
        hotspotCounter.add(sample: InterfaceByteCounter.read(Config.wifiInterface), at: now, counting: net.onHotspot)
        // An old phone app has no `/status`: ask over Bluetooth every 5 minutes
        // while the number matters.
        if net.onHotspot, phone.signal == nil, now.timeIntervalSince(lastAskedAt) > 300 {
            lastAskedAt = now
            roaming.pollNow()
        }
        refreshIcon()
    }

    /// What is left now: the phone's number minus what this Mac pulled since.
    private var roamingLeft: Int64? {
        guard let r = roaming.reading else { return nil }
        return RoamingMeterPolicy.estimate(r, macBytesSince: hotspotCounter.since(r.readAt))
    }

    func refreshIcon() {
        guard let button = statusItem.button else { return }
        var look = net.look
        if case .hotspot(let level, let weak, _) = look {
            look = .hotspot(level: level, weakWifi: weak,
                            alert: RoamingAlertPolicy.alert(roaming.reading, left: roamingLeft ?? 0, now: Date()))
        }
        button.image = look == .offline ? (net.wifiPower ? Icons.wifiIdle() : Icons.wifiOff()) : Icons.image(for: look)
        button.title = ""
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        net.scanInBackground()
    }

    func menuDidClose(_ menu: NSMenu) {
        othersExpanded = false
        rescanTimer?.invalidate()
        rescanTimer = nil
        otherRows = []
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        net.refresh()

        // Networks, the way macOS lists them: the switch, the ones worth
        // comparing (✓ = in use, click = join), everything else in range, the
        // settings. Offline, a greyed "Offline N min" stands where the list was.
        menu.addItem(wifiSwitchRow())
        menu.addItem(.separator())
        if let since = traffic.offlineSince, Date().timeIntervalSince(since) >= 5 {
            menu.addItem(NSMenuItem(view: MenuRowView(
                name: "Offline \(NetworkBookPolicy.duration(Date().timeIntervalSince(since)))",
                icon: Icons.noTraffic(), enabled: false, dimmed: true)))
        } else {
            networkRows().forEach(menu.addItem)
        }
        menu.addItem(otherNetworksRow())
        let settings = action("Wi-Fi Settings…", #selector(openWifiSettings))
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        menu.addItem(settings)

        // Everything about roaming, together.
        if Config.hasPhone {
            menu.addItem(.separator())
            addRoamingRows()
        }

        menu.addItem(.separator())
        menu.addItem(action(speedTitle(), #selector(speedTestAction)))
        menu.addItem(info("Built \(BuildInfo.time)"))
        // No ⌘Q shown: its column made the whole menu wider for nothing.
        menu.addItem(action("Quit", #selector(quitAction)))
    }

    private func speedTitle() -> String {
        if traffic.speedTestRunning { return "⚡ Testing speed…" }
        let mb = traffic.network?.kind == "hotspot" ? 10 : 25
        if let key = traffic.network?.key, let r = traffic.book.records[key], let s = r.speedDown, let at = r.speedAt {
            return "⚡ Test speed (\(mb) MB) — last \(TrafficPolicy.mbps(s)), \(NetworkBookPolicy.ago(at, now: Date()))"
        }
        return "⚡ Test speed (downloads \(mb) MB)"
    }

    // MARK: - Networks, like macOS's Wi-Fi menu

    private var othersExpanded = false
    private var othersAnchor: NSMenuItem?
    private var otherRows: [NSMenuItem] = []
    private var rescanTimer: Timer?

    /// The networks worth comparing — every Wi-Fi in range this Mac knows or has
    /// measured, plus Ethernet, always — with the day's best numbers. ✓ = in use;
    /// a click on another joins it. Out of range = off the list, numbers kept.
    private func networkRows() -> [NSMenuItem] {
        let now = Date()
        let reachable = net.reachableSSIDs()
        let known = net.knownSSIDs()
        var records = traffic.book.records
        if let cur = traffic.network, cur.key != NetworkState.unnamedKey {
            var r = records[cur.key] ?? NetworkRecord(name: cur.name, kind: cur.kind, lastSeen: now)
            r.maxDown = max(r.maxDown, traffic.down.maxAverage ?? 0)
            r.maxUp = max(r.maxUp, traffic.up.maxAverage ?? 0)
            if let best = traffic.latencyBest { r.latencyMs = r.latencyMs.map { min($0, best) } ?? best }
            r.lastSeen = now
            records[cur.key] = r
        }
        for ssid in reachable.intersection(known) where records["wifi:\(ssid)"] == nil {
            records["wifi:\(ssid)"] = NetworkRecord(name: ssid, kind: ssid == Config.hotspotSSID ? "hotspot" : "wifi",
                                                    lastSeen: .distantPast)
        }
        let shown = records.filter { key, _ in
            key == traffic.network?.key || (key.hasPrefix("wifi:") && reachable.contains(String(key.dropFirst(5))))
        }.sorted { a, b in
            a.key == traffic.network?.key ? true : b.key == traffic.network?.key ? false
                : (a.value.maxDown, b.key) > (b.value.maxDown, a.key)
        }
        // One unit for the whole list, so the column reads straight down: KB/s
        // while nothing reaches 1 MB/s, MB/s otherwise (Victor, 2026-10-20).
        let unit = TrafficPolicy.listUnit(shown.flatMap { [$0.value.maxDown, $0.value.maxUp] })
        let rate: (Double) -> String = { $0 > 0 ? unit.format($0) : "—" }
        func cell(_ r: NetworkRecord) -> String {
            "↓\(rate(r.maxDown)) / ↑\(rate(r.maxUp)) / " + (r.latencyMs.map { String(format: "%.0f ms", $0) } ?? "— ms")
        }
        let rssi = Dictionary(net.scanResults().map { ($0.ssid, $0.rssi) }, uniquingKeysWith: max)

        // The header labels the numbers, not the line: "best last hour" sits
        // over the cell it describes. No Ethernet row without a cable.
        var items = [NSMenuItem(view: MenuRowView(name: "", columns: ["best last hour, \(unit.name)", "seen"], header: true))]
        for (key, r) in shown {
            let ssid = key.hasPrefix("wifi:") ? String(key.dropFirst(5)) : nil
            // ✓ on every network this Mac is on: the route (the cable, say) *and*
            // the Wi-Fi it is joined to — both are "active" (Victor, 2026-10-21).
            let joined = ssid != nil && ssid == net.ssid
            let current = key == traffic.network?.key || joined
            let icon: NSImage?
            if key == "wired" { icon = Icons.wired() }
            else if ssid == Config.hotspotSSID { icon = Icons.phone() }
            else {
                let level = ssid == net.ssid ? net.rssi : ssid.flatMap { rssi[$0] }
                icon = Icons.wifi(strength: level.map(NetworkLookPolicy.strength(rssi:)) ?? 0)
            }
            let seen = joined ? "now" : r.lastSeen == .distantPast ? "—" : NetworkBookPolicy.since(r.lastSeen, now: now)
            let row = MenuRowView(name: ssid ?? "Ethernet",
                                  columns: [cell(r), seen],
                                  icon: icon, checked: current, enabled: !current && ssid != nil)
            if !current, let ssid { row.onClick = { [weak self] in self?.join(ssid, password: nil) } }
            items.append(NSMenuItem(view: row))
        }
        return items
    }

    /// "Other Networks ›" — a click unfolds every other Wi-Fi in range right below
    /// it, as macOS does, and they stay until the menu closes, refreshed as new
    /// scans land (every 8 s while open).
    private func otherNetworksRow() -> NSMenuItem {
        // The disclosure chevron up front, where the icons are (Victor, 2026-10-20).
        let row = MenuRowView(name: "Other Networks", icon: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil))
        row.keepsMenuOpen = true
        row.onClick = { [weak self] in self?.toggleOthers() }
        let item = NSMenuItem(view: row)
        othersAnchor = item
        return item
    }

    /// The click replaces the "Other Networks" row with the networks themselves,
    /// refreshed every 2 s from the last scan while the menu is open; a fresh
    /// scan every 6 s (a scan takes seconds and briefly stalls the link, so not
    /// every second).
    private func toggleOthers() {
        guard !othersExpanded, let anchor = othersAnchor, let i = menu.items.firstIndex(of: anchor) else { return }
        othersExpanded = true
        othersIndex = i
        menu.removeItem(at: i)
        othersAnchor = nil
        net.scanInBackground()
        refreshOthers()
        var tick = 0
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            tick += 1
            if tick % 3 == 0 { self?.net.scanInBackground() }
            self?.refreshOthers()
        }
        RunLoop.main.add(t, forMode: .common)
        rescanTimer = t
    }

    private var othersIndex = 0

    private func refreshOthers() {
        guard othersExpanded else { return }
        otherRows.forEach { menu.removeItem($0) }
        otherRows = []
        let listed = Set(traffic.book.records.keys.filter { $0.hasPrefix("wifi:") }.map { String($0.dropFirst(5)) })
            .union(net.knownSSIDs()).intersection(net.reachableSSIDs())
        let others = net.scanResults().filter { !listed.contains($0.ssid) && $0.ssid != net.ssid }
        let rows: [NSMenuItem] = others.isEmpty
            ? [NSMenuItem(view: MenuRowView(name: net.wifiPower ? "Searching…" : "Wi-Fi is off", enabled: false, dimmed: true))]
            : others.map { n in
                let lock = n.secure ? NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "secured") : nil
                let row = MenuRowView(name: n.ssid, icon: Icons.wifi(strength: NetworkLookPolicy.strength(rssi: n.rssi)),
                                      trailing: lock)
                row.onClick = { [weak self] in self?.joinOther(n.ssid, secure: n.secure) }
                return NSMenuItem(view: row)
            }
        for (k, r) in rows.enumerated() { menu.insertItem(r, at: min(othersIndex + k, menu.items.count)) }
        otherRows = rows
    }

    private func join(_ ssid: String, password: String?) {
        netInfo("🛜 joining \(ssid)")
        net.join(ssid, password: password) { error in
            if let error { Prompt.show("Could not join \(ssid)", error) } else { netInfo("🛜 joined \(ssid)") }
        }
    }

    private func joinOther(_ ssid: String, secure: Bool) {
        var password: String?
        if secure {
            guard let pw = Prompt.password("Join “\(ssid)”", "The Wi-Fi password.") else { return }
            password = pw
        }
        join(ssid, password: password)
    }

    private func wifiSwitchRow() -> NSMenuItem {
        let row = MenuSwitchRow(title: "Wi-Fi", on: net.wifiPower)
        row.onChange = { [weak self] on in
            self?.net.setWifiPower(on) { error in
                netInfo("🛜 Wi-Fi \(on ? "on" : "off")\(error.map { " — \($0)" } ?? "")")
            }
        }
        return NSMenuItem(view: row)
    }

    @objc private func openWifiSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!)
    }

    // MARK: - Roaming

    /// Only roaming counts (at home the data is unlimited): what is left, of how
    /// much in all this cycle — the used part plus what is left.
    private func addRoamingRows() {
        let gb: (Int64) -> String = { String(format: "%.1f", Double($0) / 1e9) }
        let day = DateFormatter()
        day.dateFormat = "d MMM"
        if let r = roaming.reading {
            // One line, no emoji: "Roaming: 22.6/60.9 GB left until 2 Nov" — the
            // total is what this cycle allowed in all, used + left.
            let left = roamingLeft ?? r.remaining
            // +12 h: the reset is midnight in the phone's time zone, which may
            // still be the day before in this Mac's.
            menu.addItem(info("Roaming: \(gb(left))/\(gb(left + r.cycleTotal)) GB left until \(day.string(from: r.nextReset + 12 * 3600))"))
        } else {
            menu.addItem(info("Roaming: the phone has not answered yet"))
        }
        let asking = askedVodafoneAt.map { Date().timeIntervalSince($0) < 180 } ?? false
        let ask = action(asking ? "Asking Vodafone… (the answer comes by SMS)" : "Ask Vodafone for What Is Left", #selector(askVodafone))
        ask.isEnabled = !asking
        menu.addItem(ask)
        // Said the positive way, ticked by default.
        let allow = action("Allow Claude on Roaming", #selector(toggleSuspend))
        allow.state = RoamingDataSettings.suspendClaude ? .off : .on
        menu.addItem(allow)
        let start = action("Auto-Start Mobile Hotspot", #selector(toggleHotspot))
        start.image = Icons.hotspot()
        start.state = HotspotFallbackSettings.isEnabled ? .on : .off
        menu.addItem(start)
        if let r = roaming.reading {
            let stop = action("Auto-Stop Mobile Hotspot Below \(String(format: "%.0f", Double(r.reserve) / 1e9)) GB"
                              + (r.guardOff ? " (off until reset)" : ""), #selector(toggleGuard))
            stop.image = Icons.hotspotOff()
            stop.state = r.guardOff ? .off : .on
            menu.addItem(stop)
        }
    }

    // MARK: - Rows

    /// Greyed: a readout, nothing to click.
    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        return item
    }

    /// The menu bar's cable glyph (◀ ‐ ‐ ▶), tinted with the link's state:
    /// green with an address, yellow cable-in-no-IP, grey unplugged.
    static func wiredRowIcon(_ state: WiredLinkState) -> NSImage? {
        let color: NSColor = switch WiredLinkPolicy.tint(state) {
        case .green: .systemGreen
        case .yellow: .systemYellow
        case .gray: .systemGray
        }
        return Icons.tinted(Icons.wired(), color)
    }

    /// `GET /test/menu/open?close=N` — open as a click would, closing itself:
    /// the close is armed before opening, since nothing else reaches the main
    /// thread while the menu tracks.
    func openForTest(closeAfter seconds: TimeInterval) {
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in self?.menu.cancelTracking() }
        RunLoop.main.add(timer, forMode: .common)
        statusItem.button?.performClick(nil)
    }

    /// `GET /test/icon` — the icon as it is now, 8×, on a light and a dark bar.
    /// `wired=1` renders the cable glyph and the three tinted row icons instead.
    func renderIconForTest(wired: Bool = false) -> String? {
        guard let current = statusItem.button?.image else { return nil }
        let icon = wired ? Icons.wired() : current
        let scale: CGFloat = 8, pad: CGFloat = 4
        let cell = NSSize(width: (icon.size.width + 2 * pad) * scale, height: (icon.size.height + 2 * pad) * scale)
        let out = NSImage(size: NSSize(width: cell.width * 2, height: cell.height))
        out.lockFocus()
        for (i, name) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                (i == 0 ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.16, alpha: 1)).setFill()
                let r = NSRect(x: CGFloat(i) * cell.width, y: 0, width: cell.width, height: cell.height)
                r.fill()
                let img = icon.isTemplate ? Icons.tinted(icon, .labelColor) : icon
                img.draw(in: NSRect(x: r.minX + pad * scale, y: pad * scale,
                                    width: icon.size.width * scale, height: icon.size.height * scale))
                if wired {
                    for (k, state) in [WiredLinkState.connected(ip: ""), .noAddress, .disconnected].enumerated() {
                        Self.wiredRowIcon(state)?.draw(in: NSRect(x: r.minX + 6 + CGFloat(k) * 62, y: 6, width: 40, height: 32))
                    }
                    Icons.hotspot().map { Icons.tinted($0, .labelColor) }?
                        .draw(in: NSRect(x: r.maxX - 60, y: 4, width: 48, height: 48))
                }
            }
        }
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return nil }
        let url = Config.directory.appendingPathComponent("icon-test.png")
        try? png.write(to: url)
        return url.path
    }

    // MARK: - Vodafone (the phone dials, the Mac decides)

    private(set) var vodafone: VodafoneBalance?
    private var askedVodafoneAt: Date?
    private static let appliedKey = "Vodafone.appliedReceived"
    private static let askedKey = "Vodafone.lastAsked"

    /// Every `/status` carries the phone's last Vodafone SMS; a new one is applied
    /// once — the remaining GB come from Vodafone, never from a dialog.
    func vodafoneArrived(_ v: VodafoneBalance) {
        vodafone = v
        let applied = UserDefaults.standard.double(forKey: Self.appliedKey)
        guard v.received.timeIntervalSince1970 > applied, let r = roaming.reading, let plan = r.planMb else { return }
        let adjust = VodafonePolicy.adjustMb(v, planMb: plan, usedNowBytes: r.cycleTotal)
        netInfo("📶 Vodafone says \(Double(v.remainingMb) / 1000) GB left (data of \(v.at)) → adjust \(adjust) MB")
        UserDefaults.standard.set(v.received.timeIntervalSince1970, forKey: Self.appliedKey)
        askedVodafoneAt = nil
        send(["adjustMb": "\(adjust)"], what: "Vodafone's \(Double(v.remainingMb) / 1000) GB")
    }

    @objc private func askVodafone() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.askedKey)
        askedVodafoneAt = Date()
        netInfo("📶 asking Vodafone (*123#) through the phone")
        phone.askVodafone { answer, error in
            netInfo("📶 *123# → \(answer ?? error ?? "?") — the balance follows by SMS")
        }
    }

    @objc private func toggleGuard() {
        let off = !(roaming.reading?.guardOff ?? false)
        send(["guardOff": off ? "1" : "0"], what: off ? "protection off until reset" : "protection on")
    }

    private func send(_ params: [String: String], what: String) {
        phone.configure(params) { reading, error in
            if let error {
                netError("📶 roaming setting (\(what)) not sent: \(error)")
            } else {
                netInfo("📶 roaming setting sent: \(what) → \(reading.map { RoamingWarningPolicy.gb($0.remaining) } ?? "?") left")
            }
        }
    }

    // MARK: - Actions

    @objc private func speedTestAction() {
        traffic.runSpeedTest { _ in }
    }

    @objc private func toggleHotspot() {
        HotspotFallbackSettings.isEnabled.toggle()
        netInfo("🛜 Auto Mobile Hotspot \(HotspotFallbackSettings.isEnabled ? "on" : "off")")
    }

    @objc private func toggleSuspend() {
        RoamingDataSettings.suspendClaude.toggle()
        netInfo("⏸️ Pause Claude on roaming data \(RoamingDataSettings.suspendClaude ? "on" : "off")")
        onRoamingSuspendToggled?()
    }

    @objc private func quitAction() { NSApp.terminate(nil) }
}

/// Small modal questions. The app has no window, so it is brought forward first.
enum Prompt {
    static func password(_ title: String, _ text: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Join")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    static func show(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }


}
