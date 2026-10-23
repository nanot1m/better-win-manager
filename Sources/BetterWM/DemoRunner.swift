import BetterWMCore
import Cocoa

/// Runs a plain-text demo script so recordings are repeatable. One step per line; `#` starts a comment.
///
///   open Safari                 launch (or activate) an app and wait for its window
///   focus Notes                 bring an app's window to front
///   drag Safari right           ⌥-drag Safari's window onto the right half of the focused window (left|right|top|bottom)
///   action moveLeft             any hotkey action name (see Config.actions), e.g. preset 2 is "action layout 2"
///   layout 2                    apply the n-th layout preset
///   popup / popup close         show or hide the window actions popup
///   caption Tiling with ⌥-drag  flash a caption in the action overlay
///   wait 1.5                    pause
///   quit Notes                  terminate an app
final class DemoRunner {
    private let manager: WindowManager
    private let popup: ActionPopup
    private let hud: ActionHUD
    private let perform: (String) -> Bool
    private var steps: [[String]] = []
    private(set) var running = false
    private var hudWasEnabled = false

    init(manager: WindowManager, popup: ActionPopup, hud: ActionHUD, perform: @escaping (String) -> Bool) {
        self.manager = manager
        self.popup = popup
        self.hud = hud
        self.perform = perform
    }

    func run(scriptAt path: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("Demo: cannot read \(path)"); return }
        steps = text.split(whereSeparator: \.isNewline)
            .map { String($0.split(separator: "#", maxSplits: 1).first ?? "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.split(separator: " ", maxSplits: 1).map(String.init) }
        // Captions need the overlay; restore the user's setting when the demo ends or is stopped.
        hudWasEnabled = hud.enabled
        hud.enabled = true
        running = true
        next()
    }

    /// Abort: drops the remaining steps and closes anything the demo opened on screen.
    func stop() {
        guard running else { return }
        steps = []
        running = false
        hud.enabled = hudWasEnabled
        popup.close()
        manager.overlay.hide()
        manager.interacting = false
        hud.show(keys: nil, action: "Demo stopped", preformatted: true)
        print("Demo: stopped")
    }

    private func next() {
        guard running else { return }
        guard !steps.isEmpty else { running = false; hud.enabled = hudWasEnabled; print("Demo: done"); return }
        let step = steps.removeFirst()
        let cmd = step[0].lowercased(), arg = step.count > 1 ? step[1] : ""
        var delay = 0.8
        switch cmd {
        case "wait":
            delay = Double(arg) ?? 1
        case "open":
            launch(arg)
            delay = 2.0
        case "focus":
            window(of: arg)?.raise()
        case "quit":
            app(named: arg)?.terminate()
        case "caption":
            hud.show(keys: nil, action: arg, preformatted: true)
            delay = 1.6
        case "popup":
            if arg.lowercased() == "close" { popup.close() } else { popup.show() }
        case "layout":
            if let n = Int(arg), let (_, windows) = manager.presetCandidates() {
                let presets = LayoutPreset.presets(for: windows.count)
                if n - 1 < presets.count {
                    hud.show(keys: "⌥\(n)", action: "Layout: \(presets[n - 1].name)", preformatted: true)
                    manager.applyPreset(presets[n - 1])
                }
            }
        case "action":
            if !perform(arg) { print("Demo: unknown action \(arg)") }
        case "drag":
            let parts = arg.split(separator: " ").map(String.init)
            if parts.count >= 2 { delay = drag(appName: parts[0], side: parts[1].lowercased()) }
        default:
            print("Demo: unknown step \(cmd)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.next() }
    }

    private func app(named name: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func window(of name: String) -> AXWindow? {
        guard let a = app(named: name) else { return nil }
        return AX.queue.sync { Spaces.visibleWindows() }.first { $0.pid == a.processIdentifier }
    }

    private func launch(_ name: String) {
        if let a = app(named: name) { a.activate(); return }
        let candidates = ["/Applications", "/System/Applications", "/System/Applications/Utilities"]
            .map { URL(fileURLWithPath: "\($0)/\(name).app") }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name)
            ?? candidates.first { FileManager.default.fileExists(atPath: $0.path) }
        guard let url else { print("Demo: app not found: \(name)"); return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
    }

    /// Glides the cursor to the chosen half of the focused window with the zone highlighted, then drops.
    /// Returns how long the whole gesture takes so the script waits for it.
    private func drag(appName: String, side: String) -> Double {
        guard let w = window(of: appName), let target = manager.system.focused.flatMap({ $0 == w ? nil : $0 }) ?? otherWindow(than: w) else { return 0.5 }
        let f = target.frame
        let point: CGPoint
        switch side {
        case "left": point = CGPoint(x: f.minX + f.width * 0.15, y: f.midY)
        case "right": point = CGPoint(x: f.maxX - f.width * 0.15, y: f.midY)
        case "top": point = CGPoint(x: f.midX, y: f.minY + f.height * 0.15)
        default: point = CGPoint(x: f.midX, y: f.maxY - f.height * 0.15)
        }
        let start = CGPoint(x: w.frame.midX, y: w.frame.minY + 12)
        hud.show(keys: "⌥ drag", action: "\(appName) → \(side) of \(NSRunningApplication(processIdentifier: target.pid)?.localizedName ?? "window")", preformatted: true)
        manager.interacting = true
        let frames = 24
        for i in 0...frames {
            let t = Double(i) / Double(frames)
            let eased = t * t * (3 - 2 * t)
            let p = CGPoint(x: start.x + (point.x - start.x) * eased, y: start.y + (point.y - start.y) * eased)
            DispatchQueue.main.asyncAfter(deadline: .now() + t * 0.9) { [weak self] in
                guard let self else { return }
                CGWarpMouseCursorPosition(p)
                if let zone = self.manager.zone(at: p, dragging: w) { self.manager.overlay.show(zone: zone.1) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self else { return }
            self.manager.overlay.hide()
            self.manager.interacting = false
            if let zone = self.manager.zone(at: point, dragging: w) { self.manager.drop(w, into: zone.0, at: point, from: w.frame) }
        }
        return 2.2
    }

    private func otherWindow(than w: AXWindow) -> AXWindow? {
        AX.queue.sync { Spaces.visibleWindows() }.first { $0 != w && manager.isTiled($0) }
    }
}
