import BetterWMCore
import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    var manager: WindowManager!
    var drag: DragController!
    var statusItem: NSStatusItem!
    var pauseItem: NSMenuItem?
    var autoTileItem: NSMenuItem?
    var popup: ActionPopup!
    var hotKeys: [HotKey] = []
    let hud = ActionHUD()
    var bar: StatusBar!
    var demo: DemoRunner?
    var switcher: WindowSwitcher!
    let systemReveal = SystemReveal()
    var overlayItem: NSMenuItem?
    var switcherItem: NSMenuItem?
    let configWindow = ConfigWindow()

    func applicationDidFinishLaunching(_ n: Notification) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            print("Grant Accessibility access in System Settings > Privacy & Security > Accessibility, then relaunch.")
            waitForTrust()
            return
        }
        boot()
    }

    private func waitForTrust() {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            if AXIsProcessTrusted() { t.invalidate(); self?.boot() }
        }
    }

    private func boot() {
        let config = Config.load()
        manager = WindowManager(config: config)
        popup = ActionPopup(manager: manager)
        switcher = WindowSwitcher(manager: manager)
        bar = StatusBar(config: config)
        manager.system.topInset = { [weak self] screen in self?.bar.inset(for: screen) ?? 0 }
        bar.onLayoutChange = { [weak self] in self?.manager.apply() }
        bar.onSelectDesktop = { [weak self] in self?.manager.switchDesktop($0) }
        bar.desktopCount = { [weak self] in self?.manager.desktopCount ?? 0 }
        bar.currentDesktop = { [weak self] in self?.manager.currentDesktop }
        manager.onDesktopChange = { [weak self] in self?.bar.focusChanged() }
        manager.onFocusChange = { [weak self] in self?.bar.focusChanged() }
        systemReveal.onChange = { [weak self] active in
            self?.manager.focusRing.hiddenForSystemReveal = active
            self?.bar.hiddenForSystemReveal = active
        }
        manager.apply()
        hud.enabled = config.actionOverlay
        popup.onAction = { [weak self] keys, name in self?.hud.show(keys: keys, action: name, preformatted: true) }
        registerHotKeys(config)
        drag = DragController(manager: manager)
        if !drag.start() {
            print("Failed to create event tap (needs Accessibility permission).")
            NSApp.terminate(nil)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = StatusIcon.make(paused: false)
        statusItem.menu = buildMenu()
        Log.enabled = config.debugLog
        Log.write("app", "launched \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"), workspaces=\(config.workspaces.rawValue)")
        print("BetterWM running. Hold ⌥ and drag a window.")
        if CommandLine.arguments.contains("--settings") {
            showSettings()
            print("settings window:", configWindow.windowNumber ?? -1)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot-popup"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            popup.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [popup] in
                popup?.snapshot(to: path)
                print("popup snapshot written")
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--demo"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            demo = DemoRunner(manager: manager, popup: popup, hud: hud) { [weak self] in self?.perform(action: $0) ?? false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [demo] in demo?.run(scriptAt: path) }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot-bar"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            var c = manager.config
            c.bar = true
            c.barWeatherLocation = "52.52,13.40"
            if let sheets = ProcessInfo.processInfo.environment["BWM_CAT_SHEETS"] { c.barCatSheets = sheets.split(separator: ";").map(String.init) }
            UserDefaults.standard.set(true, forKey: "barMenuBarHintShown")
            bar.apply(c)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [bar] in
                bar?.snapshot(to: path)
                print("bar snapshot written")
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot-handle"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            let h = HandleWindow()
            h.setFrame(NSRect(x: 0, y: 0, width: 16, height: 300), display: true)
            h.isVertical = true
            h.snapshot(hover: true, dragging: false, to: path)
            h.snapshot(hover: true, dragging: true, to: path.replacingOccurrences(of: ".png", with: "-drag.png"))
            print("handle snapshots written")
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot-switcher"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [switcher] in switcher?.snapshot(to: path) }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot-hud"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            hud.enabled = true
            hud.show(keys: "alt+cmd+space", action: "Window actions popup")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [hud] in
                hud.snapshot(to: path)
                print("hud snapshot written")
            }
        }
        if CommandLine.arguments.contains("--test-hotkeys") {
            registerHotKeys(manager.config)
            registerHotKeys(manager.config)
            print("hotkeys registered twice ok:", hotKeys.count)
        }
        if CommandLine.arguments.contains("--test-record") {
            showSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [configWindow] in
                configWindow.beginRecordingFirst()
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: down)
                    e?.flags = .maskControl
                    e?.post(tap: .cghidEventTap)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    print("recorded:", configWindow.firstRecordedSpec ?? "nil")
                }
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot-settings"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            showSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [configWindow] in
                configWindow.snapshot(to: path)
                print("snapshot written")
            }
        }
    }
}

