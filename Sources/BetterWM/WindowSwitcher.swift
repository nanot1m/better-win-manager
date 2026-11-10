import BetterWMCore
import Cocoa

/// ⌥Tab: all windows grouped by desktop (or virtual workspace). Hold ⌥ and press Tab to cycle, release to switch;
/// Escape cancels; items are clickable.
final class WindowSwitcher {
    struct Item {
        /// Nil for one of BetterWM's own windows, raised through AppKit instead.
        let window: AXWindow?
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
        panel = .overlay(level: .popUpMenu, shadow: true)
        panel.contentView = view
        view.onPick = { [weak self] index in self?.selected = index; self?.commit() }
    }

    /// Called from the hotkey: opens the switcher on the first press, cycles on later presses while ⌥ is held.
    func step(reverse: Bool) {
        if !panel.isVisible {
            open()
            guard !flat.isEmpty else { return }
            selected = firstTarget(reverse: reverse)
            view.selected = selected
            return
        }
        guard !flat.isEmpty else { return }
        selected = (selected + (reverse ? -1 : 1) + flat.count) % flat.count
        view.selected = selected
    }

    /// The first press goes to the neighbour of the focused window on the current desktop, wrapping within it;
    /// only a desktop with no other window hands over to the next (or previous) desktop.
    private func firstTarget(reverse: Bool) -> Int {
        let focusedID = manager.system.focused?.windowID
        // A focused floating window starts the cycle in its own group.
        let focusedGroup = focusedID.flatMap { f in groups.first { $0.items.contains { $0.id == f } } }
        guard let current = focusedGroup ?? groups.first(where: { $0.desktop == manager.currentDesktop }) ?? groups.first else { return 0 }
        let base = flat.firstIndex { $0.desktop == current.desktop } ?? 0
        let n = current.items.count
        if n > 1 {
            let i = current.items.firstIndex { $0.id == focusedID } ?? (reverse ? 0 : n - 1)
            return base + (i + (reverse ? -1 : 1) + n) % n
        }
        guard flat.count > n else { return base }
        return reverse ? (base - 1 + flat.count) % flat.count : (base + n) % flat.count
    }

    /// The group of the floating windows shared across desktops, after the desktops, as the status bar shows them.
    static let floatingGroup = -1

