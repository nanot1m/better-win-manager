import Carbon
import Cocoa

/// Global hotkey via Carbon; works for background apps and needs no extra permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    /// Spec like "alt+cmd+space" or "ctrl+shift+k". Returns nil if it cannot be parsed or registered.
    init?(_ spec: String, id: UInt32, action: @escaping () -> Void) {
        self.action = action
        guard let (code, mods) = HotKey.parse(spec) else { return nil }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            Unmanaged<HotKey>.fromOpaque(userData!).takeUnretainedValue().action()
            return noErr
        }, 1, &type, selfPtr, &handler)
        let id = EventHotKeyID(signature: OSType(0x4257_4D4B), id: id)
        guard RegisterEventHotKey(code, mods, id, GetApplicationEventTarget(), 0, &ref) == noErr else { return nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }

    private static let keyCodes: [String: UInt32] = [
        "space": UInt32(kVK_Space), "return": UInt32(kVK_Return), "tab": UInt32(kVK_Tab), "escape": UInt32(kVK_Escape),
        "left": UInt32(kVK_LeftArrow), "right": UInt32(kVK_RightArrow), "up": UInt32(kVK_UpArrow), "down": UInt32(kVK_DownArrow),
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    /// CGEventFlags for a modifier-only spec such as "alt+cmd"; used for the drag gesture.
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
