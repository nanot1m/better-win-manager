import Foundation

public struct Config {
    /// Bumped whenever a key is renamed or its meaning changes; `parse` migrates older files.
    public static let schemaVersion = 7
    public init() {}
    public var gap: CGFloat = 16
    public var outerGap: CGFloat = 16
    /// Per-edge overrides of `outerGap`; nil takes it.
    public var outerGapTop: CGFloat?
    public var outerGapLeft: CGFloat?
    public var outerGapBottom: CGFloat?
    public var outerGapRight: CGFloat?
    public var outerGaps: (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        (outerGapTop ?? outerGap, outerGapLeft ?? outerGap, outerGapBottom ?? outerGap, outerGapRight ?? outerGap)
    }
    public var dragModifiers: String = "alt"
    public var hotkeys: [String: String] = Config.defaultHotkeys

    /// ⌃-arrows and ⌃-digits collide with Mission Control's shortcuts; disable those in System Settings ›
    /// Keyboard › Keyboard Shortcuts › Mission Control, or the registrations fail (and say so in the log).
    public static let defaultHotkeys: [String: String] = {
        var h: [String: String] = [
            "popup": "alt+cmd+space", "switcher": "alt+tab", "switcherBack": "alt+shift+tab",
            "focusNext": "ctrl+]", "focusPrevious": "ctrl+[", "focusFloating": "ctrl+f", "toggleFullscreen": "ctrl+alt+f",
            "moveLeft": "ctrl+alt+left", "moveRight": "ctrl+alt+right", "moveUp": "ctrl+alt+up", "moveDown": "ctrl+alt+down",
            "mergeLeft": "ctrl+alt+shift+left", "mergeRight": "ctrl+alt+shift+right",
            "toggleTile": "ctrl+alt+t", "togglePin": "ctrl+alt+p", "toggleStack": "ctrl+alt+s", "toggleZen": "ctrl+alt+z", "retile": "ctrl+alt+r", "equalize": "ctrl+alt+e",
            "grow": "ctrl+=", "shrink": "ctrl+-",
            "desktopNext": "ctrl+right", "desktopPrevious": "ctrl+left",
        ]
        for i in 1...9 {
            h["desktop\(i)"] = "ctrl+\(i)"
            h["sendToDesktop\(i)"] = "ctrl+alt+\(i)"
        }
        return h
    }()
    public var tileExistingOnStart: Bool = true
    /// Stacked mode: horizontal shift between cascaded windows, in points.
    public var stackOffset: CGFloat = 48
    /// How a stacked screen looks: a cascade, or every window full size behind a row of tabs.
    public enum StackStyle: String, CaseIterable {
        case cascade, tabsTop, tabsLeft, tabsRight
        public var title: String {
            switch self {
            case .cascade: return "Cascade"
            case .tabsTop: return "Tabs on top"
            case .tabsLeft: return "Tabs on the left"
            case .tabsRight: return "Tabs on the right"
            }
        }
    }
    public var stackStyle: StackStyle = .tabsTop
    /// Thickness of the tab strip (height on top, width on the left; left tabs read sideways).
    public var tabHeight: CGFloat = 30
    /// Inactive tabs: "flat" grey, or "glass" (macOS 26; flat before).
    public var tabStyle: String = "glass"
    /// Longest a single tab gets along the strip.
    public var tabWidth: CGFloat = 240
    /// Tab label; {app} and {title} are replaced.
    public var tabTitleFormat: String = "{app} — {title}"
    /// A tab above every tiled window too, so renamed tabs and titles read outside the stacked layout.
    public var tiledTabs: Bool = false
    /// Zen mode: the widest the one window shown gets, in points; 0 for the whole screen.
    public var zenMaxWidth: CGFloat = 1600
    /// Zen mode also hides the status bar on that screen, the window taking its room.
    public var zenHidesBar: Bool = false
    /// Drawn under the windows while zen is on, fading in and out: a hex colour, a path to a picture, or blank for none.
    public var zenBackground: String = ""
    /// Move left/right at the edge of the grid: carry the window to the neighbouring desktop instead of cycling its width.
    public var moveAcrossDesktops: Bool = false
    /// How much the grow and shrink actions change a window, in points.
    public var resizeStep: CGFloat = 40
    /// Screens narrower than this start in stacked mode (0 = never). Handy for a laptop panel next to a big display.
    public var stackScreensNarrowerThan: CGFloat = 0
    /// Remember each desktop's grid and put matching windows back into it on the next launch.
    public var restoreLayouts: Bool = true
    /// Pin every window that starts out floating, so it follows to whichever desktop shows instead of parking.
    public var autoPinFloating: Bool = false
    /// Action log at ~/.config/betterwm/log.txt (menu: Open Log File / Copy Diagnostics Report).
    public var debugLog: Bool = true
    /// Ask GitHub once a day whether a newer release exists; `autoUpdate` installs it without asking.
    public var checkForUpdates: Bool = true
    public var autoUpdate: Bool = false
    /// Window switcher (⌥Tab). Off leaves the ⌥Tab hotkeys unregistered.
    public var switcher: Bool = true
    /// Show live window previews, or just app icons.
    public var switcherThumbnails: Bool = false
    /// Desktop overview: every desktop in a strip and the current one's windows spread out, Mission Control style.
    public var overview: Bool = true
    /// Take over the Mission Control key (F3 on Apple keyboards) to open the overview.
    public var overviewKey: Bool = true
    /// Drive the overview with a four-finger vertical swipe, like Mission Control's gesture; the native gesture
    /// should be turned off in System Settings › Trackpad › More Gestures or both will open.
    public var overviewGesture: Bool = false
    /// Four-finger swipe left/right switches to the next/previous desktop; macOS's own swipe between Spaces
    /// should be turned off or set to three fingers.
    public var desktopSwipe: Bool = false
    /// Fingers for the swipe gestures: 3 or 4.
    public var gestureFingers: Int = 4
    public var autoTile: Bool = false
    public var autoTileStrategy: AutoTileStrategy = .rightmost
    public var focusRing: Bool = true
    public var actionOverlay: Bool = false
    public var focusRingFloating: Bool = true
    public var focusRingWidth: CGFloat = 6
    /// Gap between a tiled window and its ring: the window is drawn that much inside its slot while the ring stays
    /// on the slot's edge.
    public var focusRingPadding: CGFloat = 0
    /// How far the ring reaches beyond a slot's edge; the layout keeps that much clear of the tab strip. The ring is
    /// a card under the window, so its whole width lies outside the window.
    public var focusRingOutset: CGFloat { focusRing ? focusRingWidth : 0 }
    /// Height of the ring's button tab, which stands on the ring's top line.
    public static let ringButtonsHeight: CGFloat = 20
    /// Extra room above the layout for the ring buttons, so the outer gap is measured to them as it is to a tab
    /// strip: nothing when a strip sits there (the buttons stand in it), else the buttons' height above the ring.
    public func ringButtonsRoom(tabsAbove: Bool) -> CGFloat {
        guard focusRing, focusRingActions, !focusRingActionKeys.isEmpty, !tabsAbove else { return 0 }
        return max(0, Self.ringButtonsHeight - ringButtonsOverlap)
    }
    /// How far the buttons and the tabs reach down over the ring, by its width.
    public var ringButtonsOverlap: CGFloat { focusRing ? focusRingWidth : 0 }
    /// The inset of a tiled window within its slot. The ring's inner edge lies a little inside the slot, so the
    /// inset covers that too and the visible gap is exactly `focusRingPadding`; zero keeps the window in its slot.
    public var tileInset: CGFloat {
        guard focusRing, focusRingPadding > 0 else { return 0 }
        return focusRingPadding + max(0, focusRingWidth - focusRingOutset)
    }
    public var focusRingRadius: CGFloat = 24
    /// Small icon buttons for common actions on the ring's top edge.
    public var focusRingActions: Bool = true
    /// The ring, tab strips and action buttons fade in and out instead of popping.
    public var fadeAnimations: Bool = true
    /// Which actions the ring buttons run, in order; keys from `actions`.
    public var focusRingActionKeys: [String] = Config.defaultRingActionKeys
    public static let defaultRingActionKeys = ["toggleTile", "togglePin", "toggleStack", "toggleTabs", "retile", "sendToDesktop"]
    /// Actions that make sense as a ring button, in the order they appear.
    public static let ringActionChoices = ["toggleTile", "togglePin", "toggleFullscreen", "toggleStack", "toggleZen", "toggleTabs", "grow", "shrink", "equalize", "retile",
                                           "sendToDesktop", "sendToPreviousDesktop", "sendToNextDesktop", "overview", "popup"]
    /// Measure each window's real corner radius once and match it; `focusRingRadius` is the fallback.
    public var focusRingAutoRadius: Bool = true
    /// Hex, or "accent" for the system accent colour.
    public var focusRingColor: String = "accent"
    /// Ring colour for a focused window that is floating (untiled); "same" uses focusRingColor.
    public var focusRingFloatingColor: String = "same"
    public var ignoreApps: [String] = Config.defaultIgnoreApps
    public var bar: Bool = false
    /// Desktop chips in the system menu bar, next to the BetterWM icon; useful with the bar off.
    public var menuBarChips: Bool = true
    /// How the menu bar shows the desktops: "chips" (icons, three at most), "numbers", "dots", or "pill" (one
    /// pill with slashes; only the active desktop shows its icons).
    public var menuBarChipStyle: String = "numbers"
    public var barHeight: CGFloat = 32
    public var barClockFormat: String = "EEE d MMM  HH:mm"
    /// Active window label; {app} and {title} are replaced. The title part is dropped when the title is empty.
    public var barTitleFormat: String = "{app}"
    /// The bar's widgets. The left side holds `desktops`, `fullscreen` and `title`; everything else is a
    /// right-side widget. The per-widget booleans below are views onto the right-side list, kept so older config
    /// files (and older app versions reading new ones) keep working.
    public enum BarWidget: String, CaseIterable {
        case desktops, fullscreen, title
        case weather, cpu, memory, disk, keyboard, wifi, battery, clock, menu, media, sound
        /// Roams the free span between the sides; ordered by neither list.
        case cats
        public static let leftKinds: [BarWidget] = [.desktops, .fullscreen, .title]
        public static let rightKinds: [BarWidget] = allCases.filter { !leftKinds.contains($0) && $0 != .cats }
        public var title: String {
            switch self {
            case .desktops: return "Desktop chips"
            case .fullscreen: return "Fullscreen apps"
            case .title: return "Active window title"
            case .weather: return "Weather"
            case .cpu: return "CPU load"
            case .memory: return "Memory used"
            case .disk: return "Free disk"
            case .keyboard: return "Keyboard layout"
            case .wifi: return "Wi-Fi signal"
            case .battery: return "Battery"
            case .clock: return "Clock"
            case .menu: return "BetterWM menu button"
            case .media: return "Now playing (Music, Spotify)"
            case .sound: return "Sound (volume, output and input devices)"
            case .cats: return "Cats"
            }
        }
        /// The widget's own settings, shown under it in Settings › Widgets.
        public var settings: [WidgetSetting] {
            switch self {
            case .desktops: return [WidgetSetting("barDesktopApps", "App icons", "One icon per window open on that desktop.", .toggle)]
            case .title: return [WidgetSetting("barTitleFormat", "Format", "{app} and {title} are replaced; the rest is shown as is.", .text(placeholder: "{app}", width: 200))]
            case .clock: return [WidgetSetting("barClockFormat", "Format", "Unicode date pattern, for example EEE d MMM  HH:mm.", .text(placeholder: "EEE d MMM  HH:mm", width: 200))]
            case .battery: return [WidgetSetting("barBatteryPercent", "Percentage", "Show the number next to the battery icon.", .toggle)]
            case .weather: return [WidgetSetting("barWeatherFahrenheit", "Fahrenheit", nil, .toggle),
                                   WidgetSetting("barWeatherLocation", "Location", "Weather comes from Open-Meteo.",
                                                 .autoOrText(autoTitle: "Use Location Services", customTitle: "Fixed coordinates", placeholder: "52.52, 13.40", auto: "auto", width: 140))]
            default: return []
            }
        }
    }

