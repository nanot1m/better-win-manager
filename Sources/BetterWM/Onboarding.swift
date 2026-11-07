import BetterWMCore
import Cocoa

/// The welcome window: permissions, how to show the desktops, and the macOS settings to hand over. Shown at
/// launch until it has been gone through once (and always while Accessibility is missing); from the menu any time.
final class OnboardingWindow {
    private let window: NSWindow
    private var rows: [PermissionRow] = []
    private var poll: Timer?
    private var step = 0
    private let pages = NSTabView()
    private let back = NSButton(title: "Back", target: nil, action: nil)
    private let next = NSButton(title: "Continue", target: nil, action: nil)
    private let progress = NSTextField(labelWithString: "")
    private var menuBarCard: RecommendationView?
    private var barChoice: NSButton!, menuChoice: NSButton!
    /// The configuration to read and write choices through; set by the app once it has booted.
    var config: () -> Config? = { nil }
    var apply: (Config) -> Void = { _ in }
    var openSettings: () -> Void = {}

    private struct Permission {
        let title: String
        let why: String
        let required: Bool
        let pane: String
        let granted: () -> Bool
    }

    private let permissions: [Permission] = [
        Permission(title: "Accessibility", why: "Reads window positions and moves them into the grid. Nothing works without it.",
                   required: true, pane: "Privacy_Accessibility", granted: { AXIsProcessTrusted() }),
        Permission(title: "Screen Recording", why: "Window previews in the ⌥Tab switcher and the desktop overview. Without it they show app icons.",
                   required: false, pane: "Privacy_ScreenCapture", granted: { CGPreflightScreenCaptureAccess() }),
    ]

