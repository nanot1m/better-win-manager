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
    var overview: Overview!
    var slide: DesktopSlide!
    var swipe: SwipeGesture?
    let systemReveal = SystemReveal()
    var overlayItem: NSMenuItem?
    var switcherItem: NSMenuItem?
    let configWindow = ConfigWindow()
    let onboarding = OnboardingWindow()
    var updater: Updater!

    func applicationWillTerminate(_ n: Notification) { manager.prepareForQuit() }

    /// `pkill`/`kill` send SIGTERM, which never reaches `applicationWillTerminate`; route it through a normal quit
    /// so hidden apps are unhidden and parked windows restored.
    private var sigterm: DispatchSourceSignal?
    private func handleSigterm() {
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        sigterm = src
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        guard AXIsProcessTrusted() else {
            print("Grant Accessibility access in System Settings > Privacy & Security > Accessibility.")
            onboarding.show()
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
        handleSigterm()
        let config = Config.load()
        manager = WindowManager(config: config)
        updater = Updater(config: config)
        popup = ActionPopup(manager: manager)
        switcher = WindowSwitcher(manager: manager)
        overview = Overview(manager: manager)
        slide = DesktopSlide(manager: manager)
        bar = StatusBar(config: config)
        manager.system.topInset = { [weak self] screen in self?.bar.inset(for: screen) ?? 0 }
        bar.onLayoutChange = { [weak self] in self?.manager.apply() }
        bar.onSelectDesktop = { [weak self] in self?.manager.switchDesktop($0) }
        bar.onSelectFullscreen = { [weak self] in self?.manager.activateSpace($0) }
        bar.fullscreenSpaces = { [weak self] in self?.manager.fullscreenSpaces() ?? [] }
        bar.onReorderDesktop = { [weak self] from, to in self?.manager.moveDesktop(from: from, to: to) }
        bar.onDesktopMenu = { [weak self] desktop, view in self?.showDesktopMenu(desktop, from: view) }
        bar.onMenuRequested = { [weak self] view in
            guard let self else { return }
            let menu = self.buildMenu()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.minY - 4), in: view)
        }
        bar.desktopsOn = { [weak self] in self?.manager.desktopList(on: $0) ?? [] }
        bar.shownOn = { [weak self] in self?.manager.shownDesktop(on: $0) }
        bar.activeDesktop = { [weak self] in self?.manager.currentDesktop }
        bar.desktopApps = { [weak self] in self?.manager.appsByDesktop() ?? [:] }
        bar.focusedWindow = { [weak self] in self?.manager.focusRing.currentWindowID }
        bar.focusedAXWindow = { [weak self] in self?.manager.system.focused }
        bar.isInteracting = { [weak self] in self?.manager.interacting ?? false }
        manager.onInteractionEnd = { [weak self] in self?.bar.interactionEnded() }
        manager.onWindowsChange = { [weak self] in self?.bar.focusChanged() }
        manager.focusRing.onFocusChange = { [weak self] in self?.bar.focusChanged() }
        manager.onDesktopChange = { [weak self] in
            self?.bar.focusChanged()
            self?.overview.desktopChanged()
        }
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
        drag.onOverviewKey = { [weak self] in self?.overview.toggle() }
        drag.chipDesktop = { [weak self] p in self?.bar.desktop(at: p) }
        drag.highlightChip = { [weak self] d in self?.bar.highlightDrop(d) }
        drag.swallowScrolling = { [weak self] in (self?.overview.isOpen ?? false) || (self?.slide.isActive ?? false) || (self?.swipe?.fingersDown ?? false) }
        overview.onOpenChange = { [weak self] in self?.drag.refreshState() }
        slide.onActiveChange = { [weak self] in self?.drag.refreshState() }
        KeyRecorderView.onActiveChange = { [weak self] in self?.drag.refreshState() }
        applyGestureSetting(config)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = StatusIcon.make(paused: false)
        statusItem.menu = buildMenu()
        Log.enabled = config.debugLog
        Log.write("app", "launched \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
        print("BetterWM running. Hold ⌥ and drag a window.")
        runDevHooks()
    }
}

