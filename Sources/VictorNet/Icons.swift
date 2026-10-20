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
        case .hotspot(let level, let weakWifi):
            let bars = cellular(level: level)
            guard let weakWifi, let wifi = wifi(strength: weakWifi) else { return bars }
            return pair(bars, wifi)
        case .wifi(let s): return wifi(strength: s)
        case .offline: return offline()
        }
    }

    /// The last seconds as bars, the newest in the accent colour — for a menu
    /// row, so not a template. `scale` is the 10-minute maximum, so a bar's
    /// height reads against the best this network has done, not the window's.
    static func bars(_ values: [Double], scale: Double, count: Int = 20) -> NSImage {
        let w: CGFloat = 2, gap: CGFloat = 1, h: CGFloat = 13
        let padded = Array(repeating: 0.0, count: max(0, count - values.count)) + values.suffix(count)
        let size = NSSize(width: CGFloat(count) * (w + gap), height: h)
        return NSImage(size: size, flipped: false) { _ in
            let top = max(scale, padded.max() ?? 0, 1)
            for (i, v) in padded.enumerated() {
                let bh = max(1, CGFloat(v / top) * h)
                (i == padded.count - 1 ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).set()
                NSRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: bh).fill()
            }
            return true
        }
    }
}