    private static let doneKey = "onboardingDone"
    static var completed: Bool { UserDefaults.standard.bool(forKey: doneKey) }

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Welcome to BetterWM"
        window.isReleasedWhenClosed = false
        pages.tabViewType = .noTabsNoBorder
        pages.translatesAutoresizingMaskIntoConstraints = false
        for (title, view) in [("Permissions", permissionsPage()), ("Your desktops", desktopsPage()), ("Hand over macOS", handoverPage()), ("Ready", readyPage())] {
            let item = NSTabViewItem(identifier: title)
            item.view = view
            pages.addTabViewItem(item)
        }
        back.target = self; back.action = #selector(goBack)
        next.target = self; next.action = #selector(goNext)
        next.keyEquivalent = "\r"
        progress.font = .systemFont(ofSize: 11)
        progress.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [progress, NSView(), back, next])
        footer.orientation = .horizontal
        footer.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(pages)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            pages.topAnchor.constraint(equalTo: root.topAnchor, constant: 20), pages.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            pages.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), pages.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -14),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        window.contentView = root
        window.setContentSize(NSSize(width: 640, height: 600))
        window.center()
        showStep(0)
    }

    /// True when the window should appear at launch: the required permission is missing, or the tour was never finished.
    var needed: Bool { !permissions.filter(\.required).allSatisfy { $0.granted() } || !Self.completed }

    var windowNumber: Int { window.windowNumber }

    func show() {
        if let c = config() { menuChoice.state = c.bar ? .off : .on; barChoice.state = c.bar ? .on : .off }
        update()
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.update() }
        showStep(permissions.filter(\.required).allSatisfy { $0.granted() } && !Self.completed ? 1 : 0)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showStep(_ i: Int) {
        step = max(0, min(pages.numberOfTabViewItems - 1, i))
        pages.selectTabViewItem(at: step)
        back.isHidden = step == 0
        next.title = step == pages.numberOfTabViewItems - 1 ? "Done" : "Continue"
        progress.stringValue = "Step \(step + 1) of \(pages.numberOfTabViewItems)"
        menuBarCard?.isHidden = barChoice.state != .on
    }

    @objc private func goBack() { showStep(step - 1) }
    @objc private func goNext() {
        if step == pages.numberOfTabViewItems - 1 { finish(); return }
        showStep(step + 1)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        poll?.invalidate()
        poll = nil
        window.close()
    }

    private func update() {
        for (row, p) in zip(rows, permissions) { row.granted = p.granted() }
        menuBarCard?.done = Self.menuBarAutoHides
    }

    private func open(pane: String) {
        if pane == "Privacy_ScreenCapture", !CGPreflightScreenCaptureAccess() {
            // Puts the app in the pane's list so the user only has to flip the switch.
            CGRequestScreenCaptureAccess()
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }

    private static func open(_ urls: [String]) {
        for u in urls.compactMap(URL.init(string:)) where NSWorkspace.shared.open(u) { return }
    }

    static var menuBarAutoHides: Bool {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
        return (global["_HIHideMenuBar"] as? Int) == 1 || (global["_HIHideMenuBar"] as? Bool) == true
    }

    // MARK: Pages

    private func page(_ title: String, _ intro: String, _ views: [NSView]) -> NSView {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        let text = NSTextField(wrappingLabelWithString: intro)
        text.font = .systemFont(ofSize: 13)
        text.preferredMaxLayoutWidth = 600
        content.addArrangedSubview(heading)
        content.addArrangedSubview(text)
        content.setCustomSpacing(6, after: heading)
        for v in views {
            content.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        // The page fills its tab; the content stays at the top and a spacer takes the rest.
        content.distribution = .fill
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        content.addArrangedSubview(spacer)
        return content
    }

    private func permissionsPage() -> NSView {
        var views: [NSView] = []
        for p in permissions {
            let row = PermissionRow(title: p.title, why: p.why, required: p.required) { [weak self] in self?.open(pane: p.pane) }
            rows.append(row)
            views.append(row)
        }
        return page("Permissions", "BetterWM manages other apps' windows, which macOS only allows with your permission. Grant these in System Settings; the app picks them up on its own, no relaunch needed.", views)
    }

    private func desktopsPage() -> NSView {
        menuChoice = NSButton(radioButtonWithTitle: "Desktops in the system menu bar", target: self, action: #selector(chooseDesktops))
        barChoice = NSButton(radioButtonWithTitle: "A status bar of BetterWM's own", target: self, action: #selector(chooseDesktops))
        menuChoice.state = .on
        let menuNote = note("Numbers next to the BetterWM icon. Click to switch, drop a window on one to send it there. Nothing else changes on your screen.")
        let barNote = note("One bar per screen at the top: desktops with app icons, the focused window, now playing, sound, Wi-Fi, battery, a clock and optional cats. Tiled windows start below it.")
        let card = RecommendationView(title: "Hide the system menu bar", text: "The bar sits where the menu bar is. Set \"Automatically hide and show the menu bar\" to Always so the two do not overlap; the system bar still appears when you move the mouse to the top edge.", button: "Open Menu Bar Settings", image: SetupIllustration.image(.menuBar)) {
            Self.open(["x-apple.systempreferences:com.apple.Menu-Bar-Settings.extension", "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension"])
        }
        menuBarCard = card
        return page("Your desktops", "BetterWM's desktops replace macOS Spaces: they switch instantly and keep their layouts. Pick where to see them; you can change this in Settings later.",
                    [menuChoice, menuNote, barChoice, barNote, card])
    }

    private func note(_ text: String) -> NSView {
        let t = NSTextField(wrappingLabelWithString: text)
        t.font = .systemFont(ofSize: 12)
        t.textColor = .secondaryLabelColor
        t.preferredMaxLayoutWidth = 570
        let wrap = NSStackView(views: [t])
        wrap.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 4, right: 0)
        return wrap
    }

    @objc private func chooseDesktops() {
        guard var c = config() else { return }
        c.bar = barChoice.state == .on
        if !c.bar { c.menuBarChips = true }
        apply(c)
        c.save()
        menuBarCard?.isHidden = !c.bar
    }

    private func handoverPage() -> NSView {
        let cards = [
            RecommendationView(title: "Keep one native desktop per display", text: "Extra macOS Spaces only add a second, slower set of places for windows to hide. In Mission Control, close every desktop but the first on each display, and keep \"Displays have separate Spaces\" on.", button: "Open Desktop & Dock", image: SetupIllustration.image(.oneDesktop)) {
                Self.open(["x-apple.systempreferences:com.apple.Desktop-Settings.extension?MissionControl", "x-apple.systempreferences:com.apple.Desktop-Settings.extension"])
            },
            RecommendationView(title: "Free the Mission Control shortcuts", text: "macOS claims ⌃← ⌃→ and ⌃1 to ⌃9 for its own desktops, so they never reach BetterWM until you turn them off: Keyboard Shortcuts › Mission Control, untick both Mission Control rows and Application windows.", button: "Open Keyboard Shortcuts", image: SetupIllustration.image(.shortcuts)) {
                Self.open(["x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts", "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"])
            },
            RecommendationView(title: "Hand over the gestures and F3", text: "Turn off Mission Control, App Exposé and Swipe between full-screen applications under Trackpad › More Gestures, so BetterWM's swipe moves between its desktops and the Mission Control key opens its overview.", button: "Open Trackpad", image: SetupIllustration.image(.gestures)) {
                Self.open(["x-apple.systempreferences:com.apple.Trackpad-Settings.extension?MoreGestures", "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"])
            },
        ]
        return page("Hand over to BetterWM", "BetterWM takes over what Mission Control did. Three macOS settings keep the two from fighting; each button opens the right pane, and the picture shows what to change there.", cards)
    }

    private func readyPage() -> NSView {
        let tips = NSTextField(wrappingLabelWithString: "Hold ⌥ and drag a window to tile it. ⌃⌥T tiles or untiles the focused window, ⌃⌥S stacks the screen, ⌃1 to ⌃9 switch desktops and ⌃⌥1 to ⌃⌥9 send the window there. Everything is in the menu behind the BetterWM icon, and every binding is editable.")
        tips.font = .systemFont(ofSize: 13)
        tips.preferredMaxLayoutWidth = 520
        let settings = NSButton(title: "Open Settings…", target: self, action: #selector(openSettingsNow))
        let row = NSStackView(views: [settings, NSView()])
        row.orientation = .horizontal
        return page("Ready", "That is the setup. A few things to try first:", [tips, row])
    }

    @objc private func openSettingsNow() { openSettings() }

}

/// Schematic pictures of the settings to change: a few rows of a pane with the ones that matter marked, drawn in
/// the theme's colours, so they read at a glance where a screenshot would be a thumbnail.
enum SetupIllustration {
    enum Kind { case oneDesktop, shortcuts, gestures, menuBar }

    static func image(_ kind: Kind) -> NSImage {
        let size = NSSize(width: 150, height: 96)
        return NSImage(size: size, flipped: false) { rect in
            draw(kind, in: rect)
            return true
        }
    }

    private static func draw(_ kind: Kind, in rect: NSRect) {
        let panel = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.windowBackgroundColor.blended(withFraction: 0.3, of: .textBackgroundColor)?.setFill()
        panel.fill()
        NSColor.separatorColor.setStroke()
        panel.stroke()
        switch kind {
        case .oneDesktop:
            // Mission Control: one desktop kept, two others crossed out.
            let w: CGFloat = 36, h: CGFloat = 22, y = rect.midY - h / 2 + 6
            for (i, keep) in [true, false, false].enumerated() {
                let r = NSRect(x: 18 + CGFloat(i) * (w + 10), y: y, width: w, height: h)
                let p = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
                (keep ? NSColor.controlAccentColor.withAlphaComponent(0.85) : NSColor.secondaryLabelColor.withAlphaComponent(0.25)).setFill()
                p.fill()
                if !keep { cross(r) }
            }
            label("Desktop 1", at: NSPoint(x: 18, y: y - 16), bold: true)
            toggle(on: true, at: NSPoint(x: rect.maxX - 40, y: rect.minY + 12))
            label("Separate Spaces", at: NSPoint(x: 14, y: rect.minY + 10), bold: false)
        case .shortcuts:
            // Three shortcut rows: the Mission Control ones unticked, one left ticked for contrast.
            let rows: [(String, Bool)] = [("Mission Control", false), ("Application windows", false)]
            for (i, (name, on)) in rows.enumerated() {
                let y = rect.maxY - 24 - CGFloat(i) * 24
                checkbox(on: on, at: NSPoint(x: 16, y: y - 6))
                label(name, at: NSPoint(x: 34, y: y - 7), bold: false, dim: !on)
            }
            label("⌃←  ⌃→  ⌃1…9", at: NSPoint(x: 16, y: rect.minY + 10), bold: true)
        case .gestures:
            // Trackpad: a swipe arrow struck out above three switches turned off.
            let hand = NSBezierPath()
            hand.move(to: NSPoint(x: 24, y: rect.maxY - 22)); hand.line(to: NSPoint(x: 70, y: rect.maxY - 22))
            hand.move(to: NSPoint(x: 60, y: rect.maxY - 16)); hand.line(to: NSPoint(x: 70, y: rect.maxY - 22)); hand.line(to: NSPoint(x: 60, y: rect.maxY - 28))
            hand.lineWidth = 2; NSColor.secondaryLabelColor.setStroke(); hand.stroke()
            cross(NSRect(x: 24, y: rect.maxY - 32, width: 46, height: 20))
            for (i, name) in ["Mission Control", "App Exposé", "Full-screen swipe"].enumerated() {
                let y = rect.maxY - 48 - CGFloat(i) * 18
                label(name, at: NSPoint(x: 16, y: y - 6), bold: false, dim: true)
                toggle(on: false, at: NSPoint(x: rect.maxX - 40, y: y - 5))
            }
        case .menuBar:
            // A menu bar sliding up out of sight, the BetterWM bar taking its place.
            let bar = NSRect(x: 10, y: rect.maxY - 16, width: rect.width - 20, height: 8)
            NSColor.secondaryLabelColor.withAlphaComponent(0.3).setFill(); NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: rect.midX, y: rect.maxY - 20)); arrow.line(to: NSPoint(x: rect.midX, y: rect.maxY - 4))
            arrow.move(to: NSPoint(x: rect.midX - 5, y: rect.maxY - 10)); arrow.line(to: NSPoint(x: rect.midX, y: rect.maxY - 4)); arrow.line(to: NSPoint(x: rect.midX + 5, y: rect.maxY - 10))
            arrow.lineWidth = 2; NSColor.controlAccentColor.setStroke(); arrow.stroke()
            let ours = NSRect(x: 10, y: rect.maxY - 36, width: rect.width - 20, height: 10)
            NSColor.controlAccentColor.withAlphaComponent(0.85).setFill(); NSBezierPath(roundedRect: ours, xRadius: 3, yRadius: 3).fill()
            label("Hide menu bar: Always", at: NSPoint(x: 14, y: rect.minY + 10), bold: false)
            toggle(on: true, at: NSPoint(x: rect.maxX - 40, y: rect.minY + 12))
        }
    }

    private static func label(_ text: String, at p: NSPoint, bold: Bool, dim: Bool = false) {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: bold ? .semibold : .regular),
            .foregroundColor: dim ? NSColor.tertiaryLabelColor : NSColor.labelColor,
        ]).draw(at: p)
    }

    private static func toggle(on: Bool, at p: NSPoint) {
        let track = NSBezierPath(roundedRect: NSRect(x: p.x, y: p.y, width: 26, height: 14), xRadius: 7, yRadius: 7)
        (on ? NSColor.controlAccentColor : NSColor.secondaryLabelColor.withAlphaComponent(0.35)).setFill(); track.fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: on ? p.x + 13 : p.x + 1, y: p.y + 1, width: 12, height: 12)).fill()
    }

    private static func checkbox(on: Bool, at p: NSPoint) {
        let box = NSBezierPath(roundedRect: NSRect(x: p.x, y: p.y, width: 12, height: 12), xRadius: 3, yRadius: 3)
        if on { NSColor.controlAccentColor.setFill(); box.fill() } else { NSColor.secondaryLabelColor.setStroke(); box.lineWidth = 1; box.stroke() }
        if on {
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: p.x + 3, y: p.y + 6)); tick.line(to: NSPoint(x: p.x + 5.5, y: p.y + 3.5)); tick.line(to: NSPoint(x: p.x + 9.5, y: p.y + 9))
            tick.lineWidth = 1.5; NSColor.white.setStroke(); tick.stroke()
        }
    }

    private static func cross(_ r: NSRect) {
        let x = NSBezierPath()
        x.move(to: NSPoint(x: r.minX + 4, y: r.minY + 4)); x.line(to: NSPoint(x: r.maxX - 4, y: r.maxY - 4))
        x.move(to: NSPoint(x: r.minX + 4, y: r.maxY - 4)); x.line(to: NSPoint(x: r.maxX - 4, y: r.minY + 4))
        x.lineWidth = 2; NSColor.systemRed.setStroke(); x.stroke()
    }
}

