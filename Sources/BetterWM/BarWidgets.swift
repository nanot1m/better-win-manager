import BetterWMCore
import Cocoa

/// What a widget renders with: the bar's colours and the configuration.
struct BarStyle {
    let textColor: NSColor
    let activeColor: NSColor
    let focusOutline: NSColor?
    let config: Config

    /// On glass the text always follows the system: the glass itself turns light or dark with the theme.
    static func textColor(of config: Config) -> NSColor {
        guard config.barBackground.lowercased() != "glass", config.barTextColor.lowercased() != "auto" else { return .labelColor }
        return NSColor(hex: config.barTextColor) ?? .labelColor
    }
}

/// A view laid over the whole bar that lives in the span left free by the sides.
protocol BarFreeView: NSView {
    var roam: ClosedRange<CGFloat> { get set }
    var gap: ClosedRange<CGFloat>? { get set }
}

/// What the left-side widgets ask of the window manager, and what they tell it.
final class BarContext {
    var desktopsOn: (NSScreen) -> [Int] = { _ in [] }
    var shownOn: (NSScreen) -> Int? = { _ in nil }
    var activeDesktop: () -> Int? = { nil }
    var desktopApps: () -> [Int: [(pid: pid_t, windows: [WindowID])]] = { [:] }
    var floatingApps: () -> [(pid: pid_t, windows: [WindowID])] = { [] }
    var onSelectFloating: (() -> Void)?
    var focusedWindow: () -> WindowID? = { nil }
    var fullscreenSpaces: () -> [(space: UInt64, pids: [pid_t])] = { [] }
    var focusedAXWindow: () -> AXWindow? = { nil }
    var tabLabel: (WindowID) -> String? = { _ in nil }
    var onSelectDesktop: ((Int) -> Void)?
    var onSelectFullscreen: ((UInt64) -> Void)?
    var onReorderDesktop: ((Int, Int) -> Void)?
    var onDesktopMenu: ((Int, NSView) -> Void)?
}

/// One entry of the status bar. A widget owns its data source, one view per bar window, and its refresh
/// triggers; the bar only orders, starts and renders it. `wantsRefresh` asks the bar for a render pass.
protocol BarWidget: AnyObject {
    var id: Config.BarWidget { get }
    var wantsRefresh: (() -> Void)? { get set }
    /// A view for one bar window, on `screen`; the widget keeps it and updates it on `render`.
    func makeView(for screen: NSScreen) -> NSView
    /// Forgets every view made: the bar windows are being rebuilt.
    func dropViews()
    /// The data source runs only while the widget is in the bar.
    func start()
    func stop()
    func apply(_ config: Config)
    /// Updates every view; hidden when there is nothing to show.
    func render(_ style: BarStyle)
}

extension BarWidget {
    func start() {}
    func stop() {}
    func apply(_ config: Config) {}
}

/// A non-key panel swallows the first click unless the control accepts it.
final class BarButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A button that also reports trackpad and wheel scrolling, for the volume.
final class BarScrollButton: NSButton {
    var onScroll: ((CGFloat) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func scrollWheel(with event: NSEvent) {
        let d = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        guard d != 0 else { return }
        onScroll?(event.hasPreciseScrollingDeltas ? d / 4 : d)
    }
}

enum BarWidgetViews {
    static func label(monospaced: Bool = false, weight: NSFont.Weight = .regular) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = monospaced ? .monospacedDigitSystemFont(ofSize: 12, weight: weight) : .systemFont(ofSize: 12, weight: weight)
        l.lineBreakMode = .byTruncatingTail
        l.maximumNumberOfLines = 1
        return l
    }
    static func icon(_ symbol: String? = nil, width: CGFloat = 16) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyDown
        if let symbol { v.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        v.widthAnchor.constraint(equalToConstant: width).isActive = true
        return v
    }
    static func row(_ views: [NSView], spacing: CGFloat = 3) -> NSStackView {
        let st = NSStackView(views: views)
        st.orientation = .horizontal
        st.alignment = .centerY
        st.spacing = spacing
        return st
    }
    /// Two digits minimum, padded with a figure space so monospaced labels keep a stable width.
    static func percent(_ value: Double) -> String {
        let n = Int(value.rounded())
        return (n < 10 ? "\u{2007}" : "") + "\(n)%"
    }
}