setbuf(stdout, nil)
extension AppDelegate {
    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        // Key equivalents only display the user's global hotkey for the action; the Carbon registration
        // does the actual work, so a menu item without a configured hotkey shows none.
        func add(_ title: String, _ sel: Selector, action: String? = nil) {
            let item = menu.addItem(withTitle: title, action: sel, keyEquivalent: "")
            item.target = self
            if let action, let spec = manager.config.hotkeys[action] { HotKey.applyKeyEquivalent(spec, to: item) }
        }
        func section(_ title: String) {
            if menu.items.count > 0 { menu.addItem(.separator()) }
            if #available(macOS 14, *) {
                menu.addItem(.sectionHeader(title: title))
            } else {
                let h = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
                h.isEnabled = false
            }
        }

        section("Window")
        add("Window Actions…", #selector(showPopup), action: "popup")
        add("Tile / Untile Focused Window", #selector(toggleFocused), action: "toggleTile")
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
        menu.addItem(withTitle: "Move Focused Window", action: nil, keyEquivalent: "").submenu = moveMenu
        let focusMenu = NSMenu(title: "Focus")
        focusMenu.delegate = self
        focusMenu.autoenablesItems = false
        for (title, dir, action) in [("Focus Left", Direction.left, "focusLeft"),
                                     ("Focus Right", .right, "focusRight"),
                                     ("Focus Up", .up, "focusUp"),
                                     ("Focus Down", .down, "focusDown")] {
            let item = focusMenu.addItem(withTitle: title, action: #selector(focusDirection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dir
            if let spec = manager.config.hotkeys[action] { HotKey.applyKeyEquivalent(spec, to: item) }
        }
        menu.addItem(withTitle: "Focus Direction", action: nil, keyEquivalent: "").submenu = focusMenu
        let sendMenu = NSMenu(title: "SendTo")
        sendMenu.autoenablesItems = false
        sendMenu.delegate = self
        menu.addItem(withTitle: "Send Focused Window to Desktop", action: nil, keyEquivalent: "").submenu = sendMenu
        add("Focus Next Window", #selector(focusNext), action: "focusNext")
        add("Focus Previous Window", #selector(focusPrevious), action: "focusPrevious")

        section("Screen")
        add("Retile Current Screen", #selector(retile), action: "retile")
        add("Grow Window", #selector(growWindow), action: "grow")
        add("Shrink Window", #selector(shrinkWindow), action: "shrink")
        add("Equalize Sizes", #selector(equalize), action: "equalize")
        add("Toggle Stacked Layout", #selector(toggleStack), action: "toggleStack")

        section("Desktops")
        let desktops = NSMenuItem(title: "Switch to Desktop", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Desktops")
        sub.delegate = self
        desktops.submenu = sub
        menu.addItem(desktops)
        add("Move This Desktop Left", #selector(moveDesktopLeft), action: "desktopMoveLeft")
        add("Move This Desktop Right", #selector(moveDesktopRight), action: "desktopMoveRight")
        if NSScreen.screens.count > 1 { add("Send This Desktop to Next Screen", #selector(desktopToNextScreen), action: "desktopToNextScreen") }

        section("Tiling")
        let pause = menu.addItem(withTitle: manager.enabled ? "Pause Tiling" : "Resume Tiling", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        if let spec = manager.config.hotkeys["pause"] { HotKey.applyKeyEquivalent(spec, to: pause) }
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
        let switcherItem = menu.addItem(withTitle: "⌥Tab Window Switcher", action: #selector(toggleSwitcher), keyEquivalent: "")
        switcherItem.target = self
        self.switcherItem = switcherItem
        let overlay = menu.addItem(withTitle: "Show Action Overlay", action: #selector(toggleOverlay), keyEquivalent: "")
        overlay.target = self
        overlayItem = overlay
        syncAutoTileItems()

        section("BetterWM")
        add("Settings…", #selector(showSettings))
        add("Check for Updates…", #selector(checkForUpdates))
        add("Permissions…", #selector(showPermissions))
        add("Open Config File", #selector(openConfig))
        add("Reload Config", #selector(reloadConfig))
        let diag = NSMenu(title: "Diagnostics")
        for (title, sel, action) in [("Re-measure Window Corners", #selector(refreshRing), "refreshRing"), ("Open Log File", #selector(openLog), ""),
                                     ("Copy Diagnostics Report", #selector(copyDiagnostics), ""), ("Report a Bug…", #selector(reportBug), ""),
                                     ("Reset Layout State…", #selector(resetState), "")] {
            let item = diag.addItem(withTitle: title, action: sel, keyEquivalent: "")
            item.target = self
            if let spec = manager.config.hotkeys[action] { HotKey.applyKeyEquivalent(spec, to: item) }
        }
        menu.addItem(withTitle: "Diagnostics", action: nil, keyEquivalent: "").submenu = diag
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit BetterWM", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc func switchDesktop(_ sender: NSMenuItem) { manager.switchDesktop(sender.tag) }
    @objc func desktopNext() { manager.switchDesktop(next: true) }
    @objc func desktopPrevious() { manager.switchDesktop(next: false) }
    @objc func sendToDesktop(_ sender: NSMenuItem) { manager.sendFocusedWindow(toDesktop: sender.tag) }
    @objc func toggleFocused() { resumeForTiling(); manager.toggleFocused() }
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
            "overview": { [weak self] in self?.overview.toggle() },
            "focusNext": { [weak self] in self?.manager.focusNext() },
            "focusPrevious": { [weak self] in self?.manager.focusNext(reverse: true) },
            "focusLeft": { [weak self] in self?.manager.focusWindow(in: .left) },
            "focusRight": { [weak self] in self?.manager.focusWindow(in: .right) },
            "focusUp": { [weak self] in self?.manager.focusWindow(in: .up) },
            "focusDown": { [weak self] in self?.manager.focusWindow(in: .down) },
            "moveLeft": { [weak self] in self?.manager.moveFocused(.left) },
            "moveRight": { [weak self] in self?.manager.moveFocused(.right) },
            "moveUp": { [weak self] in self?.manager.moveFocused(.up) },
            "moveDown": { [weak self] in self?.manager.moveFocused(.down) },
            "mergeLeft": { [weak self] in self?.manager.moveFocused(.mergeLeft) },
            "mergeRight": { [weak self] in self?.manager.moveFocused(.mergeRight) },
            "toggleTile": { [weak self] in self?.resumeForTiling(); self?.manager.toggleFocused() },
            "retile": { [weak self] in self?.resumeForTiling(); self?.manager.retileCurrentScreen() },
            "toggleStack": { [weak self] in self?.manager.toggleStackedLayout() },
            "refreshRing": { [weak self] in self?.manager.focusRing.remeasureCorners() },
            "equalize": { [weak self] in self?.manager.equalize() },
            "grow": { [weak self] in self?.manager.resizeFocused(grow: true) },
            "shrink": { [weak self] in self?.manager.resizeFocused(grow: false) },
            "pause": { [weak self] in self?.togglePause() },
            "desktopNext": { [weak self] in self?.manager.switchDesktopOrSpace(next: true) },
            "desktopMoveLeft": { [weak self] in self?.manager.moveCurrentDesktop(left: true) },
            "desktopMoveRight": { [weak self] in self?.manager.moveCurrentDesktop(left: false) },
            "desktopToNextScreen": { [weak self] in self?.manager.sendDesktopToNextScreen() },
            "sendToNextDesktop": { [weak self] in self?.manager.sendFocusedWindow(toNext: true) },
            "sendToPreviousDesktop": { [weak self] in self?.manager.sendFocusedWindow(toNext: false) },
            "desktopPrevious": { [weak self] in self?.manager.switchDesktopOrSpace(next: false) },
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
            if name == "overview", !config.overview { continue }
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
    @objc func focusDirection(_ sender: NSMenuItem) {
        if let dir = sender.representedObject as? Direction { manager.focusWindow(in: dir) }
    }
    @objc func moveFocused(_ sender: NSMenuItem) {
        if let dir = sender.representedObject as? Move { manager.moveFocused(dir) }
    }
    @objc func retile() { resumeForTiling(); manager.retileCurrentScreen() }
    @objc func moveDesktopLeft() { manager.moveCurrentDesktop(left: true) }
    @objc func moveDesktopRight() { manager.moveCurrentDesktop(left: false) }
    @objc func desktopToNextScreen() { manager.sendDesktopToNextScreen() }
    @objc func growWindow() { manager.resizeFocused(grow: true) }
    @objc func shrinkWindow() { manager.resizeFocused(grow: false) }

    /// Right-click menu of a desktop chip; each item carries the desktop as its represented object.
    func showDesktopMenu(_ desktop: Int, from view: NSView) {
        let menu = NSMenu()
        func add(_ title: String, _ sel: Selector, enabled: Bool = true, action: String? = nil) {
            let item = menu.addItem(withTitle: title, action: sel, keyEquivalent: "")
            item.target = self
            item.representedObject = desktop
            item.isEnabled = enabled
            if let action, let spec = manager.config.hotkeys[action] { HotKey.applyKeyEquivalent(spec, to: item) }
        }
        let n = desktop + 1
        add("Switch to Desktop \(n)", #selector(menuSwitchDesktop(_:)), enabled: desktop != manager.currentDesktop, action: "desktop\(n)")
        add("Send Focused Window Here", #selector(menuSendWindowToDesktop(_:)), action: n <= 9 ? "sendToDesktop\(n)" : nil)
        menu.addItem(.separator())
        add("Move Left", #selector(menuMoveDesktopLeft(_:)), enabled: manager.neighbourDesktop(of: desktop, next: false) != nil)
        add("Move Right", #selector(menuMoveDesktopRight(_:)), enabled: manager.neighbourDesktop(of: desktop, next: true) != nil)
        if NSScreen.screens.count > 1 { add("Send to Next Screen", #selector(menuSendDesktopToNextScreen(_:))) }
        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.minY - 4), in: view)
    }

    private func desktop(of sender: NSMenuItem) -> Int? { sender.representedObject as? Int }
    @objc func menuSwitchDesktop(_ s: NSMenuItem) { if let d = desktop(of: s) { manager.switchDesktop(d) } }
    @objc func menuSendWindowToDesktop(_ s: NSMenuItem) { if let d = desktop(of: s) { manager.sendFocusedWindow(toDesktop: d) } }
    @objc func menuMoveDesktopLeft(_ s: NSMenuItem) {
        if let d = desktop(of: s), let to = manager.neighbourDesktop(of: d, next: false) { manager.moveDesktop(from: d, to: to) }
    }
    @objc func menuMoveDesktopRight(_ s: NSMenuItem) {
        if let d = desktop(of: s), let to = manager.neighbourDesktop(of: d, next: true) { manager.moveDesktop(from: d, to: to) }
    }
    @objc func menuSendDesktopToNextScreen(_ s: NSMenuItem) { if let d = desktop(of: s) { manager.sendDesktopToNextScreen(d) } }
    @objc func toggleStack() { manager.toggleStackedLayout() }
    @objc func equalize() { manager.equalize() }
    @objc func reloadConfig() {
        manager.reloadConfig()
        bar.apply(manager.config)
        updater.config = manager.config
        registerHotKeys(manager.config)
        applyGestureSetting(manager.config)
        statusItem.menu = buildMenu()
        syncAutoTileItems()
    }
    func applyGestureSetting(_ config: Config) {
        let vertical = config.overview && config.overviewGesture
        let horizontal = config.overview && config.desktopSwipe
        guard vertical || horizontal else {
            swipe?.stop()
            swipe = nil
            return
        }
        let g = swipe ?? SwipeGesture()
        g.fingers = config.gestureFingers
        g.onBegan = vertical ? { [weak self] in self?.overview.gestureBegan() } : nil
        g.onChanged = vertical ? { [weak self] in self?.overview.gestureChanged($0) } : nil
        g.onEnded = vertical ? { [weak self] in self?.overview.gestureEnded(velocity: $0) } : nil
        // With the overview open the swipe scrubs the overview itself; otherwise it slides the desktops.
        g.onFingersChange = { [weak self] in self?.drag.refreshState() }
        g.onTouchBegan = horizontal ? { [weak self] in
            guard let self, !self.overview.isOpen else { return }
            self.slide.prewarm()
        } : nil
        g.onHorizontalBegan = horizontal ? { [weak self] in
            guard let self else { return }
            if self.overview.isOpen { self.overview.horizontalBegan() } else { self.slide.began() }
        } : nil
        g.onHorizontalChanged = horizontal ? { [weak self] in
            guard let self else { return }
            if self.slide.isActive { self.slide.changed($0) } else { self.overview.horizontalChanged($0) }
        } : nil
        g.onHorizontalEnded = horizontal ? { [weak self] in
            guard let self else { return }
            if self.slide.isActive { self.slide.ended(velocity: $0) } else { self.overview.horizontalEnded(velocity: $0) }
        } : nil
        if swipe == nil {
            if g.start() { swipe = g } else { Log.write("gesture", "multitouch framework unavailable; gesture off") }
        }
    }

    @objc func toggleAutoTile() {
        manager.config.autoTile.toggle()
        manager.config.save()
        syncAutoTileItems()
    }
    @objc func setStrategy(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let st = Config.AutoTileStrategy(rawValue: raw) {
            manager.config.autoTileStrategy = st
            manager.config.save()
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
        manager.config.save()
        registerHotKeys(manager.config)
        statusItem.menu = buildMenu()
        syncAutoTileItems()
    }
    @objc func toggleOverlay() {
        manager.config.actionOverlay.toggle()
        manager.config.save()
        syncAutoTileItems()
    }
    @objc func openConfig() { NSWorkspace.shared.open(Config.path) }
    @objc func openLog() { NSWorkspace.shared.open(Log.path) }
    @objc func refreshRing() { manager.focusRing.remeasureCorners() }
    @objc func copyDiagnostics() {
        let state = try? String(contentsOf: Config.statePath, encoding: .utf8)
        let report = Log.diagnostics(config: manager.config, stateJSON: state)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        hud.show(keys: nil, action: "Diagnostics copied to clipboard", preformatted: true, force: true)
        Log.write("app", "diagnostics report copied (\(report.count) chars)")
    }
    /// Builds a report folder (diagnostics, optional screenshot), opens a prefilled GitHub issue and shows the
    /// folder so the files can be dragged in. GitHub takes attachments only from a signed-in browser, and the
    /// user should see what is about to become public anyway.
    @objc func reportBug() {
        let alert = NSAlert()
        alert.messageText = "Report a bug"
        alert.informativeText = "BetterWM will collect the diagnostics report into a folder, open a new GitHub issue with the basics filled in, and show the folder so you can drag the files into the issue. Nothing is sent until you submit it.\n\nA screenshot shows whatever is on your screen; leave it out if anything private is visible."
        let shot = NSButton(checkboxWithTitle: "Include a screenshot of the main screen", target: nil, action: nil)
        shot.state = .on
        alert.accessoryView = shot
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let stamp = { () -> String in let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"; return f.string(from: Date()) }()
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/BetterWM/report-\(stamp)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let state = try? String(contentsOf: Config.statePath, encoding: .utf8)
        let report = Log.diagnostics(config: manager.config, stateJSON: state)
        let reportURL = folder.appendingPathComponent("diagnostics.txt")
        try? report.write(to: reportURL, atomically: true, encoding: .utf8)
        var files = [reportURL]
        if shot.state == .on {
            // Let the alert disappear before capturing.
            Thread.sleep(forTimeInterval: 0.3)
            let png = folder.appendingPathComponent("screenshot.png")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-m", png.path]
            try? p.run()
            p.waitUntilExit()
            if FileManager.default.fileExists(atPath: png.path) { files.append(png) }
        }

        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let tail = Log.tail(25)
        let body = """
        **What happened**


        **What you expected**


        **Steps to reproduce**
        1.

        ---
        BetterWM \(v), macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(NSScreen.screens.count) display(s)

        Please drag `\(files.map(\.lastPathComponent).joined(separator: "` and `"))` from the Finder window into this issue.

        <details><summary>Recent log</summary>

        ```
        \(tail.prefix(3500))
        ```
        </details>
        """
        var comps = URLComponents(string: "https://github.com/nanot1m/better-win-manager/issues/new")!
        comps.queryItems = [URLQueryItem(name: "title", value: ""), URLQueryItem(name: "body", value: body)]
        if let url = comps.url { NSWorkspace.shared.open(url) }
        NSWorkspace.shared.activateFileViewerSelecting(files)
        Log.write("app", "bug report prepared in \(folder.path) (\(files.count) file(s))")
    }

    /// Starts over: every window back on screen, the saved layout deleted, and a fresh launch with no memory of
    /// desktops, grids or floating spots. Settings are kept.
    @objc func resetState() {
        let alert = NSAlert()
        alert.messageText = "Reset layout state?"
        alert.informativeText = "All windows come back on screen, the saved grids, floating positions and desktop assignments are deleted, and BetterWM restarts. Your settings and hotkeys are kept."
        alert.addButton(withTitle: "Reset and Restart")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Log.write("app", "layout state reset requested")
        manager.resetLayout()
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; open \"$0\"", Bundle.main.bundlePath]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    @objc func showPermissions() { onboarding.show() }
    @objc func checkForUpdates() { updater.check(interactive: true) }
    @objc func showSettings() {
        configWindow.show(config: manager.config) { [weak self] cfg in
            guard let self else { return }
            self.manager.config = cfg
            self.updater.config = cfg
            self.drag.refreshState()
            self.bar.apply(cfg)
            self.manager.relayout()
            self.registerHotKeys(cfg)
            self.applyGestureSetting(cfg)
            self.statusItem.menu = self.buildMenu()
            self.syncAutoTileItems()
        }
    }
    @objc func togglePause() { setTiling(enabled: !manager.enabled) }

    /// Pausing changes what every other action does, so it is always announced, overlay setting or not.
    func setTiling(enabled: Bool, reason: String? = nil) {
        manager.enabled = enabled
        pauseItem?.title = enabled ? "Pause Tiling" : "Resume Tiling"
        statusItem.button?.image = StatusIcon.make(paused: !enabled)
        hud.show(keys: nil, action: reason ?? (enabled ? "Tiling resumed" : "Tiling paused"), preformatted: true, force: true)
        Log.write("tile", enabled ? "tiling resumed" : "tiling paused")
    }

    /// Asking to tile while paused means tiling is wanted: resume first rather than silently doing nothing.
    private func resumeForTiling() {
        guard !manager.enabled else { return }
        setTiling(enabled: true, reason: "Tiling resumed")
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
            let actions: [Move: String] = [.left: "moveLeft", .right: "moveRight", .up: "moveUp", .down: "moveDown",
                                           .mergeLeft: "mergeLeft", .mergeRight: "mergeRight"]
            for item in menu.items {
                guard let dir = item.representedObject as? Move else { continue }
                item.isEnabled = manager.canMoveFocused(dir)
                item.keyEquivalent = ""
                if let spec = actions[dir].flatMap({ manager.config.hotkeys[$0] }) { HotKey.applyKeyEquivalent(spec, to: item) }
            }
            return
        }
        if menu.title == "Focus" {
            let actions: [Direction: String] = [.left: "focusLeft", .right: "focusRight", .up: "focusUp", .down: "focusDown"]
            for item in menu.items {
                guard let dir = item.representedObject as? Direction else { continue }
                item.keyEquivalent = ""
                if let spec = actions[dir].flatMap({ manager.config.hotkeys[$0] }) { HotKey.applyKeyEquivalent(spec, to: item) }
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
            next.isEnabled = current.map { $0 + 1 < 9 } ?? false
            if let spec = manager.config.hotkeys["sendToNextDesktop"] { HotKey.applyKeyEquivalent(spec, to: next) }
            let prev = menu.addItem(withTitle: "Previous Desktop", action: #selector(sendPrevious), keyEquivalent: "")
            prev.target = self
            prev.isEnabled = current.map { $0 > 0 } ?? false
            if let spec = manager.config.hotkeys["sendToPreviousDesktop"] { HotKey.applyKeyEquivalent(spec, to: prev) }
            menu.addItem(.separator())
        } else {
            let next = menu.addItem(withTitle: "Next Desktop", action: #selector(desktopNext), keyEquivalent: "")
            next.target = self
            if let spec = manager.config.hotkeys["desktopNext"] { HotKey.applyKeyEquivalent(spec, to: next) }
            let prev = menu.addItem(withTitle: "Previous Desktop", action: #selector(desktopPrevious), keyEquivalent: "")
            prev.target = self
            if let spec = manager.config.hotkeys["desktopPrevious"] { HotKey.applyKeyEquivalent(spec, to: prev) }
            menu.addItem(.separator())
        }
        // All nine, existing or not: switching to or sending to a missing one creates it.
        for i in 0..<9 {
            let exists = i < manager.desktopCount
            let item = menu.addItem(withTitle: "Desktop \(i + 1)" + (exists ? "" : "  (new)"), action: sending ? #selector(sendToDesktop(_:)) : #selector(switchDesktop(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = i == current ? .on : .off
            if sending { item.isEnabled = i != current }
            if let spec = manager.config.hotkeys[(sending ? "sendToDesktop" : "desktop") + "\(i + 1)"] { HotKey.applyKeyEquivalent(spec, to: item) }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
