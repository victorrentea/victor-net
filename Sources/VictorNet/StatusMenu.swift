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

/// The one status item. **The menu bar shows the route and whether to worry,
/// nothing else** (Victor, 2026-10-20): the phone's bars on its hotspot, with
/// ⚠ under 5 GB of roaming left or a red ✕ once it is gone; the GB themselves
/// are in the menu.
///
/// **The menu is a snapshot**, taken when it opens: no number moves while it is
/// read (*"I don't really care about seeing live data. It distracts me."*). The
/// one exception is the busiest-apps table, which can only exist after `nettop`
/// has watched for a couple of seconds — it fills in once, then stays.
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
    private var appsItem: NSMenuItem?
    private var appsFilled = false

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
        appsFilled = false
        traffic.apps.onBlock = { [weak self] in self?.fillAppsOnce() }
        traffic.apps.start()
    }

    func menuDidClose(_ menu: NSMenu) {
        traffic.apps.onBlock = nil
        traffic.apps.stop()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        net.refresh()

        if let since = traffic.offlineSince, Date().timeIntervalSince(since) >= 5 {
            menu.addItem(info("📵 Offline \(NetworkBookPolicy.duration(Date().timeIntervalSince(since)))"))
        }
        let wiredItem = info(WiredLinkPolicy.title(net.wired))
        wiredItem.image = Self.wiredRowIcon(net.wired)
        menu.addItem(wiredItem)
        menu.addItem(info(NetworkLookPolicy.wifiRow(ssid: net.ssid, rssi: net.rssi)))
        if Config.hasPhone {
            menu.addItem(info(NetworkLookPolicy.phoneRow(phone.signal, onHotspot: net.onHotspot)))
        }
        menu.addItem(.separator())

        // This network, as a table.
        menu.addItem(info("📈 \(traffic.network?.name ?? "No network")"))
        let rate = TrafficPolicy.rate
        func r(_ v: Double?) -> String { v.map(rate) ?? "—" }
        func ms(_ v: Double?) -> String { v.map { String(format: "%.0f ms", $0) } ?? "—" }
        menu.addItem(MenuTable.item(header: ["", "5 s average", "best in 10 min"], rows: [
            ["↓ Download", r(traffic.down.average), r(traffic.down.maxAverage)],
            ["↑ Upload", r(traffic.up.average), r(traffic.up.maxAverage)],
            ["Latency", ms(traffic.latencyRecent), ms(traffic.latencyBest)],
        ]))
        menu.addItem(action(speedTitle(), #selector(speedTestAction)))
        menu.addItem(otherNetworksItem())
        menu.addItem(.separator())

        menu.addItem(info("Busiest apps — 5 s average"))
        let apps = MenuTable.item(header: nil, rows: [["measuring…", "", ""]])
        appsItem = apps
        menu.addItem(apps)

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

    /// The apps table, once, after nettop's first full block (~2 s).
    private func fillAppsOnce() {
        guard !appsFilled, let item = appsItem else { return }
        let top = traffic.apps.top()
        appsFilled = true
        let rows = top.isEmpty ? [["nothing is moving data", "", ""]]
            : top.map { [$0.0, "↓ " + TrafficPolicy.rate($0.1), "↑ " + TrafficPolicy.rate($0.2)] }
        item.view = MenuTable.view(header: nil, rows: rows)
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
        let item = NSMenuItem(title: "🗂️ Compare networks", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let now = Date()
        let records = traffic.book.records.sorted { $0.value.lastSeen > $1.value.lastSeen }
        if records.isEmpty {
            sub.addItem(info("Nothing measured yet"))
        } else {
            let rate = TrafficPolicy.rate
            let rows = records.map { _, r -> [String] in
                [r.name, rate(r.maxDown), rate(r.maxUp), r.speedDown.map(rate) ?? "—",
                 r.latencyMs.map { String(format: "%.0f ms", $0) } ?? "—", NetworkBookPolicy.ago(r.lastSeen, now: now)]
            }
            let current = Set(records.enumerated().filter { $0.element.key == traffic.network?.key }.map(\.offset))
            sub.addItem(MenuTable.item(header: ["network", "↓ best", "↑ best", "⚡ test", "latency", "seen"],
                                       rows: rows, bold: current))
            sub.addItem(info("best = highest 5 s average today · ⚡ = last speed test"))
        }
        item.submenu = sub
        return item
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

        let settings = NSMenuItem(title: "⚙️ Roaming plan", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let plan = r.planMb.map { gb($0 * 1_000_000) } ?? "?"
        sub.addItem(action("Monthly plan: \(plan) …", #selector(setPlan)))
        sub.addItem(action("Resets on day \(r.resetDay.map(String.init) ?? "?") …", #selector(setResetDay)))
        let extra = r.adjust == 0 ? "none" : (r.adjust > 0 ? "+" : "") + gb(r.adjust)
        sub.addItem(action("Extra this cycle: \(extra) — add a package …", #selector(addPackage)))
        sub.addItem(action("Vodafone says remaining is …", #selector(setRemaining)))
        sub.addItem(action("Ask Vodafone (*123#)", #selector(askVodafone)))
        sub.addItem(.separator())
        sub.addItem(action(r.guardOff ? "🔓 Hotspot protection off until the reset — turn back on"
                                      : "🔒 Hotspot protection on (keeps \(gb(r.reserve))) — turn off until reset",
                           #selector(toggleGuard)))
        sub.addItem(action("Ask the phone now", #selector(askNow)))
        if !net.onHotspot {
            sub.addItem(.separator())
            sub.addItem(info("Changes reach the phone only over its hotspot"))
        }
        settings.submenu = sub
        menu.addItem(settings)
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
