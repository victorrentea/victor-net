import AppKit

/// The menu bar glyphs, drawn rather than taken from emoji so they sit in the
/// menu bar like the system's own: template images, painted by AppKit in the
/// bar's colour and inverted when highlighted.
enum Icons {
    static let barHeight: CGFloat = 16

    /// A cable: **open angle brackets** pointing apart with two dashes between
    /// them — `< ‐ ‐ >` (Victor, 2026-10-20, after filled and then hollow
    /// triangles): the Ethernet row's icon in the menu.
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
    /// Like the phone's status bar (Victor, 2026-11-11): `network` ("5G", "4G") sits small in the empty
    /// corner above the short bars. No age after them (Victor, 2026-11-12: the hotspot's row says it,
    /// next to the battery; beside every SIM it distracted).
    /// `switchHint` draws a slanted ⇄ in the top corner instead: the other SIM has more bars (`SimSwitchHint`).
    static func cellular(level: Int?, network: String? = nil, switchHint: Bool = false) -> NSImage {
        let width: CGFloat = 17
        let image = NSImage(size: NSSize(width: width, height: barHeight), flipped: false) { rect in
            let small: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 6.5, weight: .semibold),
                .foregroundColor: NSColor.black,
            ]
            if switchHint {
                switchArrows(in: NSRect(x: 0, y: 10, width: 8.5, height: 6))
            } else if let network {
                // "4G+" / "5G+": the + small and raised, as on the phone, so it stays clear of the third bar.
                let base = network.hasSuffix("+") ? String(network.dropLast()) : network
                let text = NSMutableAttributedString(string: base, attributes: small)
                text.addAttribute(.kern, value: -0.2, range: NSRange(location: 0, length: text.length))
                if base != network {
                    text.append(NSAttributedString(string: "+", attributes: [
                        .font: NSFont.systemFont(ofSize: 5, weight: .bold), .foregroundColor: NSColor.black,
                        .baselineOffset: 1.8]))
                }
                text.draw(at: NSPoint(x: 0, y: rect.height - NSAttributedString(string: base, attributes: small).size().height + 1.5))
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

    /// On the hotspot with nothing behind it: the bars empty, a red "!" in the corner they leave
    /// free. Not a template — two tones.
    static func noInternet(_ bars: NSImage) -> NSImage {
        let image = NSImage(size: bars.size, flipped: false) { r in
            bars.draw(in: r)
            NSColor.labelColor.set()
            r.fill(using: .sourceAtop)
            NSAttributedString(string: "!", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .heavy), .foregroundColor: NSColor.systemRed,
            ]).draw(at: NSPoint(x: 1.5, y: r.height - 11.5))
            return true
        }
        image.isTemplate = false
        return image
    }

    /// The hotspot glyph struck through: Stop Hotspot.
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

    /// Two glyphs side by side as one image. Not a template (the battery is red): a template
    /// one is filled with the bar's text colour at draw time.
    static func beside(_ a: NSImage, _ b: NSImage) -> NSImage {
        let gap: CGFloat = 4
        let size = NSSize(width: a.size.width + gap + b.size.width, height: max(a.size.height, b.size.height))
        let image = NSImage(size: size, flipped: false) { _ in
            for (img, x) in [(a, CGFloat(0)), (b, a.size.width + gap)] {
                (img.isTemplate ? tinted(img, .labelColor) : img)
                    .draw(in: NSRect(x: x, y: (size.height - img.size.height) / 2, width: img.size.width, height: img.size.height))
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// `beside`, inside one rounded frame: a faint fill and a thin outline in the bar's colour,
    /// so the phone's battery and its bars read as one thing, the phone (Victor, 2026-11-17).
    static func united(_ a: NSImage, _ b: NSImage) -> NSImage {
        let inner = beside(a, b)
        let padX: CGFloat = 4, height: CGFloat = 20
        let size = NSSize(width: inner.size.width + 2 * padX, height: max(height, inner.size.height))
        let image = NSImage(size: size, flipped: false) { rect in
            let pill = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            pill.fill()
            NSColor.labelColor.withAlphaComponent(0.45).setStroke()
            pill.lineWidth = 1
            pill.stroke()
            inner.draw(in: NSRect(x: padX, y: (size.height - inner.size.height) / 2,
                                  width: inner.size.width, height: inner.size.height))
            return true
        }
        image.isTemplate = false
        return image
    }

    /// `network`: the data SIM's "5G" / "4G" over the bars, unless ⇄ holds that corner.
    /// `bright`: the lit half of the red gauge's blink.
    static func image(for look: NetworkLook, switchHint: Bool = false, network: String? = nil,
                      bright: Bool = true) -> NSImage? {
        switch look {
        case .hotspot(let level, let gauge):
            let image = cellular(level: level, network: network, switchHint: switchHint)
            return gauge.map { gauged(image, $0, bright: bright) } ?? image
        case .away(let level, let gauge):
            // As solid as on the hotspot (Victor, 2026-11-12: the phone also answers over Bluetooth
            // and the home Wi-Fi); with no answer, `cellular` draws all four bars faint. In thin
            // [ ] (Victor, 2026-11-17): the phone is only the backup while the Mac is on another network.
            let image = cellular(level: level)
            return bracketed(gauge.map { gauged(image, $0, bright: bright) } ?? image)
        case .airplane:
            return airplane()
        }
    }

    /// The phone in airplane mode: SF Symbols' airplane, the bars' height, turned **nose up** like
    /// the one in Android's status bar (Victor, 2026-11-18; SF Symbols' points right).
    static func airplane() -> NSImage? {
        guard let glyph = NSImage(systemSymbolName: "airplane", accessibilityDescription: "Phone in airplane mode")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) else { return nil }
        let size = NSSize(width: glyph.size.height, height: glyph.size.width)
        let image = NSImage(size: size, flipped: false) { r in
            let t = NSAffineTransform()
            t.translateX(by: r.midX, yBy: r.midY)
            t.rotate(byDegrees: 90)   // counter-clockwise: right → up
            t.concat()
            glyph.draw(in: NSRect(x: -glyph.size.width / 2, y: -glyph.size.height / 2,
                                  width: glyph.size.width, height: glyph.size.height))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Phone in airplane mode"
        return image
    }

    /// `image` between two thin square brackets, `[ ▂▄▆█ ]`: the phone as a backup, not the route.
    /// Stays a template when `image` is one (the roaming gauge makes it two-toned, then the
    /// brackets take the bar's text colour like `gauged` does).
    static func bracketed(_ image: NSImage) -> NSImage {
        let pad: CGFloat = 4, serif: CGFloat = 2, line: CGFloat = 0.9
        let size = NSSize(width: image.size.width + 2 * pad, height: max(image.size.height, barHeight))
        let template = image.isTemplate
        let out = NSImage(size: size, flipped: false) { r in
            image.draw(in: NSRect(x: pad, y: (size.height - image.size.height) / 2,
                                  width: image.size.width, height: image.size.height))
            // Full text colour, not dimmed: plain white on the dark bar (Victor, 2026-11-18).
            (template ? NSColor.black : NSColor.labelColor).setStroke()
            let top = r.maxY - 1, bottom = r.minY + 1
            for (x, dir) in [(CGFloat(0.8), CGFloat(1)), (r.maxX - 0.8, CGFloat(-1))] {
                let b = NSBezierPath()
                b.move(to: NSPoint(x: x + serif * dir, y: top))
                b.line(to: NSPoint(x: x, y: top))
                b.line(to: NSPoint(x: x, y: bottom))
                b.line(to: NSPoint(x: x + serif * dir, y: bottom))
                b.lineWidth = line
                b.lineCapStyle = .butt
                b.lineJoinStyle = .miter
                b.stroke()
            }
            return true
        }
        out.isTemplate = template
        return out
    }

    /// A template filled with one colour (for the test render).
    static func tinted(_ template: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: template.size, flipped: false) { r in
            template.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
    }

    /// The bars lifted 1 pt, and under them a thin bar as wide as the four bars at 100% of the
    /// roaming plan left, shrinking to the left (Victor, 2026-11-18, in place of the ⚠ badge).
    /// No border: one solid strip in the bar's text colour, yellow under half, red and blinking
    /// under 1 GB. Coloured, so not a template: the bars are filled with `labelColor` at draw time.
    static func gauged(_ glyphs: NSImage, _ gauge: RoamingGauge, bright: Bool) -> NSImage {
        let size = NSSize(width: glyphs.size.width, height: max(glyphs.size.height, barHeight))
        let image = NSImage(size: size, flipped: false) { _ in
            let g = NSRect(x: 0, y: (size.height - glyphs.size.height) / 2 + 1,
                           width: glyphs.size.width, height: glyphs.size.height)
            // A template drawn by hand is just a mask: fill it with the text colour.
            NSImage(size: g.size, flipped: false) { r in
                glyphs.draw(in: r)
                NSColor.labelColor.set()
                r.fill(using: .sourceAtop)
                return true
            }.draw(in: g)
            // The four bars run from x = 1 to 16 in `cellular`.
            let full = NSRect(x: 1, y: 0, width: 15, height: 1.6)
            let color: NSColor
            switch gauge.tone {
            case .plain: color = .labelColor
            case .yellow: color = .systemYellow
            case .red: color = NSColor.systemRed.withAlphaComponent(bright ? 1 : 0.2)
            }
            color.setFill()
            // Never thinner than a dot, so an empty red gauge still blinks.
            let width = max(1.5, full.width * CGFloat(gauge.fraction))
            NSBezierPath(roundedRect: NSRect(x: full.minX, y: full.minY, width: width, height: full.height),
                         xRadius: 0.5, yRadius: 0.5).fill()
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