/// One recommendation: a title, what to do and why, a button to the pane, a picture of the pane with the change
/// marked (click to see it large), and a check mark once it is done where the app can tell.
private final class RecommendationView: NSView {
    private let status = NSTextField(labelWithString: "")
    var done: Bool? { didSet { status.stringValue = done == true ? "✓ Done" : ""; status.isHidden = done != true } }

    init(title: String, text: String, button: String, image: NSImage?, action: @escaping () -> Void) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: text)
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = image == nil ? 420 : 400
        status.font = .systemFont(ofSize: 12)
        status.textColor = .systemGreen
        status.isHidden = true
        let open = ActionButton(title: button, action: action)
        let buttons = NSStackView(views: [open, status])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let left = NSStackView(views: [name, body, buttons])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 6
        left.setCustomSpacing(10, after: body)
        var views: [NSView] = [left]
        if let image {
            let shot = NSImageView(image: image)
            shot.imageScaling = .scaleNone
            shot.widthAnchor.constraint(equalToConstant: image.size.width).isActive = true
            shot.heightAnchor.constraint(equalToConstant: image.size.height).isActive = true
            views.append(shot)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 14
        row.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            left.widthAnchor.constraint(equalToConstant: image == nil ? 420 : 400),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

private final class ActionButton: NSButton {
    private let run: () -> Void
    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        self.action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

private final class PermissionRow: NSView {
    private let status = NSTextField(labelWithString: "")
    private let button: NSButton
    private let onOpen: () -> Void
    var granted = false { didSet { render() } }
    private let required: Bool

    init(title: String, why: String, required: Bool, onOpen: @escaping () -> Void) {
        self.onOpen = onOpen
        self.required = required
        button = NSButton(title: "Open System Settings", target: nil, action: nil)
        super.init(frame: .zero)
        button.target = self
        button.action = #selector(open)
        let name = NSTextField(labelWithString: title + (required ? "" : "  (optional)"))
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        let text = NSTextField(wrappingLabelWithString: why)
        text.font = .systemFont(ofSize: 12)
        text.textColor = .secondaryLabelColor
        text.preferredMaxLayoutWidth = 330
        status.font = .systemFont(ofSize: 12)
        let left = NSStackView(views: [name, text])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 3
        let right = NSStackView(views: [status, button])
        right.orientation = .vertical
        right.alignment = .trailing
        right.spacing = 6
        let row = NSStackView(views: [left, right])
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            left.widthAnchor.constraint(equalToConstant: 330),
        ])
        render()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func render() {
        status.stringValue = granted ? "✓ Granted" : "Not granted"
        status.textColor = granted ? .systemGreen : (required ? .systemOrange : .secondaryLabelColor)
        button.isHidden = granted
    }

    @objc private func open() { onOpen() }
}
