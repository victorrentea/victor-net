import AppKit

/// The menu bar switches: state in the title (a trailing ✓), not the item's
/// native tick — one ticked row makes AppKit reserve a check column for the
/// whole menu and nudges every row's emoji to the right.
enum HotspotMenu {
    static func title(enabled: Bool) -> String { "🛜 Auto-Start Hotspot" + (enabled ? "  ✓" : "") }
}

enum RoamingSuspendMenu {
    static func title(enabled: Bool) -> String { "⏸️ Pause Claude on roaming data" + (enabled ? "  ✓" : "") }
}

enum JoinFailure {
    /// `networksetup`'s tmpErr with no password given. It can also mean a join raced by
    /// auto-join, so the worst case is one needless password dialog.
    static func lacksPassword(_ error: String, typedOne: Bool) -> Bool {
        !typedOne && error.contains("-3900")
    }
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
    private let hotspot: HotspotFallback
    private var hotspotCounter = InterfaceByteCounter()
    private var lastAskedAt = Date.distantPast
    /// The blink of the ⇄ hint: flipped once a second by `tick`.
    private var blinkBright = true
    /// `GET /test/sim-hint/simulate/on|off`: draw the hint whatever the SIMs say.
    var simulateSwitchHint = false

    var onRoamingSuspendToggled: (() -> Void)?
    var phoneBattery: (() -> PhoneBattery?)?
    /// The menu just opened — offline, that is when to ask the phone for its hotspot.
    var onOpen: (() -> Void)?


    init(net: NetworkState, traffic: TrafficMonitor, phone: PhoneLink, roaming: PhoneRoamingMonitor, hotspot: HotspotFallback) {
        self.net = net
        self.traffic = traffic
        self.phone = phone
        self.roaming = roaming
        self.hotspot = hotspot
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
        blinkBright.toggle()
        refreshIcon()
    }

    /// On the hotspot, with a fresh reading: the SIM not carrying data has ≥ 2 bars more.
    private var switchHint: (better: SimSignal?, sims: [SimSignal])? {
        if simulateSwitchHint { return (nil, []) }
        guard net.onHotspot, let s = net.phoneSignal,
              Date().timeIntervalSince(s.readAt) < PhoneStatusPolicy.staleAfter,
              let better = SimSwitchHint.better(s.sims) else { return nil }
        return (better, s.sims)
    }

    var switchHintJSON: [String: Any] {
        let h = switchHint
        return ["showing": h != nil, "simulated": simulateSwitchHint, "better": orNull(h?.better.map(SimSignalPolicy.label))]
    }

    /// What is left now: the phone's number minus what this Mac pulled since.
    private var roamingLeft: Int64? {
        guard let r = roaming.reading else { return nil }
        return RoamingMeterPolicy.estimate(r, macBytesSince: hotspotCounter.since(r.readAt))
    }

    /// The data SIM's "5G" / "4G" for the menu bar's bars, from a fresh reading only.
    private var barsNetwork: String? {
        guard let s = net.phoneSignal, Date().timeIntervalSince(s.readAt) < PhoneStatusPolicy.staleAfter else { return nil }
        return SimSignalPolicy.generation(s.network)
    }

