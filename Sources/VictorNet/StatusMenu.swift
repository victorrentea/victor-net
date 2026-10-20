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
        button.image = Icons.image(for: look)
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

        if let since = traffic.offlineSince, Date().timeIntervalSince(since) >= 5 {
            menu.addItem(info("📵 Offline \(NetworkBookPolicy.duration(Date().timeIntervalSince(since)))"))
        }
        // Networks, the way macOS lists them: the ones worth comparing as a
        // table (✓ = in use, click = join), then everything else in range, then
        // the Wi-Fi switch. No status rows above: the icon and the ✓ say it.
        menu.addItem(wifiSwitchRow())
        menu.addItem(.separator())
        networkRows().forEach(menu.addItem)
        menu.addItem(otherNetworksRow())

        // Everything about roaming, together.
        if Config.hasPhone {
            menu.addItem(.separator())
            addRoamingRows()
            let hotspot = action("Auto-start Mobile Hotspot", #selector(toggleHotspot))
            hotspot.image = Icons.hotspot()
            hotspot.state = HotspotFallbackSettings.isEnabled ? .on : .off
            menu.addItem(hotspot)
        }

        menu.addItem(.separator())
        menu.addItem(action(speedTitle(), #selector(speedTestAction)))
        menu.addItem(action("Wi-Fi Settings…", #selector(openWifiSettings)))
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
        let rssi = Dictionary(net.scanResults().map { ($0.ssid, $0.rssi) }, uniquingKeysWith: max)

        var items = [NSMenuItem(view: MenuRowView(name: "best today", columns: ["↓" + unit.name, "↑" + unit.name, "ms", "seen"], header: true))]
        // Ethernet: always listed, greyed when there is no cable.
        if traffic.network?.key != "wired" {
            items.append(NSMenuItem(view: MenuRowView(name: "Ethernet", icon: Icons.wired(), enabled: false, dimmed: true)))
        }
        for (key, r) in shown {
            let ssid = key.hasPrefix("wifi:") ? String(key.dropFirst(5)) : nil
            let current = key == traffic.network?.key
            let icon: NSImage?
            if key == "wired" { icon = Icons.wired() }
            else if ssid == Config.hotspotSSID { icon = Icons.phone() }
            else {
                let level = ssid == net.ssid ? net.rssi : ssid.flatMap { rssi[$0] }
                icon = Icons.wifi(strength: level.map(NetworkLookPolicy.strength(rssi:)) ?? 0)
            }
            let seen = r.lastSeen == .distantPast ? "—" : NetworkBookPolicy.since(r.lastSeen, now: now)
            let row = MenuRowView(name: ssid ?? "Ethernet",
                                  columns: [rate(r.maxDown), rate(r.maxUp), r.latencyMs.map { String(format: "%.0f", $0) } ?? "—", seen],
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
        let row = MenuRowView(name: "Other Networks", trailing: NSImage(systemSymbolName: othersExpanded ? "chevron.down" : "chevron.right",
                                                                    accessibilityDescription: nil))
        row.keepsMenuOpen = true
        row.onClick = { [weak self] in self?.toggleOthers() }
        let item = NSMenuItem(view: row)
        othersAnchor = item
        return item
    }

    private func toggleOthers() {
        othersExpanded.toggle()
        if let anchor = othersAnchor, let i = menu.items.firstIndex(of: anchor) {
            menu.removeItem(at: i)
            menu.insertItem(otherNetworksRow(), at: i)
        }
        refreshOthers()
        if othersExpanded {
            net.scanInBackground()
            let t = Timer(timeInterval: 8, repeats: true) { [weak self] _ in
                self?.net.scanInBackground()
                self?.refreshOthers()
            }
            RunLoop.main.add(t, forMode: .common)
            rescanTimer = t
        } else {
            rescanTimer?.invalidate()
            rescanTimer = nil
        }
    }

    private func refreshOthers() {
        otherRows.forEach { menu.removeItem($0) }
        otherRows = []
        guard othersExpanded, let anchor = othersAnchor, var at = menu.items.firstIndex(of: anchor) else { return }
        let listed = Set(traffic.book.records.keys.filter { $0.hasPrefix("wifi:") }.map { String($0.dropFirst(5)) })
            .union(net.knownSSIDs())
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
        for r in rows {
            at += 1
            menu.insertItem(r, at: at)
        }
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
        let gb = RoamingWarningPolicy.gb
        if let r = roaming.reading {
            let left = roamingLeft ?? r.remaining
            let alert = RoamingAlertPolicy.alert(r, left: left, now: Date())
            let mark = alert == .capped ? "⛔" : alert == .low ? "⚠️" : "📶"
            menu.addItem(info("\(mark) Roaming: \(gb(left)) left of \(gb(left + r.cycleTotal))"))
            let day = DateFormatter()
            day.dateFormat = "d MMM"
            var detail = "    " + (vodafone.map { "Vodafone, \(NetworkBookPolicy.ago($0.at, now: Date()))" } ?? "phone's count")
            detail += " · resets " + day.string(from: r.nextReset)
            menu.addItem(info(detail))
        } else {
            menu.addItem(info("📶 Roaming: the phone has not answered yet"))
        }
        let asking = askedVodafoneAt.map { Date().timeIntervalSince($0) < 180 } ?? false
        let ask = action(asking ? "Asking Vodafone… (the answer comes by SMS)" : "Ask Vodafone for what is left", #selector(askVodafone))
        ask.isEnabled = !asking
        menu.addItem(ask)
        if let r = roaming.reading {
            let guardItem = action("🔒 Auto-stop hotspot at \(gb(r.reserve)) left" + (r.guardOff ? " (off until the reset)" : ""),
                                   #selector(toggleGuard))
            guardItem.state = r.guardOff ? .off : .on
            menu.addItem(guardItem)
        }
        let pause = action("⏸️ Pause Claude on roaming", #selector(toggleSuspend))
        pause.state = RoamingDataSettings.suspendClaude ? .on : .off
        menu.addItem(pause)
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
