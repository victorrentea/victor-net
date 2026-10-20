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
/// **Every roaming setting is made here**, not on the phone (*"the application
/// on the mobile shouldn't do anything really"*): plan, reset day, an extra
/// package, "Vodafone says N GB left", protection off until the reset. They are
/// sent to the phone (`PhoneLink.configure`), which keeps them because it is the
/// one counting and refusing the hotspot.
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
        // No Wired / Wi-Fi / Phone status rows (Victor, 2026-10-20: the icon and
        // the ✓ in the list below already say it). The cable is the list's first
        // row, always.
        // Every network in reach, one row each, in the main menu; ✓ on the one
        // in use, a click on another joins it.
        networkRows().forEach(menu.addItem)
        menu.addItem(action(speedTitle(), #selector(speedTestAction)))
        menu.addItem(.separator())

        if Config.hasPhone {
            menu.addItem(.separator())
            addRoamingRows()
            menu.addItem(.separator())
            menu.addItem(action(HotspotMenu.title(enabled: HotspotFallbackSettings.isEnabled), #selector(toggleHotspot)))
            menu.addItem(action(RoamingSuspendMenu.title(enabled: RoamingDataSettings.suspendClaude), #selector(toggleSuspend)))
        }

        menu.addItem(.separator())
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
            records["wifi:\(ssid)"] = NetworkRecord(name: (hotspot ? "📱 " : "🛜 ") + ssid,
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
        header.attributedTitle = Self.row(["network", "↓ best", "↑ best", "latency", "last seen"], header: true)
        header.isEnabled = false
        let rate = TrafficPolicy.mbps
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
            let name = key == "wired" ? "Ethernet" : r.name
            item.attributedTitle = Self.row([name, r.maxDown > 0 ? rate(r.maxDown) : "—", r.maxUp > 0 ? rate(r.maxUp) : "—",
                                             r.latencyMs.map { String(format: "%.0f ms", $0) } ?? "—", seen], header: false)
            if key == "wired" { item.image = Self.wiredRowIcon(net.wired) }
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
        style.tabStops = [230, 310, 370, 440].map { NSTextTab(textAlignment: .right, location: $0) }
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

    private func addRoamingRows() {
        let gb = RoamingWarningPolicy.gb
        guard let r = roaming.reading else {
            menu.addItem(info("📶 Roaming: the phone has not answered yet"))
            menu.addItem(action("Ask the phone now", #selector(askNow)))
            return
        }
        let left = roamingLeft ?? r.remaining
        let alert = RoamingAlertPolicy.alert(r, left: left, now: Date())
        let mark = alert == .capped ? "⛔" : alert == .low ? "⚠️" : "📶"
        let reset = DateFormatter.localizedString(from: r.nextReset, dateStyle: .medium, timeStyle: .none)
        menu.addItem(info("\(mark) Roaming: \(gb(left)) left of \(gb(r.limit)) · resets \(reset)"))
        let age = NetworkBookPolicy.ago(r.readAt, now: Date())
        menu.addItem(info("    \(r.roamingNow ? "roaming now" : "home network") · used \(gb(r.cycleTotal)) · read \(age)"))

        // The plan's settings, right in the main menu (Victor, 2026-10-20).
        let sub = menu
        let plan = r.planMb.map { gb($0 * 1_000_000) } ?? "?"
        sub.addItem(action("Monthly plan: \(plan) …", #selector(setPlan)))
        sub.addItem(action("Resets on day \(r.resetDay.map(String.init) ?? "?") …", #selector(setResetDay)))
        let extra = r.adjust == 0 ? "none" : (r.adjust > 0 ? "+" : "") + gb(r.adjust)
        sub.addItem(action("Extra this cycle: \(extra) — add a package …", #selector(addPackage)))
        sub.addItem(action("Vodafone says remaining is …", #selector(setRemaining)))
        sub.addItem(action("Ask Vodafone (*123#)", #selector(askVodafone)))
        sub.addItem(action(r.guardOff ? "🔓 Hotspot protection off until the reset — turn back on"
                                      : "🔒 Hotspot protection on (keeps \(gb(r.reserve))) — turn off until reset",
                           #selector(toggleGuard)))
        sub.addItem(action("Ask the phone now", #selector(askNow)))
        if !net.onHotspot {
            sub.addItem(info("    changes reach the phone only over its hotspot"))
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

    // MARK: - Roaming settings (sent to the phone)

    @objc private func setPlan() {
        guard let gb = Prompt.number("Monthly roaming plan", "GB per month, as Vodafone states it (e.g. 13.38).",
                                     initial: roaming.reading?.planMb.map { Double($0) / 1000 }) else { return }
        send(["planMb": "\(Int64((gb * 1000).rounded()))"], what: "plan \(gb) GB")
    }

    @objc private func setResetDay() {
        guard let day = Prompt.number("Plan resets on day", "Day of the month (1–31).",
                                      initial: roaming.reading?.resetDay.map(Double.init)),
              (1...31).contains(Int(day)) else { return }
        send(["resetDay": "\(Int(day))"], what: "reset day \(Int(day))")
    }

    @objc private func addPackage() {
        guard let gb = Prompt.number("Add a roaming package", "GB bought for this cycle; added to what is left.",
                                     initial: nil), let r = roaming.reading else { return }
        let adjustMb = r.adjust / 1_000_000 + Int64((gb * 1000).rounded())
        send(["adjustMb": "\(adjustMb)"], what: "+\(gb) GB this cycle")
    }

    /// remaining = plan + adjust − used ⇒ adjust = remaining − plan + used.
    @objc private func setRemaining() {
        guard let gb = Prompt.number("Vodafone says remaining is", "GB left this cycle, from *123# or the My Vodafone app.",
                                     initial: nil) else { return }
        applyRemaining(Int64((gb * 1000).rounded()))
    }

    private func applyRemaining(_ mb: Int64) {
        guard let r = roaming.reading, let plan = r.planMb else { return }
        send(["adjustMb": "\(mb - plan + r.cycleTotal / 1_000_000)"], what: "remaining \(Double(mb) / 1000) GB")
    }

    @objc private func toggleGuard() {
        let off = !(roaming.reading?.guardOff ?? false)
        send(["guardOff": off ? "1" : "0"], what: off ? "protection off until reset" : "protection on")
    }

    @objc private func askVodafone() {
        netInfo("📶 asking Vodafone (*123#) through the phone")
        phone.askVodafone { [weak self] answer, error in
            guard let answer else { return Prompt.show("Vodafone did not answer", error ?? "?") }
            netInfo("📶 *123# → \(answer)")
            if let mb = UssdPolicy.megabytes(in: answer) {
                if Prompt.confirm("Vodafone says", answer, ok: "Use \(Double(mb) / 1000) GB as remaining") {
                    self?.applyRemaining(mb)
                }
            } else {
                Prompt.show("Vodafone says", answer)
            }
        }
    }

    private func send(_ params: [String: String], what: String) {
        phone.configure(params) { reading, error in
            if let error {
                netError("📶 roaming setting (\(what)) not sent: \(error)")
                Prompt.show("Not sent to the phone", "\(what): \(error)")
            } else {
                netInfo("📶 roaming setting sent: \(what) → \(reading.map { RoamingWarningPolicy.gb($0.remaining) } ?? "?") left")
            }
        }
    }

    // MARK: - Actions

    @objc private func speedTestAction() {
        traffic.runSpeedTest { _ in }
    }

    @objc private func askNow() {
        lastAskedAt = Date()
        roaming.pollNow()
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

/// `*123#`'s answer → the first "N GB" / "N MB" in it. Not applied by itself: the
/// exact wording is not known yet, and a wrong number would disarm the reserve.
enum UssdPolicy {
    static func megabytes(in text: String) -> Int64? {
        guard let m = text.range(of: #"(\d+(?:[.,]\d+)?)\s*(GB|MB)"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let match = String(text[m])
        let digits = match.prefix { $0.isNumber || $0 == "." || $0 == "," }.replacingOccurrences(of: ",", with: ".")
        let number = Double(digits) ?? 0
        return Int64((match.uppercased().hasSuffix("GB") ? number * 1000 : number).rounded())
    }
}

/// Small modal questions. The app has no window, so it is brought forward first.
enum Prompt {
    static func number(_ title: String, _ text: String, initial: Double?) -> Double? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        if let initial { field.stringValue = String(format: "%g", initial) }
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return Double(field.stringValue.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }

    static func show(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    static func confirm(_ title: String, _ text: String, ok: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: ok)
        alert.addButton(withTitle: "Close")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