/// An icon with a value label, one per bar window.
final class IconValueView {
    let icon: NSImageView
    let label: NSTextField
    let row: NSStackView
    init(symbol: String?, iconWidth: CGFloat = 16, monospaced: Bool = true, spacing: CGFloat = 3) {
        icon = BarWidgetViews.icon(symbol, width: iconWidth)
        label = BarWidgetViews.label(monospaced: monospaced)
        row = BarWidgetViews.row([icon, label], spacing: spacing)
    }
}

/// Icon + text widgets that read a value on every render: CPU, memory, disk, battery, weather.
class ValueWidget: BarWidget {
    let id: Config.BarWidget
    var wantsRefresh: (() -> Void)?
    var views: [IconValueView] = []
    private let symbol: String?
    private let iconWidth: CGFloat
    private let monospaced: Bool
    private let spacing: CGFloat

    init(id: Config.BarWidget, symbol: String?, iconWidth: CGFloat = 16, monospaced: Bool = true, spacing: CGFloat = 3) {
        self.id = id; self.symbol = symbol; self.iconWidth = iconWidth; self.monospaced = monospaced; self.spacing = spacing
    }

    func makeView(for screen: NSScreen) -> NSView {
        let v = IconValueView(symbol: symbol, iconWidth: iconWidth, monospaced: monospaced, spacing: spacing)
        views.append(v)
        return v.row
    }
    func dropViews() { views.removeAll() }
    func apply(_ config: Config) {}

    /// The text to show, or nil to hide; `symbol` overrides the fixed icon.
    func reading(_ style: BarStyle) -> (text: String, symbol: String?, tint: NSColor?)? { nil }

    func render(_ style: BarStyle) {
        let r = reading(style)
        for v in views {
            v.row.isHidden = r == nil
            guard let r else { continue }
            v.label.stringValue = r.text
            v.label.textColor = style.textColor
            if let s = r.symbol { v.icon.image = NSImage(systemSymbolName: s, accessibilityDescription: nil) }
            v.icon.contentTintColor = r.tint ?? style.textColor
        }
    }
}

final class CpuWidget: ValueWidget {
    /// The last reading, for the cats.
    private(set) var load: Double?
    init() { super.init(id: .cpu, symbol: "cpu") }
    override func reading(_ style: BarStyle) -> (text: String, symbol: String?, tint: NSColor?)? {
        load = SystemStatus.cpuLoad()
        return load.map { (BarWidgetViews.percent($0 * 100), nil, nil) }
    }
}

final class MemoryWidget: ValueWidget {
    init() { super.init(id: .memory, symbol: "memorychip") }
    override func reading(_ style: BarStyle) -> (text: String, symbol: String?, tint: NSColor?)? {
        SystemStatus.memoryUsed().map { (BarWidgetViews.percent($0 * 100), nil, nil) }
    }
}

final class DiskWidget: ValueWidget {
    init() { super.init(id: .disk, symbol: "internaldrive") }
    override func reading(_ style: BarStyle) -> (text: String, symbol: String?, tint: NSColor?)? {
        SystemStatus.diskFree().map { (SystemStatus.formatBytes($0), nil, nil) }
    }
}

final class BatteryWidget: ValueWidget {
    /// The last reading, for the cats.
    private(set) var battery: SystemStatus.Battery?
    init() { super.init(id: .battery, symbol: nil, iconWidth: 22, spacing: 4) }
    override func reading(_ style: BarStyle) -> (text: String, symbol: String?, tint: NSColor?)? {
        battery = SystemStatus.battery()
        guard let b = battery else { return nil }
        let low = b.percent <= 15 && !b.charging
        return (style.config.barBatteryPercent ? BarWidgetViews.percent(Double(b.percent)) : "", b.symbol, low ? .systemRed : nil)
    }
    override func render(_ style: BarStyle) {
        super.render(style)
        for v in views {
            v.label.isHidden = !style.config.barBatteryPercent
            v.icon.toolTip = battery.map { "\($0.percent)%" }
        }
    }
}

final class WeatherWidget: ValueWidget {
    private let service: WeatherService
    init(config: Config) {
        service = WeatherService(config: config)
        super.init(id: .weather, symbol: nil, monospaced: false)
        service.onUpdate = { [weak self] _ in self?.wantsRefresh?() }
    }
    override func apply(_ config: Config) { service.apply(config) }
    override func reading(_ style: BarStyle) -> (text: String, symbol: String?, tint: NSColor?)? {
        service.reading.map { (String(format: "%.0f°", $0.temperature), $0.symbol, nil) }
    }
}

