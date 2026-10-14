import Foundation

struct Config {
    var gap: CGFloat = 16
    var outerGap: CGFloat = 16
    var handleWidth: CGFloat = 16
    var dragModifiers: String = "alt"
    var hotkeys: [String: String] = ["popup": "alt+cmd+space"]
    var autoTile: Bool = true
    var autoTileStrategy: AutoTileStrategy = .rightmost
    var ignoreApps: [String] = Config.defaultIgnoreApps
    var floatSmallWindows: Bool = true
    var smallWindowWidth: CGFloat = 500
    var smallWindowHeight: CGFloat = 400

    /// Utility apps whose windows are dialogs or fixed-size panels; the usual suspects in community yabai/Amethyst rules.
    static let defaultIgnoreApps = [
        "com.apple.systempreferences", "com.apple.calculator", "com.apple.archiveutility",
        "com.apple.ActivityMonitor", "com.apple.Installer", "com.apple.SoftwareUpdate",
        "com.apple.SystemProfiler", "com.apple.Dictionary", "com.apple.screenshot.launcher",
        "com.apple.FontBook", "com.apple.ColorSyncUtility", "com.apple.DigitalColorMeter",
        "com.apple.print.PrinterProxy", "com.apple.Passwords", "com.apple.MigrateAssistant",
        "com.apple.PhotoBooth", "com.apple.AppStore", "com.apple.findmy", "com.apple.weather",
        "com.apple.clock", "com.apple.Stickies", "com.apple.VoiceMemos", "com.apple.AirPort",
        "com.apple.loginwindow", "com.apple.dock", "com.apple.notificationcenterui",
        "com.1password.1password", "org.pqrs.Karabiner-Elements.Settings", "com.apple.CoreSimulator.SimulatorTrampoline",
    ]

    enum AutoTileStrategy: String, CaseIterable {
        case rightmost, leftmost, position, stackFocused

        var title: String {
            switch self {
            case .rightmost: return "New column on the right"
            case .leftmost: return "New column on the left"
            case .position: return "New column at window position"
            case .stackFocused: return "Stack below focused window"
            }
        }
    }

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/betterwm/config.conf")

    static var template: String { Config().serialized() }

    static let actions: [(key: String, title: String)] = [
        ("popup", "Window actions popup"), ("focusNext", "Focus next window"), ("focusPrevious", "Focus previous window"),
        ("moveLeft", "Move left"), ("moveRight", "Move right"), ("moveUp", "Move up"), ("moveDown", "Move down"),
        ("mergeLeft", "Merge into left column"), ("mergeRight", "Merge into right column"),
        ("toggleTile", "Tile / untile focused window"), ("retile", "Retile current screen"),
        ("equalize", "Equalize sizes"), ("pause", "Pause / resume tiling"),
        ("desktopNext", "Next desktop"), ("desktopPrevious", "Previous desktop"),
    ] + (1...9).map { ("desktop\($0)", "Switch to desktop \($0)") }

    func save() {
        try? FileManager.default.createDirectory(at: Config.path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? serialized().write(to: Config.path, atomically: true, encoding: .utf8)
    }

    private func num(_ v: CGFloat) -> String { v == v.rounded() ? String(Int(v)) : String(Double(v)) }

    func serialized() -> String {
        var out = """
        # BetterWM configuration. Lines starting with # are comments.

        # Space between tiled windows and around the screen edge, in points.
        gap = \(num(gap))
        outerGap = \(num(outerGap))
        # Width of the draggable bar sitting in each gap.
        handleWidth = \(num(handleWidth))

        # Tile windows automatically when they open or arrive on a desktop.
        autoTile = \(autoTile)
        # Where an auto-tiled window goes: rightmost, leftmost, position, stackFocused.
        autoTileStrategy = \(autoTileStrategy.rawValue)

        # Apps never tiled automatically, by bundle identifier, comma separated. Manual ⌥-drag still works.
        ignoreApps = \(ignoreApps.joined(separator: ", "))
        # Leave dialog-sized windows floating. Size is width x height in points.
        floatSmallWindows = \(floatSmallWindows)
        smallWindowSize = \(num(smallWindowWidth))x\(num(smallWindowHeight))

        # Modifiers held while dragging a window to tile it (cmd, alt, ctrl, shift joined with +).
        dragModifiers = \(dragModifiers)

        # Global hotkeys: hotkey.<action> = <modifiers>+<key>. Comment a line to unbind.
        # Keys: letters, digits, space, return, tab, escape, left, right, up, down, punctuation.

        """
        for a in Config.actions {
            if let spec = hotkeys[a.key] {
                out += "hotkey.\(a.key) = \(spec)\n"
            } else {
                out += "# hotkey.\(a.key) =\n"
            }
        }
        return out
    }

    static func load() -> Config {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? template.write(to: path, atomically: true, encoding: .utf8)
            return Config()
        }
        return parse(text)
    }

    static func parse(_ text: String) -> Config {
        var cfg = Config()
        cfg.hotkeys = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.firstIndex(of: "#").map { String(raw[..<$0]) } ?? String(raw)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "gap": cfg.gap = Double(value).map { CGFloat($0) } ?? cfg.gap
            case "outerGap": cfg.outerGap = Double(value).map { CGFloat($0) } ?? cfg.outerGap
            case "handleWidth": cfg.handleWidth = Double(value).map { CGFloat($0) } ?? cfg.handleWidth
            case "dragModifiers": cfg.dragModifiers = value
            case "autoTile": cfg.autoTile = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "autoTileStrategy": cfg.autoTileStrategy = AutoTileStrategy(rawValue: value) ?? cfg.autoTileStrategy
                case "ignoreApps": cfg.ignoreApps = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case "floatSmallWindows": cfg.floatSmallWindows = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "smallWindowSize":
                let parts = value.lowercased().split(separator: "x").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if parts.count == 2 { cfg.smallWindowWidth = CGFloat(parts[0]); cfg.smallWindowHeight = CGFloat(parts[1]) }
        case _ where key.hasPrefix("hotkey."): cfg.hotkeys[String(key.dropFirst("hotkey.".count))] = value
            default: print("Unknown config key '\(key)'")
            }
        }
        return cfg
    }
}
