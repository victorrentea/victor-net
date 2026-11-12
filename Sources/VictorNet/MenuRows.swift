import AppKit

/// Menu rows drawn by hand, to look and behave like macOS's own Wi-Fi menu
/// (Victor, 2026-10-20: *"the experience is far from the native Wi-Fi menu"*):
/// columns at fixed x so they line up whatever the names (tab stops in a title
/// could not — a long name pushed its row out), a rounded highlight under the
/// pointer, a click that acts. A view-backed `NSMenuItem` gets none of that
/// from AppKit, so it is here.
enum MenuRowLayout {
    /// The whole menu's width: 320 like the native one, wider only as far as the
    /// network cells shown need (Victor, 2026-11-08: 400 fixed was too wide).
    static var width: CGFloat { max(320, nameX + nameMin + 4 + cellWidth + 12) }
    static let height: CGFloat = 22
    static let checkX: CGFloat = 10
    static let iconX: CGFloat = 26
    static let nameX: CGFloat = 48
    /// Room for "Vodafone RO" under the hotspot too: 16 of indent plus the bars' age after them (2026-11-11).
    static let nameMin: CGFloat = 112
    /// The SIM rows under the hotspot and their roaming rows: 16 until 2026-11-12, then pulled left
    /// so "… - resets Dec 2" fits without widening the menu as much (Victor).
    static let simIndent: CGFloat = 4
    /// The widest "2.9↓MB/s ⋅ 2.5↑MB/s ⋅ 5↕︎ms ⋅ now" cell of the list being drawn —
    /// each number with its unit, no header over them, "seen" after a dot instead of
    /// in a column of its own (Victor, 2026-11-08).
    static var cellWidth: CGFloat = 130
    /// One column, right-aligned.
    static var columnRights: [CGFloat] { [width - 12] }
    static var columnWidths: [CGFloat] { [cellWidth] }
    static let statusRightInset: CGFloat = 12
}

final class MenuRowView: NSView {
    var onClick: (() -> Void)?
    /// Keep the menu open after the click (e.g. *Start Hotspot*, to watch it run).
    var keepsMenuOpen = false
    private let enabled: Bool
    private var highlighted = false { didSet { needsDisplay = true; recolor() } }
    private var labels: [(NSTextField, NSColor)] = []
    /// Number cells whose ↓ ↑ ↕︎ are green, redrawn on highlight (an attributed
    /// string keeps its own colours whatever `textColor` says).
    private var arrowCells: [(NSTextField, String, NSFont)] = []
    private var images: [NSImageView] = []

