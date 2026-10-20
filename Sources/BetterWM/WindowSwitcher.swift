import BetterWMCore
import Cocoa

/// ⌥Tab: all windows grouped by desktop (or virtual workspace). Hold ⌥ and press Tab to cycle, release to switch;
/// Escape cancels; items are clickable.
final class WindowSwitcher {
    struct Item {
        let window: AXWindow
        let id: WindowID
        let desktop: Int
        let title: String
        let app: String
        let icon: NSImage?
    }
    struct Group { let desktop: Int; let items: [Item] }

    private let manager: WindowManager
    private let panel: NSPanel
    private let view = SwitcherView()
    private var groups: [Group] = []
    private var flat: [Item] = []
    private var selected = 0
    private var monitors: [Any] = []
    var isVisible: Bool { panel.isVisible }

    init(manager: WindowManager) {
        self.manager = manager
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        panel.contentView = view
        view.onPick = { [weak self] index in self?.selected = index; self?.commit() }
    }

    /// Called from the hotkey: opens the switcher on the first press, cycles on later presses while ⌥ is held.
    func step(reverse: Bool) {
        if !panel.isVisible { open() }
        guard !flat.isEmpty else { return }
        selected = (selected + (reverse ? -1 : 1) + flat.count) % flat.count
        view.selected = selected
    }

    private func open() {
        groups = manager.windowsByDesktop().map { desktop, windows in
            Group(desktop: desktop, items: windows.compactMap { w in
                guard let id = w.windowID else { return nil }
                let app = NSRunningApplication(processIdentifier: w.pid)
                return Item(window: w, id: id, desktop: desktop, title: w.title, app: app?.localizedName ?? "", icon: app?.icon)
            })
        }.filter { !$0.items.isEmpty }
        flat = groups.flatMap(\.items)
        // Like ⌘Tab: start on the most recent *other* window.
        selected = flat.count > 1 ? 1 : 0
        view.configure(groups: groups, current: manager.currentDesktop, flat: flat, thumbnails: manager.config.switcherThumbnails)
        view.selected = selected
        let size = view.fittingSize
        let screen = NSScreen.main?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            if !e.modifierFlags.contains(.option) { self?.commit() }
        } as Any)
        if let lm = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in
            if !e.modifierFlags.contains(.option) { self?.commit() }
            return e
        }) { monitors.append(lm) }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.cancel() }
        } as Any)
        if let lm = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if e.keyCode == 53 { self?.cancel(); return nil }
            return e
        }) { monitors.append(lm) }
        if manager.config.switcherThumbnails { view.loadThumbnails(for: flat) }
    }

    private func close() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        panel.orderOut(nil)
    }

    func cancel() { close() }

    /// Dev aid: opens the switcher and renders it to PNG.
    func snapshot(to path: String) {
        if !panel.isVisible { open() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("switcher snapshot written")
            close()
        }
    }

    private func commit() {
        guard panel.isVisible else { return }
        let item = flat.indices.contains(selected) ? flat[selected] : nil
        close()
        guard let item else { return }
        Log.write("switcher", "pick \(manager.describe(item.window)) on desktop \(item.desktop + 1)")
        manager.activate(item.window, onDesktop: item.desktop)
    }
}

/// ⌘Tab-style strip: one row of tiles, desktops separated by thin dividers with a small title above each group,
/// the selected window's title under the row.
final class SwitcherView: NSView {
    var onPick: ((Int) -> Void)?
    var selected = 0 {
        didSet { for (i, c) in cells.enumerated() { c.isSelected = i == selected } }
    }
    private let background = NSVisualEffectView()
    private let row = NSStackView()
    private var cells: [SwitcherCell] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 22
        layer?.masksToBounds = true
        background.material = .hudWindow
        background.state = .active
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        row.orientation = .horizontal
        row.alignment = .bottom
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor), background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor), background.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(groups: [WindowSwitcher.Group], current: Int?, flat: [WindowSwitcher.Item], thumbnails: Bool) {
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cells = []
        var index = 0
        for (g, group) in groups.enumerated() {
            if g > 0 {
                let divider = NSBox()
                divider.boxType = .custom
                divider.borderWidth = 0
                divider.fillColor = NSColor.white.withAlphaComponent(0.14)
                divider.translatesAutoresizingMaskIntoConstraints = false
                divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
                divider.heightAnchor.constraint(equalToConstant: SwitcherCell.tileSize(thumbnails: thumbnails).height).isActive = true
                row.addArrangedSubview(divider)
                row.setCustomSpacing(14, after: divider)
                row.setCustomSpacing(14, after: row.arrangedSubviews[row.arrangedSubviews.count - 2])
            }
            let title = NSTextField(labelWithString: "Desktop \(group.desktop + 1)")
            title.font = .systemFont(ofSize: 11, weight: .semibold)
            title.textColor = group.desktop == current ? .controlAccentColor : .secondaryLabelColor
            let tiles = NSStackView()
            tiles.spacing = 6
            for item in group.items {
                let cell = SwitcherCell(item: item, index: index, compact: !thumbnails)
                cell.onClick = { [weak self] i in self?.onPick?(i) }
                tiles.addArrangedSubview(cell)
                cells.append(cell)
                index += 1
            }
            let column = NSStackView(views: [title, tiles])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 4
            row.addArrangedSubview(column)
        }
    }

    /// Thumbnails need Screen Recording permission; without it the app icon stands in.
    func loadThumbnails(for items: [WindowSwitcher.Item]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for (i, item) in items.enumerated() {
                guard let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, item.id, [.boundsIgnoreFraming, .nominalResolution]),
                      cg.width > 1 else { continue }
                let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                DispatchQueue.main.async { self?.cells[safe: i]?.setThumbnail(img) }
            }
        }
    }
}

