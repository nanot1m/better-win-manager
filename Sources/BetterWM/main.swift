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
        registerHotKeys(config)
        drag = DragController(manager: manager)
        if !drag.start() {
            print("Failed to create event tap (needs Accessibility permission).")
            NSApp.terminate(nil)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = StatusIcon.make(paused: false)
        statusItem.menu = buildMenu()
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
        add("Send Focused Window to Next Desktop", #selector(sendNext))
        add("Send Focused Window to Previous Desktop", #selector(sendPrevious))
        let sendMenu = NSMenu(title: "SendTo")
        sendMenu.autoenablesItems = false
        sendMenu.delegate = self
        menu.addItem(withTitle: "Send Focused Window to Desktop", action: nil, keyEquivalent: "").submenu = sendMenu
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
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc func switchDesktop(_ sender: NSMenuItem) { Spaces.switchToDesktop(sender.tag) }
    @objc func sendToDesktop(_ sender: NSMenuItem) { manager.sendFocusedWindow(toDesktop: sender.tag) }
    @objc func toggleFocused() { manager.toggleFocused() }
    @objc func showPopup() { popup.toggle() }

    func registerHotKeys(_ config: Config) {
        hotKeys.removeAll()
        var actions: [String: () -> Void] = [
            "popup": { [weak self] in self?.popup.toggle() },
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
            "equalize": { [weak self] in self?.manager.equalize() },
            "pause": { [weak self] in self?.togglePause() },
            "desktopNext": { Spaces.swipe(toNext: true) },
            "sendToNextDesktop": { [weak self] in self?.manager.sendFocusedWindow(toNext: true) },
            "sendToPreviousDesktop": { [weak self] in self?.manager.sendFocusedWindow(toNext: false) },
            "desktopPrevious": { Spaces.swipe(toNext: false) },
        ]
        for i in 1...9 {
            actions["desktop\(i)"] = { Spaces.switchToDesktop(i - 1) }
            actions["sendToDesktop\(i)"] = { [weak self] in self?.manager.sendFocusedWindow(toDesktop: i - 1) }
        }
        for (index, (name, spec)) in config.hotkeys.sorted(by: { $0.key < $1.key }).enumerated() {
            guard let action = actions[name] else { print("Unknown hotkey action '\(name)'"); continue }
            if let hk = HotKey(spec, id: UInt32(index + 1), action: action) { hotKeys.append(hk) }
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
    @objc func equalize() { manager.equalize() }
    @objc func reloadConfig() {
        manager.reloadConfig()
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
    }
    @objc func openConfig() { NSWorkspace.shared.open(Config.path) }
    @objc func showSettings() {
        configWindow.show(config: manager.config) { [weak self] cfg in
            guard let self else { return }
            self.manager.config = cfg
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
        let current = Spaces.currentDesktopIndex()
        for i in Spaces.desktops().indices {
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
