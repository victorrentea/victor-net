import AppKit

/// What the toast says about a clip from the phone. No AppKit, so a test can pin it.
enum ClipToastPolicy {
    static let maxPreview = 60
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

    /// **Never the content** (Victor, 13 Nov 2026): the screen may be shared, and no rule
    /// tells a password, a card or a one-time code from harmless text every time — the
    /// heuristics that tried missed "Your code is 482913" and hid years and prices. Only how
    /// much arrived. A lone link is the exception, and `show` names its host.
    static func preview(_ text: String) -> String {
        let n = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        return n == 1 ? "1 character" : "\(n) characters"
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

        let title = NSTextField(labelWithString: link == nil ? "📋 Copied from phone" : "🔗 Link copied from phone")
        title.font = .boldSystemFont(ofSize: 12)
        title.textColor = .white
        let body = NSTextField(labelWithString: link.map { $0.host ?? $0.absoluteString } ?? ClipToastPolicy.preview(text))
        body.font = .systemFont(ofSize: 11)
        body.textColor = NSColor.white.withAlphaComponent(0.75)
        body.lineBreakMode = .byTruncatingTail
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let texts = NSStackView(views: [title, body])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2

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