    func refreshIcon() {
        guard let button = statusItem.button else { return }
        var look = net.look
        if case .hotspot(let level, let weak, _) = look {
            look = .hotspot(level: level, weakWifi: weak,
                            alert: RoamingAlertPolicy.alert(roaming.reading, left: roamingLeft ?? 0, now: Date()))
        }
        // Connected but with nothing behind it must not look connected (Victor, 2026-11-06).
        let noInternet = offlineSince != nil || hotspot.progress.offline
        if look == .offline, !net.wifiPower {
            button.image = Icons.wifiOff()
        } else if noInternet {
            button.image = Icons.wifiNoInternet()
        } else if case .hotspot = look, let hint = switchHint {
            // Blinks (Victor, 2026-11-11): a nudge to switch the data SIM by hand on the phone.
            let image = Icons.image(for: look, switchHint: true, network: barsNetwork)
            button.image = image.map { blinkBright ? $0 : Icons.faded($0, 0.3) }
            button.toolTip = hint.better.map { SimSwitchHint.tooltip($0, over: hint.sims) } ?? "Simulated ⇄"
            button.title = ""
            return
        } else {
            button.image = look == .offline ? Icons.wifiIdle() : Icons.image(for: look, network: barsNetwork)
        }
        button.toolTip = nil
        button.title = ""
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        onOpen?()
        net.onScan = { [weak self] in
            self?.updateMoreStatus()
            self?.updateWifiArcs()
            if self?.net.scanning == false { self?.refreshOthers() }
        }
        net.scanInBackground()
        // Every second while open: the "More" row's status, and a new scan as soon
        // as the last one is over, at most every 2 s from its start (Victor,
        // 2026-10-21: "every two, three seconds"). A scan itself takes ~5 s and
        // briefly stalls the link, so while the menu is open it is near-continuous.
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateMoreStatus()
            self.updateHotspotRow()
            if let item = self.batteryItem, let b = self.phoneBattery?() { item.title = b.menuTitle(now: Date()) }
            self.updateSimBars()
            self.refreshNetworksIfChanged()
            if !self.net.scanning, Date().timeIntervalSince(self.net.lastScanStarted ?? .distantPast) >= 2 {
                self.net.scanInBackground()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        rescanTimer = t
    }

    func menuDidClose(_ menu: NSMenu) {
        net.onScan = nil
        rescanTimer?.invalidate()
        rescanTimer = nil
        networkItems = []
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        net.refresh()

        // Networks, the way macOS lists them: the switch, the ones worth
        // comparing (✓ = in use, click = join), everything else in range, the
        // settings. Offline, a greyed "Offline N min" stands where the list was.
        // The network rows first: their numbers set the menu's width, which the switch row uses.
        MenuRowLayout.cellWidth = 0
        networkItems = networkSection()
        if Config.hasPhone, !Config.hotspotSSID.isEmpty {
            menu.addItem(hotspotButtonItem())
            menu.addItem(.separator())
        }
        menu.addItem(wifiSwitchRow())
        menu.addItem(.separator())
        networkItems.forEach(menu.addItem)
        menu.addItem(otherNetworksRow())

        // Everything about the network that is not roaming, under its settings.
        menu.addItem(.separator())
        let settings = action("Wi-Fi Settings…", #selector(openWifiSettings))
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        menu.addItem(settings)
        if Config.hasPhone { addAutoJoinRows() }
        let speed = action(speedTitle(), #selector(speedTestAction))
        speed.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Speed test")
        menu.addItem(speed)

        // Everything about roaming, together.
        if Config.hasPhone {
            menu.addItem(.separator())
            addRoamingRows()
        }

        menu.addItem(.separator())
        if Config.hasPhone, let battery = phoneBattery?() {
            let item = info(battery.menuTitle(now: Date()))
            batteryItem = item
            menu.addItem(item)
        }
        menu.addItem(info("Built \(BuildInfo.time)"))
        // No ⌘Q shown: its column made the whole menu wider for nothing.
        menu.addItem(action("Quit", #selector(quitAction)))
    }

    /// The phone's battery row, its age ticking while the menu is open.
    private weak var batteryItem: NSMenuItem?

    private func speedTitle() -> String {
        if traffic.speedTestRunning { return "Testing speed…" }
        let mb = traffic.network?.kind == "hotspot" ? 10 : 25
        return "Run speed test (\(mb)MB)"
    }

    // MARK: - Networks, like macOS's Wi-Fi menu

    /// The rows between the switch and *More*, and which network they were drawn for.
    private var networkItems: [NSMenuItem] = []
    private var drawnFor = ""

    private var offlineSince: Date? {
        traffic.offlineSince.flatMap { Date().timeIntervalSince($0) >= 5 ? $0 : nil }
    }

    private func networkSection() -> [NSMenuItem] {
        drawnFor = networkSignature
        if let since = offlineSince {
            return [NSMenuItem(view: MenuRowView(
                name: "Offline \(NetworkBookPolicy.duration(Date().timeIntervalSince(since)))",
                icon: Icons.noTraffic(), enabled: false, dimmed: true))]
        }
        return networkRows()
    }

    private var networkSignature: String {
        "\(traffic.network?.key ?? "-")|\(net.ssid ?? "-")|\(offlineSince == nil ? "on" : "off")"
    }

    /// The one exception to the snapshot: when the Mac moves to another network
    /// while the menu is open (the hotspot comes up, say), the network rows are
    /// redrawn in place so the ✓ follows (Victor, 2026-10-29: he watched it join
    /// the hotspot with the menu open and the row never showed up).
    private func refreshNetworksIfChanged() {
        guard !networkItems.isEmpty, networkSignature != drawnFor,
              let at = menu.items.firstIndex(of: networkItems[0]) else { return }
        netInfo("🛜 network changed while the menu is open (\(drawnFor) → \(networkSignature)): redrawing its rows")
        networkItems.forEach { menu.removeItem($0) }
        networkItems = networkSection()
        for (k, item) in networkItems.enumerated() { menu.insertItem(item, at: at + k) }
        refreshOthers()
    }

    private weak var othersMenu: NSMenu?
    private var othersDrawn: String?
    private var rescanTimer: Timer?

    /// The networks worth comparing — the one in use, those of today, every Wi-Fi
    /// in range this Mac knows or has measured — with their best numbers. ✓ = in
    /// use; a click on another joins it. Out of range: greyed if it was today,
    /// off the list otherwise, numbers kept.
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
            if let sim = traffic.windowSim {
                let key = TrafficMonitor.simKey(sim)
                var s = records[key] ?? NetworkRecord(name: sim, kind: "sim", lastSeen: now)
                s.maxDown = max(s.maxDown, traffic.down.maxAverage ?? 0)
                s.maxUp = max(s.maxUp, traffic.up.maxAverage ?? 0)
                if let best = traffic.latencyBest { s.latencyMs = s.latencyMs.map { min($0, best) } ?? best }
                s.lastSeen = now
                records[key] = s
            }
        }
        for ssid in reachable.intersection(known) where records["wifi:\(ssid)"] == nil {
            records["wifi:\(ssid)"] = NetworkRecord(name: ssid, kind: ssid == Config.hotspotSSID ? "hotspot" : "wifi",
                                                    lastSeen: .distantPast)
        }
        var shown = NetworkBookPolicy.listed(records, current: traffic.network?.key, reachable: reachable, now: now)
        // The cable first, a line under it, then the Wi-Fis (Victor, 2026-11-09).
        if let k = shown.firstIndex(where: { $0.key == "wired" }) { shown.insert(shown.remove(at: k), at: 0) }
        // The hotspot's row is also its Start button, so it is always there.
        let hotspotKey = "wifi:\(Config.hotspotSSID)"
        if Config.hasPhone, !Config.hotspotSSID.isEmpty, !shown.contains(where: { $0.key == hotspotKey }) {
            shown.append((key: hotspotKey, value: records[hotspotKey]
                          ?? NetworkRecord(name: Config.hotspotSSID, kind: "hotspot", lastSeen: .distantPast)))
        }
        // The SIM rows under the hotspot: live while it is in use, what each gave before while it is off.
        let hotspotJoined = Config.hasPhone && !Config.hotspotSSID.isEmpty && net.ssid == Config.hotspotSSID
        let simEntries = hotspotJoined ? liveSimEntries(records: records)
            : hotspotShowsStop ? [] : idleSimEntries(records: records)
        // One unit for the whole list, so the column reads straight down: KB/s
        // while nothing reaches 1 MB/s, MB/s otherwise (Victor, 2026-10-20).
        let unit = TrafficPolicy.listUnit((shown.map(\.value) + simEntries.compactMap(\.record))
            .flatMap { [$0.maxDown, $0.maxUp, $0.speedDown ?? 0] })
        let rate: (Double) -> String = { $0 > 0 ? unit.format($0) : "—" }
        func isCurrent(_ key: String) -> Bool {
            key == traffic.network?.key || (key.hasPrefix("wifi:") && String(key.dropFirst(5)) == net.ssid)
        }
        // Each number with its unit, the arrow before the unit (Victor, 2026-11-08):
        // "2.9↓MB/s ⋅ 2.5↑MB/s ⋅ 5↕︎ms" — the header that labelled them is gone.
        // A network not in use shows its speed test as ↓ when it had one, after a ⚡ (Victor, 2026-11-09).
        func cell(_ r: NetworkRecord, _ seen: String, unused: Bool) -> String {
            let test = unused ? r.speedDown : nil
            // Thin spaces around the dot: the full ones cost the menu 14 pt.
            return (test == nil ? "" : "⚡\u{2009}")
                + "\(rate(test ?? r.maxDown))↓\(unit.name)\u{2009}⋅\u{2009}\(rate(r.maxUp))↑\(unit.name)\u{2009}⋅\u{2009}"
                + (r.latencyMs.map { String(format: "%.0f", $0) } ?? "—") + "↕︎ms\u{2009}⋅\u{2009}\(seen)"
        }
        func seen(_ key: String, _ r: NetworkRecord) -> String {
            let joined = key.hasPrefix("wifi:") && String(key.dropFirst(5)) == net.ssid
            return joined ? "now" : r.lastSeen == .distantPast ? "—" : NetworkBookPolicy.since(r.lastSeen, now: now)
        }
        // Only grows: rows redrawn while the menu is open keep the width it opened with.
        let texts = shown.map { cell($0.value, seen($0.key, $0.value), unused: !isCurrent($0.key)) }
            + simEntries.compactMap { e in e.record.map { cell($0, e.seen, unused: !e.isData) } }
        MenuRowLayout.cellWidth = max(MenuRowLayout.cellWidth, texts.map(MenuRowView.cellWidth).max() ?? 0)
        let rssi = Dictionary(net.scanResults().map { ($0.ssid, $0.rssi) }, uniquingKeysWith: max)

        var items: [NSMenuItem] = []
        wifiRows = []
        for (key, r) in shown {
            let ssid = key.hasPrefix("wifi:") ? String(key.dropFirst(5)) : nil
            // ✓ on every network this Mac is on: the route (the cable, say) *and*
            // the Wi-Fi it is joined to — both are "active" (Victor, 2026-10-21).
            let joined = ssid != nil && ssid == net.ssid
            let current = key == traffic.network?.key || joined
            let inRange = ssid.map(reachable.contains) ?? false
            let icon: NSImage?
            if key == "wired" { icon = Icons.wired() }
            else if ssid == Config.hotspotSSID { icon = Icons.hotspot() }
            else {
                let level = ssid == net.ssid ? net.rssi : ssid.flatMap { rssi[$0] }
                icon = Icons.wifi(strength: level.map(NetworkLookPolicy.strength(rssi:)) ?? 0)
            }
            let isHotspot = ssid == Config.hotspotSSID && Config.hasPhone
            // The hotspot's numbers are its SIMs', shown on their rows under it (Victor, 2026-11-08).
            // Start/Stop is no longer here but the button at the top (Victor, 2026-11-11): this row
            // is a network like the others, a click joins it when it is in range.
            let sims = isHotspot ? simRowViews(simEntries, cell: cell).map { NSMenuItem(view: $0) } : []
            let row = MenuRowView(name: ssid ?? "Ethernet",
                                  columns: isHotspot ? [] : [cell(r, seen(key, r), unused: !current)],
                                  icon: icon, checked: current,
                                  enabled: !current && inRange,
                                  dimmed: !isHotspot && !current && !inRange,
                                  staleNumbers: !current)
            if let ssid, key != "wired", ssid != Config.hotspotSSID { wifiRows.append((row, ssid)) }
            if isHotspot { frame(row, sims.compactMap { $0.view as? MenuRowView }) }
            if !current, inRange, let ssid, key != "wired" { row.onClick = { [weak self] in self?.join(ssid, password: nil) } }
            // The header said what the numbers are; the tooltip says it now (Victor, 2026-11-08).
            row.toolTip = r.maxDown == 0 && r.maxUp == 0 && r.latencyMs == nil && r.speedDown == nil ? "Not measured yet"
                : !current && r.speedDown != nil
                ? "⚡ ↓ from the last speed test on it; ↑ upload (5 s average) and ↕︎ latency to 1.1.1.1, best over the last hour spent on it"
                : (current ? "Best over the last hour" : "Best over the last hour spent on it")
                + ": ↓ download and ↑ upload (5 s average), ↕︎ latency to 1.1.1.1"
            items.append(NSMenuItem(view: row))
            items += sims
            if key == "wired", shown.count > 1 { items.append(.separator()) }
        }
        return items
    }

    /// One SIM row under the hotspot, worked out before any row is drawn: its numbers set the menu's width.
    struct SimEntry {
        let name: String
        let label: String
        /// The phone's live reading, while the Mac is on its hotspot; nil while it is off.
        let signal: SimSignal?
        let record: NetworkRecord?
        /// Its numbers were filed at this place (`SimLog`), not just anywhere.
        let here: Bool
        let seen: String
        /// Bars the phone reported for it with the hotspot off (`PhoneLan`, on the home Wi-Fi): nil = no icon.
        var bars: (level: Int, network: String?, readAt: Date)? = nil
        var isData: Bool { signal?.isData ?? false }
    }

    /// The SIMs' signal from the phone's `/status` off the hotspot: over the home Wi-Fi (`PhoneLan`)
    /// or Bluetooth (`PhoneRoamingMonitor`), every 10 / 20 min and once more at each menu opening.
    var offHotspotSignal: PhoneSignal?

    /// Under the hotspot while it is in use: the phone's SIMs, in the same bars as the menu bar,
    /// ✓ on the one carrying the data (Victor, 2026-11-08). The switch stays his, on the phone.
    /// The data SIM shows its live best; the other, what it gave before (`idleSim`).
    private func liveSimEntries(records: [String: NetworkRecord]) -> [SimEntry] {
        guard let s = net.phoneSignal, Date().timeIntervalSince(s.readAt) < PhoneStatusPolicy.staleAfter else { return [] }
        let now = Date()
        return SimSignalPolicy.ordered(s.sims).map { sim in
            let (r, here) = sim.isData ? (records[TrafficMonitor.simKey(sim.name)], false)
                : idleSim(sim.name, records: records) ?? (nil, false)
            return SimEntry(name: sim.name, label: SimSignalPolicy.label(sim), signal: sim, record: r, here: here,
                            seen: sim.isData ? "now" : r.map { NetworkBookPolicy.since($0.lastSeen, now: now) } ?? "—")
        }
    }

    /// With the hotspot off — on the home, hotel or office Wi-Fi too: what each SIM gave before,
    /// in grey, so the place can be judged before starting it (Victor, 2026-11-08/09). None = no rows.
    private func idleSimEntries(records: [String: NetworkRecord]) -> [SimEntry] {
        let now = Date()
        // Bars only from a real reading (Victor, 2026-11-09): the phone's answer over the home Wi-Fi,
        // at most 15 min old (it is asked every 10); without one, no icon at all.
        let reading = [net.phoneSignal, offHotspotSignal].compactMap { $0 }
            .filter { now.timeIntervalSince($0.readAt) < 900 }.max { $0.readAt < $1.readAt }
        let live = reading?.sims ?? []
        // Every SIM the phone ever named here, numbers or not (Victor, 2026-11-09: "ambele SIM-uri, oricum").
        let known = live + (net.phoneSignal?.sims ?? []) + (offHotspotSignal?.sims ?? [])
        let names = Set(records.keys.filter { $0.hasPrefix("sim:") }.map { String($0.dropFirst(4)) })
            .union((simHere?() ?? [:]).keys).union(known.map(\.name))
        return names.sorted().compactMap { name in
            let sim = live.first { $0.name == name }
            let found = idleSim(name, records: records)
            let label = known.first { $0.name == name }.map(SimSignalPolicy.label) ?? simLabel?(name) ?? name
            var e = SimEntry(name: name, label: label, signal: nil, record: found?.0, here: found?.here ?? false,
                             seen: found.map { NetworkBookPolicy.since($0.0.lastSeen, now: now) } ?? "—")
            if let sim, let reading { e.bars = (sim.level, sim.network, reading.readAt) }
            return e
        }
    }

    /// A SIM not carrying data: what it gave at this place (`SimLog`) — its speed test there, if
    /// one ran, shown after a ⚡ — else its best anywhere (`sim:<name>`). Nothing = nil.
    private func idleSim(_ name: String, records: [String: NetworkRecord]) -> (NetworkRecord, here: Bool)? {
        let book = records[TrafficMonitor.simKey(name)]
        if let spot = simHere?()[name] {
            var r = NetworkRecord(name: name, kind: "sim", lastSeen: spot.lastSeen)
            // A spot filed before it kept ↓ ↑ lacks them: those come from the book.
            r.maxDown = spot.maxDown ?? book?.maxDown ?? 0
            r.maxUp = spot.maxUp ?? book?.maxUp ?? 0
            r.latencyMs = SimLogPolicy.median(spot.latency) ?? book?.latencyMs
            r.speedDown = spot.speed
            r.speedAt = spot.speedAt
            return (r, true)
        }
        guard let book, book.maxDown > 0 || book.maxUp > 0 || book.latencyMs != nil || book.speedDown != nil else { return nil }
        return (book, false)
    }

    /// Each SIM with the same numbers as a network — best ↓ ↑ (⚡ = a speed test's ↓), latency
    /// and when last used — and, while on the hotspot, the bars the phone sees for it now.
    private func simRowViews(_ entries: [SimEntry], cell: (NetworkRecord, String, Bool) -> String) -> [MenuRowView] {
        let now = Date()
        let readAt = net.phoneSignal?.readAt ?? now
        simAgeRows = []
        return entries.map { e in
            let icon = e.signal.map { Icons.cellular(level: $0.level, network: SimSignalPolicy.generation($0.network),
                                                     age: SimSignalPolicy.age(readAt, now: now)) }
                ?? e.bars.map { Icons.cellular(level: $0.level, network: SimSignalPolicy.generation($0.network),
                                               age: SimSignalPolicy.age($0.readAt, now: now)) }
                // No reading yet: an empty slot the bars fill once the phone answers (asked at the opening).
                ?? NSImage(size: NSSize(width: Icons.cellularWithAgeWidth, height: Icons.barHeight))
            let row = MenuRowView(name: e.label, columns: e.record.map { [cell($0, e.seen, !e.isData)] } ?? [],
                                  icon: icon, checked: e.isData, enabled: false, indent: 16, staleNumbers: !e.isData)
            simAgeRows.append((row, e.name))
            let test = !e.isData && e.record?.speedDown != nil
            row.toolTip = e.record == nil ? "Not used through the hotspot yet"
                : (e.isData ? "Best over the last hour on this SIM"
                   : e.here ? "Measured here before, through the hotspot on this SIM"
                   : "Best through the hotspot on this SIM, anywhere (nothing measured here yet)")
                + (test ? ": ⚡ ↓ from a speed test, ↑ upload (5 s average), ↕︎ latency to 1.1.1.1"
                   : ": ↓ download and ↑ upload (5 s average), ↕︎ latency to 1.1.1.1")
            return row
        }
    }

    /// "More…" — a real submenu with every other Wi-Fi in range (Victor,
    /// 2026-11-05; it unfolded inline until then), redrawn as the scans come in.
    /// Before the name, proof that it is really looking: a spinner while a scan
    /// runs, then the networks in that submenu in the same spot — "5 More…"
    /// (Victor, 2026-11-06: nothing on the right, no "in range", no "now").
    private func otherNetworksRow() -> NSMenuItem {
        let row = MenuRowView(name: "More…",
                              trailing: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil))
        row.statusBeforeName = true
        moreRow = row
        updateMoreStatus()
        let item = NSMenuItem(view: row)
        let others = NSMenu()
        others.autoenablesItems = false
        item.submenu = others
        othersMenu = others
        othersDrawn = nil
        refreshOthers()
        return item
    }

    private weak var moreRow: MenuRowView?

    private func updateMoreStatus() {
        guard let row = moreRow else { return }
        let failure = net.scanning ? nil : net.lastScan?.error
        row.toolTip = failure.map { "Scan failed: \($0)" }
        if net.scanning {
            row.setStatus("", spinning: true)
        } else if let l = net.lastScan {
            row.setStatus(l.error != nil ? "⚠︎" : "\(otherNetworks().count)", spinning: false)
        } else {
            row.setStatus("", spinning: false)
        }
    }

    /// In range and not already in the list above.
    private func otherNetworks() -> [(ssid: String, rssi: Int, secure: Bool)] {
        let listed = Set(traffic.book.records.keys.filter { $0.hasPrefix("wifi:") }.map { String($0.dropFirst(5)) })
            .union(net.knownSSIDs()).intersection(net.reachableSSIDs())
        return net.scanResults().filter { !listed.contains($0.ssid) && $0.ssid != net.ssid }
    }

    /// Redrawn only when the list changed: replacing a row takes the highlight off
    /// the one under the pointer.
    private func refreshOthers() {
        guard let othersMenu else { return }
        let others = otherNetworks()
        let drawn = "\(net.wifiPower)|" + others.map {
            "\($0.ssid)|\(NetworkLookPolicy.strength(rssi: $0.rssi))|\($0.secure)"
        }.joined(separator: "|")
        guard drawn != othersDrawn else { return }
        othersDrawn = drawn
        netInfo("🛜 More: \(others.count) other networks in range")
        othersMenu.removeAllItems()
        if others.isEmpty {
            othersMenu.addItem(NSMenuItem(view: MenuRowView(name: net.wifiPower ? "Searching…" : "Wi-Fi is off",
                                                            enabled: false, dimmed: true, width: 160)))
        }
        // As narrow as its longest name (Victor, 2026-11-08): no numbers here to line up.
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let longest = others.map { ($0.ssid as NSString).size(withAttributes: [.font: font]).width }.max() ?? 80
        let width = (MenuRowLayout.nameX + longest + 40).rounded(.up)
        for n in others {
            let lock = n.secure ? NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "secured") : nil
            let row = MenuRowView(name: n.ssid, icon: Icons.wifi(strength: NetworkLookPolicy.strength(rssi: n.rssi)),
                                  trailing: lock, width: width)
            row.onClick = { [weak self] in self?.joinOther(n.ssid, secure: n.secure) }
            othersMenu.addItem(NSMenuItem(view: row))
        }
    }

    private func frame(_ head: MenuRowView, _ children: [MenuRowView]) {
        head.groupEdge = children.isEmpty ? .single : .top
        for (i, c) in children.enumerated() { c.groupEdge = i == children.count - 1 ? .bottom : .middle }
    }

    /// The Wi-Fi rows on screen, whose arcs follow each scan: the menu opens before the first
    /// scan of its own is back, so a network not joined had no strength yet (Victor, 2026-11-08).
    private var wifiRows: [(row: MenuRowView, ssid: String)] = []

    private func updateWifiArcs() {
        let rssi = Dictionary(net.scanResults().map { ($0.ssid, $0.rssi) }, uniquingKeysWith: max)
        for (row, ssid) in wifiRows {
            guard let level = ssid == net.ssid ? net.rssi : rssi[ssid] else { continue }
            row.setIcon(Icons.wifi(strength: NetworkLookPolicy.strength(rssi: level)) ?? NSImage())
        }
    }

    /// What each SIM gave this Mac where it is now (`SimLog`), by the SIM's own name.
    var simHere: (() -> [String: SimSpot])?

    /// How a SIM was named in any place it was used ("Orange"), for when the phone is not around.
    var simLabel: ((String) -> String?)?

    /// The SIM rows on screen, to redraw their bars and age every second while the menu is open:
    /// the phone answers every 5 s, and the corner shows how fresh that answer is (Victor, 2026-11-08).
    private var simAgeRows: [(row: MenuRowView, sim: String)] = []

    /// With the hotspot off too, from the phone's answer over the home Wi-Fi (Victor, 2026-11-09: the age runs live).
    private func updateSimBars() {
        let now = Date()
        for (row, name) in simAgeRows {
            guard let s = [net.phoneSignal, offHotspotSignal].compactMap({ $0 })
                .filter({ r in now.timeIntervalSince(r.readAt) < 900 && r.sims.contains { $0.name == name } })
                .max(by: { $0.readAt < $1.readAt }) else { continue }
            let sim = s.sims.first { $0.name == name }
            row.setIcon(Icons.cellular(level: sim?.level, network: SimSignalPolicy.generation(sim?.network),
                                       age: SimSignalPolicy.age(s.readAt, now: now)))
        }
    }

    /// The hotspot button at the top of the menu (`HotspotButton`). The row's corner tells what
    /// the automatic path is doing, every second: the attempt running, or how long until the next
    /// one (Victor, 2026-11-05). The menu stays open, to watch it.
    private func hotspotButtonItem() -> NSMenuItem {
        let state = hotspotButtonState
        let row = MenuRowView(name: state.title, icon: state == .stop ? Icons.hotspotOff() : Icons.hotspot())
        row.keepsMenuOpen = true
        row.onClick = { [weak self] in
            guard let self else { return }
            let now = self.hotspotButtonState
            guard HotspotRowPolicy.takesClick(shown: self.hotspotButtonShown, now: now,
                                              shownSince: self.hotspotButtonShownSince, at: Date()) else {
                netInfo("🛜 hotspot button: click on \"\(self.hotspotButtonShown.title)\" ignored (now \(now.rawValue))")
                return
            }
            if now == .stop { self.stopHotspot() } else { self.hotspot.startNow() }
            self.updateHotspotRow()
        }
        hotspotRow = row
        hotspotButtonShown = state
        hotspotButtonShownSince = Date()
        updateHotspotRow()
        return NSMenuItem(view: row)
    }

    private var hotspotButtonShown = HotspotButton.start
    private var hotspotButtonShownSince = Date.distantPast

    private var hotspotButtonState: HotspotButton {
        HotspotRowPolicy.button(
            hotspot.progress, onHotspot: net.onHotspot,
            inScan: net.scanResults().contains { $0.ssid == Config.hotspotSSID },
            stoppedRecently: Date().timeIntervalSince(hotspotStoppedAt) < Self.scanOutlivesStop)
    }

    private var hotspotShowsStop: Bool {
        HotspotRowPolicy.showsStop(
            hotspot.progress, onHotspot: net.onHotspot,
            inScan: net.scanResults().contains { $0.ssid == Config.hotspotSSID },
            stoppedRecently: Date().timeIntervalSince(hotspotStoppedAt) < Self.scanOutlivesStop)
    }

    /// `GET /test/hotspot/row` — what the row would say; scans, as an open menu does.
    func hotspotRowForTest() -> [String: Any] {
        net.scanInBackground()
        return ["stop": hotspotShowsStop, "button": hotspotButtonState.rawValue, "in_scan": net.scanResults().contains { $0.ssid == Config.hotspotSSID },
                "on_hotspot": net.onHotspot, "networks": net.scanResults().count]
    }

    /// Also `GET /test/hotspot/stop`.
    func stopHotspot(retrying: Bool = true) {
        hotspotStoppedAt = Date()
        // Off the hotspot with no other network is "offline": the fallback must not answer by
        // starting it right back.
        hotspot.hold(for: Self.holdAfterStop)
        hotspot.releaseChannel()
        netInfo("🛜 Stop Hotspot — asking the phone")
        phone.stopHotspot { [weak self] _, error in
            guard let error else { return }
            netInfo("🛜 Stop Hotspot: \(error)")
            // The Bluetooth channel can still be held by the one that started it.
            guard retrying else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.stopHotspot(retrying: false) }
        }
    }

