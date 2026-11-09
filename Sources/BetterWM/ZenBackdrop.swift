import BetterWMCore
import Cocoa

/// A backdrop under the windows of a screen in zen mode: a colour or a picture over the wallpaper and the desktop
/// icons, fading in as zen begins and out as it ends. One per screen, shown only where zen is on.
final class ZenBackdrop {
    private var windows: [NSScreen: NSWindow] = [:]
    private var config: Config

    init(config: Config) { self.config = config }

    func apply(_ config: Config) {
        self.config = config
        for (screen, w) in windows { paint(w, for: screen) }
    }

    /// `zen` tells whether a screen is in zen right now.
    func update(zen: (NSScreen) -> Bool) {
        guard !config.zenBackground.isEmpty else { windows.values.forEach { Fade.hide($0) }; return }
        for screen in NSScreen.screens {
            let on = zen(screen)
            let w = windows[screen] ?? make(for: screen)
            if on {
                w.setFrame(screen.frame, display: false)
                paint(w, for: screen)
                Fade.show(w) { w.orderFront(nil) }
            } else {
                Fade.hide(w)
            }
        }
        for screen in windows.keys where !NSScreen.screens.contains(screen) { windows[screen]?.orderOut(nil); windows[screen] = nil }
    }

    private func make(for screen: NSScreen) -> NSWindow {
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.animationBehavior = .none
        // Just above the desktop picture and its icons, under every app window.
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let v = NSImageView()
        v.imageScaling = .scaleAxesIndependently
        v.wantsLayer = true
        w.contentView = v
        windows[screen] = w
        return w
    }

    private func paint(_ w: NSWindow, for screen: NSScreen) {
        guard let v = w.contentView as? NSImageView else { return }
        if let color = NSColor(hex: config.zenBackground) {
            v.image = nil
            v.layer?.backgroundColor = color.cgColor
        } else if let image = NSImage(contentsOfFile: (config.zenBackground as NSString).expandingTildeInPath) {
            v.layer?.backgroundColor = NSColor.black.cgColor
            v.image = Self.fill(image, to: screen.frame.size)
        } else {
            v.image = nil
            v.layer?.backgroundColor = nil
        }
    }

    /// The picture scaled to cover the screen and cropped to it, so it is never stretched.
    private static func fill(_ image: NSImage, to size: NSSize) -> NSImage {
        let scale = max(size.width / max(1, image.size.width), size.height / max(1, image.size.height))
        let drawn = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let out = NSImage(size: size)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2, width: drawn.width, height: drawn.height))
        out.unlockFocus()
        return out
    }
}
