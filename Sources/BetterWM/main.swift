import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    var manager: WindowManager!
    var drag: DragController!
    var statusItem: NSStatusItem!
    var pauseItem: NSMenuItem?

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
        drag = DragController(manager: manager)
        if !drag.start() {
            print("Failed to create event tap (needs Accessibility permission).")
            NSApp.terminate(nil)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⊞"
        statusItem.menu = buildMenu()
        print("BetterWM running. Hold ⌥ and drag a window.")
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
        add("Tile / Untile Focused Window", #selector(toggleFocused), "t")
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
        menu.addItem(.separator())
        add("Open Config", #selector(openConfig))
        add("Reload Config", #selector(reloadConfig))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc func switchDesktop(_ sender: NSMenuItem) { Spaces.switchToDesktop(sender.tag) }
    @objc func toggleFocused() { manager.toggleFocused() }
    @objc func retile() { manager.retileCurrentScreen() }
    @objc func equalize() { manager.equalize() }
    @objc func reloadConfig() { manager.reloadConfig() }
    @objc func openConfig() { NSWorkspace.shared.open(Config.path) }
    @objc func togglePause() {
        manager.enabled.toggle()
        pauseItem?.title = manager.enabled ? "Pause Tiling" : "Resume Tiling"
        statusItem.button?.title = manager.enabled ? "⊞" : "⊡"
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Desktops" else { return }
        menu.removeAllItems()
        let current = Spaces.currentDesktopIndex()
        for i in Spaces.desktops().indices {
            let item = menu.addItem(withTitle: "Desktop \(i + 1)", action: #selector(switchDesktop(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = i == current ? .on : .off
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
