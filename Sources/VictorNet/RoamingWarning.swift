import AppKit

/// 📶 The roaming allowance is nearly gone: a red pill bottom-left on every
/// screen, `📶 Roaming: 1.8 GB left (13%)`, on a day the phone roams and under
/// its low threshold (both numbers are the phone's; see `RoamingWarningPolicy`).
///
/// **It stays until hovered** — a warning that leaves on its own is one nobody
/// saw. The dismissal lasts for the rest of the day, persisted so restarts do
/// not bring it back; the next roaming day asks again. A pill and not a native
/// notification because macOS holds notifications back while a deck is
/// fullscreen, which is most of a training day.
///
/// In Victor Addons this rode on its shared `BottomLeftBanner`; this app has one
/// warning and draws it itself.
final class RoamingWarning {
    private static let dismissedKey = "roaming.warning.dismissed.day"
    private var reading: RoamingWarningPolicy.Reading?
    private var panels: [NSPanel] = []
    private var dayTimer: Timer?

    func start() {
        // The day flips under a pill nobody dismissed, and a stale reading has
        // to take it down: re-decide on a clock, not only on new readings.
        dayTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.evaluate() }
    }

    func update(_ r: RoamingWarningPolicy.Reading?) {
        reading = r
        evaluate()
    }

    /// `GET /test/roaming/reset-dismissal` — forget today's dismissal.
    func resetDismissal() {
        UserDefaults.standard.removeObject(forKey: Self.dismissedKey)
        evaluate()
    }

    private func evaluate() {
        let dismissed = UserDefaults.standard.string(forKey: Self.dismissedKey)
        guard RoamingWarningPolicy.shouldWarn(reading, now: Date(), dismissedDay: dismissed, calendar: .current),
              let r = reading else { return hide() }
        let text = RoamingWarningPolicy.text(r)
        if panels.isEmpty {
            panels = NSScreen.screens.map { makePanel(on: $0, text: text) }
            NSSound(named: NSSound.Name("Basso"))?.play()
            netInfo("📶 roaming warning shown: \(text)")
        } else {
            panels.forEach { ($0.contentView as? PillView)?.text = text }
        }
    }

    private func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
    }

    private func dismissForToday() {
        UserDefaults.standard.set(RoamingWarningPolicy.dayKey(Date(), calendar: .current), forKey: Self.dismissedKey)
        hide()
        netInfo("📶 roaming warning dismissed for today")
    }

    private func makePanel(on screen: NSScreen, text: String) -> NSPanel {
        let view = PillView(text: text)
        view.onHover = { [weak self] in self?.dismissForToday() }
        let size = view.fittingSize
        let origin = NSPoint(x: screen.visibleFrame.minX + 16, y: screen.visibleFrame.minY + 16)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = view
        panel.orderFrontRegardless()
        return panel
    }
}

/// The red pill. A hover held for 0.6 s puts it away: a deliberate gesture, not
/// the pointer passing by on its way somewhere.
private final class PillView: NSView {
    var onHover: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private var dwell: Timer?

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.88).cgColor
        layer?.cornerRadius = 14
        label.stringValue = text
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) {
        dwell = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in self?.onHover?() }
    }

    override func mouseExited(with event: NSEvent) {
        dwell?.invalidate()
        dwell = nil
    }
}