final class ClockWidget: BarWidget {
    let id = Config.BarWidget.clock
    var wantsRefresh: (() -> Void)?
    private var labels: [NSTextField] = []
    private var timer: Timer?
    private let formatter = DateFormatter()

    func makeView(for screen: NSScreen) -> NSView {
        let l = BarWidgetViews.label(monospaced: true, weight: .medium)
        labels.append(l)
        return l
    }
    func dropViews() { labels.removeAll() }
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.wantsRefresh?() }
    }
    func stop() { timer?.invalidate(); timer = nil }
    func apply(_ config: Config) { formatter.dateFormat = config.barClockFormat }
    func render(_ style: BarStyle) {
        if formatter.dateFormat != style.config.barClockFormat { formatter.dateFormat = style.config.barClockFormat }
        let text = formatter.string(from: Date())
        for l in labels { l.stringValue = text; l.textColor = style.textColor }
    }
}

final class WifiWidget: BarWidget {
    let id = Config.BarWidget.wifi
    var wantsRefresh: (() -> Void)?
    private var icons: [NSImageView] = []
    private let monitor = WiFiMonitor()

    init() { monitor.onChange = { [weak self] in self?.wantsRefresh?() } }
    func makeView(for screen: NSScreen) -> NSView {
        let v = BarWidgetViews.icon()
        icons.append(v)
        return BarWidgetViews.row([v])
    }
    func dropViews() { icons.removeAll() }
    func render(_ style: BarStyle) {
        let image = monitor.strength.map { NSImage(systemSymbolName: "wifi", variableValue: $0, accessibilityDescription: nil) }
            ?? NSImage(systemSymbolName: "wifi.slash", accessibilityDescription: nil)
        for v in icons { v.image = image; v.contentTintColor = style.textColor }
    }
}

final class KeyboardWidget: BarWidget {
    let id = Config.BarWidget.keyboard
    var wantsRefresh: (() -> Void)?
    private var labels: [NSTextField] = []
    private var observer: NSObjectProtocol?

    func makeView(for screen: NSScreen) -> NSView {
        let l = BarWidgetViews.label(weight: .semibold)
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.wantsLayer = true
        l.layer?.cornerRadius = 4
        l.alignment = .center
        l.widthAnchor.constraint(equalToConstant: 26).isActive = true
        labels.append(l)
        return BarWidgetViews.row([l])
    }
    func dropViews() { labels.removeAll() }
    func start() { if observer == nil { observer = InputSource.observe { [weak self] in self?.wantsRefresh?() } } }
    func stop() { observer = nil }
    func render(_ style: BarStyle) {
        let text = InputSource.current()
        for l in labels {
            l.stringValue = text
            l.textColor = style.textColor
            l.layer?.backgroundColor = style.textColor.dimmed(0.12).cgColor
        }
    }
}

/// Play/pause button and the track; hidden while nothing plays.
final class MediaWidget: BarWidget {
    let id = Config.BarWidget.media
    var wantsRefresh: (() -> Void)?
    private struct Views { let button: BarButton; let label: NSTextField; let row: NSStackView }
    private var views: [Views] = []
    private let service = MediaService()

    init() { service.onUpdate = { [weak self] _ in self?.wantsRefresh?() } }
    func makeView(for screen: NSScreen) -> NSView {
        let button = BarButton(title: "", target: self, action: #selector(pressed))
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let label = BarWidgetViews.label()
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        let v = Views(button: button, label: label, row: BarWidgetViews.row([button, label], spacing: 2))
        views.append(v)
        return v.row
    }
    func dropViews() { views.removeAll() }
    func start() { service.start() }
    func stop() { service.stop() }
    @objc private func pressed() { service.togglePlayPause() }
    func render(_ style: BarStyle) {
        let np = service.current
        for v in views {
            v.row.isHidden = np == nil
            guard let np else { continue }
            v.button.image = NSImage(systemSymbolName: np.playing ? "pause.fill" : "play.fill", accessibilityDescription: np.playing ? "Pause" : "Play")
            v.button.contentTintColor = style.textColor
            v.label.stringValue = np.text
            v.label.toolTip = np.text
            v.label.textColor = style.textColor
        }
    }
}

/// Volume icon: click for the popover with devices and sliders, scroll to change the output volume.
final class SoundWidget: BarWidget {
    let id = Config.BarWidget.sound
    var wantsRefresh: (() -> Void)?
    private var buttons: [BarScrollButton] = []
    let service = SoundService()
    private lazy var popover = SoundPopover(service: service)

