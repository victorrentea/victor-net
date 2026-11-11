import AppKit

/// The menu bar glyphs, drawn rather than taken from emoji so they sit in the
/// menu bar like the system's own: template images, painted by AppKit in the
/// bar's colour and inverted when highlighted.
enum Icons {
    static let barHeight: CGFloat = 16

    /// A cable: **open angle brackets** pointing apart with two dashes between
    /// them — `< ‐ ‐ >` (Victor, 2026-10-20, after filled and then hollow
    /// triangles). The same glyph is the menu bar icon on a cable and, tinted, the
    /// Ethernet row's icon in the menu.
    static func wired() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: barHeight), flipped: false) { rect in
            NSColor.black.set()
            let y = rect.midY
            for (tip, dir) in [(CGFloat(1.6), CGFloat(1)), (CGFloat(18.4), CGFloat(-1))] {
                let chevron = NSBezierPath()
                chevron.move(to: NSPoint(x: tip + 4 * dir, y: y + 4))
                chevron.line(to: NSPoint(x: tip, y: y))
                chevron.line(to: NSPoint(x: tip + 4 * dir, y: y - 4))
                chevron.lineWidth = 1.5
                chevron.lineCapStyle = .round
                chevron.lineJoinStyle = .round
                chevron.stroke()
            }
            for x in [CGFloat(6.6), 11.1] {
                NSBezierPath(roundedRect: NSRect(x: x, y: y - 0.7, width: 2.3, height: 1.4), xRadius: 0.5, yRadius: 0.5).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Four rising bars, `level` of them solid, the rest faint. No level = all faint.
    /// `age` ("3s") sits small in the empty corner above the short bars: how old the reading is.
    /// `switchHint` draws a slanted ⇄ in that same corner: the other SIM has more bars (`SimSwitchHint`).
    static func cellular(level: Int?, age: String? = nil, switchHint: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 17, height: barHeight), flipped: false) { rect in
            if switchHint { switchArrows(in: NSRect(x: 0, y: 10, width: 8.5, height: 6)) }
            if let age {
                let text = NSAttributedString(string: age, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 6.5, weight: .semibold),
                    .foregroundColor: NSColor.black,
                ])
                text.draw(at: NSPoint(x: 0, y: rect.height - text.size().height + 1.5))
            }
            for i in 0..<4 {
                let h = 4 + CGFloat(i) * 3
                let bar = NSBezierPath(roundedRect: NSRect(x: 1 + CGFloat(i) * 4, y: 2, width: 3, height: h),
                                       xRadius: 0.8, yRadius: 0.8)
                NSColor.black.withAlphaComponent(i < (level ?? 0) ? 1 : 0.28).set()
                bar.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// ⇄ drawn as two thin arrows, slanted like italics, in `r` (the corner above the short bars).
    private static func switchArrows(in r: NSRect) {
        let slant: CGFloat = 0.3
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x + (y - r.minY) * slant, y: y) }
        let top = r.maxY - 1.7, bottom = r.minY + 1.4, head: CGFloat = 1.7
        let left = r.minX + 0.6, right = r.maxX - 1.6
        let path = NSBezierPath()
        path.move(to: p(left, top)); path.line(to: p(right, top))
        path.move(to: p(right - head, top + head)); path.line(to: p(right, top)); path.line(to: p(right - head, top - head))
        path.move(to: p(right, bottom)); path.line(to: p(left, bottom))
        path.move(to: p(left + head, bottom + head)); path.line(to: p(left, bottom)); path.line(to: p(left + head, bottom - head))
        path.lineWidth = 1.1
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.black.set()
        path.stroke()
    }

    /// The same image at `alpha` — the dim half of a blink. Keeps it a template if it was one.
    static func faded(_ image: NSImage, _ alpha: CGFloat) -> NSImage {
        let out = NSImage(size: image.size, flipped: false) { r in
            image.draw(in: r, from: .zero, operation: .sourceOver, fraction: alpha)
            return true
        }
        out.isTemplate = image.isTemplate
        return out
    }

    /// The system's own Wi-Fi symbol, its arcs filled by `strength` (0…1).
    static func wifi(strength: Double) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(systemSymbolName: "wifi", variableValue: strength, accessibilityDescription: "Wi-Fi")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    /// The hotspot glyph Victor picked (2026-10-20): a ring in the middle and two
    /// arcs around it, open at the bottom. Drawn rather than shipped as his PNG,
    /// so it is a crisp template in both themes. (SF Symbols' `personalhotspot`
    /// is two linked rings, which is not this.)
    static func hotspot() -> NSImage? {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
            NSColor.black.set()
            let c = NSPoint(x: r.midX, y: r.midY - 0.5)
            let dot = NSBezierPath()
            dot.appendArc(withCenter: c, radius: 1.8, startAngle: 0, endAngle: 360)
            dot.lineWidth = 1.4
            dot.stroke()
            for radius in [CGFloat(4.4), 7.0] {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: c, radius: radius, startAngle: -50, endAngle: 230)
                arc.lineWidth = 1.5
                arc.lineCapStyle = .butt
                arc.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The phone's own network in the list (Victor: "keep displaying the phone icon").
    static func phone() -> NSImage? {
        let image = NSImage(systemSymbolName: "iphone", accessibilityDescription: "Phone")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        image?.isTemplate = true
        return image
    }

    /// Wi-Fi switched off, as macOS draws it: the arcs greyed, the slash across
    /// them in full text colour (white on a dark bar). Not a template — two tones.
    static func wifiOff() -> NSImage? {
        guard let arcs = wifi(strength: 1) else { return nil }
        let size = NSSize(width: arcs.size.width + 2, height: max(arcs.size.height, barHeight))
        let image = NSImage(size: size, flipped: false) { r in
            let a = NSRect(x: 1, y: (size.height - arcs.size.height) / 2, width: arcs.size.width, height: arcs.size.height)
            tinted(arcs, NSColor.labelColor.withAlphaComponent(0.35)).draw(in: a)
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: a.minX + 1, y: a.maxY - 0.5))
            slash.line(to: NSPoint(x: a.maxX - 1, y: a.minY + 0.5))
            slash.lineWidth = 1.6
            slash.lineCapStyle = .round
            NSColor.labelColor.set()
            slash.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Wi-Fi on but joined to nothing: the full symbol, greyed, a size larger —
    /// macOS's "not connected".
    static func wifiNoInternet() -> NSImage? {
        NSImage(systemSymbolName: "wifi.exclamationmark", accessibilityDescription: "No internet")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold)
                .applying(.init(paletteColors: [.systemRed])))
    }

    static func wifiIdle() -> NSImage? {
        guard let arcs = NSImage(systemSymbolName: "wifi", variableValue: 1, accessibilityDescription: "Wi-Fi")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) else { return nil }
        let image = NSImage(size: arcs.size, flipped: false) { r in
            tinted(arcs, NSColor.labelColor.withAlphaComponent(0.35)).draw(in: r)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// The hotspot glyph struck through — "✈️ Roaming: Auto-Stop Hotspot".
    static func hotspotOff() -> NSImage? {
        guard let base = hotspot() else { return nil }
        let image = NSImage(size: base.size, flipped: false) { r in
            base.draw(in: r)
            NSColor.black.set()
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: r.minX + 1.5, y: r.maxY - 1.5))
            slash.line(to: NSPoint(x: r.maxX - 1.5, y: r.minY + 1.5))
            slash.lineWidth = 1.5
            slash.lineCapStyle = .round
            slash.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// No traffic at all: two arrows back and forth, struck through.
    static func noTraffic() -> NSImage? {
        guard let arrows = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Offline")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) else { return nil }
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
            arrows.draw(in: r.insetBy(dx: 1, dy: 2))
            NSColor.black.set()
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: r.minX + 2, y: r.maxY - 2))
            slash.line(to: NSPoint(x: r.maxX - 2, y: r.minY + 2))
            slash.lineWidth = 1.4
            slash.lineCapStyle = .round
            slash.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    static func offline() -> NSImage? {
        let image = NSImage(systemSymbolName: "wifi.slash", accessibilityDescription: "Offline")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        image?.isTemplate = true
        return image
    }

    /// Two template glyphs side by side, as one template image.
    static func pair(_ a: NSImage, _ b: NSImage) -> NSImage {
        let gap: CGFloat = 3
        let size = NSSize(width: a.size.width + gap + b.size.width, height: max(a.size.height, b.size.height))
        let image = NSImage(size: size, flipped: false) { _ in
            a.draw(in: NSRect(x: 0, y: (size.height - a.size.height) / 2, width: a.size.width, height: a.size.height))
            b.draw(in: NSRect(x: a.size.width + gap, y: (size.height - b.size.height) / 2,
                              width: b.size.width, height: b.size.height))
            return true
        }
        image.isTemplate = true
        return image
    }

    static func image(for look: NetworkLook, switchHint: Bool = false) -> NSImage? {
        switch look {
        case .wired: return wired()
        case .hotspot(let level, let weakWifi, let alert):
            // The roaming badge takes the same corner, and says more.
            var image = cellular(level: level, switchHint: switchHint && alert == nil)
            if let weakWifi, let wifi = wifi(strength: weakWifi) { image = pair(image, wifi) }
            guard let alert else { return image }
            return badged(image, alert)
        case .wifi(let s): return wifi(strength: s)
        case .offline: return offline()
        }
    }

    /// A small ⚠ (yellow) or red disc with a white ✕ **in the top-left corner,
    /// over the bars** (Victor, 2026-10-20) — the corner the rising bars leave
    /// empty. Coloured, so not a template: the glyphs are filled with
    /// `labelColor`, resolved at draw time against the menu bar's appearance.
    /// A template filled with one colour (for the test render).
    static func tinted(_ template: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: template.size, flipped: false) { r in
            template.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
    }

    static func badged(_ glyphs: NSImage, _ alert: RoamingAlert) -> NSImage {
        let d: CGFloat = 9
        let size = NSSize(width: glyphs.size.width, height: max(glyphs.size.height, barHeight))
        let image = NSImage(size: size, flipped: false) { _ in
            let g = NSRect(x: 0, y: (size.height - glyphs.size.height) / 2,
                           width: glyphs.size.width, height: glyphs.size.height)
            // A template drawn by hand is just a mask: fill it with the text colour.
            glyphs.draw(in: g)
            NSColor.labelColor.set()
            g.fill(using: .sourceAtop)
            let b = NSRect(x: 0, y: size.height - d, width: d, height: d)
            switch alert {
            case .low:
                let t = NSBezierPath()
                t.move(to: NSPoint(x: b.midX, y: b.maxY))
                t.line(to: NSPoint(x: b.maxX, y: b.minY))
                t.line(to: NSPoint(x: b.minX, y: b.minY))
                t.close()
                NSColor.systemYellow.set()
                t.fill()
                NSColor.black.set()
                NSRect(x: b.midX - 0.6, y: b.minY + 3, width: 1.2, height: 3.4).fill()
                NSRect(x: b.midX - 0.6, y: b.minY + 1.2, width: 1.2, height: 1.1).fill()
            case .capped:
                NSColor.systemRed.set()
                NSBezierPath(ovalIn: b).fill()
                let x = NSBezierPath()
                let i = b.insetBy(dx: 2.6, dy: 2.6)
                x.move(to: NSPoint(x: i.minX, y: i.minY)); x.line(to: NSPoint(x: i.maxX, y: i.maxY))
                x.move(to: NSPoint(x: i.minX, y: i.maxY)); x.line(to: NSPoint(x: i.maxX, y: i.minY))
                x.lineWidth = 1.4
                x.lineCapStyle = .round
                NSColor.white.set()
                x.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

extension Icons {
    /// The Mac's own battery, measured off the bar in points: 22.5 × 12, a 1 pt outline in the
    /// bar's colour at half strength, a 1.5 × 4 nub after a 1 pt gap. No number: only the red
    /// charge inside blinks, as wide as the charge left.
    static func lowPhoneBattery(pct: Int, bright: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 26, height: barHeight), flipped: false) { rect in
            let shell = NSColor.labelColor.withAlphaComponent(0.45)
            shell.setStroke()
            let outline = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 2.5, width: 21.5, height: 11), xRadius: 3, yRadius: 3)
            outline.lineWidth = 1
            outline.stroke()
            shell.setFill()
            let nub = NSBezierPath()
            nub.move(to: NSPoint(x: 23.5, y: rect.midY - 2))
            nub.curve(to: NSPoint(x: 23.5, y: rect.midY + 2),
                      controlPoint1: NSPoint(x: 25.5, y: rect.midY - 1), controlPoint2: NSPoint(x: 25.5, y: rect.midY + 1))
            nub.close()
            nub.fill()

            let inner = NSRect(x: 1.5, y: 4, width: 19.5, height: 8)
            let charge = NSRect(x: inner.minX, y: inner.minY,
                                width: max(2.5, inner.width * CGFloat(pct) / 100), height: inner.height)
            NSColor.systemRed.withAlphaComponent(bright ? 1 : 0.2).setFill()
            NSBezierPath(roundedRect: charge, xRadius: 1.5, yRadius: 1.5).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