setbuf(stdout, nil)
extension AppDelegate {
    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ sel: Selector, _ key: String = "") {
            let item = menu.addItem(withTitle: title, action: sel, keyEquivalent: key)
            item.target = self
        }
        add("Window Actions…", #selector(showPopup), "w")
        menu.addItem(.separator())
        add("Focus Next Window", #selector(focusNext), "]")
        add("Focus Previous Window", #selector(focusPrevious), "[")
        menu.addItem(.separator())
        add("Tile / Untile Focused Window", #selector(toggleFocused), "t")
        let moveMenu = NSMenu(title: "Move")
        moveMenu.delegate = self
        moveMenu.autoenablesItems = false
        for (title, dir) in [("Move Left", Move.left), ("Move Right", .right),
                             ("Move Up", .up), ("Move Down", .down),
                             ("Merge Into Left Column", .mergeLeft), ("Merge Into Right Column", .mergeRight)] {
            let item = moveMenu.addItem(withTitle: title, action: #selector(moveFocused(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dir
        }
        let move = menu.addItem(withTitle: "Move Focused Window", action: nil, keyEquivalent: "")
        move.submenu = moveMenu
        let sendMenu = NSMenu(title: "SendTo")
        sendMenu.autoenablesItems = false
        sendMenu.delegate = self
        menu.addItem(withTitle: "Send Focused Window to", action: nil, keyEquivalent: "").submenu = sendMenu
        add("Toggle Stacked Layout on This Screen", #selector(toggleStack), "s")
        add("Retile Current Screen", #selector(retile), "r")
        add("Equalize Sizes", #selector(equalize), "e")
        menu.addItem(.separator())
        let desktops = NSMenuItem(title: "Switch to Desktop", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Desktops")
        sub.delegate = self
        desktops.submenu = sub
        menu.addItem(desktops)
        menu.addItem(.separator())
        let pause = menu.addItem(withTitle: "Pause Tiling", action: #selector(togglePause), keyEquivalent: "p")
        pause.target = self
        pauseItem = pause
        let switcherItem = menu.addItem(withTitle: "⌥Tab Window Switcher", action: #selector(toggleSwitcher), keyEquivalent: "")
        switcherItem.target = self
        self.switcherItem = switcherItem
        let overlay = menu.addItem(withTitle: "Show Action Overlay", action: #selector(toggleOverlay), keyEquivalent: "")
        overlay.target = self
        overlayItem = overlay
        let auto = menu.addItem(withTitle: "Auto-tile New Windows", action: #selector(toggleAutoTile), keyEquivalent: "")
        auto.target = self
        autoTileItem = auto
        let strategyMenu = NSMenu(title: "Strategy")
        strategyMenu.delegate = self
        for st in Config.AutoTileStrategy.allCases {
            let item = strategyMenu.addItem(withTitle: st.title, action: #selector(setStrategy(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = st.rawValue
        }
        menu.addItem(withTitle: "Auto-tile Strategy", action: nil, keyEquivalent: "").submenu = strategyMenu
        syncAutoTileItems()
        menu.addItem(.separator())
        add("Settings…", #selector(showSettings), ",")
        add("Open Config File", #selector(openConfig))
        add("Reload Config", #selector(reloadConfig))
        add("Open Log File", #selector(openLog))
        add("Copy Diagnostics Report", #selector(copyDiagnostics))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc func switchDesktop(_ sender: NSMenuItem) { manager.switchDesktop(sender.tag) }
    @objc func sendToDesktop(_ sender: NSMenuItem) { manager.sendFocusedWindow(toDesktop: sender.tag) }
    @objc func toggleFocused() { manager.toggleFocused() }
    @objc func showPopup() { popup.toggle() }

    func perform(action name: String) -> Bool {
        guard let a = actionTable()[name] else { return false }
        Log.write("action", name)
        if let title = Config.actions.first(where: { $0.key == name })?.title {
            hud.show(keys: manager.config.hotkeys[name], action: title)
        }
        a()
        return true
    }

    func actionTable() -> [String: () -> Void] {
        var actions: [String: () -> Void] = [
            "popup": { [weak self] in self?.popup.toggle() },
            "switcher": { [weak self] in self?.switcher.step(reverse: false) },
            "switcherBack": { [weak self] in self?.switcher.step(reverse: true) },
            "focusNext": { [weak self] in self?.manager.focusNext() },
            "focusPrevious": { [weak self] in self?.manager.focusNext(reverse: true) },
            "moveLeft": { [weak self] in self?.manager.moveFocused(.left) },
            "moveRight": { [weak self] in self?.manager.moveFocused(.right) },
            "moveUp": { [weak self] in self?.manager.moveFocused(.up) },
            "moveDown": { [weak self] in self?.manager.moveFocused(.down) },
            "mergeLeft": { [weak self] in self?.manager.moveFocused(.mergeLeft) },
            "mergeRight": { [weak self] in self?.manager.moveFocused(.mergeRight) },
            "toggleTile": { [weak self] in self?.manager.toggleFocused() },
            "retile": { [weak self] in self?.manager.retileCurrentScreen() },
            "toggleStack": { [weak self] in self?.manager.toggleStackedLayout() },
            "equalize": { [weak self] in self?.manager.equalize() },
            "pause": { [weak self] in self?.togglePause() },
            "desktopNext": { [weak self] in self?.manager.switchDesktop(next: true) },
            "sendToNextDesktop": { [weak self] in self?.manager.sendFocusedWindow(toNext: true) },
            "sendToPreviousDesktop": { [weak self] in self?.manager.sendFocusedWindow(toNext: false) },
            "desktopPrevious": { [weak self] in self?.manager.switchDesktop(next: false) },
        ]
        for i in 1...9 {
            actions["desktop\(i)"] = { [weak self] in self?.manager.switchDesktop(i - 1) }
            actions["sendToDesktop\(i)"] = { [weak self] in self?.manager.sendFocusedWindow(toDesktop: i - 1) }
        }
        return actions
    }

    func registerHotKeys(_ config: Config) {
        hotKeys.removeAll()
        var actions = actionTable()
        // While a demo runs, the popup hotkey doubles as its stop button.
        if let popupAction = actions["popup"] {
            actions["popup"] = { [weak self] in
                if let demo = self?.demo, demo.running { demo.stop() } else { popupAction() }
            }
        }
        for (index, (name, spec)) in config.hotkeys.sorted(by: { $0.key < $1.key }).enumerated() {
            guard let action = actions[name] else { print("Unknown hotkey action '\(name)'"); continue }
            if name.hasPrefix("switcher"), !config.switcher { continue }
            let title = Config.actions.first { $0.key == name }?.title ?? name
            let wrapped = { [weak self] in
                Log.write("hotkey", "\(spec) -> \(name)")
                if !name.hasPrefix("switcher") { self?.hud.show(keys: spec, action: title) }
                action()
            }
            if let hk = HotKey(spec, id: UInt32(index + 1), action: wrapped) { hotKeys.append(hk) }
        }
    }

    @objc func focusNext() { manager.focusNext() }
    @objc func sendNext() { manager.sendFocusedWindow(toNext: true) }
    @objc func sendPrevious() { manager.sendFocusedWindow(toNext: false) }
    @objc func focusPrevious() { manager.focusNext(reverse: true) }
    @objc func moveFocused(_ sender: NSMenuItem) {
        if let dir = sender.representedObject as? Move { manager.moveFocused(dir) }
    }
    @objc func retile() { manager.retileCurrentScreen() }
    @objc func toggleStack() { manager.toggleStackedLayout() }
    @objc func equalize() { manager.equalize() }
    @objc func reloadConfig() {
        manager.reloadConfig()
        bar.apply(manager.config)
        registerHotKeys(manager.config)
        syncAutoTileItems()
    }
    @objc func toggleAutoTile() {
        manager.config.autoTile.toggle()
        syncAutoTileItems()
    }
    @objc func setStrategy(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let st = Config.AutoTileStrategy(rawValue: raw) {
            manager.config.autoTileStrategy = st
        }
    }
    func syncAutoTileItems() {
        autoTileItem?.state = manager.config.autoTile ? .on : .off
        overlayItem?.state = manager.config.actionOverlay ? .on : .off
        switcherItem?.state = manager.config.switcher ? .on : .off
        hud.enabled = manager.config.actionOverlay
    }
    @objc func toggleSwitcher() {
        manager.config.switcher.toggle()
        registerHotKeys(manager.config)
        syncAutoTileItems()
    }
    @objc func toggleOverlay() {
        manager.config.actionOverlay.toggle()
        syncAutoTileItems()
    }
    @objc func openConfig() { NSWorkspace.shared.open(Config.path) }
    @objc func openLog() { NSWorkspace.shared.open(Log.path) }
    @objc func copyDiagnostics() {
        let state = try? String(contentsOf: Config.statePath, encoding: .utf8)
        let report = Log.diagnostics(config: manager.config, stateJSON: state)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        hud.enabled = true
        hud.show(keys: nil, action: "Diagnostics copied to clipboard", preformatted: true)
        Log.write("app", "diagnostics report copied (\(report.count) chars)")
    }
    @objc func showSettings() {
        configWindow.show(config: manager.config) { [weak self] cfg in
            guard let self else { return }
            self.manager.config = cfg
            self.bar.apply(cfg)
            self.manager.relayout()
            self.registerHotKeys(cfg)
            self.syncAutoTileItems()
        }
    }
    @objc func togglePause() {
        manager.enabled.toggle()
        pauseItem?.title = manager.enabled ? "Pause Tiling" : "Resume Tiling"
        statusItem.button?.image = StatusIcon.make(paused: !manager.enabled)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "Strategy" {
            for item in menu.items {
                item.state = (item.representedObject as? String) == manager.config.autoTileStrategy.rawValue ? .on : .off
            }
            return
        }
        if menu.title == "Move" {
            for item in menu.items {
                if let dir = item.representedObject as? Move { item.isEnabled = manager.canMoveFocused(dir) }
            }
            return
        }
        guard menu.title == "Desktops" || menu.title == "SendTo" else { return }
        let sending = menu.title == "SendTo"
        menu.removeAllItems()
        let current = manager.currentDesktop
        if sending {
            let next = menu.addItem(withTitle: "Next Desktop", action: #selector(sendNext), keyEquivalent: "")
            next.target = self
            next.isEnabled = current.map { $0 + 1 < manager.desktopCount } ?? false
            let prev = menu.addItem(withTitle: "Previous Desktop", action: #selector(sendPrevious), keyEquivalent: "")
            prev.target = self
            prev.isEnabled = current.map { $0 > 0 } ?? false
            menu.addItem(.separator())
        }
        for i in 0..<manager.desktopCount {
            let item = menu.addItem(withTitle: "Desktop \(i + 1)", action: sending ? #selector(sendToDesktop(_:)) : #selector(switchDesktop(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = i == current ? .on : .off
            if sending { item.isEnabled = i != current }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