    init() { service.onChange = { [weak self] in self?.wantsRefresh?(); self?.popover.refreshIfShown() } }
    func makeView(for screen: NSScreen) -> NSView {
        let b = BarScrollButton(title: "", target: self, action: #selector(pressed(_:)))
        b.isBordered = false
        b.imageScaling = .scaleProportionallyDown
        b.widthAnchor.constraint(equalToConstant: 24).isActive = true
        b.heightAnchor.constraint(equalToConstant: 28).isActive = true
        b.onScroll = { [weak self] d in
            guard let self else { return }
            self.service.setOutputVolume(self.service.state.outputVolume + Float(d) * 0.03)
        }
        buttons.append(b)
        return BarWidgetViews.row([b])
    }
    func dropViews() { buttons.removeAll() }
    func start() { service.start() }
    func stop() { service.stop() }
    @objc private func pressed(_ sender: NSView) { popover.toggle(relativeTo: sender) }
    /// Dev aid: the popover on the first bar.
    func showPopover() { if let b = buttons.first { popover.toggle(relativeTo: b) } }
    func render(_ style: BarStyle) {
        let image = NSImage(systemSymbolName: service.symbolName, accessibilityDescription: "Sound")
        for b in buttons { b.image = image; b.contentTintColor = style.textColor }
    }
}

/// The BetterWM menu button.
final class MenuWidget: BarWidget {
    let id = Config.BarWidget.menu
    var wantsRefresh: (() -> Void)?
    var onPressed: ((NSView) -> Void)?
    private var buttons: [BarButton] = []

    func makeView(for screen: NSScreen) -> NSView {
        let b = BarButton(title: "", target: self, action: #selector(pressed(_:)))
        b.isBordered = false
        b.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "BetterWM menu")
        b.imageScaling = .scaleProportionallyDown
        // Generous hit area: the icon is 16pt but the whole bar height and a wide margin should take the click.
        b.widthAnchor.constraint(equalToConstant: 32).isActive = true
        b.heightAnchor.constraint(equalToConstant: 28).isActive = true
        b.toolTip = "BetterWM"
        buttons.append(b)
        return BarWidgetViews.row([b])
    }
    func dropViews() { buttons.removeAll() }
    @objc private func pressed(_ sender: NSView) { onPressed?(sender) }
    func render(_ style: BarStyle) { for b in buttons { b.contentTintColor = style.textColor } }
}

// MARK: - Left side

/// Desktop chips of one screen: number plus the icons of the apps open there, draggable to reorder desktops,
/// with a menu on right-click, and lit up while a window is dragged over one.
final class DesktopChipsView: NSStackView {
    private let screen: NSScreen
    private let context: BarContext
    private var chips: [ChipView] = []
    /// Desktop index of each visible chip, left to right.
    private(set) var chipDesktops: [Int] = []
    /// The floating windows shared across desktops, after the desktop chips; hidden when there are none.
    private let floatingChip = ChipView()
    private var activeColor = NSColor.controlAccentColor
    private var chipDrag: ReorderDrag?
    private var settlingChips: ReorderDrag?

    init(screen: NSScreen, context: BarContext) {
        self.screen = screen
        self.context = context
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 10
        alignment = .centerY
    }
    required init(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        settlingChips?.settle()
        settlingChips = nil
    }

    /// The desktop under a point in this view's coordinates.
    func chipDesktop(at point: NSPoint) -> Int? {
        for (i, c) in chips.enumerated() where !c.isHidden && i < chipDesktops.count {
            if c.frame.insetBy(dx: -4, dy: -6).contains(point) { return chipDesktops[i] }
        }
        return nil
    }

    /// Where a desktop's chip is, in the coordinates of `view`; for the cats.
    func chipMidX(for desktop: Int, in view: NSView) -> CGFloat? {
        guard let i = chipDesktops.firstIndex(of: desktop), chips.indices.contains(i) else { return nil }
        return chips[i].convert(chips[i].bounds, to: view).midX
    }

