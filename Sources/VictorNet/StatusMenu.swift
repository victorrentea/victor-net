import AppKit

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
        return SimSignalPolicy.generation(s.network, shown: s.shown)
    }

    /// The ⚠ / ✕ beside the bars: the data SIM's allowance, while roaming.
    private var roamingAlert: RoamingAlert? {
        RoamingAlertPolicy.alert(roaming.reading, left: roamingLeft ?? 0, now: Date())
    }

    /// What hovering the menu bar icon says (`/test/state`).
    var menuBarTooltip: String? { statusItem.button?.toolTip }

    /// The badge in words, or nil without one.
    private var roamingAlertReason: String? {
        guard let a = roamingAlert, let r = roaming.reading else { return nil }
        return RoamingAlertPolicy.reason(a, left: roamingLeft ?? r.remaining, sim: r.simName)
    }

    /// **The phone's bars, always** (Victor, 2026-11-12: the Wi-Fi is macOS's own icon again, this
    /// one is the phone): live on its hotspot, from its last answer (≤ 25 min) off it.
    func refreshIcon() {
        guard let button = statusItem.button else { return }
        var look = net.look
        let alert = roamingAlert
        let alertReason = roamingAlertReason
        button.title = ""
        switch look {
        case .hotspot(let level, _): look = .hotspot(level: level, alert: alert)
        case .away(let level, _): look = .away(level: level, alert: alert)
        }
        guard case .hotspot = look else {
            button.image = Icons.image(for: look)
            if case .away(nil, _) = look {
                button.toolTip = [alertReason, "The phone has not answered in the last 25 min"].compactMap { $0 }.joined(separator: "\n")
            } else {
                button.toolTip = alertReason
            }
            return
        }
        // On the hotspot with nothing behind it must not look connected (Victor, 2026-11-06).
        if offlineSince != nil || hotspot.progress.offline {
            button.image = Icons.noInternet(Icons.cellular(level: nil))
            button.toolTip = "On the phone's hotspot, but no internet behind it"
        } else if let hint = switchHint {
            // Blinks (Victor, 2026-11-11): a nudge to switch the data SIM by hand on the phone.
            let image = Icons.image(for: look, switchHint: true, network: barsNetwork)
            button.image = image.map { blinkBright ? $0 : Icons.faded($0, 0.3) }
            let hintText = hint.better.map { SimSwitchHint.tooltip($0, over: hint.sims) } ?? "Simulated ⇄"
            button.toolTip = [alertReason, hintText].compactMap { $0 }.joined(separator: "\n")
        } else {
            button.image = Icons.image(for: look, network: barsNetwork)
            button.toolTip = alertReason
        }
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        onOpen?()
        scanForHotspot()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateHotspotRow()
            self.updateBattery()
            self.updateSimBars()
            self.refreshNetworksIfChanged()
            if Date().timeIntervalSince(self.net.lastScanStarted ?? .distantPast) >= Self.scanEvery { self.scanForHotspot() }
        }
        RunLoop.main.add(t, forMode: .common)
        rescanTimer = t
    }

    /// The only scan left (Victor, 2026-11-12: the networks are macOS's menu again): whether the
    /// phone's hotspot is up, for Start / Stop, and only while this Mac is not on it. A scan
    /// takes ~5 s and briefly stalls the link, so not back to back.
    private static let scanEvery: TimeInterval = 5
    private func scanForHotspot() {
        guard Config.hasPhone, !Config.hotspotSSID.isEmpty, !net.onHotspot, !net.scanning else { return }
        net.scanInBackground()
    }

    func menuDidClose(_ menu: NSMenu) {
        rescanTimer?.invalidate()
        rescanTimer = nil
        networkItems = []
        stopClimbingBars()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        net.refresh()

        // The hotspot button, the network in use with its numbers, the phone's SIMs with
        // theirs. Picking a Wi-Fi is macOS's own menu (Victor, 2026-11-12).
        MenuRowLayout.cellWidth = 0
        networkItems = networkSection()
        if Config.hasPhone, !Config.hotspotSSID.isEmpty {
            menu.addItem(hotspotButtonItem())
            // Right under Start, which it automates (Victor, 2026-11-12).
            // A drawn row like the button, so their icons line up: a native item sits 4 pt to the left.
            let auto = MenuRowView(name: "Auto-Start on no Internet", icon: Icons.hotspot(),
                                   checked: HotspotFallbackSettings.isEnabled)
            auto.onClick = { [weak self] in self?.toggleHotspot() }
            menu.addItem(NSMenuItem(view: auto))
            menu.addItem(.separator())
        }
        networkItems.forEach(menu.addItem)

        menu.addItem(.separator())
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
        menu.addItem(info("Built \(BuildInfo.time)"))
        // No ⌘Q shown: its column made the whole menu wider for nothing.
        menu.addItem(action("Quit", #selector(quitAction)))
    }

    /// The phone's battery on the hotspot's row (Victor, 2026-11-12: at the bottom, greyed, it was
    /// almost invisible), its age ticking while the menu is open.
    private weak var batteryRow: MenuRowView?

    private func updateBattery() {
        guard let row = batteryRow, let b = phoneBattery?() else { return }
        row.setStatus(b.rowText(now: Date()), spinning: false)
    }

    private func speedTitle() -> String {
        if traffic.speedTestRunning { return "Testing speed…" }
        let mb = traffic.network?.kind == "hotspot" ? 10 : 25
        return "Run speed test (\(mb)MB)"
    }

    // MARK: - This network and the phone's SIMs

    /// The network rows, and which network they were drawn for.
    private var networkItems: [NSMenuItem] = []
    private var drawnFor = ""

    private var offlineSince: Date? {
        traffic.offlineSince.flatMap { Date().timeIntervalSince($0) >= 5 ? $0 : nil }
    }

    private func networkSection() -> [NSMenuItem] {
        drawnFor = networkSignature
        guard let since = offlineSince else { return networkRows() }
        let offline = NSMenuItem(view: MenuRowView(
            name: "Offline \(NetworkBookPolicy.duration(Date().timeIntervalSince(since)))",
            icon: Icons.noTraffic(), enabled: false, dimmed: true))
        return [offline] + networkRows(current: false)
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
    }

    private var rescanTimer: Timer?

    /// **This network, now** — one row, so the hotel Wi-Fi can still be held against the hotspot
    /// (Victor, 2026-11-12: the list of other networks went back to macOS) — then the phone's
    /// hotspot framed with its SIMs. On the hotspot the first row is left out: its numbers are
    /// the data SIM's. `current: false` while offline, when "Offline N min" stands in its place.
    private func networkRows(current showCurrent: Bool = true) -> [NSMenuItem] {
        let now = Date()
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
        let hasHotspot = Config.hasPhone && !Config.hotspotSSID.isEmpty
        let hotspotJoined = hasHotspot && net.ssid == Config.hotspotSSID
        // The SIM rows under the hotspot: live while it is in use, what each gave before while it is off.
        let simEntries = hotspotJoined ? liveSimEntries(records: records) : idleSimEntries(records: records)
        let here: (id: NetworkID, record: NetworkRecord)? = showCurrent && !hotspotJoined
            ? traffic.network.flatMap { id in records[id.key].map { (id, $0) } } : nil
        // One unit for all rows, so the column reads straight down: KB/s
        // while nothing reaches 1 MB/s, MB/s otherwise (Victor, 2026-10-20).
        let unit = TrafficPolicy.listUnit(((here.map { [$0.record] } ?? []) + simEntries.compactMap(\.record))
            .flatMap { [$0.maxDown, $0.maxUp, $0.speedDown ?? 0] })
        let rate: (Double) -> String = { $0 > 0 ? unit.format($0) : "—" }
        // Each number with its unit, the arrow before the unit (Victor, 2026-11-08):
        // "2.9↓MB/s ⋅ 2.5↑MB/s ⋅ 5↕︎ms" — the header that labelled them is gone.
        // A SIM not in use shows its speed test as ↓ when it had one, after a ⚡ (Victor, 2026-11-09).
        func cell(_ r: NetworkRecord, _ seen: String, unused: Bool) -> String {
            let test = unused ? r.speedDown : nil
            // Thin spaces around the dot: the full ones cost the menu 14 pt.
            return (test == nil ? "" : "⚡\u{2009}")
                + "\(rate(test ?? r.maxDown))↓\(unit.name)\u{2009}⋅\u{2009}\(rate(r.maxUp))↑\(unit.name)\u{2009}⋅\u{2009}"
                + (r.latencyMs.map { String(format: "%.0f", $0) } ?? "—") + "↕︎ms\u{2009}⋅\u{2009}\(seen)"
        }
        // Only grows: rows redrawn while the menu is open keep the width it opened with.
        let texts = (here.map { [cell($0.record, "now", unused: false)] } ?? [])
            + simEntries.compactMap { e in e.record.map { cell($0, e.seen, unused: !e.isData) } }
        MenuRowLayout.cellWidth = max(MenuRowLayout.cellWidth, texts.map(MenuRowView.cellWidth).max() ?? 0)
        // The roaming rows under the SIMs whole, not cut ("… - resets Dec 2"): the menu widens for them.
        // Their name starts at nameX + simIndent and leaves 30 for the ↺ on the right.
        let roamingNeed = simEntries.flatMap { simRoamingRows($0.name).map(\.nameWidth) }.max() ?? 0
        MenuRowLayout.cellWidth = max(MenuRowLayout.cellWidth,
                                      roamingNeed + MenuRowLayout.simIndent + 30 - (MenuRowLayout.nameMin + 4 + 12))

        var items: [NSMenuItem] = []
        roamingPlaced = []
        if let here {
            let wired = here.id.kind == "wired"
            let row = MenuRowView(name: wired ? "Ethernet" : net.ssid ?? "Wi-Fi",
                                  columns: [cell(here.record, "now", unused: false)],
                                  icon: wired ? Icons.wired() : Icons.wifi(strength: net.rssi.map(NetworkLookPolicy.strength(rssi:)) ?? 0),
                                  checked: true, enabled: false)
            row.toolTip = "The network this Mac is on, best over the last hour: ↓ download and ↑ upload (5 s average), ↕︎ latency to 1.1.1.1"
            items.append(NSMenuItem(view: row))
        }
        guard hasHotspot else { return items }
        // The hotspot's numbers are its SIMs', on their rows under it (Victor, 2026-11-08), each
        // SIM's roaming allowance right under it, in the same frame (Victor, 2026-11-12). Not
        // clickable: Start / Stop is the button at the top, joining it is macOS's Wi-Fi menu.
        let sims = zip(simEntries, simRowViews(simEntries, cell: cell)).flatMap { e, row in
            [NSMenuItem(view: row)] + simRoamingRows(e.name).map { NSMenuItem(view: $0) }
        }
        let head = MenuRowView(name: Config.hotspotSSID, icon: Icons.hotspot(), checked: hotspotJoined, enabled: false)
        frame(head, sims.compactMap { $0.view as? MenuRowView })
        batteryRow = head
        updateBattery()
        items.append(NSMenuItem(view: head))
        return items + sims
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
        var bars: (level: Int, network: String?, readAt: Date)? = nil   // network: already as shown ("5G", "4G+")
        var isData: Bool { signal?.isData ?? false }
    }

    /// The SIMs' signal from the phone's `/status` off the hotspot: over the home Wi-Fi (`PhoneLan`)
    /// or Bluetooth (`PhoneRoamingMonitor`), every 10 / 20 min and once more at each menu opening.
    var offHotspotSignal: PhoneSignal? {
        get { net.offHotspotSignal }
        set { net.offHotspotSignal = newValue; refreshIcon() }
    }

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
            if let sim, let reading { e.bars = (sim.level, SimSignalPolicy.generation(sim.network, shown: sim.shown), reading.readAt) }
            return e
        }
    }

    /// A SIM not carrying data: what it gave at this place (`SimLog`), its speed test there after a ⚡
    /// if one ran there. **Only this place** (Victor, 2026-11-12): its best anywhere showed yoxo's
    /// Bucharest speed test in Utrecht as if run here. Nothing measured here = nil, no numbers.
    private func idleSim(_ name: String, records: [String: NetworkRecord]) -> (NetworkRecord, here: Bool)? {
        guard let spot = simHere?()[name] else { return nil }
        var r = NetworkRecord(name: name, kind: "sim", lastSeen: spot.lastSeen)
        // A spot filed before it kept ↓ ↑ lacks them: none, rather than another place's.
        r.maxDown = spot.maxDown ?? 0
        r.maxUp = spot.maxUp ?? 0
        r.latencyMs = SimLogPolicy.median(spot.latency)
        r.speedDown = spot.speed
        r.speedAt = spot.speedAt
        return (r, true)
    }

    /// Each SIM with the same numbers as a network — best ↓ ↑ (⚡ = a speed test's ↓), latency
    /// and when last used — and, while on the hotspot, the bars the phone sees for it now.
    private func simRowViews(_ entries: [SimEntry], cell: (NetworkRecord, String, Bool) -> String) -> [MenuRowView] {
        let now = Date()
        let readAt = net.phoneSignal?.readAt ?? now
        simAgeRows = []
        return entries.map { e in
            let icon = e.signal.map { Icons.cellular(level: $0.level, network: SimSignalPolicy.generation($0.network, shown: $0.shown),
                                                     age: SimSignalPolicy.age(readAt, now: now)) }
                ?? e.bars.map { Icons.cellular(level: $0.level, network: $0.network,
                                               age: SimSignalPolicy.age($0.readAt, now: now)) }
                // No reading yet: an empty slot the bars fill once the phone answers (asked at the opening).
                ?? NSImage(size: NSSize(width: Icons.cellularWithAgeWidth, height: Icons.barHeight))
            let row = MenuRowView(name: e.label, columns: e.record.map { [cell($0, e.seen, !e.isData)] } ?? [],
                                  icon: icon, checked: e.isData, enabled: false, indent: MenuRowLayout.simIndent, staleNumbers: !e.isData)
            simAgeRows.append((row, e.name))
            let test = !e.isData && e.record?.speedDown != nil
            row.toolTip = e.record == nil ? "Nothing measured on this SIM here yet"
                : (e.isData ? "Best over the last hour on this SIM"
                   : "Measured here before, through the hotspot on this SIM")
                + (test ? ": ⚡ ↓ from a speed test, ↑ upload (5 s average), ↕︎ latency to 1.1.1.1"
                   : ": ↓ download and ↑ upload (5 s average), ↕︎ latency to 1.1.1.1")
            return row
        }
    }

    private func frame(_ head: MenuRowView, _ children: [MenuRowView]) {
        head.groupEdge = children.isEmpty ? .single : .top
        for (i, c) in children.enumerated() { c.groupEdge = i == children.count - 1 ? .bottom : .middle }
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
            row.setIcon(Icons.cellular(level: sim?.level, network: SimSignalPolicy.generation(sim?.network, shown: sim?.shown),
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
        // The countdown alone: the title already says what is going on. While starting, the
        // climbing bars are the progress, so no wheel next to them.
        case .asking, .starting, .start: row.setStatus(status.text.replacingOccurrences(of: "asking phone ", with: "")
                                                           .replacingOccurrences(of: "joining ", with: ""),
                                                       spinning: status.spinning && state != .starting)
        }
        if state == .starting { startClimbingBars() } else { stopClimbingBars() }
        row.toolTip = p.lastFailure.map { "Last attempt: \($0)" }
    }

    /// `HotspotRowPolicy.climbingBars`: its own timer, faster than the menu's 1 s one, in the
    /// common modes so it keeps going while the menu tracks the mouse.
    private var climbTimer: Timer?
    private var climbStarted = Date()

    private func startClimbingBars() {
        guard climbTimer == nil else { return }
        climbStarted = Date()
        let tick = { [weak self] in
            guard let self, let row = self.hotspotRow else { return }
            let level = HotspotRowPolicy.climbingBars(elapsed: Date().timeIntervalSince(self.climbStarted))
            row.setIcon(Icons.cellular(level: level))
        }
        tick()
        let t = Timer(timeInterval: HotspotRowPolicy.climbStep, repeats: true) { _ in tick() }
        RunLoop.main.add(t, forMode: .common)
        climbTimer = t
    }

    private func stopClimbingBars() {
        climbTimer?.invalidate()
        climbTimer = nil
    }

    // MARK: - Roaming

    /// Only roaming counts (at home the data is unlimited): what is left, of how
    /// much in all this cycle — the used part plus what is left.
    private func addRoamingRows() {
        let gb: (Int64) -> String = { String(format: "%.1f", Double($0) / 1e9) }
        let day = DateFormatter()
        day.dateFormat = "d MMM"
        if let r = roaming.reading, r.sims.count > 1, r.sims.allSatisfy({ roamingPlaced.contains($0.simName ?? "") }) {
            // Every SIM's allowance already sits under its SIM row.
        } else if let r = roaming.reading {
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
            if r.sims.count > 1 {
                // One allowance per SIM (Victor, 2026-11-11), each with its own plan and
                // reset day. Only the data SIM's moves with this Mac's traffic.
                for sim in r.sims where !roamingPlaced.contains(sim.simName ?? "") {
                    let simLeft = sim.isData ? left : sim.remaining
                    let mark = sim.isData ? roamingAlert.map(RoamingAlertPolicy.emoji) ?? "✈️" : "✈️"
                    let title = "\(mark) \(sim.simName ?? sim.simKey ?? "SIM"): \(gb(simLeft))/\(gb(simLeft + sim.cycleTotal)) GB left until \(day.string(from: sim.nextReset + 12 * 3600))\(asOf)"
                    if sim.simKey == "22601" { roamingRow(title) } else { otherSimRow(title, sim) }
                }
            } else {
                roamingRow("\(roamingAlert.map(RoamingAlertPolicy.emoji) ?? "✈️") Roaming: \(gb(left))/\(gb(left + r.cycleTotal)) GB left until \(day.string(from: r.nextReset + 12 * 3600))\(asOf)")
            }
        } else {
            roamingRow("✈️ Roaming: the phone has not answered yet")
        }
        // Said the positive way, ticked by default.
        let allow = action("✈️ Roaming: Allow Claude", #selector(toggleSuspend))
        allow.state = RoamingDataSettings.suspendClaude ? .off : .on
        menu.addItem(allow)
        if let r = roaming.reading {
            // No glyph before the plane, and short (Victor, 2026-11-12).
            let stop = action("✈️ Roaming: Stop under \(String(format: "%.0f", Double(r.reserve) / 1e9)) GB", #selector(toggleGuard))
            stop.toolTip = "Only while the phone is roaming: on the home network the hotspot is never stopped"
            stop.state = r.guardOff ? .off : .on
            menu.addItem(stop)
        }
    }

    /// Home over the hotspot, when both are in range. (Auto-Start sits under the Start button.)
    private func addAutoJoinRows() {
        if let home = Config.values["PREFERRED_SSID"], !home.isEmpty {
            let prefer = action("Prefer \(home) over \(Config.hotspotSSID)", #selector(togglePreferred))
            prefer.image = Icons.wifi(strength: 1)
            prefer.state = PreferredWifiSettings.isEnabled ? .on : .off
            menu.addItem(prefer)
        }
    }

    private func roamingRow(_ title: String) {
        let asking = askedVodafoneAt.map { Date().timeIntervalSince($0) < 180 } ?? false
        let row = action(asking ? "\(title) — asking Vodafone…" : title, #selector(askVodafone))
        row.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Ask Vodafone")
        row.toolTip = "Ask Vodafone (*123#, through the phone) for what is left"
        row.isEnabled = !asking
        menu.addItem(row)
    }

    /// A SIM no `*123#` answers for (yoxo has no balance code, only its app): the
    /// phone's own count against the plan. A click asks the phone again.
    private func otherSimRow(_ title: String, _ sim: RoamingWarningPolicy.Reading) {
        let row = action(title, #selector(pollRoaming))
        row.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Ask the phone")
        row.toolTip = "Counted by the phone while \(sim.simName ?? "this SIM") carried the data, against its \(String(format: "%.2f", Double(sim.planMb ?? 0) / 1000)) GB plan"
        menu.addItem(row)
    }

    @objc private func pollRoaming() { roaming.pollNow(reason: "menu") }

    /// The SIMs whose allowance was drawn under their SIM row this time, so the roaming group skips them.
    private var roamingPlaced: Set<String> = []

    /// A SIM's roaming allowance as a row under it (Victor, 2026-11-12): "✈️ 6.7/13.4 GB left · 2 Dec".
    /// Vodafone's click asks `*123#`; any other SIM's asks the phone for a new count. Nil without a
    /// per-SIM reading for it (an older phone app), and then the roaming group shows it as before.
    private func simRoamingRows(_ name: String) -> [MenuRowView] {
        guard let r = roaming.reading, r.sims.count > 1, let sim = r.sims.first(where: { $0.simName == name }) else { return [] }
        roamingPlaced.insert(name)
        let gb: (Int64) -> String = { String(format: "%.1f", Double($0) / 1e9) }
        let day = DateFormatter()
        day.dateFormat = "d MMM"
        // Only the data SIM's moves with this Mac's traffic between the phone's answers.
        let left = sim.isData ? (roamingLeft ?? sim.remaining) : sim.remaining
        // Victor's wording, 2026-11-12, on two lines: "1.2GB (9%) left at 20:30" (no "/13.4", the % says
        // it), then "resets to 13.4GB on Dec 2" with the ↺ — a click there asks again.
        let at = DateFormatter()
        at.locale = Locale(identifier: "en_US_POSIX")   // 24 h whatever the system clock says
        // The date only when the count is from another day (Victor, 2026-11-12).
        at.dateFormat = Calendar.current.isDateInToday(sim.readAt) ? "HH:mm" : "MMM d HH:mm"
        let pct = sim.limit > 0 ? Int((Double(left) / Double(sim.limit) * 100).rounded()) : 0
        let vodafone = sim.simKey == "22601"
        let asking = vodafone && (askedVodafoneAt.map { Date().timeIntervalSince($0) < 180 } ?? false)
        // +12 h: the reset is midnight in the phone's time zone, which may still be the day before here.
        let resets = DateFormatter()
        resets.locale = Locale(identifier: "en_US_POSIX")
        resets.dateFormat = "MMM d"
        // The menu bar's ⚠ / ✕ belongs to the data SIM: its row says so too, in place of ✈️.
        let alert = sim.isData ? roamingAlert : nil
        let left1 = MenuRowView(name: "\(alert.map(RoamingAlertPolicy.emoji) ?? "✈️") \(gb(left))GB (\(pct)%) left at \(at.string(from: sim.readAt))",
                                enabled: false, indent: MenuRowLayout.simIndent)
        // Under the text of the line above, past its emoji.
        let row = MenuRowView(name: "resets to \(gb(sim.limit))GB on \(resets.string(from: sim.nextReset + 12 * 3600))" + (asking ? " · asking…" : ""),
                              enabled: !asking,
                              trailing: NSImage(systemSymbolName: vodafone ? "arrow.counterclockwise" : "arrow.clockwise",
                                                accessibilityDescription: vodafone ? "Ask Vodafone" : "Ask the phone"),
                              indent: MenuRowLayout.simIndent + 22)
        let live = sim.isData && roamingLeft != nil
            ? " The GB move on with what this Mac pulled through the hotspot since then." : ""
        row.toolTip = (alert.map { RoamingAlertPolicy.reason($0, left: left, sim: name) + ".\n" } ?? "")
            + "Counted by the phone at \(at.string(from: sim.readAt)).\(live) "
            + (vodafone ? "Click: ask Vodafone (*123#, through the phone)"
               : "Against its \(String(format: "%.2f", Double(sim.planMb ?? 0) / 1000)) GB plan, while \(name) carried the data (no balance code for it). Click: ask the phone again")
        left1.toolTip = row.toolTip
        row.onClick = { [weak self] in vodafone ? self?.askVodafone() : self?.pollRoaming() }
        return [left1, row]
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

    /// `GET /test/menu/render` — the hotspot button in each state, the rows as they are now plus
    /// sample ones, drawn off-screen on a light and a dark menu, to look at without opening the menu.
    func renderRowsForTest() -> String? {
        let rows: [(name: String, status: String, spinning: Bool)] = [
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
            out += networkRows().compactMap(\.view)
            let head = MenuRowView(name: "victor", icon: Icons.hotspot(), checked: true)
            out.append(head)
            var yoxo = NetworkRecord(name: "yoxo", kind: "sim", lastSeen: Date()); yoxo.maxDown = 2_100_000; yoxo.maxUp = 900_000; yoxo.latencyMs = 36
            var vic = NetworkRecord(name: "Vic", kind: "sim", lastSeen: Date().addingTimeInterval(-7200)); vic.maxDown = 1_300_000; vic.maxUp = 400_000; vic.latencyMs = 53
            vic.speedDown = 9_050_000
            let sims = [(SimSignal(name: "yoxo", isData: true, level: 3, operatorName: "orange", network: "LTE", rsrp: -97, sinr: -5, shown: "4G+"), yoxo as NetworkRecord?),
                        (SimSignal(name: "Vic", isData: false, level: 4, operatorName: "Vodafone RO", network: "5G", rsrp: -85, sinr: 21), vic),
                        (SimSignal(name: "Maya", isData: false, level: 0, network: nil, rsrp: nil, sinr: nil), nil)]
            let simRows = simRowViews(sims.map { SimEntry(name: $0.0.name, label: SimSignalPolicy.label($0.0), signal: $0.0, record: $0.1,
                                                   here: true, seen: $0.0.isData ? "now" : "2 h") },
                               cell: { r, seen, unused in (unused && r.speedDown != nil ? "⚡\u{2009}" : "")
                                   + "\(TrafficPolicy.rate(unused ? r.speedDown ?? r.maxDown : r.maxDown))↓\u{2009}⋅\u{2009}\(TrafficPolicy.rate(r.maxUp))↑\u{2009}⋅\u{2009}\(Int(r.latencyMs ?? 0))↕︎ms\u{2009}⋅\u{2009}\(seen)" })
            // Each SIM's roaming allowance under it, from the phone's real reading.
            let framed = zip(sims, simRows).flatMap { s, row in [row] + simRoamingRows(s.0.name) }
            out += framed
            frame(head, framed)
            // Off: what each SIM gave here before, in grey.
            let off = MenuRowView(name: "victor", icon: Icons.hotspot())
            out.append(off)
            for (name, cellText) in [("Orange", "2.1↓MB/s\u{2009}⋅\u{2009}0.9↑MB/s\u{2009}⋅\u{2009}36↕︎ms\u{2009}⋅\u{2009}3 days"),
                                     ("Vodafone", "1.3↓MB/s\u{2009}⋅\u{2009}0.4↑MB/s\u{2009}⋅\u{2009}53↕︎ms\u{2009}⋅\u{2009}3 days")] {
                out.append(MenuRowView(name: name, columns: [cellText], icon: Icons.cellular(level: nil, ageSlot: true), enabled: false,
                                       indent: MenuRowLayout.simIndent, staleNumbers: true))
            }
            frame(off, Array(out.suffix(2)).compactMap { $0 as? MenuRowView })
            out.append(MenuRowView(name: "Hotel-Guest-Wireless-5G", columns: [samples[0]],
                                   icon: Icons.wifi(strength: 0.5), checked: true, enabled: false))
            out.append(MenuRowView(name: "Ethernet", columns: [samples[1]],
                                   icon: Icons.wired(), checked: true, enabled: false))
            for r in rows {
                let row = MenuRowView(name: Config.hotspotSSID, icon: Icons.hotspot())
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
        let url = Config.directory.appendingPathComponent("menu-render-test.png")
        try? png.write(to: url)
        return url.path
    }

    /// `GET /test/icon` — the icon as it is now, 8×, on a light and a dark bar.
    func renderIconForTest() -> String? {
        guard let icon = statusItem.button?.image else { return nil }
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
        // Vodafone's SIM, whichever SIM carries the data now (yoxo has its own plan).
        guard v.received.timeIntervalSince1970 > applied, let top = roaming.reading else { return }
        let r = top.vodafone
        guard let plan = r.planMb else { return }
        let adjust = VodafonePolicy.adjustMb(v, planMb: plan, usedNowBytes: r.cycleTotal)
        netInfo("📶 Vodafone says \(Double(v.remainingMb) / 1000) GB left (data of \(v.at)) → adjust \(adjust) MB")
        guard !applyingVodafone else { return }
        applyingVodafone = true
        askedVodafoneAt = nil
        // Marked applied only once the phone took it: a failed send is retried on
        // the next `/status` that carries the same SMS.
        var params = ["adjustMb": "\(adjust)"]
        if let key = r.simKey { params["sim"] = key }
        send(params, what: "Vodafone's \(Double(v.remainingMb) / 1000) GB") { [weak self] ok in
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