    /// Measured: 40–50 s until a scan drops a stopped hotspot.
    private static let scanOutlivesStop: TimeInterval = 60
    private static let holdAfterStop: TimeInterval = 120
    private var hotspotStoppedAt = Date.distantPast
    private weak var hotspotRow: MenuRowView?

    private func updateHotspotRow() {
        guard let row = hotspotRow else { return }
        let state = hotspotButtonState
        if state != hotspotButtonShown {
            hotspotButtonShown = state
            hotspotButtonShownSince = Date()
            row.setName(state.title)
            row.setIcon((state == .stop ? Icons.hotspotOff() : Icons.hotspot()) ?? NSImage())
        }
        let p = hotspot.progress
        let status = HotspotRowPolicy.status(p, now: Date())
        switch state {
        case .stopping: row.setStatus("", spinning: true)
        case .stop: row.setStatus("", spinning: false)
        // The countdown alone: the title already says what is going on.
        case .asking, .starting, .start: row.setStatus(status.text.replacingOccurrences(of: "asking phone ", with: "")
                                                           .replacingOccurrences(of: "joining ", with: ""),
                                                       spinning: status.spinning)
        }
        row.toolTip = p.lastFailure.map { "Last attempt: \($0)" }
    }

    private func join(_ ssid: String, password: String?) {
        netInfo("🛜 joining \(ssid)")
        net.join(ssid, password: password) { [weak self] error in
            if let error {
                // macOS lists the network but gives `networksetup` no password for it
                // (airportd: "Missing password", tmpErr): asked once, then `WifiPasswords`.
                if JoinFailure.lacksPassword(error, typedOne: password != nil), let pw = Prompt.wifiPassword(ssid) {
                    self?.join(ssid, password: pw)
                    return
                }
                return Prompt.show("Could not join \(ssid)", error)
            }
            netInfo("🛜 joined \(ssid)")
            // A new network must stay known to macOS (Known Networks + keychain),
            // so it auto-joins later with or without this app (Victor, 2026-10-21).
            // Checked, not assumed: if the join did not remember it, add it.
            guard let password else { return }
            WifiPasswords.store(password, for: ssid)
            self?.net.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                netInfo("🛜 storing \(ssid) in the known networks")
                self.net.remember(ssid, password: password) { error in
                    netInfo("🛜 remember \(ssid): \(error ?? "ok")")
                }
            }
        }
    }

    /// A network this Mac does not know: an open one is joined straight away, a
    /// secured one asks for its password first (`Prompt.wifiPassword`); macOS
    /// keeps it in the keychain once joined. System Settings › Wi-Fi was tried
    /// for one evening (2026-10-21) and rejected: Victor wants the join right here.
    private func joinOther(_ ssid: String, secure: Bool) {
        guard secure else { return join(ssid, password: nil) }
        guard let pw = Prompt.wifiPassword(ssid) else { return }
        join(ssid, password: pw)
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
            // One line: "✈️ Roaming: 22.6/60.9 GB left until 2 Nov" — the total is
            // what this cycle allowed in all, used + left. Every row of the group starts
            // with "✈️ Roaming" (Victor, 2026-11-06), so it reads as one.
            let left = roamingLeft ?? r.remaining
            // +12 h: the reset is midnight in the phone's time zone, which may
            // still be the day before in this Mac's.
            // One row with "Ask Vodafone" (Victor, 2026-10-21: one row less): ↺ = a
            // click asks Vodafone, through the phone, for what is really left.
            // A reading over 30 min old (the phone out of reach, or cached on disk
            // from before a restart) says when it is from.
            let age = Date().timeIntervalSince(r.readAt)
            let asOf = age > 30 * 60 ? " · \(NetworkBookPolicy.ago(r.readAt, now: Date()))" : ""
            roamingRow("✈️ Roaming: \(gb(left))/\(gb(left + r.cycleTotal)) GB left until \(day.string(from: r.nextReset + 12 * 3600))\(asOf)")
        } else {
            roamingRow("✈️ Roaming: the phone has not answered yet")
        }
        // Said the positive way, ticked by default.
        let allow = action("✈️ Roaming: Allow Claude", #selector(toggleSuspend))
        allow.state = RoamingDataSettings.suspendClaude ? .off : .on
        menu.addItem(allow)
        if let r = roaming.reading {
            let stop = action("✈️ Roaming: Auto-Stop Hotspot < \(String(format: "%.0f", Double(r.reserve) / 1e9)) GB", #selector(toggleGuard))
            stop.image = Icons.hotspotOff()
            stop.toolTip = "Only while the phone is roaming: on the home network the hotspot is never stopped"
            stop.state = r.guardOff ? .off : .on
            menu.addItem(stop)
        }
    }

    /// The two rows that pick a network by themselves, roaming or not.
    private func addAutoJoinRows() {
        if let home = Config.values["PREFERRED_SSID"], !home.isEmpty {
            let prefer = action("Prefer \(home) over \(Config.hotspotSSID)", #selector(togglePreferred))
            prefer.image = Icons.wifi(strength: 1)
            prefer.state = PreferredWifiSettings.isEnabled ? .on : .off
            menu.addItem(prefer)
        }
        let start = action("Auto-Start Hotspot on no Internet", #selector(toggleHotspot))
        start.image = Icons.hotspot()
        start.state = HotspotFallbackSettings.isEnabled ? .on : .off
        menu.addItem(start)
    }

    private func roamingRow(_ title: String) {
        let asking = askedVodafoneAt.map { Date().timeIntervalSince($0) < 180 } ?? false
        let row = action(asking ? "\(title) — asking Vodafone…" : title, #selector(askVodafone))
        row.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Ask Vodafone")
        row.toolTip = "Ask Vodafone (*123#, through the phone) for what is left"
        row.isEnabled = !asking
        menu.addItem(row)
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

    /// `GET /test/menu/rows` — the rows' titles, built as if opened, without opening anything.
    func rowsForTest() -> [String] {
        menuNeedsUpdate(menu)
        return menu.items.map(\.title)
    }

    /// `GET /test/more-row` — the Wi-Fi switch, the network rows as they are now plus
    /// sample ones, and the rows with a status, drawn off-screen in each state on a
    /// light and a dark menu, to look at without opening the menu.
    func renderMoreRowForTest() -> String? {
        let rows: [(name: String, status: String, spinning: Bool)] = [
            ("More…", "", true), ("More…", "5", false), ("More…", "14", false), ("More…", "⚠︎", false),
            ("Start Hotspot", "asking phone 38s", true), ("Start Hotspot", "joining 47s", true),
            ("Start Hotspot", "retrying in 23s", false), ("Start Hotspot", "Start Hotspot", false),
        ]
        // Sized as the menu would be, with the sample cells counted in.
        let samples = ["290↓KB/s\u{2009}⋅\u{2009}120↑KB/s\u{2009}⋅\u{2009}145↕︎ms\u{2009}⋅\u{2009}3 days",
                       "12.9↓MB/s\u{2009}⋅\u{2009}12.5↑MB/s\u{2009}⋅\u{2009}—↕︎ms\u{2009}⋅\u{2009}2 h"]
        MenuRowLayout.cellWidth = 0
        _ = networkRows()
        MenuRowLayout.cellWidth = max(MenuRowLayout.cellWidth, samples.map(MenuRowView.cellWidth).max() ?? 0)
        func views() -> [NSView] {
            // The hotspot button at the top, in each of its states.
            var out: [NSView] = HotspotButton.allStates.map { b in
                let row = MenuRowView(name: b.title, icon: b == .stop ? Icons.hotspotOff() : Icons.hotspot())
                row.setStatus(b == .asking ? "18s" : b == .starting ? "41s" : "", spinning: !b.clickable)
                return row
            }
            out += [MenuSwitchRow(title: "Wi-Fi", on: true), MenuSwitchRow(title: "Wi-Fi", on: false)]
            out += networkRows().compactMap(\.view)
            let head = MenuRowView(name: "victor", icon: Icons.hotspot(), checked: true)
            out.append(head)
            var yoxo = NetworkRecord(name: "yoxo", kind: "sim", lastSeen: Date()); yoxo.maxDown = 2_100_000; yoxo.maxUp = 900_000; yoxo.latencyMs = 36
            var vic = NetworkRecord(name: "Vic", kind: "sim", lastSeen: Date().addingTimeInterval(-7200)); vic.maxDown = 1_300_000; vic.maxUp = 400_000; vic.latencyMs = 53
            vic.speedDown = 9_050_000
            let sims = [(SimSignal(name: "yoxo", isData: true, level: 3, operatorName: "orange", network: "LTE", rsrp: -97, sinr: -5), yoxo as NetworkRecord?),
                        (SimSignal(name: "Vic", isData: false, level: 4, operatorName: "Vodafone RO", network: "5G", rsrp: -85, sinr: 21), vic),
                        (SimSignal(name: "Maya", isData: false, level: 0, network: nil, rsrp: nil, sinr: nil), nil)]
            out += simRowViews(sims.map { SimEntry(name: $0.0.name, label: SimSignalPolicy.label($0.0), signal: $0.0, record: $0.1,
                                                   here: true, seen: $0.0.isData ? "now" : "2 h") },
                               cell: { r, seen, unused in (unused && r.speedDown != nil ? "⚡\u{2009}" : "")
                                   + "\(TrafficPolicy.rate(unused ? r.speedDown ?? r.maxDown : r.maxDown))↓\u{2009}⋅\u{2009}\(TrafficPolicy.rate(r.maxUp))↑\u{2009}⋅\u{2009}\(Int(r.latencyMs ?? 0))↕︎ms\u{2009}⋅\u{2009}\(seen)" })
            frame(head, Array(out.suffix(3)).compactMap { $0 as? MenuRowView })
            // Off: what each SIM gave here before, in grey.
            let off = MenuRowView(name: "victor", icon: Icons.hotspot())
            out.append(off)
            for (name, cellText) in [("Orange", "2.1↓MB/s\u{2009}⋅\u{2009}0.9↑MB/s\u{2009}⋅\u{2009}36↕︎ms\u{2009}⋅\u{2009}3 days"),
                                     ("Vodafone", "1.3↓MB/s\u{2009}⋅\u{2009}0.4↑MB/s\u{2009}⋅\u{2009}53↕︎ms\u{2009}⋅\u{2009}3 days")] {
                out.append(MenuRowView(name: name, columns: [cellText], icon: Icons.cellular(level: nil, ageSlot: true), enabled: false,
                                       indent: 16, staleNumbers: true))
            }
            frame(off, Array(out.suffix(2)).compactMap { $0 as? MenuRowView })
            out.append(MenuRowView(name: "Hotel-Guest-Wireless-5G", columns: [samples[0]],
                                   icon: Icons.wifi(strength: 2)))
            out.append(MenuRowView(name: "tzutze", columns: [samples[1]],
                                   icon: Icons.wifi(strength: 3), dimmed: true))
            for r in rows {
                let row = r.name == "More…"
                    ? MenuRowView(name: r.name, trailing: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil))
                    : MenuRowView(name: Config.hotspotSSID, icon: Icons.hotspot())
                row.statusBeforeName = r.name == "More…"
                row.setStatus(r.status, spinning: r.spinning)
                out.append(row)
            }
            return out
        }
        let w = MenuRowLayout.width
        let panes = [views(), views()]
        let height = panes.map { $0.reduce(0) { $0 + $1.frame.height } }.max() ?? 0
        let board = NSView(frame: NSRect(x: 0, y: 0, width: w * 2, height: height))
        for (i, name) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            let pane = NSBox(frame: NSRect(x: CGFloat(i) * w, y: 0, width: w, height: board.frame.height))
            pane.boxType = .custom
            pane.borderWidth = 0
            // No title strip and no margins: the box's content view is the whole pane.
            pane.titlePosition = .noTitle
            pane.contentViewMargins = .zero
            pane.fillColor = i == 0 ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.2, alpha: 1)
            pane.appearance = NSAppearance(named: name)
            var y = height
            for v in panes[i] {
                y -= v.frame.height
                v.frame.origin = NSPoint(x: 0, y: y)
                pane.addSubview(v)
            }
            board.addSubview(pane)
        }
        let window = NSWindow(contentRect: board.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = board
        board.layoutSubtreeIfNeeded()
        guard let rep = board.bitmapImageRepForCachingDisplay(in: board.bounds) else { return nil }
        board.cacheDisplay(in: board.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = Config.directory.appendingPathComponent("more-row-test.png")
        try? png.write(to: url)
        return url.path
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
        guard !applyingVodafone else { return }
        applyingVodafone = true
        askedVodafoneAt = nil
        // Marked applied only once the phone took it: a failed send is retried on
        // the next `/status` that carries the same SMS.
        send(["adjustMb": "\(adjust)"], what: "Vodafone's \(Double(v.remainingMb) / 1000) GB") { [weak self] ok in
            self?.applyingVodafone = false
            if ok { UserDefaults.standard.set(v.received.timeIntervalSince1970, forKey: Self.appliedKey) }
        }
    }
    private var applyingVodafone = false

    /// `GET /test/vodafone/ask`.
    func askVodafoneNow() { askVodafone() }

    @objc private func askVodafone() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.askedKey)
        askedVodafoneAt = Date()
        netInfo("📶 asking Vodafone (*123#) through the phone")
        phone.askVodafone { answer, error in
            netInfo("📶 *123# → \(answer ?? error ?? "?") — the balance follows by SMS")
            // The SMS lands ~10 s later. On the hotspot the 5 s `/status` brings it;
            // off it, only a Bluetooth poll does.
            for delay in [20.0, 60.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.askedVodafoneAt != nil else { return }
                    self.roaming.pollNow(reason: "Vodafone SMS")
                }
            }
        }
    }

    @objc private func toggleGuard() {
        let off = !(roaming.reading?.guardOff ?? false)
        send(["guardOff": off ? "1" : "0"], what: off ? "protection off until reset" : "protection on")
    }

    private func send(_ params: [String: String], what: String, done: ((Bool) -> Void)? = nil) {
        phone.configure(params) { reading, error in
            if let error {
                netError("📶 roaming setting (\(what)) not sent: \(error)")
            } else {
                netInfo("📶 roaming setting sent: \(what) → \(reading.map { RoamingWarningPolicy.gb($0.remaining) } ?? "?") left")
            }
            done?(error == nil)
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

    @objc private func togglePreferred() {
        PreferredWifiSettings.isEnabled.toggle()
        netInfo("🛜 Prefer \(Config.values["PREFERRED_SSID"] ?? "") over \(Config.hotspotSSID) \(PreferredWifiSettings.isEnabled ? "on" : "off")")
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
    /// The Wi-Fi password, **in clear by default** with a "Hide password" box
    /// (Victor, 2026-10-21: the other way round from macOS), in big type.
    static func wifiPassword(_ ssid: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Join “\(ssid)”"
        alert.informativeText = ""
        let font = NSFont.systemFont(ofSize: 18)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 92))
        let caption = NSTextField(labelWithString: "Password")
        caption.font = .systemFont(ofSize: 16, weight: .medium)
        caption.frame = NSRect(x: 0, y: 66, width: 340, height: 22)
        let plain = NSTextField(frame: NSRect(x: 0, y: 30, width: 340, height: 30))
        let secret = NSSecureTextField(frame: plain.frame)
        for f in [plain, secret] { f.font = font; f.placeholderString = "Wi-Fi password" }
        secret.isHidden = true
        let hide = NSButton(checkboxWithTitle: "Hide password", target: nil, action: nil)
        hide.font = .systemFont(ofSize: 15)
        hide.frame = NSRect(x: 0, y: 0, width: 340, height: 22)
        let toggler = HideToggler(plain: plain, secret: secret)
        hide.target = toggler
        hide.action = #selector(HideToggler.toggle(_:))
        [caption, plain, secret, hide].forEach(box.addSubview)
        alert.accessoryView = box
        alert.addButton(withTitle: "Join")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = plain
        let ok = alert.runModal() == .alertFirstButtonReturn
        _ = toggler
        return ok ? (secret.isHidden ? plain.stringValue : secret.stringValue) : nil
    }

    /// Swaps the clear field for the secure one, keeping what was typed.
    private final class HideToggler: NSObject {
        let plain: NSTextField, secret: NSSecureTextField
        init(plain: NSTextField, secret: NSSecureTextField) { self.plain = plain; self.secret = secret }
        @objc func toggle(_ sender: NSButton) {
            let hide = sender.state == .on
            if hide { secret.stringValue = plain.stringValue } else { plain.stringValue = secret.stringValue }
            plain.isHidden = hide
            secret.isHidden = !hide
            (hide ? secret : plain).window?.makeFirstResponder(hide ? secret : plain)
        }
    }

    static func show(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }


}
