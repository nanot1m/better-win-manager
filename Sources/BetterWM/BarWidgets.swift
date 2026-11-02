import BetterWMCore
import Cocoa

/// What a widget renders with: the bar's colours and the configuration.
struct BarStyle {
    let textColor: NSColor
    let config: Config
}

/// One entry of the status bar's right side. A widget owns its data source, one view per bar window, and its refresh
/// triggers; the bar only orders, starts and renders it. `wantsRefresh` asks the bar for a render pass.
protocol BarWidget: AnyObject {
    var id: Config.BarWidget { get }
    var wantsRefresh: (() -> Void)? { get set }
    /// A view for one bar window; the widget keeps it and updates it on `render`.
    func makeView() -> NSView
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

    func makeView() -> NSView {
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

    func makeView() -> NSView {
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
    func makeView() -> NSView {
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

    func makeView() -> NSView {
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
            l.layer?.backgroundColor = style.textColor.withAlphaComponent(0.12).cgColor
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
    func makeView() -> NSView {
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
    func makeView() -> NSView {
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

    func makeView() -> NSView {
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

enum BarWidgets {
    /// One widget object per kind, built once for the bar's lifetime.
    static func make(config: Config) -> [Config.BarWidget: BarWidget] {
        let all: [BarWidget] = [WeatherWidget(config: config), CpuWidget(), MemoryWidget(), DiskWidget(), KeyboardWidget(),
                                WifiWidget(), BatteryWidget(), ClockWidget(), MenuWidget(), MediaWidget(), SoundWidget()]
        return Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }
}
