import Cocoa

/// First-run window: which permissions BetterWM needs, why, and a button straight to the right System Settings
/// pane for each. Shown at launch while Accessibility is missing, and from the menu any time.
final class OnboardingWindow {
    private let window: NSWindow
    private var rows: [PermissionRow] = []
    private var poll: Timer?

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

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 10), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Welcome to BetterWM"
        window.isReleasedWhenClosed = false
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        let intro = NSTextField(wrappingLabelWithString: "BetterWM manages other apps' windows, which macOS only allows with your permission. Grant these in System Settings; the app picks them up on its own, no relaunch needed.")
        intro.font = .systemFont(ofSize: 13)
        intro.preferredMaxLayoutWidth = 480
        content.addArrangedSubview(intro)
        for p in permissions {
            let row = PermissionRow(title: p.title, why: p.why, required: p.required) { [weak self] in self?.open(pane: p.pane) }
            rows.append(row)
            content.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true
        }
        let done = NSButton(title: "Continue", target: self, action: #selector(close))
        done.keyEquivalent = "\r"
        let footer = NSStackView(views: [NSView(), done])
        footer.orientation = .horizontal
        content.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true
        content.setCustomSpacing(6, after: intro)
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.center()
    }

    /// True when the window should appear at launch: the required permission is missing.
    var needed: Bool { !permissions.filter(\.required).allSatisfy { $0.granted() } }

    var windowNumber: Int { window.windowNumber }

    func show() {
        update()
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.update() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func close() {
        poll?.invalidate()
        poll = nil
        window.close()
    }

    private func update() {
        for (row, p) in zip(rows, permissions) { row.granted = p.granted() }
    }

    private func open(pane: String) {
        if pane == "Privacy_ScreenCapture", !CGPreflightScreenCaptureAccess() {
            // Puts the app in the pane's list so the user only has to flip the switch.
            CGRequestScreenCaptureAccess()
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
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
        text.preferredMaxLayoutWidth = 300
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
            left.widthAnchor.constraint(equalToConstant: 300),
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