    /// `columns` sit right-aligned at `MenuRowLayout.columnRights`.
    init(name: String, columns: [String] = [], icon: NSImage? = nil, checked: Bool = false,
         enabled: Bool = true, dimmed: Bool = false, header: Bool = false, trailing: NSImage? = nil, bold: Bool = false,
         indent: CGFloat = 0, staleNumbers: Bool = false, width: CGFloat? = nil) {
        // Headers too: the networks' header measures the speed on a click.
        self.enabled = enabled
        let rowWidth = width ?? MenuRowLayout.width
        super.init(frame: NSRect(x: 0, y: 0, width: rowWidth,
                                 height: header ? 18 : MenuRowLayout.height))
        let size = header ? NSFont.smallSystemFontSize : NSFont.systemFontSize
        // Greyed only when unavailable (Ethernet unplugged); the network in use
        // is not clickable but reads in full colour.
        let base: NSColor = header || dimmed ? .tertiaryLabelColor : .labelColor
        if checked {
            add(label("✓", font: .systemFont(ofSize: size, weight: .semibold), color: base),
                x: MenuRowLayout.checkX + indent, width: 14)
        }
        // An icon wider than the slot (the SIM bars with their age after them) pushes the name right.
        let iconWidth = icon.map { $0.size.width > 22 ? $0.size.width : 18 } ?? 18
        let nameShift = max(0, iconWidth - 18)
        if let icon {
            let v = NSImageView(image: icon)
            v.alphaValue = dimmed ? 0.45 : 1
            v.frame = NSRect(x: MenuRowLayout.iconX + indent, y: (frame.height - 16) / 2, width: iconWidth, height: 16)
            v.imageScaling = .scaleProportionallyDown
            v.contentTintColor = base
            addSubview(v)
            images.append(v)
        }
        let nameEnd = columns.isEmpty ? rowWidth - 30
            : MenuRowLayout.columnRights[0] - MenuRowLayout.columnWidths[0] - 4
        let n = label(name, font: header ? .systemFont(ofSize: size, weight: .medium)
                      : .systemFont(ofSize: size, weight: bold ? .semibold : .regular), color: base)
        nameLabel = n
        n.lineBreakMode = .byTruncatingTail
        add(n, x: (header ? MenuRowLayout.checkX : MenuRowLayout.nameX) + indent + nameShift,
            width: nameEnd - indent - nameShift - (header ? MenuRowLayout.checkX : MenuRowLayout.nameX))
        for (i, text) in columns.enumerated() where i < MenuRowLayout.columnRights.count {
            // Header units in a size smaller, so "↓MB/s" fits its column.
            let c = label(text, font: header ? .systemFont(ofSize: size - 1, weight: .medium)
                          : .monospacedDigitSystemFont(ofSize: size - 1, weight: .regular),
                          color: header ? base : staleNumbers ? .tertiaryLabelColor : .secondaryLabelColor)
            c.alignment = .right
            if !header, text.contains(where: Self.arrows.contains) {
                // Old numbers (a SIM not in use) in grey, arrows included (Victor, 2026-11-08).
                let grey = NSColor.tertiaryLabelColor
                if !staleNumbers { arrowCells.append((c, text, c.font!)) }
                c.attributedStringValue = Self.greenArrows(text, font: c.font!, color: staleNumbers ? grey : .secondaryLabelColor,
                                                           arrows: staleNumbers ? grey : .systemGreen)
            }
            // A header has no name: its first column may run over that space.
            let width = header && i == 0 ? MenuRowLayout.columnRights[0] - MenuRowLayout.checkX : MenuRowLayout.columnWidths[i]
            add(c, x: MenuRowLayout.columnRights[i] - width, width: width)
        }
        if let trailing {
            let v = NSImageView(image: trailing)
            v.frame = NSRect(x: rowWidth - 26, y: (frame.height - 14) / 2, width: 14, height: 14)
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

    private var statusLabel: NSTextField?
    private var spinner: NSProgressIndicator?
    /// The status stands in the icon's place, before the name ("5 More…"),
    /// instead of the right corner. Set before the first `setStatus`.
    var statusBeforeName = false

    /// A spinning wheel while something runs, a short note after it. The wheel
    /// animates on its own thread, so it keeps turning while the menu tracks the mouse.
    private var nameLabel: NSTextField?
    func setName(_ name: String) { nameLabel?.stringValue = name }

    /// How wide the name is drawn, untruncated: a long one widens the menu ([StatusMenu]'s roaming rows).
    var nameWidth: CGFloat { ceil(nameLabel?.cell?.cellSize.width ?? 0) + 8 }   // the field's own inset, and a little air

    /// Swaps the row's icon, e.g. bars redrawn with a newer age.
    func setIcon(_ image: NSImage) { images.first?.image = image }

    func setStatus(_ text: String, spinning: Bool) {
        if statusLabel == nil {
            let l = label("", font: .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - (statusBeforeName ? 0 : 1), weight: .regular),
                          color: statusBeforeName ? .labelColor : .secondaryLabelColor)
            if statusBeforeName {
                l.alignment = .center
                add(l, x: MenuRowLayout.iconX - 4, width: 26)
            } else {
                l.alignment = .right
                add(l, x: frame.width - MenuRowLayout.statusRightInset - 150, width: 150)
            }
            statusLabel = l
            let s = NSProgressIndicator()
            s.style = .spinning
            s.controlSize = .small
            s.isIndeterminate = true
            s.usesThreadedAnimation = true
            s.isDisplayedWhenStopped = false
            addSubview(s)
            spinner = s
        }
        statusLabel?.stringValue = text
        if let l = statusLabel, let s = spinner {
            let w = (text as NSString).size(withAttributes: [.font: l.font as Any]).width
            let x = statusBeforeName ? MenuRowLayout.iconX + 1 : frame.width - MenuRowLayout.statusRightInset - w - 20
            s.frame = NSRect(x: x, y: (frame.height - 16) / 2, width: 16, height: 16)
            if spinning { s.startAnimation(nil) } else { s.stopAnimation(nil) }
        }
    }

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

    static let arrows: Set<Character> = ["↓", "↑", "↕︎", "↕"]

    /// How wide a number cell is drawn, to size `MenuRowLayout.cellWidth`.
    static func cellWidth(_ text: String) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        return ceil(greenArrows(text, font: font, color: .labelColor, arrows: .labelColor).size().width) + 4
    }

