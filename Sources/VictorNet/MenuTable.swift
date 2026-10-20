import AppKit

/// A real table inside a menu row (Victor, 2026-10-20: *"can you actually display
/// a table in your menu?"*) — an `NSGridView` as the item's view: the first
/// column left-aligned, the numbers right-aligned in monospaced digits, a grey
/// header. A view-backed row is not highlighted and not clickable, which is
/// right for a readout.
enum MenuTable {
    /// Left inset matching the text of ordinary rows (after the image column).
    private static let inset = NSEdgeInsets(top: 3, left: 21, bottom: 3, right: 16)

    static func item(header: [String]?, rows: [[String]], bold: Set<Int> = []) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view(header: header, rows: rows, bold: bold)
        return item
    }

    static func view(header: [String]?, rows: [[String]], bold: Set<Int> = []) -> NSView {
        let size = NSFont.systemFontSize
        func label(_ s: String, header: Bool, bold: Bool) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = header ? .systemFont(ofSize: size - 2, weight: .medium)
                : .monospacedDigitSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
            l.textColor = header ? .tertiaryLabelColor : .secondaryLabelColor
            return l
        }
        var cells: [[NSView]] = []
        if let header { cells.append(header.map { label($0, header: true, bold: false) }) }
        for (i, row) in rows.enumerated() {
            cells.append(row.map { label($0, header: false, bold: bold.contains(i)) })
        }
        let grid = NSGridView(views: cells)
        grid.rowSpacing = 3
        grid.columnSpacing = 18
        for c in 0..<grid.numberOfColumns {
            grid.column(at: c).xPlacement = c == 0 ? .leading : .trailing
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        let fit = grid.fittingSize
        let box = NSView(frame: NSRect(x: 0, y: 0, width: fit.width + inset.left + inset.right,
                                       height: fit.height + inset.top + inset.bottom))
        box.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: inset.left),
            grid.topAnchor.constraint(equalTo: box.topAnchor, constant: inset.top),
        ])
        return box
    }
}
