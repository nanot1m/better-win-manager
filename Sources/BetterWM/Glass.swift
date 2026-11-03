import Cocoa

/// Liquid Glass (`NSGlassEffectView`, macOS 26) reached by name, so the app also builds with an older SDK; nil
/// where the system has no glass.
enum Glass {
    static func makeView() -> NSView? {
        guard #available(macOS 26, *), let cls = NSClassFromString("NSGlassEffectView") as? NSView.Type else { return nil }
        return cls.init(frame: .zero)
    }
    static func set(_ view: NSView, cornerRadius: CGFloat) { view.setValue(cornerRadius, forKey: "cornerRadius") }
    /// Style 0 is regular glass, 1 the clear, more transparent one.
    static func set(_ view: NSView, clear: Bool) { view.setValue(clear ? 1 : 0, forKey: "style") }
}
