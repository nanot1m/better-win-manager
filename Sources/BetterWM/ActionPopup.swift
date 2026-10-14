import Cocoa

final class ActionPopup: NSPanel {
    private let manager: WindowManager
    private let view: ActionView
    private var clickMonitor: Any?

    init(manager: WindowManager) {
        self.manager = manager
        view = ActionView()
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 290),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = true
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .transient]
        contentView = view
        view.onKey = { [weak self] e in self?.handle(e) ?? false }
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }

    func toggle() {
        if isVisible { close() } else { show() }
    }

    func show() {
        refresh()
        makeKeyAndOrderFront(nil)
        // Raising other windows steals key status, so clicks outside close the panel instead of resignKey.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.frame.contains(NSEvent.mouseLocation) else { return }
            self.close()
        }
    }

    override func close() {
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
        orderOut(nil)
    }

    private func regainKey() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.isVisible else { return }
            self.refresh()
            self.makeKeyAndOrderFront(nil)
        }
    }

    private func refresh() {
        view.enabled = Dictionary(uniqueKeysWithValues: ActionView.actions.map { ($0.dir, manager.canMoveFocused($0.dir)) })
        view.tiled = AXWindow.focused.map(manager.isTiled) ?? false
        view.desktopCount = Spaces.desktops().count
        view.currentDesktop = Spaces.currentDesktopIndex()
        view.needsDisplay = true
        let target = AXWindow.focused?.frame.toCocoa() ?? NSScreen.main?.visibleFrame ?? .zero
        setFrameOrigin(NSPoint(x: target.midX - frame.width / 2, y: target.midY - frame.height / 2))
    }

    private func handle(_ e: NSEvent) -> Bool {
        let shift = e.modifierFlags.contains(.shift)
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let code = e.keyCode
        var dir: Layout.Move?
        switch (code, key) {
        case (123, _), (_, "h"): dir = shift ? .mergeLeft : .left
        case (124, _), (_, "l"): dir = shift ? .mergeRight : .right
        case (126, _), (_, "k"): dir = .up
        case (125, _), (_, "j"): dir = .down
        case (48, _): manager.focusNext(reverse: shift)
        case (_, "t"): manager.toggleFocused()
        case (_, "n"), (_, "p"):
            close()
            manager.sendFocusedWindow(toNext: key == "n")
            return true
        case (53, _): close(); return true
        case (_, let k) where ("1"..."9").contains(k) && k.count == 1:
            let index = Int(k)! - 1
            guard index < Spaces.desktops().count else { return true }
            if shift {
                close()
                manager.sendFocusedWindow(toDesktop: index)
                return true
            }
            Spaces.switchToDesktop(index)
            // The switch is asynchronous; re-read the focused window once it has landed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.regainKey() }
            return true
        default: return false
        }
        if let dir {
            guard manager.canMoveFocused(dir) else { return true }
            manager.moveFocused(dir)
        }
        refresh()
        regainKey()
        return true
    }
}

private final class ActionView: NSView {
    struct Action {
        let dir: Layout.Move
        let title: String
        let keys: String
        let col: Int, row: Int
    }

    static let actions: [Action] = [
        Action(dir: .up, title: "Move Up", keys: "↑  K", col: 2, row: 0),
        Action(dir: .mergeLeft, title: "Merge Left", keys: "⇧←  ⇧H", col: 0, row: 1),
        Action(dir: .left, title: "Move Left", keys: "←  H", col: 1, row: 1),
        Action(dir: .right, title: "Move Right", keys: "→  L", col: 3, row: 1),
        Action(dir: .mergeRight, title: "Merge Right", keys: "⇧→  ⇧L", col: 4, row: 1),
        Action(dir: .down, title: "Move Down", keys: "↓  J", col: 2, row: 2),
    ]

    var enabled: [Layout.Move: Bool] = [:]
    var tiled = false
    var desktopCount = 0
    var currentDesktop: Int?
    var onKey: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()

        let footerH: CGFloat = 36, desktopsH: CGFloat = 60
        let grid = NSRect(x: 14, y: footerH + desktopsH, width: bounds.width - 28, height: bounds.height - footerH - desktopsH - 14)
        let cellW = grid.width / 5, cellH = grid.height / 3
        func cell(_ col: Int, _ row: Int) -> NSRect {
            NSRect(x: grid.minX + CGFloat(col) * cellW, y: grid.maxY - CGFloat(row + 1) * cellH, width: cellW, height: cellH).insetBy(dx: 4, dy: 4)
        }

        let center = cell(2, 1)
        (tiled ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: center, xRadius: 8, yRadius: 8).fill()
        draw(tiled ? "Focused" : "Not tiled\n(T to tile)", in: center, color: .labelColor, size: 12, bold: true)

        for a in Self.actions {
            let on = enabled[a.dir] ?? false
            let r = cell(a.col, a.row)
            let color: NSColor = on ? .labelColor : .tertiaryLabelColor
            (on ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.separatorColor.withAlphaComponent(0.15)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
            draw(a.title, in: NSRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2 - 2), color: color, size: 12, bold: true)
            draw(a.keys, in: NSRect(x: r.minX, y: r.minY + 4, width: r.width, height: r.height / 2 - 2), color: color, size: 11, bold: false)
        }

        drawDesktops(in: NSRect(x: 14, y: footerH, width: bounds.width - 28, height: desktopsH))

        draw("Tab / ⇧Tab  focus next / previous      T  tile / untile      N / P  send to next / previous desktop      Esc  close",
             in: NSRect(x: 0, y: 8, width: bounds.width, height: footerH - 12), color: .secondaryLabelColor, size: 11, bold: false)
    }

    private func drawDesktops(in rect: NSRect) {
        draw("Desktops   1–9 switch   ⇧1–9 send window", in: NSRect(x: rect.minX, y: rect.maxY - 18, width: rect.width, height: 14), color: .secondaryLabelColor, size: 11, bold: false)
        let n = min(desktopCount, 9)
        guard n > 0 else { return }
        let chip: CGFloat = 32, gap: CGFloat = 8
        var x = rect.midX - (CGFloat(n) * chip + CGFloat(n - 1) * gap) / 2
        for i in 0..<n {
            let r = NSRect(x: x, y: rect.minY + 6, width: chip, height: chip)
            let current = i == currentDesktop
            (current ? NSColor.controlAccentColor : NSColor.controlAccentColor.withAlphaComponent(0.12)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
            draw("\(i + 1)", in: r, color: current ? .white : .labelColor, size: 13, bold: true)
            x += chip + gap
        }
    }

    private func draw(_ text: String, in rect: NSRect, color: NSColor, size: CGFloat, bold: Bool) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
            .foregroundColor: color, .paragraphStyle: style,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let h = s.boundingRect(with: NSSize(width: rect.width, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin).height
        s.draw(in: NSRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h))
    }
}
