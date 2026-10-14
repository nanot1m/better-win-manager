import Foundation

struct Config {
    var gap: CGFloat = 16
    var outerGap: CGFloat = 16
    var handleWidth: CGFloat = 16
    var dragModifiers: String = "alt"
    var hotkeys: [String: String] = ["popup": "alt+cmd+space"]
    var autoTile: Bool = true
    var autoTileStrategy: AutoTileStrategy = .rightmost

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

    static let template = """
    # BetterWM configuration. Lines starting with # are comments.

    # Space between tiled windows and around the screen edge, in points.
    gap = 16
    outerGap = 16
    # Width of the draggable bar sitting in each gap.
    handleWidth = 16

    # Tile windows automatically when they open or arrive on a desktop.
    autoTile = true
    # Where an auto-tiled window goes:
    #   rightmost     new column on the right
    #   leftmost      new column on the left
    #   position      new column matching the window's on-screen x
    #   stackFocused  below the focused window in its column
    autoTileStrategy = rightmost

    # Modifiers held while dragging a window to tile it. Combine with "+", e.g. alt+cmd.
    # Modifiers: cmd, alt, ctrl, shift.
    dragModifiers = alt

    # Global hotkeys, one per action: hotkey.<action> = <modifiers>+<key>
    # Keys: letters, digits, space, return, tab, escape, left, right, up, down,
    # and punctuation like - = [ ] ; ' , . / \\ `. Remove or comment a line to unbind.
    hotkey.popup = alt+cmd+space
    # hotkey.focusNext = alt+cmd+]
    # hotkey.focusPrevious = alt+cmd+[
    # hotkey.moveLeft = alt+cmd+h
    # hotkey.moveRight = alt+cmd+l
    # hotkey.moveUp = alt+cmd+k
    # hotkey.moveDown = alt+cmd+j
    # hotkey.mergeLeft = alt+cmd+shift+h
    # hotkey.mergeRight = alt+cmd+shift+l
    # hotkey.toggleTile = alt+cmd+t
    # hotkey.retile = alt+cmd+r
    # hotkey.equalize = alt+cmd+e
    # hotkey.pause = alt+cmd+p
    # hotkey.desktop1 = alt+cmd+1        (desktop1 ... desktop9)
    # hotkey.desktopNext = alt+cmd+right
    # hotkey.desktopPrevious = alt+cmd+left
    """

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
            case _ where key.hasPrefix("hotkey."): cfg.hotkeys[String(key.dropFirst("hotkey.".count))] = value
            default: print("Unknown config key '\(key)'")
            }
        }
        return cfg
    }
}
