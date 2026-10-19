import Carbon
import BetterWMCore
import Cocoa

/// Global hotkey via Carbon; works for background apps and needs no extra permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private let action: () -> Void

    private struct Weak { weak var value: HotKey? }
    // Weak so that replacing an entry never deallocates a HotKey mid-mutation (its deinit would re-enter here).
    private static var registry: [UInt32: Weak] = [:]
    private static var handler: EventHandlerRef?
    private static let signature = OSType(0x4257_4D4B)

    /// Spec like "alt+cmd+space" or "ctrl+shift+k". Returns nil if it cannot be parsed or registered.
    init?(_ spec: String, id: UInt32, action: @escaping () -> Void) {
        self.id = id
        self.action = action
        guard let (code, mods) = HotKey.parse(spec) else { print("Hotkey '\(spec)': cannot parse"); return nil }
        HotKey.installHandlerOnce()
        let hotKeyID = EventHotKeyID(signature: HotKey.signature, id: id)
        let status = RegisterEventHotKey(code, mods, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            let why = status == OSStatus(eventHotKeyExistsErr) ? "already registered, probably by another running BetterWM instance" : "OSStatus \(status)"
            print("Hotkey '\(spec)': \(why)")
            return nil
        }
        HotKey.registry[id] = Weak(value: self)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }

    // One handler for all hotkeys: Carbon delivers every hot-key event to every handler on the target,
    // so dispatch must go by the ID carried in the event.
    private static func installHandlerOnce() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard hotKeyID.signature == HotKey.signature else { return OSStatus(eventNotHandledErr) }
            HotKey.registry[hotKeyID.id]?.value?.action()
            return noErr
        }, 1, &type, nil, &handler)
    }

    static let keyCodes: [String: UInt32] = [
        "space": UInt32(kVK_Space), "return": UInt32(kVK_Return), "tab": UInt32(kVK_Tab), "escape": UInt32(kVK_Escape),
        "left": UInt32(kVK_LeftArrow), "right": UInt32(kVK_RightArrow), "up": UInt32(kVK_UpArrow), "down": UInt32(kVK_DownArrow),
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    /// CGEventFlags for a modifier-only spec such as "alt+cmd"; used for the drag gesture.
    /// Shows a config hotkey spec on a menu item (display only; the global registration handles the key).
    static func applyKeyEquivalent(_ spec: String, to item: NSMenuItem) {
        var mask: NSEvent.ModifierFlags = []
        var key = ""
        for part in spec.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command": mask.insert(.command)
            case "alt", "option", "opt": mask.insert(.option)
            case "ctrl", "control": mask.insert(.control)
            case "shift": mask.insert(.shift)
            case "space": key = " "
            case "return", "enter": key = "\r"
            case "tab": key = "\t"
            case "escape", "esc": key = "\u{1b}"
            case "left": key = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
            case "right": key = String(UnicodeScalar(NSRightArrowFunctionKey)!)
            case "up": key = String(UnicodeScalar(NSUpArrowFunctionKey)!)
            case "down": key = String(UnicodeScalar(NSDownArrowFunctionKey)!)
            default: key = part
            }
        }
        guard !key.isEmpty else { return }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = mask
    }

    static func eventFlags(_ spec: String) -> CGEventFlags {
        var flags: CGEventFlags = []
        for part in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command": flags.insert(.maskCommand)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "shift": flags.insert(.maskShift)
            default: break
            }
        }
        return flags.isEmpty ? .maskAlternate : flags
    }

    /// Builds a spec string from a key event, e.g. "alt+cmd+space"; nil for modifier-only presses.
    static func spec(from e: NSEvent) -> String? {
        var flags: CGEventFlags = []
        if e.modifierFlags.contains(.control) { flags.insert(.maskControl) }
        if e.modifierFlags.contains(.option) { flags.insert(.maskAlternate) }
        if e.modifierFlags.contains(.shift) { flags.insert(.maskShift) }
        if e.modifierFlags.contains(.command) { flags.insert(.maskCommand) }
        return spec(keyCode: UInt32(e.keyCode), flags: flags)
    }

    static func spec(keyCode: UInt32, flags: CGEventFlags) -> String? {
        guard let name = keyCodes.first(where: { $0.value == keyCode })?.key else { return nil }
        var parts: [String] = []
        if flags.contains(.maskControl) { parts.append("ctrl") }
        if flags.contains(.maskAlternate) { parts.append("alt") }
        if flags.contains(.maskShift) { parts.append("shift") }
        if flags.contains(.maskCommand) { parts.append("cmd") }
        parts.append(name)
        return parts.joined(separator: "+")
    }

    private static func parse(_ spec: String) -> (UInt32, UInt32)? {
        var mods: UInt32 = 0
        var code: UInt32?
        for part in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command": mods |= UInt32(cmdKey)
            case "alt", "option", "opt": mods |= UInt32(optionKey)
            case "ctrl", "control": mods |= UInt32(controlKey)
            case "shift": mods |= UInt32(shiftKey)
            default: code = keyCodes[part]
            }
        }
        guard let code else { return nil }
        return (code, mods)
    }
}