    private func open() {
        func items(_ windows: [AXWindow], desktop: Int) -> [Item] {
            windows.compactMap { w in
                guard let id = w.windowID else { return nil }
                let app = NSRunningApplication(processIdentifier: w.pid)
                // A tab's given name stands in for the window's title, as in the bar and the tabs.
                return Item(window: w, id: id, desktop: desktop, title: manager.tabLabel(for: id) ?? w.title, app: app?.localizedName ?? "", icon: app?.icon)
            }
        }
        let shared = Set(manager.sharedFloatingApps().flatMap(\.windows))
        groups = manager.windowsByDesktop().map { desktop, windows in
            Group(desktop: desktop, items: items(windows.filter { $0.windowID.map { !shared.contains($0) } ?? true }, desktop: desktop))
        }
        // Our own windows (Settings, Welcome) are floating windows of the current desktop, reached through AppKit.
        if let current = manager.currentDesktop {
            let own = manager.ownWindows.map { Item(window: nil, id: CGWindowID($0.windowNumber), desktop: current, title: $0.title, app: "BetterWM", icon: NSApp.applicationIconImage) }
            if let i = groups.firstIndex(where: { $0.desktop == current }) { groups[i] = Group(desktop: current, items: groups[i].items + own) }
            else if !own.isEmpty { groups.append(Group(desktop: current, items: own)) }
        }
        let pinned = items(shared.sorted().compactMap { manager.system.axWindow($0) }, desktop: Self.floatingGroup)
        if !pinned.isEmpty { groups.append(Group(desktop: Self.floatingGroup, items: pinned)) }
        groups = groups.filter { !$0.items.isEmpty }
        flat = groups.flatMap(\.items)
        selected = 0
        let screen = NSScreen.main?.visibleFrame ?? .zero
        view.configure(groups: groups, current: manager.currentDesktop, flat: flat, thumbnails: manager.config.switcherThumbnails, maxWidth: screen.width - 80)
        view.selected = selected
        let size = view.fittingSize
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
        if manager.config.switcherThumbnails {
            view.showCached(for: flat)
            view.loadThumbnails(for: flat)
        }
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
        guard let window = item.window else {
            Log.write("switcher", "pick own window '\(item.title)'")
            manager.ownWindow(item.id)?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        Log.write("switcher", "pick \(manager.describe(window)) on desktop \(item.desktop + 1)")
        manager.activate(window, onDesktop: item.desktop)
    }
}

/// ⌘Tab-style strip: one row of tiles, desktops separated by thin dividers with a small title above each group,
/// the selected window's title under the row.
final class SwitcherView: NSView {
    var onPick: ((Int) -> Void)?
    var selected = 0 {
        didSet {
            for (i, c) in cells.enumerated() { c.isSelected = i == selected }
            placeCaption()
        }
    }
    /// The selected window's title, drawn over the panel so it is not cut to the tile's width.
    private let caption = NSTextField(labelWithString: "")
    private var compact = false
    /// Liquid Glass where the system has it, the HUD material before.
    private let background: NSView = Glass.makeView() ?? {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.state = .active
        return v
    }()
    /// Rows of desktop columns; a row wraps when the next column would not fit the screen.
    private let rows = NSStackView()
    private var cells: [SwitcherCell] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 28
        layer?.masksToBounds = true
        Glass.set(background, cornerRadius: 28)
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 14
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        caption.textColor = .labelColor
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingMiddle
        caption.isHidden = true
        addSubview(caption)
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor), background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor), background.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(groups: [WindowSwitcher.Group], current: Int?, flat: [WindowSwitcher.Item], thumbnails: Bool, maxWidth: CGFloat) {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cells = []
        compact = !thumbnails
        var index = 0
        var row = newRow()
        var rowWidth: CGFloat = 0
        for group in groups {
            let title = NSTextField(labelWithString: group.desktop == WindowSwitcher.floatingGroup ? "Pinned" : "Desktop \(group.desktop + 1)")
            title.font = .systemFont(ofSize: 11, weight: .semibold)
            title.textColor = group.desktop == current ? .controlAccentColor : .secondaryLabelColor
            let tiles = NSStackView()
            tiles.spacing = thumbnails ? 6 : 2
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
            let width = column.fittingSize.width
            // The next column does not fit beside the others: a new row. A single column wider than the screen
            // still gets a row of its own.
            if !row.arrangedSubviews.isEmpty, rowWidth + 14 + 1 + 14 + width > maxWidth - 44 {
                rows.addArrangedSubview(row)
                row = newRow()
                rowWidth = 0
            }
            if !row.arrangedSubviews.isEmpty {
                let divider = NSBox()
                divider.boxType = .custom
                divider.borderWidth = 0
                divider.fillColor = NSColor.white.withAlphaComponent(0.14)
                divider.translatesAutoresizingMaskIntoConstraints = false
                divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
                // As tall as the tiles, centred on them: the row aligns on its centre, and a column is a title above
                // the tiles with the caption's room below, so the divider is lifted by half their difference.
                divider.heightAnchor.constraint(equalToConstant: SwitcherCell.tileSize(thumbnails: thumbnails).height).isActive = true
                row.addArrangedSubview(divider)
                row.setCustomSpacing(14, after: divider)
                row.setCustomSpacing(14, after: row.arrangedSubviews[row.arrangedSubviews.count - 2])
                rowWidth += 14 + 1 + 14
            }
            row.addArrangedSubview(column)
            rowWidth += width
        }
        if !row.arrangedSubviews.isEmpty { rows.addArrangedSubview(row) }
        layoutSubtreeIfNeeded()
        placeCaption()
    }

    override func layout() {
        super.layout()
        placeCaption()
    }

    /// Centred under the selected tile, as wide as it needs up to most of the panel, kept inside it.
    private func placeCaption() {
        guard compact, let cell = cells[safe: selected], cell.superview != nil else { caption.isHidden = true; return }
        caption.stringValue = cell.caption
        caption.isHidden = caption.stringValue.isEmpty
        let tile = cell.convert(cell.tileFrame, to: self)
        let maxWidth = min(bounds.width - 44, 420)
        var size = caption.sizeThatFits(NSSize(width: maxWidth, height: 20))
        size.width = min(size.width, maxWidth)
        var x = tile.midX - size.width / 2
        x = max(22, min(x, bounds.width - 22 - size.width))
        caption.frame = NSRect(x: x, y: tile.minY - 4 - size.height, width: size.width, height: size.height)
    }

    private func newRow() -> NSStackView {
        let r = NSStackView()
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = 6
        // A shorter row keeps its own width; stretched to the longest one it would spread its tiles apart.
        r.setHuggingPriority(.required, for: .horizontal)
        return r
    }

    /// Thumbnails need Screen Recording permission; without it the app icon stands in. Fresh captures replace the
    /// cached ones as they arrive.
    func loadThumbnails(for items: [WindowSwitcher.Item]) {
        SwitcherThumbnails.refresh(items.map(\.id)) { [weak self] id, img in
            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            self?.cells[safe: i]?.setThumbnail(img)
        }
    }

    /// What the cache has, right away, so the panel opens with previews.
    func showCached(for items: [WindowSwitcher.Item]) {
        for (i, item) in items.enumerated() { if let img = SwitcherThumbnails.cached(item.id) { cells[safe: i]?.setThumbnail(img) } }
    }
}