    func setDropTarget(_ desktop: Int?) {
        for (i, c) in chips.enumerated() where i < chipDesktops.count {
            c.setDropTarget(chipDesktops[i] == desktop, color: activeColor)
        }
    }

    func render(_ style: BarStyle) {
        activeColor = style.activeColor
        let desktops = context.desktopsOn(screen)
        let current = context.shownOn(screen), active = context.activeDesktop()
        let apps = style.config.barDesktopApps ? context.desktopApps() : [:]
        let focused = context.focusedWindow()
        chipDesktops = desktops
        while chips.count < desktops.count {
            let c = ChipView()
            // Chips change places in `chips` after a drag, so each looks its index up when asked.
            let indexOf: (ChipView) -> Int? = { [weak self] c in self?.chips.firstIndex { $0 === c } }
            c.onClick = { [weak self, weak c] in
                guard let self, let c, let i = indexOf(c), i < self.chipDesktops.count else { return }
                self.context.onSelectDesktop?(self.chipDesktops[i])
            }
            c.onDragBegan = { [weak self, weak c] in if let c, let i = indexOf(c) { self?.beginDrag(i) } }
            c.onDragMoved = { [weak self] dx in self?.chipDrag?.update(delta: dx) }
            c.onDragEnded = { [weak self] in self?.endDrag() }
            c.onContextMenu = { [weak self, weak c] in
                guard let self, let c, let i = indexOf(c), i < self.chipDesktops.count else { return }
                self.context.onDesktopMenu?(self.chipDesktops[i], c)
            }
            chips.append(c)
            addArrangedSubview(c)
        }
        for (i, c) in chips.enumerated() {
            c.isHidden = i >= desktops.count
            guard i < desktops.count else { continue }
            let d = desktops[i]
            // The desktop being worked on gets the accent; the one merely shown on this screen a lighter mark.
            let isCurrent = d == current && d == active
            let shownHere = d == current
            c.number.attributedStringValue = NSAttributedString(string: "\(d + 1)", attributes: [
                .foregroundColor: isCurrent ? style.activeColor.contrastingText : style.textColor.dimmed(shownHere ? 1 : 0.7),
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            ])
            let glass = style.config.barChipStyle == "glass"
            if glass, Glass.makeView() != nil {
                c.setGlass(true, tint: isCurrent ? style.activeColor : nil, clear: style.config.glassStyle == "clear")
                c.layer?.backgroundColor = nil
            } else {
                c.setGlass(false, tint: nil)
                c.layer?.backgroundColor = isCurrent ? style.activeColor.cgColor : style.textColor.dimmed(shownHere ? 0.3 : 0.1).cgColor
            }
            c.setApps(apps[d] ?? [], focused: focused, color: style.focusOutline ?? (isCurrent ? style.activeColor.contrastingText : style.activeColor))
        }
        renderFloatingChip(style, focused: focused)
    }

    private func renderFloatingChip(_ style: BarStyle, focused: WindowID?) {
        let floating = context.floatingApps()
        if floatingChip.superview == nil {
            floatingChip.onClick = { [weak self] in self?.context.onSelectFloating?() }
            addArrangedSubview(floatingChip)
        } else if arrangedSubviews.last !== floatingChip {
            // Chips are appended as desktops appear; the floating chip stays last.
            removeArrangedSubview(floatingChip)
            addArrangedSubview(floatingChip)
        }
        floatingChip.isHidden = floating.isEmpty
        guard !floating.isEmpty else { return }
        let holdsFocus = focused.map { f in floating.contains { $0.windows.contains(f) } } ?? false
        floatingChip.number.attributedStringValue = NSAttributedString(string: "⧉", attributes: [
            .foregroundColor: holdsFocus ? style.activeColor.contrastingText : style.textColor,
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
        ])
        if style.config.barChipStyle == "glass", Glass.makeView() != nil {
            floatingChip.setGlass(true, tint: holdsFocus ? style.activeColor : nil, clear: style.config.glassStyle == "clear")
            floatingChip.layer?.backgroundColor = nil
        } else {
            floatingChip.setGlass(false, tint: nil)
            floatingChip.layer?.backgroundColor = holdsFocus ? style.activeColor.cgColor : style.textColor.dimmed(0.3).cgColor
        }
        floatingChip.setApps(floating, focused: focused, color: style.focusOutline ?? (holdsFocus ? style.activeColor.contrastingText : style.activeColor))
    }

