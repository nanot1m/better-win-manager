import BetterWMCore
import Cocoa

/// Command-line switches for screenshots, demos and manual checks.
extension AppDelegate {
    func runDevHooks() {
        if CommandLine.arguments.contains("--settings") {
            showSettings()
            if let i = CommandLine.arguments.firstIndex(of: "--settings-section"), i + 1 < CommandLine.arguments.count, let n = Int(CommandLine.arguments[i + 1]) {
                configWindow.selectSection(n)
            }
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
        if CommandLine.arguments.contains("--onboarding") {
            onboarding.show()
            print("onboarding window:", onboarding.windowNumber)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--slide-sweep"), i + 1 < CommandLine.arguments.count {
            // Scrubs the desktop slide to the given travel over a second and lets go, as a swipe would.
            let travel = CGFloat(Double(CommandLine.arguments[i + 1]) ?? -0.35)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [slide] in
                slide?.began()
                Tween.run(duration: 1, linear: true, step: { x in slide?.changed(travel * x) }, done: {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { slide?.ended(velocity: 0) }
                })
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--overview-hsweep"), i + 1 < CommandLine.arguments.count {
            // Opens the overview, then scrubs it sideways to the given travel over a second and lets go.
            let travel = CGFloat(Double(CommandLine.arguments[i + 1]) ?? -0.4)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [overview] in overview?.toggle() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [overview] in
                overview?.horizontalBegan()
                Tween.run(duration: 1, linear: true, step: { x in overview?.horizontalChanged(travel * x) }, done: {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { overview?.horizontalEnded(velocity: 0) }
                })
            }
        }
        if CommandLine.arguments.contains("--inventory") { print(Log.windowInventory()) }
        if CommandLine.arguments.contains("--sound-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [bar] in bar?.showSoundPopover() }
        }
        if CommandLine.arguments.contains("--overview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [overview] in overview?.toggle() }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--overview-sweep"), i + 1 < CommandLine.arguments.count {
            // Scrubs the overview open over the given seconds, as a gesture would, and holds it there.
            let seconds = Double(CommandLine.arguments[i + 1]) ?? 2
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [overview] in
                overview?.gestureBegan()
                Tween.run(duration: seconds, linear: true, step: { x in overview?.gestureChanged(x) })
            }
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
            statusItem.menu = buildMenu()
            registerHotKeys(manager.config)
            statusItem.menu = buildMenu()
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
