import AppKit

/// The menu bar glyphs, drawn rather than taken from emoji so they sit in the
/// menu bar like the system's own: template images, painted by AppKit in the
/// bar's colour and inverted when highlighted.
enum Icons {
    static let barHeight: CGFloat = 16

    /// A cable: a dashed line with an arrowhead at each end (⇠⇢ joined).
    static func wired() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: barHeight), flipped: false) { rect in
            NSColor.black.set()
            let y = rect.midY
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 4.5, y: y))
            line.line(to: NSPoint(x: 15.5, y: y))
            line.lineWidth = 1.6
            line.setLineDash([2.2, 1.6], count: 2, phase: 0)
            line.stroke()
            for (tip, dir) in [(CGFloat(1.5), CGFloat(1)), (CGFloat(18.5), CGFloat(-1))] {
                let head = NSBezierPath()
                head.move(to: NSPoint(x: tip, y: y))
                head.line(to: NSPoint(x: tip + 4.5 * dir, y: y + 3.6))
                head.line(to: NSPoint(x: tip + 4.5 * dir, y: y - 3.6))
                head.close()
                head.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Four rising bars, `level` of them solid, the rest faint. No level = all faint.
    static func cellular(level: Int?) -> NSImage {
        let image = NSImage(size: NSSize(width: 17, height: barHeight), flipped: false) { _ in
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

    /// The system's own Wi-Fi symbol, its arcs filled by `strength` (0…1).
    static func wifi(strength: Double) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(systemSymbolName: "wifi", variableValue: strength, accessibilityDescription: "Wi-Fi")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
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

    static func image(for look: NetworkLook) -> NSImage? {
        switch look {
        case .wired: return wired()
        case .hotspot(let level, let weakWifi, let alert):
            var image = cellular(level: level)
            if let weakWifi, let wifi = wifi(strength: weakWifi) { image = pair(image, wifi) }
            guard let alert else { return image }
            return badged(image, alert)
        case .wifi(let s): return wifi(strength: s)
        case .offline: return offline()
        }
    }

    /// The glyphs followed by ⚠ (yellow) or a red disc with a white ✕. Coloured,
    /// so not a template: the glyphs are drawn in `labelColor`, resolved at draw
    /// time against the menu bar's own appearance.
    static func badged(_ glyphs: NSImage, _ alert: RoamingAlert) -> NSImage {
        let d: CGFloat = 13, gap: CGFloat = 3
        let size = NSSize(width: glyphs.size.width + gap + d, height: max(glyphs.size.height, barHeight))
        let image = NSImage(size: size, flipped: false) { _ in
            let g = NSRect(x: 0, y: (size.height - glyphs.size.height) / 2,
                           width: glyphs.size.width, height: glyphs.size.height)
            // A template drawn by hand is just a mask: fill it with the text colour.
            glyphs.draw(in: g)
            NSColor.labelColor.set()
            g.fill(using: .sourceAtop)
            let b = NSRect(x: glyphs.size.width + gap, y: (size.height - d) / 2, width: d, height: d)
            switch alert {
            case .low:
                let t = NSBezierPath()
                t.move(to: NSPoint(x: b.midX, y: b.maxY))
                t.line(to: NSPoint(x: b.maxX, y: b.minY + 0.5))
                t.line(to: NSPoint(x: b.minX, y: b.minY + 0.5))
                t.close()
                NSColor.systemYellow.set()
                t.fill()
                NSColor.black.set()
                NSRect(x: b.midX - 0.9, y: b.minY + 4.6, width: 1.8, height: 4.6).fill()
                NSRect(x: b.midX - 0.9, y: b.minY + 2.2, width: 1.8, height: 1.6).fill()
            case .capped:
                NSColor.systemRed.set()
                NSBezierPath(ovalIn: b).fill()
                let x = NSBezierPath()
                let i = b.insetBy(dx: 3.8, dy: 3.8)
                x.move(to: NSPoint(x: i.minX, y: i.minY)); x.line(to: NSPoint(x: i.maxX, y: i.maxY))
                x.move(to: NSPoint(x: i.minX, y: i.maxY)); x.line(to: NSPoint(x: i.maxX, y: i.minY))
                x.lineWidth = 1.8
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