/// Window previews for the switcher, kept between openings and scaled down to the tile, so the panel opens with
/// pictures and the fresh captures only replace them. Warmed shortly after launch and after a desktop switch.
enum SwitcherThumbnails {
    private static var cache: [CGWindowID: NSImage] = [:]
    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "betterwm.thumbnails", qos: .utility)
    /// Twice the tile for Retina; a window's own buffer would be megabytes.
    private static let target = CGSize(width: 300, height: 192)

    static func cached(_ id: CGWindowID) -> NSImage? { lock.lock(); defer { lock.unlock() }; return cache[id] }

    /// Captures `ids` in the background, keeps the results and reports each on the main thread.
    static func refresh(_ ids: [CGWindowID], _ each: ((CGWindowID, NSImage) -> Void)? = nil) {
        guard CGPreflightScreenCaptureAccess() else { return }
        queue.async {
            for id in ids {
                guard let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .nominalResolution]), cg.width > 1 else { continue }
                let img = scaled(cg)
                lock.lock(); cache[id] = img; lock.unlock()
                if let each { DispatchQueue.main.async { each(id, img) } }
            }
            lock.lock(); cache = cache.filter { ids.contains($0.key) || CGWindowInfo.isOnScreen($0.key) }; lock.unlock()
        }
    }

    private static func scaled(_ cg: CGImage) -> NSImage {
        let scale = min(target.width / CGFloat(cg.width), target.height / CGFloat(cg.height), 1)
        let size = NSSize(width: CGFloat(cg.width) * scale, height: CGFloat(cg.height) * scale)
        let img = NSImage(size: size)
        img.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)).draw(in: NSRect(origin: .zero, size: size))
        img.unlockFocus()
        return img
    }
}

/// One tile: an app icon with the window's title under it, or a window preview with the icon badged when
/// previews are on (then the app name shows under the selected tile, like ⌘Tab).
final class SwitcherCell: NSView {
    static func tileSize(thumbnails: Bool) -> NSSize { thumbnails ? NSSize(width: 150, height: 96) : NSSize(width: 76, height: 76) }
    static let nameHeight: CGFloat = 20
    private let name = NSTextField(labelWithString: "")
    private let tile = NSView()
    /// What the panel captions the selected tile with: the window's title, the app's name when it has none.
    let caption: String
    var tileFrame: NSRect { tile.frame }
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
        self.caption = item.title.isEmpty ? item.app : item.title
        super.init(frame: .zero)
        let size = SwitcherCell.tileSize(thumbnails: !compact)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size.width).isActive = true
        heightAnchor.constraint(equalToConstant: size.height + SwitcherCell.nameHeight).isActive = true

        tile.wantsLayer = true
        tile.layer?.cornerRadius = compact ? 18 : 12
        tile.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tile)
        icon.image = item.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(icon)
        // Icons: the window's title (the app's name when it has none), always. Previews: the app name, on selection.
        name.stringValue = compact ? (item.title.isEmpty ? item.app : item.title) : item.app
        name.font = .systemFont(ofSize: 11, weight: .medium)
        name.textColor = .labelColor
        name.alignment = .center
        name.lineBreakMode = .byTruncatingTail
        name.isHidden = true
        name.translatesAutoresizingMaskIntoConstraints = false
        addSubview(name)
        let iconSize: CGFloat = compact ? 60 : 48
        NSLayoutConstraint.activate([
            tile.topAnchor.constraint(equalTo: topAnchor), tile.leadingAnchor.constraint(equalTo: leadingAnchor),
            tile.trailingAnchor.constraint(equalTo: trailingAnchor), tile.heightAnchor.constraint(equalToConstant: size.height),
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor), icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: iconSize), icon.heightAnchor.constraint(equalToConstant: iconSize),
            name.topAnchor.constraint(equalTo: tile.bottomAnchor, constant: 3),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: compact ? -30 : -16), name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: compact ? 30 : 16),
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
        // Previews caption the selected tile with the app's name here; the icon view's caption is the panel's, so
        // a long title is not cut to the tile.
        name.isHidden = compact || !isSelected
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?(index) }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
