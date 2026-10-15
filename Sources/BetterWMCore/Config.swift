import Foundation

public struct Config {
    public init() {}
    public var gap: CGFloat = 16
    public var outerGap: CGFloat = 16
    public var handleWidth: CGFloat = 16
    public var dragModifiers: String = "alt"
    public var hotkeys: [String: String] = ["popup": "alt+cmd+space"]
    public var tileExistingOnStart: Bool = true
    /// Remember each desktop's grid and put matching windows back into it on the next launch.
    public var restoreLayouts: Bool = true
    public var autoTile: Bool = true
    public var autoTileStrategy: AutoTileStrategy = .rightmost
    public var focusRing: Bool = true
    public var actionOverlay: Bool = false
    public var focusRingStyle: FocusRingStyle = .outline
    public var focusRingFloating: Bool = false
    public var focusRingWidth: CGFloat = 3
    public var focusRingRadius: CGFloat = 10
    /// Measure each window's real corner radius once and match it; `focusRingRadius` is the fallback.
    public var focusRingAutoRadius: Bool = true
    public var focusRingColor: String = "4C8BF5"
    public var ignoreApps: [String] = Config.defaultIgnoreApps
    public var bar: Bool = false
    public var barHeight: CGFloat = 28
    public var barClockFormat: String = "EEE d MMM  HH:mm"
    public var barWeather: Bool = true
    public var barBattery: Bool = true
    public var barBatteryPercent: Bool = true
    /// A pixel cat wandering the empty part of the bar.
    public var barCat: Bool = true
    /// One cat per entry: a path to a "Pixel Cats 64x64" sheet (Last tick's layout) or "builtin". Empty = one built-in cat.
    public var barCatSheets: [String] = []
    public var barWifi: Bool = true
    public var barCpu: Bool = true
    public var barMemory: Bool = true
    public var barDisk: Bool = true
    public var barWeatherFahrenheit: Bool = false
    /// "auto" uses Location Services; otherwise "lat,lon".
    public var barWeatherLocation: String = "auto"
    /// "blur" for a translucent material, or a hex colour such as 1E1E1ECC.
    public var barBackground: String = "blur"
    /// "auto" follows the system label colour, or a hex colour.
    public var barTextColor: String = "auto"
    public var barBorderColor: String = "FFFFFF22"
    /// "accent" follows the system accent colour, or a hex colour.
    public var barActiveColor: String = "accent"
    public var barBorderWidth: CGFloat = 0
    public var barRadius: CGFloat = 0
    /// Horizontal space between the bar edge and its content.
    public var barPadding: CGFloat = 12
    /// Horizontal gap between the bar and the screen edges; above zero the bar floats.
    public var barMargin: CGFloat = 0
    /// Distance from the top edge of the screen to the bar.
    public var barTopOffset: CGFloat = 0
    public var floatSmallWindows: Bool = true
    public var smallWindowWidth: CGFloat = 500
    public var smallWindowHeight: CGFloat = 400

