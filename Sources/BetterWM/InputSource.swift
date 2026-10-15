import Carbon
import Cocoa

/// Current keyboard layout as a short code ("EN", "RU", "DE"), updated instantly on change.
enum InputSource {
    static func current() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "" }
        if let langs = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) {
            let list = Unmanaged<CFArray>.fromOpaque(langs).takeUnretainedValue() as? [String] ?? []
            if let first = list.first, !first.isEmpty { return String(first.prefix(2)).uppercased() }
        }
        if let name = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) {
            return (Unmanaged<CFString>.fromOpaque(name).takeUnretainedValue() as String).prefix(2).uppercased()
        }
        return ""
    }

    /// Fires `handler` whenever the selected keyboard input source changes.
    static func observe(_ handler: @escaping () -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { _ in handler() }
    }
}
