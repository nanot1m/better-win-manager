// Renders the app icon: the status bar's tile motif on an orange squircle. Run from the repo root:
//   swift Resources/icon/make-icon.swift
// writes Resources/AppIcon.icns (and Resources/icon/preview.png).
import Cocoa

func render(_ px: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: px, height: px), flipped: false) { rect in
        // Big Sur grid: the squircle is 824/1024 of the canvas, the rest transparent margin.
        let s = px / 1024
        let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 24 * s
        shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
        shadow.set()
        NSColor(srgbRed: 1, green: 0.58, blue: 0, alpha: 1).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: NSColor(srgbRed: 1, green: 0.70, blue: 0.20, alpha: 1), ending: NSColor(srgbRed: 0.93, green: 0.45, blue: 0, alpha: 1))!
            .draw(in: shape, angle: -90)
        // Tiles: a tall column on the left, two stacked on the right, as in the menu bar icon.
        let inner = body.insetBy(dx: 150 * s, dy: 150 * s)
        let gap = 44 * s, r = 56 * s
        let colW = (inner.width - gap) / 2, rowH = (inner.height - gap) / 2
        let tiles = [NSRect(x: inner.minX, y: inner.minY, width: colW, height: inner.height),
                     NSRect(x: inner.minX + colW + gap, y: inner.minY + rowH + gap, width: colW, height: rowH),
                     NSRect(x: inner.minX + colW + gap, y: inner.minY, width: colW, height: rowH)]
        NSGraphicsContext.saveGraphicsState()
        let tileShadow = NSShadow()
        tileShadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        tileShadow.shadowBlurRadius = 14 * s
        tileShadow.shadowOffset = NSSize(width: 0, height: -6 * s)
        tileShadow.set()
        NSColor.white.setFill()
        for t in tiles { NSBezierPath(roundedRect: t, xRadius: r, yRadius: r).fill() }
        NSGraphicsContext.restoreGraphicsState()
        return true
    }
}

func png(_ img: NSImage, _ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: "Resources")
let set = root.appendingPathComponent("icon/AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! png(render(CGFloat(px)), px).write(to: set.appendingPathComponent(name))
    }
}
try! png(render(512), 512).write(to: root.appendingPathComponent("icon/preview.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", root.appendingPathComponent("AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