    /// Utility apps whose windows are dialogs or fixed-size panels; the usual suspects in community yabai/Amethyst rules.
    public static let defaultIgnoreApps = [
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

    public enum FocusRingStyle: String, CaseIterable {
        case outline, underneath
        public var title: String { self == .outline ? "Outline around the window" : "Glow underneath the window" }
    }

    public enum AutoTileStrategy: String, CaseIterable {
        case rightmost, leftmost, position, nextToFocused, stackFocused, autoSplit, spiral

        public var title: String {
            switch self {
            case .rightmost: return "New column on the right"
            case .leftmost: return "New column on the left"
            case .position: return "New column at window position"
            case .nextToFocused: return "Next to focused window (i3 default)"
            case .stackFocused: return "Stack below focused window"
            case .autoSplit: return "Auto split by focused window shape (i3 autotiling)"
            case .spiral: return "Spiral (approximate)"
            }
        }
    }

    public static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/betterwm/config.conf")
    public static let statePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/betterwm/state.json")

    static var template: String { Config().serialized() }

    public static let actions: [(key: String, title: String)] = [
        ("popup", "Window actions popup"), ("focusNext", "Focus next window"), ("focusPrevious", "Focus previous window"),
        ("moveLeft", "Move left"), ("moveRight", "Move right"), ("moveUp", "Move up"), ("moveDown", "Move down"),
        ("mergeLeft", "Merge into left column"), ("mergeRight", "Merge into right column"),
        ("toggleTile", "Tile / untile focused window"), ("retile", "Retile current screen"),
        ("equalize", "Equalize sizes"), ("pause", "Pause / resume tiling"),
        ("desktopNext", "Next desktop"), ("desktopPrevious", "Previous desktop"),
        ("sendToNextDesktop", "Send focused window to next desktop"),
        ("sendToPreviousDesktop", "Send focused window to previous desktop"),
    ] + (1...9).map { ("desktop\($0)", "Switch to desktop \($0)") }
      + (1...9).map { ("sendToDesktop\($0)", "Send focused window to desktop \($0)") }

    public func save() {
        try? FileManager.default.createDirectory(at: Config.path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? serialized().write(to: Config.path, atomically: true, encoding: .utf8)
    }

    private func num(_ v: CGFloat) -> String { v == v.rounded() ? String(Int(v)) : String(Double(v)) }

    public func serialized() -> String {
        var out = """
        # BetterWM configuration. Lines starting with # are comments.

        # Space between tiled windows and around the screen edge, in points.
        gap = \(num(gap))
        outerGap = \(num(outerGap))
        # Width of the draggable bar sitting in each gap.
        handleWidth = \(num(handleWidth))

        # Tile the windows already open when a desktop is first seen (at launch or on first visit).
        tileExistingOnStart = \(tileExistingOnStart)
        # Remember each desktop's grid (state.json next to this file) and restore matching windows on launch.
        restoreLayouts = \(restoreLayouts)
        # Tile windows automatically when they open or arrive on a desktop.
        autoTile = \(autoTile)
        # Where an auto-tiled window goes: rightmost, leftmost, position, nextToFocused, stackFocused, autoSplit, spiral.
        #   nextToFocused  new column right after the focused window's column (i3 default)
        #   autoSplit      beside the focused window if it is wider than tall, below it otherwise (i3 autotiling)
        #   spiral         alternately beside and below the last auto-tiled window (approximates dwindle layouts)
        autoTileStrategy = \(autoTileStrategy.rawValue)

        # Flash the pressed hotkey and action name at the bottom of the screen (handy for demos).
        actionOverlay = \(actionOverlay)

        # Highlight the focused window. Style: outline (ring around it) or underneath (glow behind it).
        focusRing = \(focusRing)
        focusRingStyle = \(focusRingStyle.rawValue)
        # Also ring floating (untiled) windows, not just tiled ones.
        focusRingFloating = \(focusRingFloating)
        focusRingWidth = \(num(focusRingWidth))
        # Match each window's own corner radius (measured once per window); the radius below is the fallback.
        focusRingAutoRadius = \(focusRingAutoRadius)
        focusRingRadius = \(num(focusRingRadius))
        # Colours are hex RRGGBB or RRGGBBAA without a leading #.
        focusRingColor = \(focusRingColor)

        # Status bar under the (auto-hidden) system menu bar: desktops, active window, weather, clock.
        bar = \(bar)
        barHeight = \(num(barHeight))
        # Unicode date format pattern for the clock.
        barClockFormat = \(barClockFormat)
        barWeather = \(barWeather)
        barBattery = \(barBattery)
        barBatteryPercent = \(barBatteryPercent)
        barCat = \(barCat)
        # One cat per entry, comma separated: a path to a sheet in Last tick's "Pixel Cats 64x64" layout
        # (not bundled; download it yourself) or "builtin" for the hand-drawn cat. Two or more cats interact.
        barCatSheets = \(barCatSheets.joined(separator: ", "))
        barWifi = \(barWifi)
        barCpu = \(barCpu)
        barMemory = \(barMemory)
        barDisk = \(barDisk)
        barWeatherFahrenheit = \(barWeatherFahrenheit)
        # "auto" asks Location Services; or a fixed "latitude,longitude" such as 52.52,13.40.
        barWeatherLocation = \(barWeatherLocation)
        # Appearance: background is "blur" or a hex colour (RRGGBB or RRGGBBAA); text colour "auto" or hex.
        barBackground = \(barBackground)
        barTextColor = \(barTextColor)
        barBorderColor = \(barBorderColor)
        # Active desktop chip: "accent" or a hex colour.
        barActiveColor = \(barActiveColor)
        barBorderWidth = \(num(barBorderWidth))
        barRadius = \(num(barRadius))
        barPadding = \(num(barPadding))
        # Horizontal gap from the screen edges; above zero the bar floats.
        barMargin = \(num(barMargin))
        # Distance from the top of the screen. 0 sticks the bar to the edge (where the hidden menu bar lives).
        barTopOffset = \(num(barTopOffset))

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

    public static func load() -> Config {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? template.write(to: path, atomically: true, encoding: .utf8)
            return Config()
        }
        return parse(text)
    }

    /// A `#` starts a comment unless it directly follows `=`, so older configs with `#4C8BF5` colours still parse.
    static func stripComment(_ line: String) -> String {
        var i = line.startIndex
        while let hash = line[i...].firstIndex(of: "#") {
            let before = line[..<hash].reversed().first { !$0.isWhitespace }
            if before == "=" { i = line.index(after: hash); continue }
            return String(line[..<hash])
        }
        return line
    }

    public static func parse(_ text: String) -> Config {
        var cfg = Config()
        cfg.hotkeys = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = Config.stripComment(String(raw))
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "gap": cfg.gap = Double(value).map { CGFloat($0) } ?? cfg.gap
            case "outerGap": cfg.outerGap = Double(value).map { CGFloat($0) } ?? cfg.outerGap
            case "handleWidth": cfg.handleWidth = Double(value).map { CGFloat($0) } ?? cfg.handleWidth
            case "dragModifiers": cfg.dragModifiers = value
            case "restoreLayouts": cfg.restoreLayouts = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "tileExistingOnStart": cfg.tileExistingOnStart = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "autoTile": cfg.autoTile = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "autoTileStrategy": cfg.autoTileStrategy = AutoTileStrategy(rawValue: value) ?? cfg.autoTileStrategy
                case "actionOverlay": cfg.actionOverlay = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "focusRing": cfg.focusRing = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "focusRingFloating": cfg.focusRingFloating = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "focusRingStyle": cfg.focusRingStyle = FocusRingStyle(rawValue: value) ?? cfg.focusRingStyle
            case "focusRingWidth": cfg.focusRingWidth = Double(value).map { CGFloat($0) } ?? cfg.focusRingWidth
            case "focusRingAutoRadius": cfg.focusRingAutoRadius = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "focusRingRadius": cfg.focusRingRadius = Double(value).map { CGFloat($0) } ?? cfg.focusRingRadius
            case "focusRingColor": cfg.focusRingColor = value
            case "bar": cfg.bar = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "barHeight": cfg.barHeight = Double(value).map { CGFloat($0) } ?? cfg.barHeight
            case "barClockFormat": cfg.barClockFormat = value
            case "barCatSheet": if !value.isEmpty { cfg.barCatSheets = [value] }
            case "barCatSheets": cfg.barCatSheets = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case "barCat": cfg.barCat = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "barBatteryPercent": cfg.barBatteryPercent = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "barBattery": cfg.barBattery = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "barCpu": cfg.barCpu = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "barMemory": cfg.barMemory = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "barDisk": cfg.barDisk = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "barWifi": cfg.barWifi = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "barWeather": cfg.barWeather = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "barWeatherFahrenheit": cfg.barWeatherFahrenheit = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "barWeatherLocation": cfg.barWeatherLocation = value
            case "barBackground": cfg.barBackground = value
            case "barTextColor": cfg.barTextColor = value
            case "barBorderColor": cfg.barBorderColor = value
            case "barActiveColor": cfg.barActiveColor = value
            case "barBorderWidth": cfg.barBorderWidth = Double(value).map { CGFloat($0) } ?? cfg.barBorderWidth
            case "barRadius": cfg.barRadius = Double(value).map { CGFloat($0) } ?? cfg.barRadius
            case "barPadding": cfg.barPadding = Double(value).map { CGFloat($0) } ?? cfg.barPadding
            case "barMargin": cfg.barMargin = Double(value).map { CGFloat($0) } ?? cfg.barMargin
            case "barTopOffset": cfg.barTopOffset = Double(value).map { CGFloat($0) } ?? cfg.barTopOffset
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
