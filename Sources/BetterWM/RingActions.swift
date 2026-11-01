import BetterWMCore
import Cocoa

/// A small tab of icon buttons growing out of the focus ring's top edge near the right corner, in the ring's
/// colour: the most used window actions a click away. Gone whenever the ring is gone or grey.
final class RingActions {
    struct Button {
        let symbol: String
        let title: String
        let action: String
    }
    static let buttons = [
        Button(symbol: "rectangle.split.2x1", title: "Tile / untile", action: "toggleTile"),
        Button(symbol: "rectangle.stack", title: "Toggle stacked layout", action: "toggleStack"),
        Button(symbol: "arrow.right.square", title: "Send to next desktop", action: "sendToNextDesktop"),
        Button(symbol: "ellipsis.circle", title: "Window actions", action: "popup"),
    ]

    private let panel: NSPanel
    private let view = PillView()
    private let tip = TooltipPanel()
    /// The hotkey bound to an action, for the tooltip.
    var hotkeyLabel: (String) -> String? = { _ in nil }
    /// Runs an action by its key, the same table hotkeys and the menu use.
    var perform: (String) -> Void = { _ in }
    private static let restingAlpha: CGFloat = 0.85

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        // One step above the ring, which sits at floating level and orders itself front on every focus change.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true
        panel.alphaValue = Self.restingAlpha
        // Dark whatever is behind it: white icons on a translucent material vanish over a light window.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = view
        panel.setContentSize(view.fittingSize)
        view.onAction = { [weak self] key in self?.perform(key) }
        view.onHover = { [weak self] inside in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                self.panel.animator().alphaValue = inside ? 1 : Self.restingAlpha
            }
            if !inside { self.tip.hide() }
        }
        // Tooltips of our own: AppKit shows none for a panel of an app that is not active.
        view.onHoverButton = { [weak self] button in
            guard let self else { return }
            guard let button else { return self.tip.hide() }
            var text = button.title
            if let key = self.hotkeyLabel(button.action) { text += "  \(key)" }
            guard let frame = self.view.frame(of: button.action) else { return }
            self.tip.show(text, below: self.panel.convertToScreen(frame))
        }
    }

    /// Follows the ring: `ring` is the ring window's frame (Cocoa coordinates), `inset` how far the ring's inner
    /// edge is from it. The pill grows out of the ring's top edge near the right corner, in the ring's colour,
    /// above the window so it never covers an app's own toolbar. Nil hides the pill.
    func follow(ring: NSRect?, inset: CGFloat, ringWidth: CGFloat, color: NSColor, enabled: Bool) {
        guard enabled, let ring else { panel.orderOut(nil); return }
        view.setColor(color)
        let size = panel.frame.size
        // Bottom edge on the ring's inner edge: the pill and the ring line read as one shape.
        let origin = NSPoint(x: ring.maxX - inset - 10 - size.width, y: ring.maxY - inset)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() { panel.orderOut(nil); tip.hide() }
}

/// A small dark label under a pill button.
private final class TooltipPanel {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let back = NSView()
        back.wantsLayer = true
        back.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.95).cgColor
        back.layer?.cornerRadius = 6
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        back.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: back.leadingAnchor, constant: 8), label.trailingAnchor.constraint(equalTo: back.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: back.topAnchor, constant: 4), label.bottomAnchor.constraint(equalTo: back.bottomAnchor, constant: -4),
        ])
        panel.contentView = back
    }

    /// Centred under `anchor` (a screen rect), kept on the anchor's screen.
    func show(_ text: String, below anchor: NSRect) {
        label.stringValue = text
        let size = panel.contentView!.fittingSize
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 6)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) {
            origin.x = min(max(origin.x, screen.frame.minX + 4), screen.frame.maxX - size.width - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() { panel.orderOut(nil) }
}

private final class PillView: NSView {
    var onAction: ((String) -> Void)?
    var onHover: ((Bool) -> Void)?
    var onHoverButton: ((RingActions.Button?) -> Void)?
    private var hoveredButton: NSButton?
    private let background = NSView()
    private var buttons: [NSButton] = []

    /// A button's frame in window coordinates, for anchoring its tooltip.
    func frame(of action: String) -> NSRect? {
        guard let b = buttons.first(where: { $0.identifier?.rawValue == action }), let sup = b.superview else { return nil }
        return sup.convert(b.frame, to: nil)
    }

    /// The ring's colour as the pill's; icons in whatever reads on it.
    func setColor(_ color: NSColor) {
        background.layer?.backgroundColor = color.cgColor
        for b in buttons { b.contentTintColor = color.contrastingText }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        background.wantsLayer = true
        background.layer?.cornerRadius = 7
        // Rounded on top only; the bottom merges into the ring line.
        background.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        background.layer?.masksToBounds = true
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 1, left: 5, bottom: 1, right: 5)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for b in RingActions.buttons {
            let button = NSButton()
            button.bezelStyle = .inline
            button.isBordered = false
            button.image = NSImage(systemSymbolName: b.symbol, accessibilityDescription: b.title)?
                .withSymbolConfiguration(.init(pointSize: 10.5, weight: .semibold))
            button.toolTip = b.title
            button.target = self
            button.action = #selector(pressed(_:))
            button.identifier = NSUserInterfaceItemIdentifier(b.action)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
            button.heightAnchor.constraint(equalToConstant: 18).isActive = true
            stack.addArrangedSubview(button)
            buttons.append(button)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor), background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor), background.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func pressed(_ sender: NSButton) {
        if let key = sender.identifier?.rawValue { onAction?(key) }
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true); mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { hoveredButton = nil; onHover?(false) }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let under = buttons.first { $0.frame.contains(convert(p, to: $0.superview)) }
        guard under !== hoveredButton else { return }
        hoveredButton = under
        onHoverButton?(under.flatMap { b in RingActions.buttons.first { $0.action == b.identifier?.rawValue } })
    }
}