/// One tile: a large app icon (⌘Tab style), or a window preview with the icon badged when previews are on.
final class SwitcherCell: NSView {
    static func tileSize(thumbnails: Bool) -> NSSize { thumbnails ? NSSize(width: 150, height: 96) : NSSize(width: 84, height: 84) }
    static let nameHeight: CGFloat = 20
    private let name = NSTextField(labelWithString: "")
    private let tile = NSView()
    private let icon = NSImageView()
    private let thumbnail = NSImageView()
    private let badge = NSImageView()
    private let index: Int
    private let compact: Bool
    var onClick: ((Int) -> Void)?
    var isSelected = false { didSet { updateSelection() } }

    init(item: WindowSwitcher.Item, index: Int, compact: Bool = false) {
        self.index = index
        self.compact = compact
        super.init(frame: .zero)
        let size = SwitcherCell.tileSize(thumbnails: !compact)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size.width).isActive = true
        heightAnchor.constraint(equalToConstant: size.height + SwitcherCell.nameHeight).isActive = true

        tile.wantsLayer = true
        tile.layer?.cornerRadius = 12
        tile.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tile)
        icon.image = item.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(icon)
        // App name only, shown under the selected tile like ⌘Tab.
        name.stringValue = item.app
        name.font = .systemFont(ofSize: 11, weight: .medium)
        name.textColor = .labelColor
        name.alignment = .center
        name.lineBreakMode = .byTruncatingTail
        name.isHidden = true
        name.translatesAutoresizingMaskIntoConstraints = false
        addSubview(name)
        let iconSize: CGFloat = compact ? 64 : 48
        NSLayoutConstraint.activate([
            tile.topAnchor.constraint(equalTo: topAnchor), tile.leadingAnchor.constraint(equalTo: leadingAnchor),
            tile.trailingAnchor.constraint(equalTo: trailingAnchor), tile.heightAnchor.constraint(equalToConstant: size.height),
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor), icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: iconSize), icon.heightAnchor.constraint(equalToConstant: iconSize),
            name.topAnchor.constraint(equalTo: tile.bottomAnchor, constant: 3),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -16), name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 16),
        ])

        if !compact {
            thumbnail.imageScaling = .scaleProportionallyUpOrDown
            thumbnail.wantsLayer = true
            thumbnail.layer?.cornerRadius = 8
            thumbnail.layer?.masksToBounds = true
            thumbnail.isHidden = true
            thumbnail.translatesAutoresizingMaskIntoConstraints = false
            badge.image = item.icon
            badge.imageScaling = .scaleProportionallyUpOrDown
            badge.isHidden = true
            badge.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(thumbnail)
            tile.addSubview(badge)
            NSLayoutConstraint.activate([
                thumbnail.topAnchor.constraint(equalTo: tile.topAnchor, constant: 8), thumbnail.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -8),
                thumbnail.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 8), thumbnail.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -8),
                badge.widthAnchor.constraint(equalToConstant: 26), badge.heightAnchor.constraint(equalToConstant: 26),
                badge.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -4), badge.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -4),
            ])
        }
        updateSelection()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setThumbnail(_ image: NSImage) {
        guard !compact else { return }
        thumbnail.image = image
        thumbnail.isHidden = false
        badge.isHidden = false
        icon.isHidden = true
    }

    private func updateSelection() {
        // Brighter than ⌘Tab's default so it reads on busy wallpapers, with a hairline edge.
        tile.layer?.backgroundColor = isSelected ? NSColor.white.withAlphaComponent(0.38).cgColor : nil
        tile.layer?.borderWidth = isSelected ? 1 : 0
        tile.layer?.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
        name.isHidden = !isSelected
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?(index) }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