    /// The value of one config key as the file would show it, or nil for an unknown key.
    public func value(forKey key: String) -> String? {
        for raw in serialized().split(whereSeparator: \.isNewline) {
            let line = Config.stripComment(String(raw))
            guard let eq = line.firstIndex(of: "=") else { continue }
            if line[..<eq].trimmingCharacters(in: .whitespaces) == key { return line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    /// Sets one config key from its file form; a later line wins, so the whole file is re-read with it appended.
    public mutating func set(_ key: String, to value: String) {
        self = Config.parse(serialized() + "\n\(key) = \(value)\n")
    }
    /// One setting of a widget, described rather than coded: the Settings window renders it, and the value lives in
    /// the config file under `key` like any other.
    public struct WidgetSetting {
        public enum Kind {
            case toggle
            case text(placeholder: String?, width: CGFloat)
            /// A choice between an automatic value and a typed one: `auto` is stored for the first option.
            case autoOrText(autoTitle: String, customTitle: String, placeholder: String, auto: String, width: CGFloat)
        }
        public let key: String
        public let title: String
        public let note: String?
        public let kind: Kind
        public init(_ key: String, _ title: String, _ note: String? = nil, _ kind: Kind) { self.key = key; self.title = title; self.note = note; self.kind = kind }
    }

    /// The lists are stored as written: an id this build does not know (a widget from a newer version) keeps its
    /// place through a save, so going back and forth between versions does not lose it.
    public var barWidgetIDs: [String] = [BarWidget.keyboard, .wifi, .battery, .clock, .menu].map(\.rawValue)
    public var barLeftWidgetIDs: [String] = BarWidget.leftKinds.map(\.rawValue)
    public var barWidgets: [BarWidget] {
        get { barWidgetIDs.compactMap(BarWidget.init).filter(BarWidget.rightKinds.contains) }
        set { barWidgetIDs = Self.merge(newValue, into: barWidgetIDs) }
    }
    /// Left-side widgets, in display order.
    public var barLeftWidgets: [BarWidget] {
        get { barLeftWidgetIDs.compactMap(BarWidget.init).filter(BarWidget.leftKinds.contains) }
        set { barLeftWidgetIDs = Self.merge(newValue, into: barLeftWidgetIDs) }
    }
    /// The new order, with the ids `old` had that are not widgets of this build kept at their index.
    private static func merge(_ new: [BarWidget], into old: [String]) -> [String] {
        var ids = new.map(\.rawValue)
        for (i, id) in old.enumerated() where BarWidget(rawValue: id) == nil { ids.insert(id, at: min(i, ids.count)) }
        return ids
    }
    private mutating func setWidget(_ w: BarWidget, _ on: Bool) {
        if on, !barWidgets.contains(w) {
            // Slot it where the default order would have it, after the nearest enabled predecessor.
            let all = BarWidget.rightKinds
            let before = all[..<all.firstIndex(of: w)!]
            let at = before.reversed().compactMap { barWidgets.firstIndex(of: $0) }.first.map { $0 + 1 } ?? 0
            barWidgets.insert(w, at: at)
        } else if !on {
            barWidgets.removeAll { $0 == w }
        }
    }
    /// The per-widget booleans of files before 0.37; read as aliases of the list, no longer written.
    private static let widgetFlags: [String: BarWidget] = [
        "barWeather": .weather, "barBattery": .battery, "barWifi": .wifi, "barInputSource": .keyboard,
        "barCpu": .cpu, "barMemory": .memory, "barDisk": .disk, "barClock": .clock,
    ]
    public var barDesktopApps: Bool = true
    public var barBatteryPercent: Bool = false
    /// A pixel cat wandering the empty part of the bar.
    public var barCat: Bool = true
    /// Cats cross the notch through portals; off, they stay left of it as the bar text does.
    public var barNotchPortals: Bool = true
    /// One cat per entry: a path to a "Pixel Cats 64x64" sheet (Last tick's layout) or "builtin". Empty = one built-in cat.
    public var barCatSheets: [String] = []
    public var barWeatherFahrenheit: Bool = false
    /// "auto" uses Location Services; otherwise "lat,lon".
    public var barWeatherLocation: String = "auto"
    /// "blur" for a translucent material, "glass" for Liquid Glass (macOS 26; blur before), or a hex colour such as 1E1E1ECC.
    public var barBackground: String = "glass"
    /// Desktop chips: "flat" colour fills, or "glass" capsules (macOS 26; flat before).
    public var barChipStyle: String = "glass"
    /// Liquid Glass everywhere it is used: "regular", or "clear" for a more transparent glass.
    public var glassStyle: String = "regular"
    /// "auto" follows the system label colour, or a hex colour.
    public var barTextColor: String = "auto"
    public var barBorderColor: String = "424242"
    /// "accent" follows the system accent colour, or a hex colour.
    public var barActiveColor: String = "accent"
    /// Outline around the focused window's icon in a chip: "auto" (contrasts with the chip) or a hex colour.
    public var barFocusOutlineColor: String = "auto"
    public var barBorderWidth: CGFloat = 0
    public var barRadius: CGFloat = 0
    /// Horizontal space between the bar edge and its content.
    public var barPadding: CGFloat = 24
    /// Horizontal gap between the bar and the screen edges; above zero the bar floats.
    public var barMargin: CGFloat = 0
    /// Distance from the screen edge the bar sits at.
    public var barTopOffset: CGFloat = 0
    /// "top" (where the hidden menu bar lives) or "bottom" (above the Dock).
    public var barPosition: String = "top"
    public var barAtBottom: Bool { barPosition == "bottom" }
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
        ("popup", "Window actions popup"), ("switcher", "Window switcher (⌥Tab)"), ("switcherBack", "Window switcher, backwards"),
        ("overview", "Desktop overview"),
        ("focusNext", "Focus next window"), ("focusPrevious", "Focus previous window"), ("focusFloating", "Focus floating window"), ("focusFullscreen", "Focus fullscreen window"),
        ("focusLeft", "Focus left"), ("focusRight", "Focus right"), ("focusUp", "Focus up"), ("focusDown", "Focus down"),
        ("moveLeft", "Move left"), ("moveRight", "Move right"), ("moveUp", "Move up"), ("moveDown", "Move down"),
        ("mergeLeft", "Merge into left column"), ("mergeRight", "Merge into right column"),
        ("toggleTile", "Tile / untile focused window"), ("togglePin", "Pin / unpin focused floating window"), ("toggleFullscreen", "Fullscreen the focused window within BetterWM"), ("grow", "Grow focused window"), ("shrink", "Shrink focused window"),
        ("toggleStack", "Toggle stacked layout on this screen"),
        ("toggleZen", "Toggle zen mode on this screen"),
        ("toggleTabs", "Tabs: show or hide them on tiled windows; on a stacked screen, the next stacked look"),
        ("retile", "Retile current screen"),
        ("equalize", "Equalize sizes"), ("pause", "Pause / resume tiling"), ("refreshRing", "Re-measure window corners for the focus ring"),
        ("desktopNext", "Next desktop"), ("desktopPrevious", "Previous desktop"),
        ("desktopMoveLeft", "Move this desktop left"), ("desktopMoveRight", "Move this desktop right"),
        ("desktopToNextScreen", "Send this desktop to the next screen"),
        ("sendToNextDesktop", "Send focused window to next desktop"),
        ("sendToDesktop", "Send focused window to a desktop… (menu)"),
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
        version = \(Config.schemaVersion)

        # Space between tiled windows and around the screen edge, in points.
        gap = \(num(gap))
        outerGap = \(num(outerGap))
        # Per-edge gap to the screen; blank takes outerGap.
        outerGapTop = \(outerGapTop.map(num) ?? "")
        outerGapLeft = \(outerGapLeft.map(num) ?? "")
        outerGapBottom = \(outerGapBottom.map(num) ?? "")
        outerGapRight = \(outerGapRight.map(num) ?? "")

        # Tile the windows already open when a desktop is first seen (at launch or on first visit).
        tileExistingOnStart = \(tileExistingOnStart)
        # Action log (log.txt next to this file) for debugging; Copy Diagnostics Report in the menu bundles it.
        debugLog = \(debugLog)
        # Look for a newer release on GitHub once a day; autoUpdate installs it and relaunches without asking.
        checkForUpdates = \(checkForUpdates)
        autoUpdate = \(autoUpdate)
        # Remember each desktop's grid (state.json next to this file) and restore matching windows on launch.
        restoreLayouts = \(restoreLayouts)
        # Pin every window that starts out floating: it follows to whichever desktop is shown (togglePin does it by hand).
        autoPinFloating = \(autoPinFloating)
        # ⌥Tab window switcher grouped by desktop; previews need Screen Recording permission, otherwise icons only.
        switcher = \(switcher)
        switcherThumbnails = \(switcherThumbnails)
        # Desktop overview (Mission Control style). overviewKey takes over the Mission Control key (F3);
        # overviewGesture drives it with a four-finger swipe (turn the native gesture off in System Settings).
        overview = \(overview)
        overviewKey = \(overviewKey)
        overviewGesture = \(overviewGesture)
        # Four-finger swipe left/right switches desktops (turn off macOS's swipe between Spaces, or set it to three fingers).
        desktopSwipe = \(desktopSwipe)
        # Fingers for both swipe gestures: 3 or 4.
        gestureFingers = \(gestureFingers)
        # Tile windows automatically when they open or arrive on a desktop.
        autoTile = \(autoTile)
        # Stacked layout (per screen, toggled with the toggleStack action): windows cascade with this horizontal
        # shift so the ones behind stay visible; screens narrower than the threshold start stacked (0 = never).
        stackOffset = \(num(stackOffset))
        stackScreensNarrowerThan = \(num(stackScreensNarrowerThan))
        # Stacked look: cascade, tabsTop, tabsLeft or tabsRight. The strip is tabHeight points thick (side tabs read sideways),
        # a tab is at most tabWidth points long, and shows tabTitleFormat, where {app} and {title} are replaced.
        stackStyle = \(stackStyle.rawValue)
        tabHeight = \(num(tabHeight))
        # Inactive tabs: "flat" or "glass".
        tabStyle = \(tabStyle)
        tabWidth = \(num(tabWidth))
        tabTitleFormat = \(tabTitleFormat)
        # Also a tab above every tiled window (in the columns layout), to see titles and renamed tabs.
        tiledTabs = \(tiledTabs)
        # Zen mode (toggleZen): one window at a time, centred, at most this wide; 0 for the whole screen.
        zenMaxWidth = \(num(zenMaxWidth))
        zenHidesBar = \(zenHidesBar)
        # Behind the zen window, fading in: a hex colour (RRGGBB or RRGGBBAA), a path to a picture, or blank for the wallpaper.
        zenBackground = \(zenBackground)
        # Move left/right at the grid's edge carries the window to the previous/next desktop instead of cycling its width.
        moveAcrossDesktops = \(moveAcrossDesktops)
        # How much the grow and shrink actions change the focused window, in points.
        resizeStep = \(num(resizeStep))

        # Where an auto-tiled window goes: rightmost, leftmost, position, nextToFocused, stackFocused, autoSplit, spiral.
        #   nextToFocused  new column right after the focused window's column (i3 default)
        #   autoSplit      beside the focused window if it is wider than tall, below it otherwise (i3 autotiling)
        #   spiral         alternately beside and below the last auto-tiled window (approximates dwindle layouts)
        autoTileStrategy = \(autoTileStrategy.rawValue)

        # Flash the pressed hotkey and action name at the bottom of the screen (handy for demos).
        actionOverlay = \(actionOverlay)

        # Highlight the focused window. Style: outline (ring around it) or underneath (glow behind it).
        focusRing = \(focusRing)
        # Also ring floating (untiled) windows, not just tiled ones.
        focusRingFloating = \(focusRingFloating)
        focusRingWidth = \(num(focusRingWidth))
        # Gap between the window and the ring.
        focusRingPadding = \(num(focusRingPadding))
        # Match each window's own corner radius (measured once per window); the radius below is the fallback.
        focusRingAutoRadius = \(focusRingAutoRadius)
        # Icon buttons (tile, stack, send to next desktop, actions) inside the ring's top-right corner.
        focusRingActions = \(focusRingActions)
        focusRingActionKeys = \(focusRingActionKeys.joined(separator: ", "))
        # Fade the ring, tabs and buttons in and out instead of popping them.
        fadeAnimations = \(fadeAnimations)
        focusRingRadius = \(num(focusRingRadius))
        # Colours are hex RRGGBB or RRGGBBAA without a leading #, or "accent" for the system accent colour.
        focusRingColor = \(focusRingColor)
        # Colour for a focused floating (untiled) window: hex, "accent", or "same" as above.
        focusRingFloatingColor = \(focusRingFloatingColor)

        # Status bar under the (auto-hidden) system menu bar: desktops, active window, weather, clock.
        bar = \(bar)
        # Desktop chips in the system menu bar next to the BetterWM icon, with or without the bar.
        menuBarChips = \(menuBarChips)
        # Their look: chips, numbers, dots, or pill (one pill with slashes, icons on the active desktop only).
        menuBarChipStyle = \(menuBarChipStyle)
        barHeight = \(num(barHeight))
        # Unicode date format pattern for the clock.
        barClockFormat = \(barClockFormat)
        # Active window label: {app} and {title} are replaced; the rest is shown as is.
        barTitleFormat = \(barTitleFormat)
        # Left-side widgets in display order: desktops, fullscreen, title. Leave one out to hide it.
        barLeftWidgets = \(barLeftWidgetIDs.joined(separator: ", "))
        # Right-side widgets in display order: weather, cpu, memory, disk, keyboard, wifi, battery, clock, menu, media, sound.
        # Leave one out to hide it.
        barWidgets = \(barWidgetIDs.joined(separator: ", "))
        # Icons of the apps open on each desktop next to its number.
        barDesktopApps = \(barDesktopApps)
        barBatteryPercent = \(barBatteryPercent)
        barCat = \(barCat)
        # Cats cross the notch through a pair of portals; false keeps them left of it.
        barNotchPortals = \(barNotchPortals)
        # One cat per entry, comma separated: a path to a sheet in Last tick's "Pixel Cats 64x64" layout
        # (not bundled; download it yourself) or "builtin" for the hand-drawn cat. Two or more cats interact.
        barCatSheets = \(barCatSheets.joined(separator: ", "))
        barWeatherFahrenheit = \(barWeatherFahrenheit)
        # "auto" asks Location Services; or a fixed "latitude,longitude" such as 52.52,13.40.
        barWeatherLocation = \(barWeatherLocation)
        # Appearance: background is "blur", "glass" (Liquid Glass) or a hex colour (RRGGBB or RRGGBBAA); text colour "auto" or hex.
        barBackground = \(barBackground)
        # Desktop chips: "flat" or "glass".
        barChipStyle = \(barChipStyle)
        # Liquid Glass look wherever it is used: "regular" or "clear" (more transparent).
        glassStyle = \(glassStyle)
        barTextColor = \(barTextColor)
        barBorderColor = \(barBorderColor)
        # Active desktop chip: "accent" or a hex colour.
        barActiveColor = \(barActiveColor)
        # Outline around the focused window's icon: "auto" (contrasts with its chip) or a hex colour.
        barFocusOutlineColor = \(barFocusOutlineColor)
        barBorderWidth = \(num(barBorderWidth))
        barRadius = \(num(barRadius))
        barPadding = \(num(barPadding))
        # Horizontal gap from the screen edges; above zero the bar floats.
        barMargin = \(num(barMargin))
        # Which edge the bar sits at: top (where the hidden menu bar lives) or bottom (above the Dock).
        barPosition = \(barPosition)
        # Distance from that edge. 0 sticks the bar to it.
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
        # ⌃-arrows and ⌃-digits are also Mission Control shortcuts; disable those in System Settings ›
        # Keyboard › Keyboard Shortcuts › Mission Control or these registrations fail.

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

    private static func ids(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    public static func parse(_ text: String) -> Config {
        var cfg = Config()
        let defaultHotkeys = cfg.hotkeys
        cfg.hotkeys = [:]
        var fileVersion = 1
        var hadHotkeys = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = Config.stripComment(String(raw))
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "version": fileVersion = Int(value) ?? 1
            case "gap": cfg.gap = Double(value).map { CGFloat($0) } ?? cfg.gap
            case "outerGap": cfg.outerGap = Double(value).map { CGFloat($0) } ?? cfg.outerGap
            case "outerGapTop": cfg.outerGapTop = Double(value).map { CGFloat($0) }
            case "outerGapLeft": cfg.outerGapLeft = Double(value).map { CGFloat($0) }
            case "outerGapBottom": cfg.outerGapBottom = Double(value).map { CGFloat($0) }
            case "outerGapRight": cfg.outerGapRight = Double(value).map { CGFloat($0) }
            case "handleWidth": break  // the gap handles went in 0.42; tiles are resized by dragging a window's edge
            case "dragModifiers": cfg.dragModifiers = value
            case "workspaces": break  // native Spaces mode was removed in 0.12; the key is accepted and ignored
            case "virtualWorkspaces": break  // workspaces are created on demand since 0.12.1; accepted and ignored
            case "switcher": cfg.switcher = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "switcherThumbnails": cfg.switcherThumbnails = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "overview": cfg.overview = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "overviewKey": cfg.overviewKey = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "overviewGesture": cfg.overviewGesture = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "gestureFingers": cfg.gestureFingers = Int(value) == 3 ? 3 : 4
            case "desktopSwipe": cfg.desktopSwipe = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "debugLog": cfg.debugLog = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "checkForUpdates": cfg.checkForUpdates = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "autoUpdate": cfg.autoUpdate = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "restoreLayouts": cfg.restoreLayouts = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "autoPinFloating": cfg.autoPinFloating = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "floatingOnAllDesktops": break
            case "stackOffset": cfg.stackOffset = Double(value).map { CGFloat($0) } ?? cfg.stackOffset
            case "stackStyle": cfg.stackStyle = StackStyle(rawValue: value) ?? cfg.stackStyle
            case "tabHeight": cfg.tabHeight = Double(value).map { CGFloat($0) } ?? cfg.tabHeight
            case "tabWidth": cfg.tabWidth = Double(value).map { CGFloat($0) } ?? cfg.tabWidth
            case "tabTitleFormat": cfg.tabTitleFormat = value
            case "tiledTabs": cfg.tiledTabs = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "zenMaxWidth": cfg.zenMaxWidth = Double(value).map { CGFloat($0) } ?? cfg.zenMaxWidth
            case "zenHidesBar": cfg.zenHidesBar = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "zenBackground": cfg.zenBackground = value
            case "moveAcrossDesktops": cfg.moveAcrossDesktops = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "resizeStep": cfg.resizeStep = Double(value).map { CGFloat($0) } ?? cfg.resizeStep
            case "stackScreensNarrowerThan": cfg.stackScreensNarrowerThan = Double(value).map { CGFloat($0) } ?? cfg.stackScreensNarrowerThan
            case "animateLayout": break  // removed: Accessibility-driven frame animation was too laggy
            case "tileExistingOnStart": cfg.tileExistingOnStart = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "autoTile": cfg.autoTile = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "autoTileStrategy": cfg.autoTileStrategy = AutoTileStrategy(rawValue: value) ?? cfg.autoTileStrategy
                case "actionOverlay": cfg.actionOverlay = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "focusRing": cfg.focusRing = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "focusRingFloating": cfg.focusRingFloating = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "focusRingStyle": break  // outline, glow and filled styles came and went; the ring is a card under the window
            case "focusRingWidth": cfg.focusRingWidth = Double(value).map { CGFloat($0) } ?? cfg.focusRingWidth
            case "focusRingPadding": cfg.focusRingPadding = Double(value).map { CGFloat($0) } ?? cfg.focusRingPadding
            case "focusRingAutoRadius": cfg.focusRingAutoRadius = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "focusRingActions": cfg.focusRingActions = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "fadeAnimations": cfg.fadeAnimations = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "focusRingActionKeys": cfg.focusRingActionKeys = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case "focusRingRadius": cfg.focusRingRadius = Double(value).map { CGFloat($0) } ?? cfg.focusRingRadius
            case "focusRingColor": cfg.focusRingColor = value
            case "focusRingFloatingColor": cfg.focusRingFloatingColor = value
            case "bar": cfg.bar = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "menuBarChips": cfg.menuBarChips = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "menuBarChipStyle": cfg.menuBarChipStyle = ["chips", "numbers", "dots", "pill"].contains(value.lowercased()) ? value.lowercased() : "chips"
            case "barHeight": cfg.barHeight = Double(value).map { CGFloat($0) } ?? cfg.barHeight
            case "barClockFormat": cfg.barClockFormat = value
            case "barTitleFormat": cfg.barTitleFormat = value
            case "barCatSheet": if !value.isEmpty { cfg.barCatSheets = [value] }  // v1 name, kept forever
            case "barCatSheets": cfg.barCatSheets = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case "barCat": cfg.barCat = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "barNotchPortals": cfg.barNotchPortals = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "barBatteryPercent": cfg.barBatteryPercent = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "barWidgets": cfg.barWidgetIDs = ids(value).filter { BarWidget(rawValue: $0).map(BarWidget.rightKinds.contains) ?? true }
            case "barLeftWidgets": cfg.barLeftWidgetIDs = ids(value).filter { BarWidget(rawValue: $0).map(BarWidget.leftKinds.contains) ?? true }
            case _ where widgetFlags[key] != nil: cfg.setWidget(widgetFlags[key]!, ["true", "yes", "1", "on"].contains(value.lowercased()))
            case "barDesktopApps": cfg.barDesktopApps = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "barWeatherFahrenheit": cfg.barWeatherFahrenheit = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "barWeatherLocation": cfg.barWeatherLocation = value
            case "barBackground": cfg.barBackground = value
            case "barChipStyle": cfg.barChipStyle = value.lowercased() == "glass" ? "glass" : "flat"
            case "glassStyle": cfg.glassStyle = value.lowercased() == "clear" ? "clear" : "regular"
            case "tabStyle": cfg.tabStyle = value.lowercased() == "glass" ? "glass" : "flat"
            case "barTextColor": cfg.barTextColor = value
            case "barBorderColor": cfg.barBorderColor = value
            case "barActiveColor": cfg.barActiveColor = value
            case "barFocusOutlineColor": cfg.barFocusOutlineColor = value
            case "barBorderWidth": cfg.barBorderWidth = Double(value).map { CGFloat($0) } ?? cfg.barBorderWidth
            case "barRadius": cfg.barRadius = Double(value).map { CGFloat($0) } ?? cfg.barRadius
            case "barPadding": cfg.barPadding = Double(value).map { CGFloat($0) } ?? cfg.barPadding
            case "barMargin": cfg.barMargin = Double(value).map { CGFloat($0) } ?? cfg.barMargin
            case "barTopOffset": cfg.barTopOffset = Double(value).map { CGFloat($0) } ?? cfg.barTopOffset
            case "barPosition": cfg.barPosition = value.lowercased() == "bottom" ? "bottom" : "top"
            case "ignoreApps": cfg.ignoreApps = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case "floatSmallWindows": cfg.floatSmallWindows = ["true", "yes", "1", "on"].contains(value.lowercased())
            case "smallWindowSize":
                let parts = value.lowercased().split(separator: "x").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if parts.count == 2 { cfg.smallWindowWidth = CGFloat(parts[0]); cfg.smallWindowHeight = CGFloat(parts[1]) }
            case _ where key.hasPrefix("hotkey."): cfg.hotkeys[String(key.dropFirst("hotkey.".count))] = value; hadHotkeys = true
            default: print("Unknown config key '\(key)'")
            }
        }
        if !hadHotkeys { cfg.hotkeys = defaultHotkeys }
        return migrate(cfg, from: fileVersion, hadHotkeys: hadHotkeys)
    }

    /// Migrations from older schema versions. Each step only fills in what that version could not express.
    static func migrate(_ cfg: Config, from version: Int, hadHotkeys: Bool) -> Config {
        var cfg = cfg
        if version < 2 {
            // v1 files predate the ⌥Tab switcher; give them its default bindings.
            if hadHotkeys {
                if cfg.hotkeys["switcher"] == nil { cfg.hotkeys["switcher"] = "alt+tab" }
                if cfg.hotkeys["switcherBack"] == nil { cfg.hotkeys["switcherBack"] = "alt+shift+tab" }
            }
            // v1 stored hex colours with a leading '#'.
            for kp in [\Config.focusRingColor, \Config.barBorderColor, \Config.barBackground, \Config.barTextColor, \Config.barActiveColor]
            where cfg[keyPath: kp].hasPrefix("#") {
                cfg[keyPath: kp].removeFirst()
            }
        }
        if version < 3 {
            // v3 added the menu widget; files that already pinned an explicit widget order get it appended.
            if !cfg.barWidgets.contains(.menu) { cfg.barWidgets.append(.menu) }
        }
        if version < 7, hadHotkeys, cfg.hotkeys["toggleFullscreen"] == nil { cfg.hotkeys["toggleFullscreen"] = defaultHotkeys["toggleFullscreen"] }
        if version < 6, hadHotkeys, cfg.hotkeys["togglePin"] == nil { cfg.hotkeys["togglePin"] = defaultHotkeys["togglePin"] }
        if version < 6, !cfg.focusRingActionKeys.contains("togglePin") {
            cfg.focusRingActionKeys.insert("togglePin", at: (cfg.focusRingActionKeys.firstIndex(of: "toggleTile") ?? -1) + 1)
        }
        if version < 5, hadHotkeys, cfg.hotkeys["toggleZen"] == nil { cfg.hotkeys["toggleZen"] = defaultHotkeys["toggleZen"] }
        if version < 4, hadHotkeys, cfg.hotkeys["focusFloating"] == nil {
            // v4 added the focus-floating action; an unbound action is written commented out, which reads as
            // absent, so only files from before the action get its default.
            cfg.hotkeys["focusFloating"] = defaultHotkeys["focusFloating"]
        }
        return cfg
    }
}