    private func beginDrag(_ index: Int) {
        let visible = chips.enumerated().filter { !$0.element.isHidden && $0.offset < chipDesktops.count }
        guard let i = visible.firstIndex(where: { $0.offset == index }) else { return }
        chipDrag = ReorderDrag(items: visible.map(\.element), index: i, horizontal: true)
    }

    private func endDrag() {
        guard let drag = chipDrag else { return }
        chipDrag = nil
        let visible = chips.enumerated().filter { !$0.element.isHidden && $0.offset < chipDesktops.count }.map(\.offset)
        drag.end { [weak self] target in
            guard let self, let from = visible.firstIndex(where: { self.chips[$0] === drag.grabbed }), target != from,
                  target < visible.count else {
                drag.settle()
                return
            }
            // The chip view moves to its new place first, keeping its content, so the re-render only confirms what
            // is already on screen; relabelling views in place would show the old order for a frame.
            let fromIndex = visible[from], toIndex = visible[target]
            let c = self.chips.remove(at: fromIndex)
            self.chips.insert(c, at: toIndex)
            self.insertArrangedSubview(c, at: toIndex)
            self.settlingChips = drag
            self.needsLayout = true
            self.context.onReorderDesktop?(self.chipDesktops[fromIndex], self.chipDesktops[toIndex])
        }
    }
}

final class DesktopsWidget: BarWidget {
    let id = Config.BarWidget.desktops
    var wantsRefresh: (() -> Void)?
    private let context: BarContext
    private(set) var views: [DesktopChipsView] = []

    init(context: BarContext) { self.context = context }
    func makeView(for screen: NSScreen) -> NSView {
        let v = DesktopChipsView(screen: screen, context: context)
        views.append(v)
        return v
    }
    func dropViews() { views.removeAll() }
    func render(_ style: BarStyle) { views.forEach { $0.render(style) } }

    /// The desktop whose chip is under a screen point (Cocoa coordinates), on any bar.
    func chipDesktop(atScreenPoint p: NSPoint) -> Int? {
        for v in views {
            guard let w = v.window, w.isVisible, w.frame.contains(p) else { continue }
            return v.chipDesktop(at: v.convert(w.convertPoint(fromScreen: p), from: nil))
        }
        return nil
    }
    func setDropTarget(_ desktop: Int?) { views.forEach { $0.setDropTarget(desktop) } }
}

/// Fullscreen Spaces, one chip each after the desktop chips; clicking one goes there.
final class FullscreenWidget: BarWidget {
    let id = Config.BarWidget.fullscreen
    var wantsRefresh: (() -> Void)?
    private let context: BarContext
    private final class Row { let stack: NSStackView; var chips: [ChipView] = []; var spaces: [UInt64] = []
        init() { stack = NSStackView(); stack.orientation = .horizontal; stack.spacing = 10; stack.alignment = .centerY } }
    private var rows: [Row] = []

    init(context: BarContext) { self.context = context }
    func makeView(for screen: NSScreen) -> NSView {
        let r = Row()
        rows.append(r)
        return r.stack
    }
    func dropViews() { rows.removeAll() }
    func render(_ style: BarStyle) {
        let spaces = context.fullscreenSpaces()
        for r in rows {
            r.spaces = spaces.map(\.space)
            r.stack.isHidden = spaces.isEmpty
            while r.chips.count < spaces.count {
                let c = ChipView()
                let i = r.chips.count
                c.onClick = { [weak self, weak r] in
                    guard let self, let r, i < r.spaces.count else { return }
                    self.context.onSelectFullscreen?(r.spaces[i])
                }
                r.chips.append(c)
                r.stack.addArrangedSubview(c)
            }
            for (i, c) in r.chips.enumerated() {
                c.isHidden = i >= spaces.count
                guard i < spaces.count else { continue }
                c.number.attributedStringValue = NSAttributedString(string: "⛶", attributes: [
                    .foregroundColor: style.textColor.dimmed(0.7), .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                ])
                c.layer?.backgroundColor = style.textColor.dimmed(0.1).cgColor
                c.setApps(spaces[i].pids.map { ($0, []) }, focused: nil, color: style.activeColor)
            }
        }
    }
}

/// The active window's label, after a separator: `barTitleFormat`, or the name its tab was given.
final class TitleWidget: BarWidget {
    let id = Config.BarWidget.title
    var wantsRefresh: (() -> Void)?
    private let context: BarContext
    private var labels: [NSTextField] = []

