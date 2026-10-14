import Cocoa

enum StatusIcon {
    /// Template image: rounded tile with a tall left column and a stacked right column.
    static func make(paused: Bool) -> NSImage {
        let size = NSSize(width: 20, height: 16)
        let img = NSImage(size: size, flipped: false) { rect in
            let outer = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
            outer.lineWidth = 1.2
            NSColor.black.setStroke()
            outer.stroke()
            let inner = rect.insetBy(dx: 3.5, dy: 3.5)
            let gap: CGFloat = 1.6
            let colW = (inner.width - gap) / 2
            let left = NSRect(x: inner.minX, y: inner.minY, width: colW, height: inner.height)
            let rowH = (inner.height - gap) / 2
            let topRight = NSRect(x: inner.minX + colW + gap, y: inner.minY + rowH + gap, width: colW, height: rowH)
            let bottomRight = NSRect(x: inner.minX + colW + gap, y: inner.minY, width: colW, height: rowH)
            NSColor.black.setFill()
            for r in [left, topRight, bottomRight] {
                let p = NSBezierPath(roundedRect: r, xRadius: 1, yRadius: 1)
                if paused { p.lineWidth = 1; p.stroke() } else { p.fill() }
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
