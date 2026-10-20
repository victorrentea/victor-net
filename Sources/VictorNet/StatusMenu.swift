import AppKit

/// The menu bar switches: state in the title (a trailing ✓), not the item's
/// native tick — one ticked row makes AppKit reserve a check column for the
/// whole menu and nudges every row's emoji to the right.
enum HotspotMenu {
    static func title(enabled: Bool) -> String { "🛜 Auto Mobile Hotspot" + (enabled ? "  ✓" : "") }
}

enum RoamingSuspendMenu {
    static func title(enabled: Bool) -> String { "⏸️ Pause Claude on roaming data" + (enabled ? "  ✓" : "") }
}

/// The one status item: the network icon (see `NetworkLook`), followed by the
/// roaming allowance in GB while the Mac is on the phone's hotspot abroad
/// (`RoamingMeterPolicy` — orange under 3 GB, red under 1.5 GB, 📵 once the
/// phone refuses the hotspot). That number was its own status item in Victor
/// Addons; here it rides next to the bars it is about.
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

    // The live rows, repainted every second while the menu is open.
    private var downItem: NSMenuItem?
    private var upItem: NSMenuItem?
    private var latencyItem: NSMenuItem?
    private var appItems: [NSMenuItem] = []
    private var speedItem: NSMenuItem?
    private var isOpen = false

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
        // Off the hotspot's HTTP channel (an old phone app), fall back to asking
        // over Bluetooth every 5 minutes while the number matters.
        if net.onHotspot, phone.signal == nil, now.timeIntervalSince(lastAskedAt) > 300 {
            lastAskedAt = now
            roaming.pollNow()
        }
        refreshIcon()
        if isOpen { refreshLiveRows() }
    }

    func refreshIcon() {
        guard let button = statusItem.button else { return }
        button.image = Icons.image(for: net.look)
        button.imagePosition = .imageLeading
        let r = roaming.reading
        guard RoamingMeterPolicy.visible(onHotspot: net.onHotspot, reading: r, now: Date()) else {
            button.attributedTitle = NSAttributedString(string: "")
            return
        }
        let since = r.map { hotspotCounter.since($0.readAt) } ?? 0
        let d = RoamingMeterPolicy.display(r, macBytesSince: since, now: Date())
        // The bars already say "phone"; 📵 stays, it is the one state that changes what to do.
        let text = " " + d.title.replacingOccurrences(of: "📶 ", with: "")
        let color: NSColor? = switch d.tint {
        case .normal: nil
        case .orange: .systemOrange
        case .red: .systemRed
        }
        var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.menuBarFont(ofSize: 0)]
        if let color { attrs[.foregroundColor] = color }
        button.attributedTitle = NSAttributedString(string: text, attributes: attrs)
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
        traffic.apps.onBlock = { [weak self] in self?.refreshLiveRows() }
        traffic.apps.start()
    }

    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
        traffic.apps.onBlock = nil
        traffic.apps.stop()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        net.refresh()

        // Where the bytes go.
        let wired = net.wired
        let wiredItem = info(WiredLinkPolicy.title(wired))
        wiredItem.image = Self.wiredRowIcon(wired)
        menu.addItem(wiredItem)
        menu.addItem(info(NetworkLookPolicy.wifiRow(ssid: net.ssid, rssi: net.rssi)))
        if Config.hasPhone {
            menu.addItem(info(NetworkLookPolicy.phoneRow(phone.signal, onHotspot: net.onHotspot)))
        }
        menu.addItem(.separator())

        // A run of failed handshakes, from the second one (≥ 5 s): one lost
        // probe on a busy link is not "offline".
        if let since = traffic.offlineSince, Date().timeIntervalSince(since) >= 5 {
            menu.addItem(info("📵 Offline \(NetworkBookPolicy.duration(Date().timeIntervalSince(since)))"))
        }

        // How well, on this network.
        menu.addItem(info("📈 \(traffic.network?.name ?? "No network") — 5 s average · best in 10 min"))
        downItem = info("")
        upItem = info("")
        latencyItem = info("")
        [downItem, upItem, latencyItem].compactMap { $0 }.forEach(menu.addItem)
        let speed = action(speedTitle(), #selector(speedTestAction))
        speedItem = speed
        menu.addItem(speed)
        menu.addItem(otherNetworksItem())
        menu.addItem(.separator())

        menu.addItem(info("Busiest apps — 5 s average"))
        appItems = (0..<3).map { _ in info("") }
        appItems.forEach(menu.addItem)
        refreshLiveRows()

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

    private func refreshLiveRows() {
        let rate = TrafficPolicy.rate
        func dash(_ v: Double?) -> String { v.map(rate) ?? "—" }
        let downMax = traffic.down.maxAverage ?? 0, upMax = traffic.up.maxAverage ?? 0
        downItem?.attributedTitle = Self.columns(["↓ In", dash(traffic.down.average), "max \(dash(traffic.down.maxAverage))"])
        downItem?.image = Icons.bars(traffic.down.recent(20), scale: downMax)
        upItem?.attributedTitle = Self.columns(["↑ Out", dash(traffic.up.average), "max \(dash(traffic.up.maxAverage))"])
        upItem?.image = Icons.bars(traffic.up.recent(20), scale: upMax)
        let ms: (Double?) -> String = { $0.map { String(format: "%.0f ms", $0) } ?? "—" }
        latencyItem?.attributedTitle = Self.columns(["⏱️ Latency", ms(traffic.latencyRecent), "best \(ms(traffic.latencyBest))"])

        let top = traffic.apps.top()
        for (i, item) in appItems.enumerated() {
            if i < top.count {
                item.attributedTitle = Self.columns([top[i].0, "↓ \(rate(top[i].1))", "↑ \(rate(top[i].2))"])
                item.isHidden = false
            } else {
                item.attributedTitle = Self.columns([i == 0 ? (traffic.apps.isRunning ? "measuring…" : "—") : "", "", ""])
                item.isHidden = i > 0
            }
        }
        speedItem?.title = speedTitle()
    }

    private func speedTitle() -> String {
        if traffic.speedTestRunning { return "⚡ Testing speed…" }
        let mb = traffic.network?.kind == "hotspot" ? 10 : 25
        if let key = traffic.network?.key, let r = traffic.book.records[key], let s = r.speedDown, let at = r.speedAt {
            return "⚡ Test speed (\(mb) MB) — last \(TrafficPolicy.rate(s)), \(NetworkBookPolicy.ago(at, now: Date()))"
        }
        return "⚡ Test speed (downloads \(mb) MB)"
    }

    private func otherNetworksItem() -> NSMenuItem {
        let item = NSMenuItem(title: "🗂️ Other networks", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let now = Date()
        let rows = traffic.book.records.sorted { $0.value.lastSeen > $1.value.lastSeen }
        if rows.isEmpty { sub.addItem(info("Nothing measured yet")) }
        for (key, r) in rows {
            let row = info(NetworkBookPolicy.line(r, now: now))
            if key == traffic.network?.key { row.attributedTitle = Self.bold(row.title) }
            sub.addItem(row)
        }
        sub.addItem(.separator())
        sub.addItem(info("max = best 5 s average seen today · ⚡ = last speed test"))
        item.submenu = sub
        return item
    }

    private func addRoamingRows() {
        let gb = RoamingWarningPolicy.gb
        if let r = roaming.reading {
            let since = hotspotCounter.since(r.readAt)
            let time = DateFormatter.localizedString(from: r.readAt, dateStyle: .none, timeStyle: .short)
            menu.addItem(info("📶 Roaming left: \(gb(RoamingMeterPolicy.estimate(r, macBytesSince: since))) of \(gb(r.limit))"))
            menu.addItem(info("Phone said \(gb(r.remaining)) at \(time) · this Mac pulled \(gb(since)) since"))
            menu.addItem(info("Resets \(DateFormatter.localizedString(from: r.nextReset, dateStyle: .medium, timeStyle: .none))"))
            if r.guardOff {
                menu.addItem(info("🔓 Protection off on the phone until the reset"))
            } else {
                menu.addItem(info(r.hotspotBlocked
                    ? "📵 Under the phone's \(gb(r.reserve)) reserve — it refuses the hotspot"
                    : "The phone refuses the hotspot under \(gb(r.reserve)) left, while roaming"))
            }
        } else {
            menu.addItem(info("📶 Roaming: the phone has not answered yet"))
        }
        menu.addItem(action("Ask the phone now", #selector(askNow)))
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

    /// Three columns on tab stops, digits monospaced, so the numbers line up
    /// from one second to the next instead of jittering.
    static func columns(_ cols: [String]) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: 120),
                          NSTextTab(textAlignment: .left, location: 215)]
        return NSAttributedString(string: cols.joined(separator: "\t"), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .paragraphStyle: style,
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    private static func bold(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
    }

    /// The Ethernet symbol, tinted with the link's state.
    static func wiredRowIcon(_ state: WiredLinkState) -> NSImage? {
        let color: NSColor = switch WiredLinkPolicy.tint(state) {
        case .green: .systemGreen
        case .yellow: .systemYellow
        case .gray: .systemGray
        }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: "network", accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    /// `GET /test/menu/open?close=N` — open as a click would, closing itself:
    /// the close is armed before opening, since nothing else reaches the main
    /// thread while the menu tracks.
    func openForTest(closeAfter seconds: TimeInterval) {
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in self?.menu.cancelTracking() }
        RunLoop.main.add(timer, forMode: .common)
        statusItem.button?.performClick(nil)
    }

    // MARK: - Actions

    @objc private func speedTestAction() {
        traffic.runSpeedTest { [weak self] _ in self?.refreshLiveRows() }
        refreshLiveRows()
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
