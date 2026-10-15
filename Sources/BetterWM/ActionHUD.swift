import BetterWMCore
import Cocoa

/// Demo aid: flashes the key combination and action name at the bottom of the screen.
final class ActionHUD {
    var enabled = false
    private let window: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    init() {
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 22, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 22),
            label.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -22),
            label.topAnchor.constraint(equalTo: bg.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -12),
        ])
        window.contentView = bg
    }

    /// `keys` is a config spec like "alt+cmd+space" unless `preformatted`, in which case it is shown verbatim.
    func snapshot(to path: String) {
        guard let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    func show(keys: String?, action: String, preformatted: Bool = false) {
        guard enabled else { return }
        let text = NSMutableAttributedString()
        if let keys {
            text.append(NSAttributedString(string: (preformatted ? keys : KeyRecorderView.pretty(keys)) + "   ", attributes: [
                .font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.controlAccentColor,
            ]))
        }
        text.append(NSAttributedString(string: action, attributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .medium), .foregroundColor: NSColor.labelColor,
        ]))
        label.attributedStringValue = text
        let size = label.fittingSize
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let w = size.width + 44, h = size.height + 24
        window.setFrame(NSRect(x: screen.midX - w / 2, y: screen.minY + 48, width: w, height: h), display: true)
        window.alphaValue = 1
        window.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                self?.window.animator().alphaValue = 0
            }, completionHandler: { self?.window.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}
