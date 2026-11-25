import AppKit

/// What the toast says about a clip from the phone. No AppKit, so a test can pin it.
enum ClipToastPolicy {
    static let stay: TimeInterval = 4
    /// Longer when there is a button to reach for.
    static let stayWithLink: TimeInterval = 9

    /// The clip is one web address and nothing else: `https://…`, `http://…` or `www.…`.
    static func link(in text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        let lower = t.lowercased()
        let candidate = lower.hasPrefix("www.") ? "https://" + t : t
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www."),
              let url = URL(string: candidate), let host = url.host, host.contains(".") else { return nil }
        return url
    }

    /// How many characters of the clip the toast shows (Victor, 25 Nov 2026): enough to tell
    /// which copy arrived, too few to give away a password, a card or a one-time code on a
    /// shared screen. Until then it showed none, only the length (13 Nov 2026).
    static let shownChars = 3

    /// `abc…`: the first characters only, on one line (newlines and tabs made spaces);
    /// a clip that short is shown whole. No length, no quotes (Victor, 25 Nov 2026: the toast is
    /// one line, `📋 From phone: abc…`). A lone link is the exception, and `show` names its host.
    static func preview(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = String(t.prefix(shownChars).map { $0.isWhitespace || $0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } ? " " : $0 })
        return head + (t.count > shownChars ? "…" : "")
    }

    /// The toast's only line: `📋 From phone: abc…`, or `🔗 From phone: example.com` for a link.
    static func line(_ text: String) -> (label: String, what: String) {
        if let url = link(in: text) { return ("🔗 From phone:", url.host ?? url.absoluteString) }
        return ("📋 From phone:", preview(text))
    }
}

/// 📋 A small toast in the top-right corner when the phone's clipboard lands here, with
/// "Open" when it is a link (Emma, 2026-11-08). A panel of our own, not a system
/// notification: no permission to ask for, and it never takes the focus from the app in front.
final class ClipToast {
    private var panel: NSPanel?
    private var timer: Timer?
    private(set) var lastShown: (Date, Bool)?

    func show(_ text: String) {
        let link = ClipToastPolicy.link(in: text)
        lastShown = (Date(), link != nil)
        close()

        let (label, what) = ClipToastPolicy.line(text)
        let shown = NSMutableAttributedString(string: label, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.white])
        shown.append(NSAttributedString(string: " " + what, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white.withAlphaComponent(0.8)]))
        let texts = NSTextField(labelWithAttributedString: shown)
        texts.lineBreakMode = .byTruncatingTail
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var row: [NSView] = [texts]
        if let link {
            let open = ToastButton(title: "Open in Browser") { [weak self] in
                NSWorkspace.shared.open(link)
                self?.close()
            }
            // Drawn by hand: a system button in a window that is never key looks disabled.
            open.isBordered = false
            open.wantsLayer = true
            open.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            open.layer?.cornerRadius = 6
            open.attributedTitle = NSAttributedString(string: open.title, attributes: [
                .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
            open.translatesAutoresizingMaskIntoConstraints = false
            open.heightAnchor.constraint(equalToConstant: 26).isActive = true
            open.widthAnchor.constraint(equalToConstant: open.intrinsicContentSize.width + 20).isActive = true
            row.append(open)
        }
        let stack = NSStackView(views: row)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 12)

        let back = ToastView { [weak self] hovering in
            hovering ? self?.timer?.invalidate() : self?.closeLater(link == nil ? ClipToastPolicy.stay : ClipToastPolicy.stayWithLink)
        }
        back.material = .hudWindow
        back.blendingMode = .behindWindow
        back.state = .active
        back.wantsLayer = true
        back.layer?.cornerRadius = 10
        back.layer?.masksToBounds = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        back.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: back.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: back.trailingAnchor),
            stack.topAnchor.constraint(equalTo: back.topAnchor),
            stack.bottomAnchor.constraint(equalTo: back.bottomAnchor),
            back.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
        let size = stack.fittingSize

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.contentView = back
        p.appearance = NSAppearance(named: .vibrantDark)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: area.maxX - size.width - 12, y: area.maxY - size.height - 8))
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        panel = p
        closeLater(link == nil ? ClipToastPolicy.stay : ClipToastPolicy.stayWithLink)
    }

    /// The toast on screen, drawn to a PNG: a check that works with the display asleep.
    func png() -> Data? {
        guard let view = panel?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private func closeLater(_ after: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: after, repeats: false) { [weak self] _ in self?.fadeOut() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func fadeOut() {
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p.animator().alphaValue = 0 }) { [weak self] in
            if self?.panel === p { self?.close() }
        }
    }

    private func close() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

/// The toast's background: hovering keeps it up, a click elsewhere on it dismisses it.
private final class ToastView: NSVisualEffectView {
    private let hover: (Bool) -> Void
    private var area: NSTrackingArea?

    init(hover: @escaping (Bool) -> Void) {
        self.hover = hover
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { hover(true) }
    override func mouseExited(with event: NSEvent) { hover(false) }
    override func mouseDown(with event: NSEvent) { window?.orderOut(nil) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A button that fires on the first click, though the panel never becomes key.
private final class ToastButton: NSButton {
    private let action_: () -> Void

    init(title: String, action: @escaping () -> Void) {
        action_ = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { action_() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
