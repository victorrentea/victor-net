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

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        net.refresh()

        if let since = traffic.offlineSince, Date().timeIntervalSince(since) >= 5 {
            menu.addItem(info("📵 Offline \(NetworkBookPolicy.duration(Date().timeIntervalSince(since)))"))
        }
        // Networks, the way macOS lists them: the ones worth comparing as a
        // table (✓ = in use, click = join), then everything else in range, then
        // the Wi-Fi switch. No status rows above: the icon and the ✓ say it.
        networkRows().forEach(menu.addItem)
        menu.addItem(otherNetworksItem())
        let wifi = action("Wi-Fi", #selector(toggleWifi))
        wifi.state = net.wifiPower ? .on : .off
        menu.addItem(wifi)

        // Everything about roaming, together.
        if Config.hasPhone {
            menu.addItem(.separator())
            addRoamingRows()
            let hotspot = action("🛜 Auto-start Mobile Hotspot", #selector(toggleHotspot))
            hotspot.state = HotspotFallbackSettings.isEnabled ? .on : .off
            menu.addItem(hotspot)
        }

        menu.addItem(.separator())
        menu.addItem(action(speedTitle(), #selector(speedTestAction)))
        menu.addItem(action("Wi-Fi Settings…", #selector(openWifiSettings)))
        menu.addItem(info("Built \(BuildInfo.time)"))
        let quit = action("Quit", #selector(quitAction))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func speedTitle() -> String {
        if traffic.speedTestRunning { return "⚡ Testing speed…" }
        let mb = traffic.network?.kind == "hotspot" ? 10 : 25
        if let key = traffic.network?.key, let r = traffic.book.records[key], let s = r.speedDown, let at = r.speedAt {
            return "⚡ Test speed (\(mb) MB) — last \(TrafficPolicy.mbps(s)), \(NetworkBookPolicy.ago(at, now: Date()))"
        }
        return "⚡ Test speed (downloads \(mb) MB)"
    }

    /// The networks to compare, as clickable rows (Victor, 2026-10-20): every
    /// Wi-Fi **in range** that this Mac knows or has measured, plus the cable
    /// while it carries the traffic. One out of range drops off the list, but
    /// its numbers stay in the book and come back with it. ✓ marks the one in
    /// use; a click on another joins it.
    ///
    /// Rows, not a grid view, because a grid row cannot be clicked; the columns
    /// are tab stops in the attributed title.
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
            let hotspot = ssid == Config.hotspotSSID
            records["wifi:\(ssid)"] = NetworkRecord(name: ssid,
                                                    kind: hotspot ? "hotspot" : "wifi", lastSeen: .distantPast)
        }
        let shown = records.filter { key, _ in
            if key == traffic.network?.key { return true }
            guard key.hasPrefix("wifi:") else { return false }
            return reachable.contains(String(key.dropFirst(5)))
        }.sorted { a, b in
            a.key == traffic.network?.key ? true : b.key == traffic.network?.key ? false
                : (a.value.maxDown, b.key) > (b.value.maxDown, a.key)
        }
        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        header.attributedTitle = Self.row(["best of the day", "↓ MB/s", "↑ MB/s", "ping", "seen"], header: true)
        header.isEnabled = false
        let rate: (Double) -> String = { String(format: "%.2f", $0 / 1_000_000) }
        let rssi = Dictionary(net.scanResults().map { ($0.ssid, $0.rssi) }, uniquingKeysWith: max)
        // The cable, always listed: its numbers while it carries the traffic,
        // otherwise what state it is in.
        let wiredRow: NSMenuItem
        if traffic.network?.key == "wired" {
            wiredRow = NSMenuItem()   // filled by the loop below, as the current network
        } else {
            wiredRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            let state = net.wired == .disconnected ? "not connected" : WiredLinkPolicy.title(net.wired)
                .replacingOccurrences(of: "Wired: ", with: "")
            wiredRow.attributedTitle = Self.row(["Ethernet", state], header: false, dimmed: true)
            wiredRow.image = Self.wiredRowIcon(net.wired)
            wiredRow.isEnabled = false
        }
        let rows = shown.map { key, r -> NSMenuItem in
            let seen = r.lastSeen == .distantPast ? "never" : NetworkBookPolicy.since(r.lastSeen, now: now)
            let item = NSMenuItem(title: r.name, action: nil, keyEquivalent: "")
            let ssid = key.hasPrefix("wifi:") ? String(key.dropFirst(5)) : nil
            let name = ssid ?? "Ethernet"
            item.attributedTitle = Self.row([name, r.maxDown > 0 ? rate(r.maxDown) : "—", r.maxUp > 0 ? rate(r.maxUp) : "—",
                                             r.latencyMs.map { String(format: "%.0f", $0) } ?? "—", seen], header: false)
            if key == "wired" {
                item.image = Self.wiredRowIcon(net.wired)
            } else if ssid == Config.hotspotSSID {
                item.image = Icons.hotspot()
            } else if let ssid {
                let level = ssid == net.ssid ? net.rssi : rssi[ssid]
                item.image = Icons.wifi(strength: level.map(NetworkLookPolicy.strength(rssi:)) ?? 0)
            }
            let current = key == traffic.network?.key
            item.state = current ? .on : .off
            if !current, key.hasPrefix("wifi:") {
                item.action = #selector(joinNetwork(_:))
                item.target = self
                item.representedObject = String(key.dropFirst(5))
                item.isEnabled = true
            } else {
                item.isEnabled = current
            }
            return item
        }
        return [header] + (traffic.network?.key == "wired" ? [] : [wiredRow]) + rows
    }

    /// Name, then four right-aligned numeric columns on tab stops.
    private static func row(_ cols: [String], header: Bool, dimmed: Bool = false) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        // Narrow (Victor, 2026-10-20): numbers only, the unit is in the header.
        style.tabStops = [175, 220, 260, 305].map { NSTextTab(textAlignment: .right, location: $0) }
        let size = NSFont.systemFontSize - (header ? 2 : 0)
        return NSAttributedString(string: cols.joined(separator: "\t"), attributes: [
            .font: header ? NSFont.systemFont(ofSize: size, weight: .medium)
                          : NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular),
            .foregroundColor: header ? NSColor.tertiaryLabelColor : dimmed ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .paragraphStyle: style,
        ])
    }

    @objc private func joinNetwork(_ sender: NSMenuItem) {
        guard let ssid = sender.representedObject as? String else { return }
        netInfo("🛜 joining \(ssid)")
        net.join(ssid) { error in
            if let error {
                netError("🛜 could not join \(ssid): \(error)")
                Prompt.show("Could not join \(ssid)", error)
            } else {
                netInfo("🛜 joined \(ssid)")
            }
        }
    }

    /// Everything else in range, strongest first, as macOS shows it: the Wi-Fi
    /// arcs at the network's strength, 🔒 when it has a password. A click joins
    /// — asking for the password only for a secured network this Mac doesn't know.
    private func otherNetworksItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Other Networks", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let listed = Set(traffic.book.records.keys.filter { $0.hasPrefix("wifi:") }.map { String($0.dropFirst(5)) })
            .union(net.knownSSIDs())
        let others = net.scanResults().filter { !listed.contains($0.ssid) && $0.ssid != net.ssid }
        if others.isEmpty { sub.addItem(info(net.wifiPower ? "Nothing else in range" : "Wi-Fi is off")) }
        for n in others {
            let row = action(n.ssid + (n.secure ? "  🔒" : ""), #selector(joinOther(_:)))
            row.image = Icons.wifi(strength: NetworkLookPolicy.strength(rssi: n.rssi))
            row.representedObject = [n.ssid, n.secure ? "1" : "0"]
            sub.addItem(row)
        }
        item.submenu = sub
        return item
    }

    @objc private func joinOther(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        let (ssid, secure) = (pair[0], pair[1] == "1")
        var password: String?
        if secure {
            guard let pw = Prompt.password("Join “\(ssid)”", "The Wi-Fi password.") else { return }
            password = pw
        }
        netInfo("🛜 joining \(ssid)")
        net.join(ssid, password: password) { error in
            if let error { Prompt.show("Could not join \(ssid)", error) } else { netInfo("🛜 joined \(ssid)") }
        }
    }

    @objc private func toggleWifi() {
        let on = !net.wifiPower
        net.setWifiPower(on) { error in
            netInfo("🛜 Wi-Fi \(on ? "on" : "off")\(error.map { " — \($0)" } ?? "")")
        }
    }

    @objc private func openWifiSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!)
    }

    private func addRoamingRows() {
        let gb = RoamingWarningPolicy.gb
        if let r = roaming.reading {
            let left = roamingLeft ?? r.remaining
            let alert = RoamingAlertPolicy.alert(r, left: left, now: Date())
            let mark = alert == .capped ? "⛔" : alert == .low ? "⚠️" : "📶"
            let source = vodafone.map { "Vodafone \(NetworkBookPolicy.ago($0.at, now: Date()))" } ?? "the phone's count"
            menu.addItem(info("\(mark) Roaming: \(gb(left)) left · per \(source)"))
            var detail = "    used \(gb(r.cycleTotal)) this cycle · resets " +
                DateFormatter.localizedString(from: r.nextReset, dateStyle: .medium, timeStyle: .none)
            if let until = vodafone?.validUntil {
                detail += " · package until " + DateFormatter.localizedString(from: until, dateStyle: .medium, timeStyle: .none)
            }
            menu.addItem(info(detail))
        } else {
            menu.addItem(info("📶 Roaming: the phone has not answered yet"))
        }
        let asking = askedVodafoneAt.map { Date().timeIntervalSince($0) < 180 } ?? false
        let ask = action(asking ? "Asking Vodafone… (the answer comes by SMS)" : "Ask Vodafone for what is left", #selector(askVodafone))
        ask.isEnabled = !asking
        menu.addItem(ask)
        if let r = roaming.reading {
            // Unticking turns it off until the reset; it comes back by itself then.
            let guardItem = action("🔒 Hotspot protection — keeps \(gb(r.reserve))" + (r.guardOff ? " (off until the reset)" : ""),
                                   #selector(toggleGuard))
            guardItem.state = r.guardOff ? .off : .on
            menu.addItem(guardItem)
        }
        let pause = action("⏸️ Pause Claude on roaming data", #selector(toggleSuspend))
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
