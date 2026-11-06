import AppKit

/// When the phone needs a charger, and what the bar then says. No AppKit, so a test can pin it.
enum PhoneLowBattery {
    static let threshold = 30
    /// A phone that went quiet this long ago may have been charged since.
    static let maxAge: TimeInterval = 2 * 60 * 60

    static func showing(_ b: PhoneBattery?, now: Date) -> Int? {
        guard let b, b.pct <= threshold, !b.charging, now.timeIntervalSince(b.readAt) < maxAge else { return nil }
        return b.pct
    }
}

/// 🔋 The phone's own item in the menu bar, there only while it runs low, blinking slowly
/// in red (Victor, 2026-11-06). It replaces the battery warning that was Soduto's last job.
///
/// macOS puts a new item at the left of the others; `autosaveName` keeps it where it is dragged.
final class PhoneBatteryBar {
    private static let blink: TimeInterval = 1

    private var item: NSStatusItem?
    private var timer: Timer?
    private var bright = true
    private var simulated: Int?

    var reading: () -> PhoneBattery? = { nil }

    func start() {
        let t = Timer(timeInterval: Self.blink, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    /// `GET /test/phone-battery/simulate/<pct>`; nil goes back to the real reading.
    func simulate(_ pct: Int?) {
        simulated = pct
        tick()
    }

    var stateJSON: [String: Any] {
        ["showing": item != nil, "simulated": orNull(simulated)]
    }

    private func tick() {
        guard let pct = simulated ?? PhoneLowBattery.showing(reading(), now: Date()) else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        let shown = item ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        shown.autosaveName = "phone-battery"
        shown.button?.image = Icons.lowPhoneBattery(pct: pct, bright: bright)
        shown.button?.toolTip = "Phone battery: \(pct)%"
        item = shown
        bright.toggle()
    }
}
