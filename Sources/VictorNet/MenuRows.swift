import AppKit

/// Menu rows drawn by hand, to look and behave like macOS's own Wi-Fi menu
/// (Victor, 2026-10-20: *"the experience is far from the native Wi-Fi menu"*):
/// columns at fixed x so they line up whatever the names (tab stops in a title
/// could not — a long name pushed its row out), a rounded highlight under the
/// pointer, a click that acts. A view-backed `NSMenuItem` gets none of that
/// from AppKit, so it is here.
enum MenuRowLayout {
    /// The whole menu's width — narrow, like the native one.
    static let width: CGFloat = 300
    static let height: CGFloat = 22
    static let checkX: CGFloat = 10
    static let iconX: CGFloat = 26
    static let nameX: CGFloat = 48
    /// Right edges of the numeric columns: ↓, ↑, ping, seen.
    static let columnRights: [CGFloat] = [186, 226, 254, 290]
    static let columnWidth: CGFloat = 40
}

final class MenuRowView: NSView {
    var onClick: (() -> Void)?
    /// Keep the menu open after the click (e.g. expanding *Other Networks*).
    var keepsMenuOpen = false
    private let enabled: Bool
    private var highlighted = false { didSet { needsDisplay = true; recolor() } }
    private var labels: [(NSTextField, NSColor)] = []
    private var images: [NSImageView] = []

    /// `columns` sit right-aligned at `MenuRowLayout.columnRights`.
    init(name: String, columns: [String] = [], icon: NSImage? = nil, checked: Bool = false,
         enabled: Bool = true, dimmed: Bool = false, header: Bool = false, trailing: NSImage? = nil, bold: Bool = false) {
        self.enabled = enabled && !header
        super.init(frame: NSRect(x: 0, y: 0, width: MenuRowLayout.width,
                                 height: header ? 18 : MenuRowLayout.height))
        let size = header ? NSFont.smallSystemFontSize : NSFont.systemFontSize
        // Greyed only when unavailable (Ethernet unplugged); the network in use
        // is not clickable but reads in full colour.
        let base: NSColor = header || dimmed ? .tertiaryLabelColor : .labelColor
        if checked {
            add(label("✓", font: .systemFont(ofSize: size, weight: .semibold), color: base),
                x: MenuRowLayout.checkX, width: 14)
        }
        if let icon {
            let v = NSImageView(image: icon)
            v.frame = NSRect(x: MenuRowLayout.iconX, y: (frame.height - 16) / 2, width: 18, height: 16)
            v.imageScaling = .scaleProportionallyDown
            v.contentTintColor = base
            addSubview(v)
            images.append(v)
        }
        let nameEnd = columns.isEmpty ? MenuRowLayout.width - 30
            : MenuRowLayout.columnRights[0] - MenuRowLayout.columnWidth - 4
        let n = label(name, font: header ? .systemFont(ofSize: size, weight: .medium)
                      : .systemFont(ofSize: size, weight: bold ? .semibold : .regular), color: base)
        n.lineBreakMode = .byTruncatingTail
        add(n, x: header ? MenuRowLayout.checkX : MenuRowLayout.nameX, width: nameEnd - (header ? MenuRowLayout.checkX : MenuRowLayout.nameX))
        for (i, text) in columns.enumerated() where i < MenuRowLayout.columnRights.count {
            // Header units in a size smaller, so "↓MB/s" fits its column.
            let c = label(text, font: header ? .systemFont(ofSize: size - 1, weight: .medium)
                          : .monospacedDigitSystemFont(ofSize: size - 1, weight: .regular),
                          color: header ? base : .secondaryLabelColor)
            c.alignment = .right
            add(c, x: MenuRowLayout.columnRights[i] - MenuRowLayout.columnWidth, width: MenuRowLayout.columnWidth)
        }
        if let trailing {
            let v = NSImageView(image: trailing)
            v.frame = NSRect(x: MenuRowLayout.width - 26, y: (frame.height - 14) / 2, width: 14, height: 14)
            v.contentTintColor = .secondaryLabelColor
            addSubview(v)
            images.append(v)
        }
        if self.enabled {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func label(_ s: String, font: NSFont, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = font
        l.textColor = color
        labels.append((l, color))
        return l
    }

    private func add(_ l: NSTextField, x: CGFloat, width: CGFloat) {
        let h = l.intrinsicContentSize.height
        l.frame = NSRect(x: x, y: (frame.height - h) / 2, width: width, height: h)
        addSubview(l)
    }

    private func recolor() {
        for (l, c) in labels { l.textColor = highlighted ? .selectedMenuItemTextColor : c }
        for v in images { v.contentTintColor = highlighted ? .selectedMenuItemTextColor : nil }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard highlighted else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4).fill()
    }

    override func mouseEntered(with event: NSEvent) { highlighted = true }
    override func mouseExited(with event: NSEvent) { highlighted = false }

    override func mouseUp(with event: NSEvent) {
        guard enabled, let onClick else { return }
        if keepsMenuOpen {
            onClick()
        } else {
            highlighted = false
            enclosingMenuItem?.menu?.cancelTracking()
            DispatchQueue.main.async(execute: onClick)
        }
    }
}

/// "Wi-Fi" in bold with a switch on the right — macOS's first line.
final class MenuSwitchRow: NSView {
    private let toggle = NSSwitch()
    var onChange: ((Bool) -> Void)?

    init(title: String, on: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuRowLayout.width, height: 30))
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        l.frame = NSRect(x: MenuRowLayout.checkX + 4, y: 7, width: 150, height: 17)
        addSubview(l)
        toggle.controlSize = .small
        toggle.state = on ? .on : .off
        toggle.sizeToFit()
        toggle.frame.origin = NSPoint(x: MenuRowLayout.width - toggle.frame.width - 14, y: (30 - toggle.frame.height) / 2)
        toggle.target = self
        toggle.action = #selector(changed)
        addSubview(toggle)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() { onChange?(toggle.state == .on) }
}

extension NSMenuItem {
    convenience init(view: NSView) {
        self.init()
        self.view = view
    }
}