    init(context: BarContext) { self.context = context }
    func makeView(for screen: NSScreen) -> NSView {
        let sep = NSBox(); sep.boxType = .separator
        sep.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let l = BarWidgetViews.label()
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labels.append(l)
        return BarWidgetViews.row([sep, l], spacing: 10)
    }
    func dropViews() { labels.removeAll() }
    func render(_ style: BarStyle) {
        let focused = context.focusedAXWindow()
        let app = focused.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.localizedName }
            ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let title = focused?.title ?? ""
        let text = focused?.windowID.flatMap(context.tabLabel).map { BarView.formatTitle("{app}", app: $0, title: "", color: style.textColor) }
            ?? BarView.formatTitle(style.config.barTitleFormat, app: app, title: title, color: style.textColor)
        for l in labels { l.attributedStringValue = text }
    }
}

enum BarWidgets {
    /// One widget object per kind, built once for the bar's lifetime.
    static func make(config: Config, context: BarContext) -> [Config.BarWidget: BarWidget] {
        let all: [BarWidget] = [DesktopsWidget(context: context), FullscreenWidget(context: context), TitleWidget(context: context),
                                WeatherWidget(config: config), CpuWidget(), MemoryWidget(), DiskWidget(), KeyboardWidget(),
                                WifiWidget(), BatteryWidget(), ClockWidget(), MenuWidget(), MediaWidget(), SoundWidget(),
                                CatsWidget(context: context)]
        return Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }
}

extension BarCat: BarFreeView {}

/// The cats: one `BarCat` per bar, roaming the span the layout leaves free, reacting to what the other
/// widgets show (a new desktop, a low battery, a busy machine).
final class CatsWidget: BarWidget {
    let id = Config.BarWidget.cats
    var wantsRefresh: (() -> Void)?
    /// The widgets the cats watch, looked up by id; set by the bar once every widget exists.
    var peer: (Config.BarWidget) -> BarWidget? = { _ in nil }
    private let context: BarContext
    private var config: Config?
    private var cats: [(screen: NSScreen, view: BarCat)] = []
    private var lastDesktop: [ObjectIdentifier: Int] = [:]
    private var warnedBatteryLow = false
    private var lastLoadReaction = Date.distantPast

    init(context: BarContext) { self.context = context }

    func makeView(for screen: NSScreen) -> NSView {
        let v = BarCat(frame: .zero)
        if let c = config { v.configure(sheets: c.barCatSheets, color: BarStyle.textColor(of: c), barHeight: c.barHeight) }
        cats.append((screen, v))
        return v
    }
    func dropViews() { cats.removeAll(); lastDesktop = [:] }
    func start() {}
    func stop() {}
    func apply(_ config: Config) {
        self.config = config
        cats.forEach { $0.view.configure(sheets: config.barCatSheets, color: BarStyle.textColor(of: config), barHeight: config.barHeight) }
    }

    func render(_ style: BarStyle) {
        let battery = peer(.battery) as? BatteryWidget
        let chips = peer(.desktops) as? DesktopsWidget
        let load = (peer(.cpu) as? CpuWidget)?.load
        for (screen, cat) in cats where !cat.isHidden {
            let key = ObjectIdentifier(cat)
            if let current = context.shownOn(screen), current != lastDesktop[key] {
                if lastDesktop[key] != nil, let x = chips?.views.first(where: { $0.window === cat.window })?.chipMidX(for: current, in: cat) {
                    cat.react(.desktopSwitched(towardX: x))
                }
                lastDesktop[key] = current
            }
            if let b = battery?.battery, let w = battery?.views.first(where: { $0.row.window === cat.window })?.row {
                if b.percent <= 15, !b.charging, !warnedBatteryLow, !w.isHidden {
                    warnedBatteryLow = true
                    cat.react(.batteryLow(x: w.convert(w.bounds, to: cat).midX))
                } else if warnedBatteryLow, b.charging {
                    warnedBatteryLow = false
                    cat.react(.charging(x: w.convert(w.bounds, to: cat).midX))
                } else if b.percent > 20 {
                    warnedBatteryLow = false
                }
            }
            if let load, load > 0.8, Date().timeIntervalSince(lastLoadReaction) > 120 {
                lastLoadReaction = Date()
                cat.react(.load)
            }
        }
    }
}