    /// "2.9↓MB/s": the arrows in `arrows` colour, the unit after them a size smaller.
    static func greenArrows(_ text: String, font: NSFont, color: NSColor, arrows arrowColor: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let unitFont = NSFont.systemFont(ofSize: font.pointSize - 1)
        var inUnit = false
        for ch in text {
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if arrows.contains(ch) {
                attrs[.foregroundColor] = arrowColor
                inUnit = true
            } else if inUnit, ch.isLetter || ch == "/" {
                attrs[.font] = unitFont
            } else {
                inUnit = false
            }
            out.append(NSAttributedString(string: String(ch), attributes: attrs))
        }
        return out
    }

    private func recolor() {
        for (l, c) in labels { l.textColor = highlighted ? .selectedMenuItemTextColor : c }
        for (l, text, font) in arrowCells {
            let c: NSColor = highlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
            l.attributedStringValue = Self.greenArrows(text, font: font, color: c, arrows: highlighted ? c : .systemGreen)
            l.alignment = .right
        }
        for v in images { v.contentTintColor = highlighted ? .selectedMenuItemTextColor : nil }
    }

    /// Where this row sits in a framed group — the hotspot and its SIMs (Victor, 2026-11-08).
    enum GroupEdge { case single, top, middle, bottom }
    var groupEdge: GroupEdge? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4).fill()
        }
        guard let edge = groupEdge else { return }
        // One rounded frame across several rows: each draws the frame stretched past the edges
        // it shares with a neighbour, clipped to itself, so only its own part shows.
        let r: CGFloat = 6, over = r * 2
        var frame = bounds.insetBy(dx: 4.5, dy: 0)
        let openTop = edge == .middle || edge == .bottom, openBottom = edge == .middle || edge == .top
        let (low, high) = isFlipped ? (openTop, openBottom) : (openBottom, openTop)
        frame.origin.y -= low ? over : -0.5
        frame.size.height += (low ? over : -0.5) + (high ? over : -0.5)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).setClip()
        NSColor.tertiaryLabelColor.setStroke()
        let path = NSBezierPath(roundedRect: frame, xRadius: r, yRadius: r)
        path.lineWidth = 1
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseEntered(with event: NSEvent) { highlighted = true }
    override func mouseExited(with event: NSEvent) { highlighted = false }

    override func mouseUp(with event: NSEvent) {
        guard enabled, let onClick else { return }
        if keepsMenuOpen {
            onClick()
        } else {
            highlighted = false
            // From a submenu too: closes the whole menu, not just that level.
            var menu = enclosingMenuItem?.menu
            while let parent = menu?.supermenu { menu = parent }
            menu?.cancelTracking()
            DispatchQueue.main.async(execute: onClick)
        }
    }
}

extension NSMenuItem {
    convenience init(view: NSView) {
        self.init()
        self.view = view
    }
}
