import BetterWMCore
import Cocoa

/// Append-only action log for debugging and bug reports: `~/.config/betterwm/log.txt`, rotated at 2 MB,
/// mirrored to stdout. Cheap enough to leave on; `debugLog = false` silences it.
enum Log {
    static let path = Config.path.deletingLastPathComponent().appendingPathComponent("log.txt")
    static var enabled = true
    /// Window titles can hold anything (message previews, document names, URLs); only a dev build logs them.
    static let includeTitles = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") == "dev"
    private static var handle: FileHandle?
    private static let queue = DispatchQueue(label: "betterwm.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ category: String, _ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "\(stamp.string(from: Date())) [\(category)] \(message())"
        print(line)
        queue.async { append(line + "\n") }
    }

    private static func append(_ text: String) {
        if handle == nil { open() }
        guard let h = handle, let data = text.data(using: .utf8) else { return }
        h.write(data)
        if (try? h.offset()) ?? 0 > 2_000_000 { rotate() }
    }

    private static func open() {
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path.path) { FileManager.default.createFile(atPath: path.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: path)
        _ = try? handle?.seekToEnd()
    }

    private static func rotate() {
        try? handle?.close()
        handle = nil
        let old = path.deletingPathExtension().appendingPathExtension("1.txt")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: path, to: old)
    }

    /// Last `lines` lines of the log, for the diagnostics report.
    static func tail(_ lines: Int = 400) -> String {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return "(no log)" }
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }

    /// Every ordinary on-screen window as BetterWM sees it: whether Accessibility lists it, its role, and why it
    /// would be skipped. Titles are left out. The probe uses a longer timeout than the app does, to tell a slow
    /// app from one that does not answer at all.
    static func windowInventory() -> String {
        let list = CGWindowInfo.list([.optionOnScreenOnly, .excludeDesktopElements])
        guard !list.isEmpty else { return "(no window list)" }
        var lines: [String] = []
        var axCache: [pid_t: (AXError, [AXUIElement], Int)] = [:]
        for info in list where info.isOrdinaryOtherApp {
            let pid = info.pid, id = info.id
            let app = NSRunningApplication(processIdentifier: pid)
            let bundle = app?.bundleIdentifier ?? info.owner ?? "?"
            if axCache[pid] == nil {
                let el = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(el, 2)
                var v: CFTypeRef?
                let t0 = Date()
                let err = AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &v)
                axCache[pid] = (err, v as? [AXUIElement] ?? [], Int(Date().timeIntervalSince(t0) * 1000))
            }
            let (err, axWindows, ms) = axCache[pid]!
            var match = "not in AX list"
            for el in axWindows {
                var wid: CGWindowID = 0
                guard _AXUIElementGetWindow(el, &wid) == .success, wid == id else { continue }
                var role: CFTypeRef?, sub: CFTypeRef?, minimized: CFTypeRef?
                AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
                AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &sub)
                AXUIElementCopyAttributeValue(el, kAXMinimizedAttribute as CFString, &minimized)
                match = "role \(role as? String ?? "-") subrole \(sub as? String ?? "-")\((minimized as? Bool) == true ? " minimized" : "")"
            }
            let size = "\(Int(info.bounds.width))x\(Int(info.bounds.height))"
            lines.append("#\(id) \(bundle) \(size): AX \(err == .success ? "ok" : "error \(err.rawValue)") in \(ms) ms, \(axWindows.count) AX window(s); \(match)\(AXResponsiveness.isUnresponsive(pid) ? "; marked unresponsive" : "")")
        }
        return lines.isEmpty ? "(none)" : lines.joined(separator: "\n")
    }

    /// Saved window titles are what layout restore matches on, but they do not belong in a report from a release build.
    static func redactTitles(_ json: String) -> String {
        guard !includeTitles, let re = try? NSRegularExpression(pattern: #""title"\s*:\s*"(?:[^"\\]|\\.)*""#) else { return json }
        return re.stringByReplacingMatches(in: json, range: NSRange(json.startIndex..., in: json), withTemplate: #""title" : "<redacted>""#)
    }

    /// Everything a bug report needs, as one text block.
    static func diagnostics(config: Config, stateJSON: String?) -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let screens = NSScreen.screens.map { "\($0.frame) visible \($0.visibleFrame) notch \($0.safeAreaInsets.top)" }.joined(separator: "; ")
        var cfg = config
        cfg.barWeatherLocation = cfg.barWeatherLocation.lowercased() == "auto" ? "auto" : "<redacted>"
        return """
        BetterWM \(v) — macOS \(os)
        Screens: \(screens)
        Accessibility trusted: \(AXIsProcessTrusted())

        === config.conf ===
        \(cfg.serialized())

        === state.json ===
        \(stateJSON.map(redactTitles) ?? "(none)")

        === windows ===
        \(windowInventory())

        === log tail ===
        \(tail())
        """
    }
}
